--[[
	OBJParser - Parses Wavefront OBJ text format into structured mesh data.

	Returns a table with:
	  positions: {Vector3}
	  uvs: {Vector2}
	  normals: {Vector3}
	  faces: {{v: number, vt: number?, vn: number?}}  (each face is a list of vertex refs)
]]

local OBJParser = {}

-- Parse a face vertex component like "1/2/3", "1//3", "1/2", or "1"
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

--[[
	Parse OBJ text content into mesh data.
	Handles vertices, UVs, normals, triangles, and quads (auto-triangulated).
	Negative indices are resolved relative to the current vertex count.
]]
function OBJParser.parse(objText: string): any
	local positions: {Vector3} = {}
	local uvs: {Vector2} = {}
	local normals: {Vector3} = {}
	local faces = {} -- each face: list of {v, vt?, vn?}

	for line in objText:gmatch("[^\r\n]+") do
		-- Trim whitespace
		line = line:match("^%s*(.-)%s*$")

		if line == "" or line:sub(1, 1) == "#" then
			-- Skip empty lines and comments
		elseif line:sub(1, 2) == "v " then
			-- Vertex position: v x y z
			local x, y, z = line:match("v%s+([%-%d%.e]+)%s+([%-%d%.e]+)%s+([%-%d%.e]+)")
			if x then
				table.insert(positions, Vector3.new(tonumber(x), tonumber(y), tonumber(z)))
			end

		elseif line:sub(1, 3) == "vt " then
			-- Texture coordinate: vt u v
			local u, v = line:match("vt%s+([%-%d%.e]+)%s+([%-%d%.e]+)")
			if u then
				table.insert(uvs, Vector2.new(tonumber(u), tonumber(v)))
			end

		elseif line:sub(1, 3) == "vn " then
			-- Vertex normal: vn x y z
			local x, y, z = line:match("vn%s+([%-%d%.e]+)%s+([%-%d%.e]+)%s+([%-%d%.e]+)")
			if x then
				table.insert(normals, Vector3.new(tonumber(x), tonumber(y), tonumber(z)))
			end

		elseif line:sub(1, 2) == "f " then
			-- Face: f v1[/vt1[/vn1]] v2[/vt2[/vn2]] ...
			local faceVerts = {}
			for vertStr in line:sub(3):gmatch("%S+") do
				local vert = parseFaceVertex(vertStr)

				-- Handle negative indices (relative to current count)
				if vert.v < 0 then
					vert.v = #positions + 1 + vert.v
				end
				if vert.vt and vert.vt < 0 then
					vert.vt = #uvs + 1 + vert.vt
				end
				if vert.vn and vert.vn < 0 then
					vert.vn = #normals + 1 + vert.vn
				end

				table.insert(faceVerts, vert)
			end

			-- Triangulate: fan triangulation for polygons with 3+ vertices
			if #faceVerts >= 3 then
				for i = 2, #faceVerts - 1 do
					table.insert(faces, {
						faceVerts[1],
						faceVerts[i],
						faceVerts[i + 1],
					})
				end
			end
		end
		-- Skip: o, g, s, mtllib, usemtl, and other lines
	end

	return {
		positions = positions,
		uvs = uvs,
		normals = normals,
		faces = faces, -- each face is exactly 3 vertices (triangulated)
	}
end

--[[
	Calculate the bounding box of parsed mesh data.
	Returns min, max, size, center as Vector3 values.
]]
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
	local size = max - min
	local center = (min + max) / 2

	return min, max, size, center
end

return OBJParser
