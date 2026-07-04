# Matt's KeeperFX Mods

Lua mod systems for KeeperFX focused on persistent progression, offline rewards, automated camera movement, aggressive computer digging, randomized map modifiers, and light in-session quality-of-life support.

## Files

- `init.lua` - entry point that loads core modules and mods in a dependency-safe order.
- `upgrades.lua` - persistent upgrade shop and Upgrade Gold progression.
- `offline_progress.lua` - offline rewards, checkpointing, save/load rebinding, and training simulation.
- `quality_of_life.lua` - safe in-game polish: low-gold safety stipend and tiny active-play Upgrade Gold trickle.
- `world_modifiers.lua` - randomized world modifiers and active map effects.
- `auto_camera.lua` - automated cinematic camera targeting, interrupts, and chat controls.
- `computer_dig_aggressive.lua` - PLAYER0 auto-dig logic for hero/rival objectives.
- `keepcompp.cfg` - KeeperFX computer player configuration.

## Player commands

- `/upgrades` - show upgrade tabs.
- `/upgrades info <id>` - show one upgrade in detail.
- `/upgrades buy <id>` - buy one upgrade rank.
- `/upgrades buymax` - buy efficient affordable upgrades.
- `/upgrades status` - show owned upgrade summary.
- `/m`, `/modifier`, or `/modifiers` - show active world modifiers.
- `/autocam` - control the automated camera system when `auto_camera.lua` is loaded.

## Runtime files

Generated files such as `upgrades.dat`, `offline_progress.dat`, and `offline_progress.log` are local play-session data and should not be committed.

## Development notes

- Keep scripts compatible with KeeperFX Lua.
- Guard optional KeeperFX API calls before using them.
- Use `pcall` where a missing runtime API should not stop the whole mod.
- Keep generated data files out of version control.
- Load `upgrades.lua` before `offline_progress.lua` so offline rewards can call upgrade helpers when available.
- Load `quality_of_life.lua` after `offline_progress.lua`; it uses optional Upgrade Gold helpers but remains safe if they are unavailable.
- Treat `world_modifiers.lua` effects as map/session effects unless the modifier explicitly stores state in `Game`.
