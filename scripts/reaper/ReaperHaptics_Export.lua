--[[
ReaperHaptics_Export.lua — export haptic items to .ahap + HapticEvent[] JSON

Authoring model ("items-as-rectangles"):
  * A track named  HAPTICS  holds one media item per haptic event
    (empty items are fine: Insert -> Empty item).
  * item position                  -> event start time
  * item length                    -> transient (short) or continuous (long)
  * item volume x take volume      -> intensity 0..1  (1.0 = 0 dB = full)
    Use items made from reference-sine.wav (same folder) so the volume
    handle exists and the pattern is audible in REAPER. Empty items have
    no volume handle: give them "i=0.6" instead (defaults to 1.0).
  * "i=0.6" in take name/item note -> intensity override (wins over volume)
  * "s=0.7" in take name/item note -> sharpness override (default: = intensity)
  * "type=t" / "type=c"            -> force transient / continuous

Scope:
  * If a time selection exists: items whose START falls inside it,
    times exported relative to the selection start.
  * No time selection: all items on the track, relative to the first item.

Output — every export pops a confirm dialog for the target folder
(prefilled with the last confirmed choice; Enter accepts, Cancel aborts):
  * preview.ahap        — Apple AHAP, times in SECONDS   (iOS playAHAP / bench)
  * preview.events.json — HapticEvent[], times in MS     (Android / bench)

The phone test bench (REAPER Bench tab) watching
http://<pc-ip>:8765/preview.ahap will replay within a second of each run.

Validation mirrored from the test bench: intensity/sharpness clamped to 0..1,
transients closer than 100 ms and continuous events over 30 s are reported
in the console.
]]

local TRACK_NAME = "HAPTICS"
local TRANSIENT_MAX_LEN = 0.15 -- items shorter than this (s) become transients
-- Empirical floor from device testing: ~23 ms gaps are still perceivable as
-- distinct pulses, so only warn below 20 ms. (Apple's 100 ms guidance is
-- conservative.)
local MIN_TRANSIENT_GAP = 0.020 -- s
local MAX_CONTINUOUS = 30.0 -- s, Core Haptics limit
local EXT_SECTION = "ReaperHaptics"
local EXT_KEY_DIR = "export_dir"

local function msg(s) reaper.ShowConsoleMsg(s .. "\n") end

local function clamp01(v) return math.max(0, math.min(1, v)) end

-- ---------------------------------------------------------------- export dir

local function get_export_dir()
  -- Confirm the folder on every export: prefilled with the remembered
  -- choice (or the project path the first time), Enter to accept,
  -- Cancel to abort the export. Whatever is confirmed is remembered.
  local current = reaper.GetExtState(EXT_SECTION, EXT_KEY_DIR)
  if current == "" then current = reaper.GetProjectPath("") end
  local ok, csv = reaper.GetUserInputs(
    "ReaperHaptics: 确认导出文件夹", 1,
    "preview.ahap 导出到:,extrawidth=260", current)
  if not ok or csv == "" then return nil end
  reaper.SetExtState(EXT_SECTION, EXT_KEY_DIR, csv, true)
  return csv
end

-- ---------------------------------------------------------------- find track

local function find_haptics_track()
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name:upper() == TRACK_NAME then return track end
  end
  return nil
end

-- ------------------------------------------------------------- collect items

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

local function collect_events(track, warnings)
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local has_sel = sel_end > sel_start

  local events = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if (not has_sel) or (pos >= sel_start and pos < sel_end) then
      local label = label_of(item)
      local intensity
      -- explicit "i=0.6" wins (the only handle empty items have); otherwise
      -- item x take volume against the full-scale reference sine.
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
        is_transient = len < TRANSIENT_MAX_LEN
      end

      if (not is_transient) and len > MAX_CONTINUOUS then
        warnings[#warnings + 1] = string.format(
          "item @%.3fs: 持续事件 %.1fs 超过 Core Haptics 的 30 秒上限", pos, len)
      end

      events[#events + 1] = {
        pos = pos,
        len = len,
        transient = is_transient,
        intensity = intensity,
        sharpness = sharpness,
      }
    end
  end

  table.sort(events, function(a, b) return a.pos < b.pos end)

  -- rebase times to selection start / first item
  local base = has_sel and sel_start or (events[1] and events[1].pos or 0)
  for _, e in ipairs(events) do e.time = e.pos - base end

  -- transient spacing check
  local prev_t = nil
  for _, e in ipairs(events) do
    if e.transient then
      if prev_t and (e.time - prev_t) < (MIN_TRANSIENT_GAP - 0.0005) then
        warnings[#warnings + 1] = string.format(
          "位于 %.3fs 的瞬态与前一个仅隔 %.0fms,低于 %.0fms 可能糊成一个脉冲",
          e.pos, (e.time - prev_t) * 1000, MIN_TRANSIENT_GAP * 1000)
      end
      prev_t = e.time
    end
  end

  return events, has_sel
end

-- -------------------------------------------------------------- serializers

local function fnum(v) -- trim trailing fractional zeros: 0.5, 1, 0.375, 10
  local s = string.format("%.4f", v)
  return (s:gsub("%.?0+$", ""))
end

local function to_ahap(events)
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

local function to_haptic_events_json(events)
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

local function write_file(path, content)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true
end

-- --------------------------------------------------------------------- main

local function main()
  reaper.ClearConsole()

  local track = find_haptics_track()
  if not track then
    reaper.MB('未找到名为 "' .. TRACK_NAME .. '" 的轨道。\n\n' ..
      "请新建一条轨道命名为 HAPTICS,每个震动事件放一个 item。",
      "ReaperHaptics", 0)
    return
  end

  local warnings = {}
  local events, has_sel = collect_events(track, warnings)
  if #events == 0 then
    reaper.MB(has_sel
      and "时间选区内没有起点落在选区里的 HAPTICS 轨 item。"
      or "HAPTICS 轨上没有任何 item。", "ReaperHaptics", 0)
    return
  end

  local dir = get_export_dir()
  if not dir then return end
  local sep = package.config:sub(1, 1)
  if dir:sub(-1) ~= sep and dir:sub(-1) ~= "/" then dir = dir .. sep end

  local ahap_path = dir .. "preview.ahap"
  local json_path = dir .. "preview.events.json"

  local ok, err = write_file(ahap_path, to_ahap(events))
  if not ok then
    reaper.MB("无法写入 " .. ahap_path .. "\n" .. tostring(err) ..
      "\n\n请重新运行导出并换一个文件夹。",
      "ReaperHaptics", 0)
    return
  end
  write_file(json_path, to_haptic_events_json(events))

  local n_trans, n_cont, last_end = 0, 0, 0
  for _, e in ipairs(events) do
    if e.transient then n_trans = n_trans + 1 else n_cont = n_cont + 1 end
    local e_end = e.time + (e.transient and 0 or e.len)
    if e_end > last_end then last_end = e_end end
  end

  msg(string.format("ReaperHaptics: 已导出 %d 个事件(瞬态 %d 个,持续 %d 个),总长 %.0fms",
    #events, n_trans, n_cont, last_end * 1000))
  msg("  " .. ahap_path)
  msg("  " .. json_path)
  for _, w in ipairs(warnings) do msg("  警告: " .. w) end
  if #warnings == 0 then msg("  无警告") end
end

main()
