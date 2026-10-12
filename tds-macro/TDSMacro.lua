--[[
    TDS Macro - record & replay for Tower Defense Simulator

    RECORD: plays along while you play normally. Every tower action your own client
            sends (place, upgrade, sell, target, options, abilities, skip votes) is
            captured together with the wave it happened on, then saved to a strat file.
    PLAY:   loads a strat file (from your workspace folder or a URL), waits for each
            recorded wave, and replays the same calls. Placements and upgrades are
            retried until they go through, so a run with less cash just waits longer.

    Nothing about the game's remote format is hard-coded: whatever the client sends is
    what gets replayed, so it works on any map/mode and survives most game updates.

    Settings (set before loading):
        getgenv().TDSMacro = {
            File = "strat",       -- file name in workspace/TDSMacro/, or a raw URL
            AutoPlay = false,     -- start playing as soon as a match loads (for autoexec)
            ActionTimeout = 300,  -- seconds to keep retrying one placement/upgrade
            Debug = false,        -- log every tracked remote call while recording
        }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local Env = getgenv and getgenv() or _G

------------------------------------------------------------------------------------
-- Config
------------------------------------------------------------------------------------

local Config = Env.TDSMacro or {}
Config.Folder = Config.Folder or "TDSMacro"
Config.File = Config.File or "strat"
Config.AutoPlay = Config.AutoPlay == true
Config.RetryDelay = Config.RetryDelay or 0.5
Config.ActionTimeout = Config.ActionTimeout or 300
Config.SpawnWait = Config.SpawnWait or 3
Config.Debug = Config.Debug == true
Env.TDSMacro = Config

-- First argument of the remote calls worth recording.
local TRACKED_CATEGORIES = { Troops = true, Voting = true }

-- Shared across re-executions so the metamethod hook is only installed once.
local Shared = Env.__TDSMacroShared or {}
Env.__TDSMacroShared = Shared
if Shared.connections then
    for _, conn in ipairs(Shared.connections) do
        pcall(function() conn:Disconnect() end)
    end
end
Shared.connections = {}
Shared.recording = false
if Shared.stopPlayback then
    Shared.stopPlayback()
end

local function track(conn)
    table.insert(Shared.connections, conn)
    return conn
end

------------------------------------------------------------------------------------
-- Logging (GUI is attached later)
------------------------------------------------------------------------------------

local logSink
local function log(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[TDSMacro] " .. msg)
    if logSink then
        pcall(logSink, msg)
    end
end

local function setIdentity()
    local set = setthreadidentity or setidentity or (syn and syn.set_thread_identity)
    if set then
        pcall(set, 7)
    end
end

------------------------------------------------------------------------------------
-- Game state
------------------------------------------------------------------------------------

local function getGameStateReplicator()
    local reps = ReplicatedStorage:FindFirstChild("StateReplicators")
    return reps and reps:FindFirstChild("GameStateReplicator")
end

local function inMatch()
    return getGameStateReplicator() ~= nil
end

local function getWave()
    local rep = getGameStateReplicator()
    if not rep then
        return 0
    end
    return tonumber(rep:GetAttribute("Wave")) or 0
end

local function readMatchInfo()
    local info = { map = "Unknown", difficulty = "Unknown", mode = "Unknown", towers = {} }

    local state = ReplicatedStorage:FindFirstChild("State")
    if state then
        local map, difficulty, mode = state:FindFirstChild("Map"), state:FindFirstChild("Difficulty"), state:FindFirstChild("Mode")
        if map then info.map = tostring(map.Value) end
        if difficulty then info.difficulty = tostring(difficulty.Value) end
        if mode then info.mode = tostring(mode.Value) end
    end

    local reps = ReplicatedStorage:FindFirstChild("StateReplicators")
    if reps then
        for _, rep in ipairs(reps:GetChildren()) do
            if rep.Name == "PlayerReplicator" and rep:GetAttribute("UserId") == LocalPlayer.UserId then
                local equipped = rep:GetAttribute("EquippedTowers")
                local json = type(equipped) == "string" and equipped:match("%[.*%]")
                if json then
                    local ok, list = pcall(HttpService.JSONDecode, HttpService, json)
                    if ok and type(list) == "table" then
                        info.towers = list
                    end
                end
            end
        end
    end

    return info
end

------------------------------------------------------------------------------------
-- Tower spawn tracking
--
-- Every tower we own (holograms excluded) gets a sequence number in spawn order.
-- Recorder and player both "claim" new spawns after a call to learn which call
-- produced which tower.
------------------------------------------------------------------------------------

local Spawns = { seq = 0, claimed = 0, list = {} }

local function isOwnedRealTower(model)
    local rep = model:FindFirstChild("TowerReplicator") or model:WaitForChild("TowerReplicator", 5)
    if not rep then
        return false
    end
    if rep:GetAttribute("OwnerId") ~= LocalPlayer.UserId then
        return false
    end
    return rep:GetAttribute("Hologram") ~= true
end

local function towerName(model)
    local rep = model:FindFirstChild("TowerReplicator")
    return (rep and rep:GetAttribute("Name")) or model.Name
end

local function watchTowersFolder(folder)
    track(folder.ChildAdded:Connect(function(model)
        if isOwnedRealTower(model) then
            Spawns.seq += 1
            Spawns.list[Spawns.seq] = model
        end
    end))
end

local function resetSpawns()
    Spawns.claimed = Spawns.seq
end

-- Waits until `count` new towers appeared after sequence `before`, then claims them.
local function claimSpawns(before, count, timeout)
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
        local from = math.max(before, Spawns.claimed)
        if Spawns.seq - from >= count then
            local models = {}
            for i = from + 1, from + count do
                table.insert(models, Spawns.list[i])
            end
            Spawns.claimed = from + count
            return models
        end
        task.wait(0.05)
    end
    -- Partial result: claim whatever did appear so it isn't attributed to a later call.
    local from = math.max(before, Spawns.claimed)
    if Spawns.seq > from then
        local models = {}
        for i = from + 1, Spawns.seq do
            table.insert(models, Spawns.list[i])
        end
        Spawns.claimed = Spawns.seq
        return models
    end
    return nil
end

task.spawn(function()
    local folder = workspace:FindFirstChild("Towers")
    if not folder then
        local conn
        conn = track(workspace.ChildAdded:Connect(function(child)
            if child.Name == "Towers" and child:IsA("Folder") then
                conn:Disconnect()
                watchTowersFolder(child)
            end
        end))
        return
    end
    watchTowersFolder(folder)
end)

------------------------------------------------------------------------------------
-- Instance paths
------------------------------------------------------------------------------------

local function pathOf(inst)
    local parts = {}
    local current = inst
    while current and current ~= game do
        table.insert(parts, 1, current.Name)
        current = current.Parent
    end
    return parts
end

local function resolvePath(parts, timeout)
    local ok, current = pcall(game.GetService, game, parts[1])
    if not ok or not current then
        current = game:FindFirstChild(parts[1])
    end
    for i = 2, #parts do
        if not current then
            return nil
        end
        current = current:WaitForChild(parts[i], timeout or 10)
    end
    return current
end

------------------------------------------------------------------------------------
-- Serialization (strat files are plain Lua tables)
------------------------------------------------------------------------------------

local encode

local function encodeKey(k)
    if type(k) == "string" and k:match("^[_%a][_%w]*$") then
        return k
    end
    return "[" .. encode(k) .. "]"
end

-- towerIndexOf(instance) -> number|nil, supplied by the recorder.
local towerIndexOf = function() return nil end

encode = function(v, depth)
    depth = depth or 0
    if depth > 10 then
        return "nil"
    end

    local t = typeof(v)
    if t == "nil" or t == "boolean" then
        return tostring(v)
    elseif t == "number" then
        if v ~= v then return "0/0" end
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        return tostring(v)
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "Vector3" then
        return string.format("Vector3.new(%s, %s, %s)", encode(v.X), encode(v.Y), encode(v.Z))
    elseif t == "Vector2" then
        return string.format("Vector2.new(%s, %s)", encode(v.X), encode(v.Y))
    elseif t == "CFrame" then
        local parts = {}
        for i, c in ipairs({ v:GetComponents() }) do
            parts[i] = encode(c)
        end
        return "CFrame.new(" .. table.concat(parts, ", ") .. ")"
    elseif t == "EnumItem" then
        return tostring(v)
    elseif t == "Instance" then
        local idx = towerIndexOf(v)
        if idx then
            return string.format("{ __tower = %d }", idx)
        end
        local parts = {}
        for i, name in ipairs(pathOf(v)) do
            parts[i] = string.format("%q", name)
        end
        return "{ __path = { " .. table.concat(parts, ", ") .. " } }"
    elseif t == "table" then
        local parts = {}
        local n = #v
        for i = 1, n do
            parts[i] = encode(v[i], depth + 1)
        end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
                table.insert(keys, k)
            end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            table.insert(parts, encodeKey(k) .. " = " .. encode(v[k], depth + 1))
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "nil"
end

local function encodeArgs(args)
    local parts = {}
    for i = 1, args.n do
        parts[i] = encode(args[i])
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function argsReferenceTower(v, depth)
    depth = depth or 0
    if depth > 10 then
        return false
    end
    if typeof(v) == "Instance" then
        return towerIndexOf(v) ~= nil
    end
    if type(v) == "table" then
        for _, inner in pairs(v) do
            if argsReferenceTower(inner, depth + 1) then
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------------------------------
-- Recorder
------------------------------------------------------------------------------------

local Recorder = { actions = {}, towers = {}, towerCount = 0, seq = 0, info = nil }

local function recorderAssign(model)
    Recorder.towerCount += 1
    Recorder.towers[model] = Recorder.towerCount
    return Recorder.towerCount
end

towerIndexOf = function(inst)
    local current = inst
    while current and current ~= workspace do
        if Recorder.towers[current] then
            return Recorder.towers[current]
        end
        current = current.Parent
    end
    -- A tower of ours that no recorded call produced: index it anyway so later
    -- upgrades on it still line up, but warn because playback can't place it.
    if Shared.recording then
        current = inst
        while current and current ~= workspace do
            for i = Spawns.claimed + 1, Spawns.seq do
                if Spawns.list[i] == current then
                    Spawns.claimed = i
                    local idx = recorderAssign(current)
                    log("Warning: tower #%d (%s) appeared without a recorded placement", idx, towerName(current))
                    return idx
                end
            end
            current = current.Parent
        end
    end
    return nil
end

local function isQuery(args)
    for i = 1, args.n do
        local v = args[i]
        if type(v) == "string" and v:match("^Get") then
            return true
        end
    end
    return false
end

local function onRemoteCall(remote, method, args, results, spawnBefore, order)
    setIdentity()
    if typeof(remote) ~= "Instance" or not (remote.ClassName == "RemoteFunction" or remote.ClassName == "RemoteEvent") then
        return
    end

    local wave = getWave()
    local category = args[1]
    local succeeded = method == "FireServer" or (results.n > 0 and results[1] ~= nil and results[1] ~= false)

    if Config.Debug then
        log("[spy] %s:%s %s -> %s", remote.Name, method, encodeArgs(args), tostring(results[1]))
    end

    if isQuery(args) then
        return
    end

    local action = {
        order = order,
        wave = wave,
        remote = pathOf(remote),
        method = method,
        expect = method == "InvokeServer" and succeeded,
    }

    if category == "Voting" then
        action.args = encodeArgs(args)
        action.label = wave == 0 and "Ready" or ("Vote skip (wave " .. wave .. ")")
    elseif argsReferenceTower(args) then
        if not succeeded then
            return
        end
        action.args = encodeArgs(args)
        action.label = string.format("%s %s", tostring(args[2]), tostring(args[3] or ""))
    else
        -- Not about an existing tower: keep it only if it produced a tower (a placement).
        local models = claimSpawns(spawnBefore, 1, Config.SpawnWait)
        if not models then
            return
        end
        action.args = encodeArgs(args)
        action.spawns = {}
        local names = {}
        for _, model in ipairs(models) do
            table.insert(action.spawns, recorderAssign(model))
            table.insert(names, towerName(model))
        end
        action.label = "Place " .. table.concat(names, ", ")
    end

    table.insert(Recorder.actions, action)
    if action.spawns then
        log("W%d  %s  (#%s)", wave, action.label, table.concat(action.spawns, ", #"))
    else
        log("W%d  %s", wave, action.label)
    end
end

Shared.snapshot = function()
    Recorder.seq += 1
    return Spawns.seq, Recorder.seq
end
Shared.onCall = onRemoteCall

if not Shared.hooked and hookmetamethod and getnamecallmethod then
    Shared.hooked = true
    -- Not wrapped in newcclosure: on some executors that breaks yielding InvokeServer calls.
    local isOurs = checkcaller or function() return false end
    local original
    original = hookmetamethod(game, "__namecall", function(self, ...)
        -- Nothing in this branch may namecall before `original` runs, or the
        -- pending method name gets overwritten.
        local method = getnamecallmethod()
        if Shared.recording and (method == "InvokeServer" or method == "FireServer") and not isOurs() then
            local first = ...
            if type(first) == "string" and TRACKED_CATEGORIES[first] then
                local spawnBefore, order = Shared.snapshot()
                local args = table.pack(...)
                local results = table.pack(original(self, ...))
                task.spawn(Shared.onCall, self, method, args, results, spawnBefore, order)
                return table.unpack(results, 1, results.n)
            end
        end
        return original(self, ...)
    end)
end

local function canRecord()
    return Shared.hooked == true
end

local function startRecording()
    if not canRecord() then
        log("Your executor has no hookmetamethod; recording isn't supported (playback still works)")
        return
    end
    if not inMatch() then
        log("Join a match first, then start recording")
        return
    end

    table.clear(Recorder.actions)
    table.clear(Recorder.towers)
    Recorder.towerCount = 0
    Recorder.info = readMatchInfo()
    resetSpawns()

    local existing = 0
    local folder = workspace:FindFirstChild("Towers")
    if folder then
        for _, model in ipairs(folder:GetChildren()) do
            local rep = model:FindFirstChild("TowerReplicator")
            if rep and rep:GetAttribute("OwnerId") == LocalPlayer.UserId and rep:GetAttribute("Hologram") ~= true then
                recorderAssign(model)
                existing += 1
            end
        end
    end

    Shared.recording = true
    log("Recording on %s (%s). Play normally.", Recorder.info.map, Recorder.info.difficulty)
    if existing > 0 then
        log("Warning: %d tower(s) already placed; playback can't recreate them", existing)
    end
end

local function serializeStrat()
    table.sort(Recorder.actions, function(a, b) return a.order < b.order end)
    local info = Recorder.info or readMatchInfo()

    local lines = {
        "-- Recorded with TDSMacro on " .. os.date("%Y-%m-%d %H:%M"),
        "return {",
        "    version = 1,",
        "    info = " .. encode({
            map = info.map,
            difficulty = info.difficulty,
            mode = info.mode,
            towers = info.towers,
        }) .. ",",
        "    actions = {",
    }
    for _, a in ipairs(Recorder.actions) do
        local fields = {
            "wave = " .. a.wave,
            "remote = " .. encode(a.remote),
            "method = " .. string.format("%q", a.method),
            "args = " .. a.args,
        }
        if a.expect then
            table.insert(fields, "expect = true")
        end
        if a.spawns then
            table.insert(fields, "spawns = " .. encode(a.spawns))
        end
        table.insert(lines, string.format("        { %s }, -- %s", table.concat(fields, ", "), a.label or ""))
    end
    table.insert(lines, "    },")
    table.insert(lines, "}")
    return table.concat(lines, "\n") .. "\n"
end

local function stratPath(name)
    if not name:match("%.lua$") and not name:match("%.txt$") then
        name ..= ".lua"
    end
    return Config.Folder .. "/" .. name
end

local function stopRecording(fileName)
    if not Shared.recording then
        log("Not recording")
        return
    end
    Shared.recording = false
    task.wait(Config.SpawnWait + 0.2) -- let in-flight placements resolve

    local src = serializeStrat()
    if writefile then
        if makefolder and isfolder and not isfolder(Config.Folder) then
            makefolder(Config.Folder)
        end
        local path = stratPath(fileName)
        writefile(path, src)
        log("Saved %d actions to workspace/%s", #Recorder.actions, path)
    else
        log("Executor has no writefile; strat printed to console")
        print(src)
    end
    if setclipboard then
        pcall(setclipboard, src)
        log("Strat also copied to clipboard")
    end
end

------------------------------------------------------------------------------------
-- Strat loading (sandboxed: a strat file can only build data, not run code)
------------------------------------------------------------------------------------

local function loadStrat(source)
    local src
    if source:match("^https?://") then
        local ok, body = pcall(game.HttpGet, game, source)
        if not ok then
            return nil, "download failed: " .. tostring(body)
        end
        src = body
    else
        local path = stratPath(source)
        if not (isfile and isfile(path)) then
            return nil, "file not found: workspace/" .. path
        end
        src = readfile(path)
    end

    local chunk, err = loadstring(src)
    if not chunk then
        return nil, "syntax error: " .. tostring(err)
    end
    setfenv(chunk, {
        Vector3 = { new = Vector3.new },
        Vector2 = { new = Vector2.new },
        CFrame = { new = CFrame.new },
        Enum = Enum,
        math = { huge = math.huge },
    })
    local ok, strat = pcall(chunk)
    if not ok then
        return nil, "error while reading: " .. tostring(strat)
    end
    if type(strat) ~= "table" or type(strat.actions) ~= "table" then
        return nil, "not a TDSMacro strat (no actions table)"
    end
    return strat
end

------------------------------------------------------------------------------------
-- Player
------------------------------------------------------------------------------------

local Player = { running = false, towers = {}, runId = 0 }

local function decode(v, missing, depth)
    depth = depth or 0
    if type(v) ~= "table" or depth > 10 then
        return v
    end
    if v.__tower then
        local model = Player.towers[v.__tower]
        if not model or not model.Parent then
            missing[#missing + 1] = v.__tower
        end
        return model
    end
    if v.__path then
        return resolvePath(v.__path, 5)
    end
    local out = {}
    for k, inner in pairs(v) do
        out[k] = decode(inner, missing, depth + 1)
    end
    return out
end

local function hasTowerToken(v, depth)
    depth = depth or 0
    if type(v) ~= "table" or depth > 10 then
        return false
    end
    if v.__tower then
        return true
    end
    for _, inner in pairs(v) do
        if hasTowerToken(inner, depth + 1) then
            return true
        end
    end
    return false
end

local function argCount(args)
    local n = 0
    for k in pairs(args) do
        if type(k) == "number" and k > n then
            n = k
        end
    end
    return n
end

local function waitForWave(wave, runId)
    while Player.runId == runId and getWave() < wave do
        if not inMatch() then
            return false
        end
        task.wait(0.25)
    end
    return Player.runId == runId
end

local function runAction(action, runId)
    local remote = resolvePath(action.remote, 10)
    if not remote then
        return false, "remote not found: " .. table.concat(action.remote, ".")
    end

    local hasTowerRef = hasTowerToken(action.args)
    local deadline = os.clock() + Config.ActionTimeout
    local startWave = getWave()

    while Player.runId == runId do
        local missing = {}
        local args = decode(action.args, missing)
        if #missing > 0 then
            return false, "tower #" .. missing[1] .. " doesn't exist (placement failed or sold)"
        end

        local before = Spawns.seq
        local ok, result = pcall(function()
            if action.method == "InvokeServer" then
                return remote:InvokeServer(table.unpack(args, 1, argCount(args)))
            end
            remote:FireServer(table.unpack(args, 1, argCount(args)))
            return true
        end)

        local done
        if action.spawns then
            local models = claimSpawns(before, #action.spawns, Config.SpawnWait)
            if models then
                for i, model in ipairs(models) do
                    local idx = action.spawns[i]
                    if idx then
                        Player.towers[idx] = model
                    end
                end
                done = #models >= #action.spawns
            end
        elseif action.expect then
            done = ok and result ~= nil and result ~= false
        else
            done = ok
        end

        if done then
            return true
        end
        if os.clock() > deadline then
            return false, "timed out"
        end
        -- Votes and other non-tower calls only make sense during the wave they were made in.
        if not action.spawns and not hasTowerRef and getWave() ~= startWave then
            return false, "wave passed"
        end
        if not inMatch() then
            return false, "match ended"
        end
        task.wait(Config.RetryDelay)
    end
    return false, "stopped"
end

local function stopPlayback()
    if Player.running then
        Player.runId += 1
        Player.running = false
        log("Playback stopped")
    end
end
Shared.stopPlayback = stopPlayback

local function play(source)
    if Player.running then
        log("Already playing; stop first")
        return
    end
    if Shared.recording then
        log("Stop recording before playing")
        return
    end
    if not inMatch() then
        log("Join a match first, then press Play")
        return
    end

    local strat, err = loadStrat(source)
    if not strat then
        log("Can't load strat: %s", err)
        return
    end

    local info = strat.info or {}
    local current = readMatchInfo()
    log("Loaded %d actions (recorded on %s / %s)", #strat.actions, tostring(info.map), tostring(info.difficulty))
    if info.map and info.map ~= current.map then
        log("Warning: you're on %s, strat was recorded on %s", current.map, info.map)
    end
    if type(info.towers) == "table" and #info.towers > 0 then
        log("Needs loadout: %s", table.concat(info.towers, ", "))
    end

    Player.running = true
    Player.runId += 1
    local runId = Player.runId
    table.clear(Player.towers)
    resetSpawns()

    task.spawn(function()
        for i, action in ipairs(strat.actions) do
            if not waitForWave(action.wave or 0, runId) then
                break
            end
            local ok, why = runAction(action, runId)
            if Player.runId ~= runId then
                break
            end
            local label = action.spawns and ("place -> #" .. table.concat(action.spawns, ", #"))
                or tostring(action.args and action.args[2] or action.method)
            if ok then
                log("[%d/%d] W%d %s", i, #strat.actions, getWave(), label)
            else
                log("[%d/%d] skipped %s: %s", i, #strat.actions, label, why)
            end
        end
        if Player.runId == runId then
            Player.running = false
            log("Strat finished")
        end
    end)
end

------------------------------------------------------------------------------------
-- GUI
------------------------------------------------------------------------------------

local function make(class, props, children)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        inst[k] = v
    end
    for _, child in ipairs(children or {}) do
        child.Parent = inst
    end
    return inst
end

local function buildGui()
    local parent = (gethui and gethui()) or game:GetService("CoreGui")
    local old = parent:FindFirstChild("TDSMacroGui")
    if old then
        old:Destroy()
    end

    local gui = make("ScreenGui", { Name = "TDSMacroGui", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
    local corner = function(r) return make("UICorner", { CornerRadius = UDim.new(0, r) }) end

    local frame = make("Frame", {
        Size = UDim2.fromOffset(280, 330),
        Position = UDim2.new(0, 20, 0.5, -165),
        BackgroundColor3 = Color3.fromRGB(22, 22, 28),
        BorderSizePixel = 0,
        Parent = gui,
    }, { corner(8) })

    local title = make("TextLabel", {
        Size = UDim2.new(1, -40, 0, 30),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Text = "TDS Macro",
        TextColor3 = Color3.fromRGB(235, 235, 245),
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })

    local minimize = make("TextButton", {
        Size = UDim2.fromOffset(26, 22),
        Position = UDim2.new(1, -32, 0, 4),
        BackgroundColor3 = Color3.fromRGB(40, 40, 50),
        Text = "–",
        TextColor3 = Color3.fromRGB(220, 220, 230),
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        Parent = frame,
    }, { corner(5) })

    local body = make("Frame", {
        Size = UDim2.new(1, -24, 1, -40),
        Position = UDim2.fromOffset(12, 34),
        BackgroundTransparency = 1,
        Parent = frame,
    })

    local fileBox = make("TextBox", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundColor3 = Color3.fromRGB(32, 32, 40),
        Text = Config.File,
        PlaceholderText = "strat name or raw URL",
        TextColor3 = Color3.fromRGB(235, 235, 245),
        PlaceholderColor3 = Color3.fromRGB(120, 120, 135),
        Font = Enum.Font.Gotham,
        TextSize = 13,
        ClearTextOnFocus = false,
        Parent = body,
    }, { corner(6), make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }) })

    local function button(text, color, x, y)
        return make("TextButton", {
            Size = UDim2.new(0.5, -4, 0, 30),
            Position = UDim2.new(x, x > 0 and 4 or 0, 0, y),
            BackgroundColor3 = color,
            Text = text,
            TextColor3 = Color3.fromRGB(255, 255, 255),
            Font = Enum.Font.GothamBold,
            TextSize = 13,
            AutoButtonColor = true,
            Parent = body,
        }, { corner(6) })
    end

    local recordBtn = button("● Record", Color3.fromRGB(190, 55, 65), 0, 38)
    local saveBtn = button("■ Stop & Save", Color3.fromRGB(70, 70, 85), 0.5, 38)
    local playBtn = button("▶ Play", Color3.fromRGB(45, 140, 85), 0, 74)
    local stopBtn = button("■ Stop Play", Color3.fromRGB(70, 70, 85), 0.5, 74)

    local status = make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 18),
        Position = UDim2.fromOffset(0, 110),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = Color3.fromRGB(160, 160, 175),
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = body,
    })

    local logFrame = make("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, -134),
        Position = UDim2.fromOffset(0, 132),
        BackgroundColor3 = Color3.fromRGB(16, 16, 20),
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Parent = body,
    }, { corner(6), make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 4) }) })

    local logText = make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = Color3.fromRGB(200, 200, 210),
        Font = Enum.Font.Code,
        TextSize = 12,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        Parent = logFrame,
    })

    local lines = {}
    logSink = function(msg)
        table.insert(lines, msg)
        while #lines > 60 do
            table.remove(lines, 1)
        end
        logText.Text = table.concat(lines, "\n")
        task.defer(function()
            logFrame.CanvasPosition = Vector2.new(0, math.huge)
        end)
    end

    local function refreshStatus()
        local state = Shared.recording and "Recording" or (Player.running and "Playing" or "Idle")
        status.Text = string.format("%s  •  wave %d", state, getWave())
    end
    task.spawn(function()
        while gui.Parent do
            refreshStatus()
            task.wait(0.5)
        end
    end)

    local function fileName()
        local name = fileBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then
            name = "strat"
        end
        return name
    end

    recordBtn.MouseButton1Click:Connect(function()
        task.spawn(startRecording)
    end)
    saveBtn.MouseButton1Click:Connect(function()
        task.spawn(stopRecording, fileName())
    end)
    playBtn.MouseButton1Click:Connect(function()
        task.spawn(play, fileName())
    end)
    stopBtn.MouseButton1Click:Connect(stopPlayback)

    local collapsed = false
    minimize.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        body.Visible = not collapsed
        frame.Size = collapsed and UDim2.fromOffset(280, 30) or UDim2.fromOffset(280, 330)
        minimize.Text = collapsed and "+" or "–"
    end)

    -- Drag by the title bar.
    local dragging, dragStart, startPos
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, frame.Position
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    gui.Parent = parent
end

------------------------------------------------------------------------------------
-- Start
------------------------------------------------------------------------------------

buildGui()
log("Loaded. %s", canRecord() and "Record + play ready." or "Playback only (no hookmetamethod).")

if Config.AutoPlay then
    task.spawn(function()
        local waited = 0
        while not inMatch() and waited < 60 do
            task.wait(1)
            waited += 1
        end
        if inMatch() then
            task.wait(2)
            play(Config.File)
        end
    end)
end

return {
    StartRecording = startRecording,
    StopRecording = stopRecording,
    Play = play,
    Stop = stopPlayback,
    GetWave = getWave,
}
