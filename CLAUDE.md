# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

phxpresence is a Discord Rich Presence addon for **Final Fantasy XI**, written for
[Ashita v4](https://github.com/AshitaXI/Ashita-v4beta). It is pure Lua (LuaJIT) —
there is no build step, no compiler, and no test suite. You develop by editing the
`.lua` files and reloading the addon in-game.

## Running / testing

There is no CLI build or test harness. To exercise a change you must run it inside
Ashita with FFXI and the Discord desktop app both running on the same machine:

1. The addon folder must live in the Ashita `addons` directory (or be symlinked there).
2. In-game: `/addon reload phxpresence` after editing, then drive it with the
   `/phxpresence` commands (see README) or the `/phxpresence` config window.
3. `/phxpresence status` reports the Discord pipe connection state and the current
   details/state lines — the primary way to confirm behavior without a debugger.

`os.time()`-based throttling means presence updates lag a few seconds; flag changes
(`/anon`, `/seek`, `/away`) are pushed immediately via packet handlers.

## Architecture

The addon is layered so that game-state reading, Discord transport, and the
"shape" of the presence are independent. Data flows one direction:

```
game state ──> presence/state.lua ──(snapshot)──> presence/activity.lua ──(activity obj)──> discord/presence.lua ──> discord/ipc.lua ──> Discord pipe
```

**`phxpresence.lua`** — the addon entry point and the only file that touches Ashita
events. It owns all mutable state (`gConfig`, `gPresence`, runtime flags) and wires
the layers together. Key responsibilities:
- Registers `load` / `unload` / `d3d_present` / `packet_in` / `packet_out` /
  `command` events.
- The `d3d_present` handler is the heartbeat: throttled by `gConfig.interval`, it
  calls `gPresence:tick()` (keeps the pipe alive) then `refresh()` (re-evaluates
  and pushes presence). It also renders the ImGui window every frame when open.
- The `packet_in` handler watches two packets (`0x0037` server-status and `0x000D`
  PC-update) to track the local player's `/anon`, `/seek`, `/away` flags. These
  flags are **never set by command** — they mirror the in-game state. See the long
  comment near the top of the file for the exact flag-bit layout, which differs
  between the two packets.
- The `packet_out` handler watches `0x00E0` (search comment) to track the local
  player's `/seacom` text, which is surfaced as the job-icon hover text. The client
  resends it on zone-in and login, so an already-set comment is picked up shortly
  after load.
- Social flags and the search comment are also seeded from live game memory via
  `sync_social_flags()` (calling `state.social_flags()`) on `load` and on every
  poll, so a mid-session `/addon reload` recovers the real state immediately instead
  of waiting for the next flag packet; the packet handlers still push sub-poll
  changes instantly. All flag/comment changes call `refresh(true)` only when a value
  actually flipped.

**`presence/state.lua`** — reads live game state (job/level, zone, party, status)
into a plain snapshot table via `state.snapshot()`. Returns `nil` whenever there's
nothing worth publishing (logged out, zoning, no job), so callers never post
garbage. Also exposes `state.social_flags()`, which reads the `/anon`, `/seek`,
`/away` bits straight from memory (returns `nil` until in-world). This is the only
module that reads `AshitaCore` / `GetPlayerEntity()`.

**`presence/activity.lua`** — pure transform: snapshot + display options → a Discord
activity object. No I/O, no game access. The `/anon` branch produces a deliberately
minimal activity (name + timer only). Asset keys here (`'ffxi'`, job abbreviations,
`'seeking'`/`'away'`) must match the filenames uploaded to the Discord app's art
assets **and** the local files under `assets/`.

**`presence/ui.lua`** — the ImGui config window. Stateless: the addon passes a
`ctx` table each frame and the UI reports changes back through callbacks
(`set_enabled`, `on_config_change`, `on_reconnect`). It also renders a live preview
card by loading the local PNGs as D3D8 textures.

**`discord/presence.lua`** — high-level Rich Presence manager. Owns the connection
lifecycle (connect → handshake → ready), throttled `SET_ACTIVITY` sends (change
detection + a 15s resend floor to respect Discord's rate limit), PING/PONG
heartbeat, queuing of activities sent before `ready`, and reconnect-with-backoff.

**`discord/ipc.lua`** — low-level transport. Implements Discord's RPC framing
(`[op:u32 LE][len:u32 LE][json]`) over the `\\.\pipe\discord-ipc-N` named pipe via
LuaJIT FFI against Win32 (`CreateFileA`/`WriteFile`/`ReadFile`/`PeekNamedPipe`).
Reads are non-blocking (peek-first) so the render thread never stalls. No native
DLL — this is why the addon needs no compilation.

### Conventions worth matching

- This is **Ashita Lua**: `require('common')` is loaded, so `T{}` (typed tables with
  `:ieach`, `:any`, etc.), `chat.header`/`chat.message`/`chat.color1`, and the
  `settings` library are available globally. Match the existing semicolon-terminated,
  `local`-heavy style.
- Settings persist **per character** via Ashita's `settings` library
  (`settings.load(defaults)` / `settings.save()`). Runtime config lives in `config/`
  and `settings/`, both gitignored.
- The `d3d_present` handler runs every frame — keep work there cheap and behind the
  poll throttle or the `ui.is_open` gate.

## Assets (not built)

`assets/ffxi.png`, `assets/jobs/*.png`, and `assets/status/*.png` are 512×512 PNGs
uploaded **manually** to the Discord Developer Portal (app id in `phxpresence.lua` as
`CLIENT_ID`). The asset key is the filename without extension — no renaming. See the
"Discord application setup" section of the README.

`data/zones.lua` and `tools/build_zone_urls.ps1` are **dormant plumbing** for
per-zone artwork that is currently on hold. Presence uses the single `ffxi` icon for
every zone today; don't assume the zone map is wired into runtime.
