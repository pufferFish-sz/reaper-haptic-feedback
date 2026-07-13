--[[
ReaperHaptics_SetExportFolder.lua — change where ReaperHaptics_Export.lua
writes preview.ahap / preview.events.json. The choice persists across
REAPER restarts (stored in reaper-extstate.ini).
]]

local EXT_SECTION = "ReaperHaptics"
local EXT_KEY_DIR = "export_dir"

local current = reaper.GetExtState(EXT_SECTION, EXT_KEY_DIR)
if current == "" then current = reaper.GetProjectPath("") end

local ok, csv = reaper.GetUserInputs(
  "ReaperHaptics: set export folder", 1,
  "Folder for preview.ahap:,extrawidth=260", current)
if not ok or csv == "" then return end

reaper.SetExtState(EXT_SECTION, EXT_KEY_DIR, csv, true)
reaper.MB("Export folder set to:\n" .. csv ..
  "\n\nServe it with serve-haptics.bat and point the phone at\nhttp://<pc-ip>:8765/preview.ahap",
  "ReaperHaptics", 0)
