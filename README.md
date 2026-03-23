# OpenDisplay

[中文说明](README_CN.md)

Lightweight macOS menu bar tool for multi-display management. Built entirely through agentic coding with Claude Code.

## Features

- **HiDPI for non-4K displays** — Enable HiDPI (Retina rendering) on 2K/1440p external monitors via virtual display + mirroring. Instant, no logout required.
- **Resolution & refresh rate switching** — Full mode list including HiDPI modes, via CGS private API (works on macOS 26 where public API no longer exposes HiDPI modes).
- **Display on/off** — Disable external displays without unplugging. Auto-restores on quit.
- **Set main display** — Promote any display to primary with one click.
- **Auto-restore** — Remembers HiDPI state and resolution per display. Auto-restores on reconnect and app launch.
- **Launch at login** — Via SMAppService.

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon Mac

## Build

```bash
make          # build
make install  # install to /Applications
make run      # build and run
make clean    # clean build
```

## How it works

**HiDPI**: Creates a high-resolution virtual display (CGVirtualDisplay private API) and mirrors the physical display to it. macOS renders at 2x resolution on the virtual display, then scales down to the physical display. This gives Retina-quality text on non-Retina screens.

**Mode switching**: Uses `CGSGetNumberOfDisplayModes` / `CGSConfigureDisplayMode` private APIs to enumerate and switch display modes, including HiDPI variants that `CGDisplayCopyAllDisplayModes` no longer returns on macOS 26.

**Display control**: Uses `CGDisplayCapture` / `CGDisplayRelease` public APIs to enable/disable displays.

## Privacy

- No network requests
- No data collection or telemetry
- No sensitive data stored (only display vendor/product IDs and mode numbers in UserDefaults)
- No special permissions required

## License

MIT
