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

  CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
  NSMutableArray *modes = [NSMutableArray array];
  [modes addObject:[[modeClass alloc] initWithWidth:(uint32_t) width height:(uint32_t) height refreshRate:refreshRate]];

  // HiDPI needs the half size partner mode registered alongside the native one,
  // or the window server hands back a display at half the requested resolution.
  if (hiDPI && width >= 2 && height >= 2) {
    [modes addObject:[[modeClass alloc] initWithWidth:(uint32_t) (width / 2)
                                              height:(uint32_t) (height / 2)
                                         refreshRate:refreshRate]];
  }

  settings.modes = modes;
  settings.hiDPI = hiDPI ? 1 : 0;

  if (![display applySettings:settings]) {
    NSLog(@"[sunshine] could not apply virtual display settings");
    return nil;
  }

  instance.display = display;
  instance.displayID = [display displayID];
  instance.width = width;
  instance.height = height;

  // Adoption is not immediate, and capturing a display the window server has not
  // registered yet fails, so wait for it to show up rather than assuming.
  const NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + kAdoptionTimeout;
  while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
    if ([SolariVirtualDisplay isDisplayActive:instance.displayID]) {
      return instance;
    }
    usleep(kAdoptionPollInterval);
  }

  NSLog(@"[sunshine] virtual display %u was created but never became active", instance.displayID);
  return nil;
}

- (void)dealloc {
  // Releasing the CGVirtualDisplay is what removes it from the desktop.
  _display = nil;
}

@end

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
static NSLock *g_shared_lock = nil;

__attribute__((constructor)) static void solari_virtual_display_init(void) {
  g_shared_lock = [[NSLock alloc] init];
}

CGDirectDisplayID solari_virtual_display_acquire(int width, int height, double refreshRate) {
  if (width <= 0 || height <= 0) {
    return 0;
  }

  [g_shared_lock lock];

  // Reuse whatever is already there when the geometry matches, so a probe run
  // does not tear the desktop apart once per encoder.
  if (g_shared_display && g_shared_width == width && g_shared_height == height && g_shared_refresh == refreshRate) {
    const CGDirectDisplayID existing = g_shared_display.displayID;
    [g_shared_lock unlock];
    return existing;
  }

  g_shared_display = nil;

  SolariVirtualDisplay *created = [SolariVirtualDisplay displayWithWidth:width
                                                                 height:height
                                                            refreshRate:refreshRate
                                                                  hiDPI:NO];
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

  // After the display is gone, so the restore does not try to place a display
  // that no longer exists.
  solari_virtual_display_restore_arrangement();
}

CGDirectDisplayID solari_virtual_display_current(void) {
  [g_shared_lock lock];
  const CGDirectDisplayID displayID = g_shared_display ? g_shared_display.displayID : 0;
  [g_shared_lock unlock];
  return displayID;
}

#pragma mark - Primary display

/**
 * Saved arrangement, so the desktop can be put back the way the user had it.
 * CoreGraphics treats whichever display sits at the origin as the primary one, so
 * making the virtual display primary means moving everything else out of the way.
 */
typedef struct {
  CGDirectDisplayID displayID;
  CGPoint origin;
} solari_display_origin_t;

static solari_display_origin_t g_saved_origins[32];
static uint32_t g_saved_origin_count = 0;
static BOOL g_arrangement_changed = NO;

/**
 * @brief Record where every active display currently sits.
 */
static void solari_save_arrangement(void) {
  g_saved_origin_count = 0;

  uint32_t count = 0;
  CGDirectDisplayID ids[32];
  if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess) {
    return;
  }

  for (uint32_t i = 0; i < count && i < 32; ++i) {
    g_saved_origins[g_saved_origin_count].displayID = ids[i];
    g_saved_origins[g_saved_origin_count].origin = CGDisplayBounds(ids[i]).origin;
    g_saved_origin_count++;
  }
}

BOOL solari_virtual_display_make_primary(void) {
  [g_shared_lock lock];
  SolariVirtualDisplay *display = g_shared_display;
  [g_shared_lock unlock];

  if (!display) {
    return NO;
  }

  const CGDirectDisplayID target = display.displayID;
  if (CGDisplayIsMain(target)) {
    return YES;
  }

  solari_save_arrangement();
  if (g_saved_origin_count == 0) {
    return NO;
  }

  CGDisplayConfigRef configuration = NULL;
  if (CGBeginDisplayConfiguration(&configuration) != kCGErrorSuccess || !configuration) {
    return NO;
  }

  // Whatever sits at the origin is primary, so the virtual display goes there and
  // the others are pushed to the right of it, keeping their relative order.
  const CGRect target_bounds = CGDisplayBounds(target);
  CGConfigureDisplayOrigin(configuration, target, 0, 0);

  double next_x = target_bounds.size.width;
  for (uint32_t i = 0; i < g_saved_origin_count; ++i) {
    const CGDirectDisplayID other = g_saved_origins[i].displayID;
    if (other == target) {
      continue;
    }

    CGConfigureDisplayOrigin(configuration, other, (int32_t) next_x, 0);
    next_x += CGDisplayBounds(other).size.width;
  }

  if (CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession) != kCGErrorSuccess) {
    CGCancelDisplayConfiguration(configuration);
    return NO;
  }

  g_arrangement_changed = YES;
  return YES;
}

void solari_virtual_display_restore_arrangement(void) {
  if (!g_arrangement_changed || g_saved_origin_count == 0) {
    return;
  }

  g_arrangement_changed = NO;

  CGDisplayConfigRef configuration = NULL;
  if (CGBeginDisplayConfiguration(&configuration) != kCGErrorSuccess || !configuration) {
    return;
  }

  for (uint32_t i = 0; i < g_saved_origin_count; ++i) {
    // The virtual display is gone by now, so only real displays are restored.
    if (CGDisplayIsActive(g_saved_origins[i].displayID)) {
      CGConfigureDisplayOrigin(configuration,
                               g_saved_origins[i].displayID,
                               (int32_t) g_saved_origins[i].origin.x,
                               (int32_t) g_saved_origins[i].origin.y);
    }
  }

  if (CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession) != kCGErrorSuccess) {
    CGCancelDisplayConfiguration(configuration);
  }

  g_saved_origin_count = 0;
}
