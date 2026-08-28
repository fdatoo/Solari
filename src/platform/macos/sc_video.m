/**
 * @file src/platform/macos/sc_video.m
 * @brief Definitions for ScreenCaptureKit display capture.
 *
 * Compiled with ARC. The rest of the macOS platform code is manual retain and
 * release, but ScreenCaptureKit's API is built around blocks and completion
 * handlers, where manual memory management is a reliable source of mistakes.
 */

// platform includes
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// local includes
#import "sc_video.h"

/// How long to wait for the window server to enumerate shareable content.
static const NSTimeInterval kShareableContentTimeout = 5.0;

/// Standard range reference white, used to turn EDR headroom into nits.
static const double kReferenceWhiteNits = 100.0;

@interface SCVideo () <SCStreamOutput, SCStreamDelegate>

@property(nonatomic, strong, nullable) SCStream *stream;
@property(nonatomic, strong, nullable) SCStreamConfiguration *configuration;
@property(nonatomic, strong, nullable) SCContentFilter *filter;
@property(nonatomic, strong, nullable) dispatch_queue_t sampleQueue;
@property(nonatomic, strong, nullable) dispatch_semaphore_t stopSignal;
@property(nonatomic, copy, nullable) SCFrameCallbackBlock frameCallback;
@property(nonatomic, assign) BOOL capturing;
@property(nonatomic, assign) BOOL hdrActive;

@end

@implementation SCVideo

+ (BOOL)isSupported {
  if (@available(macOS 12.3, *)) {
    return YES;
  }
  return NO;
}

/**
 * @brief Find the NSScreen backing a CoreGraphics display.
 *
 * @param displayID Display to look up.
 * @return Matching screen, or nil.
 */
+ (nullable NSScreen *)screenForDisplay:(CGDirectDisplayID)displayID {
  for (NSScreen *screen in [NSScreen screens]) {
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    if (number && (CGDirectDisplayID) number.unsignedIntValue == displayID) {
      return screen;
    }
  }
  return nil;
}

+ (BOOL)displaySupportsHDR:(CGDirectDisplayID)displayID {
  NSScreen *screen = [SCVideo screenForDisplay:displayID];
  if (!screen) {
    return NO;
  }

  // Potential headroom rather than current: the current value drops to 1.0 when
  // nothing on screen is asking for extended range, which would read as a display
  // that cannot do HDR at all.
  return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0;
}

+ (uint16_t)displayPeakLuminance:(CGDirectDisplayID)displayID {
  NSScreen *screen = [SCVideo screenForDisplay:displayID];
  if (!screen) {
    return 0;
  }

  const double headroom = screen.maximumPotentialExtendedDynamicRangeColorComponentValue;
  if (headroom <= 1.0) {
    return 0;
  }

  const double nits = headroom * kReferenceWhiteNits;
  return (uint16_t) fmin(nits, 65535.0);
}

/**
 * @brief Fetch the SCDisplay for a CoreGraphics display id.
 *
 * SCShareableContent is only available asynchronously, and callers here need a
 * display before they can build a stream, so this waits rather than restructuring
 * the whole capture path around a callback.
 *
 * @param displayID Display to find.
 * @return Matching SCDisplay, or nil when it cannot be found in time.
 */
+ (nullable SCDisplay *)shareableDisplay:(CGDirectDisplayID)displayID API_AVAILABLE(macos(12.3)) {
  __block SCShareableContent *content = nil;
  __block NSError *failure = nil;
  dispatch_semaphore_t ready = dispatch_semaphore_create(0);

  [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                            onScreenWindowsOnly:NO
                                              completionHandler:^(SCShareableContent *shareableContent, NSError *error) {
                                                content = shareableContent;
                                                failure = error;
                                                dispatch_semaphore_signal(ready);
                                              }];

  const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t) (kShareableContentTimeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(ready, deadline) != 0) {
    NSLog(@"[sunshine] timed out enumerating shareable content");
    return nil;
  }

  if (!content) {
    NSLog(@"[sunshine] could not enumerate shareable content: %@", failure);
    return nil;
  }

  for (SCDisplay *display in content.displays) {
    if (display.displayID == displayID) {
      return display;
    }
  }

  NSLog(@"[sunshine] display %u is not in the shareable content list", displayID);
  return nil;
}

- (nullable instancetype)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate hdr:(BOOL)hdr {
  self = [super init];
  if (!self) {
    return nil;
  }

  if (![SCVideo isSupported]) {
    return nil;
  }

  if (@available(macOS 12.3, *)) {
    _displayID = displayID;
    _frameRate = frameRate > 0 ? frameRate : 60;
    _pixelFormat = kCVPixelFormatType_32BGRA;
    _hdrRequested = hdr;

    SCDisplay *display = [SCVideo shareableDisplay:displayID];
    if (!display) {
      return nil;
    }

    // Native pixel dimensions, which the encoder may later scale down.
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    if (mode) {
      _frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
      _frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
      CGDisplayModeRelease(mode);
    } else {
      _frameWidth = (int) display.width;
      _frameHeight = (int) display.height;
    }

    _filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    _configuration = [self buildConfiguration];
    if (!_configuration) {
      return nil;
    }

    _sampleQueue = dispatch_queue_create("dev.lizardbyte.sunshine.capture", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));

    return self;
  }

  return nil;
}

/**
 * @brief Build a stream configuration for the current settings.
 *
 * @return Configuration, or nil when one cannot be created.
 */
- (nullable SCStreamConfiguration *)buildConfiguration API_AVAILABLE(macos(12.3)) {
  SCStreamConfiguration *configuration = nil;
  self.hdrActive = NO;

  if (self.hdrRequested) {
    if (@available(macOS 15.0, *)) {
      // The preset carries the pixel format, colour space and matrix that belong
      // together for HDR. Setting them piecemeal is how you get a stream that
      // reports success and hands back mismatched buffers.
      configuration = [SCStreamConfiguration streamConfigurationWithPreset:SCStreamConfigurationPresetCaptureHDRStreamCanonicalDisplay];
      if (configuration) {
        configuration.captureDynamicRange = SCCaptureDynamicRangeHDRCanonicalDisplay;
        self.hdrActive = YES;
      }
    }

    if (!self.hdrActive) {
      NSLog(@"[sunshine] HDR capture unavailable, falling back to standard range");
    }
  }

  if (!configuration) {
    configuration = [[SCStreamConfiguration alloc] init];
  }
  if (!configuration) {
    return nil;
  }

  configuration.width = (size_t) self.frameWidth;
  configuration.height = (size_t) self.frameHeight;
  configuration.minimumFrameInterval = CMTimeMake(1, self.frameRate);
  configuration.showsCursor = YES;

  // Deeper than the default so a brief stall in the encoder drops frames inside
  // ScreenCaptureKit rather than backing up into the window server.
  configuration.queueDepth = 8;
  configuration.scalesToFit = NO;

  // The preset already chose a format that matches the HDR colour space; only
  // override it for standard range capture.
  if (!self.hdrActive) {
    configuration.pixelFormat = self.pixelFormat;
  }

  if (@available(macOS 14.0, *)) {
    configuration.captureResolution = SCCaptureResolutionBest;
  }

  return configuration;
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  if (frameWidth <= 0 || frameHeight <= 0) {
    return;
  }
  if (frameWidth == _frameWidth && frameHeight == _frameHeight) {
    return;
  }

  _frameWidth = frameWidth;
  _frameHeight = frameHeight;
  [self applyConfiguration];
}

- (void)setPixelFormat:(OSType)pixelFormat {
  if (pixelFormat == _pixelFormat) {
    return;
  }

  _pixelFormat = pixelFormat;
  [self applyConfiguration];
}

- (void)setShowsCursor:(BOOL)showsCursor {
  if (@available(macOS 12.3, *)) {
    if (!self.configuration || self.configuration.showsCursor == showsCursor) {
      return;
    }

    self.configuration.showsCursor = showsCursor;
    [self applyConfiguration];
  }
}

/**
 * @brief Push the current configuration to a running stream.
 *
 * Rebuilds the configuration and updates in place. Updating avoids tearing the
 * stream down, which would drop frames and re-trigger the window server's
 * enumeration of shareable content.
 */
- (void)applyConfiguration {
  if (@available(macOS 12.3, *)) {
    const BOOL showsCursor = self.configuration ? self.configuration.showsCursor : YES;

    SCStreamConfiguration *configuration = [self buildConfiguration];
    if (!configuration) {
      return;
    }
    configuration.showsCursor = showsCursor;
    self.configuration = configuration;

    if (!self.stream || !self.capturing) {
      return;
    }

    [self.stream updateConfiguration:configuration
                   completionHandler:^(NSError *error) {
                     if (error) {
                       NSLog(@"[sunshine] could not update capture configuration: %@", error);
                     }
                   }];
  }
}

- (nullable dispatch_semaphore_t)capture:(SCFrameCallbackBlock)frameCallback {
  if (@available(macOS 12.3, *)) {
    if (!self.filter || !self.configuration) {
      return nil;
    }

    [self stopCapture];

    self.frameCallback = frameCallback;
    self.stopSignal = dispatch_semaphore_create(0);
    self.stream = [[SCStream alloc] initWithFilter:self.filter configuration:self.configuration delegate:self];
    if (!self.stream) {
      NSLog(@"[sunshine] could not create a capture stream");
      return nil;
    }

    NSError *error = nil;
    if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.sampleQueue error:&error]) {
      NSLog(@"[sunshine] could not add a capture output: %@", error);
      self.stream = nil;
      return nil;
    }

    self.capturing = YES;

    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block NSError *startError = nil;
    [self.stream startCaptureWithCompletionHandler:^(NSError *failure) {
      startError = failure;
      dispatch_semaphore_signal(started);
    }];

    const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t) (kShareableContentTimeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(started, deadline) != 0) {
      NSLog(@"[sunshine] timed out starting capture");
      [self stopCapture];
      return nil;
    }

    if (startError) {
      NSLog(@"[sunshine] could not start capture: %@", startError);
      [self stopCapture];
      return nil;
    }

    return self.stopSignal;
  }

  return nil;
}

- (void)stopCapture {
  if (@available(macOS 12.3, *)) {
    SCStream *stream = self.stream;
    if (!stream) {
      self.capturing = NO;
      return;
    }

    self.capturing = NO;
    self.stream = nil;

    [stream stopCaptureWithCompletionHandler:^(NSError *error) {
      if (error) {
        NSLog(@"[sunshine] error while stopping capture: %@", error);
      }
    }];

    [self signalStopped];
  }
}

/**
 * @brief Release anything blocked waiting for capture to finish.
 */
- (void)signalStopped {
  dispatch_semaphore_t signal = self.stopSignal;
  if (signal) {
    dispatch_semaphore_signal(signal);
  }
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type != SCStreamOutputTypeScreen || !self.capturing) {
    return;
  }

  SCFrameCallbackBlock callback = self.frameCallback;
  if (!callback) {
    return;
  }

  // A frame carries a status saying whether it holds new content. Handing an idle
  // frame to the consumer as though it were new would republish a stale image;
  // passing NULL lets the consumer keep its last frame and still notice shutdown.
  BOOL hasNewContent = CMSampleBufferIsValid(sampleBuffer) && CMSampleBufferGetImageBuffer(sampleBuffer) != NULL;

  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (attachments && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef attachment = CFArrayGetValueAtIndex(attachments, 0);
    CFNumberRef rawStatus = CFDictionaryGetValue(attachment, (__bridge CFStringRef) SCStreamFrameInfoStatus);
    if (rawStatus) {
      SCFrameStatus status = SCFrameStatusComplete;
      CFNumberGetValue(rawStatus, kCFNumberNSIntegerType, &status);

      if (status == SCFrameStatusStopped) {
        self.capturing = NO;
        [self signalStopped];
        return;
      }

      if (status != SCFrameStatusComplete && status != SCFrameStatusStarted) {
        hasNewContent = NO;
      }
    }
  }

  if (!callback(hasNewContent ? sampleBuffer : NULL)) {
    self.capturing = NO;
    [self signalStopped];
  }
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
  NSLog(@"[sunshine] capture stopped: %@", error);
  self.capturing = NO;
  [self signalStopped];
}

@end
