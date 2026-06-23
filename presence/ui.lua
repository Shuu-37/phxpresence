--[[
* phxpresence - Discord Rich Presence for FFXI
* Copyright (c) 2026 Shuu-37 [github.com/Shuu-37/phxpresence]
* MIT License
*
* presence/ui.lua
* In-game ImGui config window. The addon owns all state; this module only
* renders it and reports changes back through the context's callbacks.
--]]

local imgui = require('imgui');
local ffi   = require('ffi');
local d3d8  = require('d3d8');

local C = ffi.C;

local ui = {};

-- Window visibility (imgui.Begin wants a bool ref it can clear on the [x]).
ui.is_open = { false };

-- Widget value buffers, re-synced from the live config every frame so external
-- changes (e.g. /phxpresence commands) stay reflected while the window is open.
local r = {
    enabled  = { false },
    showName = { true },
    showJob = { true },
    showParty = { true },
    hidePartyWhenSolo = { false },
    showZone = { true },
};

-- Status text colors (RGBA, 0..1).
local COLOR_OK   = { 0.40, 0.85, 0.40, 1.0 };
local COLOR_WARN = { 0.95, 0.78, 0.30, 1.0 };
local COLOR_OFF  = { 0.70, 0.70, 0.70, 1.0 };
local COLOR_DIM  = { 0.65, 0.65, 0.65, 1.0 };

-- Preview card geometry (a small mock-up of the Discord activity card).
local PREVIEW_LARGE = 60; -- large (game) image edge, px
local PREVIEW_SMALL = 24; -- small (job/status) badge edge, px

-- Cached preview textures keyed by absolute path. A 'false' value means a load
-- was attempted and failed, so we don't retry it every frame.
local textures = {};

--[[
* Resolves a Discord art-asset key to the local PNG that backs it. Mirrors the
* layout in assets/: the game icon, status icons, then job icons.
--]]
local function asset_path(key)
    if (key == nil) then
        return nil;
    end
    if (key == 'ffxi') then
        return ('%s/assets/ffxi.png'):format(addon.path);
    elseif (key == 'seeking' or key == 'away') then
        return ('%s/assets/status/%s.png'):format(addon.path, key);
    end
    return ('%s/assets/jobs/%s.png'):format(addon.path, key);
end

--[[
* Loads (and caches) a texture from an absolute path. Returns the
* IDirect3DTexture8* or nil if the device isn't ready or the file is missing.
--]]
local function load_texture(path)
    if (path == nil) then
        return nil;
    end
    local cached = textures[path];
    if (cached ~= nil) then
        return cached or nil; -- false -> previously failed
    end
    local dev = d3d8.get_device();
    if (dev == nil or not ashita.fs.exists(path)) then
        textures[path] = false;
        return nil;
    end
    local ptr = ffi.new('IDirect3DTexture8*[1]');
    if (C.D3DXCreateTextureFromFileA(dev, path, ptr) ~= C.S_OK) then
        textures[path] = false;
        return nil;
    end
    local tex = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]));
    textures[path] = tex;
    return tex;
end

--[[
* Casts a texture handle to the integer ImTextureID ImGui expects.
--]]
local function tex_ptr(tex)
    return tonumber(ffi.cast('uint32_t', tex));
end

--[[
* Composes the state line as Discord renders it: "<state> (<current> of <max>)"
* when a party slot count is present, else just the state line.
--]]
local function state_line(p)
    if (p.party ~= nil) then
        return ('%s (%d of %d)'):format(p.state, p.party[1], p.party[2]);
    end
    return p.state;
end

--[[
* Renders a Discord-style activity card: the large game image with the
* job/status icon as a corner badge, then the details/state text to the right.
* Falls back to text-only if the textures can't be loaded.
--]]
local function draw_preview_card(p)
    local large = load_texture(asset_path(p.largeImage));
    if (large == nil) then
        imgui.Text(p.details);
        imgui.Text(state_line(p));
        return;
    end

    local small = load_texture(asset_path(p.smallImage));
    local dl = imgui.GetWindowDrawList();
    local x0, y0 = imgui.GetCursorScreenPos();
    local x1, y1 = x0 + PREVIEW_LARGE, y0 + PREVIEW_LARGE;

    dl:AddImage(tex_ptr(large), { x0, y0 }, { x1, y1 }, { 0, 0 }, { 1, 1 }, 0xFFFFFFFF);

    -- Small badge in the bottom-right corner, with a dark ring behind it so a
    -- transparent icon still reads against the large image (as Discord does).
    if (small ~= nil) then
        local bx0, by0 = x1 - PREVIEW_SMALL, y1 - PREVIEW_SMALL;
        dl:AddRectFilled({ bx0 - 2, by0 - 2 }, { x1 + 2, y1 + 2 }, 0xCC000000, (PREVIEW_SMALL + 4) / 2);
        dl:AddImage(tex_ptr(small), { bx0, by0 }, { x1, y1 }, { 0, 0 }, { 1, 1 }, 0xFFFFFFFF);
    end

    -- Reserve the layout box the draw-list calls painted into.
    imgui.Dummy({ PREVIEW_LARGE, PREVIEW_LARGE });

    -- Image hover text, matching Discord's large/small image tooltips.
    if (imgui.IsItemHovered()) then
        local over_badge = (small ~= nil)
            and imgui.IsMouseHoveringRect({ x1 - PREVIEW_SMALL, y1 - PREVIEW_SMALL }, { x1, y1 });
        if (over_badge and p.smallText ~= nil) then
            imgui.SetTooltip(p.smallText);
        elseif (p.largeText ~= nil) then
            imgui.SetTooltip(p.largeText);
        end
    end

    -- Text block, vertically centered against the image like the real card.
    imgui.SameLine();
    local off_y = math.max(0, (PREVIEW_LARGE - imgui.GetTextLineHeight() * 3) / 2);
    local cx, cy = imgui.GetCursorScreenPos();
    imgui.SetCursorScreenPos({ cx, cy + off_y });
    imgui.BeginGroup();
    imgui.Text('Phoenix XI');
    imgui.TextColored(COLOR_DIM, p.details);
    imgui.TextColored(COLOR_DIM, state_line(p));
    imgui.EndGroup();
end

--[[
* Toggles window visibility (bound to /phxpresence config).
--]]
function ui.toggle()
    ui.is_open[1] = not ui.is_open[1];
end

--[[
* Renders the config window. Call every frame from d3d_present.
*
* @param {table} ctx - {
*     config            : the persisted settings table (mutated in place),
*     runtime           : { seeking, away } live in-game flags (read-only here),
*     anon              : boolean, the in-game /anon flag is active (read-only),
*     status            : connection status string,
*     connected         : boolean, pipe connected,
*     ready             : boolean, handshake complete,
*     preview           : { details, state, largeImage, smallImage, largeText,
*                           smallText } or nil when nothing is publishable,
*     set_enabled(v)    : enable/disable presence (connects/disconnects + saves),
*     on_config_change(): a persisted display option changed (save + refresh),
*     on_reconnect()    : force a Discord reconnect,
* }
--]]
function ui.render(ctx)
    if (not ui.is_open[1]) then
        return;
    end

    -- Pull current values into the widget buffers.
    r.enabled[1]  = ctx.config.enabled;
    r.showName[1] = ctx.config.showName;
    r.showJob[1] = ctx.config.showJob;
    r.showParty[1] = ctx.config.showParty;
    r.hidePartyWhenSolo[1] = ctx.config.hidePartyWhenSolo;
    r.showZone[1] = ctx.config.showZone;

    imgui.SetNextWindowSize({ 340, 0 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('phxpresence', ui.is_open, ImGuiWindowFlags_None)) then
        -- Connection status + reconnect.
        imgui.Text('Discord:');
        imgui.SameLine();
        local color, label;
        if (not ctx.connected) then
            color, label = COLOR_OFF, 'disconnected';
        elseif (not ctx.ready) then
            color, label = COLOR_WARN, 'handshaking';
        else
            color, label = COLOR_OK, 'connected';
        end
        imgui.TextColored(color, label);
        imgui.SameLine();
        if (imgui.SmallButton('Reconnect')) then
            ctx.on_reconnect();
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip(ctx.status);
        end

        imgui.Separator();

        -- Master enable.
        if (imgui.Checkbox('Enabled', r.enabled)) then
            ctx.set_enabled(r.enabled[1]);
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Publish Rich Presence to Discord.');
        end

        imgui.Separator();
        imgui.TextColored(COLOR_DIM, 'Display');

        if (imgui.Checkbox('Show character name', r.showName)) then
            ctx.config.showName = r.showName[1];
            ctx.on_config_change();
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Your name is visible to friends and shared servers.');
        end

        if (imgui.Checkbox('Show job', r.showJob)) then
            ctx.config.showJob = r.showJob[1];
            ctx.on_config_change();
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Show your job/level (e.g. WAR99/NIN49) and the job icon.');
        end

        if (imgui.Checkbox('Show party info', r.showParty)) then
            ctx.config.showParty = r.showParty[1];
            ctx.on_config_change();
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Show party/alliance membership and the slot count.');
        end

        -- Sub-option of "Show party info"; inert (and grayed) when party info is off.
        local partyOff = not r.showParty[1];
        if (partyOff and imgui.BeginDisabled ~= nil) then imgui.BeginDisabled(true); end
        imgui.Indent();
        if (imgui.Checkbox('Hide while solo', r.hidePartyWhenSolo)) then
            ctx.config.hidePartyWhenSolo = r.hidePartyWhenSolo[1];
            ctx.on_config_change();
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('When solo, omit party info entirely (no "Solo" shown).');
        end
        imgui.Unindent();
        if (partyOff and imgui.EndDisabled ~= nil) then imgui.EndDisabled(); end

        if (imgui.Checkbox('Show current zone', r.showZone)) then
            ctx.config.showZone = r.showZone[1];
            ctx.on_config_change();
        end

        imgui.Separator();
        imgui.TextColored(COLOR_DIM, 'Status (from in-game flags)');

        -- These mirror your /seek, /away and /anon flags - they're detected from
        -- game packets, not set here.
        local shown = false;
        if (ctx.runtime.seeking) then
            imgui.TextColored(COLOR_OK, 'Seeking party');
            shown = true;
        end
        if (ctx.runtime.away) then
            imgui.TextColored(COLOR_WARN, 'Away');
            shown = true;
        end
        if (ctx.anon) then
            imgui.TextColored(COLOR_WARN, 'Anonymous (/anon)');
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip('You are /anon in-game: job, zone and party are hidden from presence.');
            end
            shown = true;
        end
        if (not shown) then
            imgui.TextColored(COLOR_DIM, 'Available');
        end

        imgui.Separator();
        imgui.TextColored(COLOR_DIM, 'Preview');
        if (ctx.preview ~= nil) then
            draw_preview_card(ctx.preview);
        else
            imgui.TextColored(COLOR_OFF, 'Nothing to show (logged out or zoning).');
        end
    end
    imgui.End();
end

return ui;
