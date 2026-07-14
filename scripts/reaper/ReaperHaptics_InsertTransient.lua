--[[
ReaperHaptics_InsertTransient.lua — 在光标处插入一个瞬态震动 item。

绑定单键使用(建议 T)。每按一次,在鼠标位置(装了 SWS)或编辑光标处
插入一个 25ms 的参考正弦 item(必然导出为瞬态);拖右边缘拉长到
≥45ms 即变为持续事件,正弦无缝循环。HAPTICS 轨不存在时自动创建。

所有逻辑在 ReaperHaptics_Core.lua;这个脚本只是快捷键入口。
]]

local core = dofile(
  (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) .. "ReaperHaptics_Core.lua")

core.insert_transient()
