--[[
ReaperHaptics_Panel.lua — 震动编辑面板(设计师的唯一入口)。

REAPER 原生 gfx 实现,零依赖(不需要 ReaImGui)。功能:
  ① 启用震动编辑 — 建立/定位 HAPTICS 轨
  ② 插入瞬态     — 在编辑光标处插入 25ms 正弦 item(拖长即变持续)
  ③ 启动手机服务器 — 一键在导出文件夹启动 serve-haptics.bat,
                     面板里直接显示手机要填的 URL
  ④ 试发送选中   — 只导出选中的 item,手机 Watch 秒回放(不弹路径框)
  ⑤ 导出到手机   — 导出时间选区/全部,导出前确认路径
下方实时列出当前的震动事件,点击某一行 = 在工程里选中该 item,
再点『试发送选中』即可单发到手机。

建议:加载后把它拖到工具栏(右键工具栏 → 自定义)当常驻按钮。
]]

local core = dofile(
  (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) .. "ReaperHaptics_Core.lua")

local EXT_SECTION = "ReaperHaptics"
local WIN_W, WIN_H = 560, 520

-- ------------------------------------------------------------------- state

local status_line = "① 启用震动编辑 → ② 插入瞬态 → ③ 启动服务器 → 手机开 Watch"
local ips = nil -- lazy: fetched on first draw / server start
local scroll = 0
local mouse_was_down = false
local clicked_this_frame = false

-- ---------------------------------------------------------------- gfx utils

local COL = {
  bg = { 0.13, 0.14, 0.16 },
  card = { 0.18, 0.20, 0.23 },
  btn = { 0.26, 0.30, 0.36 },
  btn_hover = { 0.34, 0.40, 0.48 },
  accent = { 0.23, 0.51, 0.96 },
  accent_hover = { 0.33, 0.60, 1.0 },
  text = { 0.94, 0.95, 0.97 },
  dim = { 0.62, 0.66, 0.72 },
  ok = { 0.30, 0.78, 0.45 },
  warn = { 0.96, 0.62, 0.14 },
  row_sel = { 0.23, 0.38, 0.62 },
}

local function set_col(c) gfx.set(c[1], c[2], c[3], 1) end

local function draw_text(x, y, text, col, size)
  gfx.setfont(1, "Microsoft YaHei", size or 16)
  set_col(col or COL.text)
  gfx.x, gfx.y = x, y
  gfx.drawstr(text)
end

local function text_w(text, size)
  gfx.setfont(1, "Microsoft YaHei", size or 16)
  return gfx.measurestr(text)
end

local function hit(x, y, w, h)
  return gfx.mouse_x >= x and gfx.mouse_x <= x + w
    and gfx.mouse_y >= y and gfx.mouse_y <= y + h
end

local function button(x, y, w, h, label, accent)
  local hover = hit(x, y, w, h)
  local base = accent and COL.accent or COL.btn
  local hov = accent and COL.accent_hover or COL.btn_hover
  set_col(hover and hov or base)
  gfx.rect(x, y, w, h, 1)
  gfx.setfont(1, "Microsoft YaHei", 16)
  set_col(COL.text)
  local tw = gfx.measurestr(label)
  gfx.x = x + (w - tw) / 2
  gfx.y = y + (h - gfx.texth) / 2
  gfx.drawstr(label)
  return hover and clicked_this_frame
end

-- ------------------------------------------------------------------ actions

local function act_enable()
  local _, created = core.find_or_create_track()
  reaper.UpdateArrange()
  status_line = created and "已创建 HAPTICS 轨,点『插入瞬态』开始(或给它绑个 T 键)"
    or "HAPTICS 轨已存在,可以直接插入瞬态"
end

local function act_insert()
  core.insert_transient()
  status_line = "已在光标处插入 25ms 瞬态。拖右边缘拉长(≥150ms 变持续),音量把手=强度"
end

local function act_server()
  local dir = core.get_export_dir_raw()
  if dir == "" then
    dir = core.confirm_export_dir()
    if not dir then status_line = "已取消:先确定导出文件夹才能启动服务器" return end
  end
  local ok, err = core.launch_server(dir)
  if ok then
    ips = core.get_local_ips()
    status_line = "服务器已在新窗口启动(如已在运行会提示端口占用,可无视)"
  else
    status_line = err
  end
end

local function act_export()
  local status = core.export("auto", true)
  if status then status_line = status end
end

local function act_send_selected()
  local status = core.export("selected", false)
  if status then status_line = status .. " → 手机 Watch 将在 1 秒内回放" end
end

-- ------------------------------------------------------------------- panel

local function draw_events_list(x, y, w, h)
  set_col(COL.card)
  gfx.rect(x, y, w, h, 1)

  local track = core.find_track()
  if not track then
    draw_text(x + 12, y + 10, "(还没有 HAPTICS 轨,点上方『启用震动编辑』)", COL.dim, 15)
    return
  end

  local events = core.collect_events(track, "auto")
  if #events == 0 then
    draw_text(x + 12, y + 10, "(暂无事件:点『插入瞬态』或按你绑的快捷键)", COL.dim, 15)
    return
  end

  draw_text(x + 12, y + 8, "时间", COL.dim, 13)
  draw_text(x + 90, y + 8, "类型", COL.dim, 13)
  draw_text(x + 210, y + 8, "强度", COL.dim, 13)
  draw_text(x + 280, y + 8, "锐度", COL.dim, 13)
  draw_text(x + 350, y + 8, "(点击行=在工程中选中)", COL.dim, 13)

  local row_h = 24
  local list_y = y + 30
  local visible = math.floor((h - 36) / row_h)

  local wheel = gfx.mouse_wheel
  if wheel ~= 0 then
    gfx.mouse_wheel = 0
    if hit(x, y, w, h) then
      scroll = scroll - (wheel > 0 and 1 or -1)
    end
  end
  scroll = math.max(0, math.min(scroll, math.max(0, #events - visible)))

  for i = 1, visible do
    local idx = i + scroll
    local e = events[idx]
    if not e then break end
    local ry = list_y + (i - 1) * row_h
    local selected = reaper.IsMediaItemSelected(e.item)

    if selected then
      set_col(COL.row_sel)
      gfx.rect(x + 4, ry - 2, w - 8, row_h - 2, 1)
    end

    if hit(x + 4, ry - 2, w - 8, row_h - 2) and clicked_this_frame then
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(e.item, true)
      reaper.UpdateArrange()
      status_line = string.format("已选中 %.3fs 的事件,点『试发送选中』单发到手机", e.pos)
    end

    local type_label = e.transient and "瞬态"
      or string.format("持续 %.0fms", e.len * 1000)
    draw_text(x + 12, ry, string.format("%.3fs", e.time), COL.text, 14)
    draw_text(x + 90, ry, type_label, e.transient and COL.accent_hover or COL.warn, 14)
    draw_text(x + 210, ry, string.format("%.2f", e.intensity), COL.text, 14)
    draw_text(x + 280, ry, string.format("%.2f", e.sharpness), COL.text, 14)
  end

  if #events > visible then
    draw_text(x + w - 90, y + 8,
      string.format("%d/%d ↕滚轮", math.min(scroll + visible, #events), #events),
      COL.dim, 13)
  end
end

local function draw()
  set_col(COL.bg)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  -- title + guide
  draw_text(16, 12, "ReaperHaptics 震动编辑", COL.text, 20)
  draw_text(16, 40,
    "音量把手=强度 · item 备注写 s=0.3 调锐度 · 拖长 ≥150ms 变持续震动",
    COL.dim, 13)

  -- buttons row 1
  local bw, bh, gap = 168, 34, 8
  if button(16, 64, bw, bh, "① 启用震动编辑") then act_enable() end
  if button(16 + (bw + gap), 64, bw, bh, "② 插入瞬态 (光标处)") then act_insert() end
  if button(16 + (bw + gap) * 2, 64, bw, bh, "③ 启动手机服务器") then act_server() end

  -- buttons row 2
  if button(16, 64 + bh + gap, bw, bh, "④ 试发送选中") then act_send_selected() end
  if button(16 + (bw + gap), 64 + bh + gap, bw * 2 + gap, bh, "⑤ 导出到手机 (选区/全部)", true) then
    act_export()
  end

  -- connection info card
  local info_y = 64 + (bh + gap) * 2 + 4
  set_col(COL.card)
  gfx.rect(16, info_y, gfx.w - 32, 66, 1)
  local dir = core.get_export_dir_raw()
  draw_text(28, info_y + 8, "导出文件夹: " ..
    (dir ~= "" and dir or "(未设置,导出/启动服务器时会询问)"),
    dir ~= "" and COL.text or COL.dim, 14)
  if ips == nil then ips = core.get_local_ips() end
  if #ips > 0 then
    local urls = {}
    for i, ip in ipairs(ips) do
      if i <= 2 then
        urls[#urls + 1] = string.format("http://%s:%d/preview.ahap", ip, core.SERVER_PORT)
      end
    end
    draw_text(28, info_y + 28, "手机 URL: " .. table.concat(urls, "  或  "), COL.ok, 14)
    draw_text(28, info_y + 46, "手机 app → REAPER Bench 页签 → 填上面 URL → 开 Watch(仅首次)", COL.dim, 13)
  else
    draw_text(28, info_y + 28, "手机 URL: 未检测到局域网 IP(点『启动手机服务器』后刷新)", COL.dim, 14)
  end

  -- events list
  local list_y = info_y + 74
  draw_events_list(16, list_y, gfx.w - 32, gfx.h - list_y - 44)

  -- status line
  set_col(COL.card)
  gfx.rect(0, gfx.h - 32, gfx.w, 32, 1)
  draw_text(16, gfx.h - 26, status_line, COL.ok, 14)
end

-- -------------------------------------------------------------------- loop

local function loop()
  local down = (gfx.mouse_cap & 1) == 1
  clicked_this_frame = down and not mouse_was_down
  mouse_was_down = down

  draw()
  gfx.update()

  local ch = gfx.getchar()
  if ch == 27 or ch == -1 then
    reaper.SetExtState(EXT_SECTION, "panel_dock", tostring(gfx.dock(-1)), true)
    gfx.quit()
    return
  end
  reaper.defer(loop)
end

local dock = tonumber(reaper.GetExtState(EXT_SECTION, "panel_dock")) or 0
gfx.init("ReaperHaptics 震动编辑", WIN_W, WIN_H, dock)
loop()
