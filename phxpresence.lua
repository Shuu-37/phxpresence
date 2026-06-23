--[[
* phxpresence - Discord Rich Presence for FFXI
* Copyright (c) 2026 Shuu-37 [github.com/Shuu-37/phxpresence]
* MIT License
*
* Publishes Discord Rich Presence (job/subjob, zone, party status, elapsed time)
* while playing FFXI with the addon enabled. Talks to the local Discord client
* over its RPC named pipe - no Discord login/OAuth required.
--]]

addon.name    = 'phxpresence';
addon.author  = 'Phoenix Team';
addon.version = '0.1.0';
addon.desc    = 'Discord Rich Presence for FFXI.';
addon.link    = 'https://github.com/Shuu-37/phxpresence';

require('common');

local chat     = require('chat');
local settings = require('settings');
local state    = require('presence.state');
local activity = require('presence.activity');
local ui       = require('presence.ui');
local Presence = require('discord.presence');

-- Discord application (client) id for phxpresence.
local CLIENT_ID = '1518771970878214395';

-- How often (seconds) we poll game state and refresh presence.
local DEFAULT_INTERVAL = 5;

-- Packets that carry the local player's social flags (/anon, /seek, /away). We
-- watch both so a flag change is caught however the server pushes it: 0x0037
-- (server status, always the local player; sent on zone/login/status changes) and
-- 0x000D (PC update, broadcast when a player - including us - changes
-- appearance/flags). A plain toggle generally only sends 0x000D, so 0x0037 alone
-- misses re-toggles. Both pack Lfg/Anon/Away into a single flag byte:
--   0x0037: Flags0 low byte @ 0x28 -> Lfg 0x10, Anon 0x20, Away 0x80
--   0x000D: Flags1 byte      @ 0x21 -> Lfg 0x08, Anon 0x10, Away 0x40
local PACKET_SERVERSTATUS = 0x0037;
local PACKET_CHAR_PC      = 0x000D;

-- Outgoing packet carrying the local player's search comment (/seacom). The client
-- resends it on every zone-in and at login, so we pick up an already-set comment
-- shortly after the addon loads. sMessage is 128 bytes at offset 0x04: three
-- 40-char space-padded lines (the last 8 bytes are unused).
local PACKET_SEARCH_COMMENT = 0x00E0;

local defaults = T{
    enabled     = true,
    showName    = true,  -- character name in details (privacy: /phxpresence name off)
    showJob     = true,  -- job/level line in details + the job icon badge
    showParty   = true,  -- party slot pill + "In party"/"In alliance"/"Solo" text
    hidePartyWhenSolo = false, -- suppress party info while solo (sub of showParty)
    showZone    = true,  -- show the current zone (state line + image hover text)
    interval    = DEFAULT_INTERVAL,
};

local gConfig    = settings.load(defaults);
local gPresence  = Presence.new(CLIENT_ID);
local gSession   = 0;     -- epoch of when presence first started this session
local gLastPoll  = 0;
local gShowing   = false; -- whether we currently have an activity posted
local gRuntime   = { seeking = false, away = false }; -- live /seek + /away flags from packets
local gAnon      = false; -- in-game /anon flag, detected from packet 0x0037
local gSeacom    = nil;   -- in-game search comment (/seacom), from packet 0x00E0

-- Forward declarations: the load/poll handlers below seed the social flags from
-- game memory, but the setters that own the diff logic live with the packet
-- handlers further down.
local set_flags;
local sync_social_flags;

--[[
* Builds the display options table passed to activity.build().
--]]
local function display_opts()
    return T{
        showName    = gConfig.showName,
        showJob     = gConfig.showJob,
        showParty   = gConfig.showParty,
        hidePartyWhenSolo = gConfig.hidePartyWhenSolo,
        showZone    = gConfig.showZone,
        seeking     = gRuntime.seeking,
        away        = gRuntime.away,
        anon        = gAnon,
        seacom      = gSeacom,
        startTime   = gSession,
    };
end

--[[
* Immediately re-evaluates and pushes presence (used after a setting changes).
--]]
local function refresh(force)
    if (not gConfig.enabled) then
        return;
    end
    local snap = state.snapshot();
    if (snap ~= nil) then
        gPresence:update(activity.build(snap, display_opts()), force);
        gShowing = true;
    elseif (gShowing) then
        gPresence:clear();
        gShowing = false;
    end
end

--[[
* Enables or disables presence, persisting the choice and connecting / tearing
* down the Discord pipe to match. Shared by the command handler and the UI.
--]]
local function set_enabled(v)
    gConfig.enabled = v;
    settings.save();
    if (gConfig.enabled) then
        print(chat.header(addon.name):append(chat.message('Rich Presence enabled.')));
        gPresence:tick();
        refresh(true);
    else
        print(chat.header(addon.name):append(chat.message('Rich Presence disabled.')));
        gPresence:disconnect();
        gShowing = false;
    end
end

--[[
* Forces a fresh reconnect to Discord. Shared by the command handler and the UI.
--]]
local function reconnect()
    gPresence:disconnect();
    gPresence.next_retry = 0;
    gPresence:tick();
    refresh(true);
end

--[[
* Builds the context table the UI renders from. Cheap; the only non-trivial work
* (the preview) is gated behind the window being open by the caller.
--]]
local function build_ctx()
    local preview;
    local snap = state.snapshot();
    if (snap ~= nil) then
        local d = activity.build(snap, display_opts());
        local assets = d.assets or T{};
        preview = {
            details    = d.details or '',
            state      = d.state or '',
            party      = d.party and d.party.size, -- {current, max} or nil
            largeImage = assets.large_image,
            smallImage = assets.small_image,
            largeText  = assets.large_text,
            smallText  = assets.small_text,
        };
    end
    return {
        config            = gConfig,
        runtime           = gRuntime,
        anon              = gAnon,
        status            = gPresence:status(),
        connected         = gPresence.ipc:is_connected(),
        ready             = gPresence.ready,
        preview           = preview,
        set_enabled       = set_enabled,
        on_config_change  = function () settings.save(); refresh(true); end,
        on_reconnect      = reconnect,
    };
end

--[[
* Prints the addon help.
--]]
local function print_help()
    print(chat.header(addon.name):append(chat.message('Available commands:')));
    local cmds = T{
        { '/phxpresence',             'Open the config window.' },
        { '/phxpresence on | off',    'Enable or disable Rich Presence.' },
        { '/phxpresence status',      'Show connection status and current presence.' },
        { '/phxpresence reconnect',   'Force a reconnect to Discord.' },
        { '/phxpresence name on|off', 'Show or hide your character name.' },
        { '/phxpresence job on|off',  'Show or hide your job/level and job icon.' },
        { '/phxpresence party on|off','Show or hide party info (slots + membership).' },
        { '/phxpresence zone on|off', 'Show or hide your current zone.' },
        { '/phxp',                     'Shortcut for /phxpresence.' },
    };
    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

--[[
* Parses an on/off argument; returns boolean or nil if not on/off.
--]]
local function parse_toggle(arg)
    if (arg == nil) then return nil; end
    if (arg:any('on', 'true', '1')) then return true; end
    if (arg:any('off', 'false', '0')) then return false; end
    return nil;
end

--[[
* event: load
--]]
ashita.events.register('load', 'load_cb', function ()
    gSession  = os.time();
    gLastPoll = 0;
    -- Recover the real /anon, /seek, /away state from memory now, since a reload
    -- mid-session won't get a fresh flag packet (otherwise we'd broadcast job/zone
    -- while still anonymous until the next toggle).
    sync_social_flags();
    if (gConfig.enabled) then
        gPresence:tick(); -- kick off the first connect attempt
    end
end);

--[[
* event: unload - clear presence and close the pipe.
--]]
ashita.events.register('unload', 'unload_cb', function ()
    gPresence:disconnect();
    settings.save();
end);

--[[
* event: d3d_present - throttled poll + presence refresh.
--]]
ashita.events.register('d3d_present', 'present_cb', function ()
    -- Render the config window every frame (independent of the poll throttle).
    if (ui.is_open[1]) then
        ui.render(build_ctx());
    end

    if (not gConfig.enabled) then
        return;
    end

    local now = os.time();
    if ((now - gLastPoll) < (gConfig.interval or DEFAULT_INTERVAL)) then
        return;
    end
    gLastPoll = now;

    gPresence:tick();
    sync_social_flags(); -- self-heal flags in case a packet was missed
    refresh(false);
end);

--[[
* Records the latest social flags (/anon, /seek, /away) and pushes presence
* immediately if any flipped, so the change shows without waiting for the next poll.
--]]
set_flags = function (anon, seeking, away)
    if (anon ~= gAnon or seeking ~= gRuntime.seeking or away ~= gRuntime.away) then
        gAnon = anon;
        gRuntime.seeking = seeking;
        gRuntime.away = away;
        refresh(true);
    end
end

--[[
* Seeds the social flags (/anon, /seek, /away) from live game memory (see
* state.social_flags). Used on load to recover state immediately - a reload
* mid-session never gets a fresh flag packet - and on each poll as a safety net;
* no-op until the player is in-world. The packet handlers still push sub-poll
* changes instantly; this just keeps memory as the source of truth.
--]]
sync_social_flags = function ()
    local f = state.social_flags();
    if (f ~= nil) then
        set_flags(f.anon, f.seeking, f.away);
    end
end

--[[
* Decodes the search comment out of a 0x00E0 packet. sMessage is three 40-char,
* space-padded lines at offset 0x04; we trim each line and join the non-empty ones
* with a space. Returns nil when the comment is blank (all spaces = no comment).
--]]
local function decode_seacom(data)
    local parts = T{};
    for line = 0, 2 do
        local first = 0x05 + (line * 40); -- 1-indexed start of this line in data
        local s = data:sub(first, first + 39);
        s = s:gsub('%z', ''):gsub('^%s+', ''):gsub('%s+$', '');
        if (#s > 0) then
            parts:append(s);
        end
    end
    if (#parts == 0) then
        return nil;
    end
    return parts:concat(' ');
end

--[[
* Records the latest search comment and pushes presence immediately if it changed,
* mirroring set_flags so the new tooltip shows without waiting for the next poll.
--]]
local function set_seacom(s)
    if (s ~= gSeacom) then
        gSeacom = s;
        refresh(true);
    end
end

--[[
* event: packet_in - watch the local player's flag packets so /anon, /seek and
* /away are reflected in presence automatically (never set by hand).
--]]
ashita.events.register('packet_in', 'packet_in_cb', function (e)
    if (e.id == PACKET_SERVERSTATUS) then
        -- Always the local player. Flags0's low byte (0x28) holds all three bits.
        if (e.size < 0x2C) then
            return;
        end
        local f = e.data:byte(0x28 + 1);
        if (f ~= nil) then
            set_flags(bit.band(f, 0x20) ~= 0, bit.band(f, 0x10) ~= 0, bit.band(f, 0x80) ~= 0);
        end
    elseif (e.id == PACKET_CHAR_PC) then
        -- Sent for any player; only trust it for our own entity, and only when the
        -- 'General' send flag (0x04) is set, since Flags1 is stale otherwise.
        if (e.size < 0x24) then
            return;
        end
        local me = GetPlayerEntity();
        if (me == nil) then
            return;
        end
        local d = e.data;
        local uniqueNo = d:byte(0x05) + (d:byte(0x06) * 0x100)
                       + (d:byte(0x07) * 0x10000) + (d:byte(0x08) * 0x1000000);
        if (uniqueNo ~= me.ServerId) then
            return;
        end
        local sendFlg = d:byte(0x0A + 1);
        if (sendFlg == nil or bit.band(sendFlg, 0x04) == 0) then
            return;
        end
        -- Flags1 byte 0x21 holds Lfg (0x08), Anon (0x10) and Away (0x40).
        local f = d:byte(0x21 + 1);
        if (f ~= nil) then
            set_flags(bit.band(f, 0x10) ~= 0, bit.band(f, 0x08) ~= 0, bit.band(f, 0x40) ~= 0);
        end
    end
end);

--[[
* event: packet_out - watch the local player's search comment packet (0x00E0) so
* /seacom is reflected as the job-icon hover text automatically (resent on zone/login).
--]]
ashita.events.register('packet_out', 'packet_out_cb', function (e)
    if (e.id ~= PACKET_SEARCH_COMMENT) then
        return;
    end
    -- Need the full 128-byte message (offset 0x04 .. 0x83) before decoding.
    if (e.size < 0x84) then
        return;
    end
    set_seacom(decode_seacom(e.data));
end);

--[[
* event: command - /phxpresence handler.
--]]
ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/phxpresence', '/phxp')) then
        return;
    end

    e.blocked = true;

    -- No subcommand opens the config window.
    local sub = (#args >= 2) and args[2]:lower() or 'config';
    local val = (#args >= 3) and args[3] or nil;

    if (sub == 'help') then
        print_help();
        return;
    end

    if (sub:any('config', 'ui', 'cfg')) then
        ui.toggle();
        return;
    end

    if (sub == 'on' or sub == 'off') then
        set_enabled(sub == 'on');
        return;
    end

    if (sub == 'status') then
        print(chat.header(addon.name):append(chat.message('Discord: ')):append(chat.success(gPresence:status())));
        local snap = state.snapshot();
        if (snap ~= nil) then
            if (gAnon) then
                print(chat.header(addon.name):append(chat.message('Privacy: ')):append(chat.color1(6, 'Anonymous (/anon) - job, zone and party hidden.')));
            end
            local d = activity.build(snap, display_opts());
            print(chat.header(addon.name):append(chat.message('Details: ')):append(chat.color1(6, d.details or '(hidden)')));
            print(chat.header(addon.name):append(chat.message('State:   ')):append(chat.color1(6, d.state or '(hidden)')));
        else
            print(chat.header(addon.name):append(chat.message('Not logged in / no presence to show.')));
        end
        return;
    end

    if (sub == 'reconnect') then
        reconnect();
        print(chat.header(addon.name):append(chat.message('Reconnecting to Discord...')));
        return;
    end

    -- on/off toggles for the persisted display options. /seek and /away are no
    -- longer manual - they track the in-game flags automatically (see packet_in).
    local toggle = parse_toggle(val);
    local set_show_zone = function (v) gConfig.showZone = v; settings.save(); end;
    local handled = T{
        name  = function (v) gConfig.showName = v; settings.save(); end,
        job   = function (v) gConfig.showJob = v; settings.save(); end,
        party = function (v) gConfig.showParty = v; settings.save(); end,
        zone  = set_show_zone,
        art   = set_show_zone, -- backward-compat alias for the old 'art' subcommand
    };

    if (handled[sub] ~= nil) then
        if (toggle == nil) then
            print(chat.header(addon.name):append(chat.error(('Usage: /phxpresence %s on|off'):format(sub))));
            return;
        end
        handled[sub](toggle);
        refresh(true);
        print(chat.header(addon.name):append(chat.message(('%s -> %s'):format(sub, toggle and 'on' or 'off'))));
        return;
    end

    print_help();
end);
