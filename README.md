# Zento

A keyboard-driven launcher for Wayland, in the spirit of [Raycast](https://www.raycast.com/) — built from scratch in **Zig** as a project for learning the language and Linux systems programming.

> **This is a learning project.** The goal isn't to compete with Raycast or fuzzel; it's to understand, end to end, how a desktop launcher actually works — Wayland protocols, software rendering, font rasterization, D-Bus, and native binary-format parsing — while picking up Zig 0.16 (coming from Go). The code carries Go-comparison comments throughout.

## What it does

A floating overlay window: start typing, results rank as you go, hit Enter to act. The features are the Raycast bits that get used dozens of times a day:

| Feature | What you type | Notes |
|---|---|---|
| **App launcher** | `firef…` | Fuzzy-matches `.desktop` files across XDG dirs, launches on Enter |
| **Calculator** | `12 * (3 + 4)` | Inline arithmetic (`+ - * / %`), result shown instantly |
| **Unit conversion** | `32F to C`, `100 MB in KB` | Temperature (F↔C) and data units (B/KB/MB/GB/TB) |
| **Dictionary** | `dw serendipity` | Native StarDict lookup; Enter expands the full definition |
| **System / power** | `suspend`, `reboot`, `shutdown` | Issued over D-Bus to `systemd-logind` (no subprocess spawn) |

Two extras that make it feel fast:

- **Frecency ranking** — frequently launched apps and commands float to the top (usage is tracked and persisted between runs).
- **Modes** — typing `dw ` switches into a dictionary mode with its own prefix; `Esc` steps back out (and closes from the top level).

## How it works (the systems-programming part)

No toolkit — everything is talked to directly, the way `fuzzel` and `foot` do it:

- **Wayland client** via [`zig-wayland`](https://codeberg.org/ifreund/zig-wayland) over the **wlr-layer-shell** protocol for the overlay surface.
- **Software rendering** into an `mmap`'d shared-memory buffer (`memfd` + `wl_shm`) with **pixman**.
- **Font rasterization** with **fcft** (glyph → pixman image, composited per-codepoint), HiDPI-aware via `wl_surface.enter` scale detection.
- **Keyboard input** through raw `wl_keyboard` + **xkbcommon**, with a UTF-8 cursor-aware input buffer.
- **D-Bus** to `org.freedesktop.login1` via **libsystemd**'s sd-bus, through Zig's C interop (`@cImport`).
- **StarDict** dictionaries parsed natively in Zig (`.ifo`/`.idx`/`.dict`) — binary index, positional reads, no shelling out to `sdcv`.

### Architecture

```
wayland.zig    Wayland event loop, keyboard input, rendering orchestration
  └─ render.zig    pixman + fcft drawing (no Wayland knowledge)
  └─ dispatcher.zig  owns the pipeline: builds handlers, runs/ranks candidates, modes
       └─ handler.zig   the handler interface (a comptime-generated vtable)
       └─ calc / convert / dict / systemd / apps   the handlers
  └─ history.zig   frecency tracking, persisted to the cache dir
```

Each handler is a small struct exposing `suggest`/`load`/`execute`/`expand`; the dispatcher type-erases them behind a uniform `Handler` (the interface is hand-built, since Zig has none) and collects + ranks their candidates every keystroke.

## Building

Requires **Zig 0.16** and a Wayland session with a compositor that supports `wlr-layer-shell` (sway, Hyprland, KWin, Mutter, …).

System libraries (Fedora):

```bash
sudo dnf install wayland-devel wayland-protocols-devel \
                 pixman-devel fcft-devel libxkbcommon-devel \
                 systemd-devel
```

Then:

```bash
zig build run        # build and launch
# or
zig build            # binary at ./zig-out/bin/zento
```

The `zig-wayland` dependency is fetched automatically by the build (see `build.zig.zon`).

## Usage

- Launch it (bind it to a hotkey in your compositor).
- Type to search — apps, math, conversions, or a power command.
- `↑`/`↓` to move, `Enter` to act, `Esc` to go back / close.
- `dw <word>` for a dictionary definition; `Enter` expands it, `↑`/`↓` scrolls.

### Dictionary setup

Drop a StarDict dictionary under `~/.stardict/dic/` (Webster's 1913 from [stardict.uber.space](https://stardict.uber.space/) is a good default). The path is currently hardcoded — scanning all dictionary dirs is on the roadmap.

## Status & roadmap

Working today: the table above, plus frecency, fuzzy matching, HiDPI, and the mode system. It's actively evolving and rough in places.

Planned: key repeat, readline shortcuts (Ctrl+A/E/U/K/W), bandwidth conversions, timezone lookups, theming, scanning all StarDict directories, and case-insensitive dictionary lookup.

## License

Personal learning project — no license yet.
