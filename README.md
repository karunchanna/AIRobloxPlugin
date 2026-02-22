# Meshy AI Asset Generator - Roblox Studio Plugin

A Roblox Studio plugin that integrates with the [Meshy API](https://www.meshy.ai/api) to generate, texture, and remesh 3D assets directly within Studio.

## Features

- **Generate Mesh** - Create 3D models from text prompts or reference images using Meshy's AI
- **Texture** - Apply AI-generated textures using text descriptions or reference images
- **Remesh** - Reduce triangle count with a slider (1,000 - 20,000) to stay within Roblox's limits
- **Publish to Workspace** - Import the final mesh directly into your game's workspace

## Prerequisites

- [Roblox Studio](https://www.roblox.com/create)
- A [Meshy API key](https://www.meshy.ai/api) (create an account at meshy.ai)
- [Rojo](https://rojo.space/) (for building from source)
- **EditableImage and EditableMesh** beta feature enabled in Studio (Settings > Beta Features) for auto-import

## Installation

### Option 1: Build with Rojo (Recommended)

1. Install [Rojo](https://rojo.space/docs/v7/getting-started/installation/)
2. Clone this repository
3. Build the plugin:
   ```bash
   rojo build -o MeshyAIPlugin.rbxm
   ```
4. Copy `MeshyAIPlugin.rbxm` to your Roblox Studio plugins folder:
   - **Windows:** `%LOCALAPPDATA%/Roblox/Plugins/`
   - **macOS:** `~/Documents/Roblox/Plugins/`
5. Restart Roblox Studio

### Option 2: Manual Installation

1. Open Roblox Studio
2. Create a new Script in `ServerStorage` (or your plugins folder)
3. Copy the contents of each `.lua` file from `src/` into ModuleScripts:
   - `src/init.server.lua` → Main plugin Script
   - `src/MeshyAPI.lua` → ModuleScript child named "MeshyAPI"
   - `src/OBJParser.lua` → ModuleScript child named "OBJParser"
   - `src/UI.lua` → ModuleScript child named "UI"
4. Save as a local plugin

## Usage

1. Click the **"Asset Generator"** button in the Meshy AI toolbar to open the panel
2. Enter your Meshy API key in the Settings section and click **Save**
3. **Step 1 - Generate Mesh:**
   - Choose **Text Prompt** or **Image URL** input
   - For text: describe the 3D object you want (e.g., "a medieval wooden chair")
   - For image: paste a publicly accessible image URL
   - Select an art style (Realistic, Cartoon, or Sculpture)
   - Click **Generate Mesh** and wait for processing
4. **Step 2 - Texture (Optional):**
   - Choose text or image input for texture guidance
   - Describe the desired texture or provide a reference image URL
   - Click **Apply Texture**
5. **Step 3 - Remesh (Optional):**
   - Use the slider to set your target triangle count (1,000 - 20,000)
   - Click **Remesh** to reduce polygon count for Roblox compatibility
6. **Publish:**
   - Click **Add to Workspace** to import the mesh into your game
   - The mesh will appear near your camera position
   - If auto-import fails, download links will be provided in the Output window

## Project Structure

```
src/
  init.server.lua   -- Main plugin entry point and orchestration
  MeshyAPI.lua      -- Meshy REST API client (text-to-3d, image-to-3d, remesh, retexture)
  OBJParser.lua     -- Wavefront OBJ format parser
  UI.lua            -- Plugin GUI (dark theme, 3-step wizard)
```

## Notes

- Generated models are retained by Meshy for a maximum of 3 days
- The plugin requires HTTP requests to be enabled (standard for Studio plugins)
- Auto-import uses EditableMesh (beta) to parse OBJ files and create MeshParts programmatically
- If EditableMesh is unavailable, the plugin provides direct download URLs for manual import via File > Import 3D
- API credits are consumed per task (see [Meshy pricing](https://www.meshy.ai/api))
