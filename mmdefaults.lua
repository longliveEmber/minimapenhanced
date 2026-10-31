require('common')

local defaults = T{}

-- Opacity of each minimap layer while the minimap is shown (0 - 1).
defaults.opacity = T{
    map = 1,
    frame = 1,
    arrow = 1,
    monsters = 1,
    npcs = 1,
    players = 1,
}

-- true = keep the minimap shown in this situation, false = hide it.
defaults.show_when = T{
    moving = true,
    during_events = false,
    in_combat = false,
    any_menu_open = true,
    window_open = false,
    command_menu_open = true,
    main_menu_open = true,
    map_open = false,
    auction_open = false,
    chat_expanded = false,
    dead = true,                  -- keep it shown while KO'd (handy for homepointing)
    minimap_editor_open = true,   -- always fully shown while /minimap's editor is open
}

-- What counts as "in combat" (only used when show_when.in_combat is false).
defaults.combat = T{
    engaged = true,               -- you have your weapon out (status 1)
    claims = true,                -- a monster near you is claimed by you / your party
    hostile_actions = true,       -- a monster recently attacked or cast on you / your party
    include_party = true,         -- false = only count your own claims / attacks on you and your pet
    aggro_timeout = 8,            -- seconds a monster that hit you still counts (unclaimed mobs)
    ignore_when_mounted = true,   -- never treat it as combat while on a chocobo / mount
}

-- Timing, all in seconds. Fades use the real clock, not CPU time.
defaults.timing = T{
    fade_in = 0.18,               -- 0 - 1 s
    fade_out = 0.22,              -- 0 - 1 s
    show_delay = 0.10,            -- wait this long after the last hide reason clears (anti-flicker)
    menu_debounce = 0.05,         -- a menu / chat change must last this long to count
    move_hold = 0.25,             -- you count as moving until this long after you stop
    update_hz = 30,               -- max opacity updates per second sent to the minimap during a fade
}

-- In-game config window.
defaults.ui = T{
    attach_to_minimap_editor = true, -- open this window with /minimap's editor
}

defaults.debug_menus = false
defaults.debug_state = false
defaults.debug_zoom = false       -- print a chat line whenever a zone's zoom is saved

-- Zoom used when "zoom by zone type" is off. (Zoom amounts are the minimap plugin's own,
-- which it clamps to 0.1 - 2.0.)
defaults.default_zoom = 1

-- Minimap zoom by zone type.
defaults.zoom_by_type = T{
    enabled = true,
    hostile = 1,                  -- first visit to a field / dungeon / battle zone
    safe = 1,                     -- first visit to a city, town, indoor or residential area, boat, airship
    delay = 1.0,                  -- seconds after zoning before the zoom is sent (map must be loaded)
    auto_save = true,             -- when you change the zoom in a zone, save it for that zone
}
-- Saved zoom for each zone (zone id -> zoom). Filled automatically when you change the zoom in a
-- zone, or with /mme zoom set <n>.
defaults.zoom_overrides = T{}

return defaults
