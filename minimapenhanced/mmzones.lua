--[[
* minimapcontrol 1.4: safe (city/town/indoor/residential/transport) zone table.
* Zone ids checked against LandSandBoat sql/zone_settings.sql (zonetype column, ZONE_TYPE_CITY = 0x01,
* commit 759efe8, Jul 2025). Everything not listed counts as hostile / field.
* Deliberately left out although LSB tags them CITY: 0 (unknown), 32 Sealion's Den (battlefield),
* 189 Outer Ra'Kaznar [U3]. Added although LSB doesn't tag them CITY: Nashmau (LSB: outdoors),
* Leafallia, the boats and airships, and Phanauet Channel / Manaclipper (barge and ferry rides).
--]]
local M = {}

M.SAFE = {
    -- San d'Oria
    [230] = { 'Southern San d\'Oria', 'city' }, [231] = { 'Northern San d\'Oria', 'city' },
    [232] = { 'Port San d\'Oria', 'city' },    [233] = { 'Chateau d\'Oraguille', 'city' },
    -- Bastok
    [234] = { 'Bastok Mines', 'city' }, [235] = { 'Bastok Markets', 'city' },
    [236] = { 'Port Bastok', 'city' },  [237] = { 'Metalworks', 'city' },
    -- Windurst
    [238] = { 'Windurst Waters', 'city' }, [239] = { 'Windurst Walls', 'city' },
    [240] = { 'Port Windurst', 'city' },   [241] = { 'Windurst Woods', 'city' },
    [242] = { 'Heavens Tower', 'city' },
    -- Jeuno
    [243] = { 'Ru\'Lude Gardens', 'city' }, [244] = { 'Upper Jeuno', 'city' },
    [245] = { 'Lower Jeuno', 'city' },      [246] = { 'Port Jeuno', 'city' },
    -- Past (WotG) cities
    [80] = { 'Southern San d\'Oria [S]', 'city' }, [87] = { 'Bastok Markets [S]', 'city' },
    [94] = { 'Windurst Waters [S]', 'city' },
    -- Aht Urhgan / Tavnazia
    [50] = { 'Aht Urhgan Whitegate', 'city' }, [48] = { 'Al Zahbi', 'city' },
    [53] = { 'Nashmau', 'town' },              [26] = { 'Tavnazian Safehold', 'town' },
    -- Towns
    [248] = { 'Selbina', 'town' }, [249] = { 'Mhaura', 'town' }, [250] = { 'Kazham', 'town' },
    [252] = { 'Norg', 'town' },    [247] = { 'Rabao', 'town' },
    -- Adoulin
    [256] = { 'Western Adoulin', 'city' }, [257] = { 'Eastern Adoulin', 'city' },
    [284] = { 'Celennia Memorial Library', 'indoor' }, [281] = { 'Leafallia', 'town' },
    -- Indoor / special safe areas
    [280] = { 'Mog Garden', 'residential' }, [285] = { 'Feretory', 'indoor' },
    [70] = { 'Chocobo Circuit', 'indoor' },  [71] = { 'The Colosseum', 'indoor' },
    [251] = { 'Hall of the Gods', 'indoor' },
    -- Residential areas (rented rooms / mog house corridors)
    [199] = { 'Residential Area', 'residential' }, [214] = { 'Residential Area', 'residential' },
    [219] = { 'Residential Area', 'residential' },
    -- Airships
    [223] = { 'San d\'Oria-Jeuno Airship', 'transport' }, [224] = { 'Bastok-Jeuno Airship', 'transport' },
    [225] = { 'Windurst-Jeuno Airship', 'transport' },    [226] = { 'Kazham-Jeuno Airship', 'transport' },
    -- Boats / ferries
    [220] = { 'Ship bound for Selbina', 'transport' }, [221] = { 'Ship bound for Mhaura', 'transport' },
    [227] = { 'Ship bound for Selbina (Pirates)', 'transport' }, [228] = { 'Ship bound for Mhaura (Pirates)', 'transport' },
    [46] = { 'Open sea route to Al Zahbi', 'transport' }, [47] = { 'Open sea route to Mhaura', 'transport' },
    [58] = { 'Silver Sea route to Nashmau', 'transport' }, [59] = { 'Silver Sea route to Al Zahbi', 'transport' },
    [1] = { 'Phanauet Channel', 'transport' }, [3] = { 'Manaclipper', 'transport' },
}

-- 'safe' or 'hostile', plus the kind ('city', 'town', 'indoor', 'residential', 'transport', 'field')
function M.classify(zone_id)
    local z = M.SAFE[tonumber(zone_id) or -1]
    if z then return 'safe', z[2] end
    return 'hostile', 'field'
end

function M.is_safe(zone_id) return M.classify(zone_id) == 'safe' end

-- Display name: the game's own resource strings when available, else our table, else the id.
function M.name(zone_id, resources)
    zone_id = tonumber(zone_id)
    if zone_id == nil then return 'unknown' end
    if resources ~= nil then
        local ok, n = pcall(function () return resources:GetString('zones.names', zone_id) end)
        if ok and type(n) == 'string' and n ~= '' then return n end
    end
    local z = M.SAFE[zone_id]
    if z then return z[1] end
    return ('Zone %d'):format(zone_id)
end

return M
