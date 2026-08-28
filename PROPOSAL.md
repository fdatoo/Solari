# Solari: overhauling Sunshine's macOS support

Date: 2026-08-27. Target OS: macOS 26 Tahoe (26.5.2 on the reference machine).
Target hardware: Mac Studio, Apple M4 Max, two Dell U2725QE displays (4K and 5K,
both 120 Hz). Sources studied: upstream LizardByte/Sunshine at `377e07ce`
(2026-08-26, three commits past v2026.826.1804) and the abandoned Lumen fork
(github.com/saxlamen/Lumen, 29 commits, Feb to Apr 2026, forked from upstream
main of 2026-02-15).

Scope decisions, settled: Solari is personal-machine-first (distribution is a
non-goal for now), gamepad support is out of scope entirely, and HDR is a
required feature, not a stretch goal.

## 1. Where Sunshine actually stands on macOS

macOS is documented as experimental upstream, and the code backs that up.

### Input, the headline problem

A structural surprise first: as of 2026-08-16 (PR #5368), upstream deleted its
entire macOS input backend. `src/platform/macos/input.cpp` went from 759 lines
to 61, and everything now routes through a cross-platform shim
(`src/platform/virtualhid_input.cpp`) over an external `libvirtualhid`
submodule, which is not even checked out in the reference tree. libvirtualhid
has no macOS gamepad backend, and if its macOS mouse or keyboard backend is
missing or fails, every input call silently no-ops behind `if (context.mouse)`
guards.

The last in-tree implementation (recoverable at `687e12d0^`, and presumably
what libvirtualhid's macOS backend was ported from) contains the likely causes
of the jitter you feel in games:

1. Every mouse move is followed by `CGWarpMouseCursorPosition`, with
   `CGAssociateMouseAndMouseCursorPosition` never called and no suppression
   interval configured. Warping triggers the WindowServer's ~250 ms local
   event suppression window, which is a textbook recipe for stuttery aim.
2. Relative mouse motion is faked as absolute motion: each delta reads the
   current cursor position (allocating and releasing a throwaway CGEvent per
   call), adds integer deltas, clamps to the display bounds, and posts an
   absolute move. There is no true relative path and no sub-pixel
   accumulation.
3. All input injection shares Sunshine's single global task-pool worker thread
   (`task_pool.start(1)` in `src/main.cpp:339`) with key-repeat timers and
   every other deferred job. A QoS elevation helper exists in
   `misc.mm` but nothing on the input path calls it.
4. Bursts of queued mouse moves are summed into one call
   (`src/input.cpp:1576`), so motion collapses rather than being paced.
5. Accessibility permission, which `CGEventPost` requires, is never checked or
   requested anywhere. Denied permission means silently dropped input.

Gamepads simply do not work on macOS: the feature matrix shows every gamepad
type unsupported, and `supported_gamepads()` reports
`gamepads.virtualhid-not-available`.

### Keyboard: held modifiers oscillate

This is a separate defect from mouse jitter, with its own root cause. A held
Shift (or Control, or Option) is reported to the game as being released and
re-pressed roughly 25 times a second. Reproduced deterministically by
`tools/modifier_oscillation_repro.cpp`, which replays the real call sequence
against a faithful copy of the backend's modifier accumulator.

Three things combine:

1. `send_key_and_modifiers()` (`src/input.cpp:989`) implements "synthetic"
   modifiers by pressing the modifier, sending the key, then releasing the
   modifier again. That is correct for typing a capital letter on a client
   whose Shift the host never saw, and wrong for a modifier the player is
   physically holding.
2. `repeat_key()` (`src/input.cpp:1026`) re-runs that entire sequence every
   `key_repeat_period`, which defaults to 1/24.9 s ≈ 40 ms
   (`src/config.cpp:847`), reusing the `synthetic_modifiers` value captured
   when the key was first pressed (`src/input.cpp:1093`).
3. The macOS backend cannot tell the synthetic modifier from the real one.
   `VKEY_SHIFT` (0x10) and `VKEY_LSHIFT` (0xA0) both map to `kVK_Shift`
   (libvirtualhid `macos_backend.cpp:54` and `:168`), so both resolve to the
   same `NX_DEVICELSHIFTKEYMASK` bit (`:259`). The accumulator is a single
   shared flag word with no press count (`:441`), so the synthetic release
   clears the device bit, sees no devices left, and clears the generic
   `kCGEventFlagMaskShift` too (`:486-489`), then posts a
   `kCGEventFlagsChanged` announcing Shift is up while the player is still
   holding it.

The trigger for the synthetic path is a desync: it engages when the client's
packet reports `MODIFIER_SHIFT` but Sunshine's own `shortcutFlags` does not
have SHIFT recorded (`src/input.cpp:1068`). A stray Shift key-up, a modifier
resync from the client, or Shift already being held when the session starts
all produce that state, which is why the symptom is intermittent rather than
constant.

Note the severity ordering: even without key repeat, a single synthetic
release clobbers a physically held modifier. Key repeat is what turns a
one-shot glitch into a sustained 25 Hz oscillation.

### Capture

Capture still uses `AVCaptureScreenInput`, deprecated since macOS 13, with no
ScreenCaptureKit path anywhere. `minFrameDuration` acts as a ceiling rather
than a pacer, the capture thread waits on a semaphore with an unbounded
timeout (an in-tree FIXME acknowledges this), there is no HDR (the display
class never overrides `is_hdr()`), no YUV 4:4:4, and one display per session
selected by raw CGDirectDisplayID.

### Audio, encoding, and the rest

Audio is in better shape: since macOS 14, upstream captures system audio with
a Core Audio process tap (`CATapDescription` and
`AudioHardwareCreateProcessTap`) in a carefully real-time-safe callback, so
BlackHole is only needed as a legacy fallback. The sink enumeration functions
are stubs, so the web UI cannot list or validate audio devices.

Encoding is VideoToolbox with H.264, HEVC, and AV1, NV12 and P010, with a
known and worked-around H.264 quirk (setting `max_ref_frames=1` on Apple
Silicon produces all-IDR output, LizardByte/Sunshine#5013). No 4:4:4 formats.

Other gaps: no virtual display of any kind, display mode switching is
verify-only (resolution and refresh matching are inert), the high-precision
timer is a plain `sleep_for` wrapper, and `restart()` requires a fork dance to
keep the tray icon alive.

## 2. What Lumen actually delivers

Lumen's README promises a macOS overhaul. The code delivers about half of it,
and notably not the half you care most about.

### The reality check on input

Lumen's `input.mm` is upstream's old `input.cpp` renamed, with the CGEvent
injection path byte-for-byte intact: same reused event, same per-move
`CGWarpMouseCursorPosition`, same absolute reconstruction of relative motion,
no threading changes, no layout awareness. Its only input changes are a
corrected high-resolution scroll (`distance / 120` line units), an implemented
horizontal scroll, retargeting the mouse at the virtual display, and gamepad
wiring. The input overhaul does not exist in the code. Nobody has solved your
top problem yet; Solari would be first.

### What is genuinely worth borrowing, ranked

1. `vd_helper.m`, the virtual display helper. A standalone binary that drives
   the private `CGVirtualDisplay` API plus four SkyLight calls to create,
   enable, position, and un-mirror a virtual display, including the hard-won
   HiDPI mode dance (register a two-mode HiDPI list or WindowServer hands back
   half resolution, then explicitly switch back to the 1x native mode). This
   is real reverse-engineering effort that would take days to rediscover.
2. `sc_capture.m`, a straightforward ScreenCaptureKit capture backend with
   sensible NV12/P010 wiring into the existing zero-copy path, plus a
   synthetic black dummy frame that avoids restarting capture during encoder
   probing.
3. A gamepad fast path in common `src/input.cpp` that dispatches controller
   updates directly on the control-stream thread instead of the task pool,
   claiming 5 to 15 ms saved. The idea generalizes to mouse input.
4. The H.264 `max_ref_frames` fix (upstream has since adopted it
   independently) and the `PARALLEL_ENCODING` flag for VideoToolbox.

Lumen's `hid_gamepad.m` (a virtual HID gamepad via `IOHIDUserDeviceCreate`)
is technically sound, but it needs an Apple-restricted entitlement that Lumen
works around by requiring AMFI disabled via nvram boot-args. With gamepad
support out of scope for Solari, we take nothing from it.

### What to leave behind

Lumen's SCK-based audio (upstream's Core Audio tap is newer and better, and
Lumen's version has a use-after-free on teardown plus per-callback mallocs on
the audio thread). Both gamepad backends, per the scope decision. The world-writable
`/tmp/sunshine_vd_id` handoff file. A hard 5-second sleep on the session
start path after virtual display creation, about 2 more seconds of sleeps in
the helper, and up to 3 seconds of blocking retries in capture. A dead frame
pacing timer that is declared and cancelled but never scheduled. Cursor
visibility fixed at stream start. The Homebrew-specific `launchctl` restart
with hardcoded paths.

Lumen also deleted the Windows and Linux platforms, docs, and the `.app`
packaging, and it sits on a February 2026 base that upstream has moved six
months past (including a full macOS packaging and signing rewrite and the
Core Audio rework).

## 3. Fork strategy

Fork current upstream Sunshine, not Lumen. Lumen's base is stale, its
structural deletions would all have to be undone, and its two best assets
(the virtual display helper and the SCK capture backend) are small,
self-contained files that port forward easily. Both projects are GPLv3, so
wholesale borrowing is fine with notices kept intact.

One consequential decision inside that: input. Upstream now expects input to
come from libvirtualhid. I recommend Solari implement its own macOS input
backend in-tree at `src/platform/macos/`, replacing the shim on Apple, rather
than working inside the submodule. The input rewrite is our core product; we
want to iterate on it daily without a second repo and a pinned submodule in
the loop. If it works out we can offer it upstream to libvirtualhid later.

## 4. Workstreams

### A. Input rewrite (the headline)

Keep CGEvent injection as the mechanism (a virtual HID mouse hits the same
restricted entitlement wall as gamepads), but fix how it is driven:

1. True relative motion. Post `mouseMoved`/`*MouseDragged` events whose
   location advances from our own tracked position, set
   `kCGMouseEventDeltaX/Y` from the raw deltas, and stop warping on every
   move. Warp only on absolute repositioning, and set
   `CGEventSourceSetLocalEventsSuppressionInterval` to zero on our source so
   no warp ever stalls injected events.
2. Sub-pixel accumulation. Carry float remainders across moves instead of
   truncating to int, so slow precise aiming is not quantized. (The current
   shim even rounds away the protocol's sub-pixel absolute coordinates.)
3. A dedicated input thread at `QOS_CLASS_USER_INTERACTIVE`, decoupled from
   the single shared task-pool worker, with event timestamps set from
   `mach_absolute_time` so WindowServer coalescing behaves.
4. Accessibility preflight via `AXIsProcessTrustedWithOptions` at startup with
   a clear prompt, mirroring the existing screen-recording preflight, so
   denied permission fails loudly instead of dropping input silently.
5. Keyboard modifiers, which need a different model rather than a patch.
   On macOS modifier state travels as flags on each event, so the entire
   synthetic press/release dance is unnecessary: a key that needs Shift can
   simply be posted with `kCGEventFlagMaskShift` in its own flags, which the
   backend already sets (`macos_backend.cpp:496`). Solari should derive
   modifier flags from the client's reported modifier bitmask per key event
   and stop translating synthetic modifiers into key events entirely. That
   removes the clobbering at its source instead of reference-counting around
   it. Supporting changes: suppress host-side key repeat on macOS (the client
   sends its own key events, so host repeat adds only hazard), and fix the
   `shortcutFlags` desync that makes the synthetic path engage.
6. Keyboard, rest: keep the proven VK to kVK table, add unicode text entry via
   `CGEventKeyboardSetUnicodeString`, and adopt Lumen's corrected
   high-resolution scroll plus horizontal scroll. Note that scroll events are
   currently posted with no flags at all (`macos_backend.cpp:756-762`), so
   scrolling while holding a modifier drops it, a smaller instance of the
   same class of bug.
7. Measure before and after. `tools/solari_input_probe.c` (built in phase 0)
   taps the event stream a game sees and reports modifier transition counts,
   mouse inter-arrival jitter, and whether deltas are quantised to whole
   pixels, so every claim here is checkable against a number.

### B. ScreenCaptureKit capture

Port Lumen's `sc_capture.m` onto current upstream and clean it up: async
shareable-content lookup instead of one-second thread sleeps, honor the
callback's return value on idle re-delivery, allow cursor toggling
mid-session, and drop the dead timer. Then go past it: 120 Hz capture config
for your displays and frame pacing from SCK presentation timestamps.

HDR is a first-class goal of this workstream, not a follow-on. Neither
Sunshine nor Lumen has any HDR support, so this is new work: configure the
SCK stream's dynamic range for HDR capture, select P010, override the
display's `is_hdr()` and `get_hdr_metadata()` (currently inherited stubs),
and carry color space and mastering metadata through the VideoToolbox
encoders so HEVC and AV1 streams are correctly tagged for the client. This
also interacts with the virtual display workstream: the virtual display's
mode and EDR support must advertise HDR for the pipeline to light up when
streaming headless. Keep the AVFoundation path as an SDR-only fallback during
transition, as Lumen did.

### C. Virtual display

Port `vd_helper.m` and its manager with fixes: build the mode list from the
client's negotiated resolution and fps (including 120 Hz and HiDPI variants)
instead of a fixed pair, replace every fixed sleep with polling or
`CGDisplayRegisterReconfigurationCallback`, hand the display ID over the pipe
only (no `/tmp` file), and give the helper a parent-death watchdog (kqueue
`EVFILT_PROC` on the parent PID) so a crashed server cannot orphan a phantom
display. This is a private API, so an early spike must confirm it still works
on macOS 26 before we commit to the design. The spike should also probe
whether a virtual display can present as HDR/EDR-capable, since headless HDR
streaming depends on it.

### D. Audio and encoding polish

Keep upstream's Core Audio tap unchanged and skip Lumen's audio entirely.
Implement the `sink_info`/`is_sink_available` stubs so the web UI can
enumerate devices. Keep upstream's H.264 VideoToolbox workaround and evaluate
Lumen's `PARALLEL_ENCODING` flag against it.

### E. Permissions, packaging, config

Personal-machine-first keeps this light. Keep upstream's `.app` build working
(it already handles Info.plist usage strings and ad-hoc signing) but skip dmg
polish, notarization, and installer work. What still matters even for one
machine: preflight both Screen Recording and Accessibility with directed
System Settings deep links, and expose the new options (`virtual_display`,
`show_cursor`, HDR, input tuning) in the web UI rather than config-file-only
as Lumen did.

## 5. Phasing

Status as of 2026-08-27: phases 0 and 1 are done, on branch
`solari/phase-0-bootstrap`. Upstream is forked to `fdatoo/Solari` at `377e07ce`
and builds on macOS 26 (Xcode 21, tray and docs off for now, so Qt is not yet a
dependency).

Phase 1 is verified against a real Moonlight client, not just in test. Both
reported defects are fixed and accepted by the user:

- Held modifiers no longer oscillate. Two rounds were needed. Keeping the flag
  word steady was not enough, because the backend still posted a flags event
  for every synthetic modifier press and release, roughly fifty a second. A
  game reading the modifier per event rather than by diffing the flag word
  still flickered. Flags events are now emitted only on a genuine change.
- Mouse motion is much improved, from removing the per-move cursor warp.

What the measurements settled, so it is not re-litigated later:

- Remaining motion spread is not ours. `pacing_generator` posts locally at a
  fixed rate through the same injection path: posts leave with 0.81 ms spread
  and arrive with 1.30 ms, against 13.74 ms during a stream. Roughly 12 ms is
  introduced before injection, in the client or the network (Tailscale is the
  leading suspect and was not ruled out).
- Thread QoS was not the bottleneck. Elevating the injecting thread to
  `USER_INTERACTIVE` changed nothing measurable. It is kept because it is
  correct, not because it helped.
- Relative mouse batching in `src/input.cpp:1585` is dead code upstream: the
  overflow test is inverted, so batching terminates whenever the addition is
  safe. Harmless in practice, and it means batching was never collapsing
  motion. Worth reporting upstream.

Operational note for future sessions: the app must be signed with a real
certificate (`SOLARI_SIGN_ID`), otherwise macOS ties Screen Recording and
Accessibility to the exact binary and every rebuild silently revokes them.
Signing has to happen from the user's own Terminal; an agent shell runs in a
Background security session that cannot reach the keychain. See
`scripts/solari-dev.sh`.

Each phase ships something testable on the Mac Studio via a real Moonlight
client.

- Phase 0, bootstrap. Fork upstream, check out submodules, build on macOS 26,
  stand up the input measurement harness, and spike CGVirtualDisplay on
  macOS 26 (including its HDR/EDR behavior) to de-risk phase 3.
- Phase 1, input. The in-tree macOS input backend, covering both defects.
  Exit criteria: a held modifier shows exactly one down transition in
  `solari_input_probe` for the whole time it is held (today it shows ~25 per
  second), no 250 ms stalls, measurably lower inter-event jitter than stock,
  and smooth aim plus reliable sprint in an actual game.
- Phase 2, capture and HDR. SCK backend at 120 Hz with clean pacing, then HDR
  end to end. Exit criteria: an HDR-tagged HEVC stream that a Moonlight
  client renders correctly in HDR.
- Phase 3, virtual display. Headless streaming at the client's native mode,
  HDR included if the phase 0 spike confirmed it.
- Phase 4, polish. Permissions UX, web UI options, docs.

## 6. Risks and open questions

1. libvirtualhid is a moving target upstream; replacing it on Apple means
   owning merge friction at that seam. Contained, since the shim boundary is
   narrow.
2. CGVirtualDisplay and SkyLight are private APIs that any macOS update can
   break. The phase 0 spike and a capture fallback to a real display keep
   this survivable.
3. HDR on macOS 26 has unknowns we can only resolve on the hardware: how SCK
   delivers HDR pixel data on this OS version, what the tone mapping
   semantics are for EDR content, and whether a virtual display can present
   as HDR-capable at all. Real displays are the fallback if headless HDR
   proves impossible.
4. Streaming clients vary in HDR handling; validation targets Moonlight
   specifically, on the clients you actually use.
