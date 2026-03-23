# OpenDisplay

[中文说明](README_CN.md)

Lightweight macOS menu bar tool for multi-display management. Built entirely through agentic coding with Claude Code.

## Features

- **HiDPI for non-4K displays** — Enable HiDPI (Retina rendering) on 2K/1440p external monitors. Instant, no logout required.
- **Resolution & refresh rate switching** — Full mode list including HiDPI modes.
- **Display on/off** — Disable external displays without unplugging. Auto-restores on quit.
- **Set main display** — Promote any display to primary with one click.
- **Auto-restore** — Remembers HiDPI state and resolution per display. Auto-restores on reconnect and app launch.
- **Launch at login** — Native macOS login item support.

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


## Privacy

- No network requests
- No data collection or telemetry
- No sensitive data stored (only display vendor/product IDs and mode numbers in UserDefaults)
- No special permissions required

## Disclaimer

This software is provided as-is, without warranty of any kind. It has not been exhaustively tested across all hardware configurations. Use at your own risk — the authors are not responsible for any issues that may arise.

## License

MIT
