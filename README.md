# Matt's KeeperFX Mods

Lua mod systems for KeeperFX focused on persistent progression, offline rewards, and randomized map modifiers.

## Files

- `upgrades.lua` - persistent upgrade shop and Upgrade Gold progression.
- `offline_progress.lua` - offline rewards, checkpointing, save/load rebinding, and training simulation.
- `world_modifiers.lua` - randomized world modifiers and active map effects.

## Player commands

- `/upgrades` - show upgrade tabs.
- `/upgrades info <id>` - show one upgrade in detail.
- `/upgrades buy <id>` - buy one upgrade rank.
- `/upgrades buymax` - buy efficient affordable upgrades.
- `/upgrades status` - show owned upgrade summary.
- `/m`, `/modifier`, or `/modifiers` - show active world modifiers.

## Runtime files

Generated files such as `upgrades.dat`, `offline_progress.dat`, and `offline_progress.log` are local play-session data and should not be committed.

## Development notes

- Keep scripts compatible with KeeperFX Lua.
- Guard optional KeeperFX API calls before using them.
- Use `pcall` where a missing runtime API should not stop the whole mod.
- Keep generated data files out of version control.
- Load `upgrades.lua` before `offline_progress.lua` so offline rewards can call upgrade helpers when available.
- Treat `world_modifiers.lua` effects as map/session effects unless the modifier explicitly stores state in `Game`.
