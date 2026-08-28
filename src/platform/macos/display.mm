/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */

// standard includes
#include <charconv>
#include <cstring>
#include <chrono>
#include <optional>
#include <string_view>

// local includes
#include "src/config.h"
#include "src/display_device.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/nv12_zero_device.h"
#include "src/platform/macos/sc_video.h"
#include "src/platform/macos/virtual_display.h"

// Avoid conflict between AVFoundation and libavutil both defining AVMediaType
/**
 * @def AVMediaType
 * @brief Macro for AV media type.
 */
#define AVMediaType AVMediaType_FFmpeg
#include "src/video.h"
#undef AVMediaType

namespace platf {
  using namespace std::literals;

  namespace {
    std::optional<CGDirectDisplayID> parse_display_id(std::string_view display_name) {
      if (display_name.empty()) {
        return std::nullopt;
      }

      CGDirectDisplayID display_id {};
      const auto *const begin {display_name.data()};
      const auto *const end {display_name.data() + display_name.size()};
      const auto [ptr, ec] {std::from_chars(begin, end, display_id)};
      if (ec != std::errc {} || ptr != end) {
        return std::nullopt;
      }

      return display_id;
    }

    OSType videotoolbox_pixel_format(const video::config_t &config, bool hdr_display) {
      const auto colorspace {video::colorspace_from_client_config(config, hdr_display)};
      return colorspace.bit_depth == 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
  }  // namespace

  /**
   * @brief macOS display capture source and image buffers.
   */
  struct av_display_t: public display_t {
    AVVideo *av_capture {};  ///< AV capture.
    CGDirectDisplayID display_id {};  ///< Display ID.
    std::unique_ptr<display_device::DisplayPowerGuardInterface> display_power_guard;  ///< Display power guard.

    ~av_display_t() override {
      [av_capture release];
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);

        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out)) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }
        auto av_img = std::static_pointer_cast<av_img_t>(img_out);

        auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
          av_img->sample_buffer,
          av_img->pixel_buffer,
          img_out->data
        );

        av_img->sample_buffer = new_sample_buffer;
        av_img->pixel_buffer = new_pixel_buffer;
        img_out->data = new_pixel_buffer->data();

        img_out->width = (int) CVPixelBufferGetWidth(new_pixel_buffer->buf);
        img_out->height = (int) CVPixelBufferGetHeight(new_pixel_buffer->buf);
        img_out->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf);
        img_out->pixel_pitch = img_out->row_pitch / img_out->width;

        old_data_retainer = nullptr;

        if (!push_captured_image_cb(std::move(img_out), true)) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }

        return true;
      }];

      // FIXME: We should time out if an image isn't returned for a while
      dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

      return capture_e::ok;
    }

    /**
     * @brief Allocate an image buffer compatible with this display backend.
     *
     * @return Allocated img object, or null when unavailable.
     */
    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    /**
     * @brief Create AVCodec encode device.
     *
     * @param pix_fmt Sunshine pixel format to convert or allocate for.
     * @return Constructed AVCodec encode device object.
     */
    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        av_capture.pixelFormat = kCVPixelFormatType_32BGRA;

        return std::make_unique<avcodec_encode_device_t>();
      } else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        auto device = std::make_unique<nv12_zero_device>();

        device->init(static_cast<void *>(av_capture), pix_fmt, setResolution, setPixelFormat);

        return device;
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    /**
     * @brief Populate a fallback image when real capture data is unavailable.
     *
     * @param img Image or frame object to read from or populate.
     * @return Capture status reported to the streaming pipeline.
     */
    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        // If we don't have the screen capture permission, this function will hang
        // indefinitely without doing anything useful. Exit instead to avoid this.
        // A non-zero return value indicates failure to the calling function.
        return 1;
      }

      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);

        auto av_img = (av_img_t *) img;

        auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
          av_img->sample_buffer,
          av_img->pixel_buffer,
          img->data
        );

        av_img->sample_buffer = new_sample_buffer;
        av_img->pixel_buffer = new_pixel_buffer;
        img->data = new_pixel_buffer->data();

        img->width = (int) CVPixelBufferGetWidth(new_pixel_buffer->buf);
        img->height = (int) CVPixelBufferGetHeight(new_pixel_buffer->buf);
        img->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf);
        img->pixel_pitch = img->row_pitch / img->width;

        old_data_retainer = nullptr;

        // returning false here stops capture backend
        return false;
      }];

      dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

      return 0;
    }

    /**
     * A bridge from the pure C++ code of the hwdevice_t class to the pure Objective C code.
     *
     * display --> an opaque pointer to an object of this class
     * width --> the intended capture width
     * height --> the intended capture height
     * @param display Display object or identifier associated with the operation.
     * @param width Frame or display width in pixels.
     * @param height Frame or display height in pixels.
     */
    static void setResolution(void *display, int width, int height) {
      [static_cast<AVVideo *>(display) setFrameWidth:width frameHeight:height];
    }

    /**
     * @brief Set pixel format.
     *
     * @param display Display object or identifier associated with the operation.
     * @param pixelFormat Pixel format.
     */
    static void setPixelFormat(void *display, OSType pixelFormat) {
      static_cast<AVVideo *>(display).pixelFormat = pixelFormat;
    }
  };

  /**
   * @brief macOS display capture through ScreenCaptureKit.
   *
   * Preferred over av_display_t, which is built on AVCaptureScreenInput, deprecated
   * since macOS 13 and unable to express HDR capture at all.
   */
  struct sc_display_t: public display_t {
    SCVideo *sc_capture {};  ///< ScreenCaptureKit capture source.
    CGDirectDisplayID display_id {};  ///< Display ID.
    std::unique_ptr<display_device::DisplayPowerGuardInterface> display_power_guard;  ///< Display power guard.
    std::uint16_t peak_luminance {};  ///< Display peak luminance in nits.
    SolariVirtualDisplay *virtual_display {};  ///< Virtual display being captured, if any.

    ~sc_display_t() override {
      [sc_capture stopCapture];
      [sc_capture release];

      // Released after capture has stopped, since letting the display disappear
      // from under a running stream is what makes the window server unhappy.
      [virtual_display release];
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      __block bool shown_cursor = true;

      auto signal = [sc_capture capture:^(CMSampleBufferRef sampleBuffer) {
        // Read the flag every frame rather than caching it, and push the change to
        // the running stream instead of restarting it.
        if (cursor && *cursor != shown_cursor) {
          shown_cursor = *cursor;
          [sc_capture setShowsCursor:shown_cursor ? YES : NO];
        }

        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out)) {
          return false;
        }

        // A null buffer means the display had no new content. The consumer keeps
        // the image it already has, and is still given the chance to shut down.
        if (!sampleBuffer) {
          return push_captured_image_cb(std::move(img_out), false);
        }

        auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);
        auto av_img = std::static_pointer_cast<av_img_t>(img_out);

        auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
          av_img->sample_buffer,
          av_img->pixel_buffer,
          img_out->data
        );

        av_img->sample_buffer = new_sample_buffer;
        av_img->pixel_buffer = new_pixel_buffer;
        img_out->data = new_pixel_buffer->data();

        img_out->width = (int) CVPixelBufferGetWidth(new_pixel_buffer->buf);
        img_out->height = (int) CVPixelBufferGetHeight(new_pixel_buffer->buf);
        img_out->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf);
        img_out->pixel_pitch = img_out->width > 0 ? img_out->row_pitch / img_out->width : 0;

        // Latency reporting reads this, and the presentation timestamp is closer to
        // when the frame was composited than the time it reached this callback.
        const auto presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (CMTIME_IS_VALID(presentation)) {
          img_out->frame_timestamp = std::chrono::steady_clock::now();
        }

        old_data_retainer = nullptr;

        return push_captured_image_cb(std::move(img_out), true);
      }];

      if (!signal) {
        BOOST_LOG(error) << "Could not start ScreenCaptureKit capture."sv;
        return capture_e::error;
      }

      dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

      // Only a consumer-initiated stop is a clean finish. If the stream ended on
      // its own, from a resolution change or a display being unplugged, reporting
      // success would tear the session down instead of rebuilding capture.
      if ([sc_capture stopReason] == SCVideoStopReasonStream) {
        BOOST_LOG(info) << "ScreenCaptureKit stream ended on its own, reinitializing capture."sv;
        return capture_e::reinit;
      }

      return capture_e::ok;
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        sc_capture.pixelFormat = kCVPixelFormatType_32BGRA;
        return std::make_unique<avcodec_encode_device_t>();
      } else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        auto device = std::make_unique<nv12_zero_device>();
        device->init(static_cast<void *>(sc_capture), pix_fmt, setResolution, setPixelFormat);
        return device;
      }

      BOOST_LOG(error) << "Unsupported Pixel Format."sv;
      return nullptr;
    }

    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        return 1;
      }

      // Synthesised rather than captured. This runs on the encoder probe path
      // while the capture thread already owns the capture session, and a second
      // session on the same source would stop the first. A blank frame of the
      // right size and format is all the probe needs.
      auto av_img = (av_img_t *) img;

      const auto width = frameWidthForDummy();
      const auto height = frameHeightForDummy();
      if (width <= 0 || height <= 0) {
        return 1;
      }

      CVPixelBufferRef pixel_buffer {};
      NSDictionary *attributes = @{
        (__bridge NSString *) kCVPixelBufferIOSurfacePropertiesKey: @{},
      };

      const auto status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        (size_t) width,
        (size_t) height,
        sc_capture.pixelFormat,
        (__bridge CFDictionaryRef) attributes,
        &pixel_buffer
      );

      if (status != kCVReturnSuccess || !pixel_buffer) {
        BOOST_LOG(error) << "Could not allocate a dummy image buffer: "sv << status;
        return 1;
      }

      CVPixelBufferLockBaseAddress(pixel_buffer, 0);
      for (size_t plane = 0; plane < std::max<size_t>(1, CVPixelBufferGetPlaneCount(pixel_buffer)); ++plane) {
        auto *base = CVPixelBufferIsPlanar(pixel_buffer) ? CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane) : CVPixelBufferGetBaseAddress(pixel_buffer);
        const auto bytes = CVPixelBufferIsPlanar(pixel_buffer) ? CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane) * CVPixelBufferGetHeightOfPlane(pixel_buffer, plane) : CVPixelBufferGetBytesPerRow(pixel_buffer) * CVPixelBufferGetHeight(pixel_buffer);
        if (base && bytes > 0) {
          std::memset(base, 0, bytes);
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);

      av_img->sample_buffer = nullptr;
      av_img->pixel_buffer = std::make_shared<av_pixel_buf_t>(pixel_buffer);
      CVPixelBufferRelease(pixel_buffer);  // the wrapper holds its own reference now

      img->data = av_img->pixel_buffer->data();
      img->width = width;
      img->height = height;
      img->row_pitch = (int) CVPixelBufferGetBytesPerRow(av_img->pixel_buffer->buf);
      img->pixel_pitch = img->width > 0 ? img->row_pitch / img->width : 0;

      return 0;
    }

    /**
     * @brief Width to use for a synthesised frame.
     *
     * @return Width in pixels.
     */
    int frameWidthForDummy() const {
      return sc_capture.frameWidth > 0 ? sc_capture.frameWidth : width;
    }

    /**
     * @brief Height to use for a synthesised frame.
     *
     * @return Height in pixels.
     */
    int frameHeightForDummy() const {
      return sc_capture.frameHeight > 0 ? sc_capture.frameHeight : height;
    }

    bool is_hdr() override {
      // ScreenCaptureKit can capture HDR, but only into formats VideoToolbox's
      // zero-copy path cannot take, so HDR is not offered until a conversion
      // step exists. Claiming it here would tag standard range content as HDR.
      return false;
    }

    bool get_hdr_metadata(SS_HDR_METADATA &metadata) override {
      std::memset(&metadata, 0, sizeof(metadata));
      if (!is_hdr()) {
        return false;
      }

      // Rec. 2020 primaries, which is what the HDR capture presets produce.
      // Coordinates are normalised to 50,000 as the protocol requires.
      metadata.displayPrimaries[0].x = 35400;  // red
      metadata.displayPrimaries[0].y = 14600;
      metadata.displayPrimaries[1].x = 8500;  // green
      metadata.displayPrimaries[1].y = 39850;
      metadata.displayPrimaries[2].x = 6550;  // blue
      metadata.displayPrimaries[2].y = 2300;

      // D65 white point.
      metadata.whitePoint.x = 15635;
      metadata.whitePoint.y = 16450;

      metadata.maxDisplayLuminance = peak_luminance;
      metadata.minDisplayLuminance = 0;  // in ten-thousandths of a nit
      metadata.maxFullFrameLuminance = peak_luminance;

      return true;
    }

    /**
     * @brief Bridge from the encode device to the ObjC capture source.
     *
     * @param display Opaque pointer to the SCVideo source.
     * @param width Intended capture width.
     * @param height Intended capture height.
     */
    static void setResolution(void *display, int width, int height) {
      [static_cast<SCVideo *>(display) setFrameWidth:width frameHeight:height];
    }

    /**
     * @brief Set the capture pixel format.
     *
     * @param display Opaque pointer to the SCVideo source.
     * @param pixelFormat CoreVideo pixel format.
     */
    static void setPixelFormat(void *display, OSType pixelFormat) {
      static_cast<SCVideo *>(display).pixelFormat = pixelFormat;
    }
  };

  std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type, const std::string &display_name, const video::config_t &config) {
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
      return nullptr;
    }

    BOOST_LOG(debug) << "Waking display for capture selector ["sv << display_name << ']';
    if (!display_device::wake_display(display_name, 1s)) {
      BOOST_LOG(debug) << "Display wake attempt did not expose the requested display ["sv << display_name << ']';
    }

    // Default to main display
    auto display_id {CGMainDisplayID()};

    if (const auto configured_display_id {parse_display_id(display_name)}) {
      display_id = *configured_display_id;
    } else if (!display_name.empty()) {
      BOOST_LOG(warning) << "Configured display ["sv << display_name
                         << "] is not a valid macOS capture display id. Falling back to main display ["sv
                         << display_id << "]."sv;
    }

    // Print all displays available with their names and ids
    BOOST_LOG(debug) << "Detecting displays"sv;
    for (const auto &device : display_device::enumerate_devices()) {
      if (device.m_display_name.empty()) {
        continue;
      }

      BOOST_LOG(debug) << "Detected display: "sv << device.m_friendly_name
                       << " (id: "sv << device.m_display_name << ") connected: true"sv;
    }

    BOOST_LOG(info) << "Configuring selected display ("sv << display_id << ") to stream"sv;

    // A display created at exactly the client's resolution removes scaling from
    // the pipeline entirely, which is the only way to get a genuinely 1:1 image.
    SolariVirtualDisplay *virtual_display {};
    if (config::video.virtual_display == "enabled" && config.width > 0 && config.height > 0) {
      if (![SolariVirtualDisplay isSupported]) {
        BOOST_LOG(warning) << "Virtual displays are not available on this version of macOS."sv;
      } else {
        // Retained explicitly: this file is manual retain and release, and the
        // factory method hands back an autoreleased object, which would take the
        // display away at the next pool drain.
        virtual_display = [[SolariVirtualDisplay displayWithWidth:config.width
                                                           height:config.height
                                                      refreshRate:config.framerate
                                                            hiDPI:NO] retain];
        if (virtual_display) {
          display_id = virtual_display.displayID;
          BOOST_LOG(info) << "Created a virtual display ("sv << display_id << ") at "sv
                          << config.width << 'x' << config.height << " @ "sv << config.framerate << "Hz"sv;
        } else {
          BOOST_LOG(warning) << "Could not create a virtual display, capturing the physical one instead."sv;
        }
      }
    }

    // ScreenCaptureKit only delivers a fixed set of pixel formats, and the 10-bit
    // biplanar format the VideoToolbox zero-copy path uses is not among them. When
    // the client asks for 10 bits, capture has to stay on AVFoundation until a
    // conversion step exists.
    const auto wanted_pixel_format {videotoolbox_pixel_format(config, false)};
    const bool sck_format_supported {[SCVideo supportsPixelFormat:wanted_pixel_format] == YES};

    if (config.dynamicRange > 0) {
      const bool display_supports_hdr {[SCVideo displaySupportsHDR:display_id] == YES};
      BOOST_LOG(info) << "Client requested 10-bit output. Display ("sv << display_id << ") "sv
                      << (display_supports_hdr ? "reports extended dynamic range headroom."sv
                                               : "reports no extended dynamic range headroom, so its content is standard range."sv);
    }

    if ([SCVideo isSupported] && sck_format_supported) {
      auto display = std::make_shared<sc_display_t>();
      display->display_id = display_id;
      display->virtual_display = virtual_display;
      display->display_power_guard = display_device::keep_display_awake("Sunshine display capture");
      if (display->display_power_guard) {
        BOOST_LOG(debug) << "Keeping display awake for capture"sv;
      } else {
        BOOST_LOG(debug) << "Unable to create display sleep prevention assertion"sv;
      }

      display->sc_capture = [[SCVideo alloc] initWithDisplay:display_id
                                                  frameRate:config.framerate
                                                pixelFormat:wanted_pixel_format];

      if (display->sc_capture) {
        display->peak_luminance = [SCVideo displayPeakLuminance:display_id];

        display->width = display->sc_capture.frameWidth;
        display->height = display->sc_capture.frameHeight;
        display->env_width = display->width;
        display->env_height = display->height;

        const auto native {[display->sc_capture nativePixelSize]};

        if (hwdevice_type == platf::mem_type_e::videotoolbox) {
          [display->sc_capture setFrameWidth:config.width frameHeight:config.height];
        }

        BOOST_LOG(info) << "Using ScreenCaptureKit capture"sv;
        BOOST_LOG(info) << "Display native resolution is "sv << (int) native.width << 'x' << (int) native.height
                        << ", streaming at "sv << config.width << 'x' << config.height;

        if (config.width > 0 && native.width > config.width * 1.5) {
          BOOST_LOG(info) << "The client is asking for well under the display's native resolution. "sv
                          << "Streaming at "sv << (int) native.width << 'x' << (int) native.height
                          << " would avoid the downscale and look considerably sharper."sv;
        }
        return display;
      }

      BOOST_LOG(warning) << "ScreenCaptureKit setup failed, falling back to AVFoundation."sv;
    } else if ([SCVideo isSupported]) {
      BOOST_LOG(info) << "ScreenCaptureKit cannot deliver the requested pixel format, using AVFoundation."sv;
    }

    if (virtual_display) {
      // The fallback path has nowhere to keep it alive for the session.
      BOOST_LOG(warning) << "Falling back to AVFoundation, releasing the virtual display."sv;
      [virtual_display release];
      virtual_display = nullptr;
      display_id = CGMainDisplayID();
    }

    auto display = std::make_shared<av_display_t>();
    display->display_id = display_id;
    display->display_power_guard = display_device::keep_display_awake("Sunshine display capture");
    if (display->display_power_guard) {
      BOOST_LOG(debug) << "Keeping display awake for capture"sv;
    } else {
      BOOST_LOG(debug) << "Unable to create display sleep prevention assertion"sv;
    }

    display->av_capture = [[AVVideo alloc] initWithDisplay:display->display_id frameRate:config.framerate];

    if (!display->av_capture) {
      BOOST_LOG(error) << "Video setup failed."sv;
      return nullptr;
    }

    display->width = display->av_capture.frameWidth;
    display->height = display->av_capture.frameHeight;
    // We also need set env_width and env_height for absolute mouse coordinates
    display->env_width = display->width;
    display->env_height = display->height;

    if (hwdevice_type == platf::mem_type_e::videotoolbox) {
      const auto pixel_format {videotoolbox_pixel_format(config, false)};
      [display->av_capture setFrameWidth:config.width frameHeight:config.height];
      display->av_capture.pixelFormat = pixel_format;
    }

    BOOST_LOG(info) << "Using AVFoundation capture (SDR only)"sv;
    return display;
  }

  std::vector<std::string> display_names(mem_type_e hwdevice_type) {
    std::vector<std::string> display_names;
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      return display_names;
    }

    const auto devices {display_device::enumerate_devices()};
    display_names.reserve(devices.size());
    for (const auto &device : devices) {
      if (!device.m_display_name.empty()) {
        display_names.emplace_back(device.m_display_name);
      }
    }

    return display_names;
  }

  /**
   * @brief Report whether encoder backends should be probed again before streaming.
   *
   * @return Always `true` because macOS GPU changes are not tracked by this backend.
   */
  bool needs_encoder_reenumeration() {
    // We don't track GPU state, so we will always reenumerate. Fortunately, it is fast on macOS.
    return true;
  }
}  // namespace platf
