--[[
* minimapenhanced core logic. Pure Lua: no Ashita calls, so it can be tested offline.
*
*   Gate     - turns the per-frame list of "hide reasons" into a stable shown/hidden target:
*              hides on the same frame a reliable reason appears, filters single-frame menu/chat
*              blips (menu_debounce), and only shows again once every reason has been gone for
*              show_delay seconds (hysteresis, no flicker between menus or between pulls).
*   Fader    - moves a 0..1 level toward the target at 1/fade_in or 1/fade_out per real second,
*              eased with smoothstep. Direction changes are continuous (no jumps).
*   Sender   - decides when to raise the minimap opacity event: only when the value changed,
*              at most update_hz times a second during a fade, but always at once on a
*              direction change and on the final value of a fade.
*   Threats  - deterministic combat tracking: monsters that hit/cast on you or your party
*              (expire after aggro_timeout unless still claimed by the party), plus monsters
*              claimed by the party (from entity memory, not packet guesses).
*   Moving   - "moving" with a short hold so a frame without a position update isn't "stopped".
--]]
local M = {}

-- Reasons are evaluated in this order; the first one is shown in /mmc info as "the" reason.
-- reliable = applies on the same frame; noisy = must last menu_debounce seconds first.
M.REASONS = {
    { key = 'interface_hidden', noisy = false },
    { key = 'moving',           noisy = false },
    { key = 'event',            noisy = false },
    { key = 'any_menu',         noisy = true  },
    { key = 'map',              noisy = true  },
    { key = 'window',           noisy = true  },
    { key = 'command_menu',     noisy = true  },
    { key = 'main_menu',        noisy = true  },
    { key = 'auction',          noisy = true  },
    { key = 'combat',           noisy = false },
    { key = 'chat_expanded',    noisy = true  },
    { key = 'dead',             noisy = false },
}
local NOISY = {}
for _, r in ipairs(M.REASONS) do NOISY[r.key] = r.noisy end
M.NOISY = NOISY

-- Map: reason -> show_when key
M.SHOW_KEY = {
    moving = 'moving', event = 'during_events', any_menu = 'any_menu_open', map = 'map_open',
    window = 'window_open', command_menu = 'command_menu_open', main_menu = 'main_menu_open',
    auction = 'auction_open', combat = 'in_combat', chat_expanded = 'chat_expanded', dead = 'dead',
}

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
M.clamp = clamp
local function num(v, d) v = tonumber(v); if v == nil or v ~= v then return d end return v end
M.num = num

--[[
* Raw hide reasons for this frame.
* sig: { interface_hidden, moving, event, any_menu, map, window, command_menu, main_menu, auction,
*        combat, chat_expanded, dead, editor_open, force }  (booleans; force = 'show'|'hide'|nil)
* Returns: list of reason keys (in priority order), and an override ('show'|'hide'|nil).
--]]
function M.raw_reasons(sig, show_when)
    show_when = show_when or {}
    if sig.force == 'show' then return {}, 'show' end
    if sig.force == 'hide' then return { 'forced' }, 'hide' end
    if sig.editor_open and show_when.minimap_editor_open ~= false then return {}, 'show' end
    local out = {}
    for _, r in ipairs(M.REASONS) do
        local k = r.key
        if sig[k] then
            if k == 'interface_hidden' then
                out[#out + 1] = k                       -- always hides (as before)
            elseif show_when[M.SHOW_KEY[k]] == false then
                out[#out + 1] = k
            end
        end
    end
    return out, nil
end

---------------------------------------------------------------------------
-- Gate
---------------------------------------------------------------------------
local Gate = {}; Gate.__index = Gate
function M.Gate() return setmetatable({ first = {}, visible = true, clear_since = nil, active = {}, last_reason = nil }, Gate) end

-- reasons: list from raw_reasons; override: 'show'|'hide'|nil; t: timing table
function Gate:update(now, reasons, override, t)
    t = t or {}
    local deb = math.max(0, num(t.menu_debounce, 0.05))
    local delay = math.max(0, num(t.show_delay, 0.10))
    local seen = {}
    local effective = {}
    local pending = false          -- a noisy reason that has not lasted menu_debounce yet
    for _, k in ipairs(reasons) do
        seen[k] = true
        if self.first[k] == nil then self.first[k] = now end
        if (not NOISY[k]) or (now - self.first[k] >= deb - 1e-9) then effective[#effective + 1] = k else pending = true end
    end
    for k in pairs(self.first) do if not seen[k] then self.first[k] = nil end end
    self.active = effective

    if override == 'show' then
        self.visible, self.clear_since, self.last_reason = true, nil, nil
        return true, true
    end
    if override == 'hide' or #effective > 0 then
        self.last_reason = effective[1] or 'forced'
        local changed = self.visible
        self.visible, self.clear_since = false, nil
        return false, changed or (override == 'hide')
    end
    -- no (effective) reasons now
    if self.visible then return true, false end
    -- Hidden, but a menu/chat change is still being debounced: don't start the show timer yet, or a
    -- show_delay shorter than menu_debounce would flash the minimap in before it hides again.
    if pending then self.clear_since = nil; return false, false end
    if self.clear_since == nil then self.clear_since = now end
    if now - self.clear_since >= delay - 1e-9 then
        self.visible, self.clear_since, self.last_reason = true, nil, nil
        return true, true
    end
    return false, false
end

function Gate:reset(visible)
    self.first, self.active, self.clear_since, self.last_reason = {}, {}, nil, nil
    self.visible = (visible ~= false)
end

---------------------------------------------------------------------------
-- Fader
---------------------------------------------------------------------------
local Fader = {}; Fader.__index = Fader
function M.Fader(start) return setmetatable({ p = start or 1, last = nil, target = 1 }, Fader) end
function M.ease(p) p = clamp(p, 0, 1); return p * p * (3 - 2 * p) end

-- Advance toward target (1 shown / 0 hidden). Returns eased level.
function Fader:update(now, target_visible, t)
    t = t or {}
    local target = target_visible and 1 or 0
    local dt = 0
    if self.last ~= nil then dt = now - self.last end
    if dt < 0 then dt = 0 end
    self.last = now
    self.target = target
    if self.p ~= target then
        local dur = target == 1 and num(t.fade_in, 0.18) or num(t.fade_out, 0.22)
        if dur <= 0.0005 then
            self.p = target
        else
            -- A long frame (alt-tab, load) simply finishes the fade; no overshoot.
            local step = dt / dur
            if target == 1 then self.p = math.min(1, self.p + step) else self.p = math.max(0, self.p - step) end
        end
    end
    return M.ease(self.p)
end
function Fader:snap(target_visible, now) self.p = target_visible and 1 or 0; self.target = self.p; self.last = now end
function Fader:level() return M.ease(self.p) end
function Fader:done() return self.p == self.target end

---------------------------------------------------------------------------
-- Sender (rate limiter)
---------------------------------------------------------------------------
local Sender = {}; Sender.__index = Sender
function M.Sender() return setmetatable({ last_sent = nil, last_time = -1e9, last_dir = nil, count = 0 }, Sender) end

local function same(a, b)
    if a == nil or b == nil then return false end
    for i = 1, #a do if math.abs(a[i] - b[i]) > 0.0005 then return false end end
    return true
end
M.same_values = same

-- values: array of 6 numbers; dir: 1/-1/0 fade direction; final: fade finished this frame.
-- Returns true when the caller should raise the event now (and records it as sent).
function Sender:want(now, values, dir, final, hz, force)
    if same(values, self.last_sent) and not force then self.last_dir = dir; return false end
    hz = clamp(num(hz, 30), 1, 240)
    local ok = force or final or (self.last_dir ~= dir) or (now - self.last_time >= (1 / hz) - 1e-6)
    if not ok then return false end
    local copy = {}
    for i = 1, #values do copy[i] = values[i] end
    self.last_sent, self.last_time, self.last_dir = copy, now, dir
    self.count = self.count + 1
    return true
end
function Sender:invalidate() self.last_sent = nil end

---------------------------------------------------------------------------
-- Movement with hold
---------------------------------------------------------------------------
local Mover = {}; Mover.__index = Mover
function M.Mover() return setmetatable({ pos = nil, last_move = -1e9 }, Mover) end
function Mover:update(now, x, y, z, hold)
    if x == nil then return false end
    local p = self.pos
    if p ~= nil and (math.abs(p[1] - x) > 1e-4 or math.abs(p[2] - y) > 1e-4 or math.abs(p[3] - z) > 1e-4) then
        self.last_move = now
    end
    self.pos = { x, y, z }
    return (now - self.last_move) < num(hold, 0.25)
end
function Mover:reset() self.pos = nil; self.last_move = -1e9 end

---------------------------------------------------------------------------
-- Threats (combat tracking)
---------------------------------------------------------------------------
--[[
* env (all functions of a target index unless noted):
*   is_mob(i)      spawn flags say monster (0x10)
*   valid(i)       rendered and not hidden (render flags 0x200 set, 0x4000 clear)
*   hp(i)          HP percent
*   status(i)      entity status (2/3 = dead)
*   server_id(i)
*   claim(i)       claim status (server id of the claimer, 0 = unclaimed)
*   max_index      highest index to sweep (0x8FF)
--]]
local Threats = {}; Threats.__index = Threats
function M.Threats(env) return setmetatable({ env = env, hostile = {}, claimed = {}, cursor = 1 }, Threats) end

local band = (bit and bit.band) or function(a, b)
    local r, m = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + m end
        a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
    end
    return r
end

-- Claim id vs a set of friendly server ids. Exact match, or the low 16 bits (how the client
-- stores some claims; same rule other Ashita addons use).
function M.claim_matches(claim, ids)
    if claim == nil or claim == 0 then return false end
    for id in pairs(ids) do
        if claim == id or band(claim, 0xFFFF) == band(id, 0xFFFF) then return true end
    end
    return false
end

-- Is index i a live hostile monster (not friendly, not dead, on screen)?
function Threats:live_mob(i, ctx)
    local e = self.env
    if i == nil or i <= 0 then return false end
    if ctx and ctx.friendly_index and ctx.friendly_index[i] then return false end
    if not e.is_mob(i) or not e.valid(i) then return false end
    if (e.hp(i) or 0) <= 0 then return false end
    local st = e.status(i)
    if st == 2 or st == 3 then return false end
    return true
end

--[[
* Action packet from a monster.
* ctx: { now, party_ids = {id=true}, self_ids = {id=true}, friendly_index = {idx=true},
*        friendly_ids = {id=true}, include_party }
--]]
function Threats:on_action(actor_index, actor_id, target_ids, ctx)
    if actor_index == nil or actor_index <= 0 then return false end
    if ctx.friendly_ids and actor_id and ctx.friendly_ids[actor_id] then return false end -- trusts / party
    if not self:live_mob(actor_index, ctx) then return false end
    local watch = ctx.include_party and ctx.party_ids or ctx.self_ids
    for _, id in ipairs(target_ids) do
        if watch[id] then
            self.hostile[actor_index] = { t = ctx.now, id = actor_id or self.env.server_id(actor_index) }
            return true
        end
    end
    return false
end

-- Check one index for a party claim (sweep step and current-target fast path).
function Threats:check_claim(i, ctx)
    local ids = ctx.include_party and ctx.party_ids or ctx.self_ids
    if self:live_mob(i, ctx) and M.claim_matches(self.env.claim(i), ids) then
        self.claimed[i] = self.env.server_id(i) or true
        return true
    end
    self.claimed[i] = nil
    return false
end

-- Sweep `budget` indices per call, wrapping around (whole table every few frames).
function Threats:sweep(ctx, budget)
    local max = self.env.max_index or 0x8FF
    budget = math.min(budget or 384, max)
    for _ = 1, budget do
        local i = self.cursor
        self:check_claim(i, ctx)
        i = i + 1
        if i > max then i = 1 end
        self.cursor = i
    end
end

-- Drop dead / despawned / reused / timed-out entries. Returns in_combat, counts.
function Threats:prune(ctx, aggro_timeout)
    local e = self.env
    aggro_timeout = num(aggro_timeout, 8)
    local nh, nc = 0, 0
    for i, rec in pairs(self.claimed) do
        local sid = e.server_id(i)
        if not self:live_mob(i, ctx) or (rec ~= true and sid ~= rec) then self.claimed[i] = nil else nc = nc + 1 end
    end
    for i, rec in pairs(self.hostile) do
        local sid = e.server_id(i)
        local alive = self:live_mob(i, ctx) and (rec.id == nil or sid == rec.id)
        if not alive or (ctx.now - rec.t > aggro_timeout and not self.claimed[i]) then
            self.hostile[i] = nil
        else
            nh = nh + 1
        end
    end
    return (nh + nc) > 0, nh, nc
end

function Threats:clear() self.hostile, self.claimed = {}, {} end
function Threats:counts()
    local nh, nc = 0, 0
    for _ in pairs(self.hostile) do nh = nh + 1 end
    for _ in pairs(self.claimed) do nc = nc + 1 end
    return nh, nc
end

---------------------------------------------------------------------------
-- Menu classification (stateful, as before, but never "stuck")
---------------------------------------------------------------------------
local function any_match(name, list)
    for _, v in ipairs(list) do if name:match(v) then return true end end
    return false
end

-- st: persistent table; returns st with fields menu, window, command_menu, main_menu, auction, map
function M.classify_menu(st, menu_now, defines)
    local d = defines.menus
    st.current = menu_now
    if menu_now == '' then
        st.menu, st.config, st.helpdesk, st.auction = false, false, false, false
    end
    if menu_now:match(d.menu1) or menu_now:match(d.menu2) then
        st.menu, st.config, st.helpdesk, st.auction = true, false, false, false
    end
    st.command_menu = any_match(menu_now, defines.command_menu)
    if st.command_menu then
        -- A command menu (magic, abilities...) means the main menu tree was left; old code kept
        -- the config/helpdesk/auction flags set here, which kept "window open" stuck.
        st.config, st.helpdesk, st.auction = false, false, false
    end
    if menu_now:match(d.config_menu) then st.config = true end
    if menu_now:match(d.helpdesk_menu) then st.helpdesk = true end
    if menu_now:match(d.auction_menu) then st.auction = true end

    st.main_menu = st.config or st.helpdesk or any_match(menu_now, defines.main_menu)
    st.window = st.config or st.helpdesk or any_match(menu_now, defines.window)
    if menu_now:match(d.misson_category) then st.window = false end
    st.map = (menu_now:match(d.map) or menu_now:match(d.region_map) or menu_now:match(d.widescan)) and true or false
    return st
end

return M
