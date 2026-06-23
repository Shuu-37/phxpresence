# xipresence

Discord Rich Presence for **Final Fantasy XI**, as an [Ashita v4](https://github.com/AshitaXI/Ashita-v4beta) addon.

While the addon is loaded, your Discord profile shows what you're up to in Vana'diel:

- **Playing** Final Fantasy XI
- **Details** — your character name (optional), job/subjob, and current zone
- **State** — *Seeking party* / *In party (n/6)* / *In alliance (n/18)* / *Solo* / *Away*
- **Party** — the slot pill when you're grouped
- **Artwork** — the zone you're in (with a default fallback)
- **Elapsed time** since you started playing

## How it works

xipresence talks to your **local Discord client over its RPC named pipe**
(`\\.\pipe\discord-ipc-N`). This is the same mechanism game integrations use to
set Rich Presence — it requires **no Discord login or OAuth**. The client is
implemented in pure Lua via LuaJIT FFI against the Win32 named-pipe APIs, so
there are no native DLLs to build or install.

Discord just needs to be running on the same machine.

## Install

1. Copy the `xipresence` folder into your Ashita `addons` directory.
2. Add `/addon load xipresence` to your Ashita script (or run it in-game).
3. Make sure the Discord desktop app is running.

## Commands

| Command | Description |
| --- | --- |
| `/xipresence on` \| `off` | Enable / disable Rich Presence |
| `/xipresence status` | Show connection status and current presence |
| `/xipresence reconnect` | Force a reconnect to Discord |
| `/xipresence name on` \| `off` | Show / hide your character name |
| `/xipresence party on` \| `off` | Show / hide the party slot count |
| `/xipresence art on` \| `off` | Show / hide zone artwork |
| `/xipresence seek on` \| `off` | Mark yourself as seeking party |
| `/xipresence away on` \| `off` | Mark yourself as away |

`/xipre` is an alias. Settings persist per character.

## Privacy

Your character name is **shown by default** (Discord Rich Presence is visible to
your friends and shared servers). Turn it off any time with
`/xipresence name off`.

## Assets

Zone artwork is hosted as external image URLs and referenced by zone id
(`assets/zones/<id>.png`). Regenerate / refresh the art set with:

```pwsh
pwsh tools/fetch_zone_assets.ps1
```

This pulls area images from [ffxiclopedia](https://ffxiclopedia.fandom.com) and
writes a coverage report. Zones without art fall back to `assets/zones/default.png`.

### Discord application setup (one-time)

- The "game name" shown in Discord is the **application name** in the
  [Discord Developer Portal](https://discord.com/developers/applications) — set
  it to `Final Fantasy XI` for this app id (`1518771970878214395`).
- Job icons use small-image asset **keys** named `job_<abbr>` (e.g. `job_war`).
  Upload 22 job icons under *Rich Presence → Art Assets* to enable them; if they
  aren't present, the small icon is simply omitted.

## License

[MIT](LICENSE)
