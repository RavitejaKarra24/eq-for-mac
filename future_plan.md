# EQ for Mac — Future Plan

Written after a full read of the code at `bb04988`. The previous roadmap is done:
spectrum, draggable curve, A/B, auto-preamp, user presets, device profiles, login
item, hotkey, fuzzy search, onboarding, settings window, crossfeed, spatial
controls, and tests all shipped in one commit. This document is not a wishlist —
it is an honest audit of what that commit left behind, what should be deleted,
and where the next order of magnitude actually is.

**The core thesis:** the app is now feature-complete and *fidelity-poor*. It has
every control an EQ is supposed to have, and it cannot tell you the truth about
what any of them do. The next phase is not more features. It is owning the DSP,
deleting a third of the surface area, and fixing the handful of bugs that make
the app stutter and lie.

---

## 1. The single biggest problem: the app doesn't know its own response

`AVAudioUnitEQ` is a black box that will not report its transfer function. So the
codebase *guesses* it — twice, differently, with hand-rolled Gaussians:

| Where | Parametric weight |
|---|---|
| `EQViewModel.approximateGains` (`EQViewModel.swift:727`) | `exp(-0.693 · (Δoct / bandwidth)²)` |
| `EQHeadroomCalculator.contribution` (`EQHeadroomCalculator.swift:45`) | `exp(-0.693 · (Δoct / (bandwidth·0.5))²)` |

Same band, two different widths. The curve you see, the fader positions you drag,
and the "Safe: −6.5 dB" headroom number are three different fictions about one
filter — and none of them is the biquad Apple actually renders. Consequences that
are live today:

- **The response curve is decorative.** It is a Catmull-Rom spline through 10 or
  15 guessed points, not the filter response. Apply a headphone preset with a
  narrow 8 kHz notch and the curve will show something that isn't happening.
- **Auto-preamp is an estimate presented as a guarantee.** It's labeled "Safe"
  and it isn't computed from the real response.
- **Bandwidth is clamped to `[0.05, 5]` octaves** (`AudioEngine.swift:576`).
  AutoEQ files routinely contain Q > 15 (≈0.09 oct) and the clamp quietly widens
  them. The correction you applied is not the correction you downloaded.
- **Bands past slot 64 are silently dropped** (`configureEQBands`, `AudioEngine.swift:570`).
  A dense PEQdB import plus accumulated user overlays can cross that line with no
  warning.

**Fix: own the filter graph.** Replace `AVAudioUnitEQ` with an RBJ biquad cascade
run through `vDSP_biquadm` in the source-node render block. It is roughly 200
lines. What it buys:

- One exact `EQResponse.magnitudeDB(bands:at:)`, shared by the curve, the fader
  projection, and the headroom calculator. The picture becomes true for free.
- No band cap, no bandwidth clamp, correct high-Q behavior.
- Exact clip headroom instead of an estimate.
- The prerequisite for per-app EQ (§5.1) — you need N independent filter chains,
  and you can't cheaply have N `AVAudioUnitEQ`s.

This is the highest-leverage change available. Almost everything else in this
document gets easier once it lands.

---

## 2. Bugs and code problems that need fixing

Ordered by user-visible damage.

### 2.1 Up to 1.5 seconds of main-thread `Thread.sleep` on every engine start
`AudioEngine.swift:343-349` polls `kAudioDevicePropertyDeviceIsAlive` 30 times
with `Thread.sleep(forTimeInterval: 0.05)` — inside a `@MainActor` method. Every
EQ toggle, every output-device change, and every sample-rate change can freeze
the UI for over a second. This is the worst bug in the app.

**Fix:** make `start()` async and await an `AudioObjectAddPropertyListenerBlock`
on `DeviceIsAlive`, or at minimum move the poll off the main actor.

### 2.2 ARC retain/release on the audio thread
`renderCallback` (`AudioEngine.swift:32`) and the IOProc block (`:448`) both read
`Optional<class>` globals — `rtRingBuffer`, `rtStereoProcessor`. Binding those
emits atomic retain/release on the real-time thread. Worse, the matching release
can be the *last* one during teardown, meaning `free()` runs on the audio thread.

**Fix:** capture the objects strongly in the render closure and IO block at
construction (they're already per-start objects), or hold them as `Unmanaged`
raw pointers. Stop reading mutable global class references from the RT path.

### 2.3 Scratch buffer freed while a render may be in flight
`tearDownAudioGraph` calls `engine?.stop()` then `oldScratch?.deallocate()`
(`AudioEngine.swift:508-524`). `AVAudioEngine.stop()` does not document that the
render thread has quiesced on return. Same pattern in `start()` at `:363-366`.

**Fix:** tie the scratch buffer's lifetime to the render block (own it, don't
share it through a global), or defer the free by a generation.

### 2.4 Global RT state makes the engine a singleton by accident
`rtRingBuffer`, `rtChannelCount`, `rtScratchBuffer`, `rtScratchCapacity`,
`rtStereoProcessor` are file-scope `nonisolated(unsafe)` vars. A second
`AudioEngine` would corrupt the first. This is also the structural blocker for
per-app EQ. Fold them into a render-context object owned by the source node.

### 2.5 Persistence runs a full JSON round-trip on every fader tick
`EQViewModel.persist()` (`:836`) starts with `AppPreferences.load()` — decoding
the entire prefs blob, *including every device profile with its full embedded
preset* — then re-encodes all 25 fields and writes to `UserDefaults`. It is
called from `finishFilterMutation()`, which `setGain` calls on every drag frame,
and from `setPreampDB`, which the menu-bar scroll handler calls every 55 ms.

**Fix:** coalesce writes behind a debounce, and stop the load-modify-save
round-trip — write only the keys that changed.

### 2.6 Two writers for the same persisted state
`PresetStore` owns favorites / recents / device profiles under dedicated keys and
mirrors them into `AppPreferences` (`syncStoreStateToPreferences`, `:1156`).
`EQViewModel.persist()` writes the same four fields back from the other side
(`:862-867`). Interleave a store mutation with a viewmodel persist and one
silently clobbers the other. Pick one owner — the store — and delete the mirror.

### 2.7 A/B compare is not level-matched, so it's biased
`setBypassed(true)` sets `eq.bypass` and `limiter.bypass` (`AudioEngine.swift:547-554`),
which drops `globalGain` — the preamp — along with the EQ. Preamps are almost
always negative (auto-headroom makes them so). The "dry" side of your A/B is
therefore several dB *louder* than the wet side. Louder always sounds better.
The comparison button systematically argues that EQ off is better.

**Fix:** keep a compensating gain applied on the bypass path so both sides match
in level. This is a two-line fix for a feature that is currently misleading.

### 2.8 Latency is unknown, undisplayed, and uncontrolled
The path is tap → 0.5 s-capacity ring → source node → EQ → `AUPeakLimiter`
(7 ms attack) → output. Steady-state delay is whatever backlog happens to
accumulate; `discardStaleOnRead` only trims after an overrun. Nothing measures
it, nothing shows it, nothing lets you trade it against safety. For a
*system-wide* EQ this means every video the user watches is out of lip sync by an
amount nobody can see or change. This is the most-felt unaddressed behavior in
the app.

### 2.9 Any output format notification triggers a full tap + aggregate rebuild
`handleOutputFormatChange` → `scheduleRestart(0.12)` (`AudioEngine.swift:701`),
which tears down the tap, destroys the aggregate device, and rebuilds — including
the 1.5 s sleep from §2.1. Sample-rate changes are routine (track changes,
Bluetooth codec renegotiation). There is also no guard against the rebuild
provoking the next notification.

**Fix:** handle rate changes by reconfiguring the source-node format where
possible; only rebuild the tap when the device identity actually changes.

### 2.10 Per-frame no-op loop in the render path
`StereoProcessor.applyGainOnly` iterates every frame of every buffer even when
`gain == 1` and no ramp is pending — the common case, on every callback. Early-out
when `remainingRampFrames == 0 && currentGain == 1`.

### 2.11 Global scroll monitor for the whole system
`MenuBarController.installScrollMonitors` (`:317`) installs an
`addGlobalMonitorForEvents(matching: .scrollWheel)` and then filters by pointer
location. That is a callback for every scroll gesture anywhere on the Mac, for
the life of the process, to serve one interaction over a 22-pt button. Handle
`scrollWheel` on the status item's own button view instead.

### 2.12 The popover's SwiftUI tree is rebuilt on every open
`togglePopover` assigns a fresh `NSHostingController` each time (`MenuBarController.swift:102`).
Search text, scroll position, and every `@State` in the tree are discarded on
every open, and the whole hierarchy is re-instantiated. Build it once.

### 2.13 `restore()` forces `eqEnabled = false`, then a 0.3 s timer turns it on
`EQViewModel.swift:832` and `:137`. Audio is unprocessed for 300 ms after launch
and the published state briefly disagrees with the user's intent. Restore the
intended state directly.

### 2.14 Bare `b` keyboard shortcut inside a panel with a text field
`EQPopoverView.swift:175` binds bypass to `"b"` with no modifiers, in a view that
contains the headphone search field. Verify and give it a modifier.

### 2.15 Unchecked Core Audio return codes
`AudioObjectGetPropertyData` results are ignored for the PID→process translation
(`AudioEngine.swift:255`) and the nominal sample rate (`:301`). Both silently
fall back to defaults that change behavior (a failed translate means the app taps
*itself*).

### 2.16 `swift test` does not run on a Command Line Tools–only Mac
Verified on this machine: `xcode-select -p` → `/Library/Developer/CommandLineTools`,
and `swift test` fails with `no such module 'XCTest'`. The project explicitly
supports CLT-only builds (commit `7f5b7c5`) and the README tells contributors to
run `swift test`. CI hides this because `macos-15` runners have full Xcode.

**Fix:** migrate to swift-testing (`import Testing`), which ships with the
toolchain, or document the Xcode requirement for the test target honestly.

### 2.17 Toolchain and coverage gaps
- `swift-tools-version: 5.9` — no strict concurrency checking on a codebase built
  around `@unchecked Sendable` and `nonisolated(unsafe)` globals. Move to 6.0 and
  fix what it finds; this is exactly the class of code that checking is for.
- No test touches `AudioEngine`, `SpectrumAnalyzer`, or `EQCurveView` geometry.
  The two components most likely to break are the two with zero coverage.
- No `LICENSE` file, despite the README having a License section.

---

## 3. What should be deleted

Every one of these costs code, state, persistence fields, tests, and UI space,
and returns approximately nothing.

### 3.1 Mono fold-down and L/R balance — **delete**
macOS already ships both, system-wide: Accessibility → Audio → "Play stereo audio
as mono", and Sound → Balance. Reimplementing them buys zero differentiation and
costs two persisted fields, two engine setters, two packed atomic bits, two
Settings rows, and render-path branches.

### 3.2 Stereo width — **delete**
A mid/side gain with no perceptual model. At width > 1 it exaggerates and at
< 1 it collapses; neither is a thing a user can reason about. Crossfeed alone is
the defensible spatial feature and it has an actual justification.

Deleting §3.1 and §3.2 collapses `StereoProcessor` to a crossfeed stage plus the
restart ramp, and removes an entire Settings section.

### 3.3 The 10-band / 15-band switch — **delete, keep one**
Both modes are lossy projections of a parametric engine onto fixed ISO centers.
Nobody can hear the difference between 10 and 15 fixed-Q bands. The cost is real:
`tenBandGains` + `fifteenBandGains` + `graphicGainsByMode` + `resampleGraphicGains`
+ `rebuildGraphicDisplay` + its tests + a segmented control in the hero position
of the panel. Ship one graphic view and spend the space on real parametric
editing (§5.4).

### 3.4 Half the genre presets — **delete**
`Classical` is `[0,0,0,0,0,0,-1,-1,-1,-1]` at 0 dB preamp: a 1 dB shelf, i.e.
nothing. `Rock`, `Electronic`, `V-Shape`, `Treble Boost` are 1998 Winamp cargo
cult and mostly duplicate each other. Keep `Flat`, `Bass Boost`, `Vocal`,
`Podcast`, `Loudness` — the ones that map to a real listening situation.

### 3.5 The catalog's long tail — **curate down**
Measured: 6,808 entries backed by 6,016 files. **567 entries point at a file
another entry already uses** (aliases masquerading as distinct products) and
**108 bundled files are referenced by no entry at all.** The tail is 24 MB of
repo and a search space where the ~200 headphones people actually own compete
with thousands they don't.

Curate to a few hundred real, deduplicated models, keep import for everything
else, and consider fetching the long tail on demand rather than bundling it.

### 3.6 Reference targets as catalog rows — **move or delete**
17 rows that exist only to show an error when clicked
(`EQViewModel.applyCatalogEntry:296`). Either make them functional (§5.5) or take
them out of the results list.

### 3.7 Repo cruft
- Root `graph_names.txt` — verified byte-identical to
  `Sources/EQForMac/Resources/graph_names.txt` and referenced by nothing. Tracked
  in git. Delete.
- `NSMicrophoneUsageDescription` in `Info.plist` — the app never touches the
  microphone. `NSScreenCaptureDescription` is not a key macOS consults. Both are
  purpose strings for permissions that are never requested; the only person they
  affect is a security-conscious user reading the bundle and drawing the wrong
  conclusion.
- A local `dist/` holds a 38 MB `EQ-for-Mac-1.0.0.dmg` that the README says does
  not exist. Gitignored, but it's a claim/artifact mismatch.

---

## 4. What should be better (same features, done right)

### 4.1 The panel is a 500 × 700 wall
Header + banner + curve + 15 faders + preamp + presets + a 6,800-row catalog +
footer, all always visible, nothing progressive. The catalog — useful to the
subset of users who own a measured headphone — gets as much room as the
equalizer itself. Collapse the catalog behind a search affordance, make the curve
the hero, and let the panel be roughly half its current height at rest.

### 4.2 The curve and the faders are the same control, twice
Both edit the same gain array; together they consume ~316 pt of vertical space
for one piece of state. Promote the curve to the real editor (§5.4) and drop the
faders, or make them an alternate mode rather than a permanent second copy.

### 4.3 Overlay bands accumulate without visibility
`setGain` on a parametric preset appends `isUserOverlay` bands
(`EQViewModel.swift:201-231`). They're persisted, they never expire, and they
count toward the 64-slot cap — and the user has no way to see or clear them. Add
a "revert to source curve" affordance.

### 4.4 The spectrum is peak-per-bin with an ad-hoc dual-rate smoother
`publishLogBins` uses `vDSP_maxv` per bin with 0.45 attack / 0.12 release
coefficients that aren't time-normalized to the 33 ms tick. It looks fine and
it isn't a meter. If it's going to sit behind the curve permanently, make it
honest: RMS per bin, proper ballistics, and an optional dB scale that lines up
with the curve's own axis.

### 4.5 Errors are `NSAlert.runModal()` from a menu-bar app
Import failures and preset-save failures block the whole app with a modal
(`EQViewModel.swift:917`). Preset naming uses a modal `NSAlert` with an
`NSTextField` accessory. Inline the affordances in the panel.

### 4.6 `AppPreferences` is 25 fields of hand-written `Codable`
Three parallel lists (properties, `CodingKeys`, `init(from:)`, `encode(to:)`) plus
a hand-maintained memberwise init, for every setting. Adding one preference is
five edits. The legacy-key fallbacks are thoughtful but the shape is unmaintainable.

---

## 5. Where the enormous value is

Ranked by (value to the user) × (nobody else on macOS does this).

### 5.1 Per-app EQ — the moat
No free macOS EQ does this. Core Audio already supports it:
`CATapDescription(stereoMixdownOfProcesses:)`. "Podcast curve on Safari, flat on
Ableton, bass cut on Discord, and it just remembers" is the feature people switch
tools for. It requires §1 (own the filter graph, so N chains is cheap) and §2.4
(kill the global RT state, so N engines is possible). Everything else in this
document is polish next to this.

### 5.2 Latency budget you can see and choose
Measure the real end-to-end delay and put it in the panel: *"Latency: 21 ms"*,
with a Low / Balanced / Safe selector that sets the ring target. Nobody in this
category exposes it; everybody's users suffer from it silently. Cheap once the
ring buffer maintains a target fill rather than only trimming after overruns.

### 5.3 Auto-EQ: generate a correction from measurement + target
You already bundle thousands of measurements *and* 17 PEQdB reference targets,
and today the targets are dead ends. Let the user pick "HD 600 → Harman 2018,"
compute the correction offline in milliseconds, and show the source curve, the
target, and the delta on the same axes. This turns your most-inert asset into the
app's best feature, and it's the thing PEQdB Studio is *for*.

### 5.4 Real parametric editing on the curve
The engine is parametric; the UI insists it isn't. Drag a node horizontally for
frequency, scroll for Q, click empty canvas to add a filter, right-click to
delete, per-node filter-type picker, per-node solo/bypass. This is the line
between a toy and a tool, and §1 makes the visual feedback exact.

### 5.5 Export back to Equalizer APO text
You already parse the format. The inverse is ~20 lines and one "Copy filters"
button, and it makes the app a citizen of the ecosystem instead of a one-way
sink. Highest value-per-line-of-code item in this document.

### 5.6 Loudness compensation tied to system volume
Track the output device's volume and apply an equal-loudness (ISO 226) tilt so
quiet listening keeps its bass and air. Genuinely useful, genuinely rare, and
nearly free once you own the filter graph. This is what the `Loudness` preset is
pretending to be.

### 5.7 Auto-update
Build-from-source with no update mechanism means nearly every install goes
permanently stale. Sparkle + an appcast, opt-in, without abandoning the
source-install stance.

---

## 6. Sequenced plan

**Phase 1 — Stop the bleeding (days).** No new features.
§2.1 main-thread sleep · §2.5 persist storm · §2.7 level-matched A/B ·
§2.2/2.3 RT-thread ARC and buffer lifetime · §2.10 render no-op loop ·
§2.11 global scroll monitor · §2.12 hosting-controller rebuild · §2.16 tests
runnable on CLT-only · add a `LICENSE`.

**Phase 2 — Delete (days).**
§3.1–3.4 spatial extras, band-mode switch, dead presets · §3.7 repo cruft ·
§2.6 single persistence owner. Expect the codebase to get meaningfully smaller
and the panel to get shorter.

**Phase 3 — Own the DSP (1–2 weeks).**
§1 biquad cascade + one shared exact response function · §2.4 render-context
object replacing global RT state · §2.8/§5.2 latency measurement and target ·
§2.9 reconfigure instead of rebuild on rate change.

**Phase 4 — The features only this app can have.**
§5.4 real parametric curve · §5.5 APO export · §5.3 auto-EQ from target ·
§5.1 per-app EQ · §5.6 loudness compensation · §5.7 auto-update ·
§3.5 curated catalog.

---

## 7. Non-goals (unchanged, and still right)

Driver-free. Offline-first — no telemetry, no audio ever leaving the Mac.
Menu-bar-light, no Dock icon. Evolve the visual language rather than replacing it.

One addition: **no feature ships that the app cannot describe accurately.** A
"Safe" preamp that is a guess, an A/B that isn't level-matched, and a response
curve that doesn't match the audio are worse than not having them — they teach
the user to distrust the instrument.
