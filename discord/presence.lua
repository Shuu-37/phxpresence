--[[
* xipresence - Discord Rich Presence for FFXI
* Copyright (c) 2026 Shuu-37 [github.com/Shuu-37/xipresence]
* MIT License
*
* discord/presence.lua
* High-level Rich Presence manager built on top of discord/ipc.lua.
*
* Owns the connection lifecycle (connect -> handshake -> ready), throttled
* SET_ACTIVITY updates, PING/PONG heartbeat, and reconnect-with-backoff when
* Discord is closed or restarted.
--]]

local json = require('json');
local IPC  = require('discord.ipc');

-- Discord rate-limits Rich Presence updates to roughly 5 per 20s; we resend only
-- when the activity changes or this many seconds have elapsed.
local RESEND_INTERVAL = 15;

-- Backoff (seconds) between reconnect attempts when Discord is unavailable.
local RECONNECT_BACKOFF = 15;

local Presence = {};
Presence.__index = Presence;

--[[
* Creates a new presence manager for the given Discord application/client id.
*
* @param {string} client_id - The Discord application id (snowflake string).
--]]
function Presence.new(client_id)
    local self = setmetatable({}, Presence);
    self.client_id   = client_id;
    self.ipc         = IPC.new();
    self.ready       = false;
    self.nonce       = 0;
    self.last_json   = nil;   -- last encoded activity object (for change detection)
    self.last_sent   = 0;     -- os.time() of the last successful send
    self.next_retry  = 0;     -- os.time() before which we won't retry connecting
    self.pending     = nil;   -- activity queued before we became ready
    return self;
end

--[[
* Returns a short status string for the /xipresence status command.
--]]
function Presence:status()
    if (not self.ipc:is_connected()) then
        return 'disconnected';
    end
    if (not self.ready) then
        return ('connected (discord-ipc-%d), handshaking'):format(self.ipc.pipe or -1);
    end
    return ('ready (discord-ipc-%d)'):format(self.ipc.pipe or -1);
end

--[[
* Builds a unique nonce for a frame.
--]]
function Presence:next_nonce()
    self.nonce = self.nonce + 1;
    return ('%d-%d'):format(os.time(), self.nonce);
end

--[[
* Attempts to connect and send the handshake. Honors the reconnect backoff so we
* don't hammer CreateFile every frame when Discord isn't running.
*
* @return {boolean} true if connected (handshake sent), false otherwise.
--]]
function Presence:ensure_connected()
    if (self.ipc:is_connected()) then
        return true;
    end

    local now = os.time();
    if (now < self.next_retry) then
        return false;
    end
    self.next_retry = now + RECONNECT_BACKOFF;

    if (not self.ipc:connect()) then
        return false;
    end

    -- Send the handshake. Discord replies with a READY dispatch we pick up in tick().
    self.ready = false;
    self.last_json = nil; -- force a resend once ready
    local handshake = json.encode(T{ v = 1, client_id = self.client_id });
    if (not self.ipc:write(IPC.OP.HANDSHAKE, handshake)) then
        return false;
    end

    return true;
end

--[[
* Drains any pending frames from Discord. Marks the session ready on the first
* response, and answers PING with PONG to keep the pipe alive.
--]]
function Presence:pump()
    if (not self.ipc:is_connected()) then
        return;
    end

    -- Drain everything currently buffered (usually 0-1 frames per tick).
    for _ = 1, 8 do
        local op, payload = self.ipc:read();
        if (op == nil) then
            break;
        end

        if (op == IPC.OP.PING) then
            self.ipc:write(IPC.OP.PONG, payload or '');
        elseif (op == IPC.OP.CLOSE) then
            self.ipc:close();
            self.ready = false;
            break;
        elseif (op == IPC.OP.FRAME) then
            -- Any FRAME (the READY dispatch) means the handshake succeeded.
            if (not self.ready) then
                self.ready = true;
                if (self.pending ~= nil) then
                    local act = self.pending;
                    self.pending = nil;
                    self:update(act, true);
                end
            end
        end
    end
end

--[[
* Periodic driver. Call this on a throttled tick from the addon. Keeps the
* connection alive and processes incoming frames.
--]]
function Presence:tick()
    self:ensure_connected();
    self:pump();
end

--[[
* Sends an activity object as the user's Rich Presence. No-ops (cheaply) when the
* activity hasn't changed and the resend interval hasn't elapsed.
*
* @param {table}   activity - The Discord activity object.
* @param {boolean} force    - When true, bypass the change/interval throttle.
--]]
function Presence:update(activity, force)
    if (not self.ipc:is_connected()) then
        self.pending = activity;
        return false;
    end
    if (not self.ready) then
        -- Queue until the handshake completes.
        self.pending = activity;
        return false;
    end

    local encoded = json.encode(activity);
    local now = os.time();
    if (not force and encoded == self.last_json and (now - self.last_sent) < RESEND_INTERVAL) then
        return true; -- unchanged and not stale; skip
    end

    local frame = json.encode(T{
        cmd   = 'SET_ACTIVITY',
        nonce = self:next_nonce(),
        args  = T{ pid = IPC.pid(), activity = activity },
    });

    if (not self.ipc:write(IPC.OP.FRAME, frame)) then
        self.ready = false;
        self.pending = activity;
        return false;
    end

    self.last_json = encoded;
    self.last_sent = now;
    return true;
end

--[[
* Clears the user's Rich Presence (activity -> null). Used on unload / disable.
--]]
function Presence:clear()
    if (not self.ipc:is_connected() or not self.ready) then
        return;
    end
    -- json.encode has no null sentinel and renders empty tables as arrays, so the
    -- clear frame is built by hand.
    local frame = ('{"cmd":"SET_ACTIVITY","nonce":"%s","args":{"pid":%d,"activity":null}}')
        :format(self:next_nonce(), IPC.pid());
    self.ipc:write(IPC.OP.FRAME, frame);
    self.last_json = nil;
    self.pending = nil;
end

--[[
* Clears presence (best effort) and tears down the connection.
--]]
function Presence:disconnect()
    self:clear();
    self.ipc:close();
    self.ready = false;
    self.pending = nil;
end

return Presence;
