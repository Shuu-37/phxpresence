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

Presence currently uses a **single large image** — the FFXI game icon
(`assets/ffxi.png`) — for every zone, plus your **primary job** icon as the small
image (`assets/jobs/`). The current zone is still shown in the details line and as
the large-image hover text. Per-zone artwork is on hold; the plumbing for it
(`data/zones.lua` + `tools/build_zone_urls.ps1`, which resolves
[bg-wiki](https://www.bg-wiki.com) image URLs) remains for later.

### Discord application setup (one-time)

In the [Discord Developer Portal](https://discord.com/developers/applications)
for app id `1518771970878214395`:

- Set the **application name** to `Final Fantasy XI` — this is the "game name"
  Discord shows next to *Playing*.
- Under *Rich Presence → Art Assets*, upload everything in `assets/` (the
  `ffxi.png` large image and all of `assets/jobs/*.png`). The asset keys are taken
  from the filenames, so **no renaming is needed** — `ffxi.png` → key `ffxi`,
  `war.png` → `war`, `nin.png` → `nin`, etc. All images are already 512×512.

Assets can take a few minutes to propagate before they appear in presence.

## Credits

- Job icons (`assets/jobs/`) — Final Fantasy XIV (Square Enix) and
  [Tylas11](https://github.com/Tylas11), via the
  [XIUI](https://github.com/tirem/XIUI) addon.

## License

[MIT](LICENSE)
