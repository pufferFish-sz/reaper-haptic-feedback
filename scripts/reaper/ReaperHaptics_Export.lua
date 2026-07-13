--[[
ReaperHaptics_Export.lua — 导出 HAPTICS 轨为 preview.ahap + preview.events.json。

绑定快捷键使用(如 Ctrl+Shift+H)。有时间选区时只导出选区内的 item,
否则导出整轨;每次导出前弹窗确认导出文件夹(回车确认,取消中止)。

所有逻辑在 ReaperHaptics_Core.lua;日常使用推荐直接开
ReaperHaptics_Panel.lua 面板,这个脚本只是它的快捷键入口。
]]

local core = dofile(
  (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) .. "ReaperHaptics_Core.lua")

local status = core.export("auto", true)
if status then
  reaper.ShowConsoleMsg("ReaperHaptics: " .. status .. "\n")
end
