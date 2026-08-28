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
#import <sys/wait.h>

// local includes
#import "virtual_display.h"

/// How long to wait for the window server to adopt a new display.
static const NSTimeInterval kAdoptionTimeout = 3.0;

/// Interval between checks while waiting for adoption.
static const useconds_t kAdoptionPollInterval = 50000;

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
  instance.queue = dispatch_queue_create("dev.lizardbyte.sunshine.virtualdisplay", DISPATCH_QUEUE_SERIAL);

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
    NSLog(@"[sunshine] virtual display terminated by the window server");
  };

  id display = [[displayClass alloc] initWithDescriptor:descriptor];
  if (!display) {
    NSLog(@"[sunshine] could not create a virtual display");
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
    NSLog(@"[sunshine] could not apply virtual display settings");
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
          NSLog(@"[sunshine] HiDPI mode selection did not take on the virtual display");
        }
      }

      instance.primaryVerified = [instance makePrimaryOutOfProcess];
      return instance;
    }
    usleep(kAdoptionPollInterval);
  }

  NSLog(@"[sunshine] virtual display %u was created but never became active", instance.displayID);
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

  NSString *displayArgument = [NSString stringWithFormat:@"%u", self.displayID];
  const char *argv[] = {executable.fileSystemRepresentation, flag, displayArgument.UTF8String, NULL};

  pid_t child = 0;
  if (posix_spawn(&child, argv[0], NULL, NULL, (char *const *) argv, NULL) != 0) {
    NSLog(@"[sunshine] could not spawn the HiDPI selection helper");
    return NO;
  }

  const NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 5.0;
  while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
    int status = 0;
    const pid_t reaped = waitpid(child, &status, WNOHANG);
    if (reaped == child) {
      return WIFEXITED(status) && WEXITSTATUS(status) == 0;
    }
    if (reaped < 0) {
      return NO;
    }
    usleep(kAdoptionPollInterval);
  }

  kill(child, SIGKILL);
  waitpid(child, NULL, 0);
  NSLog(@"[sunshine] display helper %s timed out", flag);
  return NO;
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
  return [self runHelper:"--vd-make-primary"];
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

    CGDisplayConfigRef configuration = NULL;
    if (CGBeginDisplayConfiguration(&configuration) == kCGErrorSuccess && configuration) {
      CGError err = CGConfigureDisplayOrigin(configuration, display_id, 0, 0);
      fprintf(stderr, "[vd-helper] origin target: %d\n", err);

      int32_t next_x = (int32_t) CGDisplayBounds(display_id).size.width;
      for (uint32_t i = 0; i < count; ++i) {
        if (ids[i] == display_id) {
          continue;
        }
        err = CGConfigureDisplayOrigin(configuration, ids[i], next_x, 0);
        fprintf(stderr, "[vd-helper] origin %u -> %d: %d\n", ids[i], next_x, err);
        next_x += (int32_t) CGDisplayBounds(ids[i]).size.width;
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
      return 0;
    }

    usleep(100000);
  }

  return 1;
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
}

CGDirectDisplayID solari_virtual_display_acquire(int width, int height, double refreshRate, BOOL hiDPI) {
  if (width <= 0 || height <= 0) {
    return 0;
  }

  [g_shared_lock lock];

  // Reuse whatever is already there when the geometry matches, so a probe run
  // does not tear the desktop apart once per encoder.
  if (g_shared_display && g_shared_width == width && g_shared_height == height &&
      g_shared_refresh == refreshRate && g_shared_hidpi == hiDPI) {
    SolariVirtualDisplay *existing = g_shared_display;
    [g_shared_lock unlock];

    // Selecting the HiDPI mode right after creation can fail while the window
    // server is still adopting the display. Callers come back through here
    // repeatedly, so keep trying until it verifies, then stop for good: the
    // helper is a process spawn, and reapplying a display mode mid-stream is
    // a visible glitch.
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
  g_shared_display = nil;
  g_shared_width = g_shared_height = 0;
  g_shared_refresh = 0;
  [g_shared_lock unlock];
}

CGDirectDisplayID solari_virtual_display_current(void) {
  [g_shared_lock lock];
  const CGDirectDisplayID displayID = g_shared_display ? g_shared_display.displayID : 0;
  [g_shared_lock unlock];
  return displayID;
}
