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
* Timing: the zoom is sent `delay` seconds after zoning has finished (so the minimap has loaded the
* new zone's map), then once more RETRY_GAP later unless minimap.ini already shows it or you changed
* the zoom yourself in between. Never more than 2 sends per zone-in.
*
* Manual change = a '/minimap zoom <n>' / '/mm zoom <n>' we did not send, or the minimap.ini zoom
* changing to a value we did not send (editor slider / mouse wheel: the plugin stores every zoom
* change through Ashita's configuration manager). Checked every POLL seconds and on leaving a zone.
* The plugin clamps zoom to 0.1 - 2.0, so we clamp too (otherwise its stored value would differ
* from what we sent and look like a manual change).
--]]
local zones = require('mmzones')

local M = { RETRY_GAP = 1.5, POLL = 0.5, EXPECT_WINDOW = 3.0, EPS = 0.005, MIN = 0.1, MAX = 2.0 }

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

function Z:on_ready(now, s, zone)
    if self.pending == nil or self.pending.zone ~= tonumber(zone) then self.pending = { zone = tonumber(zone), tries = 0 } end
    local d = tonumber((s.zoom_by_type or {}).delay) or 1.0
    self.pending.at = now + math.max(0, d)
end

function Z:send(now, value)
    local str = M.fmt(value)
    self.expect[#self.expect + 1] = { v = tonumber(str), untilt = now + M.EXPECT_WINDOW }
    self.sent = { v = tonumber(str), untilt = now + M.EXPECT_WINDOW }
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
    if p.tries >= 1 then
        local ini = self.io.read_ini()
        if close(ini, tonumber(M.fmt(v))) then self.pending = nil; return false end
    end
    self:send(now, v)
    p.tries = p.tries + 1
    if p.tries >= 2 then self.pending = nil else p.at = now + M.RETRY_GAP end
    return true
end

return M
