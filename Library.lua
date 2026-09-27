--[[
    Midnight UI Library
    Version: 1.0.0
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
    Version = "1.0.0",
    Flags = {},
    Windows = {},
    Visible = true,
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
    Panel = Color3.fromRGB(17, 24, 39),
    Raised = Color3.fromRGB(23, 32, 51),
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
    stroke(scope, result, "Border", 0.35)
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

local function animate(scope, object, goals, duration)
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
        local tween = TweenService:Create(object, TweenInfo.new(
            math.clamp(duration or 0.2, 0.15, 0.35),
            Enum.EasingStyle.Quart,
            Enum.EasingDirection.Out
        ), { [property] = value })
        channels[property] = tween
        tween:Play()
    end
end

local function hover(scope, object, outline)
    local over = false
    local function render()
        local theme = Midnight.Theme
        animate(scope, object, {
            BackgroundColor3 = over and theme.Raised or theme.Panel,
        })
        if outline then
            animate(scope, outline, {
                Transparency = over and 0.12 or 0.7,
            })
        end
    end
    scope:Connect(object.MouseEnter, function()
        over = true
        render()
    end)
    scope:Connect(object.MouseLeave, function()
        over = false
        render()
    end)
    themed(scope, function(theme)
        object.BackgroundColor3 = over and theme.Raised or theme.Panel
    end)
end

local function glow(scope, object)
    local lines = {}
    for index = 1, 3 do
        local halo = frame(scope, object, {
            Name = "Glow",
            Position = UDim2.fromOffset(-index * 3, -index * 3),
            Size = UDim2.new(1, index * 6, 1, index * 6),
            BackgroundTransparency = 1,
            ZIndex = object.ZIndex,
        })
        corner(halo, 10 + index * 2)
        lines[index] = stroke(scope, halo, "Accent", 0.88 + index * 0.025, 2)
    end
    return lines
end

-- 4. Pointer dragging: mouse and touch ---------------------------------------

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
        if not pointer(input) or active then
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
    self.ConfigData = values
    self.Loading = true
    for flag, control in pairs(self.Controls) do
        if values[flag] ~= nil then
            control:Set(copy(values[flag]), fireCallbacks ~= true)
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

local function installKeyboard(window)
    local scope = window.Scope
    scope:Connect(UserInputService.InputBegan, function(input, processed)
        local key = input.KeyCode
        if window.Capture then
            if key == Enum.KeyCode.Unknown then
                return
            end
            local control = window.Capture
            window.Capture = nil
            if key == Enum.KeyCode.Escape then
                control:Refresh()
            else
                control:Set(key == Enum.KeyCode.Backspace and Enum.KeyCode.Unknown or key)
            end
            return
        end
        if processed or UserInputService:GetFocusedTextBox() then
            return
        end
        if window.Modal then
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
    window.Gui.Enabled = self.Visible
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
    window.Scale = new("UIScale", { Scale = 0.94 }, window.Root)
    local shadow = frame(scope, window.Root, {
        Position = UDim2.fromOffset(9, 19),
        Size = UDim2.new(1, -18, 1, -25),
        BackgroundTransparency = 0.45,
    }, "Shadow")
    corner(shadow, 12)
    local shadowGradient = new("UIGradient", { Rotation = 90 }, shadow)
    shadowGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.7),
        NumberSequenceKeypoint.new(1, 0.2),
    })
    window.Shell = frame(scope, window.Root, {
        Position = UDim2.fromOffset(16, 16),
        Size = UDim2.new(1, -32, 1, -32),
        ZIndex = 2,
        ClipsDescendants = false,
    }, "Background")
    corner(window.Shell, 10)
    stroke(scope, window.Shell, "Border", 0.15)
    window.Glow = glow(scope, window.Shell)

    local title = frame(scope, window.Shell, {
        Size = UDim2.new(1, 0, 0, 54),
        BackgroundTransparency = 0.88,
        ZIndex = 3,
    }, "Text")
    corner(title, 10)
    gradient(scope, title)
    local titleHit = button(scope, title, "", {
        Size = UDim2.new(1, -92, 1, 0),
    })
    label(scope, titleHit, options.Title or "Midnight UI", {
        Position = UDim2.fromOffset(16, 6),
        Size = UDim2.new(1, -20, 0, 22),
        Font = Enum.Font.GothamBold,
        TextSize = 16,
    })
    label(scope, titleHit, options.SubTitle or "Made for the night", {
        Position = UDim2.fromOffset(16, 29),
        Size = UDim2.new(1, -20, 0, 17),
        TextSize = 11,
    }, "Muted")
    local minimize = button(scope, title, "−", {
        Position = UDim2.new(1, -84, 0, 7),
        Size = UDim2.fromOffset(36, 38),
        BackgroundTransparency = 0,
        TextSize = 22,
    })
    local close = button(scope, title, "×", {
        Position = UDim2.new(1, -44, 0, 7),
        Size = UDim2.fromOffset(36, 38),
        BackgroundTransparency = 0,
        TextSize = 22,
    })
    for _, item in ipairs({ minimize, close }) do
        corner(item, 8)
        hover(scope, item, stroke(scope, item, "Accent", 0.7))
    end
    scope:Connect(minimize.Activated, function()
        window:SetMinimized(not window.Minimized)
    end)
    scope:Connect(close.Activated, function()
        window:SetVisible(false)
    end)

    window.Body = frame(scope, window.Shell, {
        Position = UDim2.fromOffset(10, 64),
        Size = UDim2.new(1, -20, 1, -89),
        BackgroundTransparency = 1,
        ZIndex = 3,
    })
    local top = window.TabPosition == "Top"
    window.TabBar = new("ScrollingFrame", {
        Size = top and UDim2.new(1, 0, 0, 38) or UDim2.new(0, 132, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = top and Enum.AutomaticSize.X or Enum.AutomaticSize.Y,
        ScrollingDirection = top and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y,
        ScrollBarThickness = 2,
    }, window.Body)
    color(scope, window.TabBar, "ScrollBarImageColor3", "Accent")
    layout(window.TabBar, 6, top and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical)
    window.Pages = frame(scope, window.Body, {
        Position = top and UDim2.fromOffset(0, 46) or UDim2.fromOffset(142, 0),
        Size = top and UDim2.new(1, 0, 1, -46) or UDim2.new(1, -142, 1, 0),
        BackgroundTransparency = 1,
    })
    window.Watermark = label(scope, window.Shell, "Midnight UI", {
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -24, 1, -5),
        Size = UDim2.fromOffset(110, 16),
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex = 3,
    }, "Muted")
    window.ResizeHandle = button(scope, window.Shell, "⋱", {
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.fromScale(1, 1),
        Size = UDim2.fromOffset(28, 28),
        TextSize = 22,
        ZIndex = 5,
    })
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
                BackgroundTransparency = random:NextNumber(0.8, 0.95),
                ZIndex = 2,
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
        if window.Visible and Midnight.Visible then
            for index, line in ipairs(window.Glow) do
                animate(scope, line, {
                    Transparency = (bright and 0.82 or 0.89) + index * 0.025,
                }, 0.35)
            end
        end
        scope:Delay(1.2, pulse)
    end
    pulse()
    animate(scope, window.Root, { GroupTransparency = 0 }, 0.3)
    animate(scope, window.Scale, { Scale = 1 }, 0.3)
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
    self.Root.Size = UDim2.fromOffset(width + 32, (self.Minimized and 54 or height) + 32)
end

function WindowMethods:SetVisible(visible)
    if self.Destroyed then
        return
    end
    self.Visible = visible == true
    self.Scope:Cancel(self.HideJob)
    if self.Visible then
        self.Root.Visible = true
        animate(self.Scope, self.Root, { GroupTransparency = 0 }, 0.25)
        animate(self.Scope, self.Scale, { Scale = 1 }, 0.25)
    else
        releaseBindings(self)
        if self.Capture then
            local capture = self.Capture
            self.Capture = nil
            capture:Refresh()
        end
        animate(self.Scope, self.Root, { GroupTransparency = 1 }, 0.2)
        animate(self.Scope, self.Scale, { Scale = 0.96 }, 0.2)
        self.HideJob = self.Scope:Delay(0.21, function()
            self.Root.Visible = false
        end)
    end
end

function WindowMethods:SetMinimized(minimized)
    if self.Destroyed then
        return
    end
    self.Minimized = minimized == true
    self.Body.Visible = not self.Minimized
    self.ResizeHandle.Visible = not self.Minimized
    self.Watermark.Visible = not self.Minimized
    animate(self.Scope, self.Root, {
        Size = UDim2.fromOffset(self.FullSize.X + 32, (self.Minimized and 54 or self.FullSize.Y) + 32),
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
    self.Visible = value == nil and not self.Visible or value == true
    for _, window in ipairs(self.Windows) do
        window.Gui.Enabled = self.Visible
        if not self.Visible then
            releaseBindings(window)
        end
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
    local top = self.TabPosition == "Top"
    tab.Button = button(scope, self.TabBar, "", {
        Size = top and UDim2.fromOffset(126, 36) or UDim2.new(1, -4, 0, 40),
        BackgroundTransparency = 0,
        LayoutOrder = #self.Tabs + 1,
    })
    corner(tab.Button, 8)
    local outline = stroke(scope, tab.Button, "Accent", 0.85)
    local text = (options.Icon and tostring(options.Icon) .. "  " or "")
        .. (options.Title or "Tab")
    local caption = label(scope, tab.Button, text, {
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(1, -20, 1, 0),
        TextSize = 12,
    })
    local indicator = frame(scope, tab.Button, {
        Position = UDim2.fromOffset(0, 8),
        Size = UDim2.new(0, 3, 1, -16),
    }, "Accent")
    corner(indicator, 3)
    tab.Content = new("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 3,
        ScrollBarImageTransparency = 0.25,
        Visible = false,
    }, self.Pages)
    color(scope, tab.Content, "ScrollBarImageColor3", "Accent")
    padding(tab.Content, 4)
    layout(tab.Content, 8)
    function tab:Refresh()
        local selected = self.Window.SelectedTab == self
        self.Content.Visible = selected
        indicator.Visible = selected
        outline.Transparency = selected and 0.28 or 0.88
        self.Button.BackgroundColor3 = selected and Midnight.Theme.Raised or Midnight.Theme.Panel
        caption.TextColor3 = selected and Midnight.Theme.Text or Midnight.Theme.Muted
    end
    function tab:Select()
        self.Window.SelectedTab = self
        for _, item in ipairs(self.Window.Tabs) do
            item:Refresh()
        end
    end
    themed(scope, function()
        tab:Refresh()
    end)
    scope:Connect(tab.Button.Activated, function()
        tab:Select()
    end)
    table.insert(self.Tabs, tab)
    if #self.Tabs == 1 then
        tab:Select()
    else
        tab:Refresh()
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
    local outline = stroke(scope, object, "Border", 0.7)
    return scope, object, outline
end

local function captions(scope, object, options, reserve)
    local hasDescription = options.Description and options.Description ~= ""
    local title = label(scope, object, options.Title or "Control", {
        Position = UDim2.fromOffset(12, hasDescription and 7 or 0),
        Size = UDim2.new(1, -(reserve or 24), 0, hasDescription and 21 or 44),
        Font = Enum.Font.GothamMedium,
    })
    local description
    if hasDescription then
        description = label(scope, object, options.Description, {
            Position = UDim2.fromOffset(12, 28),
            Size = UDim2.new(1, -24, 0, 19),
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
    self.Disabled = disabled == true
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
    local scope, root = row(self, 40)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.Size = UDim2.new(1, -6, 0, 0)
    root.BackgroundTransparency = 1
    local header = button(scope, root, "", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundTransparency = 0,
    })
    corner(header, 8)
    color(scope, header, "BackgroundColor3", "Raised")
    label(scope, header, options.Title or "Section", {
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -44, 1, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 12,
    })
    local arrow = label(scope, header, "−", {
        Position = UDim2.new(1, -30, 0, 0),
        Size = UDim2.fromOffset(24, 36),
        TextXAlignment = Enum.TextXAlignment.Center,
    }, "Accent")
    local content = frame(scope, root, {
        Position = UDim2.fromOffset(0, 44),
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    })
    layout(content, 8)
    local section = setmetatable({
        Window = self.Window,
        Scope = scope,
        Content = content,
        Root = root,
        Order = 0,
        Collapsed = false,
    }, { __index = ContainerMethods })
    function section:SetCollapsed(value)
        self.Collapsed = value == true
        content.Visible = not self.Collapsed
        root.AutomaticSize = self.Collapsed and Enum.AutomaticSize.None or Enum.AutomaticSize.Y
        root.Size = UDim2.new(1, -6, 0, self.Collapsed and 36 or 0)
        content.Position = UDim2.fromOffset(0, self.Collapsed and 36 or 44)
        arrow.Text = self.Collapsed and "+" or "−"
    end
    scope:Connect(header.Activated, function()
        if options.Collapsible ~= false then
            section:SetCollapsed(not section.Collapsed)
        end
    end)
    section:SetCollapsed(options.Collapsed == true)
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
    item.Value = title.Text
    return item
end

ContainerMethods.Paragraph = ContainerMethods.Label

-- Buttons --------------------------------------------------------------------

function ContainerMethods:Button(options)
    options = option(options)
    local item, scope, root = control(self, options, options.Description and 58 or 44)
    captions(scope, root, options, 48)
    local symbol = label(scope, root, "›", {
        Position = UDim2.new(1, -32, 0, 0),
        Size = UDim2.fromOffset(24, 44),
        TextSize = 22,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, "Accent")
    local hit = button(scope, root, "", { Size = UDim2.fromScale(1, 1) })
    local scale = new("UIScale", { Scale = 1 }, symbol)
    hover(scope, root, item.Outline)
    scope:Connect(hit.InputBegan, function(input)
        if pointer(input) and not item.Disabled then
            animate(scope, scale, { Scale = 0.8 }, 0.15)
        end
    end)
    scope:Connect(hit.InputEnded, function(input)
        if pointer(input) then
            animate(scope, scale, { Scale = 1 }, 0.15)
        end
    end)
    function item:Press()
        if self.Scope.Alive and not self.Disabled then
            safe(self.Callback)
        end
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
    local baseHeight = options.Description and 94 or 76
    local item, scope, root = control(self, options, baseHeight)
    captions(scope, root, options)
    item.Multi = options.Multi == true
    item.Items = stringOptions(options.Options or options.Values)
    item.Open = false
    local selected = button(scope, root, "Select...", {
        Position = UDim2.fromOffset(12, baseHeight - 38),
        Size = UDim2.new(1, -24, 0, 30),
        BackgroundTransparency = 0,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextSize = 12,
    })
    corner(selected, 6)
    padding(selected, 8)
    color(scope, selected, "BackgroundColor3", "Background")
    stroke(scope, selected, "Accent", 0.65)
    local panel = frame(scope, root, {
        Position = UDim2.fromOffset(12, baseHeight),
        Size = UDim2.new(1, -24, 0, 178),
        BackgroundTransparency = 1,
        Visible = false,
    })
    local searchable = options.Searchable ~= false
    local search = textBox(scope, panel, "Search options...", {
        Size = UDim2.new(1, 0, 0, 30),
        Visible = searchable,
    })
    local list = new("ScrollingFrame", {
        Position = UDim2.fromOffset(0, searchable and 36 or 0),
        Size = UDim2.new(1, 0, 1, searchable and -36 or 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, panel)
    color(scope, list, "ScrollBarImageColor3", "Accent")
    layout(list, 4)
    local listScope
    local entries = {}
    function item:Refresh()
        if self.Multi then
            selected.Text = #self.Value > 0 and table.concat(self.Value, ", ") or "Select..."
        else
            selected.Text = self.Value ~= "" and self.Value or "Select..."
        end
        for value, entry in pairs(entries) do
            local active = self.Multi and table.find(self.Value, value) ~= nil or self.Value == value
            entry.Text = (active and "✓  " or "    ") .. value
            entry.TextColor3 = active and Midnight.Theme.Accent or Midnight.Theme.Text
            entry.BackgroundColor3 = active and Midnight.Theme.Raised or Midnight.Theme.Panel
        end
    end
    function item:SetOpen(value)
        self.Open = value == true
        panel.Visible = self.Open
        animate(scope, root, {
            Size = UDim2.new(1, -6, 0, baseHeight + (self.Open and 190 or 0)),
        })
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
        local old = self.Multi and table.concat(self.Value or {}, "\0") or self.Value
        local current = self.Multi and table.concat(nextValue, "\0") or nextValue
        self.Value = nextValue
        self:Refresh()
        self:_Commit(silent, old ~= current)
        return self
    end
    local function build()
        if listScope then
            listScope:Destroy()
        end
        for _, entry in pairs(entries) do
            entry:Destroy()
        end
        entries = {}
        listScope = Scope.new(scope)
        local query = string.lower(search.Text)
        for index, value in ipairs(item.Items) do
            local entry = button(listScope, list, value, {
                Size = UDim2.new(1, -6, 0, 32),
                BackgroundTransparency = 0,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextSize = 12,
                LayoutOrder = index,
                Visible = string.find(string.lower(value), query, 1, true) ~= nil,
            })
            corner(entry, 6)
            entries[value] = entry
            listScope:Connect(entry.Activated, function()
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
            item:Refresh()
        end)
    end
    function item:SetOptions(values)
        self.Items = stringOptions(values)
        self:Set(self.Value, true)
        build()
        return self
    end
    scope:Connect(search:GetPropertyChangedSignal("Text"), function()
        local query = string.lower(search.Text)
        for value, entry in pairs(entries) do
            entry.Visible = string.find(string.lower(value), query, 1, true) ~= nil
        end
        list.CanvasPosition = Vector2.zero
    end)
    scope:Connect(selected.Activated, function()
        if not item.Disabled then
            item:SetOpen(not item.Open)
        end
    end)
    item.Value = item.Multi and {} or ""
    themed(scope, function()
        item:Refresh()
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
    stroke(scope, keyButton, "Accent", 0.6)
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
        keyButton.Text = self.Window.Capture == self and "Press a key..."
            or (self.Value == Enum.KeyCode.Unknown and "None" or self.Value.Name)
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
        local previous = item.Window.Capture
        item.Window.Capture = item
        if previous and previous ~= item then
            previous:Refresh()
        end
        item:Refresh()
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
        self.Open = open == true
        panel.Visible = self.Open
        animate(scope, root, {
            Size = UDim2.new(1, -6, 0, baseHeight + (self.Open and 278 or 0)),
        })
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
    local slot = frame(scope, host.Holder, {
        Size = UDim2.new(0, math.min(320, math.max(180, host.Gui.AbsoluteSize.X - 32)), 0, 100),
        BackgroundTransparency = 1,
        LayoutOrder = NotificationId,
    })
    local group = new("CanvasGroup", {
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromOffset(30, 0),
        BackgroundTransparency = 1,
        GroupTransparency = 1,
    }, slot)
    local card = frame(scope, group, {
        Position = UDim2.fromOffset(4, 4),
        Size = UDim2.new(1, -8, 1, -8),
    }, "Panel")
    corner(card, 10)
    stroke(scope, card, token, 0.15, 1.5)
    local tint = frame(scope, card, {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 0.94,
    }, token)
    corner(tint, 10)
    label(scope, card, options.Title or "Notification", {
        Position = UDim2.fromOffset(12, 9),
        Size = UDim2.new(1, -45, 0, 20),
        Font = Enum.Font.GothamBold,
    })
    label(scope, card, options.Content or "", {
        Position = UDim2.fromOffset(12, 32),
        Size = UDim2.new(1, -24, 0, 46),
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextSize = 12,
    }, "Muted")
    local dismiss = button(scope, card, "×", {
        Position = UDim2.new(1, -32, 0, 4),
        Size = UDim2.fromOffset(28, 28),
        TextSize = 18,
    })
    local progress = frame(scope, card, {
        Position = UDim2.new(0, 8, 1, -5),
        Size = UDim2.new(1, -16, 0, 2),
    }, token)
    corner(progress, 2)
    local handle = { Closed = false }
    function handle:Close()
        if self.Closed or not scope.Alive then
            return
        end
        self.Closed = true
        animate(scope, group, {
            Position = UDim2.fromOffset(30, 0),
            GroupTransparency = 1,
        }, 0.2)
        scope:Delay(0.22, function()
            scope:Destroy()
            slot:Destroy()
            host.Count = host.Count - 1
            if host.Count == 0 and Runtime == host then
                host.Scope:Destroy()
                host.Gui:Destroy()
                Runtime = nil
            end
        end)
    end
    scope:Connect(dismiss.Activated, function()
        handle:Close()
    end)
    local started = os.clock()
    -- Duration tracking is not a tween; all visual easing uses animate().
    scope:Connect(RunService.Heartbeat, function()
        if handle.Closed then
            return
        end
        local remaining = math.clamp(1 - (os.clock() - started) / duration, 0, 1)
        progress.Size = UDim2.new(remaining, -16 * remaining, 0, 2)
        if remaining == 0 then
            handle:Close()
        end
    end)
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
    local handle = { Closed = false }
    function handle:Close(accepted)
        if self.Closed or not scope.Alive then
            return
        end
        self.Closed = true
        if window.Modal == self then
            window.Modal = nil
        end
        animate(scope, overlay, { GroupTransparency = 1 }, 0.2)
        scope:Delay(0.21, function()
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
