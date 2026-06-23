--[[
* xipresence - Discord Rich Presence for FFXI
* Copyright (c) 2026 Shuu-37 [github.com/Shuu-37/xipresence]
* MIT License
*
* presence/activity.lua
* Maps a game-state snapshot (presence/state.lua) into a Discord activity object
* suitable for SET_ACTIVITY.
--]]

local activity = {};

-- Static large image: the FFXI game icon, uploaded to the Discord application's
-- Rich Presence art assets under this key (see README). The current zone is shown
-- as the image hover text and in the details line - per-zone art is on hold.
local GAME_IMAGE = 'ffxi';

--[[
* Builds the state line describing what the player is doing socially.
--]]
local function state_line(snap, opts)
    if (opts.away) then
        return 'Away';
    end
    if (opts.seeking) then
        return 'Seeking party';
    end
    if (snap.inAlliance) then
        return ('In alliance (%d/18)'):format(snap.allianceSize);
    end
    if (snap.partySize > 1) then
        return ('In party (%d/6)'):format(snap.partySize);
    end
    return 'Solo';
end

--[[
* Builds a Discord activity object from a snapshot.
*
* @param {table} snap - Snapshot from state.snapshot().
* @param {table} opts - Display options:
*   showName    {boolean} - prefix the character name in details.
*   showParty   {boolean} - include the party slot pill.
*   showZoneArt {boolean} - use zone art for the large image.
*   seeking     {boolean} - player is seeking party.
*   away        {boolean} - player is away.
*   startTime   {number}  - epoch seconds for the elapsed timer.
* @return {table} Discord activity object.
--]]
function activity.build(snap, opts)
    opts = opts or T{};

    -- details: "<name> - <JOB/SUB>, in <Zone>"
    local details;
    local jobZone = ('%s, in %s'):format(snap.jobLine, snap.zoneName);
    if (opts.showName and snap.name ~= nil) then
        details = ('%s - %s'):format(snap.name, jobZone);
    else
        details = jobZone;
    end

    local act = T{
        type    = 0, -- Playing
        details = details,
        state   = state_line(snap, opts),
    };

    -- Party slot pill (only when grouped and enabled).
    if (opts.showParty) then
        if (snap.inAlliance) then
            act.party = T{ size = T{ snap.allianceSize, 18 } };
        elseif (snap.partySize > 1) then
            act.party = T{ size = T{ snap.partySize, 6 } };
        end
    end

    -- Assets: the FFXI game icon as the large image (zone shown as hover text),
    -- job icon as the small image.
    local assets = T{};
    if (opts.showZoneArt) then
        assets.large_image = GAME_IMAGE;
        assets.large_text  = snap.zoneName;
    end

    local jobAbbr = snap.jobLine:match('^[^/]+');
    if (jobAbbr ~= nil) then
        -- Job-icon keys are uploaded to the Discord dev portal as job_<abbr>.
        assets.small_image = ('job_%s'):format(jobAbbr:lower());
        assets.small_text  = ('%s (Lv%d)'):format(snap.jobLine, snap.mainLevel or 0);
    end

    -- Only attach assets if non-empty (json renders {} as []).
    if (next(assets) ~= nil) then
        act.assets = assets;
    end

    if (opts.startTime ~= nil and opts.startTime > 0) then
        act.timestamps = T{ start = opts.startTime };
    end

    return act;
end

return activity;
