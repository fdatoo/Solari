/**
 * @file src/platform/macos/virtual_display.h
 * @brief Declarations for on-demand virtual displays.
 *
 * Streaming a display whose resolution does not match the client means scaling
 * somewhere, and scaling is what makes a stream look soft. A virtual display
 * created at exactly the client's resolution removes the scaling entirely, which
 * is how macOS Screen Sharing stays crisp.
 *
 * This uses CoreGraphics' private virtual display interfaces. They are present
 * from macOS 12 through macOS 26, but nothing obliges Apple to keep them, so
 * every entry point degrades to "no virtual display" rather than failing.
 */
#pragma once

// platform includes
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * @brief A display that exists only for the duration of a stream.
 */
@interface SolariVirtualDisplay: NSObject

@property(nonatomic, readonly) CGDirectDisplayID displayID;  ///< Identifier of the created display.
@property(nonatomic, readonly) int width;  ///< Width in pixels.
@property(nonatomic, readonly) int height;  ///< Height in pixels.

/**
 * @brief Whether virtual displays can be created on this system.
 *
 * @return True when the private interfaces are present.
 */
+ (BOOL)isSupported;

/**
 * @brief Create a virtual display and wait for the window server to adopt it.
 *
 * @param width Width in pixels.
 * @param height Height in pixels.
 * @param refreshRate Refresh rate in Hz.
 * @param hiDPI Whether to register a HiDPI mode pair, doubling the rendered detail.
 * @return The display, or nil when one could not be created.
 */
+ (nullable instancetype)displayWithWidth:(int)width
                                   height:(int)height
                              refreshRate:(double)refreshRate
                                    hiDPI:(BOOL)hiDPI;

@end

NS_ASSUME_NONNULL_END
