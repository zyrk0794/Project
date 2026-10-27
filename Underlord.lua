-- Underlord Classic 1.2: standalone UI library.
-- UI only; no game hooks, remotes, detection bypass, or external code downloads.
local Underlord = { version = "Classic 1.2" }

local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Window = {}
local Tab = {}
local Section = {}

Window.__index = Window
Tab.__index = Tab
Section.__index = Section

local defaults = {
	size = Vector2.new(700, 590),
	scale = 1,
	dragDuration = 0.10,
	tintDuration = 0.08,
	slideDuration = 0.20,
	revealDuration = 0.16,
	popupDuration = 0.10,
	accent = Color3.fromRGB(222, 65, 88),
	background = Color3.fromRGB(16, 16, 18),
	panel = Color3.fromRGB(19, 19, 21),
	text = Color3.fromRGB(213, 213, 213),
	muted = Color3.fromRGB(139, 139, 139),
	outline = Color3.fromRGB(49, 49, 55),
	font = Enum.Font.Code,
	headerFont = Enum.Font.Code,
	textSize = 13,
	hoverDuration = 0.06,
    glow = true, glowIntensity = 0.55,
	fadeOutDuration = 0.09,
	fadeInDuration = 0.12,
	toggleKey = Enum.KeyCode.RightShift,
}

local function create(className, parent, properties)
	local instance = Instance.new(className)

	for property, value in pairs(properties or {}) do
		instance[property] = value
	end

	instance.Parent = parent
	return instance
end

local function frame(parent, name, properties)
	local instance = create("Frame", nil, {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	})

	for property, value in pairs(properties or {}) do
		instance[property] = value
	end

	instance.Parent = parent
	return instance
end

local function round() end -- Deliberately square, including popup panels.

local function outline(instance, color, thickness)
	return create("UIStroke", instance, {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = color,
		Thickness = thickness or 1,
	})
end

local function shadow() end -- No UIShadow dependency or animated glow on panels.

local function connect(window, signal, callback)
	local scope = window.connectionScope
	local connection = signal:Connect(function(...)
		if scope and scope.owner and (scope.owner.isDestroyed or not scope.owner.isEnabled) then return end
		callback(...)
	end)
	window.connections[connection] = true
	if window.connectionScope then table.insert(window.connectionScope, connection) end
	return connection
end

local function motionDuration(window, base)
    if window.theme.animations == false then return 0 end
    return base / math.clamp(tonumber(window.theme.animationSpeed) or 1, 0.5, 2)
end

local function animate(window, instance, properties, duration, easingStyle, easingDirection)
	if window.isDestroyed then return nil end
	local previous = window.tweens[instance]
	if previous then
		previous:Cancel()
	end

	local tween = TweenService:Create(instance,
		TweenInfo.new(motionDuration(window, duration or window.theme.hoverDuration), easingStyle or Enum.EasingStyle.Quad, easingDirection or Enum.EasingDirection.Out),
		properties)

	window.tweens[instance] = tween
	window.targets[instance] = properties
	tween:Play()
	return tween
end

local function dispatch(callback, ...)
	if callback then
		task.spawn(callback, ...)
	end
end

local function label(window, parent, text, properties)
	local instance = create("TextLabel", nil, {
		Name = "Label",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = window.theme.font,
		AutoLocalize = false,
		TextScaled = false,
		Text = text,
		TextColor3 = window.theme.text,
        TextStrokeColor3 = window.theme.accent,
        TextStrokeTransparency = window.theme.glow == false and 1 or 0.96 - 0.25 * window.theme.glowIntensity,
		TextSize = window.theme.textSize,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.fromScale(1, 1),
	})

	for property, value in pairs(properties or {}) do
		instance[property] = value
	end

	instance.Parent = parent
	return instance
end

local function button(window, parent, text, properties)
	local instance = create("TextButton", nil, {
		Name = "Button",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = window.theme.font,
		AutoLocalize = false,
		TextScaled = false,
		Text = text,
		TextColor3 = window.theme.text,
        TextStrokeColor3 = window.theme.accent,
        TextStrokeTransparency = window.theme.glow == false and 1 or 0.96 - 0.25 * window.theme.glowIntensity,
		TextSize = window.theme.textSize,
		Size = UDim2.fromScale(1, 1),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	for property, value in pairs(properties or {}) do
		instance[property] = value
	end

	instance.Parent = parent
	return instance
end

local function bindHover(window, target, refresh)
	connect(window, target.MouseEnter, function() refresh(true) end)
	connect(window, target.MouseLeave, function() refresh(false) end)
	connect(window, target.SelectionGained, function() refresh(true) end)
	connect(window, target.SelectionLost, function() refresh(false) end)
end

local function textHover(window, target, border)
	bindHover(window, target, function(isHovered)
		animate(window, target, { TextColor3 = isHovered and window.theme.accent or window.theme.text })
		if border then
			animate(window, border, { Color = isHovered and window.theme.accent or window.theme.outline })
		end
	end)
end

local fallbackIcons = {
	["shopping-bag"] = { 16898613777, 49, 820 },
	["crosshair"] = { 16898613044, 453, 869 },
	["eye"] = { 16898613353, 771, 563 },
	["compass"] = { 16898613044, 514, 967 },
	["folder-plus"] = { 16898613353, 661, 918 },
	["menu"] = { 16898613613, 49, 820 },
	["chevron-down"] = { 16898612819, 196, 918 },
	["check"] = { 16898612819, 710, 869 },
	["x"] = { 16898613869, 869, 906 },
	["search"] = { 16898613699, 918, 857 },
	["info"] = { 16898613509, 612, 869 },
	["palette"] = { 16898613613, 453, 918 },
	["settings"] = { 16898613777, 771, 257 },
	["bell"] = { 16898612819, 820, 257 },
	["save"] = { 16898613699, 918, 453 },
	["copy"] = { 16898613044, 918, 612 },
	["circle-help"] = { 16898613044, 820, 257 },
	["mouse-pointer"] = { 16898613613, 612, 869 },
	["keyboard"] = { 16898613509, 453, 820 },
	["sliders-horizontal"] = { 16898613777, 820, 355 },
	["user"] = { 16898613869, 661, 869 },
	["sun"] = { 16898613777, 967, 453 },
	["shield"] = { 16898613777, 869, 0 },
	["chevrons-up-down"] = { 16898612819, 918, 759 },
	["grip"] = { 16898613509, 869, 257 },
	["minus"] = { 16898613613, 771, 196 },
}

local cachedIcons

local function fallbackAsset(name)
	local record = fallbackIcons[name]
	if not record then return nil end
	return {
		Url = "rbxassetid://" .. record[1],
		ImageRectSize = Vector2.new(48, 48),
		ImageRectOffset = Vector2.new(record[2], record[3]),
	}
end

local function resolveIcon(window, name)
	name = name:gsub("^lucide%-", "")
	if name == "folder" then name = "folder-plus" end
	if name == "settings-2" then name = "settings" end
	if name == "shopping-cart" then name = "shopping-bag" end
	if name:match("^rbxassetid://%d+$") then return { Url = name } end
	if window.icons then
		local isSuccess, asset = pcall(window.icons.GetAsset, name, 48)
		if isSuccess and type(asset) == "table" then return asset end
	end
	return fallbackAsset(name) or fallbackAsset("circle-help")
end

local function createIcon(window, parent, name, size)
	local asset = resolveIcon(window, name)
	return create("ImageLabel", parent, {
		Name = "Icon", BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size), Image = asset.Url,
		ImageRectSize = asset.ImageRectSize or Vector2.new(0, 0),
		ImageRectOffset = asset.ImageRectOffset or Vector2.new(0, 0),
		ImageColor3 = window.theme.text, ScaleType = Enum.ScaleType.Fit,
	})
end

local function refreshTab(tab)
    local window = tab.window
    local selected = window.targetTab == tab
    tab.button.BackgroundColor3 = selected and window.theme.panel or window.theme.background
    tab.caption.TextColor3 = (selected or tab.isHovered) and window.theme.text or window.theme.muted
    tab.indicator.Visible = selected
    tab.icon.ImageColor3 = selected and window.theme.accent or window.theme.muted
end

local function closePopup(window, shouldHideImmediately)
	if window.hideTooltip then window.hideTooltip() end
	local view = window.activePopup
	if window.closePopup then
		window.closePopup()
		window.closePopup = nil
	end
	if shouldHideImmediately and view and view.shell.Parent then view.shell.Visible = false end
end

local function runTransition(window)
	window.isTransitioning = true
	window.cover.Visible = true

	while not window.isDestroyed and window.targetTab ~= window.activeTab do
		animate(window, window.cover, { BackgroundTransparency = 0 }, window.theme.fadeOutDuration).Completed:Wait()
		if window.isDestroyed then return end

		if window.activeTab then window.activeTab.page.Visible = false end
		window.activeTab = window.targetTab
		window.activeTab.page.Visible = true
		animate(window, window.cover, { BackgroundTransparency = 1 }, window.theme.fadeInDuration).Completed:Wait()
	end

	if window.isDestroyed then return end
	window.cover.Visible = false
	window.isTransitioning = false
end

local function clampWindowPosition(window, left, top)
	local viewport = window.viewport.AbsoluteSize
	local scale = window.scale.Scale
	local height = window.isMinimized and 40 or window.theme.size.Y
	return UDim2.fromOffset(
		math.clamp(left, 0, math.max(0, viewport.X - window.theme.size.X * scale)),
		math.clamp(top, 0, math.max(0, viewport.Y - height * scale)))
end

local function hiddenPosition(window)
	local height = window.isMinimized and 40 or window.theme.size.Y
	return UDim2.fromOffset(window.shownPosition.X.Offset, -height * window.scale.Scale - 48)
end

local function fitWindow(window, shouldCenter)
	local viewport = window.viewport.AbsoluteSize
	if viewport.X < 1 or viewport.Y < 1 then return end
	local size = window.theme.size
	local scale = math.max(0.1, math.min(window.theme.scale, (viewport.X - 24) / size.X, (viewport.Y - 24) / size.Y))
	window.scale.Scale = scale
	local position = window.shownPosition or window.host.Position
	local left = shouldCenter and (viewport.X - size.X * scale) / 2 or position.X.Offset
	local height = window.isMinimized and 40 or size.Y
	local top = shouldCenter and (viewport.Y - height * scale) / 2 or position.Y.Offset
	window.shownPosition = clampWindowPosition(window, left, top)
	if not window.isVisibilityAnimating then
		window.host.Position = window.isVisible and window.shownPosition or hiddenPosition(window)
	end
end

local function finishVisibility(window, revision, isVisible)
	if window.isDestroyed or revision ~= window.visibilityRevision then return end
	window.isVisibilityAnimating = false
	window.host.Visible = isVisible
	window.visibilityCover.Visible = not isVisible
	if isVisible then window.visibilityCover.BackgroundTransparency = 1 end
end

local function animateVisibility(window, revision, isVisible)
	if isVisible then
		local movement = animate(window, window.host, { Position = window.shownPosition }, window.theme.slideDuration, Enum.EasingStyle.Quart)
		animate(window, window.visibilityCover, { BackgroundTransparency = 1 }, window.theme.revealDuration)
		movement.Completed:Wait()
	else
		animate(window, window.visibilityCover, { BackgroundTransparency = 0 }, window.theme.tintDuration).Completed:Wait()
		if window.isDestroyed or revision ~= window.visibilityRevision then return end
		animate(window, window.host, { Position = hiddenPosition(window) }, window.theme.slideDuration,
			Enum.EasingStyle.Cubic, Enum.EasingDirection.In).Completed:Wait()
	end
	finishVisibility(window, revision, isVisible)
end

local function isPointer(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function startPointer(window, input, move)
	if not isPointer(input) then return end
	window.pointer = { input = input, move = move }
end

local function movePointer(window, input)
	local pointer = window.pointer
	if not pointer then return end
	local isMouse = pointer.input.UserInputType == Enum.UserInputType.MouseButton1
	if input == pointer.input or (isMouse and input.UserInputType == Enum.UserInputType.MouseMovement) then
		pointer.move(Vector2.new(input.Position.X, input.Position.Y))
	end
end

local function bindDrag(window, header)
	connect(window, header.InputBegan, function(input)
		if not isPointer(input) or not window.isVisible or window.isVisibilityAnimating then return end
		local origin = Vector2.new(input.Position.X, input.Position.Y)
		local start = window.host.Position
		window.hasDragged = false
		closePopup(window)
		startPointer(window, input, function(position)
			local delta = position - origin
			if delta.Magnitude > 3 then window.hasDragged = true end
			window.shownPosition = clampWindowPosition(window, start.X.Offset + delta.X, start.Y.Offset + delta.Y)
			animate(window, window.host, { Position = window.shownPosition }, window.theme.dragDuration)
		end)
	end)
end

local function containsPoint(instance, position)
	local origin, size = instance.AbsolutePosition, instance.AbsoluteSize
	return position.X >= origin.X and position.Y >= origin.Y
		and position.X <= origin.X + size.X and position.Y <= origin.Y + size.Y
end

local function placePopup(window, view)
	if not view.shell.Parent then return end
	local scale = window.scale.Scale
	local anchor = view.anchor or view.control
	local origin = anchor.AbsolutePosition
	local viewportOrigin = window.viewport.AbsolutePosition
	local viewport = window.viewport.AbsoluteSize
	local width = view.width or view.control.AbsoluteSize.X / scale
	local height = view.listHeight
	local anchorLeft = origin.X - viewportOrigin.X
	if view.anchor then anchorLeft = anchorLeft + anchor.AbsoluteSize.X - width * scale end
	local left = math.clamp(anchorLeft, 2, math.max(2, viewport.X - width * scale - 2))
	local below = origin.Y - viewportOrigin.Y + anchor.AbsoluteSize.Y + (view.anchor and 3 or 1) * scale
	local top = below
	if below + height * scale > viewport.Y - 2 then top = origin.Y - viewportOrigin.Y - height * scale - scale end
	top = math.clamp(top, 2, math.max(2, viewport.Y - height * scale - 2))
	local hostOrigin = window.host.AbsolutePosition - viewportOrigin
	view.shell.Position = UDim2.fromOffset((left - hostOrigin.X) / scale, (top - hostOrigin.Y) / scale)
	view.targetSize = UDim2.fromOffset(width, height)
	if not view.isAnimating then view.shell.Size = view.targetSize end
end

local function popupAnimation(window, view)
	local revision = 0
	return function(shouldOpen)
		revision = revision + 1
		local currentRevision = revision
		if not view.shell.Parent then return end
		if shouldOpen then
			placePopup(window, view)
			if not view.shell.Visible then
				view.shell.Size = UDim2.fromOffset(view.targetSize.X.Offset, 0)
			end
			view.shell.Visible = true
			window.activePopup = view
			window.popupOrder = (window.popupOrder or 0) + 1
			view.shell.ZIndex = window.popupOrder
		elseif window.activePopup == view then
			window.activePopup = nil
		end
		if view.scroll then
			view.scroll.Active = shouldOpen
			view.scroll.ScrollingEnabled = shouldOpen
		end
		view.blocker.Visible = not shouldOpen
		if view.arrow then animate(window, view.arrow, { Rotation = shouldOpen and 180 or 0 }) end
		view.isAnimating = true
		animate(window, view.list, { GroupTransparency = shouldOpen and 0 or 1 }, window.theme.popupDuration)
		local target = shouldOpen and view.targetSize or UDim2.fromOffset(view.shell.Size.X.Offset, 0)
		local tween = animate(window, view.shell, { Size = target }, window.theme.popupDuration, Enum.EasingStyle.Quart)
		task.spawn(function()
			tween.Completed:Wait()
			if window.isDestroyed or revision ~= currentRevision or not view.shell.Parent then return end
			view.isAnimating = false
			view.shell.Visible = shouldOpen
			if shouldOpen then placePopup(window, view) end
		end)
	end
end

local function bindPopupPosition(window, view)
	local function refresh()
		if window.activePopup == view then placePopup(window, view) end
	end
	connect(window, view.control:GetPropertyChangedSignal("AbsolutePosition"), refresh)
	connect(window, view.control:GetPropertyChangedSignal("AbsoluteSize"), refresh)
    if view.anchor then
        connect(window, view.anchor:GetPropertyChangedSignal("AbsolutePosition"), refresh)
        connect(window, view.anchor:GetPropertyChangedSignal("AbsoluteSize"), refresh)
    end
	connect(window, window.viewport:GetPropertyChangedSignal("AbsoluteSize"), refresh)
	connect(window, window.host:GetPropertyChangedSignal("AbsolutePosition"), refresh)
end

local function bindInput(window)
	connect(window, UserInputService.InputChanged, function(input) movePointer(window, input) end)
	connect(window, UserInputService.InputEnded, function(input)
		if window.pointer and window.pointer.input == input then window.pointer = nil end
	end)
	connect(window, UserInputService.WindowFocusReleased, function() window.pointer = nil end)
	connect(window, UserInputService.InputBegan, function(input, isProcessed)
		if isPointer(input) and window.activePopup then
			local position = Vector2.new(input.Position.X, input.Position.Y)
			local view = window.activePopup
			if not containsPoint(view.shell, position) and not containsPoint(view.control, position) then closePopup(window) end
		end
		if UserInputService:GetFocusedTextBox() then return end
		if window.captureKey then
			window.captureKey(input)
			return
		end
		if isProcessed then return end
		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode == window.theme.toggleKey then
			window:setVisible(not window.isVisible)
			return
		end
		for _, binding in ipairs(window.keybinds) do
			if binding.key == input.KeyCode and not binding.isDisabled then dispatch(binding.callback, binding.key) end
		end
	end)
end

local function buildHeader(window, options)
    local header = frame(window.root, "Header", { Size = UDim2.new(1, 0, 0, 27), Active = true })
    window.title = label(window, header, "", { Name = "Title", Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -48, 1, 0), TextSize = 13, RichText = true })
    window.titlePrefix, window.titleAccent = "UNDER", "LORD"
    window.titleVersion = options.subtitle or "BARRICADED"
    local hide = button(window, header, "-", { Name = "Hide", Position = UDim2.new(1, -29, 0, 3), Size = UDim2.fromOffset(23, 20) })
    textHover(window, hide)
    connect(window, hide.Activated, function() window:setVisible(false) end)
    frame(header, "Divider", { Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1),
        BackgroundTransparency = 0, BackgroundColor3 = window.theme.outline })
    window.navigation = frame(window.root, "Navigation", { Position = UDim2.fromOffset(9, 34),
        Size = UDim2.new(1, -18, 0, 24) })
    create("UIListLayout", window.navigation, { FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 0) })
    outline(window.navigation, window.theme.outline)
    bindDrag(window, header)
end

local function buildWindow(window, parent, options)
	local previous = parent:FindFirstChild(options.name or "Underlord")
	if previous and previous:GetAttribute("UnderlordManaged") then previous:Destroy() end
	window.gui = create("ScreenGui", parent, {
		Name = options.name or "Underlord", ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = options.displayOrder or 50,
		IgnoreGuiInset = true,
	})
	window.gui:SetAttribute("UnderlordManaged", true)
	window.viewport = frame(window.gui, "Viewport", { Size = UDim2.fromScale(1, 1) })
	window.host = frame(window.viewport, "WindowHost", {
		Size = UDim2.fromOffset(window.theme.size.X, window.theme.size.Y), ZIndex = 10,
	})
	window.scale = create("UIScale", window.host, { Scale = window.theme.scale })
	shadow(window.host, 22, 7, 3, 0.25)
	window.root = create("CanvasGroup", window.host, {
		Name = "Window", BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = window.theme.background, BackgroundTransparency = 0,
	})
	window.popupLayer = frame(window.host, "PopupLayer", { Size = UDim2.fromScale(1, 1), ZIndex = 300 })
	window.visibilityCover = button(window, window.root, "", {
		Name = "VisibilityCover", BackgroundTransparency = 1, BackgroundColor3 = window.theme.accent,
		Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 500, Selectable = false,
	})
	-- All outer decoration lives INSIDE the fading CanvasGroup.
    -- No UIStroke is attached to the CanvasGroup or its host.
    window.chrome = frame(window.root, "Chrome", { Size = UDim2.fromScale(1, 1), ZIndex = 0 })
    window.glowEdges = {}
    local function edgeRing(name, inset, color, transparency, glowLevel)
        local ring = frame(window.chrome, name, { Position = UDim2.fromOffset(inset, inset),
            Size = UDim2.new(1, -2 * inset, 1, -2 * inset), ZIndex = 0 })
        local edges = {
            { UDim2.new(), UDim2.new(1, 0, 0, 1) },
            { UDim2.new(0, 0, 1, -1), UDim2.new(1, 0, 0, 1) },
            { UDim2.fromOffset(0, 1), UDim2.new(0, 1, 1, -2) },
            { UDim2.new(1, -1, 0, 1), UDim2.new(0, 1, 1, -2) },
        }
        for _, geometry in ipairs(edges) do
            local edge = frame(ring, "Edge", { Position = geometry[1], Size = geometry[2],
                BackgroundColor3 = color, BackgroundTransparency = transparency, ZIndex = 0 })
            if glowLevel then table.insert(window.glowEdges, { instance = edge, level = glowLevel }) end
        end
    end
    edgeRing("Border", 0, window.theme.accent, 0.2)
    for inset = 1, 7 do
        local strength = (8 - inset) / 7
        local alpha = window.theme.glow == false and 1 or 1 - 0.34 * strength * window.theme.glowIntensity
        edgeRing("Glow" .. inset, inset, window.theme.accent, alpha, strength)
    end
	buildHeader(window, options)
	window.body = frame(window.root, "Body", {
		Position = UDim2.fromOffset(9, 65), Size = UDim2.new(1, -18, 1, -75), ClipsDescendants = true,
	})
	window.cover = button(window, window.body, "", {
		Name = "Transition", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1,
		Visible = false, ZIndex = 100, Active = true, Selectable = false,
	})
end

local function createRow(section, height)
	section.rowCount = section.rowCount + 1
	local row = create("CanvasGroup", section.content, {
		Name = "Control", BackgroundTransparency = 1, BorderSizePixel = 0,
		Size = UDim2.new(1, -2, 0, height or 18), LayoutOrder = section.rowCount,
	})
	section.pendingRow = row
	return row
end

local function limitText(text, maximum)
	text = tostring(text):gsub("[%c]", "")
	local length = utf8.len(text)
	if not length then return "" end
	if length <= maximum then return text end
	return text:sub(1, utf8.offset(text, maximum + 1) - 1)
end

local function createField(window, parent, width, text, maxLength)
	maxLength = maxLength or 256
	local field = create("TextBox", parent, {
		Name = "Input", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -1, 0.5, 0),
		Size = UDim2.fromOffset(width, 18), BackgroundTransparency = 1, BorderSizePixel = 0,
		Font = window.theme.font, TextColor3 = window.theme.text,
        TextStrokeColor3 = window.theme.accent,
        TextStrokeTransparency = window.theme.glow == false and 1 or 0.96 - 0.25 * window.theme.glowIntensity, TextSize = window.theme.textSize,
		AutoLocalize = false, TextScaled = false,
		Text = limitText(text, maxLength), ClearTextOnFocus = false, MultiLine = false, TextWrapped = false,
	})
	field:SetAttribute("MaxLength", maxLength)
	connect(window, field:GetPropertyChangedSignal("Text"), function()
		local limited = limitText(field.Text, maxLength)
		if field.Text ~= limited then field.Text = limited end
	end)
	round(field, 2)
	local border = outline(field, window.theme.outline)
	connect(window, field.Focused, function() animate(window, border, { Color = window.theme.accent }) end)
	connect(window, field.FocusLost, function() animate(window, border, { Color = window.theme.outline }) end)
	return field
end

local function createSliderView(section, options)
    local window = section.window
    local row = createRow(section, 34)
    label(window, row, options.name or "Slider", { Size = UDim2.new(1, -48, 0, 18) })
    local field = createField(window, row, 43, "0", 24)
    field.Position = UDim2.new(1, -1, 0, 9)
    field.Size = UDim2.fromOffset(43, 16)
    local hitbox = button(window, row, "", { Name = "Slider", Position = UDim2.fromOffset(1, 21), Size = UDim2.new(1, -2, 0, 11),
        BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(26, 26, 29) })
    outline(hitbox, window.theme.outline)
    local fill = frame(hitbox, "Fill", { Size = UDim2.fromOffset(0, 11), BackgroundTransparency = 0, BackgroundColor3 = window.theme.accent })
    local knob = frame(hitbox, "Knob", { Visible = false })
    return hitbox, knob, field, fill
end

local function createToggleView(section, options)
    local window = section.window
    local row = createRow(section, 18)
    local control = button(window, row, "", { Name = "Toggle", Size = UDim2.fromScale(1, 1) })
    label(window, control, options.name or "Toggle", { Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -20, 1, 0), Active = false })
    local check = frame(control, "Checkbox", { Position = UDim2.fromOffset(1, 3), Size = UDim2.fromOffset(12, 12),
        BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(24, 24, 27) })
    local border = outline(check, window.theme.outline)
    return control, border, check
end

local function createKeybindView(section, options)
	local window = section.window
	local row = createRow(section)
	local width = options.width or 84
	label(window, row, options.name or "Keybind", { Size = UDim2.new(1, -width - 6, 1, 0) })
	local control = button(window, row, "", { Name = "Keybind", AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -1, 0.5, 0), Size = UDim2.fromOffset(width, 18) })
	round(control, 2)
	local border = outline(control, window.theme.outline)
	textHover(window, control, border)
	return control, border
end

local function schedule(window, delaySeconds, callback)
	if window.isDestroyed then return nil end
	local thread
	thread = task.delay(delaySeconds, function()
		window.tasks[thread] = nil
		if not window.isDestroyed then callback() end
	end)
	window.tasks[thread] = true
	return thread
end

local function releaseConnections(window, connections)
	for _, connection in ipairs(connections) do
		connection:Disconnect()
		window.connections[connection] = nil
	end
	local owner = connections.owner
	table.clear(connections)
	connections.owner = owner
end

local function destroyPopup(window, view, handle)
	if window.activePopup == view then window.activePopup = nil end
	if window.closePopup == handle.close then window.closePopup = nil end
	if view.connections then releaseConnections(window, view.connections) end
	for instance, tween in pairs(window.tweens) do
		if instance == view.shell or instance:IsDescendantOf(view.shell) then
			tween:Cancel()
			window.tweens[instance], window.targets[instance] = nil, nil
		end
	end
	view.shell:Destroy()
end

local function escapeRichText(text)
	return tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local function refreshTitle(window)
    local accent = window.theme.accent
    window.title.Text = string.format('%s<font color="rgb(%d,%d,%d)">%s</font><font color="#777780">  |  %s</font>',
        escapeRichText(window.titlePrefix), math.round(accent.R * 255), math.round(accent.G * 255),
        math.round(accent.B * 255), escapeRichText(window.titleAccent), escapeRichText(window.titleVersion))
end

local function cancelScheduled(window, thread)
	if not thread then return end
	window.tasks[thread] = nil
	task.cancel(thread)
end

local function destroyOverlay(window, shell)
	for instance, tween in pairs(window.tweens) do
		if instance == shell or instance:IsDescendantOf(shell) then
			tween:Cancel()
			window.tweens[instance], window.targets[instance] = nil, nil
		end
	end
	shell:Destroy()
end

local function measureText(window, text, width, maximum)
	local bounds = TextService:GetTextSize(text, 12, window.theme.font, Vector2.new(math.max(1, width), 10000))
	return math.clamp(bounds.Y, 16, maximum)
end

local function overlayCard(window, parent, name, size, layer)
	local shell = frame(parent, name, { Size = size, ZIndex = layer or 1 })
	round(shell, 5)
	shadow(shell, 10, 3, 1, 0.35)
	local panel = create("CanvasGroup", shell, {
		Name = "Content", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0,
		BackgroundColor3 = window.theme.panel, GroupTransparency = 1,
	})
	round(panel, 5)
	outline(shell, Color3.fromRGB(49, 49, 53))
	return shell, panel
end

local function tooltipPosition(window, target, width, height)
	local viewport = window.viewport.AbsoluteSize
	local origin = target.AbsolutePosition - window.viewport.AbsolutePosition
	local top = origin.Y + target.AbsoluteSize.Y + 7
	if top + height > viewport.Y - 8 then top = origin.Y - height - 7 end
	return UDim2.fromOffset(math.clamp(origin.X, 8, math.max(8, viewport.X - width - 8)),
		math.clamp(top, 8, math.max(8, viewport.Y - height - 8)))
end

local function createTooltip(window, target, text)
	local width = math.max(48, math.min(250, window.viewport.AbsoluteSize.X - 16))
	local height = measureText(window, text, width - 20, 96) + 16
	local shell, panel = overlayCard(window, window.viewport, "Tooltip", UDim2.fromOffset(width, height), 400)
	label(window, panel, text, { Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 1, -16),
		TextWrapped = true, TextSize = 12, TextYAlignment = Enum.TextYAlignment.Top })
	local position = tooltipPosition(window, target, width, height)
	shell.Position = UDim2.fromOffset(position.X.Offset, position.Y.Offset + 4)
	animate(window, shell, { Position = position }, 0.12)
	animate(window, panel, { GroupTransparency = 0 }, 0.12)
	return shell, panel
end

local function addTooltip(window, target, text)
	local shell, panel, pending
	local function hide()
		cancelScheduled(window, pending)
		pending = nil
		if shell then
			local previous = shell
			animate(window, panel, { GroupTransparency = 1 }, 0.10)
			schedule(window, 0.10, function() destroyOverlay(window, previous) end)
			shell, panel = nil, nil
		end
	end
	bindHover(window, target, function(isHovered)
		hide()
		if not isHovered then return end
		if window.hideTooltip then window.hideTooltip() end
		window.hideTooltip = hide
		pending = schedule(window, 0.3, function()
			pending = nil
			if not window.isVisible or not target.Parent or window.isTransitioning then return end
			local ancestor = target
			while ancestor and ancestor ~= window.gui do
				if ancestor:IsA("GuiObject") and not ancestor.Visible then return end
				ancestor = ancestor.Parent
			end
			shell, panel = createTooltip(window, target, limitText(text, 320))
		end)
	end)
	connect(window, target:GetPropertyChangedSignal("AbsolutePosition"), hide)
	connect(window, target.Destroying, hide)
	return hide
end

local function attachControl(section, handle, options, kind, connections)
	local window = section.window
	local row = handle.instance.Parent
	handle.kind, handle.row = kind, row
	handle.isEnabled, handle.isDestroyed = true, false
	handle.options = options
	handle.connections = connections
	if handle.get then handle.default = handle:get() end
	handle.blocker = button(window, row, "", { Name = "Disabled", Visible = false, ZIndex = 90, Selectable = false })
	if options.tooltip then handle.hideTooltip = addTooltip(window, handle.instance, options.tooltip) end
	function handle:setVisible(isVisible)
		if self.isDestroyed then return end
		self.row.Visible = isVisible == true
		if self.hideTooltip then self.hideTooltip() end
		if not isVisible and self.close then self.close() end
	end
	function handle:setEnabled(isEnabled)
		if self.isDestroyed then return end
		self.isEnabled = isEnabled == true
		self.blocker.Visible = not self.isEnabled
		if self.hideTooltip then self.hideTooltip() end
		if not self.isEnabled and self.close then self.close() end
		if self.binding then self.binding.isDisabled = not self.isEnabled end
		if not self.isEnabled and window.captureOwner == self.instance and window.cancelKeyCapture then window.cancelKeyCapture() end
		animate(window, row, { GroupTransparency = self.isEnabled and 0 or 0.55 })
	end
	function handle:reset(shouldNotify)
		if self.set and self.default ~= nil then self:set(self.default, shouldNotify) end
	end
	table.insert(window.controls, handle)
	if options.id then
		assert(not window.flags[options.id], "Duplicate control ID: " .. options.id)
		window.flags[options.id] = handle
	end
	return handle
end

local function destroyControl(window, handle)
	if handle.isDestroyed then return end
	if window.captureOwner == handle.instance and window.cancelKeyCapture then window.cancelKeyCapture() end
	if handle.cleanup then handle.cleanup() end
	if window.closePopup == handle.close then window.closePopup = nil end
	handle.isDestroyed = true
	if handle.hideTooltip then handle.hideTooltip() end
	if handle.binding then
		local index = table.find(window.keybinds, handle.binding)
		if index then table.remove(window.keybinds, index) end
	end
	releaseConnections(window, handle.connections)
	for instance, tween in pairs(window.tweens) do
		if instance == handle.row or instance:IsDescendantOf(handle.row) then
			tween:Cancel()
			window.tweens[instance] = nil
		end
	end
	if handle.options.id then window.flags[handle.options.id] = nil end
	local index = table.find(window.controls, handle)
	if index then table.remove(window.controls, index) end
	handle.row:Destroy()
end

local function registerControl(method, kind)
	local constructor = Section[method]
	Section[method] = function(section, options)
		options = options or {}
		local window = section.window
		assert(not window.isDestroyed, "Window has been destroyed.")
		assert(not options.id or not window.flags[options.id], "Duplicate control ID.")
		local connections = {}
		section.pendingRow = nil
		window.connectionScope = connections
		local isSuccess, handle = pcall(constructor, section, options)
		if isSuccess then handle = attachControl(section, handle, options, kind, connections) end
		window.connectionScope = nil
		if not isSuccess then
			releaseConnections(window, connections)
			if section.pendingRow then section.pendingRow:Destroy() end
			section.pendingRow = nil
			error(handle, 2)
		end
		section.pendingRow = nil
		connections.owner = handle
		function handle:destroy() destroyControl(window, self) end
		if options.isEnabled == false then handle:setEnabled(false) end
		if options.isVisible == false then handle:setVisible(false) end
		return handle
	end
end

local function encodeSetting(setting)
	if typeof(setting) == "Color3" then return { kind = "color", hex = setting:ToHex() } end
	if typeof(setting) == "EnumItem" then return { kind = "key", name = setting.Name } end
	if type(setting) == "table" then return table.clone(setting) end
	return setting
end

local function decodeSetting(handle, setting)
	local kind = handle.kind
	if kind == "color" then
		assert(type(setting) == "table" and setting.kind == "color" and type(setting.hex) == "string", "Invalid color.")
		assert(setting.hex:match("^%x%x%x%x%x%x$"), "Invalid hex color.")
		return Color3.fromHex(setting.hex)
	end
	if kind == "keybind" then
		assert(type(setting) == "table" and setting.kind == "key", "Invalid keybind.")
		return Enum.KeyCode[setting.name]
	end
	if kind == "toggle" then assert(type(setting) == "boolean", "Expected boolean.") end
	if kind == "slider" then
		assert(type(setting) == "number" and setting == setting and math.abs(setting) < math.huge, "Expected finite number.")
	end
	if kind == "input" then
		assert(type(setting) == "string", "Expected text.")
		local length = utf8.len(setting)
		assert(length and length >= (handle.options.minLength or 0) and length <= (handle.options.maxLength or 64), "Invalid text length.")
		assert(limitText(setting, handle.options.maxLength or 64) == setting, "Control characters are not accepted.")
		assert(not handle.options.validate or handle.options.validate(setting), "Text rejected.")
	end
	if kind == "dropdown" then assert(handle:accepts(setting), "Invalid selection.") end
	return setting
end

local function createDropdownPanel(section, options)
	local window = section.window
	local row = createRow(section, 38)
	label(window, row, options.name or "Dropdown", { Size = UDim2.new(1, 0, 0, 19) })
	local control = button(window, row, "", { Name = "Dropdown", Position = UDim2.fromOffset(1, 19), Size = UDim2.new(1, -2, 0, 18), BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(26, 26, 29) })
	round(control, 4)
	outline(control, window.theme.outline)
	local caption = label(window, control, "", { Position = UDim2.fromOffset(4, 0), Size = UDim2.new(1, -26, 1, 0), TextXAlignment = Enum.TextXAlignment.Left })
	local arrow = createIcon(window, control, "chevron-down", 14)
	arrow.Position = UDim2.new(1, -18, 0.5, -7)
	local shell = frame(window.popupLayer, "DropdownPopup", { Size = UDim2.fromOffset(230, 162), Visible = false, ClipsDescendants = true })
	round(shell, 5)
	shadow(shell, 8, 3, 1, 0.25)
	outline(shell, window.theme.outline)
	local list = create("CanvasGroup", shell, { Name = "Choices", Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = window.theme.panel, BorderSizePixel = 0, GroupTransparency = 1 })
	round(list, 5)
	local search = createField(window, list, 180, "", 64)
	search.Name, search.PlaceholderText = "Search", "Search..."
	search.AnchorPoint, search.Position, search.Size = Vector2.new(0, 0), UDim2.fromOffset(2, 2), UDim2.new(1, -4, 0, 20)
	search.Visible = options.searchable == true
	local top = search.Visible and 25 or 0
	local scroll = create("ScrollingFrame", list, { Name = "Options", Position = UDim2.fromOffset(1, top), Size = UDim2.new(1, -2, 1, -top - 1),
		BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 1, ScrollBarImageColor3 = window.theme.outline, ScrollingDirection = Enum.ScrollingDirection.Y })
	create("UIListLayout", scroll, { SortOrder = Enum.SortOrder.LayoutOrder })
	local blocker = button(window, list, "", { Name = "ClosingBlocker", ZIndex = 100, Visible = true, Selectable = false })
	return { row = row, control = control, caption = caption, arrow = arrow, shell = shell, list = list, scroll = scroll,
		search = search, blocker = blocker, listHeight = 162, top = top, maxVisible = math.max(1, options.maxVisible or 8), entries = {}, connections = {} }
end

local function validateChoices(choices)
	assert(type(choices) == "table", "Expected an options list.")
	local seen = {}
	for _, choice in ipairs(choices) do
		assert(type(choice) == "string" and not seen[choice], "Options must be unique strings.")
		seen[choice] = true
	end
	return table.clone(choices)
end

local function refreshChoice(window, entry)
	local isHighlighted = entry.isHovered or entry.isSelected
	animate(window, entry.button, { TextColor3 = isHighlighted and window.theme.accent or window.theme.text })
	animate(window, entry.mark, { ImageTransparency = entry.isMulti and entry.isSelected and 0 or 1 })
end

local function refreshDropdown(window, view, selected, isMulti)
	view.caption.Text = isMulti and (#selected > 0 and table.concat(selected, ", ") or "None") or (selected or "None")
	local query = string.lower(view.search.Text)
	local visibleCount = 0
	for _, entry in ipairs(view.entries) do
		entry.isMulti = isMulti
		entry.isSelected = isMulti and table.find(selected, entry.name) ~= nil or selected == entry.name
		entry.button.Visible = query == "" or string.find(string.lower(entry.name), query, 1, true) ~= nil
		if entry.button.Visible then visibleCount = visibleCount + 1 end
		refreshChoice(window, entry)
	end
	view.listHeight = math.min(math.max(visibleCount, 1), view.maxVisible) * 20 + view.top + 1
	if window.activePopup == view then placePopup(window, view) end
end

local function rebuildChoices(window, view, choices, onSelect)
	releaseConnections(window, view.connections)
	for _, entry in ipairs(view.entries) do entry.button:Destroy() end
	table.clear(view.entries)
	local previousScope = window.connectionScope
	window.connectionScope = view.connections
	for index, choice in ipairs(choices) do
		local entry = { name = choice, isHovered = false, isSelected = false }
		entry.button = button(window, view.scroll, choice, { Name = "Choice", Size = UDim2.new(1, 0, 0, 20), LayoutOrder = index })
		frame(entry.button, "Divider", { Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1),
			BackgroundTransparency = 0.25, BackgroundColor3 = window.theme.outline })
		entry.mark = createIcon(window, entry.button, "check", 12)
		entry.mark.Position, entry.mark.ImageColor3 = UDim2.new(1, -16, 0.5, -6), window.theme.accent
		bindHover(window, entry.button, function(isHovered) entry.isHovered = isHovered; refreshChoice(window, entry) end)
		connect(window, entry.button.Activated, function() onSelect(choice) end)
		table.insert(view.entries, entry)
	end
	window.connectionScope = previousScope
end

local function createColorPanel(section, options)
	local window = section.window
	local row = createRow(section, 20)
	local control = button(window, row, "", { Name = "Color", Size = UDim2.new(1, 0, 0, 20) })
	label(window, control, options.name or "Color", { Size = UDim2.new(1, -34, 1, 0) })
	local swatch = frame(control, "Swatch", { Position = UDim2.new(1, -29, 0, 2), Size = UDim2.fromOffset(28, 16), BackgroundTransparency = 0 })
	round(swatch, 2)
	outline(swatch, window.theme.outline)
	local shell = frame(window.popupLayer, "ColorPopup", {
		Size = UDim2.fromOffset(230, 158), Visible = false, ClipsDescendants = true,
	})
	round(shell, 5)
	shadow(shell, 8, 3, 1, 0.25)
	outline(shell, window.theme.outline)
	local list = create("CanvasGroup", shell, { Name = "Picker", Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = window.theme.panel, BorderSizePixel = 0, GroupTransparency = 1 })
	round(list, 5)
	local panel = frame(list, "Content", {
		Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 0, 142),
	})
	local saturation = button(window, panel, "", { Name = "Saturation", Size = UDim2.new(1, -24, 0, 110), BackgroundTransparency = 0, BackgroundColor3 = Color3.new(1, 1, 1) })
	create("UIGradient", saturation, { Color = ColorSequence.new(Color3.new(1, 1, 1)), Transparency = NumberSequence.new(0, 1) })
	local hueBase = frame(panel, "HueBase", { Size = saturation.Size, BackgroundTransparency = 0, ZIndex = 0 })
	saturation.ZIndex = 1
	local shade = frame(saturation, "Value", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0 })
	create("UIGradient", shade, { Rotation = 90, Transparency = NumberSequence.new(1, 0) })
	local marker = frame(saturation, "Cursor", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(6, 6), ZIndex = 3 })
	round(marker, 99)
	outline(marker, Color3.new(1, 1, 1))
	local hue = button(window, panel, "", { Name = "Hue", Position = UDim2.new(1, -16, 0, 0), Size = UDim2.fromOffset(14, 110), BackgroundTransparency = 0, BackgroundColor3 = Color3.new(1, 1, 1) })
	local stops = {}
	for index = 0, 6 do table.insert(stops, ColorSequenceKeypoint.new(index / 6, Color3.fromHSV(index / 6, 1, 1))) end
	create("UIGradient", hue, { Rotation = 90, Color = ColorSequence.new(stops) })
	local hueMarker = frame(hue, "Cursor", { Size = UDim2.new(1, 4, 0, 2), Position = UDim2.fromOffset(-2, 0), BackgroundTransparency = 0, BackgroundColor3 = Color3.new(1, 1, 1) })
	local hex = createField(window, panel, 90, "", 7)
	hex.Position = UDim2.new(1, -1, 0, 129)
	local blocker = button(window, list, "", { Name = "ClosingBlocker", ZIndex = 100, Visible = true, Selectable = false })
	return { row = row, control = control, swatch = swatch, anchor = swatch, panel = panel, shell = shell, list = list,
		blocker = blocker, width = 230, listHeight = 158, saturation = saturation, hueBase = hueBase,
		marker = marker, hue = hue, hueMarker = hueMarker, hex = hex }
end

local function refreshColor(window, view, color)
	local hue, saturation, brightness = color:ToHSV()
	if saturation > 0 and brightness > 0 then view.selectedHue = hue end
	hue = view.selectedHue or hue
	view.hex.Text = "#" .. color:ToHex()
	view.hueBase.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
	view.marker.Position = UDim2.fromScale(saturation, 1 - brightness)
	view.hueMarker.Position = UDim2.new(0, -2, hue, -1)
	animate(window, view.swatch, { BackgroundColor3 = color })
end

local function bindColorPointer(window, view, handle)
	local function bind(target, isHue)
		connect(window, target.InputBegan, function(input)
			if not isPointer(input) then return end
			local function update(position)
				local relative = position - target.AbsolutePosition
				local hue, saturation, brightness = handle:get():ToHSV()
				hue = view.selectedHue or hue
				if isHue then
					hue = math.clamp(relative.Y / math.max(1, target.AbsoluteSize.Y), 0, 0.9999)
					view.selectedHue = hue
				else
					saturation = math.clamp(relative.X / math.max(1, target.AbsoluteSize.X), 0, 1)
					brightness = 1 - math.clamp(relative.Y / math.max(1, target.AbsoluteSize.Y), 0, 1)
				end
				handle:set(Color3.fromHSV(hue, saturation, brightness))
			end
			startPointer(window, input, update)
			update(Vector2.new(input.Position.X, input.Position.Y))
		end)
	end
	bind(view.hue, true)
	bind(view.saturation, false)
end

Underlord.new = function(options)
	options = options or {}
	local player = Players.LocalPlayer
	assert(player, "Underlord requires a Roblox client.")
	local parent = options.parent or player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	assert(parent, "PlayerGui unavailable.")
	local theme = table.clone(defaults)
	for key, value in pairs(options.theme or {}) do theme[key] = value end
	local window = setmetatable({ theme = theme, connections = {}, tweens = setmetatable({}, { __mode = "k" }), targets = setmetatable({}, { __mode = "k" }), tabs = {}, keybinds = {},
		controls = {}, flags = {}, tasks = {}, notifications = {},
		isVisible = true, isDestroyed = false, isTransitioning = false, visibilityRevision = 0 }, Window)
	window.storage = options.storage
	window.icons = options.icons
	buildWindow(window, parent, options)
	refreshTitle(window)
	bindInput(window)
	if options.showToggleButton or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then window:createToggleButton() end
	fitWindow(window, true)
	connect(window, window.viewport:GetPropertyChangedSignal("AbsoluteSize"), function() fitWindow(window, false) end)
	connect(window, window.gui.Destroying, function() window:destroy() end)
	return window
end

Window.setVisible = function(self, isVisible)
    if self.isDestroyed then return end
    isVisible = isVisible == true
    if self.isVisible == isVisible then return end
    if self.isVisible and not self.isVisibilityAnimating then self.shownPosition = self.host.Position end
    self.isVisible = isVisible
    self.visibilityRevision = (self.visibilityRevision or 0) + 1
    local revision = self.visibilityRevision
    cancelScheduled(self, self.visibilityTask)
    self.visibilityTask = nil
    self.pointer = nil
    closePopup(self, true)
    if self.cancelKeyCapture then self.cancelKeyCapture() end
    local shown = self.shownPosition or self.host.Position
    local hidden = UDim2.new(shown.X.Scale, shown.X.Offset, shown.Y.Scale, shown.Y.Offset + 8)
    if isVisible and not self.host.Visible then
        self.host.Position, self.root.GroupTransparency = hidden, 1
    end
    self.host.Visible = true
    self.popupLayer.Visible = isVisible
    self.visibilityCover.Visible = not isVisible
    self.isVisibilityAnimating = true
    self.chrome.Visible = false
    local base = 0.18
    animate(self, self.host, { Position = isVisible and shown or hidden }, base)
    animate(self, self.root, { GroupTransparency = isVisible and 0 or 1 }, base)
    local function finish()
        if self.isDestroyed or self.visibilityRevision ~= revision then return end
        self.visibilityTask = nil
        self.isVisibilityAnimating = false
        self.host.Visible = isVisible
        self.chrome.Visible = isVisible
        if isVisible then self.host.Position = self.shownPosition or shown end
        self.visibilityCover.Visible = false
    end
    local duration = motionDuration(self, base)
    if duration == 0 then finish() else self.visibilityTask = schedule(self, duration, finish) end
end

Window.selectTab = function(self, tab)
    if self.isDestroyed or tab.window ~= self or self.activeTab == tab then return end
    closePopup(self, true)
    if self.cancelKeyCapture then self.cancelKeyCapture() end
    self.pointer = nil
    local previous = self.activeTab
    self.activeTab, self.targetTab = tab, tab
    for _, entry in ipairs(self.tabs) do entry.page.Visible = entry == tab; refreshTab(entry) end
    if previous and self.theme.animations ~= false then
        tab.page.Position = UDim2.fromOffset(0, 7)
    end
    animate(self, tab.page, { Position = UDim2.fromOffset(0, 0) }, 0.16)
end

Window.setGlow = function(self, enabled, intensity)
    if self.isDestroyed then return end
    self.theme.glow = enabled ~= false
    self.theme.glowIntensity = math.clamp(tonumber(intensity) or self.theme.glowIntensity, 0, 1)
    for _, edge in ipairs(self.glowEdges) do
        edge.instance.BackgroundTransparency = self.theme.glow and (1 - 0.34 * edge.level * self.theme.glowIntensity) or 1
    end
    for _, object in ipairs(self.gui:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            object.TextStrokeColor3 = self.theme.accent
            object.TextStrokeTransparency = self.theme.glow and (0.96 - 0.25 * self.theme.glowIntensity) or 1
        end
    end
end

Window.setSectionsCollapsed = function(self, collapsed)
    if self.isDestroyed then return end
    closePopup(self, true)
    for _, tab in ipairs(self.tabs) do
        for _, section in ipairs(tab.sections) do section:setCollapsed(collapsed, tab == self.activeTab) end
    end
end

Window.createTab = function(self, options)
    options = options or {}
    local index = #self.tabs + 1
    local tab = setmetatable({ window = self, sections = {}, columns = {}, isHovered = false }, Tab)
    tab.button = button(self, self.navigation, "", { Name = options.name or "Tab", Size = UDim2.fromOffset(120, 24),
        BackgroundTransparency = 0, LayoutOrder = index })
    tab.icon = createIcon(self, tab.button, options.icon or "menu", 13)
    tab.icon.Position = UDim2.new(0.5, -43, 0, 5)
    tab.caption = label(self, tab.button, options.name or "Tab", { Position = UDim2.fromOffset(16, 0),
        Size = UDim2.new(1, -16, 1, 0), TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center })
    tab.indicator = frame(tab.button, "ActiveLine", { Size = UDim2.new(1, 0, 0, 1), BackgroundTransparency = 0, BackgroundColor3 = self.theme.accent })
    tab.page = frame(self.body, options.name or "Page", { Size = UDim2.fromScale(1, 1), Visible = false })
    for i = 1, 2 do
        local column = create("ScrollingFrame", tab.page, { Name = i == 1 and "LeftColumn" or "RightColumn",
            Position = UDim2.new((i - 1) * 0.5, i == 1 and 0 or 6, 0, 0), Size = UDim2.new(0.5, -6, 1, 0),
            BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = self.theme.muted,
            CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y })
        create("UIPadding", column, { PaddingTop = UDim.new(0, 1), PaddingBottom = UDim.new(0, 5), PaddingLeft = UDim.new(0, 1), PaddingRight = UDim.new(0, 4) })
        create("UIListLayout", column, { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder })
        tab.columns[i] = column
    end
    table.insert(self.tabs, tab)
    for _, entry in ipairs(self.tabs) do entry.button.Size = UDim2.new(1 / #self.tabs, 0, 0, 24) end
    refreshTab(tab)
    bindHover(self, tab.button, function(isHovered) tab.isHovered = isHovered; refreshTab(tab) end)
    connect(self, tab.button.Activated, function() self:selectTab(tab) end)
    if index == 1 then self:selectTab(tab) end
    return tab
end

Window.destroy = function(self)
	if self.isDestroyed then return end
	self.isDestroyed = true
	self.pointer = nil
	if self.clockTask then task.cancel(self.clockTask) end
	for connection in pairs(self.connections) do connection:Disconnect() end
	for thread in pairs(self.tasks) do task.cancel(thread) end
	for _, tween in pairs(self.tweens) do tween:Cancel() end
	table.clear(self.connections)
	table.clear(self.tweens)
	table.clear(self.keybinds)
	table.clear(self.tasks)
	table.clear(self.targets)
	table.clear(self.controls)
	table.clear(self.flags)
	self.gui:Destroy()
end

Tab.createSection = function(self, name, column)
    local window = self.window
    column = column or ((#self.sections % 2) + 1)
    assert(column == 1 or column == 2, "Section column must be 1 or 2")
    local section = setmetatable({ window = window, rowCount = 0, collapsed = false, column = column }, Section)
    section.frame = frame(self.columns[column], "Section", { Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 0,
        BackgroundColor3 = window.theme.panel, LayoutOrder = #self.sections + 1, ClipsDescendants = true })
    outline(section.frame, window.theme.outline)
    frame(section.frame, "AccentLine", { Size = UDim2.new(1, 0, 0, 1), BackgroundTransparency = 0, BackgroundColor3 = window.theme.accent })
    local title = button(window, section.frame, "", { Name = "SectionHeader", Size = UDim2.new(1, 0, 0, 23) })
    label(window, title, name, { Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -32, 1, 0), TextSize = 12 })
    local caret = label(window, title, "-", { Position = UDim2.new(1, -22, 0, 0), Size = UDim2.fromOffset(16, 23), TextColor3 = window.theme.muted, TextXAlignment = Enum.TextXAlignment.Center })
    section.content = frame(section.frame, "Controls", { Position = UDim2.fromOffset(8, 27), Size = UDim2.new(1, -16, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
    local layout = create("UIListLayout", section.content, { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder })
    local function resize()
        section.frame.Size = UDim2.new(1, 0, 0, section.collapsed and 23 or layout.AbsoluteContentSize.Y + 35)
    end
    function section:setCollapsed(value, withAnimation)
        if window.isDestroyed then return end
        value = value == true
        if self.collapsed == value then return end
        self.collapsed = value
        self.foldRevision = (self.foldRevision or 0) + 1
        local revision = self.foldRevision
        cancelScheduled(window, self.foldTask)
        self.foldTask = nil
        self.content.Visible = true
        caret.Text = self.collapsed and "+" or "-"
        local target = UDim2.new(1, 0, 0, self.collapsed and 23 or layout.AbsoluteContentSize.Y + 35)
        local base = withAnimation == false and 0 or 0.16
        animate(window, self.frame, { Size = target }, base)
        local function finish()
            if window.isDestroyed or self.foldRevision ~= revision then return end
            self.foldTask = nil
            self.content.Visible = not self.collapsed
        end
        local duration = motionDuration(window, base)
        if duration == 0 then finish() else self.foldTask = schedule(window, duration, finish) end
    end
    connect(window, layout:GetPropertyChangedSignal("AbsoluteContentSize"), resize)
    connect(window, title.Activated, function() closePopup(window, true); section:setCollapsed(not section.collapsed) end)
    table.insert(self.sections, section)
    return section
end

Section.addButton = function(self, options)
	local window = self.window
	local row = createRow(self, 19)
	local control = button(window, row, options.name or "Button", {
		Name = "Action", Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(26, 26, 29),
	})
	round(control, 2)
	outline(control, window.theme.outline)
	textHover(window, control)
	local lastActivation = -math.huge
	connect(window, control.Activated, function()
		local now = os.clock()
		if now - lastActivation < (options.debounce or 0.15) then return end
		lastActivation = now
		dispatch(options.callback)
	end)
	return { instance = control, setText = function(_, text) control.Text = text end }
end

Section.addToggle = function(self, options)
	local window = self.window
	local control, border, check = createToggleView(self, options)
	local isEnabled, isHovered = options.default == true, false
	local function refresh()
		animate(window, border, { Color = (isEnabled or isHovered) and window.theme.accent or window.theme.outline })
		animate(window, check, { BackgroundColor3 = isEnabled and window.theme.accent or Color3.fromRGB(24, 24, 27) })
	end
	local handle = { instance = control }
	function handle:set(nextState, shouldNotify)
		nextState = nextState == true
		if nextState == isEnabled then return end
		isEnabled = nextState
		refresh()
		if shouldNotify ~= false then dispatch(options.callback, isEnabled) end
	end
	function handle:get() return isEnabled end
	bindHover(window, control, function(hovered) isHovered = hovered; refresh() end)
	connect(window, control.Activated, function() handle:set(not isEnabled) end)
	refresh()
	return handle
end

Section.addSlider = function(self, options)
	local window = self.window
	local minimum, maximum, step = options.min or 0, options.max or 100, options.step or 1
	assert(maximum > minimum and step > 0, "Invalid slider bounds.")
	local hitbox, knob, field, fill = createSliderView(self, options)
	local current = math.clamp(options.default or minimum, minimum, maximum)
	local handle = { instance = hitbox }
	function handle:set(number, shouldNotify)
		if type(number) ~= "number" or number ~= number then return end
		number = math.clamp(minimum + math.round((number - minimum) / step) * step, minimum, maximum)
		local hasChanged = number ~= current
		current = number
		field.Text = string.format("%.4g", current)
		local ratio = (current - minimum) / (maximum - minimum)
		knob.Position = UDim2.fromScale(ratio, 0.5)
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		if hasChanged and shouldNotify ~= false then dispatch(options.callback, current) end
	end
	function handle:get() return current end
	local function updateFromPointer(position)
		local ratio = math.clamp((position.X - hitbox.AbsolutePosition.X) / math.max(1, hitbox.AbsoluteSize.X), 0, 1)
		handle:set(minimum + ratio * (maximum - minimum))
	end
	connect(window, hitbox.InputBegan, function(input)
		if not isPointer(input) then return end
		startPointer(window, input, updateFromPointer)
		updateFromPointer(Vector2.new(input.Position.X, input.Position.Y))
	end)
	connect(window, hitbox.InputBegan, function(input)
		if input.KeyCode == Enum.KeyCode.Left then handle:set(current - step) end
		if input.KeyCode == Enum.KeyCode.Right then handle:set(current + step) end
	end)
	connect(window, field.FocusLost, function() handle:set(tonumber(field.Text) or current) end)
	handle:set(current, false)
	return handle
end

Section.addKeybind = function(self, options)
	local window = self.window
	local control, border = createKeybindView(self, options)
	local binding = { key = options.default or Enum.KeyCode.Unknown, callback = options.callback }
	table.insert(window.keybinds, binding)
	local handle = { instance = control, binding = binding }
	function handle:set(key, shouldNotify)
		assert(typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode, "Expected a keyboard KeyCode.")
		local hasChanged = binding.key ~= key
		binding.key = key
		if hasChanged and shouldNotify ~= false then dispatch(options.onChanged, key) end
		control.Text = key == Enum.KeyCode.Unknown and "None" or key.Name
	end
	function handle:get() return binding.key end
	local function cancelCapture()
		window.captureKey, window.cancelKeyCapture, window.captureOwner = nil, nil, nil
		handle:set(binding.key)
		animate(window, border, { Color = window.theme.outline })
	end
	connect(window, control.Activated, function()
		if window.cancelKeyCapture then window.cancelKeyCapture() end
		control.Text = "..."
		animate(window, border, { Color = window.theme.accent })
		window.cancelKeyCapture = cancelCapture
		window.captureOwner = control
		window.captureKey = function(input)
			if input.KeyCode == Enum.KeyCode.Unknown then return end
			if input.KeyCode ~= Enum.KeyCode.Escape then
				handle:set(input.KeyCode == Enum.KeyCode.Backspace and Enum.KeyCode.Unknown or input.KeyCode)
			end
			cancelCapture()
		end
	end)
	handle:set(binding.key)
	return handle
end

Section.addDropdown = function(self, options)
	local window = self.window
	local choices = validateChoices(options.options or { "None" })
	local view = createDropdownPanel(self, options)
	local isMulti = options.isMulti == true
	local selected = isMulti and {} or (choices[1] or "")
	local isOpen = false
	local animateOpen = popupAnimation(window, view)
	local handle = { instance = view.control }
	view.connections.owner = handle
	function handle:get() return isMulti and table.clone(selected) or selected end
	function handle:accepts(selection)
		if not isMulti then return type(selection) == "string" and (table.find(choices, selection) ~= nil or (#choices == 0 and selection == "")) end
		if type(selection) ~= "table" then return false end
		for key in pairs(selection) do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #selection then return false end
		end
		local seen = {}
		for _, choice in ipairs(selection) do
			if not table.find(choices, choice) or seen[choice] then return false end
			seen[choice] = true
		end
		return true
	end
	function handle:set(selection, shouldNotify)
		if not self:accepts(selection) then return false end
		local nextSelection = isMulti and table.clone(selection) or selection
		local hasChanged = isMulti and table.concat(selected, "\0") ~= table.concat(nextSelection, "\0") or (not isMulti and selected ~= nextSelection)
		selected = nextSelection
		refreshDropdown(window, view, selected, isMulti)
		if hasChanged and shouldNotify ~= false then dispatch(options.callback, self:get()) end
		return true
	end
	local function setOpen(shouldOpen)
		isOpen = shouldOpen
		animateOpen(shouldOpen)
		if not shouldOpen then view.search:ReleaseFocus() end
	end
	handle.close = function() setOpen(false) end
	local function selectChoice(choice)
		if isMulti then
			local selection = handle:get()
			local index = table.find(selection, choice)
			if index then table.remove(selection, index) else table.insert(selection, choice) end
			handle:set(selection)
		else
			handle:set(choice)
			closePopup(window)
		end
	end
	function handle:setOptions(nextChoices, shouldNotify)
		choices = validateChoices(nextChoices)
		rebuildChoices(window, view, choices, selectChoice)
		local nextSelection = selected
		if isMulti then
			nextSelection = {}
			for _, choice in ipairs(selected) do if table.find(choices, choice) then table.insert(nextSelection, choice) end end
		elseif not table.find(choices, selected) then nextSelection = choices[1] or "" end
		self:set(nextSelection, shouldNotify)
	end
	connect(window, view.control.Activated, function()
		local shouldOpen = not isOpen
		closePopup(window)
		if shouldOpen then window.closePopup = handle.close; setOpen(true) end
	end)
	connect(window, view.search:GetPropertyChangedSignal("Text"), function() refreshDropdown(window, view, selected, isMulti) end)
	local function cleanup()
		destroyPopup(window, view, handle)
	end
	connect(window, view.control.Destroying, cleanup)
	bindPopupPosition(window, view)
	bindHover(window, view.control, function(isHovered)
		animate(window, view.caption, { TextColor3 = isHovered and window.theme.accent or window.theme.text })
	end)
	handle.cleanup = cleanup
	handle:setOptions(choices, false)
	if options.default ~= nil then assert(handle:set(options.default, false), "Invalid default selection.") end
	return handle
end

Section.addInput = function(self, options)
	local window = self.window
	local maximum, minimum = options.maxLength or 64, options.minLength or 0
	assert(type(maximum) == "number" and maximum % 1 == 0 and maximum >= 1 and maximum <= 32768, "maxLength must be between 1 and 32768.")
	assert(type(minimum) == "number" and minimum % 1 == 0 and minimum >= 0 and minimum <= maximum, "Invalid minLength.")
	local initial = limitText(options.default or "", maximum)
	assert(utf8.len(initial) >= minimum and (not options.validate or options.validate(initial)), "Invalid initial text.")
	local row = createRow(self)
	local width = options.width or 110
	label(window, row, options.name or "Input", { Size = UDim2.new(1, -width - 6, 1, 0) })
	local field = createField(window, row, width, initial, maximum)
	field.PlaceholderText = options.placeholder or ""
	local committed = field.Text
	local handle = { instance = field }
	function handle:set(text, shouldNotify)
		text = limitText(text, maximum)
		if utf8.len(text) < minimum or (options.validate and not options.validate(text)) then field.Text = committed; return false end
		local hasChanged = text ~= committed
		committed, field.Text = text, text
		if hasChanged and shouldNotify ~= false then dispatch(options.callback, text) end
		return true
	end
	function handle:get() return committed end
	connect(window, field.FocusLost, function() handle:set(field.Text) end)
	return handle
end


Underlord.loadIcons = function() return nil end -- Built-in atlas only.

Underlord.getIcon = function(name)
	return resolveIcon({ icons = cachedIcons }, name)
end

Window.getFlag = function(self, id)
	local control = self.flags[id]
	assert(control and control.get, "Control not found: " .. tostring(id))
	return control:get()
end

Window.setFlag = function(self, id, setting, shouldNotify)
	local control = self.flags[id]
	assert(control and control.set, "Control not found: " .. tostring(id))
	control:set(setting, shouldNotify)
end

Window.exportConfig = function(self)
	local settings = {}
	for id, control in pairs(self.flags) do
		if control.get and control.options.shouldSave ~= false then settings[id] = encodeSetting(control:get()) end
	end
	return HttpService:JSONEncode({ format = "Underlord", version = 1, settings = settings })
end

Window.importConfig = function(self, json, shouldNotify)
	local isSuccess, result = pcall(function()
		local config = HttpService:JSONDecode(json)
		assert(type(config) == "table" and config.format == "Underlord" and config.version == 1, "Incompatible configuration.")
		assert(type(config.settings) == "table", "Invalid configuration.")
		local updates = {}
		for id, setting in pairs(config.settings) do
			local control = self.flags[id]
			if control and control.set and control.options.shouldSave ~= false then
				table.insert(updates, { control = control, setting = decodeSetting(control, setting) })
			end
		end
		return updates
	end)
	if not isSuccess then return false, tostring(result) end
	for _, update in ipairs(result) do update.control:set(update.setting, shouldNotify == true) end
	return true
end

Window.reset = function(self, shouldNotify)
	for _, control in ipairs(self.controls) do control:reset(shouldNotify) end
end

Window.setAccent = function(self, accent)
	assert(typeof(accent) == "Color3", "Expected Color3.")
	if self.isDestroyed then return end
	local previous = self.theme.accent
	self.theme.accent = accent
	for _, instance in ipairs(self.gui:GetDescendants()) do
		local properties = self.targets[instance] or {}
		local replacements = {}
		for _, property in ipairs({ "Color", "BackgroundColor3", "TextColor3", "ImageColor3", "TextStrokeColor3" }) do
			local isReadable, current = pcall(function() return instance[property] end)
			if instance.Name ~= "Swatch" and isReadable and (current == previous or properties[property] == previous) then
				replacements[property] = accent
			end
		end
		if next(replacements) then animate(self, instance, replacements) end
	end
	refreshTitle(self)
	for _, tab in ipairs(self.tabs) do refreshTab(tab) end
end

Window.setSize = function(self, size)
	assert(typeof(size) == "Vector2" and size.X >= 560 and size.Y >= 300, "Minimum window size: 560 x 300.")
	self.theme.size = size
	self.host.Size = UDim2.fromOffset(size.X, self.isMinimized and 40 or size.Y)
	fitWindow(self, false)
end

Window.setPosition = function(self, position)
	assert(typeof(position) == "Vector2", "Expected Vector2.")
	self.shownPosition = UDim2.fromOffset(position.X, position.Y)
	fitWindow(self, false)
end

Window.center = function(self)
	fitWindow(self, true)
end

Window.setMinimized = function(self, isMinimized)
	if self.isDestroyed then return end
	self.isMinimized = isMinimized == true
	closePopup(self, true)
	self.body.Visible = not self.isMinimized
	self.host.Size = UDim2.fromOffset(self.theme.size.X, self.isMinimized and 40 or self.theme.size.Y)
	fitWindow(self, false)
end

Window.setTitle = function(self, prefix, accentText, version)
	self.titlePrefix, self.titleAccent = prefix or "UNDER", accentText or "LORD"
	self.titleVersion = version or self.titleVersion
	refreshTitle(self)
end

local function layoutNotifications(window)
	local width = math.max(64, math.min(280, window.viewport.AbsoluteSize.X - 28))
	window.toastStack.Size = UDim2.fromOffset(width, 0)
	local offset = 0
	for index = #window.notifications, 1, -1 do
		local notice = window.notifications[index]
		notice:resize(width)
		animate(window, notice.shell, { Position = UDim2.new(1, 0, 0, -offset) }, 0.16)
		offset = offset + notice.shell.Size.Y.Offset + 8
	end
	if #window.notifications > 1 and offset > window.viewport.AbsoluteSize.Y - 28 then
		window.notifications[1]:dismiss(true)
	end
end

local function createNotificationView(window, options)
	local shell, panel = overlayCard(window, window.toastStack, "Notification", UDim2.fromOffset(280, 74))
	shell.AnchorPoint = Vector2.new(1, 1)
	shell.Position = UDim2.new(1, 24, 0, 0)
	local icon = createIcon(window, panel, options.icon or "bell", 16)
	icon.Position, icon.ImageColor3 = UDim2.fromOffset(10, 10), window.theme.accent
	label(window, panel, limitText(options.title or "Underlord", 64), {
		Position = UDim2.fromOffset(34, 8), Size = UDim2.new(1, -66, 0, 20), TextSize = 13,
	})
	local content = label(window, panel, limitText(options.content or "", 320), {
		Position = UDim2.fromOffset(10, 33), Size = UDim2.new(1, -20, 0, 30), TextSize = 12,
		TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = window.theme.muted,
	})
	local close = button(window, panel, "", {
		Name = "Dismiss", Position = UDim2.new(1, -27, 0, 7), Size = UDim2.fromOffset(20, 20),
	})
	local closeIcon = createIcon(window, close, "x", 12)
	closeIcon.Position = UDim2.fromOffset(4, 4)
	local progress = frame(panel, "Lifetime", { Position = UDim2.new(0, 0, 1, -2), Size = UDim2.new(1, 0, 0, 2),
		BackgroundTransparency = 0, BackgroundColor3 = window.theme.accent })
	return { shell = shell, panel = panel, content = content, close = close, closeIcon = closeIcon, progress = progress }
end

local function notificationHandle(window, view)
	local handle = { isDismissed = false, shell = view.shell, connections = {} }
	function handle:resize(width)
		local height = measureText(window, view.content.Text, width - 20, 64)
		view.content.Size = UDim2.new(1, -20, 0, height)
		view.shell.Size = UDim2.fromOffset(width, height + 45)
	end
	function handle:dismiss(shouldHideImmediately)
		if self.isDismissed or window.isDestroyed then return end
		self.isDismissed = true
		cancelScheduled(window, self.timer)
		releaseConnections(window, self.connections)
		local index = table.find(window.notifications, self)
		if index then table.remove(window.notifications, index) end
		if shouldHideImmediately then
			destroyOverlay(window, view.shell)
		else
			animate(window, view.panel, { GroupTransparency = 1 }, 0.14)
			animate(window, view.shell, { Position = UDim2.new(1, 24, 0, view.shell.Position.Y.Offset) }, 0.14)
			schedule(window, 0.14, function() destroyOverlay(window, view.shell) end)
		end
		layoutNotifications(window)
	end
	table.insert(handle.connections, connect(window, view.close.Activated, function() handle:dismiss() end))
	table.insert(handle.connections, connect(window, view.close.MouseEnter, function()
		animate(window, view.closeIcon, { ImageColor3 = window.theme.accent })
	end))
	table.insert(handle.connections, connect(window, view.close.MouseLeave, function()
		animate(window, view.closeIcon, { ImageColor3 = window.theme.text })
	end))
	return handle
end

Window.notify = function(self, options)
	options = options or {}
	if self.isDestroyed then return end
	if not self.toastStack then
		self.toastStack = frame(self.viewport, "Notifications", { AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -14, 1, -14), Size = UDim2.fromOffset(280, 0), ZIndex = 350 })
		connect(self, self.viewport:GetPropertyChangedSignal("AbsoluteSize"), function() layoutNotifications(self) end)
	end
	if #self.notifications >= 3 then self.notifications[1]:dismiss(true) end
	local duration = tonumber(options.duration) or 4
	if duration ~= duration then duration = 4 end
	duration = math.clamp(duration, 1, 15)
	local view = createNotificationView(self, options)
	local handle = notificationHandle(self, view)
	table.insert(self.notifications, handle)
	layoutNotifications(self)
	animate(self, view.panel, { GroupTransparency = 0 }, 0.16)
	animate(self, view.progress, { Size = UDim2.fromOffset(0, 2) }, duration, Enum.EasingStyle.Linear)
	handle.timer = schedule(self, duration, function() handle.timer = nil; handle:dismiss() end)
	return handle
end

Tab.setName = function(self, name)
	self.button.Name = name
end

Section.setVisible = function(self, isVisible)
	if self.window.hideTooltip then self.window.hideTooltip() end
	local popup = self.window.activePopup
	if not isVisible and popup and popup.control:IsDescendantOf(self.frame) then closePopup(self.window, true) end
	self.frame.Visible = isVisible == true
end

Section.setTitle = function(self, title)
	local heading = self.frame:FindFirstChild("Title")
	if heading then heading.Text = title end
end

Section.addLabel = function(self, options)
	local row = createRow(self, options.height or 18)
	local caption = label(self.window, row, options.text or options.name or "", { TextWrapped = options.wrapped == true })
	return { instance = caption, setText = function(_, text) caption.Text = text end }
end

Section.addSeparator = function(self, options)
	local row = createRow(self, options.name and 22 or 8)
	local divider = frame(row, "Divider", { Position = UDim2.new(0, 0, 1, -2), Size = UDim2.new(1, 0, 0, 1),
		BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(42, 42, 44) })
	if options.name then label(self.window, row, options.name, { TextSize = 12, TextColor3 = self.window.theme.muted }) end
	return { instance = divider }
end

Section.addColorPicker = function(self, options)
	local window = self.window
	local selected = options.default or window.theme.accent
	assert(typeof(selected) == "Color3", "Expected Color3.")
	local view = createColorPanel(self, options)
	local isOpen = false
	local animateOpen = popupAnimation(window, view)
	local handle = { instance = view.control }
	function handle:get() return selected end
	function handle:set(color, shouldNotify)
		if typeof(color) ~= "Color3" then return end
		local hasChanged = color ~= selected
		selected = color
		refreshColor(window, view, color)
		if hasChanged and shouldNotify ~= false then dispatch(options.callback, color) end
	end
	local function setOpen(shouldOpen)
		isOpen = shouldOpen
		animateOpen(shouldOpen)
		if not shouldOpen then
			window.pointer = nil
			view.hex:ReleaseFocus()
		end
	end
	handle.close = function() setOpen(false) end
	connect(window, view.control.Activated, function()
		local shouldOpen = not isOpen
		closePopup(window)
		if shouldOpen then window.closePopup = handle.close; setOpen(true) end
	end)
	connect(window, view.hex.FocusLost, function()
		local hex = view.hex.Text:gsub("^#", "")
		if hex:match("^%x%x%x%x%x%x$") then handle:set(Color3.fromHex(hex)) else refreshColor(window, view, selected) end
	end)
	bindColorPointer(window, view, handle)
	bindPopupPosition(window, view)
	handle.cleanup = function() destroyPopup(window, view, handle) end
	connect(window, view.control.Destroying, handle.cleanup)
	handle:set(selected, false)
	return handle
end

Window.saveConfig = function(self, name)
	if not self.storage or type(self.storage.write) ~= "function" then return false, "Storage unavailable." end
	if type(name) ~= "string" or not name:match("^[%w_-]+$") then return false, "Invalid profile name." end
	return pcall(self.storage.write, "Underlord_" .. name .. ".json", self:exportConfig())
end

Window.loadConfig = function(self, name, shouldNotify)
	if not self.storage or type(self.storage.read) ~= "function" then return false, "Storage unavailable." end
	if type(name) ~= "string" or not name:match("^[%w_-]+$") then return false, "Invalid profile name." end
	local isSuccess, json = pcall(self.storage.read, "Underlord_" .. name .. ".json")
	if not isSuccess then return false, tostring(json) end
	return self:importConfig(json, shouldNotify)
end

Window.createToggleButton = function(self)
	if self.toggleButton then return self.toggleButton end
	local control = button(self, self.viewport, "UL", {
		Name = "ToggleWindow", Position = UDim2.fromOffset(16, 110), Size = UDim2.fromOffset(38, 30),
		BackgroundTransparency = 0, BackgroundColor3 = self.theme.background, ZIndex = 200,
	})
	outline(control, self.theme.outline)
	textHover(self, control)
	connect(self, control.Activated, function() self:setVisible(not self.isVisible) end)
	self.toggleButton = control
	return control
end

registerControl("addButton", "button")
registerControl("addToggle", "toggle")
registerControl("addSlider", "slider")
registerControl("addDropdown", "dropdown")
registerControl("addKeybind", "keybind")
registerControl("addInput", "input")
registerControl("addColorPicker", "color")
registerControl("addLabel", "label")
registerControl("addSeparator", "separator")

return Underlord
