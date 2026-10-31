--[[
* minimapenhanced in-game config window (imgui).
* Opened with /mme (or /mme config), and automatically next to /minimap's own editor.
* Every change applies at once and is saved per character half a second later.
--]]
local imgui = require('imgui')

local M = {
    open = false,          -- opened by the user (/mme)
    auto = false,          -- opened because /minimap's editor opened
    suppressed = false,    -- user closed the auto-opened window; stay closed until the editor closes
    visible = false,       -- drawn last frame
    keep_shown = true,     -- keep the minimap shown while this window is open (not saved)
    reset_armed_until = nil,
}
local mmc, settings, core

function M.init(m, s, c) mmc, settings, core = m, s, c end
M.zones = require('mmzones')
M.zoomlib = require('mmzoom')
function M.is_open() return M.visible end

function M.toggle()
    if M.visible then M.close() else M.open, M.suppressed = true, false end
end

function M.close()
    M.open = false
    if M.auto then M.suppressed = true end
    -- We can't see the editor's own close button when only the command is tracked, so closing
    -- this window means "done with both"; the next /minimap opens them together again.
    if mmc and mmc.editor.mode ~= 'detected' then mmc.editor.tracked = false; M.auto = false end
end

function M.on_editor_toggled(open)
    if open then M.suppressed = false end
end

local function changed()
    mmc.schedule_save(mmc.now)
end

local function tip(text)
    if imgui.IsItemHovered() then imgui.SetTooltip(text) end
end

local function checkbox(label, tbl, key, help)
    local v = { tbl[key] ~= false }
    if imgui.Checkbox(label, v) then tbl[key] = v[1]; changed() end
    if help then tip(help) end
end

local function slider_ms(label, tbl, key, lo, hi, help)
    local v = { math.floor((tonumber(tbl[key]) or 0) * 1000 + 0.5) }
    if imgui.SliderInt(label, v, lo, hi, '%d ms') then tbl[key] = core.clamp(v[1], lo, hi) / 1000; changed() end
    if help then tip(help) end
end

local function slider_float(label, tbl, key, lo, hi, fmt, help)
    local v = { tonumber(tbl[key]) or lo }
    if imgui.SliderFloat(label, v, lo, hi, fmt or '%.2f') then tbl[key] = core.clamp(v[1], lo, hi); changed() end
    if help then tip(help) end
end

local SHOW_ROWS = {
    { 'in_combat',          'In combat' },
    { 'moving',             'While moving' },
    { 'during_events',      'During events / cutscenes' },
    { 'any_menu_open',      'Any menu open' },
    { 'main_menu_open',     'Main menu (right side)' },
    { 'window_open',        'Windows (inventory, equip, ...)' },
    { 'command_menu_open',  'Command menus (magic, abilities)' },
    { 'map_open',           'Map / region map / widescan' },
    { 'auction_open',       'Auction house' },
    { 'chat_expanded',      'Chat log expanded' },
    { 'dead',               'While KO\'d' },
    { 'minimap_editor_open','Minimap editor open (always shown)' },
}

-- Which memory scan each "keep shown" row depends on (rows without an entry never need one).
local SHOW_SCAN = {
    during_events = 'event', chat_expanded = 'chat',
    any_menu_open = 'menu', main_menu_open = 'menu', window_open = 'menu', command_menu_open = 'menu',
    map_open = 'menu', auction_open = 'menu',
}

function M.draw_body()
    local s = mmc.settings
    local sig = mmc.sig or {}

    -- Status
    local reasons = mmc.gate.active or {}
    local state = mmc.visible == false and 'hidden' or 'shown'
    local why = #reasons > 0 and table.concat(reasons, ', ') or (sig.force and ('forced ' .. sig.force) or 'nothing hiding it')
    imgui.Text(('Minimap: %s (%s)'):format(state, why))
    imgui.Text(('Combat: %s%s'):format(sig.combat and 'yes' or 'no', (mmc.combat_src or '') ~= '' and (' - ' .. mmc.combat_src) or ''))
    local kv = { M.keep_shown }
    if imgui.Checkbox('Keep minimap shown while this window is open', kv) then M.keep_shown = kv[1] end
    tip('Lets you see opacity changes. Untick it to test the hide rules with this window open.')
    if imgui.Button('Preview fade') then mmc.preview_hide_until = (mmc.now or 0) + 0.4 + (tonumber(s.timing.fade_out) or 0) end
    tip('Hides the minimap briefly, then shows it again, using your fade times.')
    imgui.Separator()

    if imgui.CollapsingHeader('Keep the minimap shown...', ImGuiTreeNodeFlags_DefaultOpen) then
        imgui.TextDisabled('Unticked = the minimap fades out in that situation.')
        local scans = (mmc.probe and mmc.probe.scans) or {}
        for _, row in ipairs(SHOW_ROWS) do
            local need = SHOW_SCAN[row[1]]
            if need ~= nil and scans[need] == false then
                imgui.TextDisabled(row[2] .. ' - unavailable (game memory scan failed)')
            else
                checkbox(row[2] .. '##sw_' .. row[1], s.show_when, row[1])
            end
        end
        if scans.interface == false then imgui.TextDisabled('Game UI hidden detection unavailable (memory scan failed).') end
    end

    if imgui.CollapsingHeader('Combat detection', ImGuiTreeNodeFlags_DefaultOpen) then
        imgui.TextDisabled('Used when "In combat" above is unticked.')
        checkbox('Weapon drawn (engaged)', s.combat, 'engaged', 'You are engaged (status 1).')
        checkbox('Monster claimed by you / party', s.combat, 'claims', 'Covers pulling with spells or ranged attacks before you engage.')
        checkbox('Monster attacked you / party', s.combat, 'hostile_actions', 'Aggro: a monster hit or cast on you, your party or a party pet.')
        checkbox('Count party and alliance members', s.combat, 'include_party', 'Off = only your own claims and attacks on you or your pet.')
        checkbox('Ignore while mounted', s.combat, 'ignore_when_mounted')
        slider_float('Aggro memory', s.combat, 'aggro_timeout', 1, 30, '%.0f s',
            'How long an unclaimed monster that hit you still counts as combat after its last attack.')
    end

    if imgui.CollapsingHeader('Fade and timing', ImGuiTreeNodeFlags_DefaultOpen) then
        local t = s.timing
        slider_ms('Fade in', t, 'fade_in', 0, 1000, 'Time to fade the minimap back in (0 - 1000 ms).')
        slider_ms('Fade out', t, 'fade_out', 0, 1000, 'Time to fade the minimap out (0 - 1000 ms).')
        slider_ms('Show delay', t, 'show_delay', 0, 1000, 'Wait this long after the last reason to hide is gone before fading back in. Stops flicker between menus or pulls.')
        slider_ms('Menu filter', t, 'menu_debounce', 0, 300, 'A menu or chat change has to last this long before it hides the minimap.')
        slider_ms('Moving hold', t, 'move_hold', 0, 1000, 'You count as moving until this long after your last step.')
        local hz = { math.floor(tonumber(t.update_hz) or 30) }
        if imgui.SliderInt('Updates per second', hz, 10, 60) then t.update_hz = core.clamp(hz[1], 10, 60); changed() end
        tip('How often the opacity is sent to the minimap during a fade. Nothing is sent while it is steady.')
    end

    if imgui.CollapsingHeader('Opacity when shown') then
        local o = s.opacity
        slider_float('Map', o, 'map', 0, 1)
        slider_float('Frame', o, 'frame', 0, 1)
        slider_float('Arrow', o, 'arrow', 0, 1)
        slider_float('Monsters', o, 'monsters', 0, 1)
        slider_float('NPCs', o, 'npcs', 0, 1)
        slider_float('Players', o, 'players', 0, 1)
    end

    if imgui.CollapsingHeader('Zoom') then
        local zc = s.zoom_by_type
        local zl = mmc.zoomer
        local zid = mmc.zone_id
        local fmt = function (v) return M.zoomlib.fmt(v) end
        local function zoom_input(label, tbl, key, help)
            local z = { tonumber(tbl[key]) or 1 }
            if imgui.InputFloat(label, z, 0.05, 0.25, '%.2f') then
                tbl[key] = M.zoomlib.clamp(z[1]); changed(); M.zoom_dirty_at = (mmc.now or 0) + 0.6
            end
            if help then tip(help) end
        end
        if zid ~= nil then
            local kind, sub = M.zones.classify(zid)
            local v, src = zl:resolve(zid, s)
            imgui.Text(('%s (%d): %s (%s)'):format(mmc.zone_name(zid), zid, kind == 'safe' and 'safe zone' or 'hostile zone', sub))
            if src == 'saved' then
                imgui.Text(('Zoom here: %s (saved for this zone)'):format(fmt(v)))
            else
                imgui.Text(('Zoom here: default (%s) %s'):format(src, fmt(v)))
            end
        end
        checkbox('Save my zoom changes per zone', zc, 'auto_save',
            'When you change the zoom in a zone (/minimap zoom, the minimap editor, mouse wheel), keep it for that zone.')
        checkbox('First-visit zoom by zone type', zc, 'enabled', 'Zones without a saved zoom use the hostile or safe zoom below.')
        zoom_input('Hostile zone zoom', zc, 'hostile', 'Field, dungeon and battle zones you have no saved zoom for. (0.1 - 2)')
        zoom_input('Safe zone zoom', zc, 'safe', 'Cities, towns, indoor and residential areas, boats and airships. (0.1 - 2)')
        zoom_input('Zoom when "by type" is off', s, 'default_zoom')
        slider_ms('Delay after zoning', zc, 'delay', 0, 5000, 'Wait this long after arriving so the minimap has loaded the new map (sent once more 1.5 s later if needed).')
        if zid ~= nil then
            M.override_input = M.override_input or { 1 }
            if M.override_zone ~= zid then                      -- follow the zone you are in
                M.override_zone = zid
                M.override_input[1] = (zl:resolve(zid, s))
            end
            imgui.InputFloat('##mmc_override_value', M.override_input, 0.05, 0.25, '%.2f')
            imgui.SameLine()
            if imgui.Button('Save for this zone') then
                s.zoom_overrides[zid] = M.zoomlib.clamp(M.override_input[1])
                changed(); mmc.apply_zoom()
            end
            if s.zoom_overrides[zid] ~= nil then
                if imgui.Button('Forget this zone\'s zoom') then s.zoom_overrides[zid] = nil; changed(); mmc.apply_zoom() end
            end
        end
        local ids = {}
        for k in pairs(s.zoom_overrides) do if tonumber(k) then ids[#ids + 1] = tonumber(k) end end
        table.sort(ids)
        imgui.Text(('Saved zone zooms (%d)'):format(#ids))
        for _, id in ipairs(ids) do
            if imgui.Button('Remove##ovr' .. id) then
                s.zoom_overrides[id] = nil; changed()
                if id == zid then mmc.apply_zoom() end
            else
                imgui.SameLine()
                imgui.Text(('%s (%d): %s'):format(mmc.zone_name(id), id, fmt(s.zoom_overrides[id])))
            end
        end
    end

    if imgui.CollapsingHeader('Other') then
        checkbox('Open with /minimap\'s editor', s.ui, 'attach_to_minimap_editor')
        checkbox('Print menu names (debug)', s, 'debug_menus')
        checkbox('Print combat start/end (debug)', s, 'debug_state')
        checkbox('Print when a zone\'s zoom is saved (debug)', s, 'debug_zoom')
        local now = mmc.now or 0
        if M.reset_armed_until ~= nil and now < M.reset_armed_until then
            if imgui.Button('Click again to reset everything') then
                M.reset_armed_until = nil
                settings.reset()
            end
        else
            M.reset_armed_until = nil
            if imgui.Button('Reset to defaults') then M.reset_armed_until = now + 3 end
        end
        imgui.SameLine()
        imgui.TextDisabled(('editor: %s'):format(mmc.editor.mode == 'detected' and 'detected' or 'via /minimap'))
    end
    imgui.TextDisabled('Changes apply now and save automatically.')
end

function M.draw()
    if mmc == nil then return end
    if M.zoom_dirty_at ~= nil and (mmc.now or 0) >= M.zoom_dirty_at then
        M.zoom_dirty_at = nil
        mmc.apply_zoom()
    end
    local s = mmc.settings
    local editor = mmc.editor_open()
    if not editor then M.suppressed = false end
    M.auto = (s.ui.attach_to_minimap_editor ~= false) and editor and not M.suppressed
    if not (M.open or M.auto) then
        if M.visible then mmc.flush_save() end
        M.visible = false
        return
    end
    M.visible = true
    imgui.SetNextWindowSize({ 400, 0 }, ImGuiCond_FirstUseEver)
    local p = { true }
    if imgui.Begin('Minimap Enhanced##minimapenhanced_config', p, ImGuiWindowFlags_AlwaysAutoResize) then
        M.draw_body()
    end
    imgui.End()
    if not p[1] then
        M.close()
        mmc.flush_save()
    end
end

return M
