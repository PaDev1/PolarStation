# PolarStation

A macOS application for telescope control, astrophotography, and polar alignment.

> **Hobby project** — This software is provided as-is, with no warranty. Use at your own risk. The author assumes no responsibility for any damage to equipment or data loss resulting from use of this software. SW is in alpha state, but has been used successfully for deepsky astrophotography. Not every feature has been tested so expect bugs.

## Features

- **Polar Alignment** — Plate-solving assisted polar alignment workflow with simulated alignment mode for practice
- **Framing & Sky Map** — Interactive sky map with stereographic projection, DSS2 sky imagery tiles, deep-sky catalog (~14,000 objects from OpenNGC), altitude/visibility planning, and observation window filtering
- **Camera Control** — Live preview with configurable Bayer debayer (RGGB/BGGR/GRBG/GBRG), STF auto-stretch (Midtone Transfer Function), frame capture to FITS/TIFF with plate-solved RA/Dec coordinates (OBJCTRA/OBJCTDEC) written to the header when available, sensor cooling control, and star detection via CoreML and classical background-subtraction with sub-pixel centroid refinement
- **Autoguiding** — Guide camera control with calibration, guide loop, dithering, and guide graph
- **Sequencer** — Visual sequence builder with containers, conditions, triggers, and 30+ instruction types covering all connected devices. AI-assisted sequence building via the assistant
- **AI Assistant** — LLM-powered assistant with tool use for mount control, sky information, weather, catalog search, and device commands
- **Full ASCOM/Alpaca Support** — All 10 standard device types: Camera, Mount, Focuser, Filter Wheel, Rotator, Dome, Switch, Safety Monitor, Cover Calibrator, Observing Conditions
- **ZWO ASI Cameras** — Native USB support for ZWO ASI cameras via the ASI SDK
- **Mount Protocols** — LX200 (serial & TCP) and ASCOM Alpaca

## Architecture

```
PolarStation
├── polar-core/           # Rust core library (plate solving, mount protocols, Alpaca clients)
│   └── UniFFI bindings   # Auto-generated Swift bindings
├── PolarCore/            # Swift package wrapping the Rust static library
├── PolarAligner/         # Xcode project (historically named PolarAligner)
│   └── PolarAligner/     # Swift source
│       ├── App/          # AppState, entry point
│       ├── Views/        # SwiftUI views, sky map, settings
│       ├── Camera/       # Camera & filter wheel control
│       ├── Pipeline/     # Metal shaders (debayer, stretch, DSS)
│       ├── Devices/      # Alpaca device ViewModels
│       ├── Sequencer/    # Sequence engine, executors, UI
│       ├── Assistant/    # AI assistant with LLM tool use (Claude/OpenAI)
│       ├── Guiding/      # Autoguider
│       ├── Alignment/    # Polar alignment engine
│       └── Services/     # Mount, plate solve, weather, DSS tiles
├── StarDetector-Mac/     # CoreML star detection model project
└── build.sh              # Complete build script
```

> **Note:** The Xcode project is named `PolarAligner` for historical reasons. The app builds and runs as **PolarStation**.

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1 or later)
- 16 GB RAM or more
- Xcode 15+ (for building from source)
- Rust toolchain (`rustup`, stable, for building from source)

## Building

```bash
# Install Rust if needed
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Clone and build
git clone <repo-url>
cd PolarStation
./build.sh
```

The build script:
1. Builds the Rust core library (`polar-core`)
2. Generates UniFFI Swift bindings
3. Copies artifacts to the PolarCore Swift package
4. Builds the Xcode project

The built app is located in Xcode's DerivedData directory.

## Third-Party Dependencies

### Rust (polar-core)
| Crate | License | Purpose |
|-------|---------|---------|
| [uniffi](https://github.com/mozilla/uniffi-rs) | MPL-2.0 | Swift/Rust bindings generator |
| [tetra3](https://crates.io/crates/tetra3) | MIT/Apache-2.0 | Star pattern plate solver |
| [nalgebra](https://github.com/dimforge/nalgebra) | Apache-2.0 | Linear algebra |
| [ureq](https://github.com/algesten/ureq) | MIT/Apache-2.0 | HTTP client (Alpaca API) |
| [serialport](https://crates.io/crates/serialport) | MPL-2.0 | Serial port (LX200) |
| [thiserror](https://crates.io/crates/thiserror) | MIT/Apache-2.0 | Error handling |

### Swift
| Package | License | Purpose |
|---------|---------|---------|
| [SwiftAA](https://github.com/onekiloparsec/SwiftAA) | MIT | Astronomical algorithms |

### Bundled SDKs
| SDK | License | Purpose |
|-----|---------|---------|
| [ZWO ASI Camera SDK](https://www.zwoastro.com/software/) | Proprietary (freely distributed) | ZWO ASI USB camera support |

### Sky Imagery

Sky map tiles are loaded on-demand from the [STScI Digitized Sky Survey](https://archive.stsci.edu/dss/) (DSS2) archive — not bundled with the app. Tiles are cached locally for offline use. The Digitized Sky Surveys were produced at the Space Telescope Science Institute under U.S. Government grant NAG W-2166. Images based on photographic data from the UK Schmidt Telescope and Palomar Observatory.

### Object Catalogs (bundled)

| Catalog | Entries | Content |
|---------|---------|---------|
| [OpenNGC](https://github.com/mattiaverga/OpenNGC) | ~13,900 | NGC and IC deep-sky objects (CC BY-SA 4.0) |
| OpenNGC addendum | ~60 | Barnard, Caldwell, Sharpless, and other notable objects |
| Named Stars | ~460 | Bright stars with common names |

## Plate Solving

PolarStation uses two plate solving backends:

### Local solver (default)

Built-in [tetra3](https://crates.io/crates/tetra3) geometric hash solver compiled into the app via the Rust core. Solves in under a second when stars are detected.

A star catalog database is required and is **not bundled** — generate it from within the app:

1. Open **Settings → Star Catalog**
2. Choose a star density (mag≤8 ~480 MB, mag≤9 ~1.5 GB, mag≤10 ~4 GB, mag≤11 ~8 GB)
3. Click **Download & Generate** — the app downloads Gaia DR3 data from ESA and builds the pattern database

The catalog is stored in `~/Library/Application Support/PolarStation/` and persists across app updates. mag≤11 achieves the highest solve rate; mag≤9 is a reasonable default for most setups. Once generated, load it with the **Load** button.

### Remote / local server solver (optional fallback)

PolarStation supports the [Astrometry.net REST API](https://astrometry.net/doc/net/api.html) as a fallback when the local solver fails. This works with:

- **nova.astrometry.net** — free cloud service, requires an account and API key. Solves are typically 30–120 seconds depending on server load. Sign up at [nova.astrometry.net](https://nova.astrometry.net) and find your API key in My Profile.
- **Watney (local server)** — run the same API locally on your Mac with no internet required.

#### Running Watney locally

[Watney](https://github.com/Jusas/WatneyAstrometry) is a .NET-based plate solver that exposes the Astrometry.net-compatible REST API on `localhost`. A macOS binary is available on its releases page.

1. Download the macOS release from [github.com/Jusas/WatneyAstrometry/releases](https://github.com/Jusas/WatneyAstrometry/releases)
2. Download the Watney quad database (star catalog for Watney — separate download, a few GB)
3. Edit `config.yml` to point at the catalog and set the HTTP port (default `8080`)
4. Start Watney: `./watney-solve-api`
5. In PolarStation → Settings → Plate Solving: enable **Use local server**, set URL to `http://localhost:8080/api`

No API key is needed for Watney. Solves are fast (seconds) since everything runs locally.

## License

MIT License — see [LICENSE](LICENSE) for details.
