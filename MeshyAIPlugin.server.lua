--[[
	Meshy AI Asset Generator - Roblox Studio Plugin (Single File)

	Drop this file into your Roblox Studio Plugins folder:
	  Windows: %localappdata%/Roblox/Plugins/
	  Mac: ~/Documents/Roblox/Plugins/

	A 4-step workflow for generating 3D assets using Meshy's AI API:
	  1. Generate Mesh (text prompt or image)
	  2. Texture (text prompt or reference image)
	  3. Remesh (reduce triangle count for Roblox's 20k limit)
	  4. Publish to Workspace

	Requires a Meshy API key from https://www.meshy.ai/api
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")
local AssetService = game:GetService("AssetService")

-- Compatibility: use task.wait if available, otherwise wait
local taskWait = task and task.wait or wait

------------------------------------------------------------------------
-- OBJParser
------------------------------------------------------------------------
local OBJParser = {}

local function parseFaceVertex(str: string): {v: number, vt: number?, vn: number?}
	local parts = string.split(str, "/")
	local result: any = {}
	result.v = tonumber(parts[1])
	if parts[2] and parts[2] ~= "" then
		result.vt = tonumber(parts[2])
	end
	if parts[3] and parts[3] ~= "" then
		result.vn = tonumber(parts[3])
	end
	return result
end

function OBJParser.parse(objText: string): any
	local positions: {Vector3} = {}
	local uvs: {Vector2} = {}
	local normals: {Vector3} = {}
	local faces = {}

	for line in objText:gmatch("[^\r\n]+") do
		line = line:match("^%s*(.-)%s*$")

		if line == "" or line:sub(1, 1) == "#" then
			-- skip
		elseif line:sub(1, 2) == "v " then
			local x, y, z = line:match("v%s+([%-%d%.e]+)%s+([%-%d%.e]+)%s+([%-%d%.e]+)")
			if x then
				table.insert(positions, Vector3.new(tonumber(x), tonumber(y), tonumber(z)))
			end
		elseif line:sub(1, 3) == "vt " then
			local u, v = line:match("vt%s+([%-%d%.e]+)%s+([%-%d%.e]+)")
			if u then
				table.insert(uvs, Vector2.new(tonumber(u), tonumber(v)))
			end
		elseif line:sub(1, 3) == "vn " then
			local x, y, z = line:match("vn%s+([%-%d%.e]+)%s+([%-%d%.e]+)%s+([%-%d%.e]+)")
			if x then
				table.insert(normals, Vector3.new(tonumber(x), tonumber(y), tonumber(z)))
			end
		elseif line:sub(1, 2) == "f " then
			local faceVerts = {}
			for vertStr in line:sub(3):gmatch("%S+") do
				local vert = parseFaceVertex(vertStr)
				if vert.v < 0 then vert.v = #positions + 1 + vert.v end
				if vert.vt and vert.vt < 0 then vert.vt = #uvs + 1 + vert.vt end
				if vert.vn and vert.vn < 0 then vert.vn = #normals + 1 + vert.vn end
				table.insert(faceVerts, vert)
			end
			if #faceVerts >= 3 then
				for i = 2, #faceVerts - 1 do
					table.insert(faces, { faceVerts[1], faceVerts[i], faceVerts[i + 1] })
				end
			end
		end
	end

	return { positions = positions, uvs = uvs, normals = normals, faces = faces }
end

function OBJParser.getBounds(meshData: any): (Vector3, Vector3, Vector3, Vector3)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, pos in ipairs(meshData.positions) do
		minX = math.min(minX, pos.X)
		minY = math.min(minY, pos.Y)
		minZ = math.min(minZ, pos.Z)
		maxX = math.max(maxX, pos.X)
		maxY = math.max(maxY, pos.Y)
		maxZ = math.max(maxZ, pos.Z)
	end
	local min = Vector3.new(minX, minY, minZ)
	local max = Vector3.new(maxX, maxY, maxZ)
	return min, max, max - min, (min + max) / 2
end

------------------------------------------------------------------------
-- MeshyAPI
------------------------------------------------------------------------
local MeshyAPI = {}
MeshyAPI.__index = MeshyAPI

local BASE_URL = "https://api.meshy.ai"

local ENDPOINTS = {
	["text-to-3d"] = "/openapi/v2/text-to-3d",
	["image-to-3d"] = "/openapi/v1/image-to-3d",
	["retexture"] = "/openapi/v1/retexture",
	["remesh"] = "/openapi/v1/remesh",
}

function MeshyAPI.new()
	local self = setmetatable({}, MeshyAPI)
	self._apiKey = ""
	return self
end

function MeshyAPI:setApiKey(key: string)
	self._apiKey = key
end

function MeshyAPI:getApiKey(): string
	return self._apiKey
end

function MeshyAPI:_request(method: string, path: string, body: any?): any
	if self._apiKey == "" then
		error("API key not set. Please enter your Meshy API key in Settings.")
	end

	local url = BASE_URL .. path
	local headers = {
		["Authorization"] = "Bearer " .. self._apiKey,
		["Content-Type"] = "application/json",
	}

	local requestOptions: any = {
		Url = url,
		Method = method,
		Headers = headers,
	}

	if body and method ~= "GET" then
		requestOptions.Body = HttpService:JSONEncode(body)
	end

	local success, response = pcall(function()
		return HttpService:RequestAsync(requestOptions)
	end)

	if not success then
		error("HTTP request failed: " .. tostring(response))
	end

	if response.StatusCode < 200 or response.StatusCode >= 300 then
		local errorMsg = "API error (" .. response.StatusCode .. ")"
		pcall(function()
			local decoded = HttpService:JSONDecode(response.Body)
			if decoded.message then
				errorMsg = errorMsg .. ": " .. decoded.message
			end
		end)
		error(errorMsg)
	end

	return HttpService:JSONDecode(response.Body)
end

function MeshyAPI:textTo3DPreview(prompt: string, artStyle: string?): string
	local body: any = {
		mode = "preview",
		prompt = prompt,
		art_style = artStyle or "realistic",
		should_remesh = false,
	}
	local result = self:_request("POST", ENDPOINTS["text-to-3d"], body)
	return result.result
end

function MeshyAPI:textTo3DRefine(previewTaskId: string, texturePrompt: string?, textureImageUrl: string?): string
	local body: any = {
		mode = "refine",
		preview_task_id = previewTaskId,
		enable_pbr = true,
	}
	if textureImageUrl and textureImageUrl ~= "" then
		body.texture_image_url = textureImageUrl
	elseif texturePrompt and texturePrompt ~= "" then
		body.texture_prompt = texturePrompt
	end
	local result = self:_request("POST", ENDPOINTS["text-to-3d"], body)
	return result.result
end

function MeshyAPI:imageTo3D(imageUrl: string, shouldTexture: boolean?): string
	local body: any = {
		image_url = imageUrl,
		should_texture = shouldTexture or false,
		enable_pbr = true,
	}
	local result = self:_request("POST", ENDPOINTS["image-to-3d"], body)
	return result.result
end

function MeshyAPI:retexture(inputTaskId: string, textStylePrompt: string?, imageStyleUrl: string?): string
	local body: any = {
		input_task_id = inputTaskId,
		enable_pbr = true,
	}
	if imageStyleUrl and imageStyleUrl ~= "" then
		body.image_style_url = imageStyleUrl
	end
	if textStylePrompt and textStylePrompt ~= "" then
		body.text_style_prompt = textStylePrompt
	end
	local result = self:_request("POST", ENDPOINTS["retexture"], body)
	return result.result
end

function MeshyAPI:remesh(inputTaskId: string, targetPolycount: number): string
	local body = {
		input_task_id = inputTaskId,
		target_polycount = targetPolycount,
		topology = "triangle",
		target_formats = {"obj", "glb"},
	}
	local result = self:_request("POST", ENDPOINTS["remesh"], body)
	return result.result
end

function MeshyAPI:getTask(taskType: string, taskId: string): any
	local endpoint = ENDPOINTS[taskType]
	if not endpoint then
		error("Unknown task type: " .. taskType)
	end
	return self:_request("GET", endpoint .. "/" .. taskId)
end

function MeshyAPI:pollTask(taskType: string, taskId: string, onProgress: ((number) -> ())?): any
	local POLL_INTERVAL = 3
	local MAX_POLLS = 200

	for _ = 1, MAX_POLLS do
		local taskData = self:getTask(taskType, taskId)
		local status = taskData.status

		if onProgress and taskData.progress then
			onProgress(taskData.progress)
		end

		if status == "SUCCEEDED" then
			if onProgress then onProgress(100) end
			return taskData
		elseif status == "FAILED" or status == "CANCELED" then
			local errMsg = taskData.task_error and taskData.task_error.message or "Unknown error"
			error("Task " .. status:lower() .. ": " .. errMsg)
		end

		taskWait(POLL_INTERVAL)
	end

	error("Task timed out after polling " .. MAX_POLLS .. " times")
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local UI = {}
UI.__index = UI

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

local function addCorner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or CORNER
	c.Parent = parent
	return c
end

local function addBorder(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.inputBorder
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function addPadding(parent, t, b, l, r)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, t or PADDING)
	p.PaddingBottom = UDim.new(0, b or PADDING)
	p.PaddingLeft = UDim.new(0, l or PADDING)
	p.PaddingRight = UDim.new(0, r or PADDING)
	p.Parent = parent
	return p
end

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

local function createProgressBar(props)
	local container = Instance.new("Frame")
	container.Name = props.Name or "ProgressContainer"
	container.Size = UDim2.new(1, 0, 0, 40)
	container.BackgroundTransparency = 1
	container.LayoutOrder = props.LayoutOrder or 0
	container.Visible = false
	container.Parent = props.Parent

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, 0, 0, 6)
	track.Position = UDim2.new(0, 0, 0, 0)
	track.BackgroundColor3 = Theme.progressBg
	track.Parent = container
	addCorner(track, UDim.new(0, 3))

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Theme.progressFill
	fill.Parent = track
	addCorner(fill, UDim.new(0, 3))

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

	local controller = {}
	function controller:setProgress(percent: number)
		fill.Size = UDim2.new(math.clamp(percent / 100, 0, 1), 0, 1, 0)
	end
	function controller:setStatus(text: string, color: Color3?)
		status.Text = text
		status.TextColor3 = color or Theme.textMuted
	end
	function controller:show() container.Visible = true end
	function controller:hide() container.Visible = false end
	function controller:reset()
		fill.Size = UDim2.new(0, 0, 1, 0)
		status.Text = ""
		container.Visible = false
	end

	return container, controller
end

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

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, -20, 0, 8)
	track.Position = UDim2.new(0, 10, 0, 24)
	track.BackgroundColor3 = Theme.sliderTrack
	track.Parent = container
	addCorner(track, UDim.new(0, 4))

	local fillFraction = (defaultVal - minVal) / (maxVal - minVal)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(fillFraction, 0, 1, 0)
	fill.BackgroundColor3 = Theme.sliderFill
	fill.Parent = track
	addCorner(fill, UDim.new(0, 4))

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

	local currentValue = defaultVal
	local dragging = false

	local function updateValue(fraction)
		fraction = math.clamp(fraction, 0, 1)
		local raw = minVal + fraction * (maxVal - minVal)
		currentValue = math.floor(raw / step + 0.5) * step
		currentValue = math.clamp(currentValue, minVal, maxVal)
		local displayFraction = (currentValue - minVal) / (maxVal - minVal)
		fill.Size = UDim2.new(displayFraction, 0, 1, 0)
		thumb.Position = UDim2.new(displayFraction, -8, 0.5, -8)
		valueLabel.Text = "Triangle Count: " .. tostring(currentValue)
		if props.OnChanged then props.OnChanged(currentValue) end
	end

	thumb.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true end
	end)
	thumb.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end)
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			updateValue((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X)
		end
	end)
	track.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			updateValue((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end)

	local controller = {}
	function controller:getValue() return currentValue end
	function controller:setValue(val)
		updateValue((val - minVal) / (maxVal - minVal))
	end

	return container, controller
end

-- UI constructor
function UI.new(widget: DockWidgetPluginGui)
	local self = setmetatable({}, UI)
	self.widget = widget
	self.callbacks = {}
	self:_build()
	return self
end

function UI:_build()
	local widget = self.widget

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

	-- Title
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

	-- Settings: API Key
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

	-- Step 1: Generate Mesh
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

	local genImageFrame, genImageInput = createInput({
		Name = "GenImageUrl",
		Placeholder = "Paste image URL (https://... or data:image/...)",
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})
	genImageFrame.Visible = false
	self._genImageFrame = genImageFrame
	self._genImageInput = genImageInput

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

	local artStyles = {"realistic", "sculpture"}
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

	local _, genProgress = createProgressBar({
		Name = "GenProgress",
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})
	self._genProgress = genProgress

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

	-- Step 2: Texture (Optional)
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

	-- Step 3: Remesh (Optional)
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

	-- Publish to Workspace
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
		Text = "Publish Asset",
		LayoutOrder = nextPubOrder(),
		Parent = publishContainer,
	})

	local publishBtn = createButton({
		Name = "PublishBtn",
		Text = "Publish as Roblox Asset",
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

	-- Download links (selectable TextBox so users can copy)
	local downloadBox = Instance.new("TextBox")
	downloadBox.Name = "DownloadLinks"
	downloadBox.Size = UDim2.new(1, 0, 0, 0)
	downloadBox.AutomaticSize = Enum.AutomaticSize.Y
	downloadBox.BackgroundColor3 = Theme.input
	downloadBox.Font = FONT
	downloadBox.TextColor3 = Theme.primary
	downloadBox.TextSize = 12
	downloadBox.Text = ""
	downloadBox.TextXAlignment = Enum.TextXAlignment.Left
	downloadBox.TextWrapped = true
	downloadBox.MultiLine = true
	downloadBox.ClearTextOnFocus = false
	downloadBox.TextEditable = false
	downloadBox.Visible = false
	downloadBox.LayoutOrder = nextPubOrder()
	downloadBox.Parent = publishContainer
	addCorner(downloadBox)
	addPadding(downloadBox, 8, 8, 8, 8)
	self._downloadLabel = downloadBox

	local spacer = Instance.new("Frame")
	spacer.Name = "Spacer"
	spacer.Size = UDim2.new(1, 0, 0, 20)
	spacer.BackgroundTransparency = 1
	spacer.LayoutOrder = nextOrder()
	spacer.Parent = scroll

	self:_setStepEnabled(2, false)
	self:_setStepEnabled(3, false)
	self:_setPublishEnabled(false)
end

function UI:_updateGenInputVisibility(option: string)
	if option == "A" then
		self._genPromptFrame.Visible = true
		self._genImageFrame.Visible = false
		self._artStyleFrame.Visible = true
	else
		self._genPromptFrame.Visible = false
		self._genImageFrame.Visible = true
		self._artStyleFrame.Visible = false
	end
end

function UI:_updateTexInputVisibility(option: string)
	if option == "A" then
		self._texPromptFrame.Visible = true
		self._texImageFrame.Visible = false
	else
		self._texPromptFrame.Visible = false
		self._texImageFrame.Visible = true
	end
end

function UI:_setStepEnabled(step: number, enabled: boolean)
	local container
	if step == 2 then container = self._step2
	elseif step == 3 then container = self._step3 end
	if not container then return end
	container.Visible = enabled
end

function UI:_setPublishEnabled(enabled: boolean)
	self._publishContainer.Visible = enabled
end

function UI:setApiKey(key: string) self._apiKeyInput.Text = key end
function UI:enableStep(step: number) self:_setStepEnabled(step, true) end
function UI:disableStep(step: number) self:_setStepEnabled(step, false) end
function UI:enablePublish() self:_setPublishEnabled(true) end
function UI:disablePublish() self:_setPublishEnabled(false) end

function UI:setThumbnail(url: string)
	if url and url ~= "" then
		self._thumbnail.Image = url
		self._thumbnail.Visible = true
	else
		self._thumbnail.Visible = false
	end
end

function UI:setDownloadLinks(text: string)
	if text ~= "" then
		self._downloadLabel.Text = text .. "\n\n(Click text to select, then Ctrl+C to copy. Also printed to Output.)"
	else
		self._downloadLabel.Text = ""
	end
	self._downloadLabel.Visible = text ~= ""
end

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

function UI:setButtonEnabled(btn, enabled)
	local button
	if btn == "generate" then button = self._genBtn
	elseif btn == "texture" then button = self._texBtn
	elseif btn == "remesh" then button = self._remeshBtn
	elseif btn == "publish" then button = self._publishBtn end
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

------------------------------------------------------------------------
-- Plugin Setup
------------------------------------------------------------------------
local toolbar = plugin:CreateToolbar("Meshy AI")
local toggleButton = toolbar:CreateButton(
	"Asset Generator",
	"Generate 3D assets with Meshy AI",
	"rbxassetid://14978048121"
)

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false, false,
	320, 700,
	280, 400
)

local widget = plugin:CreateDockWidgetPluginGui("MeshyAIAssetGenerator", widgetInfo)
widget.Title = "Meshy AI"

local api = MeshyAPI.new()
local ui = UI.new(widget)

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local state = {
	currentTaskId = nil,
	currentTaskType = nil,
	sourceType = nil,
	modelUrls = nil,
	textureUrls = nil,
	thumbnailUrl = nil,
	busy = false,
	-- Preview mesh (shown in workspace after generation)
	previewMeshPart = nil,
	previewEditableMesh = nil,
}

------------------------------------------------------------------------
-- Persistence: load/save API key
------------------------------------------------------------------------
local function loadApiKey()
	local key = plugin:GetSetting("MeshyApiKey")
	if key and key ~= "" then
		api:setApiKey(key)
		ui:setApiKey(key)
	end
end

local function saveApiKey(key)
	plugin:SetSetting("MeshyApiKey", key)
	api:setApiKey(key)
end

loadApiKey()

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function setBusy(busy)
	state.busy = busy
	ui:setButtonEnabled("generate", not busy)
	ui:setButtonEnabled("texture", not busy)
	ui:setButtonEnabled("remesh", not busy)
	ui:setButtonEnabled("publish", not busy)
end

local function downloadText(url: string): string
	local response = HttpService:RequestAsync({
		Url = url,
		Method = "GET",
	})
	if response.StatusCode ~= 200 then
		error("Download failed (HTTP " .. response.StatusCode .. ")")
	end
	return response.Body
end

------------------------------------------------------------------------
-- Mesh Import: OBJ -> EditableMesh -> MeshPart
------------------------------------------------------------------------
local function createMeshFromOBJ(objText: string)
	local meshData = OBJParser.parse(objText)

	if #meshData.positions == 0 or #meshData.faces == 0 then
		error("OBJ file contains no geometry")
	end

	local editableMesh = AssetService:CreateEditableMesh()
	if not editableMesh then
		error("Failed to create EditableMesh (memory budget may be exhausted)")
	end

	-- Add all vertex positions
	local vertexIds = {}
	for i, pos in ipairs(meshData.positions) do
		vertexIds[i] = editableMesh:AddVertex(pos)
	end

	-- Add all normals
	local normalIds = {}
	for i, normal in ipairs(meshData.normals) do
		normalIds[i] = editableMesh:AddNormal(normal)
	end

	-- Add all UVs (flip V for Roblox: OBJ is bottom-left origin, Roblox is top-left)
	local uvIds = {}
	for i, uv in ipairs(meshData.uvs) do
		uvIds[i] = editableMesh:AddUV(Vector2.new(uv.X, 1 - uv.Y))
	end

	-- Add triangles, then assign normals and UVs per-face
	local triCount = 0
	for _, face in ipairs(meshData.faces) do
		local v1 = vertexIds[face[1].v]
		local v2 = vertexIds[face[2].v]
		local v3 = vertexIds[face[3].v]

		if not v1 or not v2 or not v3 then continue end

		local ok, faceId = pcall(function()
			return editableMesh:AddTriangle(v1, v2, v3)
		end)

		if ok and faceId then
			triCount = triCount + 1

			-- Assign normals to this face's vertices
			if face[1].vn and face[2].vn and face[3].vn then
				local n1 = normalIds[face[1].vn]
				local n2 = normalIds[face[2].vn]
				local n3 = normalIds[face[3].vn]
				if n1 and n2 and n3 then
					pcall(function()
						editableMesh:SetFaceNormals(faceId, {n1, n2, n3})
					end)
				end
			end

			-- Assign UVs to this face's vertices
			if face[1].vt and face[2].vt and face[3].vt then
				local uv1 = uvIds[face[1].vt]
				local uv2 = uvIds[face[2].vt]
				local uv3 = uvIds[face[3].vt]
				if uv1 and uv2 and uv3 then
					pcall(function()
						editableMesh:SetFaceUVs(faceId, {uv1, uv2, uv3})
					end)
				end
			end
		end
	end

	if triCount == 0 then
		editableMesh:Destroy()
		error("Failed to create any triangles from OBJ data")
	end

	-- Create a MeshPart from the EditableMesh via AssetService
	local meshPart = AssetService:CreateMeshPartAsync(Content.fromObject(editableMesh))
	meshPart.Name = "MeshyAsset"
	meshPart.Anchored = true

	return meshPart, editableMesh, triCount
end

-- Import preview mesh into workspace, removing any previous preview
local function importPreview(modelUrls)
	-- Log available formats for debugging
	if modelUrls then
		local formats = {}
		for k, v in pairs(modelUrls) do
			if v and v ~= "" then
				table.insert(formats, k)
			end
		end
		print("[Meshy AI] Available model formats: " .. table.concat(formats, ", "))
	else
		warn("[Meshy AI] No model_urls in task result")
		return nil
	end

	local objUrl = modelUrls.obj
	if not objUrl or objUrl == "" then
		warn("[Meshy AI] OBJ format not available in model_urls, cannot preview")
		return nil
	end

	-- Remove old preview
	if state.previewMeshPart and state.previewMeshPart.Parent then
		state.previewMeshPart:Destroy()
	end
	if state.previewEditableMesh then
		pcall(function() state.previewEditableMesh:Destroy() end)
	end
	state.previewMeshPart = nil
	state.previewEditableMesh = nil

	print("[Meshy AI] Downloading OBJ from: " .. objUrl:sub(1, 80) .. "...")
	local objText = downloadText(objUrl)
	print("[Meshy AI] OBJ downloaded, " .. tostring(#objText) .. " bytes. Parsing...")

	local meshPart, editableMesh, triCount = createMeshFromOBJ(objText)
	print("[Meshy AI] Mesh created: " .. tostring(triCount) .. " triangles")

	-- Position in front of camera
	local camera = workspace.CurrentCamera
	if camera then
		meshPart.Position = camera.CFrame.Position + camera.CFrame.LookVector * 15
	end

	meshPart.Parent = workspace
	Selection:Set({meshPart})

	-- Store for later publish
	state.previewMeshPart = meshPart
	state.previewEditableMesh = editableMesh

	return triCount
end

------------------------------------------------------------------------
-- Callbacks
------------------------------------------------------------------------

ui.callbacks.onApiKeySaved = function(key)
	if key == "" then
		ui:showGenProgress()
		ui:setGenStatus("Please enter a valid API key.", Color3.fromRGB(244, 67, 54))
		return
	end
	saveApiKey(key)
	ui:showGenProgress()
	ui:setGenStatus("API key saved!", Color3.fromRGB(76, 175, 80))
	task.delay(2, function()
		ui:resetGenProgress()
	end)
end

-- Step 1: Generate Mesh
ui.callbacks.onGenerate = function(inputType, prompt, artStyle)
	if state.busy then return end
	if prompt == "" then
		ui:showGenProgress()
		ui:setGenStatus("Please enter a prompt or image URL.", Color3.fromRGB(244, 67, 54))
		return
	end

	setBusy(true)
	ui:showGenProgress()
	ui:setGenProgress(0)
	ui:setGenStatus("Creating task...")
	ui:setThumbnail("")

	ui:disableStep(2)
	ui:disableStep(3)
	ui:disablePublish()
	ui:resetTexProgress()
	ui:resetRemeshProgress()
	ui:resetPubProgress()

	task.spawn(function()
		local success, err = pcall(function()
			local taskId, taskType

			if inputType == "text" then
				taskType = "text-to-3d"
				ui:setGenStatus("Submitting text-to-3D preview...")
				taskId = api:textTo3DPreview(prompt, artStyle)
			else
				taskType = "image-to-3d"
				ui:setGenStatus("Submitting image-to-3D task...")
				taskId = api:imageTo3D(prompt, false)
			end

			ui:setGenStatus("Generating mesh... (this may take a few moments)")

			local result = api:pollTask(taskType, taskId, function(progress)
				ui:setGenProgress(progress)
				ui:setGenStatus("Generating mesh... " .. tostring(progress) .. "%")
			end)

			state.currentTaskId = taskId
			state.currentTaskType = taskType
			state.sourceType = taskType
			state.modelUrls = result.model_urls
			state.textureUrls = result.texture_urls
			state.thumbnailUrl = result.thumbnail_url

			ui:setGenProgress(80)
			ui:setGenStatus("Importing preview into workspace...")

			-- Auto-import preview mesh
			local previewOk, previewErr = pcall(importPreview, result.model_urls)
			if previewOk and state.previewMeshPart then
				ui:setGenProgress(100)
				ui:setGenStatus("Mesh generated and previewed!", Color3.fromRGB(76, 175, 80))
			else
				ui:setGenProgress(100)
				ui:setGenStatus("Mesh generated! (preview failed - check Output)", Color3.fromRGB(255, 152, 0))
				if not previewOk then
					warn("[Meshy AI] Preview import error: " .. tostring(previewErr))
				else
					warn("[Meshy AI] Preview returned nil (OBJ format likely unavailable)")
				end
			end

			ui:setThumbnail(result.thumbnail_url or "")
			ui:enableStep(2)
			ui:enableStep(3)
			ui:enablePublish()
		end)

		if not success then
			ui:setGenProgress(0)
			ui:setGenStatus("Error: " .. tostring(err), Color3.fromRGB(244, 67, 54))
		end

		setBusy(false)
	end)
end

-- Step 2: Texture
ui.callbacks.onTexture = function(inputType, prompt)
	if state.busy then return end
	if not state.currentTaskId then
		ui:showTexProgress()
		ui:setTexStatus("Generate a mesh first (Step 1).", Color3.fromRGB(244, 67, 54))
		return
	end
	if prompt == "" then
		ui:showTexProgress()
		ui:setTexStatus("Please enter a texture prompt or image URL.", Color3.fromRGB(244, 67, 54))
		return
	end

	setBusy(true)
	ui:showTexProgress()
	ui:setTexProgress(0)
	ui:setTexStatus("Creating texture task...")

	task.spawn(function()
		local success, err = pcall(function()
			local taskId, taskType

			if state.sourceType == "text-to-3d" then
				taskType = "text-to-3d"
				local texturePrompt = inputType == "text" and prompt or nil
				local textureImageUrl = inputType == "image" and prompt or nil

				ui:setTexStatus("Submitting texture refine task...")
				taskId = api:textTo3DRefine(state.currentTaskId, texturePrompt, textureImageUrl)
			else
				taskType = "retexture"
				local textStylePrompt = inputType == "text" and prompt or nil
				local imageStyleUrl = inputType == "image" and prompt or nil

				ui:setTexStatus("Submitting retexture task...")
				taskId = api:retexture(state.currentTaskId, textStylePrompt, imageStyleUrl)
			end

			ui:setTexStatus("Applying texture...")

			local result = api:pollTask(taskType, taskId, function(progress)
				ui:setTexProgress(progress)
				ui:setTexStatus("Applying texture... " .. tostring(progress) .. "%")
			end)

			state.currentTaskId = taskId
			state.currentTaskType = taskType
			state.modelUrls = result.model_urls
			state.textureUrls = result.texture_urls
			if result.thumbnail_url then
				state.thumbnailUrl = result.thumbnail_url
				ui:setThumbnail(result.thumbnail_url)
			end

			ui:setTexProgress(80)
			ui:setTexStatus("Updating preview...")

			local previewOk, previewErr = pcall(importPreview, result.model_urls)
			if previewOk and state.previewMeshPart then
				ui:setTexProgress(100)
				ui:setTexStatus("Texture applied!", Color3.fromRGB(76, 175, 80))
			else
				ui:setTexProgress(100)
				ui:setTexStatus("Texture applied! (preview failed - check Output)", Color3.fromRGB(255, 152, 0))
				if not previewOk then
					warn("[Meshy AI] Texture preview error: " .. tostring(previewErr))
				end
			end
		end)

		if not success then
			ui:setTexProgress(0)
			ui:setTexStatus("Error: " .. tostring(err), Color3.fromRGB(244, 67, 54))
		end

		setBusy(false)
	end)
end

-- Step 3: Remesh
ui.callbacks.onRemesh = function(targetPolycount)
	if state.busy then return end
	if not state.currentTaskId then
		ui:showRemeshProgress()
		ui:setRemeshStatus("Generate a mesh first (Step 1).", Color3.fromRGB(244, 67, 54))
		return
	end

	setBusy(true)
	ui:showRemeshProgress()
	ui:setRemeshProgress(0)
	ui:setRemeshStatus("Creating remesh task...")

	task.spawn(function()
		local success, err = pcall(function()
			ui:setRemeshStatus("Submitting remesh task (target: " .. tostring(targetPolycount) .. " tris)...")
			local taskId = api:remesh(state.currentTaskId, targetPolycount)

			ui:setRemeshStatus("Remeshing...")

			local result = api:pollTask("remesh", taskId, function(progress)
				ui:setRemeshProgress(progress)
				ui:setRemeshStatus("Remeshing... " .. tostring(progress) .. "%")
			end)

			state.currentTaskId = taskId
			state.currentTaskType = "remesh"
			state.modelUrls = result.model_urls
			if result.texture_urls then
				state.textureUrls = result.texture_urls
			end
			if result.thumbnail_url then
				state.thumbnailUrl = result.thumbnail_url
				ui:setThumbnail(result.thumbnail_url)
			end

			ui:setRemeshProgress(80)
			ui:setRemeshStatus("Updating preview...")

			local previewOk, previewErr = pcall(importPreview, result.model_urls)
			if previewOk and state.previewMeshPart then
				ui:setRemeshProgress(100)
				ui:setRemeshStatus("Remesh complete!", Color3.fromRGB(76, 175, 80))
			else
				ui:setRemeshProgress(100)
				ui:setRemeshStatus("Remesh complete! (preview failed - check Output)", Color3.fromRGB(255, 152, 0))
				if not previewOk then
					warn("[Meshy AI] Remesh preview error: " .. tostring(previewErr))
				end
			end
		end)

		if not success then
			ui:setRemeshProgress(0)
			ui:setRemeshStatus("Error: " .. tostring(err), Color3.fromRGB(244, 67, 54))
		end

		setBusy(false)
	end)
end

-- Step 4: Publish as permanent Roblox asset
ui.callbacks.onPublish = function()
	if state.busy then return end
	if not state.modelUrls then
		ui:showPubProgress()
		ui:setPubStatus("No model available. Run Generate first.", Color3.fromRGB(244, 67, 54))
		return
	end

	setBusy(true)
	ui:showPubProgress()
	ui:setPubProgress(0)
	ui:setPubStatus("Publishing asset...")

	task.spawn(function()
		local success, err = pcall(function()
			-- If preview didn't work, create the EditableMesh now
			local editableMesh = state.previewEditableMesh
			if not editableMesh then
				ui:setPubProgress(10)
				ui:setPubStatus("Downloading mesh data...")

				local objUrl = state.modelUrls.obj
				if not objUrl or objUrl == "" then
					error("OBJ format not available. Cannot publish.")
				end

				local objText = downloadText(objUrl)
				ui:setPubProgress(20)
				ui:setPubStatus("Parsing mesh geometry...")

				local meshPart
				meshPart, editableMesh = createMeshFromOBJ(objText)
				-- We don't need this meshPart, just the editableMesh
				meshPart:Destroy()
			end

			ui:setPubProgress(30)
			ui:setPubStatus("Creating permanent Roblox asset...")

			local result = AssetService:CreateAssetAsync(
				editableMesh,
				Enum.AssetType.Mesh,
				{ Name = "Meshy AI Asset" }
			)

			-- result may be an AssetId number or a result table
			local assetId = result
			if type(result) == "table" then
				assetId = result.AssetId or result.assetId
			end

			ui:setPubProgress(70)
			ui:setPubStatus("Creating MeshPart from published asset...")

			-- Create a new MeshPart from the published asset
			local meshPart = AssetService:CreateMeshPartAsync(
				Content.fromUri("rbxassetid://" .. tostring(assetId))
			)
			meshPart.Name = "MeshyAsset"
			meshPart.Anchored = true

			-- Position near camera
			local camera = workspace.CurrentCamera
			if camera then
				meshPart.Position = camera.CFrame.Position + camera.CFrame.LookVector * 15
			end

			meshPart.Parent = workspace
			Selection:Set({meshPart})

			-- Remove preview since we now have the published version
			if state.previewMeshPart and state.previewMeshPart.Parent then
				state.previewMeshPart:Destroy()
			end
			state.previewMeshPart = nil

			ui:setPubProgress(100)
			ui:setPubStatus("Published! Asset ID: " .. tostring(assetId), Color3.fromRGB(76, 175, 80))
			print("[Meshy AI] Published asset: rbxassetid://" .. tostring(assetId))
		end)

		if not success then
			ui:setPubProgress(0)
			ui:setPubStatus("Publish failed: " .. tostring(err), Color3.fromRGB(244, 67, 54))

			-- Show download links as fallback
			if state.modelUrls then
				local links = "Download your model manually:"
				if state.modelUrls.glb then links = links .. "\nGLB: " .. state.modelUrls.glb end
				if state.modelUrls.fbx then links = links .. "\nFBX: " .. state.modelUrls.fbx end
				if state.modelUrls.obj then links = links .. "\nOBJ: " .. state.modelUrls.obj end
				ui:setDownloadLinks(links)

				print("[Meshy AI] Model download links:")
				if state.modelUrls.glb then print("  GLB: " .. state.modelUrls.glb) end
				if state.modelUrls.fbx then print("  FBX: " .. state.modelUrls.fbx) end
				if state.modelUrls.obj then print("  OBJ: " .. state.modelUrls.obj) end
			end
		end

		setBusy(false)
	end)
end

------------------------------------------------------------------------
-- Toggle widget visibility
------------------------------------------------------------------------
toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)

print("[Meshy AI] Plugin loaded. Click the toolbar button to open.")
