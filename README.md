# EQ for Mac

A **menu-bar** system-wide equalizer for macOS. Once EQ is on, it shapes **all** audio leaving your Mac — browser, Spotify, Apple Music, YouTube Music, video players, games, notifications — everything.

No virtual audio driver required. Uses **Core Audio Taps** (macOS 14.2+).

Thank you to [Sharur](https://www.youtube.com/@Sharur) and [PEQdB](https://peqdb.com) for the inspiration to take on a project like this.

---

## Screenshots

### Menu bar panel

![EQ for Mac floating over the desktop](docs/images/menu-bar-overview.jpg)

*Lives in the menu bar — no Dock icon, no full-window app.*

### 15-band EQ + headphone search

<img src="docs/images/eq-panel-headphone-search.png" alt="15-band graphic EQ with headphone graph search" width="450" />

*Drag faders, apply genre presets, or search ~6,800 offline headphone curves.*

### Offline catalog & import

<img src="docs/images/headphone-catalog.png" alt="Headphone catalog list with Import EQ file" width="450" />

*Browse the full offline catalog or import your own Equalizer APO / PEQdB / AutoEQ `.txt` file.*

---

## Features

| Feature | Description |
|--------|-------------|
| **Live spectrum + interactive curve** | See the signal, drag response points directly, hover for Hz/dB, or double-click a point to reset |
| **10- or 15-band graphic EQ** | Faders stay synchronized with the curve; full parametric filters are preserved while editing |
| **6,825 searchable graphs and targets** | 6,808 headphone entries plus 17 PEQdB Studio reference targets — no internet needed |
| **Fuzzy search, pins, and recents** | Forgiving compact-model search with favorite and recently applied headphone sections |
| **Import EQ files** | Equalizer APO / PEQdB / AutoEQ parametric `.txt` |
| **Built-in and personal presets** | Save, favorite, rename, reorder, and delete your own curves |
| **Clip-safe auto-preamp** | Estimates the combined response and reserves headroom automatically or on demand |
| **Instant A/B** | Toggle bypass, or hold A/B to hear dry audio and release to resume processing |
| **Per-output profiles** | Remember a full EQ snapshot for an output device and restore it when that device becomes active |
| **Spatial controls** | Optional crossfeed, stereo width, L/R balance, and mono fold-down |
| **Menu-bar power tools** | Global ⌥⌘E toggle, option-click quick controls, scroll-to-adjust preamp, and Settings |
| **Guided permission setup** | Explains the macOS system-audio permission, opens the correct pane, and confirms it with a real engine probe |

---

## Requirements

- macOS **14.2** or newer (Core Audio Process Taps)
- **Screen & System Audio Recording** permission (macOS groups system-audio taps under this privacy setting)

---

## Install from source

EQ for Mac intentionally ships without a DMG, Homebrew Cask, or other prebuilt
binary. Clone the source, inspect it if you want, and build the app locally with
Apple's free Xcode Command Line Tools. No Apple ID, paid developer account,
notarization, or administrator access is required.

### One-time setup

Install the free command-line tools if they are not already present:

```bash
xcode-select --install
```

Then clone, build, install, and launch:

```bash
git clone https://github.com/RavitejaKarra24/eq-for-mac.git
cd eq-for-mac
./install.sh
```

If you have already cloned the repository and are inside it, the only command you
need is:

```bash
./install.sh
```

The installer:

1. builds a release binary from the checked-out source;
2. creates and ad-hoc signs `EQ for Mac.app` locally;
3. installs it at `~/Applications/EQ for Mac.app`;
4. removes quarantine metadata only from that locally built app; and
5. opens it.

It does not disable Gatekeeper or change any system-wide security setting.
Because the installed bundle stays at the same path, normal future launches do
not require rebuilding or repeating the installation commands.

### Required audio permission

The panel presents a guided setup before asking for **Screen & System Audio
Recording**. This permission is required by Core Audio Process Taps and cannot
be granted by a shell script.

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. Enable **EQ for Mac**.
3. Toggle the EQ off and on again.

The app processes audio locally and does not save or upload it.

### Launch later

```bash
open "$HOME/Applications/EQ for Mac.app"
```

### Update

From the cloned project directory:

```bash
git pull --ff-only
./install.sh
```

### Uninstall

```bash
pkill -x EQForMac 2>/dev/null || true
rm -rf "$HOME/Applications/EQ for Mac.app"
```

## How to use

| Action | How |
|--------|-----|
| Open panel | **Left-click** the menu bar slider icon |
| Quick controls | **Option-click** the icon |
| Adjust preamp without opening | **Scroll** over the menu bar icon |
| Quit | **Right-click** the icon → **Quit EQ for Mac**, or use the panel footer / **⌘Q** |
| Enable EQ | Flip the **System EQ** switch |
| Toggle from any app | Press **⌥⌘E** after enabling the global shortcut in Settings |
| Hear dry audio | Click **Bypass**, or press and hold **A/B** |
| Shape the curve | Drag a point vertically; double-click it to reset; faders remain available below |
| 10 vs 15 bands | Segmented control at the top of the panel |
| Automatic headroom | Enable **Auto headroom**, or click **Match** beside the safe preamp value |
| Save a preset | **Save current** above the preset chips; right-click a saved chip to manage it |
| Headphones | Search graphs → click a model |
| Pin a headphone | Click the star at the right of its row |
| Custom curve | **Import EQ file…** |
| Remember an output | **Settings → Output profile → Remember EQ for this output** |
| Crossfeed / width / balance / mono | **Settings → Headphone spatial controls** |
| Reset | **Reset** (flat / 0 dB) |

---

## Offline data

Everything needed to run ships in the repo:

| Asset | Notes |
|--------|--------|
| `Sources/EQForMac/Resources/autoeq/*.txt` | ~6,015 parametric EQ curves |
| `Sources/EQForMac/Resources/headphones_catalog.json` | Headphone search index (~6,808 entries) |
| `Sources/EQForMac/Resources/graph_names.txt` | PEQdB-style graph and target name list |
| `Sources/EQForMac/Resources/target_curves.json` | 17 categorized PEQdB Studio reference targets and search aliases |
| `Sources/EQForMac/Resources/AppIcon.icns` | Multi-resolution macOS application icon |
| Installed app | Typically **~20–25 MB** on disk after `./install.sh` |

No network is required to search or apply a bundled preset.

### Measurement / curve sources

1. **[AutoEq](https://github.com/jaakkopasanen/AutoEq)** — published parametric EQ files (primary)
2. **[Squiglink](https://squig.link)** network — public FR files converted offline to Harman-target PEQ (`scripts/fill_from_squig.py`)
3. **[PEQdB Studio](https://peqdb.com/studio/)** — public graph index / archive (`scripts/fill_from_peqdb_archive.py`)
4. **[graph.hangout.audio](https://graph.hangout.audio)** (Crinacle) — via PEQdB’s public archive where applicable

Reference targets are searchable for discovery, but are deliberately not applied as standalone EQ presets: a target must be paired with a compatible headphone measurement and measurement rig.

Equalizer APO / AutoEQ / PEQdB text format example:

```text
Preamp: -6.3 dB
Filter 1: ON LSC Fc 105 Hz Gain 6.3 dB Q 0.70
Filter 2: ON PK Fc 169 Hz Gain -2.1 dB Q 0.77
…
```

---

## Architecture (short)

```text
App audio ──► (muted) CATap ──► Aggregate device IOProc
                                      │
                       ┌──────────────┴──────────────┐
                       ▼                             ▼
                  Ring buffer                 Spectrum queue
                       │                       (Hann + vDSP FFT)
                       ▼
              AVAudioSourceNode
                       │
                       ▼
        Crossfeed / width / balance / mono
                       │
                       ▼
                 AVAudioUnitEQ
                       │
                       ▼
                  Peak limiter
                       │
                       ▼
                  Output device
```

The tap mutes the direct path to the speakers so you only hear the processed stream. The EQ process is excluded from the tap so the engine does not silence itself.

---

## Project layout

```text
eq-for-mac/
├── .github/workflows/ci.yml      # Tests, builds, and validates the app
├── Package.swift                 # SwiftPM package
├── Tests/EQForMacTests/          # Parser, models, headroom, preset, and ring-buffer tests
├── install.sh                    # Build, install to ~/Applications, and launch
├── README.md
├── docs/images/                  # Screenshots for this README
├── scripts/build-app.sh          # Assemble and ad-hoc sign the local app bundle
├── scripts/package-dmg.sh        # Optional Developer ID + notarized DMG path
├── scripts/                      # Offline catalog fill / backfill tools
└── Sources/EQForMac/
    ├── AppDelegate.swift         # Menu-bar app entry
    ├── MenuBarController.swift   # Status item, popover, quit
    ├── EQPopoverView.swift       # SwiftUI panel
    ├── EQCurveView.swift         # Interactive response + spectrum surface
    ├── EQViewModel.swift         # State + presets bridge
    ├── AudioEngine.swift         # CATap + AVAudioEngine EQ
    ├── AudioRingBuffer.swift
    ├── SpectrumAnalyzer.swift    # Off-render-thread vDSP FFT
    ├── StereoProcessor.swift     # Crossfeed / width / balance / mono + ramps
    ├── EQHeadroomCalculator.swift
    ├── SettingsView.swift
    ├── LoginItem.swift
    ├── HotKeyManager.swift
    ├── CoreAudioHelpers.swift
    ├── EQModels.swift
    ├── EqualizerAPOParser.swift  # AutoEQ / PEQdB text parser
    ├── PresetStore.swift
    ├── VerticalSlider.swift
    ├── Info.plist
    └── Resources/                # Catalog + bundled .txt curves
```

---

## Develop / customize

Clone, edit Swift under `Sources/EQForMac/`, then:

```bash
swift build
swift test
# or rebuild, reinstall, and launch the app bundle:
./install.sh
```

Useful starting points:

| Want to… | Look at |
|----------|---------|
| Change UI layout / labels | `EQPopoverView.swift` |
| Add genre presets | `EQModels.swift` / `EQViewModel.swift` |
| Audio pipeline / latency | `AudioEngine.swift` |
| Parse more EQ file formats | `EqualizerAPOParser.swift` |
| Catalog loading | `PresetStore.swift` |

Regenerating the offline catalog (optional, for maintainers) needs Python + the AutoEq library; see comments in `scripts/`.

### Optional signed DMG (maintainers)

The default source-install path remains ad-hoc signed. Maintainers with a
Developer ID Application certificate can also create a hardened-runtime DMG:

```bash
VERSION=1.2.3 \
BUILD_NUMBER=123 \
CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
scripts/package-dmg.sh
```

To notarize and staple it, first store App Store Connect credentials with
`notarytool store-credentials`, then add `NOTARY_PROFILE`:

```bash
VERSION=1.2.3 \
BUILD_NUMBER=123 \
CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE="eq-for-mac-notary" \
scripts/package-dmg.sh
```

The script verifies the app signature, creates a compressed DMG with an
Applications shortcut, optionally notarizes/staples it, and prints its SHA-256.
Certificates and notarization credentials are intentionally never stored in the
repository.

---

## Limitations

- Requires macOS **14.2+** (no fallback virtual driver in this project).
- Some DRM / protected paths may behave differently depending on OS version and app.
- Bluetooth/output changes are faded and debounced, but hardware reconnection
  can still produce a short gap.
- The app is built and ad-hoc signed on each user's Mac; there are no prebuilt
  downloads or automatic updates.
- Launch at login uses `SMAppService` and must be exercised from the installed
  application bundle. macOS can require approval under **General → Login Items**;
  raw `swift run` executables cannot register.
- EQ is currently system-wide. Independent per-app taps/profiles remain an
  advanced future engine mode.
- The initial install requires System Audio Recording permission. macOS may ask
  again after a materially changed rebuild, but not on ordinary launches.

---

## Credits

- **[Sharur](https://www.youtube.com/@Sharur)** and **[PEQdB](https://peqdb.com)** — inspiration for headphone graph EQ workflows.
- **[AutoEq](https://github.com/jaakkopasanen/AutoEq)** — parametric EQ data and tooling.
- Squiglink / measurement communities — FR data used where applicable.

---

## License

App source in this repository: free to use, modify, and share for personal and community projects.

Bundled EQ curves are derived from [AutoEq](https://github.com/jaakkopasanen/AutoEq), Squiglink, and [PEQdB](https://peqdb.com/studio/) measurements — respect those projects’ credits and terms when redistributing curves.
