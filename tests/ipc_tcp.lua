local ffi = require('ffi');
package.preload.win32types = function () ffi.cdef('typedef unsigned long DWORD;'); end;

local incoming = {};
local outgoing = '';
local closed = false;
local partial_send = false;
local conn = {
    settimeout = function () end,
    connect = function (_, host, port)
        assert(host == '127.0.0.1' and port == 51337);
        return true;
    end,
    send = function (_, data)
        if (partial_send) then
            partial_send = false;
            outgoing = outgoing .. data:sub(1, 3);
            return nil, 'timeout', 3;
        end
        outgoing = outgoing .. data;
        return #data;
    end,
    receive = function ()
        return nil, 'timeout', table.remove(incoming, 1) or '';
    end,
    close = function () closed = true; end,
};
package.preload.socket = function () return { tcp = function () return conn; end }; end;

local getenv = os.getenv;
os.getenv = function (name)
    if (name == 'PHXPRESENCE_PORT') then return '51337'; end
    if (name == 'PHXPRESENCE_PID') then return '4242'; end
    return getenv(name);
end;
local IPC = require('discord.ipc');
assert(IPC.pid() == 4242);
local ipc = IPC.new();
assert(ipc:connect());

local function frame(op, payload)
    local function le(n)
        return string.char(n % 256, math.floor(n / 256) % 256,
            math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256);
    end
    return le(op) .. le(#payload) .. payload;
end

partial_send = true;
assert(ipc:write(IPC.OP.HANDSHAKE, '{}'));
assert(#outgoing == 3);
assert(ipc:read() == nil); -- flushes the rest without waiting for inbound data
assert(outgoing == frame(IPC.OP.HANDSHAKE, '{}'));

local reply = frame(IPC.OP.FRAME, '{"evt":"READY"}');
incoming[1] = reply:sub(1, 5);
assert(ipc:read() == nil);
incoming[1] = reply:sub(6);
local op, payload = ipc:read();
assert(op == IPC.OP.FRAME and payload == '{"evt":"READY"}');

incoming[1] = string.char(1, 0, 0, 0, 1, 0, 1, 0); -- 65537-byte frame
assert(ipc:read() == nil);
assert(closed and not ipc:is_connected());

print('ipc_tcp ok');
