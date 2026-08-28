/**
 * @file tools/modifier_oscillation_repro.cpp
 * @brief Deterministic reproducer for the held-modifier oscillation defect.
 *
 * A held Shift is reported to games as repeatedly released and re-pressed. This
 * reproduces the defect in isolation by replaying the exact call sequence the
 * common input layer produces against a faithful copy of the macOS backend's
 * modifier accumulator. No events are injected, so running it cannot disturb the
 * live session.
 *
 * The two pieces that combine to cause it:
 *
 *   src/input.cpp:989 send_key_and_modifiers()
 *     Presses a synthetic modifier, sends the key, then releases the synthetic
 *     modifier again. Correct for typing a capital letter, wrong for a modifier
 *     the user is physically holding.
 *
 *   src/input.cpp:1026 repeat_key()
 *     Re-runs that whole sequence every key_repeat_period (1/24.9 s by default,
 *     src/config.cpp:847), reusing the synthetic_modifiers captured at press time.
 *
 * The backend cannot tell the two Shifts apart: VKEY_SHIFT (0x10) and
 * VKEY_LSHIFT (0xA0) both map to kVK_Shift, so both resolve to the same
 * NX_DEVICELSHIFTKEYMASK bit, and the accumulator holds no press count.
 * (libvirtualhid macos_backend.cpp:54, :168, :259, :483-490.)
 *
 * Build:
 *   clang++ -std=c++20 -O2 -Wall -Wextra -o build/modifier_oscillation_repro \
 *       tools/modifier_oscillation_repro.cpp
 */

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {

  /* Subset of the CoreGraphics and IOKit constants the accumulator touches. */
  constexpr std::uint64_t flag_mask_shift = 0x00020000;
  constexpr std::uint32_t dev_lshift = 0x00000002;
  constexpr std::uint32_t dev_rshift = 0x00000004;

  constexpr int vk_shift = 0x10;  ///< Generic Shift, what the synthetic path sends.
  constexpr int vk_lshift = 0xA0;  ///< Left Shift, what a physically held key sends.
  constexpr int vk_w = 0x57;

  constexpr int kvk_shift = 0x38;
  constexpr int kvk_right_shift = 0x3C;
  constexpr int kvk_w = 0x0D;

  /// Mirrors macos_backend.cpp make_key_code_map(): both Shift codes collapse to one.
  int macos_key_code(int portable_key_code) {
    switch (portable_key_code) {
      case vk_shift:
        return kvk_shift;
      case vk_lshift:
        return kvk_shift;
      case vk_w:
        return kvk_w;
      default:
        return -1;
    }
  }

  struct ModifierFlags {
    std::uint64_t generic {};
    std::uint64_t device {};
    std::uint64_t all_devices {};
  };

  /// Mirrors macos_backend.cpp:256 modifier_flags_for_key().
  bool modifier_flags_for_key(int key, ModifierFlags &flags) {
    switch (key) {
      case kvk_shift:
        flags = {flag_mask_shift, dev_lshift, dev_lshift | dev_rshift};
        return true;
      case kvk_right_shift:
        flags = {flag_mask_shift, dev_rshift, dev_lshift | dev_rshift};
        return true;
      default:
        return false;
    }
  }

  /// Faithful copy of the backend's shared modifier state, macos_backend.cpp:441.
  class ModifierAccumulator {
  public:
    virtual ~ModifierAccumulator() = default;

    /// Mirrors MacosKeyboard::submit(), macos_backend.cpp:481-497.
    virtual void submit(int portable_key_code, bool pressed) {
      const auto key = macos_key_code(portable_key_code);
      if (key < 0) {
        return;
      }

      ModifierFlags modifier_flags;
      if (modifier_flags_for_key(key, modifier_flags)) {
        if (pressed) {
          keyboard_flags_ |= modifier_flags.generic | modifier_flags.device;
        } else {
          keyboard_flags_ &= ~modifier_flags.device;
          if ((keyboard_flags_ & modifier_flags.all_devices) == 0) {
            keyboard_flags_ &= ~modifier_flags.generic;
          }
        }
      }

      record_observation();
    }

    bool shift_is_down() const {
      return (keyboard_flags_ & flag_mask_shift) != 0;
    }

    unsigned transitions() const {
      return transitions_;
    }

    unsigned shift_presses() const {
      return shift_presses_;
    }

  protected:
    /// A game sees a transition whenever the generic Shift bit changes.
    void record_observation() {
      const bool down = shift_is_down();
      if (down != last_observed_) {
        transitions_++;
        if (down) {
          shift_presses_++;
        }
        last_observed_ = down;
      }
    }

    std::uint64_t keyboard_flags_ {};

  private:
    bool last_observed_ = false;
    unsigned transitions_ = 0;
    unsigned shift_presses_ = 0;
  };

  /**
   * @brief Solari's reference counted accumulator.
   *
   * Mirrors macos_input_t::apply_modifier() in src/platform/macos/input.cpp.
   * Counting presses per device bit means the synthetic release that brackets a
   * key cannot clear a modifier the player is still physically holding.
   */
  class RefCountedAccumulator final: public ModifierAccumulator {
  public:
    void submit(int portable_key_code, bool pressed) override {
      const auto key = macos_key_code(portable_key_code);
      if (key < 0) {
        return;
      }

      ModifierFlags modifier_flags;
      if (modifier_flags_for_key(key, modifier_flags)) {
        const bool is_left = modifier_flags.device == dev_lshift;
        int &count = is_left ? left_count_ : right_count_;
        const int &sibling = is_left ? right_count_ : left_count_;

        if (pressed) {
          count++;
          keyboard_flags_ |= modifier_flags.generic | modifier_flags.device;
        } else {
          if (count > 0) {
            count--;
          }
          if (count == 0) {
            keyboard_flags_ &= ~modifier_flags.device;
            if (sibling == 0) {
              keyboard_flags_ &= ~modifier_flags.generic;
            }
          }
        }
      }

      record_observation();
    }

  private:
    int left_count_ = 0;
    int right_count_ = 0;
  };

  /// Mirrors send_key_and_modifiers(), src/input.cpp:989.
  void send_key_and_modifiers(ModifierAccumulator &acc, int key_code, bool release, bool synthetic_shift) {
    if (!release && synthetic_shift) {
      acc.submit(vk_shift, true);  // press the synthetic modifier
    }

    acc.submit(key_code, release);

    if (!release && synthetic_shift) {
      acc.submit(vk_shift, false);  // and immediately raise it again
    }
  }

}  // namespace

namespace {

  constexpr double repeat_period_s = 1.0 / 24.9;  // src/config.cpp:847
  constexpr int repeats = 25;  // roughly one second of holding the key

  /**
   * @brief Play the sprint-and-run scenario through one accumulator.
   *
   * The player holds Left Shift to sprint, then holds W to run. The client
   * reports MODIFIER_SHIFT on the W packets, and because shortcutFlags has not
   * recorded Shift as held, src/input.cpp:1068 attaches Shift as a synthetic
   * modifier. That decision is captured into the repeat task at
   * src/input.cpp:1093 and replayed on every repeat.
   *
   * @param acc Accumulator under test.
   * @param label Name to print for this run.
   * @return Number of distinct Shift presses the game would observe.
   */
  unsigned run_scenario(ModifierAccumulator &acc, const char *label) {
    std::printf("%s\n", label);

    acc.submit(vk_lshift, true);
    std::printf("  player holds Left Shift            -> shift_down=%s\n", acc.shift_is_down() ? "true" : "false");

    send_key_and_modifiers(acc, vk_w, false, true);
    std::printf("  player presses W                   -> shift_down=%s\n", acc.shift_is_down() ? "true" : "false");

    for (int i = 0; i < repeats; ++i) {
      send_key_and_modifiers(acc, vk_w, false, true);
    }

    const double elapsed_s = repeats * repeat_period_s;
    const auto presses = acc.shift_presses();

    std::printf("  after %d repeats over %.2f s        -> shift_down=%s\n",
                repeats, elapsed_s, acc.shift_is_down() ? "true" : "false");
    std::printf("  transitions seen by the game:         %u\n", acc.transitions());
    std::printf("  distinct Shift presses:               %u", presses);
    if (presses > 1) {
      std::printf("   <-- oscillating at %.1f Hz",
                  elapsed_s > 0 ? static_cast<double>(presses - 1) / elapsed_s : 0.0);
    }
    std::printf("\n\n");

    return presses;
  }

}  // namespace

int main() {
  std::printf("Held-modifier oscillation: regression test\n");
  std::printf("=========================================\n\n");
  std::printf("Scenario: Left Shift held for the whole run, never released by the player.\n");
  std::printf("A correct backend reports exactly one Shift press.\n\n");

  ModifierAccumulator shared_backend;
  const auto shared_presses = run_scenario(shared_backend, "libvirtualhid shared backend (macos_backend.cpp:483-490)");

  RefCountedAccumulator solari_backend;
  const auto solari_presses = run_scenario(solari_backend, "Solari native backend (src/platform/macos/input.cpp)");

  std::printf("Verdict\n-------\n");

  bool ok = true;
  if (shared_presses > 1) {
    std::printf("defect reproduced in the shared backend: %u presses for one held key\n", shared_presses);
  } else {
    std::printf("UNEXPECTED: the shared backend did not reproduce the defect\n");
    ok = false;
  }

  if (solari_presses == 1 && solari_backend.shift_is_down()) {
    std::printf("Solari backend holds the modifier down: 1 press, still held at the end\n");
  } else {
    std::printf("FAIL: Solari backend reported %u presses, held=%s\n",
                solari_presses, solari_backend.shift_is_down() ? "true" : "false");
    ok = false;
  }

  std::printf("\n%s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
