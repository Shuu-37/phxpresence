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

-- Static large image: the FFXI game icon (assets/ffxi.png), uploaded to the Discord
-- application's Rich Presence art assets under this key (see README). The current
-- zone is shown as the image hover text and in the details line - per-zone art is
-- on hold.
local GAME_IMAGE = 'ffxi';

--[[
* Builds the social status fragment (the party slot count is shown separately by
* the party pill).
--]]
local function social_line(snap, opts)
    if (opts.away) then
        return 'Away';
    end
    if (opts.seeking) then
        return 'Seeking party';
    end
    if (snap.inAlliance) then
        return 'In alliance';
    end
    if (snap.partySize > 1) then
        return 'In party';
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

    -- Line 2 (details): "<name> - <JOB##/SUB##>"; line 3 (state): "<Zone> - <social>".
    local details;
    if (opts.showName and snap.name ~= nil) then
        details = ('%s - %s'):format(snap.name, snap.jobLine);
    else
        details = snap.jobLine;
    end

    local act = T{
        type    = 0, -- Playing
        details = details,
        state   = ('%s - %s'):format(snap.zoneName, social_line(snap, opts)),
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

    if (snap.mainAbbr ~= nil) then
        -- Job-icon asset keys match the filenames in assets/jobs/ (e.g. 'war').
        assets.small_image = snap.mainAbbr:lower();
        assets.small_text  = snap.jobLine;
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
