--[[
* phxpresence - Discord Rich Presence for FFXI
* Copyright (c) 2026 Shuu-37 [github.com/Shuu-37/phxpresence]
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
* Builds the social status fragment for the state line (the slot count is shown
* separately by the party pill). Away/Seeking are status and always show; the
* "In alliance"/"In party"/"Solo" membership text is party info, gated by
* opts.showParty, and the "Solo" case is further suppressed by
* opts.hidePartyWhenSolo. Returns nil when there's nothing to show.
--]]
local function social_line(snap, opts)
    if (opts.away) then
        return 'Away';
    end
    if (opts.seeking) then
        return 'Seeking party';
    end
    if (not opts.showParty) then
        return nil;
    end
    if (snap.inAlliance) then
        return 'In alliance';
    end
    if (snap.partySize > 1) then
        return 'In party';
    end
    if (opts.hidePartyWhenSolo) then
        return nil;
    end
    return 'Solo';
end

--[[
* Builds a Discord activity object from a snapshot.
*
* @param {table} snap - Snapshot from state.snapshot().
* @param {table} opts - Display options:
*   showName    {boolean} - prefix the character name in details.
*   showJob     {boolean} - include the job/level line and the job icon.
*   showParty   {boolean} - include the party slot pill and membership text.
*   hidePartyWhenSolo {boolean} - suppress party info while solo (sub of showParty).
*   showZone    {boolean} - show the current zone (state line + image hover text).
*   seeking     {boolean} - player is seeking party.
*   away        {boolean} - player is away.
*   anon        {boolean} - player is /anon; hide job, zone and party.
*   seacom      {string}  - search comment (/seacom); used as the job-icon hover
*                          text when set, else the job line.
*   startTime   {number}  - epoch seconds for the elapsed timer.
* @return {table} Discord activity object.
--]]
function activity.build(snap, opts)
    opts = opts or T{};

    -- /anon: respect the in-game anonymous flag. It hides job/level (and we extend
    -- that to zone and party) from other players, so keep the presence to just the
    -- character name (anon doesn't hide that) and the elapsed timer.
    if (opts.anon) then
        local act = T{
            type    = 0, -- Playing
            state   = 'Anonymous',
            assets  = T{ large_image = GAME_IMAGE, large_text = 'Phoenix XI' },
        };
        if (opts.showName and snap.name ~= nil) then
            act.details = snap.name;
        end
        if (opts.startTime ~= nil and opts.startTime > 0) then
            act.timestamps = T{ start = opts.startTime };
        end
        return act;
    end

    -- Line 2 (details): name and/or job, e.g. "<name> - <JOB##/SUB##>". Either piece
    -- can be hidden, leaving the other alone or omitting details entirely.
    local nameShown = opts.showName and snap.name ~= nil;
    local details;
    if (nameShown and opts.showJob) then
        details = ('%s - %s'):format(snap.name, snap.jobLine);
    elseif (nameShown) then
        details = snap.name;
    elseif (opts.showJob) then
        details = snap.jobLine;
    end

    -- Line 3 (state): "<Zone> - <social>", "<social>" or just "<Zone>" depending on
    -- which pieces are present; nil when neither is shown.
    local social = social_line(snap, opts);
    local state;
    if (opts.showZone) then
        state = social and ('%s - %s'):format(snap.zoneName, social) or snap.zoneName;
    else
        state = social;
    end
    local act = T{
        type    = 0, -- Playing
        details = details,
        state   = state,
    };

    -- Party slot pill (only when grouped and enabled).
    if (opts.showParty) then
        if (snap.inAlliance) then
            act.party = T{ size = T{ snap.allianceSize, 18 } };
        elseif (snap.partySize > 1) then
            act.party = T{ size = T{ snap.partySize, 6 } };
        end
    end

    -- Assets: the FFXI game icon as the large image (current zone as its hover text
    -- when shown, else the game name), job icon as the small image.
    local assets = T{
        large_image = GAME_IMAGE,
        large_text  = opts.showZone and snap.zoneName or 'Phoenix XI',
    };

    -- Small image: a status icon (assets/status/) takes precedence over the job
    -- icon when /away or /seek is set, matching social_line's away > seeking order.
    if (opts.away) then
        assets.small_image = 'away';
        assets.small_text  = 'Away';
    elseif (opts.seeking) then
        assets.small_image = 'seeking';
        assets.small_text  = 'Seeking party';
    elseif (opts.showJob and snap.mainAbbr ~= nil) then
        -- Job-icon asset keys match the filenames in assets/jobs/ (e.g. 'war'). The
        -- hover text prefers the search comment (/seacom) when set, falling back to
        -- the job line; the icon itself is always the job.
        assets.small_image = snap.mainAbbr:lower();
        if (opts.seacom ~= nil and #opts.seacom > 0) then
            assets.small_text = opts.seacom;
        else
            assets.small_text = snap.jobLine;
        end
    end

    act.assets = assets;

    if (opts.startTime ~= nil and opts.startTime > 0) then
        act.timestamps = T{ start = opts.startTime };
    end

    return act;
end

return activity;
