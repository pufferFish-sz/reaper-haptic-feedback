--[[
ReaperHaptics_Core.lua — shared logic for the ReaperHaptics scripts.
Not an action: loaded via dofile() by ReaperHaptics_Panel.lua,
ReaperHaptics_Export.lua and ReaperHaptics_InsertTransient.lua.
]]

local M = {}

M.TRACK_NAME = "HAPTICS"
M.TRANSIENT_MAX_LEN = 0.045 -- s, shorter items become transients
M.DEFAULT_INSERT_LEN = 0.025 -- s, length of newly inserted transient items
-- Empirical floor from device testing: ~23 ms gaps are still perceivable,
-- so only warn below 20 ms. (Apple's 100 ms guidance is conservative.)
M.MIN_TRANSIENT_GAP = 0.020 -- s
M.MAX_CONTINUOUS = 30.0 -- s, Core Haptics limit
M.SERVER_PORT = 8765

local EXT_SECTION = "ReaperHaptics"
local EXT_KEY_DIR = "export_dir"

-- ------------------------------------------------------------------ helpers

function M.script_dir()
  local info = debug.getinfo(1, "S")
  return info.source:match("^@(.*[/\\])") or ""
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function clamp01(v) return math.max(0, math.min(1, v)) end

-- Item colors match the phone app's timeline: blue = transient,
-- orange = continuous.
local COLOR_TRANSIENT = reaper.ColorToNative(59, 130, 246) | 0x1000000
local COLOR_CONTINUOUS = reaper.ColorToNative(249, 115, 22) | 0x1000000

-- -------------------------------------------------------------------- track

function M.find_track()
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name:upper() == M.TRACK_NAME then return track end
  end
  return nil
end

function M.find_or_create_track()
  local track = M.find_track()
  if track then return track, false end
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", M.TRACK_NAME, true)
  return track, true
end

-- --------------------------------------------------------- insert transient

function M.insert_transient()
  reaper.Undo_BeginBlock()
  local track = M.find_or_create_track()

  local pos
  if reaper.BR_GetMouseCursorContext then
    local window = reaper.BR_GetMouseCursorContext()
    if window == "arrange" then
      local mouse_pos = reaper.BR_GetMouseCursorContext_Position()
      if mouse_pos and mouse_pos >= 0 then pos = mouse_pos end
    end
  end
  if not pos then pos = reaper.GetCursorPosition() end
  if reaper.GetToggleCommandState(1157) == 1 then -- snap enabled
    pos = reaper.SnapToGrid(0, pos)
  end

  local item = reaper.AddMediaItemToTrack(track)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", M.DEFAULT_INSERT_LEN)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 1)
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0)
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0)

  local sine = M.script_dir() .. "reference-sine.wav"
  if file_exists(sine) then
    local take = reaper.AddTakeToMediaItem(item)
    local src = reaper.PCM_Source_CreateFromFile(sine)
    reaper.SetMediaItemTake_Source(take, src)
  end
  reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", COLOR_TRANSIENT)

  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("插入瞬态震动 item", -1)
  return item
end

-- ------------------------------------------------------------ collect items

local function label_of(item)
  local take = reaper.GetActiveTake(item)
  if take then return reaper.GetTakeName(take) or "" end
  local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  return notes or ""
end

local function volume_of(item)
  local vol = reaper.GetMediaItemInfo_Value(item, "D_VOL")
  local take = reaper.GetActiveTake(item)
  if take then vol = vol * reaper.GetMediaItemTakeInfo_Value(take, "D_VOL") end
  return vol
end

--[[ Collect haptic events from the HAPTICS track.
scope: "auto"     — time selection if present, otherwise everything
       "selected" — only selected items (times rebased to the first one)
Returns events, warnings, scope_used ("timesel"/"all"/"selected").
Each event also carries .item (MediaItem*) for UI use. ]]
function M.collect_events(track, scope)
  local warnings = {}
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local has_sel = sel_end > sel_start
  local use_timesel = (scope ~= "selected") and has_sel

  local events = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    local included
    if scope == "selected" then
      included = reaper.IsMediaItemSelected(item)
    elseif use_timesel then
      included = pos >= sel_start and pos < sel_end
    else
      included = true
    end

    if included then
      local label = label_of(item)
      local intensity
      local i_override = label:match("[iI]%s*=%s*([%d%.]+)")
      if i_override then
        intensity = clamp01(tonumber(i_override) or 1)
      else
        local vol = volume_of(item)
        intensity = clamp01(vol)
        if vol > 1.001 then
          warnings[#warnings + 1] = string.format(
            "item @%.3fs: 音量 %.2f 超过 0 dB,强度已钳制为 1.0", pos, vol)
        end
      end

      local sharpness = intensity
      local s_override = label:match("[sS]%s*=%s*([%d%.]+)")
      if s_override then sharpness = clamp01(tonumber(s_override) or intensity) end

      local forced = label:match("[tT][yY][pP][eE]%s*=%s*([tTcC])")
      local is_transient
      if forced then
        is_transient = (forced:lower() == "t")
      else
        is_transient = len < M.TRANSIENT_MAX_LEN
      end

      if (not is_transient) and len > M.MAX_CONTINUOUS then
        warnings[#warnings + 1] = string.format(
          "item @%.3fs: 持续事件 %.1fs 超过 Core Haptics 的 30 秒上限", pos, len)
      end

      events[#events + 1] = {
        item = item,
        pos = pos,
        len = len,
        transient = is_transient,
        intensity = intensity,
        sharpness = sharpness,
      }
    end
  end

  table.sort(events, function(a, b) return a.pos < b.pos end)

  local base
  if scope == "selected" then
    base = events[1] and events[1].pos or 0
  else
    base = use_timesel and sel_start or (events[1] and events[1].pos or 0)
  end
  for _, e in ipairs(events) do e.time = e.pos - base end

  local prev_t = nil
  for _, e in ipairs(events) do
    if e.transient then
      if prev_t and (e.time - prev_t) < (M.MIN_TRANSIENT_GAP - 0.0005) then
        warnings[#warnings + 1] = string.format(
          "位于 %.3fs 的瞬态与前一个仅隔 %.0fms,低于 %.0fms 可能糊成一个脉冲",
          e.pos, (e.time - prev_t) * 1000, M.MIN_TRANSIENT_GAP * 1000)
      end
      prev_t = e.time
    end
  end

  local scope_used = scope == "selected" and "selected"
    or (use_timesel and "timesel" or "all")
  return events, warnings, scope_used
end

--[[ Recolor every item on the HAPTICS track by its exported type
(blue = transient, orange = continuous), so the classification is visible
at a glance while editing. Cheap enough to call every panel frame:
colors are only written when they actually change. ]]
function M.apply_type_colors(track)
  local changed = false
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local label = label_of(item)
    local forced = label:match("[tT][yY][pP][eE]%s*=%s*([tTcC])")
    local is_transient
    if forced then
      is_transient = (forced:lower() == "t")
    else
      is_transient = len < M.TRANSIENT_MAX_LEN
    end
    local want = is_transient and COLOR_TRANSIENT or COLOR_CONTINUOUS
    if reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR") ~= want then
      reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", want)
      changed = true
    end
  end
  if changed then reaper.UpdateArrange() end
end

-- -------------------------------------------------------------- serializers

local function fnum(v) -- trim trailing fractional zeros: 0.5, 1, 0.375, 10
  local s = string.format("%.4f", v)
  return (s:gsub("%.?0+$", ""))
end

function M.to_ahap(events)
  local parts = {}
  for _, e in ipairs(events) do
    local params = string.format(
      '[{"ParameterID": "HapticIntensity", "ParameterValue": %s}, ' ..
      '{"ParameterID": "HapticSharpness", "ParameterValue": %s}]',
      fnum(e.intensity), fnum(e.sharpness))
    local entry
    if e.transient then
      entry = string.format(
        '    {"Event": {"EventType": "HapticTransient", "Time": %s, "EventParameters": %s}}',
        fnum(e.time), params)
    else
      entry = string.format(
        '    {"Event": {"EventType": "HapticContinuous", "Time": %s, "EventDuration": %s, "EventParameters": %s}}',
        fnum(e.time), fnum(e.len), params)
    end
    parts[#parts + 1] = entry
  end
  return '{\n  "Version": 1.0,\n  "Pattern": [\n'
    .. table.concat(parts, ",\n") .. "\n  ]\n}\n"
end

function M.to_haptic_events_json(events)
  local parts = {}
  for _, e in ipairs(events) do
    local fields = {
      string.format('"time": %d', math.floor(e.time * 1000 + 0.5)),
      string.format('"type": "%s"', e.transient and "transient" or "continuous"),
    }
    if not e.transient then
      fields[#fields + 1] = string.format('"duration": %d', math.floor(e.len * 1000 + 0.5))
    end
    fields[#fields + 1] = string.format('"intensity": %s', fnum(e.intensity))
    fields[#fields + 1] = string.format('"sharpness": %s', fnum(e.sharpness))
    parts[#parts + 1] = "  {" .. table.concat(fields, ", ") .. "}"
  end
  return "[\n" .. table.concat(parts, ",\n") .. "\n]\n"
end

--[[ Write a sharpness override ("s=0.45") into the item's take name, or
into the item note for empty items — replacing an existing s= token if
present, appending otherwise. Returns the clamped value. ]]
function M.set_sharpness(item, value)
  value = clamp01(value)
  local token = "s=" .. fnum(value)
  local take = reaper.GetActiveTake(item)
  local label
  if take then
    label = reaper.GetTakeName(take) or ""
  else
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    label = notes or ""
  end
  local new_label, n = label:gsub("[sS]%s*=%s*[%d%.]+", token, 1)
  if n == 0 then
    new_label = label == "" and token or (label .. " " .. token)
  end
  reaper.Undo_BeginBlock()
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_label, true)
  else
    reaper.GetSetMediaItemInfo_String(item, "P_NOTES", new_label, true)
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("修改锐度", -1)
  return value
end

-- ------------------------------------------------------------- export paths

function M.get_export_dir_raw()
  return reaper.GetExtState(EXT_SECTION, EXT_KEY_DIR)
end

function M.confirm_export_dir()
  local current = M.get_export_dir_raw()
  if current == "" then current = reaper.GetProjectPath("") end
  local ok, csv = reaper.GetUserInputs(
    "ReaperHaptics: 确认导出文件夹", 1,
    "preview.ahap 导出到:,extrawidth=260", current)
  if not ok then return nil end
  -- strip surrounding whitespace/quotes and trailing slashes — a trailing
  -- backslash inside quotes breaks cmd.exe argument parsing later
  csv = csv:gsub('^[%s"]+', ""):gsub('[%s"]+$', ""):gsub("[\\/]+$", "")
  if csv == "" then return nil end
  reaper.SetExtState(EXT_SECTION, EXT_KEY_DIR, csv, true)
  return csv
end

local function normalize_dir(dir)
  local sep = package.config:sub(1, 1)
  if dir:sub(-1) ~= sep and dir:sub(-1) ~= "/" then dir = dir .. sep end
  return dir
end

-- Write preview.ahap + preview.events.json. Returns ok, err_or_path.
function M.write_files(dir, events)
  dir = normalize_dir(dir)
  local ahap_path = dir .. "preview.ahap"
  local f, err = io.open(ahap_path, "w")
  if not f then return false, tostring(err) end
  f:write(M.to_ahap(events))
  f:close()
  local jf = io.open(dir .. "preview.events.json", "w")
  if jf then jf:write(M.to_haptic_events_json(events)) jf:close() end
  return true, ahap_path
end

--[[ Full export flow. scope: "auto" | "selected".
confirm_dir: true -> always pop the folder dialog; false -> use the
remembered folder silently (dialog only if none is remembered yet).
Returns a one-line status string for UI display (nil when cancelled),
plus the warnings table. ]]
function M.export(scope, confirm_dir)
  local track = M.find_track()
  if not track then
    reaper.MB('未找到名为 "' .. M.TRACK_NAME .. '" 的轨道。\n\n' ..
      "请先点『启用震动编辑』或新建一条名为 HAPTICS 的轨道。",
      "ReaperHaptics", 0)
    return nil
  end

  local events, warnings, scope_used = M.collect_events(track, scope)
  if #events == 0 then
    local reason = scope == "selected" and "没有选中的 HAPTICS 轨 item。"
      or (scope_used == "timesel" and "时间选区内没有起点落在选区里的 HAPTICS 轨 item。"
          or "HAPTICS 轨上没有任何 item。")
    reaper.MB(reason, "ReaperHaptics", 0)
    return nil
  end

  local dir
  if confirm_dir or M.get_export_dir_raw() == "" then
    dir = M.confirm_export_dir()
    if not dir then return nil end
  else
    dir = M.get_export_dir_raw()
  end

  local ok, err_or_path = M.write_files(dir, events)
  if not ok then
    reaper.MB("无法写入导出文件:\n" .. err_or_path ..
      "\n\n请重新导出并换一个文件夹。", "ReaperHaptics", 0)
    return nil
  end

  local n_trans, n_cont, last_end = 0, 0, 0
  for _, e in ipairs(events) do
    if e.transient then n_trans = n_trans + 1 else n_cont = n_cont + 1 end
    local e_end = e.time + (e.transient and 0 or e.len)
    if e_end > last_end then last_end = e_end end
  end

  local scope_label = scope_used == "selected" and "选中"
    or (scope_used == "timesel" and "时间选区" or "全部")
  local status = string.format("已导出[%s] %d 个事件(瞬态 %d,持续 %d),总长 %.0fms",
    scope_label, #events, n_trans, n_cont, last_end * 1000)
  if #warnings > 0 then
    status = status .. string.format(",警告 %d 条(见控制台)", #warnings)
    for _, w in ipairs(warnings) do
      reaper.ShowConsoleMsg("ReaperHaptics 警告: " .. w .. "\n")
    end
  end
  return status, warnings
end

-- ------------------------------------------------------------------- server

-- Launch serve-haptics.bat in a new console window serving `dir`.
function M.launch_server(dir)
  -- sanitize: trailing backslash inside quotes breaks cmd.exe parsing
  dir = dir:gsub('^[%s"]+', ""):gsub('[%s"]+$', ""):gsub("[\\/]+$", "")
  -- resolve scripts/reaper/../serve-haptics.bat without a literal ".."
  local sdir = M.script_dir()
  local parent = sdir:match("^(.*[/\\])[^/\\]+[/\\]$") or sdir
  local bat = parent .. "serve-haptics.bat"
  if not file_exists(bat) then
    return false, "找不到 " .. bat
  end
  -- /D sets the working directory; the bat serves its cwd when run with
  -- no arguments, so no path needs to be passed as an argument at all.
  local cmd = string.format('cmd.exe /C start "ReaperHaptics Server" /D "%s" "%s"',
    dir, bat)
  reaper.ExecProcess(cmd, -1) -- -1: don't wait
  return true
end

-- Returns a list of local IPv4 addresses (best effort, Windows).
function M.get_local_ips()
  local ret = reaper.ExecProcess("cmd.exe /C ipconfig", 4000)
  local ips = {}
  if ret then
    for ip in ret:gmatch("IPv4[^\r\n]-(%d+%.%d+%.%d+%.%d+)") do
      if ip:sub(1, 7) ~= "169.254" and ip ~= "127.0.0.1" then
        ips[#ips + 1] = ip
      end
    end
  end
  return ips
end

return M
