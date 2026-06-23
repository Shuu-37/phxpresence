--[[
* xipresence - Discord Rich Presence for FFXI
* Copyright (c) 2026 Shuu-37 [github.com/Shuu-37/xipresence]
* MIT License
*
* Publishes Discord Rich Presence (job/subjob, zone, party status, elapsed time)
* while playing FFXI with the addon enabled. Talks to the local Discord client
* over its RPC named pipe - no Discord login/OAuth required.
--]]

addon.name    = 'xipresence';
addon.author  = 'Shuu-37';
addon.version = '0.1.0';
addon.desc    = 'Discord Rich Presence for FFXI.';
addon.link    = 'https://github.com/Shuu-37/xipresence';

require('common');

local chat     = require('chat');
local settings = require('settings');
local state    = require('presence.state');
local activity = require('presence.activity');
local Presence = require('discord.presence');

-- Discord application (client) id for xipresence.
local CLIENT_ID = '1518771970878214395';

-- How often (seconds) we poll game state and refresh presence.
local DEFAULT_INTERVAL = 5;

local defaults = T{
    enabled     = true,
    showName    = true,  -- character name in details (privacy: /xipresence name off)
    showParty   = true,  -- show the party slot pill
    showZoneArt = true,  -- use zone art for the large image
    interval    = DEFAULT_INTERVAL,
};

local gConfig    = settings.load(defaults);
local gPresence  = Presence.new(CLIENT_ID);
local gSession   = 0;     -- epoch of when presence first started this session
local gLastPoll  = 0;
local gShowing   = false; -- whether we currently have an activity posted
local gSeeking   = false; -- runtime toggle (not persisted)
local gAway      = false; -- runtime toggle (not persisted)

--[[
* Builds the display options table passed to activity.build().
--]]
local function display_opts()
    return T{
        showName    = gConfig.showName,
        showParty   = gConfig.showParty,
        showZoneArt = gConfig.showZoneArt,
        seeking     = gSeeking,
        away        = gAway,
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
* Prints the addon help.
--]]
local function print_help()
    print(chat.header(addon.name):append(chat.message('Available commands:')));
    local cmds = T{
        { '/xipresence on | off',    'Enable or disable Rich Presence.' },
        { '/xipresence status',      'Show connection status and current presence.' },
        { '/xipresence reconnect',   'Force a reconnect to Discord.' },
        { '/xipresence name on|off', 'Show or hide your character name.' },
        { '/xipresence party on|off','Show or hide the party slot count.' },
        { '/xipresence art on|off',  'Show or hide zone artwork.' },
        { '/xipresence seek on|off', 'Mark yourself as seeking party.' },
        { '/xipresence away on|off', 'Mark yourself as away.' },
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
    if (not gConfig.enabled) then
        return;
    end

    local now = os.time();
    if ((now - gLastPoll) < (gConfig.interval or DEFAULT_INTERVAL)) then
        return;
    end
    gLastPoll = now;

    gPresence:tick();
    refresh(false);
end);

--[[
* event: command - /xipresence handler.
--]]
ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/xipresence', '/xipre')) then
        return;
    end

    e.blocked = true;

    local sub = (#args >= 2) and args[2]:lower() or 'help';
    local val = (#args >= 3) and args[3] or nil;

    if (sub == 'help') then
        print_help();
        return;
    end

    if (sub == 'on' or sub == 'off') then
        gConfig.enabled = (sub == 'on');
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
        return;
    end

    if (sub == 'status') then
        print(chat.header(addon.name):append(chat.message('Discord: ')):append(chat.success(gPresence:status())));
        local snap = state.snapshot();
        if (snap ~= nil) then
            local d = activity.build(snap, display_opts());
            print(chat.header(addon.name):append(chat.message('Details: ')):append(chat.color1(6, d.details)));
            print(chat.header(addon.name):append(chat.message('State:   ')):append(chat.color1(6, d.state)));
        else
            print(chat.header(addon.name):append(chat.message('Not logged in / no presence to show.')));
        end
        return;
    end

    if (sub == 'reconnect') then
        gPresence:disconnect();
        gPresence.next_retry = 0;
        gPresence:tick();
        refresh(true);
        print(chat.header(addon.name):append(chat.message('Reconnecting to Discord...')));
        return;
    end

    -- on/off toggles for the various display options.
    local toggle = parse_toggle(val);
    local handled = T{
        name  = function (v) gConfig.showName = v; settings.save(); end,
        party = function (v) gConfig.showParty = v; settings.save(); end,
        art   = function (v) gConfig.showZoneArt = v; settings.save(); end,
        seek  = function (v) gSeeking = v; end,
        away  = function (v) gAway = v; end,
    };

    if (handled[sub] ~= nil) then
        if (toggle == nil) then
            print(chat.header(addon.name):append(chat.error(('Usage: /xipresence %s on|off'):format(sub))));
            return;
        end
        handled[sub](toggle);
        refresh(true);
        print(chat.header(addon.name):append(chat.message(('%s -> %s'):format(sub, toggle and 'on' or 'off'))));
        return;
    end

    print_help();
end);
