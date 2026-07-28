# EQ for Mac — Future Plan

From **good** to **the greatest system-wide EQ on macOS**.

This document is a working roadmap built from a full read of the current codebase.
It captures every feature and UI improvement worth doing, why each matters, which
files it touches, a rough effort estimate (S / M / L), and a prioritized
milestone plan.

---

## 1. Vision

EQ for Mac already nails the hard part: a driver-free, system-wide equalizer
built on Core Audio Process Taps, with a polished menu-bar panel, a 6,800-entry
offline headphone catalog, and clean permission/sleep/device handling.

To become *the greatest*, the app should feel **alive, interactive, and
personal**:

- You **see** the audio (a live spectrum), not just a static curve.
- You **shape** the sound by dragging the curve directly, like a pro tool.
- You **hear the difference** instantly (A/B compare, bypass).
- It **remembers you** (per-device profiles, custom presets, favorites, launch
  at login) and stays out of the way.
- It **protects the signal** (clip-safe auto-preamp) and **sounds audiophile**
  (crossfeed, stereo width) when you want it to.

Guiding principles: stay driver-free and offline-first, keep it menu-bar-light,
never clip, respect Reduce Motion / accessibility, and preserve the current
design language.

---

## 2. Where the app is today (baseline)

| Area | Current state | File(s) |
|------|---------------|---------|
| Audio pipeline | Global tap → ring buffer → `AVAudioSourceNode` → `AVAudioUnitEQ` (31 slots) → peak limiter → output | `AudioEngine.swift`, `AudioRingBuffer.swift` |
| EQ UI | 10/15-band graphic faders + Catmull-Rom response curve (display only) | `EQPopoverView.swift`, `EQCurveView.swift`, `VerticalSlider.swift` |
| Presets | Built-in genre presets; import Equalizer APO / AutoEQ / PEQdB `.txt` (no save) | `EQModels.swift`, `PresetStore.swift`, `EqualizerAPOParser.swift` |
| Catalog | ~6,800 offline headphone entries + 17 targets; substring search | `PresetStore.swift`, `Resources/` |
| State | Preamp, band mode, gains, last headphone persisted | `EQViewModel.swift`, `EQModels.swift` |
| System | Permission monitor, sleep/wake, default-device change recovery | `PermissionMonitor.swift`, `AppDelegate.swift`, `MenuBarController.swift` |
| Distribution | Build-from-source, ad-hoc signed, no auto-update, no tests | `install.sh`, `scripts/`, `.github/` |

---

## 3. P0 — Flagship "wow" features

These are the changes that most transform the feeling of the app.

### 3.1 Live spectrum analyzer behind the EQ curve — **L**
The tapped audio is already flowing through `AudioRingBuffer`. Tap a copy of it,
run a windowed FFT with `vDSP` (Accelerate), and render a translucent real-time
spectrum underneath the existing response curve in `EQCurveView`. This is the
single biggest perceived-quality upgrade and the data cost is near zero because
the samples already exist.

- **Why:** Turns a static graphic into a living instrument; instantly reads as
  "pro."
- **Touches:** `AudioEngine.swift` (expose a lightweight magnitude buffer /
  publisher), new `SpectrumAnalyzer.swift` (vDSP FFT + log-frequency binning +
  smoothing), `EQCurveView.swift` (draw bars/area behind curve),
  `EQPopoverView.swift` (wire in, respect Reduce Motion / pause when hidden).
- **Notes:** Compute off the render thread; throttle to ~30 fps; freeze when the
  popover is closed to save CPU.

### 3.2 Interactive draggable EQ curve — **L**
`EQCurveView` is currently `allowsHitTesting(false)`. Make the curve the primary
control surface: drag a node vertically to set band gain (phase 1), then drag
horizontally for center frequency and drag/scroll for Q to unlock true
parametric editing (phase 2). Keep the faders in sync as an alternate view.

- **Why:** Direct manipulation is what "great" EQs feel like; also the natural
  gateway to real parametric editing (the engine is already parametric).
- **Touches:** `EQCurveView.swift` (hit testing, node handles, gestures),
  `EQViewModel.swift` (map curve edits to bands, keep graphic/parametric in
  sync), `EQPopoverView.swift`.
- **Notes:** Snap to 0 dB and to ISO frequencies; double-click a node to reset;
  keep the magnetic-zero behavior from `VerticalSlider`.

### 3.3 A/B compare + one-tap bypass in the UI — **S**
The engine already supports `bypassed` (`AudioEngine.bypassed`) but the UI never
exposes it. Add a header control: quick bypass toggle plus a hold-to-compare
button (press = dry, release = processed).

- **Why:** Hearing the difference instantly is the core EQ feedback loop and is
  currently missing entirely from the UI.
- **Touches:** `EQPopoverView.swift` (header controls), `EQViewModel.swift`
  (bridge to `audioEngine.bypassed`), optional keyboard shortcut.

### 3.4 Clip-safe auto-preamp — **M**
Automatically compute recommended preamp from the maximum positive band gain
(and the summed response) so boosts never clip, with a "match preamp" button and
an optional always-on auto mode. Today `preampDB` is fully manual.

- **Why:** Protects the signal, removes a source of confusing distortion, and
  makes presets safe by default.
- **Touches:** `EQViewModel.swift` (headroom calculation on gain/preset change),
  `EQPopoverView.swift` (auto toggle + suggestion chip), `EQModels.swift`
  (store per-preset preamp intent).

---

## 4. P1 — High-impact features

### 4.1 Save & manage custom presets — **M**
Today you can only *import*. Add save-current-as-preset, rename, delete,
reorder, and favorites for user presets, surfaced alongside the built-in chips.

- **Why:** Personalization is table stakes for a great EQ; users invest in their
  own curves and expect them to stick.
- **Touches:** `PresetStore.swift` (user preset store + persistence),
  `EQModels.swift` (`AppPreferences` / user preset model), `EQPopoverView.swift`
  (preset chip management UI), `EQViewModel.swift`.

### 4.2 Per-output-device auto profiles — **M**
`handleDefaultDeviceChange()` currently just restarts on the new device. Instead,
remember an EQ per output device and auto-apply it when that device becomes
active (e.g., a headphone curve for your AirPods, flat for speakers).

- **Why:** This is a killer, "it just knows" feature for anyone who switches
  between headphones and speakers.
- **Touches:** `AudioEngine.swift` (surface device UID on change),
  `EQViewModel.swift` (profile lookup/apply), `PresetStore.swift` /
  `EQModels.swift` (device→preset map + persistence).

### 4.3 Launch at login — **S**
Add a `SMAppService`-based "Launch at login" toggle. Essential for a menu-bar
utility and currently absent.

- **Why:** A background EQ that doesn't auto-start is friction on every reboot.
- **Touches:** New `LoginItem.swift` (SMAppService wrapper), Settings UI (see
  4.6 / 5.4), `AppDelegate.swift`.

### 4.4 Global hotkey — **S/M**
Register a system-wide shortcut to toggle EQ on/off and (optionally) cycle
presets or bypass without opening the panel.

- **Why:** Instant control is expected of power-user menu-bar tools.
- **Touches:** New `HotKeyManager.swift` (Carbon `RegisterEventHotKey` or a small
  helper), `EQViewModel.swift`, Settings UI for rebinding.

### 4.5 Headphone search upgrades — **M**
`searchCatalog` is substring-only. Add fuzzy matching, "recently applied," and
pinned/favorite headphones at the top of the list.

- **Why:** 6,800 entries deserve fast, forgiving discovery; recents/favorites cut
  repeat friction.
- **Touches:** `PresetStore.swift` (ranking + recents/favorites persistence),
  `EQViewModel.swift`, `EQPopoverView.swift` (sections + pin affordance).

### 4.6 First-run onboarding for permission — **M**
Replace the single in-panel banner with a short guided onboarding that explains
the Screen & System Audio Recording requirement, deep-links to the exact
Settings pane, and confirms success via the engine probe.

- **Why:** The permission dance is the #1 place new users get stuck; a guided
  flow dramatically improves activation.
- **Touches:** New onboarding view, `PermissionMonitor.swift`,
  `EQPopoverView.swift` / `MenuBarController.swift`.

---

## 5. P2 — Polish & refinement

### 5.1 Curve axes & readouts — **S**
Add log-scale frequency labels, dB grid lines, and a hover readout
(frequency + gain) on the curve.
- **Touches:** `EQCurveView.swift`, `EQPopoverView.swift`.

### 5.2 Menu-bar quick controls — **S**
Scroll over the status item to nudge preamp; option-click for a compact control
menu; richer tooltip/state. Builds on `MenuBarController.updateIcon()`.
- **Touches:** `MenuBarController.swift`.

### 5.3 Preserve fader state across modes — **S**
`approximateGains` is lossy; moving one fader while a headphone/parametric preset
is active silently drops the full parametric curve to a graphic approximation.
Preserve original bands and only convert on explicit user intent.
- **Touches:** `EQViewModel.swift`.

### 5.4 Dedicated Settings/Preferences window — **M**
Move launch-at-login, hotkeys, auto-preamp default, update settings, and about
into a proper Settings window (macOS `Settings` scene / grouped `Form`).
- **Touches:** New `SettingsView.swift`, `AppDelegate.swift`,
  `MenuBarController.swift`.

### 5.5 Optional Tahoe Liquid Glass styling — **M**
On macOS 26+, adopt Liquid Glass materials for the popover while keeping the
current look as the fallback.
- **Touches:** `EQPopoverView.swift`, availability-gated styling.

---

## 6. Audiophile engine features

### 6.1 Crossfeed — **M**
Add optional headphone crossfeed (blend a filtered, delayed opposite channel) to
reduce listening fatigue and widen the soundstage on headphones.
- **Touches:** `AudioEngine.swift` (extra node / matrix mixer in the graph),
  `EQViewModel.swift`, UI toggle + intensity.

### 6.2 Stereo width & L/R balance / mono — **S/M**
Add stereo width, channel balance, and a mono fold-down before output.
- **Touches:** `AudioEngine.swift` (mixer/matrix node), UI controls.

### 6.3 Per-app EQ (advanced) — **L**
The tap is global today. Optionally create per-process taps to apply different
EQ per app (e.g., podcast profile for a browser, flat for a game).
- **Why:** A genuinely differentiating power feature.
- **Touches:** `AudioEngine.swift` (per-process tap management), new
  app-profile model + UI, `PresetStore.swift`.
- **Notes:** Significant complexity (multiple taps/engines); ship behind an
  "advanced" flag after the core is solid.

---

## 7. Robustness & performance

### 7.1 memcpy / vDSP buffer paths — **S**
`AudioRingBuffer.read/write` and the deinterleave in `renderCallback` use
per-sample `for` loops. Replace with `memcpy` (with wrap handling) and
`vDSP`/`cblas` deinterleave to cut CPU on the audio thread.
- **Touches:** `AudioRingBuffer.swift`, `AudioEngine.swift`.

### 7.2 Handle output format / sample-rate changes — **M**
Today only default-device changes are handled. Also react to nominal
sample-rate/format changes on the current device to avoid pitch/glitch issues.
- **Touches:** `AudioEngine.swift` (additional property listeners).

### 7.3 Smoother Bluetooth switching — **S/M**
The README notes brief Bluetooth glitches on output switch. Tune the reconnect
delay and add a short ramp/fade on restart in `handleDefaultDeviceChange()`.
- **Touches:** `AudioEngine.swift`.

### 7.4 Optional true-peak / soft-clip safety — **S**
Complementary to auto-preamp (3.4): expose limiter behavior and consider a
gentle soft-clip stage for extreme boosts.
- **Touches:** `AudioEngine.swift`.

---

## 8. Distribution & quality

### 8.1 Auto-update via Sparkle — **M**
Add Sparkle + an appcast feed so users get updates without re-running
`install.sh`. (See the `macos-auto-update` and `macos-release` skills.)
- **Touches:** `Package.swift` (Sparkle SPM dep), new `UpdaterManager.swift`,
  `Info.plist` (`SUFeedURL`, EdDSA key), Settings UI, `scripts/`, `README.md`.
- **Notes:** Optional given the intentional source-only stance; can be opt-in.

### 8.2 Signed DMG release path — **M**
Optionally provide a notarized/signed DMG alongside build-from-source for users
who don't want to compile.
- **Touches:** `scripts/`, `.github/workflows/`, `README.md`.

### 8.3 Unit tests — **M**
No tests exist. Add a test target covering:
- `EqualizerAPOParser` (PK/LS/HS/LP/HP/BW variants, preamp, junk lines),
- `EQViewModel.approximateGains` (mapping stability),
- preset (de)serialization (`EQPreset` / `AppPreferences`),
- `AudioRingBuffer` wrap-around correctness.
- **Touches:** new `Tests/EQForMacTests/`, `Package.swift`.

### 8.4 Accessibility & Reduce Motion audit — **S**
Extend the existing good accessibility (faders are labeled/adjustable) to the
new interactive curve, spectrum, and controls; verify VoiceOver and Reduce
Motion paths.
- **Touches:** `EQCurveView.swift`, `EQPopoverView.swift`, new views.

---

## 9. File-by-file implementation map

| File | Planned work |
|------|--------------|
| `AudioEngine.swift` | Spectrum tap/publisher; crossfeed + width/balance nodes; format-change listeners; memcpy/vDSP paths; BT smoothing; expose device UID |
| `AudioRingBuffer.swift` | memcpy read/write with wrap handling |
| `EQCurveView.swift` | Interactive nodes; spectrum layer; axes/grid/hover readout; a11y |
| `EQPopoverView.swift` | A/B + bypass; auto-preamp UI; preset management; search sections; onboarding entry; Tahoe styling |
| `EQViewModel.swift` | Auto-preamp calc; per-device profiles; state preservation across modes; curve-edit binding |
| `PresetStore.swift` | User presets (save/rename/delete/reorder/favorites); fuzzy search + recents; device→preset map |
| `EQModels.swift` | User preset + device-profile models; extended `AppPreferences` |
| `MenuBarController.swift` | Scroll/option-click quick controls; richer icon/state |
| `PermissionMonitor.swift` | Onboarding hooks |
| `AppDelegate.swift` | Launch-at-login wiring; Settings scene; format-change hooks |
| New: `SpectrumAnalyzer.swift` | vDSP FFT + log binning + smoothing |
| New: `LoginItem.swift` | SMAppService wrapper |
| New: `HotKeyManager.swift` | Global hotkey registration |
| New: `SettingsView.swift` | Preferences window |
| New: `UpdaterManager.swift` | Sparkle integration (optional) |
| New: `Tests/EQForMacTests/` | Parser, view model, preset, ring-buffer tests |
| `Package.swift` | Test target; optional Sparkle dep |
| `README.md` | Document new features; update limitations |

---

## 10. Prioritized roadmap

### Milestone 1 — "It feels alive" (visible, high-impact)
- 3.1 Live spectrum analyzer **(L)**
- 3.3 A/B compare + bypass **(S)**
- 3.4 Clip-safe auto-preamp **(M)**
- 5.1 Curve axes & readouts **(S)**
- 7.1 memcpy/vDSP buffers **(S)**  *(enables the analyzer to stay cheap)*
- 8.3 Unit tests (parser + view model foundation) **(M)**

### Milestone 2 — "It's personal" (retention & control)
- 3.2 Interactive draggable curve **(L)**
- 4.1 Save & manage custom presets **(M)**
- 4.2 Per-output-device auto profiles **(M)**
- 4.3 Launch at login **(S)**
- 4.4 Global hotkey **(S/M)**
- 4.5 Search upgrades (fuzzy + recents + favorites) **(M)**
- 5.3 Preserve fader state across modes **(S)**
- 5.4 Settings window **(M)**

### Milestone 3 — "Audiophile & shippable" (depth & reach)
- 6.1 Crossfeed **(M)**
- 6.2 Stereo width / balance / mono **(S/M)**
- 6.3 Per-app EQ (advanced, flagged) **(L)**
- 4.6 Onboarding flow **(M)**
- 5.2 Menu-bar quick controls **(S)**
- 5.5 Tahoe Liquid Glass **(M)**
- 7.2 Format/sample-rate change handling **(M)**
- 7.3 Bluetooth switch smoothing **(S/M)**
- 8.1 Sparkle auto-update **(M)** / 8.2 signed DMG **(M)** *(optional)*
- 8.4 Accessibility audit of new surfaces **(S)**

---

## 11. Explicit non-goals (keep the identity)
- Stay **driver-free** (no virtual audio device).
- Stay **offline-first** (bundled catalog; no telemetry, no audio upload).
- Stay **menu-bar-light** (no Dock icon, no heavy main window).
- Keep the current visual language; evolve, don't replace.

---

*Effort key: **S** ≈ hours, **M** ≈ 1–2 days, **L** ≈ multi-day. Estimates are
for a focused implementation pass and exclude polish/QA time.*
