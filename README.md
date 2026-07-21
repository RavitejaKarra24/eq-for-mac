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
| **10- or 15-band graphic EQ** | Drag faders; changes apply live to system audio |
| **6,825 searchable graphs and targets** | 6,808 headphone entries plus 17 PEQdB Studio reference targets — no internet needed |
| **Import EQ files** | Equalizer APO / PEQdB / AutoEQ parametric `.txt` |
| **Genre presets** | Flat, Bass Boost, Treble Boost, V-Shape, Vocal, Podcast, … |
| **On / Off** | Bypass processing instantly without quitting |
| **Menu bar only** | Status item + popover; right-click or footer to quit |

---

## Requirements

- macOS **14.2** or newer (Core Audio Process Taps)
- **Screen & System Audio Recording** permission (macOS groups system-audio taps under this privacy setting)

---

## Install

### Download the app

1. Download **[EQ for Mac.dmg](https://github.com/RavitejaKarra24/eq-for-mac/releases/latest/download/EQ-for-Mac.dmg)** from the latest release.
2. Open the DMG and drag **EQ for Mac** into **Applications**.
3. Try to open EQ for Mac. macOS will block this free, non-notarized build the first time.
4. Open **System Settings → Privacy & Security**, scroll to Security, click **Open Anyway**, authenticate, and confirm.
5. Allow **Screen & System Audio Recording** when prompted. The app appears in the menu bar rather than the Dock.

The downloadable app is universal (Apple Silicon and Intel) and ad-hoc signed.
It is intentionally not Apple-notarized because this project does not pay the
annual Apple Developer Program fee. Read the
**[illustrated installation guide](https://eq-for-mac.warriors-8531.chatgpt.site/install)**
before approving the first launch.

Only bypass an expected “developer cannot be verified” or “Apple cannot check
it” warning for a DMG downloaded from this repository. Do **not** bypass an alert
that says the app will damage your Mac or contains malware.

### Homebrew

This repository can also be used as a Homebrew tap:

```bash
brew tap ravitejakarra24/eq-for-mac https://github.com/RavitejaKarra24/eq-for-mac
brew install --cask eq-for-mac
```

Upgrade later with `brew upgrade --cask eq-for-mac`.

The Cask installs the same checksummed DMG and preserves Gatekeeper protection,
so complete the same **Open Anyway** step before the first launch.

### Build from source

The complete source and offline EQ data remain in this repository. Building from
source requires the Xcode Command Line Tools (`xcode-select --install`) and
installs a normal ad-hoc-signed app in `~/Applications`.

```bash
git clone https://github.com/RavitejaKarra24/eq-for-mac.git
cd eq_for_mac
./install.sh
open ~/Applications/EQ\ for\ Mac.app
```

`install.sh` runs a **release** Swift build, wraps the binary in `EQ for Mac.app`, ad-hoc codesigns it, and installs to `~/Applications`.

### Run without installing

```bash
swift run
```

### Permission

On first enable, macOS may ask for **Screen & System Audio Recording**.

If audio stays silent or EQ never starts:

1. **System Settings → Privacy & Security → Screen & System Audio Recording**
2. Enable **EQ for Mac**
3. Toggle EQ off and on again in the panel

If **Open Anyway** still does not appear, first verify the release checksum. As
an advanced fallback, remove quarantine only from the exact app bundle:

```bash
xattr -dr com.apple.quarantine "/Applications/EQ for Mac.app"
open "/Applications/EQ for Mac.app"
```

Never disable Gatekeeper globally. Work- or school-managed Macs may prohibit
per-app exceptions.

## How to use

| Action | How |
|--------|-----|
| Open panel | **Left-click** the menu bar slider icon |
| Quit | **Right-click** the icon → **Quit EQ for Mac**, or use the panel footer / **⌘Q** |
| Enable EQ | Flip the **System EQ** switch |
| 10 vs 15 bands | Segmented control at the top of the panel |
| Genre presets | Chips under the faders (Bass Boost, Vocal, …) |
| Headphones | Search graphs → click a model |
| Custom curve | **Import EQ file…** |
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
                                      ▼
                                 Ring buffer
                                      │
                                      ▼
                            AVAudioSourceNode
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
eq_for_mac/
├── .github/workflows/           # CI + ad-hoc-signed tagged releases
├── Casks/eq-for-mac.rb          # Homebrew Cask
├── Package.swift                 # SwiftPM package
├── install.sh                    # Release build → ~/Applications/EQ for Mac.app
├── README.md
├── docs/DISTRIBUTION.md          # Maintainer release setup and checklist
├── docs/images/                  # Screenshots for this README
├── scripts/package.sh            # Universal app + DMG packaging
├── scripts/                      # Offline catalog fill / backfill tools
└── Sources/EQForMac/
    ├── AppDelegate.swift         # Menu-bar app entry
    ├── MenuBarController.swift   # Status item, popover, quit
    ├── EQPopoverView.swift       # SwiftUI panel
    ├── EQViewModel.swift         # State + presets bridge
    ├── AudioEngine.swift         # CATap + AVAudioEngine EQ
    ├── AudioRingBuffer.swift
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
# or reinstall the app bundle:
./install.sh && open ~/Applications/EQ\ for\ Mac.app
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

---

## Limitations

- Requires macOS **14.2+** (no fallback virtual driver in this project).
- Some DRM / protected paths may behave differently depending on OS version and app.
- Bluetooth devices can glitch briefly when switching outputs; the engine reconnects automatically.
- Source and public release builds are ad-hoc signed and are not Apple-notarized.
- macOS may request Gatekeeper or System Audio Recording approval again after an update.

---

## Releasing

Maintainers can publish a release by pushing a semantic version tag such as
`v1.0.0`. No Apple certificate or notarization credentials are required. See
[the distribution guide](docs/DISTRIBUTION.md) for the full zero-fee release flow.

---

## Credits

- **[Sharur](https://www.youtube.com/@Sharur)** and **[PEQdB](https://peqdb.com)** — inspiration for headphone graph EQ workflows.
- **[AutoEq](https://github.com/jaakkopasanen/AutoEq)** — parametric EQ data and tooling.
- Squiglink / measurement communities — FR data used where applicable.

---

## License

App source in this repository: free to use, modify, and share for personal and community projects.

Bundled EQ curves are derived from [AutoEq](https://github.com/jaakkopasanen/AutoEq), Squiglink, and [PEQdB](https://peqdb.com/studio/) measurements — respect those projects’ credits and terms when redistributing curves.
