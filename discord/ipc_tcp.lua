-- Discord RPC over the Phoenix launcher's Linux loopback bridge.

require('win32types');

local ffi = require('ffi');
local socket = require('socket');

ffi.cdef[[ DWORD GetCurrentProcessId(void); ]];

local MAX_FRAME = 65536;
local MAX_PENDING = 131072;
local host_pid = tonumber(os.getenv('PHXPRESENCE_PID'));

local IPC = {};
IPC.__index = IPC;
IPC.OP = { HANDSHAKE = 0, FRAME = 1, CLOSE = 2, PING = 3, PONG = 4 };

function IPC.new_transport(port)
    IPC.port = port;
    return IPC;
end

function IPC.new()
    return setmetatable({ socket = nil, readbuf = '', writebuf = '' }, IPC);
end

function IPC.pid()
    return host_pid or tonumber(ffi.C.GetCurrentProcessId());
end

function IPC:label()
    return 'Linux Discord bridge';
end

function IPC:is_connected()
    return self.socket ~= nil;
end

function IPC:connect()
    if (self:is_connected()) then
        return true;
    end

    local conn = socket.tcp();
    if (conn == nil) then
        return false;
    end
    conn:settimeout(0.05); -- loopback only; never wait indefinitely in the game
    local ok = conn:connect('127.0.0.1', IPC.port);
    if (not ok) then
        conn:close();
        return false;
    end
    conn:settimeout(0);
    self.socket = conn;
    return true;
end

function IPC:close()
    if (self.socket ~= nil) then
        self.socket:close();
        self.socket = nil;
    end
    self.readbuf = '';
    self.writebuf = '';
end

local function u32(s, offset)
    local a, b, c, d = s:byte(offset, offset + 3);
    return a + b * 256 + c * 65536 + d * 16777216;
end

local function frame(op, payload)
    local len = #payload;
    local function le(n)
        return string.char(n % 256, math.floor(n / 256) % 256,
            math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256);
    end
    return le(op) .. le(len) .. payload;
end

function IPC:flush()
    while (self.socket ~= nil and #self.writebuf > 0) do
        local sent, err, partial = self.socket:send(self.writebuf);
        local count = sent or partial or 0;
        if (count > 0) then
            self.writebuf = self.writebuf:sub(count + 1);
        end
        if (not sent) then
            if (err == 'timeout') then
                return true;
            end
            self:close();
            return false;
        end
    end
    return self.socket ~= nil;
end

function IPC:write(op, payload)
    if (not self:is_connected()) then
        return false;
    end
    self.writebuf = self.writebuf .. frame(op, payload);
    if (#self.writebuf > MAX_PENDING) then
        self:close();
        return false;
    end
    return self:flush();
end

function IPC:read()
    if (not self:is_connected() or not self:flush()) then
        return nil;
    end

    for _ = 1, 8 do
        local data, err, partial = self.socket:receive(4096);
        local chunk = data or partial;
        if (chunk ~= nil and #chunk > 0) then
            self.readbuf = self.readbuf .. chunk;
            if (#self.readbuf > MAX_FRAME + 8) then
                self:close();
                return nil;
            end
        end
        if (err == 'closed') then
            self:close();
            return nil;
        end
        if (err == 'timeout' or data == nil) then
            break;
        end
    end

    if (#self.readbuf < 8) then
        return nil;
    end
    local op = u32(self.readbuf, 1);
    local len = u32(self.readbuf, 5);
    if (len > MAX_FRAME) then
        self:close();
        return nil;
    end
    if (#self.readbuf < len + 8) then
        return nil;
    end
    local payload = self.readbuf:sub(9, 8 + len);
    self.readbuf = self.readbuf:sub(9 + len);
    return op, payload;
end

return IPC;
