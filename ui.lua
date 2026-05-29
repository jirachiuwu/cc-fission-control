-- ui.lua
-- モニター（無ければターミナル）へ炉の状態を描画する。
-- 重要:
--   * CC: Tweaked は日本語を描画できない。画面に出す文字は ASCII 固定。
--   * レイアウトは getSize() から毎回計算する（モニターサイズ変更に追従）。
--   * バー幅は画面幅から算出。縦が足りなければ優先度の低い項目を省略。
--   * ボタンは常に最下段 2 行に固定。

local ui = {}

function ui.resolveOutput(monitorName)
  if monitorName == "none" then return term end
  local mon
  if monitorName and monitorName ~= "" then
    mon = peripheral.wrap(monitorName)
  else
    mon = peripheral.find("monitor")
  end
  if mon then
    if mon.setTextScale then mon.setTextScale(0.5) end
    return mon
  end
  return term
end

local function color(out, c)
  if out.isColor and out.isColor() then out.setTextColor(c) end
end
local function bgColor(out, c)
  if out.isColor and out.isColor() then out.setBackgroundColor(c) end
end

-- 1 行のパーセントバー: "LABEL    [#####-----] 42%"
-- lowGood=true なら高い方が赤（damage/heated/waste/turbine）、false なら低い方が赤（coolant/fuel）。
local function drawBar(out, y, label, pct, lowGood, w)
  pct = pct or 0
  if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end

  local prefix = string.format("%-8s [", label)   -- 8 + " [" = 10 文字
  local barX = #prefix + 1
  local pctStr = string.format("%3.0f%%", pct)
  local barW = w - #prefix - 2 - #pctStr           -- 末尾 "] " + pctStr 分を引く
  if barW < 3 then barW = 3 end
  local filled = math.floor(barW * pct / 100 + 0.5)

  -- 色
  local hot = lowGood and pct or (100 - pct)
  local bc = colors.green
  if hot >= 75 then bc = colors.red
  elseif hot >= 50 then bc = colors.orange
  elseif hot >= 25 then bc = colors.yellow end

  out.setCursorPos(1, y)
  color(out, colors.white)
  out.write(prefix)

  local isC = out.isColor and out.isColor()
  if isC then
    bgColor(out, colors.gray); out.setCursorPos(barX, y); out.write(string.rep(" ", barW))
    bgColor(out, bc);          out.setCursorPos(barX, y); out.write(string.rep(" ", filled))
    bgColor(out, colors.black)
  else
    out.setCursorPos(barX, y)
    out.write(string.rep("#", filled) .. string.rep("-", barW - filled))
  end

  color(out, colors.white)
  out.setCursorPos(barX + barW, y)
  out.write("] " .. pctStr)
end

-- メイン描画。state は "RUNNING"/"DISARMED"/"SCRAMMED"。buttons を返す。
function ui.render(out, r, state, reason, cfg)
  bgColor(out, colors.black)
  out.clear()
  local w, h = out.getSize()

  -- row1: タイトル + プロファイル
  out.setCursorPos(1, 1)
  color(out, colors.cyan); out.write("FISSION CONTROL")
  color(out, colors.lightGray); out.write(" [" .. (cfg.profile or "?") .. "]")

  -- row2: 状態 + メッセージ（RUNNING 時は制御内容が入る = 自動制御の可視化）
  out.setCursorPos(1, 2)
  local sc = colors.lightGray
  if state == "RUNNING" then sc = colors.green
  elseif state == "SCRAMMED" then sc = colors.red end
  color(out, sc); out.write(state)
  color(out, (state == "SCRAMMED") and colors.red or colors.lightGray)
  out.write(" " .. (reason or ""):sub(1, math.max(0, w - #state - 1)))

  -- row3: 温度（数値強調）
  out.setCursorPos(1, 3)
  color(out, colors.white); out.write("TEMP ")
  local tcol = colors.green
  if r.temp then
    local f = r.temp / cfg.safety.scramTemp
    if f >= 0.95 then tcol = colors.red
    elseif f >= 0.85 then tcol = colors.orange
    elseif f >= 0.7 then tcol = colors.yellow end
  end
  color(out, tcol)
  out.write(r.temp and string.format("%.0fK", r.temp) or "?K")
  color(out, colors.lightGray)
  out.write(string.format(" (tgt %.0f/scram %.0f)", cfg.control.targetTemp, cfg.safety.scramTemp))

  -- row4: burn rate
  out.setCursorPos(1, 4)
  color(out, colors.white)
  out.write(string.format("BURN %s/%s  act %s",
    r.burnRate   and string.format("%.1f", r.burnRate)   or "?",
    r.maxBurn    and string.format("%.0f", r.maxBurn)    or "?",
    r.actualBurn and string.format("%.1f", r.actualBurn) or "?"))

  -- row5+: バー（縦が足りなければ優先度順に省略）。ボタン用に最下段 2 行を空ける。
  local contentMax = h - 2
  local y = 5
  local function bar(label, pct, lowGood)
    if y > contentMax then return end
    drawBar(out, y, label, pct, lowGood, w)
    y = y + 1
  end
  bar("DAMAGE",  r.damage,     true)
  bar("COOLANT", r.coolantPct, false)
  bar("HEATED",  r.heatedPct,  true)
  bar("WASTE",   r.wastePct,   true)
  bar("FUEL",    r.fuelPct,    false)
  if r.turbinePct ~= nil then bar("TURBINE", r.turbinePct, true) end

  -- ボタン（最下段 2 行固定）。Advanced Monitor ならタッチ可。
  local buttons = {}
  local function btn(x, yy, label, action, active)
    local isC = out.isColor and out.isColor()
    if isC then
      bgColor(out, active and colors.cyan or colors.gray)
      color(out, active and colors.black or colors.white)
    elseif active then
      label = ">" .. label:sub(2)   -- 非カラー端末では先頭を ">" にして選択中を示す
    end
    out.setCursorPos(x, yy)
    out.write(label)
    if isC then bgColor(out, colors.black); color(out, colors.white) end
    buttons[#buttons + 1] = { x1 = x, y1 = yy, x2 = x + #label - 1, y2 = yy, action = action }
    return x + #label + 1
  end

  local py = h - 1
  local nx = 1
  nx = btn(nx, py, " SAFETY ",  "profile:safety",      cfg.profile == "safety")
  nx = btn(nx, py, " BALANCE ", "profile:balance",     cfg.profile == "balance")
  nx = btn(nx, py, " PERF ",    "profile:performance", cfg.profile == "performance")

  local ax = 1
  ax = btn(ax, h, " ARM ",   "arm",   state == "RUNNING")
  ax = btn(ax, h, " SCRAM ", "scram", false)
  out.setCursorPos(ax, h)
  color(out, colors.lightGray); out.write("R/S/Q")
  color(out, colors.white)

  return buttons
end

-- デバッグ: API 生値を term に一覧表示してスケールを確認する（ASCII）。
function ui.dumpRaw(reactor)
  local methods = {
    "getStatus", "getTemperature", "getDamagePercent",
    "getCoolantFilledPercentage", "getHeatedCoolantFilledPercentage",
    "getFuelFilledPercentage", "getWasteFilledPercentage",
    "getBurnRate", "getActualBurnRate", "getMaxBurnRate", "getBoilEfficiency",
  }
  print("=== RAW API DUMP (adapter: " .. tostring(reactor.name) .. ") ===")
  for _, m in ipairs(methods) do
    print(string.format("  %-34s = %s", m, tostring(reactor:call(m))))
  end
  print("Percent values 0-1 = fraction (code x100 automatically).")
  print("Press Enter to continue...")
  read()
end

return ui
