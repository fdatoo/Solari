/**
 * @file src/platform/macos/sc_video.m
 * @brief Definitions for ScreenCaptureKit display capture.
 *
 * Compiled with ARC. The rest of the macOS platform code is manual retain and
 * release, but ScreenCaptureKit's API is built around blocks and completion
 * handlers, where manual memory management is a reliable source of mistakes.
 *
 * Every mutation of the stream and its configuration is guarded. The encoder
 * thread resizes the output while the capture thread runs the session and the
 * sample queue toggles the cursor, so three threads touch this state.
 */

// platform includes
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// local includes
#import "sc_video.h"

/// How long to wait for the window server to answer a request.
static const NSTimeInterval kWindowServerTimeout = 5.0;

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
@property(nonatomic, assign) BOOL showsCursor;
@property(nonatomic, assign) SCVideoStopReason stopReasonValue;

@end

@implementation SCVideo

+ (BOOL)isSupported {
  if (@available(macOS 12.3, *)) {
    return YES;
  }
  return NO;
}

+ (BOOL)supportsPixelFormat:(OSType)pixelFormat {
  switch (pixelFormat) {
    case kCVPixelFormatType_32BGRA:  // 'BGRA'
    case kCVPixelFormatType_ARGB2101010LEPacked:  // 'l10r'
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  // '420v'
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  // '420f'
    case kCVPixelFormatType_64RGBAHalf:  // 'RGhA'
      return YES;
    default:
      return NO;
  }
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

  return (uint16_t) fmin(headroom * kReferenceWhiteNits, 65535.0);
}

/**
 * @brief Fetch the SCDisplay for a CoreGraphics display id.
 *
 * SCShareableContent is only available asynchronously, and a stream cannot be
 * built without it, so this waits rather than restructuring the capture path
 * around a callback. Called only from setup, never from a callback.
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

  const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t) (kWindowServerTimeout * NSEC_PER_SEC));
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

- (nullable instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                               frameRate:(int)frameRate
                             pixelFormat:(OSType)pixelFormat {
  self = [super init];
  if (!self) {
    return nil;
  }

  if (![SCVideo isSupported] || ![SCVideo supportsPixelFormat:pixelFormat]) {
    return nil;
  }

  if (@available(macOS 12.3, *)) {
    _displayID = displayID;
    _frameRate = frameRate > 0 ? frameRate : 60;
    _pixelFormat = pixelFormat;
    _showsCursor = YES;
    _stopReasonValue = SCVideoStopReasonNone;

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
    _configuration = [self buildConfigurationLocked];
    if (!_configuration) {
      return nil;
    }

    _sampleQueue = dispatch_queue_create(
      "dev.lizardbyte.sunshine.capture",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0)
    );

    return self;
  }

  return nil;
}

/**
 * @brief Build a stream configuration from the current settings.
 *
 * Callers must hold the lock, or be in init before the object is shared.
 *
 * @return Configuration, or nil when one cannot be created.
 */
- (nullable SCStreamConfiguration *)buildConfigurationLocked API_AVAILABLE(macos(12.3)) {
  SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
  if (!configuration) {
    return nil;
  }

  configuration.width = (size_t) self.frameWidth;
  configuration.height = (size_t) self.frameHeight;
  configuration.minimumFrameInterval = CMTimeMake(1, self.frameRate);
  configuration.pixelFormat = self.pixelFormat;
  configuration.showsCursor = self.showsCursor;

  // Deeper than the default so a brief stall in the encoder drops frames inside
  // ScreenCaptureKit rather than backing up into the window server.
  configuration.queueDepth = 8;

  // Scale rather than crop when the requested aspect ratio differs from the
  // display's, which it does whenever a client asks for a shape the panel is not.
  configuration.scalesToFit = YES;

  if (@available(macOS 14.0, *)) {
    // Composite from the full pixel resolution rather than the point resolution.
    // On a Retina display the two differ by the backing scale, and compositing at
    // point resolution renders text at 1x, which is what makes a downscaled
    // stream look soft rather than merely smaller.
    configuration.captureResolution = SCCaptureResolutionBest;
  }

  return configuration;
}

- (CGSize)nativePixelSize {
  if (@available(macOS 14.0, *)) {
    SCContentFilter *filter = self.filter;
    if (filter) {
      const CGRect rect = filter.contentRect;
      const float scale = filter.pointPixelScale;
      if (rect.size.width > 0 && rect.size.height > 0 && scale > 0) {
        return CGSizeMake(rect.size.width * scale, rect.size.height * scale);
      }
    }
  }

  return CGSizeMake(self.frameWidth, self.frameHeight);
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  if (frameWidth <= 0 || frameHeight <= 0) {
    return;
  }

  @synchronized(self) {
    if (frameWidth == _frameWidth && frameHeight == _frameHeight) {
      return;
    }

    _frameWidth = frameWidth;
    _frameHeight = frameHeight;
    [self applyConfigurationLocked];
  }
}

- (void)setPixelFormat:(OSType)pixelFormat {
  if (![SCVideo supportsPixelFormat:pixelFormat]) {
    NSLog(@"[sunshine] ScreenCaptureKit cannot deliver the requested pixel format, keeping the current one");
    return;
  }

  @synchronized(self) {
    if (pixelFormat == _pixelFormat) {
      return;
    }

    _pixelFormat = pixelFormat;
    [self applyConfigurationLocked];
  }
}

- (void)setShowsCursor:(BOOL)showsCursor {
  @synchronized(self) {
    if (_showsCursor == showsCursor) {
      return;
    }

    _showsCursor = showsCursor;
    [self applyConfigurationLocked];
  }
}

/**
 * @brief Push the current settings to a running stream.
 *
 * Callers must hold the lock. Updating in place avoids tearing the stream down,
 * which would drop frames and re-run the window server's content enumeration.
 */
- (void)applyConfigurationLocked {
  if (@available(macOS 12.3, *)) {
    SCStreamConfiguration *configuration = [self buildConfigurationLocked];
    if (!configuration) {
      return;
    }

    self.configuration = configuration;

    SCStream *stream = self.stream;
    if (!stream || !self.capturing) {
      return;
    }

    [stream updateConfiguration:configuration
              completionHandler:^(NSError *error) {
                if (error) {
                  NSLog(@"[sunshine] could not update capture configuration: %@", error);
                }
              }];
  }
}

- (nullable dispatch_semaphore_t)capture:(SCFrameCallbackBlock)frameCallback {
  if (@available(macOS 12.3, *)) {
    SCStream *stream = nil;
    dispatch_semaphore_t signal = nil;

    @synchronized(self) {
      if (self.capturing) {
        // One session at a time. Tearing down a live session here would strand
        // whoever is waiting on its semaphore.
        NSLog(@"[sunshine] capture is already running on this source");
        return nil;
      }

      if (!self.filter || !self.configuration) {
        return nil;
      }

      self.stopReasonValue = SCVideoStopReasonNone;
      self.frameCallback = frameCallback;
      self.stopSignal = dispatch_semaphore_create(0);

      stream = [[SCStream alloc] initWithFilter:self.filter configuration:self.configuration delegate:self];
      if (!stream) {
        NSLog(@"[sunshine] could not create a capture stream");
        self.frameCallback = nil;
        self.stopSignal = nil;
        return nil;
      }

      NSError *error = nil;
      if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.sampleQueue error:&error]) {
        NSLog(@"[sunshine] could not add a capture output: %@", error);
        self.frameCallback = nil;
        self.stopSignal = nil;
        return nil;
      }

      self.stream = stream;
      self.capturing = YES;
      signal = self.stopSignal;
    }

    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block NSError *startError = nil;
    [stream startCaptureWithCompletionHandler:^(NSError *failure) {
      startError = failure;
      dispatch_semaphore_signal(started);
    }];

    const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t) (kWindowServerTimeout * NSEC_PER_SEC));
    const BOOL timedOut = dispatch_semaphore_wait(started, deadline) != 0;

    if (timedOut || startError) {
      NSLog(@"[sunshine] could not start capture: %@", timedOut ? @"timed out" : startError);
      [self stopCapture];
      return nil;
    }

    return signal;
  }

  return nil;
}

- (void)stopCapture {
  if (@available(macOS 12.3, *)) {
    SCStream *stream = nil;

    @synchronized(self) {
      stream = self.stream;
      self.stream = nil;
      self.capturing = NO;
      self.frameCallback = nil;
    }

    if (stream) {
      // Wait for the stream to finish so no callback can run against state this
      // object is about to release.
      dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
      [stream stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) {
          NSLog(@"[sunshine] error while stopping capture: %@", error);
        }
        dispatch_semaphore_signal(stopped);
      }];

      const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t) (kWindowServerTimeout * NSEC_PER_SEC));
      if (dispatch_semaphore_wait(stopped, deadline) != 0) {
        NSLog(@"[sunshine] timed out stopping capture");
      }
    }

    [self signalStopped];
  }
}

- (SCVideoStopReason)stopReason {
  @synchronized(self) {
    return self.stopReasonValue;
  }
}

/**
 * @brief Release anything waiting for capture to finish.
 */
- (void)signalStopped {
  dispatch_semaphore_t signal = nil;
  @synchronized(self) {
    signal = self.stopSignal;
  }

  if (signal) {
    dispatch_semaphore_signal(signal);
  }
}

/**
 * @brief Record why capture ended, keeping the first reason recorded.
 *
 * @param reason Reason to record.
 */
- (void)recordStopReason:(SCVideoStopReason)reason {
  @synchronized(self) {
    if (self.stopReasonValue == SCVideoStopReasonNone) {
      self.stopReasonValue = reason;
    }
  }
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }

  SCFrameCallbackBlock callback = nil;
  @synchronized(self) {
    // A stopped stream can still have callbacks in flight, and its callback's
    // captures are no longer valid, so identity is checked rather than assumed.
    if (!self.capturing || stream != self.stream) {
      return;
    }
    callback = self.frameCallback;
  }

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
        [self recordStopReason:SCVideoStopReasonStream];
        @synchronized(self) {
          self.capturing = NO;
        }
        [self signalStopped];
        return;
      }

      if (status != SCFrameStatusComplete && status != SCFrameStatusStarted) {
        hasNewContent = NO;
      }
    }
  }

  if (!callback(hasNewContent ? sampleBuffer : NULL)) {
    [self recordStopReason:SCVideoStopReasonConsumer];

    // Drop the callback before signalling. Its C++ captures live only as long as
    // the capture call that installed it.
    @synchronized(self) {
      self.capturing = NO;
      self.frameCallback = nil;
    }
    [self signalStopped];
  }
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
  @synchronized(self) {
    if (stream != self.stream) {
      return;  // a stream we already replaced
    }
    self.capturing = NO;
  }

  NSLog(@"[sunshine] capture stopped unexpectedly: %@", error);
  [self recordStopReason:SCVideoStopReasonStream];
  [self signalStopped];
}

@end
