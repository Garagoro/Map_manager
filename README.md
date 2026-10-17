# Map Manager

A Lua script for **Fatality (CS2)**: per-map visuals, post-processing, profiles, skin recolor, chams and a friend whitelist. Everything lives in a single file, `Map_manager.lua`.

> **This project is no longer maintained.** I've lost interest in Fatality, so I'm releasing the source as is. There will be no updates or support. Feel free to fork it, take it apart and reuse whatever you like.

## Features

**Visuals: post-processing shaders** (HLSL via `draw.Shader`, applied to the whole screen):
Grayscale, Color Grading, Sepia, Vignette, Sharpening, Posterize, Noir, Chromatic Aberration, Filmic Tonemap, Kuwahara (oil paint), Emboss and Color Replace (swap one color for another).

**Per-map world settings**
- World colors and parameters, fog and lighting, stored separately for each map.
- Bloom, tonemapping (exposure, white point, shadows/highlights) and local contrast through the engine's own post-processing. Saved per map.

**Points**: weighted points on the map. As you move around, settings blend smoothly based on your distance to each point.

**Configs**: profiles (save, load, switch), plus migration of profiles from older versions.

**Custom skybox**: replaces the sky. Skybox packs are downloaded from the [Garagoro/skyboxes](https://github.com/Garagoro/skyboxes) release.

**Other**
- **Weapon Skin Recolor**: recolors weapon and glove skins (4 colors per skin).
- **Chams**: glow/fresnel materials on models. Materials are downloaded from [Garagoro/chams-materials](https://github.com/Garagoro/chams-materials).
- **Friend Whitelist**: a list of friends (SteamID + name).

## Installation

1. Put `Map_manager.lua` in your Fatality scripts folder.
2. For Skin Recolor and Chams, enable **Allow insecure** (FFI is required).
3. Load the script. A **Manager** tab appears in the menu.

Configs and logs are written to `game/csgo/fatality/map_manager/`.

## Things to know

- **Custom skybox, Skin Recolor and Chams work on DirectX 11 only.** On Vulkan, the custom skybox crashes the game.
- Skin Recolor and Chams install hooks and rely on offsets in `client.dll` and `materialsystem2.dll`. They break after CS2 updates. The offsets are commented in the code; when they break, they have to be found again.
- Debug output is off. Turn it on with the `DEBUG_DIAGNOSTICS_ENABLED` and `CM_VERBOSE` flags at the top of the file.

## License

[MIT](LICENSE).
