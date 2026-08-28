/**
 * @file src/platform/macos/sc_video.h
 * @brief Declarations for ScreenCaptureKit display capture.
 *
 * Replaces the AVCaptureScreenInput path, which Apple deprecated in macOS 13.
 * Beyond being current, ScreenCaptureKit is what gives us frame status, so an
 * unchanged display is reported as idle rather than silently delivering nothing,
 * and HDR capture, which AVFoundation screen input cannot express at all.
 */
#pragma once

// platform includes
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

/**
 * @brief Result of handing a sample buffer to the consumer.
 */
typedef enum {
  SCVideoFrameHandledContinue,  ///< Consumer accepted the frame.
  SCVideoFrameHandledStop  ///< Consumer asked to stop capturing.
} SCVideoFrameDisposition;

/**
 * @brief Called for each captured frame.
 *
 * @param sampleBuffer Frame contents, or NULL when the display had no new content.
 * @return False to stop capturing.
 */
typedef bool (^SCFrameCallbackBlock)(CMSampleBufferRef _Nullable sampleBuffer);

NS_ASSUME_NONNULL_BEGIN

/**
 * @brief ScreenCaptureKit frame source for one display.
 */
@interface SCVideo: NSObject

@property(nonatomic, assign) CGDirectDisplayID displayID;  ///< Display being captured.
@property(nonatomic, assign) OSType pixelFormat;  ///< CoreVideo pixel format requested of the stream.
@property(nonatomic, assign) int frameWidth;  ///< Output width in pixels.
@property(nonatomic, assign) int frameHeight;  ///< Output height in pixels.
@property(nonatomic, assign) int frameRate;  ///< Requested frames per second.
@property(nonatomic, assign) BOOL hdrRequested;  ///< Whether HDR capture was asked for.
@property(nonatomic, readonly) BOOL hdrActive;  ///< Whether HDR capture is actually configured.

/**
 * @brief Whether ScreenCaptureKit is usable on this system.
 *
 * @return True on macOS 12.3 and later.
 */
+ (BOOL)isSupported;

/**
 * @brief Whether a display can present extended dynamic range content.
 *
 * A display with no headroom renders everything in standard range, so capturing
 * it as HDR would produce HDR-tagged standard range content.
 *
 * @param displayID Display to inspect.
 * @return True when the display reports headroom above standard range.
 */
+ (BOOL)displaySupportsHDR:(CGDirectDisplayID)displayID;

/**
 * @brief Peak luminance a display can present, in nits.
 *
 * @param displayID Display to inspect.
 * @return Peak luminance, or 0 when it cannot be determined.
 */
+ (uint16_t)displayPeakLuminance:(CGDirectDisplayID)displayID;

/**
 * @brief Create a capture source for a display.
 *
 * @param displayID Display to capture.
 * @param frameRate Frames per second to request.
 * @param hdr Whether to request HDR capture.
 * @return Initialised source, or nil when the display cannot be captured.
 */
- (nullable instancetype)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate hdr:(BOOL)hdr;

/**
 * @brief Set the output frame size.
 *
 * @param frameWidth Width in pixels.
 * @param frameHeight Height in pixels.
 */
- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;

/**
 * @brief Show or hide the cursor in captured frames.
 *
 * Applied to the running stream, so it can change without restarting capture.
 *
 * @param showsCursor Whether the cursor should be composited in.
 */
- (void)setShowsCursor:(BOOL)showsCursor;

/**
 * @brief Start delivering frames to a callback.
 *
 * @param frameCallback Called for each frame; returning false stops capture.
 * @return Semaphore signalled once capture has stopped, or nil on failure.
 */
- (nullable dispatch_semaphore_t)capture:(SCFrameCallbackBlock)frameCallback;

/**
 * @brief Stop capturing and release stream resources.
 */
- (void)stopCapture;

@end

NS_ASSUME_NONNULL_END
