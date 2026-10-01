--[[
    Midnight Spooky Hunter 1.0.0 - Lumber Tycoon 2
    October 1, 2026. Standalone client script; no UI-library download required.
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
        if self.ProgressTween then self.ProgressTween:Cancel() end
        self.ProgressTween = S.TweenService:Create(self.UI.Fill, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
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
    function token:Await(fn, timeout)
        local result
        local thread = task.spawn(function() result = table.pack(pcall(fn)) end)
        local deadline = os.clock() + (timeout or 20)
        local function cancel() if not result then pcall(task.cancel, thread) end end
        self:Finally(cancel)
        while not result and os.clock() < deadline do self:Sleep(0.08) end
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
function H:Plot()
    local properties = S.Workspace:FindFirstChild("Properties")
    for _, plot in ipairs(properties and properties:GetChildren() or {}) do
        if owned(plot) then return plot end
    end
end
function H:PlotCenter(plot)
    local minX, maxX, minZ, maxZ, y = math.huge, -math.huge, math.huge, -math.huge, -math.huge
    for _, tile in ipairs(plot:GetChildren()) do
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
    for _, tile in ipairs(plot:GetChildren()) do
        if tile:IsA("BasePart") and (tile.Name == "Square" or tile.Name == "OriginSquare") then
            local point = Vector3.new(math.clamp(desired.X, tile.Position.X - tile.Size.X/2 + 2, tile.Position.X + tile.Size.X/2 - 2),
                tile.Position.Y + tile.Size.Y/2, math.clamp(desired.Z, tile.Position.Z - tile.Size.Z/2 + 2, tile.Position.Z + tile.Size.Z/2 - 2))
            local delta = (point - desired).Magnitude
            if not distance or delta < distance then nearest, distance = point, delta end
        end
    end
    return CFrame.new(nearest)
end
function H:LoadSlot(token)
    self:SetStage("Loading slot " .. self.Config.Slot, 0.12)
    local slot = self.Config.Slot
    local deadline = os.clock() + 90
    while value(Player, "CurrentlySavingOrLoading") == true do
        assert(os.clock() < deadline, "The game is still saving or loading") token:Sleep(0.25)
    end
    if value(Player, "CurrentSaveSlot") ~= slot then
        local may = self:Remote("LoadSaveRequests", "ClientMayLoad", "RemoteFunction")
        repeat
            local permitted = token:Await(function() return may:InvokeServer(Player) end)
            if permitted == true then break end
            assert(os.clock() < deadline, "Slot loading cooldown exceeded") token:Sleep(3)
        until false
        local load = self:Remote("LoadSaveRequests", "RequestLoad", "RemoteFunction")
        local result = token:Await(function() return load:InvokeServer(slot, Player) end, 40)
        assert(result ~= false, "The game rejected the selected slot")
    end
    deadline = os.clock() + 90
    repeat
        token:Check()
        if value(Player, "CurrentSaveSlot") == slot and value(Player, "CurrentlySavingOrLoading") == false and self:Plot() then break end
        assert(os.clock() < deadline, "The loaded slot and plot were not confirmed") token:Sleep(0.3)
    until false
    local character, _, root = self:Character()
    token.Character = character
    local origin = root.CFrame
    token:Finally(function()
        if self.Alive and Player.Character == character and root.Parent then pcall(self.Teleport, self, origin) end
    end)
    return self:Plot()
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
    local best, bestStats, score = nil, nil, -1
    for _, container in ipairs({Player.Character, Player:FindFirstChildOfClass("Backpack")}) do
        for _, tool in ipairs(container and container:GetChildren() or {}) do
            if tool:IsA("Tool") then
                local stats = self:AxeStats(tool, kind)
                if stats and stats.Damage / stats.SwingCooldown > score then best, bestStats, score = tool, stats, stats.Damage / stats.SwingCooldown end
            end
        end
    end
    return best, bestStats
end
function H:EnsureAxe(kind, plot, token)
    local tool, stats = self:FindAxe(kind)
    if not tool then
        self:SetStage("Collecting an axe from your base", 0.2)
        local models = S.Workspace:FindFirstChild("PlayerModels")
        local candidates = {}
        for _, item in ipairs(models and models:GetChildren() or {}) do
            local main = partOf(item)
            if owned(item) and main and value(item,"ToolName") and self:AxeStats(item, kind) then
                for _, tile in ipairs(plot:GetChildren()) do
                    if tile:IsA("BasePart") and (tile.Name == "Square" or tile.Name == "OriginSquare") then
                        local relative = tile.CFrame:PointToObjectSpace(main.Position)
                        if math.abs(relative.X) <= tile.Size.X/2 and math.abs(relative.Z) <= tile.Size.Z/2
                            and math.abs(relative.Y) < 60 then table.insert(candidates,item) break end
                    end
                end
            end
        end
        assert(#candidates > 0, "No usable axe in inventory or on your loaded plot")
        local pickup = self:Remote("Interaction", "ClientInteracted")
        for _, item in ipairs(candidates) do
            self:Teleport(partOf(item).CFrame + Vector3.new(0, 3, 3))
            pickup:FireServer(item, "Pick up tool")
            local deadline = os.clock() + 5
            repeat
                token:Sleep(0.2) tool, stats = self:FindAxe(kind)
            until tool or os.clock() >= deadline
            if tool then break end
        end
    end
    assert(tool, "Axe pickup was not confirmed")
    local _, humanoid = self:Character() humanoid:EquipTool(tool)
    return tool, stats
end
function H:Scan(token)
    local matches, counts = {}, { Spooky = 0, SpookyNeon = 0, SpookyVolume = 0, SpookyNeonVolume = 0 }
    local regions, inspected = 0, 0
    for _, region in ipairs(S.Workspace:GetChildren()) do
        if region.Name == "TreeRegion" then
            regions = regions + 1
            for _, model in ipairs(region:GetChildren()) do
                local kind, ownerField = value(model,"TreeClass"), model:FindFirstChild("Owner")
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
                inspected = inspected + 1 if inspected % 80 == 0 then token:Sleep(0.01) end
            end
        end
    end
    table.sort(matches, function(a,b) return a.Volume > b.Volume end)
    self.Counts = counts
    if self.UI then self.UI.Found.Text = string.format("Spooky  %d / %.0f studs3     Neon  %d / %.0f studs3",
        counts.Spooky, counts.SpookyVolume, counts.SpookyNeon, counts.SpookyNeonVolume) end
    return matches, regions
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
function H:Modwood(log, mill, inlet, tool, stats, token)
    assert(owned(log) and owned(mill), "Modwood requires your wood and your sawmill")
    local root, leaf, parent = self:ModwoodParts(log)
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
    local cut = log:FindFirstChild("CutEvent")
    local proxy = self:Remote("Interaction", "RemoteProxy")
    local nextSwing = 0
    local planks, seen = {}, {}
    deadline = os.clock() + self.Config.MillTimeout
    local stableSince
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
        if #planks > 0 and consumed and stableSince and os.clock() - stableSince > 1.5 then return planks end
        if leaf.Parent and not consumed then
            local ownerModel = leaf:FindFirstAncestorOfClass("Model")
            assert(ownerModel and owned(ownerModel), "Modwood - branch ownership is no longer confirmed")
            drag:FireServer(ownerModel)
            leaf.CFrame = inlet.CFrame + Vector3.new(0.7, 0, 0)
            leaf.AssemblyLinearVelocity = Vector3.zero leaf.AssemblyAngularVelocity = Vector3.zero
        end
        if log.Parent and root.Parent == log and cut and cut.Parent and os.clock() >= nextSwing then
            self:Teleport(root.CFrame * CFrame.new(root.Size.X/2 + 4, -root.Size.Y/2 + 3, 0))
            proxy:FireServer(cut, {tool = tool, sectionId = 1, height = 0.3, faceVector = Vector3.new(1,0,0),
                hitPoints = stats.Damage, cooldown = stats.SwingCooldown, cuttingClass = "Axe"})
            nextSwing = os.clock() + math.clamp(stats.SwingCooldown, 0.1, 5)
        end
        token:Sleep(0.06)
    until os.clock() >= deadline
    error("Modwood - no confirmed plank output; cycle stopped, no server hop", 0)
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
    assert(value(Player,"CurrentSaveSlot") == self.Config.Slot, "The active slot changed")
    local deadline = os.clock() + 90
    while value(Player,"CurrentlySavingOrLoading") == true do
        assert(os.clock() < deadline, "Game save is still busy") token:Sleep(0.3)
    end
    local remote = self:Remote("LoadSaveRequests", "RequestSave", "RemoteFunction")
    local result = token:Await(function() return remote:InvokeServer(self.Config.Slot, Player) end, 45)
    assert(result == true, "Save not explicitly confirmed - staying in this server")
    deadline = os.clock() + 60
    while value(Player,"CurrentlySavingOrLoading") ~= false do
        assert(os.clock() < deadline, "Save completion timed out") token:Sleep(0.3)
    end
    token:Sleep(2)
end
function H:SendWebhook(title, description, token)
    local url = self.Config.Webhook
    if url == "" then return end
    assert(webhookURL(url), "Webhook must be a Discord webhook URL without extra parameters")
    assert(type(Request) == "function", "Your executor has no HTTP request function")
    local fields = {
        {name = "Server", value = game.JobId, inline = false},
        {name = "Detected at (UTC)", value = os.date("!%Y-%m-%d %H:%M:%S"), inline = true},
        {name = "Hunt duration", value = duration(os.time() - self.StartedAt), inline = true},
        {name = "Server age / creation", value = "Unavailable - not exposed by the game", inline = false},
        {name = "Slot", value = tostring(self.Config.Slot), inline = true},
    }
    if self.Counts then
        table.insert(fields, {name="Spooky", value=string.format("%d trees / %.1f studs3",self.Counts.Spooky,self.Counts.SpookyVolume), inline=true})
        table.insert(fields, {name="SpookyNeon", value=string.format("%d trees / %.1f studs3",self.Counts.SpookyNeon,self.Counts.SpookyNeonVolume), inline=true})
    end
    local body = S.HttpService:JSONEncode({ username = "Midnight Spooky Hunter", allowed_mentions = {parse = {}},
        embeds = {{title = title, description = description, color = 4881663, fields = fields,
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
    self:SetStage("Waiting for the world",0.03)
    token:Sleep(self.Config.ScanWait)
    local entries,regions=self:Scan(token)
    assert(regions>0,"No TreeRegion loaded - not hopping from an incomplete world")
    -- Two scans separated in time avoid acting on the first replication frame.
    token:Sleep(3) entries,regions=self:Scan(token)
    if #entries==0 then self:SetStage("No rare tree found",0.1) return self:Hop(token) end
    local plan=self.Config.FullCycle and "Load slot, collect axe, cut each tree, attempt Modwood, deliver planks, save, then hop."
        or "Search-only mode: stay in this server."
    self:SetStage("Rare trees found",0.1,tostring(#entries).." trees")
    self:SendWebhook("Rare trees found",plan,token)
    if not self.Config.FullCycle then return "Found - search paused in this server" end
    local plot=self:LoadSlot(token)
    local mill,inlet=self:FindMill(token)
    self:FindLava() -- Fail before chopping if the reconstructed procedure cannot even start.
    local center=self:PlotCenter(plot) self.StackHeight=0
    local processed=0
    for index,entry in ipairs(entries) do
        token:Check()
        if entry.Model.Parent and value(entry.Model,"Owner")==nil and not entry.Model:FindFirstChild("RootCut") then
            self:ModwoodParts(entry.Model) -- Reject unsupported geometry before cutting the tree.
            local tool,stats=self:EnsureAxe(entry.Kind,plot,token)
            self:SetStage("Cutting "..entry.Kind,0.3,string.format("Tree %d / %d",index,#entries))
            local log=self:Chop(entry,tool,stats,token)
            self.Stats.Trees=self.Stats.Trees+1
            local planks=self:Modwood(log,mill,inlet,tool,stats,token)
            self:SetStage("Delivering planks",0.86,"Center of your plot")
            self:Deliver(planks,center,token)
            self:SaveSlot(token)
            processed=processed+1
        else self:Log("Tree no longer available - skipped","WARNING") end
    end
    if processed>0 then
        self:SendWebhook("Batch saved","Planks delivered and slot save confirmed. Moving to the next server.",token)
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
    if self.UI then self.UI.Start.Text="Running" end
    self.Worker=task.defer(function()
        local ok,result=pcall(self.Run,self,token)
        token:Clean()
        self.Running=false self.Busy=false self.ActiveToken=nil
        self:Persist(false)
        if not self.Alive then return end
        if self.UI then self.UI.Start.Text="Start" end
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
    if self.Gui then self.Gui:Destroy() end
    if Env.MidnightSpookyHunter==self then Env.MidnightSpookyHunter=nil end
end

-- Compact Midnight-style UI, made entirely with native instances.
local P = {Background=Color3.fromRGB(10,14,26),Panel=Color3.fromRGB(17,24,39),Raised=Color3.fromRGB(25,33,51),
    Accent=Color3.fromRGB(74,124,255),Purple=Color3.fromRGB(139,92,246),Text=Color3.fromRGB(229,233,240),Muted=Color3.fromRGB(138,147,166)}
local function new(class,name,props,parent)
    local o=Instance.new(class) o.Name=name
    for k,v in pairs(props or {}) do o[k]=v end
    o.Parent=parent return o
end
local function round(o,r) new("UICorner","Corner",{CornerRadius=UDim.new(0,r or 8)},o) end
local function label(parent,name,text,pos,size,fontSize,color)
    return new("TextLabel",name,{Position=pos,Size=size,Text=text,TextSize=fontSize or 12,Font=Enum.Font.Gotham,
        TextColor3=color or P.Text,BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,
        TextTruncate=Enum.TextTruncate.AtEnd},parent)
end
local function button(parent,name,text,pos,size,callback,primary)
    local b=new("TextButton",name,{Position=pos,Size=size,Text=text,TextSize=12,Font=Enum.Font.GothamMedium,
        TextColor3=P.Text,BackgroundColor3=primary and P.Accent or P.Raised,AutoButtonColor=false,BorderSizePixel=0},parent)
    round(b,7)
    H:Connect(b.Activated,callback)
    H:Connect(b.MouseEnter,function() b.BackgroundTransparency=0.15 end)
    H:Connect(b.MouseLeave,function() b.BackgroundTransparency=0 end)
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
    Size=UDim2.fromOffset(520,330),BackgroundTransparency=1,BorderSizePixel=0},gui)
local scale=new("UIScale","ViewportScale",{Scale=1},root)
for i=3,1,-1 do
    local halo=new("Frame","WindowHalo"..i,{Position=UDim2.fromOffset(-i*3,-i*3),Size=UDim2.new(1,i*6,1,i*6),
        BorderSizePixel=0,BackgroundColor3=P.Accent,BackgroundTransparency=0.975},root) round(halo,12+i*2)
end
local shell=new("Frame","WindowSurface",{Size=UDim2.fromScale(1,1),BackgroundColor3=P.Background,BorderSizePixel=0},root) round(shell,11)
new("UIStroke","WindowBorder",{Color=Color3.fromRGB(35,48,72),Transparency=0.4,Thickness=1},shell)
local header=new("Frame","TitleBar",{Size=UDim2.new(1,0,0,49),BackgroundColor3=P.Panel,BorderSizePixel=0},shell) round(header,11)
new("UIGradient","TitleTint",{Color=ColorSequence.new(P.Accent:Lerp(P.Background,0.87),P.Purple:Lerp(P.Background,0.9))},header)
local title=label(header,"WindowTitle","SPOOKY HUNTER",UDim2.fromOffset(55,6),UDim2.new(1,-120,0,23),13)
title.Font=Enum.Font.GothamBold
label(header,"WindowSubtitle","Midnight - Lumber Tycoon 2",UDim2.fromOffset(55,27),UDim2.new(1,-120,0,14),10,P.Muted)
local content=new("Frame","HuntPage",{Position=UDim2.fromOffset(16,60),Size=UDim2.new(1,-32,1,-74),BackgroundTransparency=1},shell)
local stage=label(content,"Stage","Ready",UDim2.fromOffset(0,0),UDim2.new(1,0,0,23),17) stage.Font=Enum.Font.GothamBold
local detail=label(content,"StageDetail","Configure the slot and webhook using the gear.",UDim2.fromOffset(0,28),UDim2.new(1,0,0,31),11,P.Muted)
detail.TextWrapped=true detail.TextTruncate=Enum.TextTruncate.None
local rail=new("Frame","ProgressRail",{Position=UDim2.fromOffset(0,67),Size=UDim2.new(1,0,0,4),BackgroundColor3=P.Raised,BorderSizePixel=0},content) round(rail,4)
local fill=new("Frame","ProgressFill",{Size=UDim2.fromScale(0,1),BackgroundColor3=P.Accent,BorderSizePixel=0},rail) round(fill,4)
new("UIGradient","ProgressGradient",{Color=ColorSequence.new(P.Accent,P.Purple)},fill)
local found=label(content,"TreeSummary","Spooky  0     Neon  0",UDim2.fromOffset(0,82),UDim2.new(1,0,0,20),12)
local stats=label(content,"SessionStats","",UDim2.fromOffset(0,107),UDim2.new(1,0,0,18),10,P.Muted)
local scroll=new("ScrollingFrame","ActivityViewport",{Position=UDim2.fromOffset(0,134),Size=UDim2.new(1,0,1,-185),
    BackgroundColor3=P.Panel,BorderSizePixel=0,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=2,ScrollBarImageColor3=Color3.fromRGB(112,117,128),ScrollBarImageTransparency=0.45},content) round(scroll,7)
local activity=label(scroll,"ActivityLog","",UDim2.fromOffset(9,5),UDim2.new(1,-22,0,0),10,P.Muted)
activity.Font=Enum.Font.Code activity.AutomaticSize=Enum.AutomaticSize.Y activity.TextWrapped=true activity.TextTruncate=Enum.TextTruncate.None
activity.TextYAlignment=Enum.TextYAlignment.Top
local startButton=button(content,"StartHunt","Start",UDim2.new(0,0,1,-35),UDim2.new(0.42,-6,0,35),function() H:Start() end,true)
button(content,"StopHunt","Stop",UDim2.new(0.42,0,1,-35),UDim2.new(0.28,-6,0,35),function() H:Stop() end)
button(content,"CopyActivity","Copy log",UDim2.new(0.7,0,1,-35),UDim2.new(0.3,0,0,35),function()
    local text="Spooky Hunter 1.0.0\n"..table.concat(H.Logs,"\n")
    local copy=cap("setclipboard",setclipboard) or cap("toclipboard",toclipboard)
    if copy and pcall(copy,text) then H:Log("Activity copied") else
        local output=new("TextBox","ManualLogCopy",{Position=UDim2.fromOffset(0,134),Size=scroll.Size,Text=text,
            BackgroundColor3=P.Panel,TextColor3=P.Text,TextSize=10,Font=Enum.Font.Code,TextWrapped=true,
            ClearTextOnFocus=false,TextEditable=false,MultiLine=true,TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Top},content)
        output:CaptureFocus() output.SelectionStart=1 output.CursorPosition=#text+1
        local connection
        connection=output.FocusLost:Connect(function() connection:Disconnect() output:Destroy() end)
    end
end)
H.UI={Stage=stage,Detail=detail,Fill=fill,Found=found,Activity=activity,Start=startButton}
local settings=new("ScrollingFrame","SettingsPage",{Position=UDim2.fromOffset(16,60),Size=UDim2.new(1,-32,1,-74),Visible=false,
    BackgroundTransparency=1,BorderSizePixel=0,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=2,ScrollBarImageColor3=Color3.fromRGB(112,117,128)},shell)
new("UIListLayout","SettingsLayout",{Padding=UDim.new(0,9),SortOrder=Enum.SortOrder.LayoutOrder},settings)
local function settingsRow(name,height)
    local row=new("Frame",name,{Size=UDim2.new(1,-5,0,height or 62),BackgroundColor3=P.Panel,BorderSizePixel=0},settings) round(row,8) return row
end
local order=0
local function field(titleText,key,numeric,secret)
    local row=settingsRow(key.."Row") order=order+1 row.LayoutOrder=order
    label(row,key.."Label",titleText,UDim2.fromOffset(10,4),UDim2.new(1,-20,0,17),10,P.Muted)
    local function display() return secret and H.Config[key]~="" and "Configured - click to edit" or tostring(H.Config[key]) end
    local box=new("TextBox",key.."Input",{Position=UDim2.fromOffset(10,24),Size=UDim2.new(1,-20,0,29),BackgroundColor3=P.Raised,
        TextColor3=P.Text,Text=display(),PlaceholderText=key=="ScriptURL" and "https://raw.githubusercontent.com/.../SpookyHunter.client.lua" or "",
        PlaceholderColor3=P.Muted,TextSize=11,Font=Enum.Font.Gotham,ClearTextOnFocus=false,TextTruncate=Enum.TextTruncate.AtEnd,
        TextXAlignment=Enum.TextXAlignment.Left,BorderSizePixel=0},row) round(box,5)
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
field("Discord webhook (optional)","Webhook",false,true)
field("Script URL - needed when not using the loader","ScriptURL")
local mode=settingsRow("ProcessingMode",46) order=order+1 mode.LayoutOrder=order
local modeButton
modeButton=button(mode,"ModeToggle",H.Config.FullCycle and "Full cycle - experimental Modwood" or "Search only - stop when found",
    UDim2.fromOffset(8,7),UDim2.new(1,-16,0,32),function()
        if H.Busy then return end
        H.Config.FullCycle=not H.Config.FullCycle
        modeButton.Text=H.Config.FullCycle and "Full cycle - experimental Modwood" or "Search only - stop when found"
        H:Persist(false)
    end)
field("Delay between servers (seconds)","HopDelay",true)
field("Initial world loading wait (seconds)","ScanWait",true)
field("Chop timeout (seconds)","ChopTimeout",true)
field("Modwood burn timeout (seconds)","BurnTimeout",true)
field("Sawmill output timeout (seconds)","MillTimeout",true)
local info=settingsRow("ModwoodNotice",58) order=order+1 info.LayoutOrder=order
local note=label(info,"ModwoodNoticeText","Modwood is reconstructed. If burn, plank output or saving is not confirmed, the hunt stays in this server.",
    UDim2.fromOffset(10,5),UDim2.new(1,-20,1,-10),10,P.Muted) note.TextWrapped=true note.TextTruncate=Enum.TextTruncate.None
button(header,"SettingsGear","⚙",UDim2.fromOffset(12,10),UDim2.fromOffset(30,29),function()
    settings.Visible=not settings.Visible content.Visible=not settings.Visible
    root.Size=UDim2.fromOffset(520,settings.Visible and 470 or 330)
end)
button(header,"CloseWindow","X",UDim2.new(1,-39,0,10),UDim2.fromOffset(27,29),function() H:Destroy() end)
local dragZone=new("Frame","TitleDragZone",{Position=UDim2.fromOffset(50,0),Size=UDim2.new(1,-96,0,49),BackgroundTransparency=1,Active=true},header)
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
    scale.Scale=math.min(1,math.max(0.35,(viewport.X-24)/520),math.max(0.35,(viewport.Y-24)/root.Size.Y.Offset))
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
