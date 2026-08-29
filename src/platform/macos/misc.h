/**
 * @file src/platform/macos/misc.h
 * @brief Miscellaneous declarations for macOS platform.
 */
#pragma once

// standard includes
#include <vector>

// platform includes
#include <CoreGraphics/CoreGraphics.h>

namespace platf {
  /**
   * @brief Check whether macOS has granted screen-capture permission.
   *
   * @return True when Sunshine can capture the screen.
   */
  bool is_screen_capture_allowed();

  /**
   * @brief Check whether this process may inject keyboard and mouse events.
   *
   * @return True when Accessibility permission is granted.
   */
  bool is_accessibility_allowed();

  /**
   * @brief Report Accessibility permission and prompt for it when it is missing.
   *
   * Injected input fails silently without this permission, so it is checked at
   * startup rather than left to be discovered mid-session.
   */
  void check_accessibility_permission();

  /**
   * @brief Release every modifier the input backend still believes is held.
   *
   * Defined in src/platform/macos/input.cpp. Called when a session ends so a key
   * release lost with the client cannot leave a modifier stuck down locally.
   */
  void macos_input_reset_modifiers();

  /**
   * @brief Bound injected input to a particular display.
   *
   * Cursor motion is clamped to this display and absolute coordinates are mapped
   * onto it, so it must be the display actually being captured. Without this the
   * cursor cannot reach a virtual display at all.
   *
   * @param display CoreGraphics display identifier.
   */
  void macos_input_set_display(CGDirectDisplayID display);
}  // namespace platf

namespace dyn {
  typedef void (*apiproc)();

  /**
   * @brief Load persisted state from its backing store.
   *
   * @param handle Native library or object handle used by the operation.
   * @param funcs Function table populated from the loaded library.
   * @param strict Whether missing functions should be treated as an error.
   * @return 0 when all required symbols are loaded; nonzero when loading fails.
   */
  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict = true);
  /**
   * @brief Return the native handle owned by the wrapper.
   *
   * @param libs List of libraries to probe for the requested symbol.
   * @return Native dynamic-library handle, or nullptr when no library can be opened.
   */
  void *handle(const std::vector<const char *> &libs);

}  // namespace dyn
