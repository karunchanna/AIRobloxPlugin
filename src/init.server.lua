--[[
	Meshy AI Asset Generator - Roblox Studio Plugin

	A 3-step workflow for generating 3D assets using Meshy's AI API:
	  1. Generate Mesh (text prompt or image)
	  2. Texture (text prompt or reference image)
	  3. Remesh (reduce triangle count for Roblox's 20k limit)
	  4. Publish to Workspace

	Requires a Meshy API key from https://www.meshy.ai/api
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")

-- Load modules
local MeshyAPI = require(script.MeshyAPI)
local OBJParser = require(script.OBJParser)
local UIModule = require(script.UI)

----------------------------------------------------------------------
-- Plugin setup
----------------------------------------------------------------------
local toolbar = plugin:CreateToolbar("Meshy AI")
local toggleButton = toolbar:CreateButton(
	"Asset Generator",
	"Generate 3D assets with Meshy AI",
	"rbxassetid://14978048121" -- cube icon
)

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false,  -- initially disabled
	false,  -- override previous enabled state
	320,    -- default width
	700,    -- default height
	280,    -- min width
	400     -- min height
)

local widget = plugin:CreateDockWidgetPluginGui("MeshyAIAssetGenerator", widgetInfo)
widget.Title = "Meshy AI"

----------------------------------------------------------------------
-- Initialize modules
----------------------------------------------------------------------
local api = MeshyAPI.new()
local ui = UIModule.new(widget)

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local state = {
	-- Current task tracking
	currentTaskId = nil,         -- task ID of the latest completed step
	currentTaskType = nil,       -- "text-to-3d", "image-to-3d", "text-to-texture", "remesh"
	sourceType = nil,            -- "text-to-3d" or "image-to-3d" (how the mesh was originally generated)
	modelUrls = nil,             -- model_urls from latest task
	textureUrls = nil,           -- texture_urls from latest task
	thumbnailUrl = nil,          -- thumbnail from latest task
	-- Flags
	busy = false,                -- true while a task is running
}

----------------------------------------------------------------------
-- Persistence: load/save API key
----------------------------------------------------------------------
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

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function setBusy(busy)
	state.busy = busy
	ui:setButtonEnabled("generate", not busy)
	ui:setButtonEnabled("texture", not busy)
	ui:setButtonEnabled("remesh", not busy)
	ui:setButtonEnabled("publish", not busy)
end

-- Download text content from a URL
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

----------------------------------------------------------------------
-- Mesh Import: OBJ -> EditableMesh -> MeshPart
----------------------------------------------------------------------
local function createMeshPartFromOBJ(objText: string): MeshPart
	-- Parse OBJ data
	local meshData = OBJParser.parse(objText)

	if #meshData.positions == 0 or #meshData.faces == 0 then
		error("OBJ file contains no geometry")
	end

	-- Create EditableMesh
	local editableMesh = Instance.new("EditableMesh")

	-- Build unique vertices: each unique (posIdx, uvIdx, normalIdx) combo = one vertex
	local vertexMap = {} -- "posIdx/uvIdx/normalIdx" -> editableMesh vertex ID
	local function getOrCreateVertex(posIdx, uvIdx, normalIdx)
		local key = tostring(posIdx) .. "/" .. tostring(uvIdx or "") .. "/" .. tostring(normalIdx or "")
		if vertexMap[key] then
			return vertexMap[key]
		end

		local pos = meshData.positions[posIdx]
		if not pos then
			error("Invalid vertex index: " .. tostring(posIdx))
		end

		local vid = editableMesh:AddVertex(pos)

		if normalIdx and meshData.normals[normalIdx] then
			editableMesh:SetVertexNormal(vid, meshData.normals[normalIdx])
		end

		if uvIdx and meshData.uvs[uvIdx] then
			local uv = meshData.uvs[uvIdx]
			-- OBJ UV v-coordinate may need flipping (OBJ: bottom-left origin, Roblox: top-left)
			editableMesh:SetUV(vid, Vector2.new(uv.X, 1 - uv.Y))
		end

		vertexMap[key] = vid
		return vid
	end

	-- Add triangles
	local triCount = 0
	for _, face in ipairs(meshData.faces) do
		local v1 = getOrCreateVertex(face[1].v, face[1].vt, face[1].vn)
		local v2 = getOrCreateVertex(face[2].v, face[2].vt, face[2].vn)
		local v3 = getOrCreateVertex(face[3].v, face[3].vt, face[3].vn)

		local success = pcall(function()
			editableMesh:AddTriangle(v1, v2, v3)
		end)
		if success then
			triCount = triCount + 1
		end
	end

	if triCount == 0 then
		editableMesh:Destroy()
		error("Failed to create any triangles from OBJ data")
	end

	-- Calculate bounding box for sizing
	local _, _, size, center = OBJParser.getBounds(meshData)
	-- Ensure minimum size
	local meshSize = Vector3.new(
		math.max(size.X, 0.1),
		math.max(size.Y, 0.1),
		math.max(size.Z, 0.1)
	)

	-- Create MeshPart
	local meshPart = Instance.new("MeshPart")
	meshPart.Name = "MeshyAsset"
	meshPart.Size = meshSize
	meshPart.Anchored = true
	meshPart.Position = Vector3.new(0, meshSize.Y / 2, 0)

	-- Parent EditableMesh to MeshPart (overrides mesh geometry)
	editableMesh.Parent = meshPart

	return meshPart, triCount
end

----------------------------------------------------------------------
-- Callbacks
----------------------------------------------------------------------

-- API Key saved
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

	-- Reset downstream steps
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

			-- Store state
			state.currentTaskId = taskId
			state.currentTaskType = taskType
			state.sourceType = taskType
			state.modelUrls = result.model_urls
			state.textureUrls = result.texture_urls
			state.thumbnailUrl = result.thumbnail_url

			-- Update UI
			ui:setGenProgress(100)
			ui:setGenStatus("Mesh generated!", Color3.fromRGB(76, 175, 80))
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
				-- Use refine mode for text-to-3D meshes
				taskType = "text-to-3d"
				local texturePrompt = inputType == "text" and prompt or nil
				local textureImageUrl = inputType == "image" and prompt or nil

				ui:setTexStatus("Submitting texture refine task...")
				taskId = api:textTo3DRefine(state.currentTaskId, texturePrompt, textureImageUrl)
			else
				-- Use retexture API for image-to-3D meshes
				taskType = "text-to-texture"
				local objectPrompt = inputType == "text" and prompt or "3D object"
				local textureImageUrl = inputType == "image" and prompt or nil

				ui:setTexStatus("Submitting retexture task...")
				taskId = api:retexture(
					state.currentTaskId,
					objectPrompt,
					inputType == "text" and prompt or nil,
					textureImageUrl
				)
			end

			ui:setTexStatus("Applying texture...")

			local result = api:pollTask(taskType, taskId, function(progress)
				ui:setTexProgress(progress)
				ui:setTexStatus("Applying texture... " .. tostring(progress) .. "%")
			end)

			-- Update state
			state.currentTaskId = taskId
			state.currentTaskType = taskType
			state.modelUrls = result.model_urls
			state.textureUrls = result.texture_urls
			if result.thumbnail_url then
				state.thumbnailUrl = result.thumbnail_url
				ui:setThumbnail(result.thumbnail_url)
			end

			ui:setTexProgress(100)
			ui:setTexStatus("Texture applied!", Color3.fromRGB(76, 175, 80))
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

			-- Update state
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

			ui:setRemeshProgress(100)
			ui:setRemeshStatus("Remesh complete!", Color3.fromRGB(76, 175, 80))
		end)

		if not success then
			ui:setRemeshProgress(0)
			ui:setRemeshStatus("Error: " .. tostring(err), Color3.fromRGB(244, 67, 54))
		end

		setBusy(false)
	end)
end

-- Step 4: Publish to Workspace
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
	ui:setPubStatus("Preparing to import...")

	task.spawn(function()
		local meshPart

		-- Try auto-import via EditableMesh
		local autoImportSuccess, autoImportErr = pcall(function()
			local objUrl = state.modelUrls.obj
			if not objUrl or objUrl == "" then
				-- Fallback: try glb
				objUrl = state.modelUrls.glb
				if not objUrl then
					error("No downloadable model URL found")
				end
				error("OBJ format not available; only GLB. Use manual download.")
			end

			ui:setPubProgress(20)
			ui:setPubStatus("Downloading OBJ mesh data...")

			local objText = downloadText(objUrl)

			ui:setPubProgress(50)
			ui:setPubStatus("Parsing mesh geometry...")

			local triCount
			meshPart, triCount = createMeshPartFromOBJ(objText)

			ui:setPubProgress(80)
			ui:setPubStatus("Adding to workspace (" .. tostring(triCount) .. " triangles)...")

			-- Position near camera or at origin
			local camera = workspace.CurrentCamera
			if camera then
				meshPart.Position = camera.CFrame.Position + camera.CFrame.LookVector * 15
			end

			meshPart.Parent = workspace
			Selection:Set({meshPart})

			ui:setPubProgress(100)
			ui:setPubStatus("Added to workspace! (" .. tostring(triCount) .. " tris)", Color3.fromRGB(76, 175, 80))
		end)

		if not autoImportSuccess then
			-- Show download links as fallback
			local links = "Auto-import unavailable: " .. tostring(autoImportErr) .. "\n\nDownload your model manually:"
			if state.modelUrls then
				if state.modelUrls.glb then
					links = links .. "\nGLB: " .. state.modelUrls.glb
				end
				if state.modelUrls.fbx then
					links = links .. "\nFBX: " .. state.modelUrls.fbx
				end
				if state.modelUrls.obj then
					links = links .. "\nOBJ: " .. state.modelUrls.obj
				end
			end

			ui:setPubProgress(0)
			ui:setPubStatus("Auto-import failed. See download links below.", Color3.fromRGB(255, 152, 0))
			ui:setDownloadLinks(links)

			-- Also print links to output for easy copying
			print("[Meshy AI] Model download links:")
			if state.modelUrls.glb then print("  GLB: " .. state.modelUrls.glb) end
			if state.modelUrls.fbx then print("  FBX: " .. state.modelUrls.fbx) end
			if state.modelUrls.obj then print("  OBJ: " .. state.modelUrls.obj) end
		end

		setBusy(false)
	end)
end

----------------------------------------------------------------------
-- Toggle widget visibility
----------------------------------------------------------------------
toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

-- Sync button state with widget
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)

print("[Meshy AI] Plugin loaded. Click the toolbar button to open.")
