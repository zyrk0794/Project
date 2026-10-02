--[[
    Midnight Spooky Hunter 1.1.3 - Lumber Tycoon 2
    October 2, 2026. Standalone client script; no UI-library download required.
    Modwood is an experimental reconstruction of the supplied Dark X source.
    A failed burn, missing plank, or unconfirmed save stops the cycle in place.
    Use the companion loader or set Script URL for continuation after a hop.
]]
local S = {}
for _, name in ipairs({"Players", "Workspace", "ReplicatedStorage", "HttpService", "TweenService",
    "UserInputService", "RunService", "TeleportService"}) do S[name] = game:GetService(name) end
local Player = S.Players.LocalPlayer
assert(Player, "Spooky Hunter requires a client")
local Env = type(getgenv) == "function" and getgenv() or _G
local old = Env.MidnightSpookyHunter
if old and type(old.Destroy) == "function" then old:Destroy() end
local function cap(name, fallback)
    local fn = Env[name] or _G[name] or fallback
    return type(fn) == "function" and fn or nil
end
local synAPI, httpAPI = Env.syn or syn, Env.http or http
local Request = cap("request", request) or cap("http_request", http_request)
    or (type(synAPI) == "table" and synAPI.request) or (type(httpAPI) == "table" and httpAPI.request)
local Queue = cap("queue_on_teleport", queue_on_teleport) or cap("queueonteleport", queueonteleport)
    or (type(synAPI) == "table" and synAPI.queue_on_teleport)
local Read, Write = cap("readfile", readfile), cap("writefile", writefile)
local FILE = "MidnightSpookyHunter.json"
local DEFAULT = { Slot = 1, Webhook = "", ScriptURL = "", HopDelay = 15, ScanWait = 12,
    ChopTimeout = 75, BurnTimeout = 40, MillTimeout = 80, FullCycle = true }
local H = { Alive = true, Running = false, Busy = false, Connections = {}, Logs = {},
    Config = table.clone(DEFAULT), Visited = {}, Stats = { Servers = 0, Trees = 0, Planks = 0 },
    StartedAt = os.time(), Arrived = os.clock(), Generation = 0, Stage = "Ready", Progress = 0 }
Env.MidnightSpookyHunter = H
local CANCEL = {}
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function value(object, name)
    local field = object and object:FindFirstChild(name)
    if field and field:IsA("ValueBase") then return field.Value end
    return nil
end
local function owned(model) return value(model, "Owner") == Player end
local function partOf(model)
    return model and (model.PrimaryPart or model:FindFirstChild("Main") or model:FindFirstChild("WoodSection")
        or model:FindFirstChildWhichIsA("BasePart", true))
end
local function rare(kind) return kind == "Spooky" or kind == "SpookyNeon" end
local function duration(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end
local function cleanURL(url)
    url = tostring(url or ""):match("^%s*(.-)%s*$")
    return url
end
local function webhookURL(url)
    return url:match("^https://discord%.com/api/webhooks/%d+/[%w_-]+$")
        or url:match("^https://discordapp%.com/api/webhooks/%d+/[%w_-]+$")
end
local function configFrom(source)
    local result = table.clone(DEFAULT)
    if type(source) ~= "table" then return result end
    for key in pairs(result) do if type(source[key]) == type(result[key]) then result[key] = source[key] end end
    result.Slot = math.floor(math.clamp(finite(result.Slot) and result.Slot or 1, 1, 6))
    for key, limits in pairs({HopDelay = {12, 180}, ScanWait = {8, 120}, ChopTimeout = {15, 180},
        BurnTimeout = {10, 120}, MillTimeout = {15, 180}}) do
        result[key] = math.clamp(finite(result[key]) and result[key] or DEFAULT[key], limits[1], limits[2])
    end
    result.Webhook = cleanURL(result.Webhook):sub(1, 400)
    result.ScriptURL = cleanURL(result.ScriptURL):sub(1, 1000)
    return result
end
local restored
if Read then
    local ok, text = pcall(Read, FILE)
    if ok then
        local decoded, data = pcall(S.HttpService.JSONDecode, S.HttpService, text)
        if decoded and type(data) == "table" and data.Schema == 1 then
            H.Config = configFrom(data.Config)
            restored = data
            if type(data.Visited) == "table" then
                for id, stamp in pairs(data.Visited) do
                    if type(id) == "string" and finite(stamp) and os.time() - stamp < 14400 then H.Visited[id] = stamp end
                end
            end
            if type(data.Stats) == "table" then
                for key in pairs(H.Stats) do
                    if finite(data.Stats[key]) then H.Stats[key] = math.max(0, math.floor(data.Stats[key])) end
                end
            end
            if finite(data.StartedAt) then H.StartedAt = math.min(os.time(), data.StartedAt) end
        elseif ok then H.ConfigWarning = "Settings file unreadable - defaults loaded" end
    end
end
function H:Log(message, level)
    message = tostring(message)
    -- Never print the webhook token or raw HTTP error body.
    if self.Config.Webhook ~= "" then message = message:gsub(self.Config.Webhook:gsub("([^%w])", "%%%1"), "[webhook]") end
    table.insert(self.Logs, os.date("!%H:%M:%S") .. "  " .. (level or "INFO") .. "  " .. message)
    while #self.Logs > 70 do table.remove(self.Logs, 1) end
    if self.UI then self.UI.Activity.Text = table.concat(self.Logs, "\n") end
end
function H:SetStage(text, progress, detail)
    self.Stage = text
    if progress then self.Progress = math.clamp(progress, 0, 1) end
    if self.UI then
        self.UI.Stage.Text = text self.UI.Detail.Text = detail or ""
        if self.StageTween then self.StageTween:Cancel() end
        self.UI.Stage.TextTransparency = 0.28
        self.StageTween = S.TweenService:Create(self.UI.Stage, TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
            {TextTransparency = 0})
        self.StageTween:Play()
        if self.ProgressTween then self.ProgressTween:Cancel() end
        self.ProgressTween = S.TweenService:Create(self.UI.Fill, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
            { Size = UDim2.fromScale(self.Progress, 1) })
        self.ProgressTween:Play()
    end
    self:Log(text .. (detail and (" - " .. detail) or ""))
end
function H:Connect(signal, callback)
    local connection = signal:Connect(function(...)
        if not self.Alive then return end
        local ok, err = pcall(callback, ...)
        if not ok then self:Log(tostring(err), "ERROR") end
    end)
    table.insert(self.Connections, connection)
    return connection
end
function H:Persist(resume, target)
    if not Write or not Read then return false, "readfile/writefile unavailable" end
    local entries = {}
    for id, stamp in pairs(self.Visited) do table.insert(entries, {id, stamp}) end
    table.sort(entries, function(a,b) return a[2] > b[2] end)
    local visited = {}
    for index = 1, math.min(#entries, 200) do visited[entries[index][1]] = entries[index][2] end
    local data = { Schema = 1, Config = self.Config, Visited = visited, Stats = self.Stats,
        StartedAt = self.StartedAt, Resume = resume == true, Target = target, TicketTime = os.time() }
    local ok = pcall(function()
        local encoded = S.HttpService:JSONEncode(data)
        Write(FILE, encoded)
        assert(Read(FILE) == encoded, "Settings write verification failed")
    end)
    if ok then return true end
    return false, "Settings could not be saved"
end
function H:Token()
    self.Generation = self.Generation + 1
    local token = { Generation = self.Generation, Cleanups = {} }
    function token:Check()
        if not H.Alive or not H.Running or H.Generation ~= self.Generation then error(CANCEL, 0) end
        if self.Character and (Player.Character ~= self.Character or not self.Character.Parent
            or not self.Character:FindFirstChildOfClass("Humanoid") or self.Character:FindFirstChildOfClass("Humanoid").Health <= 0) then
            error("Character changed - cycle stopped in this server", 0)
        end
    end
    function token:Sleep(seconds)
        local deadline = os.clock() + seconds
        repeat self:Check() task.wait(math.min(0.08, math.max(0, deadline - os.clock()))) until os.clock() >= deadline
        self:Check()
    end
    function token:Finally(fn) table.insert(self.Cleanups, fn) return fn end
    function token:Clean()
        for i = #self.Cleanups, 1, -1 do
            local ok, err = pcall(self.Cleanups[i])
            if not ok then H:Log("Cleanup - " .. tostring(err), "ERROR") end
        end
        table.clear(self.Cleanups)
    end
    function token:Await(fn, timeout, onWaiting)
        local result
        local thread = task.spawn(function() result = table.pack(pcall(fn)) end)
        local deadline = os.clock() + (timeout or 20)
        local function cancel() if not result then pcall(task.cancel, thread) end end
        self:Finally(cancel)
        while not result and os.clock() < deadline do
            if onWaiting then onWaiting() end
            self:Sleep(0.08)
        end
        if not result then cancel() error("Request timed out - it may still complete on the server", 0) end
        self:Check()
        if not result[1] then error(result[2], 0) end
        return table.unpack(result, 2, result.n)
    end
    return token
end
function H:Remote(folder, name, class)
    local parent = S.ReplicatedStorage:FindFirstChild(folder)
    local remote = parent and parent:FindFirstChild(name)
    assert(remote and remote:IsA(class or "RemoteEvent"), "Missing game remote: " .. folder .. "." .. name)
    return remote
end
function H:Character()
    local character = Player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    assert(humanoid and humanoid.Health > 0 and root, "Wait for your character")
    return character, humanoid, root
end
function H:Teleport(cf)
    local character, humanoid, root = self:Character()
    humanoid.Sit = false character:PivotTo(cf)
    root.AssemblyLinearVelocity = Vector3.zero root.AssemblyAngularVelocity = Vector3.zero
end
function H:PlotTiles(plot)
    local tiles = {}
    for _, part in ipairs(plot and plot:GetDescendants() or {}) do
        if part:IsA("BasePart") and (part.Name == "OriginSquare" or part.Name == "Square") then
            table.insert(tiles, part)
        end
    end
    return tiles
end
function H:Plot()
    local candidates, seen = {}, {}
    local function visit(node)
        if seen[node] then return end
        seen[node] = true
        local owner = node:FindFirstChild("Owner")
        if owner then
            if owner:IsA("ObjectValue") and owner.Value == Player then table.insert(candidates, node) end
            return
        end
        for _, child in ipairs(node:GetChildren()) do
            if child:IsA("Model") or child:IsA("Folder") then visit(child) end
        end
    end
    -- GetChildren is intentional: several sibling instances may share a name.
    for _, container in ipairs(S.Workspace:GetChildren()) do
        if container.Name == "Properties" or container.Name == "Propertie" or container.Name == "Property" then
            visit(container)
        end
    end
    local best, bestScore
    for _, plot in ipairs(candidates) do
        local count = #self:PlotTiles(plot)
        local score = (count > 0 and 100000 or 0) + (plot == self.LoadedPlot and 1 or 0)
        if not best or score > bestScore then best, bestScore = plot, score end
    end
    self.LoadedPlot = best
    return best
end
function H:PlotCenter(plot)
    local minX, maxX, minZ, maxZ, y = math.huge, -math.huge, math.huge, -math.huge, -math.huge
    for _, tile in ipairs(self:PlotTiles(plot)) do
        if tile:IsA("BasePart") and (tile.Name == "Square" or tile.Name == "OriginSquare") then
            minX, maxX = math.min(minX, tile.Position.X - tile.Size.X / 2), math.max(maxX, tile.Position.X + tile.Size.X / 2)
            minZ, maxZ = math.min(minZ, tile.Position.Z - tile.Size.Z / 2), math.max(maxZ, tile.Position.Z + tile.Size.Z / 2)
            y = math.max(y, tile.Position.Y + tile.Size.Y / 2)
        end
    end
    assert(minX < math.huge, "The loaded plot has no land tiles")
    local desired = Vector3.new((minX + maxX) / 2, y, (minZ + maxZ) / 2)
    -- For an L-shaped plot, use the nearest owned tile to the geometric center.
    local nearest, distance
    for _, tile in ipairs(self:PlotTiles(plot)) do
        if tile:IsA("BasePart") and (tile.Name == "Square" or tile.Name == "OriginSquare") then
            local point = Vector3.new(math.clamp(desired.X, tile.Position.X - tile.Size.X/2 + 2, tile.Position.X + tile.Size.X/2 - 2),
                tile.Position.Y + tile.Size.Y/2, math.clamp(desired.Z, tile.Position.Z - tile.Size.Z/2 + 2, tile.Position.Z + tile.Size.Z/2 - 2))
            local delta = (point - desired).Magnitude
            if not distance or delta < distance then nearest, distance = point, delta end
        end
    end
    return CFrame.new(nearest)
end
-- A successful firesignal call is only an attempt, not proof that the game
-- accepted the click. Wait for the next panel before advancing to step two.
function H:LoadConfirmation(token)
    local state = {Step=1, Seen=false, SeenFirst=false, FirstSent=false, SecondSent=false,
        LastCheck=-math.huge, Attempts={0,0}, LastAttempt={-math.huge,-math.huge}, HavePlot=false}
    local fire = cap("firesignal", firesignal)
    local getConnections = cap("getconnections", getconnections)
    local function visible(button, gui)
        if not button or not button:IsA("GuiButton") or not gui.Enabled then return false end
        local node = button
        while node and node ~= gui do
            if node:IsA("GuiObject") and not node.Visible then return false end
            node = node.Parent
        end
        return node == gui
    end
    local function buttons()
        local playerGui = Player:FindFirstChildOfClass("PlayerGui")
        local gui = playerGui and playerGui:FindFirstChild("PropertyPurchasingGUI")
        if not gui or not gui:IsA("ScreenGui") then return nil end
        local selectPanel = gui:FindFirstChild("SelectPurchase")
        local confirmPanel = gui:FindFirstChild("ConfirmPurchase")
        return gui, selectPanel and selectPanel:FindFirstChild("Purchase"),
            confirmPanel and confirmPanel:FindFirstChild("Purchase")
    end
    function state:Open()
        local gui, first, second = buttons()
        return gui and (visible(first, gui) or visible(second, gui)) or false
    end
    local function signalFor(button, attempt)
        local names = {"MouseButton1Click", "MouseButton1Down", "Activated"}
        if getConnections then
            local connected = {}
            for _, name in ipairs(names) do
                local ok, listeners = pcall(getConnections, button[name])
                if ok and type(listeners) == "table" then
                    for _, listener in ipairs(listeners) do
                        if listener.Enabled ~= false and listener.Connected ~= false then
                            table.insert(connected, name)
                            break
                        end
                    end
                end
            end
            if #connected > 0 then return connected[attempt % #connected + 1] end
        end
        return names[attempt % #names + 1]
    end
    local function service()
        token:Check()
        if os.clock() - state.LastCheck < 0.1 then return end
        state.LastCheck = os.clock()
        local gui, first, second = buttons()
        if not gui then return end
        local firstVisible, secondVisible = visible(first, gui), visible(second, gui)
        if firstVisible or secondVisible then state.Seen = true end
        if firstVisible then state.SeenFirst = true end
        if state.Step == 1 and secondVisible and
            ((state.FirstSent and (not state.SecondVisibleBeforeClick or not firstVisible))
                or (state.SeenFirst and not firstVisible)) then
            state.Step = 2
            H:SetStage("Confirming property", 0.14, "Selection accepted by the game")
        end
        if state.SecondSent and (state.HavePlot or not secondVisible) then state.Step = 3 end
        if state.Step == 3 then return end
        local button
        -- Do not use `condition and first or second`: a missing first button
        -- would silently select the second one while replication is incomplete.
        if state.Step == 1 then button = first else button = second end
        if not visible(button, gui) then state.VisibleSince = nil return end
        if state.VisibleButton ~= button then
            state.VisibleButton = button state.VisibleSince = os.clock() return
        end
        state.VisibleSince = state.VisibleSince or os.clock()
        local step = state.Step
        if os.clock() - state.VisibleSince < 0.2 or os.clock() - state.LastAttempt[step] < 1 then return end
        assert(fire, "Slot confirmation requires firesignal in this executor")
        assert(state.Attempts[step] < 6, "Property button did not respond - " ..
            (step == 1 and "SelectPurchase.Purchase" or "ConfirmPurchase.Purchase"))
        local signalName = signalFor(button, state.Attempts[step])
        if step == 1 and not state.FirstSent then state.SecondVisibleBeforeClick = secondVisible end
        state.Attempts[step] = state.Attempts[step] + 1 state.LastAttempt[step] = os.clock()
        local ok
        if signalName == "MouseButton1Down" then
            ok = pcall(fire, button[signalName], button.AbsolutePosition.X + button.AbsoluteSize.X/2,
                button.AbsolutePosition.Y + button.AbsoluteSize.Y/2)
        elseif signalName == "Activated" then ok = pcall(fire, button[signalName], nil, 1)
        else ok = pcall(fire, button[signalName]) end
        assert(ok, "Could not fire property button signal: " .. signalName)
        if step == 1 then state.FirstSent = true else state.SecondSent = true end
        H:SetStage(step == 1 and "Selecting property" or "Waiting for the plot", step == 1 and 0.13 or 0.15)
        H:Log(string.format("Property step %d - %s - attempt %d", step, signalName, state.Attempts[step]))
    end
    return service, state
end
function H:KnownSlot()
    local slot = tonumber(value(Player, "CurrentSaveSlot"))
    if finite(slot) and slot >= 1 and slot <= 6 and slot % 1 == 0 then return slot end
    return nil -- -1, 0 and missing values are not usable slot identifiers.
end
function H:LoadSlot(token)
    self:SetStage("Loading slot " .. self.Config.Slot, 0.12)
    local slot = self.Config.Slot
    self.LoadReceipt = nil
    local confirm, confirmation = self:LoadConfirmation(token)
    local deadline = os.clock() + 120
    local resuming = (self:KnownSlot() == nil or self:KnownSlot() == slot) and confirmation:Open()
    -- Resume our selected slot if a previous request is still awaiting these
    -- dialogs. Do not activate them for a different slot that is saving/loading.
    while value(Player, "CurrentlySavingOrLoading") == true do
        if self:KnownSlot() == slot or resuming then
            resuming = true
            break -- The owned-plot readiness check below also handles a stale busy indicator.
        end
        assert(os.clock() < deadline, "The previous save/load has not finished")
        token:Sleep(0.1)
    end
    local requested = false
    if not resuming and (self:KnownSlot() ~= slot or not self:Plot()) then
        local may = self:Remote("LoadSaveRequests", "ClientMayLoad", "RemoteFunction")
        repeat
            local permitted = token:Await(function() return may:InvokeServer(Player) end)
            if permitted == true then break end
            assert(os.clock() < deadline, "Slot loading cooldown exceeded") token:Sleep(2)
        until false
        requested = true
        local load = self:Remote("LoadSaveRequests", "RequestLoad", "RemoteFunction")
        local result = token:Await(function() return load:InvokeServer(slot, Player) end, 120, confirm)
        assert(result ~= false, "The game rejected the selected slot")
    end
    deadline = os.clock() + 120
    local stableSince, lastPlot, lastTiles, lastBusy
    local loadedPlot, nextDiagnostic = nil, 0
    repeat
        token:Check()
        local plot = self:Plot()
        local tiles = #self:PlotTiles(plot)
        local currentSlot = value(Player, "CurrentSaveSlot")
        local busy = value(Player, "CurrentlySavingOrLoading")
        local knownSlot = self:KnownSlot()
        local slotMatches = knownSlot == nil or knownSlot == slot
        confirmation.HavePlot = plot ~= nil and tiles > 0 and slotMatches
        confirm()
        -- The owned, usable plot is the completion signal. A stale purchase
        -- panel or a busy flag left true must not keep a loaded base waiting.
        -- A known different slot still blocks the rest of the cycle.
        local confirmed = confirmation.SecondSent or
            (not requested and not confirmation.Seen and knownSlot == slot) or
            (not confirmation:Open() and confirmation.HavePlot and not confirmation.Seen and knownSlot == slot)
        local character = Player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local ready = confirmation.HavePlot and confirmed and character and character.Parent
            and humanoid and humanoid.Health > 0 and root
        if ready then
            if plot ~= lastPlot or tiles ~= lastTiles or busy ~= lastBusy then stableSince = os.clock() end
            stableSince = stableSince or os.clock()
            if os.clock() - stableSince >= (busy == true and 3 or 1) then
                loadedPlot = plot
                if busy == true then self:Log("Owned terrain is ready; the optional busy indicator is still true", "WARNING") end
                break
            end
        else stableSince = nil end
        lastPlot, lastTiles, lastBusy = plot, tiles, busy
        if os.clock() >= nextDiagnostic then
            nextDiagnostic = os.clock() + 5
            self:SetStage("Waiting for the plot", 0.15, string.format(
                "Owner: %s - land: %d - slot: %s - confirmation: %s",
                plot and "you" or "pending", tiles, tostring(currentSlot), confirmed and "accepted" or "pending"))
        end
        assert(os.clock() < deadline, string.format(
            "Slot load not confirmed - owner: %s, land: %d, slot: %s, busy: %s",
            plot and "local player" or "missing", tiles, tostring(currentSlot), tostring(busy)))
        token:Sleep(0.15)
    until false
    self.LoadReceipt = {Slot=slot, Plot=loadedPlot, JobId=game.JobId}
    if self:KnownSlot() == nil then
        self:Log("Slot indicator unavailable - confirmed property belongs to you after the load sequence")
    end
    self:SetStage("Slot loaded", 0.18, "Owned plot confirmed")
    local character, _, root = self:Character()
    token.Character = character
    local origin = root.CFrame
    token:Finally(function()
        if self.Alive and Player.Character == character and root.Parent then pcall(self.Teleport, self, origin) end
    end)
    return loadedPlot
end
function H:FindMill(token)
    local deadline = os.clock() + 20
    repeat
        local models = S.Workspace:FindFirstChild("PlayerModels")
        for _, model in ipairs(models and models:GetChildren() or {}) do
            if model:IsA("Model") and owned(model) and (model.Name == "Sawmill4L" or value(model,"ItemName") == "Sawmill4L") then
                local inlet = model:FindFirstChild("Particles")
                if inlet and inlet:IsA("BasePart") then return model, inlet end
            end
        end
        token:Sleep(0.3)
    until os.clock() >= deadline
    error("No owned Sawmill4L with a Particles inlet in this slot", 0)
end
function H:AxeStats(tool, kind)
    local definitions = S.ReplicatedStorage:FindFirstChild("AxeClasses")
    local name = value(tool, "ToolName")
    local module = definitions and name and definitions:FindFirstChild("AxeClass_" .. tostring(name))
    if not module or not module:IsA("ModuleScript") then return end
    local ok, stats = pcall(function() return require(module).new() end)
    if not ok or type(stats) ~= "table" then return end
    stats = table.clone(stats)
    local special = stats.SpecialTrees and stats.SpecialTrees[kind]
    if type(special) == "table" then for k,v in pairs(special) do stats[k] = v end end
    if finite(stats.Damage) and stats.Damage > 0 and finite(stats.SwingCooldown) and stats.SwingCooldown > 0 then return stats end
end
function H:FindAxe(kind)
    local character = Player.Character
    for _, tool in ipairs(character and character:GetChildren() or {}) do
        if tool:IsA("Tool") then
            local stats = self:AxeStats(tool, kind)
            if stats then return tool, stats end
        end
    end
    local best, bestStats, score = nil, nil, -1
    local backpack = Player:FindFirstChildOfClass("Backpack")
    for _, tool in ipairs(backpack and backpack:GetChildren() or {}) do
        if tool:IsA("Tool") then
            local stats = self:AxeStats(tool, kind)
            if stats and stats.Damage / stats.SwingCooldown > score then
                best, bestStats, score = tool, stats, stats.Damage / stats.SwingCooldown
            end
        end
    end
    return best, bestStats
end
function H:EnsureAxe(kind, token)
    token:Check()
    local tool, stats = self:FindAxe(kind)
    assert(tool, "No compatible axe in your Backpack or character - equip an axe and retry")
    local _, humanoid = self:Character()
    self:SetStage("Equipping inventory axe", 0.23, tostring(value(tool, "ToolName") or tool.Name))
    humanoid:EquipTool(tool)
    local deadline = os.clock() + 3
    while tool.Parent ~= Player.Character do
        assert(os.clock() < deadline, "Inventory axe could not be equipped")
        token:Sleep(0.1)
    end
    return tool, stats
end
function H:Scan(token)
    local matches, counts = {}, { Spooky = 0, SpookyNeon = 0, SpookyVolume = 0, SpookyNeonVolume = 0 }
    local regions, inspected, ready = 0, 0, 0
    local snapshot, budgetStart = {}, os.clock()
    token:Check()
    for _, region in ipairs(S.Workspace:GetChildren()) do
        if region.Name == "TreeRegion" then
            regions = regions + 1
            for _, model in ipairs(region:GetChildren()) do
                local kind = value(model,"TreeClass")
                if kind then ready = ready + 1 snapshot[model] = kind end
                local ownerField = rare(kind) and model:FindFirstChild("Owner")
                if model:IsA("Model") and rare(kind) and ownerField and ownerField:IsA("ObjectValue") and ownerField.Value == nil
                    and model:FindFirstChild("CutEvent") and not model:FindFirstChild("RootCut") then
                    local trunk, volume = nil, 0
                    for _, section in ipairs(model:GetChildren()) do
                        if section:IsA("BasePart") and section.Name == "WoodSection" then
                            volume = volume + section.Size.X * section.Size.Y * section.Size.Z
                            if value(section,"ID") == 1 then trunk = section end
                        end
                    end
                    if trunk then
                        table.insert(matches, { Model = model, Trunk = trunk, Kind = kind, Volume = volume })
                        counts[kind] = counts[kind] + 1 counts[kind .. "Volume"] = counts[kind .. "Volume"] + volume
                    end
                end
                inspected = inspected + 1
                if inspected % 64 == 0 and os.clock() - budgetStart >= 0.004 then
                    token:Sleep(0.001) budgetStart = os.clock()
                end
            end
        end
    end
    table.sort(matches, function(a,b) return a.Volume > b.Volume end)
    self.Counts = counts
    if self.UI then
        self.UI.Spooky.Text = tostring(counts.Spooky)
        self.UI.Neon.Text = tostring(counts.SpookyNeon)
        self.UI.SpookyVolume.Text = string.format("%.0f studs3", counts.SpookyVolume)
        self.UI.NeonVolume.Text = string.format("%.0f studs3", counts.SpookyNeonVolume)
    end
    return matches, regions, snapshot, ready
end
function H:ScanReady(token)
    local started, stableSince = os.clock(), os.clock()
    local previous, previousRegions, previousCount, previousVolume
    self:SetStage("Scanning trees", 0.04)
    repeat
        token:Check()
        if game:IsLoaded() then
            local matches, regions, snapshot, ready = self:Scan(token)
            local volume = self.Counts.SpookyVolume + self.Counts.SpookyNeonVolume
            local changed = not previous or regions ~= previousRegions or #matches ~= previousCount or volume ~= previousVolume
            if not changed then
                for model, kind in pairs(snapshot) do if previous[model] ~= kind then changed = true break end end
                if not changed then
                    for model in pairs(previous) do if snapshot[model] == nil then changed = true break end end
                end
            end
            if changed then stableSince = os.clock() end
            previous, previousRegions, previousCount, previousVolume = snapshot, regions, #matches, volume
            -- Positive results settle briefly; an empty result needs a longer
            -- quiet window. ScanWait is a deadline, never an unconditional sleep.
            if regions > 0 and ready > 0 and os.clock() - stableSince >= (#matches > 0 and 0.6 or 2)
                and (#matches > 0 or os.clock() - started >= 4) then
                self:Log(string.format("Scan complete - %.2fs / %d trees checked", os.clock()-started, ready))
                return matches
            end
        else stableSince = os.clock() end
        assert(os.clock()-started < self.Config.ScanWait, "World scan did not stabilize - staying in this server")
        token:Sleep(0.25)
    until false
end
function H:Chop(entry, tool, stats, token)
    local tree, trunk = entry.Model, entry.Trunk
    assert(tree.Parent and trunk.Parent and value(tree,"Owner") == nil, "The selected tree is no longer available")
    local logs = S.Workspace:FindFirstChild("LogModels") assert(logs, "LogModels missing")
    local previous = {} for _, log in ipairs(logs:GetChildren()) do previous[log] = true end
    local event = tree:FindFirstChild("CutEvent")
    local proxy = self:Remote("Interaction", "RemoteProxy")
    local origin = trunk.Position
    self:Teleport(trunk.CFrame * CFrame.new(trunk.Size.X/2 + 4, -trunk.Size.Y/2 + 4, 0))
    token:Sleep(0.4)
    local deadline = os.clock() + self.Config.ChopTimeout
    repeat
        token:Check()
        local found, distance = nil, math.max(80, trunk.Size.Y)
        for _, log in ipairs(logs:GetChildren()) do
            if not previous[log] and owned(log) and value(log,"TreeClass") == entry.Kind and partOf(log) then
                local delta = (partOf(log).Position - origin).Magnitude
                if delta < distance then found, distance = log, delta end
            end
        end
        if found then return found end
        if tree.Parent and trunk.Parent and event.Parent and not tree:FindFirstChild("RootCut") then
            assert(tool.Parent == Player.Character, "The equipped axe changed")
            proxy:FireServer(event, {tool = tool, sectionId = 1, height = 0.3, faceVector = Vector3.new(1,0,0),
                hitPoints = stats.Damage, cooldown = stats.SwingCooldown, cuttingClass = "Axe"})
        end
        token:Sleep(math.clamp(stats.SwingCooldown, 0.1, 5))
    until os.clock() >= deadline
    error("Tree cut timed out - no matching owned log", 0)
end
function H:Move(model, destination, token)
    assert(model.Parent and owned(model) and partOf(model), "Owned wood is no longer available")
    local drag = self:Remote("Interaction", "ClientIsDragging")
    self:Teleport(partOf(model).CFrame + Vector3.new(0, 4, 6)) token:Sleep(0.2)
    for index = 1, 10 do
        token:Check() assert(model.Parent and owned(model), "Wood ownership changed")
        drag:FireServer(model) model:PivotTo(destination)
        for _, part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") then part.AssemblyLinearVelocity = Vector3.zero part.AssemblyAngularVelocity = Vector3.zero end
        end
        if index == 1 then self:Teleport(CFrame.new(partOf(model).Position + Vector3.new(0,4,8))) end
        token:Sleep(0.08)
    end
    token:Sleep(0.4)
    assert(model.Parent and (model:GetPivot().Position - destination.Position).Magnitude < 5, "The wood did not remain at its destination")
end
function H:BringTreeToBase(log, plot, token)
    local owner = plot and plot:FindFirstChild("Owner")
    assert(owner and owner:IsA("ObjectValue") and owner.Value == Player, "Your plot is no longer owned")
    self:SetStage("Bringing tree to your base", 0.43)
    local center = self:PlotCenter(plot)
    local bounds, size = log:GetBoundingBox()
    local relative = log:GetPivot():ToObjectSpace(bounds)
    local target = CFrame.new(center.Position.X, center.Position.Y + size.Y/2 + 0.1, center.Position.Z)
        * relative:Inverse()
    self:Move(log, target, token)
    self:Log("Felled tree delivered to your plot before Modwood")
end
function H:ModwoodParts(log)
    local sections, root, candidates = {}, nil, {}
    for _, section in ipairs(log:GetChildren()) do
        if section:IsA("BasePart") and section.Name == "WoodSection" then
            local id = value(section,"ID")
            if id then sections[id] = section end
            if id == 1 then root = section end
        end
    end
    for id, section in pairs(sections) do
        local parentID = value(section,"ParentID")
        local parent = parentID and sections[parentID]
        local childIDs = section:FindFirstChild("ChildIDs")
        -- Missing ChildIDs is not evidence of a leaf: require the explicit empty folder.
        if id ~= 1 and parent and parentID ~= 1 and childIDs and #childIDs:GetChildren() == 0 then
            table.insert(candidates, { Leaf = section, Parent = parent, Direct = parentID == 1,
                Width = section.Size.X * section.Size.Z })
        end
    end
    table.sort(candidates, function(a,b)
        if a.Direct ~= b.Direct then return a.Direct end
        return a.Width < b.Width
    end)
    assert(root and candidates[1], "Modwood - no supported leaf/ParentID topology; wood left in this server")
    return root, candidates[1].Leaf, candidates[1].Parent
end
function H:FindLava()
    local region = S.Workspace:FindFirstChild("Region_Volcano")
    assert(region, "Modwood - Region_Volcano missing")
    local anchor = Vector3.new(-1675.2002, 255.002533, 1284.19983)
    local found, distance = nil, 12
    for _, part in ipairs(region:GetDescendants()) do
        if part:IsA("BasePart") and part.Name == "Lava" then
            local delta = (part.Position - anchor).Magnitude
            if delta < distance then found, distance = part, delta end
        end
    end
    assert(found, "Modwood - the source's lava part could not be identified")
    return found
end
function H:Modwood(log, mill, inlet, token)
    assert(owned(log) and owned(mill), "Modwood requires your wood and your sawmill")
    local _, leaf, parent = self:ModwoodParts(log)
    local originalSections = {}
    for _, section in ipairs(log:GetDescendants()) do
        if section:IsA("BasePart") and section.Name == "WoodSection" then
            table.insert(originalSections, section)
        end
    end
    local lava = self:FindLava()
    local lavaState = { CFrame = lava.CFrame, Size = lava.Size }
    local restoredLava = false
    local function restoreLava()
        if not restoredLava and lava.Parent then lava.CFrame = lavaState.CFrame lava.Size = lavaState.Size end
        restoredLava = true
    end
    token:Finally(restoreLava)
    local drag = self:Remote("Interaction", "ClientIsDragging")
    local pivot = log:GetPivot()
    local leafFrame = leaf.CFrame
    self:SetStage("Modwood - igniting parent section", 0.52, "Experimental - waiting for LavaFire")
    -- Keep the avatar clear of the tiny contact area; only target the selected parent.
    self:Teleport(CFrame.new(parent.Position + Vector3.new(0, 8, 12)))
    local deadline = os.clock() + 6
    repeat
        token:Check()
        assert(parent.Parent and leaf.Parent and lava.Parent, "Modwood geometry changed before ignition")
        drag:FireServer(log)
        lava.Size = Vector3.new(0.15, 0.15, 0.15) lava.CFrame = parent.CFrame
        token:Sleep(0.1)
        if parent:FindFirstChild("LavaFire") then break end
    until os.clock() >= deadline
    local ignited = parent.Parent and parent:FindFirstChild("LavaFire") ~= nil
    restoreLava()
    assert(ignited, "Modwood - no LavaFire detected; lava restored, no server hop")
    self:SetStage("Modwood - waiting for parent separation", 0.6)
    deadline = os.clock() + self.Config.BurnTimeout
    while parent.Parent == log do
        token:Check()
        assert(leaf.Parent, "Modwood - retained branch was consumed")
        assert(os.clock() < deadline, "Modwood - parent did not separate before timeout")
        if log.Parent and owned(log) then drag:FireServer(log) log:PivotTo(pivot) end
        leaf.CFrame = leafFrame leaf.AssemblyLinearVelocity = Vector3.zero leaf.AssemblyAngularVelocity = Vector3.zero
        token:Sleep(0.08)
    end
    local playerModels = S.Workspace:FindFirstChild("PlayerModels") assert(playerModels, "PlayerModels missing")
    local before = {} for _, model in ipairs(playerModels:GetChildren()) do before[model] = true end
    local kind = value(log,"TreeClass")
    local planks, seen = {}, {}
    deadline = os.clock() + self.Config.MillTimeout
    local stableSince, outputVolume, outputParts
    self:SetStage("Modwood - feeding retained branch", 0.7, "Waiting for a new owned plank")
    repeat
        token:Check() assert(mill.Parent and owned(mill) and inlet.Parent, "The selected sawmill disappeared")
        for _, model in ipairs(playerModels:GetChildren()) do
            local section = model:FindFirstChild("WoodSection")
            if not before[model] and not seen[model] and owned(model) and value(model,"TreeClass") == kind
                and section and section:IsA("BasePart") and (section.Position - inlet.Position).Magnitude < 65 then
                seen[model] = true table.insert(planks, model) stableSince = os.clock()
            end
        end
        local leafModel=leaf.Parent and leaf:FindFirstAncestorOfClass("Model")
        local consumed=not leaf.Parent or (leafModel and seen[leafModel]==true)
        local remaining = 0
        for _, section in ipairs(originalSections) do
            local model = section.Parent and section:FindFirstAncestorOfClass("Model")
            if section.Parent and not (model and seen[model]) then remaining = remaining + 1 end
        end
        local volume, parts = 0, 0
        for _, plank in ipairs(planks) do
            assert(plank.Parent and owned(plank), "Sawmill output disappeared or changed owner")
            for _, section in ipairs(plank:GetDescendants()) do
                if section:IsA("BasePart") and section.Name == "WoodSection" then
                    parts = parts + 1 volume = volume + section.Size.X * section.Size.Y * section.Size.Z
                end
            end
        end
        if volume ~= outputVolume or parts ~= outputParts then stableSince = os.clock() end
        outputVolume, outputParts = volume, parts
        if #planks > 0 and consumed and remaining == 0 and volume > 0
            and stableSince and os.clock() - stableSince > 2 then return planks end
        if leaf.Parent and not consumed then
            local ownerModel = leaf:FindFirstAncestorOfClass("Model")
            assert(ownerModel and owned(ownerModel), "Modwood - branch ownership is no longer confirmed")
            drag:FireServer(ownerModel)
            leaf.CFrame = inlet.CFrame + Vector3.new(0.7, 0, 0)
            leaf.AssemblyLinearVelocity = Vector3.zero leaf.AssemblyAngularVelocity = Vector3.zero
        end
        -- No additional axe strikes after felling. This no-recut variation of
        -- the supplied burn/retained-branch procedure is experimental. Never
        -- accept a lone branch plank while the rest of the original tree remains.
        token:Sleep(0.06)
    until os.clock() >= deadline
    error("Modwood - whole-tree conversion or finished output not confirmed; wood left in this server", 0)
end
function H:Deliver(planks, center, token)
    for _, plank in ipairs(planks) do
        local bounds, size = plank:GetBoundingBox()
        local relative = plank:GetPivot():ToObjectSpace(bounds)
        -- Upright bounding frame; place directly on the owned land tile and stack without overlap.
        local support=center.Position.Y+self.StackHeight
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances={Player.Character,plank}
        params.RespectCanCollide=true params.IgnoreWater=true
        local hit=S.Workspace:Raycast(center.Position+Vector3.new(0,200,0),Vector3.new(0,-201,0),params)
        if hit then support=math.max(support,hit.Position.Y) end
        local target = CFrame.new(center.Position.X, support + size.Y/2 + 0.04, center.Position.Z) * relative:Inverse()
        self:Move(plank, target, token)
        self.StackHeight = self.StackHeight + size.Y + 0.05
        self.Stats.Planks = self.Stats.Planks + 1
    end
end
function H:SaveSlot(token)
    self:SetStage("Saving slot " .. self.Config.Slot, 0.94, "Waiting for confirmation before leaving")
    local knownSlot = self:KnownSlot()
    local receipt = self.LoadReceipt
    if knownSlot then
        assert(knownSlot == self.Config.Slot, "The active slot changed")
    else
        assert(receipt and receipt.Slot == self.Config.Slot and receipt.JobId == game.JobId
            and receipt.Plot == self:Plot(), "Cannot save an unknown slot without a confirmed load in this session")
    end
    local deadline = os.clock() + 90
    while value(Player,"CurrentlySavingOrLoading") == true do
        assert(os.clock() < deadline, "Game save is still busy") token:Sleep(0.3)
    end
    local remote = self:Remote("LoadSaveRequests", "RequestSave", "RemoteFunction")
    local result = token:Await(function() return remote:InvokeServer(self.Config.Slot, Player) end, 45)
    assert(result == true, "Save not explicitly confirmed - staying in this server")
    deadline = os.clock() + 60
    while value(Player,"CurrentlySavingOrLoading") == true do
        assert(os.clock() < deadline, "Save completion timed out") token:Sleep(0.3)
    end
    token:Sleep(2)
end
function H:SendWebhook(title, description, token, receipt)
    local url = self.Config.Webhook
    if url == "" then return end
    assert(webhookURL(url), "Webhook must be a Discord webhook URL without extra parameters")
    assert(type(Request) == "function", "Your executor has no HTTP request function")
    local fields = {
        {name = "Server", value = game.JobId, inline = false},
        {name = "Date (UTC)", value = os.date("!%Y-%m-%d %H:%M:%S"), inline = true},
        {name = "Hunt duration", value = duration(os.time() - self.StartedAt), inline = true},
        {name = "Slot", value = tostring(self.Config.Slot), inline = true},
    }
    if receipt then
        table.insert(fields, {name="Trees processed", value=tostring(receipt.Trees), inline=true})
        table.insert(fields, {name="Planks delivered", value=tostring(receipt.Planks), inline=true})
        table.insert(fields, {name="Processing time", value=duration(receipt.Seconds), inline=true})
        table.insert(fields, {name="Slot save", value="Confirmed", inline=true})
        if receipt.Skipped > 0 then
            table.insert(fields, {name="Unavailable trees skipped", value=tostring(receipt.Skipped), inline=true})
        end
    elseif self.Counts then
        table.insert(fields, {name="Spooky", value=string.format("%d trees / %.1f studs3",self.Counts.Spooky,self.Counts.SpookyVolume), inline=true})
        table.insert(fields, {name="SpookyNeon", value=string.format("%d trees / %.1f studs3",self.Counts.SpookyNeon,self.Counts.SpookyNeonVolume), inline=true})
    end
    local body = S.HttpService:JSONEncode({ username = "Midnight Spooky Hunter", allowed_mentions = {parse = {}},
        embeds = {{title = title, description = description, color = receipt and 8641782 or 4881663, fields = fields,
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")}} })
    local response = token:Await(function()
        local ok, result = pcall(Request, {Url=url .. "?wait=true",Method="POST",Headers={["Content-Type"]="application/json"},Body=body})
        assert(ok and type(result)=="table", "Webhook transport failed (details hidden)") return result
    end, 15)
    local status = tonumber(response.StatusCode or response.Status)
    if status == 429 then
        local ok, data = pcall(S.HttpService.JSONDecode, S.HttpService, response.Body or "")
        local delay = ok and type(data)=="table" and tonumber(data.retry_after) or 5
        token:Sleep(math.clamp(delay or 5,1,60))
        response = token:Await(function()
            local ok, result = pcall(Request, {Url=url .. "?wait=true",Method="POST",Headers={["Content-Type"]="application/json"},Body=body})
            assert(ok and type(result)=="table", "Webhook retry failed (details hidden)") return result
        end,15)
        status = tonumber(response.StatusCode or response.Status)
    end
    assert(status and status >= 200 and status < 300, "Webhook failed with HTTP " .. tostring(status))
    self:Log("Webhook delivered")
end
function H:Servers(token)
    assert(type(Request) == "function", "An HTTP request function is required for server search")
    local cursor, servers = nil, {}
    for _ = 1, 5 do
        local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100"
        if cursor then url = url .. "&cursor=" .. S.HttpService:UrlEncode(cursor) end
        local response
        for attempt = 1, 3 do
            response = token:Await(function()
                local ok, r = pcall(Request,{Url=url,Method="GET"})
                assert(ok and type(r)=="table","Server-list transport failed") return r
            end,20)
            local code = tonumber(response.StatusCode or response.Status)
            if code == 200 then break end
            assert((code==429 or (code and code>=500)) and attempt<3,"Server list HTTP "..tostring(code))
            token:Sleep(attempt*5)
        end
        local data = S.HttpService:JSONDecode(response.Body)
        assert(type(data)=="table" and type(data.data)=="table","Unexpected server-list response")
        for _, server in ipairs(data.data) do
            if type(server.id)=="string" and server.id~=game.JobId and finite(server.playing) and finite(server.maxPlayers)
                and server.playing<server.maxPlayers and (not self.Visited[server.id] or os.time()-self.Visited[server.id]>14400) then
                table.insert(servers,server.id)
            end
        end
        if #servers >= 15 or type(data.nextPageCursor)~="string" or data.nextPageCursor=="" then break end
        cursor=data.nextPageCursor token:Sleep(1)
    end
    for i=#servers,2,-1 do local j=math.random(i) servers[i],servers[j]=servers[j],servers[i] end
    return servers
end
function H:Bootstrap()
    assert(type(Queue)=="function", "queue_on_teleport unavailable - automatic continuation is not supported")
    assert(type(loadstring)=="function", "loadstring unavailable")
    assert(Read and Write, "Saved continuation requires readfile and writefile")
    local source = Env.MidnightSpookySource
    local loader
    if type(source)=="string" and #source>100 then
        loader = "local source=" .. string.format("%q",source) .. ";local env=type(getgenv)=='function' and getgenv() or _G;env.MidnightSpookySource=source;local f,e=loadstring(source);assert(f,e);f()"
    else
        local url=self.Config.ScriptURL
        assert(url:match("^https://"), "Set Script URL in Settings or start with the companion loader")
        loader = "local source=game:HttpGet(" .. string.format("%q",url) .. ");local env=type(getgenv)=='function' and getgenv() or _G;env.MidnightSpookySource=source;local f,e=loadstring(source);assert(f,e);f()"
    end
    return "repeat task.wait(0.2) until game:IsLoaded();local ok,d=pcall(function() return game:GetService('HttpService'):JSONDecode(readfile('"..FILE.."')) end);"
        .. "if not ok or not d.Resume or d.Target~=game.JobId or os.time()-(d.TicketTime or 0)>180 then return end;"
        .. "local env=type(getgenv)=='function' and getgenv() or _G;if env.MidnightSpookyBootServer==game.JobId then return end;"
        .. "env.MidnightSpookyBootServer=game.JobId;env.MidnightSpookyResume=true;" .. loader
end
function H:Hop(token)
    local bootstrap=self:Bootstrap()
    self:SetStage("Next server",0.98,"Waiting "..self.Config.HopDelay.." seconds") token:Sleep(self.Config.HopDelay)
    local servers=self:Servers(token) assert(#servers>0,"No unvisited public server found - try again later")
    for i=1,math.min(#servers,8) do
        token:Check()
        local id=servers[i] self.Visited[id]=os.time()
        local saved,err=self:Persist(true,id) assert(saved,err)
        -- Executors differ on whether a failed teleport consumes the queue.
        -- Requeue each attempt; the bootstrap permits only one launch per server.
        local queued=pcall(Queue,bootstrap) assert(queued,"Could not queue continuation")
        local attempt={Id=id} self.HopAttempt=attempt
        self:SetStage("Joining another server",1,"Attempt "..i)
        local ok=pcall(S.TeleportService.TeleportToPlaceInstance,S.TeleportService,game.PlaceId,id,Player)
        if not ok then attempt.Error="Teleport request rejected" end
        local deadline=os.clock()+35
        while not attempt.Error and os.clock()<deadline do token:Sleep(0.2) end
        self.HopAttempt=nil
        if not attempt.Error then error("Teleport outcome unknown - no second request sent",0) end
        self:Log(attempt.Error,"WARNING") token:Sleep(4)
    end
    error("No server could be joined",0)
end
function H:Run(token)
    assert(game.PlaceId==13822889,"This script targets Lumber Tycoon 2 (13822889)")
    assert(not S.Workspace.StreamingEnabled,"Streaming is enabled - a complete tree scan cannot be confirmed")
    self:Bootstrap()
    if self.Config.Webhook~="" then assert(webhookURL(self.Config.Webhook),"Invalid Discord webhook URL") end
    self.Visited[game.JobId]=os.time() self.Stats.Servers=self.Stats.Servers+1
    local saved,saveError=self:Persist(false) assert(saved,saveError)
    local entries=self:ScanReady(token)
    if #entries==0 then self:SetStage("No rare tree found",0.1) return self:Hop(token) end
    self:SetStage("Rare trees found",0.1,tostring(#entries).." trees")
    self:SendWebhook("Rare trees found",self.Config.FullCycle and "Spooky wood detected." or "Spooky wood detected - search paused.",token)
    if not self.Config.FullCycle then return "Found - search paused in this server" end
    local batchStarted, initialPlanks = os.clock(), self.Stats.Planks
    local plot=self:LoadSlot(token)
    local mill,inlet=self:FindMill(token)
    self:FindLava() -- Fail before chopping if the reconstructed procedure cannot even start.
    local center=self:PlotCenter(plot) self.StackHeight=0
    local processed=0
    for index,entry in ipairs(entries) do
        token:Check()
        if entry.Model.Parent and value(entry.Model,"Owner")==nil and not entry.Model:FindFirstChild("RootCut") then
            self:ModwoodParts(entry.Model) -- Reject unsupported geometry before cutting the tree.
            local tool,stats=self:EnsureAxe(entry.Kind,token)
            self:SetStage("Cutting "..entry.Kind,0.3,string.format("Tree %d / %d",index,#entries))
            local log=self:Chop(entry,tool,stats,token)
            self.Stats.Trees=self.Stats.Trees+1
            self:BringTreeToBase(log,plot,token)
            local planks=self:Modwood(log,mill,inlet,token)
            self:SetStage("Delivering planks",0.86,"Center of your plot")
            self:Deliver(planks,center,token)
            self:SaveSlot(token)
            processed=processed+1
        else self:Log("Tree no longer available - skipped","WARNING") end
    end
    if processed>0 then
        self:SendWebhook(processed == #entries and "Harvest complete" or "Harvest complete - some trees unavailable",
            "Wood collected, Modwood completed, planks delivered to your plot and slot save confirmed.",token,
            {Trees=processed, Planks=self.Stats.Planks-initialPlanks, Seconds=os.clock()-batchStarted, Skipped=#entries-processed})
    else
        self:SendWebhook("Trees no longer available","No harvest was performed. Moving to the next server.",token)
    end
    token:Clean() token.Character=nil
    return self:Hop(token)
end
function H:Start()
    if self.Busy or not self.Alive then return end
    self.Running=true self.Busy=true
    local token=self:Token() self.ActiveToken=token
    if self.UI then self.UI.Start.Text="Hunting..." end
    self.Worker=task.defer(function()
        local ok,result=pcall(self.Run,self,token)
        token:Clean()
        self.Running=false self.Busy=false self.ActiveToken=nil
        self:Persist(false)
        if not self.Alive then return end
        if self.UI then self.UI.Start.Text="Start hunt" end
        if result==CANCEL then self:SetStage("Stopped",self.Progress,"No further task will be started")
        elseif not ok then self:SetStage("Paused - action required",self.Progress,tostring(result)) self:Log(tostring(result),"ERROR")
        else self:SetStage(tostring(result or "Done"),1) end
    end)
end
function H:Stop()
    self.Running=false self.Generation=self.Generation+1
    self:Persist(false)
    if self.ActiveToken then self.ActiveToken:Clean() end
    if self.Alive then self:SetStage("Stopping",self.Progress,self.HopAttempt and "A teleport already sent cannot be recalled" or "Cleaning up the current task") end
end
function H:Destroy()
    if not self.Alive then return end
    self:Stop() self.Alive=false
    if self.Worker then pcall(task.cancel,self.Worker) end
    for _,c in ipairs(self.Connections) do c:Disconnect() end
    if self.ProgressTween then self.ProgressTween:Cancel() end
    if self.StageTween then self.StageTween:Cancel() end
    for _,animation in pairs(self.Motion or {}) do animation:Cancel() end
    if self.Gui then self.Gui:Destroy() end
    if Env.MidnightSpookyHunter==self then Env.MidnightSpookyHunter=nil end
end

-- Midnight UI: one quiet dashboard, with separate activity and settings pages.
local P = {Background=Color3.fromRGB(10,14,26),Panel=Color3.fromRGB(16,22,37),Raised=Color3.fromRGB(23,31,49),
    Accent=Color3.fromRGB(74,124,255),Purple=Color3.fromRGB(139,92,246),Text=Color3.fromRGB(235,239,247),Muted=Color3.fromRGB(137,148,171)}
local function new(class,name,props,parent)
    local o=Instance.new(class) o.Name=name
    for k,v in pairs(props or {}) do o[k]=v end
    o.Parent=parent return o
end
local function round(o,r) new("UICorner","Corner",{CornerRadius=UDim.new(0,r or 8)},o) end
local motion = setmetatable({}, {__mode="k"})
local function tween(object, goals, seconds)
    if motion[object] then motion[object]:Cancel() end
    local animation=S.TweenService:Create(object,TweenInfo.new(seconds or 0.22,Enum.EasingStyle.Quart,Enum.EasingDirection.Out),goals)
    motion[object]=animation animation:Play()
end
H.Motion = motion
local function label(parent,name,text,pos,size,fontSize,color)
    return new("TextLabel",name,{Position=pos,Size=size,Text=text,TextSize=fontSize or 12,Font=Enum.Font.Gotham,
        TextColor3=color or P.Text,BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,
        TextTruncate=Enum.TextTruncate.AtEnd},parent)
end
local function button(parent,name,text,pos,size,callback,primary)
    -- Scale around the center, including icon/text, without shifting to a corner.
    local base=primary and P.Accent or P.Raised
    local centered=UDim2.new(pos.X.Scale+size.X.Scale/2,pos.X.Offset+size.X.Offset/2,
        pos.Y.Scale+size.Y.Scale/2,pos.Y.Offset+size.Y.Offset/2)
    local b=new("TextButton",name,{AnchorPoint=Vector2.new(0.5,0.5),Position=centered,Size=size,Text=text,
        TextSize=12,Font=Enum.Font.GothamMedium,TextColor3=P.Text,BackgroundColor3=base,
        AutoButtonColor=false,BorderSizePixel=0,TextTruncate=Enum.TextTruncate.AtEnd},parent)
    round(b,8)
    local press=new("UIScale","PressScale",{Scale=1},b)
    H:Connect(b.Activated,callback)
    H:Connect(b.MouseEnter,function() tween(b,{BackgroundColor3=base:Lerp(P.Text,0.07)}) end)
    H:Connect(b.MouseLeave,function() tween(b,{BackgroundColor3=base}) tween(press,{Scale=1}) end)
    H:Connect(b.InputBegan,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            tween(press,{Scale=0.97},0.15)
        end
    end)
    H:Connect(b.InputEnded,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            tween(press,{Scale=1},0.25)
        end
    end)
    return b
end
local gui=new("ScreenGui","MidnightSpookyHunter",{ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset=true,DisplayOrder=125}) H.Gui=gui
local parents={}
local getUI=cap("gethui",gethui)
if getUI then local ok,target=pcall(getUI) if ok and typeof(target)=="Instance" then table.insert(parents,target) end end
local okCore,core=pcall(game.GetService,game,"CoreGui") if okCore then table.insert(parents,core) end
local playerGui=Player:FindFirstChildOfClass("PlayerGui") or Player:WaitForChild("PlayerGui",5)
if playerGui then table.insert(parents,playerGui) end
for _,parent in ipairs(parents) do local ok=pcall(function() gui.Parent=parent end) if ok and gui.Parent then break end end
assert(gui.Parent,"No available UI container")
local root=new("Frame","HunterWindow",{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),
    Size=UDim2.fromOffset(480,314),BackgroundTransparency=1,BorderSizePixel=0},gui)
local scale=new("UIScale","ViewportScale",{Scale=1},root)
for i=3,1,-1 do
    local halo=new("Frame","WindowHalo"..i,{Position=UDim2.fromOffset(-i*3,-i*3),Size=UDim2.new(1,i*6,1,i*6),
        BorderSizePixel=0,BackgroundTransparency=1},root) round(halo,12+i*3)
    new("UIStroke","HaloStroke",{Color=P.Accent,Thickness=3,Transparency=0.9+i*0.025},halo)
end
local shell=new("Frame","WindowSurface",{Size=UDim2.fromScale(1,1),BackgroundColor3=P.Background,BorderSizePixel=0},root) round(shell,12)
new("UIStroke","WindowBorder",{Color=Color3.fromRGB(45,58,86),Transparency=0.48,Thickness=1},shell)
local header=new("Frame","TitleBar",{Size=UDim2.new(1,0,0,58),BackgroundTransparency=1,BorderSizePixel=0},shell)
local title=label(header,"WindowTitle","Spooky Hunter",UDim2.fromOffset(56,11),UDim2.new(1,-158,0,21),15)
title.Font=Enum.Font.GothamBold
label(header,"WindowSubtitle","MIDNIGHT 1.1.3",UDim2.fromOffset(56,34),UDim2.new(1,-158,0,12),9,P.Muted)
local divider=new("Frame","HeaderDivider",{Position=UDim2.fromOffset(20,58),Size=UDim2.new(1,-40,0,1),
    BorderSizePixel=0,BackgroundColor3=P.Accent,BackgroundTransparency=0.72},shell)
new("UIGradient","DividerTint",{Color=ColorSequence.new(P.Accent,P.Purple)},divider)
local content=new("Frame","HuntPage",{Position=UDim2.fromOffset(20,76),Size=UDim2.new(1,-40,1,-94),BackgroundTransparency=1},shell)
local stage=label(content,"Stage","Ready to hunt",UDim2.fromOffset(0,0),UDim2.new(1,0,0,24),19) stage.Font=Enum.Font.GothamBold
local detail=label(content,"StageDetail","Spooky and SpookyNeon",UDim2.fromOffset(0,28),UDim2.new(1,0,0,29),11,P.Muted)
detail.TextWrapped=true detail.TextTruncate=Enum.TextTruncate.None detail.TextYAlignment=Enum.TextYAlignment.Top
local rail=new("Frame","ProgressRail",{Position=UDim2.fromOffset(0,65),Size=UDim2.new(1,0,0,3),BackgroundColor3=P.Raised,BorderSizePixel=0},content) round(rail,3)
local fill=new("Frame","ProgressFill",{Size=UDim2.fromScale(0,1),BackgroundColor3=P.Accent,BorderSizePixel=0},rail) round(fill,3)
new("UIGradient","ProgressGradient",{Color=ColorSequence.new(P.Accent,P.Purple)},fill)
local function treeCard(name,text,position,color)
    local card=new("Frame",name.."Card",{Position=position,Size=UDim2.new(0.5,-5,0,62),
        BackgroundColor3=P.Panel,BorderSizePixel=0},content) round(card,9)
    label(card,name.."Title",text,UDim2.fromOffset(12,8),UDim2.new(1,-65,0,16),11,P.Muted)
    local count=label(card,name.."Count","0",UDim2.new(1,-57,0,10),UDim2.fromOffset(44,35),26,color)
    count.Font=Enum.Font.GothamMedium count.TextXAlignment=Enum.TextXAlignment.Right
    local volume=label(card,name.."Volume","0 studs3",UDim2.fromOffset(12,32),UDim2.new(1,-70,0,17),10,P.Muted)
    return count,volume
end
local spooky,spookyVolume=treeCard("Spooky","Spooky",UDim2.fromOffset(0,81),P.Accent)
local neon,neonVolume=treeCard("Neon","SpookyNeon",UDim2.new(0.5,5,0,81),P.Purple)
local stats=label(content,"SessionStats","",UDim2.fromOffset(0,150),UDim2.new(1,0,0,18),10,P.Muted)
local startButton=button(content,"StartHunt","Start hunt",UDim2.new(0,0,1,-36),UDim2.new(0.68,-5,0,36),function() H:Start() end,true)
button(content,"StopHunt","Stop",UDim2.new(0.68,5,1,-36),UDim2.new(0.32,-5,0,36),function() H:Stop() end)
local activityPage=new("Frame","ActivityPage",{Position=content.Position,Size=content.Size,Visible=false,BackgroundTransparency=1},shell)
label(activityPage,"ActivityTitle","Activity",UDim2.fromOffset(0,0),UDim2.new(1,-90,0,25),16).Font=Enum.Font.GothamBold
local scroll=new("ScrollingFrame","ActivityViewport",{Position=UDim2.fromOffset(0,38),Size=UDim2.new(1,0,1,-38),
    BackgroundColor3=P.Panel,BorderSizePixel=0,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=2,ScrollBarImageColor3=Color3.fromRGB(112,117,128),ScrollBarImageTransparency=0.45},activityPage) round(scroll,8)
local activity=label(scroll,"ActivityLog","",UDim2.fromOffset(11,9),UDim2.new(1,-26,0,0),11,P.Muted)
activity.Font=Enum.Font.Code activity.AutomaticSize=Enum.AutomaticSize.Y activity.TextWrapped=true activity.TextTruncate=Enum.TextTruncate.None
activity.TextYAlignment=Enum.TextYAlignment.Top
button(activityPage,"CopyActivity","Copy",UDim2.new(1,-64,0,0),UDim2.fromOffset(64,27),function()
    local text="Spooky Hunter 1.1.3\n"..table.concat(H.Logs,"\n")
    local copy=cap("setclipboard",setclipboard) or cap("toclipboard",toclipboard)
    if copy and pcall(copy,text) then H:Log("Activity copied") else
        local previous=activityPage:FindFirstChild("ManualLogCopy") if previous then previous:Destroy() end
        local output=new("TextBox","ManualLogCopy",{Position=scroll.Position,Size=scroll.Size,Text=text,
            BackgroundColor3=P.Panel,TextColor3=P.Text,TextSize=11,Font=Enum.Font.Code,TextWrapped=true,
            ClearTextOnFocus=false,TextEditable=false,MultiLine=true,TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Top},activityPage) round(output,8)
        output:CaptureFocus() output.SelectionStart=1 output.CursorPosition=#text+1
        H:Connect(output.FocusLost,function() output:Destroy() end)
    end
end)
H.UI={Stage=stage,Detail=detail,Fill=fill,Spooky=spooky,Neon=neon,SpookyVolume=spookyVolume,
    NeonVolume=neonVolume,Activity=activity,Start=startButton}
local settings=new("ScrollingFrame","SettingsPage",{Position=content.Position,Size=content.Size,Visible=false,
    BackgroundTransparency=1,BorderSizePixel=0,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=2,ScrollBarImageColor3=Color3.fromRGB(112,117,128)},shell)
new("UIListLayout","SettingsLayout",{Padding=UDim.new(0,8),SortOrder=Enum.SortOrder.LayoutOrder},settings)
local order=0
local advancedRows={}
local function settingsRow(name,height,advanced)
    order=order+1
    local row=new("Frame",name,{Size=UDim2.new(1,-5,0,height or 62),LayoutOrder=order,
        Visible=not advanced,BackgroundColor3=P.Panel,BorderSizePixel=0},settings) round(row,8)
    if advanced then table.insert(advancedRows,row) end
    return row
end
local function field(titleText,key,numeric,secret,advanced)
    local row=settingsRow(key.."Row",62,advanced)
    label(row,key.."Label",titleText,UDim2.fromOffset(10,4),UDim2.new(1,-20,0,17),10,P.Muted)
    local function display() return secret and H.Config[key]~="" and "Configured - click to edit" or tostring(H.Config[key]) end
    local box=new("TextBox",key.."Input",{Position=UDim2.fromOffset(10,24),Size=UDim2.new(1,-20,0,29),BackgroundColor3=P.Raised,
        TextColor3=P.Text,Text=display(),PlaceholderText=key=="ScriptURL" and "https://raw.githubusercontent.com/.../SpookyHunter.client.lua" or "",
        PlaceholderColor3=P.Muted,TextSize=11,Font=Enum.Font.Gotham,ClearTextOnFocus=false,TextTruncate=Enum.TextTruncate.AtEnd,
        TextXAlignment=Enum.TextXAlignment.Left,BorderSizePixel=0},row) round(box,5)
    new("UIPadding","InputPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},box)
    H:Connect(box.Focused,function() if secret then box.Text=H.Config[key] end end)
    H:Connect(box.FocusLost,function()
        if H.Busy then box.Text=display() H:Log("Stop the hunt before editing settings","WARNING") return end
        local candidate=numeric and tonumber(box.Text) or box.Text
        if numeric and not finite(candidate) then box.Text=display() return end
        local config=table.clone(H.Config) config[key]=candidate config=configFrom(config)
        if key=="Webhook" and config.Webhook~="" and not webhookURL(config.Webhook) then
            box.Text=display() H:Log("Invalid Discord webhook URL","WARNING") return
        end
        H.Config=config box.Text=display()
        local ok,err=H:Persist(false) if not ok then H:Log(err,"WARNING") end
    end)
end
field("Save slot (1-6)","Slot",true)
field("Discord webhook","Webhook",false,true)
local mode=settingsRow("ProcessingMode",46)
local modeButton
modeButton=button(mode,"ModeToggle",H.Config.FullCycle and "Full cycle - experimental Modwood" or "Search only",
    UDim2.fromOffset(8,7),UDim2.new(1,-16,0,32),function()
        if H.Busy then return end
        H.Config.FullCycle=not H.Config.FullCycle
        modeButton.Text=H.Config.FullCycle and "Full cycle - experimental Modwood" or "Search only"
        H:Persist(false)
    end)
local advanced=settingsRow("AdvancedSettings",36)
local advancedButton
local expanded=false
advancedButton=button(advanced,"ExpandAdvanced","Advanced settings +",UDim2.fromOffset(0,0),UDim2.fromScale(1,1),function()
    expanded=not expanded
    advancedButton.Text=expanded and "Advanced settings -" or "Advanced settings +"
    for _,row in ipairs(advancedRows) do row.Visible=expanded end
end)
field("Script URL - only without the loader","ScriptURL",false,false,true)
field("Server hop delay (seconds)","HopDelay",true,false,true)
field("World scan timeout (seconds)","ScanWait",true,false,true)
field("Chop timeout (seconds)","ChopTimeout",true,false,true)
field("Burn timeout (seconds)","BurnTimeout",true,false,true)
field("Sawmill timeout (seconds)","MillTimeout",true,false,true)
local function showPage(page)
    content.Visible=page==content settings.Visible=page==settings activityPage.Visible=page==activityPage
    tween(root,{Size=UDim2.fromOffset(480,page==content and 314 or 408)},0.3)
    page.Position=UDim2.fromOffset(20,82)
    tween(page,{Position=UDim2.fromOffset(20,76)},0.25)
end
button(header,"SettingsGear","⚙",UDim2.fromOffset(16,15),UDim2.fromOffset(29,29),function()
    showPage(settings.Visible and content or settings)
end)
button(header,"OpenActivity","Log",UDim2.new(1,-91,0,15),UDim2.fromOffset(42,29),function()
    showPage(activityPage.Visible and content or activityPage)
end)
button(header,"CloseWindow","X",UDim2.new(1,-41,0,15),UDim2.fromOffset(25,29),function() H:Destroy() end)
local dragZone=new("Frame","TitleDragZone",{Position=UDim2.fromOffset(50,0),Size=UDim2.new(1,-150,0,58),BackgroundTransparency=1,Active=true},header)
local dragInput,dragStart,dragOrigin
H:Connect(dragZone.InputBegan,function(input)
    if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
        dragInput=input dragStart=input.Position dragOrigin=root.Position
    end
end)
H:Connect(S.UserInputService.InputChanged,function(input)
    if dragInput and (input==dragInput or input.UserInputType==Enum.UserInputType.MouseMovement) then
        local d=input.Position-dragStart root.Position=UDim2.new(dragOrigin.X.Scale,dragOrigin.X.Offset+d.X,dragOrigin.Y.Scale,dragOrigin.Y.Offset+d.Y)
    end
end)
H:Connect(S.UserInputService.InputEnded,function(input) if input==dragInput then dragInput=nil end end)
H:Connect(S.UserInputService.InputBegan,function(input,processed)
    if not processed and not S.UserInputService:GetFocusedTextBox() and input.KeyCode==Enum.KeyCode.RightShift then gui.Enabled=not gui.Enabled end
end)
H:Connect(S.TeleportService.TeleportInitFailed,function(player,_,message,placeId,options)
    if player~=Player or placeId~=game.PlaceId or not H.HopAttempt then return end
    local id=options and options.ServerInstanceId
    if id and id~="" and id~=H.HopAttempt.Id then return end
    H.HopAttempt.Error="Teleport failed - "..tostring(message):sub(1,160)
end)
local tick=0
H:Connect(S.RunService.RenderStepped,function(dt)
    tick=tick+dt if tick<0.25 then return end tick=0
    local viewport=gui.AbsoluteSize
    scale.Scale=math.min(1,math.max(0.35,(viewport.X-24)/480),math.max(0.35,(viewport.Y-24)/root.Size.Y.Offset))
    stats.Text=string.format("%s  -  %d servers  -  %d trees  -  %d planks",duration(os.time()-H.StartedAt),H.Stats.Servers,H.Stats.Trees,H.Stats.Planks)
end)
H:Connect(activity:GetPropertyChangedSignal("AbsoluteSize"),function()
    scroll.CanvasPosition=Vector2.new(0,math.max(0,(activity.AbsoluteSize.Y-scroll.AbsoluteSize.Y+10)/math.max(scale.Scale,0.01)))
end)
if H.ConfigWarning then H:Log(H.ConfigWarning,"WARNING") end
H:Log("Ready - settings are saved locally. Right Shift toggles the interface.")
local resume=Env.MidnightSpookyResume==true and restored and restored.Resume==true and restored.Target==game.JobId
    and finite(restored.TicketTime) and os.time()-restored.TicketTime<180
Env.MidnightSpookyResume=nil
if resume then H:Start() end
return H
