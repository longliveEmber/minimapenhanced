# Minimap Enhanced

**Smart fading and per-zone zoom for the Ashita v4 minimap plugin.**

By **Banedon**. Based on [minimapcontrol by onimitch](https://github.com/onimitch/ffxi-ashita-minimapcontrol), which did the original work of fading the minimap.

The minimap is great while you run around and in the way everywhere else. Minimap Enhanced fades it out when you fight, open menus, watch a cutscene or open the map, and fades it back in when you're done.

What it adds to minimapcontrol:

- **Fixes the erratic fading in battle.** Combat is read from your weapon status, monsters claimed by you or your party, and monsters that hit or cast on you, so the minimap no longer blinks in and out during a fight or between pulls.
- **Adds default "hostile" and "safe" zone zooms.** Fields, dungeons and battle zones get one starting zoom; cities, towns, indoor and residential areas, boats and airships get another. Change the zoom anywhere and it's remembered for that zone.
- **Adds an in-game config menu.** Type `/mme` to change every setting in game. Changes apply at once and save per character, and the menu also opens next to `/minimap`'s own editor.

---

## Install (TL;DR)

1. You need Ashita v4 with the **minimap** plugin loaded (`/load minimap`).
2. Click **Code > Download ZIP** on this page (or grab the latest release).
3. Unzip it and put it in your addons folder, so you have `/addons/minimapenhanced/minimapenhanced.lua`. If the folder is called `minimapenhanced-main`, rename it to `minimapenhanced`.
4. **Unload minimapmon and minimapcontrol** if you use them. They control the same minimap and will fight each other.
5. In game: `/addon load minimapenhanced`
6. To load it every time, add `/addon load minimapenhanced` to `/scripts/default.txt`.
7. Type `/mme` to open the settings. It also opens next to `/minimap`'s own editor.

---

## Features

| | |
| --- | --- |
| **Hide rules** | Fade the minimap out in combat, while moving, in events and cutscenes, with menus, windows, the map, the auction house or an expanded chat log, or while KO'd. Pick each one |
| **Smooth fades** | Separate fade in and fade out times (0-1000 ms) on the real clock, eased, with no jumps when the direction changes |
| **No flicker** | A short show delay and a menu filter, so it doesn't blink between menus or between pulls |
| **Real combat detection** | Weapon drawn, monsters claimed by you or your party, and monsters that hit or cast on you, with an aggro memory. Ignored while mounted |
| **Opacity when shown** | Map, frame, arrow, monsters, NPCs and players each get their own opacity |
| **Zoom per zone** | Change the zoom in a zone (command, editor or mouse wheel) and it's saved for that zone |
| **First-visit zoom** | Zones you haven't saved use a hostile or safe zoom (cities, towns, indoor and residential areas, boats, airships) |
| **Config window** | Every setting in game, applied at once and saved per character. Opens with `/minimap`'s editor |
| **Diagnostics** | `/mme info` says why the minimap is shown or hidden right now |

---

## Config Window

`/mme` opens the settings window. This section mirrors it. At the top it shows whether the minimap is shown and why, whether you're in combat, a **Keep minimap shown while this window is open** checkbox and a **Preview fade** button.

### Keep the minimap shown...
Tick a situation to keep the minimap up in it; untick it to fade the minimap out.
In combat, while moving, during events and cutscenes, any menu open, main menu (right side), windows (inventory, equip, ...), command menus (magic, abilities), map / region map / widescan, auction house, chat log expanded, while KO'd, and minimap editor open (always shown).

### Combat detection
Used when "In combat" is unticked: weapon drawn, monster claimed by you or your party, monster attacked you or your party, count party and alliance members, ignore while mounted, and aggro memory (1-30 s).

### Fade and timing
Fade in, fade out, show delay, menu filter, moving hold and updates per second.

### Opacity when shown
Map, frame, arrow, monsters, NPCs and players (0-1).

### Zoom
- The zone you're in, whether it's a safe or hostile zone, and the zoom it uses.
- Save my zoom changes per zone, first-visit zoom by zone type, hostile zone zoom, safe zone zoom, zoom when "by type" is off, delay after zoning.
- Save a zoom for this zone, forget it, and the list of saved zone zooms with a Remove button each.

### Other
Open with `/minimap`'s editor, debug messages (menu names, combat start/end, zone zoom saves) and Reset to defaults (click twice).

---

## Commands

`/mme` also answers to `/minimapenhanced`, and to `/mmc` and `/minimapcontrol` so old macros keep working.

| Command | What it does |
| --- | --- |
| `/mme` or `/mme config` | Open or close the config window |
| `/mme editor` | Open `/minimap`'s editor with this window attached |
| `/mme info` | Why the minimap is shown or hidden right now |
| `/mme fade <in> [out]` | Fade times in ms, 0-1000 (for example `/mme fade 180 220`) |
| `/mme show` / `hide` / `auto` | Force it shown or hidden until `auto` (not saved) |
| `/mme combat` | Print when combat starts and ends, and why (toggle) |
| `/mme menus` | Print menu names as they change (toggle) |
| `/mme zoom` | This zone's type and zoom |
| `/mme zoom set <n>` | Save a zoom for this zone (0.1-2) |
| `/mme zoom save` | Save the minimap's current zoom for this zone |
| `/mme zoom clear` | Forget this zone's zoom (back to the hostile or safe default) |
| `/mme zoom hostile <n>` / `safe <n>` | First-visit zoom for hostile or safe zones |
| `/mme zoom on` / `off` | Zoom by zone type on or off |
| `/mme zoom autosave on\|off` | Save your zoom changes per zone |
| `/mme zoom list` | List every saved zone zoom |
| `/mme zoom debug` | Print a line whenever a zone's zoom is saved (toggle) |
| `/mme reset` | Restore the default settings |

---

## Credits

- **[minimapcontrol](https://github.com/onimitch/ffxi-ashita-minimapcontrol)** by onimitch (MIT), which this is based on. Its license is in [LICENSE-minimapcontrol](LICENSE-minimapcontrol).
- **minimapmon** by atom0s and the **minimap** plugin, bundled with [Ashita v4](https://github.com/AshitaXI/Ashita-v4beta).
- Helper functions in `mmhelpers.lua` come from [HXUI](https://github.com/tirem/HXUI) (GPL v3).
- Safe zone list checked against the [LandSandBoat](https://github.com/LandSandBoat/server) zone settings.

## License

Minimap Enhanced by Banedon is released under the [GNU General Public License v3](LICENSE). The parts from minimapcontrol stay under their MIT license ([LICENSE-minimapcontrol](LICENSE-minimapcontrol)).
