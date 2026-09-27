--[[
    Midnight UI Library
    Version: 2.0.0
    Credits: Original implementation by OpenAI for this project.
    Date: 2026-09-27
    License: MIT

    Client-side Roblox Luau module with optional host capabilities.
    Studio: put this file in a ModuleScript and require it from a LocalScript.
    External hosts: this file returns the library for a loadstring loader.
    No external assets or runtime dependencies are required.
]]

-- 1. Services and utilities ----------------------------------------------------

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Midnight = {
    Version = "2.0.0",
    Flags = {},
    Windows = {},
    Visible = true,
    ReducedMotion = false,
}

local WindowMethods = {}
local ContainerMethods = {}
local ControlMethods = {}
local FlagOwners = {}
local MemoryConfigs = {}
local ThemeScopes = {}
local Runtime = nil
local NotificationId = 0
local ClipboardMemory = ""
local ScrollLocks = {}
local animate
local cancelCapture
local focusStyle

local function report(context, message)
    warn("[Midnight UI] " .. context .. ": " .. tostring(message))
end

local function safe(callback, ...)
    if type(callback) ~= "function" then
        return
    end
    local results = table.pack(pcall(callback, ...))
    if not results[1] then
        report("Callback failed", results[2])
        return
    end
    return table.unpack(results, 2, results.n)
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

local function finite(value, fallback)
    local number = tonumber(value)
    if not number or number ~= number or math.abs(number) == math.huge then
        return fallback
    end
    return number
end

local function option(value)
    if type(value) == "string" then
        return { Title = value }
    end
    return value or {}
end

local function capability(name)
    local environment = getfenv(0)
    local value = environment[name]
    if type(value) == "function" then
        return value
    end
    return nil
end

local function new(className, properties, parent)
    local object = Instance.new(className)
    for key, value in pairs(properties or {}) do
        object[key] = value
    end
    object.Parent = parent
    return object
end

local function corner(object, radius)
    return new("UICorner", {
        CornerRadius = UDim.new(0, radius or 8),
    }, object)
end

local function padding(object, amount)
    return new("UIPadding", {
        PaddingTop = UDim.new(0, amount),
        PaddingBottom = UDim.new(0, amount),
        PaddingLeft = UDim.new(0, amount),
        PaddingRight = UDim.new(0, amount),
    }, object)
end

local function layout(object, gap, direction)
    return new("UIListLayout", {
        Padding = UDim.new(0, gap or 8),
        FillDirection = direction or Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, object)
end

local function point(input)
    return Vector2.new(input.Position.X, input.Position.Y)
end

local function pointer(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

local function keyCode(value, fallback)
    if typeof(value) == "EnumItem" and value.EnumType == Enum.KeyCode then
        return value
    end
    if type(value) == "string" then
        local result
        pcall(function()
            result = Enum.KeyCode[value]
        end)
        if result then
            return result
        end
    end
    return fallback or Enum.KeyCode.Unknown
end

-- Every connection, delayed job, tween and child scope has a single owner.
local Scope = {}
Scope.__index = Scope

function Scope.new(parent)
    local self = setmetatable({
        Alive = true,
        Connections = {},
        Jobs = {},
        Tweens = {},
        Children = {},
        Theme = {},
        Cleanups = {},
        Parent = parent,
    }, Scope)
    ThemeScopes[self] = true
    if parent then
        parent.Children[self] = true
    end
    return self
end

function Scope:Connect(signal, callback)
    local connection = signal:Connect(function(...)
        if self.Alive then
            safe(callback, ...)
        end
    end)
    self.Connections[connection] = true
    return connection
end

function Scope:Delay(seconds, callback)
    local thread
    thread = task.delay(seconds, function()
        self.Jobs[thread] = nil
        if self.Alive then
            safe(callback)
        end
    end)
    self.Jobs[thread] = true
    return thread
end

function Scope:Cancel(thread)
    if thread and self.Jobs[thread] then
        self.Jobs[thread] = nil
        pcall(task.cancel, thread)
    end
end

function Scope:Destroy()
    if not self.Alive then
        return
    end
    self.Alive = false
    ThemeScopes[self] = nil
    if self.Parent then
        self.Parent.Children[self] = nil
    end
    for child in pairs(self.Children) do
        child:Destroy()
    end
    for connection in pairs(self.Connections) do
        connection:Disconnect()
    end
    for _, cleanup in ipairs(self.Cleanups) do
        safe(cleanup)
    end
    for thread in pairs(self.Jobs) do
        pcall(task.cancel, thread)
    end
    for object, channels in pairs(self.Tweens) do
        for _, tween in pairs(channels) do
            tween:Cancel()
        end
        self.Tweens[object] = nil
    end
    table.clear(self.Connections)
    table.clear(self.Jobs)
    table.clear(self.Children)
    table.clear(self.Theme)
    table.clear(self.Cleanups)
end

-- 2. Theme and colors ---------------------------------------------------------

local DefaultTheme = {
    Background = Color3.fromRGB(10, 14, 26),
    Panel = Color3.fromRGB(16, 22, 36),
    Raised = Color3.fromRGB(23, 31, 49),
    Border = Color3.fromRGB(30, 42, 69),
    Accent = Color3.fromRGB(74, 124, 255),
    Secondary = Color3.fromRGB(139, 92, 246),
    Text = Color3.fromRGB(229, 233, 240),
    Muted = Color3.fromRGB(138, 147, 166),
    Error = Color3.fromRGB(248, 93, 117),
    Warning = Color3.fromRGB(255, 170, 75),
    Shadow = Color3.fromRGB(0, 0, 0),
}

Midnight.Theme = copy(DefaultTheme)

local function themed(scope, callback)
    table.insert(scope.Theme, callback)
    callback(Midnight.Theme)
end

local function color(scope, object, property, token)
    themed(scope, function(theme)
        object[property] = theme[token]
    end)
end

local function stroke(scope, object, token, transparency, thickness)
    local result = new("UIStroke", {
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Thickness = thickness or 1,
        Transparency = transparency or 0.7,
    }, object)
    color(scope, result, "Color", token or "Border")
    return result
end

local function frame(scope, parent, properties, token)
    local result = new("Frame", properties or {}, parent)
    result.BorderSizePixel = 0
    if token then
        color(scope, result, "BackgroundColor3", token)
    end
    return result
end

local function label(scope, parent, text, properties, token)
    local result = new("TextLabel", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        Text = tostring(text or ""),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, parent)
    for key, value in pairs(properties or {}) do
        result[key] = value
    end
    color(scope, result, "TextColor3", token or "Text")
    return result
end

local function button(scope, parent, text, properties)
    local result = new("TextButton", {
        AutoButtonColor = false,
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        Text = tostring(text or ""),
        TextSize = 13,
        Font = Enum.Font.GothamMedium,
    }, parent)
    for key, value in pairs(properties or {}) do
        result[key] = value
    end
    color(scope, result, "TextColor3", "Text")
    return result
end

local function textBox(scope, parent, placeholder, properties)
    local result = new("TextBox", {
        Text = "",
        PlaceholderText = placeholder or "Enter text",
        ClearTextOnFocus = false,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        BorderSizePixel = 0,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, parent)
    for key, value in pairs(properties or {}) do
        result[key] = value
    end
    corner(result, 6)
    padding(result, 8)
    color(scope, result, "BackgroundColor3", "Background")
    color(scope, result, "TextColor3", "Text")
    color(scope, result, "PlaceholderColor3", "Muted")
    local outline = stroke(scope, result, "Border", 0.68)
    focusStyle(scope, result, outline)
    return result
end

local function gradient(scope, object)
    local result = new("UIGradient", {}, object)
    themed(scope, function(theme)
        object.BackgroundColor3 = Color3.new(1, 1, 1)
        result.Color = ColorSequence.new(theme.Accent, theme.Secondary)
    end)
    return result
end

function Midnight:SetTheme(values)
    if values == "Midnight" then
        values = DefaultTheme
    end
    if type(values) ~= "table" then
        return false
    end
    for key, value in pairs(values) do
        if DefaultTheme[key] and typeof(value) == "Color3" then
            self.Theme[key] = value
        end
    end
    for scope in pairs(ThemeScopes) do
        if scope.Alive then
            -- Cancel color interpolation before assigning the new palette.
            for _, channels in pairs(scope.Tweens) do
                for property, tween in pairs(channels) do
                    if string.find(property, "Color") then
                        tween:Cancel()
                        channels[property] = nil
                    end
                end
            end
            for _, callback in ipairs(scope.Theme) do
                safe(callback, self.Theme)
            end
        end
    end
    return true
end

-- 3. Centralized animation ----------------------------------------------------

animate = function(scope, object, goals, duration)
    if not scope.Alive then
        return
    end
    local channels = scope.Tweens[object]
    if not channels then
        channels = {}
        scope.Tweens[object] = channels
    end
    for property, value in pairs(goals) do
        if channels[property] then
            channels[property]:Cancel()
        end
        if Midnight.ReducedMotion then
            object[property] = value
            channels[property] = nil
        else
            local tween = TweenService:Create(object, TweenInfo.new(
                math.clamp(duration or 0.2, 0.15, 0.35),
                Enum.EasingStyle.Quint,
                Enum.EasingDirection.Out
            ), { [property] = value })
            channels[property] = tween
            tween:Play()
        end
    end
end

-- Hover, press and focus states share the same animation owner.
local function hover(scope, object, outline, settings)
    settings = settings or {}
    local over = false
    local pressed = false
    local function render(immediate)
        local theme = Midnight.Theme
        local enabled = not settings.Enabled or settings.Enabled()
        local active = enabled and (over or pressed)
        local goals = {
            BackgroundColor3 = active and theme.Raised or theme.Panel,
        }
        local edge = {
            Color = active and theme[settings.Accent or "Accent"] or theme.Border,
            Transparency = active and (pressed and 0.2 or 0.5) or 0.78,
        }
        if immediate then
            object.BackgroundColor3 = goals.BackgroundColor3
            if outline then
                outline.Color = edge.Color
                outline.Transparency = edge.Transparency
            end
        else
            animate(scope, object, goals, 0.18)
            if outline then
                animate(scope, outline, edge, 0.18)
            end
        end
    end
    scope:Connect(object.MouseEnter, function()
        over = true
        render()
    end)
    scope:Connect(object.MouseLeave, function()
        over = false
        pressed = false
        render()
    end)
    scope:Connect(object.InputBegan, function(input)
        if pointer(input) then
            pressed = true
            render()
        end
    end)
    scope:Connect(object.InputEnded, function(input)
        if pointer(input) then
            pressed = false
            render()
        end
    end)
    themed(scope, function()
        render(true)
    end)
    return render
end

-- Native vector icons avoid missing Unicode glyphs and external assets.
local IconPaths = {
    Home = { {2, 9, 10, 2, 18, 9}, {5, 8, 5, 18, 15, 18, 15, 8}, {8, 18, 8, 12, 12, 12, 12, 18} },
    Moon = { {12, 2, 7, 3, 3, 7, 3, 12, 6, 16, 11, 18, 16, 16, 18, 12, 13, 13, 9, 10, 8, 6, 12, 2} },
    Settings = { {3, 5, 17, 5}, {3, 10, 17, 10}, {3, 15, 17, 15}, {7, 3, 7, 7}, {13, 8, 13, 12}, {8, 13, 8, 17} },
    Sliders = { {3, 5, 17, 5}, {3, 10, 17, 10}, {3, 15, 17, 15}, {7, 3, 7, 7}, {13, 8, 13, 12}, {8, 13, 8, 17} },
    Grid = { {3, 3, 8, 3, 8, 8, 3, 8, 3, 3}, {12, 3, 17, 3, 17, 8, 12, 8, 12, 3}, {3, 12, 8, 12, 8, 17, 3, 17, 3, 12}, {12, 12, 17, 12, 17, 17, 12, 17, 12, 12} },
    Palette = { {10, 2, 5, 3, 2, 8, 3, 14, 7, 18, 12, 18, 12, 14, 17, 13, 18, 8, 15, 3, 10, 2}, {6, 7, 6.2, 7}, {10, 5, 10.2, 5}, {14, 8, 14.2, 8} },
    Bell = { {4, 14, 6, 12, 6, 7, 8, 4, 12, 4, 14, 7, 14, 12, 16, 14, 4, 14}, {8, 17, 12, 17} },
    Keyboard = { {2, 5, 18, 5, 18, 15, 2, 15, 2, 5}, {5, 8, 6, 8}, {9, 8, 10, 8}, {13, 8, 14, 8}, {6, 12, 14, 12} },
    Chevron = { {6, 8, 10, 12, 14, 8} },
    Arrow = { {4, 10, 16, 10}, {11, 5, 16, 10, 11, 15} },
    Close = { {5, 5, 15, 15}, {15, 5, 5, 15} },
    Minimize = { {5, 10, 15, 10} },
    Resize = { {5, 16, 16, 5}, {10, 16, 16, 10} },
    Check = { {4, 10, 8, 14, 16, 6} },
    Search = { {8, 3, 4, 5, 3, 9, 5, 12, 9, 13, 12, 11, 13, 7, 11, 4, 8, 3}, {12, 12, 17, 17} },
    Save = { {3, 3, 15, 3, 17, 5, 17, 17, 3, 17, 3, 3}, {6, 3, 6, 8, 13, 8, 13, 3}, {6, 17, 6, 12, 14, 12, 14, 17} },
}

local function icon(scope, parent, name, position, size, token)
    local aliases = { ["☾"] = "Moon", ["⚙"] = "Settings" }
    name = aliases[name] or name or "Grid"
    local root = frame(scope, parent, {
        Name = "Icon",
        BackgroundTransparency = 1,
        Position = position or UDim2.new(),
        Size = UDim2.fromOffset(size or 18, size or 18),
    })
    local segments = {}
    local scale = (size or 18) / 20
    for _, path in ipairs(IconPaths[name] or IconPaths.Grid) do
        for index = 1, #path - 2, 2 do
            local x1, y1 = path[index], path[index + 1]
            local x2, y2 = path[index + 2], path[index + 3]
            local dx, dy = x2 - x1, y2 - y1
            local line = frame(scope, root, {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromOffset((x1 + x2) * scale / 2, (y1 + y2) * scale / 2),
                Size = UDim2.fromOffset(math.max(1.6, math.sqrt(dx * dx + dy * dy) * scale), 1.6),
                Rotation = math.deg(math.atan2(dy, dx)),
            })
            corner(line, 1)
            table.insert(segments, line)
        end
    end
    local result = { Root = root, Token = token or "Muted" }
    function result:SetToken(nextToken, immediate)
        self.Token = nextToken
        for _, line in ipairs(segments) do
            if immediate then
                line.BackgroundColor3 = Midnight.Theme[self.Token]
            else
                animate(scope, line, { BackgroundColor3 = Midnight.Theme[self.Token] })
            end
        end
    end
    themed(scope, function()
        result:SetToken(result.Token, true)
    end)
    return result
end

-- Broad strokes share one contour: no concentric hard-edged rings.
local function glow(scope, object)
    local lines = {}
    for index, width in ipairs({ 16, 11, 7, 4 }) do
        local halo = frame(scope, object, {
            Name = "SoftGlow",
            Position = UDim2.fromOffset(0, 0),
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            ZIndex = 1,
        })
        corner(halo, 10)
        local base = ({ 0.985, 0.978, 0.965, 0.94 })[index]
        lines[index] = { Stroke = stroke(scope, halo, "Accent", base, width), Base = base }
    end
    return lines
end

focusStyle = function(scope, input, outline)
    local focused = false
    local function render(immediate)
        local goals = {
            Color = focused and Midnight.Theme.Accent or Midnight.Theme.Border,
            Transparency = focused and 0.18 or 0.68,
        }
        if immediate then
            outline.Color = goals.Color
            outline.Transparency = goals.Transparency
        else
            animate(scope, outline, goals, 0.2)
        end
    end
    scope:Connect(input.Focused, function()
        focused = true
        render()
    end)
    scope:Connect(input.FocusLost, function()
        focused = false
        render()
    end)
    themed(scope, function()
        render(true)
    end)
end

function Midnight:SetReducedMotion(enabled)
    self.ReducedMotion = enabled == true
end

-- 4. Pointer dragging: mouse and touch ---------------------------------------

local function isVisible(object)
    local current = object
    while current do
        if current:IsA("GuiObject") and not current.Visible then
            return false
        end
        if current:IsA("ScreenGui") and not current.Enabled then
            return false
        end
        current = current.Parent
    end
    return true
end

local function drag(scope, target, begin, update, finish)
    local active = nil
    local origin = nil
    local payload = nil
    local scrollStates = {}
    local function unlock()
        for scroller in pairs(scrollStates) do
            local lock = ScrollLocks[scroller]
            if lock then
                lock.Count = lock.Count - 1
                if lock.Count == 0 then
                    if scroller.Parent then
                        scroller.ScrollingEnabled = lock.Enabled
                    end
                    ScrollLocks[scroller] = nil
                end
            end
        end
        table.clear(scrollStates)
        active = nil
    end
    table.insert(scope.Cleanups, unlock)
    target.Active = true
    scope:Connect(target.InputBegan, function(input)
        if not pointer(input) or active or not isVisible(target) then
            return
        end
        origin = point(input)
        payload = begin and begin(origin, input)
        if payload == false then
            return
        end
        active = input
        local ancestor = target.Parent
        while ancestor do
            if ancestor:IsA("ScrollingFrame") then
                local lock = ScrollLocks[ancestor]
                if not lock then
                    lock = { Count = 0, Enabled = ancestor.ScrollingEnabled }
                    ScrollLocks[ancestor] = lock
                end
                lock.Count = lock.Count + 1
                scrollStates[ancestor] = true
                ancestor.ScrollingEnabled = false
            end
            ancestor = ancestor.Parent
        end
        update(origin, Vector2.zero, payload)
    end)
    scope:Connect(UserInputService.InputChanged, function(input)
        if not active then
            return
        end
        if not isVisible(target) then
            unlock()
            return
        end
        local touch = active.UserInputType == Enum.UserInputType.Touch
        if (touch and input == active)
            or (not touch and input.UserInputType == Enum.UserInputType.MouseMovement) then
            local position = point(input)
            update(position, position - origin, payload)
        end
    end)
    scope:Connect(UserInputService.InputEnded, function(input)
        if active and (input == active or (
            active.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseButton1
        )) then
            unlock()
            if finish then
                finish(payload)
            end
        end
    end)
    scope:Connect(UserInputService.WindowFocusReleased, function()
        if active then
            unlock()
            if finish then
                finish(payload)
            end
        end
    end)
end

local function fraction(position, object)
    local size = object.AbsoluteSize
    local start = object.AbsolutePosition
    return math.clamp((position.X - start.X) / math.max(size.X, 1), 0, 1),
        math.clamp((position.Y - start.Y) / math.max(size.Y, 1), 0, 1)
end

-- 5. Configuration: optional files, always-available memory --------------------

local function encode(value)
    if typeof(value) == "Color3" then
        return { Kind = "Color3", R = value.R, G = value.G, B = value.B }
    end
    if typeof(value) == "EnumItem" then
        return { Kind = "KeyCode", Name = value.Name }
    end
    if type(value) == "table" then
        local result = {}
        for key, item in pairs(value) do
            result[key] = encode(item)
        end
        return result
    end
    return value
end

local function decode(value)
    if type(value) ~= "table" then
        return value
    end
    if value.Kind == "Color3" then
        return Color3.new(
            math.clamp(finite(value.R, 0), 0, 1),
            math.clamp(finite(value.G, 0), 0, 1),
            math.clamp(finite(value.B, 0), 0, 1)
        )
    end
    if value.Kind == "KeyCode" then
        return keyCode(value.Name)
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = decode(item)
    end
    return result
end

local function configName(value)
    local cleaned = tostring(value):gsub("[^%w_%-]", "_")
    return cleaned ~= "" and cleaned or "default"
end

local function configure(window, options)
    window.SaveEnabled = options.SaveConfig == true
    window.ConfigPath = configName(options.ConfigFolder or "MidnightConfigs")
        .. "/" .. configName(options.ConfigName or tostring(game.PlaceId)) .. ".json"
    window.ConfigData = {}
    window.FileRead = capability("readfile")
    window.FileWrite = capability("writefile")
    window.FileExists = capability("isfile")
    window.FileMode = window.FileRead ~= nil
        and window.FileWrite ~= nil
        and window.FileExists ~= nil
    if not window.SaveEnabled then
        return
    end
    if window.FileMode then
        local makeFolder = capability("makefolder")
        local isFolder = capability("isfolder")
        local folder = configName(options.ConfigFolder or "MidnightConfigs")
        local ok, err = pcall(function()
            if makeFolder and (not isFolder or not isFolder(folder)) then
                makeFolder(folder)
            end
        end)
        if not ok then
            report("Folder creation failed; using memory", err)
            window.FileMode = false
        end
    end
    if not window.FileMode then
        report("Configuration", "File access is unavailable; using session memory")
    end
    window:LoadConfig(false)
end

function WindowMethods:SaveConfig()
    if not self.SaveEnabled then
        return false
    end
    local values = copy(self.ConfigData)
    for flag, control in pairs(self.Controls) do
        values[flag] = control:Get()
    end
    self.ConfigData = values
    MemoryConfigs[self.ConfigPath] = copy(values)
    if not self.FileMode then
        return true
    end
    local ok, err = pcall(function()
        self.FileWrite(self.ConfigPath, HttpService:JSONEncode({
            Version = 1,
            Values = encode(values),
        }))
    end)
    if not ok then
        self.FileMode = false
        report("Save failed; using memory", err)
    end
    return true
end

function WindowMethods:LoadConfig(fireCallbacks)
    local values = copy(MemoryConfigs[self.ConfigPath] or {})
    if self.FileMode then
        local ok, result = pcall(function()
            if not self.FileExists(self.ConfigPath) then
                return nil
            end
            local document = HttpService:JSONDecode(self.FileRead(self.ConfigPath))
            assert(type(document) == "table" and document.Version == 1, "Invalid config version")
            assert(type(document.Values) == "table", "Invalid config values")
            return decode(document.Values)
        end)
        if ok and result then
            values = result
        elseif not ok then
            report("Load failed; using memory", result)
        end
    end
    self.ConfigData = copy(values)
    self.Loading = true
    local restored = {}
    for flag, control in pairs(self.Controls) do
        if values[flag] ~= nil then
            control:Set(copy(values[flag]), true)
            table.insert(restored, control)
        end
    end
    -- Callbacks observe the complete restored snapshot, never half-loaded flags.
    if fireCallbacks == true then
        for _, control in ipairs(restored) do
            if control.Scope.Alive then
                safe(control.Callback, control:Get())
            end
        end
    end
    self.Loading = false
    return true
end

function WindowMethods:_ScheduleSave()
    if not self.SaveEnabled or self.Loading or self.Destroyed then
        return
    end
    self.Scope:Cancel(self.SaveJob)
    self.SaveJob = self.Scope:Delay(0.3, function()
        self.SaveJob = nil
        self:SaveConfig()
    end)
end

-- 6. Window creation ----------------------------------------------------------

local function screen(name, order)
    assert(RunService:IsClient(), "Midnight UI must run on the client")
    local gui = new("ScreenGui", {
        Name = name,
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = order or 100,
    })
    local getHidden = capability("gethui")
    local candidates = {}
    if getHidden then
        local ok, parent = pcall(getHidden)
        if ok and typeof(parent) == "Instance" then
            table.insert(candidates, parent)
        end
    end
    pcall(function()
        table.insert(candidates, game:GetService("CoreGui"))
    end)
    local player = Players.LocalPlayer
    if player then
        table.insert(candidates, player:WaitForChild("PlayerGui"))
    end
    for _, parent in ipairs(candidates) do
        local ok = pcall(function()
            gui.Parent = parent
        end)
        if ok and gui.Parent == parent then
            return gui
        end
    end
    gui:Destroy()
    error("Midnight UI could not access a GUI parent")
end

local function releaseBindings(window)
    for binding in pairs(window.Bindings) do
        if binding.Active and binding.Mode == "Hold" then
            binding.Active = false
            safe(binding.Callback, false, binding.Key)
        end
    end
end

cancelCapture = function(window)
    if window.Capture then
        local capture = window.Capture
        window.Capture = nil
        capture.Scope:Cancel(capture.CaptureJob)
        capture:Refresh()
    end
end

local function installKeyboard(window)
    local scope = window.Scope
    scope:Connect(UserInputService.InputBegan, function(input, processed)
        local key = input.KeyCode
        if pointer(input) and window.OpenPopover then
            local root = window.OpenPopover.Root
            local p = point(input)
            local start, size = root.AbsolutePosition, root.AbsoluteSize
            if p.X < start.X or p.Y < start.Y or p.X > start.X + size.X or p.Y > start.Y + size.Y then
                window.OpenPopover:SetOpen(false)
            end
        end
        if window.Capture then
            if key == Enum.KeyCode.Unknown then
                return
            end
            local control = window.Capture
            window.Capture = nil
            control.Scope:Cancel(control.CaptureJob)
            if key == Enum.KeyCode.Escape then
                control:Refresh()
            else
                control:Set(key == Enum.KeyCode.Backspace and Enum.KeyCode.Unknown or key)
            end
            return
        end
        if window.Modal then
            if key == Enum.KeyCode.Escape then
                window.Modal:Close(false)
            end
            return
        end
        if key == Enum.KeyCode.Escape and window.OpenPopover then
            window.OpenPopover:SetOpen(false)
            return
        end
        if processed or UserInputService:GetFocusedTextBox() then
            return
        end
        if key == window.Keybind then
            window:SetVisible(not window.Visible)
            return
        end
        for binding in pairs(window.Bindings) do
            if binding.Key == key and key ~= Enum.KeyCode.Unknown and binding.Enabled then
                if binding.Mode == "Hold" then
                    if not binding.Active then
                        binding.Active = true
                        safe(binding.Callback, true, key)
                    end
                else
                    binding.Active = not binding.Active
                    safe(binding.Callback, binding.Active, key)
                end
            end
        end
    end)
    scope:Connect(UserInputService.InputEnded, function(input)
        for binding in pairs(window.Bindings) do
            if binding.Mode == "Hold" and binding.Active and binding.Key == input.KeyCode then
                binding.Active = false
                safe(binding.Callback, false, binding.Key)
            end
        end
    end)
    scope:Connect(UserInputService.WindowFocusReleased, function()
        releaseBindings(window)
        cancelCapture(window)
    end)
    scope:Connect(UserInputService.TextBoxFocused, function()
        releaseBindings(window)
    end)
end

function Midnight:CreateWindow(options)
    options = option(options)
    if options.Theme == "Midnight" then
        self:SetTheme("Midnight")
    elseif options.Theme == "Custom" then
        self:SetTheme(options.CustomTheme or {})
    end
    local window = setmetatable({
        Scope = Scope.new(),
        Controls = {},
        Bindings = {},
        Tabs = {},
        Visible = true,
        Minimized = false,
        Destroyed = false,
        Keybind = keyCode(options.Keybind, Enum.KeyCode.RightShift),
        TabPosition = options.TabPosition == "Top" and "Top" or "Left",
    }, { __index = WindowMethods })
    local scope = window.Scope
    window.Gui = screen("MidnightUI", 100 + #self.Windows)
    window.Gui.Enabled = true
    table.insert(self.Windows, window)
    configure(window, options)

    window.Root = new("CanvasGroup", {
        Name = "Window",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(582, 432),
        GroupTransparency = 1,
    }, window.Gui)
    window.Scale = new("UIScale", { Scale = 0.985 }, window.Root)
    for index = 6, 1, -1 do
        local spread = index * 2
        local shadow = frame(scope, window.Root, {
            Name = "SoftShadow",
            Position = UDim2.fromOffset(16 - spread, 19 - spread),
            Size = UDim2.new(1, -32 + spread * 2, 1, -32 + spread * 2),
            BackgroundTransparency = 0.965,
        }, "Shadow")
        corner(shadow, 10 + spread)
    end
    window.Shell = frame(scope, window.Root, {
        Position = UDim2.fromOffset(16, 16),
        Size = UDim2.new(1, -32, 1, -32),
        ZIndex = 2,
        ClipsDescendants = false,
    }, "Background")
    corner(window.Shell, 10)
    stroke(scope, window.Shell, "Border", 0.42)
    window.Glow = glow(scope, window.Shell)

    local title = frame(scope, window.Shell, {
        Size = UDim2.new(1, 0, 0, 68),
        BackgroundTransparency = 0.96,
        ZIndex = 3,
    }, "Text")
    corner(title, 10)
    gradient(scope, title)
    local titleHit = button(scope, title, "", {
        Size = UDim2.new(1, -92, 1, 0),
    })
    local mark = frame(scope, titleHit, {
        Position = UDim2.fromOffset(16, 17),
        Size = UDim2.fromOffset(34, 34),
        BackgroundTransparency = 0.9,
    }, "Accent")
    corner(mark, 10)
    icon(scope, mark, "Moon", UDim2.fromOffset(7, 7), 20, "Accent")
    window.TitleLabel = label(scope, titleHit, options.Title or "Midnight UI", {
        Position = UDim2.fromOffset(62, 13),
        Size = UDim2.new(1, -70, 0, 23),
        Font = Enum.Font.GothamBold,
        TextSize = 16,
    })
    window.SubTitleLabel = label(scope, titleHit, options.SubTitle or "Your space after dark", {
        Position = UDim2.fromOffset(62, 36),
        Size = UDim2.new(1, -70, 0, 18),
        TextSize = 11,
    }, "Muted")
    local headerRule = frame(scope, title, {
        Position = UDim2.new(0, 16, 1, -1),
        Size = UDim2.new(1, -32, 0, 1),
        BackgroundTransparency = 0.85,
    }, "Text")
    gradient(scope, headerRule)
    local minimize = button(scope, title, "", {
        Position = UDim2.new(1, -86, 0, 17),
        Size = UDim2.fromOffset(32, 32),
        BackgroundTransparency = 0.5,
    })
    local close = button(scope, title, "", {
        Position = UDim2.new(1, -46, 0, 17),
        Size = UDim2.fromOffset(32, 32),
        BackgroundTransparency = 0.5,
    })
    icon(scope, minimize, "Minimize", UDim2.fromOffset(7, 7), 18, "Muted")
    icon(scope, close, "Close", UDim2.fromOffset(7, 7), 18, "Muted")
    for _, item in ipairs({ minimize, close }) do
        corner(item, 8)
        hover(scope, item, stroke(scope, item, "Border", 0.85), {
            Accent = item == close and "Error" or "Accent",
        })
    end
    scope:Connect(minimize.Activated, function()
        window:SetMinimized(not window.Minimized)
    end)
    scope:Connect(close.Activated, function()
        window:SetVisible(false)
    end)

    window.Body = frame(scope, window.Shell, {
        Position = UDim2.fromOffset(14, 80),
        Size = UDim2.new(1, -28, 1, -112),
        BackgroundTransparency = 1,
        ZIndex = 3,
    })
    window.NavLabel = label(scope, window.Body, "WORKSPACE", {
        Size = UDim2.fromOffset(128, 16),
        Position = UDim2.fromOffset(10, 0),
        TextSize = 9,
        Font = Enum.Font.GothamBold,
        TextTransparency = 0.25,
    }, "Muted")
    window.TabBar = new("ScrollingFrame", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        ScrollBarThickness = 2,
    }, window.Body)
    color(scope, window.TabBar, "ScrollBarImageColor3", "Accent")
    window.TabLayout = layout(window.TabBar, 5)
    window.NavDivider = frame(scope, window.Body, {
        Size = UDim2.new(0, 1, 1, -4),
        BackgroundTransparency = 0.55,
    }, "Border")
    window.Pages = frame(scope, window.Body, {
        BackgroundTransparency = 1,
        ClipsDescendants = true,
    })
    window.StatusLabel = label(scope, window.Shell, options.Status or "READY", {
        Position = UDim2.new(0, 24, 1, -24),
        Size = UDim2.new(0.5, -24, 0, 16),
        TextSize = 9,
        ZIndex = 3,
    }, "Muted")
    window.Watermark = label(scope, window.Shell, "Midnight UI  /  2.0", {
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -30, 1, -8),
        Size = UDim2.fromOffset(126, 16),
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex = 3,
    }, "Muted")
    window.ResizeHandle = button(scope, window.Shell, "", {
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.fromScale(1, 1),
        Size = UDim2.fromOffset(30, 30),
        ZIndex = 5,
    })
    icon(scope, window.ResizeHandle, "Resize", UDim2.fromOffset(9, 9), 13, "Muted")
    window.Responsive = options.Responsive ~= false
    window.MobileReopen = button(scope, window.Gui, "", {
        Position = UDim2.new(0, 16, 0.5, -22),
        Size = UDim2.fromOffset(44, 44),
        BackgroundTransparency = 0,
        Visible = false,
        ZIndex = 100,
    })
    corner(window.MobileReopen, 12)
    color(scope, window.MobileReopen, "BackgroundColor3", "Panel")
    stroke(scope, window.MobileReopen, "Accent", 0.4)
    icon(scope, window.MobileReopen, "Moon", UDim2.fromOffset(11, 11), 22, "Accent")
    scope:Connect(window.MobileReopen.Activated, function()
        Midnight:ToggleUI(true)
        window:SetVisible(true)
    end)
    drag(scope, titleHit, function()
        return window.Root.Position
    end, function(_, delta, start)
        local area = window.Gui.AbsoluteSize
        local half = window.Root.AbsoluteSize / 2
        local x = start.X.Scale * area.X + start.X.Offset + delta.X
        local y = start.Y.Scale * area.Y + start.Y.Offset + delta.Y
        x = math.clamp(x, half.X - 16, math.max(half.X - 16, area.X - half.X + 16))
        y = math.clamp(y, half.Y - 16, math.max(half.Y - 16, area.Y - half.Y + 16))
        animate(scope, window.Root, { Position = UDim2.fromOffset(x, y) }, 0.15)
    end)
    drag(scope, window.ResizeHandle, function()
        return window.FullSize
    end, function(_, delta, start)
        window:SetSize(Vector2.new(start.X + delta.X * 2, start.Y + delta.Y * 2))
    end)
    scope:Connect(window.Gui:GetPropertyChangedSignal("AbsoluteSize"), function()
        window:SetSize(window.RequestedSize or options.Size)
        window.Root.Position = UDim2.fromScale(0.5, 0.5)
    end)
    window:SetSize(options.Size or UDim2.fromOffset(550, 400))
    installKeyboard(window)

    if options.Stars then
        local random = Random.new(17)
        for index = 1, 20 do
            local star = frame(scope, window.Shell, {
                Name = "Star" .. index,
                Position = UDim2.fromScale(random:NextNumber(0.02, 0.98), random:NextNumber(0.18, 0.96)),
                Size = UDim2.fromOffset(2, 2),
                BackgroundTransparency = random:NextNumber(0.94, 0.985),
                ZIndex = 1,
            }, "Accent")
            corner(star, 2)
        end
    end
    local bright = false
    local function pulse()
        if not scope.Alive then
            return
        end
        bright = not bright
        if window.Visible and Midnight.Visible and not Midnight.ReducedMotion then
            for _, layer in ipairs(window.Glow) do
                animate(scope, layer.Stroke, {
                    Transparency = math.clamp(layer.Base - (bright and 0.006 or 0), 0, 1),
                }, 0.35)
            end
        end
        scope:Delay(1.2, pulse)
    end
    pulse()
    animate(scope, window.Root, { GroupTransparency = 0 }, 0.3)
    animate(scope, window.Scale, { Scale = 1 }, 0.3)
    if not self.Visible then
        window:_RenderVisibility()
    end
    return window
end

function WindowMethods:SetSize(size)
    if self.Destroyed then
        return
    end
    self.RequestedSize = size
    local area = self.Gui.AbsoluteSize
    local width, height = 550, 400
    if typeof(size) == "UDim2" then
        width = size.X.Scale * area.X + size.X.Offset
        height = size.Y.Scale * area.Y + size.Y.Offset
    elseif typeof(size) == "Vector2" then
        width, height = size.X, size.Y
    end
    local maxWidth = math.max(220, area.X - 32)
    local maxHeight = math.max(180, area.Y - 32)
    width = math.clamp(width, math.min(420, maxWidth), maxWidth)
    height = math.clamp(height, math.min(300, maxHeight), maxHeight)
    self.FullSize = Vector2.new(width, height)
    self.Root.Size = UDim2.fromOffset(width + 32, (self.Minimized and 68 or height) + 32)
    self:_UpdateLayout()
end

function WindowMethods:_UpdateLayout()
    local top = self.TabPosition == "Top" or (self.Responsive and self.FullSize.X < 480)
    self.TopTabs = top
    self.NavLabel.Visible = not top
    self.NavDivider.Visible = not top
    self.NavDivider.Position = UDim2.fromOffset(137, 0)
    self.TabBar.Position = top and UDim2.new() or UDim2.fromOffset(0, 26)
    self.TabBar.Size = top and UDim2.new(1, 0, 0, 40) or UDim2.new(0, 128, 1, -26)
    self.TabBar.AutomaticCanvasSize = top and Enum.AutomaticSize.X or Enum.AutomaticSize.Y
    self.TabBar.ScrollingDirection = top and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y
    self.TabLayout.FillDirection = top and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
    self.Pages.Position = top and UDim2.fromOffset(0, 50) or UDim2.fromOffset(151, 0)
    self.Pages.Size = top and UDim2.new(1, 0, 1, -50) or UDim2.new(1, -151, 1, 0)
    for _, tab in ipairs(self.Tabs) do
        tab.NavButton.Size = top and UDim2.fromOffset(128, 38) or UDim2.new(1, -3, 0, 40)
    end
end

function WindowMethods:SetTitle(title, subtitle)
    if self.Destroyed then
        return
    end
    self.TitleLabel.Text = tostring(title)
    if subtitle ~= nil then
        self.SubTitleLabel.Text = tostring(subtitle)
    end
end

function WindowMethods:SetStatus(text)
    if not self.Destroyed then
        self.StatusLabel.Text = tostring(text)
    end
end

function WindowMethods:_RenderVisibility()
    local effective = self.Visible and Midnight.Visible
    self.MobileReopen.Visible = UserInputService.TouchEnabled and not effective
    self.Scope:Cancel(self.HideJob)
    if effective then
        self.Root.Visible = true
        animate(self.Scope, self.Root, { GroupTransparency = 0 }, 0.25)
        animate(self.Scope, self.Scale, { Scale = 1 }, 0.25)
    else
        releaseBindings(self)
        cancelCapture(self)
        if self.OpenPopover then
            self.OpenPopover:SetOpen(false)
        end
        animate(self.Scope, self.Root, { GroupTransparency = 1 }, 0.2)
        animate(self.Scope, self.Scale, { Scale = 0.985 }, 0.2)
        self.HideJob = self.Scope:Delay(0.21, function()
            self.Root.Visible = false
        end)
    end
end

function WindowMethods:SetVisible(visible)
    if self.Destroyed then
        return
    end
    self.Visible = visible == true
    self:_RenderVisibility()
end

function WindowMethods:SetMinimized(minimized)
    if self.Destroyed then
        return
    end
    self.Minimized = minimized == true
    if self.Minimized then
        releaseBindings(self)
        cancelCapture(self)
        if self.OpenPopover then
            self.OpenPopover:SetOpen(false)
        end
    end
    self.Body.Visible = not self.Minimized
    self.ResizeHandle.Visible = not self.Minimized
    self.Watermark.Visible = not self.Minimized
    self.StatusLabel.Visible = not self.Minimized
    animate(self.Scope, self.Root, {
        Size = UDim2.fromOffset(self.FullSize.X + 32, (self.Minimized and 68 or self.FullSize.Y) + 32),
    }, 0.25)
end

function WindowMethods:Destroy()
    if self.Destroyed then
        return
    end
    self:SaveConfig()
    self.Destroyed = true
    releaseBindings(self)
    for flag, control in pairs(self.Controls) do
        if FlagOwners[flag] == control then
            FlagOwners[flag] = nil
            Midnight.Flags[flag] = nil
        end
    end
    self.Scope:Destroy()
    self.Gui:Destroy()
    table.clear(self.Controls)
    table.clear(self.Bindings)
    table.clear(self.Tabs)
    local index = table.find(Midnight.Windows, self)
    if index then
        table.remove(Midnight.Windows, index)
    end
end

function Midnight:ToggleUI(value)
    if value == nil then
        self.Visible = not self.Visible
    else
        self.Visible = value == true
    end
    for _, window in ipairs(self.Windows) do
        window:_RenderVisibility()
    end
    if Runtime then
        Runtime.Gui.Enabled = self.Visible
    end
    return self.Visible
end

-- 7. Components ---------------------------------------------------------------
-- Tabs -----------------------------------------------------------------------

function WindowMethods:CreateTab(options)
    options = option(options)
    assert(not self.Destroyed, "Cannot add a tab to a destroyed window")
    local scope = Scope.new(self.Scope)
    local tab = setmetatable({
        Window = self,
        Scope = scope,
        Order = 0,
    }, { __index = ContainerMethods })
    tab.NavButton = button(scope, self.TabBar, "", {
        Name = "TabButton",
        Size = self.TopTabs and UDim2.fromOffset(128, 38) or UDim2.new(1, -3, 0, 40),
        BackgroundTransparency = 1,
        LayoutOrder = #self.Tabs + 1,
    })
    corner(tab.NavButton, 8)
    local outline = stroke(scope, tab.NavButton, "Border", 1)
    local selectedWash = frame(scope, tab.NavButton, {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
    }, "Accent")
    corner(selectedWash, 8)
    local symbol = icon(scope, tab.NavButton, options.Icon or "Grid", UDim2.fromOffset(11, 11), 18, "Muted")
    local caption = label(scope, tab.NavButton, options.Title or "Tab", {
        Position = UDim2.fromOffset(39, 0),
        Size = UDim2.new(1, -48, 1, 0),
        TextSize = 12,
        Font = Enum.Font.GothamMedium,
    })
    local indicator = frame(scope, tab.NavButton, {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(2, 0),
        BackgroundTransparency = 1,
    }, "Accent")
    corner(indicator, 2)
    tab.Page = new("CanvasGroup", {
        Name = "TabPage",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        GroupTransparency = 1,
        Visible = false,
    }, self.Pages)
    tab.Content = new("ScrollingFrame", {
        Name = "TabContent",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 3,
        ScrollBarImageTransparency = 0.5,
    }, tab.Page)
    color(scope, tab.Content, "ScrollBarImageColor3", "Accent")
    padding(tab.Content, 3)
    layout(tab.Content, 12)
    local over = false
    function tab:Refresh(immediate)
        local selected = self.Window.SelectedTab == self
        local function set(object, goals)
            if immediate then
                for key, value in pairs(goals) do
                    object[key] = value
                end
            else
                animate(scope, object, goals, 0.22)
            end
        end
        set(self.NavButton, {
            BackgroundColor3 = Midnight.Theme.Raised,
            BackgroundTransparency = selected and 0.25 or (over and 0.6 or 1),
        })
        set(selectedWash, { BackgroundTransparency = selected and 0.94 or 1 })
        set(outline, { Transparency = selected and 0.65 or 1 })
        set(caption, { TextColor3 = selected and Midnight.Theme.Text or Midnight.Theme.Muted })
        set(indicator, {
            Size = UDim2.fromOffset(2, selected and 18 or 0),
            BackgroundTransparency = selected and 0 or 1,
        })
        symbol:SetToken(selected and "Accent" or "Muted", immediate)
    end
    function tab:Select()
        if not scope.Alive or self.Window.SelectedTab == self then
            return self
        end
        cancelCapture(self.Window)
        if self.Window.OpenPopover then
            self.Window.OpenPopover:SetOpen(false)
        end
        local previous = self.Window.SelectedTab
        self.Window.SelectedTab = self
        if previous then
            previous.Scope:Cancel(previous.HideJob)
            animate(previous.Scope, previous.Page, { GroupTransparency = 1 }, 0.15)
            previous.HideJob = previous.Scope:Delay(0.16, function()
                if self.Window.SelectedTab ~= previous then
                    previous.Page.Visible = false
                end
            end)
        end
        scope:Cancel(self.HideJob)
        self.Page.Visible = true
        self.Page.ZIndex = 2
        if previous then
            previous.Page.ZIndex = 1
        end
        self.Page.Position = UDim2.fromOffset(0, Midnight.ReducedMotion and 0 or 6)
        animate(scope, self.Page, {
            GroupTransparency = 0,
            Position = UDim2.fromOffset(0, 0),
        }, 0.25)
        for _, entry in ipairs(self.Window.Tabs) do
            entry:Refresh(false)
        end
        return self
    end
    themed(scope, function()
        tab:Refresh(true)
    end)
    scope:Connect(tab.NavButton.MouseEnter, function()
        over = true
        tab:Refresh()
    end)
    scope:Connect(tab.NavButton.MouseLeave, function()
        over = false
        tab:Refresh()
    end)
    scope:Connect(tab.NavButton.Activated, function()
        tab:Select()
    end)
    table.insert(self.Tabs, tab)
    if #self.Tabs == 1 then
        tab:Select()
    else
        tab:Refresh(true)
    end
    return tab
end

WindowMethods.Tab = WindowMethods.CreateTab

local function row(container, height)
    assert(container.Scope.Alive, "Cannot add a control to a destroyed container")
    container.Order = container.Order + 1
    local scope = Scope.new(container.Scope)
    local object = frame(scope, container.Content, {
        Size = UDim2.new(1, -6, 0, height),
        LayoutOrder = container.Order,
    }, "Panel")
    corner(object, 8)
    local outline = stroke(scope, object, "Border", 0.8)
    return scope, object, outline
end

local function captions(scope, object, options, reserve)
    local hasDescription = options.Description and options.Description ~= ""
    local title = label(scope, object, options.Title or "Control", {
        Position = UDim2.fromOffset(14, hasDescription and 9 or 0),
        Size = UDim2.new(1, -(reserve or 24), 0, hasDescription and 21 or 44),
        Font = Enum.Font.GothamMedium,
    })
    local description
    if hasDescription then
        description = label(scope, object, options.Description, {
            Position = UDim2.fromOffset(14, 30),
            Size = UDim2.new(1, -28, 0, 19),
            TextSize = 11,
        }, "Muted")
    end
    return title, description
end

local function control(container, options, height)
    local scope, object, outline = row(container, height)
    local result = setmetatable({
        Scope = scope,
        Root = object,
        Outline = outline,
        Window = container.Window,
        Options = options,
        Callback = options.Callback,
        Disabled = false,
        Value = nil,
    }, { __index = ControlMethods })
    return result, scope, object
end

function ControlMethods:Get()
    return copy(self.Value)
end

function ControlMethods:SetVisible(visible)
    if self.Scope.Alive then
        self.Root.Visible = visible == true
    end
    return self
end

function ControlMethods:SetDisabled(disabled)
    if not self.Scope.Alive then
        return self
    end
    self.Disabled = disabled == true
    if not self.DisabledVeil then
        self.DisabledVeil = frame(self.Scope, self.Root, {
            Name = "DisabledVeil",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 0.48,
            ZIndex = 50,
            Active = true,
        }, "Panel")
        corner(self.DisabledVeil, 8)
    end
    self.DisabledVeil.Visible = self.Disabled
    if self.Disabled and self.SetOpen then
        self:SetOpen(false)
    end
    if self.Disabled and self.Window.Capture == self then
        cancelCapture(self.Window)
    end
    if self.Binding then
        self.Binding.Enabled = not self.Disabled
        if self.Disabled and self.Binding.Active and self.Binding.Mode == "Hold" then
            self.Binding.Active = false
            safe(self.Binding.Callback, false, self.Binding.Key)
        end
    end
    return self
end

function ControlMethods:Destroy()
    if not self.Scope.Alive then
        return
    end
    if self.Binding then
        if self.Binding.Active and self.Binding.Mode == "Hold" then
            safe(self.Binding.Callback, false, self.Binding.Key)
        end
        self.Window.Bindings[self.Binding] = nil
    end
    if self.Window.Capture == self then
        self.Window.Capture = nil
    end
    if self.Window.OpenPopover == self then
        self.Window.OpenPopover = nil
    end
    if self.Flag and FlagOwners[self.Flag] == self then
        FlagOwners[self.Flag] = nil
        Midnight.Flags[self.Flag] = nil
        self.Window.Controls[self.Flag] = nil
    end
    self.Scope:Destroy()
    self.Root:Destroy()
end

-- Sections -------------------------------------------------------------------

function ContainerMethods:Section(options)
    options = option(options)
    self.Order = self.Order + 1
    local scope = Scope.new(self.Scope)
    local root = frame(scope, self.Content, {
        Name = "Section",
        Size = UDim2.new(1, -6, 0, 38),
        BackgroundTransparency = 1,
        LayoutOrder = self.Order,
        ClipsDescendants = true,
    })
    local header = button(scope, root, "", {
        Name = "SectionHeader",
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundTransparency = 1,
    })
    local marker = frame(scope, header, {
        Position = UDim2.fromOffset(1, 11),
        Size = UDim2.fromOffset(3, 14),
        BackgroundTransparency = 0.15,
    }, "Accent")
    corner(marker, 2)
    local title = label(scope, header, options.Title or "Section", {
        Position = UDim2.fromOffset(13, 0),
        Size = UDim2.new(1, -48, 1, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 12,
    })
    local arrow = icon(scope, header, "Chevron", UDim2.new(1, -26, 0, 9), 18, "Muted")
    arrow.Root.Visible = options.Collapsible ~= false
    local content = frame(scope, root, {
        Name = "SectionContent",
        Position = UDim2.fromOffset(0, 42),
        Size = UDim2.new(1, 0, 0, 0),
        BackgroundTransparency = 1,
    })
    local list = layout(content, 8)
    local section = setmetatable({
        Window = self.Window,
        Scope = scope,
        Content = content,
        Root = root,
        Layout = list,
        Order = 0,
        Collapsed = options.Collapsed == true,
        ExpandedHeight = 42,
        Transitioning = false,
    }, { __index = ContainerMethods })
    local function measure(updateRoot)
        if not scope.Alive then
            return
        end
        local scale = math.max(section.Window.Scale.Scale, 0.01)
        local height = math.max(0, list.AbsoluteContentSize.Y / scale)
        section.ExpandedHeight = 42 + height + (height > 0 and 2 or 0)
        content.Size = UDim2.new(1, 0, 0, height)
        -- Content-driven changes follow child animations without a second tween.
        if updateRoot ~= false and not section.Collapsed and not section.Transitioning then
            root.Size = UDim2.new(1, -6, 0, section.ExpandedHeight)
        end
    end
    function section:SetCollapsed(value, immediate)
        if not scope.Alive then
            return self
        end
        self.Collapsed = value == true
        scope:Cancel(self.CollapseJob)
        measure(false)
        local target = UDim2.new(1, -6, 0, self.Collapsed and 36 or self.ExpandedHeight)
        content.Visible = true
        if immediate or Midnight.ReducedMotion then
            self.Transitioning = false
            root.Size = target
            content.Visible = not self.Collapsed
            arrow.Root.Rotation = self.Collapsed and -90 or 0
        else
            self.Transitioning = true
            animate(scope, root, { Size = target }, 0.26)
            animate(scope, arrow.Root, { Rotation = self.Collapsed and -90 or 0 }, 0.22)
            self.CollapseJob = scope:Delay(0.27, function()
                self.Transitioning = false
                content.Visible = not self.Collapsed
                if not self.Collapsed then
                    measure()
                end
            end)
        end
        return self
    end
    function section:SetTitle(text)
        title.Text = tostring(text)
        return self
    end
    function section:SetVisible(visible)
        root.Visible = visible == true
        return self
    end
    scope:Connect(list:GetPropertyChangedSignal("AbsoluteContentSize"), measure)
    scope:Connect(section.Window.Scale:GetPropertyChangedSignal("Scale"), measure)
    scope:Connect(header.Activated, function()
        if options.Collapsible ~= false then
            section:SetCollapsed(not section.Collapsed)
        end
    end)
    scope:Connect(header.MouseEnter, function()
        arrow:SetToken("Accent")
    end)
    scope:Connect(header.MouseLeave, function()
        arrow:SetToken("Muted")
    end)
    section:SetCollapsed(section.Collapsed, true)
    return section
end

ContainerMethods.CreateSection = ContainerMethods.Section

-- Labels and paragraphs ------------------------------------------------------

function ContainerMethods:Label(options)
    options = option(options)
    local item, scope, root = control(self, options, 44)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.Size = UDim2.new(1, -6, 0, 0)
    padding(root, 12)
    layout(root, 5)
    local title = label(scope, root, options.Title or "Label", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None,
        LayoutOrder = 1,
    })
    local description = label(scope, root, options.Description or "", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None,
        TextSize = 12,
        LayoutOrder = 2,
        Visible = options.Description ~= nil and options.Description ~= "",
    }, "Muted")
    function item:Set(text, details)
        title.Text = tostring(text)
        self.Value = title.Text
        if details ~= nil then
            description.Text = tostring(details)
            description.Visible = description.Text ~= ""
        end
        return self
    end
    if options.Style == "Hero" then
        title.TextSize = 20
        title.Font = Enum.Font.GothamBold
        description.TextSize = 12
        local wash = new("UIGradient", {
            Rotation = 25,
        }, root)
        themed(scope, function(theme)
            root.BackgroundColor3 = Color3.new(1, 1, 1)
            wash.Color = ColorSequence.new(theme.Panel:Lerp(theme.Accent, 0.13), theme.Panel)
        end)
    end
    item.Value = title.Text
    return item
end

ContainerMethods.Paragraph = ContainerMethods.Label

-- Buttons --------------------------------------------------------------------

function ContainerMethods:Button(options)
    options = option(options)
    local item, scope, root = control(self, options, options.Description and 64 or 48)
    local title = captions(scope, root, options, 66)
    local token = options.Style == "Danger" and "Error" or "Accent"
    local badge = frame(scope, root, {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -14, 0.5, 0),
        Size = UDim2.fromOffset(28, 28),
        BackgroundTransparency = 0.91,
    }, token)
    corner(badge, 8)
    local symbol = icon(scope, badge, options.Icon or "Arrow", UDim2.fromOffset(5, 5), 18, token)
    local scale = new("UIScale", { Scale = 1 }, symbol.Root)
    local wash = frame(scope, root, {
        Name = "PressHighlight",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
    }, token)
    corner(wash, 8)
    local hit = button(scope, root, "", {
        Name = "ButtonHit",
        Size = UDim2.fromScale(1, 1),
        ZIndex = 4,
    })
    hover(scope, root, item.Outline, {
        Accent = token,
        Enabled = function()
            return not item.Disabled and not item.Loading
        end,
    })
    if options.Style == "Primary" then
        themed(scope, function(theme)
            root.BackgroundColor3 = theme.Panel:Lerp(theme.Accent, 0.12)
            item.Outline.Color = theme.Accent
            item.Outline.Transparency = 0.7
        end)
    end
    function item:SetLoading(value)
        if not scope.Alive then
            return self
        end
        self.Loading = value == true
        title.Text = self.Loading and (options.LoadingText or "Working...") or (options.Title or "Button")
        symbol.Root.Visible = not self.Loading
        return self
    end
    function item:SetText(text)
        options.Title = tostring(text)
        if not self.Loading then
            title.Text = options.Title
        end
        return self
    end
    function item:Press()
        if not scope.Alive or self.Disabled or self.Loading then
            return
        end
        scope:Cancel(self.PressJob)
        animate(scope, scale, { Scale = 0.87 }, 0.15)
        animate(scope, wash, { BackgroundTransparency = 0.94 }, 0.15)
        self.PressJob = scope:Delay(0.15, function()
            animate(scope, scale, { Scale = 1 }, 0.2)
            animate(scope, wash, { BackgroundTransparency = 1 }, 0.25)
        end)
        safe(self.Callback)
    end
    scope:Connect(hit.Activated, function()
        item:Press()
    end)
    return item
end

-- Toggles --------------------------------------------------------------------

function ContainerMethods:Toggle(options)
    options = option(options)
    local item, scope, root = control(self, options, options.Description and 58 or 44)
    captions(scope, root, options, 76)
    local track = frame(scope, root, {
        Position = UDim2.new(1, -58, 0, 12),
        Size = UDim2.fromOffset(44, 22),
    }, "Raised")
    corner(track, 11)
    local border = stroke(scope, track, "Accent", 0.8)
    local knob = frame(scope, track, {
        Position = UDim2.fromOffset(3, 3),
        Size = UDim2.fromOffset(16, 16),
    }, "Text")
    corner(knob, 8)
    local hit = button(scope, root, "", { Size = UDim2.fromScale(1, 1) })
    hover(scope, root, item.Outline)
    function item:Refresh(immediate)
        local theme = Midnight.Theme
        local goals = { BackgroundColor3 = self.Value and theme.Accent or theme.Raised }
        local position = self.Value and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3)
        if immediate then
            track.BackgroundColor3 = goals.BackgroundColor3
            knob.Position = position
            border.Transparency = self.Value and 0.05 or 0.8
        else
            animate(scope, track, goals)
            animate(scope, knob, { Position = position })
            animate(scope, border, { Transparency = self.Value and 0.05 or 0.8 })
        end
    end
    function item:Set(value, silent)
        if type(value) ~= "boolean" or not scope.Alive then
            return self
        end
        local changed = self.Value ~= value
        self.Value = value
        self:Refresh(false)
        self:_Commit(silent, changed)
        return self
    end
    themed(scope, function()
        item:Refresh(true)
    end)
    scope:Connect(hit.Activated, function()
        if not item.Disabled then
            item:Set(not item.Value)
        end
    end)
    item:_Register(options.Flag, options.Default == true)
    return item
end

-- Sliders --------------------------------------------------------------------

function ContainerMethods:Slider(options)
    options = option(options)
    local item, scope, root = control(self, options, options.Description and 96 or 78)
    captions(scope, root, options, 92)
    local minimum = finite(options.Min, 0)
    local maximum = finite(options.Max, 100)
    if maximum < minimum then
        minimum, maximum = maximum, minimum
    end
    local step = math.max(0, finite(options.Increment, 1))
    local valueLabel = label(scope, root, "", {
        Position = UDim2.new(1, -90, 0, 8),
        Size = UDim2.fromOffset(76, 28),
        TextXAlignment = Enum.TextXAlignment.Right,
        TextSize = 12,
    }, "Accent")
    local hit = button(scope, root, "", {
        Position = UDim2.new(0, 14, 1, -38),
        Size = UDim2.new(1, -28, 0, 32),
    })
    local track = frame(scope, hit, {
        Position = UDim2.new(0, 0, 0.5, -3),
        Size = UDim2.new(1, 0, 0, 6),
    }, "Raised")
    corner(track, 6)
    local fill = frame(scope, track, { Size = UDim2.fromScale(0, 1) }, "Accent")
    corner(fill, 6)
    gradient(scope, fill)
    local knob = frame(scope, track, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(16, 16),
    }, "Text")
    corner(knob, 8)
    stroke(scope, knob, "Accent", 0, 2)
    function item:Set(value, silent)
        value = finite(value, nil)
        if not value or not scope.Alive then
            return self
        end
        value = math.clamp(value, minimum, maximum)
        if step > 0 then
            value = minimum + math.floor((value - minimum) / step + 0.5) * step
        end
        value = math.clamp(value, minimum, maximum)
        value = math.round(value * 1000000) / 1000000
        local changed = self.Value ~= value
        self.Value = value
        local alpha = maximum == minimum and 0 or (value - minimum) / (maximum - minimum)
        valueLabel.Text = string.format("%.6g", value) .. tostring(options.Suffix or "")
        animate(scope, fill, { Size = UDim2.fromScale(alpha, 1) }, 0.15)
        animate(scope, knob, { Position = UDim2.fromScale(alpha, 0.5) }, 0.15)
        self:_Commit(silent, changed)
        return self
    end
    drag(scope, hit, function()
        return not item.Disabled
    end, function(position)
        if not item.Disabled then
            local alpha = fraction(position, hit)
            item:Set(minimum + alpha * (maximum - minimum))
        end
    end)
    item:_Register(options.Flag, finite(options.Default, minimum))
    return item
end

-- Dropdowns ------------------------------------------------------------------

local function stringOptions(values)
    local result = {}
    local seen = {}
    for _, value in ipairs(type(values) == "table" and values or {}) do
        local text = tostring(value)
        if not seen[text] then
            seen[text] = true
            table.insert(result, text)
        end
    end
    return result
end

function ContainerMethods:Dropdown(options)
    options = option(options)
    local baseHeight = options.Description and 98 or 80
    local item, scope, root = control(self, options, baseHeight)
    root.ClipsDescendants = true
    captions(scope, root, options)
    item.Multi = options.Multi == true
    item.Items = stringOptions(options.Options or options.Values)
    item.Open = false
    local selected = button(scope, root, "", {
        Name = "DropdownTrigger",
        Position = UDim2.fromOffset(12, baseHeight - 42),
        Size = UDim2.new(1, -24, 0, 34),
        BackgroundTransparency = 0,
    })
    corner(selected, 7)
    color(scope, selected, "BackgroundColor3", "Background")
    local selectedOutline = stroke(scope, selected, "Border", 0.65)
    local selectedText = label(scope, selected, "Select...", {
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -44, 1, 0),
        TextSize = 12,
    })
    local arrow = icon(scope, selected, "Chevron", UDim2.new(1, -27, 0, 8), 18, "Muted")
    local panel = frame(scope, root, {
        Name = "DropdownPanel",
        Position = UDim2.fromOffset(12, baseHeight + 2),
        Size = UDim2.new(1, -24, 0, 170),
        BackgroundTransparency = 1,
        Visible = false,
    })
    local searchable = options.Searchable ~= false
    local search = textBox(scope, panel, "Search options...", {
        Name = "DropdownSearch",
        Size = UDim2.new(1, 0, 0, 32),
        Visible = searchable,
    })
    local list = new("ScrollingFrame", {
        Name = "DropdownList",
        Position = UDim2.fromOffset(0, searchable and 40 or 0),
        Size = UDim2.new(1, 0, 1, searchable and -40 or 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageTransparency = 0.35,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, panel)
    color(scope, list, "ScrollBarImageColor3", "Accent")
    layout(list, 4)
    local empty = label(scope, panel, "No matching options", {
        Position = UDim2.fromOffset(4, searchable and 48 or 8),
        Size = UDim2.new(1, -8, 0, 32),
        TextSize = 12,
        Visible = false,
    }, "Muted")
    local listScope
    local entries = {}
    local function selectedValue(value)
        return item.Multi and table.find(item.Value, value) ~= nil or item.Value == value
    end
    local function renderEntry(entry, immediate)
        local active = selectedValue(entry.Value)
        local theme = Midnight.Theme
        local goals = {
            BackgroundColor3 = active and theme.Panel:Lerp(theme.Accent, 0.13) or theme.Raised,
            BackgroundTransparency = active and 0 or (entry.Hovered and 0.5 or 1),
        }
        if immediate then
            for key, value in pairs(goals) do
                entry.Root[key] = value
            end
            entry.Caption.TextColor3 = active and theme.Text or theme.Muted
        else
            animate(listScope, entry.Root, goals, 0.18)
            animate(listScope, entry.Caption, { TextColor3 = active and theme.Text or theme.Muted })
        end
        entry.Check.Root.Visible = active
    end
    function item:Refresh(immediate)
        if self.Multi then
            selectedText.Text = #self.Value > 0 and table.concat(self.Value, ", ") or "Select..."
        else
            selectedText.Text = self.Value ~= "" and self.Value or "Select..."
        end
        for _, entry in pairs(entries) do
            renderEntry(entry, immediate)
        end
        selectedOutline.Color = self.Open and Midnight.Theme.Accent or Midnight.Theme.Border
        selectedOutline.Transparency = self.Open and 0.25 or 0.65
    end
    local function updateFilter()
        local query = string.lower(search.Text)
        local count = 0
        for value, entry in pairs(entries) do
            entry.Root.Visible = string.find(string.lower(value), query, 1, true) ~= nil
            if entry.Root.Visible then
                count = count + 1
            end
        end
        empty.Visible = count == 0
        local rows = math.clamp(count, 1, math.clamp(math.floor(finite(options.MaxVisible, 4)), 1, 8))
        item.PanelHeight = (searchable and 40 or 0) + rows * 34 + math.max(0, rows - 1) * 4
        panel.Size = UDim2.new(1, -24, 0, item.PanelHeight)
        if item.Open then
            animate(scope, root, {
                Size = UDim2.new(1, -6, 0, baseHeight + item.PanelHeight + 12),
            }, 0.2)
        end
        list.CanvasPosition = Vector2.zero
    end
    function item:SetOpen(value)
        if not scope.Alive then
            return self
        end
        value = value == true and not self.Disabled
        if value and self.Window.OpenPopover and self.Window.OpenPopover ~= self then
            self.Window.OpenPopover:SetOpen(false)
        end
        self.Open = value
        scope:Cancel(self.CloseJob)
        if self.Open then
            self.Window.OpenPopover = self
            panel.Visible = true
            updateFilter()
        else
            if self.Window.OpenPopover == self then
                self.Window.OpenPopover = nil
            end
            if search:IsFocused() then
                search:ReleaseFocus()
            end
            self.CloseJob = scope:Delay(0.23, function()
                if not self.Open then
                    panel.Visible = false
                end
            end)
        end
        animate(scope, arrow.Root, { Rotation = self.Open and 180 or 0 }, 0.2)
        animate(scope, selectedOutline, {
            Color = self.Open and Midnight.Theme.Accent or Midnight.Theme.Border,
            Transparency = self.Open and 0.25 or 0.65,
        })
        animate(scope, root, {
            Size = UDim2.new(1, -6, 0, baseHeight + (self.Open and (self.PanelHeight + 12) or 0)),
        }, 0.22)
        return self
    end
    function item:Set(value, silent)
        if not scope.Alive then
            return self
        end
        local nextValue
        if self.Multi then
            nextValue = {}
            local source = type(value) == "table" and value or {}
            for _, entry in ipairs(self.Items) do
                if table.find(source, entry) then
                    table.insert(nextValue, entry)
                end
            end
        else
            nextValue = type(value) == "string" and table.find(self.Items, value) and value or ""
        end
        local changed = self.Value ~= nextValue
        if self.Multi then
            local old = self.Value or {}
            changed = #old ~= #nextValue
            for index, entry in ipairs(nextValue) do
                if old[index] ~= entry then
                    changed = true
                end
            end
        end
        self.Value = nextValue
        self:Refresh(false)
        self:_Commit(silent, changed)
        return self
    end
    local function build()
        if listScope then
            listScope:Destroy()
        end
        for _, entry in pairs(entries) do
            entry.Root:Destroy()
        end
        entries = {}
        listScope = Scope.new(scope)
        for index, value in ipairs(item.Items) do
            local entryRoot = button(listScope, list, "", {
                Size = UDim2.new(1, -6, 0, 34),
                BackgroundTransparency = 1,
                LayoutOrder = index,
            })
            corner(entryRoot, 6)
            local entry = {
                Root = entryRoot,
                Value = value,
                Hovered = false,
                Caption = label(listScope, entryRoot, value, {
                    Position = UDim2.fromOffset(10, 0),
                    Size = UDim2.new(1, -44, 1, 0),
                    TextSize = 12,
                }),
                Check = icon(listScope, entryRoot, "Check", UDim2.new(1, -26, 0, 8), 18, "Accent"),
            }
            entries[value] = entry
            listScope:Connect(entryRoot.MouseEnter, function()
                entry.Hovered = true
                renderEntry(entry)
            end)
            listScope:Connect(entryRoot.MouseLeave, function()
                entry.Hovered = false
                renderEntry(entry)
            end)
            listScope:Connect(entryRoot.Activated, function()
                if item.Disabled then
                    return
                end
                if item.Multi then
                    local values = item:Get()
                    local indexOf = table.find(values, value)
                    if indexOf then
                        table.remove(values, indexOf)
                    else
                        table.insert(values, value)
                    end
                    item:Set(values)
                else
                    item:Set(value)
                    item:SetOpen(false)
                end
            end)
        end
        themed(listScope, function()
            item:Refresh(true)
        end)
        updateFilter()
    end
    function item:SetOptions(values)
        self.Items = stringOptions(values)
        self:Set(self.Value, true)
        build()
        return self
    end
    scope:Connect(search:GetPropertyChangedSignal("Text"), updateFilter)
    scope:Connect(selected.Activated, function()
        if not item.Disabled then
            item:SetOpen(not item.Open)
        end
    end)
    item.Value = item.Multi and {} or ""
    item.PanelHeight = 170
    themed(scope, function()
        item:Refresh(true)
    end)
    item:_Register(options.Flag, options.Default or (item.Multi and {} or ""))
    build()
    return item
end

-- MultiDropdowns -------------------------------------------------------------

function ContainerMethods:MultiDropdown(options)
    options = copy(option(options))
    options.Multi = true
    return self:Dropdown(options)
end

-- Keybinds -------------------------------------------------------------------

function ContainerMethods:Keybind(options)
    options = option(options)
    local item, scope, root = control(self, options, options.Description and 60 or 46)
    captions(scope, root, options, 132)
    local keyButton = button(scope, root, "None", {
        Position = UDim2.new(1, -120, 0, 8),
        Size = UDim2.fromOffset(108, 30),
        BackgroundTransparency = 0,
        TextSize = 11,
    })
    corner(keyButton, 6)
    color(scope, keyButton, "BackgroundColor3", "Raised")
    local keyOutline = stroke(scope, keyButton, "Border", 0.65)
    item.Binding = {
        Key = Enum.KeyCode.Unknown,
        Mode = options.Mode == "Hold" and "Hold" or "Toggle",
        Active = false,
        Enabled = true,
        Callback = options.Callback,
    }
    item.Window.Bindings[item.Binding] = true
    -- The main callback is reserved for key activation, not key assignment.
    item.Callback = options.Changed
    function item:Refresh()
        local capturing = self.Window.Capture == self
        keyButton.Text = capturing and "Press a key..."
            or (self.Value == Enum.KeyCode.Unknown and "None" or self.Value.Name)
        animate(scope, keyOutline, {
            Color = capturing and Midnight.Theme.Accent or Midnight.Theme.Border,
            Transparency = capturing and 0.15 or 0.65,
        })
    end
    function item:Set(value, silent)
        if not scope.Alive then
            return self
        end
        local nextKey = keyCode(value, self.Value)
        local changed = nextKey ~= self.Value
        if changed and self.Binding.Active and self.Binding.Mode == "Hold" then
            self.Binding.Active = false
            safe(self.Binding.Callback, false, self.Binding.Key)
        end
        self.Value = nextKey
        self.Binding.Key = nextKey
        self:Refresh()
        self:_Commit(silent, changed)
        return self
    end
    function item:SetMode(mode)
        if self.Binding.Active and self.Binding.Mode == "Hold" then
            safe(self.Binding.Callback, false, self.Binding.Key)
        end
        self.Binding.Active = false
        self.Binding.Mode = mode == "Hold" and "Hold" or "Toggle"
        return self
    end
    scope:Connect(keyButton.Activated, function()
        if item.Disabled then
            return
        end
        if item.Window.Capture == item then
            cancelCapture(item.Window)
            return
        end
        cancelCapture(item.Window)
        releaseBindings(item.Window)
        item.Window.Capture = item
        item:Refresh()
        item.CaptureJob = scope:Delay(8, function()
            if item.Window.Capture == item then
                cancelCapture(item.Window)
            end
        end)
    end)
    item.Value = Enum.KeyCode.Unknown
    item:_Register(options.Flag, keyCode(options.Default))
    return item
end

-- Textboxes ------------------------------------------------------------------

function ContainerMethods:Textbox(options)
    options = option(options)
    local item, scope, root = control(self, options, options.Description and 96 or 78)
    captions(scope, root, options)
    local input = textBox(scope, root, options.Placeholder or "Enter text...", {
        Position = UDim2.new(0, 12, 1, -40),
        Size = UDim2.new(1, -24, 0, 32),
        MultiLine = options.MultiLine == true,
    })
    local maxLength = math.max(0, math.floor(finite(options.MaxLength, 4096)))
    local function trim(text)
        text = tostring(text)
        local ok, boundary = pcall(utf8.offset, text, maxLength + 1)
        if ok and boundary then
            return string.sub(text, 1, boundary - 1)
        end
        return text
    end
    function item:Set(value, silent)
        if type(value) ~= "string" or not scope.Alive then
            return self
        end
        value = trim(value)
        local changed = self.Value ~= value
        self.Value = value
        input.Text = value
        self:_Commit(silent, changed)
        return self
    end
    scope:Connect(input.Focused, function()
        if item.Disabled then
            input:ReleaseFocus()
        end
    end)
    scope:Connect(input.FocusLost, function(enterPressed)
        if item.Disabled then
            input.Text = item.Value
            return
        end
        if options.EnterOnly and not enterPressed then
            input.Text = item.Value
            return
        end
        item:Set(input.Text)
    end)
    item:_Register(options.Flag, tostring(options.Default or ""))
    return item
end

-- Color pickers --------------------------------------------------------------

local function toHex(colorValue)
    return string.format("#%02X%02X%02X",
        math.round(colorValue.R * 255),
        math.round(colorValue.G * 255),
        math.round(colorValue.B * 255)
    )
end

local function fromHex(text)
    local value = tostring(text):gsub("%s", ""):gsub("^#", "")
    if #value == 3 and value:match("^%x+$") then
        value = value:sub(1, 1):rep(2) .. value:sub(2, 2):rep(2) .. value:sub(3, 3):rep(2)
    end
    if #value ~= 6 or not value:match("^%x+$") then
        return nil
    end
    return Color3.fromRGB(
        tonumber(value:sub(1, 2), 16),
        tonumber(value:sub(3, 4), 16),
        tonumber(value:sub(5, 6), 16)
    )
end

function ContainerMethods:ColorPicker(options)
    options = option(options)
    local baseHeight = options.Description and 60 or 46
    local item, scope, root = control(self, options, baseHeight)
    captions(scope, root, options, 76)
    root.ClipsDescendants = true
    item.Open = false
    local preview = button(scope, root, "", {
        Position = UDim2.new(1, -60, 0, 10),
        Size = UDim2.fromOffset(46, 26),
        BackgroundTransparency = 0,
    })
    corner(preview, 6)
    stroke(scope, preview, "Text", 0.65)
    local panel = frame(scope, root, {
        Position = UDim2.fromOffset(12, baseHeight),
        Size = UDim2.new(1, -24, 0, 278),
        BackgroundTransparency = 1,
        Visible = false,
    })
    local sv = frame(scope, panel, {
        Size = UDim2.new(1, 0, 0, 144),
        ClipsDescendants = true,
    })
    corner(sv, 8)
    local white = frame(scope, sv, {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(1, 1, 1),
    })
    corner(white, 8)
    local whiteGradient = new("UIGradient", {}, white)
    whiteGradient.Transparency = NumberSequence.new(0, 1)
    local black = frame(scope, sv, {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
    })
    corner(black, 8)
    local blackGradient = new("UIGradient", { Rotation = 90 }, black)
    blackGradient.Transparency = NumberSequence.new(1, 0)
    local svCursor = frame(scope, sv, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(10, 10),
        BackgroundTransparency = 1,
        ZIndex = 3,
    })
    corner(svCursor, 5)
    new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }, svCursor)
    local svHit = button(scope, sv, "", {
        Size = UDim2.fromScale(1, 1),
        ZIndex = 4,
    })
    local hueHit = button(scope, panel, "", {
        Position = UDim2.fromOffset(0, 150),
        Size = UDim2.new(1, 0, 0, 30),
    })
    local hueTrack = frame(scope, hueHit, {
        Position = UDim2.fromOffset(0, 5),
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundColor3 = Color3.new(1, 1, 1),
    })
    corner(hueTrack, 6)
    local rainbow = {}
    for index = 0, 6 do
        table.insert(rainbow, ColorSequenceKeypoint.new(index / 6, Color3.fromHSV(index / 6, 1, 1)))
    end
    new("UIGradient", { Color = ColorSequence.new(rainbow) }, hueTrack)
    local hueCursor = frame(scope, hueTrack, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(5, 26),
        BackgroundColor3 = Color3.new(1, 1, 1),
    })
    corner(hueCursor, 3)
    local rgb = {}
    local names = { "R", "G", "B" }
    for index = 1, 3 do
        rgb[index] = textBox(scope, panel, names[index], {
            Position = UDim2.new((index - 1) / 3, 2, 0, 187),
            Size = UDim2.new(1 / 3, -4, 0, 32),
            TextXAlignment = Enum.TextXAlignment.Center,
        })
    end
    local hex = textBox(scope, panel, "#RRGGBB", {
        Position = UDim2.fromOffset(0, 229),
        Size = UDim2.new(1, -120, 0, 32),
        TextSize = 11,
    })
    local copyButton = button(scope, panel, "Copy", {
        Position = UDim2.new(1, -114, 0, 229),
        Size = UDim2.fromOffset(54, 32),
        BackgroundTransparency = 0,
        TextSize = 11,
    })
    local pasteButton = button(scope, panel, "Paste", {
        Position = UDim2.new(1, -54, 0, 229),
        Size = UDim2.fromOffset(54, 32),
        BackgroundTransparency = 0,
        TextSize = 11,
    })
    for _, itemButton in ipairs({ copyButton, pasteButton }) do
        corner(itemButton, 6)
        hover(scope, itemButton, stroke(scope, itemButton, "Accent", 0.7))
    end
    local h, s, v = 0, 1, 1
    function item:Refresh()
        preview.BackgroundColor3 = self.Value
        sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
        svCursor.Position = UDim2.fromScale(s, 1 - v)
        hueCursor.Position = UDim2.fromScale(h, 0.5)
        rgb[1].Text = tostring(math.round(self.Value.R * 255))
        rgb[2].Text = tostring(math.round(self.Value.G * 255))
        rgb[3].Text = tostring(math.round(self.Value.B * 255))
        hex.Text = toHex(self.Value)
    end
    function item:Set(value, silent, preserveHSV)
        if type(value) == "string" then
            value = fromHex(value)
        end
        if typeof(value) ~= "Color3" or not scope.Alive then
            return self
        end
        local changed = self.Value ~= value
        self.Value = value
        if not preserveHSV then
            local nextH, nextS, nextV = value:ToHSV()
            -- Preserve the last hue when choosing gray or black.
            if nextS > 0 then
                h = nextH
            end
            s, v = nextS, nextV
        end
        self:Refresh()
        self:_Commit(silent, changed)
        return self
    end
    function item:SetOpen(open)
        if not scope.Alive then
            return self
        end
        open = open == true and not self.Disabled
        if open and self.Window.OpenPopover and self.Window.OpenPopover ~= self then
            self.Window.OpenPopover:SetOpen(false)
        end
        self.Open = open
        scope:Cancel(self.CloseJob)
        if self.Open then
            self.Window.OpenPopover = self
            panel.Visible = true
        else
            if self.Window.OpenPopover == self then
                self.Window.OpenPopover = nil
            end
            self.CloseJob = scope:Delay(0.23, function()
                if not self.Open then
                    panel.Visible = false
                end
            end)
        end
        animate(scope, root, {
            Size = UDim2.new(1, -6, 0, baseHeight + (self.Open and 278 or 0)),
        }, 0.22)
        return self
    end
    scope:Connect(preview.Activated, function()
        if not item.Disabled then
            item:SetOpen(not item.Open)
        end
    end)
    drag(scope, svHit, function()
        return not item.Disabled
    end, function(position)
        if not item.Disabled then
            local x, y = fraction(position, sv)
            s, v = x, 1 - y
            item:Set(Color3.fromHSV(h, s, v), false, true)
        end
    end)
    drag(scope, hueHit, function()
        return not item.Disabled
    end, function(position)
        if not item.Disabled then
            h = fraction(position, hueTrack)
            item:Set(Color3.fromHSV(h, s, v), false, true)
        end
    end)
    for index = 1, 3 do
        scope:Connect(rgb[index].FocusLost, function()
            if item.Disabled then
                item:Refresh()
                return
            end
            local r = finite(rgb[1].Text, nil)
            local g = finite(rgb[2].Text, nil)
            local b = finite(rgb[3].Text, nil)
            if r and g and b then
                item:Set(Color3.fromRGB(
                    math.clamp(r, 0, 255),
                    math.clamp(g, 0, 255),
                    math.clamp(b, 0, 255)
                ))
            else
                item:Refresh()
            end
        end)
    end
    scope:Connect(hex.FocusLost, function()
        local value = fromHex(hex.Text)
        if value and not item.Disabled then
            item:Set(value)
        else
            item:Refresh()
        end
    end)
    scope:Connect(copyButton.Activated, function()
        ClipboardMemory = toHex(item.Value)
        local setClipboard = capability("setclipboard") or capability("toclipboard")
        if setClipboard then
            safe(setClipboard, ClipboardMemory)
        end
        hex:CaptureFocus()
        hex.SelectionStart = 1
        hex.CursorPosition = #hex.Text + 1
    end)
    scope:Connect(pasteButton.Activated, function()
        if item.Disabled then
            return
        end
        local text = ClipboardMemory
        local getClipboard = capability("getclipboard")
        if getClipboard then
            local ok, value = pcall(getClipboard)
            if ok and type(value) == "string" then
                text = value
            end
        end
        local value = fromHex(text)
        if value then
            item:Set(value)
        else
            hex:CaptureFocus()
        end
    end)
    item:_Register(options.Flag, options.Default or Color3.fromRGB(74, 124, 255))
    return item
end

-- Global bindings ------------------------------------------------------------

function WindowMethods:Bind(options)
    options = option(options)
    local binding = {
        Key = keyCode(options.Key or options.Default),
        Mode = options.Mode == "Hold" and "Hold" or "Toggle",
        Callback = options.Callback,
        Active = false,
        Enabled = true,
    }
    self.Bindings[binding] = true
    local window = self
    function binding:Destroy()
        if self.Active and self.Mode == "Hold" then
            safe(self.Callback, false, self.Key)
        end
        self.Active = false
        self.Enabled = false
        window.Bindings[self] = nil
    end
    function binding:Set(key)
        if self.Active and self.Mode == "Hold" then
            safe(self.Callback, false, self.Key)
        end
        self.Active = false
        self.Key = keyCode(key)
    end
    return binding
end

function Midnight:Bind(options)
    local window = self.Windows[#self.Windows]
    assert(window, "Create a window before registering a global binding")
    return window:Bind(options)
end

-- 8. Notifications ------------------------------------------------------------

local function runtime()
    if Runtime then
        return Runtime
    end
    local scope = Scope.new()
    local gui = screen("MidnightNotifications", 10000)
    gui.Enabled = Midnight.Visible
    local holder = frame(scope, gui, {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -16, 0, 20),
        Size = UDim2.new(1, -32, 1, -40),
        BackgroundTransparency = 1,
    })
    local list = layout(holder, 10)
    list.HorizontalAlignment = Enum.HorizontalAlignment.Right
    Runtime = {
        Scope = scope,
        Gui = gui,
        Holder = holder,
        Count = 0,
        Handles = {},
    }
    return Runtime
end

function Midnight:Notify(options)
    options = option(options)
    local host = runtime()
    local scope = Scope.new(host.Scope)
    local duration = math.clamp(finite(options.Duration, 4), 0.5, 120)
    local tokens = {
        Info = "Accent",
        Success = "Secondary",
        Error = "Error",
        Warning = "Warning",
    }
    local token = tokens[options.Type] or "Accent"
    NotificationId = NotificationId + 1
    host.Count = host.Count + 1
    local width = math.min(328, math.max(180, host.Gui.AbsoluteSize.X - 32))
    local slot = frame(scope, host.Holder, {
        Name = "NotificationSlot",
        Size = UDim2.fromOffset(width, 100),
        BackgroundTransparency = 1,
        LayoutOrder = NotificationId,
    })
    local group = new("CanvasGroup", {
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromOffset(24, 0),
        BackgroundTransparency = 1,
        GroupTransparency = 1,
    }, slot)
    local card = frame(scope, group, {
        Position = UDim2.fromOffset(4, 4),
        Size = UDim2.new(1, -8, 1, -8),
    }, "Panel")
    corner(card, 10)
    stroke(scope, card, "Border", 0.45)
    local accent = frame(scope, card, {
        Position = UDim2.fromOffset(0, 12),
        Size = UDim2.new(0, 2, 1, -24),
        BackgroundTransparency = 0.05,
    }, token)
    corner(accent, 2)
    local badge = frame(scope, card, {
        Position = UDim2.fromOffset(12, 13),
        Size = UDim2.fromOffset(28, 28),
        BackgroundTransparency = 0.9,
    }, token)
    corner(badge, 8)
    icon(scope, badge, options.Type == "Success" and "Check" or "Bell", UDim2.fromOffset(5, 5), 18, token)
    label(scope, card, options.Title or "Notification", {
        Position = UDim2.fromOffset(50, 12),
        Size = UDim2.new(1, -84, 0, 21),
        Font = Enum.Font.GothamBold,
        TextSize = 12,
    })
    local message = label(scope, card, options.Content or "", {
        Position = UDim2.fromOffset(50, 36),
        Size = UDim2.new(1, -64, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextSize = 11,
    }, "Muted")
    local dismiss = button(scope, card, "", {
        Position = UDim2.new(1, -30, 0, 8),
        Size = UDim2.fromOffset(24, 24),
    })
    icon(scope, dismiss, "Close", UDim2.fromOffset(5, 5), 14, "Muted")
    local progressTrack = frame(scope, card, {
        Position = UDim2.new(0, 12, 1, -7),
        Size = UDim2.new(1, -24, 0, 2),
        BackgroundTransparency = 0.4,
    }, "Border")
    corner(progressTrack, 2)
    local progress = frame(scope, progressTrack, {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 0.1,
    }, token)
    corner(progress, 2)
    local function measure()
        slot.Size = UDim2.fromOffset(width, math.max(88, 36 + message.AbsoluteSize.Y + 26))
    end
    scope:Connect(message:GetPropertyChangedSignal("AbsoluteSize"), measure)
    scope:Connect(host.Gui:GetPropertyChangedSignal("AbsoluteSize"), function()
        width = math.min(328, math.max(180, host.Gui.AbsoluteSize.X - 32))
        measure()
    end)
    local handle = { Closed = false }
    function handle:Close()
        if self.Closed or not scope.Alive then
            return
        end
        self.Closed = true
        animate(scope, group, {
            Position = UDim2.fromOffset(24, 0),
            GroupTransparency = 1,
        }, 0.2)
        scope:Delay(0.21, function()
            animate(scope, slot, { Size = UDim2.fromOffset(width, 0) }, 0.18)
            scope:Delay(0.19, function()
                scope:Destroy()
                slot:Destroy()
                host.Count = host.Count - 1
                local index = table.find(host.Handles, self)
                if index then
                    table.remove(host.Handles, index)
                end
                if host.Count == 0 and Runtime == host then
                    host.Scope:Destroy()
                    host.Gui:Destroy()
                    Runtime = nil
                end
            end)
        end)
    end
    scope:Connect(dismiss.Activated, function()
        handle:Close()
    end)
    local paused = false
    local elapsed = 0
    scope:Connect(card.MouseEnter, function()
        paused = true
    end)
    scope:Connect(card.MouseLeave, function()
        paused = false
    end)
    scope:Connect(RunService.Heartbeat, function(delta)
        if handle.Closed then
            return
        end
        if not paused and Midnight.Visible then
            elapsed = elapsed + delta
        end
        local remaining = math.clamp(1 - elapsed / duration, 0, 1)
        progress.Size = UDim2.fromScale(remaining, 1)
        if remaining == 0 then
            handle:Close()
        end
    end)
    table.insert(host.Handles, handle)
    local live = 0
    for _, entry in ipairs(host.Handles) do
        if not entry.Closed then
            live = live + 1
        end
    end
    if live > 4 then
        for _, entry in ipairs(host.Handles) do
            if not entry.Closed then
                entry:Close()
                break
            end
        end
    end
    animate(scope, group, {
        Position = UDim2.fromOffset(0, 0),
        GroupTransparency = 0,
    }, 0.25)
    return handle
end

-- 9. Toasts and confirmation dialogs -----------------------------------------

function Midnight:Toast(content, duration)
    return self:Notify({
        Title = "Midnight UI",
        Content = tostring(content),
        Duration = duration or 3,
        Type = "Info",
    })
end

function WindowMethods:Confirm(options)
    options = option(options)
    if self.Destroyed then
        return nil
    end
    if self.Modal then
        self.Modal:Close(false)
    end
    releaseBindings(self)
    cancelCapture(self)
    if self.OpenPopover then
        self.OpenPopover:SetOpen(false)
    end
    self:SetMinimized(false)
    self:SetVisible(true)
    local scope = Scope.new(self.Scope)
    local overlay = new("CanvasGroup", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.35,
        GroupTransparency = 1,
        ZIndex = 50,
        Active = true,
    }, self.Shell)
    corner(overlay, 10)
    button(scope, overlay, "", { Size = UDim2.fromScale(1, 1), ZIndex = 1 })
    local panel = frame(scope, overlay, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.new(1, -36, 0, 210),
        ZIndex = 2,
    }, "Panel")
    corner(panel, 10)
    stroke(scope, panel, "Accent", 0.15)
    label(scope, panel, options.Title or "Confirm action", {
        Position = UDim2.fromOffset(16, 14),
        Size = UDim2.new(1, -32, 0, 28),
        Font = Enum.Font.GothamBold,
        TextSize = 16,
    })
    label(scope, panel, options.Content or "Do you want to continue?", {
        Position = UDim2.fromOffset(16, 51),
        Size = UDim2.new(1, -32, 0, 92),
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None,
        TextYAlignment = Enum.TextYAlignment.Top,
    }, "Muted")
    local cancel = button(scope, panel, options.CancelText or "Cancel", {
        Position = UDim2.new(0, 16, 1, -51),
        Size = UDim2.new(0.5, -22, 0, 36),
        BackgroundTransparency = 0,
    })
    local confirm = button(scope, panel, options.ConfirmText or "Confirm", {
        Position = UDim2.new(0.5, 6, 1, -51),
        Size = UDim2.new(0.5, -22, 0, 36),
        BackgroundTransparency = 0,
    })
    corner(cancel, 8)
    corner(confirm, 8)
    color(scope, cancel, "BackgroundColor3", "Raised")
    color(scope, confirm, "BackgroundColor3", "Accent")
    local window = self
    local modalScale = new("UIScale", { Scale = 0.97 }, panel)
    local handle = { Closed = false }
    function handle:Close(accepted)
        if self.Closed or not scope.Alive then
            return
        end
        self.Closed = true
        animate(scope, modalScale, { Scale = 0.97 }, 0.2)
        animate(scope, overlay, { GroupTransparency = 1 }, 0.2)
        scope:Delay(0.21, function()
            if window.Modal == self then
                window.Modal = nil
            end
            scope:Destroy()
            overlay:Destroy()
            if accepted then
                safe(options.OnConfirm)
            else
                safe(options.OnCancel)
            end
            safe(options.Callback, accepted == true)
        end)
    end
    self.Modal = handle
    scope:Connect(confirm.Activated, function()
        handle:Close(true)
    end)
    scope:Connect(cancel.Activated, function()
        handle:Close(false)
    end)
    animate(scope, overlay, { GroupTransparency = 0 }, 0.2)
    animate(scope, modalScale, { Scale = 1 }, 0.25)
    return handle
end

function Midnight:Confirm(options)
    local window = self.Windows[#self.Windows]
    assert(window, "Create a window before opening a confirmation dialog")
    return window:Confirm(options)
end

-- 10. Flags and lifecycle -----------------------------------------------------

function ControlMethods:_Commit(silent, changed)
    if self.Flag then
        Midnight.Flags[self.Flag] = copy(self.Value)
        self.Window.ConfigData[self.Flag] = copy(self.Value)
        if changed then
            self.Window:_ScheduleSave()
        end
    end
    if changed and not silent then
        safe(self.Callback, self:Get())
    end
end

function ControlMethods:_Register(flag, default)
    if flag ~= nil then
        assert(type(flag) == "string" and #flag > 0, "Flag must be a non-empty string")
        assert(not FlagOwners[flag], "Duplicate flag: " .. flag)
        self.Flag = flag
        FlagOwners[flag] = self
        self.Window.Controls[flag] = self
    end
    local saved = flag and self.Window.ConfigData[flag]
    self:Set(default, true)
    if saved ~= nil then
        self:Set(copy(saved), true)
    end
    if self.Options.FireOnInit then
        safe(self.Callback, self:Get())
    end
end

function Midnight:GetFlag(flag)
    return copy(self.Flags[flag])
end

function Midnight:SetFlag(flag, value, silent)
    local owner = FlagOwners[flag]
    if not owner then
        report("Unknown flag", flag)
        return false
    end
    owner:Set(value, silent)
    return true
end

function Midnight:SaveConfig()
    for _, window in ipairs(self.Windows) do
        window:SaveConfig()
    end
end

function Midnight:LoadConfig(fireCallbacks)
    for _, window in ipairs(self.Windows) do
        window:LoadConfig(fireCallbacks)
    end
end

function Midnight:Destroy()
    local windows = table.clone(self.Windows)
    for _, window in ipairs(windows) do
        window:Destroy()
    end
    if Runtime then
        Runtime.Scope:Destroy()
        Runtime.Gui:Destroy()
        Runtime = nil
    end
    table.clear(FlagOwners)
    table.clear(self.Flags)
end

return Midnight
