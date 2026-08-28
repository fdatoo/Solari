/**
 * @file src/platform/macos/sc_video.h
 * @brief Declarations for ScreenCaptureKit display capture.
 *
 * Replaces the AVCaptureScreenInput path, which Apple deprecated in macOS 13.
 * Beyond being current, ScreenCaptureKit reports frame status, so a display with
 * no new content is delivered as idle rather than as a duplicate frame, and it
 * can change cursor visibility without restarting the stream.
 *
 * It does not cover every case. ScreenCaptureKit delivers only the pixel formats
 * listed by SCVideoSupportsPixelFormat, which excludes the 10-bit biplanar format
 * VideoToolbox's zero-copy path needs, so 10-bit capture still goes through
 * AVFoundation. See supports_pixel_format below.
 */
#pragma once

// platform includes
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

/**
 * @brief Why a capture session ended.
 */
typedef NS_ENUM(NSInteger, SCVideoStopReason) {
  SCVideoStopReasonNone,  ///< Still running.
  SCVideoStopReasonConsumer,  ///< The consumer asked to stop.
  SCVideoStopReasonStream  ///< The stream ended on its own, so capture should be rebuilt.
};

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
 *
 * One instance drives at most one capture session at a time.
 */
@interface SCVideo: NSObject

@property(nonatomic, assign) CGDirectDisplayID displayID;  ///< Display being captured.
@property(nonatomic, assign) OSType pixelFormat;  ///< CoreVideo pixel format requested of the stream.
@property(nonatomic, assign) int frameWidth;  ///< Output width in pixels.
@property(nonatomic, assign) int frameHeight;  ///< Output height in pixels.
@property(nonatomic, assign) int frameRate;  ///< Requested frames per second.

/**
 * @brief Whether ScreenCaptureKit is usable on this system.
 *
 * @return True on macOS 12.3 and later.
 */
+ (BOOL)isSupported;

/**
 * @brief Whether ScreenCaptureKit can deliver a pixel format.
 *
 * The framework accepts only BGRA, l10r, 420v, 420f, xf44 and RGhA. Notably it
 * cannot deliver kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, which is what
 * the VideoToolbox zero-copy path uses for 10-bit.
 *
 * @param pixelFormat CoreVideo pixel format.
 * @return True when a stream can be configured for it.
 */
+ (BOOL)supportsPixelFormat:(OSType)pixelFormat;

/**
 * @brief Whether a display can present extended dynamic range content.
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
 * @param pixelFormat Desired pixel format; must satisfy supportsPixelFormat.
 * @return Initialised source, or nil when the display cannot be captured.
 */
- (nullable instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                               frameRate:(int)frameRate
                             pixelFormat:(OSType)pixelFormat;

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
 * @brief Stop capturing and wait for the stream to finish.
 */
- (void)stopCapture;

/**
 * @brief Why the last session ended.
 *
 * @return Stop reason.
 */
- (SCVideoStopReason)stopReason;

@end

NS_ASSUME_NONNULL_END
