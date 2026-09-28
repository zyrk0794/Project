--[[
    Midnight UI Library
    Version: 2.2.2
    Credits: Original
    Date: 2026-09-28
    License: MIT
]]

-- 1. Services and utilities ----------------------------------------------------

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Midnight = {
    Version = "2.2.2",
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

local InstanceNames = setmetatable({}, { __mode = "k" })
local DefaultNames = {
    Frame = "Surface", CanvasGroup = "TransitionLayer", TextLabel = "Caption",
    TextButton = "Action", TextBox = "Input", ImageLabel = "Icon",
    ScrollingFrame = "ScrollRegion", UICorner = "CornerRadius", UIStroke = "Border",
    UIGradient = "ColorGradient", UIListLayout = "ContentLayout", UIPadding = "ContentPadding",
    UIScale = "AnimationScale", UISizeConstraint = "SizeLimits", ScreenGui = "MidnightScreen",
}
local function new(className, properties, parent)
    local object = Instance.new(className)
    local baseName = properties and properties.Name or DefaultNames[className] or ("Midnight" .. className)
    if parent then
        local names = InstanceNames[parent] or {}
        InstanceNames[parent] = names
        names[baseName] = (names[baseName] or 0) + 1
        object.Name = baseName .. (names[baseName] > 1 and tostring(names[baseName]) or "")
    else
        object.Name = baseName
    end
    for key, value in pairs(properties or {}) do
        if key ~= "Name" then
            object[key] = value
        end
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

-- Contrast is computed in linear sRGB; saved colors remain unmodified.
local function luminance(value)
    local function linear(channel)
        return channel <= 0.04045 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4
    end
    return 0.2126 * linear(value.R) + 0.7152 * linear(value.G) + 0.0722 * linear(value.B)
end

local function contrast(a, b)
    local x, y = luminance(a), luminance(b)
    return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end

local function readable(value, surfaces, ratio)
    local function score(candidate)
        local minimum = math.huge
        for _, surface in ipairs(surfaces) do
            minimum = math.min(minimum, contrast(candidate, surface))
        end
        return minimum
    end
    if score(value) >= ratio then return value end
    local black, white = Color3.new(0, 0, 0), Color3.new(1, 1, 1)
    local target = score(black) > score(white) and black or white
    for step = 1, 100 do
        local candidate = value:Lerp(target, step / 100)
        if score(candidate) >= ratio then return candidate end
    end
    return target
end

local function resolveTheme(requested)
    local theme = copy(requested)
    local light = luminance(theme.Background) >= 0.179
    local opposite = light and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
    for _, token in ipairs({ "Panel", "Raised" }) do
        -- Keep shared text roles usable on all nested surfaces.
        if (luminance(theme[token]) >= 0.179) ~= light then
            theme[token] = theme.Background:Lerp(opposite, token == "Panel" and 0.035 or 0.08)
        end
        theme[token] = readable(theme[token], { opposite }, 4.5)
    end
    local surfaces = { theme.Background, theme.Panel, theme.Raised }
    theme.Text = readable(theme.Text, surfaces, 4.5)
    theme.Muted = readable(theme.Muted, surfaces, 4.5)
    for _, token in ipairs({ "Accent", "Secondary", "Error", "Warning" }) do
        theme[token] = readable(theme[token], surfaces, 3)
    end
    theme.OnAccent = readable(theme.Text, { theme.Accent }, 4.5)
    theme.Border = readable(theme.Border, surfaces, 1.4)
    theme.IsLight = light
    return theme
end

local ThemePresets = { Midnight = copy(DefaultTheme) }
local function preset(name, background, accent, secondary)
    local values = copy(DefaultTheme)
    values.Background = Color3.fromRGB(table.unpack(background))
    local light = luminance(values.Background) >= 0.179
    local opposite = light and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
    values.Panel = values.Background:Lerp(opposite, 0.035)
    values.Raised = values.Background:Lerp(opposite, 0.08)
    values.Border = values.Background:Lerp(opposite, 0.2)
    values.Accent = Color3.fromRGB(table.unpack(accent))
    values.Secondary = Color3.fromRGB(table.unpack(secondary))
    values.Text = light and Color3.fromRGB(24, 29, 39) or DefaultTheme.Text
    values.Muted = light and Color3.fromRGB(83, 92, 108) or DefaultTheme.Muted
    ThemePresets[name] = values
end
preset("Amethyst", { 16, 11, 27 }, { 165, 122, 255 }, { 222, 132, 238 })
preset("Glacier", { 8, 18, 27 }, { 94, 208, 238 }, { 105, 146, 255 })
preset("Emerald", { 8, 20, 18 }, { 69, 211, 157 }, { 69, 178, 205 })
preset("Rose", { 25, 12, 20 }, { 246, 128, 176 }, { 178, 135, 252 })
preset("Ember", { 24, 15, 10 }, { 249, 167, 91 }, { 234, 108, 118 })
preset("Graphite", { 16, 17, 20 }, { 197, 204, 220 }, { 153, 164, 189 })
preset("Snow", { 246, 248, 252 }, { 55, 96, 217 }, { 121, 65, 197 })
preset("Ivory", { 249, 246, 238 }, { 110, 88, 190 }, { 168, 98, 50 })

Midnight.CustomThemes = {}
Midnight.ThemeName = "Midnight"
Midnight.RequestedTheme = copy(DefaultTheme)
Midnight.Theme = resolveTheme(DefaultTheme)

function Midnight:GetTheme(requested)
    return copy(requested and self.RequestedTheme or self.Theme)
end

function Midnight:ListThemes()
    local names = {}
    for name in pairs(ThemePresets) do table.insert(names, name) end
    for name in pairs(self.CustomThemes) do
        if not ThemePresets[name] then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

function Midnight:GetThemePreset(name)
    local theme = ThemePresets[name] or self.CustomThemes[name]
    return theme and copy(theme) or nil
end

function Midnight:GetContrast(a, b)
    return contrast(a, b)
end


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
        TextTruncate = Enum.TextTruncate.AtEnd,
        ClipsDescendants = true,
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
    local name = type(values) == "string" and values or nil
    if name then
        values = ThemePresets[name] or self.CustomThemes[name]
        if not values then
            return false, "Unknown theme"
        end
        self.RequestedTheme = copy(DefaultTheme)
        self.ThemeName = name
    elseif type(values) ~= "table" then
        return false, "Expected a theme name or color table"
    else
        self.ThemeName = "Custom"
    end
    for key, value in pairs(values) do
        if DefaultTheme[key] and typeof(value) == "Color3" then
            self.RequestedTheme[key] = value
        end
    end
    -- Changing only the canvas color derives matching surfaces automatically.
    if typeof(values.Background) == "Color3" then
        local base = values.Background
        local light = luminance(base) >= 0.179
        local mix = light and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
        if not values.Panel then self.RequestedTheme.Panel = base:Lerp(mix, 0.035) end
        if not values.Raised then self.RequestedTheme.Raised = base:Lerp(mix, 0.08) end
        if not values.Border then self.RequestedTheme.Border = base:Lerp(mix, 0.2) end
    end
    self.Theme = resolveTheme(self.RequestedTheme)
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
        local base = settings.Primary and theme.Panel:Lerp(theme.Accent, 0.08) or theme.Panel
        local goals = {
            BackgroundColor3 = active and base:Lerp(theme.Raised, 0.8) or base,
        }
        -- Hover changes the surface only. Borders never light up on hover.
        if immediate then
            object.BackgroundColor3 = goals.BackgroundColor3
        else
            animate(scope, object, goals, 0.18)
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

local LucideAtlas = {
    ["a-arrow-down"] = { 16898612629, 771, 0 },
    ["a-arrow-up"] = { 16898612629, 0, 771 },
    ["a-large-small"] = { 16898612629, 771, 257 },
    ["accessibility"] = { 16898612629, 257, 771 },
    ["activity-square"] = { 16898612629, 771, 514 },
    ["activity"] = { 16898612629, 514, 771 },
    ["air-vent"] = { 16898612629, 820, 0 },
    ["airplay"] = { 16898612629, 771, 49 },
    ["alarm-check"] = { 16898612629, 49, 771 },
    ["alarm-clock-check"] = { 16898612629, 0, 820 },
    ["alarm-clock-minus"] = { 16898612629, 820, 257 },
    ["alarm-clock-off"] = { 16898612629, 771, 306 },
    ["alarm-clock-plus"] = { 16898612629, 306, 771 },
    ["alarm-clock"] = { 16898612629, 257, 820 },
    ["alarm-minus"] = { 16898612629, 820, 514 },
    ["alarm-plus"] = { 16898612629, 771, 563 },
    ["alarm-smoke"] = { 16898612629, 563, 771 },
    ["album"] = { 16898612629, 514, 820 },
    ["alert-circle"] = { 16898612629, 869, 0 },
    ["alert-octagon"] = { 16898612629, 820, 49 },
    ["alert-triangle"] = { 16898612629, 771, 98 },
    ["align-center-horizontal"] = { 16898612629, 98, 771 },
    ["align-center-vertical"] = { 16898612629, 49, 820 },
    ["align-center"] = { 16898612629, 0, 869 },
    ["align-end-horizontal"] = { 16898612629, 869, 257 },
    ["align-end-vertical"] = { 16898612629, 820, 306 },
    ["align-horizontal-distribute-center"] = { 16898612629, 771, 355 },
    ["align-horizontal-distribute-end"] = { 16898612629, 355, 771 },
    ["align-horizontal-distribute-start"] = { 16898612629, 306, 820 },
    ["align-horizontal-justify-center"] = { 16898612629, 257, 869 },
    ["align-horizontal-justify-end"] = { 16898612629, 869, 514 },
    ["align-horizontal-justify-start"] = { 16898612629, 820, 563 },
    ["align-horizontal-space-around"] = { 16898612629, 771, 612 },
    ["align-horizontal-space-between"] = { 16898612629, 612, 771 },
    ["align-justify"] = { 16898612629, 563, 820 },
    ["align-left"] = { 16898612629, 514, 869 },
    ["align-right"] = { 16898612629, 918, 0 },
    ["align-start-horizontal"] = { 16898612629, 869, 49 },
    ["align-start-vertical"] = { 16898612629, 820, 98 },
    ["align-vertical-distribute-center"] = { 16898612629, 771, 147 },
    ["align-vertical-distribute-end"] = { 16898612629, 147, 771 },
    ["align-vertical-distribute-start"] = { 16898612629, 98, 820 },
    ["align-vertical-justify-center"] = { 16898612629, 49, 869 },
    ["align-vertical-justify-end"] = { 16898612629, 0, 918 },
    ["align-vertical-justify-start"] = { 16898612629, 918, 257 },
    ["align-vertical-space-around"] = { 16898612629, 869, 306 },
    ["align-vertical-space-between"] = { 16898612629, 820, 355 },
    ["ambulance"] = { 16898612629, 771, 404 },
    ["ampersand"] = { 16898612629, 404, 771 },
    ["ampersands"] = { 16898612629, 355, 820 },
    ["anchor"] = { 16898612629, 306, 869 },
    ["angry"] = { 16898612629, 257, 918 },
    ["annoyed"] = { 16898612629, 918, 514 },
    ["antenna"] = { 16898612629, 869, 563 },
    ["anvil"] = { 16898612629, 820, 612 },
    ["aperture"] = { 16898612629, 771, 661 },
    ["app-window-mac"] = { 16898612629, 661, 771 },
    ["app-window"] = { 16898612629, 612, 820 },
    ["apple"] = { 16898612629, 563, 869 },
    ["archive-restore"] = { 16898612629, 514, 918 },
    ["archive-x"] = { 16898612629, 967, 0 },
    ["archive"] = { 16898612629, 918, 49 },
    ["area-chart"] = { 16898612629, 869, 98 },
    ["armchair"] = { 16898612629, 820, 147 },
    ["arrow-big-down-dash"] = { 16898612629, 771, 196 },
    ["arrow-big-down"] = { 16898612629, 196, 771 },
    ["arrow-big-left-dash"] = { 16898612629, 147, 820 },
    ["arrow-big-left"] = { 16898612629, 98, 869 },
    ["arrow-big-right-dash"] = { 16898612629, 49, 918 },
    ["arrow-big-right"] = { 16898612629, 0, 967 },
    ["arrow-big-up-dash"] = { 16898612629, 967, 257 },
    ["arrow-big-up"] = { 16898612629, 918, 306 },
    ["arrow-down-0-1"] = { 16898612629, 869, 355 },
    ["arrow-down-1-0"] = { 16898612629, 820, 404 },
    ["arrow-down-a-z"] = { 16898612629, 771, 453 },
    ["arrow-down-circle"] = { 16898612629, 453, 771 },
    ["arrow-down-from-line"] = { 16898612629, 404, 820 },
    ["arrow-down-left-from-circle"] = { 16898612629, 355, 869 },
    ["arrow-down-left-square"] = { 16898612629, 306, 918 },
    ["arrow-down-left"] = { 16898612629, 257, 967 },
    ["arrow-down-narrow-wide"] = { 16898612629, 967, 514 },
    ["arrow-down-right-from-circle"] = { 16898612629, 918, 563 },
    ["arrow-down-right-square"] = { 16898612629, 869, 612 },
    ["arrow-down-right"] = { 16898612629, 820, 661 },
    ["arrow-down-square"] = { 16898612629, 771, 710 },
    ["arrow-down-to-dot"] = { 16898612629, 710, 771 },
    ["arrow-down-to-line"] = { 16898612629, 661, 820 },
    ["arrow-down-up"] = { 16898612629, 612, 869 },
    ["arrow-down-wide-narrow"] = { 16898612629, 563, 918 },
    ["arrow-down-z-a"] = { 16898612629, 514, 967 },
    ["arrow-down"] = { 16898612629, 967, 49 },
    ["arrow-left-circle"] = { 16898612629, 918, 98 },
    ["arrow-left-from-line"] = { 16898612629, 869, 147 },
    ["arrow-left-right"] = { 16898612629, 820, 196 },
    ["arrow-left-square"] = { 16898612629, 196, 820 },
    ["arrow-left-to-line"] = { 16898612629, 147, 869 },
    ["arrow-left"] = { 16898612629, 98, 918 },
    ["arrow-right-circle"] = { 16898612629, 49, 967 },
    ["arrow-right-from-line"] = { 16898612629, 967, 306 },
    ["arrow-right-left"] = { 16898612629, 918, 355 },
    ["arrow-right-square"] = { 16898612629, 869, 404 },
    ["arrow-right-to-line"] = { 16898612629, 820, 453 },
    ["arrow-right"] = { 16898612629, 453, 820 },
    ["arrow-up-0-1"] = { 16898612629, 404, 869 },
    ["arrow-up-1-0"] = { 16898612629, 355, 918 },
    ["arrow-up-a-z"] = { 16898612629, 306, 967 },
    ["arrow-up-circle"] = { 16898612629, 967, 563 },
    ["arrow-up-down"] = { 16898612629, 918, 612 },
    ["arrow-up-from-dot"] = { 16898612629, 869, 661 },
    ["arrow-up-from-line"] = { 16898612629, 820, 710 },
    ["arrow-up-left-from-circle"] = { 16898612629, 771, 759 },
    ["arrow-up-left-square"] = { 16898612629, 710, 820 },
    ["arrow-up-left"] = { 16898612629, 661, 869 },
    ["arrow-up-narrow-wide"] = { 16898612629, 612, 918 },
    ["arrow-up-right-from-circle"] = { 16898612629, 563, 967 },
    ["arrow-up-right-square"] = { 16898612629, 967, 98 },
    ["arrow-up-right"] = { 16898612629, 918, 147 },
    ["arrow-up-square"] = { 16898612629, 869, 196 },
    ["arrow-up-to-line"] = { 16898612629, 196, 869 },
    ["arrow-up-wide-narrow"] = { 16898612629, 147, 918 },
    ["arrow-up-z-a"] = { 16898612629, 98, 967 },
    ["arrow-up"] = { 16898612629, 967, 355 },
    ["arrows-up-from-line"] = { 16898612629, 918, 404 },
    ["asterisk"] = { 16898612629, 869, 453 },
    ["at-sign"] = { 16898612629, 453, 869 },
    ["atom"] = { 16898612629, 404, 918 },
    ["audio-lines"] = { 16898612629, 355, 967 },
    ["audio-waveform"] = { 16898612629, 967, 612 },
    ["award"] = { 16898612629, 918, 661 },
    ["axe"] = { 16898612629, 869, 710 },
    ["axis-3d"] = { 16898612629, 820, 759 },
    ["baby"] = { 16898612629, 771, 808 },
    ["backpack"] = { 16898612629, 710, 869 },
    ["badge-alert"] = { 16898612629, 661, 918 },
    ["badge-cent"] = { 16898612629, 612, 967 },
    ["badge-check"] = { 16898612629, 967, 147 },
    ["badge-dollar-sign"] = { 16898612629, 918, 196 },
    ["badge-euro"] = { 16898612629, 196, 918 },
    ["badge-help"] = { 16898612629, 147, 967 },
    ["badge-indian-rupee"] = { 16898612629, 967, 404 },
    ["badge-info"] = { 16898612629, 918, 453 },
    ["badge-japanese-yen"] = { 16898612629, 453, 918 },
    ["badge-minus"] = { 16898612629, 404, 967 },
    ["badge-percent"] = { 16898612629, 967, 661 },
    ["badge-plus"] = { 16898612629, 918, 710 },
    ["badge-pound-sterling"] = { 16898612629, 869, 759 },
    ["badge-russian-ruble"] = { 16898612629, 820, 808 },
    ["badge-swiss-franc"] = { 16898612629, 771, 857 },
    ["badge-x"] = { 16898612629, 710, 918 },
    ["badge"] = { 16898612629, 661, 967 },
    ["baggage-claim"] = { 16898612629, 967, 196 },
    ["ban"] = { 16898612629, 196, 967 },
    ["banana"] = { 16898612629, 967, 453 },
    ["banknote"] = { 16898612629, 453, 967 },
    ["bar-chart-2"] = { 16898612629, 967, 710 },
    ["bar-chart-3"] = { 16898612629, 918, 759 },
    ["bar-chart-4"] = { 16898612629, 869, 808 },
    ["bar-chart-big"] = { 16898612629, 820, 857 },
    ["bar-chart-horizontal-big"] = { 16898612629, 771, 906 },
    ["bar-chart-horizontal"] = { 16898612629, 710, 967 },
    ["bar-chart"] = { 16898612629, 967, 759 },
    ["barcode"] = { 16898612629, 918, 808 },
    ["baseline"] = { 16898612629, 869, 857 },
    ["bath"] = { 16898612629, 820, 906 },
    ["battery-charging"] = { 16898612629, 771, 955 },
    ["battery-full"] = { 16898612629, 967, 808 },
    ["battery-low"] = { 16898612629, 918, 857 },
    ["battery-medium"] = { 16898612629, 869, 906 },
    ["battery-warning"] = { 16898612629, 820, 955 },
    ["battery"] = { 16898612629, 967, 857 },
    ["beaker"] = { 16898612629, 918, 906 },
    ["bean-off"] = { 16898612629, 869, 955 },
    ["bean"] = { 16898612629, 967, 906 },
    ["bed-double"] = { 16898612629, 918, 955 },
    ["bed-single"] = { 16898612629, 967, 955 },
    ["bed"] = { 16898612819, 771, 0 },
    ["beef"] = { 16898612819, 0, 771 },
    ["beer-off"] = { 16898612819, 771, 257 },
    ["beer"] = { 16898612819, 257, 771 },
    ["bell-dot"] = { 16898612819, 771, 514 },
    ["bell-electric"] = { 16898612819, 514, 771 },
    ["bell-minus"] = { 16898612819, 820, 0 },
    ["bell-off"] = { 16898612819, 771, 49 },
    ["bell-plus"] = { 16898612819, 49, 771 },
    ["bell-ring"] = { 16898612819, 0, 820 },
    ["bell"] = { 16898612819, 820, 257 },
    ["between-horizontal-end"] = { 16898612819, 771, 306 },
    ["between-horizontal-start"] = { 16898612819, 306, 771 },
    ["between-vertical-end"] = { 16898612819, 257, 820 },
    ["between-vertical-start"] = { 16898612819, 820, 514 },
    ["bike"] = { 16898612819, 771, 563 },
    ["binary"] = { 16898612819, 563, 771 },
    ["biohazard"] = { 16898612819, 514, 820 },
    ["bird"] = { 16898612819, 869, 0 },
    ["bitcoin"] = { 16898612819, 820, 49 },
    ["blend"] = { 16898612819, 771, 98 },
    ["blinds"] = { 16898612819, 98, 771 },
    ["blocks"] = { 16898612819, 49, 820 },
    ["bluetooth-connected"] = { 16898612819, 0, 869 },
    ["bluetooth-off"] = { 16898612819, 869, 257 },
    ["bluetooth-searching"] = { 16898612819, 820, 306 },
    ["bluetooth"] = { 16898612819, 771, 355 },
    ["bold"] = { 16898612819, 355, 771 },
    ["bolt"] = { 16898612819, 306, 820 },
    ["bomb"] = { 16898612819, 257, 869 },
    ["bone"] = { 16898612819, 869, 514 },
    ["book-a"] = { 16898612819, 820, 563 },
    ["book-audio"] = { 16898612819, 771, 612 },
    ["book-check"] = { 16898612819, 612, 771 },
    ["book-copy"] = { 16898612819, 563, 820 },
    ["book-dashed"] = { 16898612819, 514, 869 },
    ["book-down"] = { 16898612819, 918, 0 },
    ["book-headphones"] = { 16898612819, 869, 49 },
    ["book-heart"] = { 16898612819, 820, 98 },
    ["book-image"] = { 16898612819, 771, 147 },
    ["book-key"] = { 16898612819, 147, 771 },
    ["book-lock"] = { 16898612819, 98, 820 },
    ["book-marked"] = { 16898612819, 49, 869 },
    ["book-minus"] = { 16898612819, 0, 918 },
    ["book-open-check"] = { 16898612819, 918, 257 },
    ["book-open-text"] = { 16898612819, 869, 306 },
    ["book-open"] = { 16898612819, 820, 355 },
    ["book-plus"] = { 16898612819, 771, 404 },
    ["book-text"] = { 16898612819, 404, 771 },
    ["book-type"] = { 16898612819, 355, 820 },
    ["book-up-2"] = { 16898612819, 306, 869 },
    ["book-up"] = { 16898612819, 257, 918 },
    ["book-user"] = { 16898612819, 918, 514 },
    ["book-x"] = { 16898612819, 869, 563 },
    ["book"] = { 16898612819, 820, 612 },
    ["bookmark-check"] = { 16898612819, 771, 661 },
    ["bookmark-minus"] = { 16898612819, 661, 771 },
    ["bookmark-plus"] = { 16898612819, 612, 820 },
    ["bookmark-x"] = { 16898612819, 563, 869 },
    ["bookmark"] = { 16898612819, 514, 918 },
    ["boom-box"] = { 16898612819, 967, 0 },
    ["bot-message-square"] = { 16898612819, 918, 49 },
    ["bot"] = { 16898612819, 869, 98 },
    ["box-select"] = { 16898612819, 820, 147 },
    ["box"] = { 16898612819, 771, 196 },
    ["boxes"] = { 16898612819, 196, 771 },
    ["braces"] = { 16898612819, 147, 820 },
    ["brackets"] = { 16898612819, 98, 869 },
    ["brain-circuit"] = { 16898612819, 49, 918 },
    ["brain-cog"] = { 16898612819, 0, 967 },
    ["brain"] = { 16898612819, 967, 257 },
    ["brick-wall"] = { 16898612819, 918, 306 },
    ["briefcase-business"] = { 16898612819, 869, 355 },
    ["briefcase-medical"] = { 16898612819, 820, 404 },
    ["briefcase"] = { 16898612819, 771, 453 },
    ["bring-to-front"] = { 16898612819, 453, 771 },
    ["brush"] = { 16898612819, 404, 820 },
    ["bug-off"] = { 16898612819, 355, 869 },
    ["bug-play"] = { 16898612819, 306, 918 },
    ["bug"] = { 16898612819, 257, 967 },
    ["building-2"] = { 16898612819, 967, 514 },
    ["building"] = { 16898612819, 918, 563 },
    ["bus-front"] = { 16898612819, 869, 612 },
    ["bus"] = { 16898612819, 820, 661 },
    ["cable-car"] = { 16898612819, 771, 710 },
    ["cable"] = { 16898612819, 710, 771 },
    ["cake-slice"] = { 16898612819, 661, 820 },
    ["cake"] = { 16898612819, 612, 869 },
    ["calculator"] = { 16898612819, 563, 918 },
    ["calendar-check-2"] = { 16898612819, 514, 967 },
    ["calendar-check"] = { 16898612819, 967, 49 },
    ["calendar-clock"] = { 16898612819, 918, 98 },
    ["calendar-days"] = { 16898612819, 869, 147 },
    ["calendar-fold"] = { 16898612819, 820, 196 },
    ["calendar-heart"] = { 16898612819, 196, 820 },
    ["calendar-minus-2"] = { 16898612819, 147, 869 },
    ["calendar-minus"] = { 16898612819, 98, 918 },
    ["calendar-off"] = { 16898612819, 49, 967 },
    ["calendar-plus-2"] = { 16898612819, 967, 306 },
    ["calendar-plus"] = { 16898612819, 918, 355 },
    ["calendar-range"] = { 16898612819, 869, 404 },
    ["calendar-search"] = { 16898612819, 820, 453 },
    ["calendar-x-2"] = { 16898612819, 453, 820 },
    ["calendar-x"] = { 16898612819, 404, 869 },
    ["calendar"] = { 16898612819, 355, 918 },
    ["camera-off"] = { 16898612819, 306, 967 },
    ["camera"] = { 16898612819, 967, 563 },
    ["candlestick-chart"] = { 16898612819, 918, 612 },
    ["candy-cane"] = { 16898612819, 869, 661 },
    ["candy-off"] = { 16898612819, 820, 710 },
    ["candy"] = { 16898612819, 771, 759 },
    ["cannabis"] = { 16898612819, 710, 820 },
    ["captions-off"] = { 16898612819, 661, 869 },
    ["captions"] = { 16898612819, 612, 918 },
    ["car-front"] = { 16898612819, 563, 967 },
    ["car-taxi-front"] = { 16898612819, 967, 98 },
    ["car"] = { 16898612819, 918, 147 },
    ["caravan"] = { 16898612819, 869, 196 },
    ["carrot"] = { 16898612819, 196, 869 },
    ["case-lower"] = { 16898612819, 147, 918 },
    ["case-sensitive"] = { 16898612819, 98, 967 },
    ["case-upper"] = { 16898612819, 967, 355 },
    ["cassette-tape"] = { 16898612819, 918, 404 },
    ["cast"] = { 16898612819, 869, 453 },
    ["castle"] = { 16898612819, 453, 869 },
    ["cat"] = { 16898612819, 404, 918 },
    ["cctv"] = { 16898612819, 355, 967 },
    ["check-check"] = { 16898612819, 967, 612 },
    ["check-circle-2"] = { 16898612819, 918, 661 },
    ["check-circle"] = { 16898612819, 869, 710 },
    ["check-square-2"] = { 16898612819, 820, 759 },
    ["check-square"] = { 16898612819, 771, 808 },
    ["check"] = { 16898612819, 710, 869 },
    ["chef-hat"] = { 16898612819, 661, 918 },
    ["cherry"] = { 16898612819, 612, 967 },
    ["chevron-down-circle"] = { 16898612819, 967, 147 },
    ["chevron-down-square"] = { 16898612819, 918, 196 },
    ["chevron-down"] = { 16898612819, 196, 918 },
    ["chevron-first"] = { 16898612819, 147, 967 },
    ["chevron-last"] = { 16898612819, 967, 404 },
    ["chevron-left-circle"] = { 16898612819, 918, 453 },
    ["chevron-left-square"] = { 16898612819, 453, 918 },
    ["chevron-left"] = { 16898612819, 404, 967 },
    ["chevron-right-circle"] = { 16898612819, 967, 661 },
    ["chevron-right-square"] = { 16898612819, 918, 710 },
    ["chevron-right"] = { 16898612819, 869, 759 },
    ["chevron-up-circle"] = { 16898612819, 820, 808 },
    ["chevron-up-square"] = { 16898612819, 771, 857 },
    ["chevron-up"] = { 16898612819, 710, 918 },
    ["chevrons-down-up"] = { 16898612819, 661, 967 },
    ["chevrons-down"] = { 16898612819, 967, 196 },
    ["chevrons-left-right"] = { 16898612819, 196, 967 },
    ["chevrons-left"] = { 16898612819, 967, 453 },
    ["chevrons-right-left"] = { 16898612819, 453, 967 },
    ["chevrons-right"] = { 16898612819, 967, 710 },
    ["chevrons-up-down"] = { 16898612819, 918, 759 },
    ["chevrons-up"] = { 16898612819, 869, 808 },
    ["chrome"] = { 16898612819, 820, 857 },
    ["church"] = { 16898612819, 771, 906 },
    ["cigarette-off"] = { 16898612819, 710, 967 },
    ["cigarette"] = { 16898612819, 967, 759 },
    ["circle-alert"] = { 16898612819, 918, 808 },
    ["circle-arrow-down"] = { 16898612819, 869, 857 },
    ["circle-arrow-left"] = { 16898612819, 820, 906 },
    ["circle-arrow-out-down-left"] = { 16898612819, 771, 955 },
    ["circle-arrow-out-down-right"] = { 16898612819, 967, 808 },
    ["circle-arrow-out-up-left"] = { 16898612819, 918, 857 },
    ["circle-arrow-out-up-right"] = { 16898612819, 869, 906 },
    ["circle-arrow-right"] = { 16898612819, 820, 955 },
    ["circle-arrow-up"] = { 16898612819, 967, 857 },
    ["circle-check-big"] = { 16898612819, 918, 906 },
    ["circle-check"] = { 16898612819, 869, 955 },
    ["circle-chevron-down"] = { 16898612819, 967, 906 },
    ["circle-chevron-left"] = { 16898612819, 918, 955 },
    ["circle-chevron-right"] = { 16898612819, 967, 955 },
    ["circle-chevron-up"] = { 16898613044, 771, 0 },
    ["circle-dashed"] = { 16898613044, 0, 771 },
    ["circle-divide"] = { 16898613044, 771, 257 },
    ["circle-dollar-sign"] = { 16898613044, 257, 771 },
    ["circle-dot-dashed"] = { 16898613044, 771, 514 },
    ["circle-dot"] = { 16898613044, 514, 771 },
    ["circle-ellipsis"] = { 16898613044, 820, 0 },
    ["circle-equal"] = { 16898613044, 771, 49 },
    ["circle-fading-plus"] = { 16898613044, 49, 771 },
    ["circle-gauge"] = { 16898613044, 0, 820 },
    ["circle-help"] = { 16898613044, 820, 257 },
    ["circle-minus"] = { 16898613044, 771, 306 },
    ["circle-off"] = { 16898613044, 306, 771 },
    ["circle-parking-off"] = { 16898613044, 257, 820 },
    ["circle-parking"] = { 16898613044, 820, 514 },
    ["circle-pause"] = { 16898613044, 771, 563 },
    ["circle-percent"] = { 16898613044, 563, 771 },
    ["circle-play"] = { 16898613044, 514, 820 },
    ["circle-plus"] = { 16898613044, 869, 0 },
    ["circle-power"] = { 16898613044, 820, 49 },
    ["circle-slash-2"] = { 16898613044, 771, 98 },
    ["circle-slash"] = { 16898613044, 98, 771 },
    ["circle-stop"] = { 16898613044, 49, 820 },
    ["circle-user-round"] = { 16898613044, 0, 869 },
    ["circle-user"] = { 16898613044, 869, 257 },
    ["circle-x"] = { 16898613044, 820, 306 },
    ["circle"] = { 16898613044, 771, 355 },
    ["circuit-board"] = { 16898613044, 355, 771 },
    ["citrus"] = { 16898613044, 306, 820 },
    ["clapperboard"] = { 16898613044, 257, 869 },
    ["clipboard-check"] = { 16898613044, 869, 514 },
    ["clipboard-copy"] = { 16898613044, 820, 563 },
    ["clipboard-edit"] = { 16898613044, 771, 612 },
    ["clipboard-list"] = { 16898613044, 612, 771 },
    ["clipboard-minus"] = { 16898613044, 563, 820 },
    ["clipboard-paste"] = { 16898613044, 514, 869 },
    ["clipboard-pen-line"] = { 16898613044, 918, 0 },
    ["clipboard-pen"] = { 16898613044, 869, 49 },
    ["clipboard-plus"] = { 16898613044, 820, 98 },
    ["clipboard-signature"] = { 16898613044, 771, 147 },
    ["clipboard-type"] = { 16898613044, 147, 771 },
    ["clipboard-x"] = { 16898613044, 98, 820 },
    ["clipboard"] = { 16898613044, 49, 869 },
    ["clock-1"] = { 16898613044, 0, 918 },
    ["clock-10"] = { 16898613044, 918, 257 },
    ["clock-11"] = { 16898613044, 869, 306 },
    ["clock-12"] = { 16898613044, 820, 355 },
    ["clock-2"] = { 16898613044, 771, 404 },
    ["clock-3"] = { 16898613044, 404, 771 },
    ["clock-4"] = { 16898613044, 355, 820 },
    ["clock-5"] = { 16898613044, 306, 869 },
    ["clock-6"] = { 16898613044, 257, 918 },
    ["clock-7"] = { 16898613044, 918, 514 },
    ["clock-8"] = { 16898613044, 869, 563 },
    ["clock-9"] = { 16898613044, 820, 612 },
    ["clock"] = { 16898613044, 771, 661 },
    ["cloud-cog"] = { 16898613044, 661, 771 },
    ["cloud-download"] = { 16898613044, 612, 820 },
    ["cloud-drizzle"] = { 16898613044, 563, 869 },
    ["cloud-fog"] = { 16898613044, 514, 918 },
    ["cloud-hail"] = { 16898613044, 967, 0 },
    ["cloud-lightning"] = { 16898613044, 918, 49 },
    ["cloud-moon-rain"] = { 16898613044, 869, 98 },
    ["cloud-moon"] = { 16898613044, 820, 147 },
    ["cloud-off"] = { 16898613044, 771, 196 },
    ["cloud-rain-wind"] = { 16898613044, 196, 771 },
    ["cloud-rain"] = { 16898613044, 147, 820 },
    ["cloud-snow"] = { 16898613044, 98, 869 },
    ["cloud-sun-rain"] = { 16898613044, 49, 918 },
    ["cloud-sun"] = { 16898613044, 0, 967 },
    ["cloud-upload"] = { 16898613044, 967, 257 },
    ["cloud"] = { 16898613044, 918, 306 },
    ["cloudy"] = { 16898613044, 869, 355 },
    ["clover"] = { 16898613044, 820, 404 },
    ["club"] = { 16898613044, 771, 453 },
    ["code-2"] = { 16898613044, 453, 771 },
    ["code-xml"] = { 16898613044, 404, 820 },
    ["code"] = { 16898613044, 355, 869 },
    ["codepen"] = { 16898613044, 306, 918 },
    ["codesandbox"] = { 16898613044, 257, 967 },
    ["coffee"] = { 16898613044, 967, 514 },
    ["cog"] = { 16898613044, 918, 563 },
    ["coins"] = { 16898613044, 869, 612 },
    ["columns-2"] = { 16898613044, 820, 661 },
    ["columns-3"] = { 16898613044, 771, 710 },
    ["columns-4"] = { 16898613044, 710, 771 },
    ["columns"] = { 16898613044, 661, 820 },
    ["combine"] = { 16898613044, 612, 869 },
    ["command"] = { 16898613044, 563, 918 },
    ["compass"] = { 16898613044, 514, 967 },
    ["component"] = { 16898613044, 967, 49 },
    ["computer"] = { 16898613044, 918, 98 },
    ["concierge-bell"] = { 16898613044, 869, 147 },
    ["cone"] = { 16898613044, 820, 196 },
    ["construction"] = { 16898613044, 196, 820 },
    ["contact-2"] = { 16898613044, 147, 869 },
    ["contact-round"] = { 16898613044, 98, 918 },
    ["contact"] = { 16898613044, 49, 967 },
    ["container"] = { 16898613044, 967, 306 },
    ["contrast"] = { 16898613044, 918, 355 },
    ["cookie"] = { 16898613044, 869, 404 },
    ["cooking-pot"] = { 16898613044, 820, 453 },
    ["copy-check"] = { 16898613044, 453, 820 },
    ["copy-minus"] = { 16898613044, 404, 869 },
    ["copy-plus"] = { 16898613044, 355, 918 },
    ["copy-slash"] = { 16898613044, 306, 967 },
    ["copy-x"] = { 16898613044, 967, 563 },
    ["copy"] = { 16898613044, 918, 612 },
    ["copyleft"] = { 16898613044, 869, 661 },
    ["copyright"] = { 16898613044, 820, 710 },
    ["corner-down-left"] = { 16898613044, 771, 759 },
    ["corner-down-right"] = { 16898613044, 710, 820 },
    ["corner-left-down"] = { 16898613044, 661, 869 },
    ["corner-left-up"] = { 16898613044, 612, 918 },
    ["corner-right-down"] = { 16898613044, 563, 967 },
    ["corner-right-up"] = { 16898613044, 967, 98 },
    ["corner-up-left"] = { 16898613044, 918, 147 },
    ["corner-up-right"] = { 16898613044, 869, 196 },
    ["cpu"] = { 16898613044, 196, 869 },
    ["creative-commons"] = { 16898613044, 147, 918 },
    ["credit-card"] = { 16898613044, 98, 967 },
    ["croissant"] = { 16898613044, 967, 355 },
    ["crop"] = { 16898613044, 918, 404 },
    ["cross"] = { 16898613044, 869, 453 },
    ["crosshair"] = { 16898613044, 453, 869 },
    ["crown"] = { 16898613044, 404, 918 },
    ["cuboid"] = { 16898613044, 355, 967 },
    ["cup-soda"] = { 16898613044, 967, 612 },
    ["currency"] = { 16898613044, 918, 661 },
    ["cylinder"] = { 16898613044, 869, 710 },
    ["database-backup"] = { 16898613044, 820, 759 },
    ["database-zap"] = { 16898613044, 771, 808 },
    ["database"] = { 16898613044, 710, 869 },
    ["delete"] = { 16898613044, 661, 918 },
    ["dessert"] = { 16898613044, 612, 967 },
    ["diameter"] = { 16898613044, 967, 147 },
    ["diamond-percent"] = { 16898613044, 918, 196 },
    ["diamond"] = { 16898613044, 196, 918 },
    ["dice-1"] = { 16898613044, 147, 967 },
    ["dice-2"] = { 16898613044, 967, 404 },
    ["dice-3"] = { 16898613044, 918, 453 },
    ["dice-4"] = { 16898613044, 453, 918 },
    ["dice-5"] = { 16898613044, 404, 967 },
    ["dice-6"] = { 16898613044, 967, 661 },
    ["dices"] = { 16898613044, 918, 710 },
    ["diff"] = { 16898613044, 869, 759 },
    ["disc-2"] = { 16898613044, 820, 808 },
    ["disc-3"] = { 16898613044, 771, 857 },
    ["disc-album"] = { 16898613044, 710, 918 },
    ["disc"] = { 16898613044, 661, 967 },
    ["divide-circle"] = { 16898613044, 967, 196 },
    ["divide-square"] = { 16898613044, 196, 967 },
    ["divide"] = { 16898613044, 967, 453 },
    ["dna-off"] = { 16898613044, 453, 967 },
    ["dna"] = { 16898613044, 967, 710 },
    ["dock"] = { 16898613044, 918, 759 },
    ["dog"] = { 16898613044, 869, 808 },
    ["dollar-sign"] = { 16898613044, 820, 857 },
    ["donut"] = { 16898613044, 771, 906 },
    ["door-closed"] = { 16898613044, 710, 967 },
    ["door-open"] = { 16898613044, 967, 759 },
    ["dot"] = { 16898613044, 918, 808 },
    ["download-cloud"] = { 16898613044, 869, 857 },
    ["download"] = { 16898613044, 820, 906 },
    ["drafting-compass"] = { 16898613044, 771, 955 },
    ["drama"] = { 16898613044, 967, 808 },
    ["dribbble"] = { 16898613044, 918, 857 },
    ["drill"] = { 16898613044, 869, 906 },
    ["droplet"] = { 16898613044, 820, 955 },
    ["droplets"] = { 16898613044, 967, 857 },
    ["drum"] = { 16898613044, 918, 906 },
    ["drumstick"] = { 16898613044, 869, 955 },
    ["dumbbell"] = { 16898613044, 967, 906 },
    ["ear-off"] = { 16898613044, 918, 955 },
    ["ear"] = { 16898613044, 967, 955 },
    ["earth-lock"] = { 16898613353, 771, 0 },
    ["earth"] = { 16898613353, 0, 771 },
    ["eclipse"] = { 16898613353, 771, 257 },
    ["egg-fried"] = { 16898613353, 257, 771 },
    ["egg-off"] = { 16898613353, 771, 514 },
    ["egg"] = { 16898613353, 514, 771 },
    ["ellipsis-vertical"] = { 16898613353, 820, 0 },
    ["ellipsis"] = { 16898613353, 771, 49 },
    ["equal-not"] = { 16898613353, 49, 771 },
    ["equal"] = { 16898613353, 0, 820 },
    ["eraser"] = { 16898613353, 820, 257 },
    ["euro"] = { 16898613353, 771, 306 },
    ["expand"] = { 16898613353, 306, 771 },
    ["external-link"] = { 16898613353, 257, 820 },
    ["eye-off"] = { 16898613353, 820, 514 },
    ["eye"] = { 16898613353, 771, 563 },
    ["facebook"] = { 16898613353, 563, 771 },
    ["factory"] = { 16898613353, 514, 820 },
    ["fan"] = { 16898613353, 869, 0 },
    ["fast-forward"] = { 16898613353, 820, 49 },
    ["feather"] = { 16898613353, 771, 98 },
    ["fence"] = { 16898613353, 98, 771 },
    ["ferris-wheel"] = { 16898613353, 49, 820 },
    ["figma"] = { 16898613353, 0, 869 },
    ["file-archive"] = { 16898613353, 869, 257 },
    ["file-audio-2"] = { 16898613353, 820, 306 },
    ["file-audio"] = { 16898613353, 771, 355 },
    ["file-axis-3d"] = { 16898613353, 355, 771 },
    ["file-badge-2"] = { 16898613353, 306, 820 },
    ["file-badge"] = { 16898613353, 257, 869 },
    ["file-bar-chart-2"] = { 16898613353, 869, 514 },
    ["file-bar-chart"] = { 16898613353, 820, 563 },
    ["file-box"] = { 16898613353, 771, 612 },
    ["file-check-2"] = { 16898613353, 612, 771 },
    ["file-check"] = { 16898613353, 563, 820 },
    ["file-clock"] = { 16898613353, 514, 869 },
    ["file-code-2"] = { 16898613353, 918, 0 },
    ["file-code"] = { 16898613353, 869, 49 },
    ["file-cog"] = { 16898613353, 820, 98 },
    ["file-diff"] = { 16898613353, 771, 147 },
    ["file-digit"] = { 16898613353, 147, 771 },
    ["file-down"] = { 16898613353, 98, 820 },
    ["file-edit"] = { 16898613353, 49, 869 },
    ["file-heart"] = { 16898613353, 0, 918 },
    ["file-image"] = { 16898613353, 918, 257 },
    ["file-input"] = { 16898613353, 869, 306 },
    ["file-json-2"] = { 16898613353, 820, 355 },
    ["file-json"] = { 16898613353, 771, 404 },
    ["file-key-2"] = { 16898613353, 404, 771 },
    ["file-key"] = { 16898613353, 355, 820 },
    ["file-line-chart"] = { 16898613353, 306, 869 },
    ["file-lock-2"] = { 16898613353, 257, 918 },
    ["file-lock"] = { 16898613353, 918, 514 },
    ["file-minus-2"] = { 16898613353, 869, 563 },
    ["file-minus"] = { 16898613353, 820, 612 },
    ["file-music"] = { 16898613353, 771, 661 },
    ["file-output"] = { 16898613353, 661, 771 },
    ["file-pen-line"] = { 16898613353, 612, 820 },
    ["file-pen"] = { 16898613353, 563, 869 },
    ["file-pie-chart"] = { 16898613353, 514, 918 },
    ["file-plus-2"] = { 16898613353, 967, 0 },
    ["file-plus"] = { 16898613353, 918, 49 },
    ["file-question"] = { 16898613353, 869, 98 },
    ["file-scan"] = { 16898613353, 820, 147 },
    ["file-search-2"] = { 16898613353, 771, 196 },
    ["file-search"] = { 16898613353, 196, 771 },
    ["file-signature"] = { 16898613353, 147, 820 },
    ["file-sliders"] = { 16898613353, 98, 869 },
    ["file-spreadsheet"] = { 16898613353, 49, 918 },
    ["file-stack"] = { 16898613353, 0, 967 },
    ["file-symlink"] = { 16898613353, 967, 257 },
    ["file-terminal"] = { 16898613353, 918, 306 },
    ["file-text"] = { 16898613353, 869, 355 },
    ["file-type-2"] = { 16898613353, 820, 404 },
    ["file-type"] = { 16898613353, 771, 453 },
    ["file-up"] = { 16898613353, 453, 771 },
    ["file-video-2"] = { 16898613353, 404, 820 },
    ["file-video"] = { 16898613353, 355, 869 },
    ["file-volume-2"] = { 16898613353, 306, 918 },
    ["file-volume"] = { 16898613353, 257, 967 },
    ["file-warning"] = { 16898613353, 967, 514 },
    ["file-x-2"] = { 16898613353, 918, 563 },
    ["file-x"] = { 16898613353, 869, 612 },
    ["file"] = { 16898613353, 820, 661 },
    ["files"] = { 16898613353, 771, 710 },
    ["film"] = { 16898613353, 710, 771 },
    ["filter-x"] = { 16898613353, 661, 820 },
    ["filter"] = { 16898613353, 612, 869 },
    ["fingerprint"] = { 16898613353, 563, 918 },
    ["fire-extinguisher"] = { 16898613353, 514, 967 },
    ["fish-off"] = { 16898613353, 967, 49 },
    ["fish-symbol"] = { 16898613353, 918, 98 },
    ["fish"] = { 16898613353, 869, 147 },
    ["flag-off"] = { 16898613353, 820, 196 },
    ["flag-triangle-left"] = { 16898613353, 196, 820 },
    ["flag-triangle-right"] = { 16898613353, 147, 869 },
    ["flag"] = { 16898613353, 98, 918 },
    ["flame-kindling"] = { 16898613353, 49, 967 },
    ["flame"] = { 16898613353, 967, 306 },
    ["flashlight-off"] = { 16898613353, 918, 355 },
    ["flashlight"] = { 16898613353, 869, 404 },
    ["flask-conical-off"] = { 16898613353, 820, 453 },
    ["flask-conical"] = { 16898613353, 453, 820 },
    ["flask-round"] = { 16898613353, 404, 869 },
    ["flip-horizontal-2"] = { 16898613353, 355, 918 },
    ["flip-horizontal"] = { 16898613353, 306, 967 },
    ["flip-vertical-2"] = { 16898613353, 967, 563 },
    ["flip-vertical"] = { 16898613353, 918, 612 },
    ["flower-2"] = { 16898613353, 869, 661 },
    ["flower"] = { 16898613353, 820, 710 },
    ["focus"] = { 16898613353, 771, 759 },
    ["fold-horizontal"] = { 16898613353, 710, 820 },
    ["fold-vertical"] = { 16898613353, 661, 869 },
    ["folder-archive"] = { 16898613353, 612, 918 },
    ["folder-check"] = { 16898613353, 563, 967 },
    ["folder-clock"] = { 16898613353, 967, 98 },
    ["folder-closed"] = { 16898613353, 918, 147 },
    ["folder-cog"] = { 16898613353, 869, 196 },
    ["folder-dot"] = { 16898613353, 196, 869 },
    ["folder-down"] = { 16898613353, 147, 918 },
    ["folder-edit"] = { 16898613353, 98, 967 },
    ["folder-git-2"] = { 16898613353, 967, 355 },
    ["folder-git"] = { 16898613353, 918, 404 },
    ["folder-heart"] = { 16898613353, 869, 453 },
    ["folder-input"] = { 16898613353, 453, 869 },
    ["folder-kanban"] = { 16898613353, 404, 918 },
    ["folder-key"] = { 16898613353, 355, 967 },
    ["folder-lock"] = { 16898613353, 967, 612 },
    ["folder-minus"] = { 16898613353, 918, 661 },
    ["folder-open-dot"] = { 16898613353, 869, 710 },
    ["folder-open"] = { 16898613353, 820, 759 },
    ["folder-output"] = { 16898613353, 771, 808 },
    ["folder-pen"] = { 16898613353, 710, 869 },
    ["folder-plus"] = { 16898613353, 661, 918 },
    ["folder-root"] = { 16898613353, 612, 967 },
    ["folder-search-2"] = { 16898613353, 967, 147 },
    ["folder-search"] = { 16898613353, 918, 196 },
    ["folder-symlink"] = { 16898613353, 196, 918 },
    ["folder-sync"] = { 16898613353, 147, 967 },
    ["folder-tree"] = { 16898613353, 967, 404 },
    ["folder-up"] = { 16898613353, 918, 453 },
    ["folder-x"] = { 16898613353, 453, 918 },
    ["folder"] = { 16898613353, 404, 967 },
    ["folders"] = { 16898613353, 967, 661 },
    ["footprints"] = { 16898613353, 918, 710 },
    ["forklift"] = { 16898613353, 869, 759 },
    ["form-input"] = { 16898613353, 820, 808 },
    ["forward"] = { 16898613353, 771, 857 },
    ["frame"] = { 16898613353, 710, 918 },
    ["framer"] = { 16898613353, 661, 967 },
    ["frown"] = { 16898613353, 967, 196 },
    ["fuel"] = { 16898613353, 196, 967 },
    ["fullscreen"] = { 16898613353, 967, 453 },
    ["function-square"] = { 16898613353, 453, 967 },
    ["gallery-horizontal-end"] = { 16898613353, 967, 710 },
    ["gallery-horizontal"] = { 16898613353, 918, 759 },
    ["gallery-thumbnails"] = { 16898613353, 869, 808 },
    ["gallery-vertical-end"] = { 16898613353, 820, 857 },
    ["gallery-vertical"] = { 16898613353, 771, 906 },
    ["gamepad-2"] = { 16898613353, 710, 967 },
    ["gamepad"] = { 16898613353, 967, 759 },
    ["gantt-chart-square"] = { 16898613353, 918, 808 },
    ["gantt-chart"] = { 16898613353, 869, 857 },
    ["gauge-circle"] = { 16898613353, 820, 906 },
    ["gauge"] = { 16898613353, 771, 955 },
    ["gavel"] = { 16898613353, 967, 808 },
    ["gem"] = { 16898613353, 918, 857 },
    ["ghost"] = { 16898613353, 869, 906 },
    ["gift"] = { 16898613353, 820, 955 },
    ["git-branch-plus"] = { 16898613353, 967, 857 },
    ["git-branch"] = { 16898613353, 918, 906 },
    ["git-commit-horizontal"] = { 16898613353, 869, 955 },
    ["git-commit-vertical"] = { 16898613353, 967, 906 },
    ["git-compare-arrows"] = { 16898613353, 918, 955 },
    ["git-compare"] = { 16898613353, 967, 955 },
    ["git-fork"] = { 16898613509, 771, 0 },
    ["git-graph"] = { 16898613509, 0, 771 },
    ["git-merge"] = { 16898613509, 771, 257 },
    ["git-pull-request-arrow"] = { 16898613509, 257, 771 },
    ["git-pull-request-closed"] = { 16898613509, 771, 514 },
    ["git-pull-request-create-arrow"] = { 16898613509, 514, 771 },
    ["git-pull-request-create"] = { 16898613509, 820, 0 },
    ["git-pull-request-draft"] = { 16898613509, 771, 49 },
    ["git-pull-request"] = { 16898613509, 49, 771 },
    ["github"] = { 16898613509, 0, 820 },
    ["gitlab"] = { 16898613509, 820, 257 },
    ["glass-water"] = { 16898613509, 771, 306 },
    ["glasses"] = { 16898613509, 306, 771 },
    ["globe-2"] = { 16898613509, 257, 820 },
    ["globe-lock"] = { 16898613509, 820, 514 },
    ["globe"] = { 16898613509, 771, 563 },
    ["goal"] = { 16898613509, 563, 771 },
    ["grab"] = { 16898613509, 514, 820 },
    ["graduation-cap"] = { 16898613509, 869, 0 },
    ["grape"] = { 16898613509, 820, 49 },
    ["grid-2x2"] = { 16898613509, 771, 98 },
    ["grid-3x3"] = { 16898613509, 98, 771 },
    ["grip-horizontal"] = { 16898613509, 49, 820 },
    ["grip-vertical"] = { 16898613509, 0, 869 },
    ["grip"] = { 16898613509, 869, 257 },
    ["group"] = { 16898613509, 820, 306 },
    ["guitar"] = { 16898613509, 771, 355 },
    ["ham"] = { 16898613509, 355, 771 },
    ["hammer"] = { 16898613509, 306, 820 },
    ["hand-coins"] = { 16898613509, 257, 869 },
    ["hand-heart"] = { 16898613509, 869, 514 },
    ["hand-helping"] = { 16898613509, 820, 563 },
    ["hand-metal"] = { 16898613509, 771, 612 },
    ["hand-platter"] = { 16898613509, 612, 771 },
    ["hand"] = { 16898613509, 563, 820 },
    ["handshake"] = { 16898613509, 514, 869 },
    ["hard-drive-download"] = { 16898613509, 918, 0 },
    ["hard-drive-upload"] = { 16898613509, 869, 49 },
    ["hard-drive"] = { 16898613509, 820, 98 },
    ["hard-hat"] = { 16898613509, 771, 147 },
    ["hash"] = { 16898613509, 147, 771 },
    ["haze"] = { 16898613509, 98, 820 },
    ["hdmi-port"] = { 16898613509, 49, 869 },
    ["heading-1"] = { 16898613509, 0, 918 },
    ["heading-2"] = { 16898613509, 918, 257 },
    ["heading-3"] = { 16898613509, 869, 306 },
    ["heading-4"] = { 16898613509, 820, 355 },
    ["heading-5"] = { 16898613509, 771, 404 },
    ["heading-6"] = { 16898613509, 404, 771 },
    ["heading"] = { 16898613509, 355, 820 },
    ["headphones"] = { 16898613509, 306, 869 },
    ["headset"] = { 16898613509, 257, 918 },
    ["heart-crack"] = { 16898613509, 918, 514 },
    ["heart-handshake"] = { 16898613509, 869, 563 },
    ["heart-off"] = { 16898613509, 820, 612 },
    ["heart-pulse"] = { 16898613509, 771, 661 },
    ["heart"] = { 16898613509, 661, 771 },
    ["heater"] = { 16898613509, 612, 820 },
    ["help-circle"] = { 16898613509, 563, 869 },
    ["helping-hand"] = { 16898613509, 514, 918 },
    ["hexagon"] = { 16898613509, 967, 0 },
    ["highlighter"] = { 16898613509, 918, 49 },
    ["history"] = { 16898613509, 869, 98 },
    ["home"] = { 16898613509, 820, 147 },
    ["hop-off"] = { 16898613509, 771, 196 },
    ["hop"] = { 16898613509, 196, 771 },
    ["hospital"] = { 16898613509, 147, 820 },
    ["hotel"] = { 16898613509, 98, 869 },
    ["hourglass"] = { 16898613509, 49, 918 },
    ["ice-cream-2"] = { 16898613509, 0, 967 },
    ["ice-cream-bowl"] = { 16898613509, 967, 257 },
    ["ice-cream-cone"] = { 16898613509, 918, 306 },
    ["ice-cream"] = { 16898613509, 869, 355 },
    ["image-down"] = { 16898613509, 820, 404 },
    ["image-minus"] = { 16898613509, 771, 453 },
    ["image-off"] = { 16898613509, 453, 771 },
    ["image-plus"] = { 16898613509, 404, 820 },
    ["image-up"] = { 16898613509, 355, 869 },
    ["image"] = { 16898613509, 306, 918 },
    ["images"] = { 16898613509, 257, 967 },
    ["import"] = { 16898613509, 967, 514 },
    ["inbox"] = { 16898613509, 918, 563 },
    ["indent-decrease"] = { 16898613509, 869, 612 },
    ["indent-increase"] = { 16898613509, 820, 661 },
    ["indent"] = { 16898613509, 771, 710 },
    ["indian-rupee"] = { 16898613509, 710, 771 },
    ["infinity"] = { 16898613509, 661, 820 },
    ["info"] = { 16898613509, 612, 869 },
    ["inspection-panel"] = { 16898613509, 563, 918 },
    ["instagram"] = { 16898613509, 514, 967 },
    ["italic"] = { 16898613509, 967, 49 },
    ["iteration-ccw"] = { 16898613509, 918, 98 },
    ["iteration-cw"] = { 16898613509, 869, 147 },
    ["japanese-yen"] = { 16898613509, 820, 196 },
    ["joystick"] = { 16898613509, 196, 820 },
    ["kanban-square-dashed"] = { 16898613509, 147, 869 },
    ["kanban-square"] = { 16898613509, 98, 918 },
    ["kanban"] = { 16898613509, 49, 967 },
    ["key-round"] = { 16898613509, 967, 306 },
    ["key-square"] = { 16898613509, 918, 355 },
    ["key"] = { 16898613509, 869, 404 },
    ["keyboard-music"] = { 16898613509, 820, 453 },
    ["keyboard"] = { 16898613509, 453, 820 },
    ["lamp-ceiling"] = { 16898613509, 404, 869 },
    ["lamp-desk"] = { 16898613509, 355, 918 },
    ["lamp-floor"] = { 16898613509, 306, 967 },
    ["lamp-wall-down"] = { 16898613509, 967, 563 },
    ["lamp-wall-up"] = { 16898613509, 918, 612 },
    ["lamp"] = { 16898613509, 869, 661 },
    ["land-plot"] = { 16898613509, 820, 710 },
    ["landmark"] = { 16898613509, 771, 759 },
    ["languages"] = { 16898613509, 710, 820 },
    ["laptop-2"] = { 16898613509, 661, 869 },
    ["laptop-minimal"] = { 16898613509, 612, 918 },
    ["laptop"] = { 16898613509, 563, 967 },
    ["lasso-select"] = { 16898613509, 967, 98 },
    ["lasso"] = { 16898613509, 918, 147 },
    ["laugh"] = { 16898613509, 869, 196 },
    ["layers-2"] = { 16898613509, 196, 869 },
    ["layers-3"] = { 16898613509, 147, 918 },
    ["layers"] = { 16898613509, 98, 967 },
    ["layout-dashboard"] = { 16898613509, 967, 355 },
    ["layout-grid"] = { 16898613509, 918, 404 },
    ["layout-list"] = { 16898613509, 869, 453 },
    ["layout-panel-left"] = { 16898613509, 453, 869 },
    ["layout-panel-top"] = { 16898613509, 404, 918 },
    ["layout-template"] = { 16898613509, 355, 967 },
    ["layout"] = { 16898613509, 967, 612 },
    ["leaf"] = { 16898613509, 918, 661 },
    ["leafy-green"] = { 16898613509, 869, 710 },
    ["library-big"] = { 16898613509, 820, 759 },
    ["library-square"] = { 16898613509, 771, 808 },
    ["library"] = { 16898613509, 710, 869 },
    ["life-buoy"] = { 16898613509, 661, 918 },
    ["ligature"] = { 16898613509, 612, 967 },
    ["lightbulb-off"] = { 16898613509, 967, 147 },
    ["lightbulb"] = { 16898613509, 918, 196 },
    ["line-chart"] = { 16898613509, 196, 918 },
    ["link-2-off"] = { 16898613509, 147, 967 },
    ["link-2"] = { 16898613509, 967, 404 },
    ["link"] = { 16898613509, 918, 453 },
    ["linkedin"] = { 16898613509, 453, 918 },
    ["list-checks"] = { 16898613509, 404, 967 },
    ["list-collapse"] = { 16898613509, 967, 661 },
    ["list-end"] = { 16898613509, 918, 710 },
    ["list-filter"] = { 16898613509, 869, 759 },
    ["list-minus"] = { 16898613509, 820, 808 },
    ["list-music"] = { 16898613509, 771, 857 },
    ["list-ordered"] = { 16898613509, 710, 918 },
    ["list-plus"] = { 16898613509, 661, 967 },
    ["list-restart"] = { 16898613509, 967, 196 },
    ["list-start"] = { 16898613509, 196, 967 },
    ["list-todo"] = { 16898613509, 967, 453 },
    ["list-tree"] = { 16898613509, 453, 967 },
    ["list-video"] = { 16898613509, 967, 710 },
    ["list-x"] = { 16898613509, 918, 759 },
    ["list"] = { 16898613509, 869, 808 },
    ["loader-2"] = { 16898613509, 820, 857 },
    ["loader-circle"] = { 16898613509, 771, 906 },
    ["loader"] = { 16898613509, 710, 967 },
    ["locate-fixed"] = { 16898613509, 967, 759 },
    ["locate-off"] = { 16898613509, 918, 808 },
    ["locate"] = { 16898613509, 869, 857 },
    ["lock-keyhole-open"] = { 16898613509, 820, 906 },
    ["lock-keyhole"] = { 16898613509, 771, 955 },
    ["lock-open"] = { 16898613509, 967, 808 },
    ["lock"] = { 16898613509, 918, 857 },
    ["log-in"] = { 16898613509, 869, 906 },
    ["log-out"] = { 16898613509, 820, 955 },
    ["lollipop"] = { 16898613509, 967, 857 },
    ["luggage"] = { 16898613509, 918, 906 },
    ["m-square"] = { 16898613509, 869, 955 },
    ["magnet"] = { 16898613509, 967, 906 },
    ["mail-check"] = { 16898613509, 918, 955 },
    ["mail-minus"] = { 16898613509, 967, 955 },
    ["mail-open"] = { 16898613613, 771, 0 },
    ["mail-plus"] = { 16898613613, 0, 771 },
    ["mail-question"] = { 16898613613, 771, 257 },
    ["mail-search"] = { 16898613613, 257, 771 },
    ["mail-warning"] = { 16898613613, 771, 514 },
    ["mail-x"] = { 16898613613, 514, 771 },
    ["mail"] = { 16898613613, 820, 0 },
    ["mailbox"] = { 16898613613, 771, 49 },
    ["mails"] = { 16898613613, 49, 771 },
    ["map-pin-off"] = { 16898613613, 0, 820 },
    ["map-pin"] = { 16898613613, 820, 257 },
    ["map-pinned"] = { 16898613613, 771, 306 },
    ["map"] = { 16898613613, 306, 771 },
    ["martini"] = { 16898613613, 257, 820 },
    ["maximize-2"] = { 16898613613, 820, 514 },
    ["maximize"] = { 16898613613, 771, 563 },
    ["medal"] = { 16898613613, 563, 771 },
    ["megaphone-off"] = { 16898613613, 514, 820 },
    ["megaphone"] = { 16898613613, 869, 0 },
    ["meh"] = { 16898613613, 820, 49 },
    ["memory-stick"] = { 16898613613, 771, 98 },
    ["menu-square"] = { 16898613613, 98, 771 },
    ["menu"] = { 16898613613, 49, 820 },
    ["merge"] = { 16898613613, 0, 869 },
    ["message-circle-code"] = { 16898613613, 869, 257 },
    ["message-circle-dashed"] = { 16898613613, 820, 306 },
    ["message-circle-heart"] = { 16898613613, 771, 355 },
    ["message-circle-more"] = { 16898613613, 355, 771 },
    ["message-circle-off"] = { 16898613613, 306, 820 },
    ["message-circle-plus"] = { 16898613613, 257, 869 },
    ["message-circle-question"] = { 16898613613, 869, 514 },
    ["message-circle-reply"] = { 16898613613, 820, 563 },
    ["message-circle-warning"] = { 16898613613, 771, 612 },
    ["message-circle-x"] = { 16898613613, 612, 771 },
    ["message-circle"] = { 16898613613, 563, 820 },
    ["message-square-code"] = { 16898613613, 514, 869 },
    ["message-square-dashed"] = { 16898613613, 918, 0 },
    ["message-square-diff"] = { 16898613613, 869, 49 },
    ["message-square-dot"] = { 16898613613, 820, 98 },
    ["message-square-heart"] = { 16898613613, 771, 147 },
    ["message-square-more"] = { 16898613613, 147, 771 },
    ["message-square-off"] = { 16898613613, 98, 820 },
    ["message-square-plus"] = { 16898613613, 49, 869 },
    ["message-square-quote"] = { 16898613613, 0, 918 },
    ["message-square-reply"] = { 16898613613, 918, 257 },
    ["message-square-share"] = { 16898613613, 869, 306 },
    ["message-square-text"] = { 16898613613, 820, 355 },
    ["message-square-warning"] = { 16898613613, 771, 404 },
    ["message-square-x"] = { 16898613613, 404, 771 },
    ["message-square"] = { 16898613613, 355, 820 },
    ["messages-square"] = { 16898613613, 306, 869 },
    ["mic-2"] = { 16898613613, 257, 918 },
    ["mic-off"] = { 16898613613, 918, 514 },
    ["mic-vocal"] = { 16898613613, 869, 563 },
    ["mic"] = { 16898613613, 820, 612 },
    ["microscope"] = { 16898613613, 771, 661 },
    ["microwave"] = { 16898613613, 661, 771 },
    ["milestone"] = { 16898613613, 612, 820 },
    ["milk-off"] = { 16898613613, 563, 869 },
    ["milk"] = { 16898613613, 514, 918 },
    ["minimize-2"] = { 16898613613, 967, 0 },
    ["minimize"] = { 16898613613, 918, 49 },
    ["minus-circle"] = { 16898613613, 869, 98 },
    ["minus-square"] = { 16898613613, 820, 147 },
    ["minus"] = { 16898613613, 771, 196 },
    ["monitor-check"] = { 16898613613, 196, 771 },
    ["monitor-dot"] = { 16898613613, 147, 820 },
    ["monitor-down"] = { 16898613613, 98, 869 },
    ["monitor-off"] = { 16898613613, 49, 918 },
    ["monitor-pause"] = { 16898613613, 0, 967 },
    ["monitor-play"] = { 16898613613, 967, 257 },
    ["monitor-smartphone"] = { 16898613613, 918, 306 },
    ["monitor-speaker"] = { 16898613613, 869, 355 },
    ["monitor-stop"] = { 16898613613, 820, 404 },
    ["monitor-up"] = { 16898613613, 771, 453 },
    ["monitor-x"] = { 16898613613, 453, 771 },
    ["monitor"] = { 16898613613, 404, 820 },
    ["moon-star"] = { 16898613613, 355, 869 },
    ["moon"] = { 16898613613, 306, 918 },
    ["more-horizontal"] = { 16898613613, 257, 967 },
    ["more-vertical"] = { 16898613613, 967, 514 },
    ["mountain-snow"] = { 16898613613, 918, 563 },
    ["mountain"] = { 16898613613, 869, 612 },
    ["mouse-pointer-2"] = { 16898613613, 820, 661 },
    ["mouse-pointer-click"] = { 16898613613, 771, 710 },
    ["mouse-pointer-square-dashed"] = { 16898613613, 710, 771 },
    ["mouse-pointer-square"] = { 16898613613, 661, 820 },
    ["mouse-pointer"] = { 16898613613, 612, 869 },
    ["mouse"] = { 16898613613, 563, 918 },
    ["move-3d"] = { 16898613613, 514, 967 },
    ["move-diagonal-2"] = { 16898613613, 967, 49 },
    ["move-diagonal"] = { 16898613613, 918, 98 },
    ["move-down-left"] = { 16898613613, 869, 147 },
    ["move-down-right"] = { 16898613613, 820, 196 },
    ["move-down"] = { 16898613613, 196, 820 },
    ["move-horizontal"] = { 16898613613, 147, 869 },
    ["move-left"] = { 16898613613, 98, 918 },
    ["move-right"] = { 16898613613, 49, 967 },
    ["move-up-left"] = { 16898613613, 967, 306 },
    ["move-up-right"] = { 16898613613, 918, 355 },
    ["move-up"] = { 16898613613, 869, 404 },
    ["move-vertical"] = { 16898613613, 820, 453 },
    ["move"] = { 16898613613, 453, 820 },
    ["music-2"] = { 16898613613, 404, 869 },
    ["music-3"] = { 16898613613, 355, 918 },
    ["music-4"] = { 16898613613, 306, 967 },
    ["music"] = { 16898613613, 967, 563 },
    ["navigation-2-off"] = { 16898613613, 918, 612 },
    ["navigation-2"] = { 16898613613, 869, 661 },
    ["navigation-off"] = { 16898613613, 820, 710 },
    ["navigation"] = { 16898613613, 771, 759 },
    ["network"] = { 16898613613, 710, 820 },
    ["newspaper"] = { 16898613613, 661, 869 },
    ["nfc"] = { 16898613613, 612, 918 },
    ["notebook-pen"] = { 16898613613, 563, 967 },
    ["notebook-tabs"] = { 16898613613, 967, 98 },
    ["notebook-text"] = { 16898613613, 918, 147 },
    ["notebook"] = { 16898613613, 869, 196 },
    ["notepad-text-dashed"] = { 16898613613, 196, 869 },
    ["notepad-text"] = { 16898613613, 147, 918 },
    ["nut-off"] = { 16898613613, 98, 967 },
    ["nut"] = { 16898613613, 967, 355 },
    ["octagon-alert"] = { 16898613613, 918, 404 },
    ["octagon-pause"] = { 16898613613, 869, 453 },
    ["octagon-x"] = { 16898613613, 453, 869 },
    ["octagon"] = { 16898613613, 404, 918 },
    ["option"] = { 16898613613, 355, 967 },
    ["orbit"] = { 16898613613, 967, 612 },
    ["outdent"] = { 16898613613, 918, 661 },
    ["package-2"] = { 16898613613, 869, 710 },
    ["package-check"] = { 16898613613, 820, 759 },
    ["package-minus"] = { 16898613613, 771, 808 },
    ["package-open"] = { 16898613613, 710, 869 },
    ["package-plus"] = { 16898613613, 661, 918 },
    ["package-search"] = { 16898613613, 612, 967 },
    ["package-x"] = { 16898613613, 967, 147 },
    ["package"] = { 16898613613, 918, 196 },
    ["paint-bucket"] = { 16898613613, 196, 918 },
    ["paint-roller"] = { 16898613613, 147, 967 },
    ["paintbrush-2"] = { 16898613613, 967, 404 },
    ["paintbrush"] = { 16898613613, 918, 453 },
    ["palette"] = { 16898613613, 453, 918 },
    ["palmtree"] = { 16898613613, 404, 967 },
    ["panel-bottom-close"] = { 16898613613, 967, 661 },
    ["panel-bottom-dashed"] = { 16898613613, 918, 710 },
    ["panel-bottom-inactive"] = { 16898613613, 869, 759 },
    ["panel-bottom-open"] = { 16898613613, 820, 808 },
    ["panel-bottom"] = { 16898613613, 771, 857 },
    ["panel-left-close"] = { 16898613613, 710, 918 },
    ["panel-left-dashed"] = { 16898613613, 661, 967 },
    ["panel-left-inactive"] = { 16898613613, 967, 196 },
    ["panel-left-open"] = { 16898613613, 196, 967 },
    ["panel-left"] = { 16898613613, 967, 453 },
    ["panel-right-close"] = { 16898613613, 453, 967 },
    ["panel-right-dashed"] = { 16898613613, 967, 710 },
    ["panel-right-inactive"] = { 16898613613, 918, 759 },
    ["panel-right-open"] = { 16898613613, 869, 808 },
    ["panel-right"] = { 16898613613, 820, 857 },
    ["panel-top-close"] = { 16898613613, 771, 906 },
    ["panel-top-dashed"] = { 16898613613, 710, 967 },
    ["panel-top-inactive"] = { 16898613613, 967, 759 },
    ["panel-top-open"] = { 16898613613, 918, 808 },
    ["panel-top"] = { 16898613613, 869, 857 },
    ["panels-left-bottom"] = { 16898613613, 820, 906 },
    ["panels-right-bottom"] = { 16898613613, 771, 955 },
    ["panels-top-left"] = { 16898613613, 967, 808 },
    ["paperclip"] = { 16898613613, 918, 857 },
    ["parentheses"] = { 16898613613, 869, 906 },
    ["parking-circle-off"] = { 16898613613, 820, 955 },
    ["parking-circle"] = { 16898613613, 967, 857 },
    ["parking-meter"] = { 16898613613, 918, 906 },
    ["parking-square-off"] = { 16898613613, 869, 955 },
    ["parking-square"] = { 16898613613, 967, 906 },
    ["party-popper"] = { 16898613613, 918, 955 },
    ["pause-circle"] = { 16898613613, 967, 955 },
    ["pause-octagon"] = { 16898613699, 771, 0 },
    ["pause"] = { 16898613699, 0, 771 },
    ["paw-print"] = { 16898613699, 771, 257 },
    ["pc-case"] = { 16898613699, 257, 771 },
    ["pen-line"] = { 16898613699, 771, 514 },
    ["pen-square"] = { 16898613699, 514, 771 },
    ["pen-tool"] = { 16898613699, 820, 0 },
    ["pen"] = { 16898613699, 771, 49 },
    ["pencil-line"] = { 16898613699, 49, 771 },
    ["pencil-ruler"] = { 16898613699, 0, 820 },
    ["pencil"] = { 16898613699, 820, 257 },
    ["pentagon"] = { 16898613699, 771, 306 },
    ["percent-circle"] = { 16898613699, 306, 771 },
    ["percent-diamond"] = { 16898613699, 257, 820 },
    ["percent-square"] = { 16898613699, 820, 514 },
    ["percent"] = { 16898613699, 771, 563 },
    ["person-standing"] = { 16898613699, 563, 771 },
    ["phone-call"] = { 16898613699, 514, 820 },
    ["phone-forwarded"] = { 16898613699, 869, 0 },
    ["phone-incoming"] = { 16898613699, 820, 49 },
    ["phone-missed"] = { 16898613699, 771, 98 },
    ["phone-off"] = { 16898613699, 98, 771 },
    ["phone-outgoing"] = { 16898613699, 49, 820 },
    ["phone"] = { 16898613699, 0, 869 },
    ["pi-square"] = { 16898613699, 869, 257 },
    ["pi"] = { 16898613699, 820, 306 },
    ["piano"] = { 16898613699, 771, 355 },
    ["pickaxe"] = { 16898613699, 355, 771 },
    ["picture-in-picture-2"] = { 16898613699, 306, 820 },
    ["picture-in-picture"] = { 16898613699, 257, 869 },
    ["pie-chart"] = { 16898613699, 869, 514 },
    ["piggy-bank"] = { 16898613699, 820, 563 },
    ["pilcrow-square"] = { 16898613699, 771, 612 },
    ["pilcrow"] = { 16898613699, 612, 771 },
    ["pill"] = { 16898613699, 563, 820 },
    ["pin-off"] = { 16898613699, 514, 869 },
    ["pin"] = { 16898613699, 918, 0 },
    ["pipette"] = { 16898613699, 869, 49 },
    ["pizza"] = { 16898613699, 820, 98 },
    ["plane-landing"] = { 16898613699, 771, 147 },
    ["plane-takeoff"] = { 16898613699, 147, 771 },
    ["plane"] = { 16898613699, 98, 820 },
    ["play-circle"] = { 16898613699, 49, 869 },
    ["play-square"] = { 16898613699, 0, 918 },
    ["play"] = { 16898613699, 918, 257 },
    ["plug-2"] = { 16898613699, 869, 306 },
    ["plug-zap-2"] = { 16898613699, 820, 355 },
    ["plug-zap"] = { 16898613699, 771, 404 },
    ["plug"] = { 16898613699, 404, 771 },
    ["plus-circle"] = { 16898613699, 355, 820 },
    ["plus-square"] = { 16898613699, 306, 869 },
    ["plus"] = { 16898613699, 257, 918 },
    ["pocket-knife"] = { 16898613699, 918, 514 },
    ["pocket"] = { 16898613699, 869, 563 },
    ["podcast"] = { 16898613699, 820, 612 },
    ["pointer-off"] = { 16898613699, 771, 661 },
    ["pointer"] = { 16898613699, 661, 771 },
    ["popcorn"] = { 16898613699, 612, 820 },
    ["popsicle"] = { 16898613699, 563, 869 },
    ["pound-sterling"] = { 16898613699, 514, 918 },
    ["power-circle"] = { 16898613699, 967, 0 },
    ["power-off"] = { 16898613699, 918, 49 },
    ["power-square"] = { 16898613699, 869, 98 },
    ["power"] = { 16898613699, 820, 147 },
    ["presentation"] = { 16898613699, 771, 196 },
    ["printer"] = { 16898613699, 196, 771 },
    ["projector"] = { 16898613699, 147, 820 },
    ["proportions"] = { 16898613699, 98, 869 },
    ["puzzle"] = { 16898613699, 49, 918 },
    ["pyramid"] = { 16898613699, 0, 967 },
    ["qr-code"] = { 16898613699, 967, 257 },
    ["quote"] = { 16898613699, 918, 306 },
    ["rabbit"] = { 16898613699, 869, 355 },
    ["radar"] = { 16898613699, 820, 404 },
    ["radiation"] = { 16898613699, 771, 453 },
    ["radical"] = { 16898613699, 453, 771 },
    ["radio-receiver"] = { 16898613699, 404, 820 },
    ["radio-tower"] = { 16898613699, 355, 869 },
    ["radio"] = { 16898613699, 306, 918 },
    ["radius"] = { 16898613699, 257, 967 },
    ["rail-symbol"] = { 16898613699, 967, 514 },
    ["rainbow"] = { 16898613699, 918, 563 },
    ["rat"] = { 16898613699, 869, 612 },
    ["ratio"] = { 16898613699, 820, 661 },
    ["receipt-cent"] = { 16898613699, 771, 710 },
    ["receipt-euro"] = { 16898613699, 710, 771 },
    ["receipt-indian-rupee"] = { 16898613699, 661, 820 },
    ["receipt-japanese-yen"] = { 16898613699, 612, 869 },
    ["receipt-pound-sterling"] = { 16898613699, 563, 918 },
    ["receipt-russian-ruble"] = { 16898613699, 514, 967 },
    ["receipt-swiss-franc"] = { 16898613699, 967, 49 },
    ["receipt-text"] = { 16898613699, 918, 98 },
    ["receipt"] = { 16898613699, 869, 147 },
    ["rectangle-ellipsis"] = { 16898613699, 820, 196 },
    ["rectangle-horizontal"] = { 16898613699, 196, 820 },
    ["rectangle-vertical"] = { 16898613699, 147, 869 },
    ["recycle"] = { 16898613699, 98, 918 },
    ["redo-2"] = { 16898613699, 49, 967 },
    ["redo-dot"] = { 16898613699, 967, 306 },
    ["redo"] = { 16898613699, 918, 355 },
    ["refresh-ccw-dot"] = { 16898613699, 869, 404 },
    ["refresh-ccw"] = { 16898613699, 820, 453 },
    ["refresh-cw-off"] = { 16898613699, 453, 820 },
    ["refresh-cw"] = { 16898613699, 404, 869 },
    ["refrigerator"] = { 16898613699, 355, 918 },
    ["regex"] = { 16898613699, 306, 967 },
    ["remove-formatting"] = { 16898613699, 967, 563 },
    ["repeat-1"] = { 16898613699, 918, 612 },
    ["repeat-2"] = { 16898613699, 869, 661 },
    ["repeat"] = { 16898613699, 820, 710 },
    ["replace-all"] = { 16898613699, 771, 759 },
    ["replace"] = { 16898613699, 710, 820 },
    ["reply-all"] = { 16898613699, 661, 869 },
    ["reply"] = { 16898613699, 612, 918 },
    ["rewind"] = { 16898613699, 563, 967 },
    ["ribbon"] = { 16898613699, 967, 98 },
    ["rocket"] = { 16898613699, 918, 147 },
    ["rocking-chair"] = { 16898613699, 869, 196 },
    ["roller-coaster"] = { 16898613699, 196, 869 },
    ["rotate-3d"] = { 16898613699, 147, 918 },
    ["rotate-ccw-square"] = { 16898613699, 98, 967 },
    ["rotate-ccw"] = { 16898613699, 967, 355 },
    ["rotate-cw-square"] = { 16898613699, 918, 404 },
    ["rotate-cw"] = { 16898613699, 869, 453 },
    ["route-off"] = { 16898613699, 453, 869 },
    ["route"] = { 16898613699, 404, 918 },
    ["router"] = { 16898613699, 355, 967 },
    ["rows-2"] = { 16898613699, 967, 612 },
    ["rows-3"] = { 16898613699, 918, 661 },
    ["rows-4"] = { 16898613699, 869, 710 },
    ["rows"] = { 16898613699, 820, 759 },
    ["rss"] = { 16898613699, 771, 808 },
    ["ruler"] = { 16898613699, 710, 869 },
    ["russian-ruble"] = { 16898613699, 661, 918 },
    ["sailboat"] = { 16898613699, 612, 967 },
    ["salad"] = { 16898613699, 967, 147 },
    ["sandwich"] = { 16898613699, 918, 196 },
    ["satellite-dish"] = { 16898613699, 196, 918 },
    ["satellite"] = { 16898613699, 147, 967 },
    ["save-all"] = { 16898613699, 967, 404 },
    ["save"] = { 16898613699, 918, 453 },
    ["scale-3d"] = { 16898613699, 453, 918 },
    ["scale"] = { 16898613699, 404, 967 },
    ["scaling"] = { 16898613699, 967, 661 },
    ["scan-barcode"] = { 16898613699, 918, 710 },
    ["scan-eye"] = { 16898613699, 869, 759 },
    ["scan-face"] = { 16898613699, 820, 808 },
    ["scan-line"] = { 16898613699, 771, 857 },
    ["scan-search"] = { 16898613699, 710, 918 },
    ["scan-text"] = { 16898613699, 661, 967 },
    ["scan"] = { 16898613699, 967, 196 },
    ["scatter-chart"] = { 16898613699, 196, 967 },
    ["school-2"] = { 16898613699, 967, 453 },
    ["school"] = { 16898613699, 453, 967 },
    ["scissors-line-dashed"] = { 16898613699, 967, 710 },
    ["scissors-square-dashed-bottom"] = { 16898613699, 918, 759 },
    ["scissors-square"] = { 16898613699, 869, 808 },
    ["scissors"] = { 16898613699, 820, 857 },
    ["screen-share-off"] = { 16898613699, 771, 906 },
    ["screen-share"] = { 16898613699, 710, 967 },
    ["scroll-text"] = { 16898613699, 967, 759 },
    ["scroll"] = { 16898613699, 918, 808 },
    ["search-check"] = { 16898613699, 869, 857 },
    ["search-code"] = { 16898613699, 820, 906 },
    ["search-slash"] = { 16898613699, 771, 955 },
    ["search-x"] = { 16898613699, 967, 808 },
    ["search"] = { 16898613699, 918, 857 },
    ["send-horizontal"] = { 16898613699, 869, 906 },
    ["send-to-back"] = { 16898613699, 820, 955 },
    ["send"] = { 16898613699, 967, 857 },
    ["separator-horizontal"] = { 16898613699, 918, 906 },
    ["separator-vertical"] = { 16898613699, 869, 955 },
    ["server-cog"] = { 16898613699, 967, 906 },
    ["server-crash"] = { 16898613699, 918, 955 },
    ["server-off"] = { 16898613699, 967, 955 },
    ["server"] = { 16898613777, 771, 0 },
    ["settings-2"] = { 16898613777, 0, 771 },
    ["settings"] = { 16898613777, 771, 257 },
    ["shapes"] = { 16898613777, 257, 771 },
    ["share-2"] = { 16898613777, 771, 514 },
    ["share"] = { 16898613777, 514, 771 },
    ["sheet"] = { 16898613777, 820, 0 },
    ["shell"] = { 16898613777, 771, 49 },
    ["shield-alert"] = { 16898613777, 49, 771 },
    ["shield-ban"] = { 16898613777, 0, 820 },
    ["shield-check"] = { 16898613777, 820, 257 },
    ["shield-ellipsis"] = { 16898613777, 771, 306 },
    ["shield-half"] = { 16898613777, 306, 771 },
    ["shield-minus"] = { 16898613777, 257, 820 },
    ["shield-off"] = { 16898613777, 820, 514 },
    ["shield-plus"] = { 16898613777, 771, 563 },
    ["shield-question"] = { 16898613777, 563, 771 },
    ["shield-x"] = { 16898613777, 514, 820 },
    ["shield"] = { 16898613777, 869, 0 },
    ["ship-wheel"] = { 16898613777, 820, 49 },
    ["ship"] = { 16898613777, 771, 98 },
    ["shirt"] = { 16898613777, 98, 771 },
    ["shopping-bag"] = { 16898613777, 49, 820 },
    ["shopping-basket"] = { 16898613777, 0, 869 },
    ["shopping-cart"] = { 16898613777, 869, 257 },
    ["shovel"] = { 16898613777, 820, 306 },
    ["shower-head"] = { 16898613777, 771, 355 },
    ["shrink"] = { 16898613777, 355, 771 },
    ["shrub"] = { 16898613777, 306, 820 },
    ["shuffle"] = { 16898613777, 257, 869 },
    ["sigma-square"] = { 16898613777, 869, 514 },
    ["sigma"] = { 16898613777, 820, 563 },
    ["signal-high"] = { 16898613777, 771, 612 },
    ["signal-low"] = { 16898613777, 612, 771 },
    ["signal-medium"] = { 16898613777, 563, 820 },
    ["signal-zero"] = { 16898613777, 514, 869 },
    ["signal"] = { 16898613777, 918, 0 },
    ["signpost-big"] = { 16898613777, 869, 49 },
    ["signpost"] = { 16898613777, 820, 98 },
    ["siren"] = { 16898613777, 771, 147 },
    ["skip-back"] = { 16898613777, 147, 771 },
    ["skip-forward"] = { 16898613777, 98, 820 },
    ["skull"] = { 16898613777, 49, 869 },
    ["slack"] = { 16898613777, 0, 918 },
    ["slash"] = { 16898613777, 918, 257 },
    ["slice"] = { 16898613777, 869, 306 },
    ["sliders-horizontal"] = { 16898613777, 820, 355 },
    ["sliders-vertical"] = { 16898613777, 771, 404 },
    ["sliders"] = { 16898613777, 404, 771 },
    ["smartphone-charging"] = { 16898613777, 355, 820 },
    ["smartphone-nfc"] = { 16898613777, 306, 869 },
    ["smartphone"] = { 16898613777, 257, 918 },
    ["smile-plus"] = { 16898613777, 918, 514 },
    ["smile"] = { 16898613777, 869, 563 },
    ["snail"] = { 16898613777, 820, 612 },
    ["snowflake"] = { 16898613777, 771, 661 },
    ["sofa"] = { 16898613777, 661, 771 },
    ["soup"] = { 16898613777, 612, 820 },
    ["space"] = { 16898613777, 563, 869 },
    ["spade"] = { 16898613777, 514, 918 },
    ["sparkle"] = { 16898613777, 967, 0 },
    ["sparkles"] = { 16898613777, 918, 49 },
    ["speaker"] = { 16898613777, 869, 98 },
    ["speech"] = { 16898613777, 820, 147 },
    ["spell-check-2"] = { 16898613777, 771, 196 },
    ["spell-check"] = { 16898613777, 196, 771 },
    ["spline"] = { 16898613777, 147, 820 },
    ["split-square-horizontal"] = { 16898613777, 98, 869 },
    ["split-square-vertical"] = { 16898613777, 49, 918 },
    ["split"] = { 16898613777, 0, 967 },
    ["spray-can"] = { 16898613777, 967, 257 },
    ["sprout"] = { 16898613777, 918, 306 },
    ["square-activity"] = { 16898613777, 869, 355 },
    ["square-arrow-down-left"] = { 16898613777, 820, 404 },
    ["square-arrow-down-right"] = { 16898613777, 771, 453 },
    ["square-arrow-down"] = { 16898613777, 453, 771 },
    ["square-arrow-left"] = { 16898613777, 404, 820 },
    ["square-arrow-out-down-left"] = { 16898613777, 355, 869 },
    ["square-arrow-out-down-right"] = { 16898613777, 306, 918 },
    ["square-arrow-out-up-left"] = { 16898613777, 257, 967 },
    ["square-arrow-out-up-right"] = { 16898613777, 967, 514 },
    ["square-arrow-right"] = { 16898613777, 918, 563 },
    ["square-arrow-up-left"] = { 16898613777, 869, 612 },
    ["square-arrow-up-right"] = { 16898613777, 820, 661 },
    ["square-arrow-up"] = { 16898613777, 771, 710 },
    ["square-asterisk"] = { 16898613777, 710, 771 },
    ["square-bottom-dashed-scissors"] = { 16898613777, 661, 820 },
    ["square-check-big"] = { 16898613777, 612, 869 },
    ["square-check"] = { 16898613777, 563, 918 },
    ["square-chevron-down"] = { 16898613777, 514, 967 },
    ["square-chevron-left"] = { 16898613777, 967, 49 },
    ["square-chevron-right"] = { 16898613777, 918, 98 },
    ["square-chevron-up"] = { 16898613777, 869, 147 },
    ["square-code"] = { 16898613777, 820, 196 },
    ["square-dashed-bottom-code"] = { 16898613777, 196, 820 },
    ["square-dashed-bottom"] = { 16898613777, 147, 869 },
    ["square-dashed-kanban"] = { 16898613777, 98, 918 },
    ["square-dashed-mouse-pointer"] = { 16898613777, 49, 967 },
    ["square-divide"] = { 16898613777, 967, 306 },
    ["square-dot"] = { 16898613777, 918, 355 },
    ["square-equal"] = { 16898613777, 869, 404 },
    ["square-function"] = { 16898613777, 820, 453 },
    ["square-gantt-chart"] = { 16898613777, 453, 820 },
    ["square-kanban"] = { 16898613777, 404, 869 },
    ["square-library"] = { 16898613777, 355, 918 },
    ["square-m"] = { 16898613777, 306, 967 },
    ["square-menu"] = { 16898613777, 967, 563 },
    ["square-minus"] = { 16898613777, 918, 612 },
    ["square-mouse-pointer"] = { 16898613777, 869, 661 },
    ["square-parking-off"] = { 16898613777, 820, 710 },
    ["square-parking"] = { 16898613777, 771, 759 },
    ["square-pen"] = { 16898613777, 710, 820 },
    ["square-percent"] = { 16898613777, 661, 869 },
    ["square-pi"] = { 16898613777, 612, 918 },
    ["square-pilcrow"] = { 16898613777, 563, 967 },
    ["square-play"] = { 16898613777, 967, 98 },
    ["square-plus"] = { 16898613777, 918, 147 },
    ["square-power"] = { 16898613777, 869, 196 },
    ["square-radical"] = { 16898613777, 196, 869 },
    ["square-scissors"] = { 16898613777, 147, 918 },
    ["square-sigma"] = { 16898613777, 98, 967 },
    ["square-slash"] = { 16898613777, 967, 355 },
    ["square-split-horizontal"] = { 16898613777, 918, 404 },
    ["square-split-vertical"] = { 16898613777, 869, 453 },
    ["square-stack"] = { 16898613777, 453, 869 },
    ["square-terminal"] = { 16898613777, 404, 918 },
    ["square-user-round"] = { 16898613777, 355, 967 },
    ["square-user"] = { 16898613777, 967, 612 },
    ["square-x"] = { 16898613777, 918, 661 },
    ["square"] = { 16898613777, 869, 710 },
    ["squircle"] = { 16898613777, 820, 759 },
    ["squirrel"] = { 16898613777, 771, 808 },
    ["stamp"] = { 16898613777, 710, 869 },
    ["star-half"] = { 16898613777, 661, 918 },
    ["star-off"] = { 16898613777, 612, 967 },
    ["star"] = { 16898613777, 967, 147 },
    ["step-back"] = { 16898613777, 918, 196 },
    ["step-forward"] = { 16898613777, 196, 918 },
    ["stethoscope"] = { 16898613777, 147, 967 },
    ["sticker"] = { 16898613777, 967, 404 },
    ["sticky-note"] = { 16898613777, 918, 453 },
    ["stop-circle"] = { 16898613777, 453, 918 },
    ["store"] = { 16898613777, 404, 967 },
    ["stretch-horizontal"] = { 16898613777, 967, 661 },
    ["stretch-vertical"] = { 16898613777, 918, 710 },
    ["strikethrough"] = { 16898613777, 869, 759 },
    ["subscript"] = { 16898613777, 820, 808 },
    ["subtitles"] = { 16898613777, 771, 857 },
    ["sun-dim"] = { 16898613777, 710, 918 },
    ["sun-medium"] = { 16898613777, 661, 967 },
    ["sun-moon"] = { 16898613777, 967, 196 },
    ["sun-snow"] = { 16898613777, 196, 967 },
    ["sun"] = { 16898613777, 967, 453 },
    ["sunrise"] = { 16898613777, 453, 967 },
    ["sunset"] = { 16898613777, 967, 710 },
    ["superscript"] = { 16898613777, 918, 759 },
    ["swatch-book"] = { 16898613777, 869, 808 },
    ["swiss-franc"] = { 16898613777, 820, 857 },
    ["switch-camera"] = { 16898613777, 771, 906 },
    ["sword"] = { 16898613777, 710, 967 },
    ["swords"] = { 16898613777, 967, 759 },
    ["syringe"] = { 16898613777, 918, 808 },
    ["table-2"] = { 16898613777, 869, 857 },
    ["table-cells-merge"] = { 16898613777, 820, 906 },
    ["table-cells-split"] = { 16898613777, 771, 955 },
    ["table-columns-split"] = { 16898613777, 967, 808 },
    ["table-properties"] = { 16898613777, 918, 857 },
    ["table-rows-split"] = { 16898613777, 869, 906 },
    ["table"] = { 16898613777, 820, 955 },
    ["tablet-smartphone"] = { 16898613777, 967, 857 },
    ["tablet"] = { 16898613777, 918, 906 },
    ["tablets"] = { 16898613777, 869, 955 },
    ["tag"] = { 16898613777, 967, 906 },
    ["tags"] = { 16898613777, 918, 955 },
    ["tally-1"] = { 16898613777, 967, 955 },
    ["tally-2"] = { 16898613869, 771, 0 },
    ["tally-3"] = { 16898613869, 0, 771 },
    ["tally-4"] = { 16898613869, 771, 257 },
    ["tally-5"] = { 16898613869, 257, 771 },
    ["tangent"] = { 16898613869, 771, 514 },
    ["target"] = { 16898613869, 514, 771 },
    ["telescope"] = { 16898613869, 820, 0 },
    ["tent-tree"] = { 16898613869, 771, 49 },
    ["tent"] = { 16898613869, 49, 771 },
    ["terminal-square"] = { 16898613869, 0, 820 },
    ["terminal"] = { 16898613869, 820, 257 },
    ["test-tube-2"] = { 16898613869, 771, 306 },
    ["test-tube-diagonal"] = { 16898613869, 306, 771 },
    ["test-tube"] = { 16898613869, 257, 820 },
    ["test-tubes"] = { 16898613869, 820, 514 },
    ["text-cursor-input"] = { 16898613869, 771, 563 },
    ["text-cursor"] = { 16898613869, 563, 771 },
    ["text-quote"] = { 16898613869, 514, 820 },
    ["text-search"] = { 16898613869, 869, 0 },
    ["text-select"] = { 16898613869, 820, 49 },
    ["text"] = { 16898613869, 771, 98 },
    ["theater"] = { 16898613869, 98, 771 },
    ["thermometer-snowflake"] = { 16898613869, 49, 820 },
    ["thermometer-sun"] = { 16898613869, 0, 869 },
    ["thermometer"] = { 16898613869, 869, 257 },
    ["thumbs-down"] = { 16898613869, 820, 306 },
    ["thumbs-up"] = { 16898613869, 771, 355 },
    ["ticket-check"] = { 16898613869, 355, 771 },
    ["ticket-minus"] = { 16898613869, 306, 820 },
    ["ticket-percent"] = { 16898613869, 257, 869 },
    ["ticket-plus"] = { 16898613869, 869, 514 },
    ["ticket-slash"] = { 16898613869, 820, 563 },
    ["ticket-x"] = { 16898613869, 771, 612 },
    ["ticket"] = { 16898613869, 612, 771 },
    ["timer-off"] = { 16898613869, 563, 820 },
    ["timer-reset"] = { 16898613869, 514, 869 },
    ["timer"] = { 16898613869, 918, 0 },
    ["toggle-left"] = { 16898613869, 869, 49 },
    ["toggle-right"] = { 16898613869, 820, 98 },
    ["tornado"] = { 16898613869, 771, 147 },
    ["torus"] = { 16898613869, 147, 771 },
    ["touchpad-off"] = { 16898613869, 98, 820 },
    ["touchpad"] = { 16898613869, 49, 869 },
    ["tower-control"] = { 16898613869, 0, 918 },
    ["toy-brick"] = { 16898613869, 918, 257 },
    ["tractor"] = { 16898613869, 869, 306 },
    ["traffic-cone"] = { 16898613869, 820, 355 },
    ["train-front-tunnel"] = { 16898613869, 771, 404 },
    ["train-front"] = { 16898613869, 404, 771 },
    ["train-track"] = { 16898613869, 355, 820 },
    ["tram-front"] = { 16898613869, 306, 869 },
    ["trash-2"] = { 16898613869, 257, 918 },
    ["trash"] = { 16898613869, 918, 514 },
    ["tree-deciduous"] = { 16898613869, 869, 563 },
    ["tree-palm"] = { 16898613869, 820, 612 },
    ["tree-pine"] = { 16898613869, 771, 661 },
    ["trees"] = { 16898613869, 661, 771 },
    ["trello"] = { 16898613869, 612, 820 },
    ["trending-down"] = { 16898613869, 563, 869 },
    ["trending-up"] = { 16898613869, 514, 918 },
    ["triangle-alert"] = { 16898613869, 967, 0 },
    ["triangle-right"] = { 16898613869, 918, 49 },
    ["triangle"] = { 16898613869, 869, 98 },
    ["trophy"] = { 16898613869, 820, 147 },
    ["truck"] = { 16898613869, 771, 196 },
    ["turtle"] = { 16898613869, 196, 771 },
    ["tv-2"] = { 16898613869, 147, 820 },
    ["tv"] = { 16898613869, 98, 869 },
    ["twitch"] = { 16898613869, 49, 918 },
    ["twitter"] = { 16898613869, 0, 967 },
    ["type"] = { 16898613869, 967, 257 },
    ["umbrella-off"] = { 16898613869, 918, 306 },
    ["umbrella"] = { 16898613869, 869, 355 },
    ["underline"] = { 16898613869, 820, 404 },
    ["undo-2"] = { 16898613869, 771, 453 },
    ["undo-dot"] = { 16898613869, 453, 771 },
    ["undo"] = { 16898613869, 404, 820 },
    ["unfold-horizontal"] = { 16898613869, 355, 869 },
    ["unfold-vertical"] = { 16898613869, 306, 918 },
    ["ungroup"] = { 16898613869, 257, 967 },
    ["university"] = { 16898613869, 967, 514 },
    ["unlink-2"] = { 16898613869, 918, 563 },
    ["unlink"] = { 16898613869, 869, 612 },
    ["unlock-keyhole"] = { 16898613869, 820, 661 },
    ["unlock"] = { 16898613869, 771, 710 },
    ["unplug"] = { 16898613869, 710, 771 },
    ["upload-cloud"] = { 16898613869, 661, 820 },
    ["upload"] = { 16898613869, 612, 869 },
    ["usb"] = { 16898613869, 563, 918 },
    ["user-2"] = { 16898613869, 514, 967 },
    ["user-check-2"] = { 16898613869, 967, 49 },
    ["user-check"] = { 16898613869, 918, 98 },
    ["user-circle-2"] = { 16898613869, 869, 147 },
    ["user-circle"] = { 16898613869, 820, 196 },
    ["user-cog-2"] = { 16898613869, 196, 820 },
    ["user-cog"] = { 16898613869, 147, 869 },
    ["user-minus-2"] = { 16898613869, 98, 918 },
    ["user-minus"] = { 16898613869, 49, 967 },
    ["user-plus-2"] = { 16898613869, 967, 306 },
    ["user-plus"] = { 16898613869, 918, 355 },
    ["user-round-check"] = { 16898613869, 869, 404 },
    ["user-round-cog"] = { 16898613869, 820, 453 },
    ["user-round-minus"] = { 16898613869, 453, 820 },
    ["user-round-plus"] = { 16898613869, 404, 869 },
    ["user-round-search"] = { 16898613869, 355, 918 },
    ["user-round-x"] = { 16898613869, 306, 967 },
    ["user-round"] = { 16898613869, 967, 563 },
    ["user-search"] = { 16898613869, 918, 612 },
    ["user-square-2"] = { 16898613869, 869, 661 },
    ["user-square"] = { 16898613869, 820, 710 },
    ["user-x-2"] = { 16898613869, 771, 759 },
    ["user-x"] = { 16898613869, 710, 820 },
    ["user"] = { 16898613869, 661, 869 },
    ["users-2"] = { 16898613869, 612, 918 },
    ["users-round"] = { 16898613869, 563, 967 },
    ["users"] = { 16898613869, 967, 98 },
    ["utensils-crossed"] = { 16898613869, 918, 147 },
    ["utensils"] = { 16898613869, 869, 196 },
    ["utility-pole"] = { 16898613869, 196, 869 },
    ["variable"] = { 16898613869, 147, 918 },
    ["vault"] = { 16898613869, 98, 967 },
    ["vegan"] = { 16898613869, 967, 355 },
    ["venetian-mask"] = { 16898613869, 918, 404 },
    ["vibrate-off"] = { 16898613869, 869, 453 },
    ["vibrate"] = { 16898613869, 453, 869 },
    ["video-off"] = { 16898613869, 404, 918 },
    ["video"] = { 16898613869, 355, 967 },
    ["videotape"] = { 16898613869, 967, 612 },
    ["view"] = { 16898613869, 918, 661 },
    ["voicemail"] = { 16898613869, 869, 710 },
    ["volume-1"] = { 16898613869, 820, 759 },
    ["volume-2"] = { 16898613869, 771, 808 },
    ["volume-x"] = { 16898613869, 710, 869 },
    ["volume"] = { 16898613869, 661, 918 },
    ["vote"] = { 16898613869, 612, 967 },
    ["wallet-2"] = { 16898613869, 967, 147 },
    ["wallet-cards"] = { 16898613869, 918, 196 },
    ["wallet-minimal"] = { 16898613869, 196, 918 },
    ["wallet"] = { 16898613869, 147, 967 },
    ["wallpaper"] = { 16898613869, 967, 404 },
    ["wand-2"] = { 16898613869, 918, 453 },
    ["wand-sparkles"] = { 16898613869, 453, 918 },
    ["wand"] = { 16898613869, 404, 967 },
    ["warehouse"] = { 16898613869, 967, 661 },
    ["washing-machine"] = { 16898613869, 918, 710 },
    ["watch"] = { 16898613869, 869, 759 },
    ["waves"] = { 16898613869, 820, 808 },
    ["waypoints"] = { 16898613869, 771, 857 },
    ["webcam"] = { 16898613869, 710, 918 },
    ["webhook-off"] = { 16898613869, 661, 967 },
    ["webhook"] = { 16898613869, 967, 196 },
    ["weight"] = { 16898613869, 196, 967 },
    ["wheat-off"] = { 16898613869, 967, 453 },
    ["wheat"] = { 16898613869, 453, 967 },
    ["whole-word"] = { 16898613869, 967, 710 },
    ["wifi-off"] = { 16898613869, 918, 759 },
    ["wifi"] = { 16898613869, 869, 808 },
    ["wind"] = { 16898613869, 820, 857 },
    ["wine-off"] = { 16898613869, 771, 906 },
    ["wine"] = { 16898613869, 710, 967 },
    ["workflow"] = { 16898613869, 967, 759 },
    ["worm"] = { 16898613869, 918, 808 },
    ["wrap-text"] = { 16898613869, 869, 857 },
    ["wrench"] = { 16898613869, 820, 906 },
    ["x-circle"] = { 16898613869, 771, 955 },
    ["x-octagon"] = { 16898613869, 967, 808 },
    ["x-square"] = { 16898613869, 918, 857 },
    ["x"] = { 16898613869, 869, 906 },
    ["youtube"] = { 16898613869, 820, 955 },
    ["zap-off"] = { 16898613869, 967, 857 },
    ["zap"] = { 16898613869, 918, 906 },
    ["zoom-in"] = { 16898613869, 869, 955 },
    ["zoom-out"] = { 16898613869, 967, 906 },
}

local IconAliases = {
    house = "home",
    grid = "layout-grid",
    sliders = "sliders-horizontal",
    chevron = "chevron-down",
    arrow = "arrow-right",
    close = "x",
    minimize = "minus",
    resize = "move-diagonal-2",
    ["☾"] = "moon",
    ["⚙"] = "settings",
}
local CustomIcons = {}
local MissingIcons = {}

local function iconName(name)
    name = tostring(name or "layout-grid")
    name = name:gsub("^lucide:", ""):gsub("^lucide%-", "")
    name = name:gsub("(%l)(%u)", "%1-%2"):lower():gsub("_", "-")
    return IconAliases[name] or name
end

-- GetIcon returns a copy; callers cannot accidentally mutate the built-in atlas.
function Midnight:GetIcon(name)
    local key = iconName(name)
    local custom = CustomIcons[key]
    if custom then
        return table.clone(custom)
    end
    local data = LucideAtlas[key]
    if not data then
        return nil
    end
    return {
        Name = key,
        Image = "rbxassetid://" .. tostring(data[1]),
        ImageRectOffset = Vector2.new(data[2], data[3]),
        ImageRectSize = Vector2.new(48, 48),
    }
end

function Midnight:HasIcon(name)
    return self:GetIcon(name) ~= nil
end

function Midnight:ListIcons(query)
    local result, seen = {}, {}
    query = tostring(query or ""):lower()
    for _, source in ipairs({ LucideAtlas, CustomIcons }) do
        for name in pairs(source) do
            if not seen[name] and string.find(name, query, 1, true) then
                seen[name] = true
                table.insert(result, name)
            end
        end
    end
    table.sort(result)
    return result
end

-- Register a Roblox image or an atlas descriptor for additional/custom icons.
function Midnight:RegisterIcon(name, asset)
    local descriptor
    if type(asset) == "number" or type(asset) == "string" then
        local id = tostring(asset):match("^rbxassetid://(%d+)$") or tostring(asset):match("^%d+$")
        assert(id, "RegisterIcon expects a Roblox asset ID")
        descriptor = { Image = "rbxassetid://" .. id }
    else
        assert(type(asset) == "table" and type(asset.Image) == "string", "Invalid icon descriptor")
        descriptor = table.clone(asset)
        assert(descriptor.Image:match("^rbxassetid://%d+$"), "Icon images must use Roblox asset IDs")
    end
    descriptor.Name = iconName(name)
    descriptor.ImageRectOffset = descriptor.ImageRectOffset or Vector2.zero
    descriptor.ImageRectSize = descriptor.ImageRectSize or Vector2.zero
    assert(typeof(descriptor.ImageRectOffset) == "Vector2", "Invalid icon crop offset")
    assert(typeof(descriptor.ImageRectSize) == "Vector2", "Invalid icon crop size")
    CustomIcons[descriptor.Name] = descriptor
    return self
end

local function icon(scope, parent, name, position, size, token)
    local asset = Midnight:GetIcon(name)
    if not asset and (type(name) == "number" or tostring(name):match("^rbxassetid://%d+$")) then
        asset = {
            Image = tostring(name):match("^rbxassetid://") and tostring(name) or "rbxassetid://" .. tostring(name),
            ImageRectOffset = Vector2.zero,
            ImageRectSize = Vector2.zero,
        }
    end
    if not asset then
        local key = tostring(name)
        if not MissingIcons[key] then
            MissingIcons[key] = true
            warn("[Midnight UI] Unknown Lucide icon: " .. key .. ". Use ListIcons() or RegisterIcon().")
        end
        asset = Midnight:GetIcon("circle-help")
    end
    local root = new("ImageLabel", {
        Name = "Icon",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = position or UDim2.new(),
        Size = UDim2.fromOffset(size or 18, size or 18),
        Image = asset.Image,
        ImageRectOffset = asset.ImageRectOffset,
        ImageRectSize = asset.ImageRectSize,
        ScaleType = Enum.ScaleType.Fit,
        ResampleMode = Enum.ResamplerMode.Default,
    }, parent)
    local result = { Root = root, Token = token or "Muted" }
    function result:SetToken(nextToken, immediate)
        self.Token = nextToken
        if immediate then
            root.ImageColor3 = Midnight.Theme[self.Token] or Midnight.Theme.Text
        else
            animate(scope, root, { ImageColor3 = Midnight.Theme[self.Token] or Midnight.Theme.Text })
        end
    end
    function result:SetIcon(nextName)
        local nextAsset = Midnight:GetIcon(nextName)
        if not nextAsset then
            return false
        end
        root.Image = nextAsset.Image
        root.ImageRectOffset = nextAsset.ImageRectOffset
        root.ImageRectSize = nextAsset.ImageRectSize
        return true
    end
    themed(scope, function()
        result:SetToken(result.Token, true)
    end)
    return result
end

-- A diffuse light inside the surface, built without an image or a hard outline.
local function aura(scope, parent, token)
    local layers = {}
    for index = 1, 18 do
        local layer = frame(scope, parent, {
            Name = "DiffuseLight" .. index,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.4, 0.5),
            Size = UDim2.fromScale(1.02 - index * 0.014, 1.05 - index * 0.047),
            BackgroundTransparency = 1,
        }, token or "Accent")
        corner(layer, 24)
        local washGradient = new("UIGradient", {
            Name = "DiffuseFalloff",
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1),
                NumberSequenceKeypoint.new(0.3, 0.05),
                NumberSequenceKeypoint.new(0.62, 0.42),
                NumberSequenceKeypoint.new(1, 1),
            }),
        }, layer)
        themed(scope, function(theme)
            local tint = theme[token or "Accent"]
            layer.BackgroundColor3 = Color3.new(1, 1, 1)
            washGradient.Color = ColorSequence.new(tint, tint:Lerp(theme.Secondary, 0.3))
        end)
        table.insert(layers, layer)
    end
    return function(visible, immediate, strength)
        for _, layer in ipairs(layers) do
            local transparency = visible and (1 - (strength or 0.035) * 0.48) or 1
            if immediate then
                layer.BackgroundTransparency = transparency
            else
                animate(scope, layer, { BackgroundTransparency = transparency }, 0.25)
            end
        end
    end
end

-- Fade text into place without disturbing layout, caret, selection or value.
local function revealText(scope, object, text, enabled)
    object.Text = tostring(text)
    if not Midnight.ReducedMotion and enabled ~= false then
        object.TextTransparency = 0.26
        animate(scope, object, { TextTransparency = 0 }, 0.2)
    else
        object.TextTransparency = 0
    end
end

-- Filled, nested layers sit behind the shell. Its opaque surface hides their
-- centers, leaving a soft falloff without doubled borders or hard rings.
local function glow(scope, object)
    local layers = {}
    for index = 14, 1, -1 do
        local spread = index
        local base = 0.982 + 0.017 * (index / 14)
        local surface = frame(scope, object.Parent, {
            Name = "WindowHalo" .. index,
            Position = UDim2.fromOffset(16 - spread, 16 - spread),
            Size = UDim2.new(1, -32 + spread * 2, 1, -32 + spread * 2),
            BackgroundTransparency = base,
            ZIndex = 1,
        }, "Accent")
        corner(surface, 10 + spread)
        table.insert(layers, { Surface = surface, Base = base })
    end
    return layers
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
        input.TextTruncate = Enum.TextTruncate.None
        render()
    end)
    scope:Connect(input.FocusLost, function()
        focused = false
        input.TextTruncate = Enum.TextTruncate.AtEnd
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

local CatalogMemory = {}

local function displayName(value)
    if type(value) ~= "string" then return nil, "Enter a name" end
    local name = value:match("^%s*(.-)%s*$")
    if name == "" or #name > 64 then return nil, "Use a name between 1 and 64 bytes" end
    if name:find("[%c/\\]") then return nil, "Names cannot contain slashes or control characters" end
    return name
end

local function profileFile(name)
    -- Hex encoding is reversible and avoids collisions between user-visible names.
    return "profile_" .. name:gsub(".", function(character)
        return string.format("%02x", string.byte(character))
    end) .. ".json"
end

local function storeDocument(window, path, document)
    if not window.FileMode then return true end
    local ok, err = pcall(function()
        window.FileWrite(path, HttpService:JSONEncode(encode(document)))
    end)
    if not ok then
        window.FileMode = false
        report("Save failed; using memory", err)
    end
    return true
end

local function readDocument(window, path)
    if not window.FileMode then return nil end
    local ok, document = pcall(function()
        if not window.FileExists(path) then return nil end
        local decoded = decode(HttpService:JSONDecode(window.FileRead(path)))
        assert(type(decoded) == "table", "Invalid document")
        return decoded
    end)
    if not ok then return nil, tostring(document) end
    return document
end

function WindowMethods:_SaveCatalog()
    if not self.SaveEnabled then return false end
    CatalogMemory[self.ConfigFolder] = self.Catalog
    return storeDocument(self, self.ConfigFolder .. "/_midnight_catalog.json", self.Catalog)
end

local function configDocument(window)
    local values = copy(window.ConfigData)
    for flag, control in pairs(window.Controls) do values[flag] = control:Get() end
    return { Version = 2, Values = values, Theme = Midnight:GetTheme(true), ThemeName = Midnight.ThemeName }
end

local function readConfig(window, path)
    local document, err = readDocument(window, path)
    if err then return nil, err end
    document = document or copy(MemoryConfigs[path])
    if not document then return nil, "Profile has not been saved yet" end
    if (document.Version ~= 1 and document.Version ~= 2) or type(document.Values) ~= "table" then
        return nil, "Invalid profile document"
    end
    return document
end

function WindowMethods:_ApplyConfig(document, fireCallbacks)
    self.ConfigData = copy(document.Values)
    self.Loading = true
    local restored = {}
    for flag, control in pairs(self.Controls) do
        local value = document.Values[flag]
        if value == nil then value = control.Default end
        control:Set(copy(value), true)
        table.insert(restored, control)
    end
    -- All flags are restored before any callback can observe them.
    if fireCallbacks then
        for _, control in ipairs(restored) do
            if control.Scope.Alive then safe(control.Callback, control:Get()) end
        end
    end
    if type(document.Theme) == "table" then
        Midnight:SetTheme(document.Theme)
        Midnight.ThemeName = document.ThemeName or "Custom"
    end
    self.Loading = false
end

local function configure(window, options)
    window.SaveEnabled = options.SaveConfig == true
    window.ConfigFolder = configName(options.ConfigFolder or "MidnightConfigs")
    window.ConfigBase = tostring(options.ConfigName or game.PlaceId)
    window.ProfileName = window.ConfigBase
    window.ConfigPath = window.ConfigFolder .. "/" .. configName(window.ConfigBase) .. ".json"
    window.ConfigData = {}
    window.FileRead = capability("readfile")
    window.FileWrite = capability("writefile")
    window.FileExists = capability("isfile")
    window.FileMode = window.SaveEnabled and window.FileRead ~= nil
        and window.FileWrite ~= nil and window.FileExists ~= nil
    if window.FileMode then
        local makeFolder, isFolder = capability("makefolder"), capability("isfolder")
        local ok, err = pcall(function()
            if makeFolder and (not isFolder or not isFolder(window.ConfigFolder)) then
                makeFolder(window.ConfigFolder)
            end
        end)
        if not ok then
            report("Folder creation failed; using memory", err)
            window.FileMode = false
        end
    end
    if window.SaveEnabled and not window.FileMode then
        report("Configuration", "File access is unavailable; using session memory")
    end
    local catalog, err = readDocument(window, window.ConfigFolder .. "/_midnight_catalog.json")
    if err then report("Catalog load failed; using memory", err) end
    if type(catalog) ~= "table" or catalog.Version ~= 1 then
        catalog = CatalogMemory[window.ConfigFolder] or { Version = 1 }
    end
    catalog.Profiles = type(catalog.Profiles) == "table" and catalog.Profiles or {}
    catalog.Themes = type(catalog.Themes) == "table" and catalog.Themes or {}
    catalog.Settings = type(catalog.Settings) == "table" and catalog.Settings or {}
    catalog.Active = type(catalog.Active) == "table" and catalog.Active or {}
    window.Catalog = catalog
    CatalogMemory[window.ConfigFolder] = catalog
    -- Catalog entries contain basenames only; never accept paths from a config file.
    for name, filename in pairs(catalog.Profiles) do
        if type(name) ~= "string" or type(filename) ~= "string"
            or not filename:match("^[%w_%-]+%.json$") then
            catalog.Profiles[name] = nil
        end
    end
    catalog.Profiles[window.ConfigBase] = catalog.Profiles[window.ConfigBase]
        or (configName(window.ConfigBase) .. ".json")
    local remembered = catalog.Active[window.ConfigBase]
    if options.RememberProfile ~= false and remembered and catalog.Profiles[remembered] then
        window.ProfileName = remembered
    end
    window.ConfigPath = window.ConfigFolder .. "/" .. catalog.Profiles[window.ProfileName]
    window.LoadingEnabled = options.LoadingEnabled ~= false
    if type(catalog.Settings.LoadingEnabled) == "boolean" then
        window.LoadingEnabled = catalog.Settings.LoadingEnabled
    end
    for name, values in pairs(catalog.Themes) do
        if type(name) == "string" and type(values) == "table" and not ThemePresets[name] then
            local clean = copy(DefaultTheme)
            for key, value in pairs(values) do
                if DefaultTheme[key] and typeof(value) == "Color3" then clean[key] = value end
            end
            Midnight.CustomThemes[name] = clean
        end
    end
    if window.SaveEnabled then window:LoadConfig(false) end
end

function WindowMethods:SaveConfig()
    if not self.SaveEnabled or self.Destroyed then return false, "Configuration is disabled" end
    local document = configDocument(self)
    self.ConfigData = copy(document.Values)
    MemoryConfigs[self.ConfigPath] = copy(document)
    storeDocument(self, self.ConfigPath, document)
    self.Catalog.Active[self.ConfigBase] = self.ProfileName
    self:_SaveCatalog()
    return true
end

function WindowMethods:LoadConfig(fireCallbacks)
    local document, err = readConfig(self, self.ConfigPath)
    if not document then return false, err end
    self.Scope:Cancel(self.SaveJob)
    self.SaveJob = nil
    self:_ApplyConfig(document, fireCallbacks == true)
    return true
end

function WindowMethods:ListProfiles()
    local result = {}
    for name in pairs(self.Catalog.Profiles) do table.insert(result, name) end
    table.sort(result)
    return result
end

function WindowMethods:GetProfileName()
    return self.ProfileName
end

function WindowMethods:CreateProfile(name, useCurrentValues)
    if self.Destroyed or not self.SaveEnabled then return false, "Configuration is disabled" end
    local cleaned, err = displayName(name)
    if not cleaned then return false, err end
    if self.Catalog.Profiles[cleaned] then return false, "A profile with this name already exists" end
    local document = configDocument(self)
    if useCurrentValues == false then
        document.Values = {}
        for flag, control in pairs(self.Controls) do document.Values[flag] = copy(control.Default) end
        document.Theme = copy(DefaultTheme)
        document.ThemeName = "Midnight"
    end
    local filename = profileFile(cleaned)
    local path = self.ConfigFolder .. "/" .. filename
    MemoryConfigs[path] = copy(document)
    storeDocument(self, path, document)
    self.Catalog.Profiles[cleaned] = filename
    self:_SaveCatalog()
    return true, cleaned
end

function WindowMethods:SelectProfile(name, fireCallbacks)
    if self.Destroyed or not self.SaveEnabled then return false, "Configuration is disabled" end
    if name == self.ProfileName then return true end
    local filename = self.Catalog.Profiles[name]
    if not filename then return false, "Unknown profile" end
    local path = self.ConfigFolder .. "/" .. filename
    local document, err = readConfig(self, path)
    if not document then return false, err end
    self.Scope:Cancel(self.SaveJob)
    self.SaveJob = nil
    self:SaveConfig()
    self.ProfileName, self.ConfigPath = name, path
    self:_ApplyConfig(document, fireCallbacks ~= false)
    self.Catalog.Active[self.ConfigBase] = name
    self:_SaveCatalog()
    return true
end

function WindowMethods:SaveTheme(name, overwrite)
    if self.Destroyed then return false, "Window is destroyed" end
    local cleaned, err = displayName(name)
    if not cleaned then return false, err end
    if ThemePresets[cleaned] or cleaned == "Custom" then return false, "Built-in theme names are reserved" end
    if self.Catalog.Themes[cleaned] and not overwrite then return false, "A theme with this name already exists" end
    local values = Midnight:GetTheme(true)
    self.Catalog.Themes[cleaned] = values
    Midnight.CustomThemes[cleaned] = copy(values)
    Midnight.ThemeName = cleaned
    self:_SaveCatalog()
    self:_ScheduleSave()
    return true, cleaned
end

function WindowMethods:LoadTheme(name)
    local ok, err = Midnight:SetTheme(name)
    if ok then self:_ScheduleSave() end
    return ok, err
end

function WindowMethods:_ScheduleSave()
    if not self.SaveEnabled or self.Loading or self.Destroyed then return end
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
        if window.LoadingOverlay then
            if key == window.Keybind and not processed then window:SetVisible(not window.Visible) end
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
    if options.Theme == "Custom" then
        self:SetTheme(options.CustomTheme or {})
    elseif options.Theme then
        self:SetTheme(options.Theme)
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
        Name = "Shell",
        Position = UDim2.fromOffset(16, 16),
        Size = UDim2.new(1, -32, 1, -32),
        ZIndex = 2,
        ClipsDescendants = false,
    }, "Background")
    corner(window.Shell, 10)
    stroke(scope, window.Shell, "Border", 0.65)
    window.Glow = glow(scope, window.Shell)

    local title = frame(scope, window.Shell, {
        Name = "Title",
        Size = UDim2.new(1, 0, 0, 68),
        BackgroundTransparency = 0.96,
        ZIndex = 3,
    }, "Text")
    corner(title, 10)
    gradient(scope, title)
    local titleHit = button(scope, title, "", {
        Name = "TitleHit",
        Size = UDim2.new(1, -92, 1, 0),
    })
    local mark = frame(scope, titleHit, {
        Name = "Mark",
        Position = UDim2.fromOffset(16, 17),
        Size = UDim2.fromOffset(34, 34),
        BackgroundTransparency = 0.9,
    }, "Accent")
    corner(mark, 10)
    icon(scope, mark, "Moon", UDim2.fromOffset(7, 7), 20, "Accent")
    window.TitleLabel = label(scope, titleHit, options.Title or "Midnight UI", {
        Name = "TitleLabel",
        Position = UDim2.fromOffset(62, 13),
        Size = UDim2.new(1, -70, 0, 23),
        Font = Enum.Font.GothamBold,
        TextSize = 16,
    })
    window.SubTitleLabel = label(scope, titleHit, options.SubTitle or "Your space after dark", {
        Name = "SubTitleLabel",
        Position = UDim2.fromOffset(62, 36),
        Size = UDim2.new(1, -70, 0, 18),
        TextSize = 11,
    }, "Muted")
    local headerRule = frame(scope, title, {
        Name = "HeaderRule",
        Position = UDim2.new(0, 1, 1, -1),
        Size = UDim2.new(1, -2, 0, 1),
        BackgroundTransparency = 0.85,
    }, "Text")
    gradient(scope, headerRule)
    local minimize = button(scope, title, "", {
        Name = "Minimize",
        Position = UDim2.new(1, -86, 0, 17),
        Size = UDim2.fromOffset(32, 32),
        BackgroundTransparency = 0.5,
    })
    local close = button(scope, title, "", {
        Name = "Close",
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
        Name = "Body",
        Position = UDim2.fromOffset(14, 80),
        Size = UDim2.new(1, -28, 1, -102),
        BackgroundTransparency = 1,
        ZIndex = 3,
    })
    window.NavLabel = label(scope, window.Body, "WORKSPACE", {
        Name = "NavLabel",
        Size = UDim2.fromOffset(128, 16),
        Position = UDim2.fromOffset(10, 0),
        TextSize = 9,
        Font = Enum.Font.GothamBold,
        TextTransparency = 0.25,
    }, "Muted")
    window.TabBar = new("ScrollingFrame", {
        Name = "TabBar",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        ScrollBarThickness = 2,
    }, window.Body)
    color(scope, window.TabBar, "ScrollBarImageColor3", "Accent")
    window.TabLayout = layout(window.TabBar, 5)
    window.NavDivider = frame(scope, window.Body, {
        Name = "NavDivider",
        Size = UDim2.new(0, 1, 1, 24),
        BackgroundTransparency = 0.55,
    }, "Border")
    window.Pages = frame(scope, window.Body, {
        Name = "Pages",
        BackgroundTransparency = 1,
        ClipsDescendants = true,
    })
    -- The footer intentionally contains only the resize handle.
    window.ResizeHandle = button(scope, window.Shell, "", {
        Name = "ResizeHandle",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.fromScale(1, 1),
        Size = UDim2.fromOffset(30, 30),
        ZIndex = 5,
    })
    icon(scope, window.ResizeHandle, "Resize", UDim2.fromOffset(9, 9), 13, "Muted")
    window.Responsive = options.Responsive ~= false
    window.MobileReopen = button(scope, window.Gui, "", {
        Name = "MobileReopen",
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
                animate(scope, layer.Surface, {
                    BackgroundTransparency = math.clamp(layer.Base - (bright and 0.001 or 0), 0, 1),
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
    self.NavDivider.Position = UDim2.fromOffset(137, -12)
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

-- Schedule work that is automatically canceled when this window is destroyed.
function WindowMethods:Delay(seconds, callback)
    if self.Destroyed then return nil end
    return self.Scope:Delay(math.max(0, finite(seconds, 0)), callback)
end

-- Cancel work previously scheduled with Window:Delay.
function WindowMethods:CancelDelay(job)
    if job then self.Scope:Cancel(job) end
end

function WindowMethods:SetStatus(text)
    if not self.Destroyed then
        self.Status = tostring(text)
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
        Name = "Tab_" .. tostring(options.Title or "Untitled"):gsub("[^%w_%-]", ""),
        Size = self.TopTabs and UDim2.fromOffset(128, 38) or UDim2.new(1, -3, 0, 40),
        BackgroundTransparency = 1,
        LayoutOrder = #self.Tabs + 1,
    })
    corner(tab.NavButton, 8)
    tab.NavButton.ClipsDescendants = true
    local setLight = aura(scope, tab.NavButton, "Accent")
    local symbol = icon(scope, tab.NavButton, options.Icon or "Grid", UDim2.fromOffset(11, 11), 18, "Muted")
    function tab:SetIcon(name)
        if not scope.Alive then
            return false
        end
        return symbol:SetIcon(name)
    end
    local caption = label(scope, tab.NavButton, options.Title or "Tab", {
        Name = "Caption",
        Position = UDim2.fromOffset(39, 0),
        Size = UDim2.new(1, -48, 1, 0),
        TextSize = 12,
        Font = Enum.Font.GothamMedium,
    })
    tab.Page = new("CanvasGroup", {
        Name = "Page_" .. tostring(options.Title or "Untitled"):gsub("[^%w_%-]", ""),
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
            BackgroundTransparency = selected and 0.38 or (over and 0.75 or 1),
        })
        setLight(selected, immediate, 0.045)
        set(caption, { TextColor3 = selected and Midnight.Theme.Text or Midnight.Theme.Muted })
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
        Name = "Object",
        Size = UDim2.new(1, -6, 0, height),
        LayoutOrder = container.Order,
    }, "Panel")
    corner(object, 8)
    -- UIStroke is a modifier, so it never becomes a UIListLayout item.
    -- A full-height decoration Frame here creates an AutomaticSize feedback loop.
    local outline = stroke(scope, object, "Border", 0.8)
    outline.BorderStrokePosition = Enum.BorderStrokePosition.Inner
    return scope, object, outline
end

local function captions(scope, object, options, reserve)
    local hasDescription = options.Description and options.Description ~= ""
    local title = label(scope, object, options.Title or "Control", {
        Name = "Title",
        Position = UDim2.fromOffset(14, hasDescription and 9 or 0),
        Size = UDim2.new(1, -(reserve or 24), 0, hasDescription and 21 or 44),
        Font = Enum.Font.GothamMedium,
    })
    local description
    if hasDescription then
        description = label(scope, object, options.Description, {
            Name = "Description",
            Position = UDim2.fromOffset(14, 30),
            Size = UDim2.new(1, -28, 0, 19),
            TextSize = 11,
        }, "Muted")
    end
    return title, description
end

local function control(container, options, height)
    local scope, object, outline = row(container, height)
    object.Name = tostring(options.Name or options.Flag or options.Title or "Control"):gsub("[^%w_%-]", "")
    if object.Name == "" then
        object.Name = "Control" .. tostring(container.Order)
    end
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
    -- Read-only, automatically sized labels must not receive a layout child.
    if self.Root.AutomaticSize == Enum.AutomaticSize.Y then return self end
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
        Name = "Section_" .. tostring(options.Title or "Untitled"):gsub("[^%w_%-]", ""),
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
        Name = "Marker",
        Position = UDim2.fromOffset(1, 11),
        Size = UDim2.fromOffset(3, 14),
        BackgroundTransparency = 0.15,
    }, "Accent")
    corner(marker, 2)
    local title = label(scope, header, options.Title or "Section", {
        Name = "Title",
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
        Name = "Title",
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None,
        LayoutOrder = 1,
    })
    local description = label(scope, root, options.Description or "", {
        Name = "Description",
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None,
        TextSize = 12,
        LayoutOrder = 2,
        Visible = options.Description ~= nil and options.Description ~= "",
    }, "Muted")
    function item:Set(text, details)
        revealText(scope, title, text, options.Animate)
        self.Value = title.Text
        if details ~= nil then
            revealText(scope, description, details, options.Animate)
            description.Visible = description.Text ~= ""
        end
        return self
    end
    if options.Style == "Hero" then
        title.TextSize = 20
        title.Font = Enum.Font.GothamBold
        description.TextSize = 12
        local wash = new("UIGradient", {
            Name = "Wash",
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
        Name = "Badge",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -14, 0.5, 0),
        Size = UDim2.fromOffset(28, 28),
        BackgroundTransparency = 0.91,
    }, token)
    corner(badge, 8)
    local symbol = icon(scope, badge, options.Icon or "Arrow", UDim2.fromScale(0.5, 0.5), 18, token)
    -- Scale around the center of the badge, not the image's top-left corner.
    symbol.Root.AnchorPoint = Vector2.new(0.5, 0.5)
    local scale = new("UIScale", { Name = "PressScale", Scale = 1 }, symbol.Root)
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
        Primary = options.Style == "Primary",
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
        Name = "Track",
        Position = UDim2.new(1, -58, 0, 12),
        Size = UDim2.fromOffset(44, 22),
    }, "Raised")
    corner(track, 11)
    local border = stroke(scope, track, "Accent", 0.8)
    local knob = frame(scope, track, {
        Name = "Knob",
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
        local thumbColor = self.Value and theme.OnAccent or theme.Text
        if immediate then
            track.BackgroundColor3 = goals.BackgroundColor3
            knob.Position = position
            knob.BackgroundColor3 = thumbColor
            border.Transparency = self.Value and 0.05 or 0.8
        else
            animate(scope, track, goals)
            animate(scope, knob, { Position = position, BackgroundColor3 = thumbColor })
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
    local title = captions(scope, root, options, 114)
    title.TextSize = 14
    title.Font = Enum.Font.GothamMedium
    local minimum = finite(options.Min, 0)
    local maximum = finite(options.Max, 100)
    if maximum < minimum then
        minimum, maximum = maximum, minimum
    end
    local step = math.max(0, finite(options.Increment, 1))
    local valueBadge = frame(scope, root, {
        Name = "SliderValueBadge",
        Position = UDim2.new(1, -96, 0, 9),
        Size = UDim2.fromOffset(82, 28),
        BackgroundTransparency = 0.15,
    }, "Raised")
    corner(valueBadge, 7)
    local valueLabel = label(scope, valueBadge, "", {
        Name = "SliderValue",
        Position = UDim2.fromOffset(5, 0),
        Size = UDim2.new(1, -10, 1, 0),
        TextXAlignment = Enum.TextXAlignment.Center,
        TextSize = 14,
        Font = Enum.Font.GothamBold,
    }, "Text")
    local hit = button(scope, root, "", {
        Name = "Hit",
        Position = UDim2.new(0, 14, 1, -38),
        Size = UDim2.new(1, -28, 0, 32),
    })
    local track = frame(scope, hit, {
        Name = "Track",
        Position = UDim2.new(0, 0, 0.5, -3),
        Size = UDim2.new(1, 0, 0, 6),
    }, "Raised")
    corner(track, 6)
    local fill = frame(scope, track, { Size = UDim2.fromScale(0, 1) }, "Accent")
    corner(fill, 6)
    gradient(scope, fill)
    local knob = frame(scope, track, {
        Name = "Knob",
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

-- Progress bars --------------------------------------------------------------

local function progressSurface(scope, parent, properties, backdrop)
    local track = frame(scope, parent, properties, "Raised")
    track.Name = "ProgressTrack"
    track.ClipsDescendants = true
    corner(track, 6)
    local fill = frame(scope, track, {
        Name = "ProgressFill",
        Size = UDim2.fromScale(0, 1),
    }, "Accent")
    corner(fill, 6)
    local sheen = new("UIGradient", { Name = "ProgressGradient" }, fill)
    themed(scope, function(theme)
        local a, b = theme.Accent, theme.Secondary
        if backdrop then
            a, b = readable(a, { backdrop }, 3), readable(b, { backdrop }, 3)
            track.BackgroundColor3 = Color3.fromRGB(37, 41, 52)
        end
        fill.BackgroundColor3 = Color3.new(1, 1, 1)
        sheen.Color = ColorSequence.new(a, b)
    end)
    local state = {
        Indeterminate = false,
        Alpha = 0,
        Displayed = 0,
        Velocity = 0,
        Initialized = false,
        Phase = 0,
    }
    local function render()
        if state.Indeterminate then
            -- Analytic motion avoids restarting a tween every few frames.
            local phase = Midnight.ReducedMotion and 0 or state.Phase
            local width = 0.24 + 0.1 * (0.5 + 0.5 * math.sin(phase * 2))
            local left = (1 - width) * (0.5 - 0.5 * math.cos(phase))
            fill.Position = UDim2.fromScale(left, 0)
            fill.Size = UDim2.fromScale(width, 1)
        else
            fill.Position = UDim2.new()
            fill.Size = UDim2.fromScale(state.Displayed, 1)
        end
        safe(state.OnChanged, state.Displayed, state.Indeterminate)
    end
    function state:Set(alpha)
        alpha = math.clamp(alpha, 0, 1)
        local same = self.Initialized and not self.Indeterminate and self.Alpha == alpha
        self.Indeterminate = false
        self.Alpha = alpha
        if not same then self.SettledCallback = nil end
        if not self.Initialized or Midnight.ReducedMotion then
            self.Displayed, self.Velocity = alpha, 0
        end
        self.Initialized = true
        render()
    end
    function state:SetIndeterminate(enabled)
        local nextMode = enabled == true
        if self.Indeterminate == nextMode then return end
        self.Indeterminate = nextMode
        self.Velocity = 0
        self.SettledCallback = nil
        if nextMode then self.Phase = math.pi / 2 end
        render()
    end
    function state:WhenSettled(callback)
        if not self.Indeterminate and self.Displayed == self.Alpha then
            safe(callback)
        else
            self.SettledCallback = callback
        end
    end
    scope:Connect(RunService.RenderStepped, function(delta)
        if not Midnight.Visible or not isVisible(parent) then return end
        if state.Indeterminate then
            if Midnight.ReducedMotion then
                render()
                return
            end
            state.Phase = (state.Phase + math.min(delta, 0.1) * 2.4) % (math.pi * 2)
            render()
            return
        end
        if state.Displayed ~= state.Alpha then
            if Midnight.ReducedMotion then
                state.Displayed, state.Velocity = state.Alpha, 0
            else
                -- Carry velocity across target changes instead of canceling a tween.
                state.Displayed, state.Velocity = TweenService:SmoothDamp(
                    state.Displayed, state.Alpha, state.Velocity, 0.16, math.huge, math.min(delta, 0.1)
                )
                state.Displayed = math.clamp(state.Displayed, 0, 1)
                if math.abs(state.Displayed - state.Alpha) < 0.0005 and math.abs(state.Velocity) < 0.005 then
                    state.Displayed, state.Velocity = state.Alpha, 0
                end
            end
            render()
        end
        if state.Displayed == state.Alpha and state.SettledCallback then
            local callback = state.SettledCallback
            state.SettledCallback = nil
            safe(callback)
        end
    end)
    return state, track, fill
end

function ContainerMethods:ProgressBar(options)
    options = option(options)
    local item, scope, root = control(self, options, options.Description and 98 or 76)
    local title, description = captions(scope, root, options, 94)
    title.Name = "ProgressTitle"
    local percentage = label(scope, root, "0%", {
        Name = "ProgressValue",
        Position = UDim2.new(1, -76, 0, 9),
        Size = UDim2.fromOffset(62, 26),
        TextXAlignment = Enum.TextXAlignment.Right,
        TextSize = 14,
        Font = Enum.Font.GothamBold,
    })
    local bar = progressSurface(scope, root, {
        Position = UDim2.new(0, 14, 1, -23),
        Size = UDim2.new(1, -28, 0, 7),
    })
    bar.OnChanged = function(displayed, indeterminate)
        percentage.Text = indeterminate and "..." or (tostring(math.round(displayed * 100)) .. "%")
    end
    local minimum, maximum = finite(options.Min, 0), finite(options.Max, 100)
    if maximum <= minimum then maximum = minimum + 1 end
    local completed = false
    function item:Set(value, silent)
        if not scope.Alive then return self end
        value = finite(value, nil)
        if not value then return self end
        value = math.clamp(value, minimum, maximum)
        local changed = self.Value ~= value
        self.Value = value
        local alpha = (value - minimum) / (maximum - minimum)
        bar:Set(alpha)
        self:_Commit(silent == true, changed)
        if alpha == 1 and not completed and not silent then safe(options.OnComplete, value) end
        completed = alpha == 1
        return self
    end
    function item:SetIndeterminate(enabled)
        if scope.Alive then
            bar:SetIndeterminate(enabled)
        end
        return self
    end
    function item:SetText(text, details)
        if scope.Alive then
            revealText(scope, title, text)
            if description and details ~= nil then revealText(scope, description, details) end
        end
        return self
    end
    function item:Complete(text)
        self:Set(maximum)
        if text then self:SetText(text) end
        return self
    end
    item:_Register(options.Flag, finite(options.Default, minimum))
    item:SetIndeterminate(options.Indeterminate == true)
    return item
end

ContainerMethods.Progress = ContainerMethods.ProgressBar

-- Window loading overlay -----------------------------------------------------

function WindowMethods:SetLoadingEnabled(enabled)
    if self.Destroyed then return end
    self.LoadingEnabled = enabled == true
    self.Catalog.Settings.LoadingEnabled = self.LoadingEnabled
    self:_SaveCatalog()
    if not self.LoadingEnabled and self.LoadingOverlay then self.LoadingOverlay:Close() end
end

function WindowMethods:ShowLoading(options)
    options = option(options)
    if self.LoadingOverlay then self.LoadingOverlay:Close(true) end
    local handle = {
        Closed = false,
        Aborted = false,
        Skipped = self.Destroyed or not self.LoadingEnabled,
    }
    local window = self
    -- Closing hides the overlay; aborting additionally signals cancellation.
    -- External operations should honor Aborted or stop work in OnAbort.
    function handle:Abort()
        if self.Closed or self.Completing or self.Finished or window.Destroyed then return false end
        self.Aborted = true
        self:Close()
        safe(options.OnAbort, self)
        return true
    end
    if handle.Skipped then
        function handle:Set() return self end
        function handle:SetInfo() return self end
        function handle:Close() self.Closed = true end
        function handle:Complete() self:Close() return self end
        return handle
    end
    releaseBindings(self)
    cancelCapture(self)
    local focusedInput = UserInputService:GetFocusedTextBox()
    if focusedInput then focusedInput:ReleaseFocus() end
    if self.OpenPopover then self.OpenPopover:SetOpen(false) end
    if self.Modal then self.Modal:Close(false) end
    self:SetMinimized(false)
    self:SetVisible(true)
    local scope = Scope.new(self.Scope)
    local overlay = new("CanvasGroup", {
        Name = "LoadingOverlay",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.08,
        GroupTransparency = 1,
        ZIndex = 80,
        Active = true,
        ClipsDescendants = true,
    }, self.Shell)
    corner(overlay, 10)
    button(scope, overlay, "", {
        Name = "LoadingInputBlocker",
        Size = UDim2.fromScale(1, 1),
        Active = true,
        ZIndex = 1,
    })
    local abortable = options.Abortable == true
    local panelHeight = abortable and 254 or 206
    local panel = frame(scope, overlay, {
        Name = "LoadingContent",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.new(0.84, 0, 0, panelHeight),
        BackgroundTransparency = 1,
        ZIndex = 2,
    })
    new("UISizeConstraint", { MaxSize = Vector2.new(430, panelHeight) }, panel)
    local emblem = frame(scope, panel, {
        Name = "LoadingEmblem",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.fromOffset(64, 64),
        BackgroundTransparency = 1,
    })
    local emblemScale = new("UIScale", { Name = "EmblemEntrance", Scale = 0.92 }, emblem)
    local core = frame(scope, emblem, {
        Name = "EmblemCore",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(42, 42),
        BackgroundTransparency = 0.94,
    }, "Accent")
    corner(core, 21)
    local symbol = icon(scope, emblem, "moon", UDim2.fromOffset(21, 21), 22, "Accent")
    symbol.Root.Name = "EmblemSymbol"
    local ring = frame(scope, emblem, {
        Name = "OrbitRing",
        Position = UDim2.fromOffset(3, 3),
        Size = UDim2.fromOffset(58, 58),
        BackgroundTransparency = 1,
    })
    corner(ring, 29)
    local trackBorder = stroke(scope, ring, "Muted", 0.9, 1)
    local orbit = frame(scope, emblem, {
        Name = "OrbitLight",
        Position = UDim2.fromOffset(3, 3),
        Size = UDim2.fromOffset(58, 58),
        BackgroundTransparency = 1,
    })
    corner(orbit, 29)
    local arc = stroke(scope, orbit, "Accent", 0.08, 1.6)
    local arcGradient = new("UIGradient", {
        Name = "OrbitFalloff",
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.35, 0.98),
            NumberSequenceKeypoint.new(0.7, 0.5),
            NumberSequenceKeypoint.new(1, 0),
        }),
    }, arc)
    local halo = stroke(scope, orbit, "Accent", 0.96, 5)
    local haloGradient = new("UIGradient", {
        Name = "OrbitBloomFalloff",
        Transparency = arcGradient.Transparency,
    }, halo)
    themed(scope, function(theme)
        local accent = readable(theme.Accent, { Color3.new(0, 0, 0) }, 4.5)
        local secondary = readable(theme.Secondary, { Color3.new(0, 0, 0) }, 4.5)
        symbol.Root.ImageColor3 = accent
        core.BackgroundColor3 = accent
        trackBorder.Color = Color3.fromRGB(115, 128, 157)
        arc.Color = Color3.new(1, 1, 1)
        halo.Color = Color3.new(1, 1, 1)
        arcGradient.Color = ColorSequence.new(secondary, accent)
        haloGradient.Color = arcGradient.Color
    end)
    local heading = label(scope, panel, options.Title or "Preparing your workspace", {
        Name = "LoadingTitle",
        Position = UDim2.fromOffset(0, 77),
        Size = UDim2.new(1, 0, 0, 25),
        Font = Enum.Font.GothamBold,
        TextSize = 17,
        TextXAlignment = Enum.TextXAlignment.Center,
    })
    local detail = label(scope, panel, options.Content or "Getting everything ready...", {
        Name = "LoadingStep",
        Position = UDim2.fromOffset(0, 110),
        Size = UDim2.new(1, 0, 0, 20),
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Center,
    })
    local info = label(scope, panel, options.Info or "", {
        Name = "LoadingInfo",
        Position = UDim2.fromOffset(0, 174),
        Size = UDim2.new(1, -55, 0, 20),
        TextSize = 11,
    })
    local percent = label(scope, panel, "", {
        Name = "LoadingPercentage",
        Position = UDim2.new(1, -50, 0, 174),
        Size = UDim2.fromOffset(50, 20),
        TextSize = 12,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    themed(scope, function()
        heading.TextColor3 = Color3.fromRGB(240, 243, 250)
        detail.TextColor3 = Color3.fromRGB(184, 192, 210)
        info.TextColor3 = Color3.fromRGB(154, 163, 184)
        percent.TextColor3 = Color3.fromRGB(240, 243, 250)
    end)
    local bar = progressSurface(scope, panel, {
        Position = UDim2.fromOffset(0, 155),
        Size = UDim2.new(1, 0, 0, 5),
    }, Color3.new(0, 0, 0))
    bar.OnChanged = function(displayed, indeterminate)
        local value = math.round(displayed * 100)
        if value == 100 and displayed < 1 then value = 99 end
        percent.Text = indeterminate and "..." or (tostring(value) .. "%")
    end
    local abortButton
    if abortable then
        abortButton = button(scope, panel, options.AbortText or "Abort", {
            Name = "LoadingAbortButton",
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, 208),
            Size = UDim2.fromOffset(120, 36),
            BackgroundTransparency = 0,
            TextSize = 12,
            Active = true,
        })
        corner(abortButton, 8)
        local edge = stroke(scope, abortButton, "Border", 0.65)
        edge.BorderStrokePosition = Enum.BorderStrokePosition.Inner
        themed(scope, function()
            abortButton.BackgroundColor3 = Color3.fromRGB(20, 25, 38)
            abortButton.TextColor3 = Color3.fromRGB(225, 231, 243)
            edge.Color = Color3.fromRGB(81, 95, 124)
        end)
        scope:Connect(abortButton.MouseEnter, function()
            if not handle.Closed and not handle.Completing then
                animate(scope, abortButton, { BackgroundColor3 = Color3.fromRGB(32, 39, 56) }, 0.18)
            end
        end)
        scope:Connect(abortButton.MouseLeave, function()
            animate(scope, abortButton, { BackgroundColor3 = Color3.fromRGB(20, 25, 38) }, 0.18)
        end)
        scope:Connect(abortButton.Activated, function() handle:Abort() end)
    end
    handle.AbortButton = abortButton
    local phase = 0
    scope:Connect(RunService.RenderStepped, function(delta)
        if handle.Closed or handle.Finished or Midnight.ReducedMotion
            or not Midnight.Visible or not window.Visible then return end
        phase = (phase + math.min(delta, 0.1)) % 120
        arcGradient.Rotation = (phase * 125) % 360
        haloGradient.Rotation = arcGradient.Rotation
        core.BackgroundTransparency = 0.94 + math.sin(phase * 2.2) * 0.018
    end)
    function handle:Set(value, text, information)
        if self.Closed or self.Completing or not scope.Alive then return self end
        local number = finite(value, nil)
        if number then
            number = math.clamp(number, 0, 100)
            bar:Set(number / 100)
        else
            bar:SetIndeterminate(true)
        end
        if text ~= nil then revealText(scope, detail, text) end
        if information ~= nil then revealText(scope, info, information) end
        return self
    end
    function handle:SetInfo(text)
        if scope.Alive and not self.Closed then revealText(scope, info, text) end
        return self
    end
    function handle:Close(immediate)
        if not scope.Alive then return end
        if self.Closed and not immediate then return end
        self.Closed = true
        local function dispose()
            if window.LoadingOverlay == self then window.LoadingOverlay = nil end
            scope:Destroy()
            overlay:Destroy()
        end
        if immediate or Midnight.ReducedMotion then
            dispose()
        else
            animate(scope, emblemScale, { Scale = 0.94 }, 0.25)
            animate(scope, overlay, { GroupTransparency = 1 }, 0.25)
            scope:Delay(0.26, dispose)
        end
    end
    function handle:Complete(text)
        if self.Closed or self.Completing then return self end
        self:Set(100)
        self.Completing = true
        if abortButton then
            abortButton.Active = false
            animate(scope, abortButton, { TextTransparency = 0.55 }, 0.15)
        end
        bar:WhenSettled(function()
            if self.Closed or not scope.Alive then return end
            self.Finished = true
            symbol:SetIcon("check")
            revealText(scope, detail, text or "Ready")
            animate(scope, arc, { Transparency = 0.5 }, 0.2)
            animate(scope, core, { BackgroundTransparency = 0.9 }, 0.2)
            scope:Delay(0.25, function() self:Close() end)
        end)
        return self
    end
    handle.Root = overlay
    self.LoadingOverlay = handle
    handle:Set(options.Progress, options.Content, options.Info)
    animate(scope, emblemScale, { Scale = 1 }, 0.3)
    animate(scope, overlay, { GroupTransparency = 0 }, 0.25)
    return handle
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
        Name = "SelectedText",
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
        Name = "Empty",
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
                Name = "EntryRoot",
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
                    Name = "Caption",
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
        Name = "KeyButton",
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
        Name = "Input",
        Position = UDim2.new(0, 12, 1, -40),
        Size = UDim2.new(1, -24, 0, 32),
        MultiLine = options.MultiLine == true,
    })
    item.Input = input
    scope:Connect(input:GetPropertyChangedSignal("Text"), function()
        if input:IsFocused() and not item.Disabled then
            if options.Animate ~= false and not Midnight.ReducedMotion then
                input.TextTransparency = 0.1
                animate(scope, input, { TextTransparency = 0 }, 0.15)
            end
            safe(options.OnChanged, input.Text)
        end
    end)
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
        Name = "Preview",
        Position = UDim2.new(1, -60, 0, 10),
        Size = UDim2.fromOffset(46, 26),
        BackgroundTransparency = 0,
    })
    corner(preview, 6)
    stroke(scope, preview, "Text", 0.65)
    local panel = frame(scope, root, {
        Name = "Panel",
        Position = UDim2.fromOffset(12, baseHeight),
        Size = UDim2.new(1, -24, 0, 278),
        BackgroundTransparency = 1,
        Visible = false,
    })
    local sv = frame(scope, panel, {
        Name = "Sv",
        Size = UDim2.new(1, 0, 0, 144),
        ClipsDescendants = true,
    })
    corner(sv, 8)
    local white = frame(scope, sv, {
        Name = "White",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(1, 1, 1),
    })
    corner(white, 8)
    local whiteGradient = new("UIGradient", {}, white)
    whiteGradient.Transparency = NumberSequence.new(0, 1)
    local black = frame(scope, sv, {
        Name = "Black",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
    })
    corner(black, 8)
    local blackGradient = new("UIGradient", { Rotation = 90 }, black)
    blackGradient.Transparency = NumberSequence.new(1, 0)
    local svCursor = frame(scope, sv, {
        Name = "SvCursor",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(10, 10),
        BackgroundTransparency = 1,
        ZIndex = 3,
    })
    corner(svCursor, 5)
    new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }, svCursor)
    local svHit = button(scope, sv, "", {
        Name = "SvHit",
        Size = UDim2.fromScale(1, 1),
        ZIndex = 4,
    })
    local hueHit = button(scope, panel, "", {
        Name = "HueHit",
        Position = UDim2.fromOffset(0, 150),
        Size = UDim2.new(1, 0, 0, 30),
    })
    local hueTrack = frame(scope, hueHit, {
        Name = "HueTrack",
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
        Name = "HueCursor",
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
        Name = "Hex",
        Position = UDim2.fromOffset(0, 229),
        Size = UDim2.new(1, -120, 0, 32),
        TextSize = 11,
    })
    local copyButton = button(scope, panel, "Copy", {
        Name = "CopyButton",
        Position = UDim2.new(1, -114, 0, 229),
        Size = UDim2.fromOffset(54, 32),
        BackgroundTransparency = 0,
        TextSize = 11,
    })
    local pasteButton = button(scope, panel, "Paste", {
        Name = "PasteButton",
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
        Name = "Holder",
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
    local width = math.min(340, math.max(160, host.Gui.AbsoluteSize.X - 32))
    local slot = frame(scope, host.Holder, {
        Name = "NotificationSlot",
        Size = UDim2.fromOffset(width, 100),
        BackgroundTransparency = 1,
        LayoutOrder = NotificationId,
    })
    local group = new("CanvasGroup", {
        Name = "Group",
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromOffset(24, 0),
        BackgroundTransparency = 1,
        GroupTransparency = 1,
    }, slot)
    local card = frame(scope, group, {
        Name = "Card",
        Position = UDim2.fromOffset(4, 4),
        Size = UDim2.new(1, -8, 1, -8),
    }, "Panel")
    corner(card, 10)
    stroke(scope, card, "Border", 0.82)
    local setLight = aura(scope, card, token)
    setLight(true, true, 0.018)
    local badge = frame(scope, card, {
        Name = "Badge",
        Position = UDim2.fromOffset(12, 13),
        Size = UDim2.fromOffset(28, 28),
        BackgroundTransparency = 0.9,
    }, token)
    corner(badge, 8)
    local notificationIcons = {
        Info = "info",
        Success = "circle-check",
        Error = "circle-x",
        Warning = "triangle-alert",
    }
    icon(scope, badge, options.Icon or notificationIcons[options.Type] or "info", UDim2.fromOffset(4, 4), 20, token)
    local heading = label(scope, card, options.Title or "Notification", {
        Name = "NotificationTitle",
        Position = UDim2.fromOffset(50, 12),
        Size = UDim2.new(1, -86, 0, 21),
        Font = Enum.Font.GothamBold,
        TextSize = 13,
    })
    local message = label(scope, card, options.Content or "", {
        Name = "NotificationContent",
        Position = UDim2.fromOffset(50, 37),
        Size = UDim2.new(1, -66, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextSize = 12,
        LineHeight = 1.15,
    }, "Muted")
    new("UISizeConstraint", { MaxSize = Vector2.new(10000, 84) }, message)
    revealText(scope, heading, heading.Text)
    revealText(scope, message, message.Text)
    local dismiss = button(scope, card, "", {
        Name = "Dismiss",
        Position = UDim2.new(1, -30, 0, 8),
        Size = UDim2.fromOffset(24, 24),
    })
    icon(scope, dismiss, "Close", UDim2.fromOffset(5, 5), 14, "Muted")
    local progressTrack = frame(scope, card, {
        Name = "ProgressTrack",
        Position = UDim2.new(0, 12, 1, -7),
        Size = UDim2.new(1, -24, 0, 2),
        BackgroundTransparency = 0.4,
    }, "Border")
    corner(progressTrack, 2)
    local progress = frame(scope, progressTrack, {
        Name = "Progress",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 0.1,
    }, token)
    corner(progress, 2)
    local closing = false
    local function measure()
        if not closing then
            slot.Size = UDim2.fromOffset(width, math.max(84, 37 + math.min(84, message.AbsoluteSize.Y) + 23))
        end
    end
    measure()
    scope:Connect(message:GetPropertyChangedSignal("AbsoluteSize"), measure)
    scope:Connect(host.Gui:GetPropertyChangedSignal("AbsoluteSize"), function()
        width = math.min(340, math.max(160, host.Gui.AbsoluteSize.X - 32))
        measure()
    end)
    local handle = { Closed = false }
    function handle:Close()
        if self.Closed or not scope.Alive then
            return
        end
        self.Closed = true
        closing = true
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
    local capacity = math.clamp(math.floor((host.Gui.AbsoluteSize.Y - 40) / 154), 1, 4)
    if live > capacity then
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
    if self.LoadingOverlay then self.LoadingOverlay:Close(true) end
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
        Name = "Overlay",
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
        Name = "Panel",
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
        Name = "Cancel",
        Position = UDim2.new(0, 16, 1, -51),
        Size = UDim2.new(0.5, -22, 0, 36),
        BackgroundTransparency = 0,
    })
    local confirm = button(scope, panel, options.ConfirmText or "Confirm", {
        Name = "Confirm",
        Position = UDim2.new(0.5, 6, 1, -51),
        Size = UDim2.new(0.5, -22, 0, 36),
        BackgroundTransparency = 0,
    })
    corner(cancel, 8)
    corner(confirm, 8)
    color(scope, cancel, "BackgroundColor3", "Raised")
    color(scope, confirm, "BackgroundColor3", "Accent")
    color(scope, confirm, "TextColor3", "OnAccent")
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
    self.Default = copy(default)
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
