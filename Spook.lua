--[[
    Midnight Spooky Hunter 1.5.0 - Lumber Tycoon 2
    October 3, 2026. Client script using Midnight UI Library 2.4.0 or newer.
    Gameplay sequence based on the supplied Spooky Hunter 1.3.7.
    Modwood runs once per tree. Failed attempts leave for another server.
    Use the companion loader or set Script URL for continuation after a hop.
]]
local S = {}
for _, name in ipairs({"Players", "Workspace", "ReplicatedStorage", "HttpService", "TweenService",
    "UserInputService", "RunService", "TeleportService"}) do S[name] = game:GetService(name) end
local Player = S.Players.LocalPlayer
assert(Player, "Spooky Hunter requires a client")
local Env = type(getgenv) == "function" and getgenv() or _G
local LIBRARY_URL="https://raw.githubusercontent.com/zyrk0794/Project/refs/heads/main/Library.lua"
local function loadMidnight()
    assert(type(loadstring)=="function","This script requires a client with loadstring")
    local failure
    for attempt=1,3 do
        local response
        local thread=task.spawn(function() response=table.pack(pcall(game.HttpGet,game,LIBRARY_URL)) end)
        local deadline=os.clock()+20
        while not response and os.clock()<deadline do task.wait(0.1) end
        if not response then pcall(task.cancel,thread) failure="Library download timed out"
        elseif response[1] then
            local compiled,message=loadstring(response[2])
            if compiled then
                local ok,library=pcall(compiled)
                if ok and type(library)=="table" and type(library.CreateCompactWindow)=="function" then return library end
                if ok and type(library)=="table" and type(library.Destroy)=="function" then pcall(library.Destroy,library) end
                failure="Upload Library.lua 2.4.0 to the configured GitHub URL first"
                break
            else failure="Invalid Midnight library: "..tostring(message) end
        else failure="Midnight library download failed" end
        if attempt<3 then task.wait(attempt) end
    end
    error(failure or "Midnight UI unavailable",0)
end
local LoadedMidnight=loadMidnight()
local old = Env.MidnightSpookyHunter
local wasRunning=old and old.Running==true
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
local MIN_TREE_VOLUME = 40
local STALL_TIMEOUT = 180
local DEFAULT = { Slot = 1, Webhook = "", ScriptURL = "", HopDelay = 8, ScanWait = 12, LoadTimeout = 180, MetadataTimeout = 30,
    ChopTimeout = 75, BurnTimeout = 40, MillTimeout = 80, TaskTimeout = 900, FullCycle = true, AntiAfk = true }
local H = { Version = "1.5.0", Alive = true, Running = false, Busy = false, Connections = {}, Logs = {}, ActivityEntries = {},
    Config = table.clone(DEFAULT), Visited = {}, ServerHistory = {}, FailedServers = {}, PendingWood = {},
    Stats = { Servers = 0, Trees = 0, Planks = 0, Skipped = 0 },
    StartedAt = os.time(), Arrived = os.clock(), Generation = 0, Stage = "Ready", Progress = 0 }
H.JobId=game.JobId
H.ModwoodAttempts={}
if old and (old.JobId==game.JobId or (old.LoadReceipt and old.LoadReceipt.JobId==game.JobId)) then
    H.ModwoodAttempts=old.ModwoodAttempts or {}
    H.ServerExitReason=old.ServerExitReason
end
-- Instance references can survive a script update in the same live server.
-- Never deserialize these references or reuse them after a server change.
if old and old.LoadReceipt and old.LoadReceipt.JobId==game.JobId and type(old.PendingWood)=="table"
    and #old.PendingWood>0 then
    H.PendingWood=old.PendingWood H.LoadReceipt=old.LoadReceipt H.LoadedPlot=old.LoadReceipt.Plot
    H.Dirty=true H.NeedsAttention=true H.RecoveredSession=true
end
Env.MidnightSpookyHunter = H
local CANCEL = {}
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function value(object, name)
    local field = object and object:FindFirstChild(name)
    if field and field:IsA("ValueBase") then return field.Value end
    return nil
end
local function under(object,ancestor)
    while object do
        if object==ancestor then return true end
        object=object.Parent
    end
    return false
end
local function livePart(part)
    return part and part:IsA("BasePart") and under(part,S.Workspace)
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
    for key, limits in pairs({LoadTimeout = {30, 300}, MetadataTimeout = {5, 90}, HopDelay = {8, 180}, ScanWait = {8, 120}, ChopTimeout = {15, 180},
        BurnTimeout = {10, 120}, MillTimeout = {15, 180}, TaskTimeout = {300, 1800}}) do
        result[key] = math.clamp(finite(result[key]) and result[key] or DEFAULT[key], limits[1], limits[2])
    end
    result.Webhook = cleanURL(result.Webhook):sub(1, 400)
    result.ScriptURL = cleanURL(result.ScriptURL):sub(1, 1000)
    return result
end
function H:RememberServer(id)
    if type(id) ~= "string" or id == "" then return end
    for i = #self.ServerHistory, 1, -1 do
        if self.ServerHistory[i] == id then table.remove(self.ServerHistory, i) end
    end
    table.insert(self.ServerHistory, id)
    while #self.ServerHistory > 50 do table.remove(self.ServerHistory, 1) end
    table.clear(self.Visited)
    for _, serverId in ipairs(self.ServerHistory) do self.Visited[serverId] = true end
end
local restored
if Read then
    for _, path in ipairs({FILE, FILE .. ".bak"}) do
        local ok, encoded = pcall(Read, path)
        if ok then
            local decoded, data = pcall(S.HttpService.JSONDecode, S.HttpService, encoded)
            if decoded and type(data) == "table" and (data.Schema == 1 or data.Schema == 2) then
                restored = data
                if path ~= FILE then H.ConfigWarning = "Settings recovered from backup" end
                break
            else H.ConfigWarning = "Settings file unreadable - checking backup" end
        end
    end
end
if restored then
    H.Config = configFrom(restored.Config)
    if type(restored.Departure)=="table" and restored.Departure.JobId==game.JobId then
        H.ServerExitReason=tostring(restored.Departure.Reason or "Modwood was interrupted")
    end
    if restored.Version ~= H.Version and H.Config.HopDelay == 15 then H.Config.HopDelay = 8 end
    if type(restored.WindowPosition) == "table" and finite(restored.WindowPosition.X) and finite(restored.WindowPosition.Y) then
        H.WindowPosition = {X=math.clamp(restored.WindowPosition.X,0,1),Y=math.clamp(restored.WindowPosition.Y,0,1)}
    end
    if type(restored.ServerHistory) == "table" then
        for _, id in ipairs(restored.ServerHistory) do H:RememberServer(id) end
    elseif type(restored.Visited) == "table" then
        local legacy = {}
        for id, stamp in pairs(restored.Visited) do
            if type(id) == "string" and finite(stamp) then table.insert(legacy, {Id=id, Stamp=stamp}) end
        end
        table.sort(legacy, function(a,b) if a.Stamp == b.Stamp then return a.Id < b.Id end return a.Stamp < b.Stamp end)
        for _, entry in ipairs(legacy) do H:RememberServer(entry.Id) end
    end
    if type(restored.FailedServers) == "table" then
        for id, untilTime in pairs(restored.FailedServers) do
            if type(id)=="string" and finite(untilTime) and untilTime>os.time() then H.FailedServers[id]=untilTime end
        end
    end
    if type(restored.Stats) == "table" then
        for key in pairs(H.Stats) do
            if finite(restored.Stats[key]) then H.Stats[key] = math.max(0, math.floor(restored.Stats[key])) end
        end
    end
    if finite(restored.StartedAt) then H.StartedAt = math.min(os.time(), restored.StartedAt) end
    H.LastCountedServer = restored.LastCountedServer
end
local function uiText(text) return tostring(text):gsub("SpookyNeon", "Sinister") end
local function cleanError(err)
    local message = tostring(err)
    return (message:gsub("^.-:%d+: ", "")):sub(1, 350)
end
local stageTitles = {
    ["Confirming property"]="Loading property", ["Waiting for the plot"]="Loading property",
    ["Selecting your sawmill"]="Selecting sawmill", ["Equipping inventory axe"]="Equipping axe",
    ["Bringing tree to your base"]="Bringing tree home", ["Checking felled tree"]="Preparing wood",
    ["Modwood - igniting parent section"]="Preparing Modwood",
    ["Modwood - stabilizing selected tree"]="Preparing Modwood",
    ["Modwood - waiting for parent separation"]="Preparing Modwood",
    ["Modwood - triggering conversion"]="Processing wood",
    ["Modwood - waiting for sawmill output"]="Waiting for planks",
    ["Finding another server"]="Finding a server", ["Joining another server"]="Joining server",
    ["Resuming unfinished wood"]="Resuming harvest",
}
local function shortError(message)
    message=cleanError(message)
    if message:find("Modwood unavailable",1,true) then return "Switching to standard milling" end
    if message:find("Cut not confirmed",1,true) then return "Waiting for the cut to complete" end
    if message:find("no LavaFire",1,true) then return "Ignition not confirmed - changing server" end
    if message:find("whole-tree conversion",1,true) then return "Waiting for the remaining wood" end
    if message:find("Request timed out",1,true) then return "Waiting for the server" end
    message=message:gsub(" %- copy Activity.*$", ""):gsub("; copy Activity before retrying", "")
    return message
end
function H:Log(message, level, display)
    message=tostring(message) level=level or "INFO"
    if self.Config.Webhook~="" then message=message:gsub(self.Config.Webhook:gsub("([^%w])","%%%1"),"[webhook]") end
    -- Keep technical timings in the copied report, never in the visible feed.
    table.insert(self.Logs,os.date("!%H:%M:%S").."  "..level.."  "..message)
    while #self.Logs>160 do table.remove(self.Logs,1) end
    if level=="DEBUG" or display==false then return end
    local visible=type(display)=="string" and display or shortError(message)
    if self.Config.Webhook~="" then visible=visible:gsub(self.Config.Webhook:gsub("([^%w])","%%%1"),"[webhook]") end
    visible=uiText(visible)
    local entries=self.ActivityEntries
    local last=entries[#entries]
    if last and last.Text==visible and last.Level==level then
        last.Count=last.Count+1
    else
        table.insert(entries,{Text=visible,Level=level,Count=1})
        while #entries>40 do table.remove(entries,1) end
    end
    if self.UI then
        local levels={INFO="Info",WARNING="Warning",ERROR="Error"}
        local rows={}
        for _,entry in ipairs(entries) do
            table.insert(rows,{Text=entry.Text..(entry.Count>1 and " (x"..entry.Count..")" or ""),Level=levels[entry.Level] or "Info"})
        end
        self.UI.Activity:SetEntries(rows)
    end
end
function H:SetStage(text, progress, detail)
    local changed=self.Stage~=text
    if changed then self.StageStarted=os.clock() end
    self.Stage=text
    if progress then self.Progress=math.clamp(progress,0,1) end
    local shown=stageTitles[text] or uiText(text)
    local useful=detail and (detail:match("^Tree %d") or detail:match("^Piece %d") or text=="Equipping inventory axe"
        or text=="Rare trees found" or text=="Waiting for available servers" or text=="Needs attention"
        or text=="Task stopped")
    local caption=useful and uiText(shortError(detail)) or ""
    if self.UI then
        self.UI.Progress:SetText(shown,caption)
        self.UI.Progress:Set(self.Progress*100,true)
    end
    local diagnostic=text..(detail and (" - "..detail) or "")
    if diagnostic~=self.LastStageDiagnostic then
        self.LastStageDiagnostic=diagnostic
        local visible=shown..(caption~="" and " - "..caption or "")
        self:Log(diagnostic,"INFO",visible~=self.LastStageVisible and visible or false)
        self.LastStageVisible=visible
    end
end
function H:SetAntiAfk(enabled)
    self.Config.AntiAfk=enabled==true
    if self.AntiAfkConnection then self.AntiAfkConnection:Disconnect() self.AntiAfkConnection=nil end
    if not self.Config.AntiAfk or not self.Alive then return end
    -- Own only this connection; never disconnect another script's Idled handlers.
    local ok,connection=pcall(function()
        return Player.Idled:Connect(function()
            if not self.Alive or not self.Config.AntiAfk or self.AntiAfkBusy then return end
            if self.LastIdlePulse and os.clock()-self.LastIdlePulse<60 then return end
            if S.UserInputService:GetFocusedTextBox() then return end
            self.LastIdlePulse=os.clock() self.AntiAfkBusy=true
            local sent=pcall(function()
                local virtual=game:GetService("VirtualUser")
                virtual:CaptureController()
                virtual:ClickButton2(Vector2.new(0,0))
            end)
            if not sent then
                -- Reuse the service. Always release the button, including after a failed press.
                local got,virtual=pcall(game.GetService,game,"VirtualInputManager")
                if got and virtual then
                    local attempted,result=pcall(function()
                        local pressed=pcall(function() virtual:SendMouseButtonEvent(0,0,1,true,game,0) end)
                        local released=pcall(function() virtual:SendMouseButtonEvent(0,0,1,false,game,0) end)
                        return pressed and released
                    end)
                    sent=attempted and result==true
                end
            end
            self.AntiAfkBusy=false
            if sent then
                self.AntiAfkWarning=false
                self.IdlePulses=(self.IdlePulses or 0)+1
            elseif not self.AntiAfkWarning then
                self.AntiAfkWarning=true
                self:Log("Anti-AFK input unavailable in this executor","WARNING")
            end
        end)
    end)
    if ok then self.AntiAfkConnection=connection
    else self:Log("Anti-AFK could not connect to Idled","WARNING") end
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
    local failed = {}
    for id, untilTime in pairs(self.FailedServers) do
        if untilTime > os.time() then failed[id] = untilTime else self.FailedServers[id] = nil end
    end
    local data = { Schema = 2, Version = self.Version, WindowPosition = self.WindowPosition, Config = self.Config, ServerHistory = table.clone(self.ServerHistory),
        FailedServers = failed, Stats = self.Stats, LastCountedServer = self.LastCountedServer,
        StartedAt = self.StartedAt, Resume = resume == true, Target = target, TicketTime = os.time(),
        Departure = self.ServerExitReason and {JobId=game.JobId,Reason=self.ServerExitReason} or nil }
    local ok = pcall(function()
        local encoded = S.HttpService:JSONEncode(data)
        Write(FILE .. ".tmp", encoded)
        assert(Read(FILE .. ".tmp") == encoded, "Settings staging verification failed")
        local previousOK, previous = pcall(Read, FILE)
        if previousOK then
            local valid, decoded = pcall(S.HttpService.JSONDecode, S.HttpService, previous)
            if valid and type(decoded)=="table" and (decoded.Schema==1 or decoded.Schema==2) then
                Write(FILE .. ".bak", previous)
            end
        end
        Write(FILE, encoded)
        assert(Read(FILE) == encoded, "Settings write verification failed")
    end)
    if ok then return true end
    return false, "Settings could not be saved"
end
function H:Checkpoint(key)
    self.ProgressKeys = self.ProgressKeys or {}
    if not self.ProgressKeys[key] then
        self.ProgressKeys[key] = true
        self.LastProgressAt = os.clock()
    end
end
function H:ObserveProgress()
    for _,work in ipairs(self.PendingWood) do
        local prefix=tostring(work)
        if work.Log then self:Checkpoint(prefix..":felled") end
        if work.AtBase then self:Checkpoint(prefix..":base") end
        if work.Modwood then self:Checkpoint(prefix..":modwood:"..work.Modwood.Phase) end
        if work.Classic then
            for index,job in ipairs(work.Classic.Jobs) do
                if job.Model then self:Checkpoint(prefix..":piece:"..index) end
                if job.Done then self:Checkpoint(prefix..":milled:"..index) end
            end
        end
        for plank in pairs(work.Delivered or {}) do self:Checkpoint(prefix..":delivered:"..tostring(plank)) end
    end
end
function H:Token(parent)
    if not parent then self.Generation = self.Generation + 1 end
    local token = { Generation = parent and parent.Generation or self.Generation, Cleanups = {},
        Character = parent and parent.Character, Deadline = parent and parent.Deadline or os.clock()+self.Config.TaskTimeout }

    function token:Check()
        if not H.Alive or not H.Running or H.Generation ~= self.Generation then error(CANCEL, 0) end
        if H.Watchdog then
            H:ObserveProgress()
            assert(os.clock()-(H.LastProgressAt or os.clock())<STALL_TIMEOUT,"No confirmed progress for three minutes")
        end
        assert(os.clock() < self.Deadline, "Task time limit reached - the current task was stopped")
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
        self:Check()
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
    if parent then parent:Finally(function() token:Clean() end) end
    return token
end
function H:WaitForGame(token)
    self:SetStage("Loading game",0.01)
    local deadline=os.clock()+self.Config.LoadTimeout
    local stableSince,lastSignature,lastReason
    repeat
        token:Check()
        local missing,refs={},{}
        local function need(parent,name,label)
            local object=parent and parent:FindFirstChild(name)
            if object then table.insert(refs,object) else table.insert(missing,label or name) end
            return object
        end
        if not game:IsLoaded() then table.insert(missing,"Game.Loaded") end
        local char=Player.Character
        local hum=char and char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health<=0 then table.insert(missing,"Live character") end
        need(char,"HumanoidRootPart") need(Player,"Backpack") need(Player,"PlayerGui")
        need(S.Workspace,"LogModels") need(S.Workspace,"PlayerModels")
        local interaction=need(S.ReplicatedStorage,"Interaction")
        need(interaction,"RemoteProxy") need(interaction,"ClientIsDragging")
        if self.Config.FullCycle then
            need(S.ReplicatedStorage,"AxeClasses")
            local saves=need(S.ReplicatedStorage,"LoadSaveRequests")
            need(saves,"RequestLoad") need(saves,"RequestSave")
        end
        local regions,trees=0,0
        for _,region in ipairs(S.Workspace:GetChildren()) do
            if region.Name=="TreeRegion" then
                regions=regions+1
                for _,model in ipairs(region:GetChildren()) do
                    if model:FindFirstChild("TreeClass") and model:FindFirstChild("Owner") and model:FindFirstChild("WoodSection",true) then trees=trees+1 end
                end
            end
        end
        if regions==0 or trees==0 then table.insert(missing,"Tree regions") end
        local signature={regions,trees}
        for _,object in ipairs(refs) do table.insert(signature,object) end
        local changed=not lastSignature or #signature~=#lastSignature
        if not changed then for i,object in ipairs(signature) do if lastSignature[i]~=object then changed=true break end end end
        if #missing==0 then
            if changed or not stableSince then stableSince=os.clock() end
            if os.clock()-stableSince>=2 then
                self.LoadDiagnostic="Game ready - required objects stable for 2 seconds"
                self:Log(self.LoadDiagnostic,"DEBUG") return
            end
        else stableSince=nil end
        lastSignature=signature
        local reason=#missing>0 and table.concat(missing,", ") or "Waiting for stable objects"
        self.LoadDiagnostic="Game loading - "..reason
        if reason~=lastReason then self:Log(self.LoadDiagnostic,"DEBUG") lastReason=reason end
        assert(os.clock()<deadline,"Game data is still loading - "..reason)
        token:Sleep(0.25)
    until false
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
    local function selectedProperty(gui)
        local selected
        for _,node in ipairs(gui:GetDescendants()) do
            if node:IsA("ObjectValue") and node.Value then
                local candidate=node.Value
                local owner=candidate:FindFirstChild("Owner")
                if owner and owner:IsA("ObjectValue") then
                    if selected and selected~=candidate then return nil end
                    selected=candidate
                end
            end
        end
        return selected
    end
    local function nextProperty(gui)
        if not fire or os.clock()-(state.LastNavigation or -math.huge)<2 then return false end
        for _,node in ipairs(gui:GetDescendants()) do
            if node:IsA("GuiButton") and visible(node,gui) then
                local name=node.Name:lower():gsub("[^%a]", "")
                local text=node:IsA("TextButton") and node.Text:lower():match("^%s*(.-)%s*$") or ""
                if name=="next" or name=="nextproperty" or name=="right" or text=="next" or text==">" then
                    state.LastNavigation=os.clock()
                    local signal=signalFor(node,state.NavigationAttempts or 0)
                    state.NavigationAttempts=(state.NavigationAttempts or 0)+1
                    local ok
                    if signal=="Activated" then ok=pcall(fire,node[signal],nil,1)
                    elseif signal=="MouseButton1Down" then ok=pcall(fire,node[signal],node.AbsolutePosition.X+node.AbsoluteSize.X/2,node.AbsolutePosition.Y+node.AbsoluteSize.Y/2)
                    else ok=pcall(fire,node[signal]) end
                    if ok then
                        state.Attempts={0,0} state.FirstSent=false state.SecondSent=false state.Step=1
                        state.VisibleSince=nil state.VisibleButton=nil
                        H:Log("Selecting another available property")
                        return true
                    end
                end
            end
        end
        return false
    end
    local function service()
        token:Check()
        if os.clock() - state.LastCheck < 0.1 then return end
        state.LastCheck = os.clock()
        local gui, first, second = buttons()
        if not gui then return end
        local firstVisible, secondVisible = visible(first, gui), visible(second, gui)
        -- The game can return to selection when another player takes the plot.
        if firstVisible and not secondVisible and state.Step>1 and not state.HavePlot then
            state.Step=1 state.FirstSent=false state.SecondSent=false
            state.Attempts={0,0} state.VisibleSince=nil state.VisibleButton=nil
            nextProperty(gui)
            H:Log("Property unavailable - selecting again","WARNING")
            return
        end
        local selected=selectedProperty(gui)
        if selected and value(selected,"Owner")~=nil and not owned(selected) then
            if firstVisible then nextProperty(gui) end
            return -- Never confirm a property observed as owned by another player.
        end
        if firstVisible and state.Attempts[1]>=3 and not state.HavePlot and nextProperty(gui) then return end
        if firstVisible or secondVisible then state.Seen = true end
        if firstVisible then state.SeenFirst = true end
        if state.Step==1 and secondVisible and not firstVisible and H.PropertyFirstReceipt
            and H.PropertyFirstReceipt.JobId==game.JobId and H.PropertyFirstReceipt.Slot==H.Config.Slot then
            state.FirstSent=true state.SeenFirst=true
        end
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
        if step == 1 then
            state.FirstSent = true
            H.PropertyFirstReceipt={JobId=game.JobId,Slot=H.Config.Slot}
        else state.SecondSent = true end
        H:SetStage(step == 1 and "Selecting property" or "Waiting for the plot", step == 1 and 0.13 or 0.15)
        H:Log(string.format("Property step %d - %s - attempt %d", step, signalName, state.Attempts[step]),"DEBUG")
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
    self.PropertyFirstReceipt=nil
    self.LoadReceipt = {Slot=slot, Plot=loadedPlot, JobId=game.JobId}
    self:Checkpoint("loaded:"..tostring(loadedPlot))
    if self:KnownSlot() == nil then
        self:Log("Slot indicator unavailable - confirmed property belongs to you after the load sequence","DEBUG")
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
function H:FindMill(token, plot)
    local deadline=os.clock()+math.min(90,self.Config.LoadTimeout)
    self:SetStage("Selecting your sawmill",0.46,"Looking for an owned Sawmill4L")
    repeat
        token:Check()
        local models=S.Workspace:FindFirstChild("PlayerModels")
        local selected, selectedInlet, distance
        local center=plot and self:PlotCenter(plot).Position
        for _,model in ipairs(models and models:GetChildren() or {}) do
            if model:IsA("Model") and owned(model) and (model.Name=="Sawmill4L" or value(model,"ItemName")=="Sawmill4L") then
                local inlet=model:FindFirstChild("Particles")
                local settings=model:FindFirstChild("Settings")
                local x,z=value(settings,"DimX"),value(settings,"DimZ")
                if inlet and inlet:IsA("BasePart") and finite(x) and finite(z) and x>0 and z>0 then
                    local d=center and (inlet.Position-center).Magnitude or 0
                    if not selected or d<distance then selected,selectedInlet,distance=model,inlet,d end
                end
            end
        end
        if selected then
            self.SelectedMill=selected
            self:Log("Sawmill selected automatically - "..selected:GetFullName(),"INFO","Sawmill selected")
            return selected,selectedInlet
        end
        token:Sleep(0.3)
    until os.clock()>=deadline
    error("No ready owned Sawmill4L - check its Particles inlet and DimX/DimZ settings",0)
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
    local character=Player.Character
    local backpack=Player:FindFirstChildOfClass("Backpack")
    local best,bestStats,score=nil,nil,-1
    for _,container in pairs({character,backpack}) do
        for _,tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") then
                local stats=self:AxeStats(tool,kind)
                if stats then
                    local rate=stats.Damage/stats.SwingCooldown
                    if rate>score or (rate==score and tool.Parent==character) then
                        best,bestStats,score=tool,stats,rate
                    end
                end
            end
        end
    end
    return best,bestStats
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
function H:WoodVolume(model)
    local volume=0
    for _,part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") and part.Name=="WoodSection" then volume=volume+part.Size.X*part.Size.Y*part.Size.Z end
    end
    return volume
end
function H:Scan(token)
    local matches, counts = {}, { Spooky = 0, SpookyNeon = 0, SpookyVolume = 0, SpookyNeonVolume = 0, IgnoredSmall = 0 }
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
                    for _, section in ipairs(model:GetDescendants()) do
                        if section:IsA("BasePart") and section.Name == "WoodSection" then
                            volume = volume + section.Size.X * section.Size.Y * section.Size.Z
                            if tonumber(value(section,"ID")) == 1 then trunk = section end
                        end
                    end
                    if volume<MIN_TREE_VOLUME then counts.IgnoredSmall=counts.IgnoredSmall+1 end
                    if trunk and volume>=MIN_TREE_VOLUME then
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
        self.UI.Spooky:Set(counts.Spooky,string.format("%.0f studs3",counts.SpookyVolume))
        self.UI.Neon:Set(counts.SpookyNeon,string.format("%.0f studs3",counts.SpookyNeonVolume))
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
                self:Log(string.format("Scan complete - %.2fs / %d trees checked", os.clock()-started, ready),"DEBUG")
                if self.Counts.IgnoredSmall>0 then self:Log("Trees below 4 studs3 ignored - "..self.Counts.IgnoredSmall) end
                return matches
            end
        else stableSince = os.clock() end
        assert(os.clock()-started < self.Config.ScanWait, "World scan did not stabilize - staying in this server")
        token:Sleep(0.25)
    until false
end
function H:FindFelledLog(cut)
    local logs=S.Workspace:FindFirstChild("LogModels")
    local matches, identities={},{}
    local candidates=logs and logs:GetChildren() or {}
    if cut.Tree.Parent and not table.find(candidates,cut.Tree) then table.insert(candidates,cut.Tree) end
    local ancestor=cut.Trunk.Parent and cut.Trunk:FindFirstAncestorOfClass("Model")
    if ancestor and not table.find(candidates,ancestor) then table.insert(candidates,ancestor) end
    for _, model in ipairs(candidates) do
        if model:IsA("Model") and owned(model) and value(model,"TreeClass")==cut.Kind then
            local distance, sameSection=math.huge,false
            for _, section in ipairs(model:GetDescendants()) do
                if section:IsA("BasePart") and section.Name=="WoodSection" then
                    distance=math.min(distance,(section.Position-cut.Origin).Magnitude)
                    if section==cut.Trunk then sameSection=true end
                end
            end
            local inLogs=model.Parent==logs
            local detached=inLogs and not model:FindFirstChild("RootCut")
            if detached and distance<math.huge then
                if sameSection then table.insert(identities,model)
                elseif not cut.Previous[model] and distance<cut.Radius then table.insert(matches,model) end
            end
        end
    end
    cut.Candidates=#matches cut.IdentityMatches=#identities
    if #identities==1 then return identities[1] end
    if #identities==0 and #matches==1 then return matches[1] end
    return nil
end
function H:FireAxe(proxy,event,payload)
    -- Pasted text(7).txt and the public implementations use two explicit
    -- arguments. The remote receiver is supplied only once here.
    local ok,err=pcall(proxy.FireServer,proxy,event,payload)
    if not ok then error("Axe request could not be sent - "..tostring(err),0) end
end
function H:Chop(entry, tool, stats, token, checkpoint)
    local tree, trunk=entry.Model,entry.Trunk
    assert(tree and trunk,"The selected tree has no recorded trunk")
    local logs=S.Workspace:FindFirstChild("LogModels") assert(logs,"LogModels missing")
    local cut=checkpoint and checkpoint.Cut
    if not cut then
        assert(tree.Parent and trunk.Parent and value(tree,"Owner")==nil,"The selected tree is no longer available")
        cut={Tree=tree,Trunk=trunk,Kind=entry.Kind,Origin=trunk.Position,Radius=math.max(80,trunk.Size.Y),
            Previous={},Strikes=0,Started=os.clock()}
        for _, model in ipairs(logs:GetChildren()) do cut.Previous[model]=true end
        if checkpoint then checkpoint.Cut=cut end
    end
    self.LastCut=cut
    local proxy=self:Remote("Interaction","RemoteProxy")
    local deadline=os.clock()+self.Config.ChopTimeout
    local nextStrike, nextPosition, nextStatus=0,0,os.clock()+5
    local detachedAt
    self:Log(string.format("Cut setup - axe=%s; damage=%.3f; cooldown=%.3f; height=0.3; section=%s",
        tostring(value(tool,"ToolName") or tool.Name),stats.Damage,stats.SwingCooldown,tostring(value(trunk,"ID"))),"DEBUG")
    repeat
        token:Check()
        local found=self:FindFelledLog(cut)
        if found then
            self:Log(string.format("Felled wood confirmed - %d strikes / %.1fs",cut.Strikes,os.clock()-cut.Started),"INFO","Tree cut")
            cut.Result=found
            return found
        end
        local rootCut=tree:FindFirstChild("RootCut")~=nil
        local detached=rootCut or not tree.Parent or not trunk.Parent
        if detached and not detachedAt then detachedAt=os.clock() end
        local owner=value(tree,"Owner")
        assert(owner==nil or owner==Player,"Another player now owns the selected tree")
        if not detached and (owner==nil or owner==Player) then
            local event=tree:FindFirstChild("CutEvent")
            assert(event,"The selected tree has no CutEvent")
            if tool.Parent~=Player.Character then
                local backpack=Player:FindFirstChildOfClass("Backpack")
                assert(tool.Parent==backpack,"The selected axe is no longer in your inventory")
                local _,humanoid=self:Character()
                humanoid:EquipTool(tool)
                token:Sleep(0.25)
                assert(tool.Parent==Player.Character,"The selected axe could not be re-equipped")
            end
            -- The source approaches the section center. The payload height is
            -- measured from the bottom independently of the avatar's position.
            if os.clock()>=nextPosition then
                local stand=trunk.Position+Vector3.new(5,0,0)
                self:Teleport(CFrame.lookAt(stand,trunk.Position))
                if cut.Strikes==0 then token:Sleep(0.35) end
                nextPosition=os.clock()+0.1
            end
            if os.clock()>=nextStrike then
                token:Check()
                cut.Strikes=cut.Strikes+1
                local sectionId=tonumber(value(trunk,"ID"))
                assert(sectionId==1,"The selected section is not the base trunk")
                self:FireAxe(proxy,event,{tool=tool,sectionId=sectionId,height=0.3,faceVector=Vector3.new(-1,0,0),
                    hitPoints=stats.Damage,cooldown=stats.SwingCooldown,cuttingClass="Axe"})
                -- Never shorten a slow axe's cooldown. Leave a small margin
                -- so local scheduler jitter does not send the next hit early.
                nextStrike=os.clock()+math.max(stats.SwingCooldown,0.1)+0.05
            end
        end
        cut.Status=string.format("strikes=%d; tree=%s; trunk=%s; RootCut=%s; owner=%s; candidates=%d",
            cut.Strikes,tostring(tree.Parent~=nil),tostring(trunk.Parent~=nil),tostring(rootCut),
            owner==Player and "LocalPlayer" or "Unowned",cut.Candidates or 0)
        local _,_,avatar=self:Character()
        local distance=trunk.Parent and (avatar.Position-trunk.Position).Magnitude or -1
        self.CutDiagnostic=string.format("Cut diagnostic - %s\n%s\naxe=%s; damage=%.3f; cooldown=%.3f; centerDistance=%.2f; equipped=%s",
            cut.Kind,cut.Status,tostring(value(tool,"ToolName") or tool.Name),stats.Damage,stats.SwingCooldown,
            distance,tostring(tool.Parent==Player.Character))
        if os.clock()>=nextStatus then self:Log("Cut progress - "..cut.Status,"DEBUG") nextStatus=os.clock()+10 end
        -- Poll independently from the axe cooldown so delayed ownership fields
        -- and model reparenting are observed before another strike is sent.
        token:Sleep(0.1)
    until os.clock()>=deadline and (not detachedAt or os.clock()-detachedAt>=8)
    local found=self:FindFelledLog(cut)
    if found then cut.Result=found return found end
    error("Cut not confirmed - "..(cut.Status or "No matching owned log").." - copy Activity",0)
end
function H:DampWood(model)
    if not model or not model.Parent or not owned(model) then return end
    for _,part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") and not part.Anchored then
            part.AssemblyLinearVelocity=Vector3.zero
            part.AssemblyAngularVelocity=Vector3.zero
        end
    end
end
function H:QuietWood(model,token)
    -- Suppress contact impulses during transfers, without anchoring wood or
    -- changing CanTouch. Restore every original collision value on every exit.
    local saved,restored={},false
    local function restore()
        if restored then return end
        restored=true
        for part,collision in pairs(saved) do
            if part.Parent then pcall(function() part.CanCollide=collision end) end
        end
    end
    token:Finally(restore)
    for _,part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            saved[part]=part.CanCollide
            part.CanCollide=false
        end
    end
    return restore
end
function H:Move(model,destination,token)
    assert(model.Parent and owned(model) and partOf(model),"Owned wood is no longer available")
    local record={Started=os.clock(),Placements=0,Settled=false}
    self.LastMove=record
    token:Finally(function()
        if self.LastMove==record then
            self.MoveDiagnostic=string.format("Last transfer: placements=%d; settled=%s; elapsed=%.2fs",
                record.Placements,tostring(record.Settled),os.clock()-record.Started)
        end
    end)
    local drag=self:Remote("Interaction","ClientIsDragging")
    local part=partOf(model)
    self:AcquireWood(model,part,token)
    local restore=self:QuietWood(model,token)
    local relative=model:GetPivot():ToObjectSpace(part.CFrame)
    local placements,stableSince,nextPlacement=0,nil,0
    local deadline=os.clock()+8
    repeat
        token:Check()
        assert(model.Parent and owned(model) and livePart(part),"Wood ownership changed")
        local distance=(model:GetPivot().Position-destination.Position).Magnitude
        if placements>0 then assert(distance<35,"Wood became unstable during transfer") end
        if placements==0 or (distance>1.5 and os.clock()>=nextPlacement) then
            assert(placements<3,"Wood did not settle at its destination")
            self:DampWood(model)
            -- Avatar and wood move in the same scheduler step. Never fly the
            -- tree through intervening scenery or repeat a long teleport burst.
            self:Teleport(destination*relative+Vector3.new(5,3,0))
            drag:FireServer(model)
            model:PivotTo(destination)
            self:DampWood(model)
            placements=placements+1 nextPlacement=os.clock()+0.5 stableSince=nil
            record.Placements=placements
        elseif distance<=1.5 then stableSince=stableSince or os.clock()
        else stableSince=nil end
        self:DampWood(model)
        token:Sleep(0.15)
        if stableSince and os.clock()-stableSince>=0.6 then break end
    until os.clock()>=deadline
    assert(stableSince and os.clock()-stableSince>=0.6,"Wood did not settle at its destination")
    restore()
    -- Observe restored collisions too; a local placement is not delivery proof.
    for _=1,5 do
        token:Sleep(0.15)
        assert(model.Parent and owned(model),"Wood changed after placement")
        assert((model:GetPivot().Position-destination.Position).Magnitude<5,"Wood shifted after placement")
        self:DampWood(model)
    end
    record.Settled=true
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
    self:Log("Felled tree delivered to your plot before Modwood","INFO","Tree delivered")
end
function H:ModwoodParts(log)
    local sections, root, candidates, duplicate = {}, nil, {}, false
    for _, section in ipairs(log:GetDescendants()) do
        if section:IsA("BasePart") and section.Name == "WoodSection" then
            local id = tonumber(value(section,"ID"))
            if id then
                if sections[id] then duplicate = true end
                sections[id] = section
            end
            if id == 1 then root = section end
        end
    end
    if duplicate then return nil, nil, nil, "Duplicate section IDs - branch selection is ambiguous" end
    if not root then return nil, nil, nil, "No WoodSection with ID 1 in the felled log" end
    local terminal, unresolved, direct = 0, 0, 0
    for id, section in pairs(sections) do
        local parentID = tonumber(value(section,"ParentID"))
        local parent = parentID and sections[parentID]
        local childIDs = section:FindFirstChild("ChildIDs")
        -- Missing ChildIDs is not evidence of a leaf: require the explicit empty folder.
        if id ~= 1 and childIDs and #childIDs:GetChildren() == 0 then
            terminal = terminal + 1
            if not parent or parent == section then unresolved = unresolved + 1
            elseif parentID == 1 then direct = direct + 1
            else
                -- Reject contradictory data while the server is rebuilding the log.
                local hasChild = false
                for _, other in pairs(sections) do
                    if tonumber(value(other,"ParentID")) == id then hasChild = true break end
                end
                if not hasChild then table.insert(candidates, {Leaf=section, Parent=parent, ID=id, Width=section.Size.Z}) end
            end
        end
    end
    table.sort(candidates, function(a,b)
        if a.Width == b.Width then return a.ID < b.ID end
        return a.Width < b.Width
    end)
    if not candidates[1] then
        if terminal>0 and direct==terminal and unresolved==0 then
            return nil,nil,nil,"Modwood unavailable - all terminal branches attach directly to the trunk"
        end
        return nil, nil, nil, string.format("Branch selection unresolved - terminal: %d, parent missing: %d, attached to trunk: %d - copy Activity", terminal, unresolved, direct)
    end
    return root, candidates[1].Leaf, candidates[1].Parent
end
function H:CaptureModwood(log, mill, reason)
    local lines = {"Modwood structure - " .. tostring(reason), "TreeClass: " .. tostring(value(log,"TreeClass")),
        "Owned log: " .. tostring(owned(log)), "Selected sawmill: " .. (mill and mill:GetFullName() or "Not selected")}
    local sections = {}
    for _, section in ipairs(log:GetDescendants()) do
        if section:IsA("BasePart") and section.Name == "WoodSection" then table.insert(sections,section) end
    end
    table.sort(sections,function(a,b) return tostring(value(a,"ID")) < tostring(value(b,"ID")) end)
    table.insert(lines,"Section count: " .. #sections)
    for index, section in ipairs(sections) do
        if index > 160 then table.insert(lines,"Report truncated after 160 sections") break end
        local children, ids = section:FindFirstChild("ChildIDs"), {}
        if children then
            for _, child in ipairs(children:GetChildren()) do
                table.insert(ids,child:IsA("ValueBase") and tostring(child.Value) or child.ClassName)
            end
        end
        table.sort(ids)
        table.insert(lines,string.format("ID=%s (%s) ParentID=%s Children=%s Size=%.3f,%.3f,%.3f Container=%s",
            tostring(value(section,"ID")), typeof(value(section,"ID")), tostring(value(section,"ParentID")),
            children and ("[" .. table.concat(ids,",") .. "]") or "MISSING",
            section.Size.X,section.Size.Y,section.Size.Z,section.Parent:GetFullName()))
    end
    self.ModwoodDiagnostic = table.concat(lines,"\n")
end
-- Build a post-order plan: descendants first, the trunk last.
function H:DismemberPlan(log)
    if not log or not under(log,S.Workspace) or not owned(log) then return nil,"Wood is no longer owned" end
    local byID,jobs={},{}
    for _,part in ipairs(log:GetDescendants()) do
        if part:IsA("BasePart") and part.Name=="WoodSection" then
            local id=tonumber(value(part,"ID"))
            if not id then return nil,"Waiting for section IDs" end
            if byID[id] then return nil,"Duplicate section IDs" end
            byID[id]=part
        end
    end
    if not byID[1] then return nil,"Waiting for the root section" end
    for id,part in pairs(byID) do
        local seen,depth,current={},0,id
        while current~=1 do
            if seen[current] then return nil,"Cyclic branch data" end
            seen[current]=true
            local section=byID[current]
            current=section and tonumber(value(section,"ParentID"))
            if not current or not byID[current] then return nil,"Waiting for branch parents" end
            depth=depth+1
        end
        local children=part:FindFirstChild("ChildIDs")
        for _,child in ipairs(children and children:GetChildren() or {}) do
            local childID=child:IsA("ValueBase") and tonumber(child.Value)
            if not childID or not byID[childID] then return nil,"Waiting for child sections" end
            if tonumber(value(byID[childID],"ParentID"))~=id then return nil,"Branch links are inconsistent" end
        end
        if part.Size.Y<=0 then return nil,"Invalid section dimensions" end
        table.insert(jobs,{Section=part,ID=id,Depth=depth,Height=math.min(0.3,part.Size.Y/2),OriginalHeight=part.Size.Y})
    end
    table.sort(jobs,function(a,b) return a.Depth==b.Depth and a.ID<b.ID or a.Depth>b.Depth end)
    if #jobs==1 then jobs[1].Model=log jobs[1].Direct=true end
    return jobs
end
function H:SimpleTreeParts(log)
    local jobs=self:DismemberPlan(log)
    if jobs and #jobs==2 and jobs[1].Depth==1 then return jobs[2].Section,jobs[1].Section end
end
function H:WaitForModwood(log,token)
    self:SetStage("Checking felled tree",0.48)
    local deadline=os.clock()+self.Config.MetadataTimeout
    local previous,stableSince,reason
    repeat
        token:Check()
        if not log.Parent or not owned(log) then return false,"Felled tree is no longer owned" end
        local plan,problem=self:DismemberPlan(log)
        if plan then
            local rows={}
            for _,job in ipairs(plan) do
                table.insert(rows,string.format("%d/%d/%.2f/%.2f/%.2f",job.ID,job.Depth,job.Section.Size.X,job.Section.Size.Y,job.Section.Size.Z))
            end
            local signature=table.concat(rows,";")
            if signature~=previous then previous=signature stableSince=os.clock() end
            if os.clock()-stableSince>=1 then
                local root,_,_,message=self:ModwoodParts(log)
                if root then return true end
                self:CaptureModwood(log,nil,message)
                return false,message
            end
        else previous=nil stableSince=nil end
        reason=problem or "Waiting for stable branch data"
        self.LoadDiagnostic="Felled wood - "..reason
        token:Sleep(0.2)
    until os.clock()>=deadline
    self:CaptureModwood(log,nil,reason)
    return false,reason
end
local function woodDescription(model,inlet)
    if not model then return "Missing reference" end
    local ok,description=pcall(function()
        local parts={}
        for _,part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") and part.Name=="WoodSection" then
                table.insert(parts,string.format("ID=%s size=%.3f,%.3f,%.3f position=%.2f,%.2f,%.2f inletDistance=%.2f anchored=%s",
                    tostring(value(part,"ID")),part.Size.X,part.Size.Y,part.Size.Z,part.Position.X,part.Position.Y,part.Position.Z,
                    inlet and (part.Position-inlet.Position).Magnitude or -1,tostring(part.Anchored)))
            end
        end
        table.sort(parts)
        return string.format("%s; live=%s; owner=%s; kind=%s; sections=%d\n%s",model:GetFullName(),
            tostring(under(model,S.Workspace)),owned(model) and "LocalPlayer" or tostring(value(model,"Owner")),
            tostring(value(model,"TreeClass")),#parts,table.concat(parts,"\n"))
    end)
    return ok and description or "Reference no longer readable"
end
function H:MillReport(state,job,index)
    local mill,inlet=state.Mill,state.Inlet
    local settings=mill and mill:FindFirstChild("Settings")
    local lines={string.format("Piece %d - %s",index,job.FeedState or "Not started"),
        string.format("feedAttempts=%d; outputCount=%d; inputRemaining=%s; networkOwner=%s; elapsed=%.1fs",
            job.FeedAttempts or 0,#(job.Outputs or {}),tostring(job.InputRemaining),job.NetworkStatus or "Not checked",
            job.MillStarted and os.clock()-job.MillStarted or 0),
        string.format("mill=%s; owned=%s; DimX=%s; DimZ=%s",mill and mill:GetFullName() or "Missing",tostring(mill and owned(mill)),
            tostring(value(settings,"DimX")),tostring(value(settings,"DimZ"))),
        "Input: "..woodDescription(job.Model,inlet)}
    if inlet then
        table.insert(lines,string.format("Inlet: %s; position=%.2f,%.2f,%.2f; size=%.2f,%.2f,%.2f; CanTouch=%s",
            inlet:GetFullName(),inlet.Position.X,inlet.Position.Y,inlet.Position.Z,inlet.Size.X,inlet.Size.Y,inlet.Size.Z,tostring(inlet.CanTouch)))
    end
    for n,output in ipairs(job.Outputs or {}) do table.insert(lines,"Output "..n..": "..woodDescription(output,inlet)) end
    table.insert(lines,"Nearby candidates: "..table.concat(job.CandidateNotes or {}," | "))
    return table.concat(lines,"\n")
end
function H:BuildReport()
    local lines={string.format("Spooky Hunter %s\nCaptured (UTC): %s\nServer: %s\nSlot: %d\nRecent servers: %d/50\nPending wood: %d\nStage: %s\nRunning: %s\nAnti-AFK pulses: %d",
        self.Version,os.date("!%Y-%m-%d %H:%M:%S"),game.JobId,self.Config.Slot,#self.ServerHistory,#self.PendingWood,
        self.Stage,tostring(self.Running),self.IdlePulses or 0)}
    if self.LastFailure then
        table.insert(lines,"Last failure (UTC): "..self.LastFailure.Time.."\nFailed stage: "..self.LastFailure.Stage.."\nReason: "..self.LastFailure.Reason)
    end
    table.insert(lines,string.format("Minimum volume: %d studs3\nHop delay: %ds\nAutomatic recovery: %ss without confirmed progress\nAbandoned tasks: %d\nUI version: %s",
        MIN_TREE_VOLUME,self.Config.HopDelay,STALL_TIMEOUT,self.AbandonedTasks or 0,self.Midnight and self.Midnight.Version or "unavailable"))
    table.insert(lines,"Gameplay base: supplied 1.3.7\nModwood policy: one attempt; leave on failure")
    if self.ServerExitReason then table.insert(lines,"Pending server departure: "..self.ServerExitReason) end
    if self.MoveDiagnostic then table.insert(lines,self.MoveDiagnostic) end
    if self.LoadDiagnostic then table.insert(lines,"Readiness: "..self.LoadDiagnostic) end
    table.insert(lines,"Activity (UTC)\n"..table.concat(self.Logs,"\n"))
    for _,diagnostic in ipairs({self.CutDiagnostic or "",self.ModwoodDiagnostic or "",self.ModwoodRuntimeDiagnostic or ""}) do
        if diagnostic~="" then table.insert(lines,diagnostic) end
    end
    for index,work in ipairs(self.PendingWood) do
        table.insert(lines,"Task "..index.." - "..tostring(work.Kind).." - "..tostring(work.Reason or "In progress"))
        if work.ModwoodAttempted then table.insert(lines,"Modwood attempts: 1 / 1") end
        if work.Modwood then table.insert(lines,"Modwood phase: "..work.Modwood.Phase) end
        if work.Classic then
            table.insert(lines,"Classic milling: "..work.Classic.Phase)
            for piece,job in ipairs(work.Classic.Jobs) do
                table.insert(lines,string.format("Piece %d: section=%s; cutHeight=%s; cutRequests=%d; separated=%s; milled=%s",piece,tostring(job.ID),tostring(job.Height),job.Strikes or 0,tostring(job.Model~=nil),tostring(job.Done==true)))
                if job.SkippedStub then table.insert(lines,"Small attached stub retained for the trunk feed") end
                if job.FailureSnapshot then table.insert(lines,"At interruption:\n"..job.FailureSnapshot) end
                local ok,current=pcall(self.MillReport,self,work.Classic,job,piece)
                table.insert(lines,"Current observation:\n"..(ok and current or "Unavailable"))
            end
        end
    end
    local text=table.concat(lines,"\n\n")
    if self.Config.Webhook~="" then text=text:gsub(self.Config.Webhook:gsub("([^%w])","%%%1"),"[webhook]") end
    return text
end
-- Game Owner is distinct from physics ownership. A positive executor check,
-- when available, is required before changing wood transforms.
function H:AcquireWood(model, part, token, diagnostic, finished)
    diagnostic=diagnostic or {}
    local networkOwner=cap("isnetworkowner",isnetworkowner)
    local drag=self:Remote("Interaction","ClientIsDragging")
    local started=os.clock()
    repeat
        token:Check()
        if finished and finished() then return false end
        assert(livePart(part) and model.Parent and owned(model),"Wood changed while acquiring control")
        local _,_,avatar=self:Character()
        local distance=(avatar.Position-part.Position).Magnitude
        diagnostic.AvatarDistance=distance
        if distance>9 then self:Teleport(part.CFrame+Vector3.new(5,3,0)) end
        if not diagnostic.LastDrag or os.clock()-diagnostic.LastDrag>=0.15 then
            drag:FireServer(model) diagnostic.LastDrag=os.clock()
        end
        if networkOwner then
            local ok,result=pcall(networkOwner,part)
            diagnostic.NetworkStatus=ok and tostring(result) or "Unavailable"
            if ok and result==true then return true end
            if not ok then networkOwner=nil end
        else
            diagnostic.NetworkStatus="Unavailable - proximity only"
        end
        if not networkOwner and os.clock()-started>=0.3 then return true end
        assert(os.clock()-started<6,"Physics ownership not acquired - staying near the wood")
        token:Sleep(0.1)
    until false
end

function H:ActiveWoodFire(section)
    if not livePart(section) then return nil end
    for _,effect in ipairs(section:GetDescendants()) do
        if (effect:IsA("Fire") or effect:IsA("ParticleEmitter")) and effect.Enabled then
            local node=effect
            while node and node~=section do
                if node.Name=="LavaFire" or (node==effect and (effect:IsA("Fire") or effect.Name=="Fire")) then return effect end
                node=node.Parent
            end
        end
    end
    return nil
end

function H:ClassicMill(log,mill,inlet,token,work)
    assert(work,"Classic milling requires a saved task")
    local logs=S.Workspace:FindFirstChild("LogModels")
    local models=S.Workspace:FindFirstChild("PlayerModels")
    assert(logs and models,"Wood containers are unavailable")
    local state=work.Classic
    if not state then
        local jobs,reason=self:DismemberPlan(log)
        assert(jobs,reason)
        state={Phase="Splitting",Log=log,Kind=value(log,"TreeClass"),Mill=mill,Inlet=inlet,Outputs={},SeenOutput={},
            Jobs=jobs}
        work.Classic=state
        self:Log("Using standard milling - "..#jobs.." sections")
    end
    assert(state.Mill==mill and state.Inlet==inlet,"Retry with the original sawmill")
    local function check()
        token:Check()
        assert(mill and mill.Parent and owned(mill) and inlet and inlet.Parent,"The selected sawmill is unavailable")
    end
    check()
    local proxy=self:Remote("Interaction","RemoteProxy")
    if state.Phase=="Splitting" then
        local tool,stats=self:EnsureAxe(state.Kind,token)
        for index,job in ipairs(state.Jobs) do
            -- Small terminal stubs stay on the trunk and enter the mill with it.
            -- Do not spend the entire cut timeout striking a 0.2-stud remnant.
            if not job.Model and job.ID~=1 and livePart(job.Section) and job.Section.Size.Y<=0.35 then
                job.SkippedStub=true job.Done=true
            end
            if not job.Model and not job.SkippedStub then
                self:SetStage("Separating wood",0.5+0.1*index/#state.Jobs,"Piece "..index.." / "..#state.Jobs)
                job.Height=job.Height or math.min(0.3,job.Section.Size.Y/2)
                if not job.Before then
                    job.Before={}
                    for _,model in ipairs(logs:GetChildren()) do job.Before[model]=true end
                    job.Origin=job.Section.Position job.Strikes=0
                    job.OriginalSize=job.Section.Size
                end
                local deadline=os.clock()+self.Config.ChopTimeout
                local candidate,since
                repeat
                    check()
                    local matches={}
                    local originalSize=job.OriginalSize or job.Section.Size
                    local expectedHeight=math.max(0.02,(job.OriginalHeight or originalSize.Y)-job.Height)
                    for _,model in ipairs(logs:GetChildren()) do
                        if model~=state.Log and owned(model) and value(model,"TreeClass")==state.Kind then
                            for _,part in ipairs(model:GetDescendants()) do
                                if part:IsA("BasePart") and part.Name=="WoodSection" then
                                    local same=part==job.Section
                                    local shape=math.abs(part.Size.X-originalSize.X)<=math.max(.08,originalSize.X*.12)
                                        and math.abs(part.Size.Z-originalSize.Z)<=math.max(.08,originalSize.Z*.12)
                                        and part.Size.Y>=expectedHeight*.65 and part.Size.Y<=expectedHeight*1.35+.1
                                    local near=(part.Position-job.Origin).Magnitude<math.max(25,originalSize.Y+8)
                                    if same or (not job.Before[model] and shape and near) then
                                        table.insert(matches,model) break
                                    end
                                end
                            end
                        end
                    end
                    job.CandidateCount=#matches
                    if #matches==1 then
                        if candidate~=matches[1] then candidate=matches[1] since=os.clock() end
                        if os.clock()-since>=0.35 then job.Model=candidate break end
                    else candidate=nil since=nil end
                    local section=job.Section
                    if livePart(section) and under(section,state.Log) and section.Size.Y>job.Height+0.001 and #matches==0 then
                        local source=section:FindFirstAncestorOfClass("Model")
                        while source and not source:FindFirstChild("Owner") do source=source:FindFirstAncestorOfClass("Model") end
                        assert(source and owned(source),"Selected wood changed owner")
                        local event=source:FindFirstChild("CutEvent")
                        assert(event,"The selected wood has no CutEvent")
                        if tool.Parent~=Player.Character then tool,stats=self:EnsureAxe(state.Kind,token) end
                        self:AcquireWood(source,section,token,job)
                        self:Teleport(CFrame.lookAt(section.Position+Vector3.new(5,0,0),section.Position))
                        if not job.Approached then token:Sleep(0.35) job.Approached=true end
                        if not job.LastStrike or os.clock()-job.LastStrike>=math.max(0.1,stats.SwingCooldown)+0.05 then
                            token:Check()
                            assert(livePart(section) and under(section,source) and event.Parent==source,
                                "Cut target changed while acquiring control")
                            if section.Size.Y<=job.Height+0.001 then
                                token:Sleep(0.1)
                            else
                            if tool.Parent~=Player.Character then tool,stats=self:EnsureAxe(state.Kind,token) end
                            job.Origin=section.Position job.LastStrike=os.clock() job.Strikes=job.Strikes+1
                            self:FireAxe(proxy,event,{tool=tool,sectionId=tonumber(value(section,"ID")) or job.ID,height=job.Height,faceVector=Vector3.new(-1,0,0),
                                hitPoints=stats.Damage,cooldown=stats.SwingCooldown,cuttingClass="Axe"})
                            end
                        end
                    end
                    token:Sleep(0.1)
                until os.clock()>=deadline
                if not job.Model then
                    job.FailureSnapshot=string.format("Separation: section=%s; strikes=%d; candidates=%d; live=%s; height=%.3f; network=%s; distance=%s",
                        tostring(job.ID),job.Strikes or 0,job.CandidateCount or 0,tostring(livePart(job.Section)==true),
                        job.Section.Size.Y,tostring(job.NetworkStatus or "not requested"),tostring(job.AvatarDistance))
                    error("Piece separation not confirmed - "..job.FailureSnapshot,0)
                end
                self:Log("Piece "..index.." separated")
            end
        end
        state.Phase="Milling"
    end
    local drag=self:Remote("Interaction","ClientIsDragging")
    for index,job in ipairs(state.Jobs) do
        if not job.Done then
            check()
            local piece=job.Model
            if not job.BeforeOutput then
                assert(piece and piece.Parent and owned(piece),"A separated piece is missing")
                job.Sections={}
                for _,part in ipairs(piece:GetDescendants()) do
                    if part:IsA("BasePart") and part.Name=="WoodSection" then table.insert(job.Sections,part) end
                end
                local mainCount,largest=0,-1
                for _,part in ipairs(job.Sections) do
                    if part.Size.Y>0.35 then mainCount=mainCount+1 end
                    local volume=part.Size.X*part.Size.Y*part.Size.Z
                    if volume>largest then largest=volume job.FeedSection=part end
                end
                assert(mainCount<=1 and job.FeedSection,"The separated piece still has large branches - wood kept for inspection")
                job.BeforeOutput={} job.Outputs={}
                for _,model in ipairs(models:GetChildren()) do job.BeforeOutput[model]=true end
            end
            self:SetStage("Milling wood",0.64+0.14*index/#state.Jobs,"Piece "..index.." / "..#state.Jobs)
            local deadline=os.clock()+self.Config.MillTimeout
            job.MillStarted=os.clock() job.FeedAttempts=0 job.NextFeed=0
            -- Upgrade paused 1.3.3/1.3.4 tasks without recutting their pieces.
            if not job.FeedSection then
                for _,part in ipairs(job.Sections) do if livePart(part) and part.Size.Y>0.35 then job.FeedSection=part break end end
            end
            token:Finally(function()
                if not job.Done then
                    local ok,report=pcall(self.MillReport,self,state,job,index)
                    if ok then job.FailureSnapshot=report end
                end
            end)
            local signature,stableSince
            local nextReport=0
            repeat
                check()
                job.CandidateNotes={}
                for _,model in ipairs(models:GetChildren()) do
                    if not job.BeforeOutput[model] and #job.CandidateNotes<8 then
                        local part=model:FindFirstChild("WoodSection",true)
                        if part and part:IsA("BasePart") and (part.Position-inlet.Position).Magnitude<50 then
                            table.insert(job.CandidateNotes,string.format("%s owner=%s kind=%s distance=%.1f",model.Name,
                                owned(model) and "LocalPlayer" or tostring(value(model,"Owner")),tostring(value(model,"TreeClass")),(part.Position-inlet.Position).Magnitude))
                        end
                    end
                    if not job.BeforeOutput[model] and not state.SeenOutput[model] and owned(model)
                        and value(model,"TreeClass")==state.Kind then
                        local part=model:FindFirstChild("WoodSection",true)
                        if part and part:IsA("BasePart") and (part.Position-inlet.Position).Magnitude<30 then
                            state.SeenOutput[model]=true
                            table.insert(job.Outputs,model) table.insert(state.Outputs,model)
                        end
                    end
                end
                local remaining=0
                for _,part in ipairs(job.Sections) do
                    local ownerModel=part.Parent and part:FindFirstAncestorOfClass("Model")
                    if livePart(part) and ownerModel and under(ownerModel,logs) and not state.SeenOutput[ownerModel] then remaining=remaining+1 end
                end
                job.InputRemaining=remaining
                local dims={}
                for _,output in ipairs(job.Outputs) do
                    assert(output.Parent and owned(output),"Sawmill output is missing or changed owner")
                    for _,part in ipairs(output:GetDescendants()) do
                        if part:IsA("BasePart") and part.Name=="WoodSection" then
                            table.insert(dims,string.format("%.5f,%.5f,%.5f",part.Size.X,part.Size.Y,part.Size.Z))
                        end
                    end
                end
                table.sort(dims)
                local current=table.concat(dims,";")
                if current~=signature then signature=current stableSince=os.clock() end
                if #job.Outputs>0 and #dims>0 and remaining==0 and os.clock()-stableSince>=2 then
                    job.Done=true job.FeedState="Complete" self:Log("Piece "..index.." milled") break
                end
                if #job.Outputs>0 then
                    job.FeedState=remaining>0 and "Output started; input not consumed" or "Output stabilizing"
                elseif remaining==0 then
                    job.FeedState="Input consumed; waiting for output"
                else
                    job.FeedState="Waiting for sawmill acceptance"
                end
                if os.clock()>=nextReport then
                    nextReport=os.clock()+10
                    self:Log(string.format("Mill piece %d - %s; feeds=%d; input=%d; outputs=%d",index,job.FeedState,
                        job.FeedAttempts,remaining,#job.Outputs),"DEBUG")
                end
                -- Bounded placement bursts, followed by a quiet processing window.
                -- Never drag an input that already has a corresponding output.
                if #job.Outputs==0 and remaining>0 and os.clock()>=job.NextFeed and job.FeedAttempts<3 then
                    assert(under(piece,logs) and owned(piece),"The separated wood changed owner or container")
                    local part=job.FeedSection
                    assert(livePart(part) and under(part,piece),"The input section is no longer available")
                    job.FeedAttempts=job.FeedAttempts+1
                    self:Teleport(part.CFrame+Vector3.new(0,3,5))
                    token:Sleep(0.25)
                    local networkOwner=cap("isnetworkowner",isnetworkowner)
                    local ready=networkOwner==nil
                    job.NetworkStatus=ready and "Unavailable" or "False"
                    for _=1,8 do
                        check()
                        if not livePart(part) or not under(piece,logs) then break end
                        assert(owned(piece),"Input ownership changed during acquisition")
                        drag:FireServer(piece)
                        token:Sleep(0.1)
                        if networkOwner then
                            local ok,result=pcall(networkOwner,part)
                            if not ok then job.NetworkStatus="Unavailable" ready=true
                            else job.NetworkStatus=tostring(result) ready=result==true end
                        end
                        if ready then break end
                    end
                    if ready and livePart(part) and under(piece,logs) then
                        work.AtBase=false
                        local relative=piece:GetPivot():ToObjectSpace(part.CFrame)
                        -- Standard milling uses the inlet center, without Modwood's offset.
                        local destination=inlet.CFrame*relative:Inverse()
                        for _=1,3 do
                            check()
                            if not livePart(part) or not under(piece,logs) then break end
                            assert(owned(piece),"Input ownership changed during placement")
                            piece:PivotTo(destination)
                            part.AssemblyLinearVelocity=Vector3.zero part.AssemblyAngularVelocity=Vector3.zero
                            self:Teleport(inlet.CFrame+Vector3.new(0,3,6))
                            token:Sleep(0.1)
                        end
                    end
                    job.NextFeed=os.clock()+8
                end
                token:Sleep(0.1)
            until os.clock()>=deadline
            if not job.Done then
                job.FailureSnapshot=self:MillReport(state,job,index)
                local reason
                if #(job.Outputs or {})==0 then
                    reason=(job.InputRemaining or 0)>0 and "input not accepted by the sawmill" or "input consumed but no matching plank found"
                elseif (job.InputRemaining or 0)>0 then reason="plank detected but input remains"
                else reason="plank dimensions did not stabilize" end
                error("Piece "..index.." - "..reason.."; retry resumes this piece",0)
            end
        end
    end
    state.Phase="Complete"
    return state.Outputs
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
function H:Modwood(log, mill, inlet, token, checkpoint)
    checkpoint=checkpoint or {}
    local previous=self.ModwoodAttempts[log]
    if previous and previous.Complete then return previous.Outputs end
    assert(not self.ServerExitReason,"This server must be left before another Modwood attempt")
    if previous or checkpoint.ModwoodAttempted or checkpoint.Modwood then
        self.ServerExitReason="Modwood already attempted in this server"
        self:Persist(false)
        error(self.ServerExitReason,0)
    end
    token:Check()
    -- Persist the fence before the first manipulation. Stop, reload and a
    -- failed teleport cannot accidentally launch this tree's Modwood again.
    self.ServerExitReason="Modwood was interrupted"
    local saved,message=self:Persist(false)
    assert(saved,message)
    local attempt={Started=os.clock()}
    self.ModwoodAttempts[log]=attempt
    checkpoint.ModwoodAttempted=true
    local ok,result=pcall(self.PerformModwood,self,log,mill,inlet,token,checkpoint)
    if not ok then
        attempt.Failed=true
        self.ServerExitReason=result==CANCEL and "Modwood was interrupted" or cleanError(result)
        checkpoint.Reason=self.ServerExitReason
        self:Persist(false)
        error(result,0)
    end
    attempt.Complete=true attempt.Outputs=result
    self.ServerExitReason=nil
    local persisted,problem=self:Persist(false)
    if not persisted then self:Log(problem,"WARNING") end
    return result
end
function H:PerformModwood(log, mill, inlet, token, checkpoint)
    checkpoint = checkpoint or {}
    local state = checkpoint.Modwood
    assert(mill and mill.Parent and owned(mill) and inlet and inlet.Parent, "The selected sawmill is unavailable")
    local logs = S.Workspace:FindFirstChild("LogModels")
    local playerModels = S.Workspace:FindFirstChild("PlayerModels")
    assert(logs and playerModels, "Wood containers are unavailable")
    if not state then
        assert(log and log.Parent and owned(log), "Modwood requires your felled wood")
        local root, leaf, parent, reason = self:ModwoodParts(log)
        self:CaptureModwood(log, mill, reason or "Selected")
        assert(root, reason)
        state = {Phase="Prepared", Log=log, Mill=mill, Inlet=inlet, Root=root, Leaf=leaf, Parent=parent,
            ParentContainer=parent.Parent, Kind=value(log,"TreeClass"), Pivot=log:GetPivot(),
            RootFrame=root.CFrame, LeafFrame=leaf.CFrame, ParentFrame=parent.CFrame,
            RootID=value(root,"ID"),LeafID=value(leaf,"ID"),ParentID=value(parent,"ID"),
            OriginalSections={}, BeforeOutput={}, Outputs={}, SeenOutput={}, FreezeFrames=0}
        for _, part in ipairs(log:GetDescendants()) do
            if part:IsA("BasePart") and part.Name=="WoodSection" then table.insert(state.OriginalSections,part) end
        end
        for _, model in ipairs(playerModels:GetChildren()) do state.BeforeOutput[model]=true end
        checkpoint.Modwood = state
        self:Log(string.format("Modwood selected - leaf %s / parent %s / %s",
            tostring(value(leaf,"ID")),tostring(value(parent,"ID")),mill.Name),"DEBUG")
    end
    state.SourceRevision="1.3.7-calm"
    assert(state.Mill==mill and state.Inlet==inlet, "Keep the original sawmill selected when retrying Modwood")
    self.ModwoodSelection = {Wood=state.Log, Sawmill=mill, Leaf=state.Leaf, Parent=state.Parent}
    log = state.Log
    local root, leaf, parent = state.Root, state.Leaf, state.Parent
    state.RootID=state.RootID or value(root,"ID")
    state.LeafID=state.LeafID or value(leaf,"ID")
    state.ParentID=state.ParentID or value(parent,"ID")
    local function snapshot(reason)
        local lines={"Modwood runtime - "..reason,"Phase: "..state.Phase,
            "Ignition observed: "..tostring(state.IgnitionObserved==true)}
        for _,item in ipairs({{"Root",root,state.RootID},{"Retained branch",leaf,state.LeafID},{"Burn parent",parent,state.ParentID}}) do
            local part=item[2]
            table.insert(lines,string.format("%s: ID=%s; live=%s; parent=%s; size=%.3f,%.3f,%.3f",
                item[1],tostring(item[3]),tostring(livePart(part)==true),part.Parent and part.Parent:GetFullName() or "Removed",
                part.Size.X,part.Size.Y,part.Size.Z))
        end
        state.Diagnostic=table.concat(lines,"\n")
        self.ModwoodRuntimeDiagnostic=state.Diagnostic
    end
    local function requireLive(part,name)
        if not livePart(part) then
            snapshot(name.." disappeared")
            error("Modwood - "..name.." disappeared; no trigger cut sent",0)
        end
    end
    token:Finally(function() snapshot("Task cleanup") end)
    local drag = self:Remote("Interaction", "ClientIsDragging")
    -- These three frames are explicitly present in Pasted text(7).txt.
    local burnFrame=CFrame.new(-1665.86548,355.800415,1478.47742)
    local stageFrame=CFrame.new(-904,150,-3396)
    local disposalFrame=CFrame.new(315,5,85.4999924)
    local character,_,avatar=self:Character()
    local avatarFrame,avatarAnchored=avatar.CFrame,avatar.Anchored==true
    local function releaseHover()
        if avatar.Parent then avatar.Anchored=avatarAnchored end
    end
    local function moveAvatar(frame)
        if (avatar.Position-frame.Position).Magnitude>1.5 then self:Teleport(frame) end
        avatar.Anchored=true
    end
    token:Finally(function()
        releaseHover()
        if Player.Character==character and avatar.Parent then pcall(self.Teleport,self,avatarFrame) end
    end)
    local function checkMill()
        token:Check()
        assert(mill.Parent and owned(mill) and inlet.Parent, "The selected sawmill disappeared or changed owner")
    end
    local function freeze(part, frame)
        if part.Parent then
            part.AssemblyLinearVelocity=Vector3.zero
            part.AssemblyAngularVelocity=Vector3.zero
            part.CFrame=frame
            part.AssemblyLinearVelocity=Vector3.zero
            part.AssemblyAngularVelocity=Vector3.zero
        end
    end
    local nextDrag=0
    local function refreshDrag()
        if os.clock()>=nextDrag then drag:FireServer(log) nextDrag=os.clock()+0.2 end
    end
    local heldFrame
    local function holdTree(frame)
        assert(log.Parent and owned(log), "The selected log disappeared or changed owner")
        local focus=livePart(parent) and under(parent,log) and parent or root
        self:DampWood(log)
        if heldFrame~=frame or (log:GetPivot().Position-frame.Position).Magnitude>0.4 then
            local relative=log:GetPivot():ToObjectSpace(focus.CFrame)
            moveAvatar(frame*relative+Vector3.new(5,3,0))
            refreshDrag()
            log:PivotTo(frame)
            heldFrame=frame
        else
            moveAvatar(focus.CFrame+Vector3.new(5,3,0))
            refreshDrag()
        end
        self:DampWood(log)
    end
    local restoreCollision=self:QuietWood(log,token)
    local tool, stats
    if state.Phase~="Output" then tool,stats=self:EnsureAxe(state.Kind,token) end
    if state.Phase=="Prepared" then
        requireLive(root,"root") requireLive(leaf,"retained branch") requireLive(parent,"burn parent")
        assert(under(root,log) and under(parent,log) and under(leaf,log),"Modwood - selected sections no longer belong to this log")
        local lava=self:FindLava()
        local lavaFrame,lavaSize,restored=lava.CFrame,lava.Size,false
        local function restoreLava()
            if restored then return end
            if livePart(lava) then lava.CFrame=lavaFrame lava.Size=lavaSize end
            restored=true
        end
        token:Finally(restoreLava)
        local observing=true
        local function observeFire(child)
            if not observing or child.Name~="LavaFire" or not under(child,parent) then return end
            state.IgnitionObserved=true state.Phase="Ignited"
            -- Remove contact immediately; polling must not keep burning a part
            -- after the server has already acknowledged ignition.
            restoreLava()
        end
        local fireConnection=parent.ChildAdded:Connect(observeFire)
        token:Finally(function() observing=false fireConnection:Disconnect() end)
        local fire=parent:FindFirstChild("LavaFire")
        if fire then observeFire(fire) end
        self:SetStage("Modwood - igniting parent section",0.52,"Waiting for LavaFire")
        if not state.IgnitionObserved then
            self:AcquireWood(log,parent,token,state,function() return state.IgnitionObserved==true end)
            token:Sleep(0.3)
        end
        local deadline=os.clock()+math.min(15,self.Config.BurnTimeout)
        while not state.IgnitionObserved do
            checkMill()
            requireLive(root,"root") requireLive(leaf,"retained branch") requireLive(parent,"burn parent")
            requireLive(lava,"lava contact")
            assert(under(root,log) and under(parent,log) and under(leaf,log),"Modwood - selected geometry left the original log before ignition")
            assert(os.clock()<deadline,"Modwood - no LavaFire detected; changing server")
            checkpoint.AtBase=false
            holdTree(burnFrame)
            lava.Size=Vector3.zero lava.CFrame=parent.CFrame
            fire=parent:FindFirstChild("LavaFire")
            if fire then observeFire(fire) end
            if not state.IgnitionObserved then token:Sleep(0.1) end
            fire=parent:FindFirstChild("LavaFire")
            if fire then observeFire(fire) end
        end
        observing=false fireConnection:Disconnect() restoreLava()
        snapshot("Ignition confirmed")
    end
    if state.Phase=="Ignited" then
        -- Observe before the 30 transfer frames: separation can happen there.
        requireLive(root,"root") requireLive(leaf,"retained branch")
        state.ParentSeparated=state.ParentSeparated or not livePart(parent) or parent.Parent~=state.ParentContainer
        local ancestry=parent.AncestryChanged:Connect(function()
            if not livePart(parent) or parent.Parent~=state.ParentContainer then state.ParentSeparated=true end
        end)
        token:Finally(function() ancestry:Disconnect() end)
        local fire=parent:FindFirstChild("LavaFire")
        if fire then fire:Destroy() end
        self:SetStage("Modwood - stabilizing selected tree",0.57,"Moving to the source staging position")
        while state.FreezeFrames<30 do
            checkMill()
            requireLive(root,"root") requireLive(leaf,"retained branch")
            holdTree(stageFrame)
            state.FreezeFrames=state.FreezeFrames+1
            token:Sleep(0.08)
        end
        self:SetStage("Modwood - waiting for parent separation",0.6,"Removing the burned parent section")
        if livePart(parent) then moveAvatar(parent.CFrame+Vector3.new(0,4,6)) end
        local deadline=os.clock()+self.Config.BurnTimeout
        while not state.ParentSeparated and parent.Parent==state.ParentContainer do
            checkMill()
            requireLive(root,"root") requireLive(leaf,"retained branch")
            assert(os.clock()<deadline,"Modwood - parent did not separate before timeout")
            assert(log.Parent and owned(log),"Modwood - selected wood ownership changed")
            drag:FireServer(log)
            freeze(parent,disposalFrame)
            drag:FireServer(log)
            self:DampWood(log)
            token:Sleep(0.12)
        end
        ancestry:Disconnect()
        requireLive(root,"root") requireLive(leaf,"retained branch")
        state.RootFrame=root.CFrame
        state.Phase="Separated"
    end
    if state.Phase=="Separated" then
        state.BeforeLogs={}
        for _, model in ipairs(logs:GetChildren()) do state.BeforeLogs[model]=true end
        state.Phase="Feeding"
    end
    if state.Phase=="Triggering" then state.Phase="Feeding" end
    if state.Phase=="Feeding" then
        releaseHover()
        restoreCollision()
        self:SetStage("Modwood - triggering conversion",0.7,"Cutting the selected wood and feeding its branch")
        local proxy=self:Remote("Interaction","RemoteProxy")
        local deadline=os.clock()+self.Config.ChopTimeout
        local candidate, candidateSince
        local triggerReadyAt=os.clock()+0.25
        state.ObservedLogs=state.ObservedLogs or {}
        local observed=logs.ChildAdded:Connect(function(model) state.ObservedLogs[model]=true end)
        token:Finally(function() observed:Disconnect() end)
        repeat
            checkMill()
            -- Unlike the source's broad Owner-only listener, require a new log
            -- of the selected species close to this tree or this sawmill.
            local matches={}
            local candidates={}
            for _,model in ipairs(logs:GetChildren()) do candidates[model]=true end
            for model in pairs(state.ObservedLogs) do candidates[model]=true end
            for model in pairs(candidates) do
                if model.Parent and not state.BeforeLogs[model] and owned(model) and value(model,"TreeClass")==state.Kind then
                    local near=false
                    for _,section in ipairs(model:GetDescendants()) do
                        if section:IsA("BasePart") and section.Name=="WoodSection" then
                            near=near or (section.Position-(state.LastCutPosition or state.RootFrame.Position)).Magnitude<60
                                or (section.Position-inlet.Position).Magnitude<60 or section==leaf
                        end
                    end
                    if near then table.insert(matches,model) end
                end
            end
            assert(#matches<2,"Modwood - several replacement logs appeared; conversion is ambiguous")
            if #matches==1 then
                if candidate~=matches[1] then candidate=matches[1] candidateSince=os.clock() end
                if os.clock()-candidateSince>=0.25 then
                    state.Transformed=candidate state.TransformedSections={}
                    for _, part in ipairs(candidate:GetDescendants()) do
                        if part:IsA("BasePart") and part.Name=="WoodSection" then table.insert(state.TransformedSections,part) end
                    end
                    assert(#state.TransformedSections>0,"Modwood - replacement log has no wood sections")
                    state.Phase="Output"
                    self:Log("Modwood transformation detected - new owned log","INFO","Wood accepted")
                    break
                end
            else candidate=nil candidateSince=nil end
            if under(log,S.Workspace) and livePart(root) and livePart(leaf) and under(root,log)
                and tonumber(value(root,"ID"))==1 and root.Size.Y>0.35 and not candidate then
                assert(owned(log),"Modwood - selected log ownership changed")
                local ownerModel=leaf:FindFirstAncestorOfClass("Model")
                while ownerModel and ownerModel~=log and not owned(ownerModel) do
                    ownerModel=ownerModel:FindFirstAncestorOfClass("Model")
                end
                assert(ownerModel and owned(ownerModel),"Modwood - retained branch ownership changed")
                -- The supplied routine feeds the retained branch while it
                -- repeatedly cuts the original log. The newly-added LogModels
                -- object is only the server acknowledgement of this operation.
                drag:FireServer(log)
                if ownerModel~=log then drag:FireServer(ownerModel) end
                freeze(leaf,inlet.CFrame+Vector3.new(0.7,0,0))
                self:Teleport(root.CFrame+Vector3.new(5,0,0))
                state.LastCutPosition=root.Position
                if os.clock()>=triggerReadyAt and (not state.LastStrike or os.clock()-state.LastStrike>=math.max(stats.SwingCooldown,0.1)+0.05) then
                    local event=log:FindFirstChild("CutEvent")
                    assert(event and event.Parent==log,"Modwood - selected log has no CutEvent")
                    assert(livePart(root) and under(root,log) and root.Size.Y>0.35,"Modwood - root changed before the trigger cut")
                    assert(tool.Parent==Player.Character,"The equipped axe changed")
                    state.LastStrike=os.clock()
                    self:FireAxe(proxy,event,{tool=tool,sectionId=1,height=0.3,faceVector=Vector3.new(-1,0,0),
                        hitPoints=stats.Damage,cooldown=stats.SwingCooldown,cuttingClass="Axe"})
                end
            end
            token:Sleep(0.1)
        until os.clock()>=deadline
        observed:Disconnect()
        if state.Phase~="Output" then snapshot("Trigger not confirmed") end
        assert(state.Phase=="Output","Modwood - trigger timed out without a matching new owned log")
    end
    if state.Phase=="Output" then
        self:Log("Modwood - branch accepted; waiting for sawmill output","DEBUG")
        self:Teleport(inlet.CFrame+Vector3.new(0,4,8))
    end
    self:SetStage("Modwood - waiting for sawmill output",0.78,"Waiting for finished planks")
    local deadline=os.clock()+self.Config.MillTimeout
    local stableSince, outputVolume, outputParts, outputDimensions
    repeat
        checkMill()
        for _, model in ipairs(playerModels:GetChildren()) do
            local section=model:FindFirstChild("WoodSection")
            if not state.BeforeOutput[model] and not state.SeenOutput[model] and owned(model)
                and value(model,"TreeClass")==state.Kind and section and section:IsA("BasePart")
                and (section.Position-inlet.Position).Magnitude<65 then
                state.SeenOutput[model]=true table.insert(state.Outputs,model) stableSince=os.clock()
            end
        end
        local remaining=0
        local function countRemaining(sections)
            for _, section in ipairs(sections) do
                local ownerModel=section.Parent and section:FindFirstAncestorOfClass("Model")
                -- The source strikes at height 0.3. A remaining cut stump is
                -- distinct from a full trunk and cannot be fed as the whole tree.
                local cutStump=section==root and section.Size.Y<=0.35
                if section.Parent and not cutStump and not (ownerModel and state.SeenOutput[ownerModel]) then
                    remaining=remaining+1
                end
            end
        end
        countRemaining(state.OriginalSections)
        countRemaining(state.TransformedSections or {})
        local volume,parts,dimensions=0,0,{}
        for _, plank in ipairs(state.Outputs) do
            assert(plank.Parent and owned(plank),"Sawmill output disappeared or changed owner")
            for _, section in ipairs(plank:GetDescendants()) do
                if section:IsA("BasePart") and section.Name=="WoodSection" then
                    parts=parts+1 volume=volume+section.Size.X*section.Size.Y*section.Size.Z
                    table.insert(dimensions,string.format("%.5f,%.5f,%.5f",section.Size.X,section.Size.Y,section.Size.Z))
                end
            end
        end
        table.sort(dimensions)
        local signature=table.concat(dimensions,";")
        if volume~=outputVolume or parts~=outputParts or signature~=outputDimensions then stableSince=os.clock() end
        outputVolume,outputParts,outputDimensions=volume,parts,signature
        if #state.Outputs>0 and remaining==0 and volume>0 and stableSince and os.clock()-stableSince>2 then
            return state.Outputs
        end
        token:Sleep(0.06)
    until os.clock()>=deadline
    error("Modwood - whole-tree conversion or finished output not confirmed; wood left in this server",0)
end
function H:Deliver(planks, center, token, checkpoint)
    local remaining = {}
    if checkpoint then checkpoint.Delivered = checkpoint.Delivered or {} end
    for _, plank in ipairs(planks) do
        if not checkpoint or not checkpoint.Delivered[plank] then table.insert(remaining, plank) end
    end
    for _, plank in ipairs(remaining) do
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
        self.UnsavedDelivery=true
        if checkpoint then checkpoint.Delivered[plank] = true end
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
    self.UnsavedDelivery=false
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
    self:Log("Webhook delivered","DEBUG")
end
function H:TryWebhook(title, description, token, receipt)
    local ok, err = pcall(self.SendWebhook, self, title, description, token, receipt)
    if not ok then
        if err == CANCEL then error(CANCEL, 0) end
        token:Check()
        self:Log("Webhook unavailable - " .. cleanError(err), "WARNING")
    end
    return ok
end
function H:Servers(token)
    assert(type(Request) == "function", "An HTTP request function is required for server search")
    local cursor, servers, ids, cursors = nil, {}, {}, {}
    for _ = 1, 10 do
        local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100"
        if cursor then url = url .. "&cursor=" .. S.HttpService:UrlEncode(cursor) end
        local response, lastError
        for attempt = 1, 3 do
            local ok, result = pcall(function()
                return token:Await(function()
                    local sent, r = pcall(Request,{Url=url,Method="GET"})
                    assert(sent and type(r)=="table","Server-list transport failed") return r
                end,15)
            end)
            if not ok and result == CANCEL then error(CANCEL, 0) end
            token:Check()
            local code = ok and tonumber(result.StatusCode or result.Status)
            if code == 200 then response = result break end
            lastError = code and ("Server list HTTP "..code) or "Server-list connection failed"
            if code and code ~= 429 and code < 500 then error(lastError,0) end
            if attempt < 3 then token:Sleep(attempt*2) end
        end
        assert(response, lastError)
        local data = S.HttpService:JSONDecode(response.Body)
        assert(type(data)=="table" and type(data.data)=="table","Unexpected server-list response")
        for _, server in ipairs(data.data) do
            if type(server)=="table" and type(server.id)=="string" and server.id~="" and server.id~=game.JobId
                and not ids[server.id] and finite(server.playing) and finite(server.maxPlayers)
                and server.playing>=0 and server.playing<server.maxPlayers and not self.Visited[server.id]
                and (not self.FailedServers[server.id] or self.FailedServers[server.id]<=os.time()) then
                ids[server.id]=true table.insert(servers,server.id)
            end
        end
        if #servers >= 15 or type(data.nextPageCursor)~="string" or data.nextPageCursor==""
            or cursors[data.nextPageCursor] then break end
        cursor=data.nextPageCursor cursors[cursor]=true token:Sleep(0.2)
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
    return "local deadline=os.clock()+300;repeat task.wait(0.2) until game:IsLoaded() or os.clock()>=deadline;if not game:IsLoaded() then return end;local ok,d=pcall(function() return game:GetService('HttpService'):JSONDecode(readfile('"..FILE.."')) end);"
        .. "if not ok or not d.Resume or d.Target~=game.JobId or os.time()-(d.TicketTime or 0)>600 then return end;"
        .. "local env=type(getgenv)=='function' and getgenv() or _G;if env.MidnightSpookyBootServer==game.JobId then return end;"
        .. "env.MidnightSpookyBootServer=game.JobId;env.MidnightSpookyResume=true;" .. loader
end
function H:Hop(token)
    assert(not self.Dirty, "Unfinished wood is still in this server")
    self.Watchdog=false
    local bootstrap=self:Bootstrap()
    self:RememberServer(game.JobId)
    local stored, storeError = self:Persist(false) assert(stored, storeError)
    local leaveAt = os.clock() + self.Config.HopDelay
    self:SetStage("Next server",0.98,"Preparing the next server")
    repeat
        if self.UI then self.UI.Progress:SetText("Next server","Joining in "..math.ceil(math.max(0,leaveAt-os.clock())).."s") end
        token:Sleep(math.min(1, math.max(0,leaveAt-os.clock())))
    until os.clock()>=leaveAt
    local servers
    for round=1,3 do
        self:SetStage("Finding another server",0.98,"Recent servers excluded: "..#self.ServerHistory.." / 50")
        servers=self:Servers(token)
        if #servers>0 then break end
        if round<3 then
            self:SetStage("Waiting for available servers",0.98,"Refreshing in "..(round*10).."s")
            token:Sleep(round*10)
        end
    end
    assert(#servers>0,"No eligible server available - recent-server history was preserved")
    for i=1,math.min(#servers,8) do
        token:Check()
        local id=servers[i]
        self.FailedServers[id]=os.time()+600
        local saved,err=self:Persist(true,id) assert(saved,err)
        -- Executors differ on whether a failed teleport consumes the queue.
        -- Requeue each attempt; the bootstrap permits only one launch per server.
        local queued=pcall(Queue,bootstrap) assert(queued,"Could not queue continuation")
        local attempt={Id=id} self.HopAttempt=attempt
        self.PendingTeleportTarget=id
        self:SetStage("Joining another server",1,"Attempt "..i)
        local ok=pcall(S.TeleportService.TeleportToPlaceInstance,S.TeleportService,game.PlaceId,id,Player)
        if not ok then attempt.Error="Teleport request rejected" end
        local deadline=os.clock()+35
        while not attempt.Error and os.clock()<deadline do token:Sleep(0.2) end
        self.HopAttempt=nil
        if not attempt.Error then self.HopUncertain=true error("Teleport outcome unknown - no second request sent",0) end
        self:Log(attempt.Error,"WARNING") token:Sleep(4)
    end
    error("No server could be joined",0)
end
function H:Run(token)
    if self.ServerExitReason then return self:LeaveStalledServer(token,self.ServerExitReason) end
    assert(game.PlaceId==13822889,"This script targets Lumber Tycoon 2 (13822889)")
    assert(not S.Workspace.StreamingEnabled,"Streaming is enabled - a complete tree scan cannot be confirmed")
    self:WaitForGame(token)
    self:Bootstrap()
    local resuming = #self.PendingWood>0
    if self.Dirty and not resuming then
        self.NeedsAttention=true
        return "An interrupted cut needs inspection before another hunt can start"
    end
    self:RememberServer(game.JobId)
    if self.LastCountedServer~=game.JobId then
        self.Stats.Servers=self.Stats.Servers+1 self.LastCountedServer=game.JobId
    end
    local saved,saveError=self:Persist(false) assert(saved,saveError)
    self.CanRecover=not resuming
    local entries, plot = {}, nil
    if resuming then
        local receipt=self.LoadReceipt
        if not receipt or receipt.Slot~=self.Config.Slot or receipt.JobId~=game.JobId or receipt.Plot~=self:Plot() then
            self.NeedsAttention=true
            return "The saved task no longer matches the loaded plot"
        end
        plot=receipt.Plot
        token.Character=self:Character()
        for _,work in ipairs(self.PendingWood) do
            if work.Cut and not work.Log then work.Log=self:FindFelledLog(work.Cut) end
            if not work.Planks and not work.Modwood and not work.Classic and not work.Cut and (not work.Log or not work.Log.Parent or not owned(work.Log)) then
                self.NeedsAttention=true
                return "An interrupted cut has no confirmed owned log - inspect this server before continuing"
            end
            table.insert(entries,{Model=work.Log,Kind=work.Kind,Work=work})
        end
        self:SetStage("Resuming unfinished wood",0.42,tostring(#entries).." tasks")
    else
        entries=self:ScanReady(token)
        if #entries==0 then self:SetStage("No rare tree found",0.1) return self:Hop(token) end
        self:SetStage("Rare trees found",0.1,tostring(#entries).." trees")
        if not self.FoundNotified then
            self:TryWebhook("Rare trees found",self.Config.FullCycle and "Spooky wood detected." or "Search paused in this server.",token)
            self.FoundNotified=true
        end
        if not self.Config.FullCycle then return "Found - search paused in this server" end
        self.CanRecover=false
        if self.LoadReceipt and self.LoadReceipt.JobId==game.JobId and self.LoadReceipt.Slot==self.Config.Slot
            and self.LoadReceipt.Plot==self:Plot() then
            plot=self.LoadReceipt.Plot
        else plot=self:LoadSlot(token) end
    end
    self.CanRecover=false
    local batchStarted, initialPlanks = os.clock(), self.Stats.Planks
    local mill,inlet
    assert(plot and owned(plot),"Plot ownership changed before harvesting")
    local center=self:PlotCenter(plot) self.StackHeight=self.StackHeight or 0
    local processed, skipped = 0, 0
    for index,entry in ipairs(entries) do
        token:Check()
        if entry.Work or (entry.Model.Parent and value(entry.Model,"Owner")==nil
            and not entry.Model:FindFirstChild("RootCut") and self:WoodVolume(entry.Model)>=MIN_TREE_VOLUME) then
            local scope=self:Token(token)
            local work=entry.Work
            local log=work and work.Log
            local cutStarted=work~=nil
            local ok,result=pcall(function()
                assert(owned(plot) and self:Plot()==plot,"Plot ownership changed during harvesting")
                if not work or (not work.Log and work.Cut) then
                    local tool,stats=self:EnsureAxe(entry.Kind,scope)
                    self:SetStage("Cutting "..entry.Kind,0.3,string.format("Tree %d / %d",index,#entries))
                    if not work then
                        work={Kind=entry.Kind,Reason="Cut started"}
                        table.insert(self.PendingWood,work)
                    end
                    cutStarted=true self.Dirty=true
                    local target=work.Cut and {Model=work.Cut.Tree,Trunk=work.Cut.Trunk,Kind=work.Kind} or entry
                    log=self:Chop(target,tool,stats,scope,work)
                    work.Log=log self.Stats.Trees=self.Stats.Trees+1
                end
                if not work.Planks then
                    if not work.Modwood and not work.Classic then
                        self:BringTreeToBase(log,plot,scope)
                        work.AtBase=true
                        mill,inlet=self:FindMill(scope,plot)
                        local supported, reason=self:WaitForModwood(log,scope)
                        if not supported then
                            self:CaptureModwood(log,mill,reason)
                            if self:DismemberPlan(log) then
                                work.Planks=self:ClassicMill(log,mill,inlet,scope,work)
                            else return reason end
                        end
                    elseif work.Classic then
                        mill,inlet=work.Classic.Mill,work.Classic.Inlet
                        work.Planks=self:ClassicMill(log,mill,inlet,scope,work)
                    else
                        mill,inlet=work.Modwood.Mill,work.Modwood.Inlet
                        self.ServerExitReason="An unfinished Modwood attempt cannot be restarted"
                        error(self.ServerExitReason,0)
                    end
                    if not work.Planks then
                        work.Planks=self:Modwood(log,mill,inlet,scope,work)
                    end
                end
                assert(owned(plot) and self:Plot()==plot,"Plot ownership changed before delivery")
                self:SetStage("Delivering planks",0.86,"Center of your plot")
                self:Deliver(work.Planks,center,scope,work)
                self:SaveSlot(scope)
                return true
            end)
            scope:Clean()
            if result==CANCEL then error(CANCEL,0) end
            if self.ServerExitReason then
                local reason=self.ServerExitReason
                work.Reason=reason
                self.LastFailure={Time=os.date("!%Y-%m-%d %H:%M:%S"),Stage=self.Stage,Reason=reason}
                self:Log("Modwood failed - "..reason,"WARNING","Modwood failed - changing server")
                self.Stats.Skipped=self.Stats.Skipped+1
                token:Clean() token.Character=nil
                return self:LeaveStalledServer(token,reason)
            end
            token:Check()
            if ok and result==true then
                processed=processed+1
                local workIndex=table.find(self.PendingWood,work)
                if workIndex then table.remove(self.PendingWood,workIndex) end
                self.Dirty=#self.PendingWood>0
            else
                local reason=cleanError(result or "Tree processing was not confirmed")
                skipped=skipped+1 self.Stats.Skipped=self.Stats.Skipped+1
                self.LastFailure={Time=os.date("!%Y-%m-%d %H:%M:%S"),Stage=self.Stage,Reason=reason}
                self:Log("Tree "..index.." paused - "..reason,"WARNING")
                if cutStarted then
                    work.Reason=reason
                    self.Dirty=true
                else
                    self.NeedsAttention=true
                    self:Log("Inventory or character needs attention before another tree can be cut","WARNING")
                    break
                end
                if not work.Log then
                    self:Log("Cut is unconfirmed - stopping before another tree is targeted","WARNING")
                    break
                end
                self:SetStage("Moving to the next tree",self.Progress,"Previous wood remains in this server")
                scope=nil
            end
        else
            skipped=skipped+1 self.Stats.Skipped=self.Stats.Skipped+1
            self:Log("Tree no longer available - skipped","WARNING")
        end
    end
    if self.Dirty then
        self.NeedsAttention=true
        self:Log("Resuming unfinished wood automatically","INFO")
        local atBase, unconfirmed=0,0
        for _,work in ipairs(self.PendingWood) do
            if work.AtBase then atBase=atBase+1 end
            if not work.Log and not work.Planks then unconfirmed=unconfirmed+1 end
        end
        if unconfirmed>0 then return "Cut not confirmed - Retry checks the same tree; no delivery confirmed" end
        if atBase==#self.PendingWood then return "Wood remains at your base - Retry resumes the recorded tasks" end
        return "Wood remains in this server - Retry resumes the recorded tasks"
    end
    if self.NeedsAttention then return "Equip a compatible inventory axe, then retry" end
    if processed>0 then
        self:TryWebhook(processed == #entries and "Harvest complete" or "Harvest complete - some trees unavailable",
            "Wood processed, planks delivered to your plot and slot save confirmed.",token,
            {Trees=processed, Planks=self.Stats.Planks-initialPlanks, Seconds=os.clock()-batchStarted, Skipped=skipped})
    else self:TryWebhook("Trees no longer available","No harvest was performed. Moving to the next server.",token) end
    token:Clean() token.Character=nil
    return self:Hop(token)
end
-- Modwood failures leave immediately; other stalled tasks have a bounded recovery.
function H:LeaveStalledServer(token,reason)
    self.Watchdog=false
    reason=reason or "No progress for three minutes"
    self.ServerExitReason=self.ServerExitReason or reason
    self:SetStage("Changing server",self.Progress)
    self:Persist(false)
    if self.UnsavedDelivery and self.LoadReceipt and self.LoadReceipt.Plot==self:Plot() then
        local saveToken=self:Token(token)
        saveToken.Deadline=math.min(saveToken.Deadline,os.clock()+30)
        local saved,err=pcall(self.SaveSlot,self,saveToken)
        saveToken:Clean()
        if err==CANCEL then error(CANCEL,0) end
        self:Log(saved and "Delivered planks saved" or ("Save unconfirmed - "..cleanError(err)), saved and "INFO" or "WARNING")
    end
    local report=self:BuildReport()
    self.LastRecoveryReport=report
    if Write then pcall(Write,"MidnightSpookyHunter-last-recovery.txt",report) end
    self:TryWebhook("Harvest interrupted",reason..". Moving to another server. Remaining wood was not confirmed as processed.",token)
    self.AbandonedTasks=(self.AbandonedTasks or 0)+#self.PendingWood
    self.PendingWood={} self.Dirty=false self.NeedsAttention=false
    self.Abandoning=true
    return self:Hop(token)
end
function H:Start()
    if self.Busy or not self.Alive then return end
    self.Running=true self.Busy=true self.NeedsAttention=false self.HopUncertain=false
    self.LastProgressAt=os.clock() self.ProgressKeys={} self.Watchdog=true
    self.Abandoning=self.Abandoning==true
    if self.UI then self.UI.Start.Text="Hunting..." end
    self.Worker=task.defer(function()
        local result
        while self.Alive and self.Running do
            local token=self:Token() self.ActiveToken=token
            local ok
            if self.Abandoning then
                self.Watchdog=false
                ok,result=pcall(self.Hop,self,token)
            elseif self.ServerExitReason then
                ok,result=pcall(self.LeaveStalledServer,self,token,self.ServerExitReason)
            elseif os.clock()-self.LastProgressAt>=STALL_TIMEOUT then
                ok,result=pcall(self.LeaveStalledServer,self,token)
            else
                self.Watchdog=true
                ok,result=pcall(self.Run,self,token)
            end
            token:Clean() token.Character=nil
            if result==CANCEL or not self.Alive or not self.Running then break end
            if ok and not self.NeedsAttention and not self.Config.FullCycle and not self.ServerExitReason then break end
            self.LastFailure={Time=os.date("!%Y-%m-%d %H:%M:%S"),Stage=self.Stage,Reason=cleanError(result or "Retry pending")}
            self:Log("Recovery - "..self.LastFailure.Reason,"DEBUG")
            self:SetStage("Reconnecting",self.Progress)
            -- Preserve the continuation ticket while an uncertain teleport settles.
            self.Watchdog=false
            token.Deadline=os.clock()+210
            local waited,err=pcall(token.Sleep,token,self.HopUncertain and 180 or 5)
            if not waited then result=err break end
            if self.HopUncertain then
                self.HopUncertain=false self.PendingTeleportTarget=nil self.HopAttempt=nil
                self.Abandoning=true
            end
            self.NeedsAttention=false
        end
        if self.ActiveToken then self.ActiveToken:Clean() end
        self.Watchdog=false self.Running=false self.Busy=false self.ActiveToken=nil
        self:Persist(false)
        if not self.Alive then return end
        if self.UI then self.UI.Start.Text="Start hunt" end
        self:SetStage(result==CANCEL and "Stopped" or "Ready",self.Progress)
    end)
end
function H:Stop()
    self.Running=false self.Generation=self.Generation+1
    self.HopUncertain=false self.PendingTeleportTarget=nil
    self:Persist(false)
    if self.ActiveToken then self.ActiveToken:Clean() end
    if self.Alive then self:SetStage("Stopping",self.Progress,self.HopAttempt and "A teleport already sent cannot be recalled" or "Cleaning up the current task") end
end
function H:Destroy()
    if not self.Alive then return end
    self:Stop() self.Alive=false
    if self.AntiAfkConnection then self.AntiAfkConnection:Disconnect() self.AntiAfkConnection=nil end
    if self.Worker then pcall(task.cancel,self.Worker) end
    for _,c in ipairs(self.Connections) do c:Disconnect() end
    if self.ProgressTween then self.ProgressTween:Cancel() end
    if self.StageTween then self.StageTween:Cancel() end
    for _,animation in pairs(self.Motion or {}) do animation:Cancel() end
    if self.Window then self.Window:Destroy() end
    if self.Midnight then self.Midnight:Destroy() end
    if Env.MidnightSpookyHunter==self then Env.MidnightSpookyHunter=nil end
end

-- Midnight renders every surface and control; Hunter only connects its state.
local Midnight=LoadedMidnight
assert(type(Midnight)=="table" and type(Midnight.CreateCompactWindow)=="function","Midnight UI 2.4.0 is required")
H.Midnight=Midnight
local settings,home
local Window
Window=Midnight:CreateCompactWindow({Title="Spooky Hunter",SubTitle="Midnight - "..H.Version,
    Size=UDim2.fromOffset(500,400),Theme="Midnight",Keybind=Enum.KeyCode.RightShift,
    Position=H.WindowPosition,SaveConfig=false,Resizable=false,DestroyOnClose=true,
    OnSettings=function() if settings then if Window and Window.SelectedTab==settings then home:Select() else settings:Select() end end end,
    OnPositionChanged=function(position)
        H.WindowPosition=position
        local target=H.PendingTeleportTarget
        H:Persist(target~=nil,target)
    end,
    OnDestroy=function() H:Destroy() end})
H.Window=Window H.Gui=Window.Gui
home=Window:CreatePage({Title="Hunt",Icon="Moon"})
local activityPage=Window:CreatePage({Title="Activity",Icon="Terminal"})
settings=Window:CreatePage({Title="Settings",Icon="Settings"})
local progress=home:ProgressBar({Title="Ready",Description="Spooky and Sinister - 10 studs3 minimum",Default=0})
local cards=home:Row({Title="Rare trees",Height=66,Columns=2})
local spooky=cards:Stat({Title="Spooky",Value=0,Description="0 studs3"})
local sinister=cards:Stat({Title="Sinister",Value=0,Description="0 studs3",Token="Secondary"})
local actions=home:Row({Title="Hunt actions",Height=48,Columns=2})
local start=actions:Button({Title="Start hunt",Style="Primary",Icon="Play",Callback=function() H:Start() end})
actions:Button({Title="Stop",Icon="Square",Callback=function() H:Stop() end})
local activity=activityPage:Console({Title="Activity",Height=178,MaxEntries=40,Copyable=true,Timestamps=false,Compact=true})
activityPage:Button({Title="Copy diagnostic report",Icon="Copy",Callback=function()
    local copy=cap("setclipboard",setclipboard) or cap("toclipboard",toclipboard)
    if copy and pcall(copy,H:BuildReport()) then H:Log("Report copied") else H:Log("Clipboard unavailable","WARNING") end
end})
H.UI={Progress=progress,Stage=progress.Root:FindFirstChild("ProgressTitle"),
    Detail=progress.Root:FindFirstChild("Description"),Spooky=spooky,Neon=sinister,
    Activity=activity,Start=start.Root:FindFirstChild("Title")}
local controls={}
local function apply(key,newValue,control)
    if H.Busy and key~="AntiAfk" then
        control:Set(H.Config[key],true)
        H:Log("Stop the hunt before editing settings","WARNING") return
    end
    local candidate=table.clone(H.Config) candidate[key]=newValue
    candidate=configFrom(candidate)
    if key=="Webhook" and candidate.Webhook~="" and not webhookURL(candidate.Webhook) then
        H:Log("Invalid Discord webhook URL","WARNING") return
    end
    H.Config=candidate
    if key=="AntiAfk" then H:SetAntiAfk(candidate.AntiAfk) end
    local target=H.PendingTeleportTarget
    local saved,err=H:Persist(target~=nil,target)
    if not saved then H:Log(err,"WARNING") end
end
local slot
slot=settings:Dropdown({Title="Save slot",Options={"1","2","3","4","5","6"},Default=tostring(H.Config.Slot),Callback=function(v)
    if H.Busy then slot:Set(tostring(H.Config.Slot),true) H:Log("Stop the hunt before changing slot","WARNING") return end
    apply("Slot",tonumber(v),slot)
end})
local function textSetting(parent,title,key,numeric,secret)
    local input
    input=parent:Textbox({Title=title,Default=secret and "" or tostring(H.Config[key]),
        Placeholder=secret and (H.Config[key]~="" and "Saved - enter a URL to replace" or "https://discord.com/api/webhooks/...") or "",
        MaxLength=secret and 400 or 1000,Callback=function(v)
            if secret and v=="" then return end
            local n=numeric and tonumber(v) or v
            if numeric and not finite(n) then input:Set(tostring(H.Config[key]),true) return end
            apply(key,n,input)
            input:Set(secret and "" or tostring(H.Config[key]),true)
        end})
    controls[key]=input
end
textSetting(settings,"Discord webhook","Webhook",false,true)
settings:Button({Title="Clear webhook",Callback=function() if not H.Busy then H.Config.Webhook="" H:Persist(false) end end})
for _,entry in ipairs({{"Full harvest","FullCycle"},{"Anti-AFK","AntiAfk"}}) do
    local title,key=entry[1],entry[2]
    local toggle
    toggle=settings:Toggle({Title=title,Default=H.Config[key],Callback=function(v) apply(key,v,toggle) end})
end
local advanced=settings:Section({Title="Advanced",Collapsible=true,Collapsed=true})
textSetting(advanced,"Script URL","ScriptURL",false)
for _,entry in ipairs({{"Hop delay (seconds)","HopDelay"},{"Game loading timeout","LoadTimeout"},
    {"Wood data timeout","MetadataTimeout"},{"Scan timeout","ScanWait"},{"Chop timeout","ChopTimeout"},
    {"Burn timeout","BurnTimeout"},{"Sawmill timeout","MillTimeout"}}) do
    textSetting(advanced,entry[1],entry[2],true)
end
settings:Button({Title="Reset window position",Callback=function() Window:SetPosition({X=0.5,Y=0.5}) end})
H:Connect(S.TeleportService.TeleportInitFailed,function(player,_,message,placeId,options)
    if player~=Player or placeId~=game.PlaceId or not H.HopAttempt then return end
    local id=options and options.ServerInstanceId
    if id and id~="" and id~=H.HopAttempt.Id then return end
    H.HopAttempt.Error="Teleport failed - "..tostring(message):sub(1,160)
end)
if H.ConfigWarning then H:Log(H.ConfigWarning,"WARNING") end
H:Log("Ready")
H:SetAntiAfk(H.Config.AntiAfk)
if H.RecoveredSession then H:Log("Resuming unfinished wood") end
local resume=Env.MidnightSpookyResume==true and restored and restored.Resume==true and restored.Target==game.JobId
    and finite(restored.TicketTime) and os.time()-restored.TicketTime<600
Env.MidnightSpookyResume=nil
if resume or (H.RecoveredSession and wasRunning) then H:Start() end
return H
