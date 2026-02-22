--[[
	MeshyAPI - HTTP client for the Meshy 3D generation API
	Handles text-to-3d, image-to-3d, retexture, and remesh endpoints.
]]

local HttpService = game:GetService("HttpService")

local MeshyAPI = {}
MeshyAPI.__index = MeshyAPI

local BASE_URL = "https://api.meshy.ai"

-- Compatibility: use task.wait if available, otherwise wait
local taskWait = task and task.wait or wait

local ENDPOINTS = {
	["text-to-3d"] = "/openapi/v2/text-to-3d",
	["image-to-3d"] = "/openapi/v1/image-to-3d",
	["text-to-texture"] = "/openapi/v1/text-to-texture",
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

-- Low-level HTTP request
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

	local decoded = HttpService:JSONDecode(response.Body)
	return decoded
end

--[[
	Create a Text-to-3D Preview task.
	Returns the task ID.
]]
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

--[[
	Create a Text-to-3D Refine task (texturing a preview mesh).
	Returns the task ID.
]]
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

--[[
	Create an Image-to-3D task.
	imageUrl: publicly accessible image URL or base64 data URI.
	Returns the task ID.
]]
function MeshyAPI:imageTo3D(imageUrl: string, shouldTexture: boolean?): string
	local body: any = {
		image_url = imageUrl,
		should_texture = shouldTexture or false,
		enable_pbr = true,
	}

	local result = self:_request("POST", ENDPOINTS["image-to-3d"], body)
	return result.result
end

--[[
	Create a Retexture (Text-to-Texture) task.
	Used to apply new textures to an existing mesh from any Meshy task.
	Returns the task ID.
]]
function MeshyAPI:retexture(inputTaskId: string, objectPrompt: string, stylePrompt: string?, textureImageUrl: string?): string
	local body: any = {
		input_task_id = inputTaskId,
		object_prompt = objectPrompt,
		enable_pbr = true,
		art_style = "realistic",
	}

	if textureImageUrl and textureImageUrl ~= "" then
		body.texture_image_url = textureImageUrl
	end
	if stylePrompt and stylePrompt ~= "" then
		body.style_prompt = stylePrompt
	end

	local result = self:_request("POST", ENDPOINTS["text-to-texture"], body)
	return result.result
end

--[[
	Create a Remesh task to reduce polygon count.
	Returns the task ID.
]]
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

--[[
	Retrieve a task by ID.
	taskType: "text-to-3d", "image-to-3d", "text-to-texture", or "remesh"
]]
function MeshyAPI:getTask(taskType: string, taskId: string): any
	local endpoint = ENDPOINTS[taskType]
	if not endpoint then
		error("Unknown task type: " .. taskType)
	end
	return self:_request("GET", endpoint .. "/" .. taskId)
end

--[[
	Poll a task until it completes (SUCCEEDED or FAILED).
	Calls onProgress(percent) periodically.
	Returns the completed task data.
]]
function MeshyAPI:pollTask(taskType: string, taskId: string, onProgress: ((number) -> ())?): any
	local POLL_INTERVAL = 3
	local MAX_POLLS = 200 -- ~10 minutes max

	for _ = 1, MAX_POLLS do
		local task = self:getTask(taskType, taskId)
		local status = task.status

		if onProgress and task.progress then
			onProgress(task.progress)
		end

		if status == "SUCCEEDED" then
			if onProgress then
				onProgress(100)
			end
			return task
		elseif status == "FAILED" then
			local errMsg = task.task_error and task.task_error.message or "Unknown error"
			error("Task failed: " .. errMsg)
		end

		taskWait(POLL_INTERVAL)
	end

	error("Task timed out after polling " .. MAX_POLLS .. " times")
end

return MeshyAPI
