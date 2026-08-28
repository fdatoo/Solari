/**
 * @file src/platform/macos/input.cpp
 * @brief Native CoreGraphics input backend for macOS.
 *
 * Replaces the libvirtualhid shim on Apple. Solari owns this path because the
 * shared backend has two defects that matter during gameplay:
 *
 *   Held modifiers oscillate. The common input layer brackets a key with a
 *   synthetic modifier press and release (src/input.cpp:989) and repeats that
 *   whole sequence about 25 times a second (src/input.cpp:1026). Because
 *   VKEY_SHIFT and VKEY_LSHIFT both resolve to kVK_Shift, a synthetic release
 *   used to clear the very bit a physically held Shift had set. Held state is
 *   tracked per portable key code here, so the synthetic modifier and the key
 *   the player is actually holding no longer share one bit of state.
 *
 *   Note that state must not be a press count. The same repeat path re-sends a
 *   bare press for a held key with no matching release, so a counter would climb
 *   without ever returning to zero and the modifier would stick down for good.
 *
 *   Relative motion stutters. The shared backend warps the cursor after every
 *   move, which arms the WindowServer's local event suppression window and can
 *   stall injected events for up to a quarter second. Relative motion here
 *   advances a cursor position this backend owns and never warps. Only an
 *   absolute reposition warps, and the suppression interval is set to zero so
 *   even that cannot stall the events behind it.
 *
 * Absolute positions are also kept in double precision. The shared path rounds
 * them to whole pixels (virtualhid_input.cpp lround), discarding the sub-pixel
 * precision the protocol carries.
 */

// platform includes
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>

// standard includes
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <utility>
#include <vector>

// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/virtualhid_input.h"

namespace platf {

  namespace {

    constexpr auto multi_click_delay = std::chrono::milliseconds {500};
    constexpr int wheel_delta = 120;  ///< Windows-style high-resolution wheel delta.
    constexpr double default_scrollwheel_scaling = 0.3125;  ///< Default macOS scroll speed slider position.
    constexpr int default_scroll_lines_per_detent = 5;  ///< Lines represented by one default wheel detent.

    /**
     * @brief One entry of the portable key code to macOS virtual key code map.
     */
    struct key_code_map_t {
      int portable_key_code;  ///< Windows-style virtual key code from the client.
      int macos_key_code;  ///< macOS virtual key code, or -1 when unmapped.
    };

    /**
     * @brief Build the portable key code to macOS virtual key code map.
     *
     * Ported unchanged from the shared backend, which is the proven mapping.
     *
     * @return Sorted portable key code map.
     */
    constexpr std::array<key_code_map_t, 167> make_key_code_map() {
      std::array<key_code_map_t, 167> result {};
      result[0] = {0x08 /* VKEY_BACK */, kVK_Delete};
      result[1] = {0x09 /* VKEY_TAB */, kVK_Tab};
      result[2] = {0x0A /* VKEY_BACKTAB */, 0x21E4};
      result[3] = {0x0C /* VKEY_CLEAR */, kVK_ANSI_KeypadClear};
      result[4] = {0x0D /* VKEY_RETURN */, kVK_Return};
      result[5] = {0x10 /* VKEY_SHIFT */, kVK_Shift};
      result[6] = {0x11 /* VKEY_CONTROL */, kVK_Control};
      result[7] = {0x12 /* VKEY_MENU */, kVK_Option};
      result[8] = {0x13 /* VKEY_PAUSE */, -1};
      result[9] = {0x14 /* VKEY_CAPITAL */, kVK_CapsLock};
      result[10] = {0x15 /* VKEY_KANA */, kVK_JIS_Kana};
      result[11] = {0x15 /* VKEY_HANGUL */, -1};
      result[12] = {0x17 /* VKEY_JUNJA */, -1};
      result[13] = {0x18 /* VKEY_FINAL */, -1};
      result[14] = {0x19 /* VKEY_HANJA */, -1};
      result[15] = {0x19 /* VKEY_KANJI */, -1};
      result[16] = {0x1B /* VKEY_ESCAPE */, kVK_Escape};
      result[17] = {0x1C /* VKEY_CONVERT */, -1};
      result[18] = {0x1D /* VKEY_NONCONVERT */, -1};
      result[19] = {0x1E /* VKEY_ACCEPT */, -1};
      result[20] = {0x1F /* VKEY_MODECHANGE */, -1};
      result[21] = {0x20 /* VKEY_SPACE */, kVK_Space};
      result[22] = {0x21 /* VKEY_PRIOR */, kVK_PageUp};
      result[23] = {0x22 /* VKEY_NEXT */, kVK_PageDown};
      result[24] = {0x23 /* VKEY_END */, kVK_End};
      result[25] = {0x24 /* VKEY_HOME */, kVK_Home};
      result[26] = {0x25 /* VKEY_LEFT */, kVK_LeftArrow};
      result[27] = {0x26 /* VKEY_UP */, kVK_UpArrow};
      result[28] = {0x27 /* VKEY_RIGHT */, kVK_RightArrow};
      result[29] = {0x28 /* VKEY_DOWN */, kVK_DownArrow};
      result[30] = {0x29 /* VKEY_SELECT */, -1};
      result[31] = {0x2A /* VKEY_PRINT */, -1};
      result[32] = {0x2B /* VKEY_EXECUTE */, -1};
      result[33] = {0x2C /* VKEY_SNAPSHOT */, -1};
      result[34] = {0x2D /* VKEY_INSERT */, kVK_Help};
      result[35] = {0x2E /* VKEY_DELETE */, kVK_ForwardDelete};
      result[36] = {0x2F /* VKEY_HELP */, kVK_Help};
      result[37] = {0x30 /* VKEY_0 */, kVK_ANSI_0};
      result[38] = {0x31 /* VKEY_1 */, kVK_ANSI_1};
      result[39] = {0x32 /* VKEY_2 */, kVK_ANSI_2};
      result[40] = {0x33 /* VKEY_3 */, kVK_ANSI_3};
      result[41] = {0x34 /* VKEY_4 */, kVK_ANSI_4};
      result[42] = {0x35 /* VKEY_5 */, kVK_ANSI_5};
      result[43] = {0x36 /* VKEY_6 */, kVK_ANSI_6};
      result[44] = {0x37 /* VKEY_7 */, kVK_ANSI_7};
      result[45] = {0x38 /* VKEY_8 */, kVK_ANSI_8};
      result[46] = {0x39 /* VKEY_9 */, kVK_ANSI_9};
      result[47] = {0x41 /* VKEY_A */, kVK_ANSI_A};
      result[48] = {0x42 /* VKEY_B */, kVK_ANSI_B};
      result[49] = {0x43 /* VKEY_C */, kVK_ANSI_C};
      result[50] = {0x44 /* VKEY_D */, kVK_ANSI_D};
      result[51] = {0x45 /* VKEY_E */, kVK_ANSI_E};
      result[52] = {0x46 /* VKEY_F */, kVK_ANSI_F};
      result[53] = {0x47 /* VKEY_G */, kVK_ANSI_G};
      result[54] = {0x48 /* VKEY_H */, kVK_ANSI_H};
      result[55] = {0x49 /* VKEY_I */, kVK_ANSI_I};
      result[56] = {0x4A /* VKEY_J */, kVK_ANSI_J};
      result[57] = {0x4B /* VKEY_K */, kVK_ANSI_K};
      result[58] = {0x4C /* VKEY_L */, kVK_ANSI_L};
      result[59] = {0x4D /* VKEY_M */, kVK_ANSI_M};
      result[60] = {0x4E /* VKEY_N */, kVK_ANSI_N};
      result[61] = {0x4F /* VKEY_O */, kVK_ANSI_O};
      result[62] = {0x50 /* VKEY_P */, kVK_ANSI_P};
      result[63] = {0x51 /* VKEY_Q */, kVK_ANSI_Q};
      result[64] = {0x52 /* VKEY_R */, kVK_ANSI_R};
      result[65] = {0x53 /* VKEY_S */, kVK_ANSI_S};
      result[66] = {0x54 /* VKEY_T */, kVK_ANSI_T};
      result[67] = {0x55 /* VKEY_U */, kVK_ANSI_U};
      result[68] = {0x56 /* VKEY_V */, kVK_ANSI_V};
      result[69] = {0x57 /* VKEY_W */, kVK_ANSI_W};
      result[70] = {0x58 /* VKEY_X */, kVK_ANSI_X};
      result[71] = {0x59 /* VKEY_Y */, kVK_ANSI_Y};
      result[72] = {0x5A /* VKEY_Z */, kVK_ANSI_Z};
      result[73] = {0x5B /* VKEY_LWIN */, kVK_Command};
      result[74] = {0x5C /* VKEY_RWIN */, kVK_RightCommand};
      result[75] = {0x5D /* VKEY_APPS */, kVK_RightCommand};
      result[76] = {0x5F /* VKEY_SLEEP */, -1};
      result[77] = {0x60 /* VKEY_NUMPAD0 */, kVK_ANSI_Keypad0};
      result[78] = {0x61 /* VKEY_NUMPAD1 */, kVK_ANSI_Keypad1};
      result[79] = {0x62 /* VKEY_NUMPAD2 */, kVK_ANSI_Keypad2};
      result[80] = {0x63 /* VKEY_NUMPAD3 */, kVK_ANSI_Keypad3};
      result[81] = {0x64 /* VKEY_NUMPAD4 */, kVK_ANSI_Keypad4};
      result[82] = {0x65 /* VKEY_NUMPAD5 */, kVK_ANSI_Keypad5};
      result[83] = {0x66 /* VKEY_NUMPAD6 */, kVK_ANSI_Keypad6};
      result[84] = {0x67 /* VKEY_NUMPAD7 */, kVK_ANSI_Keypad7};
      result[85] = {0x68 /* VKEY_NUMPAD8 */, kVK_ANSI_Keypad8};
      result[86] = {0x69 /* VKEY_NUMPAD9 */, kVK_ANSI_Keypad9};
      result[87] = {0x6A /* VKEY_MULTIPLY */, kVK_ANSI_KeypadMultiply};
      result[88] = {0x6B /* VKEY_ADD */, kVK_ANSI_KeypadPlus};
      result[89] = {0x6C /* VKEY_SEPARATOR */, -1};
      result[90] = {0x6D /* VKEY_SUBTRACT */, kVK_ANSI_KeypadMinus};
      result[91] = {0x6E /* VKEY_DECIMAL */, kVK_ANSI_KeypadDecimal};
      result[92] = {0x6F /* VKEY_DIVIDE */, kVK_ANSI_KeypadDivide};
      result[93] = {0x70 /* VKEY_F1 */, kVK_F1};
      result[94] = {0x71 /* VKEY_F2 */, kVK_F2};
      result[95] = {0x72 /* VKEY_F3 */, kVK_F3};
      result[96] = {0x73 /* VKEY_F4 */, kVK_F4};
      result[97] = {0x74 /* VKEY_F5 */, kVK_F5};
      result[98] = {0x75 /* VKEY_F6 */, kVK_F6};
      result[99] = {0x76 /* VKEY_F7 */, kVK_F7};
      result[100] = {0x77 /* VKEY_F8 */, kVK_F8};
      result[101] = {0x78 /* VKEY_F9 */, kVK_F9};
      result[102] = {0x79 /* VKEY_F10 */, kVK_F10};
      result[103] = {0x7A /* VKEY_F11 */, kVK_F11};
      result[104] = {0x7B /* VKEY_F12 */, kVK_F12};
      result[105] = {0x7C /* VKEY_F13 */, kVK_F13};
      result[106] = {0x7D /* VKEY_F14 */, kVK_F14};
      result[107] = {0x7E /* VKEY_F15 */, kVK_F15};
      result[108] = {0x7F /* VKEY_F16 */, kVK_F16};
      result[109] = {0x80 /* VKEY_F17 */, kVK_F17};
      result[110] = {0x81 /* VKEY_F18 */, kVK_F18};
      result[111] = {0x82 /* VKEY_F19 */, kVK_F19};
      result[112] = {0x83 /* VKEY_F20 */, kVK_F20};
      result[113] = {0x84 /* VKEY_F21 */, -1};
      result[114] = {0x85 /* VKEY_F22 */, -1};
      result[115] = {0x86 /* VKEY_F23 */, -1};
      result[116] = {0x87 /* VKEY_F24 */, -1};
      result[117] = {0x90 /* VKEY_NUMLOCK */, -1};
      result[118] = {0x91 /* VKEY_SCROLL */, -1};
      result[119] = {0xA0 /* VKEY_LSHIFT */, kVK_Shift};
      result[120] = {0xA1 /* VKEY_RSHIFT */, kVK_RightShift};
      result[121] = {0xA2 /* VKEY_LCONTROL */, kVK_Control};
      result[122] = {0xA3 /* VKEY_RCONTROL */, kVK_RightControl};
      result[123] = {0xA4 /* VKEY_LMENU */, kVK_Option};
      result[124] = {0xA5 /* VKEY_RMENU */, kVK_RightOption};
      result[125] = {0xA6 /* VKEY_BROWSER_BACK */, -1};
      result[126] = {0xA7 /* VKEY_BROWSER_FORWARD */, -1};
      result[127] = {0xA8 /* VKEY_BROWSER_REFRESH */, -1};
      result[128] = {0xA9 /* VKEY_BROWSER_STOP */, -1};
      result[129] = {0xAA /* VKEY_BROWSER_SEARCH */, -1};
      result[130] = {0xAB /* VKEY_BROWSER_FAVORITES */, -1};
      result[131] = {0xAC /* VKEY_BROWSER_HOME */, -1};
      result[132] = {0xAD /* VKEY_VOLUME_MUTE */, -1};
      result[133] = {0xAE /* VKEY_VOLUME_DOWN */, -1};
      result[134] = {0xAF /* VKEY_VOLUME_UP */, -1};
      result[135] = {0xB0 /* VKEY_MEDIA_NEXT_TRACK */, -1};
      result[136] = {0xB1 /* VKEY_MEDIA_PREV_TRACK */, -1};
      result[137] = {0xB2 /* VKEY_MEDIA_STOP */, -1};
      result[138] = {0xB3 /* VKEY_MEDIA_PLAY_PAUSE */, -1};
      result[139] = {0xB4 /* VKEY_MEDIA_LAUNCH_MAIL */, -1};
      result[140] = {0xB5 /* VKEY_MEDIA_LAUNCH_MEDIA_SELECT */, -1};
      result[141] = {0xB6 /* VKEY_MEDIA_LAUNCH_APP1 */, -1};
      result[142] = {0xB7 /* VKEY_MEDIA_LAUNCH_APP2 */, -1};
      result[143] = {0xBA /* VKEY_OEM_1 */, kVK_ANSI_Semicolon};
      result[144] = {0xBB /* VKEY_OEM_PLUS */, kVK_ANSI_Equal};
      result[145] = {0xBC /* VKEY_OEM_COMMA */, kVK_ANSI_Comma};
      result[146] = {0xBD /* VKEY_OEM_MINUS */, kVK_ANSI_Minus};
      result[147] = {0xBE /* VKEY_OEM_PERIOD */, kVK_ANSI_Period};
      result[148] = {0xBF /* VKEY_OEM_2 */, kVK_ANSI_Slash};
      result[149] = {0xC0 /* VKEY_OEM_3 */, kVK_ANSI_Grave};
      result[150] = {0xDB /* VKEY_OEM_4 */, kVK_ANSI_LeftBracket};
      result[151] = {0xDC /* VKEY_OEM_5 */, kVK_ANSI_Backslash};
      result[152] = {0xDD /* VKEY_OEM_6 */, kVK_ANSI_RightBracket};
      result[153] = {0xDE /* VKEY_OEM_7 */, kVK_ANSI_Quote};
      result[154] = {0xDF /* VKEY_OEM_8 */, -1};
      result[155] = {0xE2 /* VKEY_OEM_102 */, -1};
      result[156] = {0xE5 /* VKEY_PROCESSKEY */, -1};
      result[157] = {0xE7 /* VKEY_PACKET */, -1};
      result[158] = {0xF6 /* VKEY_ATTN */, -1};
      result[159] = {0xF7 /* VKEY_CRSEL */, -1};
      result[160] = {0xF8 /* VKEY_EXSEL */, -1};
      result[161] = {0xF9 /* VKEY_EREOF */, -1};
      result[162] = {0xFA /* VKEY_PLAY */, -1};
      result[163] = {0xFB /* VKEY_ZOOM */, -1};
      result[164] = {0xFC /* VKEY_NONAME */, -1};
      result[165] = {0xFD /* VKEY_PA1 */, -1};
      result[166] = {0xFE /* VKEY_OEM_CLEAR */, kVK_ANSI_KeypadClear};
      return result;
    }

    constexpr auto key_code_map = make_key_code_map();

    /**
     * @brief Translate a portable key code to its macOS virtual key code.
     *
     * @param key_code Windows-style virtual key code from the client.
     * @return macOS virtual key code, or empty when the key is unmapped.
     */
    std::optional<CGKeyCode> macos_key_code(uint16_t key_code) {
      const auto position = std::ranges::lower_bound(key_code_map, static_cast<int>(key_code), {}, &key_code_map_t::portable_key_code);
      if (position == key_code_map.end() || position->portable_key_code != key_code || position->macos_key_code < 0) {
        return std::nullopt;
      }

      return static_cast<CGKeyCode>(position->macos_key_code);
    }

    /**
     * @brief Identifies one modifier's generic flag and its left/right device bits.
     */
    struct modifier_flags_t {
      CGEventFlags generic {};  ///< Device independent flag a game reads.
      CGEventFlags device {};  ///< Left or right device specific bit.
    };

    /**
     * @brief Resolve a portable key code to its index in the key map.
     *
     * Held state is tracked per portable code rather than per macOS key, because
     * several portable codes collapse onto one macOS key. The generic VKEY_SHIFT is
     * what the common layer sends for a synthetic modifier (src/input.cpp:989),
     * while a real keyboard sends VKEY_LSHIFT; both resolve to kVK_Shift. Keeping
     * them apart is what stops a synthetic release from clearing a modifier the
     * player is physically holding.
     *
     * @param key_code Portable key code from the client.
     * @return Index into the key map, or -1 when the key is unmapped.
     */
    int key_index_for(uint16_t key_code) {
      const auto position = std::ranges::lower_bound(key_code_map, static_cast<int>(key_code), {}, &key_code_map_t::portable_key_code);
      if (position == key_code_map.end() || position->portable_key_code != key_code || position->macos_key_code < 0) {
        return -1;
      }

      return static_cast<int>(std::distance(key_code_map.begin(), position));
    }

    /**
     * @brief Resolve the modifier a macOS key code represents.
     *
     * @param key macOS virtual key code.
     * @param flags Populated with the modifier's masks when the key is a modifier.
     * @return True when the key is a modifier key.
     */
    bool modifier_flags_for_key(CGKeyCode key, modifier_flags_t &flags) {
      switch (key) {
        case kVK_Shift:
          flags = {kCGEventFlagMaskShift, NX_DEVICELSHIFTKEYMASK};
          return true;
        case kVK_RightShift:
          flags = {kCGEventFlagMaskShift, NX_DEVICERSHIFTKEYMASK};
          return true;
        case kVK_Control:
          flags = {kCGEventFlagMaskControl, NX_DEVICELCTLKEYMASK};
          return true;
        case kVK_RightControl:
          flags = {kCGEventFlagMaskControl, NX_DEVICERCTLKEYMASK};
          return true;
        case kVK_Option:
          flags = {kCGEventFlagMaskAlternate, NX_DEVICELALTKEYMASK};
          return true;
        case kVK_RightOption:
          flags = {kCGEventFlagMaskAlternate, NX_DEVICERALTKEYMASK};
          return true;
        case kVK_Command:
          flags = {kCGEventFlagMaskCommand, NX_DEVICELCMDKEYMASK};
          return true;
        case kVK_RightCommand:
          flags = {kCGEventFlagMaskCommand, NX_DEVICERCMDKEYMASK};
          return true;
        default:
          return false;
      }
    }

    /**
     * @brief Convert the scroll speed slider position to logical lines per detent.
     *
     * Same curve the shared backend uses, so scroll speed is unchanged.
     *
     * @param scale Scroll wheel scaling preference.
     * @return Lines represented by one wheel detent.
     */
    int lines_per_detent_for(double scale) {
      if (!std::isfinite(scale)) {
        scale = default_scrollwheel_scaling;
      }

      const auto scroll_scale = std::clamp(scale, 0.0, 1.0);
      constexpr double lines_per_scroll_scale = (default_scroll_lines_per_detent - 1.0) / default_scrollwheel_scaling;
      return std::max(1, static_cast<int>(std::ceil(1.0 + scroll_scale * lines_per_scroll_scale)));
    }

    /**
     * @brief Read the user's scroll speed preference as logical lines per detent.
     *
     * @return Lines scrolled by one wheel detent.
     */
    int read_scroll_lines_per_detent() {
      double scale = default_scrollwheel_scaling;

      const auto value = CFPreferencesCopyValue(
        CFSTR("com.apple.scrollwheel.scaling"),
        kCFPreferencesAnyApplication,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
      );
      if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
          CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberDoubleType, &scale);
        } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
          scale = CFStringGetDoubleValue(static_cast<CFStringRef>(value));
        }
        CFRelease(value);
      }

      return lines_per_detent_for(scale);
    }

    /**
     * @brief Shared CoreGraphics input state for the process.
     *
     * The event sources and the modifier press counts are process wide because
     * CoreGraphics injection is itself process wide. Every mutation is guarded so
     * the control stream thread and the task pool thread cannot interleave.
     */
    class macos_input_t {
    public:
      static macos_input_t &get() {
        static macos_input_t instance;
        return instance;
      }

      /**
       * @brief Post a keyboard event, maintaining reference counted modifier state.
       *
       * @param key_code Portable key code from the client.
       * @param release Whether this is a key release.
       */
      void keyboard(uint16_t key_code, bool release) {
        const auto key = macos_key_code(key_code);
        if (!key) {
          return;
        }

        std::lock_guard lock {mutex_};
        if (!keyboard_source_) {
          return;
        }

        const auto event = CGEventCreateKeyboardEvent(keyboard_source_, *key, !release);
        if (!event) {
          return;
        }

        CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, *key);

        modifier_flags_t modifier;
        const auto key_index = key_index_for(key_code);
        if (key_index >= 0 && modifier_flags_for_key(*key, modifier)) {
          apply_modifier(key_index, release);
          CGEventSetType(event, kCGEventFlagsChanged);
        } else {
          CGEventSetType(event, release ? kCGEventKeyUp : kCGEventKeyDown);
        }

        CGEventSetFlags(event, keyboard_flags_);
        CGEventPost(kCGSessionEventTap, event);
        CFRelease(event);
      }

      /**
       * @brief Type a UTF-8 string as a single keyboard event pair.
       *
       * @param utf8 UTF-8 encoded text.
       * @param size Length of the text in bytes.
       */
      void unicode(const char *utf8, int size) {
        if (!utf8 || size <= 0) {
          return;
        }

        std::lock_guard lock {mutex_};
        if (!keyboard_source_) {
          return;
        }

        const auto text = CFStringCreateWithBytes(
          kCFAllocatorDefault,
          reinterpret_cast<const UInt8 *>(utf8),
          size,
          kCFStringEncodingUTF8,
          false
        );
        if (!text) {
          return;
        }

        const auto length = CFStringGetLength(text);
        std::vector<UniChar> characters(static_cast<std::size_t>(length));
        CFStringGetCharacters(text, CFRangeMake(0, length), characters.data());
        CFRelease(text);
        if (characters.empty()) {
          return;
        }

        const auto key_down = CGEventCreateKeyboardEvent(keyboard_source_, 0, true);
        const auto key_up = CGEventCreateKeyboardEvent(keyboard_source_, 0, false);
        if (!key_down || !key_up) {
          if (key_down) {
            CFRelease(key_down);
          }
          if (key_up) {
            CFRelease(key_up);
          }
          return;
        }

        CGEventKeyboardSetUnicodeString(key_down, characters.size(), characters.data());
        CGEventKeyboardSetUnicodeString(key_up, characters.size(), characters.data());
        CGEventSetFlags(key_down, keyboard_flags_);
        CGEventSetFlags(key_up, keyboard_flags_);
        CGEventPost(kCGSessionEventTap, key_down);
        CGEventPost(kCGSessionEventTap, key_up);
        CFRelease(key_down);
        CFRelease(key_up);
      }

      /**
       * @brief Move the cursor by a relative delta without warping it.
       *
       * @param delta_x Horizontal delta in pixels.
       * @param delta_y Vertical delta in pixels.
       */
      void move_relative(int delta_x, int delta_y) {
        std::lock_guard lock {mutex_};
        sync_position_if_needed();

        const auto previous = position_;
        position_.x += static_cast<double>(delta_x);
        position_.y += static_cast<double>(delta_y);
        clamp_position();

        post_motion(previous, static_cast<double>(delta_x), static_cast<double>(delta_y));
      }

      /**
       * @brief Move the cursor to an absolute location within the touch port.
       *
       * @param touch_port Client's coordinate space.
       * @param x Horizontal coordinate in the client's space.
       * @param y Vertical coordinate in the client's space.
       */
      void move_absolute(const touch_port_t &touch_port, float x, float y) {
        std::lock_guard lock {mutex_};

        // Without this the first absolute move reports a delta measured from the
        // origin, which reads to a game's mouse-look as a full-screen flick.
        sync_position_if_needed();

        const auto bounds = CGDisplayBounds(display_);
        if (touch_port.width <= 0 || touch_port.height <= 0) {
          return;
        }

        const auto scale_x = bounds.size.width / static_cast<double>(touch_port.width);
        const auto scale_y = bounds.size.height / static_cast<double>(touch_port.height);

        const auto previous = position_;
        position_.x = bounds.origin.x + static_cast<double>(x) * scale_x;
        position_.y = bounds.origin.y + static_cast<double>(y) * scale_y;
        clamp_position();

        post_motion(previous, position_.x - previous.x, position_.y - previous.y);

        // An absolute jump is the one case where the cursor must be re-anchored.
        // The suppression interval is zero, so this cannot stall later events.
        CGWarpMouseCursorPosition(position_);
        position_known_ = true;
      }

      /**
       * @brief Press or release a mouse button.
       *
       * @param button Moonlight button identifier.
       * @param release Whether this is a button release.
       */
      void button(int button, bool release) {
        CGMouseButton cg_button {};
        CGEventType down_type {};
        CGEventType up_type {};
        int index = 0;

        switch (button) {
          case 1:
            cg_button = kCGMouseButtonLeft;
            down_type = kCGEventLeftMouseDown;
            up_type = kCGEventLeftMouseUp;
            index = 0;
            break;
          case 2:
            cg_button = kCGMouseButtonCenter;
            down_type = kCGEventOtherMouseDown;
            up_type = kCGEventOtherMouseUp;
            index = 1;
            break;
          case 3:
            cg_button = kCGMouseButtonRight;
            down_type = kCGEventRightMouseDown;
            up_type = kCGEventRightMouseUp;
            index = 2;
            break;
          default:
            BOOST_LOG(warning) << "Unsupported mouse button for macOS: "sv << button;
            return;
        }

        std::lock_guard lock {mutex_};
        sync_position_if_needed();

        button_down_[index] = !release;

        const auto now = std::chrono::steady_clock::now();
        const auto phase = release ? 1U : 0U;
        const auto click_count = now < last_button_event_[index][phase] + multi_click_delay ? 2 : 1;
        last_button_event_[index][phase] = now;

        post_event(release ? up_type : down_type, cg_button, 0.0, 0.0, click_count);
      }

      /**
       * @brief Post a scroll event.
       *
       * @param high_res_vertical High resolution vertical distance.
       * @param high_res_horizontal High resolution horizontal distance.
       */
      void scroll(int high_res_vertical, int high_res_horizontal) {
        std::lock_guard lock {mutex_};
        if (!source_) {
          return;
        }

        const auto source_pixels_per_line = CGEventSourceGetPixelsPerLine(source_);
        const auto pixels_per_line = source_pixels_per_line > 0 ? static_cast<int>(source_pixels_per_line + 0.5) : 10;

        const auto to_pixels = [&](int high_res) {
          const auto scaled = static_cast<std::int64_t>(high_res) *
                              std::max(1, pixels_per_line) *
                              std::max(1, scroll_lines_per_detent_);
          return static_cast<int32_t>(scaled / wheel_delta);
        };

        const auto vertical = to_pixels(high_res_vertical);
        const auto horizontal = to_pixels(high_res_horizontal);
        if (vertical == 0 && horizontal == 0) {
          return;
        }

        const auto event = CGEventCreateScrollWheelEvent(source_, kCGScrollEventUnitPixel, 2, vertical, horizontal);
        if (!event) {
          return;
        }

        CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);

        // Scrolling must carry the live modifier flags. Posting a bare scroll while
        // a modifier is held reads to the game as the modifier having been released.
        CGEventSetFlags(event, keyboard_flags_);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
      }

      /**
       * @brief Select the display that bounds cursor motion.
       *
       * @param display CoreGraphics display identifier.
       */
      void set_display(CGDirectDisplayID display) {
        std::lock_guard lock {mutex_};
        display_ = display;
        position_known_ = false;
      }

      /**
       * @brief Release every modifier this backend believes is held.
       *
       * Called when a session ends so a dropped key release cannot leave a
       * modifier stuck down for the local user.
       */
      void reset_modifiers() {
        std::lock_guard lock {mutex_};

        const auto anything_held = std::ranges::any_of(key_held_, [](bool held) {
          return held;
        });
        if (keyboard_flags_ == 0 && !anything_held) {
          return;
        }

        if (!keyboard_source_) {
          return;  // cannot announce the change, so keep state for a later attempt
        }

        const auto event = CGEventCreateKeyboardEvent(keyboard_source_, kVK_Shift, false);
        if (!event) {
          return;
        }

        // Clear only the bits this backend asserted. Caps lock and Fn belong to the
        // local user's keyboard, so announcing them as released would be a lie.
        const auto system_flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);

        CGEventSetType(event, kCGEventFlagsChanged);
        CGEventSetFlags(event, system_flags & ~keyboard_flags_);
        CGEventPost(kCGSessionEventTap, event);
        CFRelease(event);

        // Only forget the state once the release has actually been announced.
        key_held_.fill(false);
        keyboard_flags_ = 0;
      }

    private:
      macos_input_t() {
        source_ = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        keyboard_source_ = CGEventSourceCreate(kCGEventSourceStatePrivate);
        display_ = CGMainDisplayID();
        scroll_lines_per_detent_ = read_scroll_lines_per_detent();

        if (source_) {
          // Injected motion must never be gated by the cursor association delay
          // that a warp would otherwise impose.
          CGEventSourceSetLocalEventsSuppressionInterval(source_, 0.0);
        }
        if (keyboard_source_) {
          CGEventSourceSetLocalEventsSuppressionInterval(keyboard_source_, 0.0);
        }
      }

      ~macos_input_t() {
        if (source_) {
          CFRelease(source_);
        }
        if (keyboard_source_) {
          CFRelease(keyboard_source_);
        }
      }

      macos_input_t(const macos_input_t &) = delete;
      macos_input_t &operator=(const macos_input_t &) = delete;

      /**
       * @brief Record a modifier key's held state and rebuild the flag word.
       *
       * State is a boolean per portable key code, never a press count. The common
       * layer re-sends a bare press for a held key roughly 25 times a second
       * (src/input.cpp:1026) and sends only one release, so anything that counts
       * presses would never return to zero and the modifier would stick down.
       * Setting a boolean is idempotent, so repeats are harmless.
       *
       * Because the synthetic modifier arrives as VKEY_SHIFT while a real keyboard
       * sends VKEY_LSHIFT, the two occupy different slots and the synthetic release
       * cannot clear a modifier the player is still holding.
       *
       * @param slot Tracking slot for the portable key code.
       * @param release Whether this is a release.
       */
      void apply_modifier(int key_index, bool release) {
        key_held_[key_index] = !release;
        rebuild_modifier_flags();
      }

      /**
       * @brief Recompute the flag word from the set of held modifier keys.
       *
       * Derived from the key map rather than a hand written list, so a portable code
       * that maps to a modifier cannot be missed. Rebuilding the whole word each time
       * means the flags cannot drift out of step with the held keys, whatever order
       * events arrive in.
       */
      void rebuild_modifier_flags() {
        CGEventFlags flags = 0;

        for (std::size_t i = 0; i < key_code_map.size(); ++i) {
          if (!key_held_[i] || key_code_map[i].macos_key_code < 0) {
            continue;
          }

          modifier_flags_t modifier;
          if (modifier_flags_for_key(static_cast<CGKeyCode>(key_code_map[i].macos_key_code), modifier)) {
            flags |= modifier.generic | modifier.device;
          }
        }

        keyboard_flags_ = flags;
      }

      /**
       * @brief Adopt the system cursor position when this backend has not tracked it.
       */
      void sync_position_if_needed() {
        if (position_known_) {
          return;
        }

        const auto event = CGEventCreate(nullptr);
        if (event) {
          position_ = CGEventGetLocation(event);
          CFRelease(event);
        } else {
          position_ = CGDisplayBounds(display_).origin;
        }

        position_known_ = true;
      }

      void clamp_position() {
        const auto bounds = CGDisplayBounds(display_);

        // CGDisplayBounds yields an empty rect for a display that has gone away,
        // which would put std::clamp's bounds the wrong way round.
        if (bounds.size.width < 1.0 || bounds.size.height < 1.0) {
          return;
        }

        position_.x = std::clamp(position_.x, bounds.origin.x, bounds.origin.x + bounds.size.width - 1);
        position_.y = std::clamp(position_.y, bounds.origin.y, bounds.origin.y + bounds.size.height - 1);
      }

      /**
       * @brief Post a motion event carrying the requested deltas.
       *
       * @param previous Position before the move, used when a delta is not supplied.
       * @param delta_x Horizontal delta to report.
       * @param delta_y Vertical delta to report.
       */
      void post_motion(CGPoint previous, double delta_x, double delta_y) {
        auto type = kCGEventMouseMoved;
        auto button = kCGMouseButtonLeft;

        if (button_down_[0]) {
          type = kCGEventLeftMouseDragged;
        } else if (button_down_[2]) {
          type = kCGEventRightMouseDragged;
          button = kCGMouseButtonRight;
        } else if (button_down_[1]) {
          type = kCGEventOtherMouseDragged;
          button = kCGMouseButtonCenter;
        }

        static_cast<void>(previous);
        post_event(type, button, delta_x, delta_y, 0);
      }

      /**
       * @brief Create, configure, and post a mouse event at the tracked position.
       *
       * A fresh event is created per post. The shared backend reused one event
       * across threads, which is not safe once injection is not serialised.
       *
       * @param type CoreGraphics event type.
       * @param button Button the event refers to.
       * @param delta_x Horizontal delta to attach.
       * @param delta_y Vertical delta to attach.
       * @param click_count Click state for button events.
       */
      void post_event(CGEventType type, CGMouseButton button, double delta_x, double delta_y, int click_count) {
        if (!source_) {
          return;
        }

        const auto event = CGEventCreateMouseEvent(source_, type, position_, button);
        if (!event) {
          return;
        }

        CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, button);
        if (click_count > 0) {
          CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_count);
        }

        // Deltas are what a game's aim code integrates, so they are reported as
        // given rather than recomputed from the clamped position.
        CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, delta_x);
        CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, delta_y);
        CGEventSetFlags(event, keyboard_flags_);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
      }

      std::mutex mutex_;
      CGEventSourceRef source_ {};
      CGEventSourceRef keyboard_source_ {};
      CGDirectDisplayID display_ {};
      CGPoint position_ {};
      bool position_known_ = false;
      int scroll_lines_per_detent_ = default_scroll_lines_per_detent;
      CGEventFlags keyboard_flags_ {};
      std::array<bool, key_code_map.size()> key_held_ {};  ///< Held state per portable key code.
      std::array<bool, 3> button_down_ {};
      std::array<std::array<std::chrono::steady_clock::time_point, 2>, 3> last_button_event_ {};
    };

  }  // namespace

  std::optional<util::point_t> get_mouse_loc(input_t & /*input*/) {
    const auto event = CGEventCreate(nullptr);
    if (!event) {
      return std::nullopt;
    }

    const auto current = CGEventGetLocation(event);
    CFRelease(event);
    return util::point_t {current.x, current.y};
  }

  platform_caps::caps_t get_capabilities() {
    platform_caps::caps_t caps = 0;
    const auto runtime = virtualhid::create_runtime();
    if (!runtime) {
      return caps;
    }

    const auto &capabilities = runtime->capabilities();
    if (capabilities.supports_gamepad && virtualhid::configured_gamepad_supports_touchpad()) {
      caps |= platform_caps::controller_touch;
    }
    if (config::input.native_pen_touch && (capabilities.supports_touchscreen || capabilities.supports_pen_tablet)) {
      caps |= platform_caps::pen_touch;
    }

    return caps;
  }

  std::vector<supported_gamepad_t> &supported_gamepads(input_t *input) {
    static std::vector<supported_gamepad_t> gamepads;
    if (!input || !input->get()) {
      gamepads = virtualhid::static_supported_gamepads();
      return gamepads;
    }

    gamepads = virtualhid::supported_gamepads(virtualhid::get_input_context(*input).runtime.get());
    return gamepads;
  }

  void move_mouse(input_t & /*input*/, int deltaX, int deltaY) {
    macos_input_t::get().move_relative(deltaX, deltaY);
  }

  void abs_mouse(input_t & /*input*/, const touch_port_t &touch_port, float x, float y) {
    macos_input_t::get().move_absolute(touch_port, x, y);
  }

  void button_mouse(input_t & /*input*/, int button, bool release) {
    macos_input_t::get().button(button, release);
  }

  void scroll(input_t & /*input*/, int high_res_distance) {
    macos_input_t::get().scroll(high_res_distance, 0);
  }

  void hscroll(input_t & /*input*/, int high_res_distance) {
    macos_input_t::get().scroll(0, high_res_distance);
  }

  void keyboard_update(input_t & /*input*/, uint16_t modcode, bool release, uint8_t /*flags*/) {
    macos_input_t::get().keyboard(modcode, release);
  }

  void unicode(input_t & /*input*/, const char *utf8, int size) {
    macos_input_t::get().unicode(utf8, size);
  }

  /**
   * @brief Release any modifiers still held when a session ends.
   */
  void macos_input_reset_modifiers() {
    macos_input_t::get().reset_modifiers();
  }

}  // namespace platf
