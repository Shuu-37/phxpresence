--[[
* xipresence - Discord Rich Presence for FFXI
* Copyright (c) 2026 Shuu-37 [github.com/Shuu-37/xipresence]
* MIT License
*
* presence/state.lua
* Reads the live game state into a plain snapshot table. Returns nil whenever the
* player isn't in a state worth publishing (logged out, zoning, no job), so the
* caller never posts garbage presence.
--]]

local state = {};

-- Fallback job abbreviations (1..22 + monstrosity), used if the resource lookup
-- returns nothing.
local JOB_ABBR = T{
    [1]='WAR', [2]='MNK', [3]='WHM', [4]='BLM', [5]='RDM', [6]='THF',
    [7]='PLD', [8]='DRK', [9]='BST', [10]='BRD', [11]='RNG', [12]='SAM',
    [13]='NIN', [14]='DRG', [15]='SMN', [16]='BLU', [17]='COR', [18]='PUP',
    [19]='DNC', [20]='SCH', [21]='GEO', [22]='RUN',
};

-- entity.Status values we care about.
local STATUS = {
    IDLE    = 0,
    ENGAGED = 1,
    DEAD    = 2,
    EVENT   = 3,
};

--[[
* Resolves a job id to its abbreviation (WAR, NIN, ...).
--]]
local function job_abbr(id)
    if (id == nil or id == 0) then
        return nil;
    end
    local res = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', id);
    if (res ~= nil and #res > 0) then
        return res;
    end
    return JOB_ABBR[id];
end

--[[
* Counts active members in the player's immediate party (indices 0..5).
--]]
local function party_size(party)
    local n = 0;
    for i = 0, 5 do
        if (party:GetMemberIsActive(i) == 1) then
            n = n + 1;
        end
    end
    return n;
end

--[[
* Total alliance member count across all three parties.
--]]
local function alliance_size(party)
    return (party:GetAlliancePartyMemberCount1() or 0)
         + (party:GetAlliancePartyMemberCount2() or 0)
         + (party:GetAlliancePartyMemberCount3() or 0);
end

--[[
* Builds a snapshot of the current game state.
*
* @return {table|nil} snapshot, or nil when nothing publishable.
*   Fields: name, mainJob, subJob, mainLevel, subLevel, jobLine, zoneId,
*           zoneName, partySize, allianceSize, inAlliance, status (string).
--]]
function state.snapshot()
    if (AshitaCore == nil) then
        return nil;
    end

    local mm = AshitaCore:GetMemoryManager();
    if (mm == nil) then
        return nil;
    end

    local player = mm:GetPlayer();
    local party  = mm:GetParty();
    local entity = GetPlayerEntity();
    if (player == nil or party == nil or entity == nil) then
        return nil;
    end

    -- Not in-world yet, between zones, or no job loaded -> nothing to show.
    local mainJob = player:GetMainJob();
    if (mainJob == 0 or player:GetIsZoning() ~= 0) then
        return nil;
    end

    local name = entity.Name;
    if (name == nil or #name == 0) then
        return nil;
    end

    local subJob = player:GetSubJob();
    local mainAbbr = job_abbr(mainJob);
    local subAbbr  = job_abbr(subJob);
    local mainLevel = player:GetMainJobLevel();
    local subLevel  = player:GetSubJobLevel();

    -- FFXI-standard job line with levels, e.g. "WAR99/NIN49" (or "WAR99" subless).
    local jobLine;
    if (subAbbr ~= nil) then
        jobLine = ('%s%d/%s%d'):format(mainAbbr or '???', mainLevel, subAbbr, subLevel);
    else
        jobLine = ('%s%d'):format(mainAbbr or '???', mainLevel);
    end

    local zoneId   = party:GetMemberZone(0) or 0;
    local zoneName = AshitaCore:GetResourceManager():GetString('zones.names', zoneId);
    if (zoneName == nil or #zoneName == 0) then
        zoneName = 'Vana\'diel';
    end

    local pSize = party_size(party);
    local aSize = alliance_size(party);
    local inAlliance = aSize > pSize and aSize > 6;

    local statusStr = 'idle';
    local st = entity.Status;
    if (st == STATUS.ENGAGED) then
        statusStr = 'engaged';
    elseif (st == STATUS.DEAD) then
        statusStr = 'dead';
    elseif (st == STATUS.EVENT) then
        statusStr = 'event';
    end

    return T{
        name         = name,
        mainJob      = mainJob,
        subJob       = subJob,
        mainLevel    = mainLevel,
        subLevel     = subLevel,
        mainAbbr     = mainAbbr,
        jobLine      = jobLine,
        zoneId       = zoneId,
        zoneName     = zoneName,
        partySize    = pSize,
        allianceSize = aSize,
        inAlliance   = inAlliance,
        status       = statusStr,
    };
end

return state;
