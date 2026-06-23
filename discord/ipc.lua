--[[
* xipresence - Discord Rich Presence for FFXI
* Copyright (c) 2026 Shuu-37 [github.com/Shuu-37/xipresence]
* MIT License
*
* discord/ipc.lua
* Low-level Discord IPC transport over a Windows named pipe.
*
* Discord exposes a local named pipe (\\.\pipe\discord-ipc-N) that accepts the
* RPC framing protocol with no OAuth flow required for Rich Presence. Frames are
* [op:u32 LE][len:u32 LE][json payload]. This module owns one pipe connection and
* exposes framed write + non-blocking read.
--]]

require('win32types');

local ffi = require('ffi');

ffi.cdef[[
    HANDLE CreateFileA(const char* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, LPVOID lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
    BOOL   WriteFile(HANDLE hFile, LPCVOID lpBuffer, DWORD nNumberOfBytesToWrite, LPDWORD lpNumberOfBytesWritten, LPVOID lpOverlapped);
    BOOL   ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, LPDWORD lpNumberOfBytesRead, LPVOID lpOverlapped);
    BOOL   PeekNamedPipe(HANDLE hNamedPipe, LPVOID lpBuffer, DWORD nBufferSize, LPDWORD lpBytesRead, LPDWORD lpTotalBytesAvail, LPDWORD lpBytesLeftThisMessage);
    BOOL   CloseHandle(HANDLE hObject);
    DWORD  GetLastError(void);
    DWORD  GetCurrentProcessId(void);
]];

local C = ffi.C;

-- Win32 constants.
local GENERIC_RW       = 0xC0000000; -- GENERIC_READ | GENERIC_WRITE
local OPEN_EXISTING    = 3;
local INVALID_HANDLE   = ffi.cast('HANDLE', -1);

-- Discord opcodes.
local OP = {
    HANDSHAKE = 0,
    FRAME     = 1,
    CLOSE     = 2,
    PING      = 3,
    PONG      = 4,
};

local IPC = {};
IPC.__index = IPC;

--[[
* Creates a new (disconnected) IPC client.
--]]
function IPC.new()
    local self = setmetatable({}, IPC);
    self.handle    = nil;
    self.pipe      = nil;  -- index of the pipe we connected to (0..9)
    self.readbuf   = ffi.new('uint8_t[?]', 65536);
    self.dwords    = ffi.new('DWORD[1]');
    return self;
end

IPC.OP = OP;

--[[
* Returns the current process id (used as the activity 'pid').
--]]
function IPC.pid()
    return tonumber(C.GetCurrentProcessId());
end

--[[
* Returns true when a pipe handle is currently open.
--]]
function IPC:is_connected()
    return self.handle ~= nil;
end

--[[
* Attempts to open one of the discord-ipc-0..9 pipes. First success wins.
* Returns true on success, false if Discord is not running / no pipe is open.
--]]
function IPC:connect()
    if (self:is_connected()) then
        return true;
    end

    for i = 0, 9 do
        local name = ('\\\\.\\pipe\\discord-ipc-%d'):format(i);
        local h = C.CreateFileA(name, GENERIC_RW, 0, nil, OPEN_EXISTING, 0, nil);
        if (h ~= INVALID_HANDLE) then
            self.handle = h;
            self.pipe = i;
            return true;
        end
    end

    return false;
end

--[[
* Closes the pipe handle (if any) and clears connection state.
--]]
function IPC:close()
    if (self.handle ~= nil) then
        C.CloseHandle(self.handle);
        self.handle = nil;
        self.pipe = nil;
    end
end

--[[
* Writes a single framed message. The header + payload are written in one call;
* splitting a frame across writes corrupts the pipe.
*
* @param {number} op      - Discord opcode (see IPC.OP).
* @param {string} payload - JSON payload string.
* @return {boolean} true on success, false on failure (pipe is closed on failure).
--]]
function IPC:write(op, payload)
    if (not self:is_connected()) then
        return false;
    end

    local len = #payload;
    local frame = ffi.new('uint8_t[?]', 8 + len);
    local hdr = ffi.cast('uint32_t*', frame);
    hdr[0] = op;
    hdr[1] = len;
    if (len > 0) then
        ffi.copy(frame + 8, payload, len);
    end

    local ok = C.WriteFile(self.handle, frame, 8 + len, self.dwords, nil);
    if (ok == 0) then
        -- Broken pipe (Discord closed/restarted). Drop the connection so the
        -- caller can reconnect.
        self:close();
        return false;
    end

    return true;
end

--[[
* Non-blocking read of a single frame. Peeks the pipe first so the render thread
* never stalls when no data is pending.
*
* @return {number|nil, string|nil} opcode and payload, or nil when nothing is
*         available. Returns nil and closes the pipe on a read error.
--]]
function IPC:read()
    if (not self:is_connected()) then
        return nil;
    end

    -- How many bytes are waiting?
    local avail = ffi.new('DWORD[1]');
    local ok = C.PeekNamedPipe(self.handle, nil, 0, nil, avail, nil);
    if (ok == 0) then
        self:close();
        return nil;
    end
    if (avail[0] < 8) then
        return nil; -- not even a full header yet
    end

    -- Read the 8 byte header.
    if (C.ReadFile(self.handle, self.readbuf, 8, self.dwords, nil) == 0) then
        self:close();
        return nil;
    end

    local hdr = ffi.cast('uint32_t*', self.readbuf);
    local op = tonumber(hdr[0]);
    local len = tonumber(hdr[1]);

    if (len <= 0) then
        return op, '';
    end

    if (len > ffi.sizeof(self.readbuf)) then
        len = ffi.sizeof(self.readbuf); -- guard; payloads are tiny in practice
    end

    if (C.ReadFile(self.handle, self.readbuf, len, self.dwords, nil) == 0) then
        self:close();
        return nil;
    end

    return op, ffi.string(self.readbuf, tonumber(self.dwords[0]));
end

return IPC;
