--[[
    Midnight Spooky Hunter 1.14.5 - Lumber Tycoon 2
    October 13, 2026. Client script using Midnight UI Library 2.4.0 or newer.
    Chop and Modwood adapted from the user-supplied Ancestor script.
    Modwood runs once per tree. Failed attempts leave for another server.
    Use the companion loader or set Script URL for continuation after a hop.

    1.14.5: live target validation, bounded event-cache lifetime, stale task
    pruning, persistent retry budgets and progress-aware recovery backoff.

    1.14.4: single ignition-position controller, timed stability recovery,
    spaced corrections and contact gating; target-owner evidence in reports.

    1.14.3: 60 studs3 minimum; dry-area, selected-section synthetic ignition;
    bounded touch pulses, foreign-owner/fire guards and base-aligned root cuts.
    No physical lava fallback. Server outcomes are not guaranteed.

    1.14.2: persistent tracker pagination, bounded immediate page continuation,
    precise empty-pool diagnostics. Modwood remains unchanged.

    1.14.1: lag-tolerant ignition window, latched transient fire detection,
    bounded replication grace and immediate contact stop after ignition.

    1.14.0: integrates the user-validated Midnight Modwood Trial sequence;
    event-invalidated tree index, preparation pipeline and precomputed approaches.
    Foreign target ownership exits immediately; output and save checks remain.

    1.13.0: guarded teleport bootstrap with retries and OnTeleport backup;
    persistent oldest-observed batches and a six-hour visit cycle.
    Standard fallback is now opt-in when the tracker is enabled.

    1.12.0: local step retries, grounded chop repositioning, executor capability
    diagnostics, projected Drawing.new wireframes and touch argument compatibility.
    Modwood still runs once. A real disconnection still uses Auto rejoin.

    1.11.0 performance changes:
    01. Prepare server candidates during loading and saving.
    02. Share in-flight lookups and cache candidates briefly.
    03. Overlap tracker requests and delayed standard fallback.
    04. Recheck exclusions before choosing a cached destination.
    05. Overlap server lookup with the configured departure delay.
    06. Migrate the old one-second hop default to 0.25 seconds.
    07. Resume recent public-list pagination; recover expired cursors.
    08. Bound server lookup duration and page count.
    09. Back off on transport failures and honor numeric Retry-After.
    10. Handle full servers quickly and throttle flooded teleports.
    11. Sample latency without blocking world readiness.
    12. Budget initial tree indexing by elapsed CPU time.
    13. Reuse standing-tree enumeration for at most 0.5 seconds.
    14. Do not restart scan stability just because wood is growing.
    15. Update scan cards only when their displayed data changes.
    16. Validate and reuse remote, plot, sawmill and axe-stat caches.
    17. Skip equipping an axe already held by the character.
    18. Shorten post-save settling while retaining confirmation checks.
    19. Coalesce routine bot-state writes; flush critical transitions.
    20. Add performance controls and per-stage timing diagnostics.
    These changes have not been benchmarked in a live Roblox server.
]]
local S = {}
for _, name in ipairs({"Players", "Workspace", "ReplicatedStorage", "HttpService", "TweenService",
    "UserInputService", "RunService", "TeleportService", "GuiService"}) do S[name] = game:GetService(name) end
local Player = S.Players.LocalPlayer
assert(Player, "Spooky Hunter requires a client")
local Env = type(getgenv) == "function" and getgenv() or _G
local LIBRARY_URL="https://raw.githubusercontent.com/zyrk0794/Project/refs/heads/main/Library.lua"
local function loadMidnight()
    assert(type(loadstring)=="function","This script requires a client with loadstring")
    local cachePath="MidnightUI-Hunter-1.13.0.cache.lua"
    local reader,writer=Env.readfile or readfile,Env.writefile or writefile
    local function instantiate(source)
        if type(source)~="string" then return nil end
        local compiled=loadstring(source)
        if not compiled then return nil end
        local ok,library=pcall(compiled)
        if ok and type(library)=="table" and type(library.CreateCompactWindow)=="function" then return library end
        if ok and type(library)=="table" and type(library.Destroy)=="function" then pcall(library.Destroy,library) end
        return nil
    end
    if type(reader)=="function" then
        local ok,cached=pcall(reader,cachePath)
        if ok then
            local library=instantiate(cached)
            if library then return library end
        end
    end
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
                if ok and type(library)=="table" and type(library.CreateCompactWindow)=="function" then
                    if type(writer)=="function" then pcall(writer,cachePath,response[2]) end
                    return library
                end
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
local function queueAPIs()
    local result,seen={},{}
    local function add(fn,name)
        if type(fn)=="function" and not seen[fn] then
            seen[fn]=true result[#result+1]={Call=fn,Name=name}
        end
    end
    add(cap("queue_on_teleport",queue_on_teleport),"queue_on_teleport")
    add(cap("queueonteleport",queueonteleport),"queueonteleport")
    for _,name in ipairs({"syn","fluxus"}) do
        local fallback
        if name=="syn" then fallback=syn else fallback=fluxus end
        local api=Env[name] or _G[name] or fallback
        if type(api)=="table" then add(api.queue_on_teleport,name..".queue_on_teleport") end
    end
    return result
end
local Read, Write = cap("readfile", readfile), cap("writefile", writefile)
local LEGACY_FILE = "MidnightSpookyHunter.json"
local FILE = "MidnightSpookyHunter_"..tostring(Player.UserId)..".json"
local CONTINUATION_TTL = 1800
local SERVER_CYCLE_SECONDS = 6 * 60 * 60
local MIN_TREE_VOLUME = 60
local STALL_TIMEOUT = 180
local DEFAULT = { TargetSpecies = "Both", GrowSinister = false, GrowthStableSeconds = 400,
    GrowthMinWait = 400, GrowthMaxWait = 16200, GrowthNotifySeconds = 600,
    PerformanceMode = true, PrefetchServers = true, CandidateCacheSeconds = 30,
    ServerSearchBudget = 25, PublicPageLimit = 6,
    AutoRejoin = true, NoRender = false, ModwoodHighlights = true, RejoinDelay = 5, Slot = 1, BotEnabled = true, BotURL = "", BotKey = "", FastHarvest = true, ScriptURL = "", HopDelay = 0.25, ScanWait = 12,
    VisitCooldownHours = 6, HarvestCooldownHours = 24, AdaptiveTiming = true,
    ScanInterval = 0.1, ScanSettle = 0.25, EmptyScanDelay = 1, GameSettle = 0.75,
    TrackerEnabled = true, TrackerAllowFallback = false, TrackerURL = "", TrackerToken = "", TrackerTimeout = 4,
    TrackerFreshness = 30, TrackerMinAge = 0, TrackerBackoff = 120,
    ServerSearchTimeout = 8, ServerRetryDelay = 2, LoadTimeout = 180, MetadataTimeout = 30,
    ChopTimeout = 75, BurnTimeout = 40, MillTimeout = 80, TaskTimeout = 900, FullCycle = true, AntiAfk = true }
local H = { Version = "1.14.5", Alive = true, Running = false, Busy = false, Connections = {}, Logs = {}, ActivityEntries = {},
    Config = table.clone(DEFAULT), VisitRecords = {}, Visited = {}, ServerHistory = {}, FailedServers = {}, PendingWood = {},
    Stats = { Servers = 0, Trees = 0, Planks = 0, Skipped = 0, Scanned = 0, FoundServers = 0,
        FoundTrees = 0, Harvested = 0, TrackerScans = 0, TrackerFinds = 0, StandardScans = 0, StandardFinds = 0 },
    StartedAt = os.time(), Arrived = os.clock(), Generation = 0, Stage = "Ready", Progress = 0 }
local function emptyCollection()
    return {Spooky={Trees=0,TreeVolume=0,Planks=0,PlankVolume=0}, SpookyNeon={Trees=0,TreeVolume=0,Planks=0,PlankVolume=0}}
end
H.Collection=emptyCollection()
H.BatchCollection=emptyCollection()
H.JobId=game.JobId
H.ModwoodAttempts={}
if old and (old.JobId==game.JobId or (old.LoadReceipt and old.LoadReceipt.JobId==game.JobId)) then
    H.ModwoodAttempts=old.ModwoodAttempts or {}
    H.ServerExitReason=old.ServerExitReason
    H.GrowthTarget=old.GrowthTarget
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
local function trackerURL(url)
    return type(url)=="string" and url:match("^https://[%w%-]+%.[%w%-]+%.workers%.dev$")~=nil
end
local function trackerKey(key)
    return type(key)=="string" and #key>=32 and #key<=128 and key:match("^[%w_-]+$")~=nil
end
local function serverID(id)
    return type(id)=="string" and #id==36
        and id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")~=nil
end
local function configFrom(source)
    local result = table.clone(DEFAULT)
    if type(source) ~= "table" then return result end
    for key in pairs(result) do if type(source[key]) == type(result[key]) then result[key] = source[key] end end
    if result.TargetSpecies~="Spooky" and result.TargetSpecies~="SpookyNeon" and result.TargetSpecies~="Both" then result.TargetSpecies="Both" end
    result.Slot = math.floor(math.clamp(finite(result.Slot) and result.Slot or 1, 1, 6))
    for key, limits in pairs({CandidateCacheSeconds={5,90}, ServerSearchBudget={8,90}, PublicPageLimit={1,10}, GrowthStableSeconds={120,7200}, GrowthMinWait={120,14400}, GrowthMaxWait={1800,43200}, GrowthNotifySeconds={120,3600}, RejoinDelay={3,60}, VisitCooldownHours={0.1,168}, HarvestCooldownHours={0.1,336}, LoadTimeout = {30, 300}, MetadataTimeout = {5, 90}, HopDelay = {0, 180}, ScanWait = {2, 120},
        ScanInterval = {0.05, 1}, ScanSettle = {0.1, 5}, EmptyScanDelay = {0.5, 15}, GameSettle = {0.5, 5},
        TrackerTimeout = {2, 10}, TrackerFreshness = {5, 60}, TrackerMinAge = {0, 10080}, TrackerBackoff = {30, 900},
        ServerSearchTimeout = {3, 30}, ServerRetryDelay = {1, 60}, ChopTimeout = {15, 180},
        BurnTimeout = {10, 120}, MillTimeout = {15, 180}, TaskTimeout = {300, 1800}}) do
        result[key] = math.clamp(finite(result[key]) and result[key] or DEFAULT[key], limits[1], limits[2])
    end
    result.GrowthMaxWait=math.max(result.GrowthMaxWait,result.GrowthStableSeconds+300,result.GrowthMinWait+300)
    result.PublicPageLimit=math.floor(result.PublicPageLimit)
    result.ScanWait=math.max(result.ScanWait,math.max(result.ScanSettle,result.EmptyScanDelay)+result.ScanInterval)
    result.BotURL = cleanURL(result.BotURL):gsub("/+$", ""):lower():sub(1,200)
    result.BotKey = cleanURL(result.BotKey):sub(1,128)
    result.ScriptURL = cleanURL(result.ScriptURL):sub(1, 1000)
    result.TrackerURL = cleanURL(result.TrackerURL):gsub("/+$", ""):lower():sub(1, 200)
    result.TrackerToken = cleanURL(result.TrackerToken):sub(1, 128)
    return result
end
function H:WantsTree(kind)
    return rare(kind) and (self.Config.TargetSpecies=="Both" or self.Config.TargetSpecies==kind)
end
function H:EligibleVolume(kind, volume)
    return finite(volume) and volume>0 and (volume>=MIN_TREE_VOLUME or (kind=="SpookyNeon" and self.Config.GrowSinister))
end
function H:EnsureServerCycle()
    local now=os.time()
    if not self.ServerCycle or now>=self.ServerCycle.StartedAt+SERVER_CYCLE_SECONDS
        or now<self.ServerCycle.StartedAt then
        self.ServerCycle={StartedAt=now,Visited={}}
        self.OldServerBatch=nil
        self.TrackerSuppressed=nil self.TrackerCursor=nil
        self.ServerCandidateCache=nil
        self.TrackerRetryAt=nil
        self.TrackerEmptyUntil=nil
        self.ServerSearchRevision=(self.ServerSearchRevision or 0)+1
    end
    self.ServerCycle.Visited[game.JobId]=self.ServerCycle.Visited[game.JobId] or now
    return self.ServerCycle
end
function H:IsServerExcluded(id)
    if id==game.JobId then return true end
    if self.Config.TrackerEnabled then
        return self:EnsureServerCycle().Visited[id]~=nil
    end
    local record=self.VisitRecords[id]
    if not record then return false end
    local untilTime=math.max((record.LastVisit or 0)+self.Config.VisitCooldownHours*3600,
        record.HarvestedAt and record.HarvestedAt+self.Config.HarvestCooldownHours*3600 or 0)
    return untilTime>os.time()
end
function H:RememberServer(id,restoring)
    if type(id)~="string" or id=="" then return end
    if not restoring then self:EnsureServerCycle().Visited[id]=os.time() end
    for i=#self.ServerHistory,1,-1 do
        if self.ServerHistory[i]==id then table.remove(self.ServerHistory,i) end
    end
    table.insert(self.ServerHistory,id)
    local record=self.VisitRecords[id] or {}
    if not record.LastVisit then record.LastVisit=os.time() end
    if not restoring and self.ArrivalRecorded~=id then
        record.LastVisit=os.time() self.ArrivalRecorded=id
    end
    self.VisitRecords[id]=record
    while #self.ServerHistory>1000 do
        local removed=table.remove(self.ServerHistory,1)
        self.VisitRecords[removed]=nil self.Visited[removed]=nil
    end
    self.Visited[id]=true
end
function H:RefreshMetrics()
    if not self.UI or not self.UI.Results then return end
    local stats=self.Stats
    local average=stats.FoundServers>0 and string.format("%.1f servers per find",stats.Scanned/stats.FoundServers)
        or "Waiting for the first discovery"
    self.UI.Results:Set(string.format("Scanned %d - Found %d - Harvested %d",stats.Scanned,stats.FoundTrees,stats.Harvested),average)
end
function H:RecordScan(count)
    if self.ScanCounted then return end
    self.ScanCounted=true self.LastScannedServer=game.JobId
    self:RememberServer(game.JobId)
    local record=self.VisitRecords[game.JobId]
    record.ScannedAt=os.time() record.Found=count
    self.Stats.Scanned=self.Stats.Scanned+1
    self.Stats.FoundTrees=self.Stats.FoundTrees+count
    if count>0 then self.Stats.FoundServers=self.Stats.FoundServers+1 end
    local source=self.ArrivalSource=="Oldest observed" and "Tracker" or "Standard"
    self.Stats[source.."Scans"]=self.Stats[source.."Scans"]+1
    if count>0 then self.Stats[source.."Finds"]=self.Stats[source.."Finds"]+1 end
    self:RefreshMetrics()
    local ok,err=self:Persist(false) if not ok then self:Log(err,"WARNING") end
end
function H:RecordHarvest(work)
    if work.FinderCounted then return end
    work.FinderCounted=true
    self:RememberServer(game.JobId)
    self.VisitRecords[game.JobId].HarvestedAt=os.time()
    self.Stats.Harvested=self.Stats.Harvested+1
    for _,collection in ipairs({self.Collection,self.BatchCollection}) do
        local record=collection[work.Kind]
        if record then
            record.Trees=record.Trees+1
            record.TreeVolume=record.TreeVolume+(work.TreeVolume or 0)
            record.Planks=record.Planks+(work.Planks and #work.Planks or 0)
            record.PlankVolume=record.PlankVolume+(work.DeliveredVolume or 0)
        end
    end
    self:RefreshMetrics()
    local ok,err=self:Persist(false) if not ok then self:Log(err,"WARNING") end
end
function H:ObserveLatency(seconds)
    if not finite(seconds) or seconds<0 or seconds>15 then return end
    self.ServerRTT=self.ServerRTT and self.ServerRTT*0.7+seconds*0.3 or seconds
end
function H:AdaptiveWait(base,maximum)
    if not self.Config.AdaptiveTiming or not self.ServerRTT then return base end
    return math.min(maximum,base+math.max(0,self.ServerRTT-0.12)*2)
end
function H:SampleLatency(token)
    if self.NetworkSampled or not self.Config.AdaptiveTiming then return end
    self.NetworkSampled=true
    local ping=S.ReplicatedStorage:FindFirstChild("TestPing")
    if not ping or not ping:IsA("RemoteFunction") then return end
    local started=os.clock()
    local ok=pcall(function() token:Await(function() return ping:InvokeServer() end,3) end)
    token:Check()
    if ok then self:ObserveLatency(os.clock()-started) end
end
function H:StartLatencySample(token)
    if self.NetworkSampled or self.LatencyWorker then return end
    if not self.Config.PerformanceMode then self:SampleLatency(token) return end
    local scope=self:Token(token)
    local worker
    token:Finally(function()
        if worker and coroutine.status(worker)~="dead" then pcall(task.cancel,worker) end
        scope:Clean()
        self.LatencyWorker=nil
    end)
    worker=task.spawn(function()
        pcall(self.SampleLatency,self,scope)
        scope:Clean()
        self.LatencyWorker=nil
    end)
    self.LatencyWorker=worker
end
function H:RecordFailure(stage,reason)
    reason=tostring(reason)
    local lower=reason:lower()
    local code,waiting="TASK_INTERRUPTED","Completion of the current stage"
    if lower:find("lavafire",1,true) then code,waiting="IGNITION_MISSING","LavaFire on the selected parent"
    elseif lower:find("parent did not separate",1,true) then code,waiting="SEPARATION_MISSING","Burn parent leaving its original container"
    elseif lower:find("trigger",1,true) then code,waiting="CONVERSION_MISSING","Matching owned replacement log"
    elseif lower:find("output",1,true) or lower:find("whole-tree",1,true) then code,waiting="OUTPUT_UNCONFIRMED","Consumed input and stable owned planks"
    elseif lower:find("save",1,true) then code,waiting="SAVE_UNCONFIRMED","Positive slot save response and idle save state"
    elseif lower:find("cut",1,true) then code,waiting="CUT_UNCONFIRMED","Matching owned felled log"
    elseif lower:find("unstable",1,true) or lower:find("shifted",1,true) then code,waiting="WOOD_MOVED","Wood remaining at its destination"
    elseif lower:find("timed out",1,true) then code,waiting="REQUEST_TIMEOUT","Server response"
    end
    self.LastFailure={Time=os.date("!%Y-%m-%d %H:%M:%S"),Stage=stage,Reason=reason,Code=code,WaitingFor=waiting,
        LastConfirmed=self.LastConfirmedMilestone or "No harvest milestone confirmed"}
end
local restored
if Read then
    for _, path in ipairs({FILE, FILE .. ".bak", LEGACY_FILE}) do
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
-- The bootstrap keeps the validated arrival ticket across startup retries.
-- Partial UI initialization may already have written a non-resume settings file.
local arrivalTicket=Env.MidnightSpookyResumeTicket
if Env.MidnightSpookyResume==true and type(arrivalTicket)=="table"
    and arrivalTicket.PlaceId==game.PlaceId and arrivalTicket.Resume==true
    and finite(arrivalTicket.TicketTime) and os.time()-arrivalTicket.TicketTime>=-60
    and os.time()-arrivalTicket.TicketTime<CONTINUATION_TTL
    and (arrivalTicket.Target==game.JobId or (arrivalTicket.Target=="*" and arrivalTicket.Recovery==true)) then
    restored=arrivalTicket
end
if restored then
    H.Config = configFrom(restored.Config)
    local cycle=restored.ServerCycle
    if type(cycle)=="table" and finite(cycle.StartedAt) and cycle.StartedAt<=os.time()
        and os.time()-cycle.StartedAt<SERVER_CYCLE_SECONDS and type(cycle.Visited)=="table" then
        H.ServerCycle={StartedAt=cycle.StartedAt,Visited={}}
        H.TrackerSuppressed={}
        if type(restored.TrackerSuppressed)=="table" then
            for _,id in ipairs(restored.TrackerSuppressed) do
                if #H.TrackerSuppressed>=1150 then break end
                if serverID(id) then H.TrackerSuppressed[#H.TrackerSuppressed+1]=id end
            end
        end
        local count=0
        for id,stamp in pairs(cycle.Visited) do
            if count>=25000 then break end
            if serverID(id) and finite(stamp) and stamp>=cycle.StartedAt and stamp<=os.time() then
                H.ServerCycle.Visited[id]=stamp count=count+1
            end
        end
        local bookmark=restored.TrackerCursor
        if type(bookmark)=="table" and bookmark.URL==H.Config.TrackerURL and type(bookmark.After)=="table"
            and serverID(bookmark.After.id) and finite(bookmark.After.firstSeen)
            and bookmark.After.firstSeen>0 and bookmark.After.firstSeen<=os.time() then
            H.TrackerCursor={URL=bookmark.URL,After={id=bookmark.After.id,firstSeen=bookmark.After.firstSeen}}
        end
        local batch=restored.OldServerBatch
        if type(batch)=="table" and batch.URL==H.Config.TrackerURL and type(batch.Entries)=="table"
            and finite(batch.FetchedAt) and batch.FetchedAt<=os.time() and os.time()-batch.FetchedAt<300 then
            local entries={}
            for _,entry in ipairs(batch.Entries) do
                if #entries>=100 then break end
                if type(entry)=="table" and serverID(entry.id) and finite(entry.firstSeen)
                    and finite(entry.lastSeen) and entry.firstSeen>0 and entry.firstSeen<=entry.lastSeen
                    and entry.lastSeen<=os.time() and finite(entry.playing) and finite(entry.maxPlayers)
                    and entry.playing>=0 and entry.playing<entry.maxPlayers then
                    entries[#entries+1]=entry
                end
            end
            H.OldServerBatch={URL=batch.URL,FetchedAt=batch.FetchedAt,Entries=entries}
        end
    end
    -- Apply the requested growth timing once, including existing saved settings.
    -- Future edits in Advanced settings remain persistent.
    if restored.GrowthTimingRevision ~= 1 then
        H.Config.GrowthStableSeconds = 400
        H.Config.GrowthMinWait = math.min(H.Config.GrowthMinWait, 400)
    end
    for kind,record in pairs(H.Collection) do
        local saved=type(restored.Collection)=="table" and restored.Collection[kind]
        if type(saved)=="table" then
            for key in pairs(record) do if finite(saved[key]) then record[key]=math.clamp(saved[key],0,1e12) end end
        end
    end
    H.BotCommandVersion=finite(restored.BotCommandVersion) and math.max(0,math.floor(restored.BotCommandVersion)) or 0
    H.BotDesired=restored.BotDesired
    H.BotQueue={}
    if type(restored.BotQueue)=="table" then
        for _,event in ipairs(restored.BotQueue) do
            if #H.BotQueue>=50 then break end
            if type(event)=="table" and type(event.id)=="string" and type(event.title)=="string" and type(event.content)=="string"
                and (event.kind=="found" or event.kind=="complete" or event.kind=="interrupted" or event.kind=="info") then
                table.insert(H.BotQueue,{id=event.id:sub(1,64),kind=event.kind,title=event.title:sub(1,120),content=event.content:sub(1,700),snapshot=type(event.snapshot)=="table" and event.snapshot or nil,capturedAt=event.capturedAt})
            end
        end
    end
    if type(restored.Departure)=="table" and restored.Departure.JobId==game.JobId then
        H.ServerExitReason=tostring(restored.Departure.Reason or "Modwood was interrupted")
    end
    -- Apply the requested one-second hop once, then retain future user edits.
    if restored.TimingRevision~=1 then H.Config.HopDelay=1 end
    if restored.PerformanceRevision~=1 then
        if H.Config.HopDelay==1 then H.Config.HopDelay=0.25 end
        if H.Config.ServerRetryDelay==5 then H.Config.ServerRetryDelay=2 end
        if H.Config.ServerSearchTimeout==12 then H.Config.ServerSearchTimeout=8 end
    end
    if type(restored.PublicCursor)=="string" and #restored.PublicCursor<=2048
        and finite(restored.PublicCursorUntil) and restored.PublicCursorUntil>os.time()
        and restored.PublicCursorUntil<=os.time()+180 then
        H.PublicCursor=restored.PublicCursor H.PublicCursorUntil=restored.PublicCursorUntil
    end
    if type(restored.WindowPosition) == "table" and finite(restored.WindowPosition.X) and finite(restored.WindowPosition.Y) then
        H.WindowPosition = {X=math.clamp(restored.WindowPosition.X,0,1),Y=math.clamp(restored.WindowPosition.Y,0,1)}
    end
    if type(restored.VisitRecords)=="table" then
        local restoredCount=0
        for id,record in pairs(restored.VisitRecords) do
            if restoredCount>=1000 then break end
            if serverID(id) and type(record)=="table" and finite(record.LastVisit) then
                H.VisitRecords[id]={LastVisit=math.min(os.time(),record.LastVisit),
                    HarvestedAt=finite(record.HarvestedAt) and math.min(os.time(),record.HarvestedAt) or nil}
                restoredCount=restoredCount+1
            end
        end
    end
    if restored.Resume==true and restored.Target==game.JobId then H.ArrivalSource=restored.TargetSource end
    if type(restored.ServerHistory) == "table" then
        for _, id in ipairs(restored.ServerHistory) do H:RememberServer(id,true) end
    elseif type(restored.Visited) == "table" then
        local legacy = {}
        for id, stamp in pairs(restored.Visited) do
            if type(id) == "string" and finite(stamp) then table.insert(legacy, {Id=id, Stamp=stamp}) end
        end
        table.sort(legacy, function(a,b) if a.Stamp == b.Stamp then return a.Id < b.Id end return a.Stamp < b.Stamp end)
        for _, entry in ipairs(legacy) do H:RememberServer(entry.Id,true) end
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
    H.LastScannedServer=restored.LastScannedServer
    H.ScanCounted=restored.LastScannedServer==game.JobId
    if not H.ArrivalSource and restored.CurrentServer==game.JobId then H.ArrivalSource=restored.ArrivalSource end
end
H:EnsureServerCycle()
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
    ["Resuming unfinished wood"]="Recovering harvest",
    ["Checking remaining wood"]="Checking wood",
}
local function shortError(message)
    message=cleanError(message)
    if message:find("Modwood unavailable",1,true) then return "Modwood unavailable - changing server" end
    if message:find("Cut not confirmed",1,true) then return "Waiting for the cut to complete" end
    if message:find("no LavaFire",1,true) then return "Ignition not confirmed - changing server" end
    if message:find("whole-tree conversion",1,true) then return "Waiting for the remaining wood" end
    if message:find("Request timed out",1,true) then return "Waiting for the server" end
    message=message:gsub(" %- copy Activity.*$", ""):gsub("; copy Activity before retrying", "")
    return message
end
function H:Log(message, level, display)
    message=tostring(message) level=level or "INFO"
    if self.Config.BotKey~="" then message=message:gsub(self.Config.BotKey:gsub("([^%w])","%%%1"),"[client key]") end
    if self.Config.TrackerToken~="" then message=message:gsub(self.Config.TrackerToken:gsub("([^%w])","%%%1"),"[tracker key]") end
    -- Keep technical timings in the copied report, never in the visible feed.
    table.insert(self.Logs,os.date("!%H:%M:%S").."  "..level.."  "..message)
    while #self.Logs>160 do table.remove(self.Logs,1) end
    if level=="DEBUG" or display==false then return end
    local visible=type(display)=="string" and display or shortError(message)
    if self.Config.BotKey~="" then visible=visible:gsub(self.Config.BotKey:gsub("([^%w])","%%%1"),"[client key]") end
    if self.Config.TrackerToken~="" then visible=visible:gsub(self.Config.TrackerToken:gsub("([^%w])","%%%1"),"[tracker key]") end
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
local travelStages={
    ["Next server"]=true,["Finding another server"]=true,
    ["Waiting for available servers"]=true,["Joining another server"]=true,
    ["Changing server"]=true,["Waiting for teleport"]=true,
}
function H:RenderProgress(detail)
    if not self.UI then return end
    local batch=self.HarvestProgress
    local current=batch and batch.Current
    local caption=detail or ""
    if current and not travelStages[self.Stage] then
        caption=string.format("Tree %d / %d",current.Index,#batch.Items)
        if current.Detail and current.Detail~="" then caption=caption.." - "..current.Detail end
    end
    local title=stageTitles[self.Stage] or uiText(self.Stage)
    local signature=table.concat({title,caption,tostring(travelStages[self.Stage]==true),string.format("%.3f",self.Progress)},"|")
    if self.LastProgressRender==signature then return end
    self.LastProgressRender=signature
    self.UI.Progress:SetText(title,caption)
    if travelStages[self.Stage] then
        self.UI.Progress:SetIndeterminate(true)
    else
        self.UI.Progress:SetIndeterminate(false)
        self.UI.Progress:Set(self.Progress*100,true)
    end
end
function H:BeginHarvestProgress(entries)
    if self.HarvestProgress and self.HarvestProgress.JobId==game.JobId then return end
    local batch={JobId=game.JobId,Items={},ByWork={},ByModel={}}
    for index,entry in ipairs(entries) do
        local item={Index=index,Fraction=0}
        table.insert(batch.Items,item)
        if entry.Model then batch.ByModel[entry.Model]=item end
        if entry.Work then batch.ByWork[entry.Work]=item end
    end
    self.HarvestProgress=batch
    self.Progress=0.18
    self:RenderProgress()
end
function H:SelectHarvestProgress(entry)
    local batch=self.HarvestProgress
    if not batch then return end
    batch.Current=(entry.Work and batch.ByWork[entry.Work]) or batch.ByModel[entry.Model]
    self:RenderProgress()
end
function H:LinkHarvestProgress(work)
    local batch=self.HarvestProgress
    if batch and batch.Current then batch.ByWork[work]=batch.Current end
end
function H:UpdateHarvestProgress(fraction,detail)
    local batch=self.HarvestProgress
    if not batch or not batch.Current or not finite(fraction) then return end
    -- These are weighted, completed milestones, never a damage or ETA estimate.
    local item=batch.Current
    local updated=math.max(item.Fraction,math.clamp(fraction,0,1))
    local changed=updated~=item.Fraction or (detail~=nil and detail~=item.Detail)
    if updated>item.Fraction then
        local milestone=updated>=1 and "Slot save confirmed" or updated>=0.95 and "All planks delivered"
            or updated>0.85 and "Plank delivery confirmed" or updated>=0.85 and "Stable planks confirmed"
            or updated>0.70 and "Sawmill consumption observed" or updated>=0.70 and "Replacement log confirmed"
            or updated>=0.64 and "Inlet prepared" or updated>=0.60 and "Parent separation confirmed"
            or updated>=0.50 and "LavaFire confirmed" or updated>=0.40 and "Wood structure validated"
            or updated>=0.38 and "Owned sawmill found" or updated>=0.35 and "Tree delivered"
            or updated>=0.25 and "Felled tree confirmed" or "Inventory axe equipped"
        self.LastConfirmedMilestone=string.format("Tree %d - %s",item.Index,milestone)
    end
    item.Fraction=updated
    if detail~=nil then item.Detail=detail end
    local sum,complete=0,#batch.Items>0
    for _,record in ipairs(batch.Items) do
        sum=sum+record.Fraction
        complete=complete and record.Fraction==1
    end
    batch.Complete=complete
    -- Reserve 100% for every tree delivered AND its slot save confirmed.
    self.Progress=complete and 1 or math.min(0.99,0.18+0.81*sum/math.max(1,#batch.Items))
    if changed then self:RenderProgress() end
end
function H:SetStage(text, progress, detail)
    local changed=self.Stage~=text
    if changed then
        if self.Stage and self.StageStarted then
            self.StageTimes=self.StageTimes or {}
            self.StageTimes[self.Stage]=(self.StageTimes[self.Stage] or 0)+os.clock()-self.StageStarted
        end
        self.StageStarted=os.clock()
    end
    self.Stage=text
    if progress and not self.HarvestProgress and not travelStages[text] then
        self.Progress=math.max(self.Progress,math.clamp(progress,0,0.99))
    end
    if self.HarvestProgress and self.HarvestProgress.Current and changed then
        self.HarvestProgress.Current.Detail=nil
    end
    local shown=stageTitles[text] or uiText(text)
    local useful=detail and (detail:match("^Tree %d") or detail:match("^Piece %d") or text=="Equipping inventory axe"
        or text=="Rare trees found" or text=="Waiting for available servers" or text=="Needs attention"
        or text=="Task stopped" or text=="Modwood - igniting parent section")
    local caption=useful and uiText(shortError(detail)) or ""
    self:RenderProgress(caption)
    local diagnostic=text..(detail and (" - "..detail) or "")
    if diagnostic~=self.LastStageDiagnostic then
        self.LastStageDiagnostic=diagnostic
        local visible=shown..(caption~="" and " - "..caption or "")
        self:Log(diagnostic,"INFO",visible~=self.LastStageVisible and visible or false)
        self.LastStageVisible=visible
    end
end
function H:SetNoRender(enabled)
    enabled=enabled==true
    local ok=pcall(function() S.RunService:Set3dRenderingEnabled(not enabled) end)
    if not ok then
        self:Log("3D rendering control is unavailable in this client","WARNING")
        return false
    end
    self.RenderDisabled=enabled
    self.Config.NoRender=enabled
    return true
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
    local data = { Schema = 2, Version = self.Version, TimingRevision = 1, GrowthTimingRevision = 1, PerformanceRevision = 1,
        ServerCycle=self:EnsureServerCycle(),OldServerBatch=self.OldServerBatch,TrackerSuppressed=self.TrackerSuppressed,TrackerCursor=self.TrackerCursor,
        PublicCursor=self.PublicCursor,PublicCursorUntil=self.PublicCursorUntil,
        WindowPosition = self.WindowPosition, Config = self.Config, ServerHistory = table.clone(self.ServerHistory),
        VisitRecords=self.VisitRecords, CurrentServer=game.JobId, ArrivalSource=self.ArrivalSource, LastScannedServer=self.LastScannedServer, TargetSource=self.ServerSource, BotQueue=self.BotQueue or {}, BotDesired=self.BotDesired, BotCommandVersion=self.BotCommandVersion or 0, FailedServers = failed, Stats = self.Stats, LastCountedServer = self.LastCountedServer,
        Collection=self.Collection, PlaceId=game.PlaceId, Recovery=self.Rejoining==true and target=="*",
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
        if type(work)=="table" then
            local prefix=tostring(work)
        if work.Log and under(work.Log,S.Workspace) and owned(work.Log) then self:Checkpoint(prefix..":felled") end
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
end
function H:WaitResult(token,predicate,timeout,message,interval)
    local deadline=os.clock()+timeout
    repeat
        token:Check()
        local result=predicate()
        if result then return result end
        if os.clock()>=deadline then error(message or "Expected result was not observed",0) end
        token:Sleep(math.min(interval or 0.04,math.max(0,deadline-os.clock())))
    until false
end
function H:CheckTargetOwner(entry)
    if not entry then return end
    local target=entry.Model
    -- Follow the original trunk when it becomes a loose log. An old standing
    -- tree or a higher ancestor is not the owner of the newly moved section.
    local current=entry.Trunk and entry.Trunk.Parent
    while current and current~=S.Workspace do
        if current:FindFirstChild("TreeClass") then target=current break end
        current=current.Parent
    end
    local owner,field=self:TreeOwner(target)
    if owner and owner~=Player then
        local path=field and field:GetFullName() or "Owner field unavailable"
        self.TargetOwnerDiagnostic=string.format("Target: %s\nOwner field: %s\nOwner: %s (%s)\nStage: %s",
            target and target:GetFullName() or "Unavailable",path,owner.Name,
            owner:IsA("Player") and tostring(owner.UserId) or "unknown",tostring(self.Stage))
        self.ServerExitReason="Target claimed by another player - "..owner.Name
        self:Log("Target unavailable - "..path.." = "..owner.Name,"DEBUG")
        error(self.ServerExitReason,0)
    end
end
function H:Token(parent)
    if not parent then self.Generation = self.Generation + 1 end
    local token = { Generation = parent and parent.Generation or self.Generation, Cleanups = {},
        Character = parent and parent.Character, Deadline = parent and parent.Deadline or os.clock()+self.Config.TaskTimeout }

    function token:Check()
        if not H.Alive or not H.Running or H.Generation ~= self.Generation then error(CANCEL, 0) end
        if H.ActiveTarget then H:CheckTargetOwner(H.ActiveTarget) end
        assert(not self.ModwoodFailure,self.ModwoodFailure)
        if H.ModwoodGuard and H.ModwoodGuard.Generation==self.Generation then H.ModwoodGuard:Check() end
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
-- Standing trees can live in nested/custom TreeRegion models. Branch models
-- in the supplied SuperTree module inherit their ancestor tree's Owner.
function H:TreeContext(model)
    if not model or not under(model,S.Workspace) then return nil,nil,nil end
    local ownerField,ownerModel,event
    local current=model
    while current and current~=S.Workspace do
        local field=current:FindFirstChild("Owner")
        local cut=current:FindFirstChild("CutEvent")
        if not event and cut then event=cut end
        if field and field:IsA("ObjectValue") and (current==model or current:FindFirstChild("TreeClass") or cut) then
            ownerField,ownerModel=field,current
            break
        end
        if current~=model and current.Name=="TreeRegion" and not current:FindFirstChild("TreeClass") then break end
        current=current.Parent
    end
    return ownerField,ownerModel,event
end
function H:TreeOwner(model)
    local field=self:TreeContext(model)
    return field and field.Value or nil,field
end
function H:TreeTrunk(model)
    -- A nested branch can also have ID=1. Prefer the root tree's direct section.
    for _,part in ipairs(model:GetChildren()) do
        if part:IsA("BasePart") and part.Name=="WoodSection" and tonumber(value(part,"ID"))==1 then return part end
    end
    return nil
end
function H:IsStandingTree(model)
    if not model or not model:IsA("Model") or not under(model,S.Workspace) or model:FindFirstChild("RootCut") then return false end
    for _,name in ipairs({"LogModels","PlayerModels"}) do
        local excluded=S.Workspace:FindFirstChild(name)
        if excluded and under(model,excluded) then return false end
    end
    local field=model:FindFirstChild("TreeClass")
    local trunk=self:TreeTrunk(model)
    return field~=nil and field:IsA("StringValue") and livePart(trunk)
        and trunk.Anchored and trunk.Size.Y>0 and model:FindFirstChild("CutEvent")~=nil
end
function H:EnsureTreeIndex(token)
    if self.TreeIndexReady then return end
    if not self.TreeIndex then
        self.TreeIndex={} self.TreeWatchers={}
        local function invalidate()
            self.StandingCache=nil
            self.TreeRevision=(self.TreeRevision or 0)+1
        end
        local function remove(model)
            local record=self.TreeWatchers[model]
            if record then
                for _,connection in ipairs(record.Connections) do connection:Disconnect() end
                for _,connection in pairs(record.Metadata) do connection:Disconnect() end
                for _,connections in pairs(record.Parts) do for _,connection in ipairs(connections) do connection:Disconnect() end end
            end
            self.TreeWatchers[model]=nil self.TreeIndex[model]=nil
            invalidate()
        end
        self.RemoveTreeIndex=remove
        local function add(object)
            if object.Name~="TreeClass" or not object:IsA("StringValue") then return end
            local model=object.Parent
            if not model or not model:IsA("Model") or not under(model,S.Workspace) or self.TreeIndex[model]==object then return end
            if self.TreeWatchers[model] then remove(model) end
            self.TreeIndex[model]=object
            local record={Connections={},Parts={},Metadata={},Volume=nil}
            self.TreeWatchers[model]=record
            local function dirty() record.Volume=nil invalidate() end
            local function connect(signal,callback)
                record.Connections[#record.Connections+1]=signal:Connect(callback)
            end
            local function watchPart(part)
                if part:IsA("ValueBase") and (part.Name=="ID" or part.Name=="ParentID" or part.Name=="Owner") and not record.Metadata[part] then
                    record.Metadata[part]=part:GetPropertyChangedSignal("Value"):Connect(dirty)
                end
                if part:IsA("BasePart") and part.Name=="WoodSection" and not record.Parts[part] then
                    record.Parts[part]={
                        part:GetPropertyChangedSignal("Anchored"):Connect(invalidate),
                        part:GetPropertyChangedSignal("Size"):Connect(function() record.Volume=nil end)
                    }
                end
            end
            connect(object:GetPropertyChangedSignal("Value"),dirty)
            connect(model.AncestryChanged,function()
                if not under(model,S.Workspace) then remove(model) else invalidate() end
            end)
            connect(object.AncestryChanged,function()
                if object.Parent~=model and self.TreeIndex[model]==object then remove(model) end
            end)
            connect(object:GetPropertyChangedSignal("Name"),function()
                if object.Name~="TreeClass" then remove(model) end
            end)
            connect(model.DescendantAdded,function(child)
                watchPart(child)
                if child.Name=="WoodSection" or child.Name=="ID" or child.Name=="Owner" or child.Name=="CutEvent" or child.Name=="RootCut" then dirty() end
            end)
            connect(model.DescendantRemoving,function(child)
                if record.Metadata[child] then record.Metadata[child]:Disconnect() record.Metadata[child]=nil end
                if record.Parts[child] then
                    for _,connection in ipairs(record.Parts[child]) do connection:Disconnect() end
                    record.Parts[child]=nil
                end
                if child.Name=="WoodSection" or child.Name=="ID" or child.Name=="Owner" or child.Name=="CutEvent" or child.Name=="RootCut" then dirty() end
            end)
            for _,part in ipairs(model:GetDescendants()) do watchPart(part) end
            dirty()
        end
        self:Connect(S.Workspace.DescendantAdded,add)
        self:Connect(S.Workspace.DescendantRemoving,function(object)
            if object.Name=="TreeClass" and object.Parent and self.TreeIndex[object.Parent]==object then remove(object.Parent) end
        end)
        self.TreeIndexAdd=add
    end
    local budgetStart=os.clock()
    for index,object in ipairs(S.Workspace:GetDescendants()) do
        self.TreeIndexAdd(object)
        if index%128==0 and os.clock()-budgetStart>=0.004 then token:Sleep(0.001) budgetStart=os.clock() end
    end
    self.TreeIndexReady=true
end
function H:StandingTrees(token)
    self:EnsureTreeIndex(token)
    local cached=self.StandingCache
    if cached and os.clock()-cached.At<0.5 then
        return cached.Models,cached.Regions
    end
    local models,regions,seen={},{},{}
    for model,field in pairs(self.TreeIndex) do
        if not under(model,S.Workspace) or field.Parent~=model or field.Name~="TreeClass" then
            self.RemoveTreeIndex(model)
        elseif self:IsStandingTree(model) then
            local _,root=self:TreeContext(model)
            -- Do not count an inherited branch again as a separate tree.
            root=root or model
            if not seen[root] and self:IsStandingTree(root) then
                seen[root]=true table.insert(models,root)
                local region=root
                while region.Parent and region.Name~="TreeRegion" and region.Parent~=S.Workspace do region=region.Parent end
                regions[region]=true
            end
        end
    end
    local count=0
    for _ in pairs(regions) do count=count+1 end
    local rare,snapshot={},{}
    for _,model in ipairs(models) do
        local kind=value(model,"TreeClass")
        if kind then snapshot[model]=kind end
        if kind=="Spooky" or kind=="SpookyNeon" then rare[#rare+1]=model end
    end
    self.StandingCache={Models=models,Rare=rare,Snapshot=snapshot,Regions=count,At=os.clock()}
    return models,count
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
        local loadedTrees,regions=self:StandingTrees(token)
        local trees=#loadedTrees
        if regions==0 or trees==0 then table.insert(missing,"Tree regions") end
        local signature={regions,trees}
        for _,object in ipairs(refs) do table.insert(signature,object) end
        local changed=not lastSignature or #signature~=#lastSignature
        if not changed then for i,object in ipairs(signature) do if lastSignature[i]~=object then changed=true break end end end
        if #missing==0 then
            self:StartLatencySample(token)
            if changed or not stableSince then stableSince=os.clock() end
            if os.clock()-stableSince>=self:AdaptiveWait(self.Config.GameSettle,5) then
                self.LoadDiagnostic=string.format("Game ready - required objects stable for %.2f seconds",self.Config.GameSettle)
                self:Log(self.LoadDiagnostic,"DEBUG") return
            end
        else stableSince=nil end
        lastSignature=signature
        local reason=#missing>0 and table.concat(missing,", ") or "Waiting for stable objects"
        self.LoadDiagnostic="Game loading - "..reason
        if reason~=lastReason then self:Log(self.LoadDiagnostic,"DEBUG") lastReason=reason end
        assert(os.clock()<deadline,"Game data is still loading - "..reason)
        token:Sleep(math.min(0.25,self.Config.ScanInterval))
    until false
end
function H:Remote(folder, name, class)
    self.RemoteCache=self.RemoteCache or {}
    local key=folder.."/"..name.."/"..(class or "RemoteEvent")
    local cached=self.RemoteCache[key]
    if self.Config.PerformanceMode and cached and cached.Parent and cached:IsA(class or "RemoteEvent")
        and cached.Parent==S.ReplicatedStorage:FindFirstChild(folder) then return cached end
    local parent = S.ReplicatedStorage:FindFirstChild(folder)
    local remote = parent and parent:FindFirstChild(name)
    assert(remote and remote:IsA(class or "RemoteEvent"), "Missing game remote: " .. folder .. "." .. name)
    self.RemoteCache[key]=remote
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
    local guard=self.ModwoodGuard
    if guard and guard.Character==character then guard:BeforeMove(cf) end
    humanoid.Sit = false character:PivotTo(cf)
    if guard and guard.Character==character then guard:Hold(root.CFrame) end
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
    local cached=self.PlotCache
    if self.Config.PerformanceMode and cached and os.clock()-cached.At<0.25
        and under(cached.Plot,S.Workspace) and owned(cached.Plot) then return cached.Plot end
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
    self.PlotCache=best and {Plot=best,At=os.clock()} or nil
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
    return loadedPlot
end
function H:StartHarvestPreparation(token,entries)
    local previous=self.Preparation
    if previous and previous.Generation==token.Generation then return previous end
    local prepared={Generation=token.Generation,Done=false}
    self.Preparation=prepared
    local alive=true
    local worker
    token:Finally(function()
        alive=false
        if worker and coroutine.status(worker)~="dead" then pcall(task.cancel,worker) end
    end)
    worker=task.spawn(function()
        local ok,reason=pcall(function()
            for _,entry in ipairs(entries) do
                if not alive then return end
                token:Check()
                self:FindAxe(entry.Kind) -- Warms the existing axe definition cache.
                if livePart(entry.Trunk) then self:PlanChopApproaches(entry.Model,entry.Trunk) end
            end
            prepared.Lava=self:FindLava(token)
            local deadline=os.clock()+math.min(self.Config.LoadTimeout,120)
            repeat
                if not alive then return end
                token:Check()
                local plot=self:Plot()
                local models=S.Workspace:FindFirstChild("PlayerModels")
                if plot and owned(plot) then
                    prepared.Plot=plot prepared.Center=self:PlotCenter(plot)
                    local best,inlet,distance
                    for _,model in ipairs(models and models:GetChildren() or {}) do
                        if model:IsA("Model") and owned(model) and (model.Name=="Sawmill4L" or value(model,"ItemName")=="Sawmill4L") then
                            local part=model:FindFirstChild("Particles")
                            local settings=model:FindFirstChild("Settings")
                            local x,z=value(settings,"DimX"),value(settings,"DimZ")
                            if livePart(part) and finite(x) and finite(z) and x>0 and z>0 then
                                local d=(part.Position-prepared.Center.Position).Magnitude
                                if not distance or d<distance then best,inlet,distance=model,part,d end
                            end
                        end
                    end
                    if best then
                        self.MillCache={Model=best,Inlet=inlet,Plot=plot}
                        prepared.Mill=best prepared.Inlet=inlet prepared.Done=true return
                    end
                end
                token:Sleep(0.25)
            until os.clock()>=deadline
        end)
        prepared.Done=true
        if not ok and reason~=CANCEL then prepared.Error=cleanError(reason) end
    end)
    return prepared
end
function H:FindMill(token, plot)
    local cached=self.MillCache
    if self.Config.PerformanceMode and cached and cached.Plot==plot
        and under(cached.Model,S.Workspace) and owned(cached.Model)
        and (cached.Model.Name=="Sawmill4L" or value(cached.Model,"ItemName")=="Sawmill4L")
        and livePart(cached.Inlet) and under(cached.Inlet,cached.Model) then
        local settings=cached.Model:FindFirstChild("Settings")
        local x,z=value(settings,"DimX"),value(settings,"DimZ")
        if finite(x) and finite(z) and x>0 and z>0 then
            self.SelectedMill=cached.Model
            return cached.Model,cached.Inlet
        end
    end
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
            self.MillCache={Model=selected,Inlet=selectedInlet,Plot=plot}
            self:Log("Sawmill selected automatically - "..selected:GetFullName(),"INFO","Sawmill selected")
            return selected,selectedInlet
        end
        token:Sleep(0.3)
    until os.clock()>=deadline
    error("No ready owned Sawmill4L - check its Particles inlet and DimX/DimZ settings",0)
end
function H:AxeStats(tool, kind, inverse)
    local definitions = S.ReplicatedStorage:FindFirstChild("AxeClasses")
    local name = value(tool, "ToolName")
    local module = definitions and name and definitions:FindFirstChild("AxeClass_" .. tostring(name))
    if not module or not module:IsA("ModuleScript") then return end
    self.AxeStatsCache=self.AxeStatsCache or setmetatable({},{__mode="k"})
    local cached=self.AxeStatsCache[module]
    local ok,stats
    if self.Config.PerformanceMode and cached and os.clock()-cached.At<10 then
        ok,stats=true,cached.Stats
    else
        ok,stats=pcall(function() return require(module).new() end)
        if ok and type(stats)=="table" then self.AxeStatsCache[module]={Stats=stats,At=os.clock()} end
    end
    if not ok or type(stats) ~= "table" then return end
    stats = table.clone(stats)
    local special = stats.SpecialTrees and stats.SpecialTrees[kind]
    if type(special) == "table" then for k,v in pairs(special) do stats[k] = v end end
    local usable=inverse and name=="InverseAxe" and finite(stats.Damage) and stats.Damage<=0
        or not inverse and name~="InverseAxe" and finite(stats.Damage) and stats.Damage>0
    if usable and finite(stats.SwingCooldown) and stats.SwingCooldown>0 then return stats end
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
    if tool.Parent~=Player.Character then humanoid:EquipTool(tool) end
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
    local trees
    trees,regions=self:StandingTrees(token)
    ready=#trees
    local cache=self.StandingCache
    snapshot=cache.Snapshot
    for _,model in ipairs(cache.Rare) do
        local kind=value(model,"TreeClass")
        local ownerField=self:TreeContext(model)
        if self:IsStandingTree(model) and self:WantsTree(kind) and ownerField
            and (ownerField.Value==nil or (model==self.GrowthTarget and ownerField.Value==Player)) then
            local record=self.TreeWatchers[model]
            local volume=record and record.Volume
            if not volume or os.clock()-(record and record.VolumeAt or 0)>0.5 then
                volume=self:WoodVolume(model)
                if record then record.Volume=volume record.VolumeAt=os.clock() end
            end
            local trunk=self:TreeTrunk(model)
            if not self:EligibleVolume(kind,volume) then counts.IgnoredSmall=counts.IgnoredSmall+1 end
            if trunk and self:EligibleVolume(kind,volume) then
                table.insert(matches,{Model=model,Trunk=trunk,Kind=kind,Volume=volume,
                    GrowthClaimed=model==self.GrowthTarget and ownerField.Value==Player})
                counts[kind]=counts[kind]+1 counts[kind.."Volume"]=counts[kind.."Volume"]+volume
            end
        end
        inspected=inspected+1
        if inspected%64==0 and os.clock()-budgetStart>=0.004 then token:Sleep(0.001) budgetStart=os.clock() end
    end
    table.sort(matches, function(a,b)
        if self.Config.GrowSinister and a.Kind~=b.Kind then return a.Kind=="SpookyNeon" end
        return a.Volume>b.Volume
    end)
    self.Counts = counts
    local signature=string.format("%d:%.2f:%d:%.2f",counts.Spooky,counts.SpookyVolume,counts.SpookyNeon,counts.SpookyNeonVolume)
    if self.UI and signature~=self.LastScanCardSignature then
        self.LastScanCardSignature=signature
        self.UI.Spooky:Set(counts.Spooky,string.format("%.0f studs3",counts.SpookyVolume))
        self.UI.Neon:Set(counts.SpookyNeon,string.format("%.0f studs3",counts.SpookyNeonVolume))
    end
    return matches, regions, snapshot, ready
end
function H:ScanReady(token)
    local started, stableSince = os.clock(), os.clock()
    local previous, previousRegions, previousCount, previousMatches
    self:SetStage("Scanning trees", 0.04)
    repeat
        token:Check()
        if game:IsLoaded() then
            local matches, regions, snapshot, ready = self:Scan(token)
            local matched={}
            for _,entry in ipairs(matches) do matched[entry.Model]=true end
            local changed = not previous or regions ~= previousRegions or #matches ~= previousCount
            if not changed then
                for model in pairs(matched) do if not previousMatches[model] then changed=true break end end
            end
            if not changed then
                for model, kind in pairs(snapshot) do if previous[model] ~= kind then changed = true break end end
                if not changed then
                    for model in pairs(previous) do if snapshot[model] == nil then changed = true break end end
                end
            end
            if changed then stableSince = os.clock() end
            previous, previousRegions, previousCount, previousMatches = snapshot, regions, #matches, matched
            -- Positive results settle briefly; an empty result needs a longer
            -- quiet window. ScanWait is a deadline, never an unconditional sleep.
            if regions > 0 and ready > 0 and os.clock() - stableSince >= self:AdaptiveWait(#matches > 0 and self.Config.ScanSettle or self.Config.EmptyScanDelay,5) then
                self:Log(string.format("Scan complete - %.2fs / %d trees checked", os.clock()-started, ready),"DEBUG")
                if self.Counts.IgnoredSmall>0 then self:Log("Trees below "..MIN_TREE_VOLUME.." studs3 ignored - "..self.Counts.IgnoredSmall,"DEBUG") end
                local verified=self:VerifyTargets(matches)
                if #verified~=#matches then
                    previous=nil stableSince=os.clock()
                else
                    self:RecordScan(#verified)
                    return verified
                end
            end
        else stableSince = os.clock() end
        assert(os.clock()-started < self.Config.ScanWait, "World scan did not stabilize - staying in this server")
        token:Sleep(self.Config.ScanInterval)
    until false
end
function H:FindFelledLog(cut)
    if type(cut)~="table" or typeof(cut.Tree)~="Instance" or typeof(cut.Trunk)~="Instance"
        or typeof(cut.Origin)~="Vector3" then return nil end
    cut.Previous=cut.Previous or {}
    cut.Radius=finite(cut.Radius) and cut.Radius or 80
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
    -- Ancestor sends the selected CutEvent and axe payload as two arguments.
    local ok,err=pcall(proxy.FireServer,proxy,event,payload)
    if not ok then error("Axe request could not be sent - "..tostring(err),0) end
end
function H:LowestSection(model)
    local selected,index
    for _,part in ipairs(model:GetDescendants()) do
        local id=part:IsA("BasePart") and part.Name=="WoodSection" and tonumber(value(part,"ID"))
        if id and (not index or id<index) then selected,index=part,id end
    end
    return selected,index
end
-- Ancestor waits for TestPing replies after approaching. These replies allow
-- replication to catch up; they do not prove physics ownership.
function H:SyncPhysics(token,rounds,diagnostic,refresh)
    diagnostic=diagnostic or {}
    diagnostic.SyncReplies=0
    diagnostic.SyncFallback=nil
    local ping=S.ReplicatedStorage:FindFirstChild("TestPing")
    if not ping or not ping:IsA("RemoteFunction") then ping=nil end
    local deadline=os.clock()+self:AdaptiveWait(12,24)
    for _=1,rounds do
        token:Check()
        if refresh then refresh() end
        if ping then
            local remaining=deadline-os.clock()
            assert(remaining>0,"Physics synchronization timed out")
            local pingStarted=os.clock()
            local ok=token:Await(function() return pcall(ping.InvokeServer,ping) end,
                math.min(self:AdaptiveWait(3,6),remaining),refresh)
            if ok then
                self:ObserveLatency(os.clock()-pingStarted)
                diagnostic.SyncReplies=diagnostic.SyncReplies+1
            else ping=nil diagnostic.SyncFallback="TestPing rejected" end
        else diagnostic.SyncFallback=diagnostic.SyncFallback or "TestPing unavailable" end
        token:Sleep(self.Config.FastHarvest and 0.03 or 0.15)
    end
    if refresh then refresh() end
    return diagnostic.SyncReplies
end
-- Detect availability without installing hooks or altering game callbacks.
function H:DetectCapabilities()
    local available={}
    local globals={isnetworkowner=isnetworkowner,firetouchinterest=firetouchinterest,
        hooksignal=hooksignal,restoresignal=restoresignal,setstackhidden=setstackhidden,
        trampoline_call=trampoline_call,setscriptable=setscriptable,gethiddenproperty=gethiddenproperty,
        sethiddenproperty=sethiddenproperty,getproperties=getproperties,gethiddenproperties=gethiddenproperties,
        getpcdprop=getpcdprop,getcallbackmember=getcallbackmember,geteventmember=geteventmember,
        getrendersteppedlist=getrendersteppedlist}
    for _,name in ipairs({"isnetworkowner","firetouchinterest","hooksignal","restoresignal",
        "setstackhidden","trampoline_call","setscriptable","gethiddenproperty","sethiddenproperty",
        "getproperties","gethiddenproperties","getpcdprop","getcallbackmember","geteventmember","getrendersteppedlist"}) do
        available[name]=cap(name,globals[name])~=nil or (type(synAPI)=="table" and type(synAPI[name])=="function")
    end
    local drawing=Env.Drawing or Drawing
    local got,new=pcall(function() return drawing and drawing.new end)
    available["Drawing.new"]=got and type(new)=="function"
    self.DrawingFactory=available["Drawing.new"] and new or nil
    local othAPI=Env.oth or oth or (type(synAPI)=="table" and synAPI.oth)
    for _,name in ipairs({"hook","is_hooked","get_hook","replace_hook","get_root_callback","get_original_thread","is_hook_thread"}) do
        local ok,fn=pcall(function() return othAPI and othAPI[name] end)
        available["oth."..name]=ok and type(fn)=="function"
    end
    self.Capabilities=available
    return available
end

-- Retrying a single idempotent step preserves the current tree and position.
-- Modwood is deliberately excluded: its destructive sequence runs once only.
function H:LocalStep(work,label,token,callback)
    work.LocalAttempts=work.LocalAttempts or {}
    local lastError
    for attempt=1,2 do
        token:Check()
        work.Step=label
        if (work.LocalAttempts[label] or 0)>=4 then
            self.ServerExitReason="Recovery budget exhausted - "..label
            error(self.ServerExitReason,0)
        end
        work.LocalAttempts[label]=(work.LocalAttempts[label] or 0)+1
        local scope=self:Token(token)
        local result=table.pack(pcall(callback,scope))
        scope:Clean()
        if result[1] then
            work.LastCompletedStep=label
            return table.unpack(result,2,result.n)
        end
        lastError=result[2]
        if lastError==CANCEL then error(CANCEL,0) end
        token:Check()
        if self.ServerExitReason or attempt==2 then break end
        local _,humanoid=self:Character()
        humanoid.Sit=false
        self.RemoteCache={} self.MillCache=nil self.PlotCache=nil
        self:Log("Retrying "..label.." at the current task - "..cleanError(lastError),"WARNING")
        self:SetStage("Retrying "..label,self.Progress)
        token:Sleep(0.35)
    end
    error(lastError,0)
end

function H:PlanChopApproaches(model,trunk)
    local character,humanoid,root=self:Character()
    local point=trunk.CFrame:PointToWorldSpace(Vector3.new(0,-trunk.Size.Y/2+0.3,0))
    local plan={Frame=trunk.CFrame,Size=trunk.Size,Character=character,Slots={},Point=point}
    local parameters=RaycastParams.new()
    parameters.FilterType=Enum.RaycastFilterType.Exclude
    local ignore={model}
    for _,other in ipairs(S.Players:GetPlayers()) do if other.Character then ignore[#ignore+1]=other.Character end end
    parameters.FilterDescendantsInstances=ignore parameters.RespectCanCollide=true
    plan.Parameters=parameters
    local directions={Vector3.new(1,0,0),Vector3.new(0,0,1),Vector3.new(-1,0,0),Vector3.new(0,0,-1)}
    local radius=math.clamp(math.max(trunk.Size.X,trunk.Size.Z)/2+2.2,3.5,5.5)
    for index,direction in ipairs(directions) do
        local near=point+direction*radius
        local ground=S.Workspace:Raycast(near+Vector3.new(0,10,0),Vector3.new(0,-28,0),parameters)
        if ground and ground.Normal.Y>0.45 then
            local position=ground.Position+Vector3.new(0,humanoid.HipHeight+root.Size.Y/2+0.1,0)
            if not S.Workspace:Raycast(position,point-position,parameters) and (position-point).Magnitude<=9 then
                plan.Slots[index]={Frame=CFrame.lookAt(position,Vector3.new(point.X,position.Y,point.Z)),
                    Ground=ground.Instance,GroundFrame=ground.Instance:IsA("BasePart") and ground.Instance.CFrame or nil}
            end
        end
    end
    self.ChopPlans=self.ChopPlans or setmetatable({},{__mode="k"})
    self.ChopPlans[trunk]=plan
    return plan
end
function H:PositionForChop(model,trunk,token,side)
    token:Check()
    assert(livePart(trunk) and under(trunk,model),"The trunk changed before repositioning")
    local character,humanoid,root=self:Character()
    local plan=self.ChopPlans and self.ChopPlans[trunk]
    if not plan or plan.Frame~=trunk.CFrame or plan.Size~=trunk.Size or plan.Character~=character then
        plan=self:PlanChopApproaches(model,trunk)
    end
    for offset=0,3 do
        local slot=plan.Slots[((side or 1)+offset-1)%4+1]
        if slot and slot.Ground.Parent and (not slot.GroundFrame or slot.GroundFrame==slot.Ground.CFrame)
            and not S.Workspace:Raycast(slot.Frame.Position,plan.Point-slot.Frame.Position,plan.Parameters) then
            humanoid.Sit=false self:Teleport(slot.Frame)
            self:WaitResult(token,function() return (root.Position-slot.Frame.Position).Magnitude<2 end,
                0.8,"Chop approach did not settle",0.03)
            return true
        end
    end
    self.ChopPlans[trunk]=nil
    return false
end
function H:AttemptChop(model,tool,stats,token,section,height)
    token:Check()
    assert(model and under(model,S.Workspace),"The cut target is no longer in the world")
    section=section or self:LowestSection(model)
    height=height or 0.3
    assert(livePart(section) and under(section,model) and section.Size.Y>height+0.001,"No live section above the cut height")
    local id=tonumber(value(section,"ID"))
    assert(id,"The cut section has no valid ID")
    local owner=self:TreeOwner(model)
    assert(owner==nil or owner==Player,"The cut target belongs to another player")
    local _,_,event=self:TreeContext(model)
    if not event and model.Parent then event=model.Parent:FindFirstChild("CutEvent") end
    assert(event,"The cut target has no CutEvent")
    assert(tool and tool.Parent==Player.Character,"The selected axe is not equipped")
    local _,_,avatar=self:Character()
    local inverse=value(tool,"ToolName")=="InverseAxe" and stats.Damage<=0
    local standing=self:IsStandingTree(model)
    local point=(inverse or standing) and section.CFrame:PointToWorldSpace(Vector3.new(0,-section.Size.Y/2+height,0)) or section.Position
    if standing and (avatar.Position-point).Magnitude>7 then
        self:PositionForChop(model,section,token,1)
    end
    local stand=point+(inverse and Vector3.new(4,2,0) or Vector3.new(0,0,5))
    if inverse then
        local parameters=RaycastParams.new()
        parameters.FilterType=Enum.RaycastFilterType.Exclude
        parameters.FilterDescendantsInstances={model,Player.Character}
        parameters.RespectCanCollide=true
        local hit=S.Workspace:Raycast(stand+Vector3.new(0,12,0),Vector3.new(0,-35,0),parameters)
        if hit then
            local _,humanoid=self:Character()
            stand=Vector3.new(stand.X,hit.Position.Y+humanoid.HipHeight+avatar.Size.Y/2+0.1,stand.Z)
        end
    end
    if (avatar.Position-point).Magnitude>(inverse and 7 or 10) then
        self:Teleport(CFrame.lookAt(stand,point))
        token:Sleep(0.25)
    end
    token:Check()
    assert(livePart(section) and under(section,model) and section.Size.Y>height+0.001,"The cut section changed during approach")
    assert(tonumber(value(section,"ID"))==id,"The cut section ID changed during approach")
    local latestOwner=self:TreeOwner(model)
    assert(latestOwner==nil or latestOwner==Player,"The cut target changed owner during approach")
    assert(tool.Parent==Player.Character and event.Parent,"The axe or CutEvent changed during approach")
    self:FireAxe(self:Remote("Interaction","RemoteProxy"),event,{tool=tool,sectionId=id,height=height,
        faceVector=Vector3.new(1,0,0),hitPoints=stats.Damage,cooldown=stats.SwingCooldown,cuttingClass="Axe"})
    return id
end
-- Local protection for the current growth/harvest task. Only character-to-character
-- collisions are suppressed; world, wood and vehicle physics are left unchanged.
function H:ProtectHarvestCharacter(token)
    local folder=Instance.new("Folder")
    folder.Name="MidnightHarvestCharacterProtection"
    folder.Parent=S.Workspace
    local pairsByPart={}
    local active=true
    local worker
    local humanoid, seatedEnabled, sitConnection
    local function restoreHumanoid()
        if sitConnection then sitConnection:Disconnect() sitConnection=nil end
        if humanoid and humanoid.Parent then
            pcall(humanoid.SetStateEnabled,humanoid,Enum.HumanoidStateType.Seated,seatedEnabled)
        end
        humanoid=nil
    end
    token:Finally(function()
        active=false
        if worker and coroutine.status(worker)~="dead" then pcall(task.cancel,worker) end
        restoreHumanoid()
        folder:Destroy()
        table.clear(pairsByPart)
    end)
    local function refresh()
        local character=Player.Character
        local current=character and character:FindFirstChildOfClass("Humanoid")
        if current~=humanoid then
            restoreHumanoid()
            humanoid=current
            if humanoid then
                local bound=humanoid
                seatedEnabled=bound:GetStateEnabled(Enum.HumanoidStateType.Seated)
                local function standUp()
                    if active and bound.Parent and bound.Health>0 and bound.Sit then
                        bound.Sit=false
                        bound:ChangeState(Enum.HumanoidStateType.GettingUp)
                    end
                end
                sitConnection=bound:GetPropertyChangedSignal("Sit"):Connect(standUp)
                bound:SetStateEnabled(Enum.HumanoidStateType.Seated,false)
                standUp()
            end
        end
        local mine, others={},{}
        if character then
            for _,part in ipairs(character:GetChildren()) do
                if part:IsA("BasePart") then mine[part]=true end
            end
        end
        for _,other in ipairs(S.Players:GetPlayers()) do
            if other~=Player and other.Character then
                for _,part in ipairs(other.Character:GetChildren()) do
                    if part:IsA("BasePart") then others[part]=true end
                end
            end
        end
        for ownPart, links in pairs(pairsByPart) do
            for otherPart, constraint in pairs(links) do
                if not mine[ownPart] or not others[otherPart] or not constraint.Parent then
                    constraint:Destroy()
                    links[otherPart]=nil
                end
            end
            if not mine[ownPart] then pairsByPart[ownPart]=nil end
        end
        for ownPart in pairs(mine) do
            local links=pairsByPart[ownPart] or {}
            pairsByPart[ownPart]=links
            for otherPart in pairs(others) do
                if not links[otherPart] then
                    local constraint=Instance.new("NoCollisionConstraint")
                    constraint.Name="CharacterPushProtection"
                    constraint.Part0=ownPart
                    constraint.Part1=otherPart
                    constraint.Parent=folder
                    links[otherPart]=constraint
                end
            end
        end
    end
    local ok,reason=pcall(refresh)
    if not ok then self:Log("Character protection unavailable - "..tostring(reason),"WARNING") end
    worker=task.spawn(function()
        while active and self.Alive and token.Generation==self.Generation do
            task.wait(1)
            if not active then break end
            local refreshed,failure=pcall(refresh)
            if not refreshed then
                self:Log("Character protection interrupted - "..tostring(failure),"WARNING")
                break
            end
        end
    end)
end

function H:NearbyPlayerCount()
    local character=Player.Character
    local root=character and character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local count=0
    for _,other in ipairs(S.Players:GetPlayers()) do
        if other~=Player then
            local otherCharacter=other.Character
            local otherRoot=otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
            local otherHumanoid=otherCharacter and otherCharacter:FindFirstChildOfClass("Humanoid")
            if otherRoot and otherHumanoid and otherHumanoid.Health>0
                and (otherRoot.Position-root.Position).Magnitude<=50 then
                count=count+1
            end
        end
    end
    return count
end

function H:AnnounceSafetyHarvest(token)
    if token.SafetyAnnouncementAttempted then return end
    token.SafetyAnnouncementAttempted=true
    local ok,status=pcall(function()
        return token:Await(function()
            local chat=game:GetService("TextChatService")
            if chat.ChatVersion==Enum.ChatVersion.TextChatService then
                local channels=chat:FindFirstChild("TextChannels")
                local general=channels and channels:FindFirstChild("RBXGeneral")
                assert(general and general:IsA("TextChannel"),"Public chat is unavailable")
                local message=general:SendAsync("Powered by MoonClient")
                assert(message and message.Status==Enum.TextChatMessageStatus.Success,
                    "Public chat did not confirm delivery")
                return "Chat announcement delivered"
            end
            local events=S.ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
            local say=events and events:FindFirstChild("SayMessageRequest")
            assert(say and say:IsA("RemoteEvent"),"Public chat is unavailable")
            say:FireServer("Powered by MoonClient","All")
            return "Chat announcement requested"
        end,8)
    end)
    token:Check()
    if ok then self:Log(status,"DEBUG")
    else self:Log("Chat announcement unavailable - continuing safety harvest","WARNING") end
end

-- Volume stability is an observation, not proof that the tree reached its maximum size.
function H:WaitForSinisterGrowth(entry, token, parentToken)
    if entry.Kind ~= "SpookyNeon" or not self.Config.GrowSinister or entry.GrowthComplete or entry.EarlyHarvest then return end
    local tool, stats
    for _, container in pairs({Player.Character, Player:FindFirstChildOfClass("Backpack")}) do
        for _, candidate in ipairs(container:GetChildren()) do
            if candidate:IsA("Tool") and value(candidate, "ToolName") == "InverseAxe" then
                local candidateStats = self:AxeStats(candidate, entry.Kind, true)
                if candidateStats then tool, stats = candidate, candidateStats break end
            end
        end
        if tool then break end
    end
    assert(tool and stats, "Growth requires an inventory InverseAxe with non-positive damage verified from AxeClasses")
    assert(self:FindAxe(entry.Kind), "Growth requires a second, damaging axe in your inventory")
    self.GrowthTarget=entry.Model
    local started = os.clock()
    local allowance = self.Config.GrowthMaxWait + 30
    local watchdog = self.Watchdog
    token.Deadline = token.Deadline + allowance
    parentToken.Deadline = parentToken.Deadline + allowance
    self.Watchdog = false
    local growth = {Active=true, Kind=entry.Kind, Initial=entry.Volume, Volume=entry.Volume,
        Gain=0, Elapsed=0, StableFor=0, StableSeconds=self.Config.GrowthStableSeconds,
        MaxWait=self.Config.GrowthMaxWait, Hits=0, Ownership="Pending", Status="Claiming"}
    self.Growth = growth
    local finished = false
    local function finishGrowth()
        if finished then return end
        finished = true
        local elapsed = os.clock() - started
        token.Deadline = token.Deadline - allowance + elapsed
        parentToken.Deadline = parentToken.Deadline - allowance + elapsed
        growth.Active = false
        if growth.Status ~= "Stable" and growth.Status ~= "Safety harvest" then growth.Status = "Interrupted" end
        self.Watchdog = watchdog
        self.LastProgressAt = os.clock()
        self.BotWake = true
    end
    token:Finally(finishGrowth)
    self:SetStage("Waiting for Sinister growth", nil)
    self:NotifyBot("Sinister growth started", "Tracking volume while maintaining the tree with InverseAxe.", token)
    local lastChange, lastVolume = started, entry.Volume
    local nextSample, nextStrike, nextNotice = 0, 0, started + self.Config.GrowthNotifySeconds
    local unownedSince = started
    local ownershipWarned=false
    local lastOwnership=nil
    local lastOwnerField=nil
    local samples = 0
    local observedGrowth = false
    local crowd={ThreeSeconds=0,FourSeconds=0,LastSample=nil,PreviousCount=0,NextSample=0}
    while os.clock() - started < self.Config.GrowthMaxWait do
        token:Check()
        local tree = entry.Model
        assert(self:IsStandingTree(tree), "Growth target was removed, detached or cut")
        assert(value(tree, "TreeClass") == entry.Kind, "Growth target class changed")
        local owner,ownerField = self:TreeOwner(tree)
        growth.OwnerPath=ownerField and ownerField:GetFullName() or "Owner not replicated"
        growth.OwnerValue=owner==Player and "LocalPlayer" or owner and owner:GetFullName() or "Unowned"
        local lastInteraction=ownerField and value(ownerField,"LastInteraction") or nil
        growth.LastInteraction=finite(lastInteraction) and lastInteraction or nil
        if ownerField~=lastOwnerField then
            self:Log("Growth owner source - "..growth.OwnerPath,"DEBUG")
            lastOwnerField=ownerField
        end
        assert(owner == nil or owner == Player, "Growth target belongs to another player - "..growth.OwnerPath)
        if owner == Player then
            unownedSince = nil
            entry.GrowthClaimed = true
            growth.Ownership = "Confirmed"
            if lastOwnership~="Confirmed" then
                self.LastConfirmedMilestone="Sinister ownership confirmed"
                self:NotifyBot("Sinister ownership confirmed",string.format("Owner.Value matches your player - %.2f studs3. Growth monitoring continues.",growth.Volume),token)
            end
            ownershipWarned=false
        else
            unownedSince = unownedSince or os.clock()
            growth.Ownership = ownerField and "Unconfirmed" or "Owner unavailable"
            if os.clock()-unownedSince>=30 and not ownershipWarned then
                ownershipWarned=true
                self:NotifyBot("Sinister claim pending","Owner is not confirmed yet. Continuing InverseAxe hits and growth observation. Source: "..growth.OwnerPath,token)
                self:Log("Sinister owner pending - continuing observation, no server hop","WARNING")
            end
        end
        lastOwnership=growth.Ownership
        local trunk = self:TreeTrunk(tree)
        assert(livePart(trunk) and tonumber(value(trunk, "ID")) == 1, "Growing trunk is unavailable")
        entry.Trunk = trunk
        local now=os.clock()
        if now>=crowd.NextSample then
            local nearby=self:NearbyPlayerCount()
            local gap=crowd.LastSample and now-crowd.LastSample or 0
            -- Missing samples and long client stalls cannot prove continuous presence.
            if nearby==nil or gap>3 then
                crowd.ThreeSeconds,crowd.FourSeconds=0,0
            else
                crowd.ThreeSeconds=nearby>=3 and (crowd.PreviousCount>=3 and crowd.ThreeSeconds+gap or 0) or 0
                crowd.FourSeconds=nearby>=4 and (crowd.PreviousCount>=4 and crowd.FourSeconds+gap or 0) or 0
            end
            crowd.PreviousCount=nearby or 0
            crowd.LastSample=now
            crowd.NextSample=now+0.5
            growth.NearbyPlayers=nearby or 0
            growth.CrowdSeconds=math.floor(crowd.ThreeSeconds)
            growth.LargeCrowdSeconds=math.floor(crowd.FourSeconds)
            local reason
            if crowd.FourSeconds>=120 then reason="4 or more nearby players for 2 minutes"
            elseif crowd.ThreeSeconds>=300 then reason="3 or more nearby players for 5 minutes" end
            if reason then
                local current=self:WoodVolume(tree)
                assert(finite(current) and current>0,"Safety harvest target has no wood")
                entry.Volume=current
                entry.EarlyHarvest=true
                entry.EarlyHarvestReason=reason
                growth.Volume,growth.Gain=current,current-growth.Initial
                growth.Elapsed=now-started
                growth.Status="Safety harvest"
                self:SetStage("Safety harvest",nil,reason)
                self:Log("Safety harvest - "..reason,"WARNING")
                self:AnnounceSafetyHarvest(token)
                finishGrowth()
                self:NotifyBot("Sinister safety harvest",string.format(
                    "%s within 50 studs. Harvesting %.2f studs3 before growth completes; processing, delivery and saving will follow.",
                    reason,current),token)
                return
            end
        end
        if tool.Parent ~= Player.Character then
            assert(tool.Parent == Player:FindFirstChildOfClass("Backpack"), "InverseAxe left the inventory")
            local _, humanoid = self:Character()
            humanoid:EquipTool(tool)
            token:Sleep(0.15)
            assert(tool.Parent == Player.Character, "InverseAxe could not be equipped")
        end
        if os.clock() >= nextStrike then
            -- Keep the game's actual non-positive damage and cooldown; never use a damaging axe here.
            self:AttemptChop(tree, tool, stats, token, trunk, math.min(0.3, trunk.Size.Y * 0.25))
            growth.Hits = growth.Hits + 1
            nextStrike = os.clock() + math.max(0.25, stats.SwingCooldown) + 0.05
        end
        if os.clock() >= nextSample then
            local current = self:WoodVolume(tree)
            assert(finite(current) and current > 0, "Growing tree volume is unavailable")
            -- Compare against the last significant sample so tiny increases accumulate.
            if current > growth.Initial + 0.001 then observedGrowth = true end
            if current < lastVolume - math.max(0.1, lastVolume * 0.02) then
                error("Growing tree lost wood - growth observation interrupted", 0)
            end
            if math.abs(current - lastVolume) > 0.001 then lastChange, lastVolume = os.clock(), current end
            if self.Counts then
                self.Counts.SpookyNeonVolume=math.max(0,self.Counts.SpookyNeonVolume+current-growth.Volume)
            end
            growth.Volume, growth.Gain = current, current - growth.Initial
            growth.Elapsed, growth.StableFor = os.clock() - started, os.clock() - lastChange
            growth.Status = owner==Player and "Observing" or "Claiming"
            samples = samples + 1
            self:UpdateHarvestProgress(0, string.format("Sinister %.2f studs3 - unchanged %ds / %ds",
                current, math.floor(growth.StableFor), self.Config.GrowthStableSeconds))
            if self.UI then self.UI.Neon:Set(self.Counts and self.Counts.SpookyNeon or 1, string.format("Growing: %.2f studs3", current)) end
            nextSample = os.clock() + 1
            if owner == Player and samples >= 5 and growth.Elapsed >= self.Config.GrowthMinWait
                and growth.StableFor >= self.Config.GrowthStableSeconds
                and (observedGrowth or growth.Elapsed >= 11820) then
                assert(current>=MIN_TREE_VOLUME,"Sinister stabilized below the 60 studs3 harvest minimum")
                entry.Volume = current
                entry.GrowthComplete = true
                growth.Active, growth.Status = false, "Stable"
                finishGrowth()
                self:NotifyBot("Sinister growth stable", string.format(
                    "%.2f -> %.2f studs3 (%+.2f). Unchanged for %ds. Switching to the harvest axe.",
                    growth.Initial, current, growth.Gain, math.floor(growth.StableFor)), token)
                return
            end
        end
        if os.clock() >= nextNotice then
            self:NotifyBot("Sinister growth update", string.format("%.2f studs3 (%+.2f) - observed for %s - unchanged %ds.",
                growth.Volume, growth.Gain, duration(growth.Elapsed), math.floor(growth.StableFor)), token)
            nextNotice = os.clock() + self.Config.GrowthNotifySeconds
        end
        token:Sleep(0.1)
    end
    error("Sinister growth time limit reached - owner: "..growth.Ownership.." - "..(growth.OwnerPath or "Unknown owner path").." - stable owned growth was not confirmed", 0)
end

function H:Chop(entry, tool, stats, token, checkpoint)
    local tree, trunk=entry.Model,entry.Trunk
    self:CheckTargetOwner(entry)
    assert(tree and trunk,"The selected tree has no recorded trunk")
    local logs=S.Workspace:FindFirstChild("LogModels") assert(logs,"LogModels missing")
    local cut=checkpoint and checkpoint.Cut
    if not cut then
        assert(self:IsStandingTree(tree) and livePart(trunk) and under(trunk,tree) and (self:TreeOwner(tree)==nil or (entry.GrowthClaimed and self:TreeOwner(tree)==Player)),"The selected tree is no longer available")
        cut={Tree=tree,Trunk=trunk,Kind=entry.Kind,Origin=trunk.Position,Radius=math.max(80,trunk.Size.Y),
            Previous={},Strikes=0,Started=os.clock()}
        for _, model in ipairs(logs:GetChildren()) do cut.Previous[model]=true end
        if checkpoint then checkpoint.Cut=cut end
    end
    self.LastCut=cut
    cut.LastEvidenceAt=os.clock()
    cut.LastPositionAt=os.clock()
    cut.Repositions=cut.Repositions or 0
    local _,initialOwnerField=self:TreeOwner(tree)
    cut.LastInteraction=initialOwnerField and value(initialOwnerField,"LastInteraction")
    cut.LastOwner=self:TreeOwner(tree)
    local deadline=os.clock()+self.Config.ChopTimeout
    local nextStrike, nextPosition, nextStatus=0,0,os.clock()+5
    local detachedAt
    self:Log(string.format("Cut setup - axe=%s; damage=%.3f; cooldown=%.3f; height=0.3; section=%s",
        tostring(value(tool,"ToolName") or tool.Name),stats.Damage,stats.SwingCooldown,tostring(value(trunk,"ID"))),"DEBUG")
    repeat
        token:Check()
        self:CheckTargetOwner(entry)
        local found=self:FindFelledLog(cut)
        if found then
            self:Log(string.format("Felled wood confirmed - %d strikes / %.1fs",cut.Strikes,os.clock()-cut.Started),"INFO","Tree cut")
            cut.Result=found
            return found
        end
        local rootCut=tree:FindFirstChild("RootCut")~=nil
        local detached=rootCut or not tree.Parent or not trunk.Parent
        if detached and not detachedAt then detachedAt=os.clock() end
        local owner,ownerField=self:TreeOwner(tree)
        local interaction=ownerField and value(ownerField,"LastInteraction")
        if owner~=cut.LastOwner or (interaction~=nil and interaction~=cut.LastInteraction) then
            cut.LastEvidenceAt=os.clock()
            cut.LastOwner=owner cut.LastInteraction=interaction
        end
        assert(owner==nil or owner==Player,"Another player now owns the selected tree")
        if not detached and (owner==nil or owner==Player) then
            local event=tree:FindFirstChild("CutEvent")
            assert(event,"The selected tree has no CutEvent")
            if tool.Parent~=Player.Character then
                local backpack=Player:FindFirstChildOfClass("Backpack")
                assert(tool.Parent==backpack,"The selected axe is no longer in your inventory")
                local _,humanoid=self:Character()
                humanoid:EquipTool(tool)
                self:WaitResult(token,function() return tool.Parent==Player.Character end,2,"The selected axe could not be re-equipped")
            end
            -- Re-approach the same base cut when replication shows no activity.
            -- Ownership/LastInteraction are observations, not damage receipts.
            if os.clock()>=nextPosition then
                local _,_,avatar=self:Character()
                local base=trunk.CFrame:PointToWorldSpace(Vector3.new(0,-trunk.Size.Y/2+0.3,0))
                local quiet=cut.Strikes>=3 and (os.clock()-cut.LastEvidenceAt>=math.max(3,stats.SwingCooldown*4)
                    or os.clock()-cut.LastPositionAt>=math.max(8,stats.SwingCooldown*10))
                local needPosition=not cut.Synchronized or (avatar.Position-base).Magnitude>7 or quiet
                local moved=false
                if needPosition then
                    moved=self:PositionForChop(tree,trunk,token,cut.Repositions%4+1)
                    if moved then
                        cut.Repositions=cut.Repositions+1
                        cut.LastEvidenceAt=os.clock()
                        cut.LastPositionAt=os.clock()
                        if quiet then
                            self:Log("Cut reposition - felling remains unconfirmed; retrying the same trunk","DEBUG")
                            local _,humanoid=self:Character()
                            humanoid:EquipTool(tool)
                        end
                    end
                end
                if not cut.Synchronized or moved then
                    if self.Config.FastHarvest then
                        -- Send the first targeted strike after one scheduler frame,
                        -- without eight synchronous round trips in front of it.
                        token:Sleep(0.03)
                    else self:SyncPhysics(token,cut.Synchronized and 2 or 8,cut) end
                    cut.Synchronized=true
                    -- Replication may have produced the felled log during the wait.
                    found=self:FindFelledLog(cut)
                    if found then cut.Result=found return found end
                end
                nextPosition=os.clock()+0.75
            end
            if os.clock()>=nextStrike then
                if self.Config.FastHarvest and cut.Strikes>=3 and not cut.RecoverySynced and owner==nil then
                    self:SyncPhysics(token,2,cut)
                    cut.RecoverySynced=true
                    found=self:FindFelledLog(cut)
                    if found then cut.Result=found return found end
                end
                token:Check()
                cut.Strikes=cut.Strikes+1
                local sectionId=tonumber(value(trunk,"ID"))
                assert(sectionId==1,"The selected section is not the base trunk")
                self:AttemptChop(tree,tool,stats,token,trunk,0.3)
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
        self.CutDiagnostic=string.format("Cut diagnostic - %s\n%s\naxe=%s; damage=%.3f; cooldown=%.3f; centerDistance=%.2f; equipped=%s; repositions=%d; interaction=%s",
            cut.Kind,cut.Status,tostring(value(tool,"ToolName") or tool.Name),stats.Damage,stats.SwingCooldown,
            distance,tostring(tool.Parent==Player.Character),cut.Repositions,tostring(cut.LastInteraction))
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
                ..string.format("; control=%s; TestPing replies=%d",record.NetworkStatus or "Not checked",record.SyncReplies or 0)
        end
    end)
    local drag=self:Remote("Interaction","ClientIsDragging")
    local part=partOf(model)
    self:AcquireWood(model,part,token,record)
    local restore=self:QuietWood(model,token)
    -- Do not let gravity carry the wood through the plot while collisions are off.
    local suspended=false
    local suspension=S.RunService.PreSimulation:Connect(function()
        if suspended and self.Alive and self.Running and token.Generation==self.Generation
            and model.Parent and owned(model) then self:DampWood(model) end
    end)
    local function releaseSuspension()
        suspended=false
        suspension:Disconnect()
    end
    token:Finally(releaseSuspension)
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
            suspended=true
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
    releaseSuspension()
    -- Observe restored collisions too; a local placement is not delivery proof.
    for _=1,5 do
        token:Sleep(0.15)
        assert(model.Parent and owned(model),"Wood changed after placement")
        assert((model:GetPivot().Position-destination.Position).Magnitude<5,"Wood shifted after placement")
        self:DampWood(model)
    end
    record.Settled=true
end
local function worldBoundsSize(frame,size)
    local right,up,back=frame.RightVector,frame.UpVector,frame.LookVector
    return Vector3.new(
        math.abs(right.X)*size.X+math.abs(up.X)*size.Y+math.abs(back.X)*size.Z,
        math.abs(right.Y)*size.X+math.abs(up.Y)*size.Y+math.abs(back.Y)*size.Z,
        math.abs(right.Z)*size.X+math.abs(up.Z)*size.Y+math.abs(back.Z)*size.Z)
end
function H:BringTreeToBase(log, plot, token, plannedCenter)
    local owner = plot and plot:FindFirstChild("Owner")
    assert(owner and owner:IsA("ObjectValue") and owner.Value == Player, "Your plot is no longer owned")
    self:SetStage("Bringing tree to your base", 0.43)
    local center = plannedCenter or self:PlotCenter(plot)
    local bounds, size = log:GetBoundingBox()
    local relative = log:GetPivot():ToObjectSpace(bounds)
    local height=worldBoundsSize(bounds,size).Y
    local target = CFrame.new(center.Position.X, center.Position.Y + height/2 + 4, center.Position.Z)
        * bounds.Rotation * relative:Inverse()
    self:Move(log, target, token)
    self:Log("Felled tree delivered to your plot before Modwood","INFO","Tree delivered")
end
function H:ModwoodParts(log)
    local sections,ordered,children={},{},{}
    for _,part in ipairs(log:GetDescendants()) do
        if part:IsA("BasePart") and part.Name=="WoodSection" then
            local id=tonumber(value(part,"ID"))
            if not id or sections[id] then return nil,nil,nil,"Missing or duplicate section IDs" end
            sections[id]=part ordered[#ordered+1]=part
            local parentID=tonumber(value(part,"ParentID"))
            if parentID then children[parentID]=(children[parentID] or 0)+1 end
        end
    end
    local root=sections[1]
    if not root then return nil,nil,nil,"Waiting for root section 1" end
    local leaf,burn,selectedID
    for _,part in ipairs(ordered) do
        local id=tonumber(value(part,"ID"))
        local parent=sections[tonumber(value(part,"ParentID"))]
        if not children[id] and parent and parent~=root and part.Size.Y>0.1 and (not selectedID or id>selectedID) then
            local cursor,seen=part,{}
            while cursor and cursor~=root and not seen[cursor] do
                seen[cursor]=true cursor=sections[tonumber(value(cursor,"ParentID"))]
            end
            if cursor==root then leaf,burn,selectedID=part,parent,id end
        end
    end
    if not leaf then return nil,nil,nil,"Modwood unavailable - no terminal branch with a non-trunk parent" end
    return root,leaf,burn
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
function H:WaitForModwood(log,token)
    if not log or not log.Parent or not owned(log) then return false,"Felled wood is no longer owned" end
    local volume=self:WoodVolume(log)
    if not finite(volume) or volume<MIN_TREE_VOLUME then
        return false,string.format("Modwood skipped - %.2f studs3; minimum %d",volume or 0,MIN_TREE_VOLUME)
    end
    self:SetStage("Checking felled tree",0.48)
    local deadline=os.clock()+self:AdaptiveWait(self.Config.MetadataTimeout,90)
    local previous,stableSince,reason
    repeat
        token:Check()
        if not log.Parent or not owned(log) then return false,"Felled tree is no longer owned" end
        local root,leaf,parent,problem=self:ModwoodParts(log)
        if root then
            -- The validated trial uses ParentID topology; stale ChildIDs metadata
            -- must not reject an otherwise complete, consistent selection.
            local signature=tostring(value(root,"ID"))..":"..tostring(value(leaf,"ID"))..":"..tostring(value(parent,"ID"))
            if signature~=previous then previous=signature stableSince=os.clock() end
            if not root.Anchored and os.clock()-stableSince>=0.15 then
                if cap("firetouchinterest",firetouchinterest) then return true end
                return false,"Modwood unavailable - firetouchinterest missing"
            end
        else
            local count=#log:GetDescendants()
            local signature=tostring(problem)..":"..count
            if signature~=previous then previous=signature stableSince=os.clock() end
            if problem and problem:find("no terminal branch",1,true) and os.clock()-stableSince>=0.4 then
                self:CaptureModwood(log,nil,problem)
                return false,problem
            end
        end
        reason=problem or "Waiting for an unanchored root and consistent branch data"
        self.LoadDiagnostic="Felled wood - "..reason
        token:Sleep(0.05)
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
    local lines={string.format("Spooky Hunter %s\nCaptured (UTC): %s\nServer: %s\nSlot: %d\nHistory records: %d/1000\nPending wood: %d\nStage: %s\nRunning: %s\nAnti-AFK pulses: %d",
        self.Version,os.date("!%Y-%m-%d %H:%M:%S"),game.JobId,self.Config.Slot,#self.ServerHistory,#self.PendingWood,
        self.Stage,tostring(self.Running),self.IdlePulses or 0)}
    table.insert(lines,string.format("Visit exclusion: %.1fh; harvest exclusion: %.1fh\nScanned: %d; found servers: %d; found trees: %d; harvested: %d\nTracker finds/scans: %d/%d; standard finds/scans: %d/%d\nAdaptive timing: %s; observed RTT: %s",
        self.Config.VisitCooldownHours,self.Config.HarvestCooldownHours,self.Stats.Scanned,self.Stats.FoundServers,
        self.Stats.FoundTrees,self.Stats.Harvested,self.Stats.TrackerFinds,self.Stats.TrackerScans,
        self.Stats.StandardFinds,self.Stats.StandardScans,tostring(self.Config.AdaptiveTiming),
        self.ServerRTT and string.format("%.3fs",self.ServerRTT) or "Not measured"))
    table.insert(lines,"Targets: "..self.Config.TargetSpecies.."; growth: "..tostring(self.Config.GrowSinister).."; auto rejoin: "..tostring(self.Config.AutoRejoin))
    table.insert(lines,string.format("Live validation: rejected targets=%d; pruned tasks=%d; recovery attempts=%d\nLast discarded task: %s",
        self.RejectedTargets or 0,self.PrunedTasks or 0,self.RecoveryState and self.RecoveryState.Attempts or 0,
        self.LastPrunedTask or "None"))
    local capabilities=self:DetectCapabilities()
    local names={}
    for name in pairs(capabilities) do names[#names+1]=name end
    table.sort(names)
    local capabilityLines={"Executor APIs (presence only, not proof of functionality):"}
    for _,name in ipairs(names) do capabilityLines[#capabilityLines+1]=name..": "..(capabilities[name] and "Available" or "Missing") end
    capabilityLines[#capabilityLines+1]="Markers: "..tostring(self.MarkerBackend or "Not initialized")
    capabilityLines[#capabilityLines+1]="Touch argument mode: "..tostring(self.TouchArgumentMode or "Not selected")
    capabilityLines[#capabilityLines+1]="Hooks, stack masking and hidden-property writes: not installed"
    table.insert(lines,table.concat(capabilityLines,"\n"))
    table.insert(lines,string.format("Performance mode: %s; server prefetch: %s\nLast server lookup: %s; candidate cache hits: %d\nSearch budget: %.0fs; maximum pages: %d",
        tostring(self.Config.PerformanceMode),tostring(self.Config.PrefetchServers),
        self.LastServerSearchSeconds and string.format("%.2fs",self.LastServerSearchSeconds) or "Not measured",
        self.ServerCacheHits or 0,self.Config.ServerSearchBudget,self.Config.PublicPageLimit))
    if self.ServerSearchDiagnostic then table.insert(lines,"Last server lookup note: "..self.ServerSearchDiagnostic) end
    local timings={}
    for stage,seconds in pairs(self.StageTimes or {}) do timings[#timings+1]={Stage=stage,Seconds=seconds} end
    table.sort(timings,function(a,b) return a.Seconds>b.Seconds end)
    for index=1,math.min(5,#timings) do
        table.insert(lines,string.format("Time in %s: %.2fs",timings[index].Stage,timings[index].Seconds))
    end
    if self.Growth then
        table.insert(lines,string.format("Sinister growth: %s; volume: %.3f; gain: %.3f; elapsed: %.0fs; stable: %.0fs; owner: %s",
            self.Growth.Status,self.Growth.Volume,self.Growth.Gain,self.Growth.Elapsed,self.Growth.StableFor,self.Growth.Ownership))
        table.insert(lines,"Growth owner path: "..tostring(self.Growth.OwnerPath).."\nOwner value: "..tostring(self.Growth.OwnerValue)
            .."\nLastInteraction: "..tostring(self.Growth.LastInteraction).."\nInverseAxe requests: "..tostring(self.Growth.Hits))
    end
    if self.TargetOwnerDiagnostic then table.insert(lines,"Target ownership evidence\n"..self.TargetOwnerDiagnostic) end
    if self.LastFailure then
        table.insert(lines,"Failure code: "..(self.LastFailure.Code or "Unavailable")
            .."\nLast confirmed: "..(self.LastFailure.LastConfirmed or "Unavailable")
            .."\nWaiting for: "..(self.LastFailure.WaitingFor or self.LastFailure.Stage))
        table.insert(lines,"Last failure (UTC): "..self.LastFailure.Time.."\nFailed stage: "..self.LastFailure.Stage.."\nReason: "..self.LastFailure.Reason)
    end
    table.insert(lines,string.format("Minimum volume: %d studs3\nHop delay: %.2fs\nAutomatic recovery: %ss without confirmed progress\nAbandoned tasks: %d\nUI version: %s",
        MIN_TREE_VOLUME,self.Config.HopDelay,STALL_TIMEOUT,self.AbandonedTasks or 0,self.Midnight and self.Midnight.Version or "unavailable"))
    table.insert(lines,"Server finder: "..(self.Config.TrackerEnabled and "Oldest observed" or "Standard")
        .."\nTracker: "..tostring(self.TrackerStatus or "Not queried")
        .."\nServer source: "..tostring(self.ServerSource or "Not selected"))
    local cycle=self:EnsureServerCycle()
    local visitCount=0
    for _ in pairs(cycle.Visited) do visitCount=visitCount+1 end
    table.insert(lines,string.format("Oldest-server cycle: %d visited; reset in %s\nCached old candidates: %d\nStandard fallback: %s\nTeleport queue: %s",
        visitCount,duration(math.max(0,cycle.StartedAt+SERVER_CYCLE_SECONDS-os.time())),
        #self:CachedOldServers(),tostring(self.Config.TrackerAllowFallback),self.QueueBackend or "Not armed"))
    table.insert(lines,"Gameplay reference: supplied Ancestor script\nModwood policy: one attempt; leave on failure")
    if self.ServerExitReason then table.insert(lines,"Pending server departure: "..self.ServerExitReason) end
    if self.MoveDiagnostic then table.insert(lines,self.MoveDiagnostic) end
    if self.LoadDiagnostic then table.insert(lines,"Readiness: "..self.LoadDiagnostic) end
    table.insert(lines,"Activity (UTC)\n"..table.concat(self.Logs,"\n"))
    for _,diagnostic in ipairs({self.CutDiagnostic or "",self.ModwoodDiagnostic or "",self.ModwoodRuntimeDiagnostic or ""}) do
        if diagnostic~="" then table.insert(lines,diagnostic) end
    end
    for index,work in ipairs(self.PendingWood) do
        table.insert(lines,"Task "..index.." - "..tostring(work.Kind).." - "..tostring(work.Reason or "In progress"))
        table.insert(lines,"Current step: "..tostring(work.Step or "Unknown").."; last completed: "..tostring(work.LastCompletedStep or "None"))
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
    table.insert(lines,"Discord bot: "..tostring(self.BotStatus or "Not connected"))
    if self.LastDisconnect then
        table.insert(lines,"Confirmed disconnect: "..self.LastDisconnect.Code.."\nInterrupted stage: "..self.LastDisconnect.Stage)
    end
    local text=table.concat(lines,"\n\n")
    if self.Config.TrackerToken~="" then text=text:gsub(self.Config.TrackerToken:gsub("([^%w])","%%%1"),"[tracker key]") end
    if self.Config.BotKey~="" then text=text:gsub(self.Config.BotKey:gsub("([^%w])","%%%1"),"[client key]") end
    return text
end
-- Executor ownership checks are advisory. Ancestor's supplied implementation
-- effectively uses four TestPing replies instead. Confirm actual stage results
-- (ignition, separation, output) rather than treating either signal as proof.
function H:AcquireWood(model,part,token,diagnostic,finished)
    diagnostic=diagnostic or {}
    local networkOwner=cap("isnetworkowner",isnetworkowner)
    local drag=self:Remote("Interaction","ClientIsDragging")
    local complete,confirmed=false,false
    local lastDrag=-math.huge
    local function refresh()
        token:Check()
        if finished and finished() then complete=true return end
        assert(livePart(part) and under(part,model) and under(model,S.Workspace) and owned(model),
            "Wood changed while acquiring control")
        assert(not part.Anchored,"Selected wood is anchored")
        local _,_,avatar=self:Character()
        diagnostic.AvatarDistance=(avatar.Position-part.Position).Magnitude
        if diagnostic.AvatarDistance>9 then self:Teleport(part.CFrame+Vector3.new(5,3,0)) end
        if os.clock()-lastDrag>=0.15 then
            drag:FireServer(model) lastDrag=os.clock() diagnostic.LastDrag=lastDrag
        end
        if networkOwner then
            local ok,result=pcall(networkOwner,part)
            if not ok then networkOwner=nil confirmed=false
            else confirmed=result==true end
        end
        diagnostic.NetworkStatus=confirmed and "Executor confirmed" or "Unconfirmed - synchronizing"
    end
    refresh()
    if complete then return false end
    self:SyncPhysics(token,confirmed and 1 or 4,diagnostic,refresh)
    if complete then return false end
    diagnostic.NetworkStatus=confirmed and "Executor confirmed" or "Ancestor synchronization - result pending"
    return true
end

-- Ancestor keeps flight active for the complete Modwood sequence. This scoped
-- equivalent holds an unanchored avatar and is removed on every exit path.
function H:ModwoodHover(token,diagnostic)
    token:Check()
    assert(not self.ModwoodGuard,"A Modwood movement guard is already active")
    local character,humanoid,avatar=self:Character()
    local original={Frame=character:GetPivot(),Anchored=avatar.Anchored==true,
        PlatformStand=humanoid.PlatformStand,AutoRotate=humanoid.AutoRotate}
    local guard={Character=character,Avatar=avatar,Generation=token.Generation,Active=true,
        Target=avatar.CFrame,ReturnFrame=original.Frame,Rescues=0}
    local saved,objects,connection,added={},{},nil,nil
    local floor=S.Workspace.FallenPartsDestroyHeight
    guard.MinimumY=finite(floor) and floor+100 or -400
    local position,orientation
    local function zeroVelocity()
        avatar.AssemblyLinearVelocity=Vector3.zero
        avatar.AssemblyAngularVelocity=Vector3.zero
    end
    local function validate(frame)
        local p=frame.Position
        assert(finite(p.X) and finite(p.Y) and finite(p.Z) and math.abs(p.X)<1000000 and math.abs(p.Z)<1000000,
            "Modwood - invalid movement target")
        assert(p.Y>guard.MinimumY,"Modwood - movement toward the void blocked")
        assert(H:ClearOfLava(p,5),"Modwood - character movement into lava blocked")
    end
    function guard:Release()
        if not self.Active then return end
        self.Active=false
        if self.Failure then token.ModwoodFailure=self.Failure end
        if connection then connection:Disconnect() end
        if added then added:Disconnect() end
        if H.ModwoodGuard==self then H.ModwoodGuard=nil end
        -- Return while support still exists; never release above the remote work area.
        if Player.Character==character and character.Parent and avatar.Parent and humanoid.Health>0 then
            pcall(function()
                validate(self.ReturnFrame)
                character:PivotTo(self.ReturnFrame)
                zeroVelocity()
            end)
        end
        for i=#objects,1,-1 do pcall(function() objects[i]:Destroy() end) end
        for part,collision in pairs(saved) do
            if part.Parent then pcall(function() part.CanCollide=collision end) end
        end
        if humanoid.Parent then
            humanoid.PlatformStand=original.PlatformStand
            humanoid.AutoRotate=original.AutoRotate
        end
        if avatar.Parent then avatar.Anchored=original.Anchored end
        diagnostic.HoverActive=false
    end
    token:Finally(function() guard:Release() end)
    function guard:Check()
        assert(self.Active and not self.Failure,self.Failure or "Modwood movement support stopped")
        assert(Player.Character==character and avatar.Parent and humanoid.Health>0,"Modwood character changed")
    end
    function guard:BeforeMove(frame)
        self:Check() validate(frame)
        if position then position.Position=frame.Position end
    end
    function guard:Hold(frame)
        self:Check() validate(frame)
        self.Target=frame
        if position then position.Position=frame.Position end
        if orientation then orientation.CFrame=frame end
        zeroVelocity()
    end
    local function suppress(part)
        if part:IsA("BasePart") and saved[part]==nil then
            saved[part]=part.CanCollide part.CanCollide=false
        end
    end
    validate(avatar.CFrame)
    for _,part in ipairs(character:GetDescendants()) do suppress(part) end
    added=character.DescendantAdded:Connect(suppress)
    local attachment=Instance.new("Attachment")
    table.insert(objects,attachment)
    attachment.Name="MidnightModwoodHoverAttachment" attachment.Parent=avatar
    position=Instance.new("BodyPosition") table.insert(objects,position)
    position.Name="MidnightModwoodHoverPosition" position.MaxForce=Vector3.new(1e7,1e7,1e7)
    position.P=30000 position.D=1600 position.Position=avatar.Position position.Parent=avatar
    orientation=Instance.new("BodyGyro") table.insert(objects,orientation)
    orientation.Name="MidnightModwoodHoverOrientation" orientation.MaxTorque=Vector3.new(1e7,1e7,1e7)
    orientation.P=30000 orientation.D=1000 orientation.CFrame=avatar.CFrame orientation.Parent=avatar
    humanoid.Sit=false humanoid.PlatformStand=true humanoid.AutoRotate=false
    avatar.Anchored=false
    self.ModwoodGuard=guard
    diagnostic.HoverActive=true diagnostic.HoverRescues=0
    guard:Hold(avatar.CFrame)
    connection=(S.RunService.PreSimulation or S.RunService.Heartbeat):Connect(function()
        if not guard.Active then return end
        if not H.Alive or not H.Running or H.Generation~=guard.Generation then guard:Release() return end
        if Player.Character~=character or not avatar.Parent or humanoid.Health<=0 then
            guard.Failure="Modwood character changed" guard:Release() return
        end
        local ok=pcall(function()
            assert(position.Parent==avatar and orientation.Parent==avatar and attachment.Parent==avatar)
            local p=avatar.Position
            validate(guard.Target)
            local nearLava=not H:ClearOfLava(p,5)
            assert(finite(p.X) and finite(p.Y) and finite(p.Z))
            if nearLava or p.Y<guard.MinimumY or (p-guard.Target.Position).Magnitude>5 then
                guard.Rescues=guard.Rescues+1 diagnostic.HoverRescues=guard.Rescues
                if guard.Rescues>8 then
                    guard.Failure="Modwood - repeated character displacement; changing server"
                    guard:Release() return
                end
                -- Move the model so its root returns to the recorded root frame.
                character:PivotTo(guard.Target*avatar.CFrame:Inverse()*character:GetPivot())
            end
            humanoid.PlatformStand=true humanoid.AutoRotate=false
            position.Position=guard.Target.Position
            zeroVelocity()
        end)
        if not ok then guard.Failure="Modwood movement support unavailable" guard:Release() end
    end)
    return guard
end

function H:FindLava(token)
    local expected=Vector3.new(-1675.2002,255.002533,1284.19983)
    local function valid(part)
        return livePart(part) and part.Name=="Lava" and (part.Position-expected).Magnitude<=5
            and part.CanTouch and part:FindFirstChildWhichIsA("TouchTransmitter")
            and part.Parent:FindFirstChild("LavaLayer") and part.Parent:FindFirstChild("BasePlate")
    end
    if valid(self.SelectedLava) then return self.SelectedLava end
    local lava=self:WaitResult(token,function()
        local region=S.Workspace:FindFirstChild("Region_Volcano")
        local selected,distance
        for _,part in ipairs(region and region:GetDescendants() or {}) do
            if part:IsA("BasePart") and valid(part) then
                local d=(part.Position-expected).Magnitude
                if not distance or d<distance then selected,distance=part,d end
            end
        end
        return selected
    end,math.min(self.Config.MetadataTimeout,10),"Exact recorded Lava with TouchInterest is unavailable",0.15)
    local hazards={}
    local region=S.Workspace:FindFirstChild("Region_Volcano")
    for _,part in ipairs(region:GetDescendants()) do
        if part:IsA("BasePart") and (part.Name=="Lava" or part.Name=="LavaLayer") then hazards[#hazards+1]=part end
    end
    self.ModwoodLavaHazards=hazards self.SelectedLava=lava
    self:Log("Recorded lava selected - "..lava:GetFullName(),"DEBUG")
    return lava
end
function H:ClearOfLava(position,radius)
    for _,lava in ipairs(self.ModwoodLavaHazards or {}) do
        if livePart(lava) then
            local point=lava.CFrame:PointToObjectSpace(position)
            local half=lava.Size*0.5
            local outside=Vector3.new(math.max(0,math.abs(point.X)-half.X),
                math.max(0,math.abs(point.Y)-half.Y),math.max(0,math.abs(point.Z)-half.Z))
            if outside.Magnitude<=radius then return false end
        end
    end
    return true
end
function H:MarkModwood(root,leaf,parent,token)
    if not self.Config.ModwoodHighlights then return end
    self:DetectCapabilities()
    local factory=self.DrawingFactory
    local effects,groups={},{}
    local connection
    local closed=false
    local entries={{leaf,Color3.fromRGB(74,124,255)},
        {parent,Color3.fromRGB(75,220,145)},{root,Color3.fromRGB(245,185,70)}}
    local function clearDrawings()
        for _,line in ipairs(effects) do
            local ok=pcall(function() line:Remove() end)
            if not ok then pcall(function() line:Destroy() end) end
        end
        table.clear(effects)
    end
    local fallback={}
    local function nativeFallback()
        if closed or #fallback>0 then return end
        for _,entry in ipairs(entries) do
            if livePart(entry[1]) then
                local box=Instance.new("SelectionBox")
                box.Name="MidnightModwoodWireframe"
                box.Adornee=entry[1]
                box.Color3=entry[2]
                box.SurfaceTransparency=1
                box.LineThickness=0.035
                box.Parent=entry[1]
                fallback[#fallback+1]=box
            end
        end
        self.MarkerBackend="Native wireframe"
    end
    local function cleanup()
        if closed then return end
        closed=true
        if connection then connection:Disconnect() connection=nil end
        clearDrawings()
        for _,box in ipairs(fallback) do box:Destroy() end
        table.clear(fallback)
    end
    token:Finally(cleanup)
    if not factory then nativeFallback() return end
    local created=pcall(function()
        for _,entry in ipairs(entries) do
            local group={Part=entry[1],Lines={}}
            groups[#groups+1]=group
            for _=1,12 do
                local line=factory("Line")
                effects[#effects+1]=line
                group.Lines[#group.Lines+1]=line
                line.Visible=false
                line.Color=entry[2]
                line.Thickness=1.6
                line.Transparency=0.95
                pcall(function() line.ZIndex=3 end)
            end
        end
    end)
    if not created then clearDrawings() nativeFallback() return end
    self.MarkerBackend="Drawing.new projected 3D wireframe"
    local corners={Vector3.new(-1,-1,-1),Vector3.new(1,-1,-1),Vector3.new(1,1,-1),Vector3.new(-1,1,-1),
        Vector3.new(-1,-1,1),Vector3.new(1,-1,1),Vector3.new(1,1,1),Vector3.new(-1,1,1)}
    local edges={{1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8}}
    local function render()
        local camera=S.Workspace.CurrentCamera
        for _,group in ipairs(groups) do
            local part=group.Part
            local show=camera and livePart(part) and not self.Config.NoRender
                and self.Config.ModwoodHighlights and self.Running
            local points={}
            if show then
                for index,corner in ipairs(corners) do
                    points[index]=part.CFrame:PointToWorldSpace(corner*(part.Size*0.5+Vector3.new(0.025,0.025,0.025)))
                end
            end
            for index,edge in ipairs(edges) do
                local line=group.Lines[index]
                line.Visible=false
                if show then
                    local a,b=points[edge[1]],points[edge[2]]
                    local da=-camera.CFrame:PointToObjectSpace(a).Z
                    local db=-camera.CFrame:PointToObjectSpace(b).Z
                    if da>0.05 or db>0.05 then
                        if da<=0.05 then a=a:Lerp(b,(0.05-da)/(db-da))
                        elseif db<=0.05 then b=b:Lerp(a,(0.05-db)/(da-db)) end
                        local pa=camera:WorldToViewportPoint(a)
                        local pb=camera:WorldToViewportPoint(b)
                        local limit=math.max(camera.ViewportSize.X,camera.ViewportSize.Y)*8
                        if math.abs(pa.X)<limit and math.abs(pa.Y)<limit and math.abs(pb.X)<limit and math.abs(pb.Y)<limit then
                            line.From=Vector2.new(pa.X,pa.Y)
                            line.To=Vector2.new(pb.X,pb.Y)
                            line.Visible=true
                        end
                    end
                end
            end
        end
    end
    local nextFrame=0
    connection=S.RunService.RenderStepped:Connect(function()
        if closed then return end
        if not self.Alive or token.Generation~=self.Generation then cleanup() return end
        if os.clock()<nextFrame then return end
        nextFrame=os.clock()+1/30
        local ok=pcall(render)
        if not ok then
            if connection then connection:Disconnect() connection=nil end
            clearDrawings()
            pcall(nativeFallback)
            self:Log("Drawing overlay unavailable - using native wireframe","DEBUG")
        end
    end)
end

function H:HoldIgnitionWood(log,parent,token,state,followAvatar)
    local target=parent.CFrame
    local parentContainer=parent.Parent
    local active,connection=true,nil
    local corrections,nextDrag,nextSample,nextCorrection,nextFollow=0,0,0,0,0
    local stableSince,unstableSince,lastPosition=nil,os.clock(),parent.Position
    local drag=self:Remote("Interaction","ClientIsDragging")
    local networkOwner=cap("isnetworkowner",isnetworkowner)
    local rtt=math.clamp(math.max(self.ServerRTT or 0,state.SyncRTT or 0),0,15)
    local correctionInterval=math.clamp(0.35+rtt*0.5,0.35,2)
    local settlingTime=math.clamp(0.35+rtt*0.5,0.35,1.5)
    local instabilityBudget=math.clamp(10+rtt*4,10,35)
    local parts={}
    for _,part in ipairs(log:GetDescendants()) do
        if part:IsA("BasePart") then parts[#parts+1]=part end
    end
    state.HoldReady=false state.HoldDrift=0 state.HoldPhysics="Unknown"
    local function release()
        if not active then return end
        active=false state.HoldReady=false
        if connection then connection:Disconnect() connection=nil end
    end
    token:Finally(release)
    connection=S.RunService.PreSimulation:Connect(function()
        if not active then return end
        if not self.Alive or not self.Running or token.Generation~=self.Generation
            or not log.Parent or not parent.Parent or parent.Parent~=parentContainer
            or state.ParentSeparated or state.IgnitionObserved then release() return end
        local ok,reason=pcall(function()
            assert(owned(log) and under(parent,log),"Wood ownership changed during ignition")
            -- One controller owns all pre-ignition corrections. Do not anchor server wood.
            for _,part in ipairs(parts) do
                if livePart(part) and under(part,log) and not part.Anchored then
                    part.AssemblyLinearVelocity=Vector3.zero
                    part.AssemblyAngularVelocity=Vector3.zero
                end
            end
            local now=os.clock()
            if now>=nextDrag then drag:FireServer(log) nextDrag=now+0.25 end
            if now<nextSample then return end
            nextSample=now+0.1
            local bounds,size=log:GetBoundingBox()
            assert(self:ClearOfLava(bounds.Position,size.Magnitude*0.5+4),"Wood approached physical lava during ignition")
            local physics
            if networkOwner then
                local checked,result=pcall(networkOwner,parent)
                if checked and type(result)=="boolean" then physics=result end
            end
            state.HoldPhysics=physics==true and "Confirmed" or physics==false and "Reacquiring" or "Unavailable"
            local current=parent.CFrame
            local drift=(current.Position-target.Position).Magnitude
            local movement=(current.Position-lastPosition).Magnitude
            lastPosition=current.Position
            local _,angle=target:ToObjectSpace(current):ToAxisAngle()
            state.HoldDrift=drift state.HoldMovement=movement
            if followAvatar and now>=nextFollow then
                nextFollow=now+0.4
                followAvatar(parent)
            end
            local settled=drift<=1.5 and math.abs(angle)<=math.rad(8) and movement<=0.6 and physics~=false
            if settled then
                stableSince=stableSince or now
                state.HoldReady=now-stableSince>=settlingTime
                if state.HoldReady then unstableSince=nil end
            else
                stableSince=nil state.HoldReady=false
                unstableSince=unstableSince or now
                -- Do not fight a remote physics owner every frame. Retry a position
                -- correction only after a replication interval, then observe again.
                if physics~=false and now>=nextCorrection and (drift>1.5 or math.abs(angle)>math.rad(8)) then
                    if followAvatar then followAvatar(parent,target) end
                    local delta=target*current:Inverse()
                    log:PivotTo(delta*log:GetPivot())
                    corrections=corrections+1 state.IgnitionCorrections=corrections
                    nextCorrection=now+correctionInterval
                end
            end
            state.HoldUnstableSeconds=unstableSince and now-unstableSince or 0
            assert(state.HoldUnstableSeconds<instabilityBudget,string.format(
                "Wood did not settle for %.1fs - drift %.2f studs, physics %s",
                state.HoldUnstableSeconds,drift,state.HoldPhysics))
        end)
        if not ok then
            token.ModwoodFailure="Modwood - "..cleanError(reason)
            release()
        end
    end)
    local function ready()
        return active and state.HoldReady==true and not token.ModwoodFailure
    end
    return release,ready
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
-- Legacy clients accept 0/1; the supplied API also documents a boolean form.
-- Prefer the known numeric form and switch only if the executor rejects it.
function H:TouchWoodLava(touch,wood,lava,beginContact)
    if not livePart(wood) or not livePart(lava) then
        if not beginContact then return true end
        return false,"Touch parts are unavailable"
    end
    local mode=self.TouchArgumentMode or "Numeric"
    local argument
    if mode=="Boolean" then argument=beginContact else argument=beginContact and 0 or 1 end
    local ok,reason=pcall(touch,wood,lava,argument)
    if not ok and mode=="Numeric" and beginContact then
        ok,reason=pcall(touch,wood,lava,true)
        if ok then self.TouchArgumentMode="Boolean" end
    elseif ok then self.TouchArgumentMode=mode end
    return ok,reason
end
function H:PerformModwood(log,mill,inlet,token,checkpoint)
    checkpoint=checkpoint or {}
    assert(not checkpoint.Modwood,"A previous Modwood phase cannot be restarted")
    local touch=cap("firetouchinterest",firetouchinterest)
    assert(touch,"Modwood requires firetouchinterest in this executor")
    local logs=S.Workspace:FindFirstChild("LogModels")
    local playerModels=S.Workspace:FindFirstChild("PlayerModels")
    assert(logs and playerModels,"Wood containers are unavailable")
    assert(log and under(log,logs) and owned(log),"Modwood requires your felled wood")
    assert(mill and under(mill,playerModels) and owned(mill) and livePart(inlet) and under(inlet,mill),"The selected sawmill is unavailable")
    local inputVolume=self:WoodVolume(log)
    assert(finite(inputVolume) and inputVolume>=MIN_TREE_VOLUME,"Modwood requires at least 60 studs3 of felled wood")
    local root,leaf,parent,reason=self:ModwoodParts(log)
    self:CaptureModwood(log,mill,reason or "Dry-area ignition selection")
    assert(root,reason)
    assert(not root.Anchored and root.Size.Y>0.4,"Root is anchored or too short")
    local lava=self:FindLava(token)
    local originalPrimary=log.PrimaryPart
    local character,humanoid,avatar=self:Character()
    local state={Phase="Prepared",SourceRevision="Hunter-1.14.4-stable-dry-ignition",Log=log,Mill=mill,Inlet=inlet,
        Root=root,Leaf=leaf,Parent=parent,ParentContainer=parent.Parent,Kind=value(log,"TreeClass"),
        InputVolume=inputVolume,IgnitionMode="Synthetic only - dry work area",OriginalSections={},BeforeOutput={},Outputs={},SeenOutput={},BeforeLogs={},TouchPairs=0,FeedFrames=0,
        LavaPath=lava:GetFullName(),IgnitionCorrections=0,RootID=value(root,"ID"),LeafID=value(leaf,"ID"),ParentID=value(parent,"ID")}
    checkpoint.Modwood=state
    self:MarkModwood(root,leaf,parent,token)
    self.ModwoodSelection={Wood=log,Sawmill=mill,Leaf=leaf,Parent=parent}
    local initialFrames,collisions={},{}
    for _,part in ipairs(log:GetDescendants()) do
        if part:IsA("BasePart") then
            initialFrames[part]=part.CFrame collisions[part]=part.CanCollide
            if part.Name=="WoodSection" then state.OriginalSections[#state.OriginalSections+1]=part end
        end
    end
    for _,model in ipairs(playerModels:GetChildren()) do state.BeforeOutput[model]=true end
    for _,model in ipairs(logs:GetChildren()) do state.BeforeLogs[model]=true end
    local outputCandidates,replacementCandidates={},{}
    local outputListener=playerModels.ChildAdded:Connect(function(model) outputCandidates[model]=true end)
    local logListener=logs.ChildAdded:Connect(function(model) replacementCandidates[model]=true end)
    token:Finally(function() outputListener:Disconnect() logListener:Disconnect() end)
    local function snapshot(message)
        self.ModwoodRuntimeDiagnostic=table.concat({
            "Modwood runtime - "..message,"Protocol: "..state.SourceRevision,"Phase: "..state.Phase,
            "Lava target: "..state.LavaPath,
            "Ignition mode: "..state.IgnitionMode,
            string.format("Input: %.2f studs3; off-target fire: %s; ownership: %s",
                state.InputVolume,tostring(state.OffTargetFire or "none"),tostring(state.OwnerState or "confirmed")),
            string.format("Sections: root=%s; burn=%s; retained=%s",tostring(state.RootID),tostring(state.ParentID),tostring(state.LeafID)),
            string.format("Touch pairs=%d; fire=%s; detached=%s; feed pulses=%d; root strikes=%d",
                state.TouchPairs,tostring(state.IgnitionObserved==true),tostring(state.ParentSeparated==true),state.FeedFrames,state.Strikes or 0),
            string.format("Ignition: elapsed=%.2fs; budget=%.2fs; grace=%.2fs; RTT=%.2fs; target changed=%s",
                state.IgnitionSeconds or 0,state.IgnitionBudget or 0,state.IgnitionGrace or 0,
                state.IgnitionRTT or 0,tostring(state.IgnitionTargetChanged==true)),
            "Control: "..(state.NetworkStatus or "Not checked"),
            string.format("Hold: ready=%s; physics=%s; drift=%.2f; movement=%.2f; corrections=%d; unstable=%.2fs",
                tostring(state.HoldReady),state.HoldPhysics or "Unknown",state.HoldDrift or 0,
                state.HoldMovement or 0,state.IgnitionCorrections or 0,state.HoldUnstableSeconds or 0),
            string.format("Root cut distance: %.2f; touch cap: %d",state.CutDistance or 0,state.MaxTouchPairs or 0),
            "Elapsed: "..string.format("%.2fs",os.clock()-(state.Started or os.clock()))},"\n")
    end
    state.Started=os.clock()
    token:Finally(function() snapshot("Task cleanup") end)
    local hover=self:ModwoodHover(token,state)
    local function placeAvatar(frame)
        hover:BeforeMove(frame)
        avatar.CFrame=frame
        hover:Hold(frame)
        avatar.AssemblyLinearVelocity=Vector3.zero avatar.AssemblyAngularVelocity=Vector3.zero
    end
    local function restoreCollisions()
        for part,collision in pairs(collisions) do if livePart(part) then part.CanCollide=collision end end
    end
    token:Finally(function()
        -- On interruption, only rescue our original sections still above the lava.
        -- Never pull finished planks or a fed section out of the sawmill.
        for part,frame in pairs(initialFrames) do
            if owned(log) and livePart(part) and under(part,log) and (part.Position-lava.Position).Magnitude<140 then
                part.AssemblyLinearVelocity=Vector3.zero part.AssemblyAngularVelocity=Vector3.zero
                part.CFrame=frame
            end
        end
        restoreCollisions()
        if log.Parent then log.PrimaryPart=originalPrimary and under(originalPrimary,log) and originalPrimary or nil end
    end)
    local drag=self:Remote("Interaction","ClientIsDragging")
    local proxy=self:Remote("Interaction","RemoteProxy")
    local cutEvent=log:FindFirstChild("CutEvent") or log.Parent:FindFirstChild("CutEvent")
    assert(cutEvent,"Felled tree has no cut event")
    local function checkMill()
        token:Check() hover:Check()
        if log.Parent then
            local current=value(log,"Owner")
            if current and current~=Player then
                state.OwnerState="Foreign owner"
                self.ServerExitReason="Wood claimed by another player - stopping this target"
                error(self.ServerExitReason,0)
            end
        end
        assert(under(mill,playerModels) and owned(mill) and livePart(inlet) and under(inlet,mill),"The sawmill disappeared or changed owner")
    end
    local function connected(a,b)
        if not livePart(a) or not livePart(b) then return false end
        if a==b then return true end
        for _,part in ipairs(a:GetConnectedParts(true)) do if part==b then return true end end
        return false
    end
    local function moveModel(pivot,frame)
        checkMill()
        assert(livePart(pivot) and under(pivot,log) and owned(log),"Transfer pivot disappeared or changed owner")
        log.PrimaryPart=pivot self:DampWood(log) log:PivotTo(frame) self:DampWood(log)
    end
    -- Plan the work point and lava clearance before any destructive contact.
    local workPoint=Vector3.new(-1055,291,-458)
    local parameters=RaycastParams.new()
    parameters.FilterType=Enum.RaycastFilterType.Exclude
    parameters.FilterDescendantsInstances={log,character} parameters.RespectCanCollide=true
    local ground=S.Workspace:Raycast(workPoint+Vector3.new(0,25,0),Vector3.new(0,-90,0),parameters)
    assert(ground and ground.Normal.Y>0.7 and not ground.Instance.Name:lower():find("lava"),"Recorded work area has no confirmed floor")
    state.WorkFrame=CFrame.new(workPoint.X,math.max(workPoint.Y,ground.Position.Y+4),workPoint.Z)
    -- Keep every section on dry ground. CanCollide=false alone cannot prevent Touched.
    -- Preserve CanTouch and TouchTransmitter: disabling CanTouch can disconnect game events.
    -- https://create.roblox.com/docs/reference/engine/classes/BasePart#CanTouch
    -- The selected parent receives only the explicitly paired synthetic contact.
    local box,size=log:GetBoundingBox()
    local rootToBox=root.CFrame:ToObjectSpace(box)
    local plannedBox=state.WorkFrame*rootToBox
    local bottom=plannedBox.Position.Y-(math.abs(plannedBox.RightVector.Y)*size.X
        +math.abs(plannedBox.UpVector.Y)*size.Y+math.abs(plannedBox.LookVector.Y)*size.Z)*0.5
    state.WorkFrame=state.WorkFrame+Vector3.new(0,math.max(0,ground.Position.Y+2-bottom),0)
    local plannedCenter=(state.WorkFrame*rootToBox).Position
    assert(self:ClearOfLava(plannedCenter,size.Magnitude*0.5+8),"Dry work area overlaps a lava hazard")
    local observing,contactActive,endContact=true,false,nil
    local fireNames,fireConnections={},{}
    assert(not parent:FindFirstChild("LavaFire",true),"Burn parent was already ignited before this attempt")
    local function observeFire(child)
        if not observing or state.IgnitionObserved or child.Name~="LavaFire" then return end
        state.IgnitionObserved=true state.IgnitionAt=os.clock() state.Phase="Ignited"
        -- Latch before releasing: the effect may disappear in the same frame.
        if endContact and contactActive then
            local ok,released=pcall(endContact)
            if not ok or not released then state.ContactReleasePending=true end
        end
    end
    local function watchFire(child)
        observeFire(child)
        if not observing or state.IgnitionObserved or fireNames[child] then return end
        -- Some clients replicate the instance before its final name.
        fireNames[child]=child:GetPropertyChangedSignal("Name"):Connect(function() observeFire(child) end)
    end
    fireConnections[1]=parent.DescendantAdded:Connect(watchFire)
    fireConnections[2]=parent.DescendantRemoving:Connect(function(child)
        observeFire(child)
        if fireNames[child] then fireNames[child]:Disconnect() fireNames[child]=nil end
    end)
    for _,child in ipairs(parent:GetDescendants()) do watchFire(child) end
    local function stopFireObservation()
        observing=false
        for _,connection in ipairs(fireConnections) do connection:Disconnect() end
        for child,connection in pairs(fireNames) do connection:Disconnect() fireNames[child]=nil end
    end
    token:Finally(stopFireObservation)
    local function fireConfirmed()
        if state.IgnitionObserved then return true end
        local effect=parent:FindFirstChild("LavaFire",true)
        if effect then observeFire(effect) end
        return state.IgnitionObserved==true
    end
    local guardConnections={}
    local guardNames={}
    local function inspectFire(child)
        if child.Name~="LavaFire" then return end
        local section=child.Parent
        while section and section~=log and not (section:IsA("BasePart") and section.Name=="WoodSection") do section=section.Parent end
        if section and section~=log and section~=parent then
            state.OffTargetFire=tostring(value(section,"ID") or section.Name)
            token.ModwoodFailure="Fire detected outside the selected burn section - contacts stopped"
            if endContact then pcall(endContact) end
        end
    end
    local function watchHazard(child)
        inspectFire(child)
        if not guardNames[child] then guardNames[child]=child:GetPropertyChangedSignal("Name"):Connect(function() inspectFire(child) end) end
    end
    guardConnections[#guardConnections+1]=log.DescendantAdded:Connect(watchHazard)
    guardConnections[#guardConnections+1]=log.DescendantRemoving:Connect(function(child)
        inspectFire(child)
        if guardNames[child] then guardNames[child]:Disconnect() guardNames[child]=nil end
    end)
    for _,child in ipairs(log:GetDescendants()) do watchHazard(child) end
    local ownerValue=log:FindFirstChild("Owner")
    assert(ownerValue and ownerValue:IsA("ObjectValue") and ownerValue.Value==Player,"Confirmed wood ownership is required")
    guardConnections[#guardConnections+1]=ownerValue:GetPropertyChangedSignal("Value"):Connect(function()
        if ownerValue.Value and ownerValue.Value~=Player then
            state.OwnerState="Foreign owner"
            token.ModwoodFailure="Wood claimed by another player - contacts stopped"
            self.ServerExitReason=token.ModwoodFailure
            if endContact then pcall(endContact) end
        end
    end)
    token:Finally(function()
        for _,connection in ipairs(guardConnections) do connection:Disconnect() end
        for _,connection in pairs(guardNames) do connection:Disconnect() end
    end)
    local tool,stats=self:EnsureAxe(state.Kind,token)
    -- One bounded synchronization, with observable stage results as the authority.
    placeAvatar(CFrame.new(root.Position+Vector3.new(5,3,0)))
    local ping=S.ReplicatedStorage:FindFirstChild("TestPing")
    local replied,worker=false,nil
    if ping and ping:IsA("RemoteFunction") then
        worker=task.spawn(function()
            local started=os.clock()
            local ok=pcall(ping.InvokeServer,ping)
            if ok then
                state.SyncRTT=os.clock()-started
                self:ObserveLatency(state.SyncRTT)
            end
            replied=ok
        end)
    end
    local function stopPing() if worker and coroutine.status(worker)~="dead" then pcall(task.cancel,worker) end end
    token:Finally(stopPing)
    local networkOwner=cap("isnetworkowner",isnetworkowner)
    local syncStart=os.clock()
    repeat
        checkMill() drag:FireServer(log)
        local controlled=false
        if networkOwner then local ok,result=pcall(networkOwner,root) controlled=ok and result==true end
        if os.clock()-syncStart>=0.18 and (controlled or replied) then
            state.NetworkStatus=controlled and "Executor confirmed" or "Server replied" break
        end
        token:Sleep(0.12)
    until os.clock()-syncStart>=2
    stopPing()
    state.NetworkStatus=state.NetworkStatus or "Synchronization elapsed - awaiting actual results"
    checkpoint.AtBase=false
    for part in pairs(collisions) do
        if livePart(part) then
            part.CanCollide=false
        end
    end
    self:SetStage("Modwood - igniting selected section",0.52)
    placeAvatar(state.WorkFrame+Vector3.new(5,5,0))
    moveModel(root,state.WorkFrame)
    log.PrimaryPart=parent
    local target=parent.CFrame
    state.BurnTarget=target
    placeAvatar(CFrame.new(parent.Position+Vector3.new(5,3,0)))
    local releaseHold,ignitionReady=self:HoldIgnitionWood(log,parent,token,state,function(section,destination)
        local point=destination and destination.Position or section.Position
        if livePart(section) and (avatar.Position-point).Magnitude>9 then
            placeAvatar(CFrame.new(point+Vector3.new(5,3,0)))
        end
    end)
    endContact=function()
        if not contactActive then return true end
        local ok,reason=self:TouchWoodLava(touch,parent,lava,false)
        if ok then contactActive=false state.ContactReleasePending=nil end
        return ok,reason
    end
    token:Finally(function()
        local ok=endContact()
        if not ok then endContact() end
    end)
    local rtt=math.clamp(math.max(self.ServerRTT or 0,state.SyncRTT or 0),0,15)
    local ignitionStart=os.clock()
    local ignitionBudget=math.clamp(self.Config.BurnTimeout+math.max(0,rtt-0.12)*6,10,120)
    local deadline=ignitionStart+ignitionBudget
    state.IgnitionBudget=ignitionBudget state.IgnitionRTT=rtt
    local holdSeconds=0.035
    local pulseInterval=math.clamp(1.25+rtt*2,1.25,8)
    local maxTouchPairs=3
    state.MaxTouchPairs=maxTouchPairs
    local loggedSlow=false
    while not fireConfirmed() and os.clock()<deadline and state.TouchPairs<maxTouchPairs do
        checkMill()
        -- Recheck before every movement and contact. A delayed event received
        -- during a wait must never cause another full-tree lava transfer.
        if fireConfirmed() then break end
        if not livePart(parent) or not under(parent,log) then
            state.IgnitionTargetChanged=true break
        end
        assert(owned(log),"Burn target ownership changed before ignition")
        assert(livePart(lava) and lava.CanTouch and lava:FindFirstChildWhichIsA("TouchTransmitter"),
            "Recorded lava touch handler became unavailable")
        local currentBounds,currentSize=log:GetBoundingBox()
        assert(self:ClearOfLava(currentBounds.Position,currentSize.Magnitude*0.5+4),"Physical lava proximity detected - synthetic contact blocked")
        while not ignitionReady() and not fireConfirmed() and os.clock()<deadline do
            checkMill()
            token:Sleep(0.05)
        end
        if fireConfirmed() or os.clock()>=deadline then break end
        checkMill()
        if not ignitionReady() then continue end
        contactActive=true
        local pressed,problem=self:TouchWoodLava(touch,parent,lava,true)
        local contactUntil=os.clock()+holdSeconds
        while not fireConfirmed() and ignitionReady() and os.clock()<contactUntil do token:Sleep(0.015) end
        local released,releaseProblem=endContact()
        if not released then released,releaseProblem=endContact() end
        assert(pressed and released,"Lava contact failed - "..tostring(problem or releaseProblem))
        state.TouchPairs=state.TouchPairs+1
        if fireConfirmed() then break end
        if not loggedSlow and os.clock()-ignitionStart>=8 then
            loggedSlow=true
            self:Log("Ignition response delayed - wood remains in the dry work area","DEBUG")
        end
        local nextPulse=math.min(deadline,os.clock()+pulseInterval)
        while not fireConfirmed() and os.clock()<nextPulse do token:Sleep(0.03) end
    end
    endContact()
    if not fireConfirmed() then
        -- Stop generating contacts while late server replication is arriving.
        -- Keep the observer and avatar support alive; never infer fire from a ping.
        local grace=math.clamp(1.5+rtt*3,1.5,10)
        local graceUntil=math.max(deadline,os.clock()+grace)
        state.IgnitionGrace=grace
        while not fireConfirmed() and os.clock()<graceUntil do
            checkMill()
            assert(owned(log),"Wood ownership changed while awaiting ignition")
            -- The position controller continues alone while late fire events arrive.
            -- Never add a second pivot writer here.
            token:Sleep(0.12)
        end
    end
    releaseHold()
    state.IgnitionSeconds=os.clock()-ignitionStart
    assert(fireConfirmed(),string.format(
        "Ignition not confirmed after %.1fs - %d contacts, RTT %.2fs; no second Modwood attempt",
        state.IgnitionSeconds,state.TouchPairs,rtt))
    local released,releaseProblem=endContact()
    assert(released,"Lava contact release failed - "..tostring(releaseProblem))
    stopFireObservation()
    snapshot("Ignition confirmed") self:UpdateHarvestProgress(0.50)
    state.Phase="Separating"
    self:SetStage("Modwood - waiting for branch separation",0.57)
    placeAvatar(state.WorkFrame+Vector3.new(5,8,0))
    moveModel(root,state.WorkFrame)
    restoreCollisions()
    self:WaitResult(token,function() return not connected(parent,root) and not connected(parent,leaf) end,
        math.clamp(math.max(3,1+rtt*4,(state.IgnitionSeconds or 0)*0.5),3,20),
        "Burned section is still connected - disposal blocked",0.05)
    self:SetStage("Modwood - removing detached section",0.60)
    deadline=os.clock()+math.clamp(math.max(7,3+rtt*4,(state.IgnitionSeconds or 0)*0.5),7,30)
    placeAvatar(CFrame.new(parent.Position+Vector3.new(5,4,0)))
    drag:FireServer(log) token:Sleep(math.clamp(0.15+rtt,0.15,1))
    local removalFrame=CFrame.new(1279,49,2328)
    assert(self:ClearOfLava(removalFrame.Position,parent.Size.Magnitude*0.5+4),"Disposal destination overlaps lava")
    placeAvatar(removalFrame+Vector3.new(5,6,0))
    while livePart(parent) and under(parent,log) do
        checkMill()
        assert(owned(log),"Wood ownership changed before disposal")
        assert(not connected(parent,root) and not connected(parent,leaf),"Burned section reconnected")
        parent.AssemblyLinearVelocity=Vector3.zero parent.AssemblyAngularVelocity=Vector3.zero
        parent.CFrame=removalFrame drag:FireServer(log)
        assert(os.clock()<deadline,"Detached burn section did not disappear")
        token:Sleep(0.12)
    end
    state.ParentSeparated=true self:UpdateHarvestProgress(0.60)
    assert(livePart(root) and livePart(leaf) and under(leaf,log),"Root or retained section disappeared")
    assert(not connected(leaf,root),"Retained section is still joined to the trunk")
    log.PrimaryPart=root state.RootFrame=root.CFrame
    humanoid:EquipTool(tool)
    self:WaitResult(token,function() return tool.Parent==character end,2,"Inventory axe could not be equipped")
    state.Phase="Feeding"
    self:SetStage("Modwood - feeding and cutting",0.70)
    local rootHeight,rootParent=root.Size.Y,root.Parent
    local nextFeed,nextStrike,leafMissingSince=0,0,nil
    deadline=os.clock()+self:AdaptiveWait(self.Config.ChopTimeout,120)
    local originalSet={}
    for _,section in ipairs(state.OriginalSections) do originalSet[section]=true end
    local function trackReplacement()
        local leafModel=livePart(leaf) and leaf:FindFirstAncestorOfClass("Model")
        if leafModel and leafModel~=log then replacementCandidates[leafModel]=true end
        state.TransformedSections=state.TransformedSections or {}
        state.TransformedSeen=state.TransformedSeen or {}
        for model in pairs(replacementCandidates) do
            if not model.Parent then replacementCandidates[model]=nil
            elseif not state.BeforeLogs[model] and owned(model) and value(model,"TreeClass")==state.Kind then
                local sections,related={},false
                for _,section in ipairs(model:GetDescendants()) do
                    if section:IsA("BasePart") and section.Name=="WoodSection" then
                        sections[#sections+1]=section
                        if originalSet[section] then related=true end
                    end
                end
                if related then
                    state.Transformed=model
                    for _,section in ipairs(sections) do
                        if not state.TransformedSeen[section] then
                            state.TransformedSeen[section]=true state.TransformedSections[#state.TransformedSections+1]=section
                        end
                    end
                end
            end
        end
    end
    repeat
        checkMill() trackReplacement()
        if root.Size.Y<rootHeight-0.1 or state.Transformed then state.Phase="Output" break end
        assert(livePart(root) and root.Parent==rootParent and owned(log),"Original cut target changed unexpectedly")
        if os.clock()>=nextFeed then
            if livePart(leaf) then
                if connected(leaf,root) then
                    leafMissingSince=leafMissingSince or os.clock()
                    assert(os.clock()-leafMissingSince<math.clamp(1+rtt*3,2,8),"Retained section remained connected - feeding blocked")
                else
                    leafMissingSince=nil
                    leaf.AssemblyLinearVelocity=Vector3.zero leaf.AssemblyAngularVelocity=Vector3.zero
                    leaf.CFrame=inlet.CFrame drag:FireServer(log)
                    state.FeedFrames=state.FeedFrames+1
                end
            else
                -- The mill can consume the retained section before the root-cut update arrives.
                -- Keep waiting for the actual root cut; disappearance alone is not success.
                leafMissingSince=leafMissingSince or os.clock()
                local outputSeen=false
                for candidate in pairs(outputCandidates) do
                    if candidate.Parent and owned(candidate) and value(candidate,"TreeClass")==state.Kind then
                        local section=candidate:FindFirstChild("WoodSection")
                        if section and section:IsA("BasePart") and (section.Position-inlet.Position).Magnitude<65 then outputSeen=true break end
                    end
                end
                assert(outputSeen or os.clock()-leafMissingSince<math.clamp(2+rtt*3,3,12),"Retained section disappeared without a matching sawmill result")
            end
            nextFeed=os.clock()+0.35
        end
        if os.clock()>=nextStrike then
            if tool.Parent~=character then
                humanoid:EquipTool(tool)
                self:WaitResult(token,function() return tool.Parent==character end,2,"Inventory axe was not re-equipped")
            end
            local cutHeight=math.clamp(0.3,0.1,math.max(0.1,root.Size.Y-0.1))
            local cutPoint=root.CFrame:PointToWorldSpace(Vector3.new(root.Size.X*0.5,cutHeight-root.Size.Y*0.5,0))
            local stand=root.CFrame:PointToWorldSpace(Vector3.new(root.Size.X*0.5+3,cutHeight-root.Size.Y*0.5+2.3,0))
            placeAvatar(CFrame.lookAt(stand,cutPoint))
            cutEvent=log:FindFirstChild("CutEvent") or (log.Parent and log.Parent:FindFirstChild("CutEvent"))
            assert(cutEvent and cutEvent.Parent,"Root cut event disappeared")
            state.CutDistance=(avatar.Position-cutPoint).Magnitude
            proxy:FireServer(cutEvent,{tool=tool,sectionId=value(root,"ID"),height=cutHeight,faceVector=Vector3.new(1,0,0),
                hitPoints=stats.Damage,cooldown=stats.SwingCooldown,cuttingClass="Axe"})
            state.Strikes=(state.Strikes or 0)+1
            nextStrike=os.clock()+math.max(0.1,stats.SwingCooldown)+0.02
        end
        token:Sleep(0.03)
    until os.clock()>=deadline
    assert(state.Phase=="Output","Root cut was not confirmed before timeout")
    self:UpdateHarvestProgress(0.70)
    snapshot("Root cut confirmed - feeding stopped")
    placeAvatar(inlet.CFrame+Vector3.new(0,6,8))
    self:SetStage("Modwood - waiting for sawmill output",0.78,"Waiting for finished planks")
    local deadline=os.clock()+self:AdaptiveWait(self.Config.MillTimeout,180)
    local stableSince, outputVolume, outputParts, outputDimensions
    local expectedSections={}
    for _,section in ipairs(state.OriginalSections) do if section~=parent then expectedSections[section]=true end end
    for _,section in ipairs(state.TransformedSections or {}) do if section~=parent then expectedSections[section]=true end end
    repeat
        checkMill() trackReplacement()
        for _,section in ipairs(state.TransformedSections or {}) do
            if section~=parent then expectedSections[section]=true end
        end
        for model in pairs(outputCandidates) do
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
                if livePart(section) and section~=parent and not cutStump and not (ownerModel and state.SeenOutput[ownerModel]) then
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
        local totalSections,consumedSections=0,0
        for section in pairs(expectedSections) do
            totalSections=totalSections+1
            local ownerModel=section.Parent and section:FindFirstAncestorOfClass("Model")
            if not livePart(section) or (section==root and section.Size.Y<=0.35)
                or (ownerModel and state.SeenOutput[ownerModel]) then consumedSections=consumedSections+1 end
        end
        if #state.Outputs>0 and volume>0 then
            self:UpdateHarvestProgress(0.70+0.10*consumedSections/math.max(1,totalSections),
                "Planks: "..#state.Outputs)
        end
        if #state.Outputs>0 and remaining==0 and volume>0 and stableSince and os.clock()-stableSince>2 then
            self:UpdateHarvestProgress(0.85)
            hover:Release()
            return state.Outputs
        end
        token:Sleep(0.08)
    until os.clock()>=deadline
    error("Modwood - whole-tree conversion or finished output not confirmed; wood left in this server",0)
end
function H:PlankPlacement(plank,center)
    local plot=self:Plot()
    assert(plot and owned(plot),"Your plot is no longer owned")
    local bounds,size=plank:GetBoundingBox()
    local relative=plank:GetPivot():ToObjectSpace(bounds)
    local rotation=bounds.Rotation
    local extent=worldBoundsSize(bounds,size)
    local width,height,depth=extent.X,extent.Y,extent.Z
    local tiles=self:PlotTiles(plot)
    local function onLand(x,z)
        for _,tile in ipairs(tiles) do
            if tile:IsA("BasePart") and (tile.Name=="Square" or tile.Name=="OriginSquare")
                and math.abs(x-tile.Position.X)<=tile.Size.X/2-0.05
                and math.abs(z-tile.Position.Z)<=tile.Size.Z/2-0.05 then return true end
        end
        return false
    end
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances={Player.Character,plank}
    params.RespectCanCollide=true params.IgnoreWater=true
    local offsets={{0,0},{1,0},{-1,0},{0,1},{0,-1},{1,1},{-1,1},{1,-1},{-1,-1}}
    local best,bestScore
    for _,offset in ipairs(offsets) do
        local x=center.Position.X+offset[1]*(width+0.6)
        local z=center.Position.Z+offset[2]*(depth+0.6)
        local support,valid=center.Position.Y,true
        for _,corner in ipairs({{0,0},{-1,-1},{1,-1},{-1,1},{1,1}}) do
            local px,pz=x+corner[1]*width/2,z+corner[2]*depth/2
            if not onLand(px,pz) then valid=false break end
            local hit=S.Workspace:Raycast(Vector3.new(px,center.Position.Y+200,pz),Vector3.new(0,-205,0),params)
            if not hit then valid=false break end
            support=math.max(support,hit.Position.Y)
        end
        if valid and support-center.Position.Y<12 then
            local score=(support-center.Position.Y)*10+math.abs(x-center.Position.X)+math.abs(z-center.Position.Z)
            if not bestScore or score<bestScore then
                bestScore=score
                best=CFrame.new(x,support+height/2+4,z)*rotation*relative:Inverse()
            end
        end
    end
    assert(best,"No supported placement near the plot center - clear space for this plank")
    return best
end
function H:Deliver(planks, center, token, checkpoint)
    local remaining = {}
    if checkpoint then checkpoint.Delivered = checkpoint.Delivered or {} end
    for _, plank in ipairs(planks) do
        if not checkpoint or not checkpoint.Delivered[plank] then table.insert(remaining, plank) end
    end
    local deliveredCount=#planks-#remaining
    self:UpdateHarvestProgress(0.85+0.10*deliveredCount/math.max(1,#planks),
        string.format("Planks %d / %d",deliveredCount,#planks))
    for _, plank in ipairs(remaining) do
        local target=self:PlankPlacement(plank,center)
        self:Move(plank, target, token)
        self.Stats.Planks = self.Stats.Planks + 1
        if checkpoint then checkpoint.DeliveredVolume=(checkpoint.DeliveredVolume or 0)+self:WoodVolume(plank) end
        self.UnsavedDelivery=true
        if checkpoint then checkpoint.Delivered[plank] = true end
        deliveredCount=deliveredCount+1
        self:UpdateHarvestProgress(0.85+0.10*deliveredCount/math.max(1,#planks),
            string.format("Planks %d / %d",deliveredCount,#planks))
    end
end
function H:SaveSlot(token)
    self.ActiveTarget=nil
    token:Finally(function() self.ActiveTarget=nil end)
    self:StartServerPrefetch(token)
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
    token:Sleep(self.Config.PerformanceMode and self:AdaptiveWait(0.25,2) or 2)
    -- Keep the explicit server acknowledgement and recheck a late busy update.
    while value(Player,"CurrentlySavingOrLoading")==true do
        assert(os.clock()<deadline,"Save completion timed out") token:Sleep(0.1)
    end
    self.UnsavedDelivery=false
end
-- Only the per-account client key is stored here. The Discord token stays in Cloudflare.
function H:PersistBotState()
    if not self.Config.PerformanceMode then
        local target=self.PendingTeleportTarget
        return self:Persist(target~=nil,target)
    end
    -- Critical transitions still call Persist synchronously. Only routine bot
    -- status updates share one short write window.
    if not self.BotPersistWorker then
        self.BotPersistWorker=task.delay(0.35,function()
            self.BotPersistWorker=nil
            if self.Alive then
                local target=self.PendingTeleportTarget
                local ok,reason=self:Persist(target~=nil,target)
                if not ok then self:Log(reason,"WARNING") end
            end
        end)
    end
    return true
end
function H:BotSnapshot(event)
    local counts=self.Counts or {}
    local growth=self.Growth and table.clone(self.Growth) or nil
    local function copyCollection(source)
        local result={}
        for kind,record in pairs(source) do result[kind]=table.clone(record) end
        return result
    end
    return {accountId=tostring(Player.UserId),jobId=game.JobId,version=self.Version,
        stage=self.Stage,running=self.Running,progress=self.Progress*100,slot=self.Config.Slot,
        target=self.Config.TargetSpecies,growSinister=self.Config.GrowSinister,autoRejoin=self.Config.AutoRejoin,
        counts={Spooky=counts.Spooky or 0,SpookyNeon=counts.SpookyNeon or 0,
            SpookyVolume=counts.SpookyVolume or 0,SpookyNeonVolume=counts.SpookyNeonVolume or 0},
        collection=copyCollection(self.Collection),batch=copyCollection(self.BatchCollection),growth=growth,
        pending=#self.PendingWood,stats={Scanned=self.Stats.Scanned,FoundTrees=self.Stats.FoundTrees,
            Harvested=self.Stats.Harvested,Planks=self.Stats.Planks,Skipped=self.Stats.Skipped},
        lastConfirmed=self.LastConfirmedMilestone or "",report=self:BuildReport():sub(1,6000),
        ackVersion=self.BotCommandVersion or 0,event=event}
end
function H:BotRequest(event)
    if not self.Alive or not self.Config.BotEnabled or self.Config.BotURL=="" or self.Config.BotKey=="" then return false end
    if type(Request)~="function" then return false end
    local response
    local url,secret=self.Config.BotURL,self.Config.BotKey
    local encoded=S.HttpService:JSONEncode(self:BotSnapshot(event))
    local worker=task.spawn(function()
        response=table.pack(pcall(Request,{Url=url.."/v1/sync",Method="POST",
            Headers={["Content-Type"]="application/json",Authorization="Bearer "..secret},Body=encoded}))
    end)
    self.BotRequestThread=worker
    local deadline=os.clock()+8
    while self.Alive and not response and os.clock()<deadline do task.wait(0.08) end
    if not response then pcall(task.cancel,worker) end
    self.BotRequestThread=nil
    if not self.Alive or url~=self.Config.BotURL or secret~=self.Config.BotKey then return false end
    if not response or not response[1] or type(response[2])~="table" then
        self.BotStatus="Service unavailable" return false
    end
    local status=tonumber(response[2].StatusCode or response[2].Status)
    if status~=200 then
        self.BotStatus=status==401 and "Client key rejected" or "Service HTTP "..tostring(status)
        return false
    end
    self.BotLastSync=os.time()
    local body=response[2].Body
    if type(body)~="string" or #body>8192 then return false end
    local ok,data=pcall(S.HttpService.JSONDecode,S.HttpService,body)
    if not ok or type(data)~="table" or data.ok~=true then return false end
    self.BotStatus="Connected"
    if data.desired=="paused" or data.desired=="running" or data.desired=="observe" then self.BotDesired=data.desired end
    local revision=data.commandVersion
    if finite(revision) and revision>=0 and revision==math.floor(revision) then
        if revision>(self.BotCommandVersion or 0) then
            local acknowledged=false
            if data.desired=="paused" then self:Stop() acknowledged=true
            elseif data.desired=="running" and not self.Busy then self:Start() acknowledged=true
            elseif data.desired=="running" and self.Running then acknowledged=true
            elseif data.desired=="observe" then acknowledged=true end
            if acknowledged then
                self.BotCommandVersion=revision
                self:PersistBotState()
                self:Log(data.desired=="paused" and "Stopped from Discord" or "Discord command received")
            end
        elseif data.desired=="paused" and self.Running then self:Stop() end
    end
    return not event or data.eventAccepted==true
end
function H:StartBot()
    if self.BotLoop then return end
    self.BotQueue=self.BotQueue or {}
    self.BotLoop=task.defer(function()
        local failures=0
        while self.Alive do
            local event=self.BotQueue[1]
            local ok,accepted=pcall(self.BotRequest,self,event)
            if not self.Alive then break end
            if self.UI and self.UI.BotConnection then
                local status=self.Config.BotEnabled and (self.BotStatus or "Not configured") or "Disabled"
                if status~=self.BotShownStatus then
                    self.BotShownStatus=status
                    self.UI.BotConnection:Set("Bot - "..status,"Roblox account "..tostring(Player.UserId))
                end
            end
            if ok and accepted then
                failures=0
                if event then table.remove(self.BotQueue,1) self:PersistBotState() end
            else failures=math.min(4,failures+1) end
            local pause=failures>0 and math.min(120,15*2^(failures-1)) or (#self.BotQueue>0 and 2 or 30)
            local untilTime=os.clock()+pause
            repeat task.wait(0.25) until not self.Alive or os.clock()>=untilTime or self.BotWake
            self.BotWake=false
        end
        self.BotLoop=nil
    end)
end
function H:NotifyBot(title,description,token,receipt)
    if token then token:Check() end
    if not self.Config.BotEnabled or self.Config.BotURL=="" or self.Config.BotKey=="" then return false end
    local kind=receipt and "complete" or title=="Rare trees found" and "found"
        or title=="Harvest interrupted" and "interrupted" or "info"
    local eventId=kind=="found" and (game.JobId.."-"..(self.Config.TargetSpecies=="Spooky" and "01" or self.Config.TargetSpecies=="SpookyNeon" and "02" or "03"))
        or S.HttpService:GenerateGUID(false):lower()
    local event={id=eventId,kind=kind,title=title,content=description,capturedAt=os.time()}
    event.snapshot=self:BotSnapshot()
    event.snapshot.report=nil event.snapshot.ackVersion=nil
    if receipt then
        event.content=string.format("%d trees processed - %d planks delivered - slot save confirmed. Processing: %s.",
            receipt.Trees,receipt.Planks,duration(receipt.Seconds))
    end
    self.BotQueue=self.BotQueue or {}
    -- Coalesce unsent periodic growth messages; discovery and completion remain distinct.
    if title=="Sinister growth update" then
        for i=#self.BotQueue,2,-1 do
            if self.BotQueue[i].title==title and self.BotQueue[i].snapshot and self.BotQueue[i].snapshot.jobId==game.JobId then
                table.remove(self.BotQueue,i)
            end
        end
    end
    if #self.BotQueue>=50 then
        self:Log("Discord queue full - oldest pending notice removed","WARNING")
        table.remove(self.BotQueue,1)
    end
    table.insert(self.BotQueue,event)
    self:PersistBotState()
    self.BotWake=true
    self:StartBot()
    return true
end

function H:EligibleServers(candidates)
    local result,seen={},{}
    for _,id in ipairs(candidates or {}) do
        if serverID(id) and not seen[id] and not self:IsServerExcluded(id)
            and (not self.FailedServers[id] or self.FailedServers[id]<=os.time()) then
            seen[id]=true result[#result+1]=id
        end
    end
    return result
end

function H:CachedOldServers()
    self:EnsureServerCycle()
    local batch=self.OldServerBatch
    if not batch or batch.URL~=self.Config.TrackerURL or os.time()-batch.FetchedAt>=300 then return {} end
    table.sort(batch.Entries,function(a,b)
        if a.firstSeen~=b.firstSeen then return a.firstSeen<b.firstSeen end
        if a.lastSeen~=b.lastSeen then return a.lastSeen>b.lastSeen end
        return a.id<b.id
    end)
    local result={}
    for _,entry in ipairs(batch.Entries) do
        if os.time()-entry.lastSeen<=self.Config.TrackerFreshness*60
            and os.time()-entry.firstSeen>=self.Config.TrackerMinAge*60
            and not self:IsServerExcluded(entry.id)
            and (not self.FailedServers[entry.id] or self.FailedServers[entry.id]<=os.time()) then
            result[#result+1]=entry.id
        end
    end
    return result
end

function H:PublicServers(token)
    assert(type(Request)=="function","An HTTP request function is required for server search")
    local deadline=os.clock()+self.Config.ServerSearchBudget
    local cursor=self.PublicCursorUntil and self.PublicCursorUntil>os.time() and self.PublicCursor or nil
    local servers,ids,cursors={},{},{}
    local resetCursor=false
    for _=1,self.Config.PublicPageLimit do
        token:Check()
        if os.clock()>=deadline then break end
        local cooldown=(self.PublicRetryAt or 0)-os.clock()
        if cooldown>0 then
            if cooldown>=deadline-os.clock() then break end
            token:Sleep(cooldown)
        end
        local base="https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100"
        local url=base..(cursor and "&cursor="..S.HttpService:UrlEncode(cursor) or "")
        local response,lastError
        for attempt=1,3 do
            local remaining=deadline-os.clock()
            if remaining<=0 then break end
            local ok,result=pcall(function()
                return token:Await(function()
                    local sent,r=pcall(Request,{Url=url,Method="GET"})
                    assert(sent and type(r)=="table","Server-list transport failed")
                    return r
                end,math.min(self.Config.ServerSearchTimeout,remaining))
            end)
            if not ok and result==CANCEL then error(CANCEL,0) end
            token:Check()
            local code=ok and tonumber(result.StatusCode or result.Status)
            if code==200 then response=result self.PublicFailures=0 break end
            lastError=code and ("Server list HTTP "..code) or "Server-list connection failed"
            if code==400 and cursor and not resetCursor then
                cursor=nil self.PublicCursor=nil self.PublicCursorUntil=nil
                resetCursor=true url=base
            else
                if code and code~=429 and code<500 then error(lastError,0) end
                self.PublicFailures=math.min((self.PublicFailures or 0)+1,6)
                local delay=math.min(20,2^(self.PublicFailures-1))+math.random()*0.25
                if code==429 then
                    local headers=result.Headers or result.headers
                    local retry=type(headers)=="table" and tonumber(headers["Retry-After"] or headers["retry-after"])
                    delay=math.max(delay,finite(retry) and math.clamp(retry,1,300) or 10)
                end
                self.PublicRetryAt=os.clock()+delay
                if attempt<3 and delay<deadline-os.clock() then token:Sleep(delay) else break end
            end
        end
        if not response then self.ServerSearchDiagnostic=lastError or "Server search budget reached" break end
        assert(type(response.Body)=="string" and #response.Body<2000000,"Server-list body is invalid")
        local decoded,data=pcall(S.HttpService.JSONDecode,S.HttpService,response.Body)
        assert(decoded and type(data)=="table" and type(data.data)=="table","Unexpected server-list response")
        for _,server in ipairs(data.data) do
            if type(server)=="table" and serverID(server.id) and not ids[server.id]
                and finite(server.playing) and finite(server.maxPlayers)
                and server.playing>=0 and server.playing<server.maxPlayers
                and not self:IsServerExcluded(server.id)
                and (not self.FailedServers[server.id] or self.FailedServers[server.id]<=os.time()) then
                ids[server.id]=true servers[#servers+1]=server.id
            end
        end
        local nextCursor=type(data.nextPageCursor)=="string" and #data.nextPageCursor<=2048
            and data.nextPageCursor~="" and data.nextPageCursor or nil
        self.PublicCursor=nextCursor
        self.PublicCursorUntil=nextCursor and os.time()+180 or nil
        if #servers>0 or not nextCursor or cursors[nextCursor] then break end
        cursors[nextCursor]=true cursor=nextCursor
        token:Sleep(self.Config.PerformanceMode and 0.03 or 0.2)
    end
    for i=#servers,2,-1 do local j=math.random(i) servers[i],servers[j]=servers[j],servers[i] end
    return servers
end

-- The tracker supplies observation history, never a claimed server creation date.
-- Standard fallback is explicit; oldest-only mode waits for tracker recovery.
function H:TrackerServers(token)
    token:Check()
    if type(Request)~="function" then return nil,"HTTP request function unavailable" end
    if not trackerURL(self.Config.TrackerURL) then return nil,"Invalid Worker URL" end
    if not trackerKey(self.Config.TrackerToken) then return nil,"Tracker key missing or invalid" end
    local bookmark=self.TrackerCursor
    local cursor=bookmark and bookmark.URL==self.Config.TrackerURL and bookmark.After or nil
    local deadline=os.clock()+self.Config.ServerSearchBudget
    local rewound=false
    for page=1,4 do
        token:Check()
        if os.clock()>=deadline then return nil,"Continuing oldest-server pagination" end
        local exclusions,seen={},{}
        local function exclude(id)
            if #exclusions<1250 and serverID(id) and not seen[id] then
                seen[id]=true exclusions[#exclusions+1]=id
            end
        end
        exclude(game.JobId)
        for id,untilTime in pairs(self.FailedServers) do if untilTime>os.time() then exclude(id) end end
        for _,entry in ipairs(self.OldServerBatch and self.OldServerBatch.Entries or {}) do
            if self:IsServerExcluded(entry.id) then exclude(entry.id) end
        end
        -- Suppress returned historical IDs before recent visits. Pagination
        -- makes the 1250-ID HTTP limit independent of the six-hour history size.
        for _,id in ipairs(self.TrackerSuppressed or {}) do
            if self:IsServerExcluded(id) then exclude(id) end
        end
        local visits={}
        for id,stamp in pairs(self:EnsureServerCycle().Visited) do visits[#visits+1]={Id=id,Stamp=stamp} end
        table.sort(visits,function(a,b) return a.Stamp>b.Stamp end)
        for _,entry in ipairs(visits) do exclude(entry.Id) end
        local body=S.HttpService:JSONEncode({placeId=game.PlaceId,exclude=exclusions,limit=100,after=cursor,
            maxSeenAgeSeconds=math.floor(self.Config.TrackerFreshness*60),
            minObservedAgeSeconds=math.floor(self.Config.TrackerMinAge*60)})
        local response=token:Await(function()
            local sent,result=pcall(Request,{Url=self.Config.TrackerURL.."/v1/servers",Method="POST",
                Headers={["Content-Type"]="application/json",["Authorization"]="Bearer "..self.Config.TrackerToken},Body=body})
            assert(sent and type(result)=="table","Tracker connection failed")
            return result
        end,math.min(self.Config.TrackerTimeout,math.max(0.1,deadline-os.clock())))
        local code=tonumber(response.StatusCode or response.Status)
        if code==401 then return nil,"Tracker key rejected" end
        if code==503 then return nil,"Tracker warming up or unavailable" end
        if code~=200 then return nil,"Tracker HTTP "..tostring(code or "unavailable") end
        if type(response.Body)~="string" or #response.Body>65536 then return nil,"Invalid tracker response" end
        local decoded,data=pcall(S.HttpService.JSONDecode,S.HttpService,response.Body)
        if not decoded or type(data)~="table" or data.schema~=1 or data.placeId~=game.PlaceId
            or data.ageKind~="observed_minimum" or data.stale~=false or type(data.servers)~="table"
            or #data.servers>100 or not finite(data.generatedAt) or not finite(data.lastScanAt)
            or math.abs(os.time()-data.generatedAt)>120 or data.lastScanAt>data.generatedAt
            or data.generatedAt-data.lastScanAt>900 then return nil,"Tracker data is stale or invalid" end
        local paginated=data.paginationVersion==1
        local nextCursor=data.nextCursor
        if paginated and data.hasMore==true then
            if type(nextCursor)~="table" or not serverID(nextCursor.id) or not finite(nextCursor.firstSeen)
                or nextCursor.firstSeen<=0 or nextCursor.firstSeen>data.generatedAt
                or (cursor and nextCursor.firstSeen==cursor.firstSeen and nextCursor.id==cursor.id) then
                return nil,"Invalid tracker pagination cursor"
            end
        else nextCursor=nil end
        local ordered,accepted,suppressed={},{},{}
        for _,entry in ipairs(data.servers) do
            if type(entry)=="table" and serverID(entry.id) and self:IsServerExcluded(entry.id) then
                suppressed[#suppressed+1]=entry.id
            end
            if type(entry)=="table" and serverID(entry.id) and entry.id~=game.JobId
                and not accepted[entry.id] and not self:IsServerExcluded(entry.id)
                and (not self.FailedServers[entry.id] or self.FailedServers[entry.id]<=os.time())
                and finite(entry.firstSeen) and finite(entry.lastSeen) and entry.firstSeen>0
                and entry.firstSeen<=entry.lastSeen and entry.lastSeen<=data.generatedAt
                and data.generatedAt-entry.lastSeen<=self.Config.TrackerFreshness*60
                and data.generatedAt-entry.firstSeen>=self.Config.TrackerMinAge*60
                and finite(entry.playing) and finite(entry.maxPlayers)
                and entry.playing>=0 and entry.playing<entry.maxPlayers then
                accepted[entry.id]=true ordered[#ordered+1]=entry
            end
        end
        local suppressionSet={}
        for _,id in ipairs(suppressed) do suppressionSet[id]=true end
        for _,id in ipairs(self.TrackerSuppressed or {}) do
            if #suppressed>=1150 then break end
            if not suppressionSet[id] and self:IsServerExcluded(id) then
                suppressionSet[id]=true suppressed[#suppressed+1]=id
            end
        end
        self.TrackerSuppressed=suppressed
        table.sort(ordered,function(a,b)
            return a.firstSeen==b.firstSeen and a.id<b.id or a.firstSeen<b.firstSeen
        end)
        self.TrackerCursor=nextCursor and {URL=self.Config.TrackerURL,After=nextCursor} or nil
        self.OldServerBatch={URL=self.Config.TrackerURL,FetchedAt=os.time(),Entries=ordered}
        local filters=type(data.filters)=="table" and data.filters or {}
        self.ServerSearchDiagnostic=string.format(
            "Tracker %s - tracked=%d; stale=%d; full=%d; below minimum age=%d; excluded=%d; eligible=%d; page=%d; more=%s",
            tostring(data.version or "unknown"),tonumber(data.tracked) or 0,tonumber(filters.stale) or 0,
            tonumber(filters.full) or 0,tonumber(filters.tooYoung) or 0,tonumber(filters.excluded) or 0,
            tonumber(data.eligible) or 0,page,tostring(nextCursor~=nil))
        if #ordered>0 then
            local result={}
            for _,entry in ipairs(ordered) do result[#result+1]=entry.id end
            self.TrackerStatus=string.format("Ready - %d oldest-observed candidates",#result)
            return result
        end
        if paginated and nextCursor then
            cursor=nextCursor -- Continue immediately past rejected/visited pages.
        elseif paginated and cursor and not rewound and (tonumber(data.eligible) or 0)>0 then
            cursor=nil rewound=true -- Pick up refreshed/added records before the bookmark.
        elseif not paginated and #suppressed>0 and page<4 and #exclusions<1250 then
            cursor=nil -- Compatibility with Worker 1.0.2, until it is updated.
        else
            if not paginated and #suppressed>0 then return nil,"Tracker pagination update required - install Worker 1.0.3" end
            if (tonumber(filters.tooYoung) or 0)>0 and (tonumber(data.eligible) or 0)==0 then
                return nil,"No tracked server meets the minimum observed age"
            end
            if (tonumber(data.tracked) or 0)>0 and finite(data.freshTracked) and data.freshTracked==0 then
                return nil,"Tracked servers need a fresh scan"
            end
            return nil,"No eligible observed server"
        end
    end
    return nil,"Continuing oldest-server pagination"
end
function H:SearchServers(token)
    token:Check()
    local useTracker=self.Config.TrackerEnabled
    if not useTracker then
        return self:PublicServers(token),"Standard"
    end
    local batch=self:CachedOldServers()
    if #batch>0 then
        self.TrackerStatus="Ready - "..#batch.." oldest-observed candidates cached"
        return batch,"Oldest observed"
    end
    if os.clock()<(self.TrackerRetryAt or 0) then
        if self.Config.TrackerAllowFallback then return self:PublicServers(token),"Standard" end
        return {},"Oldest observed"
    end
    -- Both operations are reads. Preserve tracker preference, but overlap the
    -- standard fallback so a failed tracker does not add two network waits.
    local trackerScope=self:Token(token)
    local publicScope=self:Token(token)
    local trackerResult,publicResult
    local publicWorker
    local trackerWorker=task.spawn(function()
        trackerResult=table.pack(pcall(self.TrackerServers,self,trackerScope))
    end)
    local cleaned=false
    local function clean()
        if cleaned then return end
        cleaned=true
        for _,thread in pairs({trackerWorker,publicWorker}) do
            if coroutine.status(thread)~="dead" then pcall(task.cancel,thread) end
        end
        trackerScope:Clean() publicScope:Clean()
    end
    token:Finally(clean)
    local hedgeAt=os.clock()+0.6
    while not trackerResult do
        token:Check()
        if self.Config.TrackerAllowFallback and self.Config.PerformanceMode and not publicWorker and os.clock()>=hedgeAt then
            publicWorker=task.spawn(function()
                publicResult=table.pack(pcall(self.PublicServers,self,publicScope))
            end)
        end
        token:Sleep(0.05)
    end
    if trackerResult[1] and type(trackerResult[2])=="table" and #trackerResult[2]>0 then
        self.TrackerRetryAt=nil self.TrackerFallbackLogged=false self.TrackerFailures=0
        local result=trackerResult[2]
        clean()
        return result,"Oldest observed"
    end
    if trackerResult[2]==CANCEL then clean() error(CANCEL,0) end
    self.TrackerStatus=trackerResult[1] and (trackerResult[3] or "No eligible tracked server")
        or "Tracker request failed or timed out"
    self.TrackerFailures=math.min((self.TrackerFailures or 0)+1,5)
    local retry=self.TrackerStatus=="Continuing oldest-server pagination" and 1
        or self.TrackerStatus=="No eligible observed server" and 15
        or math.min(self.Config.TrackerBackoff,5*2^(self.TrackerFailures-1))
    if self.TrackerStatus=="Tracker key rejected" or self.TrackerStatus=="Tracker key missing or invalid"
        or self.TrackerStatus=="Invalid Worker URL" then retry=self.Config.TrackerBackoff end
    self.TrackerRetryAt=os.clock()+retry
    if not self.TrackerFallbackLogged or self.LastTrackerWarning~=self.TrackerStatus then
        self.LastTrackerWarning=self.TrackerStatus
        self:Log(self.TrackerStatus..(self.Config.TrackerAllowFallback and " - using standard search" or " - oldest-server search will retry"),"WARNING")
        self.TrackerFallbackLogged=true
    end
    if not self.Config.TrackerAllowFallback then
        clean()
        return {},"Oldest observed"
    end
    if not publicWorker then
        publicWorker=task.spawn(function()
            publicResult=table.pack(pcall(self.PublicServers,self,publicScope))
        end)
    end
    while not publicResult do token:Sleep(0.05) end
    clean()
    if not publicResult[1] then error(publicResult[2],0) end
    return publicResult[2],"Standard"
end

function H:StartServerPrefetch(token)
    self:EnsureServerCycle()
    if not self.Config.PrefetchServers then return end
    local cached=self.ServerCandidateCache
    if cached and os.clock()<cached.Until and #self:EligibleServers(cached.Servers)>0 then return end
    local previous=self.ServerPrefetch
    if previous and not previous.Done and not previous.Cancelled then return previous end
    if previous and previous.Done and os.clock()-(previous.Finished or 0)<2 then return previous end
    local state={Scope=self:Token(token),Started=os.clock(),Revision=self.ServerSearchRevision}
    self.ServerPrefetch=state
    token:Finally(function()
        if not state.Done then
            state.Cancelled=true
            if state.Worker and coroutine.status(state.Worker)~="dead" then pcall(task.cancel,state.Worker) end
            state.Scope:Clean()
            if self.ServerPrefetch==state then self.ServerPrefetch=nil end
        end
    end)
    state.Worker=task.spawn(function()
        local result=table.pack(pcall(self.SearchServers,self,state.Scope))
        state.Scope:Clean()
        if state.Cancelled or state.Revision~=self.ServerSearchRevision then
            state.Cancelled=true return
        end
        state.Done=true state.Finished=os.clock()
        self.LastServerSearchSeconds=state.Finished-state.Started
        if result[1] then
            state.Servers=self:EligibleServers(result[2]) state.Source=result[3]
            if #state.Servers>0 then
                self.ServerCandidateCache={Servers=state.Servers,Source=state.Source,
                    Until=os.clock()+self.Config.CandidateCacheSeconds}
            end
        else
            -- Request exceptions may include headers; never log their raw value.
            state.Failed=true
            self.ServerSearchDiagnostic="Background server lookup failed"
        end
    end)
    return state
end

function H:Servers(token)
    token:Check()
    self:EnsureServerCycle()
    if self.Config.TrackerEnabled then
        local batch=self:CachedOldServers()
        if #batch>0 then
            self.ServerSource="Oldest observed"
            self.ServerCacheHits=(self.ServerCacheHits or 0)+1
            return batch
        end
    end
    local cached=self.ServerCandidateCache
    if cached and os.clock()<cached.Until and (not self.Config.TrackerEnabled
        or self.Config.TrackerAllowFallback or cached.Source=="Oldest observed") then
        local eligible=self:EligibleServers(cached.Servers)
        if #eligible>0 then
            self.ServerSource=cached.Source
            self.ServerCacheHits=(self.ServerCacheHits or 0)+1
            return eligible
        end
    end
    local state=self:StartServerPrefetch(token)
    if state then
        while not state.Done and not state.Cancelled do token:Sleep(0.05) end
        token:Check()
        if state.Done and state.Servers then
            self.ServerSource=state.Source
            return self:EligibleServers(state.Servers)
        end
        return {}
    end
    local started=os.clock()
    local servers,source=self:SearchServers(token)
    self.LastServerSearchSeconds=os.clock()-started
    self.ServerSource=source
    servers=self:EligibleServers(servers)
    self.ServerCandidateCache={Servers=servers,Source=source,Until=os.clock()+self.Config.CandidateCacheSeconds}
    return servers
end
function H:Bootstrap()
    assert(#queueAPIs()>0, "queue_on_teleport unavailable - automatic continuation is not supported")
    assert(type(loadstring)=="function", "loadstring unavailable")
    assert(Read and Write, "Saved continuation requires readfile and writefile")
    if self.BootstrapPayload and self.BootstrapURL==self.Config.ScriptURL then return self.BootstrapPayload end
    local marker="Midnight Spooky Hunter "..self.Version
    local source=Env.MidnightSpookySource
    local cacheFile="MidnightSpookyHunter-"..self.Version..".cache.lua"
    local cached=false
    local inline=""
    if type(source)=="string" and source:find(marker,1,true) then
        cached=pcall(function()
            local ok,current=pcall(Read,cacheFile)
            if not ok or current~=source then Write(cacheFile,source) end
            assert(Read(cacheFile)==source,"Source cache verification failed")
        end)
        if not cached then inline=source end
    else
        local ok,current=pcall(Read,cacheFile)
        cached=ok and type(current)=="string" and current:find(marker,1,true)~=nil
    end
    assert(cached or inline~="" or self.Config.ScriptURL:match("^https://"),
        "Set Script URL in Settings or start with the companion loader")
    local payload=[==[
local env=type(getgenv)=="function" and getgenv() or _G
local previous=env.MidnightSpookyBootstrap
if type(previous)=="table" and previous.Active and not previous.Cancelled then return end
local existing=env.MidnightSpookyHunter
if type(existing)=="table" and existing.Alive and existing.BootReady and existing.JobId==game.JobId then return end
local boot={Active=true,Cancelled=false,Attempts=0}
env.MidnightSpookyBootstrap=boot
task.spawn(function()
    local ok=pcall(function()
        local players=game:GetService("Players")
        local deadline=os.clock()+900
        while not game:IsLoaded() or not players.LocalPlayer or game.JobId=="" do
            if boot.Cancelled or os.clock()>=deadline then return end
            task.wait(0.2)
        end
        local reader=env.readfile or readfile
        local compiler=env.loadstring or loadstring
        if type(reader)~="function" or type(compiler)~="function" then
            warn("[Spooky Hunter] Continuation requires readfile and loadstring in the new server")
            return
        end
        local ticket
        for attempt=1,10 do
            local readOK,data=pcall(function()
                return game:GetService("HttpService"):JSONDecode(reader(__FILE__))
            end)
            if not readOK or type(data)~="table" then
                readOK,data=pcall(function()
                    return game:GetService("HttpService"):JSONDecode(reader(__FILE__..".bak"))
                end)
            end
            if readOK and type(data)=="table" then ticket=data break end
            if boot.Cancelled then return end
            task.wait(0.5)
        end
        if not ticket or ticket.Resume~=true or ticket.PlaceId~=game.PlaceId
            or type(ticket.TicketTime)~="number" or ticket.TicketTime~=ticket.TicketTime
            or os.time()-ticket.TicketTime< -60 or os.time()-ticket.TicketTime>1800
            or (ticket.Target~=game.JobId and not (ticket.Target=="*" and ticket.Recovery==true))
            or ticket.BotDesired=="paused" then return end
        local source
        local function valid(text)
            return type(text)=="string" and #text>100 and text:find(__MARKER__,1,true)~=nil
        end
        local cacheOK,cache=pcall(reader,__CACHE__)
        if cacheOK and valid(cache) then source=cache end
        if not source and valid(__INLINE__) then source=__INLINE__ end
        local url=__URL__
        while not boot.Cancelled and os.time()-ticket.TicketTime<1800 do
            boot.Attempts=boot.Attempts+1
            if not source and url:match("^https://") then
                local downloaded
                local thread=task.spawn(function() downloaded=table.pack(pcall(game.HttpGet,game,url)) end)
                local untilTime=os.clock()+20
                while not downloaded and not boot.Cancelled and os.clock()<untilTime do task.wait(0.1) end
                if not downloaded then pcall(task.cancel,thread)
                elseif downloaded[1] and valid(downloaded[2]) then source=downloaded[2] end
            end
            if boot.Cancelled then return end
            local compiled=source and compiler(source)
            if type(compiled)=="function" then
                env.MidnightSpookySource=source
                env.MidnightSpookyResume=true
                env.MidnightSpookyResumeTicket=ticket
                local result
                local thread=task.spawn(function() result=table.pack(pcall(compiled)) end)
                local untilTime=os.clock()+180
                while not result and not boot.Cancelled and os.clock()<untilTime do task.wait(0.1) end
                if not result then pcall(task.cancel,thread) end
                if boot.Cancelled then return end
                if result and result[1] and type(result[2])=="table" and result[2].Alive and result[2].BootReady then
                    env.MidnightSpookyBootServer=game.JobId
                    boot.Completed=true
                    return
                end
                local partial=env.MidnightSpookyHunter
                boot.Cleaning=true
                if type(partial)=="table" and type(partial.Destroy)=="function" then pcall(partial.Destroy,partial) end
                boot.Cleaning=false
            else source=nil end
            if boot.Attempts==1 or boot.Attempts%5==0 then
                warn("[Spooky Hunter] Startup incomplete - retrying automatically ("..boot.Attempts..")")
            end
            local untilTime=os.clock()+math.min(15,2*boot.Attempts)
            while not boot.Cancelled and os.clock()<untilTime do task.wait(0.2) end
        end
    end)
    boot.Active=false
    env.MidnightSpookyResume=nil
    env.MidnightSpookyResumeTicket=nil
    if not boot.Completed and not boot.Cancelled then
        warn(ok and "[Spooky Hunter] No valid continuation completed - check the script URL and executor"
            or "[Spooky Hunter] Continuation failed before startup - check executor support")
    end
end)
]==]
    local substitutions={__FILE__=FILE,__MARKER__=marker,__CACHE__=cacheFile,
        __INLINE__=inline,__URL__=self.Config.ScriptURL}
    payload=payload:gsub("__[A-Z]+__",function(key) return string.format("%q",substitutions[key]) end)
    self.BootstrapPayload=payload self.BootstrapURL=self.Config.ScriptURL
    return payload
end

function H:QueueContinuation(arm,backup)
    if not arm or self.TeleportArm~=arm or arm.Queuing then return false end
    if backup and arm.BackupQueued then return true end
    arm.Queuing=true
    for _,api in ipairs(queueAPIs()) do
        local ok,result=pcall(api.Call,arm.Payload)
        if ok and result~=false then
            arm.Queuing=false arm.Queued=true
            if backup then arm.BackupQueued=true end
            self.QueueBackend=api.Name
            return true
        end
    end
    arm.Queuing=false
    return false
end
function H:ArmContinuation(target,payload)
    self.PendingTeleportTarget=target
    local arm={Target=target,Payload=payload or self:Bootstrap()}
    self.TeleportArm=arm
    local saved,reason=self:Persist(true,target)
    if not saved then
        self.PendingTeleportTarget=nil self.TeleportArm=nil
        return false,reason
    end
    if not self:QueueContinuation(arm,false) then
        self.PendingTeleportTarget=nil self.TeleportArm=nil
        self:Persist(false)
        return false,"All available teleport queue functions rejected continuation"
    end
    return true
end
-- ErrorMessageChanged also reports non-disconnect errors. Never cancel a live
-- harvest merely because an error string was displayed.
function H:ConfirmedDisconnect()
    local gotMessage,message=pcall(function() return S.GuiService:GetErrorMessage() end)
    if not gotMessage or type(message)~="string" or message=="" then return false end
    local gotCode,code=pcall(function() return S.GuiService:GetErrorCode() end)
    if not gotCode then return false end
    local name=typeof(code)=="EnumItem" and code.Name or ""
    local numberCode=typeof(code)=="EnumItem" and code.Value or tonumber(code)
    -- Use the typed engine reason when exposed. Numeric fallbacks are limited
    -- to disconnect reasons; HTTP, purchase and teleport errors are excluded.
    local disconnected=name:sub(1,10)=="Disconnect" and not name:find("Teleport",1,true)
    local knownCodes={[266]=true,[267]=true,[277]=true,[278]=true,[285]=true,[288]=true}
    if not disconnected and not knownCodes[numberCode] then return false end
    return true,message,name~="" and name or tostring(numberCode)
end
function H:ScheduleRejoinCheck()
    self.DisconnectRevision=(self.DisconnectRevision or 0)+1
    local revision=self.DisconnectRevision
    if self.DisconnectCheck then pcall(task.cancel,self.DisconnectCheck) self.DisconnectCheck=nil end
    if not self.Config.AutoRejoin or self.Rejoining or not self.Running then return end
    self.DisconnectCheck=task.delay(1.5,function()
        self.DisconnectCheck=nil
        if not self.Alive or revision~=self.DisconnectRevision then return end
        local confirmed,message,code=self:ConfirmedDisconnect()
        if not confirmed then return end
        local ok,err=pcall(self.BeginRejoin,self,message,code)
        if not ok and self.Alive then self:Log("Rejoin preparation failed - "..cleanError(err),"WARNING") end
    end)
end
-- Recovery uses a separate, cancellable worker. It cannot restart a closed Roblox process.
function H:BeginRejoin(message)
    if not self.Alive or not self.Config.AutoRejoin or self.Rejoining
        or self.BotDesired == "paused" or self.HopAttempt or not (self.Running or self.Busy) then return end
    local disconnected,currentMessage,disconnectCode=self:ConfirmedDisconnect()
    if not disconnected then return end
    self.LastDisconnect={Stage=self.Stage,Code=disconnectCode,Message=currentMessage,Time=os.time()}
    local ready, bootstrap = pcall(self.Bootstrap, self)
    if not ready then self:Log("Auto rejoin unavailable - " .. cleanError(bootstrap), "WARNING") return end
    self.Rejoining = true
    self.Generation = self.Generation + 1
    self.Watchdog = false
    if self.Worker then pcall(task.cancel, self.Worker) self.Worker = nil end
    if self.ActiveToken then self.ActiveToken:Clean() self.ActiveToken = nil end
    if self.ModwoodGuard then self.ModwoodGuard:Release() end
    self.Running, self.Busy = true, true
    self.HopAttempt = nil
    self.HopUncertain = false
    self:NotifyBot("Connection interrupted", "Attempting to reconnect. Unfinished wood is not counted as collected.")
    self:Log("Connection interrupted during "..self.LastDisconnect.Stage.." - "..disconnectCode.." - preparing rejoin", "WARNING")
    self.RejoinWorker = task.defer(function()
        local attempt = 0
        local function waitFor(seconds)
            local deadline = os.clock() + seconds
            repeat
                if not self.Alive or not self.Rejoining or not self.Config.AutoRejoin then return false end
                task.wait(0.2)
            until os.clock() >= deadline
            return true
        end
        while self.Alive and self.Rejoining and self.Config.AutoRejoin do
            attempt = attempt + 1
            local delay = math.min(60, self.Config.RejoinDelay * 2 ^ math.min(attempt - 1, 4))
            self:SetStage("Rejoining game", nil, "Attempt " .. attempt)
            if not waitFor(delay) then break end
            -- A wildcard ticket is valid only for a recovery into this exact place.
            local armed, failure = self:ArmContinuation("*",bootstrap)
            if armed then
                self.RejoinAttempt = {Number=attempt}
                local sent, reason = pcall(S.TeleportService.Teleport, S.TeleportService, game.PlaceId, Player)
                if not sent then self.RejoinAttempt.Error = tostring(reason) end
                local deadline = os.clock() + 45
                while self.Rejoining and not self.RejoinAttempt.Error and os.clock() < deadline do
                    if not waitFor(0.2) then break end
                end
                if self.Rejoining then self:Log(self.RejoinAttempt.Error or "Rejoin has not completed - retry pending", "WARNING") end
                self.RejoinAttempt = nil
            else
                self:Log(failure or "Could not queue the script for rejoin", "WARNING")
            end
        end
        self.RejoinWorker = nil
        if self.Alive and self.Rejoining then
            self.Rejoining = false
            self.Running, self.Busy = false, false
            self.PendingTeleportTarget = nil
            self:Persist(false)
            self:SetStage("Ready", nil)
        end
    end)
end

function H:Hop(token)
    assert(not self.Dirty, "Unfinished wood is still in this server")
    -- Character removal is normal while teleporting; it must not cancel the
    -- armed ticket and start a second destination request.
    token.Character=nil
    self.Watchdog=false
    self.AwaitingServer=true
    local bootstrap=self:Bootstrap()
    self:RememberServer(game.JobId)
    local stored, storeError = self:Persist(false) assert(stored, storeError)
    local leaveAt = os.clock() + self.Config.HopDelay
    self:StartServerPrefetch(token)
    self:SetStage("Next server",0.98,"Preparing the next server")
    local servers
    for round=1,3 do
        self:SetStage("Finding another server",0.98,"History: "..#self.ServerHistory.." / 1000")
        servers=self:Servers(token)
        if #servers>0 then break end
        if round<3 then
            self:SetStage("Waiting for available servers",0.98,"Refreshing in "..self.Config.ServerRetryDelay.."s")
            token:Sleep(self.Config.ServerRetryDelay)
        end
    end
    assert(#servers>0,"No eligible server available - recent-server history was preserved")
    -- Candidate lookup runs during the requested delay, not after it.
    if os.clock()<leaveAt then token:Sleep(leaveAt-os.clock()) end
    servers=self:EligibleServers(servers)
    assert(#servers>0,"Server candidates expired - refreshing on the next attempt")
    for i=1,math.min(#servers,8) do
        token:Check()
        local id=servers[i]
        self.FailedServers[id]=os.time()+600
        -- Executors differ on whether a failed teleport consumes the queue.
        -- Requeue each attempt; the bootstrap permits only one launch per server.
        local armed,reason=self:ArmContinuation(id,bootstrap) assert(armed,reason)
        local attempt={Id=id} self.HopAttempt=attempt
        self:SetStage("Joining another server",1,(self.ServerSource=="Oldest observed" and "Oldest available - " or "").."Attempt "..i)
        local ok=pcall(S.TeleportService.TeleportToPlaceInstance,S.TeleportService,game.PlaceId,id,Player)
        if not ok then attempt.Error="Teleport request rejected" end
        local deadline=os.clock()+35
        while not attempt.Error and os.clock()<deadline do token:Sleep(0.2) end
        self.HopAttempt=nil
        if not attempt.Error then self.HopUncertain=true error("Teleport outcome unknown - no second request sent",0) end
        self.TeleportArm=nil self.PendingTeleportTarget=nil
        self:Persist(false)
        self:Log(attempt.Error,"WARNING")
        local pause=self.Config.HopDelay
        if attempt.FailureKind=="GameFull" or attempt.FailureKind=="GameEnded" then
            self.FailedServers[id]=os.time()+60
            pause=self.Config.PerformanceMode and 0.2 or pause
        elseif attempt.FailureKind=="Flooded" then
            pause=math.max(pause,10)
        elseif self.Config.PerformanceMode then
            pause=math.max(0.5,pause)
        end
        token:Sleep(pause)
    end
    error("No server could be joined",0)
end
-- Rebuild candidate entries from current instances, never from the scan card or old volume.
function H:VerifyTargets(entries)
    local verified,seen={},{}
    for _,entry in ipairs(entries) do
        local model=entry.Model
        if not seen[model] and self:IsStandingTree(model) then
            local kind=value(model,"TreeClass")
            local owner,field=self:TreeOwner(model)
            local claimed=owner==Player and (entry.GrowthClaimed or model==self.GrowthTarget)
            if field and self:WantsTree(kind) and (owner==nil or claimed) then
                local volume=self:WoodVolume(model)
                if self:EligibleVolume(kind,volume) then
                    seen[model]=true
                    entry.Trunk=self:TreeTrunk(model) entry.Kind=kind entry.Volume=volume
                    entry.GrowthClaimed=claimed
                    verified[#verified+1]=entry
                end
            end
        end
    end
    self.RejectedTargets=(self.RejectedTargets or 0)+#entries-#verified
    return verified
end
function H:ValidatePending(token)
    local function validWood(model,kind)
        return typeof(model)=="Instance" and model:IsA("Model") and under(model,S.Workspace)
            and owned(model) and value(model,"TreeClass")==kind and self:WoodVolume(model)>0
    end
    local waiting=false
    local discarded=false
    local seen={}
    for index=#self.PendingWood,1,-1 do
        token:Check()
        local work=self.PendingWood[index]
        local reason
        if type(work)~="table" then reason="Invalid task record"
        elseif seen[work] then reason="Duplicate task record"
        else
            seen[work]=true
            if work.Saved then
                -- Already explicitly saved; only accounting may have been interrupted.
                self:RecordHarvest(work)
                reason="Saved task removed from the queue"
            elseif work.JobId and work.JobId~=game.JobId then reason="Task belongs to a different server"
            elseif work.Slot and work.Slot~=self.Config.Slot then reason="Task belongs to a different slot"
            elseif work.Modwood and not work.Planks then
                return false,"An unfinished Modwood attempt cannot be restarted"
            else
                local available=false
                if work.Planks then
                    if #work.Planks>0 then
                        available=true
                        for _,plank in ipairs(work.Planks) do
                            if not validWood(plank,work.Kind) then available=false break end
                        end
                    end
                else
                    if work.Log and under(work.Log,S.Workspace) then
                        local owner=self:TreeOwner(work.Log)
                        if owner and owner~=Player then return false,"Remaining wood now belongs to another player" end
                    end
                    if not validWood(work.Log,work.Kind) then
                        work.Log=nil
                        if work.Cut then work.Log=self:FindFelledLog(work.Cut) end
                    end
                    available=validWood(work.Log,work.Kind)
                    if not available and work.Cut and self:IsStandingTree(work.Cut.Tree)
                        and livePart(work.Cut.Trunk) and under(work.Cut.Trunk,work.Cut.Tree) then
                        local owner,field=self:TreeOwner(work.Cut.Tree)
                        if field and owner and owner~=Player then return false,"Cut target now belongs to another player" end
                        available=field~=nil and (owner==nil or owner==Player)
                    end
                end
                if available then
                    work.MissingSince=nil
                else
                    work.MissingSince=work.MissingSince or os.clock()
                    if os.clock()-work.MissingSince>=self:AdaptiveWait(3,8) then
                        reason="Referenced wood is no longer present or owned"
                    else waiting=true end
                end
            end
        end
        if reason then
            table.remove(self.PendingWood,index)
            self.PrunedTasks=(self.PrunedTasks or 0)+1
            self:Log("Task discarded - "..reason,"DEBUG")
            if type(work)=="table" and not work.Saved then
                self.AbandonedTasks=(self.AbandonedTasks or 0)+1
                self.LastPrunedTask=reason
                discarded=true
            end
        end
    end
    self.Dirty=#self.PendingWood>0
    if discarded then
        self.Counts={Spooky=0,SpookyNeon=0,SpookyVolume=0,SpookyNeonVolume=0,IgnoredSmall=0}
        self.LastScanCardSignature=nil self.StandingCache=nil
        if self.UI then
            self.UI.Spooky:Set(0,"0 studs3") self.UI.Neon:Set(0,"0 studs3")
        end
        return false,"Stale harvest task discarded - "..tostring(self.LastPrunedTask)
    end
    if waiting then return nil,"Waiting for wood replication" end
    if #self.PendingWood==0 then
        self.NeedsAttention=false self.HarvestProgress=nil self.ActiveTarget=nil
        self.Progress=0 self.StandingCache=nil self.FoundNotified=false
    end
    return true
end
function H:RecoveryFingerprint()
    local fields={tostring(self.LastProgressAt or 0)}
    for _,work in ipairs(self.PendingWood) do
        if type(work)=="table" then
        fields[#fields+1]=table.concat({tostring(work),tostring(work.Log),tostring(work.AtBase),
            tostring(work.Modwood and work.Modwood.Phase),tostring(work.Saved)},"/")
        end
    end
    return table.concat(fields,"|")
end
function H:Run(token)
    self.ActiveTarget=nil
    if #self.PendingWood>0 then
        local valid,reason=self:ValidatePending(token)
        if valid==false then return self:LeaveStalledServer(token,reason) end
        if valid==nil then
            self.NeedsAttention=true
            self:SetStage("Checking remaining wood",self.Progress)
            token:Sleep(0.5)
            return reason
        end
    end
    if self.ServerExitReason then return self:LeaveStalledServer(token,self.ServerExitReason) end
    for _,work in ipairs(self.PendingWood) do
        if work.Classic then
            return self:LeaveStalledServer(token,"Legacy milling task discarded - Modwood only")
        end
    end
    assert(game.PlaceId==13822889,"This script targets Lumber Tycoon 2 (13822889)")
    assert(not S.Workspace.StreamingEnabled,"Streaming is enabled - a complete tree scan cannot be confirmed")
    self:StartServerPrefetch(token)
    if #self.PendingWood==0 then
        self:WaitForGame(token)
    else
        token.Character=self:Character()
        self:SetStage("Checking remaining wood",self.Progress)
    end
    self:Bootstrap()
    local resuming = #self.PendingWood>0
    if self.Dirty and not resuming then
        self.Dirty=false self.NeedsAttention=false
        self.HarvestProgress=nil self.ActiveTarget=nil self.StandingCache=nil
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
            return self:LeaveStalledServer(token,"The saved task no longer matches the loaded plot")
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
        self.BatchCollection=emptyCollection()
        entries=self:ScanReady(token)
        if #entries==0 then self:SetStage("No rare tree found",0.1) return self:Hop(token) end
        self:SetStage("Rare trees found",0.1,tostring(#entries).." trees")
        if not self.FoundNotified then
            self:NotifyBot("Rare trees found",self.Config.FullCycle and "Selected trees detected. Volumes shown below." or "Selected trees detected - search paused in this server.",token)
            self.FoundNotified=true
        end
        if not self.Config.FullCycle then return "Found - search paused in this server" end
        entries=self:VerifyTargets(entries)
        if #entries==0 then self:SetStage("Trees no longer available",0.1) return self:Hop(token) end
        self.CanRecover=false
        self.ActiveTarget=entries[1]
        self:CheckTargetOwner(self.ActiveTarget)
        self:StartHarvestPreparation(token,entries)
        if self.LoadReceipt and self.LoadReceipt.JobId==game.JobId and self.LoadReceipt.Slot==self.Config.Slot
            and self.LoadReceipt.Plot==self:Plot() then
            plot=self.LoadReceipt.Plot
        else plot=self:LoadSlot(token) end
    end
    self.CanRecover=false
    self:BeginHarvestProgress(entries)
    local batchStarted, initialPlanks = os.clock(), self.Stats.Planks
    local mill,inlet
    assert(plot and owned(plot),"Plot ownership changed before harvesting")
    local center=self:PlotCenter(plot) self.StackHeight=self.StackHeight or 0
    local processed, skipped = 0, 0
    for index,entry in ipairs(entries) do
        self.ActiveTarget=not entry.Work and entry or nil
        token:Check()
        if entry.Work or #self:VerifyTargets({entry})>0 then
            self:SelectHarvestProgress(entry)
            local scope=self:Token(token)
            local work=entry.Work
            local log=work and work.Log
            local cutStarted=work~=nil
            local ok,result=pcall(function()
                assert(owned(plot) and self:Plot()==plot,"Plot ownership changed during harvesting")
                self:ProtectHarvestCharacter(scope)
                if not work or (not work.Log and work.Cut) then
                    if not work and entry.Kind=="SpookyNeon" and self.Config.GrowSinister then
                        local grown,growthError=pcall(self.WaitForSinisterGrowth,self,entry,scope,token)
                        if not grown then
                            if growthError==CANCEL then error(CANCEL,0) end
                            self.ServerExitReason=cleanError(growthError)
                            error(growthError,0)
                        end
                        assert((entry.EarlyHarvest and entry.Volume>0) or entry.Volume>=MIN_TREE_VOLUME,
                            "Growth stabilized below the 60 studs3 harvest minimum")
                    end
                    local tool,stats=self:EnsureAxe(entry.Kind,scope)
                    self:UpdateHarvestProgress(0.02)
                    self:SetStage("Cutting "..entry.Kind,0.3,string.format("Tree %d / %d",index,#entries))
                    if not work then
                        work={Kind=entry.Kind,JobId=game.JobId,Slot=self.Config.Slot,CreatedAt=os.clock(),TreeVolume=self:WoodVolume(entry.Model),Reason="Cut started"}
                        table.insert(self.PendingWood,work)
                    end
                    self:LinkHarvestProgress(work)
                    cutStarted=true self.Dirty=true
                    local target=work.Cut and {Model=work.Cut.Tree,Trunk=work.Cut.Trunk,Kind=work.Kind} or entry
                    log=self:LocalStep(work,"cutting",scope,function(step)
                        local freshTool,freshStats=self:EnsureAxe(entry.Kind,step)
                        return self:Chop(target,freshTool,freshStats,step,work)
                    end)
                    if self.GrowthTarget==entry.Model then self.GrowthTarget=nil end
                    self.ActiveTarget=nil
                    work.Log=log self.Stats.Trees=self.Stats.Trees+1
                end
                self:LinkHarvestProgress(work)
                self:UpdateHarvestProgress(0.25)
                if not work.Planks then
                    if not work.Modwood then
                        if not (work.AtBase and log and log.Parent and owned(log)
                            and (log:GetPivot().Position-center.Position).Magnitude<120) then
                            self:LocalStep(work,"wood transport",scope,function(step)
                                self:BringTreeToBase(log,plot,step,center)
                            end)
                            work.AtBase=true
                        end
                        self:UpdateHarvestProgress(0.35)
                        mill,inlet=self:LocalStep(work,"sawmill selection",scope,function(step)
                            return self:FindMill(step,plot)
                        end)
                        self:UpdateHarvestProgress(0.38)
                        local supported, reason=self:WaitForModwood(log,scope)
                        if not supported then
                            self:CaptureModwood(log,mill,reason)
                            self.ServerExitReason=reason or "Modwood unavailable - incompatible tree"
                            return self.ServerExitReason
                        end
                    else
                        mill,inlet=work.Modwood.Mill,work.Modwood.Inlet
                        self.ServerExitReason="An unfinished Modwood attempt cannot be restarted"
                        error(self.ServerExitReason,0)
                    end
                    if not work.Planks then
                        self:UpdateHarvestProgress(0.40)
                        work.Planks=self:Modwood(log,mill,inlet,scope,work)
                    end
                end
                self:UpdateHarvestProgress(0.85)
                assert(owned(plot) and self:Plot()==plot,"Plot ownership changed before delivery")
                self:SetStage("Delivering planks",0.86,"Center of your plot")
                if not work.Saved then
                    self:LocalStep(work,"plank delivery",scope,function(step)
                        self:Deliver(work.Planks,center,step,work)
                    end)
                    self:LocalStep(work,"slot saving",scope,function(step)
                        self:SaveSlot(step)
                    end)
                    work.Saved=true
                end
                self:UpdateHarvestProgress(1,"Saved")
                self:RecordHarvest(work)
                return true
            end)
            scope:Clean()
            if result==CANCEL then error(CANCEL,0) end
            if self.ServerExitReason then
                local reason=self.ServerExitReason
                if work then work.Reason=reason end
                self:RecordFailure(self.Stage,reason)
                self:Log("Harvest interrupted - "..reason,"WARNING","Changing server")
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
                self:RecordFailure(self.Stage,reason)
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
        self:Log("Harvest has unfinished tasks - validating before retry","DEBUG")
        local atBase, unconfirmed=0,0
        for _,work in ipairs(self.PendingWood) do
            if work.AtBase then atBase=atBase+1 end
            if not work.Log and not work.Planks then unconfirmed=unconfirmed+1 end
        end
        if unconfirmed>0 then return "Cut not confirmed - Retry checks the same tree; no delivery confirmed" end
        if atBase==#self.PendingWood then return "Wood remains at your base - recovery is bounded" end
        return "Wood remains in this server - recovery is bounded"
    end
    if self.NeedsAttention then return "Equip a compatible inventory axe, then retry" end
    if processed>0 then
        self:NotifyBot(processed == #entries and "Harvest complete" or "Harvest complete - some trees unavailable",
            "Wood processed, planks delivered to your plot and slot save confirmed.",token,
            {Trees=processed, Planks=self.Stats.Planks-initialPlanks, Seconds=os.clock()-batchStarted, Skipped=skipped})
    else self:NotifyBot("Trees no longer available","No harvest was performed. Moving to the next server.",token) end
    token:Clean() token.Character=nil
    return self:Hop(token)
end
-- Modwood failures leave immediately; other stalled tasks have a bounded recovery.
function H:LeaveStalledServer(token,reason)
    self.Watchdog=false self.ActiveTarget=nil
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
    self:NotifyBot("Harvest interrupted",reason..". Moving to another server. Remaining wood was not confirmed as processed.",token)
    self.AbandonedTasks=(self.AbandonedTasks or 0)+#self.PendingWood
    self.PendingWood={} self.Dirty=false self.NeedsAttention=false
    self.Abandoning=true
    return self:Hop(token)
end
function H:Start()
    if self.Busy or self.Rejoining or not self.Alive then return end
    self.Running=true self.Busy=true self.NeedsAttention=false self.HopUncertain=false
    self.LastProgressAt=os.clock() self.ProgressKeys={} self.Watchdog=true
    self.RecoveryState=nil
    self.Abandoning=self.Abandoning==true
    if self.UI then self.UI.Start.Text="Hunting..." end
    self.Worker=task.defer(function()
        local result
        while self.Alive and self.Running do
            local token=self:Token() self.ActiveToken=token
            local ok
            if self.Abandoning or self.AwaitingServer then
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
            self.ActiveTarget=nil
            if result==CANCEL or not self.Alive or not self.Running then break end
            if ok and not self.NeedsAttention and not self.Config.FullCycle and not self.ServerExitReason then break end
            if result and (not self.LastFailure or self.LastFailure.Reason~=cleanError(result)) then self:RecordFailure(self.Stage,cleanError(result)) end
            if not self.LastFailure then self:RecordFailure(self.Stage,"Retry pending") end
            local fingerprint=self:RecoveryFingerprint()
            local recovery=self.RecoveryState
            if not recovery or recovery.Fingerprint~=fingerprint then
                recovery={Fingerprint=fingerprint,Attempts=0,Started=os.clock()}
                self.RecoveryState=recovery
            end
            recovery.Attempts=recovery.Attempts+1
            recovery.Reason=self.LastFailure.Reason
            local searching=self.Abandoning or self.AwaitingServer or self.HopUncertain
            if not searching and not self.ServerExitReason and
                (recovery.Attempts>=4 or os.clock()-recovery.Started>=45) then
                self.ServerExitReason="No confirmed progress after bounded recovery - "..recovery.Reason
                self.ActiveTarget=nil
            end
            if recovery.Attempts==1 or self.ServerExitReason then
                self:Log("Recovery - "..recovery.Reason,"DEBUG")
            end
            self.Watchdog=false
            token.Deadline=os.clock()+210
            local retryDelay=self.ServerExitReason and not self.HopUncertain and 0
                or (self.HopUncertain and 180 or math.min(8,2^(recovery.Attempts-1)))
            if self.HopUncertain then self:SetStage("Waiting for teleport",self.Progress)
            elseif self.ServerExitReason then self:SetStage("Changing server",self.Progress)
            elseif not searching then self:SetStage("Checking remaining wood",self.Progress) end
            if self.AwaitingServer and not self.HopUncertain and self.Config.TrackerEnabled
                and not self.Config.TrackerAllowFallback then
                retryDelay=math.max(retryDelay,math.min(30,(self.TrackerRetryAt or 0)-os.clock()))
                self:SetStage("Waiting for oldest servers",0.98,self.TrackerStatus)
            end
            local waited,err=pcall(token.Sleep,token,retryDelay)
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
    self.ActiveTarget=nil
    local boot=Env.MidnightSpookyBootstrap
    if type(boot)=="table" and boot.Active and not boot.Cleaning then boot.Cancelled=true end
    self.TeleportArm=nil self.AwaitingServer=false
    self.DisconnectRevision=(self.DisconnectRevision or 0)+1
    if self.DisconnectCheck then pcall(task.cancel,self.DisconnectCheck) self.DisconnectCheck=nil end
    self.Rejoining=false
    if self.RejoinWorker then pcall(task.cancel,self.RejoinWorker) self.RejoinWorker=nil end
    self.RejoinAttempt=nil
    if not self.Worker then self.Busy=false end
    self.Running=false self.Generation=self.Generation+1
    self.HopUncertain=false self.PendingTeleportTarget=nil
    self:Persist(false)
    if self.ActiveToken then self.ActiveToken:Clean() end
    if self.ModwoodGuard then self.ModwoodGuard:Release() end
    if self.Alive then self:SetStage("Stopping",self.Progress,self.HopAttempt and "A teleport already sent cannot be recalled" or "Cleaning up the current task") end
end
function H:Destroy()
    if not self.Alive then return end
    self:Stop() self.Alive=false
    if self.BotPersistWorker then pcall(task.cancel,self.BotPersistWorker) self.BotPersistWorker=nil end
    if self.RenderDisabled then
        pcall(function() S.RunService:Set3dRenderingEnabled(true) end)
        self.RenderDisabled=false
    end
    if self.AntiAfkConnection then self.AntiAfkConnection:Disconnect() self.AntiAfkConnection=nil end
    if self.Worker then pcall(task.cancel,self.Worker) end
    if self.BotRequestThread then pcall(task.cancel,self.BotRequestThread) self.BotRequestThread=nil end
    if self.BotLoop then pcall(task.cancel,self.BotLoop) self.BotLoop=nil end
    for _,c in ipairs(self.Connections) do c:Disconnect() end
    for _,record in pairs(self.TreeWatchers or {}) do
        for _,connection in ipairs(record.Connections) do connection:Disconnect() end
                for _,connection in pairs(record.Metadata) do connection:Disconnect() end
        for _,connections in pairs(record.Parts) do for _,connection in ipairs(connections) do connection:Disconnect() end end
    end
    self.TreeWatchers=nil self.StandingCache=nil
    if self.TreeIndex then table.clear(self.TreeIndex) end
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
local progress=home:ProgressBar({Title="Ready",Description="Selected trees - Modwood only",Default=0})
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
local results=home:Label({Title="Harvest results",Description="Waiting for the first discovery"})
H.UI={Results=results,Progress=progress,Stage=progress.Root:FindFirstChild("ProgressTitle"),
    Detail=progress.Root:FindFirstChild("Description"),Spooky=spooky,Neon=sinister,
    Activity=activity,Start=start.Root:FindFirstChild("Title")}
H:RefreshMetrics()
local controls={}
local function apply(key,newValue,control)
    if H.Busy and key~="AntiAfk" and key~="NoRender" then
        control:Set(H.Config[key],true)
        H:Log("Stop the hunt before editing settings","WARNING") return
    end
    local candidate=table.clone(H.Config) candidate[key]=newValue
    candidate=configFrom(candidate)
    if key=="BotURL" and candidate.BotURL~="" and not trackerURL(candidate.BotURL) then
        control:Set(H.Config[key],true) H:Log("Use your Discord worker https://name.account.workers.dev address","WARNING") return
    end
    if key=="BotKey" and candidate.BotKey~="" and not candidate.BotKey:match("^[a-f0-9]+$") then
        H:Log("Enter the client key issued by /hunter register","WARNING") return
    end
    if key=="BotKey" and candidate.BotKey~="" and #candidate.BotKey~=64 then
        H:Log("Client keys contain 64 hexadecimal characters","WARNING") return
    end
    if key=="TrackerURL" and candidate.TrackerURL~="" and not trackerURL(candidate.TrackerURL) then
        H:Log("Use your https://worker.account.workers.dev address without a path","WARNING") return
    end
    if key=="TrackerToken" and candidate.TrackerToken~="" and not trackerKey(candidate.TrackerToken) then
        H:Log("Tracker key must contain 32 to 128 letters, numbers, dashes or underscores","WARNING") return
    end
    if key=="NoRender" and not H:SetNoRender(candidate.NoRender) then
        control:Set(H.Config.NoRender,true)
        return
    end
    H.Config=candidate
    if key:sub(1,7)=="Tracker" or key=="VisitCooldownHours" or key=="HarvestCooldownHours"
        or key=="PrefetchServers" or key=="PerformanceMode" or key=="CandidateCacheSeconds" then
        H.ServerCandidateCache=nil H.ServerPrefetch=nil
    end
    if key=="BotKey" or key=="BotURL" then H.BotCommandVersion=0 H.BotWake=true end
    if key:sub(1,7)=="Tracker" then
        H.TrackerRetryAt=nil H.TrackerFallbackLogged=false H.TrackerFailures=0
        H.OldServerBatch=nil H.TrackerSuppressed=nil H.TrackerCursor=nil
        H.ServerSearchRevision=(H.ServerSearchRevision or 0)+1
    end
    if controls.ScanWait then controls.ScanWait:Set(tostring(candidate.ScanWait),true) end
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
local speciesLabel={Both="Both",Spooky="Spooky",SpookyNeon="Sinister"}
local speciesValue={Both="Both",Spooky="Spooky",Sinister="SpookyNeon"}
local targetDropdown
 targetDropdown=settings:Dropdown({Title="Target trees",Options={"Both","Spooky","Sinister"},Default=speciesLabel[H.Config.TargetSpecies],Callback=function(v)
    if H.Busy then targetDropdown:Set(speciesLabel[H.Config.TargetSpecies],true) H:Log("Stop the hunt before changing targets","WARNING") return end
    apply("TargetSpecies",speciesValue[v] or "Both",targetDropdown)
end})
local function textSetting(parent,title,key,numeric,secret,placeholder)
    local input
    input=parent:Textbox({Title=title,Default=secret and "" or tostring(H.Config[key]),
        Placeholder=secret and (H.Config[key]~="" and "Saved - enter a value to replace" or placeholder or "Enter your client key") or placeholder or "",
        MaxLength=secret and 400 or 1000,Callback=function(v)
            if secret and v=="" then return end
            local n=numeric and tonumber(v) or v
            if numeric and not finite(n) then input:Set(tostring(H.Config[key]),true) return end
            apply(key,n,input)
            input:Set(secret and "" or tostring(H.Config[key]),true)
        end})
    controls[key]=input
end
local botSection=settings:Section({Title="Discord bot",Collapsible=true,Collapsed=false})
textSetting(botSection,"Bot service URL","BotURL",false,false,"https://midnight-hunter-discord.account.workers.dev")
textSetting(botSection,"Client key","BotKey",false,true,"Key from /hunter register")
H.UI.BotConnection=botSection:Label({Title="Bot - Not connected",Description="Roblox account "..tostring(Player.UserId)})
local botToggle
botToggle=botSection:Toggle({Title="Connect to Discord",Default=H.Config.BotEnabled,
    Callback=function(v) apply("BotEnabled",v,botToggle) H.BotWake=true end})
botSection:Button({Title="Reconnect bot",Callback=function() H.BotWake=true H:StartBot() end})
for _,entry in ipairs({{"Full harvest","FullCycle"},{"Anti-AFK","AntiAfk"},{"No render","NoRender"},{"Fast harvest","FastHarvest"},{"Auto rejoin","AutoRejoin"},{"Modwood 3D markers","ModwoodHighlights"}}) do
    local title,key=entry[1],entry[2]
    local toggle
    toggle=settings:Toggle({Title=title,Default=H.Config[key],Callback=function(v) apply(key,v,toggle) end})
    controls[key]=toggle
end
local growthSettings=settings:Section({Title="Sinister growth",Collapsible=true,Collapsed=false})
local growthToggle
 growthToggle=growthSettings:Toggle({Title="Wait for Sinister growth",Description="Includes small trees - requires InverseAxe and a harvest axe",Default=H.Config.GrowSinister,
    Callback=function(v) apply("GrowSinister",v,growthToggle) end})
textSetting(growthSettings,"Unchanged volume (seconds)","GrowthStableSeconds",true)
textSetting(growthSettings,"Minimum observation (seconds)","GrowthMinWait",true)
textSetting(growthSettings,"Maximum wait (seconds)","GrowthMaxWait",true)
textSetting(growthSettings,"Discord updates (seconds)","GrowthNotifySeconds",true)
local finder=settings:Section({Title="Server finder",Collapsible=true,Collapsed=false})
local trackerToggle
trackerToggle=finder:Toggle({Title="Oldest observed servers",Default=H.Config.TrackerEnabled,
    Callback=function(v) apply("TrackerEnabled",v,trackerToggle) end})
local fallbackToggle
fallbackToggle=finder:Toggle({Title="Allow standard fallback",Default=H.Config.TrackerAllowFallback,
    Callback=function(v) apply("TrackerAllowFallback",v,fallbackToggle) end})
finder:Label({Title="Visit cycle - 6 hours",Description="Oldest first - history and next candidates survive teleports"})
textSetting(finder,"Worker URL","TrackerURL",false,false,"https://midnight-spooky-tracker.account.workers.dev")
textSetting(finder,"Tracker key","TrackerToken",false,true,"Paste your private API_TOKEN")
finder:Button({Title="Clear tracker key",Callback=function()
    if H.Busy then H:Log("Stop the hunt before editing settings","WARNING") return end
    H.Config.TrackerToken="" H.TrackerRetryAt=nil H.TrackerFallbackLogged=false
    local saved,err=H:Persist(false) if not saved then H:Log(err,"WARNING") end
end})
textSetting(finder,"Standard revisit delay (hours)","VisitCooldownHours",true)
textSetting(finder,"Standard harvest delay (hours)","HarvestCooldownHours",true)
local adaptiveToggle
adaptiveToggle=finder:Toggle({Title="Adaptive server timing",Default=H.Config.AdaptiveTiming,
    Callback=function(v) apply("AdaptiveTiming",v,adaptiveToggle) end})
local advanced=settings:Section({Title="Advanced",Collapsible=true,Collapsed=true})
local performance=settings:Section({Title="Performance",Collapsible=true,Collapsed=false})
for _,entry in ipairs({{"Performance mode","PerformanceMode"},{"Prepare next server","PrefetchServers"}}) do
    local title,key=entry[1],entry[2]
    local toggle
    toggle=performance:Toggle({Title=title,Default=H.Config[key],Callback=function(v) apply(key,v,toggle) end})
    controls[key]=toggle
end
textSetting(performance,"Server cache lifetime (seconds)","CandidateCacheSeconds",true)
textSetting(performance,"Search budget (seconds)","ServerSearchBudget",true)
textSetting(performance,"Maximum server pages","PublicPageLimit",true)
performance:Button({Title="Clear search cache",Callback=function()
    if H.Busy then H:Log("Stop the hunt before clearing search cache","WARNING") return end
    H.ServerCandidateCache=nil H.ServerPrefetch=nil
    H.OldServerBatch=nil H.TrackerSuppressed=nil H.TrackerCursor=nil H.TrackerRetryAt=nil
    H.ServerSearchRevision=(H.ServerSearchRevision or 0)+1
    H.PublicCursor=nil H.PublicCursorUntil=nil
    H:Persist(false)
    H:Log("Search cache cleared - server history retained")
end})
textSetting(advanced,"Script URL","ScriptURL",false)
for _,entry in ipairs({{"Hop delay (seconds)","HopDelay"},{"Rejoin retry delay (seconds)","RejoinDelay"},
    {"Tracker timeout (seconds)","TrackerTimeout"},{"Tracker retry (seconds)","TrackerBackoff"},
    {"Last seen limit (minutes)","TrackerFreshness"},{"Minimum observed age (minutes)","TrackerMinAge"},
    {"Scan interval (seconds)","ScanInterval"},{"Tree confirmation (seconds)","ScanSettle"},
    {"Empty scan confirmation (seconds)","EmptyScanDelay"},{"Game stabilization (seconds)","GameSettle"},
    {"Scan timeout (seconds)","ScanWait"},{"Server search timeout (seconds)","ServerSearchTimeout"},
    {"Server search retry (seconds)","ServerRetryDelay"},{"Game loading timeout (seconds)","LoadTimeout"},
    {"Wood data timeout (seconds)","MetadataTimeout"},{"Chop timeout (seconds)","ChopTimeout"},
    {"Burn timeout (seconds)","BurnTimeout"},{"Sawmill timeout (seconds)","MillTimeout"}}) do
    textSetting(advanced,entry[1],entry[2],true)
end
settings:Button({Title="Reset window position",Callback=function() Window:SetPosition({X=0.5,Y=0.5}) end})
H:Connect(Player.OnTeleport,function(state,placeId)
    if placeId~=game.PlaceId then return end
    if state==Enum.TeleportState.Failed then
        if H.TeleportArm then H.TeleportArm.BackupQueued=false end
        local attempt=H.HopAttempt or H.RejoinAttempt
        if attempt then attempt.Error=attempt.Error or "Teleport failed - selecting another candidate" end
        return
    end
    if state~=Enum.TeleportState.Started and state~=Enum.TeleportState.WaitingForServer
        and state~=Enum.TeleportState.InProgress then return end
    if not H.Running or H.BotDesired=="paused" then return end
    local arm=H.TeleportArm
    if not arm or arm.Target~=H.PendingTeleportTarget or arm.BackupQueued then return end
    -- Queue again once during the actual teleport transition. The arrival
    -- bootstrap has a shared lock, so two queued callbacks cannot start two hunts.
    if not H:QueueContinuation(arm,true) then
        H:Log("Teleport backup could not be queued - initial continuation remains armed","WARNING")
    end
end)
H:Connect(S.TeleportService.TeleportInitFailed,function(player,result,message,placeId,options)
    if player~=Player or placeId~=game.PlaceId then return end
    if H.RejoinAttempt then H.RejoinAttempt.Error="Rejoin failed - "..tostring(message):sub(1,160) return end
    if not H.HopAttempt then return end
    local id=options and options.ServerInstanceId
    if id and id~="" and id~=H.HopAttempt.Id then return end
    H.HopAttempt.FailureKind=result and result.Name or "Unknown"
    H.HopAttempt.Error="Teleport failed - "..tostring(message):sub(1,160)
end)
local rejoinHookOK=pcall(function()
    H:Connect(S.GuiService.ErrorMessageChanged,function() H:ScheduleRejoinCheck() end)
end)
if not rejoinHookOK then H:Log("Disconnect detection is unavailable in this executor","WARNING") end
if H.ConfigWarning then H:Log(H.ConfigWarning,"WARNING") end
H:Log("Ready")
H:DetectCapabilities()
H:SetAntiAfk(H.Config.AntiAfk)
if H.Config.NoRender and not H:SetNoRender(true) then
    H.Config.NoRender=false
    if controls.NoRender then controls.NoRender:Set(false,true) end
end
H:StartBot()
if H.RecoveredSession then H:Log("Resuming unfinished wood") end
local resume=Env.MidnightSpookyResume==true and restored and restored.Resume==true
    and (restored.Target==game.JobId or (restored.Target=="*" and restored.Recovery==true and restored.PlaceId==game.PlaceId))
    and finite(restored.TicketTime) and os.time()-restored.TicketTime>=-60
    and os.time()-restored.TicketTime<CONTINUATION_TTL
Env.MidnightSpookyResume=nil
Env.MidnightSpookyResumeTicket=nil
H.BootReady=true
if (resume or (H.RecoveredSession and wasRunning)) and H.BotDesired~="paused" then H:Start() end
return H
