--[[
ReaperHaptics_Panel.lua — 震动编辑面板(设计师的唯一入口)。

REAPER 原生 gfx 实现,零依赖(不需要 ReaImGui)。功能:
  ① 新增震动轨   — 添加 HAPTICS_1、HAPTICS_2…(可多轨分层设计)
  ② 插入瞬态     — 在编辑光标处插入 25ms 正弦 item(拖长即变持续),
                   落在当前选中的震动轨上
  ③ 启动手机服务器 — 一键在导出文件夹启动 serve-haptics.bat,
                     面板里直接显示手机要填的 URL
  ④ 试发送选中   — 只导出选中的 item(单轨:跨轨时只发最早 item 的轨)
  ⑤ 导出到手机   — 合并所有勾选轨的事件,导出前确认路径和文件名
多轨时面板出现"导出轨道"勾选行;事件列表实时合并显示勾选轨,
点击某一行 = 在工程里选中该 item,双击锐度值可修改。

窗口可拉伸:放大时字体等比放大;缩小到基准尺寸(600x560)为止。
建议:加载后把它拖到工具栏(右键工具栏 → 自定义)当常驻按钮。
]]

local core = dofile(
  (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) .. "ReaperHaptics_Core.lua")

local EXT_SECTION = "ReaperHaptics"
local BASE_W, BASE_H = 600, 600 -- 最小(基准)尺寸,缩小到此为止

-- ------------------------------------------------------------------- state

local status_line = "① 新增震动轨 → ② 插入瞬态 → ③ 启动服务器 → 手机开 Watch"
local ips = nil -- lazy: fetched on first draw / server start
local scroll = 0
local mouse_was_down = false
local clicked_this_frame = false
local scale = 1
-- double-click tracking for the sharpness cell
local dbl_item, dbl_time = nil, 0
-- which haptics tracks are included in list/export, keyed by track name
local track_sel = {}

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

local function px(v) return math.floor(v * scale + 0.5) end

local function set_col(c) gfx.set(c[1], c[2], c[3], 1) end

local function draw_text(x, y, text, col, size)
  gfx.setfont(1, "Microsoft YaHei", px(size or 17))
  set_col(col or COL.text)
  gfx.x, gfx.y = x, y
  gfx.drawstr(text)
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
  gfx.setfont(1, "Microsoft YaHei", px(18))
  set_col(COL.text)
  local tw = gfx.measurestr(label)
  gfx.x = x + (w - tw) / 2
  gfx.y = y + (h - gfx.texth) / 2
  gfx.drawstr(label)
  return hover and clicked_this_frame
end

-- ------------------------------------------------------------------ actions

local function checked_tracks()
  local out = {}
  for _, t in ipairs(core.find_tracks()) do
    if track_sel[t.name] == nil then track_sel[t.name] = true end
    if track_sel[t.name] then out[#out + 1] = t end
  end
  return out
end

local function act_enable()
  local _, name = core.create_new_track()
  reaper.UpdateArrange()
  status_line = "已新增 " .. name .. " 轨;在轨道列表选中它后,插入瞬态会落到这条轨"
end

local function act_insert()
  core.insert_transient()
  status_line = "已在光标处插入 25ms 瞬态。拖右边缘拉长(≥45ms 变持续),音量把手=强度"
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
  local tracks = checked_tracks()
  if #tracks == 0 then
    status_line = "没有勾选任何震动轨,请先在下方轨道行勾选"
    return
  end
  local status = core.export("auto", true, tracks)
  if status then status_line = status end
end

local function act_send_selected()
  -- selection decides; core keeps only the earliest item's track
  local status = core.export("selected", false, core.find_tracks())
  if status then status_line = status .. " → 手机 Watch 将在 1 秒内回放" end
end

-- ------------------------------------------------------------------- panel

local function draw_events_list(x, y, w, h)
  set_col(COL.card)
  gfx.rect(x, y, w, h, 1)

  local all_tracks = core.find_tracks()
  if #all_tracks == 0 then
    draw_text(x + px(12), y + px(10), "(还没有震动轨,点上方『新增震动轨』)", COL.dim, 16)
    return
  end

  -- keep item colors in sync with their exported type (blue/orange)
  for _, t in ipairs(all_tracks) do
    core.apply_type_colors(t.track)
  end

  local tracks = checked_tracks()
  if #tracks == 0 then
    draw_text(x + px(12), y + px(10), "(没有勾选任何震动轨)", COL.dim, 16)
    return
  end

  local events = core.collect_events(tracks, "auto")
  if #events == 0 then
    draw_text(x + px(12), y + px(10), "(暂无事件:点『插入瞬态』或按你绑的快捷键)", COL.dim, 16)
    return
  end

  draw_text(x + px(12), y + px(8), "时间", COL.dim, 15)
  draw_text(x + px(95), y + px(8), "轨", COL.dim, 15)
  draw_text(x + px(135), y + px(8), "类型", COL.dim, 15)
  draw_text(x + px(240), y + px(8), "强度", COL.dim, 15)
  draw_text(x + px(320), y + px(8), "锐度", COL.dim, 15)

  -- live readout: while dragging the volume handle of a selected item the
  -- numbers update every frame — this is the 0-1 intensity meter
  local sel
  for _, e in ipairs(events) do
    if reaper.IsMediaItemSelected(e.item) then sel = e break end
  end
  if sel then
    draw_text(x + px(390), y + px(8),
      string.format("选中 强度%.2f 锐度%.2f", sel.intensity, sel.sharpness),
      COL.ok, 15)
  else
    draw_text(x + px(390), y + px(8), "(点击行=选中)", COL.dim, 15)
  end

  local row_h = px(28)
  local list_y = y + px(34)
  local visible = math.floor((h - px(40)) / row_h)

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
      gfx.rect(x + px(4), ry - px(2), w - px(8), row_h - px(2), 1)
    end

    -- sharpness cell: double-click opens an edit dialog (writes s= back
    -- into the take name / item note)
    local did_edit = false
    if hit(x + px(310), ry - px(2), px(74), row_h - px(2)) and clicked_this_frame then
      local now = reaper.time_precise()
      if dbl_item == e.item and (now - dbl_time) < 0.45 then
        dbl_item = nil
        local ok, csv = reaper.GetUserInputs("ReaperHaptics: 修改锐度", 1,
          "锐度 (0-1):", string.format("%.2f", e.sharpness))
        if ok then
          local v = tonumber(csv)
          if v then
            v = core.set_sharpness(e.item, v)
            status_line = string.format("锐度已改为 %.2f(已写入 s= 标记)", v)
          else
            status_line = "输入无效,锐度未修改"
          end
        end
        did_edit = true
      else
        dbl_item, dbl_time = e.item, now
      end
    end

    if not did_edit
      and hit(x + px(4), ry - px(2), w - px(8), row_h - px(2))
      and clicked_this_frame then
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(e.item, true)
      reaper.UpdateArrange()
      status_line = string.format("已选中 %.3fs 的事件;双击锐度数值可修改", e.pos)
    end

    local type_label = e.transient and "瞬态"
      or string.format("持续 %.0fms", e.len * 1000)
    draw_text(x + px(12), ry, string.format("%.3fs", e.time), COL.text, 16)
    draw_text(x + px(95), ry, tostring(e.track_num), COL.dim, 16)
    draw_text(x + px(135), ry, type_label, e.transient and COL.accent_hover or COL.warn, 16)
    draw_text(x + px(240), ry, string.format("%.2f", e.intensity), COL.text, 16)
    draw_text(x + px(320), ry, string.format("%.2f", e.sharpness), COL.accent_hover, 16)
  end

  if #events > visible then
    draw_text(x + w - px(110), y + h - px(24),
      string.format("%d/%d ↕滚轮", math.min(scroll + visible, #events), #events),
      COL.dim, 15)
  end
end

local function draw()
  set_col(COL.bg)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  local margin = px(16)
  local gap = px(8)

  -- title + guide
  draw_text(margin, px(12), "ReaperHaptics 震动编辑", COL.text, 22)
  draw_text(margin, px(44),
    "音量把手=强度 · 双击列表中的锐度值可修改 · 拖长 ≥45ms 变持续震动",
    COL.dim, 15)

  -- buttons: two rows of three columns
  local bh = px(40)
  local bw = math.floor((gfx.w - margin * 2 - gap * 2) / 3)
  local by1 = px(72)
  local by2 = by1 + bh + gap
  if button(margin, by1, bw, bh, "① 新增震动轨") then act_enable() end
  if button(margin + bw + gap, by1, bw, bh, "② 插入瞬态 (光标处)") then act_insert() end
  if button(margin + (bw + gap) * 2, by1, bw, bh, "③ 启动手机服务器") then act_server() end
  if button(margin, by2, bw, bh, "④ 试发送选中") then act_send_selected() end
  if button(margin + bw + gap, by2, bw * 2 + gap, bh, "⑤ 导出到手机 (选区/全部)", true) then
    act_export()
  end

  -- connection info card
  if ips == nil then ips = core.get_local_ips() end
  local preferred = reaper.GetExtState(EXT_SECTION, "preferred_ip")
  local preferred_ok = false
  for _, ip in ipairs(ips) do
    if ip == preferred then preferred_ok = true end
  end
  -- single adapter: no choice to make
  if #ips == 1 then
    preferred, preferred_ok = ips[1], true
  end

  local info_y = by2 + bh + gap + px(4)
  local row_step = px(22)
  local info_rows = preferred_ok and 3 or (#ips > 0 and (#ips + 2) or 2)
  local info_h = px(16) + row_step * info_rows
  set_col(COL.card)
  gfx.rect(margin, info_y, gfx.w - margin * 2, info_h, 1)

  local dir = core.get_export_dir_raw()
  local iy = info_y + px(8)
  draw_text(margin + px(12), iy, "导出文件夹: " ..
    (dir ~= "" and dir or "(未设置,导出/启动服务器时会询问)"),
    dir ~= "" and COL.text or COL.dim, 16)
  iy = iy + row_step

  if #ips == 0 then
    draw_text(margin + px(12), iy,
      "手机 URL: 未检测到局域网 IP(点『启动手机服务器』后刷新)", COL.dim, 16)
  elseif preferred_ok then
    local url = string.format("http://%s:%d/preview.ahap", preferred, core.SERVER_PORT)
    draw_text(margin + px(12), iy, "手机 URL: " .. url, COL.ok, 16)
    if #ips > 1 and hit(margin, iy - px(2), gfx.w - margin * 2, row_step)
      and clicked_this_frame then
      reaper.SetExtState(EXT_SECTION, "preferred_ip", "", true)
      status_line = "已清除网卡选择,请重新点选手机所在网段的 URL"
    end
    iy = iy + row_step
    draw_text(margin + px(12), iy,
      "手机 app → REAPER 调试台 → 填上面 URL → 开监听(仅首次)" ..
        (#ips > 1 and ";点 URL 行可重选网卡" or ""),
      COL.dim, 15)
  else
    draw_text(margin + px(12), iy,
      "检测到多块网卡,点击手机所在网段的那行(选一次记住):", COL.warn, 15)
    iy = iy + row_step
    for _, ip in ipairs(ips) do
      local url = string.format("http://%s:%d/preview.ahap", ip, core.SERVER_PORT)
      local row_hover = hit(margin, iy - px(2), gfx.w - margin * 2, row_step)
      if row_hover then
        set_col(COL.row_sel)
        gfx.rect(margin + px(4), iy - px(2), gfx.w - margin * 2 - px(8), row_step, 1)
      end
      draw_text(margin + px(12), iy, "→ " .. url, COL.accent_hover, 16)
      if row_hover and clicked_this_frame then
        reaper.SetExtState(EXT_SECTION, "preferred_ip", ip, true)
        status_line = "已选定 " .. ip .. ",以后只显示这一个 URL"
      end
      iy = iy + row_step
    end
  end

  -- track chips: choose which haptics tracks are listed / merged on export
  local all_tracks = core.find_tracks()
  local chips_h = 0
  if #all_tracks > 1 then
    local chip_h = px(28)
    chips_h = chip_h + gap
    local cx = margin
    local cy = info_y + info_h + gap
    draw_text(cx, cy + px(4), "导出轨道:", COL.dim, 15)
    cx = cx + px(84)
    for _, t in ipairs(all_tracks) do
      if track_sel[t.name] == nil then track_sel[t.name] = true end
      local on = track_sel[t.name]
      local label = (on and "✓ " or "○ ") .. t.name
      gfx.setfont(1, "Microsoft YaHei", px(15))
      local cw = gfx.measurestr(label) + px(20)
      local hover = hit(cx, cy, cw, chip_h)
      set_col(on and COL.accent or (hover and COL.btn_hover or COL.btn))
      gfx.rect(cx, cy, cw, chip_h, 1)
      set_col(COL.text)
      gfx.setfont(1, "Microsoft YaHei", px(15))
      gfx.x, gfx.y = cx + px(10), cy + (chip_h - gfx.texth) / 2
      gfx.drawstr(label)
      if hover and clicked_this_frame then
        track_sel[t.name] = not on
        status_line = (not on) and ("已勾选 " .. t.name)
          or ("已取消 " .. t.name .. ";⑤导出将合并所有勾选轨的事件")
      end
      cx = cx + cw + px(8)
    end
  end

  -- events list
  local list_y = info_y + info_h + gap + chips_h
  local status_h = px(36)
  draw_events_list(margin, list_y, gfx.w - margin * 2, gfx.h - list_y - status_h - gap)

  -- status line
  set_col(COL.card)
  gfx.rect(0, gfx.h - status_h, gfx.w, status_h, 1)
  draw_text(margin, gfx.h - status_h + px(8), status_line, COL.ok, 16)
end

-- -------------------------------------------------------------------- loop

local function update_scale()
  local docked = gfx.dock(-1) > 0
  if docked then
    -- docker controls the size; shrink content down to 80% at most
    scale = math.max(0.8, math.min(gfx.w / BASE_W, gfx.h / BASE_H))
  else
    -- enforce the minimum window size, grow fonts past it
    if gfx.w < BASE_W or gfx.h < BASE_H then
      gfx.init("", math.max(gfx.w, BASE_W), math.max(gfx.h, BASE_H))
    end
    scale = math.min(gfx.w / BASE_W, gfx.h / BASE_H)
  end
end

local function loop()
  local down = (gfx.mouse_cap & 1) == 1
  clicked_this_frame = down and not mouse_was_down
  mouse_was_down = down

  update_scale()
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
gfx.init("ReaperHaptics 震动编辑", BASE_W, BASE_H, dock)
loop()
