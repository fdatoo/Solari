/**
 * @file src/platform/macos/virtual_display.m
 * @brief Definitions for on-demand virtual displays.
 *
 * Compiled with ARC.
 *
 * The interfaces below are private CoreGraphics API, redeclared here because
 * there is no public way to create a display. They are resolved by name at
 * runtime rather than linked, so a macOS release that removes or renames them
 * leaves this reporting "unsupported" instead of failing to launch.
 */

// platform includes
#import <AppKit/AppKit.h>
#import <signal.h>
#import <spawn.h>
#import <errno.h>
#import <stdatomic.h>
#import <poll.h>
#import <sys/wait.h>
#import <unistd.h>

// local includes
#import "virtual_display.h"

/// How long to wait for the window server to adopt a new display.
static const NSTimeInterval kAdoptionTimeout = 3.0;

/// Interval between checks while waiting for adoption.
static const useconds_t kAdoptionPollInterval = 50000;

/**
 * Descriptor the helper writes its verdict to.
 *
 * The exit status cannot be used. proc_t::running() installs a process wide
 * `waitpid(-1, ..., WNOHANG)` reaper that runs on every call, including from the
 * control loop every 150 ms for the whole stream, so it routinely reaps these
 * children first and leaves waitpid here returning ECHILD. That reads as failure
 * for a helper that actually succeeded, which then re-spawns on every acquire
 * and rearranges the desktop each time. A pipe cannot be stolen.
 */
static const int kHelperVerdictFD = 3;

/// Byte the helper writes to report verified success.
static const char kHelperSuccessByte = 'K';

#pragma mark - Private CoreGraphics interfaces

@interface CGVirtualDisplayDescriptor: NSObject
@property(strong) dispatch_queue_t queue;
@property uint32_t vendorID;
@property uint32_t productID;
@property uint32_t serialNum;
@property(copy) NSString *name;
@property CGSize sizeInMillimeters;
@property uint32_t maxPixelsWide;
@property uint32_t maxPixelsHigh;
@property CGPoint redPrimary;
@property CGPoint greenPrimary;
@property CGPoint bluePrimary;
@property CGPoint whitePoint;
@property(copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode: NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings: NSObject
@property(copy) NSArray *modes;
@property uint32_t hiDPI;
@property uint32_t rotation;
@end

@interface CGVirtualDisplay: NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly) CGDirectDisplayID displayID;
@end

/// Display origins as they were before the virtual display took the origin.
static NSString *g_saved_arrangement = nil;

/// Set by the reconfiguration callback; consumed by acquire on the next call.
static atomic_bool g_arrangement_dirty = false;

/// Forward declaration: the reconfiguration callback needs the shared instance.
static void solari_display_reconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context);

#pragma mark - Implementation

@interface SolariVirtualDisplay ()
@property(nonatomic, strong, nullable) id display;
@property(nonatomic, strong, nullable) dispatch_queue_t queue;
@property(nonatomic, assign) CGDirectDisplayID displayID;
@property(nonatomic, assign) int width;
@property(nonatomic, assign) int height;
@property(nonatomic, assign) BOOL hiDPI;

/**
 * In-server CoreGraphics mode queries are unreliable for this display in both
 * directions, so successful selection is remembered here rather than re-read.
 */
@property(nonatomic, assign) BOOL hiDPIVerified;

/// Whether the display has been verified as the main display.
@property(nonatomic, assign) BOOL primaryVerified;

- (BOOL)selectHiDPIMode;
- (BOOL)isHiDPIActive;
- (BOOL)makePrimaryOutOfProcess;
+ (void)saveArrangementOnce;
+ (void)restoreArrangement;
@end

@implementation SolariVirtualDisplay

+ (BOOL)isSupported {
  return NSClassFromString(@"CGVirtualDisplay") != nil &&
         NSClassFromString(@"CGVirtualDisplayDescriptor") != nil &&
         NSClassFromString(@"CGVirtualDisplaySettings") != nil &&
         NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

/**
 * @brief Whether a display id is currently active.
 *
 * @param displayID Display to look for.
 * @return True when the window server lists it.
 */
+ (BOOL)isDisplayActive:(CGDirectDisplayID)displayID {
  uint32_t count = 0;
  if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
    return NO;
  }

  CGDirectDisplayID ids[32];
  const uint32_t capacity = (uint32_t) (sizeof(ids) / sizeof(ids[0]));
  if (CGGetActiveDisplayList(capacity, ids, &count) != kCGErrorSuccess) {
    return NO;
  }

  for (uint32_t i = 0; i < count && i < capacity; ++i) {
    if (ids[i] == displayID) {
      return YES;
    }
  }

  return NO;
}

+ (nullable instancetype)displayWithWidth:(int)width
                                   height:(int)height
                              refreshRate:(double)refreshRate
                                    hiDPI:(BOOL)hiDPI {
  if (![SolariVirtualDisplay isSupported] || width <= 0 || height <= 0) {
    return nil;
  }

  SolariVirtualDisplay *instance = [[SolariVirtualDisplay alloc] init];
  if (!instance) {
    return nil;
  }

  Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
  Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
  Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
  Class displayClass = NSClassFromString(@"CGVirtualDisplay");

  // A serial queue of our own, not the main queue. This process has no main run
  // loop to service, and the display only needs somewhere to deliver callbacks.
  instance.queue = dispatch_queue_create("dev.fdatoo.solari.virtualdisplay", DISPATCH_QUEUE_SERIAL);

  CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
  descriptor.queue = instance.queue;
  descriptor.name = @"Solari";
  descriptor.vendorID = 0xF0F0;
  descriptor.productID = 0x5678;
  descriptor.serialNum = (uint32_t) (arc4random() | 1);
  descriptor.maxPixelsWide = (uint32_t) width;
  descriptor.maxPixelsHigh = (uint32_t) height;

  // A plausible physical size matters. The window server rejects a descriptor
  // whose pixel density works out implausible, so this claims a 27 inch panel
  // rather than deriving millimetres from the requested pixel count.
  descriptor.sizeInMillimeters = CGSizeMake(597, 336);

  // sRGB primaries and a D65 white point.
  descriptor.redPrimary = CGPointMake(0.640, 0.330);
  descriptor.greenPrimary = CGPointMake(0.300, 0.600);
  descriptor.bluePrimary = CGPointMake(0.150, 0.060);
  descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
  descriptor.terminationHandler = ^(id sender, id reason) {
    NSLog(@"[solari] virtual display terminated by the window server");
  };

  id display = [[displayClass alloc] initWithDescriptor:descriptor];
  if (!display) {
    NSLog(@"[solari] could not create a virtual display");
    return nil;
  }

  // width and height are the PIXEL size the stream will capture. For HiDPI the
  // mode is registered at half that, in points, while maxPixelsWide/High above
  // stay at the full pixel size: the gap between the two is what gives the
  // window server room to build the 2x backing store. Registering the mode at
  // the same size as maxPixels leaves no room, and the display silently comes
  // up 1x, which is exactly what happened before this comment existed.
  CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
  const uint32_t mode_width = hiDPI ? (uint32_t) (width / 2) : (uint32_t) width;
  const uint32_t mode_height = hiDPI ? (uint32_t) (height / 2) : (uint32_t) height;
  NSArray *modes = @[
    [[modeClass alloc] initWithWidth:mode_width height:mode_height refreshRate:refreshRate]
  ];

  settings.modes = modes;
  settings.hiDPI = hiDPI ? 1 : 0;

  if (![display applySettings:settings]) {
    NSLog(@"[solari] could not apply virtual display settings");
    return nil;
  }

  instance.display = display;
  instance.displayID = [display displayID];
  instance.hiDPI = hiDPI;
  instance.width = width;
  instance.height = height;

  // Adoption is not immediate, and capturing a display the window server has not
  // registered yet fails, so wait for it to show up rather than assuming.
  const NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + kAdoptionTimeout;
  while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
    if ([SolariVirtualDisplay isDisplayActive:instance.displayID]) {
      if (hiDPI) {
        instance.hiDPIVerified = [instance selectHiDPIMode];
        if (!instance.hiDPIVerified) {
          NSLog(@"[solari] HiDPI mode selection did not take on the virtual display");
        }
      }

      instance.primaryVerified = [instance makePrimaryOutOfProcess];
      return instance;
    }
    usleep(kAdoptionPollInterval);
  }

  NSLog(@"[solari] virtual display %u was created but never became active", instance.displayID);
  return nil;
}

/**
 * @brief Switch the display to its HiDPI mode.
 *
 * Setting hiDPI on the descriptor builds the doubled backing store, but the
 * window server still presents the 1x interpretation of it, which renders the
 * desktop at one device pixel per point and makes everything look tiny. The
 * HiDPI mode is a scaled duplicate, so it only appears in the mode list when
 * duplicates are asked for, and it has to be selected explicitly.
 */
/**
 * @brief Out of process HiDPI selection, exit code as ground truth.
 *
 * In this server process, CGDisplayCopyDisplayMode and friends return null for
 * freshly created virtual displays even though the active display list sees
 * them, while every other process reads them fine. Cause unknown; measured
 * repeatedly. So the selection re-executes this same binary with a flag: the
 * child reads the modes, applies the HiDPI one, verifies, and its exit status
 * is the verification.
 *
 * @return True when the child verified a HiDPI mode is presenting.
 */
- (BOOL)selectHiDPIModeOutOfProcess {
  return [self runHelper:"--vd-select-hidpi"];
}

/**
 * @brief Re-execute this binary with a helper flag targeting this display.
 *
 * @param flag Helper mode argument.
 * @return True when the child exited reporting verified success.
 */
- (BOOL)runHelper:(const char *)flag {
  NSString *executable = [[NSBundle mainBundle] executablePath];
  if (!executable) {
    return NO;
  }

  int verdict[2] = {-1, -1};
  if (pipe(verdict) != 0) {
    return NO;
  }

  NSString *displayArgument = [NSString stringWithFormat:@"%u", self.displayID];
  const char *argv[] = {executable.fileSystemRepresentation, flag, displayArgument.UTF8String, NULL};

  // The server's sockets are not O_CLOEXEC, so without this the helper inherits
  // every listening port and keeps them bound if the server dies while it runs,
  // which stops the next instance binding them. stderr is kept for diagnostics,
  // and the verdict pipe is placed at a descriptor the helper knows about.
  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO);
  posix_spawn_file_actions_adddup2(&actions, verdict[1], kHelperVerdictFD);

  pid_t child = 0;
  const int spawned = posix_spawn(&child, argv[0], &actions, &attributes, (char *const *) argv, NULL);

  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attributes);
  close(verdict[1]);

  if (spawned != 0) {
    close(verdict[0]);
    NSLog(@"[solari] could not spawn the display helper %s", flag);
    return NO;
  }

  // Read the verdict rather than the exit status. The read ends when the helper
  // writes, or at end of file when it exits without writing, so this needs no
  // cooperation from waitpid at all.
  BOOL succeeded = NO;
  const NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 8.0;

  while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
    struct pollfd waiter = {.fd = verdict[0], .events = POLLIN};
    const int ready = poll(&waiter, 1, 200);
    if (ready < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    if (ready == 0) {
      continue;
    }

    char byte = 0;
    const ssize_t got = read(verdict[0], &byte, 1);
    if (got <= 0) {
      break;  // helper exited without reporting success
    }

    succeeded = byte == kHelperSuccessByte;
    break;
  }

  close(verdict[0]);

  if (!succeeded) {
    // Only meaningful if the helper is still alive; if the reaper already took
    // it this is a no-op, which is why the verdict does not depend on it.
    kill(child, SIGKILL);
  }
  waitpid(child, NULL, WNOHANG);

  return succeeded;
}

/**
 * @brief Make this display the main one, out of process.
 *
 * The menu bar, dock, and newly opened windows follow the main display, so an
 * extended virtual display streams an empty desktop. The in-server attempt at
 * this was silently renormalised away, which in hindsight was the same
 * unreliable in-server display configuration that broke mode selection.
 *
 * @return True when the child verified this display is main.
 */
- (BOOL)makePrimaryOutOfProcess {
  [SolariVirtualDisplay saveArrangementOnce];
  return [self runHelper:"--vd-make-primary"];
}

/**
 * @brief Record every display's origin, once, before anything moves them.
 *
 * Taken before the first change rather than at each attempt, so a retry cannot
 * record the already-rearranged layout as though it were the original.
 */
+ (void)saveArrangementOnce {
  if (g_saved_arrangement) {
    return;
  }

  uint32_t count = 0;
  CGDirectDisplayID ids[32];
  if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess || count == 0) {
    return;
  }

  NSMutableString *arrangement = [NSMutableString string];
  for (uint32_t i = 0; i < count; ++i) {
    const CGRect bounds = CGDisplayBounds(ids[i]);
    [arrangement appendFormat:@"%u,%d,%d;", ids[i], (int) bounds.origin.x, (int) bounds.origin.y];
  }

  g_saved_arrangement = [arrangement copy];
  NSLog(@"[solari] saved display arrangement: %@", g_saved_arrangement);
}

/**
 * @brief Put the display arrangement back, if it was changed.
 */
+ (void)restoreArrangement {
  NSString *arrangement = g_saved_arrangement;
  if (!arrangement) {
    return;
  }
  g_saved_arrangement = nil;

  NSString *executable = [[NSBundle mainBundle] executablePath];
  if (!executable) {
    return;
  }

  const char *argv[] = {
    executable.fileSystemRepresentation,
    "--vd-restore-arrangement",
    arrangement.UTF8String,
    NULL
  };

  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO);

  pid_t child = 0;
  const int spawned = posix_spawn(&child, argv[0], &actions, &attributes, (char *const *) argv, NULL);

  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attributes);

  if (spawned == 0) {
    // Reaped best effort: another part of Sunshine reaps every child process
    // periodically, so this may find nothing to wait for.
    waitpid(child, NULL, 0);
  }
}

- (BOOL)selectHiDPIMode {
  // The duplicate can appear a moment after the display is adopted, and the
  // configuration itself can be applied and then not take, so this verifies by
  // reading the mode back and retries rather than trusting return codes.
  const NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 0.5;

  while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
    NSDictionary *options = @{(__bridge NSString *) kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(self.displayID, (__bridge CFDictionaryRef) options);

    CGDisplayModeRef best = NULL;
    if (modes) {
      for (CFIndex i = 0; i < CFArrayGetCount(modes); ++i) {
        CGDisplayModeRef mode = (CGDisplayModeRef) CFArrayGetValueAtIndex(modes, i);

        // A HiDPI mode is one whose backing store is denser than its point size.
        if (CGDisplayModeGetPixelWidth(mode) <= CGDisplayModeGetWidth(mode)) {
          continue;
        }
        if (!best || CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetPixelWidth(best)) {
          best = mode;
        }
      }
    }

    if (best) {
      CGDisplayConfigRef configuration = NULL;
      if (CGBeginDisplayConfiguration(&configuration) == kCGErrorSuccess && configuration) {
        CGConfigureDisplayWithDisplayMode(configuration, self.displayID, best, NULL);
        if (CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession) != kCGErrorSuccess) {
          CGCancelDisplayConfiguration(configuration);
        }
      }
    }

    if (modes) {
      CFRelease(modes);
    }

    if ([self isHiDPIActive]) {
      return YES;
    }

    usleep(kAdoptionPollInterval);
  }

  if ([self isHiDPIActive]) {
    return YES;
  }

  return [self selectHiDPIModeOutOfProcess];
}

/**
 * @brief Whether the display is presenting a HiDPI mode right now.
 *
 * @return True when the active mode's backing store is denser than its points.
 */
- (BOOL)isHiDPIActive {
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(self.displayID);
  if (!mode) {
    return NO;
  }

  const BOOL active = CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetWidth(mode);
  CGDisplayModeRelease(mode);
  return active;
}

- (void)dealloc {
  // Releasing the CGVirtualDisplay is what removes it from the desktop.
  _display = nil;
}

@end

/**
 * @brief Report verified success to the parent.
 *
 * Written to a pipe rather than signalled by exit status, which a process wide
 * child reaper in this codebase routinely consumes first.
 */
static void solari_vd_report_success(void) {
  const char byte = kHelperSuccessByte;
  ssize_t written = 0;
  do {
    written = write(kHelperVerdictFD, &byte, 1);
  } while (written < 0 && errno == EINTR);
}

int solari_vd_select_hidpi_main(uint32_t display_id) {
  // Runs in a fresh process where the mode queries actually work.
  const NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 4.0;

  while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
    NSDictionary *options = @{(__bridge NSString *) kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(display_id, (__bridge CFDictionaryRef) options);

    CGDisplayModeRef best = NULL;
    if (modes) {
      for (CFIndex i = 0; i < CFArrayGetCount(modes); ++i) {
        CGDisplayModeRef mode = (CGDisplayModeRef) CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetPixelWidth(mode) <= CGDisplayModeGetWidth(mode)) {
          continue;
        }
        if (!best || CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetPixelWidth(best)) {
          best = mode;
        }
      }
    }

    if (best) {
      fprintf(stderr, "[vd-helper] applying %zux%zu (pixels %zux%zu)\n",
              CGDisplayModeGetWidth(best), CGDisplayModeGetHeight(best),
              CGDisplayModeGetPixelWidth(best), CGDisplayModeGetPixelHeight(best));

      CGDisplayConfigRef configuration = NULL;
      CGError err = CGBeginDisplayConfiguration(&configuration);
      if (err == kCGErrorSuccess && configuration) {
        err = CGConfigureDisplayWithDisplayMode(configuration, display_id, best, NULL);
        fprintf(stderr, "[vd-helper] configure: %d\n", err);
        if (err == kCGErrorSuccess) {
          err = CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
          fprintf(stderr, "[vd-helper] complete: %d\n", err);
        } else {
          CGCancelDisplayConfiguration(configuration);
        }
      } else {
        fprintf(stderr, "[vd-helper] begin: %d\n", err);
      }
    } else {
      fprintf(stderr, "[vd-helper] no HiDPI duplicate offered (modes: %ld)\n",
              modes ? CFArrayGetCount(modes) : -1);
    }

    if (modes) {
      CFRelease(modes);
    }

    // Let the change land before reading back.
    usleep(300000);

    CGDisplayModeRef current = CGDisplayCopyDisplayMode(display_id);
    if (current) {
      const bool active = CGDisplayModeGetPixelWidth(current) > CGDisplayModeGetWidth(current);
      fprintf(stderr, "[vd-helper] readback: logical %zux%zu pixels %zux%zu\n",
              CGDisplayModeGetWidth(current), CGDisplayModeGetHeight(current),
              CGDisplayModeGetPixelWidth(current), CGDisplayModeGetPixelHeight(current));
      CGDisplayModeRelease(current);
      if (active) {
        solari_vd_report_success();
        return 0;
      }
    }

    usleep(100000);
  }

  return 1;
}

int solari_vd_make_primary_main(uint32_t display_id) {
  // Runs in a fresh process where display configuration genuinely applies. The
  // display sitting at the origin is the main one, so the target goes to (0,0)
  // and every other display is laid out to its right, preserving order.
  const NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 4.0;

  while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
    if (CGDisplayIsMain(display_id)) {
      solari_vd_report_success();
      return 0;
    }

    uint32_t count = 0;
    CGDirectDisplayID ids[32];
    if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess || count == 0) {
      usleep(100000);
      continue;
    }

    bool target_active = false;
    for (uint32_t i = 0; i < count; ++i) {
      if (ids[i] == display_id) {
        target_active = true;
      }
    }
    if (!target_active) {
      usleep(100000);
      continue;
    }

    // Translate every display by the same offset so the target lands on the
    // origin. Laying the others out in a row instead would make this display
    // primary just as well, but it would also destroy the user's arrangement:
    // a monitor stacked above another would come back beside it, permanently.
    const CGRect target_bounds = CGDisplayBounds(display_id);
    const int32_t shift_x = (int32_t) target_bounds.origin.x;
    const int32_t shift_y = (int32_t) target_bounds.origin.y;

    CGDisplayConfigRef configuration = NULL;
    if (CGBeginDisplayConfiguration(&configuration) == kCGErrorSuccess && configuration) {
      CGError err = kCGErrorSuccess;
      for (uint32_t i = 0; i < count; ++i) {
        const CGRect bounds = CGDisplayBounds(ids[i]);
        const int32_t x = (int32_t) bounds.origin.x - shift_x;
        const int32_t y = (int32_t) bounds.origin.y - shift_y;

        err = CGConfigureDisplayOrigin(configuration, ids[i], x, y);
        fprintf(stderr, "[vd-helper] origin %u -> (%d, %d): %d\n", ids[i], x, y, err);
      }

      err = CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
      fprintf(stderr, "[vd-helper] complete: %d\n", err);
      if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(configuration);
      }
    }

    usleep(300000);

    if (CGDisplayIsMain(display_id)) {
      fprintf(stderr, "[vd-helper] display %u is now main\n", display_id);
      solari_vd_report_success();
      return 0;
    }

    usleep(100000);
  }

  return 1;
}

int solari_vd_restore_arrangement_main(const char *arrangement) {
  // kCGConfigureForSession persists until logout, so the rearrangement made to
  // hand the virtual display the origin outlives both the helper and the server.
  // kCGConfigureForAppOnly would revert, but it reverts when this helper exits,
  // which is immediately, so it cannot be used for the change either. That
  // leaves restoring explicitly from origins the server recorded beforehand.
  if (!arrangement || !*arrangement) {
    return 1;
  }

  CGDisplayConfigRef configuration = NULL;
  if (CGBeginDisplayConfiguration(&configuration) != kCGErrorSuccess || !configuration) {
    return 1;
  }

  const char *cursor = arrangement;
  int restored = 0;
  while (*cursor) {
    unsigned int display_id = 0;
    int x = 0;
    int y = 0;
    if (sscanf(cursor, "%u,%d,%d", &display_id, &x, &y) != 3) {
      break;
    }

    // A display that has since been unplugged is skipped rather than fatal.
    if (CGDisplayIsActive(display_id)) {
      CGConfigureDisplayOrigin(configuration, display_id, x, y);
      fprintf(stderr, "[vd-helper] restore %u -> (%d, %d)\n", display_id, x, y);
      restored++;
    }

    const char *next = strchr(cursor, ';');
    if (!next) {
      break;
    }
    cursor = next + 1;
  }

  if (restored == 0) {
    CGCancelDisplayConfiguration(configuration);
    return 1;
  }

  if (CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession) != kCGErrorSuccess) {
    CGCancelDisplayConfiguration(configuration);
    return 1;
  }

  return 0;
}

#pragma mark - Shared instance

/**
 * The virtual display is shared for the process rather than owned per capture.
 * platf::display() runs several times while encoders are probed, and creating one
 * per call left a trail of displays behind and rearranged the desktop each time.
 */
static SolariVirtualDisplay *g_shared_display = nil;
static int g_shared_width = 0;
static int g_shared_height = 0;
static double g_shared_refresh = 0;
static BOOL g_shared_hidpi = NO;
static NSLock *g_shared_lock = nil;

__attribute__((constructor)) static void solari_virtual_display_init(void) {
  g_shared_lock = [[NSLock alloc] init];


  // streaming_will_stop only fires once a session has ended, but the encoder
  // probe creates a display before any session exists, and that one has nothing
  // to balance it. Exit is the backstop for every path that does not stream.
  atexit(solari_virtual_display_release);
}

/**
 * @brief Drop cached verification when the display set changes.
 *
 * Only reacts once the change has been applied, and only to changes that can
 * actually move a display, so a mode set of our own does not invalidate itself.
 */
static void solari_display_reconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
  (void) display;
  (void) context;

  if (flags & kCGDisplayBeginConfigurationFlag) {
    return;
  }

  const CGDisplayChangeSummaryFlags interesting =
    kCGDisplayMovedFlag | kCGDisplaySetMainFlag | kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayDesktopShapeChangedFlag;
  if (!(flags & interesting)) {
    return;
  }

  // Set a flag and return. Nothing else.
  //
  // The window server runs this on the main thread while it holds the display
  // configuration, and it fires precisely when a display is being created, which
  // is when acquire() below holds g_shared_lock across a display creation and two
  // helper process spawns. Taking that lock here parked the main thread for as
  // long as that took, which shows up as the process not responding and stalls
  // the window server hard enough to beachball the whole machine on any input.
  // Reading CGDisplayIsMain here is no better: it re-enters CoreGraphics during
  // a reconfiguration it is itself reporting.
  atomic_store_explicit(&g_arrangement_dirty, true, memory_order_relaxed);
}

CGDirectDisplayID solari_virtual_display_acquire(int width, int height, double refreshRate, BOOL hiDPI) {
  if (width <= 0 || height <= 0) {
    return 0;
  }

  // Registered here rather than from a constructor. This binary re-executes
  // itself as a helper, so a constructor would install this in every helper too,
  // where it is useless and fires during the very reconfiguration the helper is
  // performing. Only the server calls acquire.
  static dispatch_once_t register_once;
  dispatch_once(&register_once, ^{
    // Someone at the Mac can drag the arrangement in System Settings, or plug in
    // a monitor, and the window server renormalises origins, silently demoting
    // the virtual display. Without this, the cached verification would keep
    // claiming it is still main for the rest of the session.
    CGDisplayRegisterReconfigurationCallback(solari_display_reconfigured, NULL);
  });

  [g_shared_lock lock];

  // Reuse whatever is already there when the geometry matches, so a probe run
  // does not tear the desktop apart once per encoder.
  // A display can go away without this process asking: the window server
  // terminates one when the desktop it belonged to is reconfigured, which
  // happens when the physical displays sleep or are disconnected. Matching
  // geometry is not enough, because the object outlives the display it names,
  // and handing back a dead identifier means capturing a display that no longer
  // exists while the log cheerfully reports success.
  if (g_shared_display && ![SolariVirtualDisplay isDisplayActive:g_shared_display.displayID]) {
    NSLog(@"[solari] virtual display %u went away; creating a new one", g_shared_display.displayID);
    g_shared_display = nil;
    g_shared_width = g_shared_height = 0;
    g_shared_refresh = 0;
  }

  if (g_shared_display && g_shared_width == width && g_shared_height == height &&
      g_shared_refresh == refreshRate && g_shared_hidpi == hiDPI) {
    SolariVirtualDisplay *existing = g_shared_display;
    [g_shared_lock unlock];

    // Selecting the HiDPI mode right after creation can fail while the window
    // server is still adopting the display. Callers come back through here
    // repeatedly, so keep trying until it verifies, then stop for good: the
    // helper is a process spawn, and reapplying a display mode mid-stream is
    // a visible glitch.
    // Displays moved since the last call, so whatever was verified may no longer
    // hold. Checked here rather than in the callback, because this thread is
    // allowed to block and the callback's thread is emphatically not.
    if (atomic_exchange_explicit(&g_arrangement_dirty, false, memory_order_relaxed)) {
      if (!CGDisplayIsMain(existing.displayID)) {
        existing.primaryVerified = NO;
      }
    }

    if (hiDPI && !existing.hiDPIVerified) {
      existing.hiDPIVerified = [existing selectHiDPIMode];
    }
    if (!existing.primaryVerified) {
      existing.primaryVerified = [existing makePrimaryOutOfProcess];
    }

    return existing.displayID;
  }

  g_shared_display = nil;

  SolariVirtualDisplay *created = [SolariVirtualDisplay displayWithWidth:width
                                                                 height:height
                                                            refreshRate:refreshRate
                                                                  hiDPI:hiDPI];
  if (!created) {
    g_shared_width = g_shared_height = 0;
    g_shared_refresh = 0;
    [g_shared_lock unlock];
    return 0;
  }

  g_shared_display = created;
  g_shared_width = width;
  g_shared_height = height;
  g_shared_refresh = refreshRate;
  g_shared_hidpi = hiDPI;

  const CGDirectDisplayID displayID = created.displayID;
  [g_shared_lock unlock];
  return displayID;
}

void solari_virtual_display_release(void) {
  [g_shared_lock lock];
  const BOOL had_display = g_shared_display != nil;
  g_shared_display = nil;
  g_shared_width = g_shared_height = 0;
  g_shared_refresh = 0;
  [g_shared_lock unlock];

  if (had_display) {
    // After the display is gone, so restoring cannot place anything relative to
    // a display that is about to vanish.
    [SolariVirtualDisplay restoreArrangement];
  }
}

CGDirectDisplayID solari_virtual_display_current(void) {
  [g_shared_lock lock];
  const CGDirectDisplayID displayID = g_shared_display ? g_shared_display.displayID : 0;
  [g_shared_lock unlock];
  return displayID;
}
