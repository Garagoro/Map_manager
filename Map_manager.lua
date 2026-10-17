-- Map Manager: post-processing shader picker + per-map visual/profile manager.

if __cm_shaderscs2_loaded and COLORED_MAPS_SHADER_API and __cm_script_build == "maps_manager_4panels_v2_15" then
    return
end
__cm_shaderscs2_loaded = true
__cm_script_build = "maps_manager_4panels_v2_15"

-- Runtime diagnostics (verbose console + file traces) are disabled by default.
local DEBUG_DIAGNOSTICS_ENABLED = false

-- Per-frame verbose tracing flag (kept OFF; checked by safe_invoke every frame).
CM_FORCE_VERBOSE_TXT_LOG = false

--[[
Map Manager (maintainer notes)
================================
High-level architecture:
1) Shader runtime:
   - HLSL shader list + fullscreen render pass (present_queue).
   - Runtime bridge is exported through the COLORED_MAPS_SHADER_API global.
2) Config system:
   - Profiles live in a dedicated, deterministic folder: fatality/map_manager/profiles/.
     Paths in the Fatality file API are relative to game/csgo, so there is one
     canonical location -- no candidate-path probing, no encoded filename guessing.
   - Each profile is one <name>.json wrapped in a marker payload; the file name
     is decoded back into the real profile name when scanning the folder.
   - Active profile is tracked in fatality/map_manager/active_profile.json;
     profiles_index.json is just a cache rebuilt from the folder scan.
   - On first run, profiles saved by older builds under fatality/ (and
     fatality/scripts/) are migrated into the new folder (see migrate_legacy_profiles).
   - UI helpers keep the list + profile registry in sync.
3) Points/weights logic:
   - Map points blend world settings by distance/weight.
   - Optional debug tools allow printing and auto-sync.
4) UI:
   - Custom tab "Manager" with panels:
       Visuals / Points / Configs / Custom skybox
   - `create_ui()` builds controls, wires callbacks, then applies visibility.
5) Runtime loop:
   - `on_frame()` updates map state, blending and periodic sync tasks.
]]

local function detect_script_dir()
    -- No debug library to introspect the path; callers use fixed relative paths.
    return nil
end

local function build_crash_log_paths()
    local paths = {
        "../colored_maps_crash.txt",
        "fatality/colored_maps_crash.txt",
        "colored_maps_crash.txt",
        "../colored_maps_crash.log",
        "fatality/colored_maps_crash.log",
        "colored_maps_crash.log"
    }

    local script_dir = detect_script_dir()
    if script_dir then
        paths[#paths + 1] = script_dir .. "colored_maps_crash.log"
        paths[#paths + 1] = script_dir .. "..\\colored_maps_crash.log"
    end

    return paths
end

CRASH_LOG_PATHS = build_crash_log_paths()
CRASH_LOG_MAX_BYTES = 262144

crash_log_path = nil
crash_log_last_line = ""
crash_log_last_time = 0
crash_log_write_failed_notified = false

local function crash_log_now()
    if utils and utils.GetUnixTime then
        return utils.GetUnixTime()
    end
    local gv = game and game.globalVars or nil
    if gv and type(gv.m_flRealTime) == "number" then
        return gv.m_flRealTime
    end
    return 0
end

-- Single switch for console output of every merged block (skin recolor, writer-FX, chams).
-- Global on purpose: the blocks live in separate protected_call functions a local would not reach.
CM_VERBOSE = false

local function protected_call(fn, ...)
    if fn == nil then
        return false, nil
    end

    -- No protected-call primitive in this sandbox: runs unprotected, keeps the
    -- (ok, result) contract every caller expects.
    return true, fn(...)
end

-- ── SHARED CONFIG FOLDER ────────────────────────────────────────────────────
-- Everything this script WRITES (including the merged blocks: chams, skin recolor, whitelist)
-- lives in fatality/map_manager, next to the profiles. Global rather than local: the blocks live
-- in separate protected_call functions a local would not reach.
-- ⚠ The migration runs BEFORE the first read. The blocks read their configs on load and are
-- declared further down, so this part must stay here, at the very top.
-- ⛔ PROFILES_LEGACY_DIRS (fatality, fatality/scripts) are NOT included: those are old locations
-- .json profiles are picked up from once. Move them and the migration stops finding them.
CM_CFG_DIR = "fatality/map_manager"
do
    if utils and utils.FileCreateDirectories then
        protected_call(utils.FileCreateDirectories, CM_CFG_DIR)
    end
    -- One-time move from the old locations. A file is moved ONLY if the new location is empty,
    -- otherwise a second run would overwrite the current config with a stale one.
    -- The skybox manifest.json cache is not listed: it is re-downloaded from GitHub every time,
    -- the local copy is just a saveToFile target that gets parsed right away.
    local moves = {
        "colored_maps_unified.json",
        "chams.cfg",
        "weapon_skin_recolor.cfg",
        "whitelist_friends.txt",
        "skychanger_skip.txt",
    }
    if utils and utils.FileExists and utils.FileRename then
        for _, name in ipairs(moves) do
            local from = "fatality/" .. name
            local to = CM_CFG_DIR .. "/" .. name
            local ok_to, has_to = protected_call(utils.FileExists, to)
            local ok_from, has_from = protected_call(utils.FileExists, from)
            if ok_to and ok_from and (not has_to) and has_from then
                protected_call(utils.FileRename, from, to)
            end
        end
    end
end

function add_child_compat(parent, child)
    if not parent then
        return false
    end
    -- NB: in the live runtime the container add method is lowercase `add`
    -- (the docs say `Add`); probe both so UI building works regardless.
    local add_fn = parent.Add or parent.add
    if not add_fn then
        return false
    end
    local ok, ret = protected_call(add_fn, parent, child)
    return ok and ret ~= false
end

function add_event_callback(event_obj, cb)
    if type(cb) ~= "function" then
        return false
    end
    if not event_obj then
        return false
    end

    local add_fn = event_obj.Add
    if not add_fn then
        return false
    end

    local ok, ret = protected_call(add_fn, event_obj, cb)
    return ok and ret ~= false
end

function notify_user(title, text)
    if not gui or not gui.notify or not gui.Notification then
        return false
    end
    local ok_note, notification = protected_call(gui.Notification, title, text)
    if not ok_note or not notification then
        return false
    end
    local ok_add = protected_call(gui.notify.Add, gui.notify, notification)
    return ok_add ~= false
end

CM_CUSTOM_SKY_TITLE_DEFAULT = CM_CUSTOM_SKY_TITLE_DEFAULT or "Custom skybox"
CM_CUSTOM_SKY_WARNING_LABEL = CM_CUSTOM_SKY_WARNING_LABEL or "Vulkan renderer not supported — will crash"

function get_global_vars_iface()
    if not game then
        return nil
    end
    return game.globalVars
end

function engine_in_game()
    local eng = game and game.engine or nil
    if not eng or not eng.InGame then
        return false
    end
    local ok, value = protected_call(eng.InGame, eng)
    if not ok then
        return false
    end
    return value == true or value == 1
end

function engine_is_connected()
    local eng = game and game.engine or nil
    if not eng or not eng.IsConnected then
        return false
    end
    local ok, value = protected_call(eng.IsConnected, eng)
    if not ok then
        return false
    end
    return value == true or value == 1
end

function read_convar_string(convar_obj)
    if not convar_obj then
        return nil
    end
    -- ConVar exposes its value through the read-only `value` field.
    local value = convar_obj.value
    if value == nil then
        return nil
    end
    local str = tostring(value)
    if str == "" then
        return nil
    end
    return str
end

local function resolve_crash_log_path()
    if crash_log_path then
        return crash_log_path
    end

    local has_utils_file_api = utils
        and utils.FileExists
        and utils.FileRead
        and utils.FileWrite
        and utils.ArrayToString
        and utils.StringToArray

    for i = 1, #CRASH_LOG_PATHS do
        local candidate = CRASH_LOG_PATHS[i]
        if has_utils_file_api then
            local ok_exists, exists_result = protected_call(utils.FileExists, candidate)
            if ok_exists and exists_result == true then
                crash_log_path = candidate
                return crash_log_path
            end
        end
    end

    if has_utils_file_api then
        local ok_empty, empty = protected_call(utils.StringToArray, "")
        if empty then
            for i = 1, #CRASH_LOG_PATHS do
                local candidate = CRASH_LOG_PATHS[i]
                protected_call(utils.FileWrite, candidate, empty)
                local ok_exists, exists_result = protected_call(utils.FileExists, candidate)
                if ok_exists and exists_result == true then
                    crash_log_path = candidate
                    return crash_log_path
                end
            end
        end
    end

    return nil
end

local function append_crash_log(raw_line)
    local path = resolve_crash_log_path()
    if not path then
        return false
    end

    if not utils or not utils.FileRead or not utils.FileWrite or not utils.ArrayToString or not utils.StringToArray then
        return false
    end

    local content = ""
    local ok_old, old_bytes = protected_call(utils.FileRead, path)
    if ok_old and old_bytes then
        local ok_loaded, loaded = protected_call(utils.ArrayToString, old_bytes)
        if ok_loaded and type(loaded) == "string" then
            content = loaded
        end
    end

    content = content .. raw_line .. "\n"
    if #content > CRASH_LOG_MAX_BYTES then
        content = content:sub(#content - CRASH_LOG_MAX_BYTES + 1)
        local first_nl = content:find("\n", 1, true)
        if first_nl then
            content = content:sub(first_nl + 1)
        end
    end

    local ok_out, out = protected_call(utils.StringToArray, content)
    if not ok_out or not out then
        return false
    end

    local ok, result = protected_call(utils.FileWrite, path, out)
    return ok and result ~= false
end

local function crash_log(message)
    if not DEBUG_DIAGNOSTICS_ENABLED then
        return
    end
    local msg = tostring(message)
    local t = crash_log_now()

    if msg == crash_log_last_line and (t - crash_log_last_time) < 0.25 then
        return
    end

    crash_log_last_line = msg
    crash_log_last_time = t
    local ok = append_crash_log(string.format("[%.3f] %s", t, msg))
    if not ok and not crash_log_write_failed_notified then
        crash_log_write_failed_notified = true
    end
end

function __cm_verbose_log(message, mirror_console)
    if not DEBUG_DIAGNOSTICS_ENABLED then
        return
    end
    local line = "[CMAP][VERBOSE] " .. tostring(message)
    crash_log(line)
end

local function safe_error_message(err)
    -- No debug library in this sandbox, so no stack traceback is available.
    return tostring(err)
end

local function safe_invoke(tag, fn, ...)
    if type(fn) ~= "function" then
        return false
    end

    if CM_FORCE_VERBOSE_TXT_LOG then
        __cm_verbose_log("enter " .. tostring(tag), false)
    end

    -- No protected-call primitive in this sandbox: the call runs unprotected.
    fn(...)

    if CM_FORCE_VERBOSE_TXT_LOG then
        __cm_verbose_log("leave " .. tostring(tag) .. " ok=true", false)
    end
    return true
end

runtime_loaded_map = nil
transition_cooldown_until = 0
MAP_COOLDOWN_ON_CHANGE = 0.75
MAP_COOLDOWN_ON_LEAVE = 0.75
MAP_CHANGE_STABLE_SECONDS = 0.30
MAP_CHANGE_STABLE_FRAMES = 8
map_change_pending_name = nil
map_change_pending_started_at = 0
map_change_pending_frames = 0
script_initialized = false
local State
local Utils
shader_runtime_can_render = false
TEAM_T = 2
TEAM_CT = 3

local function runtime_now()
    if utils and utils.GetUnixTime then
        return utils.GetUnixTime()
    end
    local gv = game and game.globalVars or nil
    if gv and type(gv.m_flRealTime) == "number" then
        return gv.m_flRealTime
    end
    return 0
end

local function set_transition_cooldown(seconds)
    local duration = tonumber(seconds) or 0
    if duration <= 0 then
        return
    end
    local until_time = runtime_now() + duration
    if until_time > transition_cooldown_until then
        transition_cooldown_until = until_time
    end
end

local function in_transition_cooldown(now_time)
    local t = now_time or runtime_now()
    return t < transition_cooldown_until
end

local function team_number(v)
    if type(v) == "number" then return v end
    if type(v) == "userdata" or type(v) == "table" then
        if v.Get then
            local n = v:Get()
            if type(n) == "number" then return n end
        end
        if v.GetRaw then
            local n = v:GetRaw()
            if type(n) == "number" then return n end
        end
    end
    return nil
end

local function get_local_team_num()
    if not entities then
        return nil
    end

    if entities.GetLocalPawn then
        local ok_pawn, p = protected_call(entities.GetLocalPawn, entities)
        if ok_pawn and p then
            local team_value = p.m_iTeamNum
            if team_value ~= nil then
                return team_number(team_value)
            end
        end
    end

    return nil
end

local function is_play_team(team_num)
    return team_num == TEAM_T or team_num == TEAM_CT
end

local function set_shader_runtime_gate_state(can_render)
    local next_state = (can_render == true)
    shader_runtime_can_render = next_state
end

local function update_shader_runtime_gate()
    if not game or not game.engine then
        set_shader_runtime_gate_state(false)
        return false, nil
    end
    if not engine_in_game() or not engine_is_connected() then
        set_shader_runtime_gate_state(false)
        return false, nil
    end

    local can_render = false
    if entities and entities.GetLocalPawn then
        local ok_pawn, pawn = protected_call(entities.GetLocalPawn, entities)
        if ok_pawn and pawn then
            if pawn.IsAlive then
                local ok_alive, alive = protected_call(pawn.IsAlive, pawn)
                can_render = ok_alive and (alive == true or alive == 1)
            else
                -- If runtime has no IsAlive method, keep rendering enabled for compatibility.
                can_render = true
            end
        end
    end

    set_shader_runtime_gate_state(can_render)
    return shader_runtime_can_render, nil
end

local function add_present_queue_callback(cb)
    if type(cb) ~= "function" or not events then
        return false
    end

    local ev = events.presentQueue
    if not ev then
        return false
    end

    return add_event_callback(ev, cb)
end

local function get_back_buffer_texture()
    if not draw or not draw.adapter then
        return nil
    end
    local adapter = draw.adapter

    if not adapter.GetBackBuffer then
        return nil
    end
    local ok, tex = protected_call(adapter.GetBackBuffer, adapter)
    if ok and tex then
        return tex
    end
    return nil
end

local shader_render_fn_ref

-- Crash guard: clamp may be missing in this environment
local function clamp(v, lo, hi)
    if type(v) ~= "number" or type(lo) ~= "number" or type(hi) ~= "number" then return v end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
if not math.clamp then math.clamp = clamp end

-- ========== Index picker helper (1-based option index) ==========
-- A ComboBox may store a bitmask (1,2,4,8,16) or a 0-based index (0,1,2,3,4).
local function get_combo_index(ctrl)
    if not ctrl or not ctrl.GetValue then return 0 end
    local value_param = ctrl:GetValue()
    if not value_param or not value_param.Get then return 0 end
    local bits = value_param:Get()
    if not bits or not bits.GetRaw then return 0 end
    local raw = bits:GetRaw()
    if raw == nil or raw < 0 then return 0 end
    if raw == 0 then return 1 end
    if type(raw) ~= "number" then return 0 end

    local int_raw = math.floor(raw)
    local is_pow2 = int_raw > 0 and (int_raw == 1 or (int_raw % 2 == 0))
    if is_pow2 then
        local t = int_raw
        while t > 1 do
            if (t % 2) ~= 0 then
                is_pow2 = false
                break
            end
            t = math.floor(t / 2)
        end
    end

    -- bitmask mode: 1,2,4,8...
    if is_pow2 then
        return math.floor(math.log(int_raw) / math.log(2)) + 1
    end

    -- index mode (usually 0-based): 0,1,2,3...
    return int_raw + 1
end

local function get_list_index(ctrl)
    if not ctrl or not ctrl.GetValue then return 0 end
    local value_param = ctrl:GetValue()
    if not value_param or not value_param.Get then return 0 end
    local bits = value_param:Get()
    if not bits then return 0 end

    local raw = nil
    if bits.GetRaw then
        raw = bits:GetRaw()
    end

    if type(raw) == "number" then
        local int_raw = math.floor(raw)
        if int_raw <= 0 then
            return 0
        end
        local idx = 1
        while int_raw > 0 do
            if (int_raw % 2) == 1 then
                return idx
            end
            int_raw = math.floor(int_raw / 2)
            idx = idx + 1
        end
        return 0
    end

    if bits.Get then
        for i = 1, 64 do
            local ok, toggled = protected_call(bits.Get, bits, i)
            if ok and toggled == true then
                return i
            end
        end
    end

    return 0
end

local function get_selector_index(ctrl)
    if not ctrl then return 0 end

    local ok_allow, allow_multiple = protected_call(function(o)
        return o.allowMultiple
    end, ctrl)
    if ok_allow and allow_multiple ~= nil then
        return get_list_index(ctrl)
    end

    local ok_unlimited, unlimited_mode = protected_call(function(o)
        return o.unlimitedMode
    end, ctrl)
    if ok_unlimited and unlimited_mode ~= nil then
        return get_list_index(ctrl)
    end

    return get_combo_index(ctrl)
end

-- Slider: return a number 0..100, otherwise default
local function get_slider_value(ctrl, default)
    if not ctrl or not ctrl.GetValue then return default end
    local v = ctrl:GetValue()
    if not v or not v.Get then return default end
    local n = v:Get()
    if type(n) ~= "number" then return default end
    return n
end

-- Color from a picker -> r, g, b, a (0-255)
local function get_color_rgba(ctrl, default_r, default_g, default_b, default_a)
    if not ctrl or not ctrl.GetValue then return default_r, default_g, default_b, default_a end
    local vp = ctrl:GetValue()
    if not vp or not vp.Get then return default_r, default_g, default_b, default_a end
    local c = vp:Get()
    if not c or not c.GetR then return default_r, default_g, default_b, default_a end
    return c:GetR(), c:GetG(), c:GetB(), c:GetA()
end

-- ========== HLSL shaders ==========
-- 11 main shaders + a separate dynamic Color Replace (single-pass).
local shaders = {}

-- 1. Grayscale
shaders[1] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float gray = dot(orig.rgb, float3(0.299, 0.587, 0.114));
    float4 eff = float4(gray, gray, gray, orig.a);
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 2. Color Grading (saturation + contrast)
shaders[2] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float saturation = 1.5;
    float contrast = 1.2;
    float4 color = orig;
    color.rgb = ((color.rgb - 0.5) * contrast) + 0.5;
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = lerp(float3(gray, gray, gray), color.rgb, saturation);
    float4 eff = color;
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 3. Sepia
shaders[3] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float gray = dot(orig.rgb, float3(0.299, 0.587, 0.114));
    float3 sepia = float3(gray * 1.2, gray * 1.0, gray * 0.8);
    float4 eff = float4(saturate(sepia), orig.a);
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 4. Vignette (darkened edges)
shaders[4] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float2 uv = inp.uv * 2.0 - 1.0;
    float vig = saturate(1.0 - dot(uv, uv) * 0.5);
    float edge = 1.0 - vig;
    float3 tint = saturate(inp.col.rgb);
    float tint_mix = saturate(inp.col.a);
    if (dot(tint, tint) < 0.0001) {
        tint = float3(1.0, 1.0, 1.0);
        tint_mix = 0.0;
    }
    // Dark rim only: the center is left untouched.
    float3 shadow_color = lerp(float3(0.0, 0.0, 0.0), tint, tint_mix);
    float3 eff_rgb = lerp(orig.rgb, shadow_color, edge);
    float4 eff = float4(eff_rgb, orig.a);
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 5. Sharpening
shaders[5] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float2 safe_tex = max(tex, float2(1.0, 1.0));
    float2 px = 1.0 / safe_tex;

    float3 c  = orig.rgb;
    float3 u  = texture0.Sample(sampler0, inp.uv + float2(0.0, -px.y)).rgb;
    float3 d  = texture0.Sample(sampler0, inp.uv + float2(0.0,  px.y)).rgb;
    float3 l  = texture0.Sample(sampler0, inp.uv + float2(-px.x, 0.0)).rgb;
    float3 r  = texture0.Sample(sampler0, inp.uv + float2( px.x, 0.0)).rgb;
    float3 ul = texture0.Sample(sampler0, inp.uv + float2(-px.x, -px.y)).rgb;
    float3 ur = texture0.Sample(sampler0, inp.uv + float2( px.x, -px.y)).rgb;
    float3 dl = texture0.Sample(sampler0, inp.uv + float2(-px.x,  px.y)).rgb;
    float3 dr = texture0.Sample(sampler0, inp.uv + float2( px.x,  px.y)).rgb;

    // Extra-radius taps for larger detail response.
    float3 u2 = texture0.Sample(sampler0, inp.uv + float2(0.0, -2.0 * px.y)).rgb;
    float3 d2 = texture0.Sample(sampler0, inp.uv + float2(0.0,  2.0 * px.y)).rgb;
    float3 l2 = texture0.Sample(sampler0, inp.uv + float2(-2.0 * px.x, 0.0)).rgb;
    float3 r2 = texture0.Sample(sampler0, inp.uv + float2( 2.0 * px.x, 0.0)).rgb;

    // Unsharp mask (small radius) + broad detail (large radius).
    float3 blur_small = (c * 4.0 + (u + d + l + r) * 2.0 + (ul + ur + dl + dr)) / 16.0;
    float3 blur_large = (u2 + d2 + l2 + r2) * 0.25;
    float3 high_small = c - blur_small;
    float3 high_large = c - blur_large;
    float3 detail = high_small * 4.9 + high_large * 1.85;

    float edge = abs(dot(high_small, float3(0.299, 0.587, 0.114)));
    float edge_mask = smoothstep(0.0008, 0.030, edge);
    float amount = 3.9 + edge_mask * 5.1;

    // Tint only the detail signal.
    float3 tint = saturate(inp.col.rgb);
    float tint_mix = saturate(inp.col.a) * 0.75;
    if (dot(tint, tint) < 0.0001) {
        tint = float3(1.0, 1.0, 1.0);
        tint_mix = 0.0;
    }
    float3 detail_tinted = detail * lerp(float3(1.0, 1.0, 1.0), tint, tint_mix);
    float3 sharpened = c + detail_tinted * amount;

    // Clamp to local neighborhood range (+small headroom) to reduce halos/artifacts.
    float3 nmin = min(c, min(min(u, d), min(l, r)));
    nmin = min(nmin, min(min(ul, ur), min(dl, dr)));
    float3 nmax = max(c, max(max(u, d), max(l, r)));
    nmax = max(nmax, max(max(ul, ur), max(dl, dr)));
    sharpened = clamp(sharpened, nmin - 0.16, nmax + 0.16);

    float4 eff = float4(saturate(sharpened), orig.a);
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 6. Posterize (fewer color levels)
shaders[6] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float levels = 4.0;
    float4 eff = orig;
    eff.rgb = floor(eff.rgb * levels) / levels;
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 7. Noir (black and white + contrast + vignette)
shaders[7] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float gray = dot(orig.rgb, float3(0.299, 0.587, 0.114));
    gray = saturate((gray - 0.3) * 1.4);
    float2 uv = inp.uv * 2.0 - 1.0;
    float vig = 1.0 - dot(uv, uv) * 0.4;
    float4 eff = float4(gray * vig, gray * vig, gray * vig, orig.a);
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 8. Chromatic Aberration (RGB shift toward the edges)
shaders[8] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float2 p = inp.uv * 2.0 - 1.0;
    float dist = length(p);
    float2 dir = (dist > 0.0001) ? (p / dist) : float2(0.0, 0.0);
    // Spread is encoded in vertex color R channel (0..1 -> 0..2x).
    float spread = saturate(inp.col.r) * 2.0;
    float2 off = dir * (0.002 + dist * dist * 0.006) * spread;
    float r = texture0.Sample(sampler0, saturate(inp.uv + off)).r;
    float g = texture0.Sample(sampler0, inp.uv).g;
    float b = texture0.Sample(sampler0, saturate(inp.uv - off)).b;
    float3 ca = float3(r, g, b);
    float4 eff = float4(ca, orig.a);
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 9. LUT/Filmic Tonemap (film-style color grading)
shaders[9] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float3 aces(float3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float3 c = orig.rgb;

    // Filmic S-curve with warm highlights and cool shadows.
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = max(c - 0.018, 0.0) * 1.12;
    c = aces(c);
    float3 warm = float3(1.04, 1.00, 0.96);
    float3 cool = float3(0.94, 0.99, 1.05);
    c *= lerp(cool, warm, saturate(l));
    c = pow(saturate(c), 1.0 / 1.05);
    c = saturate((c - 0.5) * 1.16 + 0.5);

    float4 eff = float4(c, orig.a);
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 10. Kuwahara/Oil Paint (oil painting style)
shaders[10] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float luma(float3 c) {
    return dot(c, float3(0.299, 0.587, 0.114));
}
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float2 inv = 1.0 / max(tex, float2(1.0, 1.0));
    float2 px = inv * 2.0;

    float3 m0 = 0.0; float v0 = 0.0;
    float3 m1 = 0.0; float v1 = 0.0;
    float3 m2 = 0.0; float v2 = 0.0;
    float3 m3 = 0.0; float v3 = 0.0;

    float3 c0 = texture0.Sample(sampler0, inp.uv + float2(-px.x, -px.y)).rgb;
    float3 c1 = texture0.Sample(sampler0, inp.uv + float2(0.0,   -px.y)).rgb;
    float3 c2 = texture0.Sample(sampler0, inp.uv + float2(-px.x,  0.0)).rgb;
    float3 c3 = texture0.Sample(sampler0, inp.uv + float2(0.0,    0.0)).rgb;
    m0 = (c0 + c1 + c2 + c3) * 0.25;
    float lm0 = luma(m0);
    v0 = abs(luma(c0) - lm0) + abs(luma(c1) - lm0) + abs(luma(c2) - lm0) + abs(luma(c3) - lm0);

    float3 c4 = texture0.Sample(sampler0, inp.uv + float2(0.0,   -px.y)).rgb;
    float3 c5 = texture0.Sample(sampler0, inp.uv + float2(px.x,  -px.y)).rgb;
    float3 c6 = texture0.Sample(sampler0, inp.uv + float2(0.0,    0.0)).rgb;
    float3 c7 = texture0.Sample(sampler0, inp.uv + float2(px.x,   0.0)).rgb;
    m1 = (c4 + c5 + c6 + c7) * 0.25;
    float lm1 = luma(m1);
    v1 = abs(luma(c4) - lm1) + abs(luma(c5) - lm1) + abs(luma(c6) - lm1) + abs(luma(c7) - lm1);

    float3 c8  = texture0.Sample(sampler0, inp.uv + float2(-px.x,  0.0)).rgb;
    float3 c9  = texture0.Sample(sampler0, inp.uv + float2(0.0,    0.0)).rgb;
    float3 c10 = texture0.Sample(sampler0, inp.uv + float2(-px.x,  px.y)).rgb;
    float3 c11 = texture0.Sample(sampler0, inp.uv + float2(0.0,    px.y)).rgb;
    m2 = (c8 + c9 + c10 + c11) * 0.25;
    float lm2 = luma(m2);
    v2 = abs(luma(c8) - lm2) + abs(luma(c9) - lm2) + abs(luma(c10) - lm2) + abs(luma(c11) - lm2);

    float3 c12 = texture0.Sample(sampler0, inp.uv + float2(0.0,    0.0)).rgb;
    float3 c13 = texture0.Sample(sampler0, inp.uv + float2(px.x,   0.0)).rgb;
    float3 c14 = texture0.Sample(sampler0, inp.uv + float2(0.0,    px.y)).rgb;
    float3 c15 = texture0.Sample(sampler0, inp.uv + float2(px.x,   px.y)).rgb;
    m3 = (c12 + c13 + c14 + c15) * 0.25;
    float lm3 = luma(m3);
    v3 = abs(luma(c12) - lm3) + abs(luma(c13) - lm3) + abs(luma(c14) - lm3) + abs(luma(c15) - lm3);

    float3 best = m0;
    float bestv = v0;
    if (v1 < bestv) { bestv = v1; best = m1; }
    if (v2 < bestv) { bestv = v2; best = m2; }
    if (v3 < bestv) { bestv = v3; best = m3; }

    // Return to original oil-paint look, reduced by 30% (keep 70% effect).
    best = floor(best * 7.0) / 7.0;
    float3 eff_rgb = lerp(orig.rgb, saturate(best), 0.70);
    float4 eff = float4(eff_rgb, orig.a);
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 11. Emboss
shaders[11] = draw.Shader([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float2 inv = 1.0 / max(tex, float2(1.0, 1.0));
    float3 tl = texture0.Sample(sampler0, inp.uv + float2(-inv.x, -inv.y)).rgb;
    float3 br = texture0.Sample(sampler0, inp.uv + float2( inv.x,  inv.y)).rgb;
    float3 tr = texture0.Sample(sampler0, inp.uv + float2( inv.x, -inv.y)).rgb;
    float3 bl = texture0.Sample(sampler0, inp.uv + float2(-inv.x,  inv.y)).rgb;

    float3 gx = (tr + br) - (tl + bl);
    float3 gy = (bl + br) - (tl + tr);
    float3 emb = 0.5 + (gx - gy) * 1.8;
    emb = lerp(orig.rgb, emb, 0.85);
    float3 tint = saturate(inp.col.rgb);
    float tint_mix = saturate(inp.col.a);
    if (dot(tint, tint) < 0.0001) {
        tint = float3(1.0, 1.0, 1.0);
        tint_mix = 0.0;
    }
    emb = lerp(emb, emb * tint, tint_mix);

    float4 eff = float4(saturate(emb), orig.a);
    float3 base = lerp(orig.rgb, eff.rgb, alpha);
    return float4(base, 1.0);
}
]])

-- 12. Color Replace (single-pass), shaders cached per source color.
local REPLACE_SHADER_CACHE_LIMIT = 24
local replace_shader_cache = {}
local replace_shader_lru = {}

local function clamp_u8(v)
    if type(v) ~= "number" then return 0 end
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return math.floor(v + 0.5)
end

local function quant_u8(v)
    v = clamp_u8(v)
    return math.floor(v / 4) * 4
end

local function touch_replace_shader_key(key)
    for i = 1, #replace_shader_lru do
        if replace_shader_lru[i] == key then
            table.remove(replace_shader_lru, i)
            break
        end
    end
    replace_shader_lru[#replace_shader_lru + 1] = key

    if #replace_shader_lru > REPLACE_SHADER_CACHE_LIMIT then
        local old_key = table.remove(replace_shader_lru, 1)
        replace_shader_cache[old_key] = nil
    end
end

local function build_color_replace_shader(sr, sg, sb, sa)
    local source_vec = string.format("float3(%.6f, %.6f, %.6f)", sr / 255.0, sg / 255.0, sb / 255.0)
    local search = math.max(0.0, math.min(1.0, sa / 255.0))
    local tolerance = 0.006 + search * 0.20
    local edge = tolerance * 1.65
    local tolerance_sq = tolerance * tolerance
    local edge_sq = edge * edge

    local shader = draw.Shader(string.format([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;
float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float3 source = %s;
    float3 target = saturate(inp.col.rgb);
    float repaint = saturate(inp.col.a) * saturate(alpha);
    if (repaint <= 0.0001) return orig;
    float3 diff = orig.rgb - source;
    float d2 = dot(diff, diff);
    if (d2 >= %.6f) return orig;
    float mask = 1.0 - smoothstep(%.6f, %.6f, d2);
    float3 replaced = lerp(orig.rgb, target, mask);
    float3 base = lerp(orig.rgb, replaced, repaint);
    return float4(base, 1.0);
}
]], source_vec, edge_sq, tolerance_sq, edge_sq))

    if shader and shader.create then
        shader:Create()
    end
    return shader
end

local function get_color_replace_shader(sr, sg, sb, sa)
    sr = quant_u8(sr)
    sg = quant_u8(sg)
    sb = quant_u8(sb)
    sa = quant_u8(sa)
    local key = sr * 16777216 + sg * 65536 + sb * 256 + sa

    local cached = replace_shader_cache[key]
    if cached then
        touch_replace_shader_key(key)
        return cached
    end

    local shader = build_color_replace_shader(sr, sg, sb, sa)
    replace_shader_cache[key] = shader
    touch_replace_shader_key(key)
    return shader
end

-- Tonemapping (2 sliders): darks/lights, dynamic shader cache.
local TONEMAP = {
    SHADER_CACHE_LIMIT = 32,
    shader_cache = {},
    shader_lru = {},
    FUSED_CACHE_LIMIT = 24,
    fused_cache = {},
    fused_lru = {},
    SHADOWS_MIN = -100,
    SHADOWS_MAX = 100,
    SHADOWS_DEFAULT = 0,
    HIGHLIGHTS_MIN = -100,
    HIGHLIGHTS_MAX = 100,
    HIGHLIGHTS_DEFAULT = 0,
    shadows_slider = nil,
    shadows_row = nil,
    highlights_slider = nil,
    highlights_row = nil
}

function TONEMAP.touch_shader_key(key)
    for i = 1, #TONEMAP.shader_lru do
        if TONEMAP.shader_lru[i] == key then
            table.remove(TONEMAP.shader_lru, i)
            break
        end
    end
    TONEMAP.shader_lru[#TONEMAP.shader_lru + 1] = key
    if #TONEMAP.shader_lru > TONEMAP.SHADER_CACHE_LIMIT then
        local old_key = table.remove(TONEMAP.shader_lru, 1)
        TONEMAP.shader_cache[old_key] = nil
    end
end

function TONEMAP.format_float(v)
    return string.format("%.6f", tonumber(v) or 0.0)
end

function TONEMAP.build_shader(params)
    local shader = draw.Shader(string.format([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;

static const float SHADOWS_CTL = %s;
static const float HIGHLIGHTS_CTL = %s;

static const float HABLE_A = 0.22;
static const float HABLE_B = 0.30;
static const float HABLE_C = 0.10;
static const float HABLE_D = 0.20;
static const float HABLE_E = 0.01;
static const float HABLE_F = 0.30;
static const float HABLE_W = 11.2;
static const float BASE_EXPOSURE = 2.0;

float3 hable_curve(float3 x) {
    float3 num = x * (HABLE_A * x + HABLE_C * HABLE_B) + HABLE_D * HABLE_E;
    float3 den = x * (HABLE_A * x + HABLE_B) + HABLE_D * HABLE_F;
    float base = HABLE_E / HABLE_F;
    return (num / max(den, float3(0.00001, 0.00001, 0.00001))) - base;
}

float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float3 src = max(orig.rgb, 0.0);

    float3 mapped = hable_curve(src * BASE_EXPOSURE);
    float3 white_scale = 1.0 / max(hable_curve(float3(HABLE_W, HABLE_W, HABLE_W)), float3(0.0001, 0.0001, 0.0001));
    float3 tone = saturate(mapped * white_scale);

    float luma = dot(tone, float3(0.2126, 0.7152, 0.0722));
    float shadow_mask = pow(1.0 - smoothstep(0.0, 0.55, luma), 0.70);
    float highlight_mask = pow(smoothstep(0.45, 1.0, luma), 0.70);

    float shadows_gain = clamp(SHADOWS_CTL, 0.0, 2.0);
    float highlights_gain = clamp(HIGHLIGHTS_CTL, 0.0, 2.0);

    float shadow_gamma = 1.0 / max(shadows_gain, 0.05);
    float highlight_gamma = max(highlights_gain, 0.05);
    float3 shadow_tone = saturate(pow(max(tone, float3(0.0001, 0.0001, 0.0001)), shadow_gamma));
    float3 highlight_tone = saturate(1.0 - pow(max(1.0 - tone, float3(0.0001, 0.0001, 0.0001)), highlight_gamma));

    float shadow_mix = saturate(abs(shadows_gain - 1.0) * 1.8) * shadow_mask;
    float highlight_mix = saturate(abs(highlights_gain - 1.0) * 1.8) * highlight_mask;

    float3 adjusted = lerp(tone, shadow_tone, shadow_mix);
    adjusted = lerp(adjusted, highlight_tone, highlight_mix);

    float3 base = lerp(orig.rgb, saturate(adjusted), saturate(alpha));
    return float4(base, orig.a);
}
]], TONEMAP.format_float(params.shadows_ctl), TONEMAP.format_float(params.highlights_ctl)))

    if shader and shader.create then
        shader:Create()
    end
    return shader
end

function TONEMAP.get_shadows_raw()
    local raw = get_slider_value(TONEMAP.shadows_slider, TONEMAP.SHADOWS_DEFAULT)
    raw = math.floor((tonumber(raw) or TONEMAP.SHADOWS_DEFAULT) + 0.5)
    return math.max(TONEMAP.SHADOWS_MIN, math.min(TONEMAP.SHADOWS_MAX, raw))
end

function TONEMAP.get_highlights_raw()
    local raw = get_slider_value(TONEMAP.highlights_slider, TONEMAP.HIGHLIGHTS_DEFAULT)
    raw = math.floor((tonumber(raw) or TONEMAP.HIGHLIGHTS_DEFAULT) + 0.5)
    return math.max(TONEMAP.HIGHLIGHTS_MIN, math.min(TONEMAP.HIGHLIGHTS_MAX, raw))
end

function TONEMAP.GetRaw_state()
    return {
        darks = TONEMAP.get_shadows_raw(),
        lights = TONEMAP.get_highlights_raw()
    }
end

function TONEMAP.apply_raw_state(state)
    if type(state) ~= "table" then return end
    local shadows = tonumber(state.darks) or TONEMAP.SHADOWS_DEFAULT
    shadows = math.floor(shadows + 0.5)
    shadows = math.max(TONEMAP.SHADOWS_MIN, math.min(TONEMAP.SHADOWS_MAX, shadows))

    local highlights = tonumber(state.lights) or TONEMAP.HIGHLIGHTS_DEFAULT
    highlights = math.floor(highlights + 0.5)
    highlights = math.max(TONEMAP.HIGHLIGHTS_MIN, math.min(TONEMAP.HIGHLIGHTS_MAX, highlights))

    if TONEMAP.shadows_slider and TONEMAP.shadows_slider.GetValue then
        local v = TONEMAP.shadows_slider:GetValue()
        if v and v.Set then
            v:Set(shadows)
        end
    end

    if TONEMAP.highlights_slider and TONEMAP.highlights_slider.GetValue then
        local v = TONEMAP.highlights_slider:GetValue()
        if v and v.Set then
            v:Set(highlights)
        end
    end
end

function TONEMAP.get_shader()
    local darks = TONEMAP.get_shadows_raw()
    local lights = TONEMAP.get_highlights_raw()

    local key = string.format("%d:%d", darks, lights)
    local cached = TONEMAP.shader_cache[key]
    if cached then
        TONEMAP.touch_shader_key(key)
        return cached
    end

    local shader = TONEMAP.build_shader({
        shadows_ctl = 1.0 + (darks / 100.0),
        highlights_ctl = 1.0 + (lights / 100.0)
    })
    TONEMAP.shader_cache[key] = shader
    TONEMAP.touch_shader_key(key)
    return shader
end

function TONEMAP.touch_fused_key(key)
    for i = 1, #TONEMAP.fused_lru do
        if TONEMAP.fused_lru[i] == key then
            table.remove(TONEMAP.fused_lru, i)
            break
        end
    end
    TONEMAP.fused_lru[#TONEMAP.fused_lru + 1] = key
    if #TONEMAP.fused_lru > TONEMAP.FUSED_CACHE_LIMIT then
        local old_key = table.remove(TONEMAP.fused_lru, 1)
        TONEMAP.fused_cache[old_key] = nil
    end
end

function TONEMAP.build_fused_shader(params)
    local shader = draw.Shader(string.format([[
cbuffer cb : register(b0) {
    float4x4 mvp;
    float2 tex;
    float time;
    float alpha;
};
struct PS_INPUT {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv : TEXCOORD0;
};
SamplerState sampler0 : register(s0);
Texture2D texture0;

static const float S_GRAY = %s;
static const float S_GRADING = %s;
static const float S_SEPIA = %s;
static const float S_VIGNETTE = %s;
static const float S_POSTERIZE = %s;
static const float S_NOIR = %s;
static const float S_FILMIC = %s;

static const float VIG_R = %s;
static const float VIG_G = %s;
static const float VIG_B = %s;
static const float VIG_A = %s;

static const float SHADOWS_CTL = %s;
static const float HIGHLIGHTS_CTL = %s;

static const float HABLE_A = 0.22;
static const float HABLE_B = 0.30;
static const float HABLE_C = 0.10;
static const float HABLE_D = 0.20;
static const float HABLE_E = 0.01;
static const float HABLE_F = 0.30;
static const float HABLE_W = 11.2;
static const float BASE_EXPOSURE = 2.0;

float3 hable_curve(float3 x) {
    float3 num = x * (HABLE_A * x + HABLE_C * HABLE_B) + HABLE_D * HABLE_E;
    float3 den = x * (HABLE_A * x + HABLE_B) + HABLE_D * HABLE_F;
    float base = HABLE_E / HABLE_F;
    return (num / max(den, float3(0.00001, 0.00001, 0.00001))) - base;
}

float4 main(PS_INPUT inp) : SV_Target {
    float4 orig = texture0.Sample(sampler0, inp.uv);
    float3 c = orig.rgb;

    if (S_GRAY > 0.0001) {
        float gray = dot(c, float3(0.299, 0.587, 0.114));
        c = lerp(c, float3(gray, gray, gray), saturate(S_GRAY));
    }

    if (S_GRADING > 0.0001) {
        float3 t = c;
        float saturation = 1.5;
        float contrast = 1.2;
        t = ((t - 0.5) * contrast) + 0.5;
        float gray = dot(t, float3(0.299, 0.587, 0.114));
        t = lerp(float3(gray, gray, gray), t, saturation);
        c = lerp(c, saturate(t), saturate(S_GRADING));
    }

    if (S_SEPIA > 0.0001) {
        float gray = dot(c, float3(0.299, 0.587, 0.114));
        float3 sepia = saturate(float3(gray * 1.2, gray * 1.0, gray * 0.8));
        c = lerp(c, sepia, saturate(S_SEPIA));
    }

    if (S_POSTERIZE > 0.0001) {
        float levels = 4.0;
        float3 p = floor(saturate(c) * levels) / levels;
        c = lerp(c, p, saturate(S_POSTERIZE));
    }

    if (S_NOIR > 0.0001) {
        float gray = dot(c, float3(0.299, 0.587, 0.114));
        gray = saturate((gray - 0.3) * 1.4);
        float2 uv = inp.uv * 2.0 - 1.0;
        float vig = 1.0 - dot(uv, uv) * 0.4;
        float3 noir = float3(gray * vig, gray * vig, gray * vig);
        c = lerp(c, saturate(noir), saturate(S_NOIR));
    }

    if (S_FILMIC > 0.0001) {
        float3 src = max(c, 0.0);
        float3 mapped = hable_curve(src * BASE_EXPOSURE);
        float3 white_scale = 1.0 / max(hable_curve(float3(HABLE_W, HABLE_W, HABLE_W)), float3(0.0001, 0.0001, 0.0001));
        float3 tone = saturate(mapped * white_scale);

        float luma = dot(tone, float3(0.2126, 0.7152, 0.0722));
        float shadow_mask = pow(1.0 - smoothstep(0.0, 0.55, luma), 0.70);
        float highlight_mask = pow(smoothstep(0.45, 1.0, luma), 0.70);

        float shadows_gain = clamp(SHADOWS_CTL, 0.0, 2.0);
        float highlights_gain = clamp(HIGHLIGHTS_CTL, 0.0, 2.0);

        float shadow_gamma = 1.0 / max(shadows_gain, 0.05);
        float highlight_gamma = max(highlights_gain, 0.05);
        float3 shadow_tone = saturate(pow(max(tone, float3(0.0001, 0.0001, 0.0001)), shadow_gamma));
        float3 highlight_tone = saturate(1.0 - pow(max(1.0 - tone, float3(0.0001, 0.0001, 0.0001)), highlight_gamma));

        float shadow_mix = saturate(abs(shadows_gain - 1.0) * 1.8) * shadow_mask;
        float highlight_mix = saturate(abs(highlights_gain - 1.0) * 1.8) * highlight_mask;

        float3 adjusted = lerp(tone, shadow_tone, shadow_mix);
        adjusted = lerp(adjusted, highlight_tone, highlight_mix);
        c = lerp(c, saturate(adjusted), saturate(S_FILMIC));
    }

    if (S_VIGNETTE > 0.0001) {
        float2 uv = inp.uv * 2.0 - 1.0;
        float vig = saturate(1.0 - dot(uv, uv) * 0.5);
        float edge = 1.0 - vig;
        float3 tint = saturate(float3(VIG_R, VIG_G, VIG_B));
        float tint_mix = saturate(VIG_A);
        if (dot(tint, tint) < 0.0001) {
            tint = float3(1.0, 1.0, 1.0);
            tint_mix = 0.0;
        }
        float3 shadow_color = lerp(float3(0.0, 0.0, 0.0), tint, tint_mix);
        float3 vignette = lerp(c, shadow_color, edge);
        c = lerp(c, vignette, saturate(S_VIGNETTE));
    }

    float3 base = lerp(orig.rgb, saturate(c), saturate(alpha));
    return float4(base, orig.a);
}
]], TONEMAP.format_float(params.s_gray), TONEMAP.format_float(params.s_grading), TONEMAP.format_float(params.s_sepia),
    TONEMAP.format_float(params.s_vignette), TONEMAP.format_float(params.s_posterize), TONEMAP.format_float(params.s_noir),
    TONEMAP.format_float(params.s_filmic), TONEMAP.format_float(params.vig_r), TONEMAP.format_float(params.vig_g),
    TONEMAP.format_float(params.vig_b), TONEMAP.format_float(params.vig_a), TONEMAP.format_float(params.shadows_ctl),
    TONEMAP.format_float(params.highlights_ctl)))

    if shader and shader.create then
        shader:Create()
    end
    return shader
end

function TONEMAP.get_fused_shader(config)
    local key = string.format("%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d", config.gray, config.grading, config.sepia,
        config.vignette, config.posterize, config.noir, config.filmic, config.vig_rgba_key, config.shadows, config.lights,
        config.has_vignette_tint and 1 or 0)
    local cached = TONEMAP.fused_cache[key]
    if cached then
        TONEMAP.touch_fused_key(key)
        return cached
    end

    local shader = TONEMAP.build_fused_shader({
        s_gray = (config.gray or 0) / 100.0,
        s_grading = (config.grading or 0) / 100.0,
        s_sepia = (config.sepia or 0) / 100.0,
        s_vignette = (config.vignette or 0) / 100.0,
        s_posterize = (config.posterize or 0) / 100.0,
        s_noir = (config.noir or 0) / 100.0,
        s_filmic = (config.filmic or 0) / 100.0,
        vig_r = (config.vig_r or 255) / 255.0,
        vig_g = (config.vig_g or 255) / 255.0,
        vig_b = (config.vig_b or 255) / 255.0,
        vig_a = (config.vig_a or 0) / 255.0,
        shadows_ctl = 1.0 + ((config.shadows or 0) / 100.0),
        highlights_ctl = 1.0 + ((config.lights or 0) / 100.0)
    })
    TONEMAP.fused_cache[key] = shader
    TONEMAP.touch_fused_key(key)
    return shader
end

-- create() must be called on every shader (no protected call available, nil checks only)
for i = 1, 11 do
    if shaders[i] and shaders[i].create then
        shaders[i]:Create()
    end
end
replace_shader_cache[60 * 16777216 + 140 * 65536 + 255 * 256 + 255] = build_color_replace_shader(60, 140, 255, 255)
touch_replace_shader_key(60 * 16777216 + 140 * 65536 + 255 * 256 + 255)

local FILTERS = {
    { id = "grayscale", name = "Grayscale", shader_idx = 1 },
    { id = "grading", name = "Color Grading", shader_idx = 2 },
    { id = "sepia", name = "Sepia", shader_idx = 3 },
    { id = "vignette", name = "Vignette", shader_idx = 4, tint = "vignette" },
    { id = "sharpen", name = "Sharpening", shader_idx = 5, tint = "sharpen" },
    { id = "posterize", name = "Posterize", shader_idx = 6 },
    { id = "noir", name = "Noir", shader_idx = 7 },
    { id = "chromatic", name = "Chromatic Aberration", shader_idx = 8 },
    { id = "filmic", name = "LUT/Filmic Tonemap", shader_idx = 9 },
    { id = "kuwahara", name = "Kuwahara/Oil Paint", shader_idx = 10 },
    { id = "emboss", name = "Emboss", shader_idx = 11, tint = "emboss" },
    { id = "replace", name = "Color Replace", is_replace = true }
}
local VIGNETTE_FILTER_LIST_INDEX = 4
local SHARPEN_FILTER_LIST_INDEX = 5
local CHROMATIC_FILTER_LIST_INDEX = 8
local EMBOSS_FILTER_LIST_INDEX = 11
local REPLACE_FILTER_LIST_INDEX = 12

local filter_combo = nil
local filter_combo_row = nil
local filter_strength = {}
local filter_strength_rows = {}

local vignette_tint_color = nil
local vignette_tint_row = nil
local sharpen_tint_color = nil
local sharpen_tint_row = nil
local chromatic_spread_slider = nil
local chromatic_spread_row = nil
local emboss_tint_color = nil
local emboss_tint_row = nil
local REPLACE_PAIR_MAX = 64
local REPLACE_PAIR_MIN = 1
local replace_pair_count = 1
local replace_pairs = {}
local replace_add_btn = nil
local replace_add_row = nil
local replace_remove_btn = nil
local replace_remove_row = nil
local shader_runtime_enabled = false
local shader_ui_visible = true

local function apply_uniform_button_style(button)
    if not button then
        return button
    end

    protected_call(function(ctrl)
        ctrl.sizeToParentW = true
    end, button)

    return button
end

ROW_VISIBILITY_CACHE = ROW_VISIBILITY_CACHE or {}

local function set_row_visible(row, visible)
    if not row or not row.SetVisible then
        return false
    end
    local state = (visible == true)
    if ROW_VISIBILITY_CACHE[row] == state then
        return false
    end
    ROW_VISIBILITY_CACHE[row] = state
    protected_call(row.SetVisible, row, state)
    return true
end

local function get_filter_strength(idx)
    local s = get_slider_value(filter_strength[idx], 0)
    return math.max(0.0, math.min(1.0, s / 100.0))
end

local function get_chromatic_spread()
    local value = get_slider_value(chromatic_spread_slider, 100)
    value = math.max(0, math.min(200, value))
    return value / 100.0
end

local refresh_ui_visibility = function() end

-- UI container contract for custom tab mode.
-- visuals_panel -> world/environment controls host (+ shader controls)
-- points_panel  -> points controls host (aka "group")
-- shaders_panel -> alias to visuals_panel for backward compatibility
-- configs_panel -> configs controls host (aka "group_a")
MAPS_CUSTOM_UI = MAPS_CUSTOM_UI or {
    use_custom_tab = true,
    allow_legacy_fallback = true,
    initialized = false,
    root_tab = nil,
    main_tab = nil,
    settings_tab = nil,
    section = "main",
    section_list = nil,
    section_objects = {},
    sections_panel = nil,
    visuals_panel = nil,
    points_panel = nil,
    shaders_panel = nil,
    configs_panel = nil,
    custom_sky_panel = nil,
    env_panel = nil,
    shader_point_filter_rows = {},
    shader_point_filter_checks = {},
    shader_point_filter_hint_rows = {}
}

do
    local ui_unpack = unpack or (table and table.unpack)
    local shader_ui_initialized = false

    local function ui_safe_call(fn, ...)
        if type(fn) ~= "function" and type(fn) ~= "userdata" then
            return false, nil
        end

        -- No protected-call primitive in this sandbox: run unprotected, keep (ok, result).
        return true, fn(...)
    end

    local function ui_get_member(obj, key)
        if obj == nil then
            return nil
        end
        local ok, value = ui_safe_call(function()
            return obj[key]
        end)
        if ok then
            return value
        end
        return nil
    end

    local function ui_is_callable(value)
        local t = type(value)
        if t == "function" or t == "userdata" then
            return true
        end
        if t == "table" then
            local mt = getmetatable(value)
            if mt and type(mt.__call) == "function" then
                return true
            end
        end
        return false
    end

    -- UI control methods differ in casing between the docs (PascalCase) and the
    -- live runtime (often snake_case). Generate the casing variants and probe
    -- each, so tab/group building works on either.
    local function ui_candidate_names(name)
        local out, seen = {}, {}
        local function push(v)
            if type(v) ~= "string" or v == "" or seen[v] then
                return
            end
            seen[v] = true
            out[#out + 1] = v
        end

        push(name)
        if type(name) == "string" then
            push(name:sub(1, 1):lower() .. name:sub(2))
            push(name:lower())
            local snake = name:gsub("(%l)(%u)", "%1_%2"):gsub("(%u)(%u%l)", "%1_%2"):lower()
            push(snake)
        end

        return out
    end

    local function ui_try_method(obj, method, ...)
        if obj == nil then
            return false, nil
        end
        local names = ui_candidate_names(method)
        for i = 1, #names do
            local fn = ui_get_member(obj, names[i])
            if ui_is_callable(fn) then
                return ui_safe_call(fn, obj, ...)
            end
        end
        return false, nil
    end

    local function ui_has_method(obj, method)
        if obj == nil then
            return false
        end

        local names = ui_candidate_names(method)
        for i = 1, #names do
            if ui_is_callable(ui_get_member(obj, names[i])) then
                return true
            end
        end

        return false
    end

    local function ui_make_id(id)
        if type(gui) == "table" and type(gui.ControlID) == "function" then
            local ok, cid = ui_safe_call(gui.ControlID, id)
            if ok and cid ~= nil then
                return cid
            end
        end
        return id
    end

    local function ui_add_child(parent, child)
        if not parent or not child then
            return false
        end
        -- Doc says :Add, but the live runtime varies both the method name and
        -- its casing across builds. Probe every known child-attach name; a
        -- narrow lookup silently fails and dumps controls into the Lua tab.
        local methods = { "Add", "add", "AddChild", "add_child", "Push", "push", "Insert", "insert" }
        for i = 1, #methods do
            local ok = ui_try_method(parent, methods[i], child)
            if ok then
                return true
            end
        end
        return false
    end

    local function ui_reset(obj)
        if not obj then
            return
        end
        ui_try_method(obj, "Reset")
    end

    local function ui_find_path(path)
        if not gui or not gui.ctx then
            return nil
        end
        local ok, node = ui_try_method(gui.ctx, "Find", path)
        if ok and node then
            return node
        end
        return nil
    end

    local function ui_pick_icon()
        local textures = (draw and draw.textures) or ui_get_member(draw, "textures")
        if not textures then
            return nil
        end

        local keys = {
            -- Preferred: settings/gear style icons.
            "gui_icon_settings",
            "gui_icon_gear",
            "gui_icon_cog",
            "gui_icon_config",
            "icon_settings",
            "icon_gear",
            "icon_cog",
            "icon_config",
            -- Safe fallbacks for older builds.
            "gui_icon_down",
            "icon_scripts",
            "icon_visuals",
            "gui_icon_world",
            "gui_icon_layers",
            "gui_icon_star"
        }

        for i = 1, #keys do
            local key = keys[i]
            local icon = ui_get_member(textures, key)
            if icon ~= nil then
                return icon
            end
            local get_fn = ui_get_member(textures, "Get")
            if ui_is_callable(get_fn) then
                local ok_get, got = ui_safe_call(get_fn, textures, key)
                if ok_get and got ~= nil then
                    return got
                end
            end
        end

        return nil
    end

    local function ui_get_main_window()
        if type(gui) ~= "table" then
            return nil
        end

        local probes = {
            { obj = gui, fn = "GetMainWindow" },
            { obj = gui, fn = "get_main_window" },
            { obj = gui, fn = "GetMainWnd" },
            { obj = gui, fn = "get_main_wnd" },
            { obj = gui.ctx, fn = "GetMainWindow" },
            { obj = gui.ctx, fn = "get_main_window" }
        }

        for i = 1, #probes do
            local probe = probes[i]
            local fn = ui_get_member(probe.obj, probe.fn)
            if ui_is_callable(fn) then
                local ok, window = ui_try_method(probe.obj, probe.fn)
                if ok and window ~= nil then
                    return window
                end
            end
        end

        return nil
    end

    -- Window:AddTab(id, icon, title, layoutMode). The live runtime varies in
    -- both method casing and accepted argument shape, so probe several.
    local function ui_add_root_tab(window, id, icon, title, mode)
        if not window then
            return nil
        end

        local methods = { "AddTab", "add_tab" }
        local id_candidates = { id, ui_make_id(id) }

        for i = 1, #methods do
            local method = methods[i]
            for j = 1, #id_candidates do
                local one_id = id_candidates[j]
                if one_id ~= nil then
                    local ok, tab = ui_try_method(window, method, one_id, icon, title, mode)
                    if ok and tab ~= nil then
                        return tab
                    end

                    ok, tab = ui_try_method(window, method, one_id, title, mode)
                    if ok and tab ~= nil then
                        return tab
                    end

                    ok, tab = ui_try_method(window, method, one_id, icon, title)
                    if ok and tab ~= nil then
                        return tab
                    end

                    ok, tab = ui_try_method(window, method, one_id, title)
                    if ok and tab ~= nil then
                        return tab
                    end
                end
            end
        end

        return nil
    end

    -- TabsLayout:AddTab(id, title, layoutMode, enabled)
    local function ui_add_subtab(layout, id, title, mode, enabled)
        if not layout then
            return nil
        end
        local ok, tab = ui_try_method(layout, "AddTab", ui_make_id(id), title, mode, enabled)
        if ok and tab ~= nil then
            return tab
        end
        return nil
    end

    -- Doc says gui.Group(id, title, height, gui.GroupWidthMode), but the live
    -- runtime varies in ctor casing, accepted arity, and width-mode enum
    -- availability/type. Probe every shape; a single hard-coded signature
    -- returns nil on any mismatch and collapses the whole custom tab into Lua.
    -- prefer_reduced only changes which width mode is attempted first
    -- (Visuals/Points want FULL, the side panels want REDUCED).
    local function ui_make_group(id, title, height, prefer_reduced)
        if not gui then
            return nil
        end

        local ctors = ui_candidate_names("Group")
        local width_modes = {}
        local seen_modes = {}
        local function push_mode(v)
            if v == nil then
                return
            end
            local key = tostring(v)
            if seen_modes[key] then
                return
            end
            seen_modes[key] = true
            width_modes[#width_modes + 1] = v
        end

        local function add_modes_from(tbl, full_key, default_key, reduced_key)
            if type(tbl) ~= "table" then
                return
            end
            if prefer_reduced == true then
                push_mode(tbl[reduced_key])
                push_mode(tbl[default_key])
                push_mode(tbl[full_key])
            else
                push_mode(tbl[full_key])
                push_mode(tbl[default_key])
                push_mode(tbl[reduced_key])
            end
        end

        add_modes_from(gui.GroupWidthMode, "FULL", "DEFAULT", "REDUCED")
        add_modes_from(gui.group_width_mode, "full", "default", "reduced")
        if prefer_reduced == true then
            push_mode(0)
            push_mode(1)
            push_mode(2)
        else
            push_mode(2)
            push_mode(1)
            push_mode(0)
        end

        local panel_height = tonumber(height) or 420
        local id_candidates = { ui_make_id(id), id }

        local function try_ctor(ctor_name, ...)
            local ctor = gui[ctor_name]
            if not ui_is_callable(ctor) then
                return nil
            end
            local ok, g = ui_safe_call(ctor, ...)
            if ok and g then
                return g
            end
            return nil
        end

        for _, ctor_name in ipairs(ctors) do
            for i = 1, #id_candidates do
                local group_id = id_candidates[i]
                if group_id ~= nil then
                    for w = 1, #width_modes do
                        local g = try_ctor(ctor_name, group_id, title, panel_height, width_modes[w])
                        if g then
                            return g
                        end
                    end
                    local g = try_ctor(ctor_name, group_id, title, panel_height)
                    if g then
                        return g
                    end
                    g = try_ctor(ctor_name, group_id, title)
                    if g then
                        return g
                    end
                    g = try_ctor(ctor_name, group_id)
                    if g then
                        return g
                    end
                end
            end
        end

        return nil
    end

    local function ui_attach_panel(root_tab, id, title, height)
        if not root_tab then
            return nil
        end
        local panel = ui_make_group(id, title, height)
        if panel and ui_add_child(root_tab, panel) then
            return panel
        end
        return nil
    end

    local function ui_vec2(x, y)
        if not draw then
            return nil
        end
        if ui_is_callable(draw.Vec2) then
            local ok, v = ui_safe_call(draw.Vec2, x, y)
            if ok and v then
                return v
            end
        end
        if ui_is_callable(draw.vec2) then
            local ok, v = ui_safe_call(draw.vec2, x, y)
            if ok and v then
                return v
            end
        end
        return nil
    end

    local function ui_make_layout(id, size, direction)
        if not gui or not ui_is_callable(gui.Layout) or not size or direction == nil then
            return nil
        end

        local zero = ui_vec2(0, 0)
        if not zero then
            return nil
        end

        local layout_id = ui_make_id(id)
        local ok, layout = ui_safe_call(gui.Layout, layout_id, zero, size, direction)
        if ok and layout then
            return layout
        end

        ok, layout = ui_safe_call(gui.Layout, id, zero, size, direction)
        if ok and layout then
            return layout
        end

        return nil
    end

    local function set_panel_visible(panel, visible)
        if not panel then
            return
        end
        if panel.SetVisible then
            ui_safe_call(panel.SetVisible, panel, visible == true)
        end
    end

    local function refresh_custom_section_selector()
        local list = MAPS_CUSTOM_UI.section_list
        if not list then
            return
        end
        local clear_fn = list.RemoveAll or list.ClearChildren or list.Clear
        if type(clear_fn) == "function" then
            ui_safe_call(clear_fn, list)
        end
        MAPS_CUSTOM_UI.section_objects = {}
        local add_fn = list.Add
        if type(add_fn) ~= "function" then
            return
        end
        local labels = { "Main", "Settings" }
        local i
        for i = 1, #labels do
            local selectable = custom_sky_create_selectable("cm_maps_section_" .. tostring(i), labels[i])
            if selectable then
                local ok_add, added = ui_safe_call(add_fn, list, selectable)
                if ok_add and added ~= false then
                    MAPS_CUSTOM_UI.section_objects[#MAPS_CUSTOM_UI.section_objects + 1] = selectable
                end
            end
        end
        local vp = list.GetValue and list:GetValue() or nil
        local bits = vp and vp.Get and vp:Get() or nil
        if bits and bits.SetRaw then
            bits:SetRaw((MAPS_CUSTOM_UI.section == "settings") and 2 or 1)
            if vp.Set then
                vp:Set(bits)
            end
        end
        if type(list.ProcessQueues) == "function" then
            ui_safe_call(list.ProcessQueues, list)
        end
        if type(list.RaiseFirstRenderCall) == "function" then
            ui_safe_call(list.RaiseFirstRenderCall, list)
        end
    end

    local function create_maps_custom_tab()
        if MAPS_CUSTOM_UI.initialized then
            return true
        end
        if not MAPS_CUSTOM_UI.use_custom_tab then
            return false
        end
        if not gui then
            return false
        end

        local window = ui_get_main_window()
        if not window then
            return false
        end

        local default_mode = gui.TabLayoutMode and gui.TabLayoutMode.DEFAULT or nil
        local subtabs_mode = gui.TabLayoutMode and gui.TabLayoutMode.SUBTABS or nil
        local icon = ui_pick_icon()
        -- Root tab hosts a sub-tab list (Local/Enemy/Team/World-style): "Maps" + "Skin Recolor".
        local root_tab = ui_add_root_tab(window, "cm_maps_manager_root_3p", icon, "Maps Manager", subtabs_mode or default_mode)
        if not root_tab then
            root_tab = ui_add_root_tab(window, "cm_maps_manager_root_3p", icon, "Maps Manager", nil)
        end

        if not root_tab then
            return false
        end

        -- Sub-tabs: the map-manager panels go under "Maps"; the skin recolor group goes under
        -- "Skin Recolor" (its build_ui parents into WSR_SKIN_PARENT). If sub-tabs aren't
        -- supported on this build, fall back to putting the panels straight on root_tab.
        local maps_container = root_tab
        WSR_SKIN_PARENT = nil
        if subtabs_mode then
            local maps_sub = ui_add_subtab(root_tab, "cm_maps_sub_maps_3p", "Maps", default_mode, true)
            if maps_sub then
                maps_container = maps_sub
                WSR_SKIN_PARENT = ui_add_subtab(root_tab, "cm_maps_sub_skin_3p", "Other", default_mode, false)
            end
        end

        local panel_h = 465
        local configs_panel_h = 225
        local custom_sky_panel_h = 225
        local visuals_panel = ui_make_group("cm_panel_visuals_3p", "Visuals", panel_h, true)
        local points_panel = ui_make_group("cm_panel_points_3p", "Points", panel_h, true)
        local configs_panel = ui_make_group("cm_panel_configs_3p", "Configs", configs_panel_h, true)
        local custom_sky_panel = ui_make_group("cm_panel_custom_sky_3p", CM_CUSTOM_SKY_TITLE_DEFAULT, custom_sky_panel_h, true)

        local visuals_added = false
        local points_added = false
        local configs_added = false
        local custom_sky_added = false

        local vertical_dir = nil
        local stack_ctor = gui and gui.MakeStackedGroups or nil
        local left_stack_size = ui_vec2(205, 463)
        local left_stack = nil
        if type(gui.StackDirection) == "table" then
            vertical_dir = gui.StackDirection.VERTICAL
        end

        if vertical_dir ~= nil and left_stack_size and configs_panel and custom_sky_panel then
            local left_layout = ui_make_layout("cm_maps_left_layout_3p", left_stack_size, vertical_dir)
            if left_layout then
                left_layout.stackOffset = ui_vec2(0, 18)
                if ui_add_child(left_layout, configs_panel) and ui_add_child(left_layout, custom_sky_panel) then
                    left_stack = left_layout
                end
            end
        end

        if not left_stack and ui_is_callable(stack_ctor) and left_stack_size and configs_panel and custom_sky_panel then
            local ok_left, built_left = ui_safe_call(stack_ctor, ui_make_id("cm_maps_left_stack_3p"), left_stack_size, {
                configs_panel, custom_sky_panel
            })
            if ok_left and built_left then
                left_stack = built_left
            end
        end

        visuals_added = visuals_panel and ui_add_child(maps_container, visuals_panel) or false
        points_added = points_panel and ui_add_child(maps_container, points_panel) or false

        if left_stack and ui_add_child(maps_container, left_stack) then
            configs_added = true
            custom_sky_added = true
        else
            configs_added = configs_panel and ui_add_child(maps_container, configs_panel) or false
            custom_sky_added = custom_sky_panel and ui_add_child(maps_container, custom_sky_panel) or false
        end

        if not (visuals_added and points_added and configs_added and custom_sky_added) then
            if CM_FORCE_VERBOSE_TXT_LOG then
                __cm_verbose_log(
                    "custom_tab: panel create failed visuals_created=" .. tostring(visuals_panel ~= nil) ..
                    " visuals_added=" .. tostring(visuals_added) ..
                    " points_created=" .. tostring(points_panel ~= nil) ..
                    " points_added=" .. tostring(points_added) ..
                    " configs_created=" .. tostring(configs_panel ~= nil) ..
                    " configs_added=" .. tostring(configs_added) ..
                    " custom_sky_created=" .. tostring(custom_sky_panel ~= nil) ..
                    " custom_sky_added=" .. tostring(custom_sky_added),
                    true
                )
            end
            return false
        end

        MAPS_CUSTOM_UI.root_tab = root_tab
        MAPS_CUSTOM_UI.main_tab = root_tab
        MAPS_CUSTOM_UI.settings_tab = root_tab
        MAPS_CUSTOM_UI.sections_panel = nil
        MAPS_CUSTOM_UI.section_list = nil
        MAPS_CUSTOM_UI.visuals_panel = visuals_panel
        MAPS_CUSTOM_UI.points_panel = points_panel
        MAPS_CUSTOM_UI.shaders_panel = visuals_panel
        MAPS_CUSTOM_UI.configs_panel = configs_panel
        MAPS_CUSTOM_UI.custom_sky_panel = custom_sky_panel
        MAPS_CUSTOM_UI.env_panel = visuals_panel
        MAPS_CUSTOM_UI.initialized = true

        ui_reset(visuals_panel)
        ui_reset(points_panel)
        ui_reset(configs_panel)
        ui_reset(custom_sky_panel)
        MAPS_CUSTOM_UI.section = "main"
        -- Avoid resetting root/window here: some builds crash after runtime tab injection.
        return true
    end

    -- Returns: group_a, group, env_group, shader_group, using_custom_tab
    -- group_a      -> Configs panel
    -- group        -> Points panel
    -- env_group    -> Visuals panel (custom tab) or Visuals > World > Environment (legacy)
    -- shader_group -> shader controls host (Visuals panel in custom/legacy)
    MAPS_CUSTOM_UI.resolve_ui_containers = function()
        if MAPS_CUSTOM_UI.use_custom_tab and create_maps_custom_tab() then
            return MAPS_CUSTOM_UI.configs_panel, MAPS_CUSTOM_UI.points_panel, MAPS_CUSTOM_UI.env_panel, MAPS_CUSTOM_UI.shaders_panel, true
        end

        if not MAPS_CUSTOM_UI.allow_legacy_fallback then
            return nil, nil, nil, nil, false
        end

        local group_a = ui_find_path("lua>elements a")
        local group = ui_find_path("lua>elements b")
        local env_group = ui_find_path("visuals>world>environment")
        return group_a, group, env_group, env_group, false
    end

    MAPS_CUSTOM_UI.ensure_shader_ui_container = function(shader_container)
    if shader_ui_initialized then
        return true
    end
    if not shader_container then
        return false
    end
    if not gui or not gui.ComboBox or not gui.ControlID or not gui.MakeControl or not gui.Selectable or not gui.Slider then
        return false
    end

    replace_pairs = {}
    replace_pair_count = REPLACE_PAIR_MIN

    filter_combo = gui.ComboBox(gui.ControlID("shaderscs2_filter"))
    if filter_combo and filter_combo.Add then
        for i = 1, #FILTERS do
            local opt_id = "shaderscs2_filter_" .. FILTERS[i].id
            local opt = gui.Selectable(gui.ControlID(opt_id), FILTERS[i].name)
            if opt then
                add_child_compat(filter_combo, opt)
            end
        end
    end
    if filter_combo then
        filter_combo_row = gui.MakeControl("Post filter", filter_combo)
        ui_add_child(shader_container, filter_combo_row)
    end

    for i = 1, #FILTERS do
        if not FILTERS[i].is_replace then
            filter_strength[i] = gui.Slider(gui.ControlID("shaderscs2_strength_" .. FILTERS[i].id), 0, 100, {"%.0f%%"})
            if filter_strength[i] and filter_strength[i].GetValue then
                local vs = filter_strength[i]:GetValue()
                if vs and vs.Set then
                    vs:Set(0)
                end
            end
            if filter_strength[i] then
                filter_strength_rows[i] = gui.MakeControl("Strength", filter_strength[i])
                ui_add_child(shader_container, filter_strength_rows[i])
            end
        end
    end

    chromatic_spread_slider = gui.Slider(gui.ControlID("shaderscs2_chromatic_spread"), 0, 200, {"%.0f%%"})
    if chromatic_spread_slider and chromatic_spread_slider.GetValue then
        local vcs = chromatic_spread_slider:GetValue()
        if vcs and vcs.Set then
            vcs:Set(100)
        end
    end
    if chromatic_spread_slider then
        chromatic_spread_row = gui.MakeControl("Chromatic spread", chromatic_spread_slider)
        ui_add_child(shader_container, chromatic_spread_row)
    end

    TONEMAP.shadows_slider = gui.Slider(gui.ControlID("shaderscs2_tonemap_shadows"), TONEMAP.SHADOWS_MIN, TONEMAP.SHADOWS_MAX, {"%.0f%%"})
    if TONEMAP.shadows_slider and TONEMAP.shadows_slider.GetValue then
        local vds = TONEMAP.shadows_slider:GetValue()
        if vds and vds.Set then
            vds:Set(TONEMAP.SHADOWS_DEFAULT)
        end
    end
    if TONEMAP.shadows_slider then
        TONEMAP.shadows_row = gui.MakeControl("Tonemap Darks", TONEMAP.shadows_slider)
        ui_add_child(shader_container, TONEMAP.shadows_row)
    end

    TONEMAP.highlights_slider = gui.Slider(gui.ControlID("shaderscs2_tonemap_highlights"), TONEMAP.HIGHLIGHTS_MIN, TONEMAP.HIGHLIGHTS_MAX, {"%.0f%%"})
    if TONEMAP.highlights_slider and TONEMAP.highlights_slider.GetValue then
        local vls = TONEMAP.highlights_slider:GetValue()
        if vls and vls.Set then
            vls:Set(TONEMAP.HIGHLIGHTS_DEFAULT)
        end
    end
    if TONEMAP.highlights_slider then
        TONEMAP.highlights_row = gui.MakeControl("Tonemap Lights", TONEMAP.highlights_slider)
        ui_add_child(shader_container, TONEMAP.highlights_row)
    end

    if gui.ColorPicker then
        vignette_tint_color = gui.ColorPicker(gui.ControlID("shaderscs2_vignette_tint"))
        if vignette_tint_color and vignette_tint_color.GetValue and draw and draw.Color then
            local vvg = vignette_tint_color:GetValue()
            if vvg and vvg.Set then
                vvg:Set(draw.Color(255, 255, 255, 0))
            end
        end
        if vignette_tint_color then
            vignette_tint_row = gui.MakeControl("Vignette outline color", vignette_tint_color)
            ui_add_child(shader_container, vignette_tint_row)
        end

        sharpen_tint_color = gui.ColorPicker(gui.ControlID("shaderscs2_sharpen_tint"))
        if sharpen_tint_color and sharpen_tint_color.GetValue and draw and draw.Color then
            local vps = sharpen_tint_color:GetValue()
            if vps and vps.Set then
                vps:Set(draw.Color(255, 255, 255, 255))
            end
        end
        if sharpen_tint_color then
            sharpen_tint_row = gui.MakeControl("Sharpening color", sharpen_tint_color)
            ui_add_child(shader_container, sharpen_tint_row)
        end

        emboss_tint_color = gui.ColorPicker(gui.ControlID("shaderscs2_emboss_tint"))
        if emboss_tint_color and emboss_tint_color.GetValue and draw and draw.Color then
            local vpe = emboss_tint_color:GetValue()
            if vpe and vpe.Set then
                vpe:Set(draw.Color(255, 255, 255, 255))
            end
        end
        if emboss_tint_color then
            emboss_tint_row = gui.MakeControl("Emboss color", emboss_tint_color)
            ui_add_child(shader_container, emboss_tint_row)
        end

        for i = 1, REPLACE_PAIR_MAX do
            local src_id = (i == 1) and "shaderscs2_accent_color" or ("shaderscs2_accent_color_" .. i)
            local tgt_id = (i == 1) and "shaderscs2_target_color" or ("shaderscs2_target_color_" .. i)

            local src_ctrl = gui.ColorPicker(gui.ControlID(src_id))
            if src_ctrl and src_ctrl.GetValue and draw and draw.Color then
                local vsrc = src_ctrl:GetValue()
                if vsrc and vsrc.Set then
                    vsrc:Set(draw.Color(60, 140, 255, 255))
                end
            end
            local src_row = src_ctrl and gui.MakeControl("Source color " .. i, src_ctrl) or nil
            ui_add_child(shader_container, src_row)

            local tgt_ctrl = gui.ColorPicker(gui.ControlID(tgt_id))
            if tgt_ctrl and tgt_ctrl.GetValue and draw and draw.Color then
                local vtgt = tgt_ctrl:GetValue()
                if vtgt and vtgt.Set then
                    vtgt:Set(draw.Color(255, 60, 60, 0))
                end
            end
            local tgt_row = tgt_ctrl and gui.MakeControl("Target color " .. i, tgt_ctrl) or nil
            ui_add_child(shader_container, tgt_row)

            replace_pairs[i] = {
                source = src_ctrl,
                source_row = src_row,
                target = tgt_ctrl,
                target_row = tgt_row
            }
        end
    end

    for i = 1, #FILTERS do
        if not FILTERS[i].is_replace then
            local disable_cb = gui.Checkbox(gui.ControlID("shaderscs2_point_disable_" .. FILTERS[i].id))
            if disable_cb and disable_cb.GetValue then
                local disable_value = disable_cb:GetValue()
                if disable_value and disable_value.Set then
                    disable_value:Set(false)
                end
            end
            local disable_row = disable_cb and gui.MakeControl("Save to point", disable_cb) or nil
            MAPS_CUSTOM_UI.shader_point_filter_checks[FILTERS[i].id] = disable_cb
            MAPS_CUSTOM_UI.shader_point_filter_rows[FILTERS[i].id] = disable_row
            ui_add_child(shader_container, disable_row)
            MAPS_CUSTOM_UI.shader_point_filter_hint_rows[FILTERS[i].id] = nil
        end
    end

    if gui.Button then
        replace_add_btn = apply_uniform_button_style(gui.Button(gui.ControlID("shaderscs2_replace_add"), "Add pair"))
        replace_add_row = replace_add_btn
        ui_add_child(shader_container, replace_add_row)

        replace_remove_btn = apply_uniform_button_style(gui.Button(gui.ControlID("shaderscs2_replace_remove"), "Delete pair"))
        replace_remove_row = replace_remove_btn
        ui_add_child(shader_container, replace_remove_row)
    end

    refresh_ui_visibility = function()
        set_row_visible(filter_combo_row, shader_ui_visible)
        if not shader_ui_visible then
            for i = 1, #FILTERS do
                set_row_visible(filter_strength_rows[i], false)
                set_row_visible(MAPS_CUSTOM_UI.shader_point_filter_rows[FILTERS[i].id], false)
                set_row_visible(MAPS_CUSTOM_UI.shader_point_filter_hint_rows[FILTERS[i].id], false)
            end
            set_row_visible(chromatic_spread_row, false)
            set_row_visible(TONEMAP.shadows_row, false)
            set_row_visible(TONEMAP.highlights_row, false)
            set_row_visible(vignette_tint_row, false)
            set_row_visible(sharpen_tint_row, false)
            set_row_visible(emboss_tint_row, false)
            set_row_visible(replace_add_row, false)
            set_row_visible(replace_remove_row, false)
            for i = 1, REPLACE_PAIR_MAX do
                local pair = replace_pairs[i]
                if pair then
                    set_row_visible(pair.source_row, false)
                    set_row_visible(pair.target_row, false)
                end
            end
            return
        end

        local selected = get_combo_index(filter_combo)
        if selected < 1 or selected > #FILTERS then
            selected = 1
        end

        for i = 1, #FILTERS do
            local show = (i == selected)
            set_row_visible(filter_strength_rows[i], show)
            if not FILTERS[i].is_replace then
                set_row_visible(MAPS_CUSTOM_UI.shader_point_filter_hint_rows[FILTERS[i].id], show)
                set_row_visible(MAPS_CUSTOM_UI.shader_point_filter_rows[FILTERS[i].id], show)
            end
        end

        set_row_visible(chromatic_spread_row, selected == CHROMATIC_FILTER_LIST_INDEX)
        set_row_visible(TONEMAP.shadows_row, selected == 9)
        set_row_visible(TONEMAP.highlights_row, selected == 9)
        set_row_visible(vignette_tint_row, selected == VIGNETTE_FILTER_LIST_INDEX)
        set_row_visible(sharpen_tint_row, selected == SHARPEN_FILTER_LIST_INDEX)
        set_row_visible(emboss_tint_row, selected == EMBOSS_FILTER_LIST_INDEX)

        local is_replace = (selected == REPLACE_FILTER_LIST_INDEX)
        set_row_visible(replace_add_row, is_replace)
        set_row_visible(replace_remove_row, is_replace)

        for i = 1, REPLACE_PAIR_MAX do
            local pair = replace_pairs[i]
            if pair then
                local show_pair = is_replace and (i <= replace_pair_count)
                set_row_visible(pair.source_row, show_pair)
                set_row_visible(pair.target_row, show_pair)
            end
        end
    end

    if replace_add_btn and replace_add_btn.AddCallback then
        replace_add_btn:AddCallback(function()
            if replace_pair_count < REPLACE_PAIR_MAX then
                replace_pair_count = replace_pair_count + 1
            end
            refresh_ui_visibility()
            ui_reset(shader_container)
        end)
    end

    if replace_remove_btn and replace_remove_btn.AddCallback then
        replace_remove_btn:AddCallback(function()
            if replace_pair_count > REPLACE_PAIR_MIN then
                replace_pair_count = replace_pair_count - 1
            end
            refresh_ui_visibility()
            ui_reset(shader_container)
        end)
    end

    if filter_combo and filter_combo.AddCallback then
        filter_combo:AddCallback(function()
            refresh_ui_visibility()
        end)
    end

    refresh_ui_visibility()
    ui_reset(shader_container)
    shader_ui_initialized = true
    return true
    end
end

-- Draw the fullscreen shader
local function shader_render_fn()
    if not shader_runtime_enabled then return end
    if not filter_combo then return end
    if not draw or not draw.surface or not draw.adapter then return end
    if not game or not game.engine then return end
    if not engine_in_game() or not engine_is_connected() then return end
    if map_change_pending_name and State.current_map and map_change_pending_name ~= State.current_map then
        set_shader_runtime_gate_state(false)
        return
    end
    if in_transition_cooldown() then
        set_shader_runtime_gate_state(false)
        return
    end
    if not runtime_loaded_map then
        set_shader_runtime_gate_state(false)
        return
    end

    local current_map = Utils.System.get_current_map()
    if not current_map or current_map == "" then return end
    if not State.current_map or current_map ~= State.current_map then return end
    if current_map ~= runtime_loaded_map then return end
    local can_render = update_shader_runtime_gate()
    if not can_render then return end

    local strengths = {}
    local has_any_enabled = false
    for i = 1, #FILTERS do
        strengths[i] = get_filter_strength(i)
        if strengths[i] > 0.001 then
            has_any_enabled = true
        end
    end
    local has_replace_enabled = false
    for pair_idx = 1, replace_pair_count do
        local pair = replace_pairs[pair_idx]
        if pair and pair.target then
            local _, _, _, ta = get_color_rgba(pair.target, 255, 60, 60, 0)
            if (tonumber(ta) or 0) > 0 then
                has_replace_enabled = true
                break
            end
        end
    end
    if not has_any_enabled and not has_replace_enabled then return end

    local layer = draw.surface
    if not layer or not layer.g then return end
    if not get_back_buffer_texture() then return end

    local w, h
    local disp = draw.GetDisplay()
    if type(disp) == "table" then
        w = (disp.x and tonumber(disp.x)) or disp[1]
        h = (disp.y and tonumber(disp.y)) or disp[2]
    end
    if not w or not h or w <= 0 or h <= 0 then
        w, h = game.engine:GetScreenSize()
    end
    if not w or not h or w <= 0 or h <= 0 then return end
    -- Important: no +1 overscan. It accumulates visible drift on multi-pass chains.
    w = math.max(1, math.floor(w + 0.5))
    h = math.max(1, math.floor(h + 0.5))

    local cmd = layer.g
    cmd.chained_call = false
    cmd.capture_back_buffer = true

    -- Pass 0: Color Replace remains dedicated.
    if has_replace_enabled then
        for pair_idx = 1, replace_pair_count do
            local pair = replace_pairs[pair_idx]
            if pair and pair.source and pair.target then
                local sr, sg, sb, sa = get_color_rgba(pair.source, 60, 140, 255, 255)
                local tr, tg, tb, ta = get_color_rgba(pair.target, 255, 60, 60, 0)
                if (tonumber(ta) or 0) <= 0 then
                    goto continue_replace_pair
                end
                local replace_shader = get_color_replace_shader(sr, sg, sb, sa)
                if replace_shader then
                    local back_tex = get_back_buffer_texture()
                    if back_tex then
                        cmd.capture_back_buffer = true
                        cmd.alpha = 1.0
                        cmd:SetShader(replace_shader)
                        cmd.texture = back_tex
                        cmd.uv_rect = draw.Rect(0, 0, 1, 1)
                        layer:AddRectFilled(draw.Rect(0, 0, w, h), draw.Color(tr, tg, tb, ta))
                    end
                end
            end
            ::continue_replace_pair::
        end
    end

    -- Pass 1: fused color pass (grayscale/grading/sepia/vignette/posterize/noir/filmic).
    local has_fused_color = (strengths[1] > 0.001) or (strengths[2] > 0.001) or (strengths[3] > 0.001) or
        (strengths[4] > 0.001) or (strengths[6] > 0.001) or (strengths[7] > 0.001) or (strengths[9] > 0.001)
    if has_fused_color then
        local vr, vg, vb, va = get_color_rgba(vignette_tint_color, 255, 255, 255, 0)
        local tonemap_state = TONEMAP.GetRaw_state()
        local fused_shader = TONEMAP.get_fused_shader({
            gray = math.floor((strengths[1] or 0) * 100.0 + 0.5),
            grading = math.floor((strengths[2] or 0) * 100.0 + 0.5),
            sepia = math.floor((strengths[3] or 0) * 100.0 + 0.5),
            vignette = math.floor((strengths[4] or 0) * 100.0 + 0.5),
            posterize = math.floor((strengths[6] or 0) * 100.0 + 0.5),
            noir = math.floor((strengths[7] or 0) * 100.0 + 0.5),
            filmic = math.floor((strengths[9] or 0) * 100.0 + 0.5),
            vig_r = vr,
            vig_g = vg,
            vig_b = vb,
            vig_a = va,
            vig_rgba_key = vr * 16777216 + vg * 65536 + vb * 256 + va,
            shadows = tonumber(tonemap_state.darks) or 0,
            lights = tonumber(tonemap_state.lights) or 0,
            has_vignette_tint = (vignette_tint_color ~= nil)
        })
        if fused_shader then
            local back_tex = get_back_buffer_texture()
            if back_tex then
                cmd.capture_back_buffer = true
                cmd.alpha = 1.0
                cmd:SetShader(fused_shader)
                cmd.texture = back_tex
                cmd.uv_rect = draw.Rect(0, 0, 1, 1)
                layer:AddRectFilled(draw.Rect(0, 0, w, h), draw.Color(255, 255, 255, 255))
            end
        end
    end

    -- Pass 1.5: keep Kuwahara as dedicated heavy filter (if user enabled).
    local kuwahara_strength = strengths[10] or 0.0
    if kuwahara_strength > 0.001 then
        local kuwahara_shader = shaders[10]
        if kuwahara_shader then
            local back_tex = get_back_buffer_texture()
            if back_tex then
                cmd.capture_back_buffer = true
                cmd.alpha = kuwahara_strength
                cmd:SetShader(kuwahara_shader)
                cmd.texture = back_tex
                cmd.uv_rect = draw.Rect(0, 0, 1, 1)
                layer:AddRectFilled(draw.Rect(0, 0, w, h), draw.Color(255, 255, 255, 255))
            end
        end
    end

    -- Pass 2: spatial filters are applied independently to avoid suppressing chromatic.
    local function run_spatial_pass(spatial_index, spatial_strength)
        if spatial_strength <= 0.001 then
            return
        end

        local spatial_shader = shaders[FILTERS[spatial_index].shader_idx]
        if not spatial_shader then
            return
        end

        local back_tex = get_back_buffer_texture()
        if not back_tex then
            return
        end

        cmd.capture_back_buffer = true
        cmd.alpha = spatial_strength
        cmd:SetShader(spatial_shader)
        cmd.texture = back_tex
        cmd.uv_rect = draw.Rect(0, 0, 1, 1)

        if spatial_index == CHROMATIC_FILTER_LIST_INDEX then
            local spread = get_chromatic_spread()
            local spread_byte = math.floor(math.max(0, math.min(255, (spread / 2.0) * 255.0)) + 0.5)
            layer:AddRectFilled(draw.Rect(0, 0, w, h), draw.Color(spread_byte, 255, 255, 255))
        elseif spatial_index == SHARPEN_FILTER_LIST_INDEX and sharpen_tint_color then
            local tr, tg, tb, ta = get_color_rgba(sharpen_tint_color, 255, 255, 255, 255)
            layer:AddRectFilled(draw.Rect(0, 0, w, h), draw.Color(tr, tg, tb, ta))
        elseif spatial_index == EMBOSS_FILTER_LIST_INDEX and emboss_tint_color then
            local tr, tg, tb, ta = get_color_rgba(emboss_tint_color, 255, 255, 255, 255)
            layer:AddRectFilled(draw.Rect(0, 0, w, h), draw.Color(tr, tg, tb, ta))
        else
            layer:AddRectFilled(draw.Rect(0, 0, w, h), draw.Color(255, 255, 255, 255))
        end
    end

    run_spatial_pass(SHARPEN_FILTER_LIST_INDEX, strengths[SHARPEN_FILTER_LIST_INDEX] or 0.0)
    run_spatial_pass(CHROMATIC_FILTER_LIST_INDEX, strengths[CHROMATIC_FILTER_LIST_INDEX] or 0.0)
    run_spatial_pass(EMBOSS_FILTER_LIST_INDEX, strengths[EMBOSS_FILTER_LIST_INDEX] or 0.0)

    cmd:SetShader(nil)
    cmd:SetTexture(nil)
    cmd.capture_back_buffer = false
    cmd.chained_call = false
    cmd.alpha = 1.0
end

-- Hook up the real draw function (the callback was added at the start: we draw first, ESP on top).
shader_render_fn_ref = shader_render_fn

local function color_to_tbl(ctrl, dr, dg, db, da)
    local r, g, b, a = get_color_rgba(ctrl, dr, dg, db, da)
    return {r, g, b, a}
end

local function set_color_from_tbl(ctrl, t)
    if not ctrl or not ctrl.GetValue or type(t) ~= "table" then return end
    local v = ctrl:GetValue()
    if not v or not v.Set then return end
    local r = tonumber(t[1]) or 255
    local g = tonumber(t[2]) or 255
    local b = tonumber(t[3]) or 255
    local a = tonumber(t[4]) or 255
    v:Set(draw.Color(r, g, b, a))
end

local function get_shader_global_state()
    local strengths = {}
    for i = 1, #FILTERS do
        if not FILTERS[i].is_replace then
            strengths[i] = get_slider_value(filter_strength[i], 0)
        end
    end
    return {
        strengths = strengths,
        chromatic_spread = get_slider_value(chromatic_spread_slider, 100),
        tonemap = TONEMAP.GetRaw_state(),
        vignette_tint = color_to_tbl(vignette_tint_color, 255, 255, 255, 0),
        sharpen_tint = color_to_tbl(sharpen_tint_color, 255, 255, 255, 255),
        emboss_tint = color_to_tbl(emboss_tint_color, 255, 255, 255, 255)
    }
end

local function apply_shader_global_state(data)
    if type(data) ~= "table" then return end
    local strengths = data.strengths
    if type(strengths) == "table" then
        for i = 1, #FILTERS do
            if not FILTERS[i].is_replace and filter_strength[i] and filter_strength[i].GetValue then
                local v = filter_strength[i]:GetValue()
                if v and v.Set then
                    v:Set(tonumber(strengths[i]) or 0)
                end
            end
        end
    end
    if chromatic_spread_slider and chromatic_spread_slider.GetValue then
        local v = chromatic_spread_slider:GetValue()
        if v and v.Set then
            v:Set(tonumber(data.chromatic_spread) or 100)
        end
    end
    TONEMAP.apply_raw_state(data.tonemap)
    set_color_from_tbl(vignette_tint_color, data.vignette_tint)
    set_color_from_tbl(sharpen_tint_color, data.sharpen_tint)
    set_color_from_tbl(emboss_tint_color, data.emboss_tint)
end

local function get_replace_state()
    local pairs = {}
    for i = 1, replace_pair_count do
        local p = replace_pairs[i]
        if p then
            pairs[i] = {
                source = color_to_tbl(p.source, 60, 140, 255, 255),
                target = color_to_tbl(p.target, 255, 60, 60, 0)
            }
        end
    end
    return {
        pair_count = replace_pair_count,
        pairs = pairs
    }
end

local function apply_replace_state(data)
    if type(data) ~= "table" then return end

    local n = tonumber(data.pair_count) or 1
    n = math.max(REPLACE_PAIR_MIN, math.min(REPLACE_PAIR_MAX, math.floor(n + 0.5)))
    replace_pair_count = n

    if type(data.pairs) == "table" then
        for i = 1, REPLACE_PAIR_MAX do
            local pair = data.pairs[i]
            local p = replace_pairs[i]
            if p and pair then
                set_color_from_tbl(p.source, pair.source)
                set_color_from_tbl(p.target, pair.target)
            end
        end
    end

    refresh_ui_visibility()
end

local function set_shader_strength(filter_id, value)
    if type(filter_id) ~= "string" then return end
    local target_index = nil
    for i = 1, #FILTERS do
        if FILTERS[i].id == filter_id then
            target_index = i
            break
        end
    end
    if not target_index then return end
    local ctrl = filter_strength[target_index]
    if not ctrl or not ctrl.GetValue then return end
    local v = ctrl:GetValue()
    if v and v.Set then
        v:Set(tonumber(value) or 0)
    end
end

local function set_shader_runtime_enabled(enabled)
    shader_runtime_enabled = (enabled == true)
    if not shader_runtime_enabled then
        set_shader_runtime_gate_state(false)
    end
end

local function get_shader_runtime_enabled()
    return shader_runtime_enabled == true
end

local function set_shader_ui_visibility(visible)
    shader_ui_visible = (visible == true)
    refresh_ui_visibility()
end

is_shader_point_filter_enabled = function(filter_id)
    if type(filter_id) ~= "string" or filter_id == "" then
        return false
    end

    local checks = MAPS_CUSTOM_UI and MAPS_CUSTOM_UI.shader_point_filter_checks
    local ctrl = checks and checks[filter_id] or nil
    if ctrl and ctrl.GetValue then
        local v = ctrl:GetValue()
        if v and v.Get then
            return v:Get() == true
        end
    end

    return false
end

_cm_shader_filter_from_key = function(key)
    if type(key) ~= "string" then
        return nil
    end
    local strength_filter = key:match("^shader_strength_(.+)$")
    if strength_filter then
        return strength_filter
    end
    if key == "shader_vignette_tint" then return "vignette" end
    if key == "shader_sharpen_tint" then return "sharpen" end
    if key == "shader_emboss_tint" then return "emboss" end
    if key == "shader_chromatic_spread" then return "chromatic" end
    if key == "shader_tonemap_darks" or key == "shader_tonemap_lights" then return "filmic" end
    return nil
end

should_include_shader_key_in_points = function(key)
    local filter_id = _cm_shader_filter_from_key(key)
    if not filter_id then
        return true
    end
    return is_shader_point_filter_enabled(filter_id)
end

local SHADER_RUNTIME = {
    get_global_state = get_shader_global_state,
    apply_global_state = apply_shader_global_state,
    get_replace_state = get_replace_state,
    apply_replace_state = apply_replace_state,
    set_strength = set_shader_strength,
    refresh_ui_visibility = refresh_ui_visibility,
    set_enabled = set_shader_runtime_enabled,
    get_enabled = get_shader_runtime_enabled,
    set_ui_visibility = set_shader_ui_visibility,
    is_point_filter_enabled = is_shader_point_filter_enabled,
    -- Compatibility aliases used by older bridge calls.
    GetGlobal_state = get_shader_global_state,
    ApplyGlobal_state = apply_shader_global_state,
    GetReplace_state = get_replace_state,
    ApplyReplace_state = apply_replace_state,
    GetPointFilterEnabled = is_shader_point_filter_enabled
}
-- Compat: allows old standalone shaderscs2.lua guard to detect merged runtime.
COLORED_MAPS_SHADER_API = SHADER_RUNTIME











-- ===== merged shaderscs2 into this script =====

-- ============================================
-- Colored Maps + Points System
-- Combined script with map settings + point-based color blending
-- ============================================




-- OPTIMIZATION: Localize standard library functions for performance
local math_floor = math.floor
local math_sqrt = math.sqrt
local math_min = math.min
local math_max = math.max
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort
local string_format = string.format

-- ========== CONSTANTS ==========
local CONSTANTS = {
    FILES = {
        COMBINED = CM_CFG_DIR .. "/colored_maps_unified.json",
        -- Dedicated, deterministic storage root for this script. All paths in the
        -- Fatality file API are relative to game/csgo, so there is exactly one
        -- canonical location -- no candidate-path hunting needed.
        PROFILES_ROOT = "fatality/map_manager",
        PROFILES_DIR = "fatality/map_manager/profiles",
        PROFILES_STATE = "fatality/map_manager/active_profile.json",
        PROFILES_INDEX = "fatality/map_manager/profiles_index.json",
        -- Old locations where profile .json files used to live; scanned once on
        -- startup to migrate them into PROFILES_DIR.
        PROFILES_LEGACY_DIRS = { "fatality", "fatality/scripts" },
        -- Kept for backwards compatibility with any remaining references.
        PROFILES_DIR_LEGACY = "fatality/scripts",
        PROFILE_MARKER_KEY = "__cm_profile_marker",
        PROFILE_MARKER_VALUE = "colored_maps_points_weight_profile_v1",
        PROFILE_DEFAULT = "default",
        PROFILE_OLD_DEFAULT = "old_default",
        LEGACY_MIGRATED_KEY = "__cm_legacy_migrated",
        LEGACY_MIGRATED_PROFILE_KEY = "__cm_legacy_target_profile",
        LEGACY_MIGRATED_AT_KEY = "__cm_legacy_migrated_at",
        LEGACY_MIGRATED_BY_KEY = "__cm_legacy_migrated_by"
    },
    PATHS = {
        env_enabled = "visuals>world>environment>enabled",
        sky = "visuals>world>environment>sky",
        world_color = "visuals>world>environment>world color",
        lights_color = "visuals>world>environment>lights color",
        sky_color = "visuals>world>environment>sky color",
        cloud_color = "visuals>world>environment>cloud color",
        sun_color = "visuals>world>environment>sun color",
        dof = "visuals>world>environment>dof",
        dof_strength = "visuals>world>environment>dof>strength",
        dof_far_start = "visuals>world>environment>dof>far start",
        dof_far_end = "visuals>world>environment>dof>far end",
        dof_near_start = "visuals>world>environment>dof>near start",
        dof_near_end = "visuals>world>environment>dof>near end",
        fog = "visuals>world>environment>fog",
        fog_color = "visuals>world>environment>fog>settings>color",
        fog_distance = "visuals>world>environment>fog>settings>distance",
        fog_size = "visuals>world>environment>fog>settings>size",
        thirdperson = "visuals>misc>local>thirdperson",
        exposure = "visuals>world>environment>exposure",
        -- Skybox combobox (1-6)
        skybox = "visuals>world>environment>skybox"
    },
    KEYS = {
        COLOR = {"world_color", "lights_color", "sky_color", "cloud_color", "sun_color", "fog_color"},
        SLIDER = {"dof_strength", "dof_far_start", "dof_far_end", "dof_near_start", "dof_near_end", "fog_distance", "fog_size", "exposure"},
        BOOL = {"dof", "fog"},
        MIRROR_BOOL = {"env_enabled", "sky", "dof", "fog"}
    },
    SHADERS = {
        -- Match filter ids/indexes from shaderscs2.lua FILTERS (excluding replace for point blending).
        FILTERS = {
            {id = "grayscale", index = 1},
            {id = "grading", index = 2},
            {id = "sepia", index = 3},
            {id = "vignette", index = 4},
            {id = "sharpen", index = 5},
            {id = "posterize", index = 6},
            {id = "noir", index = 7},
            {id = "chromatic", index = 8},
            {id = "filmic", index = 9},
            {id = "kuwahara", index = 10},
            {id = "emboss", index = 11}
        },
        COLOR_KEYS = {"shader_vignette_tint", "shader_sharpen_tint", "shader_emboss_tint"},
        SLIDER_KEYS = {
            "shader_strength_grayscale",
            "shader_strength_grading",
            "shader_strength_sepia",
            "shader_strength_vignette",
            "shader_strength_sharpen",
            "shader_strength_posterize",
            "shader_strength_noir",
            "shader_strength_chromatic",
            "shader_strength_filmic",
            "shader_strength_kuwahara",
            "shader_strength_emboss",
            "shader_chromatic_spread",
            "shader_tonemap_darks",
            "shader_tonemap_lights"
        }
    },
    DEFAULTS = {
        VERSION = 3,
        WEIGHT = 5,
        TRANSITION_SPEED = 3.0,
        POINTS = {
            ["de_anubis"] = {
                points = {
                    {x = -144.0, y = -1568.0, z = -11.96875}
                }
            },
            ["de_dust2"] = {
                points = {
                    {x = -787.0775756835938, y = -825.4578247070313, z = 116.66852569580078},
                    {x = 628.5068359375, y = 584.0504760742188, z = 0.9780545234680176},
                    {x = 1374.15478515625, y = 1414.484619140625, z = -8.10430908203125},
                    {x = -236.242919921875, y = 1135.772216796875, z = 32.052886962890625},
                    {x = 405.26849365234375, y = 1860.0238037109375, z = 95.4245834350586},
                    {x = 1148.3167724609375, y = 2615.631591796875, z = 96.55523681640625},
                    {x = -1802.8389892578125, y = 1174.0577392578125, z = 32.37209701538086},
                    {x = -806.34765625, y = 1444.736572265625, z = -112.1845703125},
                    {x = -1595.3634033203125, y = 2757.17626953125, z = 65.03125}
                }
            },
            ["de_inferno"] = {
                points = {
                    {x = -1601.6868896484375, y = 460.613037109375, z = -63.96875},
                    {x = -649.669921875, y = 673.563232421875, z = -31.7540283203125},
                    {x = 158.8937225341797, y = 1292.4676513671875, z = 96.68697357177734},
                    {x = 495.8374328613281, y = 556.0774536132813, z = 86.49700927734375},
                    {x = 2080.214599609375, y = 334.1875, z = 160.03125},
                    {x = 452.61492919921875, y = 3352.557861328125, z = 161.8428192138672},
                    {x = 2357.73876953125, y = 2139.056396484375, z = 132.2719268798828},
                    {x = 1711.1287841796875, y = -349.392578125, z = 256.03125},
                    {x = -24.8333740234375, y = -149.450439453125, z = 43.120914459228516},
                    {x = 359.242431640625, y = 2622.156494140625, z = 193.03125}
                }
            },
            ["de_mirage"] = {
                points = {
                    {x = -456.056640625, y = -2229.344970703125, z = -175.2293701171875},
                    {x = -2047.7166748046875, y = 262.5664978027344, z = -159.96875},
                    {x = -372.50262451171875, y = -591.1959228515625, z = -272.86962890625},
                    {x = 1248.9012451171875, y = -85.06854248046875, z = -167.96875},
                    {x = -1700.548828125, y = -1875.475341796875, z = -268.169677734375},
                    {x = 582.7745361328125, y = -2099.268798828125, z = -39.96875},
                    {x = -332.0692138671875, y = 640.8358154296875, z = -79.60748291015625},
                    {x = -943.0810546875, y = 226.2589874267578, z = -172.13848876953125}
                }
            },
            ["de_vertigo"] = {
                points = {
                    {x = -1434.9276123046875, y = -1257.415283203125, z = 11488.03125},
                    {x = -2410.21142578125, y = -696.3462524414063, z = 11776.03125},
                    {x = -2338.633544921875, y = 882.51904296875, z = 11744.03125},
                    {x = -994.336669921875, y = 847.406005859375, z = 11776.03125},
                    {x = -792.93701171875, y = -684.0889892578125, z = 11776.03125},
                    {x = -743.4915161132813, y = -279.8135986328125, z = 11488.03125}
                }
            }
        }
    }
}

-- ========== STATE ==========
State = {
    combined_config = nil,
    config = nil,
    points_config = nil,
    weights_config = nil,
    shaders_config = nil,
    current_map = nil,
    map_entry_settings = nil,
    next_point_id = 1,
    weights_dirty = false,
    shader_points_enabled = false,
    
    -- Intro message
    intro = {
        should_show = false,
        start_time = 0,
        duration = 8.0  -- Show for 8 seconds
    },
    
    -- Smooth Transition
    transition = {
        current = nil,
        target = nil,
        speed = 3.0, -- Init with default
        restore_speed_at = 0,
        one_shot_target = nil,
        one_shot_apply_shader_state = nil,
        one_shot_active_until = 0
    },
    
    -- Runtime Helpers (periodic-task timers)
    timers = {
        last_time = 0,
        last_weight_time = 0,
        last_config_reload_time = 0
    },
    cache = {
        last_camera_pos = nil,
        render_lines_was_enabled = false,
        last_map_check_time = 0,
        last_active_points = nil,
        last_active_weights = nil,
        last_current_blended = nil
    },
    shaders_runtime = {
        bootstrapped = false,
        last_sync_time = 0,
        last_replace_hash = "",
        last_replace_map = nil,
        last_replace_live_hash = "",
        replace_changed_at = 0,
        replace_pending = false,
        last_global_map = nil,
        last_global_live_hash = "",
        global_changed_at = 0,
        global_pending = false
    },
    profiles = {
        active_name = "default",
        list = {},
        option_ids = {},
        ui_syncing = false,
        draft_name = "",
        import_conflict = nil,
        trace_enabled = false,
        trace_reason = ""
    }
}

-- ========== UTILS ==========
Utils = {
    UI = {},
    Math = {},
    System = {},
    File = {},
    Config = {}
}

-- forward declarations for shader helpers (used in capture/apply settings)
local capture_current_shader_settings
local apply_shader_settings

-- ========== CONFIG MANAGER ==========
function Utils.Config.set_trace(active, reason)
    if type(State.profiles) ~= "table" then
        State.profiles = {}
    end
    State.profiles.trace_enabled = (active == true)
    State.profiles.trace_reason = tostring(reason or "")
end

function Utils.Config.is_trace_enabled()
    return type(State.profiles) == "table" and State.profiles.trace_enabled == true
end

function Utils.Config.log(message, force)
    if not DEBUG_DIAGNOSTICS_ENABLED then
        return
    end
    if not force and not (CM_FORCE_VERBOSE_TXT_LOG) and not Utils.Config.is_trace_enabled() then
        return
    end
    local line = "[CMAP][CFG] " .. tostring(message)
    crash_log(line)
end

-- A path is a profile file when it is a .json directly inside the dedicated
-- profiles directory and is not one of the reserved bookkeeping files (those
-- live one level up, so they are excluded automatically). Reserved/underscore
-- names are rejected defensively.
function Utils.Config.path_looks_like_profile(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    local norm = path:gsub("\\", "/"):lower()
    if norm:sub(-5) ~= ".json" then
        return false
    end

    local dir = CONSTANTS.FILES.PROFILES_DIR:gsub("\\", "/"):lower()
    local prefix = dir .. "/"
    if norm:sub(1, #prefix) ~= prefix then
        return false
    end

    -- Must be a file directly in the profiles dir (no further subdirectories).
    local basename = norm:sub(#prefix + 1)
    if basename == "" or basename:find("/") then
        return false
    end
    if basename:sub(1, 1) == "_" or basename:sub(1, 1) == "." then
        return false
    end

    return true
end

function Utils.Config.is_profile_payload(data)
    if type(data) ~= "table" then
        return false
    end
    local key = CONSTANTS.FILES.PROFILE_MARKER_KEY
    local value = CONSTANTS.FILES.PROFILE_MARKER_VALUE
    return data[key] == value and type(data.snapshot) == "table"
end

function Utils.Config.make_profile_payload(profile_name, snapshot)
    local payload = {}
    payload[CONSTANTS.FILES.PROFILE_MARKER_KEY] = CONSTANTS.FILES.PROFILE_MARKER_VALUE
    payload.kind = "cmap_profile_file"
    payload.version = 1
    payload.script = "colored maps+points+weight"
    payload.profile_name = Utils.Config.sanitize_profile_name(profile_name) or CONSTANTS.FILES.PROFILE_DEFAULT
    payload.snapshot = normalize_combined_config(snapshot or make_default_combined_config())
    return payload
end

function Utils.Config.extract_profile_payload(data)
    if Utils.Config.is_profile_payload(data) then
        return normalize_combined_config(data.snapshot), true
    end

    return nil, false
end

function Utils.Config.is_legacy_profile_snapshot(data)
    if type(data) ~= "table" then
        return false
    end
    return type(data.config) == "table"
        or type(data.points) == "table"
        or type(data.weights) == "table"
        or type(data.shaders) == "table"
end

function Utils.Config.try_migrate_profile_file(path, profile_name)
    local resolved = Utils.Config.find_existing_path(path) or path
    local raw = Utils.File.load_json(resolved)
    if type(raw) ~= "table" then
        return false
    end

    if Utils.Config.is_profile_payload(raw) then
        return true
    end

    if not Utils.Config.is_legacy_profile_snapshot(raw) then
        return false
    end

    local name = Utils.Config.sanitize_profile_name(profile_name)
    if not name then
        local file_name = tostring(resolved):gsub("\\", "/"):match("([^/]+)%.json$")
        name = Utils.Config.sanitize_profile_name(file_name)
    end
    name = name or CONSTANTS.FILES.PROFILE_DEFAULT

    local payload = Utils.Config.make_profile_payload(name, normalize_combined_config(raw))
    local ok = Utils.File.save_json(resolved, payload)
    if ok then
        Utils.Config.log("migrated legacy profile to marker format: " .. tostring(resolved), true)
        return true
    end

    return false
end

function Utils.Config.read_profile_file_snapshot(path)
    local resolved = Utils.Config.find_existing_path(path) or path
    local raw = Utils.File.load_json(resolved)
    if type(raw) ~= "table" then
        return nil, false
    end
    return Utils.Config.extract_profile_payload(raw)
end

function Utils.Config.is_profile_file_by_marker(path)
    local resolved = Utils.Config.find_existing_path(path) or path
    local raw = Utils.File.read(resolved)
    local text = nil

    if type(raw) == "string" then
        text = raw
    elseif raw ~= nil and utils and utils.ArrayToString then
        local ok_str, str = protected_call(utils.ArrayToString, raw)
        if ok_str and type(str) == "string" then
            text = str
        end
    end

    if type(text) ~= "string" or text == "" then
        return false
    end

    if text:find("\"" .. tostring(CONSTANTS.FILES.PROFILE_MARKER_KEY) .. "\"", 1, true)
        and text:find(tostring(CONSTANTS.FILES.PROFILE_MARKER_VALUE), 1, true) then
        return true
    end

    return false
end

-- Paths are deterministic (relative to game/csgo), so there is exactly one
-- canonical form. These helpers are kept for the existing callers but no longer
-- fan out across ./ ../ and slash variants.
function Utils.Config.normalize_path(path)
    if type(path) ~= "string" then
        return ""
    end
    return (path:gsub("\\", "/"))
end

function Utils.Config.candidate_paths(path)
    local norm = Utils.Config.normalize_path(path)
    if norm == "" then
        return {}
    end
    return { norm }
end

function Utils.Config.candidate_dirs(raw_dir)
    local norm = Utils.Config.normalize_path(raw_dir):gsub("/+$", "")
    if norm == "" then
        return {}
    end
    return { norm }
end

function Utils.Config.find_existing_path(path)
    local norm = Utils.Config.normalize_path(path)
    if norm ~= "" and Utils.File.exists(norm) then
        return norm
    end
    return nil
end

-- Writes JSON to a single canonical path. Profile files are wrapped in the
-- marker payload (name derived from the file name); everything else is stored
-- verbatim.
function Utils.Config.save(path, data)
    local norm = Utils.Config.normalize_path(path)
    if norm == "" then
        return false
    end

    local payload_data = data
    if Utils.Config.path_looks_like_profile(norm) then
        local file_name = norm:match("([^/]+)%.json$")
        local profile_name = Utils.Config.name_from_basename(file_name)
            or Utils.Config.sanitize_profile_name(file_name)
            or Utils.Config.GetActive_profile_name()
        payload_data = Utils.Config.make_profile_payload(profile_name, normalize_combined_config(data))
    end

    local ok = Utils.File.save_json(norm, payload_data)
    Utils.Config.log("save path=" .. tostring(norm) .. " ok=" .. tostring(ok))
    return ok
end

function Utils.Config.load(path, default_data)
    local norm = Utils.Config.normalize_path(path)
    if norm == "" or not Utils.File.exists(norm) then
        return default_data
    end

    local data = Utils.File.load_json(norm)
    if Utils.Config.path_looks_like_profile(norm) then
        local snapshot, tagged = Utils.Config.extract_profile_payload(data)
        if snapshot and tagged then
            return snapshot
        end
        Utils.Config.log("load skipped non-profile json path=" .. tostring(norm), true)
        return default_data
    end

    if type(data) == "table" then
        return data
    end
    return default_data
end


-- ========== UI ==========
local UI = {
    main = {
        expand_checkbox = nil,
        manager_visible = true,
        profile_expand_checkbox = nil,
        warning_label = nil,
        save_button = nil,
        group_a = nil,
        profile_combo = nil,
        profile_name_input = nil,
        profile_create_button = nil,
        profile_refresh_button = nil,
        profile_export_button = nil,
        profile_import_button = nil,
        profile_import_conflict_row = nil,
        profile_import_conflict_label = nil,
        profile_import_overwrite_button = nil,
        profile_import_rename_button = nil,
        profile_open_folder_button = nil,
        cfg_hint_label = nil
    },
    checkboxes = {
        dbg = nil,
        auto_update = nil,
        enable_shaders = nil,
        enable_points = nil,
        enable_settings = nil,
        save_shaders_in_point = nil,
        enable_shader_points = nil,
        render_points = nil,
        render_influence = nil,
        render_lines = nil,
        enable_weight = nil,
        render_weight = nil,
        mirage_preset = nil,
        local_chams = nil
    },
    sliders = {
        cutoff = nil,
        max_points = nil,

        weight = nil
    },
    buttons = {
        profile_create = nil,
        profile_refresh = nil,
        profile_export = nil,
        profile_import = nil,
        profile_import_overwrite = nil,
        profile_import_rename = nil,
        profile_open_folder = nil,
        save_point = nil,
        delete_point = nil,
        add_standard = nil,
        add_preset = nil,
        create_points = nil,
        new_point = nil,
        refresh = nil
    },
    rows = {
        warning_label = nil,
        profile_expand = nil,
        profile_combo = nil,
        profile_name = nil,
        cfg_hint = nil,
        dbg = nil,
        auto_update = nil,
        enable_shaders = nil,
        enable_points = nil,
        enable_settings = nil,
        save_shaders_in_point = nil,
        enable_shader_points = nil,
        render_points = nil,
        render_influence = nil,
        render_lines = nil,
        enable_weight = nil,
        render_weight = nil,
        mirage_preset = nil,
        local_chams = nil,
        cutoff = nil,
        max_points = nil,
        weight = nil,
        weight = nil,

        -- autosave_row handled by save button logic
    },
    shader_points = {
        hint_rows = {},
        strength_sliders = {},
        strength_rows = {},
        chromatic_slider = nil,
        chromatic_row = nil,
        tonemap_darks_slider = nil,
        tonemap_darks_row = nil,
        tonemap_lights_slider = nil,
        tonemap_lights_row = nil,
        vignette_color = nil,
        vignette_row = nil,
        sharpen_color = nil,
        sharpen_row = nil,
        emboss_color = nil,
        emboss_row = nil,
        syncing = false
    },
    cache = {}, -- Cache for UI controls
    visibility_cache = {}
}

CUSTOM_SKY_DEFAULT_ENTRY = CUSTOM_SKY_DEFAULT_ENTRY or "default"
CUSTOM_SKY_PAGE_SIZE = CUSTOM_SKY_PAGE_SIZE or 40
CUSTOM_SKY_ENABLE_APPLY_DELAY = CUSTOM_SKY_ENABLE_APPLY_DELAY or 0.05
-- Seconds after a skybox swap to fire the delayed colour BAKE (UpdateSkybox re-resolve),
-- by which point the new sky's render instances exist. Bump it if a freshly switched skybox
-- still shows its default colour.
CUSTOM_SKY_COLOR_BAKE_DELAY = 0.7

CUSTOM_SKY_PANEL = CUSTOM_SKY_PANEL or {
    enabled = false,
    selected = CUSTOM_SKY_DEFAULT_ENTRY,
    last_standard_index = 1,
    scanned = {},
    filtered = {},
    page_items = {},
    page_current = 1,
    page_total = 1,
    list_objects = {},
    page_objects = {},
    syncing = false,
    page_syncing = false,
    list_syncing = false,
    controls = {
        enable = nil,
        search = nil,
        page = nil,
        list = nil,
        download_github = nil,
        open_folder = nil,
        rescan = nil
    },
    rows = {
        enable = nil,
        search = nil,
        page = nil,
        list = nil,
        download_github = nil,
        open_folder = nil,
        rescan = nil
    },
    search_text = "",
    last_missing_notice = "",
    scan_requested = false,
    scan_completed = false,
    scan_started_at = 0,
    scan_delay = 0.6,
    color_bake_at = 0,
    notify_saved_at = 0,
    pending_enable_apply_at = 0,
    pending_enable_notify_missing = false
}

CUSTOM_SKY_RUNTIME = CUSTOM_SKY_RUNTIME or {
    build = "embedded_runtime_v1",
    available = false,
    selected = CUSTOM_SKY_DEFAULT_ENTRY,
    material_system = nil,
    resource_system = nil,
    original_state = nil,
    last_applied_key = nil,
    pending_tint_refreshes = 0,
    loaded_material_cache = {},
    resource_preload_cache = {},
    skybox_manifest = nil,
    update_skybox_addr = nil
}

CM_SKYBOX_DOWNLOAD_STATE = CM_SKYBOX_DOWNLOAD_STATE or {
    active = false,
    queue = {},
    total = 0,
    downloaded = 0,
    skipped = 0,
    failed = {},
    manifest_done = false,
    in_flight = false,
    pending_result = nil,
    http_get = nil,
    session_id = 0,
    download_goal = 0
}

do
local CM_SKYBOX_DIR = "materials/skybox"
local CM_SKYBOX_BUNDLE_MANIFEST = "manifest.json"
CM_SKYBOX_GITHUB = CM_SKYBOX_GITHUB or {
    owner = "Garagoro",
    repo = "skyboxes",
    tag = "v1.0.0",
    local_manifest_path = CM_CFG_DIR .. "/" .. CM_SKYBOX_BUNDLE_MANIFEST
}
CM_SKYBOX_GITHUB.release_url = "https://github.com/" .. CM_SKYBOX_GITHUB.owner .. "/" .. CM_SKYBOX_GITHUB.repo .. "/releases/tag/" .. CM_SKYBOX_GITHUB.tag
CM_SKYBOX_GITHUB.download_base = "https://github.com/" .. CM_SKYBOX_GITHUB.owner .. "/" .. CM_SKYBOX_GITHUB.repo .. "/releases/download/" .. CM_SKYBOX_GITHUB.tag
CM_SKYBOX_GITHUB.manifest_url = CM_SKYBOX_GITHUB.download_base .. "/" .. CM_SKYBOX_BUNDLE_MANIFEST
local CM_FALLBACK_SKYBOXES = {
    "amethyst.vmat_c", "armagedon.vmat_c", "aurora.vmat_c", "aurora_borealis.vmat_c", "aurora_skybox.vmat_c",
    "aurora01.vmat_c", "black_planet.vmat_c", "blood1.vmat_c", "cern.vmat_c", "cruel_night_ovl_hq.vmat_c",
    "csgo_night02.vmat_c", "csgo_night02b.vmat_c", "descent.vmat_c", "dreamy_ocean.vmat_c", "extreme_glaciation.vmat_c",
    "glorious_morning.vmat_c", "gravity.vmat_c", "gravity_night.vmat_c", "grimm_night.vmat_c", "mars_like01.vmat_c",
    "mpa100.vmat_c", "mpa112.vmat_c", "mpa19.vmat_c", "mr_04.vmat_c", "mr_21.vmat_c", "mr_58.vmat_c",
    "nibiru_bl.vmat_c", "northern_lights.vmat_c", "other_world.vmat_c", "persistent_fog.vmat_c", "pink.vmat_c",
    "pinkworld.vmat_c", "polluted_atm.vmat_c", "rainbow_sky.vmat_c", "retro_sun.vmat_c", "satara_night_4k.vmat_c",
    "sky_79.vmat_c", "sky_chess2.vmat_c", "sky051.vmat_c", "sky081.vmat_c", "sky091.vmat_c", "sky100.vmat_c",
    "sky105.vmat_c", "sky131.vmat_c", "sky149.vmat_c", "sky188.vmat_c", "sky56.vmat_c", "sky561.vmat_c",
    "space_18.vmat_c", "starrynight.vmat_c", "toxic_atm.vmat_c", "universe.vmat_c", "vaporwave.vmat_c", "windows.vmat_c"
}
-- ===== C_EnvSky / C_EnvCubemapFog schema offsets (current client.dll build) =====
-- These hardcoded values match the live build; cm_resolve_runtime_schema_offsets()
-- re-derives them from the entity schema on every apply so they self-correct after a
-- game update (a wrong material offset corrupts the entity and crashes ~seconds later).
-- Kept GLOBAL so the schema resolver can reassign them without upvalue-scope concerns.
CM_ENVSKY_MATERIAL_OFFSET = 0xCC8
CM_ENVSKY_MATERIAL_LIGHTING_OFFSET = 0xCD0
CM_ENVSKY_START_DISABLED_OFFSET = 0xCD8
CM_ENVSKY_TINT_OFFSET = 0xCD9
CM_ENVSKY_TINT_LIGHTING_ONLY_OFFSET = 0xCDD
CM_ENVSKY_BRIGHTNESS_OFFSET = 0xCE4
CM_ENVSKY_ENABLED_OFFSET = 0xCFC
CM_ENVSKY_TINT_REFRESH_PASSES = 8
CM_ENVCUBEMAPFOG_ACTIVE_OFFSET = 0x56C
CM_ENVCUBEMAPFOG_START_DISABLED_OFFSET = 0x56D
CM_ENVCUBEMAPFOG_SKY_MATERIAL_OFFSET = 0x578
CM_ENVCUBEMAPFOG_FOG_TEXTURE_OFFSET = 0x588
CM_ENTITYINSTANCE_IDENTITY_OFFSET = 0x10
CM_ENTITYIDENTITY_WORLDGROUP_OFFSET = 0x38
CM_SKYCAMERA_SKYBOXDATA_OFFSET = 0x548
CM_BASEPLAYERPAWN_SKYBOX3D_OFFSET = 0x11B8
CM_SKY3D_WORLDGROUP_OFFSET = 0x88
-- Live sky-render instance pointers on C_EnvSky (main + lighting). The resolved sky color
-- is written straight here (+0xE8/+0xEC/+0xF0) for smooth per-frame tint without an
-- UpdateSkybox bake (baking per color-tick grows the sky render vector -> UAF crash).
-- C_EnvSky instance pointers: the engine sky-color updater FUN_18027c2e0 stores color at
-- *(env_sky+0x1000)+0xE8 / *(env_sky+0x1008)+0xE8. Writing at a stale offset hits a different
-- object -> memory corruption/crash + no visible recolor.

CM_ENVSKY_INSTANCE_OFFSETS = { 0x1000, 0x1008 }
-- C_EnvSky::UpdateSkybox entry signature for the current client.dll. The pattern lands on
-- the function entry directly, so no prologue backtrack is needed anymore.
CM_UPDATE_SKYBOX_PATTERNS = {
    "48 89 5C 24 08 57 48 83 EC 30 48 8B F9 E8 ? ? ? ? 48 8B 47 10"
}

if ffi then
    protected_call(ffi.cdef, [[
        typedef unsigned long long uintptr_t;
        typedef int BOOL;
        void* __stdcall ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int nShowCmd);
        typedef void* (__cdecl *InstantiateInterfaceFn_t)();
        typedef struct CInterfaceRegister {
            InstantiateInterfaceFn_t fnCreate;
            const char* szName;
            struct CInterfaceRegister* pNext;
        } CInterfaceRegister;
        typedef struct {
            int nCount;
            int pad_0x04;
            const char** ppPaths;
            unsigned char bAllowBlocking;
            unsigned char nLoadFlag;
            unsigned char pad_0x12[6];
            void* pContext;
            unsigned char nBehavior;
            unsigned char pad_0x21[7];
            void* pCallback;
            void* pCallbackUserData;
        } ResourceLoadRequest_t;
        BOOL __stdcall IsBadReadPtr(const void* lp, uintptr_t ucb);
    ]])
end

local function cm_ptr_to_u64(ptr)
    if ptr == nil then return 0 end
    if type(ptr) == "number" then return ptr end
    local s = tostring(ptr)
    local hex = s:match("0[xX]([0-9A-Fa-f]+)")
    if hex then
        return tonumber(hex, 16) or 0
    end
    local dec = s:match(": (%d+)$")
    if dec then
        return tonumber(dec) or 0
    end
    return 0
end

local function cm_is_valid_ptr(ptr)
    return cm_ptr_to_u64(ptr) > 0x10000
end

-- Tracks which offsets were re-derived from the live entity schema this build; the apply
-- path refuses to write the material handle unless m_hSkyMaterial came from the schema.
CM_SCHEMA_RESOLVED = CM_SCHEMA_RESOLVED or {}

local cm_kernel32 = nil
local function cm_get_kernel32()
    if cm_kernel32 ~= nil then
        return cm_kernel32
    end
    if not ffi then
        return nil
    end
    -- ffi.load may be locked down in the sandbox; guarded, and callers degrade gracefully.
    local ok, lib = protected_call(ffi.load, "kernel32")
    if ok then
        cm_kernel32 = lib
    end
    return cm_kernel32
end

-- Guarded readability probe. If kernel32/IsBadReadPtr is unavailable we optimistically
-- return true -- every caller still routes the actual dereference through protected_call,
-- so a bad pointer is contained instead of crashing.
local function cm_is_readable_ptr(ptr, size)
    if not cm_is_valid_ptr(ptr) then
        return false
    end
    local lib = cm_get_kernel32()
    if not lib then
        return true
    end
    local ok, bad = protected_call(function()
        return lib.IsBadReadPtr(ffi.cast("const void*", ptr), size or 8)
    end)
    if not ok then
        return false
    end
    return bad == 0
end

-- sRGB(0..255) -> linear, byte-for-byte the same as client FUN_1815df420.
local function cm_srgb_lin(x)
    local c = (tonumber(x) or 0) / 255.0
    if c <= 0.04045 then
        return c / 12.92
    end
    return ((c + 0.055) / 1.055) ^ 2.4
end

local function cm_schema_accessor_offset(obj, field_name)
    if obj == nil then
        return nil
    end
    local ok_acc, accessor = protected_call(function()
        return obj[field_name]
    end)
    if not ok_acc or accessor == nil then
        return nil
    end
    local ok_off, offset = protected_call(function()
        return accessor.offset
    end)
    offset = tonumber(offset)
    if ok_off and offset ~= nil and offset >= 0 then
        return offset
    end
    return nil
end

local function cm_first_entity_by_class(class_name)
    local ges = game and game.gameEntitySystem or nil
    if not ges then
        return nil
    end
    local found = nil
    protected_call(function()
        ges:ForEachByClass(class_name, function(ent)
            if found == nil then
                found = ent
            end
        end)
    end)
    return found
end

local function cm_schema_use(label, current_value, new_value)
    new_value = tonumber(new_value)
    if new_value == nil or new_value < 0 then
        return current_value, false
    end
    CM_SCHEMA_RESOLVED[label] = true
    return new_value, true
end

-- Re-derive the C_EnvSky / C_EnvCubemapFog / C_SkyCamera offsets from the live schema so
-- they self-correct after a game update. Reassigns the CM_* offset globals in place.
function cm_resolve_runtime_schema_offsets()
    local envsky = cm_first_entity_by_class("C_EnvSky")
    if envsky then
        CM_ENVSKY_MATERIAL_OFFSET = cm_schema_use("C_EnvSky.m_hSkyMaterial", CM_ENVSKY_MATERIAL_OFFSET, cm_schema_accessor_offset(envsky, "m_hSkyMaterial"))
        CM_ENVSKY_MATERIAL_LIGHTING_OFFSET = cm_schema_use("C_EnvSky.m_hSkyMaterialLightingOnly", CM_ENVSKY_MATERIAL_LIGHTING_OFFSET, cm_schema_accessor_offset(envsky, "m_hSkyMaterialLightingOnly"))
        CM_ENVSKY_START_DISABLED_OFFSET = cm_schema_use("C_EnvSky.m_bStartDisabled", CM_ENVSKY_START_DISABLED_OFFSET, cm_schema_accessor_offset(envsky, "m_bStartDisabled"))
        CM_ENVSKY_TINT_OFFSET = cm_schema_use("C_EnvSky.m_vTintColor", CM_ENVSKY_TINT_OFFSET, cm_schema_accessor_offset(envsky, "m_vTintColor"))
        CM_ENVSKY_TINT_LIGHTING_ONLY_OFFSET = cm_schema_use("C_EnvSky.m_vTintColorLightingOnly", CM_ENVSKY_TINT_LIGHTING_ONLY_OFFSET, cm_schema_accessor_offset(envsky, "m_vTintColorLightingOnly"))
        CM_ENVSKY_BRIGHTNESS_OFFSET = cm_schema_use("C_EnvSky.m_flBrightnessScale", CM_ENVSKY_BRIGHTNESS_OFFSET, cm_schema_accessor_offset(envsky, "m_flBrightnessScale"))
        CM_ENVSKY_ENABLED_OFFSET = cm_schema_use("C_EnvSky.m_bEnabled", CM_ENVSKY_ENABLED_OFFSET, cm_schema_accessor_offset(envsky, "m_bEnabled"))
    end

    local fog = cm_first_entity_by_class("C_EnvCubemapFog")
    if fog then
        CM_ENVCUBEMAPFOG_ACTIVE_OFFSET = cm_schema_use("C_EnvCubemapFog.m_bActive", CM_ENVCUBEMAPFOG_ACTIVE_OFFSET, cm_schema_accessor_offset(fog, "m_bActive"))
        CM_ENVCUBEMAPFOG_START_DISABLED_OFFSET = cm_schema_use("C_EnvCubemapFog.m_bStartDisabled", CM_ENVCUBEMAPFOG_START_DISABLED_OFFSET, cm_schema_accessor_offset(fog, "m_bStartDisabled"))
        CM_ENVCUBEMAPFOG_SKY_MATERIAL_OFFSET = cm_schema_use("C_EnvCubemapFog.m_hSkyMaterial", CM_ENVCUBEMAPFOG_SKY_MATERIAL_OFFSET, cm_schema_accessor_offset(fog, "m_hSkyMaterial"))
        CM_ENVCUBEMAPFOG_FOG_TEXTURE_OFFSET = cm_schema_use("C_EnvCubemapFog.m_hFogCubemapTexture", CM_ENVCUBEMAPFOG_FOG_TEXTURE_OFFSET, cm_schema_accessor_offset(fog, "m_hFogCubemapTexture"))
    end

    local skycamera = cm_first_entity_by_class("C_SkyCamera")
    if skycamera then
        CM_SKYCAMERA_SKYBOXDATA_OFFSET = cm_schema_use("C_SkyCamera.m_skyboxData", CM_SKYCAMERA_SKYBOXDATA_OFFSET, cm_schema_accessor_offset(skycamera, "m_skyboxData"))
    end

    if entities and entities.GetLocalPawn then
        local ok_pawn, pawn = protected_call(entities.GetLocalPawn, entities)
        if ok_pawn and pawn then
            CM_BASEPLAYERPAWN_SKYBOX3D_OFFSET = cm_schema_use("C_BasePlayerPawn.m_skybox3d", CM_BASEPLAYERPAWN_SKYBOX3D_OFFSET, cm_schema_accessor_offset(pawn, "m_skybox3d"))
        end
    end

    return CM_SCHEMA_RESOLVED["C_EnvSky.m_hSkyMaterial"] == true
end

-- Optional user skip-list: leaf names of skyboxes whose compiled material crashes a few
-- seconds after UpdateSkybox on the current build. One name per line in
-- fatality/skychanger_skip.txt; '#' starts a comment. Absent file = nothing skipped.
local cm_skip_set = nil
local function cm_load_skybox_skip_list()
    local set = {}
    cm_skip_set = set

    local file_exists = utils and (utils.FileExists or utils.file_exists) or nil
    local file_read = utils and (utils.FileRead or utils.file_read) or nil
    local array_to_string = utils and (utils.ArrayToString or utils.array_to_string) or nil
    if not file_read or not array_to_string then
        return set
    end
    if file_exists then
        local ok_ex, ex = protected_call(file_exists, CM_CFG_DIR .. "/skychanger_skip.txt")
        if not (ok_ex and ex == true) then
            return set
        end
    end
    local ok_read, bytes = protected_call(file_read, CM_CFG_DIR .. "/skychanger_skip.txt")
    if not ok_read or bytes == nil then
        return set
    end
    local ok_str, content = protected_call(array_to_string, bytes)
    if not ok_str or type(content) ~= "string" then
        return set
    end
    for line in content:gmatch("[^\r\n]+") do
        local name = line:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" and name:sub(1, 1) ~= "#" then
            name = name:gsub("\\", "/"):match("([^/]+)$") or name
            name = name:gsub("%.vmat_c$", ""):gsub("%.vmat$", "")
            if name ~= "" then
                set[name:lower()] = true
            end
        end
    end
    return set
end

function cm_skybox_is_skipped(main_path)
    if cm_skip_set == nil then
        cm_load_skybox_skip_list()
    end
    local leaf = tostring(main_path or ""):gsub("\\", "/"):match("([^/]+)$") or tostring(main_path or "")
    leaf = leaf:gsub("%.vmat_c$", ""):gsub("%.vmat$", "")
    return cm_skip_set[leaf:lower()] == true, leaf
end

local function cm_get_utils_member(...)
    if not utils then
        return nil
    end
    local i
    for i = 1, select("#", ...) do
        local key = select(i, ...)
        local value = utils[key]
        if value ~= nil then
            return value
        end
    end
    return nil
end

local function cm_find_pattern(module_name, pattern)
    -- NB: must try BOTH casings. If only the snake_case form exists in the runtime and we
    -- check FindPattern twice, fn stays nil -> UpdateSkybox never resolves -> no colour bake.
    local fn = utils and (utils.FindPattern or utils.find_pattern)
    if fn then
        local ok, addr = protected_call(fn, module_name, pattern)
        if ok then
            return tonumber(addr) or 0
        end
    end
    if client and client.find_signature then
        local ok, addr = protected_call(client.find_signature, module_name, pattern)
        if ok then
            return tonumber(addr) or 0
        end
    end
    return 0
end

local function cm_to_relative_address(ptr, rva_offset, rip_offset)
    local base = ffi.cast("uint8_t*", ptr)
    local rel = ffi.cast("int32_t*", base + rva_offset)[0]
    local rip = base + rip_offset
    return ffi.cast("uint8_t*", rip + rel)
end

local function cm_get_create_interface(module_name, version)
    if not ffi or not utils or not utils.FindExport then
        return nil
    end
    local ci = utils.FindExport(module_name, "CreateInterface")
    if ci == nil or ci == 0 then
        return nil
    end
    local fn = ffi.cast("void*(__cdecl*)(const char*, int*)", ci)
    return fn(version, nil)
end

local function cm_get_register_list(module_name)
    if not ffi or not utils or not utils.FindExport then
        return nil
    end
    local interface = utils.FindExport(module_name, "CreateInterface")
    if interface == nil or interface == 0 then
        return nil
    end
    local ok_slot, slot = protected_call(function()
        return cm_to_relative_address(interface, 0x3, 0x7)
    end)
    if not ok_slot or slot == nil then
        return nil
    end
    local ok, list = protected_call(function()
        return ffi.cast("CInterfaceRegister**", slot)[0]
    end)
    if ok then
        return list
    end
    return nil
end

local function cm_get_interface_from_register(register, name_substring)
    local reg = register
    local limit = 0
    while reg ~= nil and limit < 256 do
        local ok_name, reg_name = protected_call(function()
            return reg.szName and ffi.string(reg.szName) or nil
        end)
        if ok_name and reg_name and reg_name:find(name_substring, 1, true) then
            local ok_create, instance = protected_call(function()
                return reg.fnCreate()
            end)
            if ok_create and cm_is_valid_ptr(instance) then
                return instance
            end
        end
        local ok_next, next_reg = protected_call(function()
            return reg.pNext
        end)
        if not ok_next or next_reg == reg then
            break
        end
        reg = next_reg
        limit = limit + 1
    end
    return nil
end

local function cm_get_interface_prefer_register(module_name, version)
    local list = cm_get_register_list(module_name)
    if cm_is_valid_ptr(list) then
        local instance = cm_get_interface_from_register(list, version)
        if cm_is_valid_ptr(instance) then
            return instance
        end
    end
    return cm_get_create_interface(module_name, version)
end

local function cm_get_material_system()
    if cm_is_valid_ptr(CUSTOM_SKY_RUNTIME.material_system) then
        return CUSTOM_SKY_RUNTIME.material_system
    end
    CUSTOM_SKY_RUNTIME.material_system = cm_get_interface_prefer_register("materialsystem2.dll", "VMaterialSystem2_001")
    if not cm_is_valid_ptr(CUSTOM_SKY_RUNTIME.material_system) then
        CUSTOM_SKY_RUNTIME.material_system = cm_get_interface_prefer_register("materialsystem2", "VMaterialSystem2_001")
    end
    return CUSTOM_SKY_RUNTIME.material_system
end

local function cm_get_resource_system()
    if cm_is_valid_ptr(CUSTOM_SKY_RUNTIME.resource_system) then
        return CUSTOM_SKY_RUNTIME.resource_system
    end
    CUSTOM_SKY_RUNTIME.resource_system = cm_get_interface_prefer_register("resourcesystem.dll", "ResourceSystem013")
    if not cm_is_valid_ptr(CUSTOM_SKY_RUNTIME.resource_system) then
        CUSTOM_SKY_RUNTIME.resource_system = cm_get_interface_prefer_register("resourcesystem", "ResourceSystem013")
    end
    return CUSTOM_SKY_RUNTIME.resource_system
end

local function cm_file_exists(path)
    local fn = cm_get_utils_member("FileExists", "file_exists")
    if not fn or not path or path == "" then
        return false
    end
    local ok, exists = protected_call(fn, path)
    return ok and exists == true
end

local function cm_skybox_dir_exists()
    if cm_file_exists(CM_SKYBOX_DIR) then
        return true
    end
    if utils and utils.FileEnumerate then
        local ok, entries = protected_call(utils.FileEnumerate, CM_SKYBOX_DIR .. "/*")
        if ok and type(entries) == "table" then
            return true
        end
    end
    return false
end

local function cm_get_compiled_material_path(path)
    if not path or path == "" then
        return nil
    end
    if path:match("%.vmat_c$") then
        return path
    end
    return path:gsub("%.vmat$", ".vmat_c")
end

local function cm_material_exists(path)
    if not path or path == "" then
        return false
    end
    local compiled = cm_get_compiled_material_path(path)
    if compiled and cm_file_exists(compiled) then
        return true
    end
    return cm_file_exists(path)
end

local function cm_normalize_skybox_path(path)
    local raw = tostring(path or ""):gsub("\\", "/"):match("^%s*(.-)%s*$") or ""
    if raw == "" or raw:lower() == CUSTOM_SKY_DEFAULT_ENTRY then
        return ""
    end
    if not raw:find("/", 1, true) then
        raw = CM_SKYBOX_DIR .. "/" .. raw
    end
    return raw
end

local function cm_get_logical_material_path(path)
    if not path or path == "" then
        return nil
    end
    return path:gsub("%.vmat_c$", ".vmat")
end

local function cm_resolve_material_load_path(path)
    if not path or path == "" then
        return nil
    end
    local logical = cm_get_logical_material_path(path)
    if logical and cm_material_exists(logical) then
        return logical
    end
    if cm_material_exists(path) then
        return path:match("%.vmat_c$") and (logical or path) or path
    end
    return logical or path
end

local function cm_build_load_request(path)
    local cstr = ffi.new("char[?]", #path + 1)
    ffi.copy(cstr, path)
    local path_array = ffi.new("const char*[1]")
    path_array[0] = cstr
    local req = ffi.new("ResourceLoadRequest_t[1]")
    req[0].nCount = 1
    req[0].ppPaths = path_array
    req[0].bAllowBlocking = 1
    req[0].nLoadFlag = 1
    req[0].nBehavior = 0xFF
    return req, cstr, path_array
end

local function cm_preload_material_resource(path)
    if not ffi then
        return nil
    end
    local resource_system = cm_get_resource_system()
    if not cm_is_valid_ptr(resource_system) or not path or path == "" then
        return nil
    end
    local resolved = cm_resolve_material_load_path(path)
    local cached = CUSTOM_SKY_RUNTIME.resource_preload_cache[resolved]
    if cached and cm_is_valid_ptr(cached.ret) then
        return cached.ret
    end
    local req, cstr, path_array = cm_build_load_request(resolved)
    local vtable = ffi.cast("void***", resource_system)[0]
    local fn = ffi.cast("void*(__fastcall*)(void*, void*)", vtable[22])
    local ret = fn(resource_system, req)
    CUSTOM_SKY_RUNTIME.resource_preload_cache[resolved] = {
        req = req, cstr = cstr, path_array = path_array, ret = ret
    }
    return ret
end

local function cm_load_material(path)
    if not ffi then
        return nil
    end
    local material_system = cm_get_material_system()
    if not cm_is_valid_ptr(material_system) or not path or path == "" then
        return nil
    end
    local resolved = cm_resolve_material_load_path(path)
    cm_preload_material_resource(resolved)
    local cached = CUSTOM_SKY_RUNTIME.loaded_material_cache[resolved]
    if cached and cm_is_valid_ptr(cached.raw) then
        return cached.raw
    end
    local handle = ffi.new("uint64_t[1]")
    local vtable = ffi.cast("void***", material_system)[0]
    local fn = ffi.cast("void*(__fastcall*)(void*, void*, const char*)", vtable[14])
    local ret = fn(material_system, handle, resolved)
    local raw = tonumber(handle[0]) or 0

    -- Pin the resource refcount. m_hSkyMaterial is a CStrongHandle = ResourceBinding*, and
    -- ResourceBinding.m_nRefCount is int32 @ +0x20 (RE'd from resourcesystem.dll). Writing
    -- the raw handle in bypasses AddRef, so the engine's later Releases underflow it ->
    -- use-after-free crash ("Bad deletion request"). Bump it high once so it can't hit zero.
    if raw ~= 0 and cm_is_readable_ptr(raw, 0x24) then
        local rc = tonumber(ffi.cast("uint32_t*", raw + 0x20)[0]) or 0
        if rc > 0 and rc < 0x1000000 then
            ffi.cast("uint32_t*", raw + 0x20)[0] = rc + 0x1000000
        end
    end

    CUSTOM_SKY_RUNTIME.loaded_material_cache[resolved] = { raw = raw, owner = ret }
    return raw
end

local function cm_read_u64(base, offset)
    return tonumber(ffi.cast("uint64_t*", base + offset)[0]) or 0
end

local function cm_read_u32(base, offset)
    return tonumber(ffi.cast("uint32_t*", base + offset)[0]) or 0
end

local function cm_write_u8(base, offset, value)
    ffi.cast("uint8_t*", base + offset)[0] = value
end

local function cm_write_ptr(base, offset, value)
    ffi.cast("uint64_t*", base + offset)[0] = cm_ptr_to_u64(value)
end

function cm_write_f32(base, offset, value)
    ffi.cast("float*", base + offset)[0] = tonumber(value) or 0.0
end

function cm_write_rgba(base, offset, r, g, b, a)
    local p = ffi.cast("uint8_t*", base + offset)
    p[0] = math.max(0, math.min(255, tonumber(r) or 255))
    p[1] = math.max(0, math.min(255, tonumber(g) or 255))
    p[2] = math.max(0, math.min(255, tonumber(b) or 255))
    p[3] = math.max(0, math.min(255, tonumber(a) or 255))
end

function cm_read_rgba(base, offset)
    local p = ffi.cast("uint8_t*", base + offset)
    return tonumber(p[0]) or 255,
        tonumber(p[1]) or 255,
        tonumber(p[2]) or 255,
        tonumber(p[3]) or 255
end

local function cm_get_local_pawn_ptr()
    if not entities or not entities.GetLocalPawn then
        return nil
    end
    local ok, pawn = protected_call(entities.GetLocalPawn, entities)
    if not ok or not pawn then
        return nil
    end
    local ptr = pawn.GetPointer and pawn:GetPointer() or nil
    if cm_is_valid_ptr(ptr) then
        return ptr
    end
    return nil
end

local function cm_get_entity_world_group(ptr)
    if not cm_is_valid_ptr(ptr) then
        return nil
    end
    local base = ffi.cast("uint8_t*", ptr)
    local identity = cm_read_u64(base, CM_ENTITYINSTANCE_IDENTITY_OFFSET)
    if not cm_is_valid_ptr(identity) then
        return nil
    end
    return cm_read_u32(identity, CM_ENTITYIDENTITY_WORLDGROUP_OFFSET)
end

local function cm_get_active_sky_world_group()
    local ges = game and game.gameEntitySystem or nil
    if ges then
        local found = nil
        protected_call(function()
            ges:ForEachByClass("C_SkyCamera", function(ent)
                if found ~= nil then return end
                local ptr = ent and ent.GetPointer and ent:GetPointer() or nil
                if not cm_is_valid_ptr(ptr) then return end
                local base = ffi.cast("uint8_t*", ptr)
                found = cm_read_u32(base + CM_SKYCAMERA_SKYBOXDATA_OFFSET, CM_SKY3D_WORLDGROUP_OFFSET)
            end)
        end)
        if found ~= nil then
            return found
        end
    end
    local pawn_ptr = cm_get_local_pawn_ptr()
    if cm_is_valid_ptr(pawn_ptr) then
        return cm_read_u32(ffi.cast("uint8_t*", pawn_ptr) + CM_BASEPLAYERPAWN_SKYBOX3D_OFFSET, CM_SKY3D_WORLDGROUP_OFFSET)
    end
    return nil
end

local function cm_collect_envsky_targets()
    local all = {}
    local preferred = {}
    local active = {}
    local ges = game and game.gameEntitySystem or nil
    local target_world_group = cm_get_active_sky_world_group()
    if not ges then
        return {}
    end
    protected_call(function()
        ges:ForEachByClass("C_EnvSky", function(ent)
            local ptr = ent and ent.GetPointer and ent:GetPointer() or nil
            if not cm_is_valid_ptr(ptr) then return end
            local base = ffi.cast("uint8_t*", ptr)
            local disabled = tonumber(ffi.cast("uint8_t*", base + CM_ENVSKY_START_DISABLED_OFFSET)[0]) or 0
            local enabled = tonumber(ffi.cast("uint8_t*", base + CM_ENVSKY_ENABLED_OFFSET)[0]) or 0
            local item = {
                ptr = ptr,
                base = base,
                disabled = disabled,
                enabled = enabled,
                world_group = cm_get_entity_world_group(ptr)
            }
            all[#all + 1] = item
            if target_world_group ~= nil and item.world_group == target_world_group then
                preferred[#preferred + 1] = item
            end
            if enabled ~= 0 and disabled == 0 then
                active[#active + 1] = item
            end
        end)
    end)
    if #preferred > 0 then
        return preferred
    end
    if #active > 0 then
        return active
    end
    if #all > 0 then
        return { all[1] }
    end
    return {}
end

function cm_collect_envcubemapfog_targets()
    local all = {}
    local preferred = {}
    local active = {}
    local ges = game and game.gameEntitySystem or nil
    local target_world_group = cm_get_active_sky_world_group()
    if not ges then
        return {}
    end
    protected_call(function()
        ges:ForEachByClass("C_EnvCubemapFog", function(ent)
            local ptr = ent and ent.GetPointer and ent:GetPointer() or nil
            if not cm_is_valid_ptr(ptr) then return end
            local base = ffi.cast("uint8_t*", ptr)
            local active_flag = tonumber(ffi.cast("uint8_t*", base + CM_ENVCUBEMAPFOG_ACTIVE_OFFSET)[0]) or 0
            local disabled = tonumber(ffi.cast("uint8_t*", base + CM_ENVCUBEMAPFOG_START_DISABLED_OFFSET)[0]) or 0
            local item = {
                ptr = ptr,
                base = base,
                active = active_flag,
                disabled = disabled,
                world_group = cm_get_entity_world_group(ptr)
            }
            all[#all + 1] = item
            if target_world_group ~= nil and item.world_group == target_world_group then
                preferred[#preferred + 1] = item
            end
            if active_flag ~= 0 and disabled == 0 then
                active[#active + 1] = item
            end
        end)
    end)
    if #preferred > 0 then
        return preferred
    end
    if #active > 0 then
        return active
    end
    if #all > 0 then
        return { all[1] }
    end
    return {}
end

function cm_filter_targets_by_world_group(targets, world_group)
    if world_group == nil then
        return targets or {}
    end
    local filtered = {}
    local i
    for i = 1, #(targets or {}) do
        local item = targets[i]
        if item and item.world_group == world_group then
            filtered[#filtered + 1] = item
        end
    end
    return filtered
end

local function cm_capture_original_state()
    local state = { envsky = {}, cubemapfog = {} }
    local targets = cm_collect_envsky_targets()
    local i
    for i = 1, #targets do
        local item = targets[i]
        local base = item.base
        state.envsky[#state.envsky + 1] = {
            ptr = item.ptr,
            main_raw = cm_read_u64(base, CM_ENVSKY_MATERIAL_OFFSET),
            light_raw = cm_read_u64(base, CM_ENVSKY_MATERIAL_LIGHTING_OFFSET),
            disabled = item.disabled,
            enabled = item.enabled,
            brightness = tonumber(ffi.cast("float*", base + CM_ENVSKY_BRIGHTNESS_OFFSET)[0]) or 1.0,
            tint = { cm_read_rgba(base, CM_ENVSKY_TINT_OFFSET) },
            tint_lighting = { cm_read_rgba(base, CM_ENVSKY_TINT_LIGHTING_ONLY_OFFSET) }
        }
    end

    local fog_all = cm_collect_envcubemapfog_targets()
    for i = 1, #fog_all do
        local item = fog_all[i]
        local base = item.base
        state.cubemapfog[#state.cubemapfog + 1] = {
            ptr = item.ptr,
            sky_raw = cm_read_u64(base, CM_ENVCUBEMAPFOG_SKY_MATERIAL_OFFSET),
            fog_tex_raw = cm_read_u64(base, CM_ENVCUBEMAPFOG_FOG_TEXTURE_OFFSET),
            active = item.active,
            disabled = item.disabled
        }
    end

    return state
end

-- C_EnvSky::UpdateSkybox resolved purely by signature (lands on the entry, no backtrack).
function cm_resolve_update_skybox_candidate()
    if CUSTOM_SKY_RUNTIME.update_skybox_addr and CUSTOM_SKY_RUNTIME.update_skybox_addr ~= 0 then
        return CUSTOM_SKY_RUNTIME.update_skybox_addr
    end
    local raw_addr = 0
    local i
    for i = 1, #CM_UPDATE_SKYBOX_PATTERNS do
        raw_addr = cm_find_pattern("client.dll", CM_UPDATE_SKYBOX_PATTERNS[i])
        if raw_addr ~= 0 then
            break
        end
    end
    CUSTOM_SKY_RUNTIME.update_skybox_addr = raw_addr
    return CUSTOM_SKY_RUNTIME.update_skybox_addr
end

-- Resolve the sky-render slot index from UpdateSkybox's own `MOVSXD RDX,[rip+disp32]`
-- load (bytes 48 63 15 ..) so the UAF vector cap survives game updates (no static addr).
function cm_resolve_skybox_slot_index()
    if CUSTOM_SKY_RUNTIME.sky_slot_idx ~= nil then
        return CUSTOM_SKY_RUNTIME.sky_slot_idx
    end
    if not ffi then
        return nil
    end
    local addr = cm_resolve_update_skybox_candidate()
    if not addr or addr == 0 then
        return nil
    end
    local ok, idx = protected_call(function()
        local p = ffi.cast("uint8_t*", addr)
        local n
        for n = 0, 0x80 do
            if not cm_is_readable_ptr(p + n, 7) then break end
            if p[n] == 0x48 and p[n + 1] == 0x63 and p[n + 2] == 0x15 then
                local disp = tonumber(ffi.cast("int32_t*", p + n + 3)[0]) or 0
                local dat = ffi.cast("uint8_t*", p + n + 7) + disp
                -- The `MOV RCX,[RAX+disp32]` right after the MOVSXD carries the sky-node table
                -- offset (0x80 or 0x88 depending on the build). Capture it so the
                -- UAF vector cap in cm_reset_skybox_render_vector tracks it across game updates
                -- instead of hardcoding a value that silently breaks the crash fix each patch.
                if cm_is_readable_ptr(p + n + 7, 7)
                    and p[n + 7] == 0x48 and p[n + 8] == 0x8B and p[n + 9] == 0x88 then
                    CUSTOM_SKY_RUNTIME.sky_node_off = tonumber(ffi.cast("int32_t*", p + n + 10)[0]) or 0x88
                end
                if cm_is_readable_ptr(dat, 4) then
                    return tonumber(ffi.cast("int32_t*", dat)[0])
                end
            end
        end
        return nil
    end)
    if ok and type(idx) == "number" and idx >= 0 and idx <= 0x1000 then
        CUSTOM_SKY_RUNTIME.sky_slot_idx = idx
        return idx
    end
    return nil
end

-- Caps the C_EnvSky sky-render CUtlVector at one element right before each UpdateSkybox.
-- UpdateSkybox AddToTail's a scratch-pool render object on every call and never clears it,
-- so repeated swaps/bakes pile up stale pointers -> cumulative use-after-free crash. The
-- whole pointer walk is wrapped in protected_call so a stale layout simply no-ops.
function cm_reset_skybox_render_vector(env_sky_ptr)
    if not ffi or not cm_is_valid_ptr(env_sky_ptr) then
        return false
    end
    local idx = cm_resolve_skybox_slot_index()
    if idx == nil then
        return false
    end
    -- Sky-node table offset, resolved from UpdateSkybox itself (see cm_resolve_skybox_slot_index).
    -- Fallback to 0x88 = current build; older builds used 0x80.
    local node_off = CUSTOM_SKY_RUNTIME.sky_node_off or 0x88
    local ok, result = protected_call(function()
        local p = ffi.cast("uint8_t*", env_sky_ptr)
        if not cm_is_readable_ptr(p + 0x10, 8) then return false end
        local P = ffi.cast("uint8_t**", p + 0x10)[0]
        if not cm_is_valid_ptr(P) or not cm_is_readable_ptr(P, 8) then return false end
        local node = ffi.cast("uint8_t**", P)[0]
        if not cm_is_valid_ptr(node) then return false end
        if not cm_is_readable_ptr(P + 8, 8) then return false end
        local Q = ffi.cast("uint8_t**", P + 8)[0]
        if not cm_is_valid_ptr(Q) or not cm_is_readable_ptr(Q + node_off, 8) then return false end
        local R = ffi.cast("uint8_t**", Q + node_off)[0]
        if not cm_is_valid_ptr(R) or not cm_is_readable_ptr(R + idx * 2, 2) then return false end
        local handle = tonumber(ffi.cast("uint16_t*", R + idx * 2)[0]) or 0xffff
        if handle == 0xffff then return false end
        if not cm_is_readable_ptr(node + handle, 8) then return false end
        local vec = ffi.cast("uint8_t**", node + handle)[0]
        if not cm_is_valid_ptr(vec) or not cm_is_readable_ptr(vec + 0x38, 4) then return false end
        local size = tonumber(ffi.cast("int32_t*", vec + 0x38)[0]) or 0
        if size > 0 then
            ffi.cast("int32_t*", vec + 0x38)[0] = 0
        end
        return true
    end)
    return ok and result == true
end

function cm_call_update_skybox()
    if not ffi then
        return false
    end
    local addr = cm_resolve_update_skybox_candidate()
    if addr == 0 then
        return false
    end
    local targets = cm_collect_envsky_targets()
    if #targets == 0 then
        return false
    end
    -- Cap the sky render vector BEFORE the append so it never accumulates stale scratch
    -- render objects. UpdateSkybox is virtual void(this, uint nUpdateType); pass an explicit
    -- light update type (1): garbage in edx would hit the heavy re-init path and crash.
    cm_reset_skybox_render_vector(targets[1].ptr)
    local fn = ffi.cast("int64_t(__fastcall*)(void*, unsigned int)", addr)
    fn(targets[1].ptr, 1)
    return true
end

local function cm_restore_original_state()
    local state = CUSTOM_SKY_RUNTIME.original_state
    if not state or not state.envsky then
        return false
    end
    local i
    for i = 1, #state.envsky do
        local item = state.envsky[i]
        if item and item.ptr then
            local base = ffi.cast("uint8_t*", item.ptr)
            ffi.cast("uint64_t*", base + CM_ENVSKY_MATERIAL_OFFSET)[0] = item.main_raw or 0
            ffi.cast("uint64_t*", base + CM_ENVSKY_MATERIAL_LIGHTING_OFFSET)[0] = item.light_raw or 0
            cm_write_u8(base, CM_ENVSKY_START_DISABLED_OFFSET, item.disabled or 0)
            cm_write_u8(base, CM_ENVSKY_ENABLED_OFFSET, item.enabled or 0)
            cm_write_f32(base, CM_ENVSKY_BRIGHTNESS_OFFSET, item.brightness or 1.0)
            cm_write_rgba(
                base,
                CM_ENVSKY_TINT_OFFSET,
                ((item.tint or {})[1]),
                ((item.tint or {})[2]),
                ((item.tint or {})[3]),
                ((item.tint or {})[4])
            )
            cm_write_rgba(
                base,
                CM_ENVSKY_TINT_LIGHTING_ONLY_OFFSET,
                ((item.tint_lighting or {})[1]),
                ((item.tint_lighting or {})[2]),
                ((item.tint_lighting or {})[3]),
                ((item.tint_lighting or {})[4])
            )
        end
    end

    local cubemapfog_state = state.cubemapfog
    if cubemapfog_state then
        for i = 1, #cubemapfog_state do
            local item = cubemapfog_state[i]
            if item and item.ptr then
                local base = ffi.cast("uint8_t*", item.ptr)
                ffi.cast("uint64_t*", base + CM_ENVCUBEMAPFOG_SKY_MATERIAL_OFFSET)[0] = item.sky_raw or 0
                ffi.cast("uint64_t*", base + CM_ENVCUBEMAPFOG_FOG_TEXTURE_OFFSET)[0] = item.fog_tex_raw or 0
                cm_write_u8(base, CM_ENVCUBEMAPFOG_ACTIVE_OFFSET, item.active or 0)
                cm_write_u8(base, CM_ENVCUBEMAPFOG_START_DISABLED_OFFSET, item.disabled or 0)
            end
        end
    end

    CUSTOM_SKY_RUNTIME.last_applied_key = nil
    CUSTOM_SKY_RUNTIME.pending_tint_refreshes = 0
    return cm_call_update_skybox()
end

-- Skybox tint source. Reads whichever control CM_SKY_COLOR_CTRL points at (set when the UI
-- is built); falls back to the cheat "sky color" control, then to neutral white.
function cm_get_runtime_refresh_color()
    local ctrl = CM_SKY_COLOR_CTRL
    if not ctrl then
        ctrl = Utils.UI.get_control(CONSTANTS.PATHS.sky_color)
    end
    if ctrl and ctrl.GetValue then
        local vp = ctrl:GetValue()
        local c = vp and vp.Get and vp:Get() or nil
        if c and c.GetR then
            return c:GetR(), c:GetG(), c:GetB(), c.GetA and c:GetA() or 255
        end
    end
    return 255, 255, 255, 255
end

-- Tint only: write the colour fields directly and push the resolved colour straight into
-- the live sky render instance(s) (+0xE8/EC/F0). Does NOT call UpdateSkybox -- each call
-- would AddToTail the sky render vector and crash after a few ticks; the env_sky reads the
-- tint live, so a direct write shows this frame at full FPS. Colour-only (brightness kept).
function cm_apply_envsky_tint_only()
    if not ffi then
        return false
    end

    -- The hardcoded tint/brightness offsets are a stale fallback (the live build sits much
    -- higher, e.g. tint 0xFB9 vs default 0xCD9); writing colour there would clobber a wrong
    -- field. Make sure the schema resolved at least once -- cheap after the first hit -- and
    -- refuse to write if it never did.
    if not CM_SCHEMA_RESOLVED["C_EnvSky.m_vTintColor"] then
        cm_resolve_runtime_schema_offsets()
    end
    if not CM_SCHEMA_RESOLVED["C_EnvSky.m_vTintColor"] then
        return false
    end

    local targets = cm_collect_envsky_targets()
    if #targets == 0 then
        return false
    end

    local r, g, b = cm_get_runtime_refresh_color()
    local i
    for i = 1, #targets do
        local base = targets[i].base
        cm_write_rgba(base, CM_ENVSKY_TINT_OFFSET, r, g, b, 255)
        cm_write_rgba(base, CM_ENVSKY_TINT_LIGHTING_ONLY_OFFSET, r, g, b, 255)

        -- Map manager controls colour only (no brightness slider): use the entity's live
        -- brightness as the linear scale instead of overwriting it.
        local brightness = tonumber(ffi.cast("float*", base + CM_ENVSKY_BRIGHTNESS_OFFSET)[0]) or 1.0
        local scale = (brightness and brightness > 0) and brightness or 1.0
        local col_r = cm_srgb_lin(r) * scale
        local col_g = cm_srgb_lin(g) * scale
        local col_b = cm_srgb_lin(b) * scale

        protected_call(function()
            local p = ffi.cast("uint8_t*", base)
            local k
            for k = 1, #CM_ENVSKY_INSTANCE_OFFSETS do
                local inst_off = CM_ENVSKY_INSTANCE_OFFSETS[k]
                if cm_is_readable_ptr(p + inst_off, 8) then
                    local inst = ffi.cast("uint8_t**", p + inst_off)[0]
                    if cm_is_valid_ptr(inst) and cm_is_readable_ptr(inst + 0xE8, 12) then
                        ffi.cast("float*", inst + 0xE8)[0] = col_r
                        ffi.cast("float*", inst + 0xEC)[0] = col_g
                        ffi.cast("float*", inst + 0xF0)[0] = col_b
                    end
                end
            end
        end)
    end

    return true
end

-- Public refresh entry (used by the map-manager UI/colour integration). Colour-only,
-- direct-write, no UpdateSkybox bake. Right for live colour drags on a settled skybox.
function cm_refresh_envsky_runtime_tint()
    return cm_apply_envsky_tint_only()
end

-- Colour BAKE: write the tint then call UpdateSkybox so the sky-render handler re-resolves
-- the new colour onto the (freshly created) instances. A direct write alone is invisible on
-- a just-swapped skybox -- the slot must be dirtied by UpdateSkybox for the tint to take.
-- Heavy (sky re-init) so it's only fired a couple of times around a swap, never per-frame.
-- The render vector is capped inside cm_call_update_skybox, so repeat bakes stay crash-safe.
function cm_bake_envsky_color()
    if not ffi then
        return false
    end
    if not CM_SCHEMA_RESOLVED["C_EnvSky.m_vTintColor"] then
        cm_resolve_runtime_schema_offsets()
    end
    if not CM_SCHEMA_RESOLVED["C_EnvSky.m_vTintColor"] then
        return false
    end
    local targets = cm_collect_envsky_targets()
    if #targets == 0 then
        return false
    end
    local r, g, b = cm_get_runtime_refresh_color()
    local i
    for i = 1, #targets do
        local base = targets[i].base
        cm_write_rgba(base, CM_ENVSKY_TINT_OFFSET, r, g, b, 255)
        cm_write_rgba(base, CM_ENVSKY_TINT_LIGHTING_ONLY_OFFSET, r, g, b, 255)
    end
    cm_call_update_skybox()
    return cm_apply_envsky_tint_only()
end

function cm_schedule_envsky_runtime_tint_refresh(count)
    CUSTOM_SKY_RUNTIME.pending_tint_refreshes = math.max(tonumber(count) or 0, 0)
end

function cm_process_pending_envsky_runtime_tint_refresh()
    local remaining = tonumber(CUSTOM_SKY_RUNTIME.pending_tint_refreshes) or 0
    if remaining <= 0 then
        return false
    end

    CUSTOM_SKY_RUNTIME.pending_tint_refreshes = math.max(remaining - 1, 0)
    return cm_apply_envsky_tint_only()
end

local function cm_apply_selected_skybox()
    if not ffi or not engine_in_game() or not engine_is_connected() then
        return false
    end
    local main_path = cm_normalize_skybox_path(CUSTOM_SKY_RUNTIME.selected)
    if main_path == "" then
        return cm_restore_original_state()
    end

    -- Skip-list guard: some compiled skyboxes crash a few seconds after UpdateSkybox on the
    -- current build (fatality/skychanger_skip.txt). They are structurally valid -> no static
    -- heuristic, just a user-grown list.
    if cm_skybox_is_skipped(main_path) then
        return false
    end

    -- Self-adaptation guard: never write the material handle at an offset that did not come
    -- from the live schema on this build -- a wrong offset corrupts the entity and crashes
    -- the engine a few seconds later on the next sky update.
    cm_resolve_runtime_schema_offsets()
    if not CM_SCHEMA_RESOLVED["C_EnvSky.m_hSkyMaterial"] then
        return false
    end

    if CUSTOM_SKY_RUNTIME.original_state == nil then
        CUSTOM_SKY_RUNTIME.original_state = cm_capture_original_state()
    end
    local mat = cm_load_material(main_path)
    if not cm_is_valid_ptr(mat) then
        return false
    end
    local apply_key = tostring(main_path) .. "|" .. tostring(mat)
    if CUSTOM_SKY_RUNTIME.last_applied_key == apply_key then
        cm_schedule_envsky_runtime_tint_refresh(CM_ENVSKY_TINT_REFRESH_PASSES)
        return true
    end
    local target_world_group = cm_get_active_sky_world_group()
    local targets = cm_collect_envsky_targets()
    if #targets == 0 then
        return false
    end
    -- Read our colour ONCE and write the material handle + tint INTO the entity together,
    -- BEFORE the UpdateSkybox bake below. UpdateSkybox resolves the new sky's colour from
    -- these tint fields during the rebuild, so the colour must already be in place -- writing
    -- it only after the bake (as a separate pass) does not stick on a freshly-swapped skybox.
    local tint_r, tint_g, tint_b = cm_get_runtime_refresh_color()
    local i
    for i = 1, #targets do
        local base = targets[i].base
        cm_write_ptr(base, CM_ENVSKY_MATERIAL_OFFSET, mat)
        cm_write_rgba(base, CM_ENVSKY_TINT_OFFSET, tint_r, tint_g, tint_b, 255)
        cm_write_rgba(base, CM_ENVSKY_TINT_LIGHTING_ONLY_OFFSET, tint_r, tint_g, tint_b, 255)
    end

    -- Point the matching cubemap-fog sky material at the new material too (same world group),
    -- so the fog/reflection sky stays consistent with the swapped skybox.
    local fog_targets = cm_filter_targets_by_world_group(cm_collect_envcubemapfog_targets(), target_world_group)
    for i = 1, #fog_targets do
        cm_write_ptr(fog_targets[i].base, CM_ENVCUBEMAPFOG_SKY_MATERIAL_OFFSET, mat)
    end

    CUSTOM_SKY_RUNTIME.last_applied_key = apply_key
    cm_schedule_envsky_runtime_tint_refresh(CM_ENVSKY_TINT_REFRESH_PASSES)
    -- Bake the swap (material + tint just written) with one UpdateSkybox, then a direct
    -- colour write so the tint also shows on this very frame.
    cm_call_update_skybox()
    return cm_apply_envsky_tint_only()
end

function CUSTOM_SKY_RUNTIME.reset()
    CUSTOM_SKY_RUNTIME.material_system = nil
    CUSTOM_SKY_RUNTIME.resource_system = nil
    CUSTOM_SKY_RUNTIME.original_state = nil
    CUSTOM_SKY_RUNTIME.last_applied_key = nil
    CUSTOM_SKY_RUNTIME.loaded_material_cache = {}
    CUSTOM_SKY_RUNTIME.resource_preload_cache = {}
    CUSTOM_SKY_RUNTIME.skybox_manifest = nil
    CUSTOM_SKY_RUNTIME.update_skybox_addr = nil
    CUSTOM_SKY_RUNTIME.pending_tint_refreshes = 0
end

local function cm_manifest_add_name(names, seen, raw_name)
    local normalized = tostring(raw_name or ""):gsub("\\", "/")
    local leaf = normalized:match("([^/]+)$") or normalized
    if leaf == "" or not leaf:lower():match("%.vmat_c$") then
        return
    end
    local key = leaf:lower()
    if seen[key] then
        return
    end
    seen[key] = true
    names[#names + 1] = leaf
end

local function cm_manifest_collect_names(value, names, seen)
    if type(value) == "string" then
        cm_manifest_add_name(names, seen, value)
        return
    end
    if type(value) ~= "table" then
        return
    end

    local is_array = (#value > 0)
    if is_array then
        local i
        for i = 1, #value do
            cm_manifest_collect_names(value[i], names, seen)
        end
        return
    end

    for _, child in pairs(value) do
        cm_manifest_collect_names(child, names, seen)
    end
end

local function cm_read_skybox_manifest()
    if CUSTOM_SKY_RUNTIME.skybox_manifest ~= nil then
        if CUSTOM_SKY_RUNTIME.skybox_manifest == false then
            return nil
        end
        return CUSTOM_SKY_RUNTIME.skybox_manifest
    end

    if not Utils or not Utils.Config or not Utils.File or not Utils.Config.find_existing_path then
        CUSTOM_SKY_RUNTIME.skybox_manifest = false
        return nil
    end

    local resolved = Utils.Config.find_existing_path(CM_SKYBOX_BUNDLE_MANIFEST)
    if not resolved then
        CUSTOM_SKY_RUNTIME.skybox_manifest = false
        return nil
    end

    local data = Utils.File.load_json(resolved)
    if type(data) ~= "table" then
        CUSTOM_SKY_RUNTIME.skybox_manifest = false
        return nil
    end

    CUSTOM_SKY_RUNTIME.skybox_manifest = data
    return data
end

local function cm_collect_manifest_skybox_names()
    local manifest = cm_read_skybox_manifest()
    if type(manifest) ~= "table" then
        return {}
    end

    local names = {}
    local seen = {}
    cm_manifest_collect_names(manifest.assets, names, seen)
    cm_manifest_collect_names(manifest.files, names, seen)
    cm_manifest_collect_names(manifest.skyboxes, names, seen)
    cm_manifest_collect_names(manifest.entries, names, seen)
    cm_manifest_collect_names(manifest.bundle_assets, names, seen)

    table.sort(names, function(a, b)
        return tostring(a):lower() < tostring(b):lower()
    end)

    return names
end

local function cm_scan_skybox_candidates()
    local names = {}
    local seen = {}
    local file_create_dirs = utils and (utils.FileCreateDirectories or utils.FileCreateDirectories) or nil
    if file_create_dirs then
        protected_call(file_create_dirs, CM_SKYBOX_DIR)
    end
    local function append_name(raw_name)
        local normalized = tostring(raw_name or ""):gsub("\\", "/")
        local leaf = normalized:match("([^/]+)$") or normalized
        if leaf == "" or not leaf:lower():match("%.vmat_c$") or seen[leaf:lower()] then
            return
        end
        seen[leaf:lower()] = true
        names[#names + 1] = leaf
    end
    if utils and utils.FileEnumerate then
        local patterns = {
            CM_SKYBOX_DIR .. "/*.vmat_c",
            CM_SKYBOX_DIR .. "/*",
            CM_SKYBOX_DIR .. "/*/*.vmat_c",
            CM_SKYBOX_DIR .. "/*/*",
            CM_SKYBOX_DIR .. "/*/*/*.vmat_c"
        }
        local i
        for i = 1, #patterns do
            local ok, entries = protected_call(utils.FileEnumerate, patterns[i])
            if ok and type(entries) == "table" then
                local j
                for j = 1, #entries do
                    append_name(entries[j])
                end
            end
        end
    end
    if #names == 0 then
        local manifest_names = cm_collect_manifest_skybox_names()
        local i
        for i = 1, #manifest_names do
            append_name(manifest_names[i])
        end
    end
    if #names == 0 then
        local i
        for i = 1, #CM_FALLBACK_SKYBOXES do
            append_name(CM_FALLBACK_SKYBOXES[i])
        end
    end
    table.sort(names, function(a, b)
        return tostring(a):lower() < tostring(b):lower()
    end)
    table.insert(names, 1, CUSTOM_SKY_DEFAULT_ENTRY)
    return names
end

CUSTOM_SKY_RUNTIME.scan = cm_scan_skybox_candidates
CUSTOM_SKY_RUNTIME.exists = function(name)
    local path = cm_normalize_skybox_path(name)
    if path == "" then
        return true
    end
    return cm_material_exists(path)
end
CUSTOM_SKY_RUNTIME.get_selected = function()
    return CUSTOM_SKY_RUNTIME.selected
end
CUSTOM_SKY_RUNTIME.set_selected = function(name)
    if type(name) ~= "string" or name == "" then
        CUSTOM_SKY_RUNTIME.selected = CUSTOM_SKY_DEFAULT_ENTRY
    else
        CUSTOM_SKY_RUNTIME.selected = name
    end
    return CUSTOM_SKY_RUNTIME.selected
end
CUSTOM_SKY_RUNTIME.is_connected = function()
    return engine_in_game() and engine_is_connected()
end
CUSTOM_SKY_RUNTIME.apply_selected = function()
    return cm_apply_selected_skybox()
end
CUSTOM_SKY_RUNTIME.refresh_tint = function()
    return cm_refresh_envsky_runtime_tint()
end
CUSTOM_SKY_RUNTIME.bake_color = function()
    return cm_bake_envsky_color()
end
CUSTOM_SKY_RUNTIME.schedule_refresh = function(count)
    cm_schedule_envsky_runtime_tint_refresh(count)
    return true
end
CUSTOM_SKY_RUNTIME.restore = function()
    return cm_restore_original_state()
end
CUSTOM_SKY_RUNTIME.available = (ffi ~= nil)
end

function custom_sky_api()
    if CUSTOM_SKY_RUNTIME and CUSTOM_SKY_RUNTIME.available then
        return CUSTOM_SKY_RUNTIME
    end
    return nil
end

function custom_sky_create_page_combo(id)
    if not gui or not gui.ComboBox then
        return nil
    end
    if gui.ControlID then
        local ok_id, cid = protected_call(gui.ControlID, id)
        if ok_id and cid then
            local ok, combo = protected_call(gui.ComboBox, cid)
            if ok and combo then
                return combo
            end
        end
    end
    local ok, combo = protected_call(gui.ComboBox, id)
    if ok and combo then
        return combo
    end
    return nil
end

function custom_sky_create_list(id)
    if not gui or not gui.List then
        return nil
    end
    local size = nil
    if draw and draw.Vec2 then
        local ok_size, vec = protected_call(draw.Vec2, 250.0, 90.0)
        if ok_size and vec then
            size = vec
        end
    end
    if not size then
        return nil
    end
    local ok, list = protected_call(gui.List, id, size)
    if not ok or not list then
        return nil
    end
    protected_call(function(ctrl)
        ctrl.sizeToParentW = true
    end, list)
    protected_call(function(ctrl)
        ctrl.allowMultiple = false
    end, list)
    return list
end

function custom_sky_create_search_input(id)
    if not gui or not gui.TextInput then
        return nil
    end

    local input_id = id
    if gui.ControlID then
        local ok_id, cid = protected_call(gui.ControlID, id)
        if ok_id and cid then
            input_id = cid
        end
    end

    local ok, input = protected_call(gui.TextInput, input_id)
    if not ok or not input then
        return nil
    end

    protected_call(function(ctrl)
        ctrl.placeholder = "Search skybox..."
    end, input)
    protected_call(function(ctrl)
        ctrl.sizeToParentW = true
    end, input)

    return input
end

function custom_sky_create_selectable(id, label)
    if not gui or not gui.Selectable then
        return nil
    end
    if gui.ControlID then
        local ok_id, cid = protected_call(gui.ControlID, id)
        if ok_id and cid then
            local ok, selectable = protected_call(gui.Selectable, cid, label)
            if ok and selectable then
                return selectable
            end
        end
    end
    local ok, selectable = protected_call(gui.Selectable, id, label)
    if ok and selectable then
        return selectable
    end
    return nil
end

function custom_sky_set_selector_index(ctrl, index)
    if not ctrl or not ctrl.GetValue or type(index) ~= "number" or index < 1 then
        return false
    end
    local value_param = ctrl:GetValue()
    if not value_param or not value_param.Get then
        return false
    end
    local bits = value_param:Get()
    if not bits or not bits.SetRaw then
        return false
    end
    bits:SetRaw(math.floor(2 ^ (index - 1)))
    if value_param.Set then
        value_param:Set(bits)
        return true
    end
    return false
end

function custom_sky_checkbox_get(ctrl, default)
    if not ctrl then
        return default == true
    end
    if type(ctrl.Get) == "function" then
        local ok_get, value = protected_call(ctrl.Get, ctrl)
        if ok_get and type(value) == "boolean" then
            return value
        end
    end
    local val = ctrl.GetValue and ctrl:GetValue() or nil
    if val and val.Get then
        local raw = val:Get()
        if type(raw) == "boolean" then
            return raw
        end
        if type(raw) == "number" then
            return raw ~= 0
        end
    end
    return default == true
end

function custom_sky_checkbox_set(ctrl, state)
    if not ctrl then
        return false
    end
    local value = (state == true)
    if type(ctrl.SetValue) == "function" then
        local ok = protected_call(ctrl.SetValue, ctrl, value)
        if ok then
            return true
        end
    end
    local val = ctrl.GetValue and ctrl:GetValue() or nil
    if val and val.Set then
        val:Set(value)
        return true
    end
    return false
end

function custom_sky_clear_control_children(ctrl, objects)
    if not ctrl then
        return
    end
    local clear_fn = ctrl.RemoveAll or ctrl.ClearChildren or ctrl.Clear
    if type(clear_fn) == "function" then
        protected_call(clear_fn, ctrl)
    else
        local remove_fn = ctrl.Remove
        if type(remove_fn) == "function" then
            local i
            for i = 1, #(objects or {}) do
                if objects[i] then
                    protected_call(remove_fn, ctrl, objects[i])
                end
            end
        end
    end
end

function custom_sky_scan_names()
    local api = custom_sky_api()
    if api and type(api.scan) == "function" then
        local ok, names = protected_call(api.scan)
        if ok and type(names) == "table" then
            CUSTOM_SKY_PANEL.scanned = names
        else
            CUSTOM_SKY_PANEL.scanned = { CUSTOM_SKY_DEFAULT_ENTRY }
        end
    else
        CUSTOM_SKY_PANEL.scanned = { CUSTOM_SKY_DEFAULT_ENTRY }
    end
    if #CUSTOM_SKY_PANEL.scanned == 0 then
        CUSTOM_SKY_PANEL.scanned = { CUSTOM_SKY_DEFAULT_ENTRY }
    end
    custom_sky_apply_filter()
end

function custom_sky_apply_filter()
    local source = CUSTOM_SKY_PANEL.scanned or {}
    local needle = Utils.Config.trim_string(tostring(CUSTOM_SKY_PANEL.search_text or "")):lower()
    CUSTOM_SKY_PANEL.filtered = {}

    local i
    for i = 1, #source do
        local name = tostring(source[i] or "")
        local normalized = name:lower()
        if normalized == CUSTOM_SKY_DEFAULT_ENTRY or needle == "" or normalized:find(needle, 1, true) ~= nil then
            CUSTOM_SKY_PANEL.filtered[#CUSTOM_SKY_PANEL.filtered + 1] = name
        end
    end

    CUSTOM_SKY_PANEL.page_total = math.max(1, math.ceil(#CUSTOM_SKY_PANEL.filtered / CUSTOM_SKY_PAGE_SIZE))
    if CUSTOM_SKY_PANEL.page_current > CUSTOM_SKY_PANEL.page_total then
        CUSTOM_SKY_PANEL.page_current = CUSTOM_SKY_PANEL.page_total
    end
    if CUSTOM_SKY_PANEL.page_current < 1 then
        CUSTOM_SKY_PANEL.page_current = 1
    end
end

function custom_sky_schedule_scan(delay)
    CUSTOM_SKY_PANEL.scan_requested = true
    CUSTOM_SKY_PANEL.scan_completed = false
    CUSTOM_SKY_PANEL.scan_started_at = runtime_now() + (tonumber(delay) or CUSTOM_SKY_PANEL.scan_delay or 0.0)
end

function custom_sky_refresh_controls()
    custom_sky_rebuild_page_items()
    custom_sky_refresh_page_combo()
    custom_sky_refresh_list()
    custom_sky_sync_ui()
end

function custom_sky_resync_to_selected()
    custom_sky_align_page_to_selected()
    custom_sky_refresh_controls()
end

function custom_sky_run_pending_scan(now)
    if CUSTOM_SKY_PANEL.scan_requested ~= true or CUSTOM_SKY_PANEL.scan_completed == true then
        return false
    end

    now = tonumber(now) or runtime_now()
    if now < (tonumber(CUSTOM_SKY_PANEL.scan_started_at) or 0) then
        return false
    end

    CUSTOM_SKY_PANEL.scan_requested = false
    CUSTOM_SKY_PANEL.scan_completed = true
    custom_sky_scan_names()
    custom_sky_resync_to_selected()
    return true
end

function custom_sky_force_rescan(notify_result)
    CUSTOM_SKY_PANEL.scan_requested = false
    CUSTOM_SKY_PANEL.scan_completed = true
    custom_sky_scan_names()
    custom_sky_resync_to_selected()

    if notify_result == true then
        local count = math.max(0, #((CUSTOM_SKY_PANEL.scanned) or {}) - 1)
        notify_user("Custom skybox", string.format("Rescan complete: %d skyboxes found", count))
    end
end

-- Opens the skybox materials directory in Explorer via ShellExecuteA.
-- Mirrors Utils.Config.open_profiles_folder: plain ffi cast wrapped in
-- protected_call, no return-code heuristics (os.execute is unavailable).
function custom_sky_open_folder()
    -- Derive the skybox dir from the resolved game/csgo root (works on any
    -- install path/drive), mirroring Utils.Config.open_profiles_folder.
    local rel = "materials/skybox"
    local base = Utils.Config.get_csgo_abs_dir()
    local path = (base and (base .. "/" .. rel)) or rel
    path = path:gsub("/", "\\")

    if not (ffi and utils and utils.FindExport) then
        notify_user("Custom skybox", "Failed to open skybox folder")
        return false
    end

    local addr = utils.FindExport("shell32.dll", "ShellExecuteA")
    if not addr or addr == 0 then
        addr = utils.FindExport("shell32", "ShellExecuteA")
    end
    if not addr or addr == 0 then
        notify_user("Custom skybox", "Failed to open skybox folder")
        return false
    end

    local ok = protected_call(function()
        local ShellExecuteA = ffi.cast(
            "void*(*)(void*, const char*, const char*, const char*, const char*, int)", addr
        )
        -- ShellExecuteA(NULL, "open", path, NULL, NULL, SW_SHOWNORMAL)
        ShellExecuteA(nil, "open", path, nil, nil, 1)
        return true
    end)

    if ok == true then
        return true
    end

    notify_user("Custom skybox", "Failed to open skybox folder")
    return false
end

function custom_sky_dl_log(msg)
    return
end

function custom_sky_dl_try_get_field(obj, key)
    local ok, value = protected_call(function()
        return obj[key]
    end)
    if ok then
        return value
    end
    return nil
end

function custom_sky_dl_is_callable(value)
    local t = type(value)
    return t == "function" or t == "userdata"
end

function custom_sky_dl_normalize_skybox_path(path)
    local raw = tostring(path or ""):gsub("\\", "/"):match("^%s*(.-)%s*$") or ""
    if raw == "" or raw:lower() == tostring(CUSTOM_SKY_DEFAULT_ENTRY or "default"):lower() then
        return ""
    end
    if not raw:find("/", 1, true) then
        raw = "materials/skybox/" .. raw
    end
    return raw
end

function custom_sky_dl_resolve_http_get()
    if http and custom_sky_dl_is_callable(http.Get) then
        return http.Get
    end
    return nil
end

function custom_sky_dl_collect_manifest_assets(manifest)
    local assets = {}
    local seen_assets = {}

    local function collect(value)
        if type(value) == "string" then
            local normalized = tostring(value):gsub("\\", "/"):match("^%s*(.-)%s*$") or ""
            if normalized ~= "" then
                local key = normalized:lower()
                if not seen_assets[key] then
                    seen_assets[key] = true
                    assets[#assets + 1] = normalized
                end
            end
            return
        end

        if type(value) == "table" then
            if #value > 0 then
                for i = 1, #value do
                    collect(value[i])
                end
                return
            end
            for _, child in pairs(value) do
                collect(child)
            end
        end
    end

    collect(manifest and manifest.assets)
    collect(manifest and manifest.files)
    collect(manifest and manifest.skyboxes)
    collect(manifest and manifest.entries)
    collect(manifest and manifest.bundle_assets)
    return assets
end

function custom_sky_dl_ensure_parent_dir(path)
    local normalized = tostring(path or ""):gsub("\\", "/")
    local dir = normalized:match("^(.*)/[^/]+$")
    if type(dir) ~= "string" or dir == "" then
        return true
    end
    local file_create_dirs = utils and (utils.FileCreateDirectories or utils.FileCreateDirectories) or nil
    if type(file_create_dirs) ~= "function" then
        return true
    end
    local ok, ret = protected_call(file_create_dirs, dir)
    if not ok then
        custom_sky_dl_log("mkdir failed dir=" .. tostring(dir))
        return false
    end
    return ret ~= false
end

function custom_sky_dl_finish(ok, text, should_rescan)
    local st = CM_SKYBOX_DOWNLOAD_STATE
    st.active = false
    st.in_flight = false
    st.pending_result = nil
    st.http_get = nil
    st.queue = {}
    st.download_goal = 0

    custom_sky_dl_log(
        "finish ok=" .. tostring(ok) ..
        " text=" .. tostring(text) ..
        " downloaded=" .. tostring(st.downloaded) ..
        " skipped=" .. tostring(st.skipped) ..
        " failed=" .. tostring(#(st.failed or {}))
    )

    if should_rescan then
        custom_sky_force_rescan(false)
    end
    notify_user("Custom skybox", text)
end

function custom_sky_dl_start_request(stage, url, save_path, asset_path)
    local st = CM_SKYBOX_DOWNLOAD_STATE
    if not st.active or st.in_flight or (not custom_sky_dl_is_callable(st.http_get)) then
        return false
    end

    if type(save_path) == "string" and save_path ~= "" and (not custom_sky_dl_ensure_parent_dir(save_path)) then
        return false
    end

    st.in_flight = true
    local session_id = tonumber(st.session_id) or 0

    custom_sky_dl_log(tostring(stage) .. " request -> " .. tostring(url) .. " saveToFile=" .. tostring(save_path))

    local callback = function(status, data)
        local ok_cb, err_cb = protected_call(function()
            st.in_flight = false
            st.pending_result = {
                session_id = session_id,
                stage = stage,
                status = status,
                data_type = type(data),
                save_path = save_path,
                asset_path = asset_path,
                url = url
            }
        end)

        if not ok_cb then
            st.in_flight = false
            st.pending_result = {
                session_id = session_id,
                stage = stage,
                status = false,
                data_type = "callback_error",
                save_path = save_path,
                asset_path = asset_path,
                url = url,
                error = tostring(err_cb)
            }
        end
    end

    local ok_call, err_call = protected_call(st.http_get, url, { saveToFile = save_path }, callback)
    if not ok_call then
        st.in_flight = false
        custom_sky_dl_log(
            tostring(stage) .. " request invoke failed err=" .. tostring(err_call) ..
            " url=" .. tostring(url)
        )
        return false
    end

    return true
end

function custom_sky_dl_request_next_asset()
    local st = CM_SKYBOX_DOWNLOAD_STATE
    if not st.active or st.in_flight then
        return
    end

    while true do
        local asset = table.remove(st.queue, 1)
        if not asset then
            if #(st.failed or {}) > 0 then
                custom_sky_dl_finish(
                    false,
                    string.format(
                        "Skybox download finished with errors. Downloaded: %d, skipped: %d, failed: %d",
                        st.downloaded,
                        st.skipped,
                        #(st.failed or {})
                    ),
                    false
                )
            else
                custom_sky_dl_finish(
                    true,
                    string.format(
                        "Skybox download complete. Downloaded: %d, skipped: %d",
                        st.downloaded,
                        st.skipped
                    ),
                    true
                )
            end
            return
        end

        local asset_save_path = custom_sky_dl_normalize_skybox_path(asset)
        local asset_file_name = tostring(asset or ""):gsub("\\", "/"):match("([^/]+)$") or tostring(asset or "")
        if asset_save_path == "" then
            st.failed[#st.failed + 1] = tostring(asset)
        elseif Utils and Utils.File and Utils.File.exists and Utils.File.exists(asset_save_path) then
            st.skipped = st.skipped + 1
        else
            local asset_url = CM_SKYBOX_GITHUB.download_base .. "/" .. tostring(asset_file_name)
            if not custom_sky_dl_start_request("asset", asset_url, asset_save_path, asset_save_path) then
                custom_sky_dl_finish(false, "Failed to start GitHub asset request", false)
            end
            return
        end
    end
end

function custom_sky_download_tick()
    local st = CM_SKYBOX_DOWNLOAD_STATE
    if not (st and st.active) then
        return
    end

    local result = st.pending_result
    if type(result) ~= "table" then
        return
    end
    st.pending_result = nil

    if (tonumber(result.session_id) or 0) ~= (tonumber(st.session_id) or 0) then
        return
    end

    if result.error then
        custom_sky_dl_log(
            tostring(result.stage) .. " callback failed err=" .. tostring(result.error) ..
            " url=" .. tostring(result.url)
        )
        custom_sky_dl_finish(false, "GitHub download callback failed", false)
        return
    end

    if result.stage == "manifest" then
        custom_sky_dl_log(
            "manifest response status=" .. tostring(result.status) ..
            " data_type=" .. tostring(result.data_type)
        )
        if result.status ~= 200 then
            custom_sky_dl_finish(false, "Failed to download GitHub skybox manifest", false)
            return
        end

        CUSTOM_SKY_RUNTIME.skybox_manifest = nil
        local manifest = Utils and Utils.File and Utils.File.load_json and Utils.File.load_json(CM_SKYBOX_GITHUB.local_manifest_path) or nil
        custom_sky_dl_log("manifest decoded type=" .. tostring(type(manifest)))
        if type(manifest) ~= "table" then
            custom_sky_dl_finish(false, "Downloaded manifest is invalid", false)
            return
        end

        local assets = custom_sky_dl_collect_manifest_assets(manifest)
        if #assets == 0 then
            custom_sky_dl_finish(false, "Manifest does not contain skybox assets", false)
            return
        end

        local missing_assets = {}
        local existing_assets = 0
        for i = 1, #assets do
            local asset = assets[i]
            local asset_path = custom_sky_dl_normalize_skybox_path(asset)
            if Utils and Utils.File and Utils.File.exists and Utils.File.exists(asset_path) then
                existing_assets = existing_assets + 1
            else
                missing_assets[#missing_assets + 1] = asset
            end
        end

        st.total = #assets
        st.skipped = existing_assets
        st.manifest_done = true
        st.download_goal = #missing_assets
        if #missing_assets == 0 then
            custom_sky_dl_finish(true, "All skyboxes from GitHub manifest are already downloaded", false)
            return
        end

        st.queue = missing_assets
        custom_sky_dl_log(
            "queue prepared total=" .. tostring(#assets) ..
            " existing=" .. tostring(existing_assets) ..
            " missing=" .. tostring(#missing_assets)
        )
        custom_sky_dl_request_next_asset()
        return
    end

    if result.stage == "asset" then
        custom_sky_dl_log(
            "asset response asset=" .. tostring(result.asset_path) ..
            " status=" .. tostring(result.status) ..
            " data_type=" .. tostring(result.data_type)
        )
        if result.status == 200 then
            st.downloaded = st.downloaded + 1
        else
            st.failed[#st.failed + 1] = tostring(result.asset_path)
        end
        custom_sky_dl_request_next_asset()
        return
    end

    custom_sky_dl_finish(false, "Unknown GitHub download state", false)
end

function custom_sky_download_from_github()
    local st = CM_SKYBOX_DOWNLOAD_STATE
    local http_get = custom_sky_dl_resolve_http_get()
    if not custom_sky_dl_is_callable(http_get) then
        notify_user("Custom skybox", "Download is unavailable: http API is not supported")
        custom_sky_dl_log("aborted: http.Get/http.Get not found")
        return false
    end

    if st.active then
        notify_user("Custom skybox", "GitHub skybox download is already in progress")
        custom_sky_dl_log("aborted: already active")
        return false
    end

    st.active = true
    st.queue = {}
    st.total = 0
    st.downloaded = 0
    st.skipped = 0
    st.failed = {}
    st.manifest_done = false
    st.in_flight = false
    st.pending_result = nil
    st.http_get = http_get
    st.session_id = (tonumber(st.session_id) or 0) + 1
    st.download_goal = 0

    custom_sky_dl_log(
        "manifest request -> " .. tostring(CM_SKYBOX_GITHUB.manifest_url) ..
        " saveToFile=" .. tostring(CM_SKYBOX_GITHUB.local_manifest_path)
    )

    if not custom_sky_dl_start_request("manifest", CM_SKYBOX_GITHUB.manifest_url, CM_SKYBOX_GITHUB.local_manifest_path, CM_SKYBOX_GITHUB.local_manifest_path) then
        custom_sky_dl_finish(false, "Failed to start GitHub manifest request", false)
        return false
    end

    notify_user("Custom skybox", "GitHub skybox download started")
    custom_sky_dl_log("started")
    return true
end

function custom_sky_render_download_progress()
    if not (CM_SKYBOX_DOWNLOAD_STATE and CM_SKYBOX_DOWNLOAD_STATE.active) then
        return
    end
    if not draw or not draw.surface then
        return
    end

    local layer = draw.surface
    local w, h
    local disp = draw.GetDisplay()
    if type(disp) == "table" then
        w = (disp.x and tonumber(disp.x)) or disp[1]
        h = (disp.y and tonumber(disp.y)) or disp[2]
    end
    if (not w or not h or w <= 0 or h <= 0) and game and game.engine and game.engine.GetScreenSize then
        w, h = game.engine:GetScreenSize()
    end
    if not w or not h or w <= 0 or h <= 0 then
        return
    end

    local total = tonumber(CM_SKYBOX_DOWNLOAD_STATE.total) or 0
    local downloaded = tonumber(CM_SKYBOX_DOWNLOAD_STATE.downloaded) or 0
    local skipped = tonumber(CM_SKYBOX_DOWNLOAD_STATE.skipped) or 0
    local failed = #(CM_SKYBOX_DOWNLOAD_STATE.failed or {})
    local processed = downloaded + skipped + failed
    local download_goal = tonumber(CM_SKYBOX_DOWNLOAD_STATE.download_goal) or 0
    local download_processed = downloaded + failed
    local progress = 0
    if CM_SKYBOX_DOWNLOAD_STATE.manifest_done == true then
        if download_goal > 0 then
            progress = math.max(0, math.min(1, download_processed / download_goal))
        elseif total > 0 then
            progress = 1
        end
    end
    local percent = math.floor((progress * 100) + 0.5)

    local font = draw.fonts and draw.fonts["gui_main"] or nil
    if not font then
        return
    end

    local function mk_vec2(x, y)
        if draw.Vec2 then
            return draw.Vec2(x, y)
        end
        if draw.Vec2 then
            return draw.Vec2(x, y)
        end
        return nil
    end

    local function mk_rect_xywh(x, y, rw, rh)
        rw = math.max(0, tonumber(rw) or 0)
        rh = math.max(0, tonumber(rh) or 0)
        if draw.Rect then
            local v1 = mk_vec2(x, y)
            local v2 = mk_vec2(x + rw, y + rh)
            if v1 and v2 then
                return draw.Rect(v1, v2)
            end
        end
        if draw.Rect then
            local ok1, r1 = protected_call(draw.Rect, x, y, rw, rh)
            if ok1 and r1 then
                return r1
            end
            local ok2, r2 = protected_call(draw.Rect, x, y, x + rw, y + rh)
            if ok2 and r2 then
                return r2
            end
        end
        return nil
    end

    layer.font = font
    local text = nil
    if CM_SKYBOX_DOWNLOAD_STATE.manifest_done ~= true then
        text = "Downloading skyboxes... preparing manifest"
    elseif download_goal > 0 then
        text = string.format("Downloading skyboxes... %d%% (%d/%d)", percent, download_processed, download_goal)
    else
        text = string.format("Downloading skyboxes... %d%% (%d/%d)", percent, processed, math.max(total, processed))
    end
    local text_size = font.GetTextSize and font:GetTextSize(text, true, false) or nil
    local text_w = text_size and tonumber(text_size.x) or 0
    local text_h = text_size and tonumber(text_size.y) or tonumber(font.height) or 18

    -- Keep the indicator compact while adapting to different resolutions/aspect ratios.
    local bar_w = math.max(90, math.min(210, math.floor(w * 0.095 + 0.5)))
    local bar_h = math.max(1, math.min(3, math.floor(h * 0.0022 + 0.5)))
    local text_x = math.max(6, math.floor((w - text_w) * 0.5))
    local text_y = math.max(20, math.min(108, math.floor(h * 0.085 + 0.5)))
    local bar_x = math.floor((w - bar_w) * 0.5)
    local bar_y = text_y + text_h + math.max(4, math.min(10, math.floor(h * 0.006 + 0.5)))
    local fill_w = math.floor(bar_w * progress + 0.5)

    local text_pos = mk_vec2(text_x, text_y)
    if text_pos then
        layer:AddText(text_pos, text, draw.Color(235, 235, 235, 255))
    end

    local track_rect = mk_rect_xywh(bar_x, bar_y, bar_w, bar_h)
    if track_rect then
        layer:AddRectFilled(track_rect, draw.Color(255, 255, 255, 70))
    end

    if fill_w > 0 then
        local fill_rect = mk_rect_xywh(bar_x, bar_y, fill_w, bar_h)
        if fill_rect then
            layer:AddRectFilled(fill_rect, draw.Color(90, 200, 255, 245))
        end
    end
end

function custom_sky_rebuild_page_items()
    CUSTOM_SKY_PANEL.page_items = {}
    local source = CUSTOM_SKY_PANEL.filtered or CUSTOM_SKY_PANEL.scanned or {}
    local start_index = ((CUSTOM_SKY_PANEL.page_current - 1) * CUSTOM_SKY_PAGE_SIZE) + 1
    local finish = math.min(#source, start_index + CUSTOM_SKY_PAGE_SIZE - 1)
    local i
    for i = start_index, finish do
        CUSTOM_SKY_PANEL.page_items[#CUSTOM_SKY_PANEL.page_items + 1] = source[i]
    end
end

function custom_sky_align_page_to_selected()
    local source = CUSTOM_SKY_PANEL.filtered or CUSTOM_SKY_PANEL.scanned or {}
    local selected = tostring(CUSTOM_SKY_PANEL.selected or CUSTOM_SKY_DEFAULT_ENTRY):lower()
    local global_index = 1
    local i
    for i = 1, #source do
        if tostring(source[i]):lower() == selected then
            global_index = i
            break
        end
    end
    CUSTOM_SKY_PANEL.page_current = math.max(1, math.ceil(global_index / CUSTOM_SKY_PAGE_SIZE))
end

function custom_sky_refresh_page_combo()
    local ctrl = CUSTOM_SKY_PANEL.controls.page
    if not ctrl then
        return
    end
    custom_sky_clear_control_children(ctrl, CUSTOM_SKY_PANEL.page_objects)
    CUSTOM_SKY_PANEL.page_objects = {}
    local add_fn = ctrl.Add
    if type(add_fn) ~= "function" then
        return
    end
    local i
    for i = 1, CUSTOM_SKY_PANEL.page_total do
        local selectable = custom_sky_create_selectable("cm_custom_sky_page_" .. tostring(i), string.format("%d / %d", i, CUSTOM_SKY_PANEL.page_total))
        if selectable then
            local ok_add, ret = protected_call(add_fn, ctrl, selectable)
            if ok_add and ret ~= false then
                CUSTOM_SKY_PANEL.page_objects[#CUSTOM_SKY_PANEL.page_objects + 1] = selectable
            end
        end
    end
    CUSTOM_SKY_PANEL.page_syncing = true
    custom_sky_set_selector_index(ctrl, CUSTOM_SKY_PANEL.page_current)
    CUSTOM_SKY_PANEL.page_syncing = false
end

function custom_sky_refresh_list()
    local ctrl = CUSTOM_SKY_PANEL.controls.list
    if ctrl then
        custom_sky_clear_control_children(ctrl, CUSTOM_SKY_PANEL.list_objects)
        CUSTOM_SKY_PANEL.list_objects = {}
        local add_fn = ctrl.Add
        if type(add_fn) == "function" then
            local i
            for i = 1, #CUSTOM_SKY_PANEL.page_items do
                local selectable = custom_sky_create_selectable("cm_custom_sky_item_" .. tostring(i), CUSTOM_SKY_PANEL.page_items[i])
                if selectable then
                    local ok_add, ret = protected_call(add_fn, ctrl, selectable)
                    if ok_add and ret ~= false then
                        CUSTOM_SKY_PANEL.list_objects[#CUSTOM_SKY_PANEL.list_objects + 1] = selectable
                    end
                end
            end
        end
        local process_fn = ctrl.ProcessQueues
        if type(process_fn) == "function" then
            protected_call(process_fn, ctrl)
        end
        local raise_fn = ctrl.RaiseFirstRenderCall
        if type(raise_fn) == "function" then
            protected_call(raise_fn, ctrl)
        end
        CUSTOM_SKY_PANEL.list_syncing = true
        local selected = tostring(CUSTOM_SKY_PANEL.selected or CUSTOM_SKY_DEFAULT_ENTRY):lower()
        local selected_idx = 1
        local i
        for i = 1, #CUSTOM_SKY_PANEL.page_items do
            if tostring(CUSTOM_SKY_PANEL.page_items[i]):lower() == selected then
                selected_idx = i
                break
            end
        end
        custom_sky_set_selector_index(ctrl, selected_idx)
        CUSTOM_SKY_PANEL.list_syncing = false
    end
end

function custom_sky_sync_ui()
    CUSTOM_SKY_PANEL.syncing = true
    custom_sky_checkbox_set(CUSTOM_SKY_PANEL.controls.enable, CUSTOM_SKY_PANEL.enabled == true)
    set_row_visible(CUSTOM_SKY_PANEL.rows.search, CUSTOM_SKY_PANEL.enabled == true)
    set_row_visible(CUSTOM_SKY_PANEL.rows.page, CUSTOM_SKY_PANEL.enabled == true)
    set_row_visible(CUSTOM_SKY_PANEL.rows.list, CUSTOM_SKY_PANEL.enabled == true)
    -- Keep loading/open-folder actions visible even when the custom skybox toggle is off.
    -- The user needs a way to rescan the folder before enabling the runtime switch.
    set_row_visible(CUSTOM_SKY_PANEL.rows.download_github, true)
    set_row_visible(CUSTOM_SKY_PANEL.rows.open_folder, true)
    set_row_visible(CUSTOM_SKY_PANEL.rows.rescan, true)
    CUSTOM_SKY_PANEL.syncing = false
end

function custom_sky_notify_missing(name)
    local msg = "Custom skybox not found: " .. tostring(name)
    if CUSTOM_SKY_PANEL.last_missing_notice ~= msg then
        CUSTOM_SKY_PANEL.last_missing_notice = msg
        notify_user("Custom skybox", msg)
    end
end

function custom_sky_notify_enable_required(name)
    local msg = "Enable custom skybox to use map skybox: " .. tostring(name)
    if CUSTOM_SKY_PANEL.last_missing_notice ~= msg then
        CUSTOM_SKY_PANEL.last_missing_notice = msg
        notify_user("Custom skybox", msg)
    end
end

-- Schedule a single delayed colour BAKE `delay` seconds after a skybox swap. The colour on
-- a fresh skybox is applied by the sky-render handler, which only runs on a slot dirtied by
-- UpdateSkybox -- a plain direct write doesn't stick. The bake in apply can fire before the
-- new sky's instances exist, so we bake once more here, by which point they're ready.
function custom_sky_schedule_color_update(delay)
    CUSTOM_SKY_PANEL.color_bake_at = runtime_now() + (tonumber(delay) or CUSTOM_SKY_COLOR_BAKE_DELAY)
    return true
end

function custom_sky_process_pending_color_update(now)
    local at = tonumber(CUSTOM_SKY_PANEL.color_bake_at) or 0
    if at <= 0 then
        return false
    end
    now = tonumber(now) or runtime_now()
    if now < at then
        return false
    end
    CUSTOM_SKY_PANEL.color_bake_at = 0
    if CUSTOM_SKY_PANEL.enabled ~= true then
        return false
    end
    local api = custom_sky_api()
    if api and type(api.bake_color) == "function" then
        return protected_call(api.bake_color) == true
    end
    return false
end

function custom_sky_schedule_enable_apply(notify_missing, delay)
    CUSTOM_SKY_PANEL.pending_enable_notify_missing = (notify_missing == true)
    CUSTOM_SKY_PANEL.pending_enable_apply_at = runtime_now() + (tonumber(delay) or CUSTOM_SKY_ENABLE_APPLY_DELAY)
    return true
end

function custom_sky_cancel_enable_apply()
    CUSTOM_SKY_PANEL.pending_enable_apply_at = 0
    CUSTOM_SKY_PANEL.pending_enable_notify_missing = false
end

function custom_sky_process_pending_enable_apply(now)
    local due_at = tonumber(CUSTOM_SKY_PANEL.pending_enable_apply_at) or 0
    if due_at <= 0 then
        return false
    end
    if (tonumber(now) or runtime_now()) < due_at then
        return false
    end

    local notify_missing = (CUSTOM_SKY_PANEL.pending_enable_notify_missing == true)
    custom_sky_cancel_enable_apply()
    return custom_sky_apply_mode_from_state(notify_missing)
end

function custom_sky_reapply_current_environment_controls()
    local api = custom_sky_api()

    -- Apply our colour immediately on the swap...
    if api and type(api.refresh_tint) == "function" then
        protected_call(api.refresh_tint)
    end

    -- ...then once more after the new skybox's sky-render instances exist (~0.3s). No cheat
    -- "sky color" control is touched anymore -- the colour is driven solely by our picker.
    custom_sky_schedule_color_update(CUSTOM_SKY_COLOR_BAKE_DELAY)
    return true
end

function custom_sky_reset_ui_state()
    CUSTOM_SKY_PANEL.scanned = { CUSTOM_SKY_DEFAULT_ENTRY }
    CUSTOM_SKY_PANEL.filtered = { CUSTOM_SKY_DEFAULT_ENTRY }
    CUSTOM_SKY_PANEL.page_items = {}
    CUSTOM_SKY_PANEL.page_total = 1
    CUSTOM_SKY_PANEL.page_current = 1
    CUSTOM_SKY_PANEL.search_text = ""
    CUSTOM_SKY_PANEL.scan_requested = false
    CUSTOM_SKY_PANEL.scan_completed = false
    CUSTOM_SKY_PANEL.scan_started_at = 0
    CUSTOM_SKY_PANEL.color_bake_at = 0
    CUSTOM_SKY_PANEL.pending_enable_apply_at = 0
    CUSTOM_SKY_PANEL.pending_enable_notify_missing = false

    if CUSTOM_SKY_PANEL.controls.search then
        Utils.Config.write_profile_name_input(CUSTOM_SKY_PANEL.controls.search, "")
    end
end

function custom_sky_apply_runtime(notify_missing)
    local api = custom_sky_api()
    if not api then
        notify_user("Custom skybox", "Custom skybox runtime is unavailable")
        return false
    end
    if type(api.is_connected) == "function" then
        local ok_connected, connected = protected_call(api.is_connected)
        if ok_connected and connected ~= true then
            return true
        end
    end
    local selected = tostring(CUSTOM_SKY_PANEL.selected or CUSTOM_SKY_DEFAULT_ENTRY)
    if selected:lower() == CUSTOM_SKY_DEFAULT_ENTRY then
        protected_call(api.restore)
        return true
    end
    local ok_exists, exists = protected_call(api.exists, selected)
    if (not ok_exists) or exists ~= true then
        CUSTOM_SKY_PANEL.selected = CUSTOM_SKY_DEFAULT_ENTRY
        custom_sky_resync_to_selected()
        if notify_missing ~= false then
            custom_sky_notify_missing(selected)
        end
        protected_call(api.restore)
        return false
    end
    CUSTOM_SKY_PANEL.last_missing_notice = ""
    Utils.UI.set_combo("skybox", 1)
    protected_call(api.set_selected, selected)
    protected_call(api.apply_selected)
    custom_sky_reapply_current_environment_controls()
    return true
end

function custom_sky_restore_runtime()
    local api = custom_sky_api()
    if api and type(api.restore) == "function" then
        if type(api.is_connected) == "function" then
            local ok_connected, connected = protected_call(api.is_connected)
            if ok_connected and connected ~= true then
                return
            end
        end
        protected_call(api.restore)
    end
end

function custom_sky_apply_mode_from_state(notify_missing)
    if CUSTOM_SKY_PANEL.enabled == true then
        Utils.UI.set_combo("skybox", 1)
        return custom_sky_apply_runtime(notify_missing)
    end
    custom_sky_restore_runtime()
    Utils.UI.set_combo("skybox", tonumber(CUSTOM_SKY_PANEL.last_standard_index) or 1)
    return true
end

custom_sky_commit_runtime_state = function() end

function custom_sky_build_ui(host_group)
    if not host_group then
        return false
    end

    local warning_id = "cm_custom_sky_warning"
    if gui and gui.ControlID then
        local ok_id, cid = protected_call(gui.ControlID, "cm_custom_sky_warning")
        if ok_id and cid then
            warning_id = cid
        end
    end
    if gui and gui.Label then
        local ok_warning, warning_label = protected_call(gui.Label, warning_id, CM_CUSTOM_SKY_WARNING_LABEL)
        if ok_warning and warning_label then
            CUSTOM_SKY_PANEL.controls.warning = warning_label
            CUSTOM_SKY_PANEL.rows.warning = warning_label
            add_child_compat(host_group, warning_label)
        end
    end

    local enable_id = "cm_custom_sky_enable"
    if gui and gui.ControlID then
        local ok_id, cid = protected_call(gui.ControlID, "cm_custom_sky_enable")
        if ok_id and cid then
            enable_id = cid
        end
    end
    local ok_checkbox, checkbox = protected_call(gui.Checkbox, enable_id)
    CUSTOM_SKY_PANEL.controls.enable = ok_checkbox and checkbox or nil
    if not CUSTOM_SKY_PANEL.controls.enable then
        return false
    end
    CUSTOM_SKY_PANEL.rows.enable = gui.MakeControl("Enable custom skybox", CUSTOM_SKY_PANEL.controls.enable)
    CUSTOM_SKY_PANEL.controls.enable.tooltip = "Enable runtime custom skybox replacement from scanned skybox files."
    add_child_compat(host_group, CUSTOM_SKY_PANEL.rows.enable)

    CUSTOM_SKY_PANEL.controls.page = custom_sky_create_page_combo("cm_custom_sky_page_combo")
    if CUSTOM_SKY_PANEL.controls.page then
        CUSTOM_SKY_PANEL.rows.page = gui.MakeControl("Skybox page", CUSTOM_SKY_PANEL.controls.page)
        CUSTOM_SKY_PANEL.controls.page.tooltip = "Select the visible page for the custom skybox list."
        add_child_compat(host_group, CUSTOM_SKY_PANEL.rows.page)
    end

    CUSTOM_SKY_PANEL.controls.search = custom_sky_create_search_input("cm_custom_sky_search")
    if CUSTOM_SKY_PANEL.controls.search then
        CUSTOM_SKY_PANEL.rows.search = CUSTOM_SKY_PANEL.controls.search
        CUSTOM_SKY_PANEL.controls.search.tooltip = "Filter scanned custom skyboxes by name."
        add_child_compat(host_group, CUSTOM_SKY_PANEL.controls.search)
    end

    CUSTOM_SKY_PANEL.controls.list = custom_sky_create_list("cm_custom_sky_list")
    if CUSTOM_SKY_PANEL.controls.list then
        CUSTOM_SKY_PANEL.rows.list = CUSTOM_SKY_PANEL.controls.list
        CUSTOM_SKY_PANEL.controls.list.tooltip = "Select a custom skybox from files found in materials/skybox."
        add_child_compat(host_group, CUSTOM_SKY_PANEL.controls.list)
    end

    CUSTOM_SKY_PANEL.controls.download_github = apply_uniform_button_style(gui.Button(gui.ControlID("cm_custom_sky_download_github"), "Download skyboxes from GitHub"))
    if CUSTOM_SKY_PANEL.controls.download_github then
        CUSTOM_SKY_PANEL.rows.download_github = CUSTOM_SKY_PANEL.controls.download_github
        CUSTOM_SKY_PANEL.controls.download_github.tooltip = "Download manifest.json and missing skybox assets from " .. CM_SKYBOX_GITHUB.owner .. "/" .. CM_SKYBOX_GITHUB.repo .. " release " .. CM_SKYBOX_GITHUB.tag .. "."
        add_child_compat(host_group, CUSTOM_SKY_PANEL.controls.download_github)
    end

    CUSTOM_SKY_PANEL.controls.open_folder = apply_uniform_button_style(gui.Button(gui.ControlID("cm_custom_sky_open_folder"), "Open skybox folder"))
    if CUSTOM_SKY_PANEL.controls.open_folder then
        CUSTOM_SKY_PANEL.rows.open_folder = CUSTOM_SKY_PANEL.controls.open_folder
        CUSTOM_SKY_PANEL.controls.open_folder.tooltip = "Open materials/skybox in Explorer."
        add_child_compat(host_group, CUSTOM_SKY_PANEL.controls.open_folder)
    end

    CUSTOM_SKY_PANEL.controls.rescan = apply_uniform_button_style(gui.Button(gui.ControlID("cm_custom_sky_rescan"), "Rescan skyboxes"))
    if CUSTOM_SKY_PANEL.controls.rescan then
        CUSTOM_SKY_PANEL.rows.rescan = CUSTOM_SKY_PANEL.controls.rescan
        CUSTOM_SKY_PANEL.controls.rescan.tooltip = "Rescan materials/skybox and rebuild the custom skybox list."
        add_child_compat(host_group, CUSTOM_SKY_PANEL.controls.rescan)
    end

    custom_sky_reset_ui_state()
    custom_sky_scan_names()
    custom_sky_resync_to_selected()
    if #CUSTOM_SKY_PANEL.scanned <= 1 then
        custom_sky_schedule_scan(0.0)
    else
        CUSTOM_SKY_PANEL.scan_completed = true
    end

    if CUSTOM_SKY_PANEL.controls.enable and CUSTOM_SKY_PANEL.controls.enable.AddCallback then
        CUSTOM_SKY_PANEL.controls.enable:AddCallback(function()
            if CUSTOM_SKY_PANEL.syncing then
                return
            end
            CUSTOM_SKY_PANEL.enabled = custom_sky_checkbox_get(CUSTOM_SKY_PANEL.controls.enable, false)
            if CUSTOM_SKY_PANEL.enabled == true then
                CUSTOM_SKY_PANEL.last_standard_index = Utils.UI.get_combo("skybox")
            end
            custom_sky_commit_runtime_state()
            custom_sky_sync_ui()
            custom_sky_update_mirror_skybox_visibility()
            if CUSTOM_SKY_PANEL.enabled == true then
                custom_sky_schedule_enable_apply(true, CUSTOM_SKY_ENABLE_APPLY_DELAY)
            else
                custom_sky_cancel_enable_apply()
                custom_sky_apply_mode_from_state(true)
            end
        end)
    end

    if CUSTOM_SKY_PANEL.controls.page and CUSTOM_SKY_PANEL.controls.page.AddCallback then
        CUSTOM_SKY_PANEL.controls.page:AddCallback(function()
            if CUSTOM_SKY_PANEL.page_syncing or CUSTOM_SKY_PANEL.syncing then
                return
            end
            local idx = get_selector_index(CUSTOM_SKY_PANEL.controls.page)
            if idx < 1 or idx == CUSTOM_SKY_PANEL.page_current then
                return
            end
            CUSTOM_SKY_PANEL.page_current = idx
            custom_sky_refresh_controls()
        end)
    end

    if CUSTOM_SKY_PANEL.controls.search and CUSTOM_SKY_PANEL.controls.search.AddCallback then
        CUSTOM_SKY_PANEL.controls.search:AddCallback(function()
            CUSTOM_SKY_PANEL.search_text = Utils.Config.read_profile_name_input(CUSTOM_SKY_PANEL.controls.search)
            if Utils.Config.trim_string(tostring(CUSTOM_SKY_PANEL.search_text or "")) ~= "" then
                CUSTOM_SKY_PANEL.selected = CUSTOM_SKY_DEFAULT_ENTRY
            end
            CUSTOM_SKY_PANEL.page_current = 1
            custom_sky_apply_filter()
            custom_sky_resync_to_selected()
        end)
    end

    if CUSTOM_SKY_PANEL.controls.list and CUSTOM_SKY_PANEL.controls.list.AddCallback then
        CUSTOM_SKY_PANEL.controls.list:AddCallback(function()
            if CUSTOM_SKY_PANEL.list_syncing or CUSTOM_SKY_PANEL.syncing then
                return
            end
            local idx = get_selector_index(CUSTOM_SKY_PANEL.controls.list)
            local selected = CUSTOM_SKY_PANEL.page_items[idx]
            if not selected then
                return
            end
            CUSTOM_SKY_PANEL.selected = tostring(selected)
            custom_sky_commit_runtime_state()
            if CUSTOM_SKY_PANEL.enabled == true then
                custom_sky_apply_mode_from_state(true)
            end
            -- Debounce notification: fire 2s after last selection change.
            CUSTOM_SKY_PANEL.notify_saved_at = runtime_now() + 2.0
        end)
    end

    if CUSTOM_SKY_PANEL.controls.rescan and CUSTOM_SKY_PANEL.controls.rescan.AddCallback then
        CUSTOM_SKY_PANEL.controls.rescan:AddCallback(function()
            custom_sky_force_rescan(true)
        end)
    end

    if CUSTOM_SKY_PANEL.controls.download_github and CUSTOM_SKY_PANEL.controls.download_github.AddCallback then
        CUSTOM_SKY_PANEL.controls.download_github:AddCallback(function()
            custom_sky_download_from_github()
        end)
    end

    if CUSTOM_SKY_PANEL.controls.open_folder and CUSTOM_SKY_PANEL.controls.open_folder.AddCallback then
        CUSTOM_SKY_PANEL.controls.open_folder:AddCallback(function()
            custom_sky_open_folder()
        end)
    end

    return true
end

-- ========== CONTROL LOOKUP ==========
function Utils.UI.get_control(path)
    if not path then return nil end

    -- During map transitions native controls may be recreated; avoid stale cached usertypes.
    local cache_allowed = not in_transition_cooldown()

    -- Check cache first
    if cache_allowed and UI.cache[path] then 
        return UI.cache[path] 
    end
    
    if gui and gui.ctx then
        local find_fn = gui.ctx.find or gui.ctx.Find
        if find_fn then
            local ok_find, ctrl = protected_call(find_fn, gui.ctx, path)
            if ok_find and ctrl then
                if cache_allowed then
                    UI.cache[path] = ctrl
                end
                return ctrl
            end
        end
    end
    return nil
end

-- ========== VALUE READ ==========
function Utils.UI.GetValue(ctrl)
    if not ctrl then return nil end
    local val = ctrl:GetValue()
    if val and val.Get then
        return val:Get()
    end
    return nil
end

-- ========== UNIVERSAL VALUE HELPERS ==========
function Utils.UI.GetBool(ctrl, default)
    if not ctrl then return default end
    local v = ctrl:GetValue()
    if v and v.Get then
        return v:Get() == true
    end
    return default
end

function Utils.UI.get_number(ctrl, default)
    if not ctrl then return default end
    local v = ctrl:GetValue()
    local n = v and v.Get and v:Get()
    return (type(n) == "number" and n) or default
end

-- ========== CONTROL SETTER HELPERS ==========
function Utils.UI.SetValue(path, value)
    local ctrl = Utils.UI.get_control(CONSTANTS.PATHS[path])
    if not ctrl then return false end
    local val = ctrl:GetValue()
    if val and val.Set then
        val:Set(value)
        return true
    end
    return false
end

function Utils.UI.set_color(key, rgba)
    -- When a custom skybox is active, the per-point sky-colour blending is redirected onto
    -- OUR own picker (which tints the custom skybox), and the cheat's native sky_color control
    -- is bypassed entirely (fully off). This moves the whole points->blend->colour logic 1:1
    -- onto the custom skybox: red at one point, blue at another, blended in between.
    if key == "sky_color" and CUSTOM_SKY_PANEL and CUSTOM_SKY_PANEL.enabled == true then
        if CM_SKY_COLOR_CTRL and CM_SKY_COLOR_CTRL.GetValue and rgba then
            local vp = CM_SKY_COLOR_CTRL:GetValue()
            if vp and vp.Set then
                vp:Set(draw.Color(rgba[1] or 255, rgba[2] or 255, rgba[3] or 255, rgba[4] or 255))
            end
        end
        local api = custom_sky_api()
        if api and type(api.refresh_tint) == "function" then
            protected_call(api.refresh_tint)
        end
        return true
    end

    local ctrl = Utils.UI.get_control(CONSTANTS.PATHS[key])
    if not ctrl then return false end
    local val = ctrl:GetValue()
    if val and val.Set and rgba then
        val:Set(draw.Color(rgba[1] or 255, rgba[2] or 255, rgba[3] or 255, rgba[4] or 255))
        if sync_elements_a_mirror_color_from_script then
            sync_elements_a_mirror_color_from_script(key, rgba)
        end
        return true
    end
    return false
end

function Utils.UI.set_bool(key, bool_value)
    return Utils.UI.SetValue(key, bool_value == true)
end

function Utils.UI.set_number(key, number_value)
    local ok = Utils.UI.SetValue(key, number_value or 0)
    -- Push to the elements-A mirror immediately, same as set_color does, so the
    -- mirror slider (e.g. Exposure) tracks script-driven changes without waiting
    -- for the next cheat->mirror poll.
    if ok and sync_elements_a_mirror_number_from_script then
        sync_elements_a_mirror_number_from_script(key, number_value or 0)
    end
    return ok
end

-- ========== COMBOBOX HELPERS (skybox) ==========
function Utils.UI.get_combo(key)
    local ctrl = Utils.UI.get_control(CONSTANTS.PATHS[key])
    if not ctrl then return 0 end
    
    local value_param = ctrl:GetValue()
    if value_param and value_param.Get then
        local bits = value_param:Get()
        if bits and bits.GetRaw then
            local raw = bits:GetRaw()
            if raw > 0 then
                return math.floor(math.log(raw) / math.log(2)) + 1
            end
        end
    end
    return 1
end

function Utils.UI.set_combo(key, index)
    local ctrl = Utils.UI.get_control(CONSTANTS.PATHS[key])
    if not ctrl then return false end
    
    local value_param = ctrl:GetValue()
    if not value_param then return false end
    
    local bits = value_param:Get()
    if bits and bits.SetRaw then
        local raw = math.floor(2 ^ (index - 1))
        bits:SetRaw(raw)
        if value_param.Set then
            value_param:Set(bits)
        end
        return true
    end
    return false
end

-- ========== CAPTURE CURRENT SETTINGS ==========
local function is_shader_settings_key(key)
    return type(key) == "string" and key:sub(1, 7) == "shader_"
end

local function strip_shader_settings(settings)
    if type(settings) ~= "table" then return settings end
    local stripped = {}
    local changed = false
    for k, v in pairs(settings) do
        -- Point settings must not carry shader/map-discrete state.
        -- `skybox` is discrete and causes hard visual snaps while blending.
        if is_shader_settings_key(k) or k == "skybox" then
            changed = true
        else
            stripped[k] = v
        end
    end
    if not changed then
        return settings
    end
    return stripped
end

filter_shader_settings_for_points = function(settings)
    if type(settings) ~= "table" then
        return settings
    end

    local filtered = {}
    local changed = false
    for k, v in pairs(settings) do
        if is_shader_settings_key(k) then
            if should_include_shader_key_in_points(k) then
                filtered[k] = v
            else
                changed = true
            end
        else
            filtered[k] = v
        end
    end

    if not changed then
        return settings
    end
    return filtered
end

-- ========== BLOOM save/load (map-scoped custom feature) ==========
-- The per-map config codec (get_preset_for_map / save_preset_for_map) only round-trips SCALARS and
-- top-level ARRAYS (it deep-copies tables with ipairs and diffs them by #length). A nested object
-- like {enable, globals={...}, levels={...}} silently loses its string-keyed data. So bloom is
-- persisted as ONE scalar string key, "bloom_json", which behaves exactly like any other scalar
-- setting (fog_size etc.). Format: "E|g1,..,g6|w1,..,w5|r1,g1,b1,..,r5,g5,b5". Controls live in the
-- global CM_BLOOM_CTRLS (built in create_elements_a_mirror_ui); resolved at call time.
-- "blend" is kept as a serialization PLACEHOLDER only: the Blend Mode slider was removed (it did
-- nothing on this build), but its slot stays in the bloom_json layout so existing saved map configs
-- (which encode 6 global values) still align on load. serialize writes 0 for it (no such slider);
-- apply skips it (no such control). Do NOT drop it -- that would shift every following value.
local BLOOM_GKEYS = { "blend", "strength", "screenstr", "blurstr", "threshold", "threshw" }

function cm_bloom_serialize()
    local B = CM_BLOOM_CTRLS
    if not (B and B.enable) then return nil end
    local en = (B.enable.Get and B.enable:Get()) == true
    local g = {}
    for _, k in ipairs(BLOOM_GKEYS) do
        local s = B.globals and B.globals[k]
        g[#g + 1] = string.format("%.4g", (s and s.Get and s:Get()) or 0)
    end
    local w, c = {}, {}
    for i = 1, 5 do
        local lv = B.levels and B.levels[i]
        local wv, r, gg, b = 0, 255, 255, 255
        if lv then
            wv = (lv.w and lv.w.Get and lv.w:Get()) or 0
            local col = lv.c and lv.c.Get and lv.c:Get() or nil
            if col and col.GetR then r = col:GetR(); gg = col:GetG(); b = col:GetB() end
        end
        w[#w + 1] = string.format("%.4g", wv)
        c[#c + 1] = string.format("%d,%d,%d", r, gg, b)
    end
    return (en and "1" or "0") .. "|" .. table.concat(g, ",") .. "|" .. table.concat(w, ",") .. "|" .. table.concat(c, ",")
end

local function cm_bloom_parse(str)
    if type(str) ~= "string" or str == "" then return nil end
    local parts = {}
    for seg in (str .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = seg end
    if #parts < 4 then return nil end
    local function nums(s) local t = {} for n in (s .. ","):gmatch("([^,]*),") do t[#t + 1] = tonumber(n) end return t end
    return { enable = parts[1] == "1", g = nums(parts[2]), w = nums(parts[3]), c = nums(parts[4]) }
end

-- Apply a serialized bloom string to the controls. No-op if str is nil (e.g. a point-blend
-- snapshot, which strips bloom_json) -> point blending never disturbs bloom.
function cm_bloom_apply(str)
    local bl = cm_bloom_parse(str)
    if not bl then return end
    local B = CM_BLOOM_CTRLS
    if not (B and B.enable) then return end
    -- Enable checkbox: push it ON only when the map config says so, and NEVER push it off. This
    -- restores bloom across a script reload.
    -- Asymmetric on purpose: "config says off" and "no config at all" both mean leave the user's
    -- hand-set checkbox alone, so the off-push -- the direction that desynced the widget -- never
    -- happens. Uses the valueparam path (:GetValue():Set), same as the sliders/pickers below;
    -- ctrl:SetValue() is what bugs the widget, not this.
    if bl.enable == true and B.enable.GetValue then B.enable:GetValue():Set(true) end
    if type(B.globals) == "table" then
        for idx, k in ipairs(BLOOM_GKEYS) do
            local s = B.globals[k]; local v = bl.g[idx]
            if s and s.GetValue and v ~= nil then s:GetValue():Set(v) end
        end
    end
    if type(B.levels) == "table" then
        for i = 1, 5 do
            local lv = B.levels[i]
            if lv then
                local wv = bl.w[i]
                if lv.w and lv.w.GetValue and wv ~= nil then lv.w:GetValue():Set(wv) end
                local r, g, b = bl.c[(i-1)*3+1], bl.c[(i-1)*3+2], bl.c[(i-1)*3+3]
                if lv.c and lv.c.GetValue and draw and draw.Color then
                    lv.c:GetValue():Set(draw.Color(r or 255, g or 255, b or 255))
                end
            end
        end
    end
end

-- Zero the VALUE sliders only (6 globals + 5 blur weights). Used at map load when the map has no
-- bloom config, so bloom never carries over from the previous map. Deliberately does NOT touch:
--  * the Enable checkbox -- toggling it programmatically bugs the widget (shows "on" while actually
--    off); bloom is disabled purely by zeroing strength/weights, not by the checkbox.
--  * the color pickers -- per user, colors are left as-is (only numeric settings are muted).
function cm_bloom_zero()
    local B = CM_BLOOM_CTRLS
    if not (B and B.enable) then return end
    if type(B.globals) == "table" then
        for _, s in pairs(B.globals) do
            if s and s.GetValue then s:GetValue():Set(0) end
        end
    end
    if type(B.levels) == "table" then
        for i = 1, 5 do
            local lv = B.levels[i]
            if lv and lv.w and lv.w.GetValue then lv.w:GetValue():Set(0) end
        end
    end
end

-- Map-load reconcile: apply the map's saved bloom, or ZERO everything when the map has none.
function cm_bloom_apply_or_zero(preset)
    local s = (type(preset) == "table") and preset.bloom_json or nil
    if type(s) == "string" and s ~= "" then cm_bloom_apply(s) else cm_bloom_zero() end
end

-- ========== TONEMAP + LOCAL CONTRAST save/load (map-scoped custom feature) ==========
-- Same reasoning as bloom above: the per-map config codec only round-trips SCALARS, so this is ONE
-- scalar string key, "postfx_json", map-scoped only and stripped from point snapshots -- point
-- blending never disturbs it. Format: "T|t1,..,tN|L|l1,..,lM" (enable bit + values, per section);
-- values are in the order CM_POSTFX_CTRLS lists them, i.e. the order the UI built them.
function cm_postfx_serialize()
    local P = CM_POSTFX_CTRLS
    if not (P and P.tone and P.lc) then return nil end
    local function sec(s)
        local en = (s.enable and s.enable.Get and s.enable:Get()) == true
        local v = {}
        for _, f in ipairs(s.fields or {}) do
            v[#v + 1] = string.format("%.4g", (f.ctrl and f.ctrl.Get and f.ctrl:Get()) or 0)
        end
        return (en and "1" or "0"), table.concat(v, ",")
    end
    local te, tv = sec(P.tone)
    local le, lv = sec(P.lc)
    return te .. "|" .. tv .. "|" .. le .. "|" .. lv
end

function cm_postfx_apply(str)
    if type(str) ~= "string" or str == "" then return end
    local P = CM_POSTFX_CTRLS
    if not (P and P.tone and P.lc) then return end
    local parts = {}
    for seg in (str .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = seg end
    if #parts < 4 then return end
    local function nums(s) local t = {} for n in (s .. ","):gmatch("([^,]*),") do t[#t + 1] = tonumber(n) end return t end
    local function put(s, enbit, vals)
        -- Same asymmetry as bloom: push the checkbox ON when the config says so, and NEVER push it
        -- off. "Config says off" and "no config at all" both mean leave the user's hand-set checkbox
        -- alone, so the off-push -- the direction that desyncs the widget -- never happens.
        if enbit == "1" and s.enable and s.enable.GetValue then s.enable:GetValue():Set(true) end
        for i, f in ipairs(s.fields or {}) do
            local v = vals[i]
            if f.ctrl and f.ctrl.GetValue and v ~= nil then f.ctrl:GetValue():Set(v) end
        end
    end
    put(P.tone, parts[1], nums(parts[2]))
    put(P.lc, parts[3], nums(parts[4]))
end

-- Map-load reconcile. Unlike bloom there is nothing to "zero": these settings have no neutral value
-- (a zeroed tonemap curve is not "off", it is broken), so the two cases are:
--   map HAS a saved config -> apply it, and mark the blocks seeded so the engine does not overwrite
--                             the user's saved curve with the map's own values;
--   map has NO config      -> clear the seed so the engine re-seeds from THIS map's look, instead of
--                             carrying the previous map's curve over.
function cm_postfx_apply_or_reseed(preset)
    local s = (type(preset) == "table") and preset.postfx_json or nil
    if type(s) == "string" and s ~= "" then
        cm_postfx_apply(s)
        if CM_POSTFX_MARK_SEEDED then CM_POSTFX_MARK_SEEDED() end
    else
        if CM_POSTFX_RESEED then CM_POSTFX_RESEED() end
    end
end

local function capture_current_settings(include_shader_settings)
    local captured = {}

    for _, key in ipairs(CONSTANTS.KEYS.COLOR) do
        if key == "sky_color" and CUSTOM_SKY_PANEL and CUSTOM_SKY_PANEL.enabled == true and CM_SKY_COLOR_CTRL then
            -- Custom skybox active -> the live sky colour lives in our picker, not the cheat
            -- control, so capture a point's sky_color from there (symmetric with set_color).
            local r, g, b, a = get_color_rgba(CM_SKY_COLOR_CTRL, 255, 255, 255, 255)
            captured[key] = {r, g, b, a}
        else
            local ctrl = Utils.UI.get_control(CONSTANTS.PATHS[key])
            local val = Utils.UI.GetValue(ctrl)
            if val then
                captured[key] = {val:GetR(), val:GetG(), val:GetB(), val:GetA()}
            else
                captured[key] = {255, 255, 255, 255}
            end
        end
    end
    
    local dof_ctrl = Utils.UI.get_control(CONSTANTS.PATHS.dof)
    local dof_val = Utils.UI.GetValue(dof_ctrl)
    local is_dof_enabled = (dof_val == true or dof_val == 1)
    -- captured.dof is not saved!
    
    local fog_ctrl = Utils.UI.get_control(CONSTANTS.PATHS.fog)
    local fog_val = Utils.UI.GetValue(fog_ctrl)
    local is_fog_enabled = (fog_val == true or fog_val == 1)
    captured.fog = is_fog_enabled

    -- Capture other booleans (local_chams)
    for _, key in ipairs(CONSTANTS.KEYS.BOOL) do
        if key ~= "dof" and key ~= "fog" then -- Special handling already done above or simple capture
            local ctrl = Utils.UI.get_control(CONSTANTS.PATHS[key])
            if ctrl then
                 local val = Utils.UI.GetValue(ctrl)
                 captured[key] = (val == true or val == 1)
            end
        end
    end
    
    for _, key in ipairs(CONSTANTS.KEYS.SLIDER) do
        local ctrl = Utils.UI.get_control(CONSTANTS.PATHS[key])
        local val = Utils.UI.GetValue(ctrl)
        captured[key] = tonumber(val) or 0
        
        -- Override values if checkbox is OFF
        
        -- DOF Logic: Strength -> 0
        if not is_dof_enabled and key == "dof_strength" then
             captured[key] = 0
        end
        
        -- Fog Logic: Transparency (Alpha 0) handled below.
        -- We do NOT change Size/Distance here anymore.
    end
    
    -- Fog Transparency Logic:
    -- If Fog is OFF, set fog_color Alpha to 0 (Invisible)
    if not is_fog_enabled and captured.fog_color then
        captured.fog_color[4] = 0
    end
    
    -- Skybox combobox (1-6)
    captured.skybox = Utils.UI.get_combo("skybox")
    do
        local selected_custom = tostring(CUSTOM_SKY_PANEL.selected or CUSTOM_SKY_DEFAULT_ENTRY)
        if CUSTOM_SKY_PANEL.enabled == true and selected_custom:lower() ~= CUSTOM_SKY_DEFAULT_ENTRY then
            captured.custom_skybox = selected_custom
        end
    end

    if include_shader_settings ~= false then
        -- Shader settings (except Color Replace, it's map-scoped only)
        local point_mode_shader_capture = (include_shader_settings == true)
        local shader_captured = capture_current_shader_settings()
        for k, v in pairs(shader_captured) do
            if (not point_mode_shader_capture) or should_include_shader_key_in_points(k) then
                captured[k] = v
            end
        end
    end

    -- Bloom (custom feature; one scalar string key so the map config codec round-trips it -- see
    -- cm_bloom_serialize above). Map-scoped only -- stripped from point snapshots.
    local bloom_str = cm_bloom_serialize()
    if bloom_str then captured.bloom_json = bloom_str end

    -- Tonemap + local contrast: same deal, one scalar string key, map-scoped only.
    local postfx_str = cm_postfx_serialize()
    if postfx_str then captured.postfx_json = postfx_str end

    return captured
end

-- ========== APPLY SETTINGS ==========
local function apply_settings(settings, apply_shader_state)
    if not settings then return false end
    
    -- Apply color settings using helper
    for _, key in ipairs(CONSTANTS.KEYS.COLOR) do
        if settings[key] then
            Utils.UI.set_color(key, settings[key])
                end
            end
            
    -- Apply boolean settings using helper
    for _, key in ipairs(CONSTANTS.KEYS.BOOL) do
        if settings[key] ~= nil then
            Utils.UI.set_bool(key, settings[key])
        end
    end
    
    -- Apply slider settings using helper
    for _, key in ipairs(CONSTANTS.KEYS.SLIDER) do
        if settings[key] ~= nil then
            Utils.UI.set_number(key, tonumber(settings[key]))
        end
    end
    
    -- Apply skybox combobox / custom skybox runtime.
    local custom_name = nil
    if settings.custom_skybox ~= nil then
        custom_name = tostring(settings.custom_skybox or CUSTOM_SKY_DEFAULT_ENTRY)
        if custom_name == "" then
            custom_name = CUSTOM_SKY_DEFAULT_ENTRY
        end
        CUSTOM_SKY_PANEL.selected = custom_name
    end
    if settings.skybox ~= nil then
        CUSTOM_SKY_PANEL.last_standard_index = tonumber(settings.skybox) or CUSTOM_SKY_PANEL.last_standard_index or 1
    end
    if custom_name and custom_name:lower() ~= CUSTOM_SKY_DEFAULT_ENTRY then
        if CUSTOM_SKY_PANEL.scan_completed ~= true then
            custom_sky_schedule_scan(CUSTOM_SKY_PANEL.scan_delay)
        end
        -- Pre-check: if file doesn't exist, clear to default before doing anything with the runtime.
        local api_chk = custom_sky_api()
        if api_chk and type(api_chk.exists) == "function" then
            local ok_ex, ex = protected_call(api_chk.exists, custom_name)
            if (not ok_ex) or ex ~= true then
                CUSTOM_SKY_PANEL.selected = CUSTOM_SKY_DEFAULT_ENTRY
                custom_name = CUSTOM_SKY_DEFAULT_ENTRY
                custom_sky_notify_missing(custom_name)
            end
        end
        if custom_name:lower() ~= CUSTOM_SKY_DEFAULT_ENTRY then
            -- Auto-enable custom skybox: if it's saved in config it was enabled when saved.
            CUSTOM_SKY_PANEL.enabled = true
            custom_sky_sync_ui()
            custom_sky_update_mirror_skybox_visibility()
            custom_sky_resync_to_selected()
            custom_sky_schedule_enable_apply(true, CUSTOM_SKY_ENABLE_APPLY_DELAY)
        else
            custom_sky_schedule_enable_apply(false, CUSTOM_SKY_ENABLE_APPLY_DELAY)
        end
    elseif settings.skybox ~= nil then
        CUSTOM_SKY_PANEL.last_missing_notice = ""
        CUSTOM_SKY_PANEL.selected = CUSTOM_SKY_DEFAULT_ENTRY
        CUSTOM_SKY_PANEL.enabled = false
        custom_sky_sync_ui()
        custom_sky_update_mirror_skybox_visibility()
        Utils.UI.set_combo("skybox", tonumber(settings.skybox) or 1)
        -- Defer restore to on_frame: calling UpdateSkybox from a UI callback crashes.
        custom_sky_schedule_enable_apply(false, CUSTOM_SKY_ENABLE_APPLY_DELAY)
    end

    -- Apply shader settings through shader API
    if apply_shader_state ~= false then
        apply_shader_settings(settings)
    end

    -- Bloom (map-scoped custom feature) -- push saved state back into CM_BLOOM_CTRLS controls; the
    -- bloom engine picks the new values up on its next frame (it reads these controls live). When
    -- settings.bloom_json is absent (e.g. a point-blend snapshot, which strips it), cm_bloom_apply
    -- is a no-op -- so point blending never touches bloom. The "no map config -> zero it out" case
    -- is handled at the map-load boundary (on_map_loaded), NOT here, precisely because here nil
    -- also means "point blend, leave alone".
    cm_bloom_apply(settings.bloom_json)
    -- Tonemap + local contrast: identical contract (nil = point blend -> no-op).
    cm_postfx_apply(settings.postfx_json)

    return true
end

-- ========== CONFIG SAVE/LOAD ==========
function make_default_combined_config()
    return {
        version = CONSTANTS.DEFAULTS.VERSION,
        config = {
            version = 1,
            defaults = {},
            maps = {}
        },
        points = {
            version = 2,
            maps = {}
        },
        weights = {
            version = 1,
            maps = {}
        },
        shaders = {
            version = 1,
            enabled = true,
            global = {},
            map_replace = {}
        }
    }
end

local function normalize_points_maps(maps)
    if type(maps) ~= "table" then
        return {}
    end

    for map_name, map_data in pairs(maps) do
        if type(map_data) ~= "table" then
            maps[map_name] = { points = {} }
        else
            if type(map_data.points) ~= "table" then
                map_data.points = {}
            end

            local sanitized = {}
            for i = 1, #map_data.points do
                local point = map_data.points[i]
                if type(point) == "table" then
                    local px = tonumber(point.x)
                    local py = tonumber(point.y)
                    local pz = tonumber(point.z)
                    if px and py and pz then
                        point.x = px
                        point.y = py
                        point.z = pz
                        if type(point.settings) ~= "table" then
                            point.settings = {}
                        end
                        sanitized[#sanitized + 1] = point
                    end
                end
            end
            map_data.points = sanitized
        end
    end

    return maps
end

function normalize_combined_config(data)
    if type(data) ~= "table" then
        data = make_default_combined_config()
    end
    if type(data.config) ~= "table" then data.config = {version = 1, defaults = {}, maps = {}} end
    if type(data.config.defaults) ~= "table" then data.config.defaults = {} end
    if type(data.config.maps) ~= "table" then data.config.maps = {} end

    if type(data.points) ~= "table" then data.points = {version = 2, maps = {}} end
    if type(data.points.maps) ~= "table" then data.points.maps = {} end
    data.points.maps = normalize_points_maps(data.points.maps)

    if type(data.weights) ~= "table" then data.weights = {version = 1, maps = {}} end
    if type(data.weights.maps) ~= "table" then data.weights.maps = {} end

    if type(data.shaders) ~= "table" then data.shaders = {version = 1, enabled = true, global = {}, map_replace = {}} end
    if data.shaders.enabled == nil then data.shaders.enabled = true end
    data.shaders.enabled = (data.shaders.enabled == true)
    if type(data.shaders.global) ~= "table" then data.shaders.global = {} end
    if type(data.shaders.map_replace) ~= "table" then data.shaders.map_replace = {} end

    data.version = CONSTANTS.DEFAULTS.VERSION
    return data
end

function Utils.Config.get_legacy_cfg_paths()
    local raw = { CONSTANTS.FILES.COMBINED }
    local out = {}
    local seen = {}
    for i = 1, #raw do
        local path = tostring(raw[i] or "")
        if path ~= "" then
            local key = path:gsub("\\", "/"):lower()
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = path
            end
        end
    end
    return out
end

function Utils.Config.load_legacy_cfg_file(path, skip_migrated)
    local resolved = Utils.Config.find_existing_path(path)
    if not resolved then
        return nil, nil
    end

    local data = Utils.File.load_json(resolved)
    if type(data) ~= "table" then
        return nil, resolved
    end

    if skip_migrated == true and data[CONSTANTS.FILES.LEGACY_MIGRATED_KEY] == true then
        return nil, resolved
    end

    return data, resolved
end

function Utils.Config.mark_legacy_cfg_files(profile_name)
    local marked = 0
    local target = Utils.Config.sanitize_profile_name(profile_name) or CONSTANTS.FILES.PROFILE_OLD_DEFAULT
    local paths = Utils.Config.get_legacy_cfg_paths()

    for i = 1, #paths do
        local data, resolved = Utils.Config.load_legacy_cfg_file(paths[i], false)
        if type(data) == "table" and type(resolved) == "string" and resolved ~= "" then
            data[CONSTANTS.FILES.LEGACY_MIGRATED_KEY] = true
            data[CONSTANTS.FILES.LEGACY_MIGRATED_PROFILE_KEY] = target
            data[CONSTANTS.FILES.LEGACY_MIGRATED_AT_KEY] = runtime_now()
            data[CONSTANTS.FILES.LEGACY_MIGRATED_BY_KEY] = "Map manager"
            if Utils.File.save_json(resolved, data) then
                marked = marked + 1
            end
        end
    end

    return marked
end

function Utils.Config.table_has_any_entries(t)
    return type(t) == "table" and next(t) ~= nil
end

function Utils.Config.looks_like_clmp_world_config(data)
    if type(data) ~= "table" then
        return false
    end
    return type(data.maps) == "table" and (data.defaults ~= nil or data.version ~= nil)
end

function Utils.Config.build_combined_from_old_scripts()
    local combined = make_default_combined_config()
    local found = false

    -- Old unified file (from previous combined builds).
    local old_unified = Utils.Config.load_legacy_cfg_file(CONSTANTS.FILES.COMBINED, true)
    if type(old_unified) == "table" then
        if type(old_unified.config) == "table"
            or type(old_unified.points) == "table"
            or type(old_unified.weights) == "table"
            or type(old_unified.shaders) == "table" then
            combined = normalize_combined_config(old_unified)
            found = true
        elseif Utils.Config.looks_like_clmp_world_config(old_unified) then
            combined.config = old_unified
            found = true
        end
    end

    return normalize_combined_config(combined), found
end

function Utils.Config.migrate_old_scripts_to_old_default()
    return false, "disabled"
end

function Utils.Config.import_from_legacy_cfg()
    return false, "disabled"
end

local function save_all_configs()
    local combined = normalize_combined_config(State.combined_config or make_default_combined_config())
    combined.config = State.config or combined.config
    combined.points = State.points_config or combined.points
    combined.weights = State.weights_config or combined.weights
    combined.shaders = State.shaders_config or combined.shaders

    State.combined_config = normalize_combined_config(combined)
    return Utils.Config.save(Utils.Config.GetActive_combined_path(), State.combined_config)
end

local function load_all_configs()
    local combined = nil

    local loaded = Utils.Config.load(Utils.Config.GetActive_combined_path(), nil)
    if type(loaded) == "table" then
        combined = normalize_combined_config(loaded)
    end

    if not combined then
        local active_name = Utils.Config.GetActive_profile_name()
        if active_name == CONSTANTS.FILES.PROFILE_DEFAULT then
            local legacy_combined = Utils.Config.load(CONSTANTS.FILES.COMBINED, nil)
            if type(legacy_combined) == "table" then
                combined = normalize_combined_config(legacy_combined)
                Utils.Config.save(Utils.Config.GetActive_combined_path(), combined)
            end
        end
    end

    if not combined then
        -- Nothing found: start from a clean config.
        combined = normalize_combined_config(make_default_combined_config())
    end

    State.combined_config = normalize_combined_config(combined)
    State.config = State.combined_config.config
    State.points_config = State.combined_config.points
    State.weights_config = State.combined_config.weights
    State.shaders_config = State.combined_config.shaders
end

local function save_config()
    save_all_configs()
end

local function load_config()
    load_all_configs()
    if not State.config.defaults then State.config.defaults = {} end
end

-- ========== POINTS CONFIG ==========
local function save_points_config()
    save_all_configs()
end

local function load_points_config()
    load_all_configs()
end

-- ========== WEIGHTS CONFIG ==========
local function save_weights_config()
    save_all_configs()
end

local function load_weights_config()
    load_all_configs()
end

-- ========== PROFILE CONFIGS ==========
function Utils.Config.trim_string(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

function Utils.Config.strip_json_extension(name)
    if type(name) ~= "string" then
        return ""
    end
    if name:lower():sub(-5) == ".json" then
        return name:sub(1, -6)
    end
    return name
end

function Utils.Config.sanitize_profile_name(raw)
    local name = tostring(raw or "")
    name = name:gsub("%z", "")
    name = name:gsub("[%c]", " ")
    name = Utils.Config.trim_string(name)
    name = Utils.Config.strip_json_extension(name)
    name = Utils.Config.trim_string(name)
    if name == "" then
        return nil
    end
    if #name > 96 then
        name = name:sub(1, 96)
    end
    if name == "" then
        return nil
    end
    return name
end

function Utils.Config.legacy_profile_basename(profile_name)
    local name = Utils.Config.trim_string(tostring(profile_name or ""))
    if name == "" then
        return CONSTANTS.FILES.PROFILE_DEFAULT
    end
    name = name:gsub("[\\/:*?\"<>|]", "_")
    name = name:gsub("%s+", " ")
    if name:sub(1, 1) == "." then
        name = "_" .. name:sub(2)
    end
    if #name > 48 then
        name = name:sub(1, 48)
    end
    name = Utils.Config.trim_string(name)
    if name == "" then
        return CONSTANTS.FILES.PROFILE_DEFAULT
    end
    return name
end

function Utils.Config.encode_profile_basename(profile_name)
    local name = Utils.Config.sanitize_profile_name(profile_name) or CONSTANTS.FILES.PROFILE_DEFAULT
    local hex = {}
    for i = 1, #name do
        hex[#hex + 1] = string.format("%02X", string.byte(name, i))
    end
    return "cmh_" .. table.concat(hex)
end

function Utils.Config.decode_profile_basename(raw)
    if type(raw) ~= "string" then
        return nil
    end
    local hex = nil
    if raw:sub(1, 4) == "cmh_" then
        hex = raw:sub(5)
    elseif raw:sub(1, 6) == "__cmh_" then
        hex = raw:sub(7)
    elseif raw:sub(1, 2) == "p_" then
        hex = raw:sub(3)
    else
        return nil
    end
    if hex == "" or (#hex % 2) ~= 0 then
        return nil
    end

    local out = {}
    for i = 1, #hex, 2 do
        local pair = hex:sub(i, i + 1)
        if not pair:match("^[0-9A-Fa-f][0-9A-Fa-f]$") then
            return nil
        end
        out[#out + 1] = string.char(tonumber(pair, 16))
    end

    return Utils.Config.sanitize_profile_name(table.concat(out))
end

function Utils.Config.is_storage_safe_basename(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    if name:find("[\\/:*?\"<>|]") then
        return false
    end
    if name:sub(1, 1) == "." then
        return false
    end
    if name:sub(-1) == "." or name:sub(-1) == " " then
        return false
    end
    if name:sub(1, 1) == "_" then
        return false
    end
    return true
end

function Utils.Config.get_profile_storage_basename(profile_name)
    local name = Utils.Config.sanitize_profile_name(profile_name) or CONSTANTS.FILES.PROFILE_DEFAULT
    if Utils.Config.is_storage_safe_basename(name) then
        return name
    end
    return Utils.Config.encode_profile_basename(name)
end

-- Inverse of get_profile_storage_basename: turn a file basename (without the
-- .json extension) back into the profile name. Encoded basenames (cmh_/p_/
-- __cmh_) are decoded; plain basenames are used as-is. This is what makes the
-- folder scan show real names instead of raw hex.
function Utils.Config.name_from_basename(basename)
    if type(basename) ~= "string" or basename == "" then
        return nil
    end
    local decoded = Utils.Config.decode_profile_basename(basename)
    if decoded then
        return decoded
    end
    return Utils.Config.sanitize_profile_name(basename)
end

function Utils.Config.get_profile_file_path(profile_name)
    local storage_name = Utils.Config.get_profile_storage_basename(profile_name)
    return Utils.Config.get_profiles_dir() .. "/" .. storage_name .. ".json"
end

-- Legacy path is only consulted for existence checks during migration / unique
-- name generation. Old profiles lived directly under fatality/.
function Utils.Config.get_profile_legacy_file_path(profile_name)
    local legacy_name = Utils.Config.legacy_profile_basename(profile_name)
    return "fatality/" .. legacy_name .. ".json"
end

-- TextInput exposes its text through the read-only `value` field.
function Utils.Config.read_profile_name_input(control)
    if not control then
        return ""
    end
    local value = control.value
    if type(value) ~= "string" then
        return ""
    end
    return Utils.Config.trim_string(value)
end

-- TextInput:SetValue(str) sets the text.
function Utils.Config.write_profile_name_input(control, text)
    if not control or not control.SetValue then
        return false
    end
    return protected_call(control.SetValue, control, tostring(text or "")) == true
end

function Utils.Config.profile_exists(profile_name)
    local name = Utils.Config.sanitize_profile_name(profile_name)
    if not name then
        return false
    end
    local main_path = Utils.Config.find_existing_path(Utils.Config.get_profile_file_path(name))
    return main_path ~= nil
end

function Utils.Config.delete_profile(raw_name)
    local name = Utils.Config.sanitize_profile_name(raw_name)
    if not name then
        return false, "Invalid profile name"
    end

    local active_before = Utils.Config.GetActive_profile_name()
    local was_active = (active_before == name)

    local path = Utils.Config.get_profile_file_path(name)
    if not Utils.File.exists(path) then
        return false, "Config file not found"
    end

    Utils.File.remove(path)
    if Utils.File.exists(path) then
        return false, "Failed to delete config file"
    end

    Utils.Config.refresh_profiles_registry()
    Utils.Config.sync_profiles_combo_ui()
    Utils.Config.save_profile_index(State.profiles.list)

    if was_active then
        local fallback = nil
        local list = State.profiles and State.profiles.list or {}
        for i = 1, #list do
            if list[i] ~= name then
                fallback = list[i]
                break
            end
        end
        fallback = Utils.Config.sanitize_profile_name(fallback) or CONSTANTS.FILES.PROFILE_DEFAULT

        if not Utils.Config.profile_exists(fallback) then
            local created, create_result = Utils.Config.create_profile_from_current(
                fallback,
                make_default_combined_config()
            )
            if not created then
                return false, "Deleted, but failed to create fallback profile: " .. tostring(create_result)
            end
            fallback = create_result
        end

        Utils.Config.switch_profile(fallback, "delete")
    else
        Utils.Config.select_profile_in_ui(active_before)
    end

    return true, name
end

function Utils.Config.overwrite_profile_from_snapshot(raw_name, snapshot_override)
    local name = Utils.Config.sanitize_profile_name(raw_name)
    if not name then
        return false, "Invalid profile name"
    end

    Utils.Config.ensure_profiles_dir()

    local snapshot = nil
    if type(snapshot_override) == "table" then
        snapshot = normalize_combined_config(snapshot_override)
    else
        snapshot = normalize_combined_config(State.combined_config or make_default_combined_config())
    end

    local path = Utils.Config.get_profile_file_path(name)
    local legacy_path = Utils.Config.get_profile_legacy_file_path(name)

    local saved = Utils.Config.save(path, snapshot)
    if (not saved) and legacy_path ~= path then
        saved = Utils.Config.save(legacy_path, snapshot)
        if saved then
            path = legacy_path
        end
    end

    if not saved then
        return false, "Failed to overwrite config file (" .. tostring(path) .. ")"
    end

    Utils.Config.refresh_profiles_registry()
    Utils.Config.sync_profiles_combo_ui()
    Utils.Config.save_profile_index(State.profiles.list)
    Utils.Config.switch_profile(name, "overwrite")
    return true, name
end

function Utils.Config.GetActive_profile_name()
    if type(State.profiles) ~= "table" then
        State.profiles = {}
    end
    local active = Utils.Config.sanitize_profile_name(State.profiles.active_name) or CONSTANTS.FILES.PROFILE_DEFAULT
    State.profiles.active_name = active
    return active
end

function Utils.Config.GetActive_combined_path()
    return Utils.Config.get_profile_file_path(Utils.Config.GetActive_profile_name())
end

function Utils.Config.get_profiles_dir()
    return CONSTANTS.FILES.PROFILES_DIR
end

function Utils.Config.get_combined_base_dir()
    -- The combined config lives directly under fatality/.
    return "fatality"
end

function Utils.Config.get_profiles_state_path()
    return CONSTANTS.FILES.PROFILES_STATE
end

function Utils.Config.get_profiles_index_path()
    return CONSTANTS.FILES.PROFILES_INDEX
end

-- Creates the dedicated storage directory. Paths in the Fatality file API are
-- always relative to game/csgo, so there is a single canonical location and no
-- need to probe for the "right" working directory.
function Utils.Config.ensure_profiles_dir()
    if type(State.profiles) ~= "table" then
        State.profiles = {}
    end
    Utils.File.make_dirs(CONSTANTS.FILES.PROFILES_DIR)
    State.profiles.base_dir = CONSTANTS.FILES.PROFILES_DIR
    return true
end

function Utils.Config.load_profile_state()
    local data = Utils.Config.load(Utils.Config.get_profiles_state_path(), nil)
    if type(data) ~= "table" then
        return nil
    end
    return Utils.Config.sanitize_profile_name(data.active_name or data.active)
end

function Utils.Config.save_profile_state(profile_name)
    local active = Utils.Config.sanitize_profile_name(profile_name) or CONSTANTS.FILES.PROFILE_DEFAULT

    Utils.Config.save(Utils.Config.get_profiles_state_path(), {
        version = 1,
        active_name = active,
        updated_at = runtime_now()
    })
end

function Utils.Config.load_profile_index()
    local names = {}
    local seen = {}

    local function ingest(data)
        if type(data) ~= "table" or type(data.names) ~= "table" then
            return
        end
        for i = 1, #data.names do
            local name = Utils.Config.sanitize_profile_name(data.names[i])
            if name and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end

    ingest(Utils.Config.load(Utils.Config.get_profiles_index_path(), nil))

    return names
end

function Utils.Config.save_profile_index(names)
    local list = {}
    local seen = {}
    if type(names) == "table" then
        for i = 1, #names do
            local name = Utils.Config.sanitize_profile_name(names[i])
            if name and not seen[name] then
                seen[name] = true
                list[#list + 1] = name
            end
        end
    end
    Utils.Config.save(Utils.Config.get_profiles_index_path(), {
        version = 1,
        names = list,
        updated_at = runtime_now()
    })
end

function Utils.Config.ensure_profile_in_light_registry(profile_name)
    local name = Utils.Config.sanitize_profile_name(profile_name)
    if not name then
        return false
    end

    if type(State.profiles) ~= "table" then
        State.profiles = {}
    end
    if type(State.profiles.list) ~= "table" then
        State.profiles.list = {}
    end

    local i
    for i = 1, #State.profiles.list do
        if State.profiles.list[i] == name then
            return false
        end
    end

    State.profiles.list[#State.profiles.list + 1] = name
    table_sort(State.profiles.list)
    State.profiles.list_signature = table.concat(State.profiles.list, "\n")
    State.profiles.option_ids_signature = nil
    Utils.Config.save_profile_index(State.profiles.list)
    Utils.Config.sync_profiles_combo_ui()
    return true
end

-- Lists profiles by reading the dedicated profiles directory directly. The
-- file name is decoded back into the real profile name, and only files that
-- actually contain a profile payload (or a legacy snapshot) are listed. The
-- on-disk folder is the single source of truth; the index file is just a cache
-- that this function rewrites.
function Utils.Config.scan_profiles_from_dir()
    Utils.Config.ensure_profiles_dir()

    local names = {}
    local seen_lower = {}

    local function add_name(raw_name)
        local name = Utils.Config.sanitize_profile_name(raw_name)
        if not name or name == "" then
            return false
        end
        local key = name:lower()
        if seen_lower[key] then
            return false
        end
        seen_lower[key] = true
        names[#names + 1] = name
        return true
    end

    local dir = Utils.Config.get_profiles_dir()
    local entries = Utils.File.enumerate(dir .. "/*.json")
    for i = 1, #entries do
        local raw = tostring(entries[i] or ""):gsub("\\", "/")
        local basename = raw:match("([^/]+)%.json$")
        -- Skip bookkeeping/hidden files (they normally live one level up, but be
        -- defensive in case the runtime returns them).
        if basename and basename:sub(1, 1) ~= "_" and basename:sub(1, 1) ~= "." then
            local full = raw:find("/") and raw or (dir .. "/" .. raw)
            local data = Utils.File.load_json(full)
            if Utils.Config.is_profile_payload(data) or Utils.Config.is_legacy_profile_snapshot(data) then
                add_name(Utils.Config.name_from_basename(basename))
            end
        end
    end

    -- Always expose the canonical default entry so the selector is never empty.
    add_name(CONSTANTS.FILES.PROFILE_DEFAULT)

    table_sort(names)
    Utils.Config.save_profile_index(names)
    Utils.Config.log("scan_profiles_from_dir found=" .. tostring(#names), true)
    return names
end

function Utils.Config.find_profile_index(profile_name)
    local target = Utils.Config.sanitize_profile_name(profile_name)
    if not target then return nil end
    local list = State.profiles and State.profiles.list
    if type(list) ~= "table" then return nil end
    for i = 1, #list do
        if list[i] == target then
            return i
        end
    end
    return nil
end

function Utils.Config.refresh_profiles_registry()
    if type(State.profiles) ~= "table" then
        State.profiles = {}
    end
    if type(State.profiles.option_ids) ~= "table" then
        State.profiles.option_ids = {}
    end
    local scanned = Utils.Config.scan_profiles_from_dir()
    local list = {}
    local seen = {}
    local seen_lower = {}
    if type(scanned) == "table" then
        for i = 1, #scanned do
            local name = Utils.Config.sanitize_profile_name(scanned[i])
            local lower_name = name and name:lower() or nil
            if name and not seen_lower[lower_name] then
                seen[name] = true
                seen_lower[lower_name] = true
                list[#list + 1] = name
            end
        end
    end

    local active = Utils.Config.GetActive_profile_name()
    if active and (not Utils.Config.profile_exists(active)) then
        local fallback = CONSTANTS.FILES.PROFILE_DEFAULT
        if not Utils.Config.profile_exists(fallback) and #list > 0 then
            fallback = list[1]
        end
        active = Utils.Config.sanitize_profile_name(fallback) or CONSTANTS.FILES.PROFILE_DEFAULT
        State.profiles.active_name = active
        Utils.Config.save_profile_state(active)
    end

    local active_lower = active and active:lower() or nil
    if active and not seen_lower[active_lower] then
        seen[active] = true
        seen_lower[active_lower] = true
        list[#list + 1] = active
    end

    table_sort(list)

    local new_signature = table.concat(list, "\n")
    State.profiles.list = list
    State.profiles.list_signature = new_signature

    Utils.Config.save_profile_index(State.profiles.list)
end

function Utils.Config.sync_profiles_combo_ui()
    if not UI.main.profile_combo then return end
    if type(State.profiles) ~= "table" then
        State.profiles = {}
    end
    if type(State.profiles.option_ids) ~= "table" then
        State.profiles.option_ids = {}
    end
    if type(State.profiles.option_objects) ~= "table" then
        State.profiles.option_objects = {}
    end
    if State.profiles.option_ids_initialized ~= true then
        State.profiles.option_ids_combo = UI.main.profile_combo
        State.profiles.option_ids = {}
        State.profiles.option_objects = {}
        State.profiles.option_ids_initialized = true
    end

    local prev_syncing = (State.profiles.ui_syncing == true)
    State.profiles.ui_syncing = true

    local list = State.profiles.list or {}
    local list_signature = table.concat(list, "\n")
    local existing = State.profiles.option_ids
    local objects = State.profiles.option_objects

    local add_fn = UI.main.profile_combo.Add
    local remove_fn = UI.main.profile_combo.Remove
    local clear_fn =
        UI.main.profile_combo.RemoveAll or
        UI.main.profile_combo.ClearChildren or
        UI.main.profile_combo.Clear
    local added = 0

    local need_rebuild = (State.profiles.option_ids_signature ~= list_signature)
    local did_reset_cache = false
    if need_rebuild then
        local cleared = false

        if type(remove_fn) == "function" then
            for _, ctrl in pairs(objects) do
                if ctrl then
                    protected_call(remove_fn, UI.main.profile_combo, ctrl)
                    cleared = true
                end
            end
        end

        if (not cleared) and type(clear_fn) == "function" then
            local ok_clear, clear_ret = protected_call(clear_fn, UI.main.profile_combo)
            if ok_clear and clear_ret ~= false then
                cleared = true
            end
        end

        if cleared then
            existing = {}
            objects = {}
            State.profiles.option_ids = existing
            State.profiles.option_objects = objects
            did_reset_cache = true
        end
    end

    if not need_rebuild then
        if not prev_syncing then
            State.profiles.ui_syncing = false
        end
        return 0
    end

    if not did_reset_cache then
        local valid_names = {}
        for i = 1, #list do
            valid_names[list[i]] = true
        end
        for name, _ in pairs(existing) do
            if not valid_names[name] then
                existing[name] = nil
                objects[name] = nil
            end
        end
    end

    if type(add_fn) == "function" then
        for i = 1, #list do
            local name = list[i]
            if existing[name] then
                goto continue
            end
            local safe_name = name:gsub("[^%w_]", "_")
            local opt_id = "cm_profile_opt_" .. safe_name .. "_" .. tostring(i)
            local id_attempt = 1
            local function is_id_used(id)
                for _, used_id in pairs(existing) do
                    if used_id == id then
                        return true
                    end
                end
                return false
            end
            while is_id_used(opt_id) do
                id_attempt = id_attempt + 1
                opt_id = "cm_profile_opt_" .. safe_name .. "_" .. tostring(i) .. "_" .. tostring(id_attempt)
            end

            local selectable = gui.Selectable(gui.ControlID(opt_id), name)
            local ok_add, add_ret = protected_call(add_fn, UI.main.profile_combo, selectable)
            if ok_add and add_ret ~= false then
                existing[name] = opt_id
                objects[name] = selectable
                added = added + 1
            end
            ::continue::
        end
    else
        existing = {}
        objects = {}
        State.profiles.option_ids = existing
        State.profiles.option_objects = objects
    end

    State.profiles.option_ids_signature = list_signature

    local process_fn = UI.main.profile_combo.ProcessQueues
    if type(process_fn) == "function" then
        protected_call(process_fn, UI.main.profile_combo)
    end

    local raise_fn = UI.main.profile_combo.RaiseFirstRenderCall
    if type(raise_fn) == "function" then
        protected_call(raise_fn, UI.main.profile_combo)
    end

    if not prev_syncing then
        State.profiles.ui_syncing = false
    end
    return added
end

function Utils.Config.refresh_profiles_ui()
    local active_before = Utils.Config.GetActive_profile_name()
    if type(State.profiles) ~= "table" then
        State.profiles = {}
    end
    State.profiles.selector_suspend_until = runtime_now() + 0.40
    Utils.Config.ensure_profiles_dir()
    Utils.Config.refresh_profiles_registry()
    -- Force full selector rebuild on refresh button, but keep existing control refs
    -- so stale entries can be removed from the UI container queue.
    State.profiles.option_ids_signature = nil
    Utils.Config.sync_profiles_combo_ui()

    local active_target = Utils.Config.sanitize_profile_name(active_before)
    if (not active_target) or (not Utils.Config.find_profile_index(active_target)) then
        active_target = Utils.Config.GetActive_profile_name()
    end
    if active_target and Utils.Config.find_profile_index(active_target) then
        State.profiles.active_name = active_target
        Utils.Config.select_profile_in_ui(active_target)
    end

    if type(State.profiles) == "table" and type(State.profiles.list) == "table" then
        Utils.Config.log("refresh_profiles_ui names=" .. table.concat(State.profiles.list, ","), true)
    end
    return State.profiles and State.profiles.list and #State.profiles.list or 0
end

-- Resolves the absolute path of the game/csgo directory (the root that the
-- Fatality file API is relative to). Derived once from the main module path:
-- <root>/game/bin/win64/cs2.exe  ->  <root>/game/csgo
function Utils.Config.get_csgo_abs_dir()
    if Utils.Config._csgo_abs_dir ~= nil then
        return Utils.Config._csgo_abs_dir or nil
    end
    Utils.Config._csgo_abs_dir = false

    if not (ffi and utils and utils.FindExport) then
        return nil
    end
    local addr = utils.FindExport("kernel32.dll", "GetModuleFileNameA")
    if not addr or addr == 0 then
        return nil
    end

    local ok, dir = protected_call(function()
        local GetModuleFileNameA = ffi.cast(
            "unsigned long(*)(void*, char*, unsigned long)", addr
        )
        local buf = ffi.new("char[520]")
        local n = GetModuleFileNameA(nil, buf, 520)
        if n == 0 then
            return nil
        end
        local exe = ffi.string(buf, n):gsub("\\", "/")
        local game_dir = exe:match("^(.*)/bin/win64/[^/]+$")
            or exe:match("^(.*)/[^/]+/[^/]+/[^/]+$")
        if not game_dir or game_dir == "" then
            return nil
        end
        return game_dir .. "/csgo"
    end)

    if ok and type(dir) == "string" and dir ~= "" then
        Utils.Config._csgo_abs_dir = dir
        return dir
    end
    return nil
end

-- Opens the profiles directory in Windows Explorer via ShellExecuteA.
-- os.execute is unavailable in the locked sandbox, so we call the WinAPI
-- directly through the utils.FindExport + ffi bridge.
function Utils.Config.open_profiles_folder()
    Utils.Config.ensure_profiles_dir()

    local rel = Utils.Config.get_profiles_dir()
    local base = Utils.Config.get_csgo_abs_dir()
    local path = (base and (base .. "/" .. rel)) or rel
    path = path:gsub("/", "\\")

    if not (ffi and utils and utils.FindExport) then
        return false
    end
    local addr = utils.FindExport("shell32.dll", "ShellExecuteA")
    if not addr or addr == 0 then
        return false
    end

    local ok = protected_call(function()
        local ShellExecuteA = ffi.cast(
            "void*(*)(void*, const char*, const char*, const char*, const char*, int)", addr
        )
        -- ShellExecuteA(NULL, "open", path, NULL, NULL, SW_SHOWNORMAL)
        ShellExecuteA(nil, "open", path, nil, nil, 1)
        return true
    end)
    return ok == true
end

function Utils.Config.ensure_profile_file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    if Utils.File.exists(path) then
        return true
    end
    return Utils.File.save_json(path, {}) and Utils.File.exists(path)
end

function Utils.Config.select_profile_in_ui(profile_name)
    if not UI.main.profile_combo or not UI.main.profile_combo.GetValue then return end
    local idx = Utils.Config.find_profile_index(profile_name)
    if not idx then return end
    local value_param = UI.main.profile_combo:GetValue()
    if not value_param or not value_param.Get then return end
    local bits = value_param:Get()
    if not bits or not bits.SetRaw then return end
    State.profiles.ui_syncing = true
    bits:SetRaw(math.floor(2 ^ (idx - 1)))
    if value_param.Set then
        value_param:Set(bits)
    end
    State.profiles.ui_syncing = false

    -- Runtime-specific selector calibration:
    -- some gui builds report selected index with an offset (+1 / -1).
    local reported_idx = get_selector_index(UI.main.profile_combo)
    if type(reported_idx) == "number" and reported_idx > 0 then
        local bias = 0
        if reported_idx == (idx + 1) then
            bias = -1
        elseif reported_idx == (idx - 1) then
            bias = 1
        end
        State.profiles.selector_index_bias = bias
    end
end

function Utils.Config.switch_profile(profile_name, source)
    local target = Utils.Config.sanitize_profile_name(profile_name)
    if not target then
        return false
    end

    local current = Utils.Config.GetActive_profile_name()
    if current == target then
        Utils.Config.select_profile_in_ui(target)
        return true
    end

    save_all_configs()

    State.profiles.active_name = target
    Utils.Config.refresh_profiles_registry()
    Utils.Config.sync_profiles_combo_ui()
    Utils.Config.save_profile_state(target)
    load_all_configs()
    if type(State.combined_config) == "table" and Utils.Config.profile_exists(target) then
        Utils.Config.ensure_profile_in_light_registry(target)
    end

    -- Switching a config fully restores its master shader state (enable AND disable).
    if UI.checkboxes.enable_shaders and UI.checkboxes.enable_shaders.GetValue then
        local shaders_val = UI.checkboxes.enable_shaders:GetValue()
        if shaders_val and shaders_val.Set then
            shaders_val:Set(State.shaders_config and State.shaders_config.enabled == true)
        end
    end

    local map_name = Utils.System.get_current_map()
    if map_name then
        -- New config -> new point data for the current map: re-arm "Save to point" checkboxes
        -- so point-saved shaders are recognized before the preset/transition is applied.
        restore_shader_point_filters_for_map(map_name)
        local preset = {}
        if State.config and type(State.config.defaults) == "table" then
            for k, v in pairs(State.config.defaults) do
                if type(v) == "table" then
                    preset[k] = {}
                    for i = 1, #v do preset[k][i] = v[i] end
                else
                    preset[k] = v
                end
            end
        end
        if State.config and State.config.maps and type(State.config.maps[map_name]) == "table" then
            for k, v in pairs(State.config.maps[map_name]) do
                if type(v) == "table" then
                    preset[k] = {}
                    for i = 1, #v do preset[k][i] = v[i] end
                else
                    preset[k] = v
                end
            end
        end
        -- Fill defaults for shader keys the new config omits, so switching resets them
        -- instead of keeping the previous config's live values.
        ensure_preset_shader_defaults(preset)
        -- The smooth transition only interpolates point-enabled (galka-ON) shaders, so it
        -- would leave config-managed shaders at the old config's values. Apply the new
        -- config's shader state directly here to guarantee a full reset on config switch.
        apply_shader_settings(preset)
        local switched_with_transition = start_one_shot_smooth_transition(preset, nil, 1.0, 1.1) == true
        if not switched_with_transition then
            apply_settings(preset)
        end
        State.map_entry_settings = preset
        if not switched_with_transition then
            seed_smooth_state(State.map_entry_settings)
        end
        State.current_map = map_name
        runtime_loaded_map = nil
    end

    Utils.Config.select_profile_in_ui(target)

    notify_user("Config", "Profile switched: " .. target)
    return true
end

function Utils.Config.next_auto_profile_name()
    Utils.Config.ensure_profiles_dir()
    Utils.Config.refresh_profiles_registry()

    local list = (State.profiles and State.profiles.list) or {}
    local max_default_idx = 0
    local used = {}

    for i = 1, #list do
        local name = Utils.Config.sanitize_profile_name(list[i])
        if name and name ~= "" then
            local lowered = name:lower()
            used[lowered] = true

            local idx_raw = lowered:match("^default(%d+)$")
            if idx_raw then
                local idx = tonumber(idx_raw) or 0
                if idx > max_default_idx then
                    max_default_idx = idx
                end
            end
        end
    end

    local next_idx = max_default_idx + 1
    local attempts = 0

    while attempts < 10000 do
        local candidate = "default" .. tostring(next_idx)
        local lowered = candidate:lower()

        local exists_in_registry = used[lowered] == true
        local exists_main = Utils.Config.find_existing_path(
            Utils.Config.get_profile_file_path(candidate)
        ) ~= nil
        local exists_legacy = Utils.Config.find_existing_path(
            Utils.Config.get_profile_legacy_file_path(candidate)
        ) ~= nil

        if (not exists_in_registry) and (not exists_main) and (not exists_legacy) then
            return candidate
        end

        next_idx = next_idx + 1
        attempts = attempts + 1
    end

    return "default" .. tostring(max_default_idx + 1)
end

function Utils.Config.create_profile_from_current(raw_name, snapshot_override)
    Utils.Config.set_trace(true, "create_profile")
    Utils.Config.log("create_profile start raw_name=" .. tostring(raw_name), true)

    local function finish(ok, result)
        Utils.Config.log("create_profile finish ok=" .. tostring(ok) .. " result=" .. tostring(result), true)
        Utils.Config.set_trace(false, "")
        return ok, result
    end

    local name = Utils.Config.sanitize_profile_name(raw_name)
    if not name then
        return finish(false, "Enter a valid name")
    end
    Utils.Config.log("create_profile sanitized_name=" .. tostring(name))

    local dir_ready = Utils.Config.ensure_profiles_dir()
    Utils.Config.log("create_profile dir_ready=" .. tostring(dir_ready))
    if not dir_ready then
        if type(State.profiles) ~= "table" then
            State.profiles = {}
        end
        State.profiles.base_dir = Utils.Config.get_combined_base_dir() or "."
        Utils.Config.log("create_profile force base_dir=" .. tostring(State.profiles.base_dir))
    end
    local path = Utils.Config.get_profile_file_path(name)
    local legacy_path = Utils.Config.get_profile_legacy_file_path(name)
    Utils.Config.log("create_profile target_path=" .. tostring(path))
    Utils.Config.log("create_profile legacy_path=" .. tostring(legacy_path))
    local existing_main = Utils.Config.find_existing_path(path)
    local existing_legacy = Utils.Config.find_existing_path(legacy_path)
    Utils.Config.log("create_profile path_exists=" .. tostring(existing_main ~= nil))
    Utils.Config.log("create_profile legacy_exists=" .. tostring(existing_legacy ~= nil))
    if existing_main or existing_legacy then
        local conflict_path = existing_main or existing_legacy
        return finish(false, "Config already exists: " .. tostring(conflict_path))
    end

    local snapshot = nil
    if type(snapshot_override) == "table" then
        snapshot = normalize_combined_config(snapshot_override)
    else
        save_all_configs()
        snapshot = normalize_combined_config(State.combined_config or make_default_combined_config())
    end

    local saved = Utils.Config.save(path, snapshot)
    if (not saved) and legacy_path ~= path then
        saved = Utils.Config.save(legacy_path, snapshot)
        if saved then
            path = legacy_path
        end
    end
    if not saved then
        local touch_main = Utils.Config.ensure_profile_file_exists(path)
        local touch_legacy = false
        if legacy_path ~= path then
            touch_legacy = Utils.Config.ensure_profile_file_exists(legacy_path)
        end
        Utils.Config.log("create_profile save failed; touch_main=" .. tostring(touch_main) .. " touch_legacy=" .. tostring(touch_legacy), true)
        return finish(false, "Failed to create config file (" .. tostring(path) .. ")")
    end

    Utils.Config.refresh_profiles_registry()
    Utils.Config.sync_profiles_combo_ui()
    Utils.Config.save_profile_index(State.profiles.list)
    Utils.Config.switch_profile(name, "create")
    return finish(true, name)
end

-- One-time migration: copy profile files that older builds stored under
-- fatality/ (and fatality/scripts/) into the dedicated profiles directory.
-- Only files carrying our profile marker are touched, so unrelated JSON in
-- those folders (other scripts' configs, the legacy split configs, the unified
-- config) are left alone. A sentinel file prevents re-running.
function Utils.Config.migrate_legacy_profiles()
    Utils.Config.ensure_profiles_dir()

    local sentinel = CONSTANTS.FILES.PROFILES_ROOT .. "/.migrated"
    if Utils.File.exists(sentinel) then
        return 0
    end

    local target_dir = Utils.Config.get_profiles_dir():lower()
    local combined = tostring(CONSTANTS.FILES.COMBINED or ""):gsub("\\", "/"):lower()
    local migrated = 0

    local dirs = CONSTANTS.FILES.PROFILES_LEGACY_DIRS or {}
    for d = 1, #dirs do
        local dir = dirs[d]
        local entries = Utils.File.enumerate(dir .. "/*.json")
        for i = 1, #entries do
            local raw = tostring(entries[i] or ""):gsub("\\", "/")
            local basename = raw:match("([^/]+)%.json$")
            if basename and basename:sub(1, 1) ~= "_" then
                local full = raw:find("/") and raw or (dir .. "/" .. raw)
                local lower_full = full:lower()
                if lower_full ~= combined and lower_full:sub(1, #target_dir + 1) ~= (target_dir .. "/") then
                    local data = Utils.File.load_json(full)
                    if Utils.Config.is_profile_payload(data) then
                        local snapshot = Utils.Config.extract_profile_payload(data)
                        local name = Utils.Config.sanitize_profile_name(data.profile_name)
                            or Utils.Config.name_from_basename(basename)
                        if name and snapshot then
                            local dest = Utils.Config.get_profile_file_path(name)
                            if not Utils.File.exists(dest) then
                                local payload = Utils.Config.make_profile_payload(name, snapshot)
                                if Utils.File.save_json(dest, payload) then
                                    migrated = migrated + 1
                                    Utils.Config.log("migrated profile '" .. name .. "' from " .. full, true)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    Utils.File.save_json(sentinel, { version = 1, migrated = migrated })
    Utils.Config.log("migrate_legacy_profiles migrated=" .. tostring(migrated), true)
    return migrated
end

function Utils.Config.bootstrap_profiles()
    Utils.Config.ensure_profiles_dir()
    if type(State.profiles) ~= "table" then
        State.profiles = {}
    end
    Utils.Config.log("bootstrap_profiles dir=" .. tostring(Utils.Config.get_profiles_dir()), true)

    Utils.Config.migrate_legacy_profiles()

    local active = Utils.Config.load_profile_state()
    if active then
        State.profiles.active_name = active
    else
        State.profiles.active_name = CONSTANTS.FILES.PROFILE_DEFAULT
    end

    Utils.Config.refresh_profiles_registry()
    Utils.Config.save_profile_state(State.profiles.active_name)
end

-- ========== HELPERS ==========
-- ===== File primitives =====
-- The Fatality file API is PascalCase and relative to game/csgo:
-- utils.FileExists / FileRead / FileWrite / FileEnumerate / FileRemove /
-- FileRename / FileCreateDirectories, plus utils.StringToArray / ArrayToString.
-- Calls go through protected_call, which returns (false) when the function is
-- absent (e.g. running without "insecure"), so a missing API degrades instead
-- of throwing -- there is no protected-call primitive in this sandbox otherwise.
function Utils.File.bytes_to_string(bytes)
    if type(bytes) == "string" then
        return bytes
    end
    if bytes == nil then
        return nil
    end
    local ok, str = protected_call(utils.ArrayToString, bytes)
    if ok and type(str) == "string" then
        return str
    end
    return nil
end

function Utils.File.string_to_bytes(str)
    if type(str) ~= "string" then
        return nil
    end
    local ok, arr = protected_call(utils.StringToArray, str)
    if ok and arr ~= nil then
        return arr
    end
    return nil
end

function Utils.File.make_dirs(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local ok = protected_call(utils.FileCreateDirectories, path)
    return ok ~= false
end

function Utils.File.ensure_parent_dir(path)
    if type(path) ~= "string" then
        return
    end
    local slash = nil
    for i = #path, 1, -1 do
        local c = path:sub(i, i)
        if c == "/" or c == "\\" then
            slash = i
            break
        end
    end
    if slash and slash > 1 then
        Utils.File.make_dirs(path:sub(1, slash - 1))
    end
end

function Utils.File.enumerate(wildcard)
    if type(wildcard) ~= "string" or wildcard == "" then
        return {}
    end
    local ok, entries = protected_call(utils.FileEnumerate, wildcard)
    if ok and type(entries) == "table" then
        return entries
    end
    return {}
end

function Utils.File.rename(path, new_path)
    if type(path) ~= "string" or type(new_path) ~= "string" then
        return false
    end
    local ok = protected_call(utils.FileRename, path, new_path)
    return ok ~= false
end

function Utils.File.exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local ok, result = protected_call(utils.FileExists, path)
    return ok and result == true
end

function Utils.File.read(path)
    -- Returns the raw file contents as a byte array (table<number>); nil if unreadable.
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local ok, data = protected_call(utils.FileRead, path)
    if ok and data ~= nil then
        return data
    end
    return nil
end

-- Convenience: read a file straight into a Lua string.
function Utils.File.read_text(path)
    return Utils.File.bytes_to_string(Utils.File.read(path))
end

function Utils.File.write(path, data)
    -- data may be a Lua string or a byte array (table<number>).
    if type(path) ~= "string" or path == "" then
        return false
    end

    Utils.File.ensure_parent_dir(path)

    local bytes = (type(data) == "string") and Utils.File.string_to_bytes(data) or data
    if bytes == nil then
        return false
    end

    local ok, result = protected_call(utils.FileWrite, path, bytes)
    if ok and result ~= false then
        return true
    end

    if Utils and Utils.Config and Utils.Config.log then
        Utils.Config.log("file write failed path=" .. tostring(path), true)
    end
    return false
end

function Utils.File.remove(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    protected_call(utils.FileRemove, path)
    return not Utils.File.exists(path)
end

function Utils.File.json_encode(data)
    local function is_array_table(tbl)
        local numeric = 0
        local max_index = 0
        for k, _ in pairs(tbl) do
            if type(k) == "number" and k > 0 and k % 1 == 0 then
                numeric = numeric + 1
                if k > max_index then
                    max_index = k
                end
            else
                return false, 0
            end
        end
        if numeric == 0 then
            return true, 0
        end
        return max_index == numeric, max_index
    end

    local function normalize_for_json(value, seen)
        local vt = type(value)
        if vt == "nil" or vt == "boolean" or vt == "number" or vt == "string" then
            return value
        end

        if vt ~= "table" then
            -- Avoid hard encode failures for userdata/functions/threads.
            return tostring(value)
        end

        seen = seen or {}
        if seen[value] then
            return "<cycle>"
        end
        seen[value] = true

        local as_array, max_index = is_array_table(value)
        local out = {}

        if as_array then
            for i = 1, max_index do
                out[i] = normalize_for_json(value[i], seen)
            end
        else
            for k, v in pairs(value) do
                local key = (type(k) == "string") and k or tostring(k)
                out[key] = normalize_for_json(v, seen)
            end
        end

        seen[value] = nil
        return out
    end

    local function json_escape(str)
        local s = tostring(str)
        s = s:gsub("\\", "\\\\")
        s = s:gsub("\"", "\\\"")
        s = s:gsub("\b", "\\b")
        s = s:gsub("\f", "\\f")
        s = s:gsub("\n", "\\n")
        s = s:gsub("\r", "\\r")
        s = s:gsub("\t", "\\t")
        s = s:gsub("[%z\1-\31]", function(c)
            return string.format("\\u%04x", string.byte(c))
        end)
        return s
    end

    local function encode_json(value, seen)
        local vt = type(value)
        if vt == "nil" then
            return "null"
        end
        if vt == "boolean" then
            return value and "true" or "false"
        end
        if vt == "number" then
            if value ~= value or value == math.huge or value == -math.huge then
                return "null"
            end
            return tostring(value)
        end
        if vt == "string" then
            return "\"" .. json_escape(value) .. "\""
        end
        if vt ~= "table" then
            return "\"" .. json_escape(tostring(value)) .. "\""
        end

        seen = seen or {}
        if seen[value] then
            return "\"<cycle>\""
        end
        seen[value] = true

        local as_array, max_index = is_array_table(value)
        local parts = {}

        if as_array then
            for i = 1, max_index do
                parts[#parts + 1] = encode_json(value[i], seen)
            end
            seen[value] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        end

        local keys = {}
        for k, _ in pairs(value) do
            keys[#keys + 1] = (type(k) == "string") and k or tostring(k)
        end
        table.sort(keys)

        for i = 1, #keys do
            local key = keys[i]
            parts[#parts + 1] = "\"" .. json_escape(key) .. "\":" .. encode_json(value[key], seen)
        end

        seen[value] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end

    -- NOTE:
    -- utils.JsonEncode may crash on mixed-key tables in this runtime.
    -- We always normalize and encode in pure Lua for table payloads.
    local payload = data
    if type(payload) == "table" then
        payload = normalize_for_json(payload, {})
    end

    local encoded = encode_json(payload, {})
    if type(encoded) == "string" and encoded ~= "" then
        return encoded
    end

    local native_encoder = nil
    if utils then
        if type(utils.JsonEncode) == "function" then
            native_encoder = utils.JsonEncode
        elseif type(utils.JsonEncode) == "function" then
            native_encoder = utils.JsonEncode
        end
    end

    if native_encoder then
        local ok_encoded, encoded_native = protected_call(native_encoder, payload)
        if ok_encoded and type(encoded_native) == "string" and encoded_native ~= "" then
            return encoded_native
        end
        if Utils and Utils.Config and Utils.Config.log then
            Utils.Config.log("json_encode fallback failed value=" .. tostring(encoded_native), true)
        end
    end

    return nil
end

function Utils.File.json_decode(str)
    if type(str) ~= "string" then
        return nil
    end

    local native_decoder = nil
    if utils then
        if type(utils.JsonDecode) == "function" then
            native_decoder = utils.JsonDecode
        elseif type(utils.JsonDecode) == "function" then
            native_decoder = utils.JsonDecode
        end
    end

    if not native_decoder then
        native_decoder = nil
    end

    if native_decoder then
        local ok, decoded = protected_call(native_decoder, str)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end

    -- Pure-Lua fallback decoder for environments where utils.JsonDecode is unstable.
    local function utf8_from_codepoint(code)
        if type(code) ~= "number" then
            return "?"
        end
        if code < 0 then
            return "?"
        end
        if code <= 0x7F then
            return string.char(code)
        end
        if code <= 0x7FF then
            local b1 = 0xC0 + math_floor(code / 0x40)
            local b2 = 0x80 + (code % 0x40)
            return string.char(b1, b2)
        end
        if code <= 0xFFFF then
            local b1 = 0xE0 + math_floor(code / 0x1000)
            local b2 = 0x80 + (math_floor(code / 0x40) % 0x40)
            local b3 = 0x80 + (code % 0x40)
            return string.char(b1, b2, b3)
        end
        if code <= 0x10FFFF then
            local b1 = 0xF0 + math_floor(code / 0x40000)
            local b2 = 0x80 + (math_floor(code / 0x1000) % 0x40)
            local b3 = 0x80 + (math_floor(code / 0x40) % 0x40)
            local b4 = 0x80 + (code % 0x40)
            return string.char(b1, b2, b3, b4)
        end
        return "?"
    end

    local i = 1
    local n = #str

    local function peek()
        if i > n then
            return nil
        end
        return str:sub(i, i)
    end

    local function skip_ws()
        while i <= n do
            local c = str:sub(i, i)
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                i = i + 1
            else
                break
            end
        end
    end

    local parse_value

    local function parse_string()
        if peek() ~= "\"" then
            return nil
        end
        i = i + 1
        local out = {}

        while i <= n do
            local c = str:sub(i, i)
            if c == "\"" then
                i = i + 1
                return table.concat(out)
            end
            if c == "\\" then
                i = i + 1
                if i > n then
                    return nil
                end
                local esc = str:sub(i, i)
                if esc == "\"" or esc == "\\" or esc == "/" then
                    out[#out + 1] = esc
                    i = i + 1
                elseif esc == "b" then
                    out[#out + 1] = "\b"
                    i = i + 1
                elseif esc == "f" then
                    out[#out + 1] = "\f"
                    i = i + 1
                elseif esc == "n" then
                    out[#out + 1] = "\n"
                    i = i + 1
                elseif esc == "r" then
                    out[#out + 1] = "\r"
                    i = i + 1
                elseif esc == "t" then
                    out[#out + 1] = "\t"
                    i = i + 1
                elseif esc == "u" then
                    local hex = str:sub(i + 1, i + 4)
                    if #hex ~= 4 or hex:find("[^0-9a-fA-F]") then
                        return nil
                    end
                    local code = tonumber(hex, 16) or 63
                    out[#out + 1] = utf8_from_codepoint(code)
                    i = i + 5
                else
                    return nil
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end

        return nil
    end

    local function parse_number()
        local start = i
        local c = peek()

        if c == "-" then
            i = i + 1
        end

        local first = peek()
        if first == "0" then
            i = i + 1
        else
            if not first or not first:match("%d") then
                return nil
            end
            while true do
                local d = peek()
                if d and d:match("%d") then
                    i = i + 1
                else
                    break
                end
            end
        end

        if peek() == "." then
            i = i + 1
            local has_frac = false
            while true do
                local d = peek()
                if d and d:match("%d") then
                    has_frac = true
                    i = i + 1
                else
                    break
                end
            end
            if not has_frac then
                return nil
            end
        end

        local e = peek()
        if e == "e" or e == "E" then
            i = i + 1
            local s = peek()
            if s == "+" or s == "-" then
                i = i + 1
            end
            local has_exp = false
            while true do
                local d = peek()
                if d and d:match("%d") then
                    has_exp = true
                    i = i + 1
                else
                    break
                end
            end
            if not has_exp then
                return nil
            end
        end

        local num = tonumber(str:sub(start, i - 1))
        return num
    end

    local function parse_array()
        if peek() ~= "[" then
            return nil
        end
        i = i + 1
        skip_ws()

        local arr = {}
        if peek() == "]" then
            i = i + 1
            return arr
        end

        while true do
            local v = parse_value()
            if v == nil and peek() ~= "n" then
                return nil
            end
            arr[#arr + 1] = v
            skip_ws()

            local c = peek()
            if c == "," then
                i = i + 1
                skip_ws()
            elseif c == "]" then
                i = i + 1
                break
            else
                return nil
            end
        end

        return arr
    end

    local function parse_object()
        if peek() ~= "{" then
            return nil
        end
        i = i + 1
        skip_ws()

        local obj = {}
        if peek() == "}" then
            i = i + 1
            return obj
        end

        while true do
            local key = parse_string()
            if key == nil then
                return nil
            end
            skip_ws()
            if peek() ~= ":" then
                return nil
            end
            i = i + 1
            skip_ws()

            local value = parse_value()
            if value == nil and peek() ~= "n" then
                return nil
            end
            obj[key] = value
            skip_ws()

            local c = peek()
            if c == "," then
                i = i + 1
                skip_ws()
            elseif c == "}" then
                i = i + 1
                break
            else
                return nil
            end
        end

        return obj
    end

    local function parse_literal(lit, value)
        if str:sub(i, i + #lit - 1) == lit then
            i = i + #lit
            return value
        end
        return nil
    end

    parse_value = function()
        skip_ws()
        local c = peek()
        if c == nil then
            return nil
        end
        if c == "\"" then
            return parse_string()
        end
        if c == "{" then
            return parse_object()
        end
        if c == "[" then
            return parse_array()
        end
        if c == "-" or c:match("%d") then
            return parse_number()
        end
        if c == "t" then
            return parse_literal("true", true)
        end
        if c == "f" then
            return parse_literal("false", false)
        end
        if c == "n" then
            return parse_literal("null", nil)
        end
        return nil
    end

    local decoded = parse_value()
    skip_ws()
    if i <= n then
        return nil
    end

    return decoded
end

function Utils.File.save_json(path, data)
    local json_str = Utils.File.json_encode(data)
    if not json_str then
        if Utils and Utils.Config and Utils.Config.log then
            Utils.Config.log("save_json encode failed path=" .. tostring(path), true)
        end
        return false
    end

    local ok_write = Utils.File.write(path, json_str)
    if Utils and Utils.Config and Utils.Config.log then
        Utils.Config.log("save_json path=" .. tostring(path) .. " ok=" .. tostring(ok_write))
    end
    return ok_write
end

function Utils.File.load_json(path)
    local str = Utils.File.read_text(path)
    if type(str) == "string" and str ~= "" then
        return Utils.File.json_decode(str)
    end
    return nil
end

function Utils.System.get_current_map()
    local function normalize(raw_name)
        if type(raw_name) ~= "string" then
            return nil
        end

        local name = raw_name:gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then
            return nil
        end

        name = name:gsub("%?.*$", "")
        name = name:gsub("\\", "/")
        name = name:gsub("^maps/", "")
        local tail = name:match(".*/([^/]+)$")
        if tail and tail ~= "" then
            name = tail
        end

        name = name:gsub("%.bsp$", ""):gsub("%.vpk$", ""):gsub("%.txt$", "")
        if name == "" then
            return nil
        end

        return name
    end

    if not engine_in_game() or not engine_is_connected() then
        return nil
    end

    local gv = game and game.globalVars or nil
    if gv then
        local from_name = normalize(gv.m_szMapName)
        if from_name then
            return from_name
        end
        local from_path = normalize(gv.m_szMapPath)
        if from_path then
            return from_path
        end
    end

    return nil
end

function Utils.System.is_in_game()
    return engine_in_game()
end

function Utils.System.get_time()
    return runtime_now()
end

-- ========== SHADER RUNTIME BRIDGE ==========
local SHADER_SYNC_INTERVAL = 1.0
local SHADER_AUTOSAVE_DEBOUNCE = 1.0
local SHADER_COLOR_DEFAULTS = {
    shader_vignette_tint = {255, 255, 255, 0},
    shader_sharpen_tint = {255, 255, 255, 255},
    shader_emboss_tint = {255, 255, 255, 255}
}

local function get_shader_api()
    return SHADER_RUNTIME
end

local function ensure_shaders_config()
    if type(State.shaders_config) ~= "table" then
        State.shaders_config = {}
    end
    if State.shaders_config.enabled == nil then
        State.shaders_config.enabled = true
    end
    State.shaders_config.enabled = (State.shaders_config.enabled == true)
    if type(State.shaders_config.global) ~= "table" then
        State.shaders_config.global = {}
    end
    if type(State.shaders_config.map_replace) ~= "table" then
        State.shaders_config.map_replace = {}
    end
    if not State.shaders_config.version then
        State.shaders_config.version = 1
    end
end

local function bootstrap_shader_runtime()
    if State.shaders_runtime.bootstrapped then return true end

    local api = get_shader_api()
    if api then
        State.shaders_runtime.bootstrapped = true
        return true
    end
    return false
end

local function apply_shader_replace_for_map(map_name)
    if not shader_runtime_enabled then return end
    local api = get_shader_api()
    if not api or not api.apply_replace_state then return end
    ensure_shaders_config()

    local payload = nil
    if map_name and State.shaders_config.map_replace then
        payload = State.shaders_config.map_replace[map_name]
    end
    if not payload then
        payload = {
            pair_count = 1,
            pairs = {
                [1] = {
                    source = {60, 140, 255, 255},
                    target = {255, 60, 60, 0}
                }
            }
        }
    end

    api.apply_replace_state(payload)
end

local function normalized_shader_color(value, defaults)
    if type(value) ~= "table" then
        return {defaults[1], defaults[2], defaults[3], defaults[4]}
    end
    return {
        tonumber(value[1]) or defaults[1],
        tonumber(value[2]) or defaults[2],
        tonumber(value[3]) or defaults[3],
        tonumber(value[4]) or defaults[4]
    }
end

local function normalize_shader_settings_payload(raw)
    local payload = {}
    for _, key in ipairs(CONSTANTS.SHADERS.SLIDER_KEYS) do
        payload[key] = tonumber(raw and raw[key]) or 0
    end
    for _, key in ipairs(CONSTANTS.SHADERS.COLOR_KEYS) do
        payload[key] = normalized_shader_color(raw and raw[key], SHADER_COLOR_DEFAULTS[key])
    end
    return payload
end

local function build_shader_settings_hash(payload, include_fn)
    local parts = {}
    for _, key in ipairs(CONSTANTS.SHADERS.SLIDER_KEYS) do
        if (not include_fn) or include_fn(key) then
            parts[#parts + 1] = key .. "=" .. string.format("%.3f", tonumber(payload[key]) or 0)
        end
    end
    for _, key in ipairs(CONSTANTS.SHADERS.COLOR_KEYS) do
        if (not include_fn) or include_fn(key) then
            local d = SHADER_COLOR_DEFAULTS[key]
            local c = normalized_shader_color(payload[key], d)
            parts[#parts + 1] = key .. "=" .. string.format("%d,%d,%d,%d", c[1], c[2], c[3], c[4])
        end
    end
    return table.concat(parts, "|")
end

local function get_map_shader_settings_payload(map_name)
    local slot = nil
    if State.config and State.config.maps and map_name then
        slot = State.config.maps[map_name]
    end
    return normalize_shader_settings_payload(slot)
end

local function store_map_shader_settings_payload(map_name, payload, include_fn)
    if not map_name then return end
    if type(State.config) ~= "table" then
        State.config = {version = 1, defaults = {}, maps = {}}
    end
    if type(State.config.maps) ~= "table" then
        State.config.maps = {}
    end
    if type(State.config.maps[map_name]) ~= "table" then
        State.config.maps[map_name] = {}
    end

    local slot = State.config.maps[map_name]
    for _, key in ipairs(CONSTANTS.SHADERS.SLIDER_KEYS) do
        if (not include_fn) or include_fn(key) then
            slot[key] = tonumber(payload[key]) or 0
        end
    end
    for _, key in ipairs(CONSTANTS.SHADERS.COLOR_KEYS) do
        if (not include_fn) or include_fn(key) then
            local d = SHADER_COLOR_DEFAULTS[key]
            slot[key] = normalized_shader_color(payload[key], d)
        end
    end
end

local function maybe_sync_shader_state()
    if not shader_runtime_enabled then
        return
    end
    -- NOTE: no global "points enabled" short-circuit here. Autosave is gated per-filter
    -- below (see autosave_to_config): filters whose "Save to point" checkbox is OFF keep
    -- autosaving to config even while other filters have it ON.

    local api = get_shader_api()
    if not api then return end

    local now = Utils.System.get_time()
    if (now - (State.shaders_runtime.last_sync_time or 0)) < SHADER_SYNC_INTERVAL then
        return
    end
    State.shaders_runtime.last_sync_time = now

    ensure_shaders_config()

    local map_name = Utils.System.get_current_map()
    if not map_name or map_name == "" then
        State.shaders_runtime.last_replace_map = nil
        State.shaders_runtime.replace_pending = false
        State.shaders_runtime.last_global_map = nil
        State.shaders_runtime.global_pending = false
        return
    end

    local dirty = false

    local get_replace_state = api.get_replace_state or api.GetReplace_state
    if map_name and get_replace_state then
        local r = get_replace_state()
        if type(r) == "table" then
            local r_hash = Utils.File.json_encode(r) or ""
            local map_slot = State.shaders_config.map_replace[map_name]
            local existing_hash = Utils.File.json_encode(map_slot) or ""

            if State.shaders_runtime.last_replace_map ~= map_name then
                State.shaders_runtime.last_replace_map = map_name
                State.shaders_runtime.last_replace_live_hash = r_hash
                State.shaders_runtime.replace_changed_at = now
                State.shaders_runtime.replace_pending = false
            elseif r_hash ~= (State.shaders_runtime.last_replace_live_hash or "") then
                State.shaders_runtime.last_replace_live_hash = r_hash
                State.shaders_runtime.replace_changed_at = now
                State.shaders_runtime.replace_pending = true
            end

            if State.shaders_runtime.replace_pending then
                local elapsed = now - (State.shaders_runtime.replace_changed_at or now)
                if elapsed >= SHADER_AUTOSAVE_DEBOUNCE then
                    if r_hash ~= existing_hash then
                        State.shaders_config.map_replace[map_name] = r
                        dirty = true
                    end
                    State.shaders_runtime.replace_pending = false
                    State.shaders_runtime.last_replace_hash = r_hash
                end
            elseif r_hash == existing_hash then
                State.shaders_runtime.last_replace_hash = r_hash
            end
        end
    end

    local get_global_state = api.get_global_state or api.GetGlobal_state
    if map_name and get_global_state then
        -- Per-filter autosave gate: only keys whose "Save to point" checkbox is OFF are
        -- written to the map config automatically. Keys with the checkbox ON are
        -- point-managed and persist to config only via the "Save map setts" button.
        local autosave_to_config = function(key)
            return not should_include_shader_key_in_points(key)
        end
        local current_payload = normalize_shader_settings_payload(capture_current_shader_settings())
        local current_hash = build_shader_settings_hash(current_payload, autosave_to_config)
        local stored_payload = get_map_shader_settings_payload(map_name)
        local stored_hash = build_shader_settings_hash(stored_payload, autosave_to_config)

        if State.shaders_runtime.last_global_map ~= map_name then
            State.shaders_runtime.last_global_map = map_name
            State.shaders_runtime.last_global_live_hash = current_hash
            State.shaders_runtime.global_changed_at = now
            State.shaders_runtime.global_pending = false
        elseif current_hash ~= (State.shaders_runtime.last_global_live_hash or "") then
            State.shaders_runtime.last_global_live_hash = current_hash
            State.shaders_runtime.global_changed_at = now
            State.shaders_runtime.global_pending = true
        end

        if State.shaders_runtime.global_pending then
            local elapsed = now - (State.shaders_runtime.global_changed_at or now)
            if elapsed >= SHADER_AUTOSAVE_DEBOUNCE then
                if current_hash ~= stored_hash then
                    store_map_shader_settings_payload(map_name, current_payload, autosave_to_config)
                    dirty = true
                end
                State.shaders_runtime.global_pending = false
            end
        end
    end

    if dirty then
        save_all_configs()
    end
end

capture_current_shader_settings = function()
    local captured = {}

    -- defaults: all off, neutral tints
    for _, key in ipairs(CONSTANTS.SHADERS.SLIDER_KEYS) do
        captured[key] = 0
    end
    captured.shader_vignette_tint = {255, 255, 255, 0}
    captured.shader_sharpen_tint = {255, 255, 255, 255}
    captured.shader_emboss_tint = {255, 255, 255, 255}
    captured.shader_chromatic_spread = 100
    captured.shader_tonemap_darks = 0
    captured.shader_tonemap_lights = 0

    local api = get_shader_api()
    local get_global_state = api and (api.get_global_state or api.GetGlobal_state) or nil
    if not get_global_state then
        return captured
    end

    local g = get_global_state()
    if type(g) ~= "table" then
        return captured
    end

    local strengths = g.strengths
    if type(strengths) == "table" then
        for _, f in ipairs(CONSTANTS.SHADERS.FILTERS) do
            local key = "shader_strength_" .. f.id
            captured[key] = tonumber(strengths[f.index]) or 0
        end
    end

    if type(g.vignette_tint) == "table" then
        captured.shader_vignette_tint = g.vignette_tint
    end
    if type(g.sharpen_tint) == "table" then
        captured.shader_sharpen_tint = g.sharpen_tint
    end
    if type(g.emboss_tint) == "table" then
        captured.shader_emboss_tint = g.emboss_tint
    end
    captured.shader_chromatic_spread = tonumber(g.chromatic_spread) or 100
    if type(g.tonemap) == "table" then
        captured.shader_tonemap_darks = tonumber(g.tonemap.darks) or 0
        captured.shader_tonemap_lights = tonumber(g.tonemap.lights) or 0
    end

    return captured
end

apply_shader_settings = function(settings)
    local api = get_shader_api()
    if not api or not api.apply_global_state or type(settings) ~= "table" then
        return
    end

    local base = capture_current_shader_settings()
    local payload = {
        strengths = {},
        chromatic_spread = tonumber(base.shader_chromatic_spread) or 100,
        tonemap = {
            darks = tonumber(base.shader_tonemap_darks) or 0,
            lights = tonumber(base.shader_tonemap_lights) or 0
        },
        vignette_tint = base.shader_vignette_tint or {255, 255, 255, 0},
        sharpen_tint = base.shader_sharpen_tint or {255, 255, 255, 255},
        emboss_tint = base.shader_emboss_tint or {255, 255, 255, 255}
    }

    for _, f in ipairs(CONSTANTS.SHADERS.FILTERS) do
        local key = "shader_strength_" .. f.id
        payload.strengths[f.index] = tonumber(base[key]) or 0
        if settings[key] ~= nil then
            payload.strengths[f.index] = tonumber(settings[key]) or 0
        end
    end

    if settings.shader_chromatic_spread ~= nil then
        payload.chromatic_spread = tonumber(settings.shader_chromatic_spread) or payload.chromatic_spread
    end
    if settings.shader_tonemap_darks ~= nil then
        payload.tonemap.darks = tonumber(settings.shader_tonemap_darks) or payload.tonemap.darks
    end
    if settings.shader_tonemap_lights ~= nil then
        payload.tonemap.lights = tonumber(settings.shader_tonemap_lights) or payload.tonemap.lights
    end
    if settings.shader_vignette_tint ~= nil then
        payload.vignette_tint = settings.shader_vignette_tint
    end
    if settings.shader_sharpen_tint ~= nil then
        payload.sharpen_tint = settings.shader_sharpen_tint
    end
    if settings.shader_emboss_tint ~= nil then
        payload.emboss_tint = settings.shader_emboss_tint
    end

    api.apply_global_state(payload)
end

function UI.shader_points.create_static_hint_control(id, text)
    if gui and gui.Checkbox and gui.MakeControl and gui.ControlID then
        local cb = gui.Checkbox(gui.ControlID(id .. "_cb"))
        if cb and cb.GetValue then
            local v = cb:GetValue()
            if v and v.Set then
                v:Set(false)
            end
        end
        return gui.MakeControl(tostring(text or ""), cb)
    end

    return nil
end

function UI.shader_points.build_payload_from_ui()
    local sp = UI.shader_points
    if not sp then
        return nil
    end

    local payload = {
        strengths = {},
        chromatic_spread = 100,
        tonemap = { darks = 0, lights = 0 },
        vignette_tint = {255, 255, 255, 0},
        sharpen_tint = {255, 255, 255, 255},
        emboss_tint = {255, 255, 255, 255}
    }

    for _, f in ipairs(CONSTANTS.SHADERS.FILTERS) do
        local slider = sp.strength_sliders[f.id]
        if slider and slider.GetValue then
            local v = slider:GetValue()
            payload.strengths[f.index] = (v and v.Get and tonumber(v:Get())) or 0
        else
            payload.strengths[f.index] = 0
        end
    end

    if sp.chromatic_slider and sp.chromatic_slider.GetValue then
        local v = sp.chromatic_slider:GetValue()
        payload.chromatic_spread = (v and v.Get and tonumber(v:Get())) or 100
    end

    if sp.tonemap_darks_slider and sp.tonemap_darks_slider.GetValue then
        local v = sp.tonemap_darks_slider:GetValue()
        payload.tonemap.darks = (v and v.Get and tonumber(v:Get())) or 0
    end

    if sp.tonemap_lights_slider and sp.tonemap_lights_slider.GetValue then
        local v = sp.tonemap_lights_slider:GetValue()
        payload.tonemap.lights = (v and v.Get and tonumber(v:Get())) or 0
    end

    payload.vignette_tint = color_to_tbl(sp.vignette_color, 255, 255, 255, 0)
    payload.sharpen_tint = color_to_tbl(sp.sharpen_color, 255, 255, 255, 255)
    payload.emboss_tint = color_to_tbl(sp.emboss_color, 255, 255, 255, 255)

    return payload
end

function UI.shader_points.push_to_runtime()
    local sp = UI.shader_points
    if not sp or sp.syncing then
        return
    end

    local api = get_shader_api()
    if not api or not api.apply_global_state then
        return
    end

    local payload = UI.shader_points.build_payload_from_ui()
    if payload then
        api.apply_global_state(payload)
    end
end

function UI.shader_points.pull_from_runtime()
    local sp = UI.shader_points
    if not sp then
        return
    end

    local api = get_shader_api()
    local get_global_state = api and (api.get_global_state or api.GetGlobal_state) or nil
    if not get_global_state then
        return
    end

    local state = get_global_state()
    if type(state) ~= "table" then
        return
    end

    sp.syncing = true

    local strengths = state.strengths
    if type(strengths) == "table" then
        for _, f in ipairs(CONSTANTS.SHADERS.FILTERS) do
            local slider = sp.strength_sliders[f.id]
            if slider and slider.GetValue then
                local v = slider:GetValue()
                if v and v.Set then
                    v:Set(tonumber(strengths[f.index]) or 0)
                end
            end
        end
    end

    if sp.chromatic_slider and sp.chromatic_slider.GetValue then
        local v = sp.chromatic_slider:GetValue()
        if v and v.Set then
            v:Set(tonumber(state.chromatic_spread) or 100)
        end
    end

    if sp.tonemap_darks_slider and sp.tonemap_darks_slider.GetValue then
        local v = sp.tonemap_darks_slider:GetValue()
        if v and v.Set then
            v:Set(tonumber(state.tonemap and state.tonemap.darks) or 0)
        end
    end

    if sp.tonemap_lights_slider and sp.tonemap_lights_slider.GetValue then
        local v = sp.tonemap_lights_slider:GetValue()
        if v and v.Set then
            v:Set(tonumber(state.tonemap and state.tonemap.lights) or 0)
        end
    end

    set_color_from_tbl(sp.vignette_color, state.vignette_tint)
    set_color_from_tbl(sp.sharpen_color, state.sharpen_tint)
    set_color_from_tbl(sp.emboss_color, state.emboss_tint)

    sp.syncing = false
end

function Utils.Math.distance_3d(p1, p2)
    local dx = p1.x - p2.x
    local dy = p1.y - p2.y
    local dz = p1.z - p2.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

function Utils.Math.distance_sq_3d(p1, p2)
    local dx = p1.x - p2.x
    local dy = p1.y - p2.y
    local dz = p1.z - p2.z
    return dx*dx + dy*dy + dz*dz
end

-- ========== ID MANAGEMENT ==========
local function restore_next_point_id(map_name)
    local max_id = 0
    if State.points_config and State.points_config.maps[map_name] then
        for _, pt in ipairs(State.points_config.maps[map_name].points or {}) do
            if pt.id and pt.id > max_id then max_id = pt.id end
        end
    end
    State.next_point_id = max_id + 1
end

local function get_new_point_id()
    local id = State.next_point_id
    State.next_point_id = State.next_point_id + 1
    return id
end

-- ========== CHECKBOX CHECKS ==========

local function is_debug_enabled()
    return Utils.UI.GetBool(UI.checkboxes.dbg, false)
end

local function is_auto_update_config_enabled()
    return Utils.UI.GetBool(UI.checkboxes.auto_update_config, false)
end

local function is_shaders_enabled()
    return Utils.UI.GetBool(UI.checkboxes.enable_shaders, true)
end

is_shader_points_enabled = function()
    for _, f in ipairs(CONSTANTS.SHADERS.FILTERS) do
        if f and not f.is_replace and is_shader_point_filter_enabled(f.id) then
            return true
        end
    end
    return false
end

-- Programmatically toggle a per-filter "Save to point" checkbox.
set_shader_point_filter_enabled = function(filter_id, enabled)
    local checks = MAPS_CUSTOM_UI and MAPS_CUSTOM_UI.shader_point_filter_checks
    local ctrl = checks and checks[filter_id] or nil
    if ctrl and ctrl.GetValue then
        local v = ctrl:GetValue()
        if v and v.Set then
            v:Set(enabled == true)
        end
    end
end

-- On map load the "Save to point" checkboxes always start OFF, so a map whose points
-- carry shader settings would have them stripped by the blend (is_shader_points_enabled
-- would be false). Re-arm each filter's checkbox from the map's stored point data: ON for
-- filters present in any point, OFF otherwise. This makes point-saved shaders apply again
-- and keeps the per-filter autosave gate consistent with what was saved.
restore_shader_point_filters_for_map = function(map_name)
    local checks = MAPS_CUSTOM_UI and MAPS_CUSTOM_UI.shader_point_filter_checks
    if not checks then return end

    local present = {}
    local map_data = State.points_config and State.points_config.maps
        and State.points_config.maps[map_name] or nil
    if map_data and type(map_data.points) == "table" then
        for _, point in ipairs(map_data.points) do
            local s = point and point.settings
            if type(s) == "table" then
                for k in pairs(s) do
                    local fid = _cm_shader_filter_from_key(k)
                    if fid then present[fid] = true end
                end
            end
        end
    end

    for _, f in ipairs(CONSTANTS.SHADERS.FILTERS) do
        if f and not f.is_replace then
            set_shader_point_filter_enabled(f.id, present[f.id] == true)
        end
    end
end

local function debug_print(msg)
    return
end

local function is_points_enabled()
    return Utils.UI.GetBool(UI.checkboxes.enable_points, false)
end

local function is_settings_edit_enabled()
    return Utils.UI.GetBool(UI.checkboxes.enable_settings, false)
end

local function is_save_shaders_in_point_enabled()
    return false
end

local function is_render_points_enabled()
    return Utils.UI.GetBool(UI.checkboxes.render_points, false)
end

local function is_weight_enabled()
    return Utils.UI.GetBool(UI.checkboxes.enable_weight, false)
end

local function is_render_weight_enabled()
    return Utils.UI.GetBool(UI.checkboxes.render_weight, false)
end

local function is_render_influence_enabled()
    return Utils.UI.GetBool(UI.checkboxes.render_influence, false)
end

local function is_render_lines_enabled()
    return Utils.UI.GetBool(UI.checkboxes.render_lines, false)
end

local function capture_point_settings_snapshot(base_settings)
    local settings = base_settings or capture_current_settings(is_shader_points_enabled())
    local result
    if is_shader_points_enabled() then
        result = filter_shader_settings_for_points(settings)
    else
        result = strip_shader_settings(settings)
    end
    -- Bloom, tonemap and local contrast are map-scoped (Save map setts), never per-point -- strip
    -- them from point snapshots so walking between points can't change them. Copy first if strip
    -- returned the input verbatim (no shader keys stripped) so we never mutate a caller-owned table
    -- (e.g. map_entry_settings).
    if type(result) == "table" and (result.bloom_json ~= nil or result.postfx_json ~= nil) then
        if result == settings then
            local copy = {}
            for k, v in pairs(result) do copy[k] = v end
            result = copy
        end
        result.bloom_json = nil
        result.postfx_json = nil
    end
    return result
end

local function is_thirdperson_enabled()
    local ctrl = Utils.UI.get_control(CONSTANTS.PATHS.thirdperson)
    local in_tp = false
    if ctrl then
        local val = ctrl:GetValue()
        if val and val.Get and val:Get() == true then
            in_tp = true
        end
    end
    
    -- Could also be checked through input (if available), but a checkbox is more reliable for setup
    return in_tp
end

-- ========== COLORED MAPS: PRESET FUNCTIONS ==========
-- Ensure a config preset specifies every shader key, defaulting any the config omits.
-- apply_shader_settings bases missing keys on the *current live* values, so without this a
-- shader absent from the loaded config would keep the previous config's value instead of
-- resetting. Only applied to full-config presets, never to partial point-blend settings.
-- Chunk-global so switch_profile (defined earlier in the file) can reach it at runtime.
ensure_preset_shader_defaults = function(preset)
    if type(preset) ~= "table" then return preset end
    for _, key in ipairs(CONSTANTS.SHADERS.SLIDER_KEYS) do
        if preset[key] == nil then
            preset[key] = (key == "shader_chromatic_spread") and 100 or 0
        end
    end
    for _, key in ipairs(CONSTANTS.SHADERS.COLOR_KEYS) do
        if preset[key] == nil then
            local d = SHADER_COLOR_DEFAULTS[key] or {255, 255, 255, 255}
            preset[key] = {d[1], d[2], d[3], d[4]}
        end
    end
    return preset
end

local function get_preset_for_map(map_name)
    if not State.config then load_config() end
    if not map_name then return ensure_preset_shader_defaults(State.config.defaults) end

    local preset = {}
    for k, v in pairs(State.config.defaults) do
        if type(v) == "table" then
            preset[k] = {}
            for i, val in ipairs(v) do preset[k][i] = val end
        else
            preset[k] = v
        end
    end

    if State.config.maps and State.config.maps[map_name] then
        for k, v in pairs(State.config.maps[map_name]) do
            if type(v) == "table" then
                preset[k] = {}
                for i, val in ipairs(v) do preset[k][i] = val end
            else
                preset[k] = v
            end
        end
    end

    return ensure_preset_shader_defaults(preset)
end

local function save_preset_for_map(map_name, preset)
    if not State.config then load_config() end
    if not map_name or not preset then return false end
    
    local diff = {}
    for k, v in pairs(preset) do
        local default_val = State.config.defaults[k]
        local is_different = false
        
        if type(v) == "table" and type(default_val) == "table" then
            for i = 1, #v do
                if v[i] ~= default_val[i] then is_different = true; break end
            end
        else
            is_different = (v ~= default_val)
        end
        
        if is_different then diff[k] = v end
    end
    
    if not State.config.maps then State.config.maps = {} end
    State.config.maps[map_name] = diff
    save_config()
    return true
end

-- ========== BLENDING HELPERS ==========
local function get_cutoff_radius()
    return Utils.UI.get_number(UI.sliders.cutoff, 100) * 100  -- 0-100 → 0-10000
end

local function get_max_points()
    return math.floor(Utils.UI.get_number(UI.sliders.max_points, 4))
end



local function collect_closest_points(points, player_pos, cutoff_radius, max_points)
    -- Reusable sort buffer: avoid allocating a new table every frame.
    if not State.cache.sort_table then State.cache.sort_table = {} end
    local result = State.cache.sort_table
    for k in pairs(result) do result[k] = nil end

    local count = 0
    for _, point in ipairs(points) do
        if type(point) == "table" and point.settings then
            local px = tonumber(point.x)
            local py = tonumber(point.y)
            local pz = tonumber(point.z)
            if px and py and pz then
                -- Real (not squared) distance: needed for the sort below.
                local dx = player_pos.x - px
                local dy = player_pos.y - py
                local dz = player_pos.z - pz
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
             
                if cutoff_radius == 0 or dist <= cutoff_radius then
                    count = count + 1
                    result[count] = {point = point, dist = dist}
                end
            end
        end
    end
    
    table_sort(result, function(a, b) return a.dist < b.dist end)
    
    -- Trim to max_points
    for i = count, max_points + 1, -1 do
        result[i] = nil
    end
    
    return result
end

local function get_point_weight(point, map_name)
    if not is_weight_enabled() then return 1.0 end
    local weight_value = CONSTANTS.DEFAULTS.WEIGHT
    if point.id and State.weights_config and State.weights_config.maps and State.weights_config.maps[map_name] then
        local data = State.weights_config.maps[map_name][tostring(point.id)]
        if data and data.weight_level then weight_value = data.weight_level end
    end
    -- Convert 1-10 slider value to multiplier (1 = 0.1, 10 = 1.0)
    return weight_value / 10
end

local function compute_weights(closest_points, cutoff_radius, map_name)
    local weights = {}
    local total = 0
    local fade_start = cutoff_radius * 0.8
    local k, n, epsilon = 1.0, 1.5, 1.0  -- Weight formula constants
    
    for i, cp in ipairs(closest_points) do
        local point_weight = get_point_weight(cp.point, map_name)
        local base = (point_weight ^ k) / ((cp.dist + epsilon) ^ n)
        local fade = 1.0
        if cutoff_radius > 0 and cp.dist > fade_start then
            fade = math.max(0, math.min(1, 1.0 - (cp.dist - fade_start) / (cutoff_radius - fade_start)))
        end
        weights[i] = base * fade
        total = total + weights[i]
    end

    -- Guard against zero/invalid total to avoid NaN propagation.
    if total <= 0 then
        for i = 1, #weights do
            weights[i] = (i == 1) and 1.0 or 0.0
        end
        return weights
    end

    for i = 1, #weights do weights[i] = weights[i] / total end
    return weights
end

local function blend_settings(closest_points, weights)
    local blended = {}
    
    -- Blend world colors
    for _, key in ipairs(CONSTANTS.KEYS.COLOR) do
        blended[key] = {0, 0, 0, 0}
        for i, cp in ipairs(closest_points) do
            local c = cp.point.settings[key]
            if c then
                for j = 1, 4 do blended[key][j] = blended[key][j] + c[j] * weights[i] end
            end
        end
    end
    
    -- Blend world sliders
    for _, key in ipairs(CONSTANTS.KEYS.SLIDER) do
        blended[key] = 0
        for i, cp in ipairs(closest_points) do
            blended[key] = blended[key] + (cp.point.settings[key] or 0) * weights[i]
        end
    end

    -- Blend shader tint colors
    for _, key in ipairs(CONSTANTS.SHADERS.COLOR_KEYS) do
        if should_include_shader_key_in_points(key) then
            local has_value = false
            blended[key] = {0, 0, 0, 0}
            for i, cp in ipairs(closest_points) do
                local c = cp.point.settings[key]
                if c then
                    has_value = true
                    for j = 1, 4 do
                        blended[key][j] = blended[key][j] + (tonumber(c[j]) or 0) * weights[i]
                    end
                end
            end
            if not has_value then
                blended[key] = nil
            end
        end
    end

    -- Blend shader strengths
    for _, key in ipairs(CONSTANTS.SHADERS.SLIDER_KEYS) do
        if should_include_shader_key_in_points(key) then
            local has_value = false
            local value = 0
            for i, cp in ipairs(closest_points) do
                local point_value = cp.point.settings[key]
                if point_value ~= nil then
                    has_value = true
                    value = value + (tonumber(point_value) or 0) * weights[i]
                end
            end
            if has_value then
                blended[key] = value
            end
        end
    end
    
    return blended
end

local function select_target_settings(closest_points, cutoff_radius, map_name)
    if not closest_points or #closest_points == 0 then
        return nil, nil
    end

    -- Fast path only for truly single-point case.
    -- For 2+ points always blend to avoid hard snapping near a point.
    if #closest_points == 1 then
        return filter_shader_settings_for_points(closest_points[1].point.settings), nil
    end

    local weights = compute_weights(closest_points, cutoff_radius, map_name)
    return blend_settings(closest_points, weights), weights
end

-- ========== SMOOTH TRANSITION HELPERS ==========
function Utils.Math.lerp(a, b, t)
    return a + (b - a) * t
end

function Utils.Math.lerp_color(c1, c2, t)
    if not c1 or not c2 then return c2 or c1 end
    return {
        Utils.Math.lerp(c1[1] or 255, c2[1] or 255, t),
        Utils.Math.lerp(c1[2] or 255, c2[2] or 255, t),
        Utils.Math.lerp(c1[3] or 255, c2[3] or 255, t),
        Utils.Math.lerp(c1[4] or 255, c2[4] or 255, t)
    }
end

local function interpolate_settings(from_settings, to_settings, t)
    if not from_settings then return to_settings end
    if not to_settings then return from_settings end
    
    local result = {}
    
    -- Interpolate world colors
    for _, key in ipairs(CONSTANTS.KEYS.COLOR) do
        result[key] = Utils.Math.lerp_color(from_settings[key], to_settings[key], t)
    end
    
    -- Interpolate world sliders
    for _, key in ipairs(CONSTANTS.KEYS.SLIDER) do
        local from_val = from_settings[key] or 0
        local to_val = to_settings[key] or 0
        result[key] = Utils.Math.lerp(from_val, to_val, t)
    end

    -- Interpolate shader tint colors
    for _, key in ipairs(CONSTANTS.SHADERS.COLOR_KEYS) do
        if to_settings[key] ~= nil and should_include_shader_key_in_points(key) then
            local from_color = from_settings[key] or to_settings[key]
            result[key] = Utils.Math.lerp_color(from_color, to_settings[key], t)
        end
    end

    -- Interpolate shader strengths
    for _, key in ipairs(CONSTANTS.SHADERS.SLIDER_KEYS) do
        if to_settings[key] ~= nil and should_include_shader_key_in_points(key) then
            local from_val = tonumber(from_settings[key])
            if from_val == nil then
                from_val = tonumber(to_settings[key]) or 0
            end
            local to_val = tonumber(to_settings[key]) or 0
            result[key] = Utils.Math.lerp(from_val, to_val, t)
        end
    end
    
    -- Copy booleans directly (no interpolation)
    for _, key in ipairs(CONSTANTS.KEYS.BOOL) do
        result[key] = to_settings[key]
    end

    -- Copy skybox state directly.
    result.skybox = to_settings.skybox
    result.custom_skybox = to_settings.custom_skybox

    -- Bloom applied wholesale (no interpolation) -- pass it through so the smooth map transition
    -- doesn't drop it. nil on point-blend targets (stripped from point snapshots) -> apply skips.
    result.bloom_json = to_settings.bloom_json
    result.postfx_json = to_settings.postfx_json

    return result
end

local current_settings = nil
local target_settings = nil

local function reset_smooth_state()
    current_settings = nil
    target_settings = nil
end

local function seed_smooth_state(settings)
    if type(settings) ~= "table" then
        reset_smooth_state()
        return
    end
    current_settings = settings
    target_settings = settings
end

function start_one_shot_smooth_transition(target, apply_shader_state, speed, duration)
    if type(target) ~= "table" then
        return false
    end

    seed_smooth_state(capture_current_settings(apply_shader_state ~= false))

    if State and State.transition then
        State.transition.speed = tonumber(speed) or 1.0
        State.transition.restore_speed_at = runtime_now() + (tonumber(duration) or 1.1)
        State.transition.one_shot_target = target
        State.transition.one_shot_apply_shader_state = apply_shader_state
        State.transition.one_shot_active_until = runtime_now() + (tonumber(duration) or 1.1)
    end

    return true
end

custom_sky_commit_runtime_state = function()
    local selected_custom = tostring(CUSTOM_SKY_PANEL.selected or CUSTOM_SKY_DEFAULT_ENTRY)
    if type(current_settings) == "table" then
        current_settings.skybox = tonumber(CUSTOM_SKY_PANEL.last_standard_index) or 1
        current_settings.custom_skybox_enabled = nil
        current_settings.custom_skybox = nil
        if CUSTOM_SKY_PANEL.enabled == true and selected_custom:lower() ~= CUSTOM_SKY_DEFAULT_ENTRY then
            current_settings.custom_skybox = selected_custom
        end
    end
    if type(target_settings) == "table" then
        target_settings.skybox = tonumber(CUSTOM_SKY_PANEL.last_standard_index) or 1
        target_settings.custom_skybox_enabled = nil
        target_settings.custom_skybox = nil
        if CUSTOM_SKY_PANEL.enabled == true and selected_custom:lower() ~= CUSTOM_SKY_DEFAULT_ENTRY then
            target_settings.custom_skybox = selected_custom
        end
    end
    if State and type(State.map_entry_settings) == "table" then
        State.map_entry_settings.skybox = tonumber(CUSTOM_SKY_PANEL.last_standard_index) or 1
        State.map_entry_settings.custom_skybox_enabled = nil
        State.map_entry_settings.custom_skybox = nil
        if CUSTOM_SKY_PANEL.enabled == true and selected_custom:lower() ~= CUSTOM_SKY_DEFAULT_ENTRY then
            State.map_entry_settings.custom_skybox = selected_custom
        end
    end
end

local function apply_smooth_settings(new_target, apply_shader_state)
    if not new_target then return end
    
    -- Get accurate frame time from Fatality API
    local dt = 0.016  -- Default ~60fps fallback
    local gv = game and game.globalVars or nil
    if gv then
        local ft = gv.m_flRenderFrameTime
        if type(ft) == "number" and ft > 0 then
            dt = ft
        end
    end
    
    -- Clamp delta time to avoid huge jumps
    dt = math.max(0.001, math.min(dt, 0.05))

    local transition_speed = CONSTANTS.DEFAULTS.TRANSITION_SPEED
    if State and State.transition then
        local now = runtime_now()
        local restore_at = tonumber(State.transition.restore_speed_at) or 0
        if restore_at > 0 and now >= restore_at then
            State.transition.speed = CONSTANTS.DEFAULTS.TRANSITION_SPEED
            State.transition.restore_speed_at = 0
        end
        local state_speed = tonumber(State.transition.speed)
        if state_speed and state_speed > 0 then
            transition_speed = state_speed
        end
    end
    
    -- Initialize current_settings if nil
    if not current_settings then
        current_settings = new_target
        target_settings = new_target
        apply_settings(new_target, apply_shader_state)
        return
    end
    
    -- Update target
    target_settings = new_target
    
    -- Calculate interpolation factor (smooth over time)
    -- transition_speed = 3.0 means ~0.3 seconds to complete transition
    local t = math.min(1.0, dt * transition_speed)
    
    -- Interpolate from current to target
    current_settings = interpolate_settings(current_settings, target_settings, t)
    
    -- Apply interpolated settings
    apply_settings(current_settings, apply_shader_state)
end

-- ========== POINTS: BLENDING ==========
local function update_blending(points_enabled, in_game, map_name)
    if points_enabled ~= true or in_game ~= true or not State.points_config then return end
    
    map_name = map_name or Utils.System.get_current_map()
    if not map_name then return end
    
    local maps = State.points_config.maps
    if type(maps) ~= "table" then return end
    local map_data = maps[map_name]
    if type(map_data) ~= "table" or type(map_data.points) ~= "table" or #map_data.points == 0 then return end
    
    if not entities or not entities.GetLocalPawn then return end
    local ok_lp, lp = protected_call(entities.GetLocalPawn, entities)
    local player_pos = nil

    if ok_lp and lp and lp.IsAlive and lp.GetAbsOrigin then
        local ok_alive, alive = protected_call(lp.IsAlive, lp)
        if ok_alive and (alive == true or alive == 1) then
            local ok_pos, pos = protected_call(lp.GetAbsOrigin, lp)
            if ok_pos and pos then
                player_pos = {x = pos.x, y = pos.y, z = pos.z}
            end
        end
    end
    
    -- Fallback to camera position (dead, spec, freecam)
    if not player_pos and State.cache.last_camera_pos then
        player_pos = {x = State.cache.last_camera_pos.x, y = State.cache.last_camera_pos.y, z = State.cache.last_camera_pos.z}
    end
    
    if not player_pos then return end
    

    

    
    local cutoff_radius = get_cutoff_radius()
    local max_points = get_max_points()

    local active_points = collect_closest_points(map_data.points, player_pos, cutoff_radius, max_points)
    if #active_points == 0 then
        return
    end

    local blended, weights = select_target_settings(active_points, cutoff_radius, map_name)

    if not blended then
        return active_points, nil, weights
    end
    local shader_points_enabled = is_shader_points_enabled()
    if shader_points_enabled then
        blended = filter_shader_settings_for_points(blended)
    else
        blended = strip_shader_settings(blended)
    end
    
    -- Apply blended settings (skip in edit mode)
    if not is_settings_edit_enabled() then
        apply_smooth_settings(blended, shader_points_enabled)
        
        -- Force fog/dof ON to avoid flickering (controlled per-map)
        Utils.UI.set_bool("fog", true)
        Utils.UI.set_bool("dof", true)
        
        -- Debug blend values (every 3 sec)
        local time = Utils.System.get_time()
        if not State.timers.last_time or time - State.timers.last_time > 3.0 then
            if is_debug_enabled() then
                debug_print(string.format("Blend: FogSize=%.1f, FogDist=%.1f, DOF=%.1f",
                    blended.fog_size or -1, blended.fog_distance or -1, blended.dof_strength or -1))
            end
            State.timers.last_time = time
        end
        
        -- Weight debug (every 3 sec)
        if is_debug_enabled() and is_weight_enabled() and weights and #weights > 0 then
            if not State.timers.last_weight_time or time - State.timers.last_weight_time > 3.0 then
                local weight_info = {}
                for i, cp in ipairs(active_points) do
                    local pt_id = cp.point.id or "?"
                    local pt_weight = get_point_weight(cp.point, map_name)
                    local blend_pct = (weights[i] or 0) * 100
                    weight_info[i] = string.format("id%s:w%.1f(%.0f%%)", tostring(pt_id), pt_weight, blend_pct)
                end
                debug_print("[WEIGHTS] " .. table.concat(weight_info, ", "))
                State.timers.last_weight_time = time
            end
        end
    end
    
    return active_points, blended, weights
end

local function render_points(active_points, weights, in_game, map_name_override)
    if in_game ~= true then return end
    if not State.points_config then return end
    
    local map_name = map_name_override or Utils.System.get_current_map()
    if not map_name then return end
    
    local maps = State.points_config.maps
    if type(maps) ~= "table" then return end
    local map_data = maps[map_name]
    if type(map_data) ~= "table" or type(map_data.points) ~= "table" then return end

    local show_weight = is_weight_enabled() and is_render_weight_enabled()
    local show_influence = is_render_influence_enabled()
    local weight_map = nil
    if show_weight and State.weights_config and State.weights_config.maps then
        weight_map = State.weights_config.maps[map_name]
    end
    local gui_main_font = draw and draw.fonts and draw.fonts['gui_main'] or nil
    if (show_weight or show_influence) and gui_main_font and draw and draw.surface then
        draw.surface.font = gui_main_font
    end

    local influence_by_point = nil
    if show_influence and type(active_points) == "table" and #active_points > 0 then
        influence_by_point = {}
        if type(weights) == "table" and #weights > 0 then
            for i, cp in ipairs(active_points) do
                if cp and cp.point then
                    local pct = (tonumber(weights[i]) or 0) * 100
                    if pct > 0 then
                        influence_by_point[cp.point] = pct
                    end
                end
            end
        elseif #active_points == 1 and active_points[1] and active_points[1].point then
            influence_by_point[active_points[1].point] = 100
        end
    end
    
    for _, point in ipairs(map_data.points) do
        local px = point and tonumber(point.x)
        local py = point and tonumber(point.y)
        local pz = point and tonumber(point.z)
        if px and py and pz then
        -- Render at head height (approx +64 units from origin)
        local screen_pos = math.world_to_screen(math.vec3(px, py, pz + 64))
        if screen_pos then
            -- 1. FOG GLOW (rim)
            if point.settings and point.settings.fog then
                -- Raw color values (table or defaults)
                local fc_r, fc_g, fc_b = 255, 255, 255
                if point.settings.fog_color then
                    local fc = point.settings.fog_color
                    fc_r, fc_g, fc_b = fc[1], fc[2], fc[3]
                end
                
                -- Radius (fog_distance): smaller distance -> bigger circle
                local fog_dist = point.settings.fog_distance or 1000
                local glow_radius = math.max(10, 40 - (fog_dist / 100))
                
                -- Opacity (fog_size): smaller size -> more visible
                local fog_size = point.settings.fog_size or 50
                local glow_alpha = math.max(20, 255 - (fog_size * 2))

                -- Center: fog color with the computed alpha
                local center_col = draw.Color(fc_r, fc_g, fc_b, math.floor(glow_alpha))
                -- Edge: fully transparent
                local edge_col = draw.Color(fc_r, fc_g, fc_b, 0)
                
                -- Draw a gradient circle (multicolor takes a table {inner, outer})
                -- Check the function exists, the API may differ
                if draw.surface.add_circle_filled_multicolor then
                    draw.surface:AddCircleFilledMulticolor(draw.Vec2(screen_pos.x, screen_pos.y), glow_radius, {center_col, edge_col})
                end
            end
            
            -- 2. SPLIT CIRCLE (Points)
            local wc_col = draw.Color(255, 255, 255, 255)
            if point.settings and point.settings.world_color then
                local wc = point.settings.world_color
                wc_col = draw.Color(wc[1], wc[2], wc[3], wc[4])
            end
            
            local lc_col = draw.Color(255, 255, 255, 255)
            if point.settings and point.settings.lights_color then
                local lc = point.settings.lights_color
                lc_col = draw.Color(lc[1], lc[2], lc[3], lc[4])
            end

            -- OPTIMIZED: Split circle using circle + triangles
            local r = 6
            local cx, cy = screen_pos.x, screen_pos.y
            local center = draw.Vec2(cx, cy)
            
            -- Background: Full circle of Lights Color
            draw.surface:AddCircleFilled(center, r, lc_col, 24)
            
            -- Overlay: Two triangles for World Color (bottom-left diagonal half)
            -- Diagonal goes from top-right to bottom-left
            local top_right = draw.Vec2(cx + r, cy - r)
            local bottom_left = draw.Vec2(cx - r, cy + r)
            draw.surface:AddTriangleFilled(center, bottom_left, draw.Vec2(cx - r, cy - r), wc_col)
            draw.surface:AddTriangleFilled(center, bottom_left, draw.Vec2(cx + r, cy + r), wc_col)
            
            -- Outline
            draw.surface:AddCircle(center, r, draw.Color(0, 0, 0, 255))
            
            -- Weight rendering (only when Enable weight AND Render Weight are ON)
            if show_weight then
                -- Dynamic offset: closer = higher offset (so text doesn't overlap circle)
                -- At close distance, the circle appears larger on screen, need more offset
                -- screen_pos.y is already available, we calculate offset in screen space
                local circle_y = screen_pos.y
                
                -- Fixed pixel offset above the circle (always above, regardless of distance)
                local text_offset_y = 15  -- pixels above circle center
                
                local wx = screen_pos.x
                local wy = circle_y - text_offset_y  -- Always above circle
                
                if point.missing_weight then
                    -- RED CROSS for missing weights
                    local cross_r = 5
                    local cross_col = draw.Color(255, 80, 80, 255)
                    
                    draw.surface:AddLine(
                        draw.Vec2(wx - cross_r, wy - cross_r),
                        draw.Vec2(wx + cross_r, wy + cross_r),
                        cross_col
                    )
                    draw.surface:AddLine(
                        draw.Vec2(wx + cross_r, wy - cross_r),
                        draw.Vec2(wx - cross_r, wy + cross_r),
                        cross_col
                    )
                else
                    -- NUMBER for existing weights
                    local weight_level = CONSTANTS.DEFAULTS.WEIGHT
                    if point.id and weight_map then
                        local data = weight_map[tostring(point.id)]
                        if data and data.weight_level then
                            weight_level = data.weight_level
                        end
                    end
                    
                    -- Color coding by weight strength
                    local text_col
                    if weight_level <= 3 then
                        -- Low (1-3): Blue/Cyan
                        text_col = draw.Color(100, 180, 255, 255)
                    elseif weight_level <= 7 then
                        -- Medium (4-7): White/Yellow
                        text_col = draw.Color(255, 255, 180, 255)
                    else
                        -- High (8-10): Orange/Red
                        text_col = draw.Color(255, 140, 60, 255)
                    end
                    
                    -- Draw weight number (centered above circle)
                    local weight_text = tostring(weight_level)
                    draw.surface:AddText(draw.Vec2(wx - 3, wy - 5), weight_text, text_col)
                end
            end

            if influence_by_point then
                local influence_pct = influence_by_point[point]
                if influence_pct and influence_pct > 0 then
                    local influence_text = string.format("%.0f%%", influence_pct)
                    local influence_y = screen_pos.y - 24
                    if show_weight then
                        influence_y = influence_y - 12
                    end
                    local influence_x = screen_pos.x - (#influence_text * 3)
                    draw.surface:AddText(draw.Vec2(influence_x + 1, influence_y + 1), influence_text, draw.Color(0, 0, 0, 220))
                    draw.surface:AddText(draw.Vec2(influence_x, influence_y), influence_text, draw.Color(160, 255, 160, 255))
                end
            end
        end
        end
    end
end

local function render_lines(active_points, current_blended, in_game)
    if in_game ~= true then return end
    if not active_points or #active_points == 0 then return end
    
    local start_screen = nil
    
    -- Third-person check
    if is_thirdperson_enabled() then
        -- In third person: from the character's head
        if not entities or not entities.GetLocalPawn then return end
        local ok_lp, lp = protected_call(entities.GetLocalPawn, entities)
        if (not ok_lp) or (not lp) or (not lp.IsAlive) or (not lp.GetAbsOrigin) then return end

        local ok_alive, alive = protected_call(lp.IsAlive, lp)
        if (not ok_alive) or (alive ~= true and alive ~= 1) then return end

        local ok_pos, pos = protected_call(lp.GetAbsOrigin, lp)
        if not ok_pos or not pos then return end
        start_screen = math.world_to_screen(math.vec3(pos.x, pos.y, pos.z + 64))
    end
    
    if not start_screen then return end
    
    -- Current blend color
    local start_color = draw.Color(255, 255, 255, 255)
    if current_blended and current_blended.world_color then
        local wc = current_blended.world_color
        start_color = draw.Color(wc[1], wc[2], wc[3], wc[4])
    end
    
    for _, cp in ipairs(active_points) do
        local point = cp.point
        -- Render line to head height (+64), same as circle
        local end_screen = math.world_to_screen(math.vec3(point.x, point.y, point.z + 64))
        
        if end_screen then
            local end_color = draw.Color(255, 255, 255, 255)
            if point.settings and point.settings.world_color then
                local wc = point.settings.world_color
                end_color = draw.Color(wc[1], wc[2], wc[3], wc[4])
            end
            
            -- Draw a gradient line
            draw.surface:AddLineMulticolor(
                draw.Vec2(start_screen.x, start_screen.y),
                draw.Vec2(end_screen.x, end_screen.y),
                start_color,
                end_color,
                2.0 -- Thickness
            )
        end
    end
end

function clear_runtime_render_cache()
    if not State or type(State.cache) ~= "table" then
        return
    end
    State.cache.last_active_points = nil
    State.cache.last_active_weights = nil
    State.cache.last_current_blended = nil
end


-- ========== POINTS: FUNCTIONS ==========

local function check_map_feature_usage(map_name)
    -- Deprecated / Removed logic
end

local function is_mirage_preset_enabled()
    if not UI.checkboxes.mirage_preset then return false end
    local val = UI.checkboxes.mirage_preset:GetValue()
    if val and val.Get then return val:Get() == true end
    return false
end

local function create_points_config()
    -- Always reset/recreate config (deletes existing!)
    State.points_config = {version = 2, maps = {}}
    State.next_point_id = 1  -- Reset ID counter
    
    -- Also reset weights config
    State.weights_config = {version = 1, maps = {}}
    save_weights_config()
    
    save_points_config()
    
    notify_user("Points", "Config RESET! All points deleted.")
    return true
end

local function save_current_point()
    if not Utils.System.is_in_game() then return false end
    
    local lp = entities.GetLocalPawn()
    if not lp or not lp:IsAlive() then return false end
    
    local pos = lp:GetAbsOrigin()
    if not pos then return false end
    
    local map_name = Utils.System.get_current_map()
    if not map_name then return false end
    
    if not State.points_config then
        create_points_config()
    end
    
    if not State.points_config.maps[map_name] then
        State.points_config.maps[map_name] = {points = {}}
    end
    
    -- Generate new unique ID
    local new_id = get_new_point_id()
    
    local point = {
        id = new_id,
        x = pos.x, y = pos.y, z = pos.z,
        settings = capture_point_settings_snapshot(capture_current_settings(is_shader_points_enabled()))
    }
    
    local pts = State.points_config.maps[map_name].points
    pts[#pts + 1] = point
    save_points_config()
    
    -- Save weight for this NEW point
    local weight_idx = CONSTANTS.DEFAULTS.WEIGHT  -- Default: 5
    if UI.sliders.weight then
        local val = UI.sliders.weight:GetValue()
        if val and val.Get then weight_idx = val:Get() end
    end
    
    if not State.weights_config then State.weights_config = {version = 1, maps = {}} end
    if not State.weights_config.maps[map_name] then State.weights_config.maps[map_name] = {} end
    State.weights_config.maps[map_name][tostring(new_id)] = {weight_level = weight_idx}
    State.weights_dirty = true
    save_weights_config()
    
    debug_print(string.format("Saved point #%d (ID: %d) with Weight level: %d", #pts, new_id, weight_idx))
    
    notify_user("Points", string.format("Point #%d saved (Weight: %d)!", #pts, weight_idx))
    
    check_map_feature_usage(map_name) -- Update the flags
    return point, pos.x, pos.y, pos.z
end



local function add_preset_points()
    local map_name = Utils.System.get_current_map()
    
    -- If NOT in game or no map name -> Add ALL presets
    if not Utils.System.is_in_game() or not map_name then
        local added_total = 0
        
        -- Load config if needed
        if not State.points_config then
            load_points_config()
        end
        if not State.points_config then create_points_config() end
        
        if not State.weights_config then
            load_weights_config()
        end
        if not State.weights_config then State.weights_config = {version = 1, maps = {}} end
        
        -- Capture current settings once to use for all points
        local settings_to_use = capture_point_settings_snapshot(capture_current_settings(is_shader_points_enabled()))
        
        for m_name, preset in pairs(CONSTANTS.DEFAULTS.POINTS) do
            if preset and preset.points then
                -- Ensure map config exists
                if not State.points_config.maps[m_name] then
                    State.points_config.maps[m_name] = {points = {}}
                end
                if not State.points_config.maps[m_name].points then
                    State.points_config.maps[m_name].points = {}
                end
                
                -- Ensure weights map config exists
                if not State.weights_config.maps[m_name] then
                    State.weights_config.maps[m_name] = {}
                end
                
                local pts = State.points_config.maps[m_name].points
                for _, p in ipairs(preset.points) do
                    -- Assign ID
                    local new_id = get_new_point_id()
                    
                    local new_point = {
                        id = new_id,
                        x = p.x, y = p.y, z = p.z,
                        settings = settings_to_use
                    }
                    
                    pts[#pts + 1] = new_point
                    
                    -- Add weight
                    State.weights_config.maps[m_name][tostring(new_id)] = {weight_level = CONSTANTS.DEFAULTS.WEIGHT}
                    added_total = added_total + 1
                end
                
                check_map_feature_usage(m_name)
            end
        end
        
        save_points_config()
        save_weights_config()
        
        notify_user("Points", string.format("Added all presets (%d points)!", added_total))
        return true
    end
    
    -- If IN GAME -> Add points for CURRENT MAP only
    local preset = CONSTANTS.DEFAULTS.POINTS[map_name]
    if not preset or not preset.points then
        notify_user("Points", "Map does not exist in preset")
        return false
    end
    
    -- Check if config loaded or exists
    if not State.points_config then
        load_points_config()
    end
    
    if not State.points_config then
        create_points_config()
    end
    
    if not State.points_config.maps[map_name] then
        State.points_config.maps[map_name] = {points = {}}
    end
    
    if not State.points_config.maps[map_name].points then
        State.points_config.maps[map_name].points = {}
    end
    
    local settings_to_use = capture_point_settings_snapshot(State.map_entry_settings or capture_current_settings(is_shader_points_enabled()))
    local pts = State.points_config.maps[map_name].points
    local added_count = 0
    
    for _, p in ipairs(preset.points) do
         local new_id = get_new_point_id()
         
         local new_point = {
             id = new_id,
             x = p.x, y = p.y, z = p.z,
             settings = settings_to_use
         }
         
         pts[#pts + 1] = new_point
         
         -- Add weight
         if not State.weights_config then State.weights_config = {version = 1, maps = {}} end
         if not State.weights_config.maps[map_name] then State.weights_config.maps[map_name] = {} end
         State.weights_config.maps[map_name][tostring(new_id)] = {weight_level = CONSTANTS.DEFAULTS.WEIGHT}
         
         added_count = added_count + 1
    end
    
    save_points_config()
    save_weights_config()
    debug_print(string.format("Added %d preset points for %s", added_count, map_name))
    
    notify_user("Points", string.format("Added %d standard points!", added_count))
    
    check_map_feature_usage(map_name) 
    return true
end

local function add_standart_point()
    if not Utils.System.is_in_game() then return false end
    
    local lp = entities.GetLocalPawn()
    if not lp or not lp:IsAlive() then return false end
    
    local pos = lp:GetAbsOrigin()
    if not pos then return false end
    
    local map_name = Utils.System.get_current_map()
    if not map_name then return false end
    
    if not State.points_config then
        create_points_config()
    end
    
    if not State.points_config.maps[map_name] then
        State.points_config.maps[map_name] = {points = {}}
    end
    
    if not State.points_config.maps[map_name].points then
        State.points_config.maps[map_name].points = {}
    end
    
    -- Use the settings on map entry
    local settings_to_use = capture_point_settings_snapshot(State.map_entry_settings or capture_current_settings(is_shader_points_enabled()))
    
    -- Assign new unique ID
    local new_id = get_new_point_id()
    
    local point = {
        id = new_id,
        x = pos.x, y = pos.y, z = pos.z,
        settings = settings_to_use
    }
    
    local pts = State.points_config.maps[map_name].points
    pts[#pts + 1] = point
    save_points_config()
    
    -- Save weight for this point
    local weight_idx = CONSTANTS.DEFAULTS.WEIGHT  -- Default: 5
    if UI.sliders.weight then
        local val = UI.sliders.weight:GetValue()
        if val and val.Get then weight_idx = val:Get() end
    end
    
    if not State.weights_config then State.weights_config = {version = 1, maps = {}} end
    if not State.weights_config.maps[map_name] then State.weights_config.maps[map_name] = {} end
    State.weights_config.maps[map_name][tostring(new_id)] = {weight_level = weight_idx}
    State.weights_dirty = true
    save_weights_config()
    
    debug_print(string.format("Saved STANDARD point #%d (id=%d, weight=%d) using MAP ENTRY settings", #pts, new_id, weight_idx))
    
    notify_user("Points", string.format("Standart point #%d added!", #pts))
    
    check_map_feature_usage(map_name) -- Update the flags
    return true
end

local function delete_closest_point()
    if not Utils.System.is_in_game() then return false end
    
    local lp = entities.GetLocalPawn()
    if not lp or not lp:IsAlive() then return false end
    
    local player_pos = lp:GetAbsOrigin()
    if not player_pos then return false end
    
    local map_name = Utils.System.get_current_map()
    if not map_name or not State.points_config then return false end
    
    if not State.points_config.maps[map_name] or not State.points_config.maps[map_name].points then
        return false
    end
    
    local pts = State.points_config.maps[map_name].points
    if #pts == 0 then return false end
    
    -- Find the nearest point
    local closest_idx = nil
    local closest_dist = math.huge
    
    for i, point in ipairs(pts) do
        local dist = Utils.Math.distance_3d(player_pos, point)
        if dist < closest_dist then
            closest_dist = dist
            closest_idx = i
        end
    end
    
    if not closest_idx then return false end
    
    -- Get point ID before deletion for weight cleanup
    local deleted_point_id = pts[closest_idx].id
    
    -- Remove the nearest point
    table.remove(pts, closest_idx)
    save_points_config()
    
    -- Delete corresponding weight
    if deleted_point_id and State.weights_config and State.weights_config.maps[map_name] then
        State.weights_config.maps[map_name][tostring(deleted_point_id)] = nil
        State.weights_dirty = true
        save_weights_config()
    end
    
    debug_print(string.format("Deleted closest point #%d (id=%s, dist: %.1f)", closest_idx, tostring(deleted_point_id), closest_dist))
    
    -- No points left: restore the map's default settings
    if #pts == 0 then
        if State.map_entry_settings then
             apply_settings(State.map_entry_settings)
             debug_print("Deleted LAST point. Restored map defaults.")
             notify_user("Points", "Last point deleted! Map defaults restored.")
        else
             debug_print("Deleted last point, but no map entry settings found.")
        end
    else
        -- Regular notification
        notify_user("Points", string.format("Point #%d deleted! (%.0f units away)", closest_idx, closest_dist))
    end
    
    return true
    

end

local function rewrite_closest_point()
    if not Utils.System.is_in_game() then return false end
    
    local lp = entities.GetLocalPawn()
    if not lp or not lp:IsAlive() then return false end
    
    local player_pos = lp:GetAbsOrigin()
    if not player_pos then return false end
    
    local map_name = Utils.System.get_current_map()
    if not map_name or not State.points_config then return false end
    
    if not State.points_config.maps[map_name] or not State.points_config.maps[map_name].points then
        return false
    end
    
    local pts = State.points_config.maps[map_name].points
    if #pts == 0 then return false end
    
    -- Find the nearest point
    local closest_idx = nil
    local closest_dist = math.huge
    
    for i, point in ipairs(pts) do
        local dist = Utils.Math.distance_3d(player_pos, point)
        if dist < closest_dist then
            closest_dist = dist
            closest_idx = i
        end
    end
    
    if not closest_idx then return false end
    
    -- Overwrite the settings (keep the old position)
    pts[closest_idx].settings = capture_point_settings_snapshot(capture_current_settings(is_shader_points_enabled()))
    
    save_points_config()
    
    -- Rewrite Weight for this point
    local point_id = pts[closest_idx].id
    if point_id then
        local weight_idx = CONSTANTS.DEFAULTS.WEIGHT -- Default: 5
        if UI.sliders.weight then
            local val = UI.sliders.weight:GetValue()
            if val and val.Get then weight_idx = val:Get() end
        end
        
        if not State.weights_config then State.weights_config = {version = 1, maps = {}} end
        if not State.weights_config.maps[map_name] then State.weights_config.maps[map_name] = {} end
        
        -- Create/Update weight
        State.weights_config.maps[map_name][tostring(point_id)] = {weight_level = weight_idx}
        pts[closest_idx].missing_weight = nil -- Update visual state
        State.weights_dirty = true
        save_weights_config()
        
        debug_print(string.format("Rewritten point #%d (ID: %d, Weight: %d)", closest_idx, point_id, weight_idx))
    end

    notify_user("Points", string.format("Point #%d updated!", closest_idx))
    
    return true
end


-- ========== MAP CHANGE HANDLING ==========
local was_in_game = false
-- map_has_fog/dof declared at top




-- ========== WEIGHTS CLEANUP ==========
local function cleanup_weights(map_name)
    if not State.weights_config or not State.weights_config.maps then return end
    if not State.weights_config.maps[map_name] then return end
    
    -- Build set of existing point IDs
    local existing_ids = {}
    if State.points_config and State.points_config.maps[map_name] then
        for _, pt in ipairs(State.points_config.maps[map_name].points or {}) do
            if pt.id then existing_ids[tostring(pt.id)] = true end
        end
    end
    
    -- If no points exist for map, remove entire weight block
    if not next(existing_ids) then
        State.weights_config.maps[map_name] = nil
        State.weights_dirty = true
        debug_print("[Weights] No points for map " .. map_name .. ", removed weight block")
        return
    end
    
    -- Remove orphan weights (weights for non-existent point IDs)
    local dirty = false
    for weight_id, _ in pairs(State.weights_config.maps[map_name]) do
        if not existing_ids[weight_id] then
            State.weights_config.maps[map_name][weight_id] = nil
            dirty = true
            debug_print("[Weights] Removed orphan weight for id " .. weight_id)
        end
    end
    
    -- Remove empty map block
    if next(State.weights_config.maps[map_name]) == nil then
        State.weights_config.maps[map_name] = nil
        dirty = true
    end
    
    if dirty then State.weights_dirty = true end
end

local function check_missing_weights(map_name)
    if not State.points_config or not State.points_config.maps[map_name] then return end
    local pts = State.points_config.maps[map_name].points
    if not pts then return end
    
    local missing_count = 0
    for _, pt in ipairs(pts) do
        if pt.id then
            local has_weight = State.weights_config and 
                               State.weights_config.maps[map_name] and 
                               State.weights_config.maps[map_name][tostring(pt.id)]
            if not has_weight then
                pt.missing_weight = true
                missing_count = missing_count + 1
                debug_print("[ColoredMaps] Missing weight for point id " .. pt.id .. " on map " .. map_name)
            else
                pt.missing_weight = false
            end
        end
    end
    
    if missing_count > 0 then
        notify_user("Weights", string.format("%d points missing weights!", missing_count))
    end
end

local function fill_missing_point_settings(map_name)
    if not State.points_config or not State.points_config.maps[map_name] then return end
    
    local pts = State.points_config.maps[map_name].points
    if not pts then return end
    
    local dirty = false
    local current_defaults = nil 
    
    -- List of all keys we want to ensure exist
    local ALL_KEYS = {
        "world_color", "lights_color", "sky_color", "cloud_color", "sun_color", "fog_color",
        "dof", "dof_strength", "dof_far_start", "dof_far_end", "dof_near_start", "dof_near_end",
        "fog", "fog_distance", "fog_size", "exposure"
    }

    for _, point in ipairs(pts) do
        if point.settings then
            -- Keep shader_* keys in point payload.
            -- They are conditionally ignored/applied at runtime by shader-points mode.
            for _, key in ipairs(ALL_KEYS) do
                if point.settings[key] == nil then
                    -- Capture defaults only if we actually need them (lazy load)
                    if not current_defaults then 
                        current_defaults = capture_current_settings() 
                    end
                    
                    if current_defaults then
                        point.settings[key] = current_defaults[key]
                        dirty = true
                    end
                end
            end
        end
    end
    
    if dirty then
        save_points_config()
        debug_print("[Points] Filled missing settings for map " .. map_name)
    end
end

local function on_map_loaded(map_name)
    if not map_name then return end
    __cm_verbose_log("stage:on_map_loaded:start map=" .. tostring(map_name), true)

    -- Check Fog/DOF usage on the map
    check_map_feature_usage(map_name)
    __cm_verbose_log("stage:on_map_loaded:feature_usage_done map=" .. tostring(map_name), true)

    -- Load Map-Specific Settings (Cutoff/MaxPoints)
    if State.points_config and State.points_config.maps and State.points_config.maps[map_name] then
        __cm_verbose_log("stage:on_map_loaded:points_map_data_found map=" .. tostring(map_name), true)
        local map_data = State.points_config.maps[map_name]
        
        -- Cutoff Radius
        if map_data.cutoff_radius then
            if UI.sliders.cutoff then UI.sliders.cutoff:GetValue():Set(map_data.cutoff_radius) end
        else
            -- If missing, save current slider value (default or previous) to config
            if UI.sliders.cutoff then
                 map_data.cutoff_radius = UI.sliders.cutoff:GetValue():Get()
                 save_points_config()
            end
        end
        
        -- Max Points
        if map_data.max_points then
            if UI.sliders.max_points then UI.sliders.max_points:GetValue():Set(map_data.max_points) end
        else
            -- If missing, save current slider value
            if UI.sliders.max_points then
                 map_data.max_points = UI.sliders.max_points:GetValue():Get()
                 save_points_config()
            end
        end


    end
    __cm_verbose_log("stage:on_map_loaded:points_ui_sync_done map=" .. tostring(map_name), true)
    if not State.config then load_config() end
    if not State.config.maps then State.config.maps = {} end
    __cm_verbose_log("stage:on_map_loaded:config_ready map=" .. tostring(map_name), true)

    -- Create the map entry if missing
    if not State.config.maps[map_name] then
        State.config.maps[map_name] = {}
    end
    
    -- FILL MISSING MAP SETTINGS
    -- Logic: If a setting is missing in the map config, take it from current cheat settings
    local current_cheat_settings = capture_current_settings()
    local map_config_changed = false
    
    for key, value in pairs(current_cheat_settings) do
        -- Bloom is opt-in per map: never auto-fill it from the currently-live (carried-over) bloom,
        -- otherwise "no bloom config -> zero" is defeated (the map would inherit+save current bloom).
        -- It only enters a map's config when the user explicitly hits "Save map setts".
        if key ~= "bloom_json" and key ~= "postfx_json" and State.config.maps[map_name][key] == nil then
            State.config.maps[map_name][key] = value
            map_config_changed = true
        end
    end

    if map_config_changed then
        save_config()
        debug_print("Filled missing map settings for: " .. map_name)
    end
    __cm_verbose_log("stage:on_map_loaded:fill_missing_map_settings_done changed=" .. tostring(map_config_changed), true)
    -- Load weights and restore the ID counter
    if not State.weights_config then load_weights_config() end
    restore_next_point_id(map_name)
    __cm_verbose_log("stage:on_map_loaded:weights_restore_done map=" .. tostring(map_name), true)

    -- Auto-migrate/Fill missing settings for POINTS
    fill_missing_point_settings(map_name)
    __cm_verbose_log("stage:on_map_loaded:fill_missing_point_settings_done map=" .. tostring(map_name), true)

    -- Re-arm per-filter "Save to point" checkboxes from this map's point data, so that
    -- shaders saved into points are recognized (and applied) again after reload.
    restore_shader_point_filters_for_map(map_name)
    __cm_verbose_log("stage:on_map_loaded:shader_point_filters_restored map=" .. tostring(map_name), true)
    
    -- Clean up stale weights
    cleanup_weights(map_name)
    __cm_verbose_log("stage:on_map_loaded:cleanup_weights_done map=" .. tostring(map_name), true)
    
    -- Check for missing weights
    check_missing_weights(map_name)
    __cm_verbose_log("stage:on_map_loaded:check_missing_weights_done map=" .. tostring(map_name), true)

    -- Save weights if the cleanup changed anything
    if State.weights_dirty then save_weights_config() end
    __cm_verbose_log("stage:on_map_loaded:weights_save_done dirty=" .. tostring(State.weights_dirty == true), true)
    -- FIRST apply the map preset
    local preset = get_preset_for_map(map_name)
    -- Bloom is map-scoped and independent of the points gate: apply this map's saved bloom, or ZERO
    -- everything when the map has none (never carry bloom over from the previous map).
    cm_bloom_apply_or_zero(preset)
    -- Tonemap/local contrast: apply the map's saved curve, or clear the seed so the engine re-seeds
    -- from THIS map instead of carrying the previous map's curve over.
    cm_postfx_apply_or_reseed(preset)
    local preset_transition_started = false
    if preset and not is_points_enabled() then
        preset_transition_started = start_one_shot_smooth_transition(preset, nil, 1.0, 1.15) == true
        if not preset_transition_started then
            apply_settings(preset)
        end
        debug_print("Applied preset for map: " .. map_name)
    end
    __cm_verbose_log("stage:on_map_loaded:preset_applied map=" .. tostring(map_name), true)
    -- THEN save the settings (with the preset already applied)
    State.map_entry_settings = preset or capture_current_settings()
    if not preset_transition_started then
        seed_smooth_state(State.map_entry_settings)
    end
    __cm_verbose_log("stage:on_map_loaded:map_entry_captured map=" .. tostring(map_name), true)

    -- Shaders: same map/settings logic as the world + map-scoped Color Replace.
    apply_shader_replace_for_map(map_name)
    __cm_verbose_log("stage:on_map_loaded:shader_replace_done map=" .. tostring(map_name), true)

    debug_print("Map loaded: " .. map_name)
    __cm_verbose_log("stage:on_map_loaded:done map=" .. tostring(map_name), true)
end

local function check_map_change()
    local in_session = engine_in_game() and engine_is_connected()
    local now = runtime_now()

    if was_in_game and not in_session then
        __cm_verbose_log("stage:map_change:left_game", true)
        if UI and UI.cache then
            UI.cache = {}
        end
        State.current_map = nil
        runtime_loaded_map = nil
        shader_runtime_can_render = false
        State.map_entry_settings = nil
        clear_runtime_render_cache()
        map_change_pending_name = nil
        map_change_pending_started_at = 0
        map_change_pending_frames = 0
    end

    was_in_game = in_session
    if not in_session then
        return nil
    end

    local map = Utils.System.get_current_map()
    if not map or map == "" then
        __cm_verbose_log("stage:map_change:map_nil_or_empty", true)
        if UI and UI.cache then
            UI.cache = {}
        end
        map_change_pending_name = nil
        map_change_pending_started_at = 0
        map_change_pending_frames = 0
        runtime_loaded_map = nil
        shader_runtime_can_render = false
        clear_runtime_render_cache()
        return nil
    end

    -- On first sign of map transition, immediately disable runtime-heavy path.
    if map ~= State.current_map then
        __cm_verbose_log(
            "stage:map_change:transition_detected current=" .. tostring(State.current_map) ..
            " new=" .. tostring(map),
            true
        )
        if UI and UI.cache then
            UI.cache = {}
        end
        runtime_loaded_map = nil
        shader_runtime_can_render = false
        clear_runtime_render_cache()
        set_transition_cooldown(MAP_COOLDOWN_ON_CHANGE)

        if map ~= map_change_pending_name then
            map_change_pending_name = map
            map_change_pending_started_at = now
            map_change_pending_frames = 1
            __cm_verbose_log("stage:map_change:pending_start map=" .. tostring(map), true)
            return nil
        end

        map_change_pending_frames = map_change_pending_frames + 1
        if map_change_pending_frames < MAP_CHANGE_STABLE_FRAMES then
            __cm_verbose_log(
                "stage:map_change:pending_frames " ..
                tostring(map_change_pending_frames) .. "/" .. tostring(MAP_CHANGE_STABLE_FRAMES),
                true
            )
            return nil
        end
        if (now - map_change_pending_started_at) < MAP_CHANGE_STABLE_SECONDS then
            __cm_verbose_log("stage:map_change:pending_time_wait", true)
            return nil
        end

        State.current_map = map
        State.map_entry_settings = nil
        map_change_pending_name = map
        map_change_pending_started_at = now
        map_change_pending_frames = MAP_CHANGE_STABLE_FRAMES
        __cm_verbose_log("stage:map_change:stable_confirmed map=" .. tostring(map), true)
        return map
    end

    -- Stable current map (no transition in progress).
    map_change_pending_name = map
    map_change_pending_started_at = now
    map_change_pending_frames = MAP_CHANGE_STABLE_FRAMES
    return map
end



-- ========== CONTROL CALLBACKS ==========
local controls_cache = {}

local function get_cached_control(key)
    if controls_cache[key] then return controls_cache[key] end
    local path = CONTROL_PATHS[key]
    if path then
        local ctrl = get_control(path)
        if ctrl then
            controls_cache[key] = ctrl
            return ctrl
        end
    end
    return nil
end



-- ========== UI ==========
local ENABLE_ELEMENTS_A_MIRROR = true

local ELEMENTS_A_MIRROR = {
    initialized = false,
    group = nil,
    syncing = false,
    last_sync_time = 0,
    sync_interval = 0.20,
    controls = {},
    rows = {},
    color_groups = {}
}

local SKYBOX_OPTIONS = {
    "Default",
    "Disabled",
    "Aztec",
    "Cloudy",
    "Sunset",
    "Italy"
}

local function mirror_add_child(parent, child)
    if not parent or not child then
        return false
    end
    if parent.Add then
        local ok_add, ret_add = protected_call(parent.Add, parent, child)
        if ok_add and ret_add ~= false then
            return true
        end
    end
    return false
end

local function mirror_set_checkbox(ctrl, state)
    if not ctrl or not ctrl.GetValue then return end
    local v = ctrl:GetValue()
    if v and v.Set then
        v:Set(state == true)
    end
end

local function mirror_set_number(ctrl, number_value)
    if not ctrl or not ctrl.GetValue then return end
    local v = ctrl:GetValue()
    if v and v.Set then
        v:Set(tonumber(number_value) or 0)
    end
end

local function mirror_set_color(ctrl, rgba)
    if not ctrl or not ctrl.GetValue or type(rgba) ~= "table" then return end
    local v = ctrl:GetValue()
    if not v or not v.Set then return end
    local r = tonumber(rgba[1]) or 255
    local g = tonumber(rgba[2]) or 255
    local b = tonumber(rgba[3]) or 255
    local a = tonumber(rgba[4]) or 255
    v:Set(draw.Color(r, g, b, a))
end

function sync_elements_a_mirror_color_from_script(key, rgba)
    if not ENABLE_ELEMENTS_A_MIRROR or type(ELEMENTS_A_MIRROR) ~= "table" then
        return
    end
    if ELEMENTS_A_MIRROR.initialized ~= true or ELEMENTS_A_MIRROR.syncing == true then
        return
    end
    local ctrl = ELEMENTS_A_MIRROR.controls and ELEMENTS_A_MIRROR.controls[key] or nil
    if not ctrl or type(rgba) ~= "table" then
        return
    end
    ELEMENTS_A_MIRROR.syncing = true
    mirror_set_color(ctrl, rgba)
    ELEMENTS_A_MIRROR.syncing = false
end

function sync_elements_a_mirror_number_from_script(key, number_value)
    if not ENABLE_ELEMENTS_A_MIRROR or type(ELEMENTS_A_MIRROR) ~= "table" then
        return
    end
    if ELEMENTS_A_MIRROR.initialized ~= true or ELEMENTS_A_MIRROR.syncing == true then
        return
    end
    local ctrl = ELEMENTS_A_MIRROR.controls and ELEMENTS_A_MIRROR.controls[key] or nil
    local n = tonumber(number_value)
    if not ctrl or not n then
        return
    end
    ELEMENTS_A_MIRROR.syncing = true
    mirror_set_number(ctrl, n)
    ELEMENTS_A_MIRROR.syncing = false
end

local function mirror_set_combo_index(ctrl, index)
    if not ctrl or not ctrl.GetValue then return end
    local value_param = ctrl:GetValue()
    if not value_param or not value_param.Get then return end
    local bits = value_param:Get()
    if bits and bits.SetRaw then
        local idx = math.max(1, math.floor(tonumber(index) or 1))
        bits:SetRaw(math.floor(2 ^ (idx - 1)))
        if value_param.Set then
            value_param:Set(bits)
        end
    end
end

local function mirror_try_set_tooltip(target, text)
    if not target or type(text) ~= "string" or text == "" then
        return
    end
    target.tooltip = text
end

local function mirror_add_row(parent, key, label, ctrl, tooltip_text)
    if not parent or not ctrl or not gui or not gui.MakeControl then
        return nil
    end
    local row = gui.MakeControl(label, ctrl)
    if not row then
        return nil
    end
    ELEMENTS_A_MIRROR.controls[key] = ctrl
    ELEMENTS_A_MIRROR.rows[key] = row
    mirror_try_set_tooltip(ctrl, tooltip_text)
    mirror_add_child(parent, row)
    return row
end

local function mirror_register_color_control(key, ctrl)
    if not key or not ctrl then
        return
    end
    ELEMENTS_A_MIRROR.controls[key] = ctrl
    ELEMENTS_A_MIRROR.color_groups[#ELEMENTS_A_MIRROR.color_groups + 1] = {
        control = ctrl,
        keys = { key }
    }
end

local function mirror_add_color_row(parent, key, label, id_suffix, tooltip_text)
    if not gui or not gui.ColorPicker or not gui.ControlID then
        return nil
    end
    local ctrl = gui.ColorPicker(gui.ControlID("cm_world_mirror_" .. tostring(id_suffix)))
    local row = mirror_add_row(parent, key, label, ctrl, tooltip_text)
    if row and ctrl then
        mirror_register_color_control(key, ctrl)
    end
    return row
end

local function mirror_add_color_to_row(row, key, id_suffix, tooltip_text)
    if not row or not gui or not gui.ColorPicker or not gui.ControlID then
        return nil
    end
    local ctrl = gui.ColorPicker(gui.ControlID("cm_world_mirror_" .. tostring(id_suffix)))
    if not ctrl then
        return nil
    end
    mirror_register_color_control(key, ctrl)
    mirror_try_set_tooltip(ctrl, tooltip_text)
    mirror_add_child(row, ctrl)
    return ctrl
end

local function mirror_add_settings(parent_row, id_suffix)
    if not parent_row or not gui or not gui.Settings then
        return nil
    end
    local settings = gui.Settings("cm_world_mirror_settings_" .. tostring(id_suffix))
    if settings and mirror_add_child(parent_row, settings) then
        return settings
    end
    return nil
end

function custom_sky_update_mirror_skybox_visibility()
    local enabled = CUSTOM_SKY_PANEL.enabled == true

    local row = ELEMENTS_A_MIRROR and ELEMENTS_A_MIRROR.rows and ELEMENTS_A_MIRROR.rows.skybox or nil
    set_row_visible(row, not enabled)

    local mirror_sky = ELEMENTS_A_MIRROR and ELEMENTS_A_MIRROR.controls and ELEMENTS_A_MIRROR.controls.sky_color or nil

    -- When switching TO our picker, seed it from the native one's current value so the colour
    -- carries over 1:1 (no jump to white) before the points blending starts driving it.
    if enabled and CM_SKY_COLOR_CTRL and mirror_sky then
        local r, g, b, a = get_color_rgba(mirror_sky, 255, 255, 255, 255)
        protected_call(function()
            local vp = CM_SKY_COLOR_CTRL:GetValue()
            if vp and vp.Set and draw and draw.Color then
                vp:Set(draw.Color(r, g, b, a))
            end
        end)
    end

    -- Swap the sky-colour picker on the custom-skybox toggle: OUR independent picker when
    -- custom skybox is on, the cheat-mirrored one when off.
    if CM_SKY_COLOR_CTRL then
        set_row_visible(CM_SKY_COLOR_CTRL, enabled)
    end
    if mirror_sky then
        set_row_visible(mirror_sky, not enabled)
    end
end

local create_elements_a_mirror_ui

local function sync_elements_a_mirror_from_cheat(force)
    if not ENABLE_ELEMENTS_A_MIRROR or not ELEMENTS_A_MIRROR.initialized or not ELEMENTS_A_MIRROR.group then return end
    local now = runtime_now()
    if not force and (now - ELEMENTS_A_MIRROR.last_sync_time) < ELEMENTS_A_MIRROR.sync_interval then
        return
    end
    ELEMENTS_A_MIRROR.last_sync_time = now
    ELEMENTS_A_MIRROR.syncing = true

    for _, group in ipairs(ELEMENTS_A_MIRROR.color_groups or {}) do
        local src_key = (group.keys and group.keys[1]) or nil
        local src_ctrl = src_key and Utils.UI.get_control(CONSTANTS.PATHS[src_key]) or nil
        local src_val = Utils.UI.GetValue(src_ctrl)
        if src_val and group.control then
            mirror_set_color(group.control, {
                src_val:GetR(),
                src_val:GetG(),
                src_val:GetB(),
                src_val:GetA()
            })
        end
    end

    for _, key in ipairs(CONSTANTS.KEYS.MIRROR_BOOL) do
        local src_ctrl = Utils.UI.get_control(CONSTANTS.PATHS[key])
        mirror_set_checkbox(ELEMENTS_A_MIRROR.controls[key], Utils.UI.GetBool(src_ctrl, false))
    end

    for _, key in ipairs(CONSTANTS.KEYS.SLIDER) do
        local src_ctrl = Utils.UI.get_control(CONSTANTS.PATHS[key])
        mirror_set_number(ELEMENTS_A_MIRROR.controls[key], Utils.UI.get_number(src_ctrl, 0))
    end

    mirror_set_combo_index(ELEMENTS_A_MIRROR.controls.skybox, Utils.UI.get_combo("skybox"))

    ELEMENTS_A_MIRROR.syncing = false
end

create_elements_a_mirror_ui = function(host_group, use_custom_tab)
    if not ENABLE_ELEMENTS_A_MIRROR then
        ELEMENTS_A_MIRROR.initialized = true
        ELEMENTS_A_MIRROR.group = nil
        return true
    end
    if use_custom_tab ~= true then
        ELEMENTS_A_MIRROR.initialized = true
        ELEMENTS_A_MIRROR.group = nil
        return true
    end
    if ELEMENTS_A_MIRROR.initialized and ELEMENTS_A_MIRROR.group == host_group then
        return true
    end
    if not host_group then
        return false
    end
    if not gui or not gui.MakeControl or not gui.ControlID then return false end
    if not gui.ColorPicker or not gui.Checkbox or not gui.Slider or not gui.ComboBox or not gui.Selectable then return false end

    ELEMENTS_A_MIRROR.group = host_group
    ELEMENTS_A_MIRROR.controls = {}
    ELEMENTS_A_MIRROR.rows = {}
    ELEMENTS_A_MIRROR.color_groups = {}

    mirror_add_row(
        host_group,
        "env_enabled",
        "Enabled",
        gui.Checkbox(gui.ControlID("cm_world_mirror_env_enabled")),
        "Master toggle for world environment."
    )

    local world_lights_row = mirror_add_color_row(
        host_group,
        "world_color",
        "World",
        "world_color",
        "World color."
    )
    if world_lights_row then
        mirror_add_color_to_row(world_lights_row, "lights_color", "lights_color", "Lights color.")
    else
        mirror_add_color_row(host_group, "world_color", "World", "world_color", "World color.")
        mirror_add_color_row(host_group, "lights_color", "Lights", "lights_color", "Lights color.")
    end

    local sky_cloud_sun_row = mirror_add_row(
        host_group,
        "sky",
        "Sky color",
        gui.Checkbox(gui.ControlID("cm_world_mirror_sky")),
        "Master toggle for sky rendering."
    )
    if sky_cloud_sun_row then
        -- Added in reverse so the rendered row keeps the visual order: Sky, Cloud, Sun, [Sky toggle].
        mirror_add_color_to_row(sky_cloud_sun_row, "sun_color", "sun_color", "Sun color.")
        mirror_add_color_to_row(sky_cloud_sun_row, "cloud_color", "cloud_color", "Cloud color.")
        mirror_add_color_to_row(sky_cloud_sun_row, "sky_color", "sky_color", "Sky color.")
    else
        mirror_add_row(
            host_group,
            "sky",
            "Sky color",
            gui.Checkbox(gui.ControlID("cm_world_mirror_sky")),
            "Master toggle for sky rendering."
        )
        mirror_add_color_row(host_group, "sky_color", "Sky color", "sky_color", "Sky color.")
        mirror_add_color_row(host_group, "cloud_color", "Cloud", "cloud_color", "Cloud color.")
        mirror_add_color_row(host_group, "sun_color", "Sun", "sun_color", "Sun color.")
    end

    -- Our OWN sky-colour picker, sitting next to the mirrored one but deliberately NOT
    -- registered for cheat sync (not in color_groups) -- so the cheat/script sync can never
    -- touch it. When the custom-skybox checkbox is on we swap to this one (and hide the
    -- mirrored one); it drives the custom skybox tint. cm_get_runtime_refresh_color reads it
    -- via CM_SKY_COLOR_CTRL. Hidden by default (custom skybox starts off).
    if gui.ColorPicker and gui.ControlID then
        local our_sky_parent = sky_cloud_sun_row or host_group
        local our_sky = gui.ColorPicker(gui.ControlID("cm_custom_sky_color"))
        if our_sky then
            CM_SKY_COLOR_CTRL = our_sky
            protected_call(function()
                local vp = our_sky:GetValue()
                if vp and vp.Set and draw and draw.Color then
                    vp:Set(draw.Color(255, 255, 255, 255))
                end
            end)
            mirror_try_set_tooltip(our_sky, "Custom skybox tint -- independent, not synced with the cheat sky color.")
            mirror_add_child(our_sky_parent, our_sky)
            if our_sky.AddCallback then
                our_sky:AddCallback(function()
                    if CUSTOM_SKY_PANEL.enabled ~= true then
                        return
                    end
                    local api = custom_sky_api()
                    if api and type(api.refresh_tint) == "function" then
                        protected_call(api.refresh_tint)
                    end
                end)
            end
            set_row_visible(our_sky, false)
        end
    end

    mirror_add_row(
        host_group,
        "exposure",
        "Exposure",
        gui.Slider(gui.ControlID("cm_world_mirror_exposure"), 0, 100, {'%.0f%%'}),
        "Controls world exposure."
    )

    local dof_row = mirror_add_row(
        host_group,
        "dof",
        "Depth of field",
        gui.Checkbox(gui.ControlID("cm_world_mirror_dof")),
        "Master toggle for depth of field."
    )
    local dof_settings = mirror_add_settings(dof_row, "dof")
    local dof_host = dof_settings or host_group
    mirror_add_row(
        dof_host,
        "dof_strength",
        "Strength",
        gui.Slider(gui.ControlID("cm_world_mirror_dof_strength"), 0, 100, {'%.0f%%'}),
        "Depth of field intensity."
    )
    mirror_add_row(
        dof_host,
        "dof_far_start",
        "Far start",
        gui.Slider(gui.ControlID("cm_world_mirror_dof_far_start"), 0, 4000, {'%.0fu'}),
        "Distance where far blur starts."
    )
    mirror_add_row(
        dof_host,
        "dof_far_end",
        "Far end",
        gui.Slider(gui.ControlID("cm_world_mirror_dof_far_end"), 0, 4000, {'%.0fu'}),
        "Distance where far blur reaches full strength."
    )
    mirror_add_row(
        dof_host,
        "dof_near_start",
        "Near start",
        gui.Slider(gui.ControlID("cm_world_mirror_dof_near_start"), -500, 500, {'%.0fu'}),
        "Distance where near blur starts."
    )
    mirror_add_row(
        dof_host,
        "dof_near_end",
        "Near end",
        gui.Slider(gui.ControlID("cm_world_mirror_dof_near_end"), -500, 500, {'%.0fu'}),
        "Distance where near blur reaches full strength."
    )

    local fog_row = mirror_add_row(
        host_group,
        "fog",
        "Fog",
        gui.Checkbox(gui.ControlID("cm_world_mirror_fog")),
        "Master toggle for fog rendering."
    )
    local fog_settings = mirror_add_settings(fog_row, "fog")
    local fog_host = fog_settings or host_group
    mirror_add_color_row(fog_host, "fog_color", "Color", "fog_color", "Fog color.")
    mirror_add_row(
        fog_host,
        "fog_distance",
        "Distance",
        gui.Slider(gui.ControlID("cm_world_mirror_fog_distance"), 0, 7000, {'%.0fu'}),
        "Fog start distance."
    )
    mirror_add_row(
        fog_host,
        "fog_size",
        "Falloff",
        gui.Slider(gui.ControlID("cm_world_mirror_fog_size"), 0, 100, {'%.0f%%'}),
        "Fog density falloff."
    )

    -- ================== Bloom (custom, NOT a cheat mirror) ==================
    -- Colored post-process bloom via direct PostProcessingResource_t writes. This is our own feature, not a

    -- native setting being mirrored, so it deliberately stays OUT of MIRROR_BOOL/SLIDER/
    -- color_groups sync lists below. The actual read/write engine (schema resolve, render-gate
    -- patch, per-frame apply) lives in its own protected_call block near the end of this file;
    -- controls are shared through the global CM_BLOOM_CTRLS table so both sides can see them
    -- regardless of load order (Lua globals resolve at call time, not definition time).
    CM_BLOOM_CTRLS = CM_BLOOM_CTRLS or {}
    if gui.Checkbox and gui.Settings and gui.Slider and gui.ColorPicker then
        local bloom_checkbox = gui.Checkbox(gui.ControlID("cm_bloom_enable"))
        local bloom_row = mirror_add_row(
            host_group,
            "bloom_enable",
            "Bloom",
            bloom_checkbox,
            "Bloom is saved ONLY for the MAP (Save map setts)"
        )
        CM_BLOOM_CTRLS.enable = bloom_checkbox
        local bloom_settings = mirror_add_settings(bloom_row, "bloom")
        local bloom_host = bloom_settings or host_group

        -- 5 blur levels: color + weight, one row each (slider stacked next to the labeled picker).
        CM_BLOOM_CTRLS.levels = {}
        for i = 1, 5 do
            local slide = gui.Slider(gui.ControlID("cm_bloom_w_" .. i), 0, 2, {'%.2f'}, 0.01)
            local pick = gui.ColorPicker(gui.ControlID("cm_bloom_col_" .. i), false)
            if slide and pick then
                if slide.GetValue then slide:GetValue():Set(0.2) end
                if pick.GetValue and draw and draw.Color then pick:GetValue():Set(draw.Color(255, 255, 255)) end
                local row = gui.MakeControl and gui.MakeControl("Color " .. i, pick) or nil
                if row then
                    mirror_add_child(row, slide)
                    if row.Reset then row:Reset() end
                    mirror_add_child(bloom_host, row)
                else
                    mirror_add_child(bloom_host, pick)
                    mirror_add_child(bloom_host, slide)
                end
                CM_BLOOM_CTRLS.levels[i] = { w = slide, c = pick }
            end
        end

        -- Only these 5 actually do something: Blend Mode does nothing on this build
        -- (dropped), and Skybox Strength/Start Value/Compute* have no effect
        -- (compute-bloom is a separate, unpatched render path).
        CM_BLOOM_CTRLS.globals = {}
        local BLOOM_GLOBAL_UI = {
            {key="strength",  label="Strength",     lo=0,  hi=10, step=0.01, fmt="%.2f", def=1.0},
            {key="screenstr", label="Screen Str.",  lo=0,  hi=10, step=0.01, fmt="%.2f", def=1.0},
            {key="blurstr",   label="Blur Str.",    lo=0,  hi=1,  step=0.01, fmt="%.2f", def=0.3},
            {key="threshold", label="Threshold",    lo=0,  hi=1,  step=0.01, fmt="%.2f", def=0.3},
            {key="threshw",   label="Threshold W.", lo=0,  hi=5,  step=0.01, fmt="%.2f", def=0.5},
        }
        for _, p in ipairs(BLOOM_GLOBAL_UI) do
            local s = gui.Slider(gui.ControlID("cm_bloom_g_" .. p.key), p.lo, p.hi, {p.fmt}, p.step)
            if s then
                if s.GetValue then s:GetValue():Set(p.def) end
                mirror_add_row(bloom_host, "bloom_" .. p.key, p.label, s, nil)
                CM_BLOOM_CTRLS.globals[p.key] = s
            end
        end
    end

    -- ================== Tonemap + Local contrast (custom, NOT a cheat mirror) ==================
    -- Same shape as Bloom above: a checkbox row plus a gear "settings" child holding the sliders,
    -- map-scoped only. Driven by the same engine block at the end of this file, shared through the
    -- global CM_POSTFX_CTRLS. `name` is the live schema field the engine resolves the offset from --
    -- the labels are ours, the names are Valve's, and the engine never guesses either.
    CM_POSTFX_CTRLS = CM_POSTFX_CTRLS or {}
    if gui.Checkbox and gui.Settings and gui.Slider then
        -- Hable filmic curve. Defaults/bounds are anchored to VALVE'S OWN defaults, read out of the
        -- engine's default-params builder (FUN_180056c20): exposure 0, shoulder 0.15, linear 0.5,
        -- angle 0.1, toe 0.2, toe num 0.02, toe denom 0.3, white point 4.0.
        -- Exposure and White point are BASE-2 EXPONENTS (the engine does 2^x), hence the tight spans.
        -- Toe denom's floor is deliberately above 0: it is the divisor in E/F, and 0 there is a
        -- divide-by-zero baked straight into a shader constant. Do not lower it to 0.
        local TONE_UI = {
            {name="m_flExposureBias",     label="Exposure",      tip="Overall brightness. Doubles every +1.", lo=-4,   hi=4, step=0.05, def=0},
            {name="m_flWhitePoint",       label="White point",   tip="Brightness that turns pure white.",     lo=0,    hi=8, step=0.05, def=4},
            {name="m_flShoulderStrength", label="Highlights",    tip="How gently bright areas roll off.",     lo=0,    hi=1, step=0.01, def=0.15},
            {name="m_flLinearStrength",   label="Midtones",      tip="Strength of the straight part.",        lo=0,    hi=1, step=0.01, def=0.5},
            {name="m_flLinearAngle",      label="Midtone slope", tip="Steepness of the straight part.",       lo=0,    hi=1, step=0.01, def=0.1},
            {name="m_flToeStrength",      label="Shadows",       tip="How hard darks are crushed.",           lo=0,    hi=1, step=0.01, def=0.2},
            {name="m_flToeNum",           label="Black lift",    tip="Lifts the darkest tones.",              lo=0,    hi=1, step=0.005, def=0.02},
            {name="m_flToeDenom",         label="Shadow shape",  tip="Shadow falloff. Never 0.",              lo=0.01, hi=1, step=0.01, def=0.3},
        }
        local tone_cb = gui.Checkbox(gui.ControlID("cm_tone_enable"))
        local tone_row = mirror_add_row(host_group, "tone_enable", "Tonemap", tone_cb,
            "Film curve: exposure/contrast. Saved ONLY for the MAP (Save map setts)")
        CM_POSTFX_CTRLS.tone = { enable = tone_cb, fields = {} }
        local tone_host = mirror_add_settings(tone_row, "tone") or host_group
        for _, p in ipairs(TONE_UI) do
            local s = gui.Slider(gui.ControlID("cm_tone_" .. p.name), p.lo, p.hi, {'%.3f'}, p.step)
            if s then
                if s.GetValue then s:GetValue():Set(p.def) end
                mirror_add_row(tone_host, "tone_" .. p.name, p.label, s, p.tip)
                CM_POSTFX_CTRLS.tone.fields[#CM_POSTFX_CTRLS.tone.fields + 1] = { name = p.name, ctrl = s }
            end
        end

        -- Local contrast. No Valve default-builder exists for these, so the bounds are judgement --
        -- but every slider is seeded from the map's own value the moment the box is ticked, so they
        -- only cap how far you can drag. "Vignette" here is local contrast's own mask, not the
        -- vignette post-effect (that one is not reachable: its blender allocates instead of storing
        -- the parameters inline).
        local LC_UI = {
            {name="m_flLocalContrastStrength",      label="Strength",     tip="Local contrast amount.",     lo=0, hi=2, step=0.01, def=0},
            {name="m_flLocalContrastEdgeStrength",  label="Edges",        tip="Extra contrast on edges.",   lo=0, hi=2, step=0.01, def=0},
            {name="m_flLocalContrastVignetteStart", label="Mask start",   tip="Where the screen mask begins.", lo=0, hi=1, step=0.01, def=0},
            {name="m_flLocalContrastVignetteEnd",   label="Mask end",     tip="Where the screen mask ends.",   lo=0, hi=1, step=0.01, def=1},
            -- 0..3, not 0..1: past 1 it stops being a soft mask edge and visibly warps the image,
            -- which is wanted. Confirmed live -- local contrast is NOT one of the dead blocks.
            {name="m_flLocalContrastVignetteBlur",  label="Mask blur",    tip="Softness of the mask edge. Warps the image past 1.", lo=0, hi=3, step=0.01, def=0},
        }
        local lc_cb = gui.Checkbox(gui.ControlID("cm_lc_enable"))
        local lc_row = mirror_add_row(host_group, "lc_enable", "Contrast", lc_cb,
            "Sharpens midtone detail. Saved ONLY for the MAP (Save map setts)")
        CM_POSTFX_CTRLS.lc = { enable = lc_cb, fields = {} }
        local lc_host = mirror_add_settings(lc_row, "lc") or host_group
        for _, p in ipairs(LC_UI) do
            local s = gui.Slider(gui.ControlID("cm_lc_" .. p.name), p.lo, p.hi, {'%.2f'}, p.step)
            if s then
                if s.GetValue then s:GetValue():Set(p.def) end
                mirror_add_row(lc_host, "lc_" .. p.name, p.label, s, p.tip)
                CM_POSTFX_CTRLS.lc.fields[#CM_POSTFX_CTRLS.lc.fields + 1] = { name = p.name, ctrl = s }
            end
        end
    end

    -- Skybox combobox (named options to match native environment menu)
    local skybox_ctrl = gui.ComboBox(gui.ControlID("cm_world_mirror_skybox"))
    if skybox_ctrl and skybox_ctrl.Add then
        for i = 1, #SKYBOX_OPTIONS do
            add_child_compat(skybox_ctrl, gui.Selectable(gui.ControlID("cm_world_mirror_skybox_" .. i), SKYBOX_OPTIONS[i]))
        end
    end
    if skybox_ctrl then
        mirror_add_row(host_group, "skybox", "Skybox", skybox_ctrl, "Select map skybox preset.")
    end
    custom_sky_update_mirror_skybox_visibility()

    -- Callbacks: mirror -> original cheat controls
    for _, group in ipairs(ELEMENTS_A_MIRROR.color_groups or {}) do
        local ctrl = group.control
        if ctrl and ctrl.AddCallback then
            ctrl:AddCallback(function()
                if ELEMENTS_A_MIRROR.syncing then return end
                local r, g, b, a = get_color_rgba(ctrl, 255, 255, 255, 255)
                for _, key in ipairs(group.keys or {}) do
                    Utils.UI.set_color(key, {r, g, b, a})
                end
            end)
        end
    end

    for _, key in ipairs(CONSTANTS.KEYS.MIRROR_BOOL) do
        local ctrl = ELEMENTS_A_MIRROR.controls[key]
        if ctrl and ctrl.AddCallback then
            ctrl:AddCallback(function()
                if ELEMENTS_A_MIRROR.syncing then return end
                Utils.UI.set_bool(key, Utils.UI.GetBool(ctrl, false))
            end)
        end
    end

    for _, key in ipairs(CONSTANTS.KEYS.SLIDER) do
        local ctrl = ELEMENTS_A_MIRROR.controls[key]
        if ctrl and ctrl.AddCallback then
            ctrl:AddCallback(function()
                if ELEMENTS_A_MIRROR.syncing then return end
                Utils.UI.set_number(key, get_slider_value(ctrl, 0))
            end)
        end
    end

    do
        local ctrl = ELEMENTS_A_MIRROR.controls.skybox
        if ctrl and ctrl.AddCallback then
            ctrl:AddCallback(function()
                if ELEMENTS_A_MIRROR.syncing then return end
                if CUSTOM_SKY_PANEL.enabled == true then
                    mirror_set_combo_index(ctrl, 1)
                    return
                end
                local idx = get_combo_index(ctrl)
                if idx < 1 then idx = 1 end
                Utils.UI.set_combo("skybox", idx)
            end)
        end
    end

    if host_group and host_group.Reset then
        host_group:Reset()
    end
    ELEMENTS_A_MIRROR.initialized = true
    sync_elements_a_mirror_from_cheat(true)
    return true
end

local function is_expand_settings_enabled()
    if UI.main.manager_visible == nil then
        UI.main.manager_visible = true
    end
    return UI.main.manager_visible == true
end

local function is_expand_cfg_system_enabled()
    if not UI.main.profile_expand_checkbox then return false end
    local val = UI.main.profile_expand_checkbox:GetValue()
    if val and val.Get then return val:Get() == true end
    return false
end

local function set_ui_visible_cached(key, control, visible)
    if not control or not control.SetVisible then return end
    local state = (visible == true)
    if UI.visibility_cache[key] == state then return false end
    UI.visibility_cache[key] = state
    control:SetVisible(state)
    return true
end

local function update_all_visibility()
    local expanded = is_expand_settings_enabled()
    local visibility_changed = false
    local function apply_visible(key, control, visible)
        if set_ui_visible_cached(key, control, visible) then
            visibility_changed = true
        end
    end
    
    local shader_api = get_shader_api()
    local shaders_enabled = is_shaders_enabled()
    if shader_api and shader_api.set_enabled then
        shader_api.set_enabled(shaders_enabled)
    end
    if shader_api and shader_api.set_ui_visibility then
        shader_api.set_ui_visibility(expanded and shaders_enabled)
    elseif shader_api and shader_api.refresh_ui_visibility then
        shader_api.refresh_ui_visibility()
    end

    apply_visible("row.section_list", UI.rows.section_list, false)

    local profile_controls_visible = expanded

    apply_visible("row.warning_label", UI.rows.warning_label, expanded)
    apply_visible("row.profile_expand", UI.rows.profile_expand, false)
    apply_visible("row.profile_combo", UI.rows.profile_combo, profile_controls_visible)
    apply_visible("row.profile_name", UI.rows.profile_name, profile_controls_visible)
    apply_visible("btn.profile_create", UI.main.profile_create_button, profile_controls_visible)
    apply_visible("btn.profile_refresh", UI.main.profile_refresh_button, profile_controls_visible)
    apply_visible("btn.profile_open_folder", UI.main.profile_open_folder_button, profile_controls_visible)
    apply_visible("row.cfg_hint", UI.rows.cfg_hint, profile_controls_visible)
    apply_visible("row.enable_shaders", UI.rows.enable_shaders, expanded)
    apply_visible("row.enable_points", UI.rows.enable_points, expanded)
    
    -- Points-dependent controls
    local points_enabled = is_points_enabled()
    local settings_enabled = is_settings_edit_enabled()
    
    apply_visible("row.cutoff", UI.rows.cutoff, expanded and points_enabled)
    apply_visible("row.max_points", UI.rows.max_points, expanded and points_enabled)
    apply_visible("row.enable_settings", UI.rows.enable_settings, expanded and points_enabled)
    apply_visible("row.render_points", UI.rows.render_points, expanded and points_enabled)
    
    -- Remember/restore the Render Lines state
    local render_points_on = is_render_points_enabled()
    

    
    apply_visible("row.debug", UI.rows.dbg, expanded and points_enabled)
    apply_visible("row.auto_update_config", UI.rows.auto_update_config, expanded and points_enabled and is_debug_enabled())
    apply_visible("row.render_lines", UI.rows.render_lines, expanded and points_enabled and render_points_on)
    apply_visible("row.render_influence", UI.rows.render_influence, expanded and points_enabled and render_points_on)
    
    local buttons_visible = expanded and points_enabled and settings_enabled

    apply_visible("btn.delete_point", UI.main.delete_point_button, buttons_visible)
    
    -- Buttons visibility
    apply_visible("btn.save_point", UI.main.save_point_button, buttons_visible)
    apply_visible("btn.new_point", UI.main.new_point_button, buttons_visible)

    local debug_buttons_visible = expanded and is_debug_enabled() and points_enabled and settings_enabled
    apply_visible("btn.add_preset", UI.main.add_preset_button, debug_buttons_visible)
    
    -- Weight controls
    apply_visible("row.enable_weight", UI.rows.enable_weight, expanded and points_enabled)
    
    -- Weight slider and Refresh button
    local weight_on = is_weight_enabled()
    apply_visible("row.weight_slider", UI.rows.weight_slider, expanded and points_enabled and settings_enabled and weight_on)
    apply_visible("btn.refresh", UI.main.refresh_button, expanded and points_enabled and settings_enabled and weight_on)
    
    -- Render Weight 
    apply_visible("row.render_weight", UI.rows.render_weight, expanded and points_enabled and weight_on and render_points_on)

    -- Fatality UI can drift after many set_visible toggles; force relayout only when needed.
    if visibility_changed and UI.main.group and UI.main.group.Reset then
        protected_call(UI.main.group.Reset, UI.main.group)
    end
    if visibility_changed and UI.main.group_a and UI.main.group_a.Reset then
        protected_call(UI.main.group_a.Reset, UI.main.group_a)
    end
    if CUSTOM_SKY_PANEL and CUSTOM_SKY_PANEL.scan_completed ~= true and CUSTOM_SKY_PANEL.scan_requested ~= true then
        custom_sky_schedule_scan(CUSTOM_SKY_PANEL.scan_delay)
    end
end

local function update_points_visibility()
    update_all_visibility()
end

function create_legacy_section_selector(host_group)
    if not host_group or MAPS_CUSTOM_UI.section_list then
        return MAPS_CUSTOM_UI.section_list ~= nil
    end
    if not (gui and gui.List and gui.Selectable and draw and draw.Vec2) then
        return false
    end

    local ok_size, list_size = protected_call(draw.Vec2, 120.0, 72.0)
    if not ok_size or not list_size then
        return false
    end

    local ok_list, list = protected_call(gui.List, "cm_maps_section_list_legacy", list_size)
    if not ok_list or not list then
        return false
    end

    protected_call(function(ctrl)
        ctrl.allowMultiple = false
    end, list)

    local labels = { "Main", "Settings" }
    local i
    for i = 1, #labels do
        local selectable = nil
        if gui.ControlID then
            local ok_id, cid = protected_call(gui.ControlID, "cm_maps_section_legacy_" .. tostring(i))
            if ok_id and cid then
                local ok_sel, sel = protected_call(gui.Selectable, cid, labels[i])
                if ok_sel and sel then
                    selectable = sel
                end
            end
        end
        if not selectable then
            local ok_sel, sel = protected_call(gui.Selectable, "cm_maps_section_legacy_" .. tostring(i), labels[i])
            if ok_sel and sel then
                selectable = sel
            end
        end
        if selectable then
            add_child_compat(list, selectable)
        end
    end

    local addcb = list.AddCallback
    if addcb then
        protected_call(addcb, list, function()
            local idx = get_selector_index(list)
            local next_section = (idx == 2) and "settings" or "main"
            if MAPS_CUSTOM_UI.section ~= next_section then
                MAPS_CUSTOM_UI.section = next_section
                update_points_visibility()
            end
        end)
    end

    MAPS_CUSTOM_UI.section_list = list
    UI.main.section_list = list
    UI.rows.section_list = list
    add_child_compat(host_group, list)
    protected_call(function()
        local value_param = list:GetValue()
        local bits = value_param and value_param.Get and value_param:Get() or nil
        if bits and bits.SetRaw then
            bits:SetRaw((MAPS_CUSTOM_UI.section == "settings") and 2 or 1)
            if value_param.Set then
                value_param:Set(bits)
            end
        end
    end)
    return true
end

local function create_ui()
    if CM_FORCE_VERBOSE_TXT_LOG then
        __cm_verbose_log("create_ui: start", true)
    end
    bootstrap_shader_runtime()
    apply_shader_replace_for_map(Utils.System.get_current_map())

    local group_a, group, env_group, shader_group, using_custom_tab = MAPS_CUSTOM_UI.resolve_ui_containers()
    if CM_FORCE_VERBOSE_TXT_LOG then
        __cm_verbose_log(
            "create_ui: group_a=" .. tostring(group_a ~= nil) ..
            " group_b=" .. tostring(group ~= nil) ..
            " env_group=" .. tostring(env_group ~= nil) ..
            " shader_group=" .. tostring(shader_group ~= nil) ..
            " custom_tab=" .. tostring(using_custom_tab == true),
            true
        )
    end
    if not group_a or not group or not env_group then return false end
    UI.main.group_a = group_a
    UI.main.group = group
    UI.main.env_group = env_group

    MAPS_CUSTOM_UI.section_list = nil
    MAPS_CUSTOM_UI.section = "main"
    UI.main.section_list = nil
    UI.rows.section_list = nil

    local mirror_ok = create_elements_a_mirror_ui(env_group, using_custom_tab == true)
    if not mirror_ok and CM_FORCE_VERBOSE_TXT_LOG then
        __cm_verbose_log("create_ui: world visuals mirror failed to initialize", true)
    end
    sync_elements_a_mirror_from_cheat(true)

    -- UI build order:
    -- 1) Visuals controls (world/environment mirror + shaders)
    -- 2) Configs controls (profile management + config actions)
    -- 3) Points controls (including debug controls under Render Points)
    -- Visibility is applied at the end by update_points_visibility().
    UI.main.warning_label = nil
    UI.rows.warning_label = nil

    UI.main.profile_expand_checkbox = nil
    UI.rows.profile_expand = nil

    UI.main.profile_combo = nil
    if gui and gui.List then
        local list_size = nil
        if draw and draw.Vec2 then
            local ok_size, size = protected_call(draw.Vec2, 250.0, 75.0)
            if ok_size and size then
                list_size = size
            end
        end
        if not list_size and draw and draw.Vec2 then
            local ok_size, size = protected_call(draw.Vec2, 250.0, 75.0)
            if ok_size and size then
                list_size = size
            end
        end

        local list = nil
        if list_size then
            local ok_list, list_res = protected_call(gui.List, "cm_profile_list", list_size)
            if ok_list and list_res then
                list = list_res
            end
        end

        if list then
            UI.main.profile_combo = list

            protected_call(function(ctrl)
                ctrl.sizeToParentW = true
            end, UI.main.profile_combo)

            protected_call(function(ctrl)
                ctrl.allowMultiple = false
            end, UI.main.profile_combo)
        end
    end

    if not UI.main.profile_combo then
        return false
    end

    if UI.main.profile_combo.AddCallback then
        UI.main.profile_combo:AddCallback(function()
        if State.profiles and State.profiles.ui_syncing then
            return
        end
        if State.profiles and type(State.profiles.selector_suspend_until) == "number" then
            if runtime_now() < State.profiles.selector_suspend_until then
                return
            end
        end
        local idx = get_selector_index(UI.main.profile_combo)
        if State.profiles and type(State.profiles.selector_index_bias) == "number" then
            idx = idx + State.profiles.selector_index_bias
        end
        local list = State.profiles and State.profiles.list
        if type(list) == "table" and #list > 0 and idx > #list then
            idx = #list
        end
        if idx < 1 then return end
        if list and list[idx] then
            Utils.Config.switch_profile(list[idx], "selector")
        end
        end)
    end

    UI.rows.profile_combo = UI.main.profile_combo
    add_child_compat(group_a, UI.main.profile_combo)

    UI.main.profile_name_input = nil
    UI.rows.profile_name = nil
    UI.main.profile_open_folder_button = nil
    UI.main.profile_export_button = nil
    UI.main.profile_import_button = nil
    UI.main.profile_import_conflict_row = nil
    UI.main.profile_import_conflict_label = nil
    UI.main.profile_import_overwrite_button = nil
    UI.main.profile_import_rename_button = nil

    local function notify_config_message(text)
        notify_user("Config", tostring(text or ""))
    end

    local function create_profile_name_input_control()
        local input_control = nil
        local row_control = nil

        local function looks_like_value_control(ctrl)
            return ctrl ~= nil and type(ctrl.GetValue) == "function"
        end

        if gui and gui.MakeControlEasy then
            local ok_make, first_ctrl, second_ctrl = protected_call(
                gui.MakeControlEasy,
                "cm_profile_name_input",
                "Name",
                "text_input"
            )

            if ok_make then
                if looks_like_value_control(first_ctrl) then
                    input_control = first_ctrl
                    row_control = second_ctrl
                elseif looks_like_value_control(second_ctrl) then
                    input_control = second_ctrl
                    row_control = first_ctrl
                end
            end
        end

        if not input_control and gui and gui.TextInput and gui.ControlID then
            local ok_input, input = protected_call(gui.TextInput, gui.ControlID("cm_profile_name_input"))
            if ok_input and input then
                input_control = input
            end
        end

        if input_control and not row_control and gui and gui.MakeControl then
            local ok_row, row = protected_call(gui.MakeControl, "Name", input_control)
            if ok_row and row then
                row_control = row
            end
        end

        if input_control and not row_control then
            row_control = input_control
        end

        return input_control, row_control
    end

    UI.main.profile_name_input, UI.rows.profile_name = create_profile_name_input_control()
    if UI.rows.profile_name then
        add_child_compat(group_a, UI.rows.profile_name)
    end
    if UI.main.profile_name_input then
        UI.main.profile_name_input.tooltip = "Profile name for Create/Import. Empty -> auto defaultN."
        if UI.main.profile_name_input.AddCallback then
            UI.main.profile_name_input:AddCallback(function()
                local raw = Utils.Config.read_profile_name_input(UI.main.profile_name_input)
                if type(State.profiles) ~= "table" then
                    State.profiles = {}
                end
                State.profiles.draft_name = raw
            end)
        end

        local initial_name = Utils.Config.sanitize_profile_name(State.profiles and State.profiles.draft_name) or Utils.Config.next_auto_profile_name()
        Utils.Config.write_profile_name_input(UI.main.profile_name_input, initial_name)
    end

    local function refresh_profiles_from_ui()
        local count = Utils.Config.refresh_profiles_ui()
        notify_config_message("Profiles refreshed (" .. tostring(count) .. ")")
        return count
    end

    local function resolve_profile_name_from_input()
        local raw = Utils.Config.read_profile_name_input(UI.main.profile_name_input)
        if raw == "" then
            return Utils.Config.next_auto_profile_name(), nil
        end

        local sanitized = Utils.Config.sanitize_profile_name(raw)
        if not sanitized then
            return nil, "Invalid profile name"
        end

        return sanitized, nil
    end

    local function create_profile_from_ui()
        local target_name, name_err = resolve_profile_name_from_input()
        if not target_name then
            return false, name_err
        end

        local ok, result = Utils.Config.create_profile_from_current(target_name)
        if ok and UI.main.profile_name_input then
            Utils.Config.write_profile_name_input(UI.main.profile_name_input, Utils.Config.next_auto_profile_name())
        end
        return ok, result
    end

    UI.main.profile_create_button = apply_uniform_button_style(gui.Button(gui.ControlID("cm_profile_create_button"), "Create config"))
    UI.main.profile_create_button:AddCallback(function()
        local ok, result = create_profile_from_ui()
        if ok then
            notify_config_message("Created profile: " .. tostring(result))
        else
            notify_config_message(tostring(result or "Failed to create profile"))
        end
    end)
    UI.main.profile_create_button.tooltip = "Create profile from textbox name. Empty name uses auto defaultN."
    add_child_compat(group_a, UI.main.profile_create_button)
    UI.buttons.profile_create = UI.main.profile_create_button

    UI.main.profile_refresh_button = apply_uniform_button_style(gui.Button(gui.ControlID("cm_profile_refresh_button"), "Refresh list"))
    UI.main.profile_refresh_button:AddCallback(function()
        refresh_profiles_from_ui()
    end)
    UI.main.profile_refresh_button.tooltip = "Reload config profiles from folder"
    add_child_compat(group_a, UI.main.profile_refresh_button)
    UI.buttons.profile_refresh = UI.main.profile_refresh_button

    UI.main.profile_open_folder_button = apply_uniform_button_style(gui.Button(gui.ControlID("cm_profile_open_folder_button"), "Open folder"))
    UI.main.profile_open_folder_button:AddCallback(function()
        if Utils.Config.open_profiles_folder() then
            notify_config_message("Opened configs folder")
        else
            notify_config_message("Failed to open folder")
        end
    end)
    UI.main.profile_open_folder_button.tooltip = "Open the configs folder in Explorer"
    add_child_compat(group_a, UI.main.profile_open_folder_button)
    UI.buttons.profile_open_folder = UI.main.profile_open_folder_button

    Utils.Config.refresh_profiles_ui()
    
    UI.main.cfg_hint_label = nil
    UI.rows.cfg_hint = nil
    UI.main.cfg_debug_spacer_label_1 = nil
    UI.main.cfg_debug_spacer_label_2 = nil
    UI.main.cfg_debug_spacer_label_3 = nil
    
    -- Enable Points
    UI.checkboxes.enable_points = gui.Checkbox(gui.ControlID("enable_points"))
    UI.checkboxes.enable_points:AddCallback(function()
        if is_points_enabled() then
            seed_smooth_state(capture_current_settings(is_shader_points_enabled()))
            if State and State.transition then
                State.transition.speed = 1.0
                State.transition.restore_speed_at = runtime_now() + 1.1
            end
        else
            if State and State.transition then
                State.transition.speed = CONSTANTS.DEFAULTS.TRANSITION_SPEED
                State.transition.restore_speed_at = 0
            end
            reset_smooth_state()
        end
        update_points_visibility()
    end)
    UI.checkboxes.enable_points.tooltip = "Enable point-based color blending"
    UI.rows.enable_points = gui.MakeControl("Enable Points", UI.checkboxes.enable_points)
    add_child_compat(group, UI.rows.enable_points)

    -- Enable Weight checkbox
    UI.checkboxes.enable_weight = gui.Checkbox(gui.ControlID("enable_weight"))
    UI.checkboxes.enable_weight:AddCallback(function()
        update_points_visibility()
    end)
    UI.checkboxes.enable_weight.tooltip = "Enable point weight system for blending"
    UI.rows.enable_weight = gui.MakeControl("Enable weight", UI.checkboxes.enable_weight)
    add_child_compat(group, UI.rows.enable_weight)

    -- Save button in Visuals panel.
    UI.main.save_button = apply_uniform_button_style(gui.Button(gui.ControlID("save_map_settings_btn"), "Save map setts"))
    UI.main.save_button:AddCallback(function()
        local map_name = Utils.System.get_current_map()
        if map_name then
            local settings = capture_current_settings()
            if save_preset_for_map(map_name, settings) then
                notify_user("Map Settings", "Settings saved for: " .. map_name)

                -- Also save cutoff/max points if they exist in UI but no callback triggered
                local map_data = State.points_config.maps[map_name]
                if map_data then
                    if UI.sliders.cutoff then map_data.cutoff_radius = UI.sliders.cutoff:GetValue():Get() end
                    if UI.sliders.max_points then map_data.max_points = UI.sliders.max_points:GetValue():Get() end
                    save_points_config()
                end
            end
        else
            notify_user("Error", "Not in game or map unknown")
        end
    end)
    local save_button_host = shader_group or env_group or group_a
    if save_button_host then
        add_child_compat(save_button_host, UI.main.save_button)
    end

    local custom_sky_host = MAPS_CUSTOM_UI.custom_sky_panel or env_group
    custom_sky_build_ui(custom_sky_host)

    UI.checkboxes.enable_shaders = gui.Checkbox(gui.ControlID("enable_shaders"))
    do
        ensure_shaders_config()
        local shaders_value = UI.checkboxes.enable_shaders:GetValue()
        if shaders_value and shaders_value.Set then
            shaders_value:Set(State.shaders_config.enabled == true)
        end
    end
    UI.checkboxes.enable_shaders:AddCallback(function()
        ensure_shaders_config()
        State.shaders_config.enabled = is_shaders_enabled()
        save_all_configs()
        update_points_visibility()
    end)
    UI.checkboxes.enable_shaders.tooltip = "Master toggle for shader rendering and shader UI"
    UI.rows.enable_shaders = gui.MakeControl("Enable shaders", UI.checkboxes.enable_shaders)
    local enable_shaders_host = shader_group or env_group or group
    local added_enable_shaders = add_child_compat(enable_shaders_host, UI.rows.enable_shaders)
    if not added_enable_shaders and env_group then
        add_child_compat(env_group, UI.rows.enable_shaders)
        added_enable_shaders = true
    end
    if not added_enable_shaders and group then
        add_child_compat(group, UI.rows.enable_shaders)
        added_enable_shaders = true
    end

    if enable_shaders_host and enable_shaders_host.Reset then
        enable_shaders_host:Reset()
    end
    if group and group ~= enable_shaders_host then
        group:Reset()
    end

    if not MAPS_CUSTOM_UI.ensure_shader_ui_container(enable_shaders_host) and CM_FORCE_VERBOSE_TXT_LOG then
        __cm_verbose_log("create_ui: shaders panel is unavailable, shader UI was not attached", true)
    end
    if enable_shaders_host and enable_shaders_host.Reset then
        enable_shaders_host:Reset()
    end

    -- Cutoff Radius slider (0-100 -> 0-10000 units)
    UI.sliders.cutoff = gui.Slider(gui.ControlID("cutoff_radius"), 0, 100, {'%.0f%%'})
    UI.sliders.cutoff:GetValue():Set(50)
    UI.sliders.cutoff:AddCallback(function()
        local map_name = Utils.System.get_current_map()
        if map_name and State.points_config and State.points_config.maps and State.points_config.maps[map_name] then
             local val = UI.sliders.cutoff:GetValue():Get()
             State.points_config.maps[map_name].cutoff_radius = val
             save_points_config()
        end
    end)
    UI.sliders.cutoff.tooltip = "Max distance to consider a point (0 = unlimited)"
    UI.rows.cutoff = gui.MakeControl("Cutoff Radius", UI.sliders.cutoff)
    add_child_compat(group, UI.rows.cutoff)
    
    -- Max Points slider (1-10)
    UI.sliders.max_points = gui.Slider(gui.ControlID("max_points"), 1, 10, {'%.0f'})
    UI.sliders.max_points:GetValue():Set(4)
    UI.sliders.max_points:AddCallback(function()
        local map_name = Utils.System.get_current_map()
        if map_name and State.points_config and State.points_config.maps and State.points_config.maps[map_name] then
             local val = UI.sliders.max_points:GetValue():Get()
             State.points_config.maps[map_name].max_points = val
             save_points_config()
        end
    end)
    UI.sliders.max_points.tooltip = "Max points to blend colors from"
    UI.rows.max_points = gui.MakeControl("Max Points", UI.sliders.max_points)
    add_child_compat(group, UI.rows.max_points)
    group:Reset()
    
    -- Enable settings for points (edit mode)
    UI.checkboxes.enable_settings = gui.Checkbox(gui.ControlID("enable_settings_points"))
    UI.checkboxes.enable_settings:AddCallback(function()
        update_points_visibility()
    end)
    UI.checkboxes.enable_settings.tooltip = "Enable edit mode - shows buttons to manage points"
    UI.rows.enable_settings = gui.MakeControl("Enable settings for points", UI.checkboxes.enable_settings)
    add_child_compat(group, UI.rows.enable_settings)

    group:Reset()

    -- Weight slider (hidden until Enable weight ON)
    UI.sliders.weight = gui.Slider(gui.ControlID("point_weight"), 1, 10, {'%.0f'})
    UI.sliders.weight:GetValue():Set(CONSTANTS.DEFAULTS.WEIGHT)
    UI.sliders.weight.tooltip = "Weight affects point influence on color blending (1 = weak, 10 = strong)"
    UI.rows.weight_slider = gui.MakeControl("Weight", UI.sliders.weight)
    add_child_compat(group, UI.rows.weight_slider)
    group:Reset()
    
    -- New Point (creates new point)
    UI.main.new_point_button = apply_uniform_button_style(gui.Button(gui.ControlID("new_point_btn"), "New Point"))
    UI.main.new_point_button:AddCallback(function()
        save_current_point()
    end)
    UI.main.new_point_button.tooltip = "Create a new point at your current position"
    add_child_compat(group, UI.main.new_point_button)

    -- Save Point (rewrites closest point)
    UI.main.save_point_button = apply_uniform_button_style(gui.Button(gui.ControlID("save_point_btn"), "Rewrite Closest"))
    UI.main.save_point_button:AddCallback(function()
        rewrite_closest_point()
    end)
    UI.main.save_point_button.tooltip = "Rewrites the closest point"
    add_child_compat(group, UI.main.save_point_button)

    -- Delete Closest
    UI.main.delete_point_button = apply_uniform_button_style(gui.Button(gui.ControlID("delete_point_btn"), "Delete Closest"))
    UI.main.delete_point_button:AddCallback(function() delete_closest_point() end)
    UI.main.delete_point_button.tooltip = "Delete the nearest point to player"
    add_child_compat(group, UI.main.delete_point_button)
    
    -- Render Points checkbox
    UI.checkboxes.render_points = gui.Checkbox(gui.ControlID("render_points"))
    UI.checkboxes.render_points:AddCallback(function()
        -- Remember/restore the Render Lines state
        local render_points_on = is_render_points_enabled()
        
        if not render_points_on and UI.checkboxes.render_lines then
            -- Remember the current state before turning it off
            local val = UI.checkboxes.render_lines:GetValue()
            if val and val.Get and val:Get() == true then
                State.render_lines_was_enabled = true
            end
            -- Turn off
            if val and val.Set then val:Set(false) end
        elseif render_points_on and State.render_lines_was_enabled and UI.checkboxes.render_lines then
            -- Restore
            local val = UI.checkboxes.render_lines:GetValue()
            if val and val.Set then val:Set(true) end
            State.render_lines_was_enabled = false
        end
        
        update_points_visibility()
    end)
    UI.checkboxes.render_points.tooltip = "Draw saved points on screen"
    UI.rows.render_points = gui.MakeControl("Render Points", UI.checkboxes.render_points)
    add_child_compat(group, UI.rows.render_points)

    -- Render Weight checkbox (nested under Render Points)
    UI.checkboxes.render_weight = gui.Checkbox(gui.ControlID("render_weight"))
    UI.checkboxes.render_weight.tooltip = "Draw weight indicator (red cross)"
    UI.rows.render_weight = gui.MakeControl("Render Weight indicators", UI.checkboxes.render_weight)
    add_child_compat(group, UI.rows.render_weight)

    UI.checkboxes.render_influence = gui.Checkbox(gui.ControlID("render_point_influence"))
    UI.checkboxes.render_influence.tooltip = "Draw local blend influence (%) above active points"
    UI.rows.render_influence = gui.MakeControl("Render influence %", UI.checkboxes.render_influence)
    add_child_compat(group, UI.rows.render_influence)
    
    -- Render Lines checkbox
    UI.checkboxes.render_lines = gui.Checkbox(gui.ControlID("render_lines"))
    UI.checkboxes.render_lines.tooltip = "Draw lines from player to active points"
    UI.rows.render_lines = gui.MakeControl("Render Lines (3rd person only)", UI.checkboxes.render_lines)
    add_child_compat(group, UI.rows.render_lines)

    -- Debug controls
    UI.checkboxes.dbg = gui.Checkbox(gui.ControlID("env_debug"))
    UI.checkboxes.dbg:AddCallback(function()
        local debug_on = is_debug_enabled()
        if not debug_on then
            if UI.checkboxes.auto_update_config then
                local val = UI.checkboxes.auto_update_config:GetValue()
                if val and val.Set then val:Set(false) end
            end
        end
        update_points_visibility()
    end)
    UI.checkboxes.dbg.tooltip = "Show debug info in console (3s interval)"
    UI.rows.dbg = gui.MakeControl("Debug", UI.checkboxes.dbg)
    add_child_compat(group, UI.rows.dbg)

    UI.checkboxes.auto_update_config = gui.Checkbox(gui.ControlID("auto_sync_map"))
    UI.checkboxes.auto_update_config.tooltip = "Reload and apply map settings from config every 4 seconds"
    UI.rows.auto_update_config = gui.MakeControl("Auto-sync map", UI.checkboxes.auto_update_config)
    add_child_compat(group, UI.rows.auto_update_config)

    UI.main.add_preset_button = apply_uniform_button_style(gui.Button(gui.ControlID("add_preset_btn"), "Load preset"))
    UI.main.add_preset_button:AddCallback(function() add_preset_points() end)
    UI.main.add_preset_button.tooltip = "Loads default points (presets) for the map"
    add_child_compat(group, UI.main.add_preset_button)
    group:Reset()

    if group_a and group_a.Reset then
        group_a:Reset()
    end
    if custom_sky_host and custom_sky_host ~= env_group then
        if custom_sky_host.Reset then
            custom_sky_host:Reset()
        end
    end
    
    -- Hide the buttons by default
    update_points_visibility()
    if CM_FORCE_VERBOSE_TXT_LOG then
        __cm_verbose_log("create_ui: done", true)
    end
    return true
end

-- ========== FRAME HANDLER ==========
local CONFIG_RELOAD_INTERVAL = 4.0  -- Map auto-sync interval

local function on_frame()
    if not script_initialized then
        return
    end

    local current_time = runtime_now()
    custom_sky_run_pending_scan(current_time)
    custom_sky_download_tick()
    custom_sky_process_pending_color_update(current_time)
    custom_sky_process_pending_enable_apply(current_time)
    local notify_at = tonumber(CUSTOM_SKY_PANEL.notify_saved_at) or 0
    if notify_at > 0 and current_time >= notify_at then
        CUSTOM_SKY_PANEL.notify_saved_at = 0
        notify_user("Custom skybox", "Saved: " .. tostring(CUSTOM_SKY_PANEL.selected or "default"))
    end
    local stable_map = check_map_change()

    local in_game = Utils.System.is_in_game()
    local raw_map_name = nil
    if in_game then
        raw_map_name = Utils.System.get_current_map()
    end

    -- Map considered ready only after check_map_change() reports stable map.
    local map_name = stable_map
    local map_ready = in_game and map_name and map_name ~= ""
    local cooldown_active = in_transition_cooldown(current_time)
    local points_enabled = is_points_enabled()

    if State and type(State.cache) == "table" then
        State.cache.frame_in_game = (in_game == true)
        State.cache.frame_map_name = (map_ready and map_name) or nil
        State.cache.frame_points_enabled = (points_enabled == true)
    end

    -- Mirror sync can touch native UI controls; skip it during unstable map transitions.
    local allow_mirror_sync = false
    if gui then
        if type(gui.IsVisible) == "function" then
            allow_mirror_sync = gui.IsVisible() == true
        elseif type(gui.GetMainWindow) == "function" then
            local wnd = gui.GetMainWindow()
            if wnd and type(wnd.isVisible) == "boolean" then
                allow_mirror_sync = wnd.isVisible == true
            end
        end
    end
    if allow_mirror_sync and in_game and (not map_ready or cooldown_active) then
        allow_mirror_sync = false
    end
    if allow_mirror_sync then
        sync_elements_a_mirror_from_cheat(false)
    end

    if map_ready and not cooldown_active and runtime_loaded_map and map_name == runtime_loaded_map then
        update_shader_runtime_gate()
    else
        set_shader_runtime_gate_state(false)
    end

    -- Hard leave: no active map name from engine (menu/disconnect).
    if (not in_game) or (not raw_map_name) or raw_map_name == "" then
        runtime_loaded_map = nil
        set_transition_cooldown(MAP_COOLDOWN_ON_LEAVE)
        clear_runtime_render_cache()
        if CUSTOM_SKY_RUNTIME and CUSTOM_SKY_RUNTIME.reset then
            CUSTOM_SKY_RUNTIME.reset()
        end
        return
    end

    -- Map transition in progress: wait until stable_map is confirmed.
    if not map_ready then
        runtime_loaded_map = nil
        clear_runtime_render_cache()
        if CUSTOM_SKY_RUNTIME and CUSTOM_SKY_RUNTIME.reset then
            CUSTOM_SKY_RUNTIME.reset()
        end
        return
    end

    if not runtime_loaded_map then
        if not in_transition_cooldown(current_time) then
            __cm_verbose_log("stage:on_frame:before_on_map_loaded map=" .. tostring(map_name), true)
            on_map_loaded(map_name)
            __cm_verbose_log("stage:on_frame:after_on_map_loaded map=" .. tostring(map_name), true)
            runtime_loaded_map = map_name
            __cm_verbose_log("stage:on_frame:runtime_loaded_set map=" .. tostring(map_name), true)
        end
    end

    if cooldown_active then
        clear_runtime_render_cache()
        return
    end
    cm_process_pending_envsky_runtime_tint_refresh()
    -- Keep point blending independent from shader runtime gating.
    -- Shader pass already has its own safety gate in shader_render_fn().

    -- Blending every frame
    local active_points, current_blended, active_weights = update_blending(points_enabled, in_game, map_name)
    if State and type(State.cache) == "table" then
        State.cache.last_active_points = active_points
        State.cache.last_active_weights = active_weights
        State.cache.last_current_blended = current_blended
    end
    maybe_sync_shader_state()

    local one_shot_active = false
    if State and State.transition and type(State.transition.one_shot_target) == "table" then
        local active_until = tonumber(State.transition.one_shot_active_until) or 0
        if current_time < active_until then
            apply_smooth_settings(
                State.transition.one_shot_target,
                State.transition.one_shot_apply_shader_state
            )
            one_shot_active = true
        else
            State.transition.one_shot_target = nil
            State.transition.one_shot_apply_shader_state = nil
            State.transition.one_shot_active_until = 0
            State.transition.speed = CONSTANTS.DEFAULTS.TRANSITION_SPEED
            State.transition.restore_speed_at = 0
        end
    end

    -- When points are disabled, do not force world colors back every frame.
    -- This lets the user edit colors freely via the mirror UI or native cheat controls.
    if not points_enabled and not one_shot_active then
        reset_smooth_state()
    end

    -- Everything else on an interval
    current_time = runtime_now()

    -- Reload the map settings config every 4 seconds (only if the checkbox is on)
    if is_auto_update_config_enabled() and (current_time - State.timers.last_config_reload_time >= CONFIG_RELOAD_INTERVAL) then
        State.timers.last_config_reload_time = current_time
        load_config()
        if UI.checkboxes.enable_shaders and UI.checkboxes.enable_shaders.GetValue then
            ensure_shaders_config()
            local shaders_val = UI.checkboxes.enable_shaders:GetValue()
            if shaders_val and shaders_val.Set then
                shaders_val:Set(State.shaders_config.enabled == true)
            end
        end
        update_points_visibility()

        -- Apply the settings from the reloaded config
        local map_name = Utils.System.get_current_map()
        if map_name then
            -- Reloaded config may carry different point data -> re-arm "Save to point" checkboxes.
            restore_shader_point_filters_for_map(map_name)
            local preset = get_preset_for_map(map_name)
            cm_bloom_apply_or_zero(preset)  -- map-scoped bloom: apply saved, or zero when none
            cm_postfx_apply_or_reseed(preset)  -- same for tonemap/local contrast
            if preset then
                local autosync_transition_started = start_one_shot_smooth_transition(preset, nil, 1.0, 1.1) == true
                if not autosync_transition_started then
                    apply_settings(preset)
                end
                State.map_entry_settings = preset
                if not autosync_transition_started then
                    seed_smooth_state(State.map_entry_settings)
                end
            end
            apply_shader_replace_for_map(map_name)
        end

        debug_print("Map settings synced from config")

        notify_user("Sync", "Map settings synced")
    end

end

-- Run frame-state update on frame-stage callback when available.
if not add_event_callback(events and events.frameStageNotify, function()
    if not script_initialized then return end
    on_frame()
end) then
    add_present_queue_callback(function()
        if not script_initialized then return end
        on_frame()
    end)
end

add_present_queue_callback(function()
    if not script_initialized then return end
    if type(shader_render_fn_ref) == "function" then
        shader_render_fn_ref()
    end

    local in_game = nil
    local map_name = nil
    local points_enabled = false
    local points = nil
    local weights = nil
    local blended = nil
    if State and type(State.cache) == "table" then
        in_game = (State.cache.frame_in_game == true)
        map_name = State.cache.frame_map_name
        points_enabled = (State.cache.frame_points_enabled == true)
        points = State.cache.last_active_points
        weights = State.cache.last_active_weights
        blended = State.cache.last_current_blended
    end

    if in_game == nil then
        in_game = Utils.System.is_in_game() == true
    end
    if in_game and not map_name then
        map_name = Utils.System.get_current_map()
    end
    if not points_enabled then
        points_enabled = is_points_enabled()
    end

    if points_enabled then
        if is_render_points_enabled() then
            render_points(points, weights, in_game, map_name)
        end
        if is_render_lines_enabled() then
            render_lines(points, blended, in_game)
        end
    end

    custom_sky_render_download_progress()

end)

-- Capture camera position
if events and events.overrideView and events.overrideView.Add then
    events.overrideView:Add(function(view)
        if script_initialized and view and view.m_vecOrigin then
            local origin = view.m_vecOrigin
            local ox, oy, oz = origin.x, origin.y, origin.z
            if type(ox) == "number" and ox == ox and ox ~= math.huge and ox ~= -math.huge
                and type(oy) == "number" and oy == oy and oy ~= math.huge and oy ~= -math.huge
                and type(oz) == "number" and oz == oz and oz ~= math.huge and oz ~= -math.huge then
                State.cache.last_camera_pos = {x = ox, y = oy, z = oz}
            end
        end
    end)
end

-- ========== INIT ==========
if CM_FORCE_VERBOSE_TXT_LOG then
    __cm_verbose_log("init: begin", true)
end

script_initialized = false
bootstrap_ok = safe_invoke("init.bootstrap_profiles", Utils.Config.bootstrap_profiles)
load_ok = safe_invoke("init.load_all_configs", load_all_configs)
ui_ok = safe_invoke("init.create_ui", create_ui)

script_initialized = (bootstrap_ok == true) and (load_ok == true) and (ui_ok == true)


-- ================== Skin Recolor (merged, self-contained) ==================
-- UI parents into the "Skin Recolor" sub-tab via
-- WSR_SKIN_PARENT. Wrapped in protected_call so its top-level return/error bails
-- only the skin init (not the whole script) and its locals stay isolated.
protected_call(function()
-- skin_recolor.lua: per-skin recolor of weapons AND gloves.
-- Offsets/mechanics:
--   hook e0c5 (MS2 FUN_18000ddb0 store): g_vColor0..3 <- DATA slots 0..3 while armed.
--   skinsys+0x28 (FUN_1813d9de0 vtable+0x28) = global texgen invalidate; WITHOUT it g_release/builder do not run texgen.
--   g_release = FUN_1813eb2b0(weapon+0x608,1) (client+0x13EB2B0); builder = FUN_18078de00(weapon,0,0,0) (client+0x78DE00).
--   the bake is DEFERRED (dirty drain ~7-15 frames) -> wait on the e0c5 counter.
--   skin-key = weapon+0x1860 (.vcompmat); enum = pawn:GetWeapons()->h:Get()->entity (ptr+GetDefIndex).

if not ffi then error("[wsr] no ffi") end
protected_call(ffi.cdef, [[
    typedef unsigned char      wsr_u8;
    typedef unsigned int       wsr_u32;
    typedef unsigned long long wsr_u64;
    typedef float              wsr_f32;
    typedef unsigned long long WSR_SIZE_T;
    typedef unsigned long      WSR_DWORD;
    int        VirtualProtect(void* a, WSR_SIZE_T s, WSR_DWORD p, WSR_DWORD* o);
    void*      VirtualAlloc(void* a, WSR_SIZE_T s, WSR_DWORD t, WSR_DWORD p);
    WSR_SIZE_T VirtualQuery(const void* a, void* b, WSR_SIZE_T l);
    typedef void  (__fastcall *wsr_relfn)(void* ctrl, char force);
    typedef void  (__fastcall *wsr_buildfn)(void* weapon, char p2, void* p3, void* p4);
    typedef void* (__fastcall *wsr_sysfn)(void);
    typedef void  (__fastcall *wsr_vm)(void* this_);
]])

local TAG="[wsr]"
local function log(...) if CM_VERBOSE then print(TAG, ...) end end
local MIN_PTR=0x100000000
local MAX_PTR=0x7FFFFFFFFFFF   -- x64 user-space ceiling: anything above is garbage, not a pointer

local RVA_HOOK = 0xDC38  -- MS2 store-site (FUN_18000d920)
local ORIG = {0x48,0x8B,0x46,0x08, 0x0F,0x10,0x44,0x24,0x30, 0x48,0x63,0xCF, 0x48,0xC1,0xE1,0x06}
local DISP = 16

-- ── WinAPI ──
local fe = utils and utils.FindExport
local function api(m,n,ct) local a=tonumber(fe(m,n) or 0); if a==0 then a=tonumber(fe("KernelBase.dll",n) or 0) end; if a==0 then return nil end; return ffi.cast(ct,a) end
local VP=api("kernel32.dll","VirtualProtect","int(__stdcall*)(void*,WSR_SIZE_T,WSR_DWORD,WSR_DWORD*)")
local VA=api("kernel32.dll","VirtualAlloc","void*(__stdcall*)(void*,WSR_SIZE_T,WSR_DWORD,WSR_DWORD)")
local VQ=api("kernel32.dll","VirtualQuery","WSR_SIZE_T(__stdcall*)(const void*,void*,WSR_SIZE_T)")
if not(VP and VA) then log("WinAPI miss"); return end
local function vprot(a,s,pr) local o=ffi.new("WSR_DWORD[1]"); VP(ffi.cast("void*",a),s,pr,o); return o[0] end
local g_mbi=ffi.new("wsr_u8[48]")
-- 🛑 Two checks this cannot work without (otherwise: crash 0xC0000005 reading FFFFFFFFFFFFFFFF):
--  1) upper bound: 0xFFFF... is the usual empty-slot marker and cannot exist in user space;
--  2) the VirtualQuery RESULT. On a bad address VQ returns 0 and does NOT touch the buffer, so g_mbi
--     keeps State/Protect from the last successful query and the function would say "readable" to anything.
local function is_readable(a)
    if a<MIN_PTR or a>MAX_PTR then return false end
    if VQ==nil then return true end
    if tonumber(VQ(ffi.cast("const void*",a),g_mbi,48) or 0)==0 then return false end
    local st=ffi.cast("wsr_u32*",ffi.cast("wsr_u64",g_mbi)+0x20)[0]
    local pr=ffi.cast("wsr_u32*",ffi.cast("wsr_u64",g_mbi)+0x24)[0]
    if st~=0x1000 then return false end
    if (pr%0x100)==0x01 then return false end
    if pr>=0x100 then return false end
    return true
end

-- ── module bases ──
local function mz_base(dll)
    local e=tonumber(fe(dll,"CreateInterface") or 0); if e==0 then return 0 end
    local cb=e-e%0x1000
    while cb>0 do local p=ffi.cast("wsr_u8*",cb); if p[0]==0x4D and p[1]==0x5A then break end; cb=cb-0x1000 end
    return cb
end
local MS2=mz_base("materialsystem2.dll"); if MS2==0 then log("materialsystem2 base miss"); return end
local CLIENT=mz_base("client.dll");        if CLIENT==0 then log("client base miss"); return end

local FP = utils and utils.FindPattern
local function fp(dll,sig) return FP and tonumber(FP(dll,sig) or 0) or 0 end
local function sig_match_at(a,sig)
    if a==0 or not is_readable(a) then return false end
    local p=ffi.cast("wsr_u8*",a); local i=0
    for tok in sig:gmatch("%S+") do
        if tok~="?" and tok~="??" then local b=tonumber(tok,16); if b==nil or p[i]~=b then return false end end
        i=i+1
    end
    return true
end
-- Name of the first function that could not be found. Not nil -> recolor DOES NOT WORK, no hook is installed.
local g_dead=nil
-- ⭐ The third branch ("rva(no-sig)") means the hint did not match and the signature is dead. Calling that
-- address would jump into the middle of some other function after a client.dll rebuild (crash or silent
-- corruption), so it only marks g_dead; the gate at the end of the block prints a single message.
local function resolve(name, dll, sig, rva_abs, off)
    off = off or 0
    local m=fp(dll,sig); local sa=(m~=0) and (m-off) or 0
    local use,how
    if sig_match_at(rva_abs+off, sig) then use,how=rva_abs,"rva-ok"
    elseif sa~=0 and sig_match_at(sa+off, sig) then use,how=sa,"SIG(rva-shift)"
    else use,how=rva_abs,"rva(no-sig)" end
    if how=="rva(no-sig)" then g_dead = g_dead or name end
    log(string.format("%s = %X (%s)", name, use, how))   -- log is already gated by CM_VERBOSE here
    return use
end
local SIG_REL = "48 89 5C 24 10 48 89 6C 24 18 48 89 74 24 20 57 41 56 41 57 48 83 EC 20 44 0F B6 F2 48 8B F9 E8 ? ? ? ?"
local SIG_BLD = "48 8D AC 24 00 FE FF FF 48 81 EC 00 03 00 00 44 0F B6 FA 48 8B D9" 
local SIG_SYS = "48 83 EC 28 48 8B 05 ? ? ? ? 48 85 C0 0F 85 ? ? ? ? 48 89 6C 24 40 48 89 74 24 48 48 89 7C 24 20"
local HOOK_SIG= "48 8B 46 08 0F 10 44 24 30 48 63 CF 48 C1 E1 06" 

local rva_hook = MS2+RVA_HOOK
local sh = fp("materialsystem2.dll", HOOK_SIG)
local function hook_valid(a)
    if a==0 or not is_readable(a) then return false end
    local p=ffi.cast("wsr_u8*",a)
    if p[0]==0xFF and p[1]==0x25 then return true end
    return sig_match_at(a,HOOK_SIG)
end
local FN
if hook_valid(rva_hook) then FN=rva_hook
elseif sh~=0 and sig_match_at(sh,HOOK_SIG) then FN=sh
else FN=rva_hook end
local BACK = FN+DISP
local g_release = ffi.cast("wsr_relfn",   resolve("g_release","client.dll", SIG_REL, CLIENT+0x1422450, 0))
local g_build   = ffi.cast("wsr_buildfn", resolve("builder",  "client.dll", SIG_BLD, CLIENT+0x7c5dd0,  5))
local g_sys     = ffi.cast("wsr_sysfn",   resolve("skinsys",  "client.dll", SIG_SYS, CLIENT+0x14135e0, 0))

-- ── verify + recover hook bytes ──
local fb=ffi.cast("wsr_u8*",FN)
if fb[0]==0xFF and fb[1]==0x25 then
    log("stale hook -> restore"); local p=vprot(FN,DISP,0x40); for i=0,DISP-1 do fb[i]=ORIG[i+1] end; vprot(FN,DISP,p)
end
for i=0,DISP-1 do if fb[i]~=ORIG[i+1] then log("hook bytes mismatch — abort"); return end end

-- ── shellcode ──
local dat=ffi.cast("wsr_u8*",VA(nil,0x8000,0x3000,0x40)); if dat==nil then log("VA dat fail"); return end
local DATA=ffi.cast("wsr_u64",dat)
local sc =ffi.cast("wsr_u8*",VA(nil,0x1000,0x3000,0x40)); if sc==nil then log("VA sc fail"); return end
local SC=ffi.cast("wsr_u64",sc)
-- DATA: [4]=armed [8]=calls [0xC]=writes ; [0x5000+slot*0x10]=slot color (slot0..3=g_vColor, 4..7=g_vColorTint)
do
    local code={}; local lp={}; local pat={}
    local function E(...) for _,b in ipairs({...}) do code[#code+1]=b%256 end end
    local function lbl(n) lp[n]=#code end
    local function jn(op2,n) E(0x0F,op2); local di=#code+1; E(0,0,0,0); pat[#pat+1]={di=di,endi=#code,label=n} end
    local function jm(n) E(0xE9); local di=#code+1; E(0,0,0,0); pat[#pat+1]={di=di,endi=#code,label=n} end
    local d=tonumber(DATA)
    local function imm64(v) for i=0,7 do E(math.floor(v/(2^(8*i)))%256) end end
    for _,b in ipairs(ORIG) do E(b) end
    E(0x41,0x52); E(0x41,0x53)                      -- push r10; push r11
    E(0x49,0xBB); imm64(d)                          -- mov r11,DATA
    E(0x41,0xFF,0x43,0x08)                          -- inc [r11+8]  calls
    E(0x41,0x83,0x7B,0x04,0x00); jn(0x84,"SKIP")    -- cmp dword[r11+4],0 / je SKIP
    E(0x4C,0x8B,0x54,0x08,0x28)                     -- mov r10,[rax+rcx+0x28]  name ptr
    E(0x4D,0x85,0xD2); jn(0x84,"SKIP")              -- test r10,r10 / jz SKIP
    -- DISCOVERY: if [DATA+0x10]!=0 -> write {name_ptr(r10), value(xmm0.x)} into the ring at DATA+0x6000 (16-byte entry), count@DATA+0x5FF8 (cap 256)
    E(0x41,0x83,0x7B,0x10,0x00); jn(0x84,"NODISC")  -- cmp dword[r11+0x10],0 / je NODISC
    E(0x50)                                          -- push rax
    E(0x41,0x8B,0x83,0xF8,0x5F,0x00,0x00)            -- mov eax,[r11+0x5FF8]  count
    E(0x3D,0x80,0x00,0x00,0x00); jn(0x83,"DPOP")     -- cmp eax,128 / jae DPOP
    E(0xC1,0xE0,0x05)                                -- shl eax,5  (*32, 32-byte entry)
    E(0x4D,0x89,0x94,0x03,0x00,0x60,0x00,0x00)       -- mov [r11+rax+0x6000],r10   name ptr
    E(0x41,0x0F,0x11,0x84,0x03,0x08,0x60,0x00,0x00)  -- movups [r11+rax+0x6008],xmm0  vec4 (full color)
    E(0x41,0xFF,0x83,0xF8,0x5F,0x00,0x00)            -- inc dword[r11+0x5FF8]
    lbl("DPOP"); E(0x58)                             -- pop rax
    lbl("NODISC")
    E(0x49,0xBB, 0x67,0x5F,0x76,0x43,0x6F,0x6C,0x6F,0x72) -- mov r11,"g_vColor"
    E(0x4D,0x39,0x1A); jn(0x85,"TRYFX")             -- cmp [r10],r11 / jne TRYFX (not g_vColor -> FX by hash)
    E(0x41,0x81,0x7A,0x08,0x54,0x69,0x6E,0x74); jn(0x85,"TRYDIG") -- cmp dword[r10+8],"Tint" / jne TRYDIG
    E(0x45,0x0F,0xB6,0x5A,0x0C)                     -- movzx r11d,byte[r10+12]
    E(0x41,0x83,0xEB,0x31); E(0x41,0x83,0xFB,0x07); jn(0x87,"SKIP") -- sub 0x31; cmp 7; ja SKIP
    jm("DOOVR")
    lbl("TRYDIG")
    E(0x41,0x80,0x7A,0x09,0x00); jn(0x85,"SKIP")    -- cmp byte[r10+9],0 / jne SKIP
    E(0x45,0x0F,0xB6,0x5A,0x08)                     -- movzx r11d,byte[r10+8]
    E(0x41,0x83,0xEB,0x30); E(0x41,0x83,0xFB,0x03); jn(0x87,"SKIP") -- sub 0x30; cmp 3; ja SKIP
    lbl("DOOVR")
    E(0x41,0xC1,0xE3,0x04)                          -- shl r11d,4
    E(0x49,0xBA); imm64(d)                          -- mov r10,DATA
    E(0x4D,0x01,0xDA)                               -- add r10,r11
    E(0x41,0x0F,0x10,0x82,0x00,0x50,0x00,0x00)      -- movups xmm0,[r10+0x5000]
    E(0x49,0xBB); imm64(d); E(0x41,0xFF,0x43,0x0C)  -- mov r11,DATA; inc [r11+0xC] writes
    jm("SKIP")                                       -- color applied -> skip FX
    -- FX: override any parameter by name HASH (table DATA+0x7000 [hash u32][value f32], count@DATA+0x6FF8)
    lbl("TRYFX")
    E(0x50); E(0x52); E(0x51)                        -- push rax; push rdx; push rcx
    E(0x31,0xD2)                                     -- xor edx,edx (hash=0)
    E(0x4C,0x89,0xD0)                                -- mov rax,r10 (name ptr)
    lbl("hloop")
    E(0x0F,0xB6,0x08)                                -- movzx ecx,byte[rax]
    E(0x84,0xC9); jn(0x84,"hdone")                   -- test cl,cl / jz hdone
    E(0x6B,0xD2,0x1F)                                -- imul edx,edx,31
    E(0x01,0xCA)                                     -- add edx,ecx
    E(0x48,0xFF,0xC0)                                -- inc rax
    jm("hloop")
    lbl("hdone")
    E(0x48,0xB8); imm64(d)                           -- mov rax,DATA
    E(0x83,0x78,0x04,0x00); jn(0x84,"fxpop")         -- cmp dword[rax+4],0 / je fxpop (not armed)
    E(0x8B,0x88,0xF8,0x7F,0x00,0x00)                 -- mov ecx,[rax+0x7FF8] override count
    E(0x48,0x8D,0x80,0x00,0x70,0x00,0x00)            -- lea rax,[rax+0x7000] table
    lbl("fxloop")
    E(0x85,0xC9); jn(0x84,"fxpop")                   -- test ecx,ecx / jz fxpop
    E(0x39,0x10); jn(0x85,"fxnext")                  -- cmp [rax],edx / jne fxnext
    E(0xF3,0x0F,0x10,0x40,0x04)                      -- movss xmm0,[rax+4]
    E(0x0F,0xC6,0xC0,0x00)                            -- shufps xmm0,xmm0,0 (broadcast value)
    jm("fxpop")
    lbl("fxnext")
    E(0x48,0x83,0xC0,0x08)                           -- add rax,8
    E(0xFF,0xC9)                                     -- dec ecx
    jm("fxloop")
    lbl("fxpop")
    E(0x59); E(0x5A); E(0x58)                        -- pop rcx; pop rdx; pop rax
    lbl("SKIP")
    E(0x41,0x5B); E(0x41,0x5A)                      -- pop r11; pop r10
    E(0xFF,0x25,0x00,0x00,0x00,0x00); imm64(BACK)   -- jmp store
    for _,p in ipairs(pat) do local dd=lp[p.label]-p.endi; if dd<0 then dd=dd+2^32 end
        for i=0,3 do code[p.di+i]=math.floor(dd/(2^(8*i)))%256 end end
    for i,b in ipairs(code) do sc[i-1]=b end
end
local Ovr=ffi.cast("wsr_u32*", DATA+0x04)
local Cc =ffi.cast("wsr_u32*", DATA+0x08)
local Wc =ffi.cast("wsr_u32*", DATA+0x0C)
local function set_slot(slot,r,g,b,a) local f=ffi.cast("wsr_f32*", DATA+0x5000+slot*0x10); f[0]=r;f[1]=g;f[2]=b;f[3]=a or 1.0 end

local Disc =ffi.cast("wsr_u32*", DATA+0x10)        -- enable flag
local DiscN=ffi.cast("wsr_u32*", DATA+0x5FF8)      -- ring count
local DISC_BASE=DATA+0x6000                         -- 16-byte entry: [u64 name_ptr][f32 value]
Disc[0]=1                                           -- discovery always on (cheap)
local function rcstr(a, cap)
    if a==0 or not is_readable(a) then return nil end
    local p=ffi.cast("wsr_u8*",a); local o={}
    for i=0,(cap or 48)-1 do local b=p[i]; if b==0 then break end; if b<0x20 or b>0x7E then return nil end; o[#o+1]=string.char(b) end
    if #o==0 then return nil end; return table.concat(o)
end
-- ── FX override: hash->value table (DATA+0x7000, count@DATA+0x7FF8), armed via Ovr ──
local OvrN=ffi.cast("wsr_u32*", DATA+0x7FF8)
local OVR_BASE=DATA+0x7000
local function fxhash(s) local h=0; for i=1,#s do h=(h*31+s:byte(i))%4294967296 end; return h end
local function ovr_set(map)   -- map: {name=value} -> fill the table
    local i=0
    for nm,val in pairs(map) do
        ffi.cast("wsr_u32*", OVR_BASE+i*8)[0]=fxhash(nm)
        ffi.cast("wsr_f32*", OVR_BASE+i*8+4)[0]=val
        i=i+1
    end
    OvrN[0]=i
end

local installed=false
local function install() if fb[0]==0xFF and fb[1]==0x25 then installed=true; return end
    local p=vprot(FN,DISP,0x40); fb[0]=0xFF;fb[1]=0x25;fb[2]=0;fb[3]=0;fb[4]=0;fb[5]=0
    ffi.cast("wsr_u64*",FN+6)[0]=SC; vprot(FN,DISP,p); installed=true end
local function uninstall() if not installed then return end
    Ovr[0]=0; local p=vprot(FN,DISP,0x40); for i=0,DISP-1 do fb[i]=ORIG[i+1] end; vprot(FN,DISP,p); installed=false end

-- ── writer-FX hook: prologue of the client.dll writer FUN_181839cc0 (2nd consumer of the FX table) ──
-- Same FX table (DATA+0x7000, count@+0x7FF8) and the Ovr@DATA+0x04 gate; covers executor-layer effects (glitter/iridescence) e0c5 cannot reach. Name-targeted (hash = e0c5 TRYFX) -> broadcast into [r9].
-- Writer entry: rcx=mat, rdx=namekey (name at [rdx+8]), r8d=type(4), r9=&value(float[4]). [r9] is written before MOV R12,R9.
-- writer-fx writes counter @DATA+0x28. Uses rax/r10/r11 (volatile, no push); rcx/rdx/r8/r9 are left untouched.
local wfx_install, wfx_uninstall, WFXWC
do
    local ORIG2 = {0x48,0x89,0x5C,0x24,0x10, 0x48,0x89,0x6C,0x24,0x18, 0x48,0x89,0x74,0x24,0x20}  -- 3×MOV [RSP+x],reg
    local DISP2 = 15
    -- unique body bytes (offset +0xEC from the start): MOV R9D,1 / MOV [RSP+40],0x18 / MOVSXD R10,R8D / MOV R8,R12 / MOV [RSP+38],0x05
    -- the twin FUN_181839f70 has 0x14/0x03 at the same positions, so it will not match
    local SIG_WFX = "41 B9 01 00 00 00 C6 44 24 40 18 4D 63 D0 4D 8B C4 C6 44 24 38 05"
    local FN2 = resolve("wfx", "client.dll", SIG_WFX, CLIENT+0x1876190, 0xEC)
    local BACK2 = FN2 + DISP2
    local cb2 = ffi.cast("wsr_u8*", FN2)
    local ok = is_readable(FN2)
    if ok and cb2[0]==0xFF and cb2[1]==0x25 then
        log("wfx: stale hook -> restore"); local p=vprot(FN2,DISP2,0x40); for i=0,DISP2-1 do cb2[i]=ORIG2[i+1] end; vprot(FN2,DISP2,p)
    end
    if ok then for i=0,DISP2-1 do if cb2[i]~=ORIG2[i+1] then
        log("wfx: bytes mismatch — off"); ok=false; break end end
    else log("wfx: FN2 unreadable — off") end
    local sc2 = ok and ffi.cast("wsr_u8*", VA(nil,0x1000,0x3000,0x40)) or nil
    if ok and sc2==nil then log("wfx: VA sc2 fail — off"); ok=false end
    if ok then
        local SC2 = ffi.cast("wsr_u64", sc2)
        local code={}; local lp={}; local pat={}
        local function E(...) for _,b in ipairs({...}) do code[#code+1]=b%256 end end
        local function lbl(n) lp[n]=#code end
        local function jn(op2,n) E(0x0F,op2); local di=#code+1; E(0,0,0,0); pat[#pat+1]={di=di,endi=#code,label=n} end
        local function jm(n) E(0xE9); local di=#code+1; E(0,0,0,0); pat[#pat+1]={di=di,endi=#code,label=n} end
        local d=tonumber(DATA)
        local function imm64(v) for i=0,7 do E(math.floor(v/(2^(8*i)))%256) end end
        E(0x49,0xBB); imm64(d)                           -- mov r11,DATA
        E(0x41,0x83,0x7B,0x04,0x00); jn(0x84,"CEND")     -- cmp dword[r11+4],0 / je CEND (Ovr armed?)
        E(0x41,0x83,0xF8,0x04); jn(0x85,"CEND")          -- cmp r8d,4 / jne CEND (vec4 format)
        E(0x4C,0x8B,0x52,0x08)                           -- mov r10,[rdx+8]  name ptr
        E(0x4D,0x85,0xD2); jn(0x84,"CEND")               -- test r10,r10 / jz CEND
        E(0x31,0xC0)                                     -- xor eax,eax  (hash=0)
        lbl("HLOOP")
        E(0x45,0x0F,0xB6,0x1A)                           -- movzx r11d,byte[r10]
        E(0x45,0x84,0xDB); jn(0x84,"HDONE")              -- test r11b,r11b / jz HDONE
        E(0x6B,0xC0,0x1F)                                -- imul eax,eax,31
        E(0x44,0x01,0xD8)                                -- add eax,r11d
        E(0x49,0xFF,0xC2)                                -- inc r10
        jm("HLOOP")
        lbl("HDONE")
        E(0x49,0xBB); imm64(d)                           -- mov r11,DATA
        E(0x45,0x8B,0x93,0xF8,0x7F,0x00,0x00)            -- mov r10d,[r11+0x7FF8]  override count
        E(0x45,0x85,0xD2); jn(0x84,"CEND")               -- test r10d,r10d / jz CEND
        E(0x4D,0x8D,0x9B,0x00,0x70,0x00,0x00)            -- lea r11,[r11+0x7000]  table
        lbl("FLOOP")
        E(0x41,0x39,0x03); jn(0x85,"FNEXT")              -- cmp [r11],eax / jne FNEXT
        E(0xF3,0x41,0x0F,0x10,0x43,0x04)                 -- movss xmm0,[r11+4]
        E(0x0F,0xC6,0xC0,0x00)                           -- shufps xmm0,xmm0,0  broadcast
        E(0x41,0x0F,0x11,0x01)                           -- movups [r9],xmm0    overwrite value
        E(0x41,0xFF,0x83,0x28,0x90,0xFF,0xFF)            -- inc dword[r11-0x6FD8] (=DATA+0x28 writes)
        jm("CEND")
        lbl("FNEXT")
        E(0x49,0x83,0xC3,0x08)                           -- add r11,8
        E(0x41,0xFF,0xCA); jn(0x85,"FLOOP")              -- dec r10d / jnz FLOOP
        lbl("CEND")
        for _,b in ipairs(ORIG2) do E(b) end             -- displaced prologue (rsp untouched)
        E(0xFF,0x25,0x00,0x00,0x00,0x00); imm64(BACK2)   -- jmp BACK2
        for _,p in ipairs(pat) do local dd=lp[p.label]-p.endi; if dd<0 then dd=dd+2^32 end
            for i=0,3 do code[p.di+i]=math.floor(dd/(2^(8*i)))%256 end end
        for i,b in ipairs(code) do sc2[i-1]=b end
        WFXWC = ffi.cast("wsr_u32*", DATA+0x28)
        local inst2=false
        wfx_install = function() if cb2[0]==0xFF and cb2[1]==0x25 then inst2=true; return end
            local p=vprot(FN2,DISP2,0x40); cb2[0]=0xFF;cb2[1]=0x25;cb2[2]=0;cb2[3]=0;cb2[4]=0;cb2[5]=0
            ffi.cast("wsr_u64*",FN2+6)[0]=SC2; vprot(FN2,DISP2,p); inst2=true end
        wfx_uninstall = function() if not inst2 then return end
            local p=vprot(FN2,DISP2,0x40); for i=0,DISP2-1 do cb2[i]=ORIG2[i+1] end; vprot(FN2,DISP2,p); inst2=false end
    end
end

local function skinsys_invalidate()
    local s=g_sys(); local sn=tonumber(ffi.cast("wsr_u64",s)) or 0
    if sn<MIN_PTR then return false end
    local vt=tonumber(ffi.cast("wsr_u64*",sn)[0]) or 0; if vt<MIN_PTR then return false end
    local fn=tonumber(ffi.cast("wsr_u64*",vt+0x28)[0]) or 0; if fn<MIN_PTR then return false end
    ffi.cast("wsr_vm",fn)(ffi.cast("void*",sn)); return true
end

-- ── entity / skin helpers ──
local function n_of(p) if p==nil then return 0 end if type(p)=="number" then return p end return tonumber(ffi.cast("wsr_u64", ffi.cast("void*", p))) or 0 end
local function pawn0()
    if not entities then return nil end
    if entities.GetLocalPawn then local p=entities:GetLocalPawn(); if p then return p end end
    return nil
end
-- skin-key = CUtlString holding the .vcompmat path inside the weapon. The offset moves between game
-- updates and the failure is silent: the config key does not match -> nothing gets recolored.
-- So the offset is found BY INVARIANT: the only pointer in the window leading to a printable string
-- that ends in ".vcompmat". The hardcoded value stays as the starting point and fallback.
local SKINKEY_OFF=0x1860
local g_skinkey_ok=false; local g_skinkey_try=0
local function skinkey_str(sp)
    -- Upper bound BEFORE is_readable: object slots are full of 0xFFFF..., no point calling VirtualQuery
    -- on them (it is a syscall per candidate).
    if sp<MIN_PTR or sp>MAX_PTR or not is_readable(sp) then return nil end
    local p=ffi.cast("wsr_u8*",sp); local o={}
    for i=0,127 do local b=p[i]; if b==0 then break end; if b<0x20 or b>0x7E then return nil end; o[#o+1]=string.char(b) end
    local s=table.concat(o); if #s==0 then return nil end
    return s
end
-- A weapon without a custom skin has no such string, so the scan cannot run forever: after
-- SKINKEY_TRIES failed attempts give up and use the hardcoded value.
local SKINKEY_TRIES=64
local function skinkey_resolve(ptr)
    if g_skinkey_ok then return end
    g_skinkey_try=g_skinkey_try+1
    if g_skinkey_try>SKINKEY_TRIES then g_skinkey_ok=true; return end
    local lo=SKINKEY_OFF-0x200; if lo<0 then lo=0 end; lo=lo-(lo%8)   -- alignment: we are looking for a POINTER
    local hi=SKINKEY_OFF+0x200
    if not (is_readable(ptr+lo) and is_readable(ptr+hi)) then return end
    for off=lo,hi,8 do
        local s=skinkey_str(tonumber(ffi.cast("wsr_u64*", ptr+off)[0]) or 0)
        if s~=nil and s:find("%.vcompmat$") then
            if off~=SKINKEY_OFF then log(string.format("skin-key 0x%X -> 0x%X (.vcompmat)", SKINKEY_OFF, off)) end
            SKINKEY_OFF=off; g_skinkey_ok=true; return
        end
    end
end
local function read_skinkey(ptr)
    skinkey_resolve(ptr)
    if not is_readable(ptr+SKINKEY_OFF) then return nil end
    local s=skinkey_str(tonumber(ffi.cast("wsr_u64*", ptr+SKINKEY_OFF)[0]) or 0)
    if s==nil then return nil end
    local base=s:match("([^/\\]+)%.vcompmat$") or s:match("([^/\\]+)$") or s
    return base
end
-- list of MY weapons: {ptr, defidx, skin}
local function my_weapons()
    local pw=pawn0(); if pw==nil or pw.GetWeapons==nil then return {} end
    local list=pw:GetWeapons(); if type(list)~="table" then return {} end
    local out={}
    for _,h in ipairs(list) do
        local valid=(h.Valid==nil) or h:Valid()
        local w=(valid and h.Get) and h:Get() or nil
        local p=(w and w.GetPointer) and n_of(w:GetPointer()) or 0
        if p>=MIN_PTR then
            local di=(w.GetDefIndex) and w:GetDefIndex() or nil
            out[#out+1]={ptr=p, defidx=di, skin=read_skinkey(p) or "?"}
        end
    end
    return out
end
local function active_skin()
    local pw=pawn0(); if pw==nil or pw.GetActiveWeapon==nil then return nil end
    local w=pw:GetActiveWeapon(); if w==nil or w.GetPointer==nil then return nil end
    local p=n_of(w:GetPointer()); if p<MIN_PTR then return nil end
    return read_skinkey(p)
end
local function active_wep()  -- -> ptr (0 if none), skin
    local pw=pawn0(); if pw==nil or pw.GetActiveWeapon==nil then return 0,nil end
    local w=pw:GetActiveWeapon(); if w==nil or w.GetPointer==nil then return 0,nil end
    local p=n_of(w:GetPointer()); if p<MIN_PTR then return 0,nil end
    return p, read_skinkey(p)
end
-- gloves: glove_item = *(pawn+0x15C8); dirty flag glove_item+0x168D -> pawn think (GUpd) re-composites
-- (dirty = m_bNeedToReApplyGloves, m_EconGloves 0x1690).
-- The back-ptr comes from the pawn constructor: `mov [rdi+0x15C8], rdi` (client 0xBF4CBE).
-- glove_item = the pawn's self back-ptr; setting the dirty byte forces a full
-- glove re-composite in GUpd (glove composite submit -> the e0c5 hook catches g_vColorTint).
-- Both offsets are RESOLVED ON THE LIVE PAWN; the hardcoded values below are only a fallback if the
-- resolve finds nothing. Otherwise every client.dll rebuild silently breaks the gloves: the back-ptr
-- reads as zero -> glove_item()=0 -> early return false.
--   dirty    = schema field m_bNeedToReApplyGloves, offset taken straight from accessor.offset
--   back-ptr = the only place in the pawn holding a pointer TO ITSELF (constructor: mov [rdi+X],rdi).
--              Searched downward from dirty: both self-stores sit right below it.
local GLOVE_BACKPTR_OFF, GLOVE_DIRTY_OFF = 0x15C8, 0x168D
local g_glove_off_ok = false
local function glove_resolve_offsets(pw, pp)
    if g_glove_off_ok then return end
    local acc = pw["m_bNeedToReApplyGloves"]
    local o = (acc~=nil) and tonumber(acc.offset) or nil
    if o~=nil and o>0 and o<0x8000 then
        if o~=GLOVE_DIRTY_OFF then log(string.format("glove dirty 0x%X -> 0x%X (schema)", GLOVE_DIRTY_OFF, o)) end
        GLOVE_DIRTY_OFF=o; g_glove_off_ok=true
    end
    -- ⚠ ALIGNMENT IS REQUIRED: dirty is a byte field (e.g. 0x168D), so a window starting from it would
    -- never land on an aligned pointer (0x15C8) with a step of 8.
    local lo=GLOVE_DIRTY_OFF-0x300; lo=lo-(lo%8)
    if lo>0 and is_readable(pp+lo) and is_readable(pp+GLOVE_DIRTY_OFF) then
        for off=lo, GLOVE_DIRTY_OFF-8, 8 do
            if (tonumber(ffi.cast("wsr_u64*", pp+off)[0]) or 0)==pp then
                if off~=GLOVE_BACKPTR_OFF then log(string.format("glove back-ptr 0x%X -> 0x%X (self-ptr)", GLOVE_BACKPTR_OFF, off)) end
                GLOVE_BACKPTR_OFF=off; g_glove_off_ok=true; break
            end
        end
    end
end
local function glove_item()
    local pw=pawn0(); if pw==nil or pw.GetPointer==nil then return 0 end
    local pp=n_of(pw:GetPointer()); if pp<MIN_PTR then return 0 end
    glove_resolve_offsets(pw, pp)
    if not is_readable(pp+GLOVE_BACKPTR_OFF) then return 0 end
    local gi=tonumber(ffi.cast("wsr_u64*", pp+GLOVE_BACKPTR_OFF)[0]) or 0
    if gi<MIN_PTR then return 0 end
    return gi
end
local function glove_mark_dirty()
    local gi=glove_item(); if gi<MIN_PTR then return false end
    if not is_readable(gi+GLOVE_DIRTY_OFF) then return false end
    ffi.cast("wsr_u8*", gi+GLOVE_DIRTY_OFF)[0]=1; return true
end
-- the glove config key = TEAM (T/CT): more reliable than the skin (the glove skin is not read reliably).
-- m_iTeamNum: 2=T, 3=CT. No team/gloves -> fallback "__gloves__".
local function glove_key()
    local gi=glove_item(); if gi<MIN_PTR then return nil end
    local pw=pawn0(); if pw==nil then return "__gloves__" end
    local t=nil; local acc=pw.m_iTeamNum
    if acc~=nil and acc.Get~=nil then t=acc:Get() end
    if t==2 then return "glove:T" elseif t==3 then return "glove:CT" end
    return "__gloves__"
end

-- ── config: skin -> {enabled, cols={{r,g,b}x4}} (r,g,b in 0..1) ──
local g_config = {}

-- ── persistence (paths relative to game/csgo) ──
local CFG_PATH = (CM_CFG_DIR or "fatality") .. "/weapon_skin_recolor.cfg"
local U_FW = utils and utils.FileWrite
local U_FR = utils and utils.FileRead
local U_FE = utils and utils.FileExists
local U_S2A= utils and utils.StringToArray
local U_A2S= utils and utils.ArrayToString
local function persist_ok() return U_FW and U_FR and U_FE and U_S2A and U_A2S end
-- line format: skin|r,g,b r,g,b ...|name=val name=val   (migrates the old skin;r;g;b;... format)
local g_last_saved=nil   -- last written config text (guards against redundant writes/spam)
local function save_config()   -- -> true if actually written (content changed)
    if not persist_ok() then log("save: file-API unavailable"); return false end
    local lines={}
    for skin,cfg in pairs(g_config) do
        if cfg.enabled and cfg.cols then
            local cs={}; for i=1,#cfg.cols do local c=cfg.cols[i] or {0,0,0}
                cs[i]=string.format("%.4f,%.4f,%.4f", c[1],c[2],c[3]) end
            local fs={}; if cfg.fx then for nm,v in pairs(cfg.fx) do fs[#fs+1]=string.format("%s=%.4f",nm,v) end end
            lines[#lines+1]=skin.."|"..table.concat(cs," ").."|"..table.concat(fs," ")
        end
    end
    table.sort(lines)   -- stable order -> content comparison does not depend on pairs()
    local text=table.concat(lines,"\n")
    if text==g_last_saved then return false end   -- nothing changed -> do not write, do not log
    U_FW(CFG_PATH, U_S2A(text)); g_last_saved=text
    log(string.format("save: %d skin(s) -> %s", #lines, CFG_PATH))
    return true
end
local function load_config()
    if not persist_ok() then log("load: file-API unavailable"); return end
    if not U_FE(CFG_PATH) then log("load: no config (first run): "..CFG_PATH); return end
    local bytes=U_FR(CFG_PATH); if not bytes then log("load: FileRead nil"); return end
    local s=U_A2S(bytes); if type(s)~="string" then log("load: ArrayToString fail"); return end
    local n=0
    for line in (s.."\n"):gmatch("([^\n]*)\n") do
        if line~="" then
            if line:find("|",1,true) then        -- NEW format
                local seg={}; for x in (line.."|"):gmatch("([^|]*)|") do seg[#seg+1]=x end
                local skin=seg[1]; local cols={}; local fx={}
                for tr in (seg[2] or ""):gmatch("%S+") do local a,b,c=tr:match("([^,]+),([^,]+),([^,]+)")
                    cols[#cols+1]={tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0} end
                for tok in (seg[3] or ""):gmatch("%S+") do local nm,v=tok:match("([^=]+)=(.+)"); if nm then fx[nm]=tonumber(v) or 0 end end
                if skin and #cols>=1 then g_config[skin]={enabled=true, cols=cols, fx=fx}; n=n+1 end
            else                                  -- OLD format skin;r;g;b;...
                local parts={}; for p in line:gmatch("[^;]+") do parts[#parts+1]=p end
                local ncol=math.floor((#parts-1)/3)
                if ncol>=1 then local skin=parts[1]; local cols={}
                    for i=0,ncol-1 do cols[i+1]={tonumber(parts[2+i*3]) or 0, tonumber(parts[3+i*3]) or 0, tonumber(parts[4+i*3]) or 0} end
                    g_config[skin]={enabled=true, cols=cols, fx={}}; n=n+1 end
            end
        end
    end
    log(string.format("load: %d skin(s) from %s", n, CFG_PATH))
end
load_config()

-- ── APPLY state machine (one weapon at a time) ──
local pickers={}
local g_params={}        -- discovered texgen parameters: name -> last value (.x)
local g_native_col={}    -- native skin colors: g_vColorN/g_vColorTintN -> {r,g,b}
local g_q={}; local g_qi=0; local g_st="idle"; local g_restore=false
local g_wbase=0; local g_wlast=0; local g_stable=0; local g_wait=0
local g_done={}          -- [weaponPtr]=true: already recolored (memo)
local g_auto=true         -- auto-apply new skins
local g_last_pawn=0; local g_cur=nil; local g_scant=0; local g_last_hp=-1
local g_wep_seen={}; local g_wep_skin={}   -- weapons from the previous scan + their skin key (detects buys / address reuse)
-- LIVE picker sync + autosave (pickers can be set from render with the right type)
local gpickers={}         -- 8 glove pickers (g_vColorTint1..8)
local g_glove_key=nil   -- current glove key (their skin), to reload the UI on change
local g_last_glove=0           -- glove ptr (ptr change = team/glove change)
local g_glove_apply_key=nil    -- glove key in the apply loop (the ptr survives a team switch -> track by KEY)
local function now_s() if game and game.engine and game.engine.GetLastTimestamp then return game.engine:GetLastTimestamp() end return 0 end
local g_picker_skin=nil   -- skin whose colors are currently in the weapon pickers
local g_active_ptr=0      -- ptr of the weapon IN HAND (forces a re-bake on color edits)
local g_last_pick={}      -- last weapon picker colors (0..255)
local g_glove_last={}; local g_glove_loaded=false   -- same for the glove pickers
local g_wep_dirty=false; local g_glove_dirty=false  -- what was edited -> what to re-bake on debounce
local g_save_in=0; local DEBOUNCE=130   -- debounce for the file write + re-bake
-- UI-FREEZE: for the first FREEZE_SEC after the script loads, picker changes are ignored (Fatality
-- "restores" them to black when loading a config, and that leaked into g_config). Skins are still
-- recolored from g_config as usual. When the window ends, colors are FORCE-loaded from the config into
-- the pickers (overwriting Fatality's black). Time is wall-clock utils.GetUnixTime (ticks in the menu too).
local FREEZE_SEC=10; local g_load_ts=nil; local g_unfrozen=false
-- FX (effects): 0-100 sliders -> parameter override by hash, per skin
local fxsliders={}; local g_fx_last={}
local gfxsliders={}; local g_glove_fx_last={}   -- glove effect sliders (same EFFECTS, config GKEY.fx)
local g_fxcb=nil; local g_fxset=nil; local g_gfxset=nil   -- "experimental settings" checkbox + cogwheel containers
local g_fx_enabled=false; local g_fx_vis=nil              -- effect logic on/off + last visibility
local EFFECTS={
  {n="g_flPearlescentScale",lo=0,hi=3},   {n="g_fBrightness",lo=0,hi=3},        {n="g_fContrast",lo=0,hi=3},
  {n="g_fSaturation",lo=0,hi=3},          {n="g_fHueShift",lo=0,hi=1},          {n="g_flColorBrightness",lo=0,hi=3},
  {n="g_flPaintRoughness",lo=0,hi=1},     {n="g_vPaintRoughness",lo=0,hi=1},    {n="g_flPaintMetalness",lo=0,hi=1},
  {n="g_vPaintMetalness",lo=0,hi=1},      {n="g_flSheenScale",lo=0,hi=3},       {n="g_fGlitterIntensity",lo=0,hi=1},
  {n="g_fGlitterScale",lo=0,hi=50},       {n="g_flIridescentStrength",lo=0,hi=2},{n="g_flIridescentScale",lo=0,hi=8},
  {n="g_flIridescentHueShift",lo=0,hi=1}, {n="g_flSelfIllumBrightness",lo=0,hi=5},{n="g_fOverlayStrength",lo=0,hi=2},
  {n="g_fPatternEmboss",lo=0,hi=2},       {n="g_fPatternMetalness",lo=0,hi=1},  {n="g_fWearProgress",lo=0,hi=1},
}
-- glove effects (csgo_customglove.vfx): global knobs + special finishes (glitter/iridescent/pearlescent on some gloves)
local GLOVE_EFFECTS={
  {n="g_flSheenScale",lo=0,hi=3},          {n="g_fWearProgress",lo=0,hi=1},        {n="g_fWearExponent",lo=0,hi=3},
  {n="g_fColorMaskBlur",lo=0,hi=3},        {n="g_fPatternNormalDistortion",lo=0,hi=2},
  {n="g_fGlitterIntensity",lo=0,hi=1},     {n="g_fGlitterScale",lo=0,hi=50},
  {n="g_flIridescentStrength",lo=0,hi=2},  {n="g_flIridescentScale",lo=0,hi=8},    {n="g_flIridescentHueShift",lo=0,hi=1},
  {n="g_flPearlescentScale",lo=0,hi=3},
}
local function v2s(e,v) local s=(v-e.lo)/(e.hi-e.lo)*100; if s<0 then s=0 elseif s>100 then s=100 end; return s end
local function s2v(e,s) return e.lo+(s/100)*(e.hi-e.lo) end
local function fx_read(e,arr) arr=arr or fxsliders; local sl=arr[e.n]; if sl==nil or sl.GetValue==nil then return nil end
    local vp=sl:GetValue(); if vp==nil or vp.Get==nil then return nil end; return vp:Get() end
local function fx_setpos(e,pos,arr) arr=arr or fxsliders; local sl=arr[e.n]; if sl==nil or sl.GetValue==nil then return end
    local vp=sl:GetValue(); if vp and vp.Set then vp:Set(pos) end end
local function pk_get(arr,i)   -- -> r,g,b in 0..255
    local pk=arr[i]; if pk==nil or pk.GetValue==nil then return nil end
    local vp=pk:GetValue(); if vp==nil or vp.Get==nil then return nil end
    local c=vp:Get(); if c==nil or c.GetR==nil then return nil end
    return c:GetR(), c:GetG(), c:GetB()
end
local function pk_set(arr,i, r,g,b)   -- r,g,b in 0..1
    local pk=arr[i]; if pk==nil or pk.GetValue==nil then return end
    local vp=pk:GetValue(); if vp==nil or vp.Set==nil then return end
    if draw==nil or draw.Color==nil then return end
    vp:Set(draw.Color(math.floor(r*255+0.5), math.floor(g*255+0.5), math.floor(b*255+0.5), 255))
end
local function start_apply(restore)
    install()
    local all=my_weapons()
    g_q={}
    for _,it in ipairs(all) do
        if restore or (g_config[it.skin] and g_config[it.skin].enabled) then g_q[#g_q+1]=it end
    end
    local gi=glove_item(); local gk=glove_key()
    if gi>=MIN_PTR and gk and (restore or (g_config[gk] and g_config[gk].enabled)) then
        g_q[#g_q+1]={isglove=true, ptr=gi, skin=gk} end
    if #g_q==0 then log("APPLY: nothing (no weapons/configs)"); g_st="idle"; return end
    g_restore=restore; g_qi=0; g_st="step"
    log(string.format("APPLY start: %d weapons restore=%s", #g_q, tostring(restore)))
end
-- weapon RESET
local function reset_active()
    install()
    local p,sk=active_wep()
    if sk==nil or p<MIN_PTR then log("reset: no active weapon skin in hands"); return end
    g_config[sk]=nil; save_config()
    g_picker_skin=nil                 
    g_done[p]=nil
    g_q={{ptr=p, skin=sk}}; g_qi=0; g_restore=true; g_st="step"
    log(string.format("reset weapon '%s' -> stock (config removed)", sk))
end
-- glove RESET
local function reset_gloves()
    install()
    local gi=glove_item(); local gk=glove_key()
    if gi<MIN_PTR or gk==nil then log("reset gloves: gloves not equipped"); return end
    g_config[gk]=nil; save_config()
    g_glove_loaded=false                    
    g_done[gi]=nil
    g_q={{isglove=true, ptr=gi, skin=gk}}; g_qi=0; g_restore=true; g_st="step"
    log("reset gloves -> stock (config removed)")
end

-- ── UI ──
local g_ui=false
local g_active_lbl=nil

-- ── "Other" sub-tab layout ──────────────────────────────────────────────────
-- Panels in a container flow left to right and fill the row. A panel can only be placed UNDER
-- another one with a vertical stack; GroupWidthMode does not do that: per the docs it is a
-- WIDTH PRESET for the host type (DEFAULT = lua>groups, REDUCED = tabs with sub-tabs,
-- FULL = no sub-tabs), not a layout hint.
-- ⚠ The ui_* helpers in this file (ui_vec2/ui_make_layout/...) are declared inside ANOTHER block and
-- are not visible here: the name would resolve to a nil global. So only gui/draw are used here.
-- ⚠ The column width is not guessed but taken from the panel itself: Control.size is a documented field
-- (Vec2 with .x/.y, "total size of this control"). The column width MUST match the panel width,
-- otherwise panels get clipped or leave a gap to the next one.
-- ⛔ The narrow REDUCED mode is NOT needed here: in the Maps tab it is used on the RIGHT panels so they
-- do not overflow the menu frame. Here moving chams to the second row solves that.
local OTHER_COL_W_FALLBACK = 310  -- if size is not filled in yet; panel width in DEFAULT mode
local OTHER_COL_GAP = 18          -- gap between panels, same as the left stack of the Maps tab

local function wsr_vec2(x, y)
    local ctor = draw and (draw.Vec2 or draw.vec2) or nil
    if not ctor then return nil end
    local ok, v = protected_call(ctor, x, y)
    if ok then return v end
    return nil
end

-- The chams panel is built WITHOUT adding it to the parent (stack_only) so it can be placed
-- in a column. The chams tick will see the ready UI and skip building it.
local function wsr_build_chams_group()
    if not CHAMS_BUILD_UI then return nil end
    local ok, g = protected_call(CHAMS_BUILD_UI, true)
    if not ok or g == true or g == false then return nil end
    return g
end

-- Same for the whitelist: its block is merged AFTER this one, but WLF_BUILD_UI is declared on load
-- and this build_ui runs on a tick, by which time the function exists.
local function wsr_build_wlf_group()
    if not WLF_BUILD_UI then return nil end
    local ok, g = protected_call(WLF_BUILD_UI, true)
    if not ok or g == true or g == false then return nil end
    return g
end

-- A vertical column of two groups. Same scheme as the working one in this file (the left stack
-- of the Maps tab): first a Layout with StackDirection.VERTICAL, falling back to
-- gui.MakeStackedGroups. Layout signature: (id, position, size, direction).
-- the width is taken from the already created panel so the column matches it pixel for pixel
local function wsr_group_width(g)
    if g and g.size and type(g.size.x) == "number" and g.size.x > 0 then return g.size.x end
    return OTHER_COL_W_FALLBACK
end

local function wsr_make_column(id, top, bottom, content_h)
    if not (top and bottom) then return nil end
    local size = wsr_vec2(wsr_group_width(top), content_h + OTHER_COL_GAP)
    local zero = wsr_vec2(0, 0)
    if not (size and zero) then return nil end

    local dir = (type(gui.StackDirection) == "table") and gui.StackDirection.VERTICAL or nil
    if dir ~= nil and gui.Layout then
        local ok, lay = protected_call(gui.Layout, gui.ControlID(id), zero, size, dir)
        if ok and lay then
            local off = wsr_vec2(0, OTHER_COL_GAP)
            if off then lay.stackOffset = off end
            local okA = protected_call(lay.Add, lay, top)
            local okB = protected_call(lay.Add, lay, bottom)
            if okA and okB then return lay end
        end
    end
    if gui.MakeStackedGroups then
        local ok, built = protected_call(gui.MakeStackedGroups,
            gui.ControlID(id .. "_stack"), size, { top, bottom })
        if ok and built then return built end
    end
    return nil
end

local function build_ui()
    if g_ui then return end
    if not gui or not gui.ctx then return end
    local parent=WSR_SKIN_PARENT or (gui.ctx and gui.ctx:Find("lua>groups")); if parent==nil then return end
    -- REDUCED = the "tabs with sub-tabs" mode (we are in a sub-tab), same as in the Maps tab.
    -- Panel width must match the column width OTHER_COL_W, otherwise panels get clipped or leave a gap.
    local wm=(gui.GroupWidthMode and gui.GroupWidthMode.DEFAULT) or 0

    -- About panel
    if gui.Label then
        local about_lines = {
            "Recolors weapon skins live in-game.",
            " ",
            "How to use:",
            "1. Join a map (main menu won't show changes)",
            "2. Equip a skin with custom pattern support",
            "   (not all skins are supported)",
            "3. Adjust the color pickers — live preview",
            "4. Settings save to config automatically",
            "   and restore on next load.",
            " ",
            "Note: Panorama preview is unaffected —",
            "changes only visible in-game.",
            " ",
            "experimental* — enables extra effect sliders",
            "(glitter, iridescence, etc.). May do nothing",
            "on some weapons — depends on the skin.",
        }
        local about_h = #about_lines * 20 - 85
        local abt=gui.Group(gui.ControlID("wsr_about_grp"), "How to use", about_h, wm)
        if abt then
            for _, line in ipairs(about_lines) do
                local lbl = gui.Label(gui.ControlID("wsr_abt_"..line:sub(1,8):gsub("%W","_")), line)
                if lbl then abt:Add(lbl) end
            end
            local cg = wsr_build_chams_group()
            local col = wsr_make_column("cm_other_col1_3p", abt, cg,
                                        about_h + (CHAMS_PANEL_H or 187))
            if col then
                parent:Add(col)
            else
                parent:Add(abt)
                if cg then parent:Add(cg) end   -- stacking not supported: at least do not lose the panel
            end
            protected_call(abt.Reset, abt)
        end
    end


    local ROW_PX = 30
    local PANEL_ROWS = 7   -- active skin, experimental settings, colors, glove 1-4, glove 5-8, reset gun, reset gloves
    local WSR_H = PANEL_ROWS*ROW_PX + 25
    local grp=gui.Group(gui.ControlID("wsr_grp"), "Weapon Skin Recolor", WSR_H, wm); if grp==nil then return end
    -- SECOND COLUMN: Weapon Skin Recolor with Friend Whitelist under it. Same scheme as the first
    -- column (How to use + Chams): a vertical stack, width taken from the panel itself.
    -- The whitelist panel is built by the HOST (WLF_BUILD_UI(true) returns the group without adding it
    -- to the parent), otherwise its own tick would place it as a separate third column in the row.
    do
        local wg = wsr_build_wlf_group()
        local col2 = wsr_make_column("cm_other_col2_3p", grp, wg, WSR_H + (WLF_PANEL_H or 187))
        if col2 then
            parent:Add(col2)
        else
            parent:Add(grp)
            if wg then parent:Add(wg) end   -- stacking not supported: at least do not lose the panel
        end
    end
    g_active_lbl=gui.Label and gui.Label(gui.ControlID("wsr_lbl"), "active skin: ?") or nil
    if g_active_lbl then grp:Add(g_active_lbl) end
    g_fxcb=gui.Checkbox and gui.Checkbox(gui.ControlID("wsr_fxen")) or nil
    if g_fxcb then
        local TIP="MAY NOT WORK AFTER CS2 UPDATE"
        g_fxcb.tooltip=TIP
        local mc=gui.MakeControl("experimental*", g_fxcb)
        if mc then mc.tooltip=TIP; grp:Add(mc) end
    end

    for i=1,4 do pickers[i]=gui.ColorPicker(gui.ControlID("wsr_c"..i), false) end
    local fxp
    local crow=gui.MakeControl("colors", pickers[1])
    if crow and crow.Add then
        crow:Add(pickers[2]); crow:Add(pickers[3]); crow:Add(pickers[4])
        local settings=gui.Settings and gui.Settings(gui.ControlID("wsr_fxset"))
        if settings then crow:Add(settings); fxp=settings; g_fxset=settings end
        grp:Add(crow)
    else
        for i=1,4 do grp:Add(gui.MakeControl("color"..(i-1), pickers[i])) end
    end
    if fxp==nil then  
        local fg=gui.Group(gui.ControlID("wsr_fxgrp"), "Effects (0-100)", (#EFFECTS+1)*ROW_PX, wm)
        if fg then parent:Add(fg); fxp=fg end
    end
    if fxp then
        for _,e in ipairs(EFFECTS) do
            local s=gui.Slider(gui.ControlID("wsr_fx_"..e.n), 0, 100, {"%.0f%%"})
            if s then fxp:Add(gui.MakeControl(e.n, s)); fxsliders[e.n]=s end
        end
        if fxp.Reset then fxp:Reset() end
    end

    for i=1,8 do gpickers[i]=gui.ColorPicker(gui.ControlID("wsr_g"..i), false) end
    local function grow(label,a,b,c,d)   -- 4 pickers per row, returns the row
        local r=gui.MakeControl(label, gpickers[a])
        if r and r.Add then r:Add(gpickers[b]); r:Add(gpickers[c]); r:Add(gpickers[d]); grp:Add(r); return r
        else for _,i in ipairs({a,b,c,d}) do grp:Add(gui.MakeControl("tint"..i, gpickers[i])) end; return nil end
    end
    local grow1=grow("glove tint 1-8", 1,2,3,4)
    grow("", 5,6,7,8)
    local gfxp
    if grow1 and grow1.Add then local gset=gui.Settings and gui.Settings(gui.ControlID("wsr_gfxset"))
        if gset then grow1:Add(gset); gfxp=gset; g_gfxset=gset end end
    if gfxp==nil then gfxp=grp end
    for _,e in ipairs(GLOVE_EFFECTS) do
        local s=gui.Slider(gui.ControlID("wsr_gfx_"..e.n), 0, 100, {"%.0f%%"})
        if s then gfxp:Add(gui.MakeControl(e.n, s)); gfxsliders[e.n]=s end
    end
    -- reset buttons at the END of the panel
    local brs=gui.Button(gui.ControlID("wsr_reset"), "reset gun")
    grp:Add(brs); brs:AddCallback(function() reset_active() end)
    local gbr=gui.Button(gui.ControlID("wsr_greset"), "reset gloves")
    grp:Add(gbr); gbr:AddCallback(function() reset_gloves() end)
    protected_call(grp.Reset, grp)
    -- Reset the host so the new group lays out, BUT never reset the injected sub-tab itself
    -- (resetting a runtime-injected tab crashes on some builds; the map-manager tab code
    -- avoids it too). Only the legacy lua>groups fallback host gets a reset.
    if parent ~= WSR_SKIN_PARENT then
        protected_call(parent.Reset, parent)
    end
    g_ui=true
end


local g_lblt=0
local function tick_discovery()
    local dn=tonumber(DiscN[0]) or 0
    if dn>0 then
        if dn>128 then dn=128 end
        for i=0,dn-1 do
            local base=DISC_BASE+i*32
            local np=tonumber(ffi.cast("wsr_u64*", base)[0]) or 0
            local nm=rcstr(np, 48)
            if nm then local f=ffi.cast("wsr_f32*", base+8)
                g_params[nm]=f[0]
                if nm:find("^g_vColor%d$") or nm:find("^g_vColorTint%d$") then g_native_col[nm]={f[0],f[1],f[2]} end
            end
        end
        DiscN[0]=0
    end
end
local function tick_sync()
    g_lblt=g_lblt+1
    -- UI-freeze window: gates picker->g_config writes. Unfreezes after FREEZE_SEC (wall-clock).
    if not g_unfrozen then
        local ts=(utils and utils.GetUnixTime) and utils.GetUnixTime() or nil
        if type(ts)~="number" then
            g_unfrozen=true          -- no time source -> do not freeze (safer than getting stuck)
        else
            if g_load_ts==nil then g_load_ts=ts end
            if ts-g_load_ts>=FREEZE_SEC then
                g_unfrozen=true
                g_picker_skin=nil; g_glove_loaded=false   -- force-reload colors from the config into the pickers
                log("ui-freeze ended -> pickers forced to config colors")
            end
        end
    end
    local frozen=not g_unfrozen
    if g_fxcb and g_fxcb.GetValue then local v=g_fxcb:GetValue(); g_fx_enabled=(v and v.Get and v:Get()==true) or false end
    if g_fx_enabled~=g_fx_vis then g_fx_vis=g_fx_enabled
        if g_fxset and g_fxset.SetVisible then g_fxset:SetVisible(g_fx_enabled) end
        if g_gfxset and g_gfxset.SetVisible then g_gfxset:SetVisible(g_fx_enabled) end
        g_picker_skin=nil; g_glove_loaded=false  
        g_done={}                                  
    end
    if g_ui and g_lblt%8==0 then
        -- WEAPON: weapon changed -> load colors + effects from the config
        local p,sk=active_wep()
        if sk~=g_picker_skin then
            g_picker_skin=sk; g_active_ptr=p
            local cfg=sk and g_config[sk]
            if cfg and cfg.cols then for i=1,4 do local cc=cfg.cols[i] or {0,0,0}; pk_set(pickers,i, cc[1],cc[2],cc[3]) end
            else for i=1,4 do local nc=g_native_col["g_vColor"..(i-1)]; if nc then pk_set(pickers,i, nc[1],nc[2],nc[3]) end end end  -- not configured -> native colors
            g_last_pick={}; for i=1,4 do local r,g,b=pk_get(pickers,i); g_last_pick[i]={r or 0,g or 0,b or 0} end
            g_fx_last={}
            if g_fx_enabled then for _,e in ipairs(EFFECTS) do
                local val=(cfg and cfg.fx and cfg.fx[e.n]) or 0   -- 0 = default (no override)
                local pos=v2s(e,val); fx_setpos(e,pos); g_fx_last[e.n]=pos
            end end
            if g_active_lbl and g_active_lbl.SetText then
                g_active_lbl:SetText(string.format("skin: %s%s", sk or "?", cfg and " [cfg]" or " [new]")) end
        elseif sk then
            g_active_ptr=p
            local cchg=false
            for i=1,4 do local r,g,b=pk_get(pickers,i); local lp=g_last_pick[i]
                if r~=nil and (lp==nil or r~=lp[1] or g~=lp[2] or b~=lp[3]) then g_last_pick[i]={r,g,b}; cchg=true end end
            local fchg=false
            if g_fx_enabled then for _,e in ipairs(EFFECTS) do local raw=fx_read(e)
                if raw~=nil and raw~=g_fx_last[e.n] then g_fx_last[e.n]=raw; fchg=true end end end
            if (cchg or fchg) and not frozen then
                local cur=g_config[sk] or {}
                local cols={}; for i=1,4 do local r,g,b=pk_get(pickers,i); cols[i]={(r or 0)/255,(g or 0)/255,(b or 0)/255} end
                cur.cols=cols
                if g_fx_enabled then cur.fx={}   -- 0 = default: only sliders > 0 are overridden
                    for _,e in ipairs(EFFECTS) do local raw=fx_read(e)
                        if raw~=nil and raw>0.5 then cur.fx[e.n]=s2v(e,raw) end end
                end
                cur.enabled=true
                g_config[sk]=cur; g_save_in=DEBOUNCE; g_wep_dirty=true
            end
        end
        if gpickers[1]~=nil then
            local gk=glove_key()
            if gk~=g_glove_key then g_glove_key=gk; g_glove_loaded=false end
            if gk and not g_glove_loaded then
                g_glove_loaded=true
                local gc=g_config[gk]
                if gc and gc.cols then for i=1,8 do local cc=gc.cols[i] or {0,0,0}; pk_set(gpickers,i, cc[1],cc[2],cc[3]) end end
                g_glove_last={}; for i=1,8 do local r,g,b=pk_get(gpickers,i); g_glove_last[i]={r or 0,g or 0,b or 0} end
                g_glove_fx_last={}
                if g_fx_enabled then for _,e in ipairs(GLOVE_EFFECTS) do
                    local val=(gc and gc.fx and gc.fx[e.n]) or 0   -- 0 = default
                    local pos=v2s(e,val); fx_setpos(e,pos,gfxsliders); g_glove_fx_last[e.n]=pos
                end end
            elseif gk then
                local cchg=false
                for i=1,8 do local r,g,b=pk_get(gpickers,i); local lp=g_glove_last[i]
                    if r~=nil and (lp==nil or r~=lp[1] or g~=lp[2] or b~=lp[3]) then g_glove_last[i]={r,g,b}; cchg=true end end
                local fchg=false
                if g_fx_enabled then for _,e in ipairs(GLOVE_EFFECTS) do local raw=fx_read(e,gfxsliders)
                    if raw~=nil and raw~=g_glove_fx_last[e.n] then g_glove_fx_last[e.n]=raw; fchg=true end end end
                if (cchg or fchg) and not frozen then
                    local cur=g_config[gk] or {}
                    local cols={}; for i=1,8 do local r,g,b=pk_get(gpickers,i); cols[i]={(r or 0)/255,(g or 0)/255,(b or 0)/255} end
                    cur.cols=cols
                    if g_fx_enabled then cur.fx={}   -- 0 = default
                        for _,e in ipairs(GLOVE_EFFECTS) do local raw=fx_read(e,gfxsliders)
                            if raw~=nil and raw>0.5 then cur.fx[e.n]=s2v(e,raw) end end
                    end
                    cur.enabled=true
                    g_config[gk]=cur; g_save_in=DEBOUNCE; g_glove_dirty=true
                end
            end
        end
    end
    if g_save_in>0 then
        g_save_in=g_save_in-1
        if g_save_in==0 then
            local changed=save_config()
            if changed then   -- re-bake only if the config actually changed (otherwise an extra cycle + spam)
                if g_wep_dirty and g_active_ptr>=MIN_PTR then g_done[g_active_ptr]=nil end  -- re-bake the weapon in hand
                if g_glove_dirty then local gi=glove_item(); if gi>=MIN_PTR then g_done[gi]=nil end end  -- re-bake the glove
                log("autosave -> rebake")
            end
            g_wep_dirty=false; g_glove_dirty=false
        end
    end
end
local function tick_apply()
    if not installed then return end
    local c=tonumber(Cc[0]) or 0

    -- GLOVES: glove ptr change = team change
    do
        local gi=glove_item()
        local gk=glove_key()
        if gi~=g_last_glove or gk~=g_glove_apply_key then
            g_last_glove=gi; g_glove_apply_key=gk
            if gi>=MIN_PTR then
                g_done[gi]=nil
            end
        end
    end

    if g_st=="idle" and g_auto then
        local pw=pawn0()
        local pp=(pw and pw.GetPointer) and n_of(pw:GetPointer()) or 0
        if pp~=g_last_pawn then g_last_pawn=pp; g_done={} end   -- new life/map -> recolor again
        -- respawn: CS2 reuses addresses (ptr does not change) -> detect the HP dead->alive transition
        local hp=0; if pw then local acc=pw.m_iHealth; if acc~=nil and acc.Get~=nil then hp=acc:Get() or 0 end end
        if hp>0 and g_last_hp<=0 then g_done={} end
        g_last_hp=hp
        g_scant=g_scant+1
        if g_scant>=45 then g_scant=0
            local pend={}
            local seen={}; local nskin={}
            for _,it in ipairs(my_weapons()) do
                seen[it.ptr]=true; nskin[it.ptr]=it.skin
                -- new weapon / skin changed at the same address -> recolor
                if not g_wep_seen[it.ptr] or g_wep_skin[it.ptr]~=it.skin then g_done[it.ptr]=nil end
                local cfg=g_config[it.skin]
                if cfg and cfg.enabled and not g_done[it.ptr] then pend[#pend+1]=it end
            end
            g_wep_seen=seen; g_wep_skin=nskin
            local gi=glove_item(); local gk=glove_key(); local gc=gk and g_config[gk]
            if gi>=MIN_PTR and gc and gc.enabled and not g_done[gi] then
                pend[#pend+1]={isglove=true, ptr=gi, skin=gk} end
            if #pend>0 then g_q=pend; g_qi=0; g_restore=false; g_st="step" end
        end
    end

    if g_st=="step" then
        g_qi=g_qi+1
        local it=g_q[g_qi]
        if it==nil then g_st="idle"; Ovr[0]=0; g_cur=nil
        else
            g_cur=it
            local cfg=(not g_restore) and g_config[it.skin] or nil
            local ncol=it.isglove and 8 or 4
            if cfg and cfg.enabled and cfg.cols then
                for s=0,ncol-1 do local col=cfg.cols[s+1] or {0,0,0}
                    set_slot(s, col[1],col[2],col[3], it.isglove and 0.0 or 1.0) end  -- gloves: tint alpha=0
                Ovr[0]=1
            else
                Ovr[0]=0   -- not configured or restore -> original
            end
            ovr_set((g_fx_enabled and cfg and cfg.fx) or {})
            skinsys_invalidate() 
            if it.isglove then
                glove_mark_dirty()
            else
                g_release(ffi.cast("void*", it.ptr+0x608), 1)
                g_build(ffi.cast("void*", it.ptr), 0, nil, nil)
            end
            g_wbase=c; g_wlast=c; g_stable=0; g_wait=(it.isglove and 120 or 30); g_st="wait"
        end
    elseif g_st=="wait" then
        if c>g_wlast then g_wlast=c; g_stable=0 else g_stable=g_stable+1 end
        g_wait=g_wait-1
        local glove=g_cur and g_cur.isglove
        if g_wait<=0 or ((not glove) and c>g_wbase and g_stable>=5) then
            Ovr[0]=0
            if (not g_restore) and g_cur and g_config[g_cur.skin] and g_config[g_cur.skin].enabled then
                g_done[g_cur.ptr]=true
            end
            g_st="step"
        end
    end
end
-- 🛑 g_dead = one of the functions was not found. No hook, no ticks, no UI: they all end up calling
-- g_release/g_build/g_sys, whose address is garbage in that case. return stops ONLY this block
-- (it is in its own protected_call); the other Map manager blocks keep running.
if g_dead then
    print(TAG.." skin recolor disabled: "..tostring(g_dead).." not found (game update)")
    return
end
local present=events and events.presentQueue
if present and present.Add then present:Add(function()
    if not g_ui then build_ui() end
    tick_discovery(); tick_sync(); tick_apply()
end)
else error("[wsr] events.presentQueue unavailable") end

install()   -- auto-install the hook on load -> auto-recolor works without pressing APPLY
if wfx_install then wfx_install() end   -- writer-FX hook (2nd consumer of the FX table, if the writer prologue matched)
function __shutdown() uninstall(); if wfx_uninstall then wfx_uninstall() end end
end)

-- ================== Post-processing Engine (bloom + tonemap + local contrast) ==================
-- UI (checkboxes + gear settings, under Fog in Visuals) is built inside create_elements_a_mirror_ui
-- above; this block is the engine. Self-contained (own FFI typedefs/helpers, no cross-scope locals)
-- like the skin-recolor block above -- it only shares state with the UI through the globals
-- CM_BLOOM_CTRLS and CM_POSTFX_CTRLS (Lua globals resolve at call time, so load order is irrelevant).
--
-- This engine writes NOTHING of the map's (patching a render gate and writing into structures
-- owned by the MAP every frame caused crashes when walking and fps drops). It hooks materialsystem2 instead:




--   hook #1 -- RETURN of FUN_180058450 (the post-processing blender). The engine has just finished
--             filling its output struct; we overwrite our own fields in it, last word, on its own
--             thread. No volumes, no pointer guessing, no cached pointers, no gate patch.
--   hook #2 -- ENTRY of FUN_18005abd0 (the tonemap curve compiler). It bakes the 15 blended tonemap
--             floats into shader constants and COMMITS them, so editing the output afterwards is
--             pointless (out+0x10 is a handle, not a pointer). Instead we rewrite its input (rdx)
--             before it runs, and Valve's own code derives 2^exposure, the white-point normaliser
--             and the rest from OUR numbers.
-- Offsets in the blender's output are byte offsets read off Valve's own code
-- (FUN_18005b090 stores hasBloom at +0x24 and the 0x88 bloom block at +0x28; FUN_18005bb80 stores
-- hasLocalContrast at +0xd5 and 5 floats at +0xd8). Field offsets INSIDE each block are resolved
-- live from SchemaSystem BY NAME -- never enumerated (walking the field array runs off the end of the
-- class into the next one, whose offsets restart at 0) and never hardcoded.
-- Fog scattering and the tonemap shadow/highlight split were dropped:
-- nothing reads the fog block, and the split made no visible difference on this build.
protected_call(function()

if not ffi then return end
protected_call(ffi.cdef, [[
    typedef unsigned char      cbl_u8;
    typedef unsigned short     cbl_u16;
    typedef unsigned int       cbl_u32;
    typedef unsigned long long cbl_u64;
    typedef unsigned long long CBL_SIZE_T;
    typedef void* (*cbl_createiface)(const char* name, int* rc);
    typedef void* (__fastcall *cbl_findscope)(void* self, const char* module, void* z);
    typedef void  (__fastcall *cbl_findclass)(void* self, void** out, const char* name);
]])

local TAG = "[cm-postfx]"
local function log(...) if CM_VERBOSE then print(TAG, ...) end end
local MIN_PTR, MAX_PTR = 0x100000000, 0x7FFFFFFFFFFF

local fe = utils and (utils.FindExport or utils.find_export)
local FP = utils and utils.FindPattern
if not fe then log("no FindExport -- engine disabled"); return end

local function api(mod, name, cast)
    local a = tonumber(fe(mod, name) or 0)
    if a == 0 then a = tonumber(fe("KernelBase.dll", name) or 0) end
    if a == 0 then return nil end
    return ffi.cast(cast, a)
end
local VQ = api("kernel32.dll", "VirtualQuery", "CBL_SIZE_T(__stdcall*)(const void*,void*,CBL_SIZE_T)")
local VP = api("kernel32.dll", "VirtualProtect", "int(__stdcall*)(void*,CBL_SIZE_T,cbl_u32,cbl_u32*)")
local VA = api("kernel32.dll", "VirtualAlloc", "void*(__stdcall*)(void*,CBL_SIZE_T,cbl_u32,cbl_u32)")

local g_mbi = ffi.new("cbl_u8[48]")
local function region_ok(a, size)
    if type(a) ~= "number" or a ~= a or a < MIN_PTR or a > MAX_PTR then return false end
    if VQ == nil then return true end
    VQ(ffi.cast("const void*", a), g_mbi, 48)
    local base = tonumber(ffi.cast("cbl_u64*", ffi.cast("cbl_u64", g_mbi) + 0)[0]) or 0
    local rsz  = tonumber(ffi.cast("cbl_u64*", ffi.cast("cbl_u64", g_mbi) + 0x18)[0]) or 0
    local st   = ffi.cast("cbl_u32*", ffi.cast("cbl_u64", g_mbi) + 0x20)[0]
    local pr   = ffi.cast("cbl_u32*", ffi.cast("cbl_u64", g_mbi) + 0x24)[0]
    if st ~= 0x1000 then return false end
    if (pr % 0x100) == 0x01 then return false end
    if pr >= 0x100 then return false end
    if base == 0 or (a + size) > (base + rsz) then return false end
    return true
end
local function n_of(p) if p == nil then return 0 end return tonumber(ffi.cast("cbl_u64", ffi.cast("void*", p))) or 0 end
local function r64(a) if not region_ok(a, 8) then return 0 end return tonumber(ffi.cast("cbl_u64*", a)[0]) or 0 end
local function rb(a, i) return ffi.cast("cbl_u8*", a)[i] end
local function wb(a, i, v) ffi.cast("cbl_u8*", a)[i] = v end
local function rstr(a, c)
    if a == 0 or not region_ok(a, 1) then return nil end
    local p = ffi.cast("cbl_u8*", a); local o = {}
    for i = 0, (c or 96) - 1 do
        local b = p[i]; if b == 0 then break end
        if b < 0x20 or b > 0x7E then return nil end
        o[#o + 1] = string.char(b)
    end
    if #o == 0 then return nil end
    return table.concat(o)
end
local g_fb = ffi.new("float[1]")
local function fbits(v) g_fb[0] = v; return tonumber(ffi.cast("cbl_u32*", g_fb)[0]) end
local function put_u32(a, off, v)
    v = v % 0x100000000
    for i = 0, 3 do wb(a, off + i, math.floor(v / 2 ^ (8 * i)) % 256) end
end
local function put_u64(a, off, v)
    for i = 0, 7 do wb(a, off + i, math.floor(v / 2 ^ (8 * i)) % 256) end
end

-- ── schema: field offsets INSIDE each parameter struct, resolved BY NAME ──────────────────────
-- By name on purpose. Enumerating a class's fields walks off the end of it (the schema keeps every
-- class's fields in ONE array and the next class's offsets restart at 0) -- that bug shipped once and
-- showed up as "the sliders are shuffled". A by-name lookup stops at the first match and cannot
-- over-run. PostProcessing*Parameters_t live in materialsystem2's scope, not client.dll's.
local scope_mat, FindClass
do
    local ci = tonumber(fe("schemasystem.dll", "CreateInterface") or 0)
    if ci ~= 0 then
        local CI = ffi.cast("cbl_createiface", ci)
        local ss = CI("SchemaSystem_001", nil); local ssn = n_of(ss)
        if ssn >= MIN_PTR then
            local FindScope = ffi.cast("cbl_findscope", r64(r64(ssn) + 13 * 8))
            scope_mat = FindScope(ss, "materialsystem2.dll", nil)
            local scn = n_of(scope_mat)
            if scn >= MIN_PTR then FindClass = ffi.cast("cbl_findclass", r64(r64(scn) + 2 * 8)) end
        end
    end
end
local FIELDS_CANDS = { 0x28, 0x30, 0x38, 0x20, 0x40, 0x18, 0x48 }
local function is_field_name(s) return s ~= nil and #s >= 2 and #s <= 80 and s:sub(1, 2) == "m_" end
local function schema_offset(cn, fn)
    if not FindClass or n_of(scope_mat) < MIN_PTR then return nil end
    local out = ffi.new("void*[1]"); out[0] = nil
    FindClass(scope_mat, out, cn)
    local ci = n_of(out[0]); if ci < MIN_PTR then return nil end
    for _, off in ipairs(FIELDS_CANDS) do
        local p = r64(ci + off)
        if p >= MIN_PTR and is_field_name(rstr(r64(p), 96)) then
            for i = 0, 8191 do
                local f = p + i * 0x20
                local nm = rstr(r64(f), 96)
                if not is_field_name(nm) then break end
                if nm == fn then return tonumber(ffi.cast("cbl_u16*", f + 0x10)[0]) end
            end
        end
    end
    return nil
end

-- Byte offsets in the blender's OUTPUT struct. Not schema types (this struct is the blender's own
-- output, so there is nothing to resolve them by name from) -- they are literally what Valve's code
-- stores, see the header comment. Everything outside these ranges is something the engine just
-- computed and we must never touch: the tonemap handle (+0x10), the vignette pointer (+0x18), the
-- texture handles (+0xB0/+0xB8), the exposure block (+0xC0..).
local OUT_HASBLOOM, OUT_BLOOM, BLOOM_SIZE = 0x24, 0x28, 0x88
local OUT_HASLC,    OUT_LC,    LC_SIZE    = 0xd5, 0xd8, 0x14
local TONE_SIZE = 0x20      -- only the always-on half of the curve (0x0..0x1c); the rest is gated

local RANGES = { { OUT_HASBLOOM, OUT_HASBLOOM + 1 }, { OUT_BLOOM, OUT_BLOOM + BLOOM_SIZE },
                 { OUT_HASLC, OUT_HASLC + 1 }, { OUT_LC, OUT_LC + LC_SIZE } }
local function in_range(off, sz)
    for _, r in ipairs(RANGES) do
        if off >= r[1] and off + sz <= r[2] then return true end
    end
    return false
end

local BLOOM_FIELDS = {   -- CM_BLOOM_CTRLS.globals key -> schema field
    strength  = "m_flBloomStrength",
    screenstr = "m_flScreenBloomStrength",
    blurstr   = "m_flBlurBloomStrength",
    threshold = "m_flBloomThreshold",
    threshw   = "m_flBloomThresholdWidth",
}
local F = {}           -- resolved absolute offsets in the out struct
local off_ok = false
local function ensure_offsets()
    if off_ok then return true end
    local t = {}
    for key, fname in pairs(BLOOM_FIELDS) do
        local o = schema_offset("PostProcessingBloomParameters_t", fname)
        if not o or o + 4 > BLOOM_SIZE then return false end
        t[key] = OUT_BLOOM + o
    end
    local bw = schema_offset("PostProcessingBloomParameters_t", "m_flBlurWeight")
    local bt = schema_offset("PostProcessingBloomParameters_t", "m_vBlurTint")
    -- validate the FULL extent of the arrays, not just their first element
    if not (bw and bt and bw + 5 * 4 <= BLOOM_SIZE and bt + 5 * 12 <= BLOOM_SIZE) then return false end
    t.blurw, t.blurt = OUT_BLOOM + bw, OUT_BLOOM + bt
    F = t
    off_ok = true
    log(string.format("schema ok: strength=0x%X blurWeight=0x%X blurTint=0x%X", F.strength, F.blurw, F.blurt))
    return true
end
-- Resolve a named field of a block on demand (tonemap/local contrast); cached.
-- Returns the RAW offset INSIDE the struct; the caller adds whatever base it needs. The same field
-- is looked up with TWO different bases (seeding reads it at out+0xec, applying writes it at rdx+0,
-- because hook #2 writes into the param array itself), so caching base+offset would let whichever
-- caller ran first poison the other. Keep the base out of here.



local g_fcache = {}
local function field_off(cls, fname, size)
    local k = cls .. fname
    local v = g_fcache[k]
    if v ~= nil then return v end
    local o = schema_offset(cls, fname)
    if not o or o < 0 or o + 4 > size then g_fcache[k] = false; return false end
    g_fcache[k] = o
    return o
end

-- ══════════════ hooks ══════════════
-- Signatures anchor AFTER the stolen bytes so they still match while our own patch sits on the
-- prologue -- that is what makes self-heal possible (a trampoline leaked by a run that crashed would
-- otherwise be unfindable). Both anchors verified unique in the file on disk; the stolen bytes were
-- verified from that same file with capstone and are position-independent (no RIP, no branch).
local ANCHOR1 = "48 89 48 08 55 41 57 48 8D A8 18 FB FF FF 48 81 EC D8 05 00 00"
local ORIG1   = { 0x48, 0x8B, 0xC4, 0x48, 0x89, 0x50, 0x10 }             -- mov rax,rsp / mov [rax+0x10],rdx
local ANCHOR2 = "48 89 6C 24 18 48 89 74 24 20 41 56 48 81 EC B0 00 00 00"
local ORIG2   = { 0x48, 0x89, 0x5C, 0x24, 0x10 }                          -- mov [rsp+0x10], rbx
local STEAL1, STEAL2 = 7, 5

local HOOK1_OFF, TRAMP1_OFF, PARAMS1_OFF = 0x000, 0x100, 0x800
local HOOK2_OFF, TRAMP2_OFF, PARAMS2_OFF = 0x200, 0x300, 0xC00
local CAVE_SIZE, MAX_ENTRIES = 0x2000, 120

local g_fn1, g_fn2, g_cave, g_params1, g_params2 = 0, 0, 0, 0, 0
local g_armed = false

-- One RWX page within +/-128MB of the target so a 5-byte E9 rel32 reaches it. The parameter tables
-- live in the SAME page: engine-lifetime memory the Lua GC can never touch or move.
local function alloc_near(target, size)
    if not VA then return 0 end
    for delta = 0, 0x08000000, 0x10000 do
        local cands = (delta == 0) and { target } or { target - delta, target + delta }
        for _, c in ipairs(cands) do
            if c > 0x10000 then
                local aligned = c - (c % 0x10000)
                local pn = n_of(VA(ffi.cast("void*", aligned), size, 0x3000, 0x40))
                if pn ~= 0 then return pn end
            end
        end
    end
    return 0
end

local g_oldprot = ffi.new("cbl_u32[1]")
local g_qw = ffi.new("cbl_u64[1]")
local g_qwb = ffi.cast("cbl_u8*", g_qw)
-- Patch and restore are ONE aligned 8-byte store. Both entries are 16-byte aligned, so that store is
-- atomic on x86: a render thread entering the function while we arm sees either the whole old
-- prologue or the whole new one, never a half-written jump. Byte-by-byte writes leave a real window
-- where an executing thread reads a torn instruction.
local function store_qword(addr, bytes8)
    if addr % 8 ~= 0 then return false end
    for i = 0, 7 do g_qwb[i] = bytes8[i + 1] end
    if VP then VP(ffi.cast("void*", addr), 8, 0x40, g_oldprot) end
    ffi.cast("cbl_u64*", addr)[0] = g_qw[0]
    if VP then VP(ffi.cast("void*", addr), 8, g_oldprot[0], g_oldprot) end
    return true
end

local function resolve_hooked_fn(anchor, orig, label)
    if not FP then return 0 end
    local m = tonumber(FP("materialsystem2.dll", anchor) or 0) or 0
    if m == 0 then log(label .. ": anchor not found -- build changed?") return 0 end
    local fn = m - #orig
    if not region_ok(fn, 16) then return 0 end
    if fn % 8 ~= 0 then log(string.format("%s: 0x%X not 8-aligned -- refusing", label, fn)) return 0 end
    if rb(fn, 0) == 0xE9 then
        local b = {}
        for i = 1, 8 do b[i] = orig[i] or rb(fn, i - 1) end
        if not store_qword(fn, b) then return 0 end
        log(string.format("%s: self-healed a leaked hook at 0x%X", label, fn))
    end
    for i = 1, #orig do
        if rb(fn, i - 1) ~= orig[i] then
            log(string.format("%s: prologue mismatch at +%d -- refusing", label, i - 1)); return 0
        end
    end
    log(string.format("%s @0x%X", label, fn))
    return fn
end

local function build_cave()
    if g_cave ~= 0 then return true end
    if g_fn1 == 0 then g_fn1 = resolve_hooked_fn(ANCHOR1, ORIG1, "blender FUN_180058450") end
    if g_fn1 == 0 then return false end
    local cave = alloc_near(g_fn1, CAVE_SIZE)
    if cave == 0 then log("alloc_near failed") return false end

    local params1 = cave + PARAMS1_OFF
    for i = 0, 0x1F do wb(params1, i, 0) end          -- counts 0 -> the hook is inert the instant it goes live
    local t1 = cave + TRAMP1_OFF
    for i = 1, STEAL1 do wb(t1, i - 1, ORIG1[i]) end
    wb(t1, STEAL1, 0xFF); wb(t1, STEAL1 + 1, 0x25)
    put_u32(t1, STEAL1 + 2, 0); put_u64(t1, STEAL1 + 6, g_fn1 + STEAL1)   -- jmp [rip+0]; dq fn+7

    -- hook #1: the new function. Calls the original, then rewrites our fields in the finished output.
    -- rax and every xmm are untouched after the call, so whatever the original returns survives; only
    -- volatile rcx/rdx/r8/r9/r10/r11 are used. Entry list: {u32 offset, u32 value}, dwords then bytes.
    local h1 = cave + HOOK1_OFF
    local sc1 = {
        0x48,0x83,0xEC,0x38,                    -- sub  rsp, 0x38       (call lands 16-aligned)
        0x48,0x89,0x54,0x24,0x20,               -- mov  [rsp+0x20], rdx     save out ptr
        0xE8,0x00,0x00,0x00,0x00,               -- call trampoline1
        0x48,0x8B,0x54,0x24,0x20,               -- mov  rdx, [rsp+0x20]     out ptr back
        0x49,0xBA,0,0,0,0,0,0,0,0,              -- mov  r10, PARAMS1
        0x49,0xFF,0x42,0x08,                    -- inc  qword [r10+8]       hits++
        0x49,0x89,0x52,0x10,                    -- mov  [r10+0x10], rdx     lastOut
        0x4D,0x8D,0x5A,0x18,                    -- lea  r11, [r10+0x18]
        0x45,0x8B,0x0A,                         -- mov  r9d, [r10]          nDword
        0x45,0x85,0xC9,                         -- test r9d, r9d
        0x74,0x15,                              -- jz   .bytes
        0x45,0x8B,0x03,                         -- .dloop: mov r8d, [r11]
        0x41,0x8B,0x4B,0x04,                    --         mov ecx, [r11+4]
        0x42,0x89,0x0C,0x02,                    --         mov [rdx+r8], ecx
        0x49,0x83,0xC3,0x08,                    --         add r11, 8
        0x41,0x83,0xE9,0x01,                    --         sub r9d, 1
        0x75,0xEB,                              --         jnz .dloop
        0x45,0x8B,0x4A,0x04,                    -- .bytes: mov r9d, [r10+4] nByte
        0x45,0x85,0xC9,                         --         test r9d, r9d
        0x74,0x15,                              --         jz .done
        0x45,0x8B,0x03,                         -- .bloop: mov r8d, [r11]
        0x41,0x8B,0x4B,0x04,                    --         mov ecx, [r11+4]
        0x42,0x88,0x0C,0x02,                    --         mov [rdx+r8], cl
        0x49,0x83,0xC3,0x08,                    --         add r11, 8
        0x41,0x83,0xE9,0x01,                    --         sub r9d, 1
        0x75,0xEB,                              --         jnz .bloop
        0x48,0x83,0xC4,0x38,                    -- .done:  add rsp, 0x38
        0xC3,                                   --         ret
    }
    for i = 1, #sc1 do wb(h1, i - 1, sc1[i]) end
    put_u32(h1, 10, (t1 - (h1 + 14)) % 0x100000000)    -- call rel32: E8 at +9, next insn at +14
    put_u64(h1, 21, params1)                           -- imm64 of `mov r10, PARAMS1` (49 BA at +19)
    g_cave, g_params1 = cave, params1

    -- hook #2 (tonemap) -- optional: if its signature ever breaks, bloom/contrast must keep working.
    -- Different shape: we must write BEFORE the original runs, so there is no frame and no return
    -- wrap -- write, then TAIL JMP into the trampoline. Register budget is the catch: at entry
    -- rcx = this, rdx = the 15 floats, r8b = a flag, so hook #1's r8 scratch would destroy an
    -- argument. Free here: rax (no return value yet) and r9-r11. rcx is pushed/popped around the
    -- loop and the jz skips the push, so the pop is never orphaned.
    if g_fn2 == 0 then g_fn2 = resolve_hooked_fn(ANCHOR2, ORIG2, "tonemap FUN_18005abd0") end
    if g_fn2 ~= 0 then
        local params2 = cave + PARAMS2_OFF
        for i = 0, 0x1F do wb(params2, i, 0) end
        local t2 = cave + TRAMP2_OFF
        for i = 1, STEAL2 do wb(t2, i - 1, ORIG2[i]) end
        wb(t2, STEAL2, 0xFF); wb(t2, STEAL2 + 1, 0x25)
        put_u32(t2, STEAL2 + 2, 0); put_u64(t2, STEAL2 + 6, g_fn2 + STEAL2)
        local h2 = cave + HOOK2_OFF
        local sc2 = {
            0x49,0xBA,0,0,0,0,0,0,0,0,          -- mov  r10, PARAMS2
            0x49,0xFF,0x42,0x08,                -- inc  qword [r10+8]
            0x49,0x89,0x52,0x10,                -- mov  [r10+0x10], rdx   ⚠STACK ptr -- never deref
            0x45,0x8B,0x0A,                     -- mov  r9d, [r10]
            0x45,0x85,0xC9,                     -- test r9d, r9d
            0x74,0x1A,                          -- jz   .done
            0x51,                               -- push rcx               save `this`
            0x4D,0x8D,0x5A,0x18,                -- lea  r11, [r10+0x18]
            0x41,0x8B,0x03,                     -- .loop: mov eax, [r11]
            0x41,0x8B,0x4B,0x04,                --        mov ecx, [r11+4]
            0x89,0x0C,0x02,                     --        mov [rdx+rax], ecx
            0x49,0x83,0xC3,0x08,                --        add r11, 8
            0x41,0x83,0xE9,0x01,                --        sub r9d, 1
            0x75,0xEC,                          --        jnz .loop
            0x59,                               -- pop  rcx
            0xE9,0x00,0x00,0x00,0x00,           -- .done: jmp trampoline2 (tail call)
        }
        for i = 1, #sc2 do wb(h2, i - 1, sc2[i]) end
        put_u64(h2, 2, params2)
        put_u32(h2, #sc2 - 4, (t2 - (h2 + #sc2)) % 0x100000000)
        g_params2 = params2
    else
        log("tonemap hook unavailable -- bloom/contrast still fine")
    end
    log(string.format("cave 0x%X", cave))
    return true
end

-- ── parameter tables ──────────────────────────────────────────────────────────────────────────
-- Entries are {u32 offset, u32 value}. Both counts are published with ONE aligned 8-byte store, so
-- the render thread can never read a count that outruns the entries behind it.
local g_cnt_q = ffi.new("cbl_u64[1]")
local g_cnt = ffi.cast("cbl_u32*", g_cnt_q)
local function publish(params, dwords, bytes_, check)
    if params == 0 then return false end
    if #dwords + #bytes_ > MAX_ENTRIES then return false end
    local seen = {}
    for _, e in ipairs(dwords) do
        if check and not check(e[1], 4) then log(string.format("offset 0x%X out of range -- refusing", e[1])); return false end
        if seen[e[1]] then log(string.format("duplicate write to 0x%X -- refusing", e[1])); return false end
        seen[e[1]] = true
    end
    for _, e in ipairs(bytes_) do
        if check and not check(e[1], 1) then return false end
    end
    local o = 0x18
    for _, e in ipairs(dwords) do put_u32(params, o, e[1]); put_u32(params, o + 4, e[2]); o = o + 8 end
    for _, e in ipairs(bytes_) do put_u32(params, o, e[1]); put_u32(params, o + 4, e[2]); o = o + 8 end
    g_cnt[0] = #dwords; g_cnt[1] = #bytes_
    ffi.cast("cbl_u64*", params)[0] = g_cnt_q[0]      -- publish barrier
    return true
end
local function unpublish()
    if g_params1 ~= 0 then ffi.cast("cbl_u64*", g_params1)[0] = 0 end
    if g_params2 ~= 0 then ffi.cast("cbl_u64*", g_params2)[0] = 0 end
end

local function patch_bytes(fn, hook, steal)
    local b = {}
    local rel = (hook - (fn + 5)) % 0x100000000
    b[1] = 0xE9
    for i = 0, 3 do b[2 + i] = math.floor(rel / 2 ^ (8 * i)) % 256 end
    for i = 6, steal do b[i] = 0x90 end                 -- pad any leftover stolen bytes
    for i = steal + 1, 8 do b[i] = rb(fn, i - 1) end    -- past the steal is NOT ours: keep it
    return b
end
local function restore_bytes(fn, orig)
    local b = {}
    for i = 1, 8 do b[i] = orig[i] or rb(fn, i - 1) end
    return b
end

local function arm()
    if g_armed then return true end
    if not ensure_offsets() then return false end
    if not build_cave() then return false end
    if not store_qword(g_fn1, patch_bytes(g_fn1, g_cave + HOOK1_OFF, STEAL1)) then return false end
    if g_params2 ~= 0 and not store_qword(g_fn2, patch_bytes(g_fn2, g_cave + HOOK2_OFF, STEAL2)) then
        log("tonemap patch failed -- continuing without it"); g_params2 = 0
    end
    g_armed = true
    log("ARMED")
    return true
end
local function disarm()
    if not g_armed then return end
    unpublish()                                          -- stop applying BEFORE the jumps go away
    store_qword(g_fn1, restore_bytes(g_fn1, ORIG1))
    if g_params2 ~= 0 then store_qword(g_fn2, restore_bytes(g_fn2, ORIG2)) end
    g_armed = false
    log("disarmed (prologues restored)")
end

-- ── widget reads ──────────────────────────────────────────────────────────────────────────────
-- Some slider types return a number from .Get(), others only from .GetValue():Get(). ColorPicker has
-- NO .Get() at all: reading it like a slider silently yields nil (colors fall through to black).

local function slider_get(s)
    if not s then return nil end
    if s.Get then local v = s:Get(); if type(v) == "number" then return v end end
    if s.GetValue then local vp = s:GetValue()
        if vp and vp.Get then local v = vp:Get(); if type(v) == "number" then return v end end end
    return nil
end
local function pk_rgb(pk)
    if not pk or not pk.GetValue then return nil end
    local vp = pk:GetValue(); if not vp or not vp.Get then return nil end
    local c = vp:Get(); if not c or not c.GetR then return nil end
    local r, g, b = c:GetR(), c:GetG(), c:GetB()
    if not (r and g and b) then return nil end
    return r / 255.0, g / 255.0, b / 255.0
end
local function checked(cb) return (cb and cb.Get and cb:Get()) == true end

-- Seed a block's sliders from the values the engine actually blended for THIS map, so ticking a box
-- starts from the map's real look instead of yanking it to numbers we invented. Read-only and fully
-- validated; lastOut is a pointer the render thread left us, so every float is treated as suspect.
-- ⚠Only hook #1's lastOut may be dereferenced. Hook #2's is a STACK address inside the render thread
-- (FUN_18005a220 builds the 15 floats as locals and passes their address) -- long dead by now. The
-- tonemap sliders are therefore seeded from out+0xec, the same 15 floats in a stable buffer.
local OUT_TONEMAP, OUT_STRUCT_MIN = 0xec, 0x160
local function seed_from_out(fields, base_off, cls, size)
    if g_params1 == 0 then return false end
    local out = tonumber(ffi.cast("cbl_u64*", g_params1 + 0x10)[0]) or 0
    if out < MIN_PTR or not region_ok(out, OUT_STRUCT_MIN) then return false end
    for _, f in ipairs(fields) do
        local o = field_off(cls, f.name, size)
        if o and f.ctrl and f.ctrl.GetValue then
            local v = tonumber(ffi.cast("float*", out + base_off + o)[0]) or 0
            if v == v and v > -1e6 and v < 1e6 then f.ctrl:GetValue():Set(v) end
        end
    end
    return true
end

-- Reading the widgets crosses into the cheat's UI layer and allocates a fresh table per picker -- a
-- lot of work for values that only change when the user drags something. Refresh on a short throttle
-- (4 frames is still >50Hz, so dragging stays smooth) and only republish when something moved.
local GATHER_EVERY = 4
local g_tmr, g_key1, g_key2 = 0, nil, nil
local g_was = false
local g_tone_seeded, g_lc_seeded = false, false
local TONE_CLS, LC_CLS = "PostProcessingTonemapParameters_t", "PostProcessingLocalContrastParameters_t"

-- Map-load hand-off with cm_postfx_apply_or_reseed (defined near cm_bloom_* above). Globals because
-- that codec lives in a different protected_call block; Lua resolves them at call time.
--   RESEED      -- map has no saved config: forget the previous map's curve and re-seed from this one.
--   MARK_SEEDED -- map HAS a saved config: it was just pushed into the sliders, so suppress seeding,
--                  otherwise the engine would overwrite the user's saved curve with the map's own.
function CM_POSTFX_RESEED() g_tone_seeded, g_lc_seeded = false, false; g_key1, g_key2 = nil, nil end
function CM_POSTFX_MARK_SEEDED() g_tone_seeded, g_lc_seeded = true, true; g_key1, g_key2 = nil, nil end

local function tick()
    local B = CM_BLOOM_CTRLS
    local P = CM_POSTFX_CTRLS
    local bloom_on = B and checked(B.enable)
    local tone_on  = P and P.tone and checked(P.tone.enable)
    local lc_on    = P and P.lc and checked(P.lc.enable)
    local want = bloom_on or tone_on or lc_on

    if want and not g_armed then
        if not arm() then return end
        g_tmr, g_key1, g_key2 = 0, nil, nil
        g_tone_seeded, g_lc_seeded = false, false
    elseif (not want) and g_armed then
        disarm()
        g_tone_seeded, g_lc_seeded = false, false
    end
    if not (want and g_armed) then g_was = want; return end
    g_was = want

    g_tmr = g_tmr - 1
    if g_tmr > 0 then return end
    g_tmr = GATHER_EVERY

    -- ── hook #1 table: bloom + local contrast ──
    local dw, by, key = {}, {}, ""
    if bloom_on then
        by[#by + 1] = { OUT_HASBLOOM, 1 }
        key = "b"
        for k, _ in pairs(BLOOM_FIELDS) do
            local v = slider_get(B.globals and B.globals[k]) or 0
            dw[#dw + 1] = { F[k], fbits(v) }
            key = key .. string.format(",%.3f", v)
        end
        for i = 1, 5 do
            local lv = B.levels and B.levels[i]
            local w = (lv and slider_get(lv.w)) or 0
            local r, g, b = 1, 1, 1
            if lv then local rr, gg, bb = pk_rgb(lv.c); if rr then r, g, b = rr, gg, bb end end
            dw[#dw + 1] = { F.blurw + (i - 1) * 4, fbits(w) }
            local t = F.blurt + (i - 1) * 12                      -- Vector = 12 bytes
            dw[#dw + 1] = { t, fbits(r) }; dw[#dw + 1] = { t + 4, fbits(g) }; dw[#dw + 1] = { t + 8, fbits(b) }
            key = key .. string.format("|%.3f,%.3f,%.3f,%.3f", w, r, g, b)
        end
    end
    if lc_on then
        -- Never publish a block before it is seeded: seeding needs lastOut, which does not exist
        -- until the hook has fired once, so the first enabled frame would otherwise push raw slider
        -- defaults over the map's real values.
        if not g_lc_seeded then g_lc_seeded = seed_from_out(P.lc.fields, OUT_LC, LC_CLS, LC_SIZE) end
        if g_lc_seeded then
            by[#by + 1] = { OUT_HASLC, 1 }
            key = key .. "|lc"
            for _, f in ipairs(P.lc.fields) do
                local o = field_off(LC_CLS, f.name, LC_SIZE)
                if o then
                    local v = slider_get(f.ctrl) or 0
                    dw[#dw + 1] = { OUT_LC + o, fbits(v) }   -- into the out struct
                    key = key .. string.format(",%.3f", v)
                end
            end
        end
    end
    if key ~= g_key1 and publish(g_params1, dw, by, in_range) then g_key1 = key end

    -- ── hook #2 table: tonemap. Offsets are field offsets INSIDE the params struct, because this
    -- hook writes into rdx = the 15-float array itself, not into the out struct.
    if g_params2 ~= 0 and P and P.tone then
        local tdw, tkey = {}, tone_on and "t" or "off"
        if tone_on then
            if not g_tone_seeded then
                g_tone_seeded = seed_from_out(P.tone.fields, OUT_TONEMAP, TONE_CLS, TONE_SIZE)
            end
            if g_tone_seeded then
                for _, f in ipairs(P.tone.fields) do
                    local o = field_off(TONE_CLS, f.name, TONE_SIZE)   -- raw: hook #2 writes rdx+o
                    if o then
                        local v = slider_get(f.ctrl) or 0
                        -- ⚠ToeDenom is F in `E/F` and `1/(hable(w)-E/F)`: 0 is a divide by zero baked
                        -- into a shader constant, i.e. the whole screen. The slider floor should stop
                        -- it, but a restored config could still carry a 0 -- refuse the lot instead.
                        if f.name == "m_flToeDenom" and v == 0 then tdw = {}; tkey = "off"; break end
                        tdw[#tdw + 1] = { o, fbits(v) }
                        tkey = tkey .. string.format(",%.3f", v)
                    end
                end
            else
                tkey = "off"
            end
        end
        if tkey ~= g_key2 and publish(g_params2, tdw, {}, function(o, sz) return o >= 0 and o + sz <= TONE_SIZE end) then
            g_key2 = tkey
        end
    end
end

local present = events and (events.presentQueue or events.present_queue)
if present and present.Add then
    present:Add(tick)
else
    log("events.presentQueue unavailable -- engine idle")
end

end)

































-- ================== Chams (merged from chams.lua) ==================
-- UI goes into the "Other" sub-tab (WSR_SKIN_PARENT). Wrapped in protected_call: its locals
-- live in their own function (otherwise they would not fit LuaJIT's 200-locals-per-function limit),
-- and a top-level return/error stops only chams, not the whole script.
protected_call(function()
    -- agent_glow_rim.lua: 2nd pass (double-draw glow rim) on the LOCAL agent's world model.
    -- The VM glow rim (double-draw on RenderObjects) ported from the hands to the world model:
    --   the VM gate (L+0x480&0x100 + lflags 0x400005) is replaced with TGT-sobj (my pawn) + the world color pass.
    --   1st draw = native agent (skin/depth intact), 2nd draw = SCRATCH copy with an additive glow material.
    -- sobj is identified by a needle scan: pointers to m_pGameSceneNode/m_CRenderComponent/m_pCollision in sobj.
    if not ffi then ffi = require and require("ffi") end
    if not ffi then error("[agr] no ffi") end
    protected_call(ffi.cdef, [[
        typedef unsigned char      agr_u8;
        typedef unsigned short     agr_u16;
        typedef unsigned int       agr_u32;
        typedef unsigned long long agr_u64;
        typedef unsigned long long AGR_SIZE_T;
        typedef unsigned long      AGR_DWORD;
        int        VirtualProtect(void* a, AGR_SIZE_T s, AGR_DWORD p, AGR_DWORD* o);
        void*      VirtualAlloc(void* a, AGR_SIZE_T s, AGR_DWORD t, AGR_DWORD p);
        AGR_SIZE_T VirtualQuery(const void* a, void* b, AGR_SIZE_T l);
    ]])
    local TAG="[chams]"; local function log(...) if CM_VERBOSE then print(TAG, ...) end end
    local MIN_PTR=0x10000
    local MAX_PTR=0x7FFFFFFFFFFF
    local RVA_HOOK=0x545D0
    local ORIG={0x48,0x8B,0xC4, 0x53, 0x57, 0x41,0x54, 0x48,0x81,0xEC,0xD0,0x00,0x00,0x00}
    local DISP=14
    local RVA_GRS=0x14DF60
    -- Reload is inlined in the game now (the old 0xFE90 wrapper is gone). The recipe is a triple,
    -- exactly as the material reload loop at 0x3AAF3..0x3AB0F calls it:
    --   11080(mat) -> FA20(mat,binding,1) -> 10EA0(mat)
    -- ⚠ clearing only the loaded bit breaks the material: 11080 releases the stages together with the bit.
    local RVA_MATUNLOAD=0x11080     -- and [mat+0xB],0xFE + releases stages from the vector at mat+0x410
    local RVA_SHADERSETUP=0xFA20    -- LoadShadersAndSetupModes; the string "Material Shader Setup" is in the prologue
    local RVA_MATNOTIFY=0x10EA0     -- walks the consumers at mat+0x50/0x58, calls 0x10bd0 on each
    local RVA_FINDMAT=0x37790
    -- ⚠ Cannot be derived statically (the slot is filled at runtime, no write xrefs).
    -- Only used as a fallback when iface_this==0; if FindMaterial silently returns 0, this is the culprit.
    local IFACE_OFF=0x15d750
    local COLOR_PASS=0x400004   -- world-model color pass (without the depth bit 0x1000000); gate default
    local SIG={
     HOOK   ={0x48,0x8B,0xC4,0x53,0x57,0x41,0x54,0x48,0x81,0xEC,0xD0,0x00,0x00,0x00,0x49,0x63,0xF9,0x49,0x8B,0xD8,0x4C,0x8B,0xE2,0x83,0xFF,0x01},
     MATUNLOAD  ={0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57,0x48,0x83,0xEC,0x20,0x80,0x61,0x0B,0xFE,0x48,0x8D,0xB9,0x10,0x04,0x00},
     SHADERSETUP={0x44,0x89,0x44,0x24,0x18,0x48,0x89,0x54,0x24,0x10,0x53,0x55,0x56,0x41,0x55,0x48,0x81,0xEC,0x88,0x00,0x00,0x00,0x4C,0x8B,0xE9},
     MATNOTIFY  ={0x48,0x89,0x5C,0x24,0x20,0x55,0x57,0x41,0x54,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,-1,-1,-1,-1,0x48,0x8B},
     FINDMAT={0x4C,0x8B,0xDC,0x49,0x89,0x5B,0x08,0x49,0x89,0x73,0x10,0x57,0x48,0x81,0xEC,0x00,0x01,0x00,0x00,0x33,0xDB,0xC7,0x44,0x24,0x24,0xC8,0x00,0x00,0xC0},
     GRS  ={pat={0x48,0x8B,0x0D,-1,-1,-1,-1,0x4C,0x8D,0x45,0xC0,0x41,0xB9,0x07,0x00,0x00,0x00,0xBA,0x76,0x6D,0x61,0x74,0x48,0x8B,0x01,0xFF,0x90,0x00,0x01,0x00,0x00}, doff=3, ilen=7},
     IFACE={pat={0x48,0x8B,0x15,-1,-1,-1,-1,0x4D,0x85,0xC0,0x74,0x27,0x40,0x38,0x6A,0x29,0x74,0x21}, doff=3, ilen=7},
    }
    local sg={iface_slot=0x143598, iface_this=0, resolved=false}
    -- 🛑 PRIVATE COPIES ONLY, never put a stock VPK path here. We WRITE into the material
    -- (recipe, sliders, color, Reload), and the engine has ONE instance for everyone referencing it:
    -- touch the stock steam_001_additive and all the smoke on the map changes.
    -- ⚠ Each section also makes ITS OWN copy (section_material: X.vmat_c -> X_<section>.vmat_c),
    -- otherwise agent, hands and weapon share one instance and one color.
    -- ⚠ The engine caches resources BY NAME: a path that failed to load once returns the error material
    -- until the game restarts. If you edit a .vmat_c, rename the file.
    -- Custom materials do NOT go here: put <name>.vmat_c into materials/chams, the folder is scanned below.
    -- Only the base set from the repository lives here; it also defines WHAT to download (see DL).
    local MAT_DIR="materials/chams"
    local BASE_PATHS={
        -- ⭐ flat = sun_disc_glow_001 with a truly solid-color texture (raw RGBA8888 mip).
        -- A BC7 texture showed a regular triangle grid across the whole surface: the artifacts were in
        -- the texture itself, not in the rendering.
        "materials/chams/flat.vmat",                  -- the only one the script creates itself (ensure_material)
        -- csgo_effects, full set of knobs (ColorBoost / ColorTint / Fresnel* / OpacityScale).
        -- ADDITIVE+FEATHER = the body fades, the rim glows.
        "materials/chams/steam_001_additive.vmat",    -- ADDITIVE + FEATHER + RENDER_BACKFACES
        "materials/chams/steam_002.vmat",             -- ADDITIVE + FEATHER
        "materials/chams/cloud_001.vmat",             -- FEATHER without additive
        "materials/chams/debug_wireframe.vmat",       -- wireframe
    }
    -- ── FOLDER SCAN: custom materials without editing the script ────────────────
    -- The base set comes first in a fixed order: combo indices of already configured materials
    -- must not shift when a new file appears. Anything found beyond it is appended alphabetically.
    -- 🛑 The scan does NOT touch the downloader list: that one walks BASE_PATHS. Otherwise a custom material
    -- that is not in the repo would hit two 404s on every run and "N material(s) still missing".
    -- ⚠ SECTION COPIES are filtered out (section_material turns X.vmat_c into X_agent.vmat_c, etc.).
    -- The rule is not "name ends in _agent" but "ends in _<section> AND the source X exists next to it":
    -- otherwise a custom material named e.g. my_weapon.vmat_c would silently drop off the list.
    local SEC_IDS={"agent","hands","weapon"}   -- must match S.id in SECS
    local GLOW_PATHS={}
    do
        local known={}
        for _,p in ipairs(BASE_PATHS) do GLOW_PATHS[#GLOW_PATHS+1]=p; known[p]=true end
        local files=(utils and utils.FileEnumerate) and utils.FileEnumerate(MAT_DIR.."/*.vmat_c") or nil
        if type(files)=="table" then
            local names, list = {}, {}
            for _,f in ipairs(files) do
                local slash=tostring(f):gsub("\\","/")
                local base=slash:match("([^/]+)$") or ""
                local n=base:match("^(.+)%.vmat_c$")
                if n then names[n]=true; list[#list+1]=n end
            end
            local extra={}
            for _,n in ipairs(list) do
                local skip=false
                for _,id in ipairs(SEC_IDS) do
                    local stem=n:match("^(.+)_"..id.."$")
                    if stem~=nil and names[stem] then skip=true end
                end
                local path=MAT_DIR.."/"..n..".vmat"
                if not skip and not known[path] then known[path]=true; extra[#extra+1]=path end
            end
            table.sort(extra)
            for _,p in ipairs(extra) do GLOW_PATHS[#GLOW_PATHS+1]=p end
            if #extra>0 then log(string.format("custom materials in folder: %d", #extra)) end
        end
    end

    local fe=utils and utils.FindExport
    local function api(m,n,ct) local a=tonumber(fe(m,n) or 0); if a==0 then a=tonumber(fe("KernelBase.dll",n) or 0) end; if a==0 then return nil end; return ffi.cast(ct,a) end
    local VP=api("kernel32.dll","VirtualProtect","int(__stdcall*)(void*,AGR_SIZE_T,AGR_DWORD,AGR_DWORD*)")
    local VA=api("kernel32.dll","VirtualAlloc","void*(__stdcall*)(void*,AGR_SIZE_T,AGR_DWORD,AGR_DWORD)")
    local VQ=api("kernel32.dll","VirtualQuery","AGR_SIZE_T(__stdcall*)(const void*,void*,AGR_SIZE_T)")
    if not(VP and VA) then log("WinAPI miss"); return end
    local b64tab={}
    do local A="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
       for i=1,64 do b64tab[A:byte(i)]=i-1 end end

    -- ── MATERIAL SELF-INSTALL (materials/chams) ─────────────────────────────────
    -- Only the .vtex_c header and the .vmat_c itself are inlined; the 1048576 bytes of pixels are NOT:
    -- the texture is uniform and is written by repeating one 64K buffer.
    -- Written through WinAPI rather than utils.FileWrite: that one takes a TABLE of bytes, and a table of a
    -- million elements means tens of MB of garbage and a noticeable pause on load.
    local CH={dir="materials\\chams", tex="flat_white_512_rgba8888_uniform_opaque_solid.vtex_c", mat="flat.vmat_c", px=1048576,
     hdr=table.concat({
    "IAgAAAwAAQAIAAAAAgAAAFJFRDIcAAAAlAMAAERBVEGwAwAAUAQAAAAAAAAAAAAABDNWS3wWEnTpBphGr/LmPrWQN+cBAAAAAAAAQAMA",
    "AACGAAAAAAAAAHcDAAARAAcAmwUAAEwDAAAAAAAAAAAAAAAAAAAAAAAApgIKAwArAAAACgABAPMGAQAAAAYAAAACAAAAAwAAAAQAAAAF",
    "FADXH5QRKwcAAAAIAAAACSgAGwooAEgR1HD9KAATCyAA9woMAAAADQAAAA4AAAAPAAAAEAAAAKYTIswRIAATEiAAExMgAAgcAB8UHAAI",
    "HxUcAAgfFhwACBMDHAAfFxwACC4PABwAExgcAC4ZABwAGxocAFMAAIBJEQgABCQALhsAQAATHEQAUB0AAAAecAFDAAAAICAAAEQBFyEg",
    "ABsiIAAIHAAeIxwAAcwAEyTkARMlCAATJggAEyf4AZMoAAAAKQAAACoYAP8RbV9JbnB1dERlcGVuZGVuY2llcwBtX0FkZGl0aW9uYWwe",
    "AAHwJFJlbGF0aXZlRmlsZW5hbWUAbWF0ZXJpYWxzL21vZGVscy93ZWFwb25zL2N1c3RvbWl6YU0A8CQvcGFpbnRzL2h5ZHJvZ3JhcGhp",
    "Yy93ZWJzLnBzZABtX1NlYXJjaFBhdGgAY3NnbwBtX25iAJJDUkMAbV9iT3CRAAAMAAAXAGBFeGlzdHMOAFFJc0dhbY0AD4kALjB0eHT+",
    "AGxyZ3VtZW73AKBQYXJhbWV0ZXJO9ACyX19fT3ZlcnJpZGUkAWhhdGFfX18oAPIDVHlwZQBCaW5hcnlCbG9iQXJn1ACbbmdlcnByaW50",
    "DwDwAERlZmF1bHQAZXRjAEludDAAcGZhc3QAZmn4APEEaHVlU2hpZnRGaXh1cABJbWFnZVIA8wtheGNvbXBpbGVkdGV4dHVyZXJlcwBG",
    "bG9hdB8AtW1pcHNpemUAbWluCwCLX1NwZWNpYWzjAIJTdHJpbmcAVEkAIiBDWQDEciBWZXJzaW9uAG1fEwCzSWRlbnRpZmllcgATAAM1",
    "AADUAEBVc2VyEAEPSQAGlSBNaXAgTm9uZSIA6UVuY29kZSBRdWFsaXR5gwIBbwIgZWThARBzggDwAGhpbGRSZXNvdXJjZUxpc0YBtVdl",
    "YWtSZWZlcmVuFAACTwJFYWJsZY8AKUlzPQAAJQB1dWJhc3NldD0AFnMVAACQASFpboUA8QNzAAkIGAkGBgwODQ4GBgwNDQ4OAE8PBgYP",
    "BAAIIAwMCAAEKgAQEAQAwAwICAgJEAEBAN3u/wAAAAAAAAAAAAAAAAEAAAAAAAAAvMkTPgAAAAAAAIA/AAIAAgEABAEAAAAACAAAAAIA",
    "AAABAAAAFAAAAAAEAAAEAAAACAQAAAwAAAAA/0mSJEmSJCAHIAA1ldbVAP9JkiRJkiSgAgAAR2FVdQD/SZIkSZIkwAYgAF+VVUQA/0mS",
    "JEmSJMAFAABQVVFdAP9JkiRJkiSABQAAVSVVVQD/SZIkSZIkoAYAAF5UVVUA/0mSJEmSJMAEAABVVTVVAP9JkiRJkiRABSAAVUVVlAD/",
    "SZIkSZIkwAcgAFVwVVUA/0mSJEmSJMAFAAAWVVVVAP9JkiRJkiQABQAAVZxVVQD/SZIkSZIk4AcAANRWVVYA/0mSJEmSJOAEAABVdVRV",
    "AP9JkiRJkiTABgAAUZVVVQD/SZIkSZIkYAcAAFWZR1oA/0mSJEmSJAAFAABFeX5cAP9JkiRJkiSABSAAXV1VJQD/SZIkSZIkAAYAAFxV",
    "clQA/0mSJEmSJEACAABVVUV1AP9JkiRJkiQgBwAAYVtVZQD/SZIkSZIkQAUAAFwVF10A/0mSJEmSJGAHQABVRVVRAP9JkiRJkiSABCAA",
    "V1EVWQD/SZIkSZIkIAIAAGUVUVcA/0mSJEmSJEAFAABVNW3FAP9JkiRJkiQAByAA0ZWldQD/SZIkSZIkgAdAAJdBbVUA/0mSJEmSJAAG",
    "IACVVRVRAP9JkiRJkiSABiAAMXVaVAD/SZIkSZIk4AYAAExVVVYA/0mSJEmSJAAFAABVVVFZAP9JkiRJkiTgBgAAxVWVVQD/SZIkSZIk",
    "QAUAAJGVRVIA/0mSJEmSJKAGIABTVVVFAP9JkiRJkiTgBAAAVVHVVQD/SZIkSZIkIAdAAFtQUXcA/0mSJEmSJAAGAABVUVVVAP9JkiRJ",
    "kiRgBgAAVlVsVQD/SZIkSZIkYAYAAEdUVWUA/0mSJEmSJCAEAAB3lFVVAP9JkiRJkiRgBAAAVVVVhgD/SZIkSZIkgAUAAFWVFUsA/0mS",
    "JEmSJOAHAABVhVqUAP9JkiRJkiSABiAAUfURWQD/SZIkSZIkAAQAABVVVXUA/0mSJEmSJGAHAABZwVVVAP9JkiRJkiRgBAAAFVVVVQD/",
    "SZIkSZIkgAIAAHVVFVcA/0mSJEmSJOAGAABHBVRpAP9JkiRJkiSgAwAAFVUF1QD/SZIkSZIkwAcAAJR9VaUA/0mSJEmSJOAGAAB1V11B",
    "AP9JkiRJkiTgBAAAVhUXRAD/SZIkSZIkgAUAABWlFlQA/0mSJEmSJAAFAABVZVRBAP9JkiRJkiRABQAAVXVREAD/SZIkSZIkIAcgAFRt",
    "FRMA/0mSJEmSJAAHYABETGdHAP9JkiRJkiRgBSAAJ1VlRQD/SZIkSZIkAAYAABVVVFQA/0mSJEmSJCAHQABXBUVWAP9JkiRJkiRgBCAA",
    "VRrWQQD/SZIkSZIkIAMAAEd1UR0A/0mSJEmSJEAHAACVRVV9AAAAAAgAAAABAAAAAAAQAA==",
    }),
     matb=table.concat({
    "1Q8AAAwAAQAIAAAABAAAAFJFUkwsAAAAmwAAAFJFRDK7AAAAfwUAAERBVEEuBgAAYwcAAElOU0eFDQAAGAIAAAgAAAACAAAA0HyXmIU3",
    "XLcYAAAAAAAAACMSg/gjSyGUOQAAAAAAAABtYXRlcmlhbHMvZGVmYXVsdC9kZWZhdWx0X21hc2tfdGdhXzM0NDEwMWY4LnZ0ZXgAbWF0",
    "ZXJpYWxzL2NoYW1zL2ZsYXRfd2hpdGVfNTEyX3JnYmE4ODg4X3VuaWZvcm1fb3BhcXVlX3NvbGlkLnZ0ZXgAAzNWS3wWEnTpBphGr/Lm",
    "PrWQN+cBAAAAAAAAQAAAAADZAAAAAAAAACcGAAAYAAcAkwkAAD8FAAAAAAAAAAAAAGJFAAAACgABAPMGBQAAAAYAAAABAAAAAgAAAAMA",
    "AAAEGABAPF4h4hwAVwcAAAAIKAATCSgAFwpAAAwkABsLJABPDl7c7SgAARsMKABP5io9sCgAAR8NdAAIEw7MABMPeAAAwAD3BhAAAAAR",
    "AAAAEgAAABMAAAAUAAAAFRwAExYcAC4XABwAHxgcAAgfGRwACBMCHAAfGhwACA+MAAEfDDgACB8MOAAIExscAC4cABwAGx0cAFMAAIBJ",
    "FQgABCQALh4AQAATH1wBACQA0yAAAAAhAAAAIgAAACMkAACEARckIAAbJSAAGxkgABMmIAATJyAAGwsgABsoIAAIHAAfKRwACB4qHAAB",
    "nAATKwwCEywsABctBABTLgAAAC8gABMwIALzEjEAAAAyAAAAMwAAADQAAAA1AAAANgAAADcAAAA4AAAAOTgAEzoIABA7GAPzEQAAAD0A",
    "AAA+AAAAPwAAAEAAAABBAAAAQgAAAEMAAABEZAD0KW1fSW5wdXREZXBlbmRlbmNpZXMAbV9SZWxhdGl2ZUZpbGVuYW1lAG1hdGVyaWFs",
    "cy9kZWZhdWx0CADwEF9tYXNrLnRnYQBtX1NlYXJjaFBhdGgAY29yZQBtX25BAPAAQ1JDAG1fYk9wdGlvbmFsDAAAFwBgRXhpc3RzDgBR",
    "SXNHYW1sAA9oAA53eHQAY3NnbygA8AhlZmZlY3RzL2dsb3dzL3N1bl9kaXNjXw8An18wMDEudm1hdC8ADRVrLwCvX3RyYW5zLnBzZDQA",
    "HgCcAGJtX0FkZGnoAA9YAQF8QXJndW1lbhcAoFBhcmFtZXRlck5sAbJfX19PdmVycmlkZUQAaGF0YV9fXygA8gNUeXBlAEJpbmFyeUJs",
    "b2JBcmdtAZtuZ2VycHJpbnQPABJERQGAAGV0YwBJbnQwAHBmYXN0AGZpkQFRSW1hZ2VEAPMLYXhjb21waWxlZHRleHR1cmVyZXMARmxv",
    "YXQfALVtaXBzaXplAG1pbgsAi19TcGVjaWFs1QBhU3RyaW5nrwEQLwUAE19HAYIudmZ4AG1fQ2kAw3JJZGVudGlmaWVyABMAE015AQDE",
    "AEBVc2VyAAEUABUAFCA4AKIgVmVyc2lvbgBUqgAOGQADEQADIAAPKAAG/wMgTWlwIEFscGhhV2VpZ2h0ZWQrAAs1Qm94IQDpRW5jb2Rl",
    "IFF1YWxpdHn/AQFDAyBlZNYCEHPvAP8BaGlsZFJlc291cmNlTGlzdOsCDP8DX3RnYV8zNDQxMDFmOC52dGV4kQId019wc2RfZTA2OTlj",
    "MjZCAMRfV2Vha1JlZmVyZW6HAAO3A0VhYmxlbgH/KkNhbkJhdGNoV2l0aER5bmFtaWNTaGFkZXJDb25zdGFudHMAVmVydGV4UGFpbnRV",
    "SVBpY2tDb2xvchcABAFfAXEAdW5saXQAnQDwDGx1Y2VudABOb1pQcmVwYXNzAERvTm90Q2FzdGkA8Alvd3MAU3VwcG9ydHNNYXBwaW5n",
    "RGltZW6FATBzAEynAfQCU2ltX0RpZmZ1c2VBbGJlZG/oAZFSZXByZXNlbnTCBAQWABBymwKWcmJhY2tmYWNlXgABTAASbWMA8QEAQWNj",
    "ZXB0c0RlY2FscwBz8gAdALwCD2EAAhFIPAIPHAADiVdpZHRoAElzBAIAeQF1dWJhc3NldJEBFnMVAACzA0Fpbml08QD0AAkKCQYGDA4N",
    "DgYGDw0ODgwABhIAEAghAC8PDwQADyAMDAgAAU8AFg8EABQQBABwDAgKBggJEAEAMA8PECsAsA8GEBAPAQEA3e7/AzNWS3wWEnTpBphG",
    "r/LmPrWQN+cAAAAAAAAAQAAAAACVAAAAHgAAANcDAAAcABMAIwcAACMHAAAAAAAAAAAAADIAAAAOAAAAAAAAAAEAAAACAAAAAwAAAAQA",
    "AAAEAAAAAgAAAAUAAAAGAAAABwAAAAIAAAAFAAAACAAAAAcAAAACAAAABQAAAAkAAAAHAAAAAgAAAAUAAAAKAAAABwAAAAsAAAAKAAAA",
    "AgAAAAUAAAAMAAAADQAAAAIAAAAFAAAADgAAAA0AAAACAAAABQAAAA8AAAANAAAAAgAAAAUAAAAQAAAADQAAAAIAAAAFAAAAEQAAAA0A",
    "AAACAAAABQAAABIAAAANAAAAAgAAAAUAAAATAAAADQAAAAIAAAAFAAAAFAAAAA0AAAACAAAABQAAABUAAAANAAAAAgAAAAUAAAAWAAAA",
    "DQAAABcAAAAHAAAAAgAAAAUAAAAYAAAAGQAAAAQAAAACAAAABQAAABoAAAAZAAAABAAAAAIAAAAFAAAAGwAAABkAAAAEAAAAAgAAAAUA",
    "AAAcAAAAGQAAAAQAAAACAAAABQAAAB0AAAAZAAAABAAAAAIAAAAFAAAAHgAAABkAAAAEAAAAAgAAAAUAAAAfAAAAGQAAAAQAAAAgAAAA",
    "BAAAAAIAAAAFAAAAIQAAACIAAAAjAAAAAgAAAAUAAAAkAAAAIgAAACUAAAACAAAABQAAACYAAAAiAAAAJQAAAAIAAAAFAAAAJwAAACIA",
    "AAAlAAAAKAAAAAAAAAApAAAAAAAAACoAAAACAAAAAgAAAAUAAAArAAAABwAAAAIAAAAFAAAALAAAAAcAAAAtAAAAAAAAAC4AAAAAAAAA",
    "LwAAAAAAAAAwAAAAAAAAADEAAAAAAAAAAAAAAAAAAIDCPWBAAAAA4E1iUD8AAAAAAADwPwAAAAAAAPA/AAAAAAAA8D8AAAAAAAAAAAAA",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA8D8AAAAAAADwPwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAPA/AAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "AAAAAAAAAADwPwAAAAAAAPA/AAAAAAAA8D8AAAAAAAAAAG1fbWF0ZXJpYWxOYW1lAG1hdGVyaWFscy9lZmZlY3RzL2dsb3dzL3N1bl9k",
    "aXNjX2dsb3dfMDAxLnZtYXQAbV9zaGFkZXJOYW1lAGNzZ29fZWZmZWN0cy52ZngAbV9pbnRQYXJhbXMAbV9uYW1lAEZfQURESVRJVkVf",
    "QkxFTkQAbV9uVmFsdWUAZ19iRm9nRW5hYmxlZABnX25UZXh0dXJlQWRkcmVzc01vZGVVAGdfblRleHR1cmVBZGRyZXNzTW9kZVYAbV9m",
    "bG9hdFBhcmFtcwBnX2ZsQ29sb3JCb29zdABtX2ZsVmFsdWUAZ19mbEZhZGVEaXN0YW5jZQBnX2ZsRmFkZUZhbGxvZmYAZ19mbEZhZGVN",
    "YXgAZ19mbEZhZGVNaW4AZ19mbEZyZXNuZWxFeHBvbmVudABnX2ZsRnJlc25lbEZhbGxvZmYAZ19mbEZyZXNuZWxNYXgAZ19mbEZyZXNu",
    "ZWxNaW4AZ19mbE9wYWNpdHlTY2FsZQBtX3ZlY3RvclBhcmFtcwBnX3ZDb2xvclRpbnQAbV92YWx1ZQBnX3ZNYXNrMVBhblNwZWVkAGdf",
    "dk1hc2sxU2NhbGUAZ192TWFzazJQYW5TcGVlZABnX3ZNYXNrMlNjYWxlAGdfdlRleENvb3JkU2Nyb2xsU3BlZWQAVGV4dHVyZUNvbG9y",
    "AG1fdGV4dHVyZVBhcmFtcwBnX3RDb2xvcgBtX3BWYWx1ZQBtYXRlcmlhbHMvY2hhbXMvZmxhdF93aGl0ZV81MTJfcmdiYTg4ODhfdW5p",
    "Zm9ybV9vcGFxdWVfc29saWQudnRleABnX3RNYXNrMQBtYXRlcmlhbHMvZGVmYXVsdC9kZWZhdWx0X21hc2tfdGdhXzM0NDEwMWY4LnZ0",
    "ZXgAZ190TWFzazIAZ190TWFzazMAbV9keW5hbWljUGFyYW1zAG1fZHluYW1pY1RleHR1cmVQYXJhbXMAbV9pbnRBdHRyaWJ1dGVzAFJl",
    "cHJlc2VudGF0aXZlVGV4dHVyZUhlaWdodABSZXByZXNlbnRhdGl2ZVRleHR1cmVXaWR0aABtX2Zsb2F0QXR0cmlidXRlcwBtX3ZlY3Rv",
    "ckF0dHJpYnV0ZXMAbV90ZXh0dXJlQXR0cmlidXRlcwBtX3N0cmluZ0F0dHJpYnV0ZXMAbV9yZW5kZXJBdHRyaWJ1dGVzVXNlZAAJBgYK",
    "CQYQBg8GDwYPCgkGBQYSBhIGEgYRBgUGEgYSBhEGEgoJBgoFBgoFBgoFBgoFBgoFBgoFBgoFCgkGhgEGhgEGhgEGhgEICAoJBhAGEAgI",
    "CAgIAN3u/wMzVkt8FhJ06QaYRq/y5j61kDfnAQAAAAAAAEAAAAAATgAAAAAAAAC5AQAACgABAPUCAADYAQAAAAAAAAAAAABiHQAAAAEA",
    "AQBTCQAAAAQQAFMCAAAAAxAAlwUAAAAGAAAAByAAEwggABMJIAAbCiAAEwsgABMMIAAbDSAAEw4gAB8PIAAEExAgABMRIAAbEiAAExMg",
    "ABMUIAAbFSAAExYgABMXIAAbGCAAExkgABsaIAAXAyQAExsQABscJAAArADxDW1fZWxlbXMAbV9wTmFtZQB2QmxlbmRJbmRpY2UWAJxT",
    "ZW1hbnRpYwAZADREM0QcAAE6APcBQkxFTkRJTkRJQ0VTAG1fbiAAU0luZGV4WwB5V2VpZ2h0AAwAADoAY1dFSUdIVCUA8AZDb2xvclRp",
    "bnQAVmVydGV4UGFpbnQQAAEZALIAQ09MT1IAdlBlch8AEExHAE5pbmcAEgDwGHZOb3JtYWxPcwBPcHRpb25hbGx5Q29tcHJlc3NlZFRh",
    "bmdlbnRGcsEAwE5PUk1BTAB2UG9zaSsA8SdPcwBQb3NYeXoAUE9TSVRJT04AdlRleENvb3JkAExvd1ByZWNpc2lvblV2AFRFWENPT1JE",
    "AHZ6AGdtYXBVVgALAPUQblRyYW5zZm9ybUJ1ZmZlck9mZnNldABJbnN0YW5jZR4Ap1V2AAkKCQYGBg8EABsQEACQCwYGBgsA3e7/",
    })}
    local W={}
    W.gmh  =api("kernel32.dll","GetModuleHandleA","void*(__stdcall*)(const char*)")
    W.gmfn =api("kernel32.dll","GetModuleFileNameA","AGR_DWORD(__stdcall*)(void*,char*,AGR_DWORD)")
    W.mkdir=api("kernel32.dll","CreateDirectoryA","int(__stdcall*)(const char*,void*)")
    W.creat=api("kernel32.dll","CreateFileA","void*(__stdcall*)(const char*,AGR_DWORD,AGR_DWORD,void*,AGR_DWORD,AGR_DWORD,void*)")
    W.write=api("kernel32.dll","WriteFile","int(__stdcall*)(void*,const void*,AGR_DWORD,AGR_DWORD*,void*)")
    W.close=api("kernel32.dll","CloseHandle","int(__stdcall*)(void*)")
    W.attr =api("kernel32.dll","GetFileAttributesA","AGR_DWORD(__stdcall*)(const char*)")
    local function b64dec(s, dst)
        local T=b64tab
        local n,acc,bits=0,0,0
        for i=1,#s do
            local v=T[s:byte(i)]
            if v then
                acc=acc*64+v; bits=bits+6
                if bits>=8 then bits=bits-8
                    local p=2^bits
                    dst[n]=math.floor(acc/p)%256; n=n+1; acc=acc%p
                end
            end
        end
        return n
    end
    -- the csgo/ root is derived from client.dll: ...\game\csgo\bin\win64\client.dll -> strip 3 components
    local function csgo_root()
        if not(W.gmh and W.gmfn) then return nil end
        local h=W.gmh("client.dll"); if h==nil then return nil end
        local buf=ffi.new("char[520]")
        local n=tonumber(W.gmfn(h,buf,520)) or 0
        if n==0 then return nil end
        local p=ffi.string(buf,n)
        for _=1,3 do p=p:match("^(.*)\\[^\\]*$") or p end
        return p
    end
    local function file_missing(p)
        if not W.attr then return true end
        return tonumber(W.attr(p))==0xFFFFFFFF
    end
    -- written in chunks: the 64K buffer is filled once, then 16 WriteFile calls.
    -- ffi.fill is NOT available in the Fatality sandbox, and a megabyte buffer is not needed anyway.
    local function file_put(p, parts)
        if not(W.creat and W.write and W.close) then return false end
        local h=W.creat(p, 0x40000000, 0, nil, 2, 0x80, nil)   -- GENERIC_WRITE, CREATE_ALWAYS
        if h==nil or tonumber(ffi.cast("agr_u64",h))==0xFFFFFFFFFFFFFFFF then return false end
        local wr=ffi.new("AGR_DWORD[1]")
        local ok=true
        for _,pt in ipairs(parts) do
            for _=1,(pt[3] or 1) do
                if W.write(h, pt[1], pt[2], wr, nil)==0 or tonumber(wr[0])~=pt[2] then ok=false; break end
            end
            if not ok then break end
        end
        W.close(h)
        return ok
    end
    local g_installed=false
    local function ensure_material()
        if g_installed then return true end
        g_installed=true
        local root=csgo_root()
        if root==nil then log("chams: csgo root not resolved, material not installed"); return false end
        local dir=root.."\\"..CH.dir
        if W.mkdir then W.mkdir(root.."\\materials", nil); W.mkdir(dir, nil) end
        local tp, mp = dir.."\\"..CH.tex, dir.."\\"..CH.mat
        if file_missing(tp) then
            local hb=ffi.new("agr_u8[?]", 2080)
            local n=b64dec(CH.hdr, hb)
            if n~=2080 then log(string.format("chams: texture header is %d bytes instead of 2080", n)); return false end
            local CHUNK=65536
            local fb=ffi.new("agr_u8[?]", CHUNK)
            for i=0,CHUNK-1 do fb[i]=0xFF end
            if not file_put(tp, {{hb,2080,1},{fb,CHUNK,CH.px/CHUNK}}) then log("chams: texture NOT written"); return false end
            log("chams: texture created")
        end
        -- ⚠ The material is ALWAYS written, not only "if the file is missing": otherwise, when the embedded
        -- blob changes (e.g. the texture is renamed), the file on disk would keep a stale reference, the engine
        -- would not find the texture and would show the error checkerboard. The file is entirely ours and
        -- rewriting 4 KB once per session costs nothing, while the disk is guaranteed to match the script.
        -- The texture is still conditional: its name describes its content, and it weighs a megabyte.
        local buf=ffi.new("agr_u8[?]", 8192)
        local n=b64dec(CH.matb, buf)
        if not file_put(mp, {{buf,n,1}}) then log("chams: material NOT written"); return false end
        return true
    end
    -- ── MATERIAL AUTO-DOWNLOAD (github.com/Garagoro/chams-materials) ────────────
    -- The repo tree mirrors the in-game path, so the file's relative path is both the URL tail
    -- and the saveToFile target. http.Get/utils.File* paths are relative to game/csgo, same as GLOW_PATHS.
    --
    -- 🛑 The order "WRITE TO DISK FIRST, THEN ASK THE ENGINE" is REQUIRED. Resources are cached BY NAME:
    -- a path that was not found once returns the error material until the game restarts, and a file
    -- downloaded later will not fix that. Hence DL.miss: while a file is missing, set_mat does NOT show
    -- that path to the engine at all. This also avoids polling FindMaterial every frame on a fresh install.
    --
    -- The script writes flat and its texture itself (ensure_material); they are fetched from GitHub only
    -- as a fallback if writing to disk failed. Everything else lives only in the repo.
    local DL={
        -- Mirrors are tried in order, one attempt each.
        -- ⚠ From inside the game raw.githubusercontent returns status=false on ALL files while jsDelivr
        -- downloads the same files fine, so jsDelivr goes first; otherwise every fresh install would
        -- waste four requests first.
        -- The skybox downloader is unaffected: it goes to objects.githubusercontent
        -- (a redirect from releases), which is a different host.
        mirrors={
            "https://cdn.jsdelivr.net/gh/Garagoro/chams-materials@main/",
            "https://raw.githubusercontent.com/Garagoro/chams-materials/main/",
        },
        dir="materials/chams",
        miss={},                       -- [.vmat path]=name of the missing file (true = do not show)
        queue={}, tries={}, res=nil, inflight=false, active=false, ok=0, fail=0,
    }
    DL.deps={ ["materials/chams/flat.vmat"]={ "materials/chams/"..CH.tex } }   -- flat has its own texture
    -- ⚠ ALWAYS PRINTS, bypassing CM_VERBOSE, so "only flat was downloaded" can be told apart from
    -- "no http", "host blocked" and "file not found". There are only a few lines and only when something
    -- is missing: with everything on disk DL.scan exits at n==0 and prints nothing.
    DL.say=function(msg) print("[chams] "..msg) end
    DL.have=function(f)
        if not(utils and utils.FileExists) then return true end   -- nothing to check with: do not interfere
        return utils.FileExists(f) and true or false
    end
    -- Recount what is missing. Material file = engine path + "_c". Dependencies count too:
    -- a material without its texture shows as a checkerboard, i.e. effectively fails to load as well.
    -- ⚠ Walks BASE_PATHS, NOT GLOW_PATHS. GLOW_PATHS also contains custom materials found by the scan,
    -- which are not and should not be in the repo: downloading them would give two 404s per file
    -- and a false "N material(s) still missing" on every run.
    DL.refresh=function()
        local need, seen, n = {}, {}, 0
        for _,eng in ipairs(BASE_PATHS) do
            local bad=nil
            local function want(f)
                if DL.have(f) then return end
                bad=bad or f
                if not seen[f] then seen[f]=true; need[#need+1]=f end
            end
            want(eng.."_c")
            local ds=DL.deps[eng]
            if ds then for _,d in ipairs(ds) do want(d) end end
            DL.miss[eng]=bad
            if bad then n=n+1 end
        end
        return n, need
    end
    DL.scan=function()
        ensure_material()                     -- try to write flat with its texture ourselves first
        local n, need = DL.refresh()
        if n==0 then return end
        if not(http and http.Get) then
            DL.say(string.format("%d material(s) missing, but http.Get is unavailable (insecure mode?)", n)); return
        end
        if utils and utils.FileCreateDirectories then utils.FileCreateDirectories(DL.dir) end
        DL.queue={}
        for _,f in ipairs(need) do
            if (DL.tries[f] or 0)<#DL.mirrors then DL.queue[#DL.queue+1]=f end
        end
        if #DL.queue>0 then
            DL.active=true; DL.ok=0; DL.fail=0
            DL.say(string.format("%d material(s) missing, downloading %d file(s)", n, #DL.queue))
        end
    end
    -- Attempt = next mirror. Out of mirrors: stop fetching the file.
    DL.start=function(f)
        local i=(DL.tries[f] or 0)+1
        local base=DL.mirrors[i]
        if base==nil then return false end
        DL.tries[f]=i
        DL.inflight=true
        -- the callback only records the result: it arrives from another thread, heavy work runs on the tick
        http.Get(base..f, {saveToFile=f}, function(status)
            DL.inflight=false
            DL.res={file=f, status=status, host=base}
        end)
        return true
    end
    DL.pump=function()
        local r=DL.res
        if r~=nil then
            DL.res=nil
            -- status==200 is not enough: saveToFile may have failed to open the file. Trust only the disk.
            if r.status==200 and DL.have(r.file) then
                DL.ok=DL.ok+1
                DL.say("ok "..r.file)
            else
                DL.fail=DL.fail+1
                DL.say(string.format("FAIL %s status=%s ondisk=%s host=%s",
                    r.file, tostring(r.status), tostring(DL.have(r.file)), tostring(r.host:match("^https://([^/]+)"))))
                -- try the next mirror right away, not on the next map
                if (DL.tries[r.file] or 0)<#DL.mirrors then DL.queue[#DL.queue+1]=r.file end
            end
        end
        if DL.inflight then return end
        while true do
            local f=table.remove(DL.queue,1)
            if f==nil then break end
            if DL.start(f) then return end        -- out of mirrors: just move on to the next file
        end
        if DL.active then
            DL.active=false
            local n=DL.refresh()                -- also clears DL.miss: the sections will re-acquire the material themselves
            local msg
            if n==0 then msg=string.format("Materials ready (%d downloaded)", DL.ok)
            else msg=string.format("%d material(s) still missing", n) end
            DL.say(msg)
            if notify_user then notify_user("Chams", msg) end
        end
    end
    -- Synchronous check on load: DL.miss must be filled BEFORE the first set_mat,
    -- otherwise the engine caches a miss on the missing path. The download itself is async.
    DL.scan()
    local function vprot(a,s,pr) local o=ffi.new("AGR_DWORD[1]"); VP(ffi.cast("void*",a),s,pr,o); return o[0] end
    local g_mbi=ffi.new("agr_u8[48]")
    local g_rd={}                       -- [page]=bool: permission cache per 4K page. Without it, VirtualQuery on
                                        -- EVERY read = thousands of syscalls per frame = freeze.
    local RD_TTL=90                    -- a per-frame reset made the cache useless (id_tgt every N frames always
                                        -- started cold). Page permissions do not change -> rare reset,
                                        -- only to avoid sticking to a freed page.
    local function is_readable(a)
        if type(a)~="number" or a~=a or a<MIN_PTR or a>MAX_PTR then return false end
        local page=a-(a%0x1000)
        local c=g_rd[page]; if c~=nil then return c end
        if VQ==nil then g_rd[page]=true; return true end
        local ok=false
        local r=tonumber(VQ(ffi.cast("const void*",a),g_mbi,48)) or 0
        if r~=0 then
            local st=ffi.cast("agr_u32*",ffi.cast("agr_u64",g_mbi)+0x20)[0]
            local pr=ffi.cast("agr_u32*",ffi.cast("agr_u64",g_mbi)+0x24)[0]
            if st==0x1000 and (pr%0x100)~=0x01 and pr<0x100 then ok=true end
        end
        g_rd[page]=ok
        return ok
    end
    local function q(a) if not is_readable(a) then return 0 end return tonumber(ffi.cast("agr_u64*",a)[0]) or 0 end
    local function r32(a) if not is_readable(a) then return 0 end return tonumber(ffi.cast("agr_u32*",a)[0]) or 0 end
    local function mz_base(dll)
        local e=tonumber(fe(dll,"CreateInterface") or 0); if e==0 then return 0 end
        local cb=e-e%0x1000
        while cb>0 do local p=ffi.cast("agr_u8*",cb); if p[0]==0x4D and p[1]==0x5A then break end; cb=cb-0x1000 end
        return cb
    end
    -- ── sig-scan (auto-relocates RVAs after a game update) ──
    function sg.imgsize(base)
        if base==0 or not is_readable(base+0x3C) then return 0 end
        local e=r32(base+0x3C); if e<=0 or e>0x1000 then return 0 end
        return r32(base+e+0x50)
    end
    function sg.match(a, pat)
        if not is_readable(a) then return false end
        local p=ffi.cast("agr_u8*",a)
        for j=0,#pat-1 do local b=pat[j+1]; if b>=0 and p[j]~=b then return false end end
        return true
    end
    function sg.find(base, size, pat)
        if base==0 or size==0 then return 0 end
        local first=pat[1]; local plen=#pat; local p=ffi.cast("agr_u8*",base); local B=tonumber(ffi.cast("agr_u64",base))
        for off=0,size-plen do
            if p[off]==first then
                local ok=true
                for j=1,plen-1 do local b=pat[j+1]; if b>=0 and p[off+j]~=b then ok=false; break end end
                if ok then return B+off end
            end
        end
        return 0
    end
    function sg.fnrva(base, size, hint, pat, tag)
        local B=tonumber(ffi.cast("agr_u64",base))
        if sg.match(B+hint, pat) then return hint end
        local f=sg.find(base, size, pat)
        if f==0 then log(string.format("SIG MISS %s: RVA %X is stale", tag, hint)); return hint end
        local nr=f-B; log(string.format("SIG %s: %X -> %X (%+d)", tag, hint, nr, nr-hint)); return nr
    end
    function sg.datarva(base, size, hint, sd, tag)
        local B=tonumber(ffi.cast("agr_u64",base))
        local f=sg.find(base, size, sd.pat)
        if f==0 then return hint,false end
        local disp=r32(f+sd.doff); if disp>=0x80000000 then disp=disp-0x100000000 end
        local nr=(f+sd.ilen+disp)-B
        return nr,true
    end
    function sg.ms2(MS)
        if sg.resolved then return end
        sg.resolved=true
        local sz=sg.imgsize(MS); if sz==0 then return end
        local B=tonumber(ffi.cast("agr_u64",MS))
        RVA_MATUNLOAD  =sg.fnrva(MS, sz, RVA_MATUNLOAD,   SIG.MATUNLOAD,   "MatUnload")
        RVA_SHADERSETUP=sg.fnrva(MS, sz, RVA_SHADERSETUP, SIG.SHADERSETUP, "ShaderSetup")
        RVA_MATNOTIFY  =sg.fnrva(MS, sz, RVA_MATNOTIFY,   SIG.MATNOTIFY,   "MatNotify")
        sg.reload_ok=sg.match(B+RVA_MATUNLOAD,SIG.MATUNLOAD) and sg.match(B+RVA_SHADERSETUP,SIG.SHADERSETUP)
                 and sg.match(B+RVA_MATNOTIFY,SIG.MATNOTIFY)   -- if any one fails -> call none of them (half measures break the material)
        log("reload triple: "..(sg.reload_ok and "OK" or "NOT resolved: material parameters will be dead"))
        RVA_FINDMAT=sg.fnrva(MS, sz, RVA_FINDMAT, SIG.FINDMAT, "FindMaterial")
        RVA_GRS    =sg.datarva(MS, sz, RVA_GRS, SIG.GRS, "g_rs")
        local islot,ok=sg.datarva(MS, sz, sg.iface_slot, SIG.IFACE, "iface_slot")
        sg.iface_slot=islot
        if ok then local this=q(MS+islot); if this~=0 then sg.iface_this=this end end
    end

    local SCENE=mz_base("scenesystem.dll"); if SCENE==0 then log("scenesystem base miss"); return end
    RVA_HOOK=sg.fnrva(SCENE, sg.imgsize(SCENE), RVA_HOOK, SIG.HOOK, "RenderObjects")
    local FN=SCENE+RVA_HOOK; local BACK=FN+DISP
    local fb=ffi.cast("agr_u8*",FN)
    if not is_readable(FN) then log("FN unreadable"); return end
    if fb[0]==0xFF and fb[1]==0x25 then
        log("stale hook -> restore"); local p=vprot(FN,DISP,0x40); for i=0,DISP-1 do fb[i]=ORIG[i+1] end; vprot(FN,DISP,p) end
    for i=0,DISP-1 do if fb[i]~=ORIG[i+1] then log(string.format("prologue mismatch off%d — abort",i)); return end end
    -- ── The item STRIDE is NOT hardcoded but DERIVED FROM CODE ────────────────────
    -- It sits right in the body of RenderObjects: advancing the pointer through the array = `add r64, imm8`
    -- (`48 83 C? xx`), e.g. three `add rbx,0x70` = three agreeing votes.
    -- If Valve reorders the RenderItem fields, the function is recompiled together with the immediate
    -- and we follow along automatically.
    local ITEM_STRIDE=0x70
    do
        local tally={}
        for off=0,0x5FF do
            if fb[off]==0x48 or fb[off]==0x49 then
                if fb[off+1]==0x83 and fb[off+2]>=0xC0 and fb[off+2]<=0xC7 then
                    local imm=fb[off+3]
                    if imm>=0x40 and imm<=0xC0 and imm%8==0 then tally[imm]=(tally[imm] or 0)+1 end
                end
            end
        end
        local best,bn=nil,0
        for imm,n in pairs(tally) do if n>bn then best,bn=imm,n end end
        if best==nil then
            log(string.format("item stride: could not derive, using %#x", ITEM_STRIDE))
        elseif best~=ITEM_STRIDE then
            log(string.format("⚠ item STRIDE CHANGED: %#x -> %#x (%d votes), using the new one", ITEM_STRIDE, best, bn))
            ITEM_STRIDE=best
        else
            log(string.format("item stride %#x confirmed by code (%d votes)", best, bn))
        end
    end
    log(string.format("scenesystem=%X FN=%X", SCENE, FN))

    -- ── material (find by name through the engine) ──
    local g_ms2=0
    local function get_ms2() if g_ms2~=0 then return g_ms2 end
        g_ms2=mz_base("materialsystem2.dll"); if g_ms2~=0 then sg.ms2(g_ms2) end; return g_ms2 end
    -- ⚠ Reads up to cap bytes, so a string near a page edge can run into the next, possibly unmapped,
    -- page. Every page crossed is checked.
    local function rstr(a,cap) if not is_readable(a) then return nil end
        local p=ffi.cast("agr_u8*",a); local o={}
        for i=0,(cap or 256)-1 do
            if (a+i)%0x1000==0 and not is_readable(a+i) then break end
            local b=p[i]; if b==0 then break end
            if b<0x20 or b>0x7E then return nil end; o[#o+1]=string.char(b)
        end
        if #o==0 then return nil end; return table.concat(o) end
    local function get_mat(obj)
        if obj==0 or not is_readable(obj) then return 0 end
        local mat=q(obj); if mat~=0 and is_readable(mat) then local vt=q(mat); if vt~=0 and is_readable(vt) and q(vt+0x30)~=0 then return mat end end
        local vt=q(obj); if vt~=0 and is_readable(vt) and q(vt+0x30)~=0 then return obj end
        return 0
    end
    local RVA_RESPRELOAD=0xB0
    local function preload_resource(name)
        local MS=get_ms2(); if MS==0 then return false end
        local g_rs=q(MS+RVA_GRS); if g_rs==0 then return false end
        local rsvt=q(g_rs); if rsvt==0 then return false end
        local slot=q(rsvt+RVA_RESPRELOAD); if slot==0 then return false end
        local cs=ffi.new("char[?]", #name+1, name)
        local arr=ffi.new("agr_u64[1]"); arr[0]=ffi.cast("agr_u64",cs)
        local req=ffi.new("agr_u8[64]"); local rp=ffi.cast("agr_u64",req)
        ffi.cast("agr_u32*",rp+0x00)[0]=1
        ffi.cast("agr_u64*",rp+0x08)[0]=ffi.cast("agr_u64",arr)
        ffi.cast("agr_u8*", rp+0x10)[0]=1
        ffi.cast("agr_u8*", rp+0x11)[0]=1
        ffi.cast("agr_u8*", rp+0x20)[0]=0xFF
        ffi.cast("void(__fastcall*)(void*,void*)", slot)(ffi.cast("void*",g_rs), ffi.cast("void*",req))
        return true
    end
    local function find_material_by_name(name)
        local MS=get_ms2(); if MS==0 then return 0,0 end
        preload_resource(name)
        local FM=ffi.cast("void(__fastcall*)(void*,void*,const char*)", MS+RVA_FINDMAT)
        local out=ffi.new("agr_u64[2]"); out[0]=0; out[1]=0
        local nb=ffi.new("char[?]", #name+1, name)
        local this_ptr=(sg.iface_this~=0) and sg.iface_this or (MS+IFACE_OFF)
        FM(ffi.cast("void*", this_ptr), ffi.cast("void*",out), nb)
        local handle=tonumber(out[0]) or 0
        log(string.format("  FM this=%X iface_this=%X handle=%X out1=%X", tonumber(ffi.cast("agr_u64",this_ptr)) or 0, sg.iface_this, handle, tonumber(out[1]) or 0))
        if handle==0 then return 0,0 end
        if is_readable(handle+0x20) then
            local rc=r32(handle+0x20)
            if rc>0 and rc<0x1000000 then ffi.cast("agr_u32*",handle+0x20)[0]=rc+0x1000000 end
        end
        return get_mat(handle), handle
    end
    local g_rl=nil
    local g_no_reload=false   -- set for KV3 materials, see set_mat
    -- SILENCES VALIDATOR WARNINGS ("attribute ... set in mode ... does not match Vector value set in
    -- another mode"). The check sits in CMaterial2::LoadShadersAndSetupModes and is disabled by the seventh
    -- argument of FUN_18000e3b0, which is out of reach: our third setup argument controls
    -- async shader compilation, not validation (FUN_1800103c0 param_4).
    -- So the channel is muted instead: it is registered by the NAME "MaterialSystem" (FUN_1800023f0), and
    -- LoggingSystem_IsChannelEnabled(channel,3) lets the warning through only at verbosity>=1.
    -- Set 0 for the duration of the triple and restore 2, the value from the registration itself.
    -- ⚠ errors on the same channel are muted for this short window too, but the window is only our own call.
    local function reload_material(mat, binding)
        if mat==0 or g_no_reload then return false end
        if g_rl==nil then
            local MS=get_ms2(); if MS==0 or not sg.reload_ok then return false end
            g_rl={unload=ffi.cast("void(__fastcall*)(void*)",           MS+RVA_MATUNLOAD),
                  setup =ffi.cast("void(__fastcall*)(void*,void*,int)", MS+RVA_SHADERSETUP),
                  notify=ffi.cast("void(__fastcall*)(void*)",           MS+RVA_MATNOTIFY),
                  mute  =api("tier0.dll","LoggingSystem_SetChannelVerbosityByName","void(__stdcall*)(const char*,int)"),
                  chan  =ffi.new("char[15]","MaterialSystem")}
        end
        local m=ffi.cast("void*",mat)
        if g_rl.mute then g_rl.mute(g_rl.chan, 0) end
        g_rl.unload(m)
        g_rl.setup(m, ffi.cast("void*",binding or 0), 1)   -- binding=NULL is allowed: the DynamicShaderCompile path calls it that way (38D99: xor edx,edx)
        g_rl.notify(m)
        if g_rl.mute then g_rl.mute(g_rl.chan, 2) end
        return true
    end
    local function find_param_record(mat, name)
        if mat==0 then return nil end
        local cnt=r32(mat+0x18); local base=q(mat+0x20)
        if base==0 then return nil end
        if cnt<=0 or cnt>256 then cnt=64 end
        for i=0,cnt-1 do local e=base+i*0x40
            if not is_readable(e) then break end
            if rstr(q(e+0x28),96)==name then return e end end
        return nil
    end
    -- ⚠ HOT PATH. rstr reads the shader name BYTE BY BYTE (up to 96 bytes) with a permission check per page,
    -- and pass_scan called it twice for each of the 64 ring entries: up to 12 thousand reads per pass.
    -- Cached by material pointer: a material's shader name does not change, and the cache is cleared together
    -- with all pointer state on map change.
    local g_shcache={}
    local function shader_of(mat)
        if mat==0 then return nil end
        local c=g_shcache[mat]; if c~=nil then if c==false then return nil end; return c end
        local pb=q(mat+0x20)
        local s=(pb~=0) and rstr(q(pb+0x30),96) or nil
        g_shcache[mat]=(s==nil) and false or s
        return s
    end

    -- ── MATERIAL BUILD FROM KV3 TEXT ─────────────────────────────────────────────
    -- Gives any shader + any textures without files, donors or name-length fitting.
    -- The parser interns the feature names itself; building the descriptor by hand crashed here.
    local RVA_KVMAT=0x3AFD0
    local SIG_KVMAT={0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,
                     0x48,0x89,0x7C,0x24,0x20,0x41,0x56,0x48,0x81,0xEC,0x10,0x01,0x00,0x00,0x48,0x8B,0x05}
    -- ⚠ SEARCH BY THE TAIL ONLY: the prologue matches TWO functions (0x3ADE0 and 0x3AFD0), a search
    -- by the head returns the first one. The tail (func+0x11E) is unique across the image.
    local SIG_KVMAT_T={0x44,0x0F,0xB6,0x84,0x24,0x48,0x01,0x00,0x00,0x48,0x8B,0xCB,0x80,0x4B,0x0B,0x08,
                       0x41,0x83,0xF0,0x01,0x48,0x8B,0x16}
    local KVMAT_TOFF=0x11E
    -- LoadKV3 is exported from tier0. tier0 has THREE overloads; this one (const char* text) is needed,
    -- the other two take CKV3Arena*/CUtlBuffer* and would silently accept the wrong argument.
    local KV3_EXPORT="?LoadKV3@@YA_NPEAVKeyValues3@@PEAVCUtlString@@PEBDAEBUKV3ID_t@@2I@Z"
    local KV3_HDR="<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d}\nformat:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->\n"
    -- KV3ID_t = { const char* name; uint64 d1; uint64 d2 }: 24 bytes, NAME AS THE FIRST FIELD.
    -- The public headers (two qwords) would give an 8-byte shift and parse garbage.
    local KV3_D1=0x469806e97412167cULL
    local KV3_D2=0xe73790b53ee6f2afULL
    local g_keep={}
    local g_kvfn=nil
    local g_loadkv3=nil
    local function get_kv3()
        if g_kvfn~=nil then return true end
        local MS=get_ms2(); if MS==0 then return false end
        local sz=sg.imgsize(MS)
        if sz>0 then
            local t=sg.find(MS,sz,SIG_KVMAT_T)
            if t~=0 then
                local nr=(t-tonumber(ffi.cast("agr_u64",MS)))-KVMAT_TOFF
                if nr~=RVA_KVMAT then log(string.format("SIG KVMaterial: %X -> %X (%+d)",RVA_KVMAT,nr,nr-RVA_KVMAT)) end
                RVA_KVMAT=nr
            end
        end
        if not sg.match(MS+RVA_KVMAT+KVMAT_TOFF, SIG_KVMAT_T) then log("KV3: tail not found"); return false end
        if not sg.match(MS+RVA_KVMAT, SIG_KVMAT) then log("KV3: head did not match"); return false end
        local lk=tonumber(fe("tier0.dll",KV3_EXPORT) or 0)
        if lk==0 then log("KV3: tier0!LoadKV3 not found"); return false end
        g_kvfn=ffi.cast("void(__fastcall*)(void*,void*,const char*,void*,int,agr_u8)", MS+RVA_KVMAT)
        g_loadkv3=ffi.cast("int(__fastcall*)(void*,void*,const char*,void*,const char*,agr_u32)", lk)
        log(string.format("KV3 ready: KVMaterial=%X LoadKV3=%X", MS+RVA_KVMAT, lk))
        return true
    end
    local function vstr(s)
        local p=VA(nil,0x1000,0x3000,0x04); if p==nil then return nil end
        ffi.copy(p, s, #s)                       -- the page is zeroed -> the terminator is in place
        g_keep[#g_keep+1]=p
        return p
    end
    -- kv3_build(name, body) -> mat  |  body = lines like '\tshader = "..."\n'
    local function kv3_build(name, body)
        if not get_kv3() then return 0 end
        local text=KV3_HDR.."{\n"..body.."}\n"
        -- ⚠⚠ BUFFERS NOT AT THE START OF A PAGE: KeyValues3 reads at -0x30 from its buffer (cluster
        -- header). VirtualAlloc returns the START of the region, there is no page before it -> crash. Use the middle.
        local pg=VA(nil,0x1000,0x3000,0x04); if pg==nil then return 0 end
        g_keep[#g_keep+1]=pg
        local pb=tonumber(ffi.cast("agr_u64",pg)) or 0; if pb==0 then return 0 end
        local err=pb+0x200; local idb=pb+0x400; local outb=pb+0x600; local kvb=pb+0x800
        local kv=ffi.cast("void*",kvb); local id=ffi.cast("void*",idb); local outp=ffi.cast("void*",outb)
        local gnm=vstr("generic"); if gnm==nil then return 0 end
        local mnm=vstr(name);      if mnm==nil then return 0 end
        ffi.cast("agr_u64*",idb+0x00)[0]=ffi.cast("agr_u64",gnm)
        ffi.cast("agr_u64*",idb+0x08)[0]=KV3_D1
        ffi.cast("agr_u64*",idb+0x10)[0]=KV3_D2
        log(string.format("KV3: calling LoadKV3 (text %d b, page %X)", #text, pb))
        local ok=tonumber(g_loadkv3(kv, ffi.cast("void*",err), text, id, nil, 0)) or 0
        if ok==0 then
            log("KV3: LoadKV3 failed: "..tostring(rstr(q(err),200)))
            for line in text:gmatch("[^\n]+") do log("    | "..line) end
            return 0
        end
        log("KV3: LoadKV3 ok, calling CreateMaterialFromKV3")
        g_kvfn(nil, outp, ffi.cast("const char*",mnm), kv, 0, 1)
        local h=q(outb); local mat=0
        if h~=0 and shader_of(h) then mat=h
        else local d=q(h); if d~=0 and shader_of(d) then mat=d end end
        if mat==0 then log(string.format("KV3: *out=%X, shader unreadable", h)); return 0 end
        log(string.format("KV3: material %s = %X [%s]", name, mat, shader_of(mat) or "?"))
        return mat
    end
    -- Recipes. ⭐ Key point: F_TRANSLUCENT selects the SHADER VARIANT, while the PASS is selected by
    -- the runtime attribute `Attributes { Translucent = 1 }` (parsed by FUN_180091d80: it asks the material
    -- for the "Translucent" attribute, hash 0x4adb6806, through vtable+0x48). Similar names, different meaning.
    -- ⚠ csgo_character has NO F_BLEND_MODE on this build: a nonexistent feature = PINK material.
    local TEX_TV="materials/models/props_interiors/tvanimstatic_color_mks_498c612d.vtex"
    -- default maps: the character shader expects more than just albedo
    local TEX_NORMAL="materials/default/default_normal_tga_7be39f77.vtex"
    local TEX_AO="materials/default/default_ao_tga_559f1ac6.vtex"
    local TEX_METAL="materials/default/default_metal_tga_dbfb4d6e.vtex"
    local KV3_RECIPES={
        {name="tv_char", label="TV / character", body=
            '\tshader = "csgo_character.vfx"\n'..
            '\tF_TRANSLUCENT = 1\n'..
            '\tF_DISABLE_Z_BUFFERING = 1\n\tF_DISABLE_Z_PREPASS = 1\n\tF_DISABLE_Z_WRITE = 1\n'..
            '\tg_vColorTint = [1.000000, 1.000000, 1.000000, 1.000000]\n'..
            '\tg_bFogEnabled = 0\n\tg_flMetalness = 0.000000\n'..
            '\tg_tColor = resource:"'..TEX_TV..'"\n'..
            '\tg_tNormal = resource:"'..TEX_NORMAL..'"\n'..
            '\tg_tAmbientOcclusion = resource:"'..TEX_AO..'"\n'..
            '\tg_tMetalness = resource:"'..TEX_METAL..'"\n'..
            '\tAttributes =\n\t{\n\t\tTranslucent = 1\n\t}\n'},
        {name="tv_char_opaque", label="TV / character opaque", body=
            '\tshader = "csgo_character.vfx"\n'..
            '\tg_vColorTint = [1.000000, 1.000000, 1.000000, 1.000000]\n'..
            '\tg_bFogEnabled = 0\n\tg_flMetalness = 0.000000\n'..
            '\tg_tColor = resource:"'..TEX_TV..'"\n'..
            '\tg_tNormal = resource:"'..TEX_NORMAL..'"\n'..
            '\tg_tAmbientOcclusion = resource:"'..TEX_AO..'"\n'..
            '\tg_tMetalness = resource:"'..TEX_METAL..'"\n'},
    }
    -- One-time dump of the material's REAL parameter list. Needed because only existing entries can be
    -- written, and a nonexistent feature = invalid combo = pink error material.
    -- csgo_effects features are not documented anywhere (the Valve wiki is empty), so the runtime is the only source of truth.
    local g_dumped={}
    local function dump_params(mat, tag)
        if mat==0 or g_dumped[mat] then return end
        g_dumped[mat]=true
        local cnt=r32(mat+0x18); local base=q(mat+0x20)
        if base==0 then return end
        local n=cnt; if n<=0 or n>256 then n=64 end
        local feats,other={},{}
        for i=0,n-1 do local e=base+i*0x40
            if not is_readable(e) then break end
            local nm=rstr(q(e+0x28),96)
            if nm then
                if nm:sub(1,2)=="F_" then feats[#feats+1]=nm else other[#other+1]=nm end
            end
        end
        table.sort(feats); table.sort(other)
        log(string.format("PARAMS %s [%s] cnt=%d", tag or "", shader_of(mat) or "?", cnt))
        log("  F_ features: "..(#feats>0 and table.concat(feats,", ") or "NONE"))
        log("  other: "..table.concat(other,", "))
    end
    -- Cogwheel: GEAR_PARAMS sliders.
    -- 🔑 FRESNEL SHAPE: why the values come from steam_001_additive and not the "Fatality recipe":
    --   the Fatality recipe (Min=1, Max=0.001, Exp=0.233) gets the rim by THRESHOLD: with Min/Max nearly equal
    --   the remap (f-Min)/(Max-Min) degenerates into a step, and a step over the interpolated N·V draws
    --   a contour line. Interpolation across a triangle is linear -> the contour breaks at the edges -> the
    --   TRIANGULATION BECOMES VISIBLE on the model. Small viewmodel geometry hid it, the agent showed it.
    --   steam_001_additive (same csgo_effects shader, NO triangles) gets the rim by POWER:
    --   the remap is off (Min=0, Max=1), thinness comes from Exp. A power curve is smooth -> nothing to break.
    -- => for a thinner rim raise Fres Exp, do NOT lower Fres Max toward zero.
    -- Scroll=0: our g_tColor is solid-colored, scrolling it is pointless.
    local GEAR_PARAMS={
        -- Glow: steam has a dark texture where values around 500 made sense; our g_tColor is white (1.0 everywhere),
        -- so the same Boost saturates. The default is the material's own value.
        {name="g_flColorBoost",         label="Glow",     min=0,   max=1000, def=1,     step=0.5,   fmt="%.1f"},
        {name="g_flOpacityScale",       label="Opacity",  min=0,   max=1,    def=0.533, step=0.01,  fmt="%.2f"},
        {name="g_flFresnelMin",         label="Fres Min", min=0,   max=1,    def=0,     step=0.01,  fmt="%.2f"},
        {name="g_flFresnelMax",         label="Fres Max", min=0,   max=1,    def=1,     step=0.01,  fmt="%.2f"},
        {name="g_flFresnelExponent",    label="Fres Exp", min=0,   max=16,   def=2.5,   step=0.05,  fmt="%.2f"},
        {name="g_flFresnelFalloff",     label="Fres Fall",min=0,   max=4,    def=1.55,  step=0.01,  fmt="%.2f"},
        {name="g_vTexCoordScrollSpeed", label="Scroll",   min=-1,  max=1,    def=0,     step=0.005, fmt="%.3f"},
    }
    -- 🛑 Pattern (g_vTexCoordScale), Feather (g_flFeatherDistance) and Feath Fall (g_flFeatherFalloff)
    -- are not exposed: they had no effect (find_param_record does not find the entry, write_f silently
    -- returns false; flat.vmat_c does not contain these names at all).
    -- Old cfgs clean themselves up: cfg_save walks GEAR_PARAMS, dropped names are not rewritten.
    local function write_f(mat, name, v)
        local e=find_param_record(mat, name); if not e then return false end
        ffi.cast("float*",e+0)[0]=v; ffi.cast("float*",e+4)[0]=v   -- .x and .y: vec2 parameters (scroll/scale)
        return true
    end
    local function write_tint(mat, r,g,b,a)
        local e=find_param_record(mat,"g_vColorTint"); if not e then return false end
        ffi.cast("float*",e+0)[0]=r; ffi.cast("float*",e+4)[0]=g; ffi.cast("float*",e+8)[0]=b; ffi.cast("float*",e+0xc)[0]=a
        return true
    end
    -- one cogwheel parameter
    -- Fatality glow recipe: F_ADDITIVE_BLEND + fresnel rim + bright tint (glow = tint × ColorBoost).
    -- All writes accumulate, Reload is called ONCE at the end (the triple is not free).
    local function apply_glow_recipe(mat, binding, r,g,b,a)
        if mat==0 then return false end
        for _,p in ipairs(GEAR_PARAMS) do write_f(mat, p.name, p.def) end
        write_tint(mat, r,g,b,a)
        write_f(mat, "F_ADDITIVE_BLEND", 1)
        return reload_material(mat, binding)
    end

    -- ── DATA + shellcode ──
    -- layout: +0x10 hits, +0x14 hits-sobj, +0x18 glowEn, +0x1C skip, +0x20 capOn, +0x28 glowMat,
    --   +0x50 tgtLflags(0=all), +0x60/0x68/0x80 saved p1/p2/R, +0x88 K, +0xC0 scratch-cursor,
    --   +0x800 ring idx, +0x808 sobj[64], +0xA08 mat[64], +0xC08 lflags[64]
    --   +0xB8 temporary slot for the matched target's material
    --   +0xE00 TGT: 16 entries of 16 bytes {sobj, material}. Pairs rather than two arrays, so the shellcode
    --   does not care how many sections there are: one compare loop, the material comes from the matched entry.
    --   Empty slots are filled with 0xFFFF... (NOT zero): an item's sobj can be 0 and would falsely match zeros.
    local dat=ffi.cast("agr_u8*",VA(nil,0x1000,0x3000,0x40)); if dat==nil then log("VA dat fail"); return end
    local DATA=ffi.cast("agr_u64",dat)
    local DNUM=tonumber(DATA)          -- q()/r32() reject cdata (is_readable: type~="number") -> read from DNUM
    local sc=ffi.cast("agr_u8*",VA(nil,0x1000,0x3000,0x40)); if sc==nil then log("VA sc fail"); return end
    local SC=ffi.cast("agr_u64",sc)
    -- ⭐ TWO scratch buffers, one per space: with a single shared buffer, in a frame with the agent enabled
    -- the world call and the viewmodel call would write into it in turn and overwrite each other.
    -- COMB: [originals(N≤2048) + glow copies(K≤64)] × 0x70
    local scb=ffi.cast("agr_u8*",VA(nil,0x40000,0x3000,0x40)); if scb==nil then log("VA scratch fail"); return end
    local SCRATCH=ffi.cast("agr_u64",scb)
    local scb2=ffi.cast("agr_u8*",VA(nil,0x40000,0x3000,0x40)); if scb2==nil then log("VA scratch2 fail"); return end
    local SCRATCH2=ffi.cast("agr_u64",scb2)
    ffi.cast("agr_u32*",DATA+0x50)[0]=COLOR_PASS
    -- the shellcode picks its scratch by space: +0x70 world, +0x78 viewmodel, the current one goes to +0xA8.
    -- ⚠ NOT 0x60/0x68: those hold param1/param2 of the original call for the second draw.
    ffi.cast("agr_u64*",DATA+0x70)[0]=SCRATCH
    ffi.cast("agr_u64*",DATA+0x78)[0]=SCRATCH2
    local tr=ffi.cast("agr_u8*",VA(nil,0x1000,0x3000,0x40)); if tr==nil then log("VA tramp fail"); return end
    local TRAMP=ffi.cast("agr_u64",tr)
    do local o=0; for _,b in ipairs(ORIG) do tr[o]=b; o=o+1 end
       tr[o]=0xFF; tr[o+1]=0x25; tr[o+2]=0; tr[o+3]=0; tr[o+4]=0; tr[o+5]=0; o=o+6
       local bk=tonumber(BACK); for i=0,7 do tr[o+i]=math.floor(bk/(2^(8*i)))%256 end end
    do
        local code={}; local lp={}; local pat={}; local abspat={}
        local function E(...) for _,b in ipairs({...}) do code[#code+1]=b%256 end end
        local function lbl(n) lp[n]=#code end
        local function jn(op2,n) E(0x0F,op2); local di=#code+1; E(0,0,0,0); pat[#pat+1]={di=di,endi=#code,label=n} end
        local function ju(n) E(0xE9); local di=#code+1; E(0,0,0,0); pat[#pat+1]={di=di,endi=#code,label=n} end
        local function imm64(v) for i=0,7 do E(math.floor(v/(2^(8*i)))%256) end end
        local d=tonumber(DATA); local tp=tonumber(TRAMP)
        -- ENTRY (push5, param_6=L at [rsp+0x58])
        E(0x50); E(0x51); E(0x52); E(0x41,0x52); E(0x41,0x53)      -- push rax,rcx,rdx,r10,r11
        E(0x49,0xBB); imm64(d)                                     -- mov r11,DATA
        E(0x41,0x8B,0x43,0x18)                                     -- mov eax,[r11+0x18] glowEn
        E(0x41,0x0B,0x43,0x20)                                     -- or eax,[r11+0x20]  capOn
        E(0x85,0xC0); jn(0x84,"DONE")
        E(0x48,0x8B,0x84,0x24,0x58,0x00,0x00,0x00)                 -- mov rax,[rsp+0x58] L
        E(0x48,0x85,0xC0); jn(0x84,"DONE")
        E(0x41,0xFF,0x43,0x10)                                     -- inc [r11+0x10] hits
        E(0x8B,0x48,0x48)                                          -- mov ecx,[rax+0x48] lflags low32 (keep ecx)
        E(0x49,0x8B,0x50,0x18)                                     -- mov rdx,[r8+0x18] sobj (item[0])
        E(0x48,0x85,0xD2); jn(0x84,"AFTERCAP")                     -- no sobj -> skip capture
        E(0x41,0xFF,0x43,0x14)                                     -- inc [r11+0x14] hits-sobj
        -- CAPTURE (rotating window): sobj+mat+lflags into rings
        E(0x41,0x83,0x7B,0x20,0x00); jn(0x84,"AFTERCAP")           -- cmp [r11+0x20]capOn,0 / je AFTERCAP
        -- ⭐ THE RING IS FILLED ONLY FROM THE VIEWMODEL VIEW AND ONLY FOR NON-DEPTH PASSES.
        -- The ring exists for the ring sections (hands/weapon), which live only in the viewmodel
        -- view; nobody needs world entries in it. Capturing from every view was costly: when shooting
        -- the world floods with calls (muzzle flash, tracer, impacts), the 64-slot ring filled with
        -- OTHER materials, and pass_scan ran shader_of over them every 8 frames: a string read from memory
        -- plus a VirtualQuery on a cold page for every new pointer. That caused microstutters while shooting.
        -- It also prevents eviction: particles no longer take the 64 slots, and viewmodel targets
        -- stop dropping out of the ring in combat.
        -- ⚠ rax is still L here (loaded above and untouched: 0x48 was read through it, sobj came from r8).
        E(0xF7,0xC1,0x00,0x00,0x00,0x01); jn(0x85,"AFTERCAP")      -- test ecx,0x1000000 / jnz: skip depth
        E(0x48,0xF7,0x80,0x80,0x04,0x00,0x00,0x00,0x01,0x00,0x00)  -- test qword[rax+0x480],0x100
        jn(0x84,"AFTERCAP")                                        -- jz: not the viewmodel view, skip
        E(0x41,0x83,0xBB,0x1C,0x00,0x00,0x00,0x00); jn(0x8E,"DOCAP") -- cmp [r11+0x1C]skip,0 / jle DOCAP
        E(0x41,0xFF,0x8B,0x1C,0x00,0x00,0x00); ju("AFTERCAP")       -- dec skip; skip>0 -> skip capture
        lbl("DOCAP")
        E(0x41,0x8B,0x83,0x00,0x08,0x00,0x00)                      -- mov eax,[r11+0x800] idx
        E(0x83,0xF8,0x40); jn(0x8D,"AFTERCAP")                     -- cmp eax,64 / jge (full)
        E(0x49,0x89,0x94,0xC3,0x08,0x08,0x00,0x00)                 -- mov [r11+rax*8+0x808],rdx sobj
        E(0x49,0x8B,0x50,0x20)                                     -- mov rdx,[r8+0x20] mat
        E(0x49,0x89,0x94,0xC3,0x08,0x0A,0x00,0x00)                 -- mov [r11+rax*8+0xA08],rdx mat
        E(0x41,0x89,0x8C,0x83,0x08,0x0C,0x00,0x00)                 -- mov [r11+rax*4+0xC08],ecx lflags
        E(0xFF,0xC0)                                               -- inc eax
        E(0x41,0x89,0x83,0x00,0x08,0x00,0x00)                      -- mov [r11+0x800],eax
        lbl("AFTERCAP")
        E(0x41,0x83,0x7B,0x18,0x00); jn(0x84,"DONE")               -- glowEn==0 → passthrough (capture-only)
        -- ⭐ ALWAYS skip DEPTH passes (bit 0x1000000): a re-draw on them crashes the engine
        E(0xF7,0xC1,0x00,0x00,0x00,0x01); jn(0x85,"DONE")          -- test ecx,0x1000000 / jnz DONE
        -- GATE: SPACE BY THE VIEW FLAG + STRICT PASS.
        -- ⭐ L+0x480 bit 0x100 is the engine's "this is the viewmodel view" flag. It is the only reliable way
        -- to tell the viewmodel from the world model (they share the skin material, so it cannot separate them).
        -- ⚠ A strict PASS alone gives single-frame dropouts, because the game draws the viewmodel with a
        -- different pass on some frames. Here the view flag selects the target set, and the pass is checked
        -- within that view.
        -- Without the view flag, the viewmodel set was applied on any non-depth pass, INCLUDING WORLD VIEWS.
        -- Viewmodel keys are material pointers, and the weapon's world model has THE SAME skin material,
        -- so third-person weapons and reflections got colored too.
        -- The world stays strict by pass: its keys are sobj, which show up in many world passes,
        -- and without strictness the agent would glow everywhere.
        -- ⚠ rax is NOT L here anymore: the capture clobbers it (mov eax,[r11+0x800]). Re-read from the stack:
        -- rsi/rdi are not pushed yet, so [rsp+0x58] still points to param_6.
        E(0x48,0x8B,0x84,0x24,0x58,0x00,0x00,0x00)                  -- mov rax,[rsp+0x58] L
        E(0x48,0xF7,0x80,0x80,0x04,0x00,0x00,0x00,0x01,0x00,0x00)   -- test qword[rax+0x480],0x100
        jn(0x84,"GWORLD")                                           -- jz -> not the viewmodel
        -- ⭐⭐ HARD SPLIT BY PERSPECTIVE. [r11+0x9C]: 1 = first person (only the viewmodel lives),
        -- 0 = third person (only the agent lives). The other space is dropped BEFORE any work:
        -- no items walk, no copies.
        E(0x41,0x83,0xBB,0x9C,0x00,0x00,0x00,0x01); jn(0x85,"DONE") -- cmp [r11+0x9C],1 / jne DONE
        -- ⭐ STRICT PASS FOR THE VIEWMODEL TOO: the gate is "view flag AND lflags==0x400005".
        -- With "view flag AND any non-depth" chams drew in all six viewmodel layers on some maps
        -- (e.g. Mirage) instead of one, and flickered.
        E(0x41,0x3B,0x8B,0x54,0x00,0x00,0x00); jn(0x85,"DONE")      -- cmp ecx,[r11+0x54] / jne DONE
        -- each space has ITS OWN scratch: agent and viewmodel in the same frame would overwrite a shared buffer
        E(0x49,0x8B,0x93,0x78,0x00,0x00,0x00)                       -- mov rdx,[r11+0x78] viewmodel scratch
        E(0x49,0x89,0x93,0xA8,0x00,0x00,0x00)                       -- mov [r11+0xA8],rdx
        E(0x49,0x8D,0x83,0x10,0x0E,0x00,0x00); ju("PSET")           -- lea rax,[r11+0xE10] viewmodel
        lbl("GWORLD")
        E(0x41,0x83,0xBB,0x9C,0x00,0x00,0x00,0x00); jn(0x85,"DONE") -- cmp [r11+0x9C],0 / jne DONE (world only in third person)
        E(0x41,0x3B,0x8B,0x50,0x00,0x00,0x00); jn(0x85,"DONE")      -- cmp ecx,[r11+0x50] / jne DONE
        E(0x49,0x8B,0x93,0x70,0x00,0x00,0x00)                       -- mov rdx,[r11+0x70] world scratch
        E(0x49,0x89,0x93,0xA8,0x00,0x00,0x00)                       -- mov [r11+0xA8],rdx
        E(0x49,0x8D,0x83,0x10,0x0D,0x00,0x00)                       -- lea rax,[r11+0xD10] world
        lbl("PSET")
        E(0x49,0x89,0x83,0xB0,0x00,0x00,0x00)                       -- mov [r11+0xB0],rax  selected set
        -- ⛔⛔ WRAP-TWICE CRASHES. Do not use it.
        -- It keeps the 2nd call's state (param1/param2 and the RETURN ADDRESS) in global DATA fields.
        -- There are many calls here: if another call (nested or from the render thread) enters between
        -- the 1st draw and STUB2, it overwrites the saved return address and STUB3 jumps into garbage.
        -- BATCH-GROW: COMB=[originals(N) + glow copies(K)], handed to RenderObjects ONCE.
        -- State lives only inside one call, so there is no foreign return address to clobber.
        E(0x41,0x81,0xF9,0x00,0x08,0x00,0x00); jn(0x83,"DONE")      -- cmp r9d,0x800 / jae DONE (the batch will not fit)
        E(0x56); E(0x57); E(0xFC)                                   -- push rsi; push rdi; cld
        -- ⭐ PRE-SCAN: does this call have at least one target? No -> leave WITHOUT memcpy.
        -- Without it the whole batch would be copied on every call that passed the gate, including world ones
        -- (hundreds of kilobytes per frame for nothing).
        E(0x4C,0x89,0xC2)                                           -- mov rdx,r8
        E(0x4D,0x63,0xD1)                                           -- movsxd r10,r9d
        lbl("PSITEM")
        E(0x4D,0x85,0xD2); jn(0x84,"PSNONE")                       -- test r10,r10 / jz PSNONE
        E(0x48,0x8B,0x4A,0x18)                                      -- mov rcx,[rdx+0x18] sobj
        E(0x48,0x8B,0x7A,0x20)                                      -- mov rdi,[rdx+0x20] the item's material
        E(0x49,0x8B,0x83,0xB0,0x00,0x00,0x00); E(0xBE,0x10,0x00,0x00,0x00) -- mov rax,[r11+0xB0]; mov esi,16
        lbl("PSCHK")
        E(0x48,0x3B,0x08); jn(0x84,"PSFOUND")                      -- cmp rcx,[rax] / je PSFOUND
        E(0x48,0x3B,0x38); jn(0x84,"PSFOUND")                      -- cmp rdi,[rax] / je PSFOUND
        E(0x48,0x83,0xC0,0x10); E(0xFF,0xCE); jn(0x85,"PSCHK")      -- add rax,16; dec esi
        E(0x48,0x83,0xC2,ITEM_STRIDE); E(0x49,0xFF,0xCA); ju("PSITEM") -- add rdx,stride; dec r10
        lbl("PSNONE")
        E(0x5F); E(0x5E); ju("DONE")                                -- pop rdi; pop rsi; leave without copying
        lbl("PSFOUND")
        -- copy ALL N originals into our buffer, then append the K colored copies at the tail
        E(0x4C,0x89,0xC6)                                           -- mov rsi,r8  src=originals
        E(0x49,0x8B,0xBB,0xA8,0x00,0x00,0x00)                       -- mov rdi,[r11+0xA8] our COMB
        E(0x49,0x63,0xC9)                                           -- movsxd rcx,r9d  N
        E(0x48,0x6B,0xC9,ITEM_STRIDE)                               -- imul rcx,rcx,stride
        E(0xF3,0xA4)                                                -- rep movsb (clobbers rsi,rdi,rcx)
        E(0x49,0x89,0xBB,0xC0,0x00,0x00,0x00)                       -- mov [r11+0xC0],rdi  tail = COMB+N*stride
        E(0x41,0xC7,0x83,0x88,0x00,0x00,0x00,0x00,0x00,0x00,0x00)   -- mov [r11+0x88],0  K=0
        E(0x4C,0x89,0xC2)                                           -- mov rdx,r8   item ptr
        E(0x4D,0x63,0xD1)                                           -- movsxd r10,r9d  remaining
        lbl("BITEM")
        E(0x4D,0x85,0xD2); jn(0x8E,"BDONE")                        -- test r10,r10 / jle BDONE
        E(0x48,0x8B,0x4A,0x18)                                      -- mov rcx,[rdx+0x18] sobj
        E(0x48,0x8B,0x7A,0x20)                                      -- mov rdi,[rdx+0x20] the item's material
        E(0x49,0x8B,0x83,0xB0,0x00,0x00,0x00); E(0xBE,0x10,0x00,0x00,0x00) -- mov rax,[r11+0xB0]; mov esi,16
        lbl("BCHK")
        -- The entry key is EITHER sobj OR material: both fields are compared. A pointer to an object and one to
        -- a material never coincide, so there are no false matches. This is what separates hands from the weapon:
        -- they can live in ONE sobj, but their items have different materials.
        E(0x48,0x3B,0x08); jn(0x84,"BMATCH")                       -- cmp rcx,[rax] / je BMATCH
        E(0x48,0x3B,0x38); jn(0x84,"BMATCH")                       -- cmp rdi,[rax] / je BMATCH
        E(0x48,0x83,0xC0,0x10); E(0xFF,0xCE); jn(0x85,"BCHK")       -- add rax,16; dec esi
        ju("BNEXT")
        lbl("BMATCH")
        E(0x48,0x8B,0x40,0x08)                                      -- mov rax,[rax+8] the material of THIS target
        E(0x49,0x89,0x83,0xB8,0x00,0x00,0x00)                       -- mov [r11+0xB8],rax
        E(0x41,0x83,0xBB,0x88,0x00,0x00,0x00,0x40); jn(0x8D,"BNEXT")-- cmp K,64 / jge BNEXT (cap)
        E(0x48,0x89,0xD6)                                           -- mov rsi,rdx  src=item
        E(0x49,0x8B,0xBB,0xC0,0x00,0x00,0x00)                       -- mov rdi,[r11+0xC0] dst
        E(0xB9,ITEM_STRIDE,0x00,0x00,0x00); E(0xF3,0xA4)            -- mov ecx,stride; rep movsb
        E(0x49,0x8B,0xBB,0xC0,0x00,0x00,0x00)                       -- mov rdi,[r11+0xC0] dst base
        E(0x49,0x8B,0x83,0xB8,0x00,0x00,0x00)                       -- mov rax,[r11+0xB8] the target's material
        E(0x48,0x89,0x47,0x20); E(0x48,0x89,0x47,0x28)              -- [rdi+0x20]=[rdi+0x28]=our material
        E(0xC7,0x47,0x50,0xFF,0xFF,0xFF,0xFF)                       -- [rdi+0x50]=white
        E(0xC7,0x47,0x54,0x00,0x00,0x80,0x3F)                       -- [rdi+0x54]=1.0f
        E(0x48,0x83,0xC7,ITEM_STRIDE); E(0x49,0x89,0xBB,0xC0,0x00,0x00,0x00) -- add rdi,stride; save
        E(0x41,0xFF,0x83,0x88,0x00,0x00,0x00)                       -- inc [r11+0x88] K++
        lbl("BNEXT")
        E(0x48,0x83,0xC2,ITEM_STRIDE); E(0x49,0xFF,0xCA); ju("BITEM") -- add rdx,stride; dec r10
        lbl("BDONE")
        E(0x5F); E(0x5E)                                            -- pop rdi; pop rsi (RSP=S-0x28)
        E(0x41,0x8B,0x83,0x88,0x00,0x00,0x00)                       -- mov eax,[r11+0x88] K
        E(0x85,0xC0); jn(0x84,"DONE")                               -- K=0 -> hand back the original r8/r9
        E(0x41,0x01,0xC1)                                           -- add r9d,eax  r9d = N + K
        E(0x4D,0x8B,0x83,0xA8,0x00,0x00,0x00)                       -- mov r8,[r11+0xA8]  hand over COMB
        lbl("DONE")
        E(0x41,0x5B); E(0x41,0x5A); E(0x5A); E(0x59); E(0x58)      -- pop r11,r10,rdx,rcx,rax
        for _,b in ipairs(ORIG) do E(b) end
        E(0xFF,0x25,0x00,0x00,0x00,0x00); imm64(tonumber(BACK))
        for _,p in ipairs(pat) do local dd=lp[p.label]-p.endi; if dd<0 then dd=dd+2^32 end
            for i=0,3 do code[p.di+i]=math.floor(dd/(2^(8*i)))%256 end end
        for _,p in ipairs(abspat) do local a=tonumber(SC)+lp[p.label]
            for i=0,7 do code[p.di+i]=math.floor(a/(2^(8*i)))%256 end end
        for i,b in ipairs(code) do sc[i-1]=b end
        log(string.format("shellcode %d bytes @%X", #code, tonumber(SC)))
    end
    local GlowEn  =ffi.cast("agr_u32*", DATA+0x18)
    local Skip    =ffi.cast("agr_u32*", DATA+0x1C)
    local CapOn   =ffi.cast("agr_u32*", DATA+0x20)
    local RingIdx =ffi.cast("agr_u32*", DATA+0x800)
    -- PERF/diagnostics are intentionally left out of the shellcode: that was 4 memory writes per
    -- RenderObjects call (44 per frame). If needed again, DATA+0x90..0xA4 are free.
    -- Two target sets of entries {sobj, material}: world and viewmodel. The shellcode picks the set
    -- by the current pass, see the gate.
    -- ⚠ 16 entries, not 8. With targeting by MATERIAL the viewmodel has many targets: for a weapon that is
    -- the body, parts, scope, knives have their own; eight slots were not enough and the rest was not drawn.
    local TGT_W=DATA+0xD10             -- world (agent)      0xD10..0xE10
    local TGT_V=DATA+0xE10             -- viewmodel          0xE10..0xF10
    local TGT_SLOTS=16
    local PassW=ffi.cast("agr_u32*", DATA+0x50)
    local PassV=ffi.cast("agr_u32*", DATA+0x54)
    local PASS_WORLD=0x400004
    local PASS_VM=0x400005
    -- SECTIONS. Each has its own target source, material, color and sliders.
    -- src: "agent" = through my pawn's rendc; "ring" = from the ring by the drawn material's shader.
    local SECS={
        {id="agent",  label="Agent",  src="agent", sh=nil,              space="w"},
        {id="hands",  label="Hands",  src="ring",  sh="csgo_character", space="v"},
        {id="weapon", label="Weapon", src="ring",  sh="csgo_weapon",    space="v"},
    }
    -- S.saved[material path] = {col="r,g,b,a", params={name=value}}: settings per "section+material" PAIR
    for _,S in ipairs(SECS) do S.on=false; S.mat=0; S.bind=0; S.sobjs={}; S.lastp={}; S.lastcol=nil; S.saved={} end
    GlowEn[0]=0; CapOn[0]=0

    local installed=false
    local function install()
        if installed then return end
        local p=vprot(FN,DISP,0x40)
        fb[0]=0xFF; fb[1]=0x25; fb[2]=0; fb[3]=0; fb[4]=0; fb[5]=0
        local s=tonumber(SC); for i=0,7 do fb[6+i]=math.floor(s/(2^(8*i)))%256 end
        vprot(FN,DISP,p); installed=true; log("hook ON")
    end
    local function uninstall()
        if not installed then return end
        GlowEn[0]=0; CapOn[0]=0
        local p=vprot(FN,DISP,0x40); for i=0,DISP-1 do fb[i]=ORIG[i+1] end; vprot(FN,DISP,p)
        installed=false; log("hook OFF")
    end

    -- ── identifying OUR sobj (needle scan) ──
    local function ptr_of(ent)
        if ent==nil or ent.GetPointer==nil then return 0 end
        return tonumber(ffi.cast("agr_u64", ffi.cast("void*", ent:GetPointer()))) or 0
    end
    local function local_pawn()
        if not(entities and entities.GetLocalPawn) then return nil end
        local p=entities.GetLocalPawn(); if p then return p end
        return nil
    end

    -- ── glow material ──
    local g_cur=nil                    -- section whose material was touched last (for do_find/diagnostics)
    local g_matcache={}
    local function slider_set(sl, v)
        if sl and sl.GetValue then local vp=sl:GetValue(); if vp and vp.Set then vp:Set(v) end end
    end
    -- after a material change the sliders show the recipe values, not their old ones:
    -- otherwise the very first tick would overwrite the fresh recipe with stale slider values.
    local function sync_sliders(S)
        S.lastp={}
        for _,p in ipairs(GEAR_PARAMS) do
            slider_set(S.sliders and S.sliders[p.name], p.def); S.lastp[p.name]=p.def
        end
    end
    -- ── MATERIAL SPLIT ───────────────────────────────────────────────────────────
    -- The same path = ONE instance in the engine. Three sections on a shared material would share color
    -- and sliders, and editing one would affect the other two. So each section gets its own file copy.
    -- Nothing needs patching in the copy: a different path alone makes it private (the engine keys by path),
    -- textures inside reference their own paths and resolve as usual.
    -- ⚠ THE COPY IS ALWAYS REFRESHED: an early "dst already exists" exit would keep a stale copy forever,
    -- with an outdated texture reference showing the error checkerboard. It is 4 KB per material pick,
    -- not per frame.
    local function copy_file(src, dst)
        if not(utils and utils.FileRead and utils.FileWrite and utils.FileExists) then return false end
        if not utils.FileExists(src) then return utils.FileExists(dst) end
        local b=utils.FileRead(src); if not b then return utils.FileExists(dst) end
        utils.FileWrite(dst, b)
        return utils.FileExists(dst)
    end
    -- "materials/chams/flat.vmat" + section agent -> "materials/chams/flat_agent.vmat"
    local function section_material(S, path)
        ensure_material()          -- the source must be on disk before we copy from it
        local dir,base=path:match("^(.*/)([^/]+)%.vmat$")
        if dir==nil then return path end
        local dst=dir..base.."_"..S.id..".vmat"
        if copy_file(dir..base..".vmat_c", dst.."_c") then return dst end
        log(string.format("copy for %s was not created: sections will share one instance (shared color)", S.label))
        return path
    end
    local function set_mat(S, name)
        local key=name
        if name:sub(1,4)~="kv3:" then
            -- 🛑 the file is not on disk yet: never show this path to the engine:
            -- it would cache the miss BY NAME and return the error material until the game restarts,
            -- even after the file is downloaded. Wait for DL.pump.
            if DL.miss[name] then return false end
            name=section_material(S, name); key=name
        else key=name.."@"..S.id end        -- kv3 is rebuilt for each section
        local c=g_matcache[key]
        local m,b,sh
        if c then m,b,sh=c.m,c.b,c.sh
        elseif name:sub(1,4)=="kv3:" then
            -- built from text instead of loading a file: no donor, no name-length fitting
            local rec=nil
            for _,r in ipairs(KV3_RECIPES) do if r.name==name:sub(5) then rec=r end end
            if rec==nil then log("no recipe "..name); return false end
            m=kv3_build(rec.name.."_"..S.id, rec.body); b=0; sh=shader_of(m) or "?"
            if m==0 then log("NOT built: "..name); return false end
            g_matcache[key]={m=m,b=b,sh=sh,kv3=true}
        else
            m,b=find_material_by_name(name); sh=shader_of(m) or "?"
            if m==0 or sh:lower():find("error") then
                log(string.format("NOT loaded: %s (mat=%X sh=%s)", name, m, sh)); return false end
            g_matcache[key]={m=m,b=b,sh=sh}
        end
        S.mat=m; S.bind=b
        -- 🛑 Do NOT Reload a KV3 material: CreateMaterialFromKV3 calls LoadShadersAndSetupModes itself
        -- at the end, and our triple (unload->setup->notify) would tear down the built material: crash.
        g_no_reload=g_matcache[key].kv3 and true or false
        dump_params(m, name)
        if not g_no_reload then apply_glow_recipe(m,b, 1,0.2,1,1) end
        sync_sliders(S)
        S.lastp={}; S.lastcol=nil
        log(string.format("%s = %s  mat=%X [%s]", S.label, name, m, sh))
        return true
    end
    local function load_glow(S)
        if S.mat~=0 then return true end
        ensure_material()
        for _,name in ipairs(GLOW_PATHS) do if set_mat(S, name) then S.path=name; return true end end
        log("no material loaded")
        return false
    end

    -- ── target identification: pawn -> m_CRenderComponent -> my scene objects ──
    -- Lifetime of a learned viewmodel target.
    -- The ring captures ONLY item[0] of each call. A material that is not first in its call
    -- reaches the ring only when the draw order happens to put it first. A short TTL makes such a
    -- target expire and stay missing until it lands in item[0] again, which shows as periodic flicker.
    -- A stale pointer is harmless: it simply matches nothing. So it is kept for a long time.
    -- ⚠ A TTL in FRAMES depends on fps (900 frames = 3 s at 300 fps and 15 s at 60).
    local VM_TTL=30000
    local ID_PERIOD=16                 -- a fresh TGT is only needed on respawn/model change; batch-grow handles flicker
    local ID_GRACE=ID_PERIOD*3
    local g_my_sobj={}                 -- [sobj]=frame of the last confirmation
    local FRAME=0
    -- The ring is only needed for hands/weapon (src="ring"): their original materials come from there.
    -- g_char_sobj is only a "capture has warmed up" marker now, it no longer drives targets.
    local g_char_sobj={}               -- [sobj]=frame of the last confirmation by a character material
    -- ⛔ No reverse needle "linker" scan over {pawn,gsn,rendc,coll}: it walked foreign memory
    -- (0xFF8 × 0x7F8 dereferences) and caused 0xC0000005. The chain below comes from the binary
    -- and needs no guessing.
    -- ⭐ Entity -> its scene objects. The layout comes from client.dll, not from guessing:
    --   CModelState::SetupModel creates the sobj and attaches it with an updater
    --   FUN_1801d1420: append into the component's CUtlVector -> rendc+0x38 count, +0x40 data, +0x48 capacity
    --   FUN_1803aedc0: updater (0x68 bytes)          -> +0x00 CSkeletonInstance(gsn), +0x20 sobj
    -- That the vector belongs to CRenderComponent was checked against its constructor FUN_1801bf810:
    -- +0x38=0, +0x40=0, +0x50=0, +0x54=0xF, +0x58=1, +0xA8=1 matched.
    -- ⚠ Never scan rendc+0..0x2000: CRenderComponent is 0xD0 bytes
    -- (alloc+memset 0xd0 in CEntityComponent::CAllocator<CRenderComponent>::Allocate), anything beyond
    -- is neighboring heap allocations (and 0xC0000005).
    local function ent_sobjs(ent, out)
        local n=0
        if ent==nil then return n end
        local base=ptr_of(ent); if base==0 then return n end
        local ra=ent["m_CRenderComponent"]; if ra==nil or ra.offset==nil then return n end
        local rc=q(base+ra.offset); if rc==0 or not is_readable(rc) then return n end
        local gsn=0
        local ga=ent["m_pGameSceneNode"]
        if ga~=nil and ga.offset~=nil then gsn=q(base+ga.offset) end
        local cnt=r32(rc+0x38) or 0
        local arr=q(rc+0x40)
        if cnt<=0 or cnt>64 or arr==0 or not is_readable(arr) then return n end
        for i=0,cnt-1 do
            local u=q(arr+i*8)
            if u~=0 and is_readable(u) then
                -- +0x00 must be the gsn of the same entity: a foreign updater cannot end up here,
                -- and if it does not match the layout has moved; returning nothing is better than coloring garbage
                if gsn==0 or q(u)==gsn then
                    local so=q(u+0x20)
                    if so~=0 and is_readable(so) then out[so]=true; n=n+1 end
                end
            end
        end
        return n
    end
    local function my_sobjs()
        local out={}
        ent_sobjs(local_pawn(), out)
        return out
    end
    -- EVERY frame: current sobj from rendc -> TGT (zero delay when the scene object is rebuilt).
    -- Collect {sobj, material} pairs across all ENABLED sections and put them into TGT.
    -- The material is written next to the target, so sections can have different ones.
    local function id_tgt()
        for so in pairs(my_sobjs()) do g_my_sobj[so]=FRAME end
        for so,fr in pairs(g_my_sobj) do
            if FRAME-fr>ID_GRACE then g_my_sobj[so]=nil end -- a dead sobj drops off within a couple of cycles
        end
        local ours={}
        for _,S in ipairs(SECS) do if S.mat~=0 then ours[S.mat]=true end end
        for _,S in ipairs(SECS) do
            if S.src=="agent" then S.sobjs=g_my_sobj
            else for k,fr in pairs(S.sobjs) do
                -- the key is sobj now and cannot be our material; the guard is kept as insurance
                -- in case of going back to a material key, it costs a single comparison
                if ours[k] or FRAME-fr>VM_TTL or g_my_sobj[k] then S.sobjs[k]=nil end
            end end
        end
        local kw,kv=0,0
        for _,S in ipairs(SECS) do
            -- ⚠ DIFFERENT EXPIRY. The agent comes from rendc and is refreshed every cycle -> short grace.
            -- Hands/weapon come FROM THE RING, and the ring is filled only during capture, which is turned off
            -- after warm-up for fps. The viewmodel is stable, so it gets a longer expiry.
            local ttl=(S.src=="ring") and VM_TTL or ID_GRACE
            -- S.act is set by the present callback based on third person; do_find may call us before it
            local act=S.act; if act==nil then act=S.on end
            if act and S.mat~=0 then
                -- ⚠ THE ITERATION ORDER IS DETERMINISTIC. pairs() over a hash table yields keys in an order
                -- that changes on inserts (and we insert on every capture). With more targets than slots,
                -- without sorting every rewrite of the set would pick a DIFFERENT subset, and weapon parts
                -- would drop in and out of the set, which looks like flicker.
                local keys={}
                for k in pairs(S.sobjs) do keys[#keys+1]=k end
                table.sort(keys)
                for _,so in ipairs(keys) do
                    local fr=S.sobjs[so]
                    if (FRAME-fr)<=ttl then
                        local base,k
                        if S.space=="w" then base,k=TGT_W,kw else base,k=TGT_V,kv end
                        if k<TGT_SLOTS then
                            ffi.cast("agr_u64*",base+k*16)[0]=ffi.cast("agr_u64",so)
                            ffi.cast("agr_u64*",base+k*16+8)[0]=ffi.cast("agr_u64",S.mat)
                            if S.space=="w" then kw=kw+1 else kv=kv+1 end
                        elseif not S.warned then
                            S.warned=true
                            log(string.format("%s: more than %d targets, the rest are not drawn", S.label, TGT_SLOTS))
                        end
                    end
                end
            end
        end
        -- ⚠ empty slots = 0xFFFF..., NOT 0: an item's sobj can be zero and would falsely match zero
        for i=kw,TGT_SLOTS-1 do
            ffi.cast("agr_u64*",TGT_W+i*16)[0]=ffi.cast("agr_u64",-1)
            ffi.cast("agr_u64*",TGT_W+i*16+8)[0]=0
        end
        for i=kv,TGT_SLOTS-1 do
            ffi.cast("agr_u64*",TGT_V+i*16)[0]=ffi.cast("agr_u64",-1)
            ffi.cast("agr_u64*",TGT_V+i*16+8)[0]=0
        end
    end
    -- less often: learn char-object vtables from the ring + collect the passes of my sobj
    -- Item fields cannot be checked by signatures, so the VALUES behind them are checked:
    -- +0x20 must hold a material (its shader name reads as a real .vfx string),
    -- +0x18 a scene object (a valid vtable as the first field). If nothing matched over a whole ring window,
    -- the fields have moved: silently reading garbage is worse than saying so loudly.
    local g_fld_ok=false
    local g_fld_warned=false
    local function verify_fields(nseen, ngood)
        if g_fld_ok or g_fld_warned or nseen<8 then return end
        if ngood>0 then g_fld_ok=true
            log(string.format("item fields confirmed: %d/%d entries gave material+sobj", ngood, nseen))
        else g_fld_warned=true
            log("⚠⚠ item FIELDS NOT CONFIRMED: no ring entry gave a material at +0x20")
            log("   after a game update this is the first thing to re-check")
        end
    end
    local function pass_scan()
        local n=tonumber(RingIdx[0]) or 0; if n>64 then n=64 end
        local nseen,ngood=0,0
        for i=0,n-1 do
            local so=q(DNUM+0x808+i*8); local mt=q(DNUM+0xA08+i*8); local lf=r32(DNUM+0xC08+i*4)
            if so~=0 then
                nseen=nseen+1
                local sh=shader_of(mt) or ""
                if sh:find("%.vfx") and q(so)~=0 then ngood=ngood+1 end
                local shl=sh:lower()
                if shl:find("character") then g_char_sobj[so]=FRAME end
                -- ring sections (hands/weapon) are identified by the SHADER of the drawn material.
                -- ⭐ THE KEY IS SOBJ, not the material.
                -- A material key would catch the WORLD hands: the world model and the viewmodel share THE SAME material
                -- (shared skin/agent), and the L+0x480 flag is on the VIEW: in the main first-person view the engine
                -- draws both the viewmodel and your own body. Symptom: world hands showing up in first person.
                -- These two objects have different sobj, so they can be told apart by it.
                -- Also explicitly drop the scene objects of OUR OWN world model: their set is known exactly
                -- from the render component (g_my_sobj), no guessing needed.
                -- The viewmodel pass filter is required: the agent's body also uses the csgo_character shader.
                if lf==PASS_VM and mt~=0 and not g_my_sobj[so] then
                    for _,S in ipairs(SECS) do
                        if S.src=="ring" and S.sh and shl:find(S.sh,1,true) then S.sobjs[so]=FRAME end
                    end
                end
            end
        end
        verify_fields(nseen, ngood)
        -- No window rotation (Skip=(FRAME%8)*64): there are only about 38 RenderObjects calls per frame,
        -- so the whole frame fits into the 64-entry ring. Skipping made capture drop out for several frames
        -- in a row, and since hands/weapon depend entirely on the ring, the target expired and the glow
        -- flickered.
        Skip[0]=0
        RingIdx[0]=0
    end
    -- list of passes of my sobj (for Next Pass); color pass = without the depth bit 0x1000000

    -- ── UI ──
    local ui=false
    -- Panel height: 3 rows (one per section) + header; 110 would fit the content.
    -- 170 keeps the columns in the Other sub-tab EQUAL: the top panels there are the same height
    -- (How to use = Weapon Skin Recolor = 235), so the bottom ones must match too, otherwise the columns
    -- end at different heights.
    local CHAMS_H=187
    local function cid(s) return (gui and gui.ctx and gui.ctx.NextID and gui.ctx:NextID()) or s end
    -- selected combo item index (1-based). A single combo's GetRaw() returns
    -- either a 0-based index or a bitmask 1,2,4…, told apart by checking for a power of two.
    local function combo_index(ctrl)
        if not ctrl or not ctrl.GetValue then return nil end
        local vp=ctrl:GetValue(); if not vp or not vp.Get then return nil end
        local bits=vp:Get(); if not bits or not bits.GetRaw then return nil end
        local raw=bits:GetRaw()
        if raw==nil or type(raw)~="number" or raw<0 then return nil end
        raw=math.floor(raw)
        if raw==0 then return 1 end
        local t=raw; local pow2=true
        while t>1 do if t%2~=0 then pow2=false; break end; t=math.floor(t/2) end
        if pow2 then return math.floor(math.log(raw)/math.log(2))+1 end
        return raw+1
    end
    -- Inverse of combo_index: sets the SELECTION, not just the internal state.
    -- Without it the config would restore the material (S.path/S.mat) while the combo kept showing the first
    -- item, which looks like "settings were not restored".
    -- Writes a bitmask: a single combo returns 1,2,4… and combo_index reads exactly that.
    local function combo_set(ctrl, index)
        if not ctrl or not ctrl.GetValue or type(index)~="number" or index<1 then return false end
        local vp=ctrl:GetValue(); if not vp or not vp.Get or not vp.Set then return false end
        local bits=vp:Get(); if not bits or not bits.SetRaw then return false end
        bits:SetRaw(math.floor(2^(index-1)))
        vp:Set(bits)
        return true
    end
    local function path_index(p)
        for i,v in ipairs(GLOW_PATHS) do if v==p then return i end end
        return nil
    end
    -- ⭐ AGENT AND VIEWMODEL ARE NEVER ACTIVE AT THE SAME TIME.
    -- In first person the agent is not visible, in third person the hands and weapon are not: no point
    -- coloring both, and it rules out any interference between the two spaces by design.
    -- The ACTUAL state is used, not the menu checkbox: the checkbox may be on a hotkey, and the cheat can
    -- simulate third person itself (m_bInThirdPersonOverride).
    -- ⚠ there is no pcall in the sandbox: linear nil guards only.
    local function in_thirdperson()
        if game==nil then return false end
        local i=game.input; if i==nil then return false end
        if i.m_bInThirdPerson==true then return true end
        if i.m_bInThirdPersonOverride==true then return true end
        return false
    end
    -- In a sniper scope OUR material showed up in the lens: the targets stayed in the set and the viewmodel
    -- view did not go away (the scope pass belongs to it). Passes cannot tell this apart, so the state
    -- is asked from the pawn directly.
    local g_scope_warned=false
    local function is_scoped()
        local p=local_pawn(); if p==nil then return false end
        local f=p.m_bIsScoped
        if f==nil or f.Get==nil then
            if not g_scope_warned then g_scope_warned=true; log("m_bIsScoped unavailable, scope gate disabled") end
            return false
        end
        return f:Get()==true
    end
    -- ⭐ What matters is not the zoom itself but ANOTHER checkbox: "remove in scope" hides the viewmodel in scope.
    --   on -> no viewmodel -> nothing to color (that was the artifact in the lens);
    --   off -> the viewmodel is there -> color as usual.
    -- A container cannot enumerate its children (Container only has Add/Remove/Find), so the path is looked up
    -- from a list of candidates and the one that worked is REPORTED: guessing a string silently is the same as
    -- having no diagnostics.
    local SCOPE_CB_PATHS={
        "visuals>local>viewmodel>remove in scope",
        "visuals>local>view model>remove in scope",
        "visuals>local>viewmodel>remove_in_scope",
    }
    local g_scope_cb=nil
    local g_scope_tries=0
    local function scope_hides_vm()
        if g_scope_cb==nil and g_scope_tries<10 then
            -- the cheat menu may be built later than us, so not "once on load" but a few
            -- rare attempts; after that stop calling Find every frame
            if FRAME%60==0 or g_scope_tries==0 then
                g_scope_tries=g_scope_tries+1
                if gui and gui.ctx and gui.ctx.Find then
                    for _,p in ipairs(SCOPE_CB_PATHS) do
                        local c=gui.ctx:Find(p)
                        if c~=nil and c.Get~=nil then g_scope_cb=c; log("scope checkbox found: "..p); break end
                    end
                end
                -- ⚠ FAILURE IS PRINTED BYPASSING CM_VERBOSE. The path is guessed from the description, and if it is wrong
                -- this is the only clue; in the merged build log is muted. Success is silent: it shows in the behavior.
                if g_scope_cb==nil and g_scope_tries>=10 then
                    print("[chams] 'remove in scope' checkbox not found, not coloring in scope. Tried:")
                    for _,p in ipairs(SCOPE_CB_PATHS) do print("[chams]    "..p) end
                end
            end
        end
        -- ⚠ FALLBACK = "hides". If the checkbox is not found, keep the behavior that fixes the visible artifact
        -- in the lens; the opposite default would silently bring the original bug back.
        if g_scope_cb==nil then return true end
        return g_scope_cb:Get()==true
    end
    -- is the section active RIGHT NOW (S.on = what the user picked, S.act = what is actually being colored)
    local function sec_active(S)
        local a=S.act; if a==nil then a=S.on end
        return a
    end
    -- 1 = first person (the viewmodel lives), 0 = third person (the agent lives), 2 = NOTHING (scope).
    -- The shellcode gate compares for equality with 1 and with 0, so any third value cuts off BOTH
    -- spaces before walking items; no separate branch in machine code is needed.
    local Space=ffi.cast("agr_u32*", DATA+0x9C)
    local g_last_pawn=-1                        -- map change/respawn: the pawn pointer changes
    local g_prev_tp=nil                         -- last seen third-person state
    -- DATA+0x90..0x9B are free (formerly diagnostic counters).
    -- Section row = [Label Mat] combo + ColorPicker + cogwheel with sliders.
    -- Enable sits on its own row above it, otherwise the checkbox gets lost among the controls.
    -- ── SETTINGS PERSISTENCE (text, debounce, applied after build_ui) ────────────────────────────
    -- Line format: sec|<id>|<on 0/1>|<r,g,b,a>|<material path>|<name>=<value> <name>=<value> ...
    -- The material is stored by PATH, not index: the GLOW_PATHS list may change and an index would shift.
    -- Config path: in the merged build everything goes into the Map manager folder (it declares CM_CFG_DIR and
    -- moves the old file there once); in a standalone chams.lua the global is missing and the old location stays.
    local CFG={path=(CM_CFG_DIR and (CM_CFG_DIR.."/chams.cfg")) or "fatality/chams.cfg",
               pend=nil, last=nil, save_in=0}
    local function cfg_ok()
        return utils and utils.FileWrite and utils.FileRead and utils.FileExists
           and utils.StringToArray and utils.ArrayToString
    end
    local function save_soon() CFG.save_in=90 end
    local function set_checkbox(cb, v)
        if cb and cb.GetValue then local vp=cb:GetValue(); if vp and vp.Set then vp:Set(v and true or false) end end
    end
    local function set_picker(pk, r,g,b,a)
        if not(pk and pk.GetValue and draw and draw.Color) then return end
        local vp=pk:GetValue(); if vp and vp.Set then vp:Set(draw.Color(r,g,b,a)) end
    end
    -- ⭐ SETTINGS PER "SECTION + MATERIAL" PAIR. Each section has its own file copy (section_material),
    -- and color and knobs are picked separately for each material, so switching materials does not
    -- overwrite them.
    local DEF_COL="255,51,255,255"     -- what apply_glow_recipe sets (tint 1,0.2,1,1)
    -- ⭐⭐ THE WEAPON SECTION ALSO HAS A SET PER WEAPON.
    -- The weapon key is the item's def-index (`GetDefIndex`): a number that does not depend on language or
    -- on how the weapon is named in different parts of the API. Knives and grenades are included like guns.
    -- The material stays SHARED per section (one combo in the UI); color and knobs are per weapon.
    -- Hands and agent are not tied to weapons: their key is just the path.
    local PER_WEAPON={weapon=true}
    -- ⭐ HANDS AND AGENT HAVE A SET PER TEAM. The difference from weapons is fundamental: there are only two
    -- teams, so the checkbox here is ONE PER SECTION and is not reset on team change (for weapons it is tied
    -- to a specific weapon and re-read for each). Hence the flag is stored differently:
    -- for weapons inside the set itself (st.off), here in the section's config line.
    -- The agent is included for the same reason: T and CT models differ, no need to color them the same.
    -- ⛔ WEAPONS ARE INTENTIONALLY NOT HERE: they must not get a second checkbox. The team split is
    -- built into "Per weapon" itself (different teams on the same weapon have different skins), so a
    -- separate toggle would only multiply states.
    local PER_TEAM={hands=true, agent=true}
    local function local_team()
        local p=local_pawn(); if p==nil then return nil end
        local a=p.m_iTeamNum; if a==nil or a.Get==nil then return nil end
        local t=a:Get()
        if t==2 then return "T" elseif t==3 then return "CT" end
        return nil
    end
    local function active_def()
        local p=local_pawn(); if p==nil or p.GetActiveWeapon==nil then return nil end
        local w=p:GetActiveWeapon(); if w==nil or w.GetDefIndex==nil then return nil end
        local d=w:GetDefIndex()
        if type(d)~="number" or d<=0 then return nil end
        return d
    end
    -- Set key: "<path>" or "<path>@<def>". The '@' separator never appears in paths.
    -- ⭐ A personal set is used ONLY if it exists and is not disabled by the "Per weapon" checkbox.
    -- Otherwise the shared set of the path (the default) is shown and edited.
    -- st.off=true = "the set is remembered but not used right now": unchecking must not erase
    -- what was tuned, otherwise a stray click would destroy the work.
    -- ⭐ COMPOSITE KEY: <path>[@<weapon>[@<team>]] or <path>[@<team>].
    -- For weapons the team COMES WITH "Per weapon" (one checkbox, two splits); for hands and agent
    -- the team is enabled by their own "Per team". Without the checkbox a section uses the shared set of the path.
    local function store_key(S, path)
        if path==nil then return nil end
        local k=path
        if PER_WEAPON[S.id] and S.def~=nil then
            local wk=path.."@"..S.def
            local st=S.saved[wk]
            -- a set exists for this weapon and is not disabled: build from it
            if st~=nil and not st.off then
                k=wk
                if S.team~=nil then k=k.."@"..S.team end
                return k
            end
        end
        if PER_TEAM[S.id] and S.pt and S.team~=nil then k=k.."@"..S.team end
        return k
    end
    -- ⚠ STRIP ALL SUFFIXES, not just the last one: cfg_save groups sets BY key_path, and a key that does
    -- not reduce to its path is silently left out of the file ("path@7@T" must become "path").
    -- Cut from the FIRST '@': material paths do not contain it, so everything after it is our suffixes.
    local function key_path(k) return (k:match("^([^@]*)@")) or k end
    -- does THIS WEAPON have an active personal set (state of the "Per weapon" checkbox).
    -- ⚠ The marker lives on the key WITHOUT the team: the checkbox is about the weapon, not the "weapon+team" pair.
    local function per_weapon_on(S)
        if not PER_WEAPON[S.id] or S.def==nil or S.path==nil then return false end
        local st=S.saved[S.path.."@"..S.def]
        return (st~=nil and not st.off) and true or false
    end
    local function store_of(S, path)
        local k=store_key(S, path); if k==nil then return nil end
        local st=S.saved[k]
        if st==nil then st={col=DEF_COL, params={}}; S.saved[k]=st end
        return st
    end
    -- Create a set for the current key if missing. Values come from the PARENT, the same key
    -- without the last suffix ("path@7@T" -> "path@7" -> "path"), and if that is missing too, from the screen.
    -- The idea is the same for every checkbox: enabling a split must not change the picture, it should only
    -- detach this weapon/team from the shared set. From then on it lives its own life.
    local function seed_set(S, k, parent)
        if k==nil then return nil end
        local have=S.saved[k]; if have~=nil then return have end
        local base=parent and S.saved[parent] or nil
        if base==nil and parent~=nil then base=S.saved[key_path(k)] end
        local ps={}
        if base~=nil then for n,v in pairs(base.params) do ps[n]=v end
        else for n,v in pairs(S.lastp) do ps[n]=v end end
        local st={col=(base and base.col) or S.lastcol or DEF_COL, params=ps}
        S.saved[k]=st
        return st
    end
    local function ensure_set(S)
        local k=store_key(S, S.path); if k==nil then return end
        seed_set(S, k, k:match("^(.+)@[^@]+$"))
    end
    -- Called AFTER set_mat: that one resets lastp/lastcol to the recipe defaults through sync_sliders,
    -- so the saved values are applied on top. Anything missing from the set stays at the GEAR_PARAMS default.
    local function restore_settings(S)
        local st=S.saved[store_key(S, S.path)]; if st==nil or S.mat==0 then return end
        local r,g,b,a=(st.col or DEF_COL):match("(%d+),(%d+),(%d+),(%d+)")
        if r then
            r,g,b,a=tonumber(r),tonumber(g),tonumber(b),tonumber(a)
            set_picker(S.picker, r,g,b,a)
            S.lastcol=string.format("%d,%d,%d,%d",r,g,b,a)
            write_tint(S.mat, r/255,g/255,b/255,a/255)
        end
        for _,p in ipairs(GEAR_PARAMS) do
            local v=st.params[p.name] or p.def
            slider_set(S.sliders and S.sliders[p.name], v)
            S.lastp[p.name]=v
            write_f(S.mat, p.name, v)
        end
        S.dirty="material change"
    end
    -- "Paste other team" button: copy the other team's set into the current one.
    -- Works for hands/agent (<path>@TEAM) and for weapons (<path>@weapon@TEAM): the team suffix
    -- is always last in the key, so that is what gets replaced.
    -- ⚠ "@T$" does not match "@CT": the character before the final T there is 'C', not '@'.
    -- ⚠ Declared AFTER restore_settings on purpose: declared earlier, the call would go to a global, i.e. nil.
    local function paste_other_team(S)
        if S.team==nil or S.path==nil or S.mat==0 then return end
        local cur=store_key(S, S.path); if cur==nil then return end
        local stem=cur:match("^(.+)@"..S.team.."$")
        if stem==nil then log("the team is not part of the set right now, nothing to copy from"); return end
        local other=(S.team=="T") and "CT" or "T"
        local from=S.saved[stem.."@"..other]
        if from==nil then log("the other team has no set yet"); return end
        local ps={}
        for n,v in pairs(from.params) do ps[n]=v end
        S.saved[cur]={col=from.col, params=ps}
        restore_settings(S)
        save_soon()
    end
    local function select_mat(S, path)
        if not set_mat(S, path) then return false end
        S.path=path
        store_of(S, path)            -- a material counts as configurable from the moment it is picked
        restore_settings(S)
        return true
    end
    -- ⚠ THE ORDER IS DETERMINISTIC: walk GLOW_PATHS, not pairs(S.saved). pairs over a hash table
    -- yields keys in varying order, the text would differ between saves, and the comparison
    -- with CFG.last would stop catching "nothing changed": the file would be rewritten for nothing.
    -- Side benefit: sets for paths that dropped off the list are cleaned up automatically.
    local function cfg_save()
        if not cfg_ok() then return end
        local t={}
        for _,S in ipairs(SECS) do
            -- 5th field = the "Per team" checkbox (a section flag, not a set flag, unlike "Per weapon",
            -- which lives in the set itself as the off field). Old lines without it read as off.
            t[#t+1]=string.format("sec|%s|%d|%s|%d", S.id, S.on and 1 or 0, S.path or "", S.pt and 1 or 0)
        end
        for _,S in ipairs(SECS) do
            for _,path in ipairs(GLOW_PATHS) do
                -- one path can now have several sets (per weapon): collect them
                -- and SORT them: deterministic text keeps the comparison with CFG.last
                -- catching "nothing changed"
                local keys={}
                for k in pairs(S.saved) do if key_path(k)==path then keys[#keys+1]=k end end
                table.sort(keys)
                for _,k in ipairs(keys) do
                    local st=S.saved[k]
                    local ps={}
                    for _,p in ipairs(GEAR_PARAMS) do
                        local v=st.params[p.name]
                        if v then ps[#ps+1]=string.format("%s=%.4f",p.name,v) end
                    end
                    -- 6th field = "the set is remembered but the checkbox is off". The old parser simply ignores it,
                    -- and without it unchecking would have to delete the set.
                    t[#t+1]=string.format("mat|%s|%s|%s|%s|%d",
                        S.id, k, st.col or DEF_COL, table.concat(ps," "), st.off and 1 or 0)
                end
            end
        end
        local text=table.concat(t,"\n")
        if text==CFG.last then return end
        utils.FileWrite(CFG.path, utils.StringToArray(text)); CFG.last=text
    end
    local function cfg_load()
        if not cfg_ok() or not utils.FileExists(CFG.path) then return end
        local b=utils.FileRead(CFG.path); if not b then return end
        local str=utils.ArrayToString(b); if type(str)~="string" then return end
        CFG.pend={}
        local function ent(id)
            local e=CFG.pend[id]; if e==nil then e={saved={}}; CFG.pend[id]=e end; return e
        end
        local function parse_params(s)
            local out={}
            for tok in (s or ""):gmatch("%S+") do
                local nm,v=tok:match("([^=]+)=(.+)"); if nm then out[nm]=tonumber(v) end
            end
            return out
        end
        local nmat=0
        for line in (str.."\n"):gmatch("([^\n]*)\n") do
            local seg={}
            for x in (line.."|"):gmatch("([^|]*)|") do seg[#seg+1]=x end
            if seg[1]=="sec" and seg[2] and seg[2]~="" then
                local e=ent(seg[2])
                e.on=(seg[3]=="1")
                -- OLD FORMAT: sec|id|on|r,g,b,a|path|params (one set per section).
                -- Detected by the 4th field: it used to be the color, now it is the path. Moved into the set of the material
                -- that was selected back then, otherwise the tuned values would be lost silently.
                if (seg[4] or ""):match("^%d+,%d+,%d+,%d+$") then
                    local p=(seg[5]~="" and seg[5] or nil)
                    e.path=p
                    if p then e.saved[p]={col=seg[4], params=parse_params(seg[6])}; nmat=nmat+1 end
                else
                    e.path=(seg[4]~="" and seg[4] or nil)
                    e.pt=(seg[5]=="1")
                end
            elseif seg[1]=="mat" and seg[2] and seg[3] and seg[3]~="" then
                -- off is stored as nil/true, not false: a nil field does not affect set comparison
                -- and in old configs (without the 6th field) gives exactly the same result as before
                ent(seg[2]).saved[seg[3]]={col=seg[4], params=parse_params(seg[5]),
                                           off=(seg[6]=="1") or nil}
                nmat=nmat+1
            end
        end
        log(string.format("cfg loaded (settings sets: %d)", nmat))
    end
    -- Applied AFTER build_ui: before that the controls do not exist and there is nothing to Set.
    -- ⚠ the combobox is NOT set: its raw value is ambiguous (index or bitmask), so the
    -- material is loaded directly by the saved path, and S.last_sel is synced with what the combo actually
    -- shows; otherwise the very first poll would switch the material to the item selected there.
    local function cfg_apply()
        if CFG.pend==nil then return end
        for _,S in ipairs(SECS) do
            local e=CFG.pend[S.id]
            if e then
                S.saved=e.saved or {}
                -- ⚠ a path from the config is accepted ONLY if it is still on the list: old configs
                -- reference materials/vmchams/*, the files are there and would load, but the combo
                -- has no such item, so the section would silently switch to a material not visible in the UI.
                local idx=e.path and path_index(e.path) or nil
                if idx then
                    -- The combo is ALWAYS moved, even if the material does not load right now: the item list
                    -- does not depend on the file being present, and showing the wrong item would mislead the user.
                    combo_set(S.combo, idx); S.last_sel=idx
                    -- select_mat applies this material's set on top of the recipe defaults itself
                    if not select_mat(S, e.path) then
                        S.path=e.path   -- the file is not there yet (downloading): remember the path, the poll will pick it up
                    end
                elseif e.path then
                    log(string.format("%s: material %s is no longer on the list, using the first one", S.label, e.path))
                end
                -- ⚠ S.pt is set BEFORE set_checkbox: the tick compares the control with S.pt and would take
                -- the restore from config for a user click (extra restore + config write)
                if PER_TEAM[S.id] then S.pt=e.pt and true or false; set_checkbox(S.pt_cb, S.pt) end
                set_checkbox(S.en_cb, e.on)
            end
        end
        CFG.pend=nil
    end
    -- ONE row per section: <name> [checkbox] [color] [cogwheel] [material].
    -- ⚠ CONTROLS ARE ADDED IN REVERSE VISUAL ORDER: the main control from MakeControl sits on the RIGHT, and each
    -- row:Add goes LEFT of the previous one. So add right to left: cogwheel, color, checkbox.
    local function build_row(parent, S)
        local combo=gui.ComboBox and gui.ComboBox(cid("ch_"..S.id.."_mat")); if not combo then return end
        for i,path in ipairs(GLOW_PATHS) do
            combo:Add(gui.Selectable(cid("ch_"..S.id.."_m"..i), path:match("([^/]+)%.vmat$") or path))
        end
        S.combo=combo
        local row=gui.MakeControl(S.label, combo); parent:Add(row)
        local gear=gui.Settings and gui.Settings(cid("ch_"..S.id.."_gear"))
        if gear then row:Add(gear)
            -- FIRST row of the cogwheel: it decides WHERE all the other knobs of this section go
            if PER_WEAPON[S.id] and gui.Checkbox then
                S.pw_cb=gui.Checkbox(cid("ch_"..S.id.."_pw"))
                if S.pw_cb then gear:Add(gui.MakeControl("Per weapon", S.pw_cb)) end
            end
            if PER_TEAM[S.id] and gui.Checkbox then
                S.pt_cb=gui.Checkbox(cid("ch_"..S.id.."_pt"))
                if S.pt_cb then gear:Add(gui.MakeControl("Per team", S.pt_cb)) end
            end
            -- Copy the other team's set into the current one. Present on every section where the team
            -- can be part of the key at all; when it cannot, the button does nothing and writes to the log.
            if (PER_WEAPON[S.id] or PER_TEAM[S.id]) and gui.Button then
                local pb=gui.Button(cid("ch_"..S.id.."_paste"), "Paste other team")
                if pb then
                    gear:Add(pb)
                    if pb.AddCallback then pb:AddCallback(function() paste_other_team(S) end) end
                end
            end
            S.sliders={}
            for _,p in ipairs(GEAR_PARAMS) do
                local sl=gui.Slider and gui.Slider(cid("ch_"..S.id.."_"..p.name), p.min, p.max, {p.fmt}, p.step)
                if sl then S.sliders[p.name]=sl; gear:Add(gui.MakeControl(p.label, sl)) end
            end
        end
        S.picker=gui.ColorPicker and gui.ColorPicker(cid("ch_"..S.id.."_col"), true)
        if S.picker then row:Add(S.picker) end
        S.en_cb=gui.Checkbox and gui.Checkbox(cid("ch_"..S.id.."_en"))
        if S.en_cb then row:Add(S.en_cb) end
    end
    local function build_ui(stack_only)
        if ui then return true end
        if not(gui and gui.ctx and gui.Group and gui.MakeControl and gui.Button and gui.Checkbox) then return false end
        local parent=WSR_SKIN_PARENT or gui.ctx:Find("lua>groups")
        if not parent then return false end
        local wm=(gui.GroupWidthMode and gui.GroupWidthMode.DEFAULT) or 0
        -- 3 sections × 2 rows (checkbox + material).
        local g=gui.Group(cid("ch_grp"),"Chams",CHAMS_H,wm); if not g then return false end
        if not stack_only then parent:Add(g) end
        for _,S in ipairs(SECS) do build_row(g, S) end
        g:Reset()
        if not stack_only and parent~=WSR_SKIN_PARENT then parent:Reset() end
        ui=true
        log("UI ready — Chams")
        if stack_only then return g end
        return true
    end
    CHAMS_BUILD_UI = build_ui
    CHAMS_PANEL_H = CHAMS_H   -- group height, the host needs it to size the stack

    local function pk_rgba(pk)
        if not pk or not pk.GetValue then return nil end
        local vp=pk:GetValue(); if not vp or not vp.Get then return nil end
        local c=vp:Get(); if not c or not c.GetR then return nil end
        local a=c.GetA and c:GetA() or 255
        return c:GetR(), c:GetG(), c:GetB(), a
    end
    local g_glow_warm=0
    local CAP_WARM=150   -- capture frames after enabling Glow: learn char-vtable + passes, then OFF
    local function has(t) for _ in pairs(t) do return true end return false end
    local present=events and (events.presentQueue or events.present_queue)
    if present and present.Add then present:Add(function()
        FRAME=FRAME+1
        if FRAME%RD_TTL==0 then g_rd={} end
        -- ⚠⚠ MAP CHANGE = ALL OUR POINTERS GO STALE AT ONCE.
        -- Otherwise: crash 0xC0000005 on map change: the engine frees thousands of pages, while the g_rd permission
        -- cache keeps claiming they are readable for up to RD_TTL frames, and q()/rstr() read freed memory.
        -- Detected by the pawn pointer: it changes on map change and respawn, and becomes 0 while loading.
        -- Materials of the previous map are freed too, so g_matcache and S.mat are zeroed; the section
        -- re-acquires the material itself (see the S.mat==0 branch in the poll below).
        do
            local p=local_pawn()
            local pp=(p~=nil) and ptr_of(p) or 0
            if pp~=g_last_pawn then
                g_last_pawn=pp
                g_rd={}                       -- page permissions of the old map mean nothing anymore
                g_matcache={}; g_shcache={}
                g_my_sobj={}; g_char_sobj={}
                -- S.def is reset too: the weapon is different after respawn, and the d~=S.def comparison
                -- would not fire otherwise, leaving the section on the previous map's set
                -- S.def/S.team are reset too: both weapon and team differ after a map change,
                -- and the d~=S.def / tm~=S.team comparisons would not fire otherwise, leaving the sections
                -- on the previous map's sets. The "Per team" checkbox (S.pt) is NOT touched: it is the user's choice.
                for _,S in ipairs(SECS) do
                    S.sobjs={}; S.mat=0; S.bind=0; S.lastp={}; S.lastcol=nil
                    S.def=nil; S.team=nil; S.key=nil
                end
                RingIdx[0]=0
                -- A map change is the only free retry point if the downloader did not finish
                -- (no network at startup). The attempt counter is reset, otherwise no retry is possible.
                if not DL.active and has(DL.miss) then DL.tries={}; DL.scan() end
            end
        end
        DL.pump()
        -- ⚠ cfg_apply is OUTSIDE the UI build branch. In the merged version the HOST builds the panel (it calls
        -- build_ui itself to place it in the right column), so by our first tick ui is already true,
        -- and a config restore inside "if not ui" would never run.
        -- cfg_apply itself is idempotent: after the first application CFG.pend=nil and it exits right away.
        if not ui then build_ui(); if not ui then return end end
        cfg_apply()
        if CFG.save_in>0 then CFG.save_in=CFG.save_in-1; if CFG.save_in==0 then cfg_save() end end
        -- Sections: enable, material pick. The hook master flag = at least one is ACTIVE.
        for _,S in ipairs(SECS) do
            local on=S.en_cb and S.en_cb:Get() and true or false
            if on~=S.on then S.on=on
                if on then
                    if S.mat==0 then
                        local sel=combo_index(S.combo)
                        if sel and GLOW_PATHS[sel] then select_mat(S, GLOW_PATHS[sel]) else load_glow(S) end
                    end
                    g_cur=S; g_glow_warm=CAP_WARM
                end
                log(S.label..(on and " ON" or " OFF")); save_soon()
            end
        end
        -- ⭐ Third person decides WHAT is colored: the agent OR the viewmodel, never both.
        -- Computed AFTER the checkbox update, otherwise S.act would lag a frame behind.
        local tp=in_thirdperson()
        -- ⭐ The scope cuts ONLY THE VIEWMODEL. "remove in scope" hides hands and weapon and does not
        -- affect the agent: in third person zoom hides nothing, and the agent is colored as usual.
        -- So third person goes to 0 right away without checks, which also avoids querying
        -- m_bIsScoped and Find there (the checkbox lookup attempts are spent only where needed).
        -- The ring is never touched: viewmodel targets must survive zoom, otherwise after
        -- leaving the scope the hands would stay without chams until the set is rebuilt by TTL.
        local sp
        if tp then sp=0                                        -- agent: scope is irrelevant
        elseif is_scoped() and scope_hides_vm() then sp=2      -- no viewmodel: color nothing
        else sp=1 end
        Space[0]=sp                            -- the shellcode drops the other space right in the gate
        local anyon=false
        for _,S in ipairs(SECS) do
            S.act=S.on and ((S.src=="agent")==tp)
            if S.act then anyon=true end
        end
        if tp~=g_prev_tp then g_prev_tp=tp
            log(tp and "third person: coloring the agent" or "first person: coloring hands/weapon")
        end
        if anyon and GlowEn[0]==0 then
            PassW[0]=PASS_WORLD; PassV[0]=PASS_VM; GlowEn[0]=1
            log("chams ON")
        elseif (not anyon) and GlowEn[0]~=0 then
            GlowEn[0]=0; g_glow_warm=0; log("chams OFF")
        end
        -- capture writes the ring on EVERY RenderObjects call (hot) -> cache misses -> fps drop.
        -- It is only needed to learn char-vtable + passes (constants). Once learned -> OFF. Runtime glow
        -- does not read the ring: pre-scan takes TGT from rendc directly (id_tgt), it does not need capture.
        -- g_char_sobj lives by TTL and is refilled only during capture. A short confirmation every 600
        -- frames is cheaper than a full re-arm after the targets expired and the glow already dropped.
        -- The confirmation rate depends on what is enabled. The agent comes from rendc and rarely needs the
        -- ring. Hands/weapon take original materials ONLY from the ring, and a weapon switch brings a new
        -- material: with a 600-frame period the weapon would go without chams for about ten seconds.
        -- Capture is cheap: about 38 calls per frame.
        local vmon=false
        for _,S in ipairs(SECS) do if sec_active(S) and S.src=="ring" then vmon=true end end
        -- with vmon capture is constant anyway -> no warm-up cycle needed (it only spammed the log)
        if GlowEn[0]~=0 and not vmon and g_glow_warm==0 and FRAME%600==0 then g_glow_warm=30 end
        if g_glow_warm>0 then
            g_glow_warm=g_glow_warm-1
            if has(g_char_sobj) and has(g_my_sobj) and g_glow_warm>20 then g_glow_warm=20 end
            if g_glow_warm==0 then log("capture warmup done -> OFF (vtable/passes learned)") end
        end
        -- ⚠ WITH THE VIEWMODEL ENABLED, CAPTURE IS CONSTANT.
        -- Its targets (the items' original materials) come ONLY from the ring, and the ring is filled
        -- only during capture. With a capture window (e.g. 20 frames out of 120) targets would run on stale
        -- data, and a material swap lasting a couple of frames would go unnoticed until the next window.
        -- The cost is small: about 38 RenderObjects calls per frame.
        CapOn[0]=(g_glow_warm>0 or vmon) and 1 or 0
        -- Color and sliders: for each enabled section separately, EVERY frame.
        -- Only control values are read here: no syscalls, and Reload still happens
        -- at most once per section per frame (coalesced by the dirty flag).
        -- Parameters are written WITHOUT Reload, the section is only marked dirty: otherwise dragging a slider
        -- would cause up to nine rebuilds in one tick.
        -- ⚠ HOT: polling runs EVERY frame (otherwise edits arrive with a delay), and that is ~13 gui API
        -- calls per section. So only the ACTIVE section is polled: in first person the agent is not drawn,
        -- there is nothing to tune, and values are re-read on view change anyway.
        -- ⭐ AND ONLY WHILE THE MENU IS OPEN. Combo, color, sliders and "Per weapon" physically cannot
        -- change while the menu is closed; reading them in combat would burn ~13 gui API calls per section
        -- every frame for nothing.
        -- 🛑 THE SECTION ENABLE CHECKBOX IS NOT GATED: it may be on a hotkey and change
        -- while the menu is closed (same reason third person is taken from game.input rather than from
        -- the checkbox). It is polled unconditionally earlier in the tick.
        local menu_open=(gui and gui.IsVisible and gui.IsVisible()) and true or false
        for _,S in ipairs(SECS) do
            -- material lost (map change) or not downloaded yet: re-acquire silently.
            -- ⚠ also try without S.path: on a fresh install there may be no config at all, and the
            -- section would stay empty until the combo is clicked by hand.
            if sec_active(S) and S.mat==0 then
                if S.path then select_mat(S, S.path) else load_glow(S) end
            end
            -- ⭐ ONE POINT FOR ALL SPLITS: update the SOURCE data of the key (weapon, team, checkboxes),
            -- and the decision is made by comparing the key itself: if it changed, we switched,
            -- no matter which of the three changed.
            if sec_active(S) and S.mat~=0 then
                -- "Per weapon": the checkbox is tied to the WEAPON IN HAND and re-read for each new one.
                -- It also enables the team split: weapons have no separate toggle.
                if PER_WEAPON[S.id] then
                    local d=active_def()
                    if d~=S.def then
                        S.def=d
                        local on=per_weapon_on(S)
                        set_checkbox(S.pw_cb, on); S.pw_last=on
                    elseif menu_open and S.pw_cb~=nil and d~=nil and S.path~=nil then
                        local on=S.pw_cb:Get() and true or false
                        if on~=S.pw_last then
                            S.pw_last=on
                            local wk=S.path.."@"..d
                            if on then
                                -- the "this weapon has its own set" marker lives on the key WITHOUT the team;
                                -- the per-team values are created by ensure_set below
                                local st=seed_set(S, wk, S.path)
                                if st~=nil then st.off=nil end
                            else
                                local st=S.saved[wk]
                                if st~=nil then st.off=true end   -- remembered but not used
                            end
                        end
                    end
                end
                -- "Per team" for hands and agent: ONE checkbox per section, not reset on team change.
                if PER_TEAM[S.id] and menu_open and S.pt_cb~=nil then
                    S.pt=S.pt_cb:Get() and true or false
                end
                -- The team is ALWAYS read: it can change with the menu closed.
                S.team=local_team()
                local k=store_key(S, S.path)
                if k~=S.key then
                    S.key=k
                    ensure_set(S)
                    restore_settings(S)   -- sets the controls, writes into the material and marks it dirty
                    save_soon()
                end
            end
            if menu_open and sec_active(S) and S.mat~=0 then
                local sel=combo_index(S.combo)
                if sel and GLOW_PATHS[sel] and sel~=S.last_sel then
                    S.last_sel=sel; g_cur=S
                    select_mat(S, GLOW_PATHS[sel])   -- restores the set if this material was tuned before
                    save_soon()
                end
                -- every edit goes into the set of this section's CURRENT material
                local st=store_of(S, S.path)
                if S.picker then
                    local r,gg,b,a=pk_rgba(S.picker)
                    if r then local key=string.format("%d,%d,%d,%d",r,gg,b,a)
                        if key~=S.lastcol then
                            S.dirty=true
                            S.lastcol=key; save_soon()
                            if st then st.col=key end
                            write_tint(S.mat, r/255,gg/255,b/255,a/255)
                        end
                    end
                end
                if S.sliders then
                    for _,p in ipairs(GEAR_PARAMS) do local sl=S.sliders[p.name]
                        if sl and sl.GetValue then local v=sl:GetValue():Get()
                            if v and v~=S.lastp[p.name] then
                                S.dirty=true
                                S.lastp[p.name]=v; save_soon()
                                if st then st.params[p.name]=v end
                                write_f(S.mat, p.name, v)
                            end
                        end
                    end
                end
            end
        end
        -- NO DELAY: applied in the same frame the edit was seen. The dirty flag coalesces:
        -- no matter how many knobs moved in a tick, there is one Reload per section.
        -- ⚠ the hook is muted during Reload, and rendering runs on its own thread -> frames that land in that window
        -- come out uncolored. So dirty is set ONLY by an actual control edit.
        for _,S in ipairs(SECS) do
            if S.dirty and S.mat~=0 then
                S.dirty=nil
                local em=tonumber(GlowEn[0]) or 0; GlowEn[0]=0
                reload_material(S.mat, S.bind); GlowEn[0]=em
            end
        end
        -- while capture or glow is active, keep TGT fresh (respawn/agent change)
        if CapOn[0]~=0 or GlowEn[0]~=0 then
            if FRAME%8==0 then pass_scan() end         -- less often: learn vtables + collect passes
            if FRAME%ID_PERIOD==0 then id_tgt()
                if GlowEn[0]~=0 and g_glow_warm==0 and not has(g_my_sobj) then
                    g_glow_warm=CAP_WARM; log("re-arm capture (agent lost: respawn/model change)")
                end
            end
        end
    end) else error("[chams] presentQueue unavailable") end

    cfg_load()
    install()
    local __prev_shutdown = __shutdown
    function __shutdown()
        cfg_save(); uninstall()
        if __prev_shutdown then __prev_shutdown() end
    end
    log("loaded: Chams: Agent / Hands / Weapon. Section checkbox -> material in the combo.")

end)
-- ================== /Chams ==================

-- ================== Friend Whitelist (merged from whitelist_friend.lua) ==================
-- The panel goes into the "Other" sub-tab UNDER Weapon Skin Recolor: both sit
-- in the second vertical column, just as How to use + Chams sit in the first.
-- The HOST builds it through WLF_BUILD_UI(true), otherwise its own tick would place it as a separate third
-- column in the row and it would overflow the menu frame.
-- Its own tick stays as a fallback: it only fires if there is no host (standalone run).
-- Wrapped in protected_call: the locals live in their own function (LuaJIT limit: 200 locals per
-- function), and a top-level return stops only the whitelist, not the whole Map manager.
-- Group height; the host uses it for the column size too.
-- Both columns of the sub-tab must end at the same height, and their top panels are equal
-- (How to use 235 = Weapon Skin Recolor 235), so the bottom ones must be equal too, and they only
-- change together with CHAMS_H in the chams block.
WLF_PANEL_H = 187
protected_call(function()
    -- whitelist_friend.lua

    if not (entities and events and gui) then return end

    -- In the merged build the file moves into the Map manager folder (it declares CM_CFG_DIR and moves
    -- the old one once); in a standalone whitelist_friend.lua the global is missing and the old location stays.
    local FILE             = (CM_CFG_DIR and (CM_CFG_DIR.."/whitelist_friends.txt"))
                             or "fatality/whitelist_friends.txt"   -- "sid|name" per line
    local MAX_PLAYER_SLOTS = 12

    local function log(...) if CM_VERBOSE then print("[wlf]", ...) end end

    -- NO pcall in Fatality: this is a nil-guard on the callee, NOT error protection.
    local function protected_call(fn, ...)
        if fn == nil then return false, nil end
        return true, fn(...)
    end

    -- ── whitelist state ──
    local WL       = {}   -- sid(string) -> name(string)
    local WL_ORDER = {}   -- ordered sids (stable display / removal)

    local function order_remove(sid)
        for i = #WL_ORDER, 1, -1 do if WL_ORDER[i] == sid then table.remove(WL_ORDER, i) end end
    end

    -- ── persistence ──
    local function save()
        if not (utils and utils.FileWrite and utils.StringToArray) then return end
        local parts = {}
        for _, sid in ipairs(WL_ORDER) do
            parts[#parts + 1] = sid .. "|" .. (WL[sid] or "")
        end
        local content = table.concat(parts, "\n")
        local ok, arr = protected_call(utils.StringToArray, content)
        if ok and arr then protected_call(utils.FileWrite, FILE, arr) end
    end

    local function load()
        if not (utils and utils.FileExists and utils.FileRead and utils.ArrayToString) then return end
        local ok_ex, ex = protected_call(utils.FileExists, FILE)
        if not (ok_ex and ex) then return end
        local ok_rd, raw = protected_call(utils.FileRead, FILE)
        if not (ok_rd and raw) then return end
        local ok_s, str = protected_call(utils.ArrayToString, raw)
        if not (ok_s and str) then return end
        for line in str:gmatch("[^\r\n]+") do
            local sid, nm = line:match("^([^|]+)|?(.*)$")
            if sid and sid ~= "" then
                if WL[sid] == nil then WL_ORDER[#WL_ORDER + 1] = sid end
                WL[sid] = nm or ""
            end
        end
    end

    -- ── helpers ──
    local function local_sid()
        local lc = entities.GetLocalController and entities:GetLocalController()
        if lc and lc.GetStringSteamID then return lc:GetStringSteamID() end
        return nil
    end

    -- live runtime exposes lowercase `add` (docs say `Add`); probe both.
    local function add_child(parent, child)
        if not parent or not child then return false end
        local add_fn = parent.Add or parent.add
        if not add_fn then return false end
        local ok = protected_call(add_fn, parent, child)
        return ok
    end

    -- 1-based index of the selected row. Selection = bitmask (bit N-1 => row N): decode via
    -- GetRaw, fall back to per-bit probing (bits are 0-based). nil when nothing selected.
    local function selected_index(ctrl)
        if not ctrl or not ctrl.GetValue then return nil end
        local vp = ctrl:GetValue(); if not vp or not vp.Get then return nil end
        local bits = vp:Get(); if not bits then return nil end
        if bits.GetRaw then
            local raw = bits:GetRaw()
            if type(raw) == "number" then
                local int_raw = math.floor(raw)
                if int_raw <= 0 then return nil end
                local idx = 1
                while int_raw > 0 do
                    if (int_raw % 2) == 1 then return idx end
                    int_raw = math.floor(int_raw / 2)
                    idx = idx + 1
                end
                return nil
            end
        end
        if bits.Get then
            for i = 0, 63 do
                local v = bits:Get(i)
                if v == true or v == 1 then return i + 1 end
            end
        end
        return nil
    end

    -- ── driver ──
    local enabled_cb = nil
    local text_cb    = nil
    local text_color = nil
    local function cb_on(cb)
        if not cb then return false end
        if cb.GetValue then local v = cb:GetValue(); if v and v.Get then return v:Get() == true end end
        if cb.Get then return cb:Get() == true end
        return false
    end

    -- Spoof ONLY the pawn's m_iTeamNum. The controller keeps its OWN m_iTeamNum (separate object
    -- we never touch), which the network keeps synced to the real team — so on un-spoof we read
    -- the truth live from the controller instead of caching a value that goes stale on a team
    -- switch. SPOOFED tracks who we desynced; spoof_n mirrors #SPOOFED for the idle fast-exit.
    local SPOOFED = {}
    local spoof_n = 0
    local function spoof_mark(sid)   if not SPOOFED[sid] then SPOOFED[sid] = true; spoof_n = spoof_n + 1 end end
    local function spoof_unmark(sid) if SPOOFED[sid]     then SPOOFED[sid] = nil;  spoof_n = spoof_n - 1 end end

    local function driver()
        if not entities.controllers then return end
        local wl_on = cb_on(enabled_cb)
        if not wl_on and spoof_n == 0 then return end

        local lp = entities.GetLocalPawn and entities:GetLocalPawn()
        if lp == nil or lp.m_iTeamNum == nil then return end
        local lt = lp.m_iTeamNum:Get()
        if lt == nil then return end

        entities.controllers:ForEach(function(entry)
            local c = entry and entry.entity
            if c == nil or c.GetStringSteamID == nil or c.GetPawn == nil or c.m_iTeamNum == nil then return end
            local sid = c:GetStringSteamID()
            if sid == nil then return end

            local spare = (wl_on and WL[sid] ~= nil)

            local pawn = c:GetPawn()
            if pawn == nil or pawn.m_iTeamNum == nil then return end
            local cur = pawn.m_iTeamNum:Get()
            if cur == nil then return end

            if spare then
                if pawn.IsAlive and not pawn:IsAlive() then return end      -- dead: team unset, wait for respawn
                if cur ~= lt then
                    pawn.m_iTeamNum:Set(lt)
                    spoof_mark(sid)
                end
            elseif SPOOFED[sid] then
                local real = c.m_iTeamNum:Get()                            -- real team from the untouched controller
                if real ~= nil and cur ~= real then pawn.m_iTeamNum:Set(real) end
                spoof_unmark(sid)
            end
        end)
    end
    if events.createMove and events.createMove.Add then events.createMove:Add(driver) end

    -- ── ESP ──
    -- pawn:GetBoundingBox() returns a ready screen Rect (nil off-screen) without native ESP enabled.
    local function render_esp()
        if not (draw and draw.surface and entities.controllers) then return end
        if not cb_on(text_cb) then return end
        local surf = draw.surface
        if surf.AddText == nil then return end
        surf.font = (draw.fonts and draw.fonts['gui_main']) or surf.font   -- AddText no-ops without a font
        local V   = draw.Vec2 or draw.vec2
        local col = (draw.Color or draw.color)(80, 255, 120)
        if text_color and text_color.Get then local c = text_color:Get(); if c ~= nil then col = c end end
        local center = (draw.TextParams and draw.TextParams.WithH and draw.TextAlignment)
            and draw.TextParams.WithH(draw.TextAlignment.CENTER) or nil

        entities.controllers:ForEach(function(entry)
            local c = entry and entry.entity
            if c == nil or c.GetStringSteamID == nil or c.GetPawn == nil then return end
            local sid = c:GetStringSteamID()
            if sid == nil or WL[sid] == nil then return end
            local pawn = c:GetPawn()
            if pawn == nil or pawn.GetBoundingBox == nil then return end
            if pawn.IsAlive and not pawn:IsAlive() then return end
            local rect = pawn:GetBoundingBox()
            if rect == nil or rect.mins == nil or rect.maxs == nil then return end

            if V then
                local cx = (rect.mins.x + rect.maxs.x) * 0.5
                local name = (c.GetName and c:GetName()) or WL[sid] or sid
                surf:AddText(V(cx, rect.mins.y - 28), name, col, center)
                surf:AddText(V(cx, rect.mins.y - 15), "Whitelisted", col, center)
            end
        end)
    end
    if events.presentQueue and events.presentQueue.Add then
        events.presentQueue:Add(render_esp)
    end

    -- ── UI ──
    local function make_cid(id) if gui and gui.ControlID then return gui.ControlID(id) end return id end

    local ui_done      = false
    local players_list = nil
    local toggle_btn   = nil
    local player_sel   = {}
    local player_sid   = {}

    local function refresh_players()
        if not (ui_done and entities.controllers) then return end
        local lsid = local_sid()
        local list = {}
        entities.controllers:ForEach(function(entry)
            local c = entry and entry.entity
            if c == nil or c.GetStringSteamID == nil then return end
            local sid = c:GetStringSteamID(); if sid == nil or sid == "" then return end
            if lsid ~= nil and sid == lsid then return end                 -- skip self
            local name = (c.GetName and c:GetName()) or sid
            list[#list + 1] = { sid = sid, name = name }
        end)
        for i = 1, MAX_PLAYER_SLOTS do
            local sel = player_sel[i]
            if sel then
                local it = list[i]
                if it then
                    sel.text = it.name .. (WL[it.sid] and "  [WL]" or "")
                    player_sid[i] = it.sid
                    if sel.SetVisible then protected_call(sel.SetVisible, sel, true) end
                else
                    sel.text = ""
                    player_sid[i] = nil
                    if sel.SetVisible then protected_call(sel.SetVisible, sel, false) end   -- hide empty rows
                end
            end
        end
    end

    local function selected_sid()
        local idx = selected_index(players_list)
        if not idx then return nil end
        return player_sid[idx], (player_sel[idx] and player_sel[idx].text)
    end

    local function update_toggle_label()
        if not toggle_btn then return end
        local sid = selected_sid()
        if sid and WL[sid] then toggle_btn.text = "Remove from white list"
        else toggle_btn.text = "Add to white list" end
    end

    local function toggle_selected()
        local sid, label = selected_sid()
        if not sid then log("select a player first"); return end
        if WL[sid] then
            local nm = WL[sid] or sid
            WL[sid] = nil; order_remove(sid); save()
            log("removed: " .. nm)
        else
            local name = label or sid
            name = (name:gsub("%s*%[WL%]%s*$", ""))                        -- strip the "[WL]" marker
            WL[sid] = name; WL_ORDER[#WL_ORDER + 1] = sid; save()
            log("added: " .. name)
        end
        refresh_players(); update_toggle_label()
    end

    local function build_ui(stack_only)
        if ui_done then return true end
        if not (gui.ctx and gui.Group and gui.Button and gui.List and gui.Selectable and draw and (draw.Vec2 or draw.vec2)) then return false end
        local parent = WSR_SKIN_PARENT or gui.ctx:Find("lua>groups")
        if not parent then return false end
        -- Same width as the column neighbors (How to use / Chams); the narrow mode is not needed here:
        -- the panel is no longer third in the row, it is third IN THE COLUMN.
        local wm = (gui.GroupWidthMode and gui.GroupWidthMode.DEFAULT) or 0
        -- In the merged build the height is set by the host (the WLF_PANEL_H global, which also sizes the column);
        -- in a standalone run the global is missing and the same number is used.
        local group = gui.Group(make_cid("wlf_group"), "Friend Whitelist", WLF_PANEL_H or 187, wm)
        if not group then return false end
        if not stack_only then parent:Add(group) end

        -- ONE row: enable checkbox, text checkbox, text color.
        -- ⚠ CONTROLS ARE ADDED IN REVERSE VISUAL ORDER: the control from MakeControl sits on the RIGHT, and each
        -- next Add goes LEFT of the previous one. So the row is built around the color picker and
        -- added right to left; on screen it comes out as [Enabled] [on] [text] [color].
        if gui.MakeControl and gui.Checkbox and gui.ColorPicker then
            enabled_cb = gui.Checkbox(make_cid("wlf_enabled"))
            text_cb    = gui.Checkbox(make_cid("wlf_text"))
            text_color = gui.ColorPicker(make_cid("wlf_textcol"), false)   -- false = no alpha
            -- Tooltips: the row has two identical checkboxes in a row, they cannot be told apart without them.
            -- The row gets the text of the FIRST control: its label is exactly "Enabled".
            local TIP_ON  = "Enable Whitelist"
            local TIP_TXT = "Enable indicator"
            local TIP_COL = "Indicator color"
            enabled_cb.tooltip = TIP_ON
            text_cb.tooltip    = TIP_TXT
            text_color.tooltip = TIP_COL
            local row = gui.MakeControl("Enabled", text_color)
            if row then
                row.tooltip = TIP_ON
                add_child(row, text_cb)
                add_child(row, enabled_cb)
                if row.Reset then row:Reset() end
                add_child(group, row)
            end
            if text_cb and text_cb.GetValue then
                protected_call(function() text_cb:GetValue():Set(true) end)
            end
            if text_color and text_color.GetValue then
                protected_call(function()
                    local mk = draw.Color or draw.color
                    if mk then text_color:GetValue():Set(mk(80, 255, 120)) end
                end)
            end
        end

        -- NB: List constructor width MUST be non-zero — click hit-testing uses it (sizeToParentW
        -- only restyles render width). Width 0 => rows render but are unclickable.
        local mkvec = draw.Vec2 or draw.vec2
        players_list = gui.List(make_cid("wlf_players"), mkvec(250.0, 90.0))
        if players_list then
            players_list.sizeToParentW = true
            protected_call(function(o) o.allowMultiple = false end, players_list)
            protected_call(function(o) o.unlimitedMode = false end, players_list)
            for i = 1, MAX_PLAYER_SLOTS do
                local sel = gui.Selectable(make_cid("wlf_p_" .. i), "-")
                if sel then player_sel[i] = sel; add_child(players_list, sel) end
            end
            if players_list.AddCallback then
                players_list:AddCallback(update_toggle_label)
            end
            add_child(group, players_list)
        end

        toggle_btn = gui.Button(make_cid("wlf_toggle"), "Add to white list")
        if toggle_btn then add_child(group, toggle_btn); if toggle_btn.AddCallback then toggle_btn:AddCallback(toggle_selected) end end

        group:Reset()
        if parent ~= WSR_SKIN_PARENT then parent:Reset() end
        ui_done = true
        refresh_players(); update_toggle_label()
        if stack_only then return group end
        return true
    end
    WLF_BUILD_UI = build_ui

    local frame_ctr = 0
    local present = events.presentQueue or events.present_queue
    if present and present.Add then
        present:Add(function()
            if not ui_done then build_ui(); return end
            -- ⭐ Updating the LIST and the button label is menu-only. While it is closed nobody sees them
            -- anyway, and refresh_players walks all controllers and rewrites 12 lines.
            -- 🛑 ONLY this is gated. driver (createMove) and render_esp (presentQueue) are
            -- the feature itself and must work with the menu closed.
            if gui and gui.IsVisible and not gui.IsVisible() then return end
            update_toggle_label()
            frame_ctr = frame_ctr + 1
            if frame_ctr >= 30 then frame_ctr = 0; refresh_players() end
        end)
    else
        print("[wlf] events.presentQueue unavailable")
    end

    load()

end)
-- ================== /Friend Whitelist ==================

print("Map manager loaded")
