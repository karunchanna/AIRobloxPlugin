# Meshy AI Asset Generator - Roblox Studio Plugin

A single-file Roblox Studio plugin that generates, textures, remeshes, and publishes 3D assets using the [Meshy AI API](https://www.meshy.ai/api).

## Prerequisites

- [Roblox Studio](https://www.roblox.com/create)
- A **Meshy API key** — sign up at [meshy.ai/api](https://www.meshy.ai/api) and generate a key

## Installation

1. Copy `MeshyAIPlugin.server.lua` into your Roblox Studio **Plugins** folder:
   - **Windows:** `%LOCALAPPDATA%\Roblox\Plugins\`
   - **macOS:** `~/Documents/Roblox/Plugins/`
2. Restart Roblox Studio (or reload plugins)
3. You should see a **"Meshy AI"** button in the toolbar

## Setup

1. Click the **"Asset Generator"** button in the Meshy AI toolbar to open the plugin panel
2. Paste your **Meshy API key** in the Settings section and click **Save**

## Usage — 4-Step Workflow

### Step 1: Generate Mesh
- Choose **Text Prompt** or **Image URL** as input
- For text: describe the 3D object (e.g. "a medieval wooden chair")
- For image: paste a publicly accessible image URL
- Select an art style (Realistic, Cartoon, or Sculpture)
- Click **Generate Mesh** and wait for processing
- A preview mesh will appear in your workspace

### Step 2: Texture
- Choose text or image input for texture guidance
- Describe the desired look or provide a reference image URL
- Click **Apply Texture**

### Step 3: Remesh
- Use the slider to set a target triangle count (1,000–20,000)
- Click **Remesh** to reduce polygon count for Roblox compatibility

### Step 4: Publish
- Click **Publish as Roblox Asset**
- The plugin publishes both the mesh and texture as permanent Roblox assets via `AssetService:CreateAssetAsync`
- A new `MeshPart` is created from the permanent asset IDs and inserted into the workspace
- If publish fails, download links (GLB/FBX/OBJ) are shown in the Output window as a manual fallback

## Notes

- The plugin is a single `.server.lua` file — no build step or Rojo required
- Generated models are retained by Meshy for a maximum of 3 days
- HTTP requests are enabled by default for Studio plugins
- The plugin uses `EditableMesh` and `EditableImage` to handle mesh parsing and texture decoding
- API credits are consumed per task — see [Meshy pricing](https://www.meshy.ai/api)
