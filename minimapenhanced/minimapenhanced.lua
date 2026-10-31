--[[
* Minimap Enhanced by Banedon.
* Based on minimapcontrol by onimitch (https://github.com/onimitch/ffxi-ashita-minimapcontrol, MIT;
* see LICENSE-minimapcontrol). Helper functions in mmhelpers.lua come from HXUI by Tirem (GPL v3).
* Released under the GNU General Public License v3 (see LICENSE).
--]]
addon.name      = 'minimapenhanced'
addon.author    = 'Banedon (based on minimapcontrol by onimitch)'
addon.version   = '1.0.0'
addon.desc      = 'Minimap Enhanced by Banedon. Controls the visibility, opacity and zoom of the Ashita v4 minimap plugin. Based on minimapcontrol by onimitch, with fixes and extra features.'
addon.link      = 'https://github.com/longliveEmber/minimapenhanced'
-- Original project: https://github.com/onimitch/ffxi-ashita-minimapcontrol

-- Ashita libs
require('common')
local settings = require('settings')
local chat = require('chat')
local imgui = require('imgui')

-- Minimapenhanced files
local default_settings = require('mmdefaults')
local defines = require('mmdefines')
require('mmhelpers')
local core = require('mmcore')
local ui = require('mmui')
local zoomlib = require('mmzoom')
local zones = require('mmzones')

local EDITOR_WINDOW = 'Minimap Configuration Editor' -- title used by the Ashita v4 minimap plugin
local MOUNT_BUFF = 252

local minimapenhanced = {
    settings = T{},
    zoning = false,
    zoning_since = 0,
    zone_id = nil,
    snap_next = true,          -- next frame jumps straight to the target (load / after zoning)

    gate = core.Gate(),
    fader = core.Fader(1),
    sender = core.Sender(),
    mover = core.Mover(),
    threats = nil,
    menu = { current = '' },
    menu_seen = false,
    sig = {},                  -- last frame's raw signals (for /mme info and the config window)
    combat_src = '',
    force = nil,               -- 'show' | 'hide' | nil (manual override, not saved)
    preview_hide_until = nil,
    editor = { tracked = false, detected = nil, mode = 'command' },
    save_at = nil,
    events_sent = 0,
    last_level = 1,
    zone_in_seen = false,      -- zone-in packet seen while zoning
    now = 0,                   -- clock at the last tick
    visible = true,            -- gate target from the last tick
    ctx = nil,                 -- last party context (combat tracking)
}
local mmc = minimapenhanced

---------------------------------------------------------------------------
-- Wall clock (os.clock is CPU time by the C standard; never use it for fades)
---------------------------------------------------------------------------
local function make_clock()
    local at = rawget(_G, 'ashita') and ashita.time
    if type(at) == 'table' and type(at.clock) == 'function' then
        local ok, c = pcall(at.clock)
        if ok and type(c) == 'table' then
            if type(c.micro) == 'number' then
                local base = c.micro
                return function () return (at.clock().micro - base) / 1e6 end, 'ashita.time.clock'
            elseif type(c.ms) == 'number' then
                local base = c.ms
                return function () return (at.clock().ms - base) / 1e3 end, 'ashita.time.clock'
            end
        end
    end
    if type(imgui.GetTime) == 'function' then
        local ok, v = pcall(imgui.GetTime)
        if ok and type(v) == 'number' then return imgui.GetTime, 'imgui.GetTime' end
    end
    return os.clock, 'os.clock (fallback)'
end
mmc.clock, mmc.clock_name = make_clock()

---------------------------------------------------------------------------
-- Game memory probes (guarded against a failed scan)
---------------------------------------------------------------------------
local function find(sig, off)
    local ok, p = pcall(ashita.memory.find, 'FFXiMain.dll', 0, sig, off, 0)
    if ok and type(p) == 'number' then return p end
    return 0
end

local pGameMenu = find('8B480C85C974??8B510885D274??3B05', 16)
local function get_game_menu_name()
    if pGameMenu == 0 then return '' end
    local menu_pointer = ashita.memory.read_uint32(pGameMenu)
    if menu_pointer == nil or menu_pointer == 0 then return '' end
    local menu_val = ashita.memory.read_uint32(menu_pointer)
    if menu_val == nil or menu_val == 0 then return '' end
    local menu_header = ashita.memory.read_uint32(menu_val + 4)
    if menu_header == nil or menu_header == 0 then return '' end
    local menu_name = ashita.memory.read_string(menu_header + 0x46, 16) or ''
    return (menu_name:gsub('\x00', ''):gsub('menu[%s]+', ''):trimex())
end

local pEventSystem = find('A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3', 0)
local function is_event_system_active()
    if pEventSystem == 0 then return false end
    local ptr = ashita.memory.read_uint32(pEventSystem + 1)
    if ptr == nil or ptr == 0 then return false end
    return ashita.memory.read_uint8(ptr) == 1
end

local pInterfaceHidden = find('8B4424046A016A0050B9????????E8????????F6D81BC040C3', 0)
local function is_game_interface_hidden()
    if pInterfaceHidden == 0 then return false end
    local ptr = ashita.memory.read_uint32(pInterfaceHidden + 10)
    if ptr == nil or ptr == 0 then return false end
    return ashita.memory.read_uint8(ptr + 0xB4) == 1
end

local pChatExpanded = find('83EC??B9????????E8????????0FBF4C24??84C0', 0x04)
local function is_chat_expanded()
    if pChatExpanded == 0 then return false end -- a failed scan reads as 0: report "not active"
    local ptr = ashita.memory.read_uint32(pChatExpanded)
    if ptr == nil or ptr == 0 then return false end
    return ashita.memory.read_uint8(ptr + 0xF1) ~= 0
end

-- Tests replace these.
mmc.probe = {
    menu_name = get_game_menu_name,
    event_active = is_event_system_active,
    interface_hidden = is_game_interface_hidden,
    chat_expanded = is_chat_expanded,
    scans = { menu = pGameMenu ~= 0, event = pEventSystem ~= 0, interface = pInterfaceHidden ~= 0, chat = pChatExpanded ~= 0 },
}

local minimap_ini = AshitaCore:GetInstallPath() .. '/config/minimap/minimap.ini'

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function msg(s) print(chat.header(addon.name):append(chat.message(s))) end
local function err(s) print(chat.header(addon.name):append(chat.error(s))) end
mmc.msg, mmc.err = msg, err

local function entity_mgr() return AshitaCore:GetMemoryManager():GetEntity() end
local function party_mgr() return AshitaCore:GetMemoryManager():GetParty() end

local function safe(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

mmc.threats = core.Threats({
    is_mob = function (i) return bit.band(entity_mgr():GetSpawnFlags(i) or 0, 0x10) ~= 0 end,
    valid = function (i) return GetIsValidMob(i) end,
    hp = function (i) return entity_mgr():GetHPPercent(i) end,
    status = function (i) return entity_mgr():GetStatus(i) end,
    server_id = function (i) return entity_mgr():GetServerId(i) end,
    claim = function (i)
        local e = entity_mgr()
        if type(e.GetClaimStatus) ~= 'function' then return 0 end
        return e:GetClaimStatus(i) or 0
    end,
    max_index = 0x8FF,
})

-- Party / alliance / trusts / pets. friendly_* are never treated as enemies.
function mmc.build_ctx(now)
    local party, ent = party_mgr(), entity_mgr()
    local ctx = { now = now, party_ids = {}, self_ids = {}, friendly_ids = {}, friendly_index = {},
                  include_party = mmc.settings.combat.include_party ~= false }
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 then
            local sid = party:GetMemberServerId(i) or 0
            local tidx = party:GetMemberTargetIndex(i) or 0
            if sid ~= 0 then
                ctx.party_ids[sid], ctx.friendly_ids[sid] = true, true
                if i == 0 then ctx.self_ids[sid] = true end
            end
            if tidx > 0 then
                ctx.friendly_index[tidx] = true
                local pet = safe(ent.GetPetTargetIndex, ent, tidx) or 0
                if pet > 0 then
                    ctx.friendly_index[pet] = true
                    local psid = ent:GetServerId(pet) or 0
                    if psid ~= 0 then
                        ctx.party_ids[psid], ctx.friendly_ids[psid] = true, true
                        if i == 0 then ctx.self_ids[psid] = true end
                    end
                end
            end
        end
    end
    return ctx
end

-- The party context changes rarely, so it is rebuilt at most every CTX_TTL seconds (the frame tick and
-- every action packet used to rebuild it each time). ctx.now is refreshed on every call.
local CTX_TTL = 0.25
local ctx_cache = { at = -1e9, ctx = nil, include_party = nil }
function mmc.get_ctx(now)
    local ip = mmc.settings.combat.include_party ~= false
    if ctx_cache.ctx == nil or now - ctx_cache.at >= CTX_TTL or now < ctx_cache.at or ctx_cache.include_party ~= ip then
        ctx_cache.ctx, ctx_cache.at, ctx_cache.include_party = mmc.build_ctx(now), now, ip
    end
    ctx_cache.ctx.now = now
    return ctx_cache.ctx
end

function mmc.is_mounted_status(status)
    if status == defines.entity_status.chocobo or status == defines.entity_status.mounted then return true end
    local buff_list = AshitaCore:GetMemoryManager():GetPlayer():GetBuffs()
    for _, buff in pairs(buff_list or {}) do
        if buff == MOUNT_BUFF then return true end
    end
    return false
end
minimapenhanced.is_mounted = function () return mmc.is_mounted_status(nil) end

---------------------------------------------------------------------------
-- Zoom (by zone type, per-zone overrides, manual zoom respected; see mmzoom.lua)
---------------------------------------------------------------------------
minimapenhanced.set_zoom_level = function (zoom_level)
    AshitaCore:GetChatManager():QueueCommand(1, '/minimap zoom ' .. zoomlib.fmt(zoom_level))
end

minimapenhanced.read_minimap_zoom = function ()
    local f = io.open(minimap_ini, 'r')
    if f == nil then return nil end
    local found = nil
    for line in f:lines() do
        local _, _, zoom_level = string.find(line, '^%s*zoom[%s]*=[%s]*([%d%.]+)')
        if zoom_level ~= nil then found = zoom_level; break end
    end
    f:close() -- always close the file
    return found
end

mmc.zoomer = zoomlib.new({
    queue = function (cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end,
    read_ini = function () return tonumber(minimapenhanced.read_minimap_zoom()) end,
    saved = function (zone, v)
        mmc.schedule_save(mmc.now)
        if mmc.settings.debug_zoom then mmc.msg(('Saved zoom %s for %s.'):format(zoomlib.fmt(v), mmc.zone_name(zone))) end
    end,
})

local function resources()
    local ok, r = pcall(function () return AshitaCore:GetResourceManager() end)
    if ok then return r end
    return nil
end

function mmc.zone_name(id) return zones.name(id, resources()) end

-- New zone id known (zone-in packet / load). The zoom is sent once zoning has finished + delay.
minimapenhanced.on_zone_changed = function (zone_id)
    minimapenhanced.zone_id = tonumber(zone_id)
    mmc.zoomer:on_zone_in(minimapenhanced.zone_id)
end

-- "Remember current zoom": make the minimap's current zoom this zone's override.
minimapenhanced.record_zoom_level = function ()
    if minimapenhanced.zone_id == nil then return nil end
    local z = tonumber(minimapenhanced.read_minimap_zoom())
    if z == nil then return nil end
    minimapenhanced.settings.zoom_overrides[minimapenhanced.zone_id] = zoomlib.clamp(z)
    settings.save()
    return z
end

function mmc.apply_zoom()
    if mmc.zone_id == nil or mmc.zoning then return nil end
    return mmc.zoomer:apply_now(mmc.clock(), mmc.settings, mmc.zone_id)
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
minimapenhanced.reset_state = function ()
    mmc.threats:clear()
    mmc.mover:reset()
    mmc.menu = { current = '' }
    mmc.menu_seen = false
    mmc.gate:reset(mmc.gate.visible)
end

function mmc.schedule_save(now)
    mmc.save_at = (now or mmc.clock()) + 0.5
end

function mmc.flush_save()
    if mmc.save_at ~= nil then
        mmc.save_at = nil
        settings.save()
    end
end

-- Is /minimap's editor open? detected (imgui) when possible, else tracked from the command.
function mmc.probe_editor_window()
    if type(imgui.FindWindowByName) ~= 'function' then return nil end
    local ok, w = pcall(imgui.FindWindowByName, EDITOR_WINDOW)
    if not ok then return nil end
    if w == nil then return false end
    local ok2, active = pcall(function () return w.WasActive end)
    if ok2 and type(active) == 'boolean' then return active end
    return nil
end

function mmc.editor_open()
    local d = mmc.probe_editor_window()
    mmc.editor.detected = d
    if d ~= nil then
        mmc.editor.mode = 'detected'
        return d
    end
    mmc.editor.mode = 'command'
    return mmc.editor.tracked
end

-- Collect this frame's signals.
function mmc.read_signals(now)
    local s = mmc.settings
    local sig = {}
    local player = GetPlayerEntity()
    local party = party_mgr()
    local my_idx = party:GetMemberTargetIndex(0) or 0
    local status = (my_idx > 0) and entity_mgr():GetStatus(my_idx) or 0
    sig.status = status

    sig.interface_hidden = mmc.probe.interface_hidden() and true or false

    if player ~= nil then
        local p = player.Movement.LocalPosition
        sig.moving = mmc.mover:update(now, p.X, p.Y, p.Z, s.timing.move_hold)
    else
        sig.moving = false
    end

    sig.event = (mmc.probe.event_active() and true or false) or status == defines.entity_status.event

    local name = mmc.probe.menu_name() or ''
    if name ~= mmc.menu.current or not mmc.menu_seen then
        mmc.menu_seen = true
        if s.debug_menus then msg('Menu: ' .. name) end
        core.classify_menu(mmc.menu, name, defines)
    end
    local m = mmc.menu
    sig.any_menu, sig.map, sig.window = m.menu, m.map, m.window
    sig.command_menu, sig.main_menu, sig.auction = m.command_menu, m.main_menu, m.auction

    sig.chat_expanded = mmc.probe.chat_expanded() and true or false
    sig.dead = (status == defines.entity_status.dead or status == defines.entity_status.dead2)

    -- Combat
    local c = s.combat
    local combat, src = false, ''
    if sig.dead then
        mmc.threats:clear()
    elseif s.show_when.in_combat ~= false then
        -- combat can't hide the minimap, so don't spend time tracking it
        mmc.threats:clear()
        src = 'not tracked (shown in combat)'
    else
        local ctx = mmc.get_ctx(now)
        if c.claims ~= false then
            -- fast path: your current target, every frame; plus a rolling sweep of all entities
            local tgt = safe(function () return AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0) end) or 0
            if tgt > 0 then mmc.threats:check_claim(tgt, ctx) end
            mmc.threats:sweep(ctx, 192) -- whole entity table every ~12 frames
        else
            mmc.threats.claimed = {}
        end
        if c.hostile_actions == false then mmc.threats.hostile = {} end
        mmc.ctx = ctx
        local _, nh, nc = mmc.threats:prune(ctx, c.aggro_timeout)
        local mounted = (c.ignore_when_mounted ~= false) and mmc.is_mounted_status(status)
        if not mounted then
            if c.engaged ~= false and status == defines.entity_status.engaged then combat, src = true, 'engaged' end
            if not combat and nc > 0 then combat, src = true, ('claimed x%d'):format(nc) end
            if not combat and nh > 0 then combat, src = true, ('attacked by x%d'):format(nh) end
        else
            src = 'mounted'
        end
    end
    sig.combat = combat
    if s.debug_state and (combat ~= (mmc.sig.combat or false)) then
        msg(('combat %s (%s)'):format(combat and 'START' or 'end', combat and src or (mmc.combat_src or '')))
    end
    mmc.combat_src = src

    -- Overrides
    -- Only a *detected* editor forces the minimap shown. When we can only track the /minimap
    -- command, the attached config window (keep_shown) covers it, so a stale guess can't
    -- leave the minimap stuck on.
    sig.editor_open = mmc.editor_open() and mmc.editor.mode == 'detected'
    if mmc.preview_hide_until ~= nil then
        if now < mmc.preview_hide_until then sig.force = 'hide' else mmc.preview_hide_until = nil end
    end
    if sig.force == nil then sig.force = mmc.force end
    if sig.force == nil and ui.is_open() and ui.keep_shown then sig.force = 'show' end
    return sig
end

-- Opacity values to send for a 0..1 level.
function mmc.values_for(level)
    local o = mmc.settings.opacity
    local function c(v) return core.clamp(core.num(v, 1), 0, 1) * level end
    return { c(o.map), c(o.frame), c(o.arrow), c(o.monsters), c(o.npcs), c(o.players) }
end

function mmc.raise(values)
    local data = struct.pack('Lffffff', 0x01, values[1], values[2], values[3], values[4], values[5], values[6])
    AshitaCore:GetPluginManager():RaiseEvent('minimap', data:totable())
    mmc.events_sent = mmc.events_sent + 1
end

-- One frame. Called from d3d_present (state, fade and send happen on the same frame).
function mmc.tick(now)
    now = now or mmc.clock()
    mmc.now = now
    if mmc.save_at ~= nil and now >= mmc.save_at then mmc.flush_save() end

    if mmc.zoning then
        -- Finish zoning once the new zone is in and the player exists (fallback: 30 s).
        if (mmc.zone_in_seen and GetPlayerEntity() ~= nil) or (now - mmc.zoning_since > 30) then
            mmc.zoning, mmc.zone_in_seen, mmc.snap_next = false, false, true
            mmc.gate:reset(true) -- judge the new zone fresh (no leftover show delay)
            mmc.sender:invalidate()
            mmc.zoomer:on_ready(now, mmc.settings, mmc.zone_id)
        else
            return
        end
    end

    local s = mmc.settings
    if mmc.zone_id ~= nil then mmc.zoomer:tick(now, s, mmc.zone_id) end
    local sig = mmc.read_signals(now)
    mmc.sig = sig
    local reasons, override = core.raw_reasons(sig, s.show_when)
    local visible, changed = mmc.gate:update(now, reasons, override, s.timing)
    mmc.visible = visible

    local level
    if mmc.snap_next then
        mmc.fader:snap(visible, now)
        level, mmc.snap_next = mmc.fader:level(), false
        mmc.sender:invalidate()
    else
        level = mmc.fader:update(now, visible, s.timing)
    end
    mmc.last_level = level
    local dir = mmc.fader:done() and 0 or (visible and 1 or -1)
    local values = mmc.values_for(level)
    if mmc.sender:want(now, values, dir, mmc.fader:done(), s.timing.update_hz, false) then
        mmc.raise(values)
    end
    return changed
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
local function onoff(v) return v and 'on' or 'off' end

function mmc.print_info()
    local sig = mmc.sig or {}
    local reasons = mmc.gate.active or {}
    msg(('v%s | target: %s | level %.2f | reason: %s'):format(addon.version, mmc.visible == false and 'hidden' or 'shown',
        mmc.last_level or 1, (#reasons > 0 and table.concat(reasons, ', ')) or (sig.force and ('forced ' .. sig.force)) or 'none'))
    local nh, nc = mmc.threats:counts()
    msg(('combat: %s [%s] | claimed mobs %d | mobs that attacked %d | status %s'):format(onoff(sig.combat), mmc.combat_src or '', nc, nh, tostring(sig.status)))
    msg(('menu: "%s" | event %s | chat expanded %s | moving %s | zoning %s'):format(mmc.menu.current or '', onoff(sig.event),
        onoff(sig.chat_expanded), onoff(sig.moving), onoff(mmc.zoning)))
    local t = mmc.settings.timing
    msg(('fade in %.0f ms, out %.0f ms, show delay %.0f ms, %d Hz max | clock: %s | events sent: %d'):format(
        t.fade_in * 1000, t.fade_out * 1000, t.show_delay * 1000, t.update_hz, mmc.clock_name, mmc.events_sent))
    local sc = mmc.probe.scans
    msg(('minimap editor: %s (%s) | memory scans: menu %s, event %s, interface %s, chat %s'):format(
        onoff(mmc.editor_open()), mmc.editor.mode == 'detected' and 'detected from its window' or 'tracked from /minimap',
        onoff(sc.menu), onoff(sc.event), onoff(sc.interface), onoff(sc.chat)))
    if mmc.zone_id ~= nil then mmc.zoom_info() end
end

local HELP = {
    '/mme                 - open/close the config window (also /minimapenhanced, /mmc)',
    '/mme config          - same',
    '/mme editor          - open /minimap\'s editor with this window attached',
    '/mme info            - why the minimap is shown/hidden right now',
    '/mme fade <in> <out> - fade times in ms, 0 - 1000 (e.g. /mme fade 180 220)',
    '/mme show|hide|auto  - force shown/hidden until "auto" (not saved)',
    '/mme combat          - print when combat starts/ends and why (toggle)',
    '/mme menus           - print menu names as they change (toggle)',
    '/mme zoom            - this zone\'s type and zoom',
    '/mme zoom set <n>    - save a zoom for this zone',
    '/mme zoom save       - save the minimap\'s current zoom for this zone',
    '/mme zoom clear      - forget this zone\'s zoom (back to the hostile/safe default)',
    '/mme zoom hostile <n> | safe <n> | on | off | autosave on|off | list | debug',
    '/mme reset           - restore default settings',
}

function mmc.zoom_info()
    local s, zid = mmc.settings, mmc.zone_id
    if zid == nil then err('Zone not known yet.'); return end
    local kind, sub = zones.classify(zid)
    local v, src = mmc.zoomer:resolve(zid, s)
    msg(('%s (%d): %s zone (%s) | zoom %s (%s) | defaults: hostile %s, safe %s%s | auto-save %s'):format(
        mmc.zone_name(zid), zid, kind, sub, zoomlib.fmt(v), src == 'saved' and 'saved for this zone' or ('default, ' .. src),
        zoomlib.fmt(s.zoom_by_type.hostile), zoomlib.fmt(s.zoom_by_type.safe),
        s.zoom_by_type.enabled ~= false and '' or (' (by type off: ' .. zoomlib.fmt(s.default_zoom) .. ')'),
        s.zoom_by_type.auto_save ~= false and 'on' or 'off'))
end

function mmc.zoom_command(args)
    local s, zid = mmc.settings, mmc.zone_id
    local what = (args[3] or ''):lower()
    local arg4 = (args[4] or ''):lower()
    local n = tonumber(args[4])
    if what == '' or what == 'info' then
        mmc.zoom_info()
    elseif what == 'hostile' or what == 'safe' then
        if n == nil or n <= 0 then err('Usage: /mme zoom ' .. what .. ' <zoom 0.1 - 2>'); return end
        s.zoom_by_type[what] = zoomlib.clamp(n)
        settings.save(); mmc.apply_zoom()
        msg(('First-visit zoom for %s zones: %s'):format(what, zoomlib.fmt(s.zoom_by_type[what])))
    elseif what == 'on' or what == 'off' then
        s.zoom_by_type.enabled = (what == 'on')
        settings.save(); mmc.apply_zoom()
        msg('Zoom by zone type ' .. what .. '.')
    elseif what == 'autosave' or what == 'auto' then
        if arg4 == 'on' or arg4 == 'off' then s.zoom_by_type.auto_save = (arg4 == 'on')
        else s.zoom_by_type.auto_save = (s.zoom_by_type.auto_save == false) end
        settings.save()
        msg('Saving your zoom changes per zone: ' .. (s.zoom_by_type.auto_save and 'on' or 'off') .. '.')
    elseif what == 'debug' then
        s.debug_zoom = not s.debug_zoom
        settings.save()
        msg('Zoom save messages ' .. onoff(s.debug_zoom) .. '.')
    elseif what == 'list' then
        local ids = {}
        for k in pairs(s.zoom_overrides) do ids[#ids + 1] = tonumber(k) end
        table.sort(ids)
        if #ids == 0 then msg('No saved zone zooms.') end
        for _, k in ipairs(ids) do msg(('%s (%d): %s'):format(mmc.zone_name(k), k, zoomlib.fmt(s.zoom_overrides[k]))) end
    elseif zid == nil then
        err('Zone not known yet.')
    elseif what == 'set' then
        if n == nil or n <= 0 then err('Usage: /mme zoom set <zoom 0.1 - 2>'); return end
        s.zoom_overrides[zid] = zoomlib.clamp(n)
        settings.save(); mmc.apply_zoom()
        msg(('Saved zoom for %s: %s'):format(mmc.zone_name(zid), zoomlib.fmt(s.zoom_overrides[zid])))
    elseif what == 'save' then
        local z = mmc.record_zoom_level()
        if z == nil then err('Could not read the minimap zoom from minimap.ini.'); return end
        msg(('Saved zoom for %s: %s'):format(mmc.zone_name(zid), zoomlib.fmt(z)))
    elseif what == 'clear' or what == 'forget' then
        s.zoom_overrides[zid] = nil
        settings.save()
        local v, src = mmc.apply_zoom()
        msg(('Forgot the zoom for %s; back to the %s default (%s).'):format(mmc.zone_name(zid), src, zoomlib.fmt(v)))
    else
        err('Usage: /mme zoom [set <n> | save | clear | hostile <n> | safe <n> | on | off | autosave on|off | list | debug]')
    end
end

function mmc.command(args)
    local sub = (args[2] or 'config'):lower()
    local s = mmc.settings
    if sub == 'config' or sub == 'ui' or sub == 'settings' then
        ui.toggle()
    elseif sub == 'editor' then
        AshitaCore:GetChatManager():QueueCommand(1, '/minimap')
    elseif sub == 'info' or sub == 'status' then
        mmc.print_info()
    elseif sub == 'fade' then
        local fi, fo = tonumber(args[3]), tonumber(args[4] or args[3])
        if fi == nil then err('Usage: /mme fade <in ms> [out ms]'); return end
        s.timing.fade_in = core.clamp(fi / 1000, 0, 1)
        s.timing.fade_out = core.clamp((fo or fi) / 1000, 0, 1)
        settings.save()
        msg(('Fade in %.0f ms, out %.0f ms (0 - 1000 ms).'):format(s.timing.fade_in * 1000, s.timing.fade_out * 1000))
    elseif sub == 'show' or sub == 'hide' then
        mmc.force = sub
        msg('Minimap forced ' .. (sub == 'show' and 'shown' or 'hidden') .. ' until /mme auto.')
    elseif sub == 'auto' then
        mmc.force = nil
        msg('Minimap back to automatic.')
    elseif sub == 'combat' or sub == 'debug' then
        s.debug_state = not s.debug_state
        settings.save()
        msg('Combat debug ' .. onoff(s.debug_state) .. '.')
    elseif sub == 'menus' then
        s.debug_menus = not s.debug_menus
        settings.save()
        msg('Menu debug ' .. onoff(s.debug_menus) .. '.')
    elseif sub == 'zoom' then
        mmc.zoom_command(args)
    elseif sub == 'reset' then
        settings.reset()
        msg('Settings reset to defaults.')
    elseif sub == 'help' then
        for _, l in ipairs(HELP) do msg(l) end
    else
        err('Unknown command. /mme help')
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
minimapenhanced.initialize = function ()
    local s = minimapenhanced.settings
    -- make sure every table exists, and every key has a value, even if an older settings file lacks them
    for _, k in ipairs({ 'opacity', 'show_when', 'combat', 'timing', 'ui' }) do
        if s[k] == nil then s[k] = T{} end
        for dk, dv in pairs(default_settings[k]) do
            if s[k][dk] == nil then s[k][dk] = dv end
        end
    end
    if s.zoom_overrides == nil then s.zoom_overrides = T{} end
    -- fade times are limited to 0 - 1 s (older settings files allowed up to 2 s)
    s.timing.fade_in = core.clamp(core.num(s.timing.fade_in, 0.18), 0, 1)
    s.timing.fade_out = core.clamp(core.num(s.timing.fade_out, 0.22), 0, 1)
    for _, k in ipairs({ 'zoom_by_type' }) do
        if s[k] == nil then s[k] = T{} end
        for dk, dv in pairs(default_settings[k]) do if s[k][dk] == nil then s[k][dk] = dv end end
    end
end

ashita.events.register('load', 'minimapenhanced_load', function ()
    minimapenhanced.settings = settings.load(default_settings)
    minimapenhanced.initialize()
    ui.init(mmc, settings, core)

    local zone_id = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
    if tonumber(zone_id) ~= nil and tonumber(zone_id) > 0 then
        minimapenhanced.on_zone_changed(zone_id)
        mmc.zoomer:on_ready(mmc.clock(), mmc.settings, mmc.zone_id)
    end

    settings.register('settings', 'minimapenhanced_settings_update', function (s)
        if (s ~= nil) then
            minimapenhanced.settings = s
            minimapenhanced.initialize()
        end
    end)

    msg('Loaded. /mme for options.')
end)

ashita.events.register('unload', 'minimapenhanced_unload', function ()
    mmc.flush_save()
    -- leave the minimap fully visible at the user's opacity when unloaded
    mmc.raise(mmc.values_for(1))
end)

ashita.events.register('command', 'minimapenhanced_command', function (e)
    local args = e.command:args()
    if #args == 0 then return end
    local cmd = args[1]:lower()
    if cmd == '/mme' or cmd == '/minimapenhanced' or cmd == '/mmc' or cmd == '/minimapcontrol' then    -- /mmc: old name, still accepted
        e.blocked = true
        mmc.command(args)
        return
    end
    -- Watch (never block) the minimap plugin's own commands.
    if cmd == '/minimap' or cmd == '/mm' then
        local sub = (args[2] or ''):lower()
        if sub == '' then
            mmc.editor.tracked = not mmc.editor.tracked
            ui.on_editor_toggled(mmc.editor.tracked)
        elseif sub == 'reload' then
            mmc.sender:invalidate() -- re-send our opacity after the plugin reloads its config
        elseif sub == 'zoom' and tonumber(args[3]) ~= nil then
            mmc.zoomer:on_command(mmc.clock(), tonumber(args[3]), mmc.zone_id, mmc.settings)
        end
    end
end)

ashita.events.register('packet_in', 'minimapenhanced_packet_in', function (e)
    if (e.id == defines.packets.inc.zone_out) then
        mmc.zoning, mmc.zoning_since, mmc.zone_in_seen = true, mmc.clock(), false
        mmc.editor.tracked = false
        minimapenhanced.reset_state()
        if mmc.zone_id ~= nil then mmc.zoomer:on_zone_out(mmc.clock(), mmc.settings, mmc.zone_id) end
        mmc.flush_save() -- a zoom you changed in the zone you're leaving
        return
    end

    if (e.id == defines.packets.inc.zone_in) then
        mmc.zone_in_seen = true
        if not mmc.zoning then mmc.zoning, mmc.zoning_since = true, mmc.clock() end
        local zone_id = struct.unpack('H', e.data, 0x30 + 1)
        minimapenhanced.on_zone_changed(zone_id)
        return
    end

    if (e.id == defines.packets.inc.action) then
        -- nothing to record when combat isn't tracked (shown in combat) or aggro tracking is off
        if mmc.zoning or mmc.settings.combat.hostile_actions == false or mmc.settings.show_when.in_combat ~= false then return end
        local packet_data = ParseActionPacket(e)
        if packet_data == nil then return end
        local user_index = packet_data.UserIndex or 0
        if user_index <= 0 then return end
        local ids = {}
        for _, t in ipairs(packet_data.Targets) do ids[#ids + 1] = t.Id end
        local ctx = mmc.get_ctx(mmc.clock())
        mmc.threats:on_action(user_index, packet_data.UserId, ids, ctx)
        return
    end
end)

ashita.events.register('d3d_present', 'minimapenhanced_present', function ()
    mmc.tick(mmc.clock())
    ui.draw()
end)

-- Exposed for the offline tests only.
if rawget(_G, 'MMC_TEST') then _G.MMC = mmc; _G.MMC_UI = ui end
