--[[
* minimapenhanced: minimap zoom per zone. Pure Lua; the caller injects:
*   io.queue(cmd)      send a chat command (the Ashita v4 minimap plugin's '/minimap zoom <amount>')
*   io.read_ini()      the minimap's zoom from config/minimap/minimap.ini (number or nil)
*   io.saved(zone, v)  a zone zoom was saved (caller persists settings)
*
* Which zoom a zone gets:
*   1. the zoom saved for that zone (zoom_overrides; set automatically when you change the zoom
*      there, or with /mme zoom set <n>)
*   2. first visit: the safe-zone or hostile-zone zoom (if zoom by zone type is enabled)
*   3. default_zoom
*
* Timing (1.1.0): the minimap plugin keeps ONE zoom for every zone, so on arrival it draws the new
* map at the zoom of the zone you left until we send the new one. 1.0.0 sent it `delay` seconds after
* zoning had finished, which is the jump you could see. Now:
*   1. early: the zoom is sent as soon as the zone-in packet names the new zone (during the load
*      screen), so the map normally arrives at the right zoom;
*   2. on arrival: minimap.ini is checked; if it does not show the zoom yet, it is sent again
*      (checked CONFIRM_GAP later, then once more RETRY_GAP later);
*   3. `delay` seconds after arrival: one last check (and send if needed), in case the plugin reset
*      its zoom while loading the map.
* settled() tells the caller when the zoom is confirmed (or given up on), so it can keep the minimap
* hidden until then and fade it in.
*
* Manual change = a '/minimap zoom <n>' / '/mm zoom <n>' we did not send, or the minimap.ini zoom
* changing to a value we did not send (editor slider / mouse wheel: the plugin stores every zoom
* change through Ashita's configuration manager). Checked every POLL seconds and on leaving a zone.
* The plugin clamps zoom to 0.1 - 2.0, so we clamp too (otherwise its stored value would differ
* from what we sent and look like a manual change).
--]]
local zones = require('mmzones')

local M = { RETRY_GAP = 1.5, CONFIRM_GAP = 0.25, EARLY_WINDOW = 60, POLL = 0.5, EXPECT_WINDOW = 3.0, EPS = 0.005, MIN = 0.1, MAX = 2.0 }

local Z = {}; Z.__index = Z

function M.new(io)
    return setmetatable({
        io = io, pending = nil, expect = {}, sent = nil,
        last_ini = nil, next_poll = 0, sends = 0, last_source = nil, last_target = nil, last_manual = nil,
    }, Z)
end

function M.clamp(v)
    v = tonumber(v) or 1
    if v ~= v then v = 1 end
    if v < M.MIN then return M.MIN elseif v > M.MAX then return M.MAX end
    return v
end

function M.fmt(v)
    local s = ('%.2f'):format(M.clamp(v))
    s = s:gsub('0+$', ''):gsub('%.$', '')
    return s
end

local function close(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < M.EPS end

-- Returns zoom, source ('saved'|'safe'|'hostile'|'default')
function Z:resolve(zone, s)
    local cfg = s.zoom_by_type or {}
    zone = tonumber(zone)
    if zone == nil then return M.clamp(s.default_zoom), 'default' end
    local o = s.zoom_overrides and tonumber(s.zoom_overrides[zone])
    if o ~= nil then return M.clamp(o), 'saved' end
    if cfg.enabled ~= false then
        if zones.classify(zone) == 'safe' then return M.clamp(cfg.safe), 'safe' end
        return M.clamp(cfg.hostile), 'hostile'
    end
    return M.clamp(s.default_zoom), 'default'
end

function Z:on_zone_in(zone)
    self.pending = { zone = tonumber(zone), at = nil, tries = 0 }
end

-- Zone-in packet: send the new zone's zoom right away, while the load screen is up. Expected for
-- EARLY_WINDOW seconds, because a long load screen must not make it look like a manual change.
function Z:send_early(now, s, zone)
    zone = tonumber(zone)
    if zone == nil then return nil end
    if self.pending == nil or self.pending.zone ~= zone then self:on_zone_in(zone) end
    local v, src = self:resolve(zone, s)
    self.last_target, self.last_source = v, src
    self:send(now, v, M.EARLY_WINDOW)
    self.pending.early = true
    return v
end

-- Zoning finished (player exists in the new zone): check at once, and once more `delay` later.
function Z:on_ready(now, s, zone)
    if self.pending == nil or self.pending.zone ~= tonumber(zone) then self.pending = { zone = tonumber(zone), tries = 0 } end
    local d = tonumber((s.zoom_by_type or {}).delay) or 1.0
    self.pending.at = now
    self.pending.final = now + math.max(0, d)
    self.pending.confirmed = false
end

-- true once this zone's zoom is confirmed in minimap.ini, given up on, or you changed it yourself.
function Z:settled()
    local p = self.pending
    return p == nil or p.confirmed == true
end

function Z:send(now, value, window)
    local str = M.fmt(value)
    local untilt = now + (window or M.EXPECT_WINDOW)
    self.expect[#self.expect + 1] = { v = tonumber(str), untilt = untilt }
    self.sent = { v = tonumber(str), untilt = untilt }
    self.sends = self.sends + 1
    self.io.queue('/minimap zoom ' .. str)
end

function Z:apply_now(now, s, zone)
    local v, src = self:resolve(zone, s)
    self.last_target, self.last_source = v, src
    self.pending = nil
    self:send(now, v)
    return v, src
end

-- You changed the zoom in `zone`: save it as that zone's zoom (if auto-save is on).
function Z:mark_manual(zone, v, s)
    zone = tonumber(zone)
    v = M.clamp(v)
    self.last_manual = { zone = zone, v = v }
    if self.pending ~= nil and self.pending.zone == zone then self.pending = nil end -- your change wins
    if zone == nil or s == nil then return false end
    if (s.zoom_by_type or {}).auto_save == false then return false end
    local cur = tonumber(s.zoom_overrides[zone])
    if close(cur, v) then return false end
    -- Back at exactly the zone's default with nothing saved: nothing to remember.
    if cur == nil and close(self:resolve(zone, s), v) then return false end
    s.zoom_overrides[zone] = v
    if self.io.saved then self.io.saved(zone, v) end
    return true
end

-- A '/minimap zoom <v>' command was seen. Returns 'ours' or 'manual'.
function Z:on_command(now, v, zone, s)
    v = tonumber(v)
    if v == nil then return nil end
    for i = #self.expect, 1, -1 do
        local e = self.expect[i]
        if now > e.untilt then table.remove(self.expect, i)
        elseif close(e.v, M.clamp(v)) then table.remove(self.expect, i); return 'ours' end
    end
    self:mark_manual(zone, v, s)
    return 'manual'
end

-- Check minimap.ini; a change to a value we didn't send = manual change in `zone`.
function Z:poll_ini(now, zone, s)
    local v = self.io.read_ini()
    if v == nil then return nil end
    if self.last_ini == nil then self.last_ini = v; return v end
    if not close(v, self.last_ini) then
        self.last_ini = v
        local sent = self.sent
        if sent ~= nil and now <= sent.untilt and close(v, sent.v) then
            self.sent = nil -- the minimap stored the zoom we sent: not a manual change
            return v
        end
        self:mark_manual(zone, v, s)
        return v, 'manual'
    end
    return v
end

-- Leaving a zone: last chance to catch a change made there.
function Z:on_zone_out(now, s, zone)
    self:poll_ini(now, zone, s)
    self.pending = nil
end

function Z:tick(now, s, zone)
    if now >= self.next_poll then
        self.next_poll = now + M.POLL
        self:poll_ini(now, zone, s)
    end
    local p = self.pending
    if p == nil or p.at == nil or now < p.at then return false end
    if p.zone ~= tonumber(zone) then self.pending = nil; return false end
    local v, src = self:resolve(zone, s)
    self.last_target, self.last_source = v, src
    local want = tonumber(M.fmt(v))
    local ini = self.io.read_ini()
    if close(ini, want) then
        -- The minimap has it. Remember the value so poll_ini doesn't take our own send for yours.
        p.confirmed = true
        self.last_ini = ini
        if self.sent ~= nil and close(self.sent.v, want) then self.sent = nil end
        if p.final ~= nil and now < p.final then p.at = p.final else self.pending = nil end
        return false
    end
    if p.tries >= 2 then
        -- Sent twice since arriving and still not shown: stop (never spam), let the map show.
        p.confirmed = true
        self.pending = nil
        return false
    end
    self:send(now, v)
    p.tries = p.tries + 1
    p.at = now + (p.tries == 1 and M.CONFIRM_GAP or M.RETRY_GAP)
    return true
end

return M
