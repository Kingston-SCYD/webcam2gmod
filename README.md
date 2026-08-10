# GMod Webcam - Install Instructions

## Requirements
- Garry's Mod x86-64 Chromium branch
- A web browser (Chrome or Firefox)

## Installation

### 1. Binary Module
Copy `bin/gmcl_webcam_win64.dll` to:
```
<GMod>/garrysmod/lua/bin/gmcl_webcam_win64.dll
```
Create the `bin` folder if it doesn't exist.

### 2. Addon
Copy the entire `addon/` folder to your addons directory and rename it:
```
<GMod>/garrysmod/addons/webcam/
```
So the structure is:
```
garrysmod/addons/webcam/
├── lua/
│   ├── autorun/
│   │   ├── client/webcam_init.lua
│   │   └── webcam_matlist.lua
│   └── entities/webcam_screen/
│       ├── cl_init.lua
│       ├── init.lua
│       └── shared.lua
└── materials/
    ├── webcam.vmt
    └── webcam_feed.vtf
```

## Usage

1. Launch GMod
2. Open console and run: `webcam_start`
3. Open `http://127.0.0.1:27099` in your browser
4. Click "Allow Camera Access" and grant permission
5. The webcam feed is now live in-game

### Console Commands
| Command | Description |
|---------|-------------|
| `webcam_start` | Start the webcam server |
| `webcam_stop` | Stop the webcam server |
| `webcam_hud` | Toggle HUD preview |

### Material Tool
Select the Material tool in the toolgun. The material `webcam` is in the material list. Apply it to any prop.

### Webcam Screen Entity
Spawn from the Entities tab under "Webcam" category. Right-click the entity and select "Edit Properties" to adjust:
- Size
- Offset X / Y (Forward) / Z (Up)
- Rotation Pitch / Yaw / Roll

### Web UI Controls
- Resolution: 480p / 720p / 1080p
- FPS: 10 / 15 / 20 / 30
