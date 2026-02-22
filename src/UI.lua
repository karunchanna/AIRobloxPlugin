--[[
	UI - Creates and manages the Meshy AI Plugin GUI.
	Provides a 3-step wizard: Generate -> Texture -> Remesh -> Publish
]]

local UI = {}
UI.__index = UI

-- Theme colors (dark, matching Roblox Studio)
local Theme = {
	bg = Color3.fromRGB(46, 46, 46),
	panel = Color3.fromRGB(56, 56, 56),
	input = Color3.fromRGB(37, 37, 37),
	inputBorder = Color3.fromRGB(80, 80, 80),
	primary = Color3.fromRGB(0, 162, 255),
	primaryHover = Color3.fromRGB(40, 180, 255),
	text = Color3.fromRGB(204, 204, 204),
	textMuted = Color3.fromRGB(120, 120, 120),
	heading = Color3.fromRGB(230, 230, 230),
	success = Color3.fromRGB(76, 175, 80),
	error = Color3.fromRGB(244, 67, 54),
	warning = Color3.fromRGB(255, 152, 0),
	divider = Color3.fromRGB(70, 70, 70),
	activeTab = Color3.fromRGB(0, 162, 255),
	inactiveTab = Color3.fromRGB(65, 65, 65),
	disabled = Color3.fromRGB(50, 50, 50),
	disabledText = Color3.fromRGB(90, 90, 90),
	progressBg = Color3.fromRGB(40, 40, 40),
	progressFill = Color3.fromRGB(0, 162, 255),
	sliderTrack = Color3.fromRGB(60, 60, 60),
	sliderFill = Color3.fromRGB(0, 162, 255),
	sliderThumb = Color3.fromRGB(220, 220, 220),
}

local PADDING = 12
local SPACING = 8
local CORNER = UDim.new(0, 6)
local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

----------------------------------------------------------------------
-- Helper: create a UICorner
----------------------------------------------------------------------
local function addCorner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or CORNER
	c.Parent = parent
	return c
end

----------------------------------------------------------------------
-- Helper: create a UIStroke (border)
----------------------------------------------------------------------
local function addBorder(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.inputBorder
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

----------------------------------------------------------------------
-- Helper: create a UIPadding
----------------------------------------------------------------------
local function addPadding(parent, t, b, l, r)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, t or PADDING)
	p.PaddingBottom = UDim.new(0, b or PADDING)
	p.PaddingLeft = UDim.new(0, l or PADDING)
	p.PaddingRight = UDim.new(0, r or PADDING)
	p.Parent = parent
	return p
end

----------------------------------------------------------------------
-- Helper: create a TextLabel
----------------------------------------------------------------------
local function createLabel(props)
	local label = Instance.new("TextLabel")
	label.Name = props.Name or "Label"
	label.Size = props.Size or UDim2.new(1, 0, 0, 20)
	label.BackgroundTransparency = 1
	label.Font = props.Font or FONT
	label.TextColor3 = props.TextColor3 or Theme.text
	label.TextSize = props.TextSize or 14
	label.Text = props.Text or ""
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.Y
	label.LayoutOrder = props.LayoutOrder or 0
	label.Parent = props.Parent
	return label
end

----------------------------------------------------------------------
-- Helper: create a TextBox
----------------------------------------------------------------------
local function createInput(props)
	local frame = Instance.new("Frame")
	frame.Name = props.Name or "InputFrame"
	frame.Size = props.Size or UDim2.new(1, 0, 0, 32)
	frame.BackgroundColor3 = Theme.input
	frame.LayoutOrder = props.LayoutOrder or 0
	frame.Parent = props.Parent
	addCorner(frame)
	addBorder(frame, Theme.inputBorder)

	local box = Instance.new("TextBox")
	box.Name = "Input"
	box.Size = UDim2.new(1, -16, 1, 0)
	box.Position = UDim2.new(0, 8, 0, 0)
	box.BackgroundTransparency = 1
	box.Font = FONT
	box.TextColor3 = Theme.text
	box.PlaceholderColor3 = Theme.textMuted
	box.TextSize = 13
	box.PlaceholderText = props.Placeholder or ""
	box.Text = props.DefaultText or ""
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.TextWrapped = false
	box.ClipsDescendants = true
	box.Parent = frame

	return frame, box
end

----------------------------------------------------------------------
-- Helper: create a button
----------------------------------------------------------------------
local function createButton(props)
	local btn = Instance.new("TextButton")
	btn.Name = props.Name or "Button"
	btn.Size = props.Size or UDim2.new(1, 0, 0, 36)
	btn.BackgroundColor3 = props.Color or Theme.primary
	btn.Font = FONT_BOLD
	btn.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	btn.TextSize = 14
	btn.Text = props.Text or "Button"
	btn.AutoButtonColor = true
	btn.LayoutOrder = props.LayoutOrder or 0
	btn.Parent = props.Parent
	addCorner(btn)

	return btn
end

----------------------------------------------------------------------
-- Helper: create a section heading
----------------------------------------------------------------------
local function createSectionHeading(props)
	local frame = Instance.new("Frame")
	frame.Name = props.Name or "Section"
	frame.Size = UDim2.new(1, 0, 0, 28)
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = props.LayoutOrder or 0
	frame.Parent = props.Parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = FONT_BOLD
	label.TextColor3 = Theme.heading
	label.TextSize = 15
	label.Text = props.Text or "Section"
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = frame

	return frame, label
end

----------------------------------------------------------------------
-- Helper: create a divider line
----------------------------------------------------------------------
local function createDivider(props)
	local div = Instance.new("Frame")
	div.Name = "Divider"
	div.Size = UDim2.new(1, 0, 0, 1)
	div.BackgroundColor3 = Theme.divider
	div.BorderSizePixel = 0
	div.LayoutOrder = props.LayoutOrder or 0
	div.Parent = props.Parent
	return div
end

----------------------------------------------------------------------
-- Helper: create a toggle button group (Text / Image)
----------------------------------------------------------------------
local function createToggle(props)
	local frame = Instance.new("Frame")
	frame.Name = props.Name or "Toggle"
	frame.Size = UDim2.new(1, 0, 0, 30)
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = props.LayoutOrder or 0
	frame.Parent = props.Parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 4)
	layout.Parent = frame

	local btnA = Instance.new("TextButton")
	btnA.Name = "OptionA"
	btnA.Size = UDim2.new(0.5, -2, 1, 0)
	btnA.BackgroundColor3 = Theme.activeTab
	btnA.Font = FONT
	btnA.TextColor3 = Color3.new(1, 1, 1)
	btnA.TextSize = 13
	btnA.Text = props.OptionA or "Option A"
	btnA.Parent = frame
	addCorner(btnA)

	local btnB = Instance.new("TextButton")
	btnB.Name = "OptionB"
	btnB.Size = UDim2.new(0.5, -2, 1, 0)
	btnB.BackgroundColor3 = Theme.inactiveTab
	btnB.Font = FONT
	btnB.TextColor3 = Theme.textMuted
	btnB.TextSize = 13
	btnB.Text = props.OptionB or "Option B"
	btnB.Parent = frame
	addCorner(btnB)

	local selected = "A"

	local function setSelected(option)
		selected = option
		if option == "A" then
			btnA.BackgroundColor3 = Theme.activeTab
			btnA.TextColor3 = Color3.new(1, 1, 1)
			btnB.BackgroundColor3 = Theme.inactiveTab
			btnB.TextColor3 = Theme.textMuted
		else
			btnB.BackgroundColor3 = Theme.activeTab
			btnB.TextColor3 = Color3.new(1, 1, 1)
			btnA.BackgroundColor3 = Theme.inactiveTab
			btnA.TextColor3 = Theme.textMuted
		end
		if props.OnChanged then
			props.OnChanged(option)
		end
	end

	btnA.Activated:Connect(function() setSelected("A") end)
	btnB.Activated:Connect(function() setSelected("B") end)

	return frame, function() return selected end, setSelected
end

----------------------------------------------------------------------
-- Helper: create a progress bar with status text
----------------------------------------------------------------------
local function createProgressBar(props)
	local container = Instance.new("Frame")
	container.Name = props.Name or "ProgressContainer"
	container.Size = UDim2.new(1, 0, 0, 40)
	container.BackgroundTransparency = 1
	container.LayoutOrder = props.LayoutOrder or 0
	container.Visible = false
	container.Parent = props.Parent

	-- Progress bar track
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, 0, 0, 6)
	track.Position = UDim2.new(0, 0, 0, 0)
	track.BackgroundColor3 = Theme.progressBg
	track.Parent = container
	addCorner(track, UDim.new(0, 3))

	-- Progress bar fill
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Theme.progressFill
	fill.Parent = track
	addCorner(fill, UDim.new(0, 3))

	-- Status label
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Size = UDim2.new(1, 0, 0, 18)
	status.Position = UDim2.new(0, 0, 0, 10)
	status.BackgroundTransparency = 1
	status.Font = FONT
	status.TextColor3 = Theme.textMuted
	status.TextSize = 12
	status.Text = ""
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Parent = container

	-- Controller functions
	local controller = {}

	function controller:setProgress(percent: number)
		fill.Size = UDim2.new(math.clamp(percent / 100, 0, 1), 0, 1, 0)
	end

	function controller:setStatus(text: string, color: Color3?)
		status.Text = text
		status.TextColor3 = color or Theme.textMuted
	end

	function controller:show()
		container.Visible = true
	end

	function controller:hide()
		container.Visible = false
	end

	function controller:reset()
		fill.Size = UDim2.new(0, 0, 1, 0)
		status.Text = ""
		container.Visible = false
	end

	return container, controller
end

----------------------------------------------------------------------
-- Helper: create a slider (1000 - 20000)
----------------------------------------------------------------------
local function createSlider(props)
	local minVal = props.Min or 1000
	local maxVal = props.Max or 20000
	local defaultVal = props.Default or 10000
	local step = props.Step or 100

	local container = Instance.new("Frame")
	container.Name = props.Name or "Slider"
	container.Size = UDim2.new(1, 0, 0, 52)
	container.BackgroundTransparency = 1
	container.LayoutOrder = props.LayoutOrder or 0
	container.Parent = props.Parent

	-- Value label
	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.Size = UDim2.new(1, 0, 0, 18)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Font = FONT
	valueLabel.TextColor3 = Theme.text
	valueLabel.TextSize = 13
	valueLabel.Text = "Triangle Count: " .. tostring(defaultVal)
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left
	valueLabel.Parent = container

	-- Track
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, -20, 0, 8)
	track.Position = UDim2.new(0, 10, 0, 24)
	track.BackgroundColor3 = Theme.sliderTrack
	track.Parent = container
	addCorner(track, UDim.new(0, 4))

	-- Fill
	local fillFraction = (defaultVal - minVal) / (maxVal - minVal)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(fillFraction, 0, 1, 0)
	fill.BackgroundColor3 = Theme.sliderFill
	fill.Parent = track
	addCorner(fill, UDim.new(0, 4))

	-- Thumb
	local thumb = Instance.new("TextButton")
	thumb.Name = "Thumb"
	thumb.Size = UDim2.new(0, 16, 0, 16)
	thumb.Position = UDim2.new(fillFraction, -8, 0.5, -8)
	thumb.BackgroundColor3 = Theme.sliderThumb
	thumb.Text = ""
	thumb.AutoButtonColor = false
	thumb.ZIndex = 2
	thumb.Parent = track
	addCorner(thumb, UDim.new(0.5, 0))

	-- Min/Max labels
	local minLabel = Instance.new("TextLabel")
	minLabel.Size = UDim2.new(0.5, 0, 0, 16)
	minLabel.Position = UDim2.new(0, 0, 0, 36)
	minLabel.BackgroundTransparency = 1
	minLabel.Font = FONT
	minLabel.TextColor3 = Theme.textMuted
	minLabel.TextSize = 11
	minLabel.Text = tostring(minVal)
	minLabel.TextXAlignment = Enum.TextXAlignment.Left
	minLabel.Parent = container

	local maxLabel = Instance.new("TextLabel")
	maxLabel.Size = UDim2.new(0.5, 0, 0, 16)
	maxLabel.Position = UDim2.new(0.5, 0, 0, 36)
	maxLabel.BackgroundTransparency = 1
	maxLabel.Font = FONT
	maxLabel.TextColor3 = Theme.textMuted
	maxLabel.TextSize = 11
	maxLabel.Text = tostring(maxVal)
	maxLabel.TextXAlignment = Enum.TextXAlignment.Right
	maxLabel.Parent = container

	-- State
	local currentValue = defaultVal
	local dragging = false

	local UserInputService = game:GetService("UserInputService")

	local function updateValue(fraction)
		fraction = math.clamp(fraction, 0, 1)
		local raw = minVal + fraction * (maxVal - minVal)
		currentValue = math.floor(raw / step + 0.5) * step
		currentValue = math.clamp(currentValue, minVal, maxVal)

		local displayFraction = (currentValue - minVal) / (maxVal - minVal)
		fill.Size = UDim2.new(displayFraction, 0, 1, 0)
		thumb.Position = UDim2.new(displayFraction, -8, 0.5, -8)
		valueLabel.Text = "Triangle Count: " .. tostring(currentValue)

		if props.OnChanged then
			props.OnChanged(currentValue)
		end
	end

	thumb.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
		end
	end)

	thumb.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	-- Also allow clicking on the track to jump
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			local fraction = (input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
			updateValue(fraction)
		end
	end)

	track.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local fraction = (input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
			updateValue(fraction)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	-- Controller
	local controller = {}

	function controller:getValue()
		return currentValue
	end

	function controller:setValue(val)
		local fraction = (val - minVal) / (maxVal - minVal)
		updateValue(fraction)
	end

	return container, controller
end

----------------------------------------------------------------------
-- Main UI builder
----------------------------------------------------------------------
function UI.new(widget: DockWidgetPluginGui)
	local self = setmetatable({}, UI)
	self.widget = widget
	self.callbacks = {}
	self:_build()
	return self
end

function UI:_build()
	local widget = self.widget

	-- Root scroll frame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Root"
	scroll.Size = UDim2.new(1, 0, 1, 0)
	scroll.BackgroundColor3 = Theme.bg
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = Theme.textMuted
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = widget

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, SPACING)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	addPadding(scroll, PADDING, PADDING, PADDING, PADDING)

	local order = 0
	local function nextOrder()
		order = order + 1
		return order
	end

	--------------------------------------------------------------------
	-- Title
	--------------------------------------------------------------------
	createLabel({
		Name = "Title",
		Text = "Meshy AI Asset Generator",
		Font = FONT_BOLD,
		TextSize = 18,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})

	createDivider({ LayoutOrder = nextOrder(), Parent = scroll })

	--------------------------------------------------------------------
	-- Settings: API Key
	--------------------------------------------------------------------
	createSectionHeading({
		Name = "SettingsHeader",
		Text = "Settings",
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})

	createLabel({
		Name = "ApiKeyLabel",
		Text = "Meshy API Key",
		TextSize = 12,
		TextColor3 = Theme.textMuted,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})

	-- API key row: input + save button
	local apiKeyRow = Instance.new("Frame")
	apiKeyRow.Name = "ApiKeyRow"
	apiKeyRow.Size = UDim2.new(1, 0, 0, 32)
	apiKeyRow.BackgroundTransparency = 1
	apiKeyRow.LayoutOrder = nextOrder()
	apiKeyRow.Parent = scroll

	local apiKeyFrame = Instance.new("Frame")
	apiKeyFrame.Name = "ApiKeyInputFrame"
	apiKeyFrame.Size = UDim2.new(1, -70, 1, 0)
	apiKeyFrame.BackgroundColor3 = Theme.input
	apiKeyFrame.Parent = apiKeyRow
	addCorner(apiKeyFrame)
	addBorder(apiKeyFrame, Theme.inputBorder)

	local apiKeyInput = Instance.new("TextBox")
	apiKeyInput.Name = "ApiKeyInput"
	apiKeyInput.Size = UDim2.new(1, -16, 1, 0)
	apiKeyInput.Position = UDim2.new(0, 8, 0, 0)
	apiKeyInput.BackgroundTransparency = 1
	apiKeyInput.Font = FONT
	apiKeyInput.TextColor3 = Theme.text
	apiKeyInput.PlaceholderColor3 = Theme.textMuted
	apiKeyInput.TextSize = 13
	apiKeyInput.PlaceholderText = "msy_..."
	apiKeyInput.Text = ""
	apiKeyInput.TextXAlignment = Enum.TextXAlignment.Left
	apiKeyInput.ClearTextOnFocus = false
	apiKeyInput.Parent = apiKeyFrame
	self._apiKeyInput = apiKeyInput

	local saveKeyBtn = createButton({
		Name = "SaveKey",
		Text = "Save",
		Size = UDim2.new(0, 60, 1, 0),
		Color = Theme.primary,
		Parent = apiKeyRow,
	})
	saveKeyBtn.Position = UDim2.new(1, -60, 0, 0)
	saveKeyBtn.Activated:Connect(function()
		if self.callbacks.onApiKeySaved then
			self.callbacks.onApiKeySaved(apiKeyInput.Text)
		end
	end)

	createDivider({ LayoutOrder = nextOrder(), Parent = scroll })

	--------------------------------------------------------------------
	-- Step 1: Generate Mesh
	--------------------------------------------------------------------
	createSectionHeading({
		Name = "Step1Header",
		Text = "Step 1: Generate Mesh",
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})

	createLabel({
		Name = "GenInputLabel",
		Text = "Input Type",
		TextSize = 12,
		TextColor3 = Theme.textMuted,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})

	local _, getGenInputType = createToggle({
		Name = "GenInputToggle",
		OptionA = "Text Prompt",
		OptionB = "Image URL",
		LayoutOrder = nextOrder(),
		Parent = scroll,
		OnChanged = function(option)
			self:_updateGenInputVisibility(option)
		end,
	})
	self._getGenInputType = getGenInputType

	-- Text prompt input
	local genPromptFrame, genPromptInput = createInput({
		Name = "GenPrompt",
		Placeholder = "Describe the 3D object (e.g., a medieval wooden chair)",
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, 0, 0, 60),
		Parent = scroll,
	})
	genPromptInput.TextWrapped = true
	genPromptInput.MultiLine = true
	self._genPromptFrame = genPromptFrame
	self._genPromptInput = genPromptInput

	-- Image URL input (hidden by default)
	local genImageFrame, genImageInput = createInput({
		Name = "GenImageUrl",
		Placeholder = "Paste image URL (https://... or data:image/...)",
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})
	genImageFrame.Visible = false
	self._genImageFrame = genImageFrame
	self._genImageInput = genImageInput

	-- Art style label and toggle (only for text)
	createLabel({
		Name = "ArtStyleLabel",
		Text = "Art Style",
		TextSize = 12,
		TextColor3 = Theme.textMuted,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})

	local artStyleFrame = Instance.new("Frame")
	artStyleFrame.Name = "ArtStyleRow"
	artStyleFrame.Size = UDim2.new(1, 0, 0, 30)
	artStyleFrame.BackgroundTransparency = 1
	artStyleFrame.LayoutOrder = nextOrder()
	artStyleFrame.Parent = scroll

	local artStyleLayout = Instance.new("UIListLayout")
	artStyleLayout.FillDirection = Enum.FillDirection.Horizontal
	artStyleLayout.Padding = UDim.new(0, 4)
	artStyleLayout.Parent = artStyleFrame

	local artStyles = {"realistic", "cartoon", "sculpture"}
	local artStyleButtons = {}
	self._selectedArtStyle = "realistic"

	for _, style in ipairs(artStyles) do
		local btn = Instance.new("TextButton")
		btn.Name = "Style_" .. style
		btn.Size = UDim2.new(0, 80, 1, 0)
		btn.BackgroundColor3 = style == "realistic" and Theme.activeTab or Theme.inactiveTab
		btn.Font = FONT
		btn.TextColor3 = style == "realistic" and Color3.new(1, 1, 1) or Theme.textMuted
		btn.TextSize = 12
		btn.Text = style:sub(1, 1):upper() .. style:sub(2)
		btn.Parent = artStyleFrame
		addCorner(btn)

		artStyleButtons[style] = btn

		btn.Activated:Connect(function()
			self._selectedArtStyle = style
			for s, b in pairs(artStyleButtons) do
				if s == style then
					b.BackgroundColor3 = Theme.activeTab
					b.TextColor3 = Color3.new(1, 1, 1)
				else
					b.BackgroundColor3 = Theme.inactiveTab
					b.TextColor3 = Theme.textMuted
				end
			end
		end)
	end
	self._artStyleFrame = artStyleFrame

	-- Generate button
	local genBtn = createButton({
		Name = "GenerateBtn",
		Text = "Generate Mesh",
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})
	genBtn.Activated:Connect(function()
		if self.callbacks.onGenerate then
			local inputType = getGenInputType() == "A" and "text" or "image"
			local prompt = inputType == "text" and genPromptInput.Text or genImageInput.Text
			self.callbacks.onGenerate(inputType, prompt, self._selectedArtStyle)
		end
	end)
	self._genBtn = genBtn

	-- Generate progress
	local _, genProgress = createProgressBar({
		Name = "GenProgress",
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})
	self._genProgress = genProgress

	-- Thumbnail preview
	local thumbnail = Instance.new("ImageLabel")
	thumbnail.Name = "Thumbnail"
	thumbnail.Size = UDim2.new(1, 0, 0, 180)
	thumbnail.BackgroundColor3 = Theme.input
	thumbnail.Image = ""
	thumbnail.ScaleType = Enum.ScaleType.Fit
	thumbnail.LayoutOrder = nextOrder()
	thumbnail.Visible = false
	thumbnail.Parent = scroll
	addCorner(thumbnail)
	self._thumbnail = thumbnail

	createDivider({ LayoutOrder = nextOrder(), Parent = scroll })

	--------------------------------------------------------------------
	-- Step 2: Texture (Optional)
	--------------------------------------------------------------------
	local step2Container = Instance.new("Frame")
	step2Container.Name = "Step2"
	step2Container.Size = UDim2.new(1, 0, 0, 0)
	step2Container.AutomaticSize = Enum.AutomaticSize.Y
	step2Container.BackgroundTransparency = 1
	step2Container.LayoutOrder = nextOrder()
	step2Container.Parent = scroll
	self._step2 = step2Container

	local step2Layout = Instance.new("UIListLayout")
	step2Layout.Padding = UDim.new(0, SPACING)
	step2Layout.SortOrder = Enum.SortOrder.LayoutOrder
	step2Layout.Parent = step2Container

	local step2Order = 0
	local function nextStep2Order()
		step2Order = step2Order + 1
		return step2Order
	end

	createSectionHeading({
		Name = "Step2Header",
		Text = "Step 2: Texture (Optional)",
		LayoutOrder = nextStep2Order(),
		Parent = step2Container,
	})

	createLabel({
		Name = "TexInputLabel",
		Text = "Texture Input Type",
		TextSize = 12,
		TextColor3 = Theme.textMuted,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = nextStep2Order(),
		Parent = step2Container,
	})

	local _, getTexInputType = createToggle({
		Name = "TexInputToggle",
		OptionA = "Text Prompt",
		OptionB = "Image URL",
		LayoutOrder = nextStep2Order(),
		Parent = step2Container,
		OnChanged = function(option)
			self:_updateTexInputVisibility(option)
		end,
	})
	self._getTexInputType = getTexInputType

	local texPromptFrame, texPromptInput = createInput({
		Name = "TexPrompt",
		Placeholder = "Describe the texture (e.g., weathered oak wood with grain)",
		LayoutOrder = nextStep2Order(),
		Size = UDim2.new(1, 0, 0, 60),
		Parent = step2Container,
	})
	texPromptInput.TextWrapped = true
	texPromptInput.MultiLine = true
	self._texPromptFrame = texPromptFrame
	self._texPromptInput = texPromptInput

	local texImageFrame, texImageInput = createInput({
		Name = "TexImageUrl",
		Placeholder = "Paste texture reference image URL",
		LayoutOrder = nextStep2Order(),
		Parent = step2Container,
	})
	texImageFrame.Visible = false
	self._texImageFrame = texImageFrame
	self._texImageInput = texImageInput

	local texBtn = createButton({
		Name = "TextureBtn",
		Text = "Apply Texture",
		LayoutOrder = nextStep2Order(),
		Parent = step2Container,
	})
	texBtn.Activated:Connect(function()
		if self.callbacks.onTexture then
			local inputType = getTexInputType() == "A" and "text" or "image"
			local prompt = inputType == "text" and texPromptInput.Text or texImageInput.Text
			self.callbacks.onTexture(inputType, prompt)
		end
	end)
	self._texBtn = texBtn

	local _, texProgress = createProgressBar({
		Name = "TexProgress",
		LayoutOrder = nextStep2Order(),
		Parent = step2Container,
	})
	self._texProgress = texProgress

	createDivider({ LayoutOrder = nextOrder(), Parent = scroll })

	--------------------------------------------------------------------
	-- Step 3: Remesh (Optional)
	--------------------------------------------------------------------
	local step3Container = Instance.new("Frame")
	step3Container.Name = "Step3"
	step3Container.Size = UDim2.new(1, 0, 0, 0)
	step3Container.AutomaticSize = Enum.AutomaticSize.Y
	step3Container.BackgroundTransparency = 1
	step3Container.LayoutOrder = nextOrder()
	step3Container.Parent = scroll
	self._step3 = step3Container

	local step3Layout = Instance.new("UIListLayout")
	step3Layout.Padding = UDim.new(0, SPACING)
	step3Layout.SortOrder = Enum.SortOrder.LayoutOrder
	step3Layout.Parent = step3Container

	local step3Order = 0
	local function nextStep3Order()
		step3Order = step3Order + 1
		return step3Order
	end

	createSectionHeading({
		Name = "Step3Header",
		Text = "Step 3: Remesh (Optional)",
		LayoutOrder = nextStep3Order(),
		Parent = step3Container,
	})

	createLabel({
		Name = "RemeshInfo",
		Text = "Reduce triangle count for Roblox (max 20,000).",
		TextSize = 12,
		TextColor3 = Theme.textMuted,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = nextStep3Order(),
		Parent = step3Container,
	})

	local _, sliderCtrl = createSlider({
		Name = "TriCountSlider",
		Min = 1000,
		Max = 20000,
		Default = 10000,
		Step = 500,
		LayoutOrder = nextStep3Order(),
		Parent = step3Container,
	})
	self._sliderCtrl = sliderCtrl

	local remeshBtn = createButton({
		Name = "RemeshBtn",
		Text = "Remesh",
		LayoutOrder = nextStep3Order(),
		Parent = step3Container,
	})
	remeshBtn.Activated:Connect(function()
		if self.callbacks.onRemesh then
			self.callbacks.onRemesh(sliderCtrl:getValue())
		end
	end)
	self._remeshBtn = remeshBtn

	local _, remeshProgress = createProgressBar({
		Name = "RemeshProgress",
		LayoutOrder = nextStep3Order(),
		Parent = step3Container,
	})
	self._remeshProgress = remeshProgress

	createDivider({ LayoutOrder = nextOrder(), Parent = scroll })

	--------------------------------------------------------------------
	-- Publish to Workspace
	--------------------------------------------------------------------
	local publishContainer = Instance.new("Frame")
	publishContainer.Name = "Publish"
	publishContainer.Size = UDim2.new(1, 0, 0, 0)
	publishContainer.AutomaticSize = Enum.AutomaticSize.Y
	publishContainer.BackgroundTransparency = 1
	publishContainer.LayoutOrder = nextOrder()
	publishContainer.Parent = scroll
	self._publishContainer = publishContainer

	local pubLayout = Instance.new("UIListLayout")
	pubLayout.Padding = UDim.new(0, SPACING)
	pubLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pubLayout.Parent = publishContainer

	local pubOrder = 0
	local function nextPubOrder()
		pubOrder = pubOrder + 1
		return pubOrder
	end

	createSectionHeading({
		Name = "PublishHeader",
		Text = "Publish to Workspace",
		LayoutOrder = nextPubOrder(),
		Parent = publishContainer,
	})

	local publishBtn = createButton({
		Name = "PublishBtn",
		Text = "Add to Workspace",
		Color = Theme.success,
		LayoutOrder = nextPubOrder(),
		Parent = publishContainer,
	})
	publishBtn.Activated:Connect(function()
		if self.callbacks.onPublish then
			self.callbacks.onPublish()
		end
	end)
	self._publishBtn = publishBtn

	local _, publishProgress = createProgressBar({
		Name = "PublishProgress",
		LayoutOrder = nextPubOrder(),
		Parent = publishContainer,
	})
	self._publishProgress = publishProgress

	-- Download links label (shown as fallback)
	local downloadLabel = createLabel({
		Name = "DownloadLinks",
		Text = "",
		TextSize = 12,
		TextColor3 = Theme.primary,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = nextPubOrder(),
		Parent = publishContainer,
	})
	downloadLabel.TextWrapped = true
	downloadLabel.Visible = false
	self._downloadLabel = downloadLabel

	-- Spacer at bottom
	local spacer = Instance.new("Frame")
	spacer.Name = "Spacer"
	spacer.Size = UDim2.new(1, 0, 0, 20)
	spacer.BackgroundTransparency = 1
	spacer.LayoutOrder = nextOrder()
	spacer.Parent = scroll

	-- Initial state: steps 2-4 disabled
	self:_setStepEnabled(2, false)
	self:_setStepEnabled(3, false)
	self:_setPublishEnabled(false)
end

----------------------------------------------------------------------
-- Input visibility toggles
----------------------------------------------------------------------
function UI:_updateGenInputVisibility(option: string)
	if option == "A" then -- Text
		self._genPromptFrame.Visible = true
		self._genImageFrame.Visible = false
		self._artStyleFrame.Visible = true
	else -- Image
		self._genPromptFrame.Visible = false
		self._genImageFrame.Visible = true
		self._artStyleFrame.Visible = false
	end
end

function UI:_updateTexInputVisibility(option: string)
	if option == "A" then -- Text
		self._texPromptFrame.Visible = true
		self._texImageFrame.Visible = false
	else -- Image
		self._texPromptFrame.Visible = false
		self._texImageFrame.Visible = true
	end
end

----------------------------------------------------------------------
-- Enable/disable steps
----------------------------------------------------------------------
function UI:_setStepEnabled(step: number, enabled: boolean)
	local container
	if step == 2 then
		container = self._step2
	elseif step == 3 then
		container = self._step3
	end
	if not container then return end

	container.Visible = enabled
end

function UI:_setPublishEnabled(enabled: boolean)
	self._publishContainer.Visible = enabled
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function UI:setApiKey(key: string)
	self._apiKeyInput.Text = key
end

function UI:enableStep(step: number)
	self:_setStepEnabled(step, true)
end

function UI:disableStep(step: number)
	self:_setStepEnabled(step, false)
end

function UI:enablePublish()
	self:_setPublishEnabled(true)
end

function UI:disablePublish()
	self:_setPublishEnabled(false)
end

function UI:setThumbnail(url: string)
	if url and url ~= "" then
		self._thumbnail.Image = url
		self._thumbnail.Visible = true
	else
		self._thumbnail.Visible = false
	end
end

function UI:setDownloadLinks(text: string)
	self._downloadLabel.Text = text
	self._downloadLabel.Visible = text ~= ""
end

-- Progress helpers for each step
function UI:showGenProgress()     self._genProgress:show() end
function UI:hideGenProgress()     self._genProgress:hide() end
function UI:setGenProgress(pct)   self._genProgress:setProgress(pct) end
function UI:setGenStatus(t, c)    self._genProgress:setStatus(t, c) end
function UI:resetGenProgress()    self._genProgress:reset() end

function UI:showTexProgress()     self._texProgress:show() end
function UI:hideTexProgress()     self._texProgress:hide() end
function UI:setTexProgress(pct)   self._texProgress:setProgress(pct) end
function UI:setTexStatus(t, c)    self._texProgress:setStatus(t, c) end
function UI:resetTexProgress()    self._texProgress:reset() end

function UI:showRemeshProgress()  self._remeshProgress:show() end
function UI:hideRemeshProgress()  self._remeshProgress:hide() end
function UI:setRemeshProgress(p)  self._remeshProgress:setProgress(p) end
function UI:setRemeshStatus(t, c) self._remeshProgress:setStatus(t, c) end
function UI:resetRemeshProgress() self._remeshProgress:reset() end

function UI:showPubProgress()     self._publishProgress:show() end
function UI:hidePubProgress()     self._publishProgress:hide() end
function UI:setPubProgress(pct)   self._publishProgress:setProgress(pct) end
function UI:setPubStatus(t, c)    self._publishProgress:setStatus(t, c) end
function UI:resetPubProgress()    self._publishProgress:reset() end

-- Button enable/disable
function UI:setButtonEnabled(btn, enabled)
	local button
	if btn == "generate" then button = self._genBtn
	elseif btn == "texture" then button = self._texBtn
	elseif btn == "remesh" then button = self._remeshBtn
	elseif btn == "publish" then button = self._publishBtn
	end
	if not button then return end

	button.AutoButtonColor = enabled
	if enabled then
		button.BackgroundColor3 = btn == "publish" and Theme.success or Theme.primary
		button.TextColor3 = Color3.new(1, 1, 1)
	else
		button.BackgroundColor3 = Theme.disabled
		button.TextColor3 = Theme.disabledText
	end
end

return UI
