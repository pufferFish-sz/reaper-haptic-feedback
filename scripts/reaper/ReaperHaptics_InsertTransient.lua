--[[
ReaperHaptics_InsertTransient.lua — drop a transient-length haptic item.

Bind this to a key (suggestion: T with the arrange view focused, or
Ctrl+Alt+T). Each press inserts an 80 ms item built from
reference-sine.wav on the HAPTICS track (created if missing):

  * 80 ms  -> always exports as HapticTransient
  * drag the right edge to stretch it: at >= 150 ms the exporter
    reclassifies it as HapticContinuous automatically (the sine loops)

Position: mouse cursor when the SWS extension is installed, otherwise
the edit cursor. Honors snap when snap is enabled.
]]

local TRACK_NAME = "HAPTICS"
local DEFAULT_LEN = 0.025 -- s, safely below the 150 ms transient threshold

local function script_dir()
  local info = debug.getinfo(1, "S")
  return info.source:match("^@(.*[/\\])") or ""
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function find_or_create_track()
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name:upper() == TRACK_NAME then return track end
  end
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  local track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", TRACK_NAME, true)
  return track
end

local function insert_position()
  -- Prefer the mouse position (needs SWS); fall back to the edit cursor.
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
  return pos
end

local function main()
  reaper.Undo_BeginBlock()

  local track = find_or_create_track()
  local pos = insert_position()

  local item = reaper.AddMediaItemToTrack(track)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", DEFAULT_LEN)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 1)
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0)
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0)

  local sine = script_dir() .. "reference-sine.wav"
  if file_exists(sine) then
    local take = reaper.AddTakeToMediaItem(item)
    local src = reaper.PCM_Source_CreateFromFile(sine)
    reaper.SetMediaItemTake_Source(take, src)
  end
  -- else: stays an empty item; use "i=0.6" in its note for intensity

  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.UpdateArrange()

  reaper.Undo_EndBlock("插入瞬态震动 item", -1)
end

main()
