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
local InsertService = game:GetService("InsertService")
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
-- PNGDecoder (minimal decoder for thumbnail preview in ImageLabel)
-- Supports: 8-bit RGB/RGBA, non-interlaced PNGs
------------------------------------------------------------------------
local PNGDecoder = {}

local function readU32BE(data: string, pos: number): number
	local b1, b2, b3, b4 = string.byte(data, pos, pos + 3)
	return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

-- Bit reader (LSB-first within bytes, as per DEFLATE spec)
local BitReader = {}
BitReader.__index = BitReader

function BitReader.new(data: string, startPos: number?)
	return setmetatable({
		data = data,
		bytePos = startPos or 1,
		bitPos = 0,
	}, BitReader)
end

function BitReader:readBit(): number
	if self.bytePos > #self.data then error("Unexpected end of compressed data") end
	local byte = string.byte(self.data, self.bytePos)
	local b = bit32.band(bit32.rshift(byte, self.bitPos), 1)
	self.bitPos += 1
	if self.bitPos >= 8 then
		self.bitPos = 0
		self.bytePos += 1
	end
	return b
end

function BitReader:readBits(n: number): number
	local result = 0
	for i = 0, n - 1 do
		result = bit32.bor(result, bit32.lshift(self:readBit(), i))
	end
	return result
end

function BitReader:alignToByte()
	if self.bitPos > 0 then
		self.bitPos = 0
		self.bytePos += 1
	end
end

-- Build canonical Huffman tree from code lengths
-- Returns a binary tree: { [0]=left, [1]=right } or { symbol=n }
local function buildHuffTree(codeLengths: {number}): any
	local maxLen = 0
	for _, len in ipairs(codeLengths) do
		if len > maxLen then maxLen = len end
	end
	if maxLen == 0 then return { symbol = 0 } end

	local blCount = {}
	for i = 0, maxLen do blCount[i] = 0 end
	for _, len in ipairs(codeLengths) do
		if len > 0 then blCount[len] += 1 end
	end

	local nextCode = {}
	local code = 0
	for bits = 1, maxLen do
		code = (code + (blCount[bits - 1] or 0)) * 2
		nextCode[bits] = code
	end

	local root = {}
	for symbol = 1, #codeLengths do
		local len = codeLengths[symbol]
		if len > 0 then
			local c = nextCode[len]
			nextCode[len] += 1
			local node = root
			for i = len - 1, 1, -1 do
				local bit = bit32.band(bit32.rshift(c, i), 1)
				if not node[bit] then node[bit] = {} end
				node = node[bit]
			end
			node[bit32.band(c, 1)] = { symbol = symbol - 1 }
		end
	end
	return root
end

local function huffDecode(reader: any, tree: any): number
	local node = tree
	if node.symbol then return node.symbol end
	while true do
		local bit = reader:readBit()
		node = node[bit]
		if not node then error("Invalid Huffman code") end
		if node.symbol then return node.symbol end
	end
end

-- Fixed Huffman trees for DEFLATE block type 1
local FIXED_LIT_TREE, FIXED_DIST_TREE
do
	local ll = {}
	for i = 1, 144 do ll[i] = 8 end
	for i = 145, 256 do ll[i] = 9 end
	for i = 257, 280 do ll[i] = 7 end
	for i = 281, 288 do ll[i] = 8 end
	FIXED_LIT_TREE = buildHuffTree(ll)

	local dd = {}
	for i = 1, 32 do dd[i] = 5 end
	FIXED_DIST_TREE = buildHuffTree(dd)
end

-- Length and distance base/extra tables
local LEN_BASE = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
local LEN_EXTRA = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
local DST_BASE = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
local DST_EXTRA = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
local CL_ORDER = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}

-- DEFLATE inflate
local function inflate(reader: any): string
	local out = {}
	local final = false

	while not final do
		final = reader:readBits(1) == 1
		local btype = reader:readBits(2)

		if btype == 0 then
			-- Stored block
			reader:alignToByte()
			local len = reader:readBits(16)
			reader:readBits(16) -- nlen (complement, skip)
			for _ = 1, len do
				table.insert(out, string.char(reader:readBits(8)))
			end
		elseif btype == 1 or btype == 2 then
			local litTree, dstTree

			if btype == 1 then
				litTree = FIXED_LIT_TREE
				dstTree = FIXED_DIST_TREE
			else
				-- Dynamic Huffman
				local hlit = reader:readBits(5) + 257
				local hdist = reader:readBits(5) + 1
				local hclen = reader:readBits(4) + 4

				local clLens = {}
				for i = 1, 19 do clLens[i] = 0 end
				for i = 1, hclen do
					clLens[CL_ORDER[i] + 1] = reader:readBits(3)
				end

				local clTree = buildHuffTree(clLens)

				local allLens = {}
				local total = hlit + hdist
				while #allLens < total do
					local sym = huffDecode(reader, clTree)
					if sym < 16 then
						table.insert(allLens, sym)
					elseif sym == 16 then
						local rep = reader:readBits(2) + 3
						local prev = allLens[#allLens] or 0
						for _ = 1, rep do table.insert(allLens, prev) end
					elseif sym == 17 then
						for _ = 1, reader:readBits(3) + 3 do table.insert(allLens, 0) end
					elseif sym == 18 then
						for _ = 1, reader:readBits(7) + 11 do table.insert(allLens, 0) end
					end
				end

				local litLens = {}
				for i = 1, hlit do litLens[i] = allLens[i] end
				local dstLens = {}
				for i = 1, hdist do dstLens[i] = allLens[hlit + i] end

				litTree = buildHuffTree(litLens)
				dstTree = buildHuffTree(dstLens)
			end

			-- Decode literals/lengths
			while true do
				local sym = huffDecode(reader, litTree)
				if sym < 256 then
					table.insert(out, string.char(sym))
				elseif sym == 256 then
					break
				else
					local li = sym - 257 + 1
					local length = LEN_BASE[li] + reader:readBits(LEN_EXTRA[li])
					local di = huffDecode(reader, dstTree) + 1
					local distance = DST_BASE[di] + reader:readBits(DST_EXTRA[di])
					local sp = #out - distance + 1
					for i = 0, length - 1 do
						table.insert(out, out[sp + i])
					end
				end
			end
		else
			error("Invalid DEFLATE block type")
		end
	end

	return table.concat(out)
end

-- Decode a PNG file (binary string) into width, height, RGBA pixel buffer
function PNGDecoder.decode(pngData: string): (number, number, buffer?)
	-- Validate PNG signature
	if #pngData < 8 or string.sub(pngData, 1, 8) ~= "\137PNG\r\n\26\n" then
		return 0, 0, nil
	end

	local pos = 9
	local width, height, bitDepth, colorType = 0, 0, 0, 0
	local idatParts = {}

	while pos <= #pngData - 12 do
		local length = readU32BE(pngData, pos)
		local ctype = string.sub(pngData, pos + 4, pos + 7)
		local dataStart = pos + 8

		if ctype == "IHDR" then
			width = readU32BE(pngData, dataStart)
			height = readU32BE(pngData, dataStart + 4)
			bitDepth = string.byte(pngData, dataStart + 8)
			colorType = string.byte(pngData, dataStart + 9)
		elseif ctype == "IDAT" then
			table.insert(idatParts, string.sub(pngData, dataStart, dataStart + length - 1))
		elseif ctype == "IEND" then
			break
		end

		pos = dataStart + length + 4 -- skip CRC
	end

	if width == 0 or height == 0 then return 0, 0, nil end

	-- Limit to reasonable thumbnail sizes
	if width > 1024 or height > 1024 then
		warn("[Meshy AI] PNG too large for thumbnail: " .. width .. "x" .. height)
		return width, height, nil
	end

	-- Only support 8-bit RGB (type 2) and RGBA (type 6)
	local channels
	if colorType == 2 then channels = 3
	elseif colorType == 6 then channels = 4
	else
		warn("[Meshy AI] Unsupported PNG color type: " .. tostring(colorType))
		return width, height, nil
	end

	if bitDepth ~= 8 then
		warn("[Meshy AI] Unsupported PNG bit depth: " .. tostring(bitDepth))
		return width, height, nil
	end

	-- Decompress IDAT data (skip 2-byte zlib header)
	local compressed = table.concat(idatParts)
	local startByte = 3 -- skip CMF + FLG
	if bit32.band(string.byte(compressed, 2), 0x20) ~= 0 then
		startByte = 7 -- skip FDICT (4 extra bytes)
	end

	local reader = BitReader.new(compressed, startByte)
	local decompOk, rawData = pcall(inflate, reader)
	if not decompOk then
		warn("[Meshy AI] PNG DEFLATE error: " .. tostring(rawData))
		return width, height, nil
	end

	-- Unfilter scanlines
	local bpp = channels -- bytes per pixel
	local stride = width * bpp
	local pixelBuf = buffer.create(width * height * 4)

	local prevRow = {}
	for i = 1, stride do prevRow[i] = 0 end

	local srcPos = 1
	for y = 0, height - 1 do
		if srcPos > #rawData then break end
		local filterType = string.byte(rawData, srcPos)
		srcPos += 1

		local curRow = {}
		for x = 1, stride do
			if srcPos > #rawData then break end
			local raw = string.byte(rawData, srcPos)
			srcPos += 1

			local a = x > bpp and curRow[x - bpp] or 0
			local b = prevRow[x]
			local c = x > bpp and prevRow[x - bpp] or 0

			if filterType == 0 then
				curRow[x] = raw
			elseif filterType == 1 then
				curRow[x] = (raw + a) % 256
			elseif filterType == 2 then
				curRow[x] = (raw + b) % 256
			elseif filterType == 3 then
				curRow[x] = (raw + math.floor((a + b) / 2)) % 256
			elseif filterType == 4 then
				local p = a + b - c
				local pa = math.abs(p - a)
				local pb = math.abs(p - b)
				local pc = math.abs(p - c)
				if pa <= pb and pa <= pc then curRow[x] = (raw + a) % 256
				elseif pb <= pc then curRow[x] = (raw + b) % 256
				else curRow[x] = (raw + c) % 256 end
			else
				curRow[x] = raw
			end
		end

		-- Write RGBA to output buffer
		for x = 0, width - 1 do
			local bufPos = (y * width + x) * 4
			local si = x * bpp + 1
			buffer.writeu8(pixelBuf, bufPos, curRow[si] or 0)
			buffer.writeu8(pixelBuf, bufPos + 1, curRow[si + 1] or 0)
			buffer.writeu8(pixelBuf, bufPos + 2, curRow[si + 2] or 0)
			if channels == 4 then
				buffer.writeu8(pixelBuf, bufPos + 3, curRow[si + 3] or 0)
			else
				buffer.writeu8(pixelBuf, bufPos + 3, 255)
			end
		end

		prevRow = curRow
	end

	return width, height, pixelBuf
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
		target_formats = {"obj", "glb", "fbx"},
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

	-- Roblox Open Cloud API Key
	createLabel({
		Name = "RobloxApiKeyLabel",
		Text = "Roblox Open Cloud API Key",
		TextSize = 12,
		TextColor3 = Theme.textMuted,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})

	local robloxKeyRow = Instance.new("Frame")
	robloxKeyRow.Name = "RobloxApiKeyRow"
	robloxKeyRow.Size = UDim2.new(1, 0, 0, 32)
	robloxKeyRow.BackgroundTransparency = 1
	robloxKeyRow.LayoutOrder = nextOrder()
	robloxKeyRow.Parent = scroll

	local robloxKeyFrame = Instance.new("Frame")
	robloxKeyFrame.Name = "RobloxApiKeyInputFrame"
	robloxKeyFrame.Size = UDim2.new(1, -70, 1, 0)
	robloxKeyFrame.BackgroundColor3 = Theme.input
	robloxKeyFrame.Parent = robloxKeyRow
	addCorner(robloxKeyFrame)
	addBorder(robloxKeyFrame, Theme.inputBorder)

	local robloxKeyInput = Instance.new("TextBox")
	robloxKeyInput.Name = "RobloxApiKeyInput"
	robloxKeyInput.Size = UDim2.new(1, -16, 1, 0)
	robloxKeyInput.Position = UDim2.new(0, 8, 0, 0)
	robloxKeyInput.BackgroundTransparency = 1
	robloxKeyInput.Font = FONT
	robloxKeyInput.TextColor3 = Theme.text
	robloxKeyInput.PlaceholderColor3 = Theme.textMuted
	robloxKeyInput.TextSize = 13
	robloxKeyInput.PlaceholderText = "Enter Roblox API key..."
	robloxKeyInput.Text = ""
	robloxKeyInput.TextXAlignment = Enum.TextXAlignment.Left
	robloxKeyInput.ClearTextOnFocus = false
	robloxKeyInput.Parent = robloxKeyFrame
	self._robloxApiKeyInput = robloxKeyInput

	local saveRobloxKeyBtn = createButton({
		Name = "SaveRobloxKey",
		Text = "Save",
		Size = UDim2.new(0, 60, 1, 0),
		Color = Theme.primary,
		Parent = robloxKeyRow,
	})
	saveRobloxKeyBtn.Position = UDim2.new(1, -60, 0, 0)
	saveRobloxKeyBtn.Activated:Connect(function()
		if self.callbacks.onRobloxApiKeySaved then
			self.callbacks.onRobloxApiKeySaved(robloxKeyInput.Text)
		end
	end)

	-- Creator User ID
	createLabel({
		Name = "CreatorIdLabel",
		Text = "Creator User ID (from profile URL)",
		TextSize = 12,
		TextColor3 = Theme.textMuted,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = nextOrder(),
		Parent = scroll,
	})

	local creatorIdRow = Instance.new("Frame")
	creatorIdRow.Name = "CreatorIdRow"
	creatorIdRow.Size = UDim2.new(1, 0, 0, 32)
	creatorIdRow.BackgroundTransparency = 1
	creatorIdRow.LayoutOrder = nextOrder()
	creatorIdRow.Parent = scroll

	local creatorIdFrame = Instance.new("Frame")
	creatorIdFrame.Name = "CreatorIdInputFrame"
	creatorIdFrame.Size = UDim2.new(1, -70, 1, 0)
	creatorIdFrame.BackgroundColor3 = Theme.input
	creatorIdFrame.Parent = creatorIdRow
	addCorner(creatorIdFrame)
	addBorder(creatorIdFrame, Theme.inputBorder)

	local creatorIdInput = Instance.new("TextBox")
	creatorIdInput.Name = "CreatorIdInput"
	creatorIdInput.Size = UDim2.new(1, -16, 1, 0)
	creatorIdInput.Position = UDim2.new(0, 8, 0, 0)
	creatorIdInput.BackgroundTransparency = 1
	creatorIdInput.Font = FONT
	creatorIdInput.TextColor3 = Theme.text
	creatorIdInput.PlaceholderColor3 = Theme.textMuted
	creatorIdInput.TextSize = 13
	creatorIdInput.PlaceholderText = "Your Roblox User ID..."
	creatorIdInput.Text = ""
	creatorIdInput.TextXAlignment = Enum.TextXAlignment.Left
	creatorIdInput.ClearTextOnFocus = false
	creatorIdInput.Parent = creatorIdFrame
	self._creatorIdInput = creatorIdInput

	local saveCreatorIdBtn = createButton({
		Name = "SaveCreatorId",
		Text = "Save",
		Size = UDim2.new(0, 60, 1, 0),
		Color = Theme.primary,
		Parent = creatorIdRow,
	})
	saveCreatorIdBtn.Position = UDim2.new(1, -60, 0, 0)
	saveCreatorIdBtn.Activated:Connect(function()
		if self.callbacks.onCreatorIdSaved then
			self.callbacks.onCreatorIdSaved(creatorIdInput.Text)
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

	-- Thumbnail URL (copyable, since ImageLabel can't load external URLs)
	local thumbUrlBox = Instance.new("TextBox")
	thumbUrlBox.Name = "ThumbnailUrl"
	thumbUrlBox.Size = UDim2.new(1, 0, 0, 28)
	thumbUrlBox.BackgroundColor3 = Theme.input
	thumbUrlBox.Font = FONT
	thumbUrlBox.TextColor3 = Theme.primary
	thumbUrlBox.TextSize = 11
	thumbUrlBox.Text = ""
	thumbUrlBox.PlaceholderText = ""
	thumbUrlBox.TextXAlignment = Enum.TextXAlignment.Left
	thumbUrlBox.TextWrapped = false
	thumbUrlBox.ClearTextOnFocus = false
	thumbUrlBox.TextEditable = false
	thumbUrlBox.Visible = false
	thumbUrlBox.LayoutOrder = nextOrder()
	thumbUrlBox.Parent = scroll
	thumbUrlBox.ClipsDescendants = true
	addCorner(thumbUrlBox)
	addPadding(thumbUrlBox, 4, 4, 8, 8)
	self._thumbUrlBox = thumbUrlBox

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
function UI:setRobloxApiKey(key: string) self._robloxApiKeyInput.Text = key end
function UI:setCreatorId(id: string) self._creatorIdInput.Text = id end
function UI:enableStep(step: number) self:_setStepEnabled(step, true) end
function UI:disableStep(step: number) self:_setStepEnabled(step, false) end
function UI:enablePublish() self:_setPublishEnabled(true) end
function UI:disablePublish() self:_setPublishEnabled(false) end

function UI:setThumbnail(url: string)
	if url and url ~= "" then
		self._thumbUrlBox.Text = "Preview: " .. url
		self._thumbUrlBox.Visible = true
		print("[Meshy AI] Thumbnail URL: " .. url)

		-- Download and decode the thumbnail image in background
		task.spawn(function()
			local editableImage = loadThumbnailImage(url)
			if editableImage then
				-- Use ImageContent with Content.fromObject for EditableImage display
				local contentOk, contentErr = pcall(function()
					self._thumbnail.ImageContent = Content.fromObject(editableImage)
				end)
				if contentOk then
					self._thumbnail.Visible = true
					self._editableImageRef = editableImage -- prevent garbage collection
					print("[Meshy AI] Thumbnail displayed in preview!")
				else
					warn("[Meshy AI] Content.fromObject failed: " .. tostring(contentErr))
					self._thumbnail.Visible = false
				end
			else
				self._thumbnail.Visible = false
				print("[Meshy AI] Thumbnail URL shown (image decode failed)")
			end
		end)
	else
		self._thumbnail.Visible = false
		self._thumbUrlBox.Visible = false
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
-- Persistence: load/save API keys
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

local function loadRobloxSettings()
	local robloxKey = plugin:GetSetting("RobloxApiKey")
	if robloxKey and robloxKey ~= "" then
		ui:setRobloxApiKey(robloxKey)
	end

	local creatorId = plugin:GetSetting("RobloxCreatorId")
	if creatorId and creatorId ~= "" then
		ui:setCreatorId(creatorId)
	elseif game.CreatorId > 0 and game.CreatorType == Enum.CreatorType.User then
		-- Auto-populate from the current place's creator
		ui:setCreatorId(tostring(game.CreatorId))
	end
end

local function saveRobloxApiKey(key)
	plugin:SetSetting("RobloxApiKey", key)
end

local function saveCreatorId(id)
	plugin:SetSetting("RobloxCreatorId", id)
end

loadApiKey()
loadRobloxSettings()

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

-- Download a thumbnail URL and return an EditableImage (or nil on failure)
local function loadThumbnailImage(url: string): any?
	local ok, response = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)

	if not ok or not response or response.StatusCode ~= 200 then
		warn("[Meshy AI] Failed to download thumbnail: " .. tostring(ok and response and response.StatusCode or response))
		return nil
	end

	local pngData = response.Body

	-- Check if it's a PNG (starts with PNG signature)
	if #pngData < 8 or string.byte(pngData, 1) ~= 137 then
		warn("[Meshy AI] Thumbnail is not PNG format, cannot decode")
		return nil
	end

	local decOk, w, h, pixelBuf = pcall(PNGDecoder.decode, pngData)
	if not decOk then
		warn("[Meshy AI] PNG decode error: " .. tostring(w))
		return nil
	end

	if not pixelBuf or w == 0 or h == 0 then
		warn("[Meshy AI] PNG decode returned no pixel data (" .. tostring(w) .. "x" .. tostring(h) .. ")")
		return nil
	end

	local imgOk, editableImage = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	end)

	if not imgOk or not editableImage then
		warn("[Meshy AI] Failed to create EditableImage: " .. tostring(editableImage))
		return nil
	end

	local writeOk, writeErr = pcall(function()
		editableImage:WritePixelsBuffer(Vector2.new(0, 0), Vector2.new(w, h), pixelBuf)
	end)

	if not writeOk then
		warn("[Meshy AI] WritePixelsBuffer failed: " .. tostring(writeErr))
		return nil
	end

	print("[Meshy AI] Thumbnail decoded: " .. w .. "x" .. h)
	return editableImage
end

------------------------------------------------------------------------
-- Mesh Import: OBJ -> EditableMesh (separate from MeshPart creation)
------------------------------------------------------------------------

-- Create an EditableMesh from OBJ text. Returns editableMesh and triCount.
-- Does NOT create a MeshPart (that's a separate step that may fail).
local function createEditableMeshFromOBJ(objText: string)
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

	-- Add all normals (pcall each in case of issues)
	local normalIds = {}
	for i, normal in ipairs(meshData.normals) do
		local ok, nid = pcall(function()
			return editableMesh:AddNormal(normal)
		end)
		if ok then normalIds[i] = nid end
	end

	-- Add all UVs (flip V for Roblox: OBJ is bottom-left origin, Roblox is top-left)
	local uvIds = {}
	for i, uv in ipairs(meshData.uvs) do
		local ok, uid = pcall(function()
			return editableMesh:AddUV(Vector2.new(uv.X, 1 - uv.Y))
		end)
		if ok then uvIds[i] = uid end
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

	print("[Meshy AI] EditableMesh created: " .. #meshData.positions .. " verts, " .. triCount .. " tris")
	return editableMesh, triCount
end

-- Import preview into workspace. Stores editableMesh in state for publish
-- even if the visual MeshPart creation fails.
local function importPreview(modelUrls)
	-- Log available formats
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
		warn("[Meshy AI] OBJ format not available in model_urls, cannot import")
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

	-- Download and parse OBJ
	print("[Meshy AI] Downloading OBJ...")
	local objText = downloadText(objUrl)
	print("[Meshy AI] OBJ downloaded, " .. tostring(#objText) .. " bytes")

	local editableMesh, triCount = createEditableMeshFromOBJ(objText)

	-- Always store the EditableMesh (needed for publish even if MeshPart fails)
	state.previewEditableMesh = editableMesh

	-- Try to create a visual MeshPart (may fail — that's OK)
	local meshPartOk, meshPartResult = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(editableMesh))
	end)

	if meshPartOk and meshPartResult then
		meshPartResult.Name = "MeshyAsset_Preview"
		meshPartResult.Anchored = true

		local camera = workspace.CurrentCamera
		if camera then
			meshPartResult.Position = camera.CFrame.Position + camera.CFrame.LookVector * 15
		end

		meshPartResult.Parent = workspace
		Selection:Set({meshPartResult})
		state.previewMeshPart = meshPartResult
		print("[Meshy AI] 3D preview added to workspace (" .. triCount .. " tris)")
	else
		warn("[Meshy AI] 3D preview failed (CreateMeshPartAsync): " .. tostring(meshPartResult))
		warn("[Meshy AI] EditableMesh is saved — Publish should still work")
	end

	return triCount
end

------------------------------------------------------------------------
-- Open Cloud: Upload FBX to Roblox
------------------------------------------------------------------------

local function uploadToRobloxCloud(fbxData: string, displayName: string, robloxApiKey: string, creatorId: string): any
	local boundary = "----RobloxBoundary" .. HttpService:GenerateGUID(false):gsub("-", "")

	local requestJson = HttpService:JSONEncode({
		assetType = "Model",
		displayName = displayName,
		description = "Generated by Meshy AI Plugin",
		creationContext = {
			creator = {
				userId = creatorId,
			},
		},
	})

	local body = "--" .. boundary .. "\r\n"
		.. "Content-Disposition: form-data; name=\"request\"\r\n"
		.. "Content-Type: application/json\r\n"
		.. "\r\n"
		.. requestJson .. "\r\n"
		.. "--" .. boundary .. "\r\n"
		.. "Content-Disposition: form-data; name=\"fileContent\"; filename=\"model.fbx\"\r\n"
		.. "Content-Type: model/fbx\r\n"
		.. "\r\n"
		.. fbxData .. "\r\n"
		.. "--" .. boundary .. "--\r\n"

	local response = HttpService:RequestAsync({
		Url = "https://apis.roblox.com/assets/v1/assets",
		Method = "POST",
		Headers = {
			["x-api-key"] = robloxApiKey,
			["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
		},
		Body = body,
	})

	if response.StatusCode < 200 or response.StatusCode >= 300 then
		local errorMsg = "Open Cloud upload failed (HTTP " .. response.StatusCode .. ")"
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

local function pollRobloxOperation(operationPath: string, robloxApiKey: string): any
	local MAX_POLLS = 60
	local POLL_INTERVAL = 3

	-- Extract operation ID from path like "operations/xxx"
	local operationId = operationPath:match("operations/(.+)")
	if not operationId then
		error("Invalid operation path: " .. tostring(operationPath))
	end

	local url = "https://apis.roblox.com/assets/v1/operations/" .. operationId

	for _ = 1, MAX_POLLS do
		taskWait(POLL_INTERVAL)

		local ok, response = pcall(function()
			return HttpService:RequestAsync({
				Url = url,
				Method = "GET",
				Headers = {
					["x-api-key"] = robloxApiKey,
				},
			})
		end)

		if ok and response.StatusCode == 200 then
			local result = HttpService:JSONDecode(response.Body)
			if result.done then
				if result.response then
					return result.response
				end
				return result
			end
		elseif ok and response.StatusCode >= 400 then
			local errorMsg = "Operation check failed (HTTP " .. response.StatusCode .. ")"
			pcall(function()
				local decoded = HttpService:JSONDecode(response.Body)
				if decoded.message then
					errorMsg = errorMsg .. ": " .. decoded.message
				end
			end)
			error(errorMsg)
		end
	end

	error("Operation timed out after " .. tostring(MAX_POLLS * POLL_INTERVAL) .. " seconds")
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

ui.callbacks.onRobloxApiKeySaved = function(key)
	if key == "" then
		ui:showPubProgress()
		ui:setPubStatus("Please enter a valid Roblox API key.", Color3.fromRGB(244, 67, 54))
		return
	end
	saveRobloxApiKey(key)
	ui:showPubProgress()
	ui:setPubStatus("Roblox API key saved!", Color3.fromRGB(76, 175, 80))
	task.delay(2, function()
		ui:resetPubProgress()
	end)
end

ui.callbacks.onCreatorIdSaved = function(id)
	if id == "" then
		ui:showPubProgress()
		ui:setPubStatus("Please enter your Creator User ID.", Color3.fromRGB(244, 67, 54))
		return
	end
	saveCreatorId(id)
	ui:showPubProgress()
	ui:setPubStatus("Creator ID saved!", Color3.fromRGB(76, 175, 80))
	task.delay(2, function()
		ui:resetPubProgress()
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

			-- Auto-import preview mesh (EditableMesh is stored even if 3D preview fails)
			local previewOk, previewErr = pcall(importPreview, result.model_urls)
			if previewOk and state.previewEditableMesh then
				if state.previewMeshPart then
					ui:setGenProgress(100)
					ui:setGenStatus("Mesh generated and previewed!", Color3.fromRGB(76, 175, 80))
				else
					ui:setGenProgress(100)
					ui:setGenStatus("Mesh generated! (see preview URL above)", Color3.fromRGB(76, 175, 80))
				end
			else
				ui:setGenProgress(100)
				ui:setGenStatus("Mesh generated! (preview failed - check Output)", Color3.fromRGB(255, 152, 0))
				if not previewOk then
					warn("[Meshy AI] Preview import error: " .. tostring(previewErr))
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
			if previewOk and state.previewEditableMesh then
				ui:setTexProgress(100)
				ui:setTexStatus("Texture applied! (see preview URL)", Color3.fromRGB(76, 175, 80))
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
			if previewOk and state.previewEditableMesh then
				if state.previewMeshPart then
					ui:setRemeshProgress(100)
					ui:setRemeshStatus("Remesh complete!", Color3.fromRGB(76, 175, 80))
				else
					ui:setRemeshProgress(100)
					ui:setRemeshStatus("Remesh complete! (see preview URL)", Color3.fromRGB(76, 175, 80))
				end
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

-- Step 4: Publish mesh + texture as permanent Roblox assets
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
	ui:setPubStatus("Publishing assets...")

	task.spawn(function()
		local success, err = pcall(function()
			------------------------------------------------------------
			-- A. Get or create the EditableMesh
			------------------------------------------------------------
			local editableMesh = state.previewEditableMesh
			if not editableMesh then
				ui:setPubProgress(5)
				ui:setPubStatus("Downloading mesh data...")

				local objUrl = state.modelUrls.obj
				if not objUrl or objUrl == "" then
					error("OBJ format not available. Cannot publish.")
				end

				local objText = downloadText(objUrl)
				ui:setPubProgress(10)
				ui:setPubStatus("Parsing mesh geometry...")

				editableMesh = createEditableMeshFromOBJ(objText)
			end

			------------------------------------------------------------
			-- B. Download and decode texture into EditableImage
			------------------------------------------------------------
			local editableImage = nil
			local textureUrl = nil

			if state.textureUrls then
				-- Log all available texture keys for debugging
				local texKeys = {}
				for k, v in pairs(state.textureUrls) do
					table.insert(texKeys, k .. "=" .. tostring(v):sub(1, 60))
				end
				print("[Meshy AI] Available texture URLs: " .. table.concat(texKeys, " | "))

				-- Try known key names for the diffuse/base color texture
				for _, key in ipairs({"base_color", "basecolor", "baseColor", "diffuse", "albedo"}) do
					if state.textureUrls[key] and state.textureUrls[key] ~= "" then
						textureUrl = state.textureUrls[key]
						print("[Meshy AI] Using texture key: " .. key)
						break
					end
				end

				-- Fallback: use the first available URL
				if not textureUrl then
					for k, v in pairs(state.textureUrls) do
						if type(v) == "string" and v ~= "" and v:match("^https?://") then
							textureUrl = v
							print("[Meshy AI] Using fallback texture key: " .. k)
							break
						end
					end
				end
			else
				print("[Meshy AI] state.textureUrls is nil")
			end

			if textureUrl and textureUrl ~= "" then
				ui:setPubProgress(15)
				ui:setPubStatus("Downloading texture...")
				print("[Meshy AI] Downloading texture from: " .. textureUrl:sub(1, 80))

				local texOk, texResult = pcall(function()
					return loadThumbnailImage(textureUrl) -- reuse PNG download+decode
				end)

				if texOk and texResult then
					editableImage = texResult
					print("[Meshy AI] Texture loaded for publishing")
				else
					warn("[Meshy AI] Texture download/decode failed: " .. tostring(texResult))
					warn("[Meshy AI] Will publish mesh without texture")
				end
			else
				print("[Meshy AI] No texture URL found — publishing mesh only")
			end

			------------------------------------------------------------
			-- C. Publish EditableMesh as permanent Mesh asset
			------------------------------------------------------------
			ui:setPubProgress(30)
			ui:setPubStatus("Publishing mesh to Roblox...")

			-- CreateAssetAsync returns: (Enum.CreateAssetResult, assetId: number)
			local meshReturnA, meshReturnB = AssetService:CreateAssetAsync(
				editableMesh,
				Enum.AssetType.Mesh,
				{ Name = "Meshy AI Mesh" }
			)

			print("[Meshy AI] Mesh CreateAssetAsync returned: " .. tostring(meshReturnA) .. ", " .. tostring(meshReturnB))

			-- Handle both possible return patterns:
			-- Pattern 1: (Enum.CreateAssetResult, assetId)
			-- Pattern 2: (assetId) or object with assetId
			local meshAssetId = nil
			if type(meshReturnB) == "number" and meshReturnB > 0 then
				meshAssetId = meshReturnB
			elseif type(meshReturnA) == "number" and meshReturnA > 0 then
				meshAssetId = meshReturnA
			end

			if not meshAssetId then
				error("Mesh publish failed — returned: " .. tostring(meshReturnA) .. ", " .. tostring(meshReturnB))
			end

			print("[Meshy AI] Mesh published — rbxassetid://" .. tostring(meshAssetId))

			------------------------------------------------------------
			-- D. Publish EditableImage as permanent Decal asset
			------------------------------------------------------------
			local textureAssetId = nil

			if editableImage then
				ui:setPubProgress(50)
				ui:setPubStatus("Publishing texture to Roblox...")

				local texPubOk, texRetA, texRetB = pcall(function()
					return AssetService:CreateAssetAsync(
						editableImage,
						Enum.AssetType.Decal,
						{ Name = "Meshy AI Texture" }
					)
				end)

				print("[Meshy AI] Texture CreateAssetAsync returned: ok=" .. tostring(texPubOk) .. ", " .. tostring(texRetA) .. ", " .. tostring(texRetB))

				if texPubOk then
					-- Same flexible extraction as mesh
					if type(texRetB) == "number" and texRetB > 0 then
						textureAssetId = texRetB
					elseif type(texRetA) == "number" and texRetA > 0 then
						textureAssetId = texRetA
					end

					if textureAssetId then
						print("[Meshy AI] Texture published — rbxassetid://" .. tostring(textureAssetId))
					else
						warn("[Meshy AI] Texture publish returned no asset ID: " .. tostring(texRetA) .. ", " .. tostring(texRetB))
					end
				else
					warn("[Meshy AI] Texture publish error: " .. tostring(texRetA))
					warn("[Meshy AI] Continuing with mesh only")
				end
			end

			------------------------------------------------------------
			-- E. Create new MeshPart from permanent mesh asset
			------------------------------------------------------------
			ui:setPubProgress(70)
			ui:setPubStatus("Creating MeshPart from published asset...")

			local permanentMeshUri = Content.fromUri("rbxassetid://" .. tostring(meshAssetId))
			local meshPart = AssetService:CreateMeshPartAsync(permanentMeshUri)

			meshPart.Name = "MeshyAsset"
			meshPart.Anchored = true

			-- Apply texture if we published one
			if textureAssetId then
				meshPart.TextureID = "rbxassetid://" .. tostring(textureAssetId)
			end

			-- Position in front of camera
			local camera = workspace.CurrentCamera
			if camera then
				meshPart.Position = camera.CFrame.Position + camera.CFrame.LookVector * 15
			end

			meshPart.Parent = workspace
			Selection:Set({meshPart})

			------------------------------------------------------------
			-- F. Clean up preview
			------------------------------------------------------------
			if state.previewMeshPart and state.previewMeshPart.Parent then
				state.previewMeshPart:Destroy()
			end
			state.previewMeshPart = nil

			ui:setPubProgress(100)
			local statusMsg = "Published! Mesh ID: " .. tostring(meshAssetId)
			if textureAssetId then
				statusMsg = statusMsg .. " | Texture ID: " .. tostring(textureAssetId)
			end
			ui:setPubStatus(statusMsg, Color3.fromRGB(76, 175, 80))

			print("[Meshy AI] Publish complete!")
			print("[Meshy AI]   Mesh: rbxassetid://" .. tostring(meshAssetId))
			if textureAssetId then
				print("[Meshy AI]   Texture: rbxassetid://" .. tostring(textureAssetId))
			end
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
