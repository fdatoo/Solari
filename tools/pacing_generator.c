/**
 * @file tools/pacing_generator.c
 * @brief Post mouse motion at a known-perfect cadence to isolate where jitter comes from.
 *
 * The input probe measures when events arrive, but during a stream that reading
 * mixes together the client's send timing, the network, Solari's injection, and
 * macOS event delivery. This posts events locally on a precise schedule, so the
 * only terms left are injection and delivery. Run the probe alongside it:
 *
 *   ./build/solari_input_probe --duration 12 &
 *   ./build/pacing_generator --rate 120 --duration 10
 *
 * Tight arrivals mean the injection path is sound and stream jitter comes from
 * the client or the network. Clumped arrivals mean macOS delivery quantises
 * events regardless of how evenly they are posted, which no backend change fixes.
 *
 * Motion alternates by one pixel each tick, so the cursor stays where it is.
 *
 * Build:
 *   clang -O2 -Wall -Wextra -framework CoreGraphics -framework CoreFoundation \
 *       -o build/pacing_generator tools/pacing_generator.c
 */

#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <mach/mach_time.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static volatile sig_atomic_t stop_requested = 0;

static void handle_signal(int signum) {
  (void) signum;
  stop_requested = 1;
}

static uint64_t now_ns(void) {
  return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

static int compare_double(const void *lhs, const void *rhs) {
  const double a = *(const double *) lhs;
  const double b = *(const double *) rhs;
  return (a > b) - (a < b);
}

int main(int argc, char **argv) {
  double rate_hz = 120.0;
  double duration_s = 10.0;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--rate") == 0 && i + 1 < argc) {
      rate_hz = atof(argv[++i]);
    } else if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
      duration_s = atof(argv[++i]);
    } else if (strcmp(argv[i], "--help") == 0) {
      printf("usage: %s [--rate HZ] [--duration SECONDS]\n", argv[0]);
      printf("\nPosts mouse motion on a precise schedule and reports how closely\n");
      printf("the posts kept to it. Run solari_input_probe alongside to compare\n");
      printf("against when the events actually arrive.\n");
      return 0;
    } else {
      fprintf(stderr, "unknown argument: %s (try --help)\n", argv[i]);
      return 2;
    }
  }

  if (rate_hz <= 0 || duration_s <= 0) {
    fprintf(stderr, "rate and duration must be positive\n");
    return 2;
  }

  if (!AXIsProcessTrusted()) {
    fprintf(stderr,
            "This process cannot post events: it needs Accessibility permission\n"
            "for whichever app runs it (Terminal, iTerm, or your IDE).\n"
            "Grant it under System Settings > Privacy & Security > Accessibility.\n");
    return 1;
  }

  const CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  if (!source) {
    fprintf(stderr, "could not create an event source\n");
    return 1;
  }
  CGEventSourceSetLocalEventsSuppressionInterval(source, 0.0);

  const double period_ns = 1e9 / rate_hz;
  const uint64_t total = (uint64_t) (duration_s * rate_hz);

  double *post_gaps_ms = calloc(total > 0 ? total : 1, sizeof(double));
  double *schedule_error_ms = calloc(total > 0 ? total : 1, sizeof(double));
  if (!post_gaps_ms || !schedule_error_ms) {
    fprintf(stderr, "out of memory\n");
    CFRelease(source);
    free(post_gaps_ms);
    free(schedule_error_ms);
    return 1;
  }

  signal(SIGINT, handle_signal);
  signal(SIGTERM, handle_signal);

  fprintf(stderr, "[generator] posting %.0f events/s for %.1f s...\n", rate_hz, duration_s);

  const uint64_t start_ns = now_ns();
  uint64_t previous_post_ns = 0;
  uint64_t posted = 0;

  const CGPoint origin = CGEventGetLocation(CGEventCreate(NULL));

  for (uint64_t i = 0; i < total && !stop_requested; ++i) {
    /* Absolute schedule, so a slow tick cannot make every later tick late. */
    const uint64_t target_ns = start_ns + (uint64_t) (period_ns * (double) i);
    while (now_ns() < target_ns) {
      const int64_t remaining = (int64_t) target_ns - (int64_t) now_ns();
      if (remaining > 1000000) {
        struct timespec ts = {0, remaining - 500000};
        nanosleep(&ts, NULL);
      }
    }

    const CGEventRef event = CGEventCreateMouseEvent(source, kCGEventMouseMoved, origin, kCGMouseButtonLeft);
    if (!event) {
      continue;
    }

    /* Alternate direction so the cursor does not travel across the screen. */
    const double delta = (i % 2 == 0) ? 1.0 : -1.0;
    CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, delta);
    CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, 0.0);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);

    const uint64_t actual_ns = now_ns();
    schedule_error_ms[posted] = (double) ((int64_t) actual_ns - (int64_t) target_ns) / 1e6;
    if (previous_post_ns != 0) {
      post_gaps_ms[posted] = (double) (actual_ns - previous_post_ns) / 1e6;
    }
    previous_post_ns = actual_ns;
    posted++;
  }

  CFRelease(source);

  printf("\n=== pacing generator summary ===\n");
  printf("requested rate      %.0f Hz (%.2f ms period)\n", rate_hz, period_ns / 1e6);
  printf("events posted       %llu\n", (unsigned long long) posted);

  if (posted > 1) {
    /* Skip index 0, which has no preceding event to measure against. */
    const uint64_t count = posted - 1;
    qsort(post_gaps_ms + 1, count, sizeof(double), compare_double);

    double sum = 0.0;
    for (uint64_t i = 1; i <= count; ++i) {
      sum += post_gaps_ms[i];
    }
    const double mean = sum / (double) count;

    double variance = 0.0;
    for (uint64_t i = 1; i <= count; ++i) {
      const double d = post_gaps_ms[i] - mean;
      variance += d * d;
    }
    variance /= (double) count;

    printf("\n-- send side, gap between posts --\n");
    printf("mean                %.2f ms\n", mean);
    printf("stddev              %.3f ms\n", sqrt(variance));
    printf("p95 / max           %.2f / %.2f ms\n",
           post_gaps_ms[1 + (uint64_t) ((double) count * 0.95)],
           post_gaps_ms[count]);

    double worst_error = 0.0;
    for (uint64_t i = 0; i < posted; ++i) {
      const double magnitude = fabs(schedule_error_ms[i]);
      if (magnitude > worst_error) {
        worst_error = magnitude;
      }
    }
    printf("worst schedule slip %.2f ms\n", worst_error);
    printf("\nCompare these against the probe's arrival numbers. If the send side is\n");
    printf("tight and arrivals are not, the spread is added after the post.\n");
  }

  free(post_gaps_ms);
  free(schedule_error_ms);
  return 0;
}
