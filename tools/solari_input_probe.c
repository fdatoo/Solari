/**
 * @file tools/solari_input_probe.c
 * @brief Passive CoreGraphics event-tap logger for diagnosing injected input on macOS.
 *
 * Solari injects keyboard and mouse events with CGEventPost. This tool taps the
 * same event stream a game would see and records what actually arrives, so input
 * defects can be measured instead of described.
 *
 * It answers two questions:
 *   - Do held modifiers stay held? A physically held Shift should produce exactly
 *     one down transition. Repeated down/up pairs are the oscillation defect.
 *   - How evenly does mouse motion arrive? Reports inter-arrival spread and how
 *     many deltas were quantised to whole pixels.
 *
 * Build:
 *   clang -O2 -Wall -Wextra -framework CoreGraphics -framework CoreFoundation \
 *       -o build/solari_input_probe tools/solari_input_probe.c
 *
 * Requires Input Monitoring (and Accessibility) permission for the terminal or
 * app that runs it. The tap is listen-only and never modifies the event stream.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Device-specific modifier bits from IOKit/hidsystem/IOLLEvent.h, declared here
   so the tool builds without pulling in the private-ish IOKit HID headers. */
#define DEV_LCTRL 0x00000001u
#define DEV_LSHIFT 0x00000002u
#define DEV_RSHIFT 0x00000004u
#define DEV_LCMD 0x00000008u
#define DEV_RCMD 0x00000010u
#define DEV_LALT 0x00000020u
#define DEV_RALT 0x00000040u
#define DEV_RCTRL 0x00002000u

#define MAX_MOTION_SAMPLES 200000

/** @brief One tracked modifier and the transitions observed for it. */
typedef struct {
  const char *name;
  CGEventFlags generic_mask;
  uint32_t left_bit;
  uint32_t right_bit;
  bool was_down;
  unsigned long downs;
  unsigned long ups;
  uint64_t last_change_ns;
  uint64_t min_hold_ns;  /* shortest observed down->up, exposes flicker */
} modifier_track_t;

static modifier_track_t modifiers[] = {
  {"shift", kCGEventFlagMaskShift, DEV_LSHIFT, DEV_RSHIFT, false, 0, 0, 0, UINT64_MAX},
  {"control", kCGEventFlagMaskControl, DEV_LCTRL, DEV_RCTRL, false, 0, 0, 0, UINT64_MAX},
  {"option", kCGEventFlagMaskAlternate, DEV_LALT, DEV_RALT, false, 0, 0, 0, UINT64_MAX},
  {"command", kCGEventFlagMaskCommand, DEV_LCMD, DEV_RCMD, false, 0, 0, 0, UINT64_MAX},
};
static const size_t modifier_count = sizeof(modifiers) / sizeof(modifiers[0]);

static volatile sig_atomic_t stop_requested = 0;
static FILE *csv = NULL;
static uint64_t start_ns = 0;

static unsigned long key_downs = 0, key_ups = 0, flags_events = 0;
static unsigned long motion_events = 0, scroll_events = 0, button_events = 0;
static unsigned long integral_deltas = 0, zero_deltas = 0;

static double *motion_gaps_ms = NULL;
static size_t motion_gap_count = 0;
static uint64_t last_motion_ns = 0;

/** @brief Monotonic nanoseconds, unaffected by wall-clock changes. */
static uint64_t now_ns(void) {
  return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

static void handle_signal(int signum) {
  (void) signum;
  stop_requested = 1;
}

/** @brief Render active modifier bits as a compact string such as "shift|control". */
static void describe_flags(CGEventFlags flags, char *out, size_t out_size) {
  out[0] = '\0';
  for (size_t i = 0; i < modifier_count; ++i) {
    if (flags & modifiers[i].generic_mask) {
      if (out[0] != '\0') {
        strlcat(out, "|", out_size);
      }
      strlcat(out, modifiers[i].name, out_size);
    }
  }
  if (out[0] == '\0') {
    strlcat(out, "none", out_size);
  }
}

/**
 * @brief Update modifier transition counters from an event's flag word.
 *
 * A modifier counts as down when its generic mask is set. Solari's backend
 * clears the generic mask when the last device bit is released, so this mirrors
 * exactly what a game observes.
 */
static void track_modifiers(CGEventFlags flags, uint64_t timestamp_ns) {
  for (size_t i = 0; i < modifier_count; ++i) {
    modifier_track_t *mod = &modifiers[i];
    const bool down = (flags & mod->generic_mask) != 0;
    if (down == mod->was_down) {
      continue;
    }

    if (down) {
      mod->downs++;
    } else {
      mod->ups++;
      if (mod->last_change_ns != 0) {
        const uint64_t held = timestamp_ns - mod->last_change_ns;
        if (held < mod->min_hold_ns) {
          mod->min_hold_ns = held;
        }
      }
    }

    mod->was_down = down;
    mod->last_change_ns = timestamp_ns;
  }
}

static const char *event_type_name(CGEventType type) {
  switch (type) {
    case kCGEventKeyDown:
      return "key_down";
    case kCGEventKeyUp:
      return "key_up";
    case kCGEventFlagsChanged:
      return "flags_changed";
    case kCGEventMouseMoved:
      return "mouse_moved";
    case kCGEventLeftMouseDragged:
      return "left_drag";
    case kCGEventRightMouseDragged:
      return "right_drag";
    case kCGEventOtherMouseDragged:
      return "other_drag";
    case kCGEventLeftMouseDown:
      return "left_down";
    case kCGEventLeftMouseUp:
      return "left_up";
    case kCGEventRightMouseDown:
      return "right_down";
    case kCGEventRightMouseUp:
      return "right_up";
    case kCGEventScrollWheel:
      return "scroll";
    default:
      return "other";
  }
}

static bool is_motion(CGEventType type) {
  return type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged ||
         type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged;
}

static CGEventRef on_event(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
  (void) proxy;
  (void) context;

  /* The tap is disabled by the system if it ever times out; re-arm and continue. */
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    fprintf(stderr, "[probe] tap disabled by system, re-enabling\n");
    return event;
  }

  const uint64_t timestamp_ns = now_ns();
  const double elapsed_ms = (double) (timestamp_ns - start_ns) / 1e6;
  const CGEventFlags flags = CGEventGetFlags(event);

  int64_t keycode = 0;
  double dx = 0.0, dy = 0.0;
  double gap_ms = 0.0;

  if (type == kCGEventKeyDown || type == kCGEventKeyUp || type == kCGEventFlagsChanged) {
    keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (type == kCGEventKeyDown) {
      key_downs++;
    } else if (type == kCGEventKeyUp) {
      key_ups++;
    } else {
      flags_events++;
    }
    track_modifiers(flags, timestamp_ns);
  } else if (is_motion(type)) {
    dx = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
    dy = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
    motion_events++;

    if (dx == 0.0 && dy == 0.0) {
      zero_deltas++;
    } else if (dx == floor(dx) && dy == floor(dy)) {
      integral_deltas++;
    }

    if (last_motion_ns != 0) {
      gap_ms = (double) (timestamp_ns - last_motion_ns) / 1e6;
      if (motion_gaps_ms && motion_gap_count < MAX_MOTION_SAMPLES) {
        motion_gaps_ms[motion_gap_count++] = gap_ms;
      }
    }
    last_motion_ns = timestamp_ns;
  } else if (type == kCGEventScrollWheel) {
    scroll_events++;
    track_modifiers(flags, timestamp_ns);
  } else {
    button_events++;
    track_modifiers(flags, timestamp_ns);
  }

  if (csv) {
    char flag_text[128];
    describe_flags(flags, flag_text, sizeof(flag_text));
    fprintf(
      csv,
      "%.3f,%s,%lld,0x%08llx,%s,%.4f,%.4f,%.3f\n",
      elapsed_ms,
      event_type_name(type),
      (long long) keycode,
      (unsigned long long) flags,
      flag_text,
      dx,
      dy,
      gap_ms
    );
  }

  return event;
}

static int compare_double(const void *lhs, const void *rhs) {
  const double a = *(const double *) lhs;
  const double b = *(const double *) rhs;
  return (a > b) - (a < b);
}

static void print_summary(double duration_s) {
  printf("\n");
  printf("=== Solari input probe summary ===\n");
  printf("duration            %.2f s\n", duration_s);
  printf("key down / up       %lu / %lu\n", key_downs, key_ups);
  printf("flags_changed       %lu\n", flags_events);
  printf("mouse motion        %lu\n", motion_events);
  printf("scroll / button     %lu / %lu\n", scroll_events, button_events);

  printf("\n-- modifier transitions (a held modifier should show exactly 1 down) --\n");
  bool any_modifier = false;
  for (size_t i = 0; i < modifier_count; ++i) {
    const modifier_track_t *mod = &modifiers[i];
    if (mod->downs == 0 && mod->ups == 0) {
      continue;
    }
    any_modifier = true;

    char verdict[96] = "";
    if (mod->downs > 2) {
      const double rate = duration_s > 0 ? (double) mod->downs / duration_s : 0.0;
      snprintf(verdict, sizeof(verdict), "  <-- OSCILLATING (%.1f down/s)", rate);
    }

    printf("%-9s down=%-5lu up=%-5lu", mod->name, mod->downs, mod->ups);
    if (mod->min_hold_ns != UINT64_MAX) {
      printf(" shortest_hold=%.1f ms", (double) mod->min_hold_ns / 1e6);
    }
    printf("%s\n", verdict);
  }
  if (!any_modifier) {
    printf("(none observed)\n");
  }

  if (motion_gap_count > 0) {
    qsort(motion_gaps_ms, motion_gap_count, sizeof(double), compare_double);

    double sum = 0.0;
    for (size_t i = 0; i < motion_gap_count; ++i) {
      sum += motion_gaps_ms[i];
    }
    const double mean = sum / (double) motion_gap_count;

    double variance = 0.0;
    for (size_t i = 0; i < motion_gap_count; ++i) {
      const double d = motion_gaps_ms[i] - mean;
      variance += d * d;
    }
    variance /= (double) motion_gap_count;

    printf("\n-- mouse motion pacing (%zu intervals) --\n", motion_gap_count);
    printf("mean                %.2f ms  (%.0f Hz)\n", mean, mean > 0 ? 1000.0 / mean : 0.0);
    printf("stddev (jitter)     %.2f ms\n", sqrt(variance));
    printf("min / median        %.2f / %.2f ms\n", motion_gaps_ms[0], motion_gaps_ms[motion_gap_count / 2]);
    printf("p95 / max           %.2f / %.2f ms\n",
           motion_gaps_ms[(size_t) ((double) motion_gap_count * 0.95)],
           motion_gaps_ms[motion_gap_count - 1]);

    /* A stall near 250 ms is the signature of cursor-association suppression. */
    if (motion_gaps_ms[motion_gap_count - 1] >= 200.0) {
      printf("NOTE: max gap >= 200 ms, consistent with cursor-association suppression.\n");
    }

    printf("\n-- mouse delta resolution --\n");
    printf("whole-pixel deltas  %lu / %lu\n", integral_deltas, motion_events);
    printf("zero deltas         %lu\n", zero_deltas);
    if (motion_events > 0 && integral_deltas == motion_events - zero_deltas) {
      printf("NOTE: every delta is a whole pixel, so sub-pixel motion is being discarded.\n");
    }
  }
  printf("\n");
}

int main(int argc, char **argv) {
  double duration_s = 0.0;
  const char *csv_path = NULL;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--csv") == 0 && i + 1 < argc) {
      csv_path = argv[++i];
    } else if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
      duration_s = atof(argv[++i]);
    } else if (strcmp(argv[i], "--help") == 0) {
      printf("usage: %s [--csv PATH] [--duration SECONDS]\n", argv[0]);
      printf("\nRecords injected keyboard and mouse events and reports modifier\n");
      printf("transitions plus mouse pacing. Stop with Ctrl-C if no duration is set.\n");
      return 0;
    } else {
      fprintf(stderr, "unknown argument: %s (try --help)\n", argv[i]);
      return 2;
    }
  }

  motion_gaps_ms = calloc(MAX_MOTION_SAMPLES, sizeof(double));
  if (!motion_gaps_ms) {
    fprintf(stderr, "out of memory\n");
    return 1;
  }

  if (csv_path) {
    csv = fopen(csv_path, "w");
    if (!csv) {
      fprintf(stderr, "cannot open %s for writing\n", csv_path);
      free(motion_gaps_ms);
      return 1;
    }
    fprintf(csv, "elapsed_ms,type,keycode,flags_raw,flags,delta_x,delta_y,gap_ms\n");
  }

  const CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
                           CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventMouseMoved) |
                           CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDragged) |
                           CGEventMaskBit(kCGEventOtherMouseDragged) | CGEventMaskBit(kCGEventLeftMouseDown) |
                           CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventRightMouseDown) |
                           CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventScrollWheel);

  CFMachPortRef tap = CGEventTapCreate(
    kCGSessionEventTap,
    kCGTailAppendEventTap,
    kCGEventTapOptionListenOnly,
    mask,
    on_event,
    NULL
  );

  if (!tap) {
    fprintf(stderr,
            "Failed to create the event tap.\n\n"
            "This needs Input Monitoring permission for whichever app runs it\n"
            "(Terminal, iTerm, or your IDE). Grant it under:\n"
            "  System Settings > Privacy & Security > Input Monitoring\n"
            "then run this tool again.\n");
    if (csv) {
      fclose(csv);
    }
    free(motion_gaps_ms);
    return 1;
  }

  CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
  CGEventTapEnable(tap, true);

  signal(SIGINT, handle_signal);
  signal(SIGTERM, handle_signal);

  start_ns = now_ns();
  if (duration_s > 0) {
    fprintf(stderr, "[probe] recording for %.1f s...\n", duration_s);
  } else {
    fprintf(stderr, "[probe] recording, press Ctrl-C to stop...\n");
  }
  if (csv_path) {
    fprintf(stderr, "[probe] writing events to %s\n", csv_path);
  }

  /* Run in slices so Ctrl-C and the duration limit are both honoured promptly. */
  while (!stop_requested) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    if (duration_s > 0 && (double) (now_ns() - start_ns) / 1e9 >= duration_s) {
      break;
    }
    if (!CGEventTapIsEnabled(tap)) {
      CGEventTapEnable(tap, true);
    }
  }

  const double elapsed_s = (double) (now_ns() - start_ns) / 1e9;
  CGEventTapEnable(tap, false);

  if (csv) {
    fclose(csv);
  }

  print_summary(elapsed_s);

  CFRelease(source);
  CFRelease(tap);
  free(motion_gaps_ms);
  return 0;
}
