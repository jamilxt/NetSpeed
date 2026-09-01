# NetSpeed

Live download/upload speed in your macOS menu bar.

<p align="center"><code>&nbsp;↓ 2.41 MB/s&nbsp; ↑ 184 KB/s&nbsp;</code></p>

A single-file Swift app with no dependencies and no Xcode project — just `swiftc` and a shell script. Runs entirely locally, uses no private APIs, and needs no permissions.

<!-- TODO: add a menu bar screenshot here -->

## Features

- Live **download + upload speed**, refreshed every 1–2 seconds
- Monospaced digits so the text doesn't jitter
- Click the menu bar item for:
  - Current speeds + total transferred this session
  - **Show as bits (Mbps)** — bytes/s ↔ bits/s toggle (persisted)
  - **Pause / Resume updates**
  - **Launch at Login** (Login Items, macOS 13+)
  - Quit (⌘Q)

## Requirements

- macOS 13 or later
- Xcode Command Line Tools to build: `xcode-select --install`

## Install

### Download

Grab `NetSpeed.zip` from the [latest release](../../releases), unzip, and launch. The app is unsigned, so the first time macOS will ask you to confirm: right-click the app → **Open**.

### Build from source

```bash
git clone https://github.com/jamilxt/NetSpeed.git
cd NetSpeed
./build.sh
open build/NetSpeed.app
```

To keep it around permanently, copy it to `/Applications` and enable **Launch at Login** from the app's menu:

```bash
cp -R build/NetSpeed.app /Applications/
```

## How it works

At launch the app runs a one-time calibration: it downloads a small probe file
(≤3 MB from speed.cloudflare.com, capped at 5 s) and checks whether the
interface byte counters actually saw those bytes. Based on that:

- **Interface-counter mode (1 s updates).** The normal case. Every second it
  sums 64-bit per-interface byte counters from `sysctl(NET_RT_IFLIST2)` — the
  same source `netstat -ib` uses — and divides the delta by the elapsed time.
- **Socket-statistics mode (~2 s updates).** On machines where interface
  counters misreport (some virtual Macs, userspace-proxy setups), it instead
  polls `nettop -l 1 -P` about twice a second and shows deltas of the total
  per-process `bytes_in` / `bytes_out` — the same source Activity Monitor's
  Network panel uses.

Notes:

- It measures **traffic**, not a speed test — all TCP/UDP traffic counts,
  including local/proxied traffic.
- The app is `LSUIElement` (menu-bar only, no Dock icon).

## Why not just `getifaddrs()`?

On current macOS, `getifaddrs()` exposes only 32-bit per-interface counters
(`struct if_data`) that wrap every ~4 GB, and on some machines inbound bytes
are never accounted at the interface layer at all — during development, a 30 MB
download moved zero counters there, on a fully unsandboxed connection. The
`sysctl` route counters and nettop's socket statistics are the reliable
sources, and the app verifies which one to trust instead of guessing.

## Contributing

Bug reports and pull requests are welcome. Some ideas: an app icon, a Homebrew
cask, per-interface filtering, a history graph dropdown.

## License

[MIT](LICENSE) © 2026 jamilxt
