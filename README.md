# Matt's KeeperFX Mods

Lua mod systems for KeeperFX.

## Files

- `upgrades.lua` - persistent upgrade shop and Upgrade Gold progression.
- `offline_progress.lua` - offline rewards, checkpointing, and save/load rebinding.
- `world_modifiers.lua` - randomized world modifiers and map effects.

## Runtime files

Generated files such as `upgrades.dat`, `offline_progress.dat`, and `offline_progress.log` are local play-session data and should not be committed.

## Development notes

- Keep scripts compatible with KeeperFX Lua.
- Guard optional KeeperFX API calls before using them.
- Use `pcall` where a missing runtime API should not stop the whole mod.
- Keep generated data files out of version control.
