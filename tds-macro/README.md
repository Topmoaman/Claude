# TDS Macro

Record a Tower Defense Simulator run once, then replay it automatically on any map or mode.

## How to use

1. Join a match, run `TDSMacro.lua` in your executor, and type a strat name in the box.
2. Press **● Record** *before placing anything*, then play normally.
3. Press **■ Stop & Save** when you're done. The strat is saved to `workspace/TDSMacro/<name>.lua` and also copied to your clipboard.
4. In a new match on the same map, use the same loadout, type the name and press **▶ Play**.

You can also type a raw URL (for example a GitHub raw link) to play a strat hosted online.

## Settings

Set these before loading the script:

```lua
getgenv().TDSMacro = {
    File = "molten-farm",  -- strat name or raw URL
    AutoPlay = true,       -- start playing when a match loads (put the script in autoexec)
    ActionTimeout = 300,   -- seconds to keep retrying one placement/upgrade
    Debug = false,         -- log every tracked remote call while recording
}
loadstring(readfile("TDSMacro.lua"))()
```

## How it works

- **Recording:** the script watches your client's own `Troops` and `Voting` remote calls, using the same approach as a remote spy. It saves each call with the wave it happened on. Towers are saved by number (#1, #2…) in the order they were placed, so upgrades and sells point at the right tower on replay. Calls that failed, such as a placement without enough cash, are left out.
- **Playback:** the script waits for each recorded wave, then sends the same call. Placements and upgrades retry until they go through, so a run with less cash just waits longer. A skip vote is dropped once its wave has passed.
- **Strat files** are plain Lua tables, so you can read and edit them. They load in a sandbox, so a strat downloaded from someone else can only contain data. It can't run code.

## Limits

- You need an executor with `hookmetamethod` to record. Playback works on any executor that has `loadstring`/`readfile`.
- It doesn't handle the lobby: queueing, loadout and modifiers. The strat file lists the loadout and map it was recorded with.
- Start recording at wave 0, before placing any towers. Towers that were already down when you started can't be replayed.
