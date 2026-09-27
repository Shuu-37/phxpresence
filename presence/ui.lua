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
* Renders the preview without touching the game's Direct3D device.
--]]
local function draw_preview_card(p)
    imgui.Text('Phoenix XI');
    imgui.TextColored(COLOR_DIM, p.details);
    imgui.TextColored(COLOR_DIM, state_line(p));
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
*     connected         : boolean, Discord transport connected,
*     ready             : boolean, handshake complete,
*     preview           : { details, state, party } or nil when nothing is publishable,
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
