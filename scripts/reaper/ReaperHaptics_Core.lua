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

-- ------------------------------------------------------------------- tracks

-- "HAPTICS" (legacy) and "HAPTICS_1", "HAPTICS_2", ... all count.
local function is_haptics_name(name)
  local upper = (name or ""):upper()
  return upper == M.TRACK_NAME
    or upper:match("^" .. M.TRACK_NAME .. "_%d+$") ~= nil
end

local function track_num(name)
  return tonumber((name or ""):match("_(%d+)$")) or 1
end

--[[ All haptics tracks in project order, as { track=, name=, num= }.
The legacy plain "HAPTICS" counts as number 1. ]]
function M.find_tracks()
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if is_haptics_name(name) then
      out[#out + 1] = { track = track, name = name:upper(), num = track_num(name) }
    end
  end
  return out
end

-- Add a new HAPTICS_<n+1> track at the end of the project.
function M.create_new_track()
  local max_num = 0
  for _, t in ipairs(M.find_tracks()) do
    if t.num > max_num then max_num = t.num end
  end
  local name = string.format("%s_%d", M.TRACK_NAME, max_num + 1)
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  local track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
  return track, name
end

--[[ Where insert_transient puts new items: the currently selected track if
it is a haptics track, else the first haptics track, else a new one. ]]
function M.insert_target_track()
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if is_haptics_name(name) then return track end
  end
  local tracks = M.find_tracks()
  if tracks[1] then return tracks[1].track end
  return (M.create_new_track())
end

-- --------------------------------------------------------- insert transient

function M.insert_transient()
  reaper.Undo_BeginBlock()
  local track = M.insert_target_track()

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

--[[ Collect haptic events from one or more haptics tracks (merged).
tracks: array of { track=, name=, num= } entries as from find_tracks().
scope: "auto"     — time selection if present, otherwise everything
       "selected" — only selected items (times rebased to the first one)
Returns events, warnings, scope_used ("timesel"/"all"/"selected").
Each event also carries .item (MediaItem*) and .track_num for UI use. ]]
function M.collect_events(tracks, scope)
  local warnings = {}
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local has_sel = sel_end > sel_start
  local use_timesel = (scope ~= "selected") and has_sel

  local events = {}
  for _, entry in ipairs(tracks) do
    local track = entry.track
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
          track_num = entry.num,
        }
      end
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

local function sanitize_name(name, fallback)
  name = (name or ""):gsub("%.ahap%s*$", "")
  name = name:gsub('[<>:"/\\|%?%*]', ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then name = fallback or "preview" end
  return name
end

local function name_key(track_name) return "export_name_" .. track_name end

-- Per-track remembered export filename; defaults to the track name.
function M.get_track_export_name(track_name)
  local name = reaper.GetExtState(EXT_SECTION, name_key(track_name))
  if name == "" then name = track_name:lower() end
  return name
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

-- Write <name>.ahap + <name>.events.json. Returns ok, err_or_path.
function M.write_files(dir, events, name)
  dir = normalize_dir(dir)
  name = name or "preview"
  local ahap_path = dir .. name .. ".ahap"
  local f, err = io.open(ahap_path, "w")
  if not f then return false, tostring(err) end
  f:write(M.to_ahap(events))
  f:close()
  local jf = io.open(dir .. name .. ".events.json", "w")
  if jf then jf:write(M.to_haptic_events_json(events)) jf:close() end
  return true, ahap_path
end

local function stats(events)
  local n_trans, n_cont, last_end = 0, 0, 0
  for _, e in ipairs(events) do
    if e.transient then n_trans = n_trans + 1 else n_cont = n_cont + 1 end
    local e_end = e.time + (e.transient and 0 or e.len)
    if e_end > last_end then last_end = e_end end
  end
  return n_trans, n_cont, last_end
end

local function log_warnings(warnings)
  for _, w in ipairs(warnings) do
    reaper.ShowConsoleMsg("ReaperHaptics 警告: " .. w .. "\n")
  end
end

-- Quick send: selected items only, one track at a time, always preview.*.
local function export_selected(tracks)
  local events, warnings = M.collect_events(tracks, "selected")
  if #events == 0 then
    reaper.MB("没有选中的震动轨 item。", "ReaperHaptics", 0)
    return nil
  end

  local note = ""
  local first_num = events[1].track_num
  local filtered, dropped = {}, 0
  for _, e in ipairs(events) do
    if e.track_num == first_num then
      filtered[#filtered + 1] = e
    else
      dropped = dropped + 1
    end
  end
  if dropped > 0 then
    -- times are already rebased to the first (kept) event
    events = filtered
    note = string.format("(选中跨多轨,仅发送 HAPTICS_%d,忽略 %d 个 item)",
      first_num, dropped)
  end

  local dir = M.get_export_dir_raw()
  if dir == "" then
    dir = M.confirm_export_dir()
    if not dir then return nil end
  end
  local ok, err = M.write_files(dir, events, "preview")
  if not ok then
    reaper.MB("无法写入导出文件:\n" .. err ..
      "\n\n请重新导出并换一个文件夹。", "ReaperHaptics", 0)
    return nil
  end

  local n_trans, n_cont, last_end = stats(events)
  local status = string.format(
    "已发送[选中] preview.ahap:%d 个事件(瞬态 %d,持续 %d),总长 %.0fms%s",
    #events, n_trans, n_cont, last_end * 1000, note)
  if #warnings > 0 then
    status = status .. string.format(",警告 %d 条(见控制台)", #warnings)
    log_warnings(warnings)
  end
  return status, warnings
end

-- Full export: ONE FILE PER TRACK, no merging. A single dialog asks for
-- the folder plus a filename per non-empty track (remembered per track).
local function export_per_track(tracks)
  local jobs, all_warnings = {}, {}
  for _, t in ipairs(tracks) do
    local events, warnings = M.collect_events({ t }, "auto")
    for _, w in ipairs(warnings) do
      all_warnings[#all_warnings + 1] = t.name .. " " .. w
    end
    if #events > 0 then
      jobs[#jobs + 1] = { entry = t, events = events }
    end
  end
  if #jobs == 0 then
    reaper.MB("勾选的震动轨上没有可导出的 item(注意时间选区)。",
      "ReaperHaptics", 0)
    return nil
  end

  local dir = M.get_export_dir_raw()
  if dir == "" then dir = reaper.GetProjectPath("") end
  local captions, defaults = { "导出文件夹:" }, { dir }
  for _, job in ipairs(jobs) do
    captions[#captions + 1] = job.entry.name .. " 文件名:"
    defaults[#defaults + 1] = M.get_track_export_name(job.entry.name)
  end
  local ok, csv = reaper.GetUserInputs(
    "ReaperHaptics: 确认导出(每轨一个文件)", #captions,
    table.concat(captions, ",") .. ",extrawidth=260",
    table.concat(defaults, ","))
  if not ok then return nil end

  -- the folder may contain commas: the LAST #jobs fields are the names
  local parts = {}
  for part in (csv .. ","):gmatch("(.-),") do parts[#parts + 1] = part end
  if #parts < #jobs + 1 then return nil end
  local names = {}
  for i = #parts - #jobs + 1, #parts do names[#names + 1] = parts[i] end
  dir = table.concat(parts, ",", 1, #parts - #jobs)
  dir = dir:gsub('^[%s"]+', ""):gsub('[%s"]+$', ""):gsub("[\\/]+$", "")
  if dir == "" then return nil end
  reaper.SetExtState(EXT_SECTION, EXT_KEY_DIR, dir, true)

  -- sanitize + duplicate check before writing anything
  local seen, written = {}, {}
  for i, job in ipairs(jobs) do
    local name = sanitize_name(names[i], job.entry.name:lower())
    if seen[name] then
      reaper.MB("文件名重复: " .. name .. ".ahap\n\n每条轨需要不同的文件名。",
        "ReaperHaptics", 0)
      return nil
    end
    seen[name] = true
    job.filename = name
  end

  for _, job in ipairs(jobs) do
    reaper.SetExtState(EXT_SECTION, name_key(job.entry.name), job.filename, true)
    local ok2, err = M.write_files(dir, job.events, job.filename)
    if not ok2 then
      reaper.MB("无法写入 " .. job.filename .. ".ahap:\n" .. err,
        "ReaperHaptics", 0)
      return nil
    end
    written[#written + 1] = { name = job.filename, count = #job.events }
  end

  -- keep the phone loop alive when exactly one file was exported
  local preview_note = ""
  if #written == 1 then
    if written[1].name ~= "preview" then
      M.write_files(dir, jobs[1].events, "preview")
      preview_note = ",已同步 preview.ahap"
    end
  else
    preview_note = ";多文件导出不更新 preview,单层试听请用④"
  end

  local descs = {}
  for _, wr in ipairs(written) do
    descs[#descs + 1] = string.format("%s.ahap(%d 事件)", wr.name, wr.count)
  end
  local status = string.format("已导出 %d 个文件: %s%s",
    #written, table.concat(descs, "、"), preview_note)
  if #all_warnings > 0 then
    status = status .. string.format(",警告 %d 条(见控制台)", #all_warnings)
    log_warnings(all_warnings)
  end
  return status, all_warnings
end

--[[ Export flow.
scope "selected": quick send — selected items, single track (earliest
  item's track wins), always written to preview.* silently.
scope "auto": full export — one file per track in `tracks`, no merging;
  one dialog collects the folder and a per-track filename (each
  remembered). Exactly one exported file also refreshes preview.* so
  the phone replays it; multi-file exports leave preview untouched.
tracks: array from find_tracks(); nil = all haptics tracks.
Returns a one-line status string (nil when cancelled) and warnings. ]]
function M.export(scope, _confirm_dir, tracks)
  tracks = tracks or M.find_tracks()
  if #tracks == 0 then
    reaper.MB("未找到震动轨道(HAPTICS_1、HAPTICS_2…)。\n\n请先点『新增震动轨』。",
      "ReaperHaptics", 0)
    return nil
  end
  if scope == "selected" then
    return export_selected(tracks)
  end
  return export_per_track(tracks)
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
