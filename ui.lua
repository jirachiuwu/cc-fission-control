-- ui.lua
-- モニター（無ければターミナル）へ炉の状態を描画する。
-- 周辺機器が無くても落ちないよう、描画先は term にフォールバックする。

local ui = {}

-- 描画先（monitor or term）を解決する。
function ui.resolveOutput(monitorName)
  if monitorName == "none" then
    return term
  end
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
  if out.isColor and out.isColor() then
    out.setTextColor(c)
  end
end

local function bgColor(out, c)
  if out.isColor and out.isColor() then
    out.setBackgroundColor(c)
  end
end

-- パーセントバーを描く。lowGood=true なら低い方が緑（温度/廃棄物等）。
local function drawBar(out, x, y, width, pct, label, lowGood)
  pct = pct or 0
  if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end

  out.setCursorPos(x, y)
  color(out, colors.white)
  out.write(label)

  local barY = y + 1
  local filled = math.floor((width * pct) / 100 + 0.5)

  -- 色: 0-25 緑 / 25-50 黄 / 50-75 橙 / 75+ 赤（lowGood=false なら反転評価）
  local barCol = colors.green
  local hot = pct
  if not lowGood then hot = 100 - pct end
  if hot >= 75 then barCol = colors.red
  elseif hot >= 50 then barCol = colors.orange
  elseif hot >= 25 then barCol = colors.yellow end

  local isColor = out.isColor and out.isColor()
  if isColor then
    out.setCursorPos(x, barY)
    bgColor(out, colors.gray)
    out.write(string.rep(" ", width))
    bgColor(out, barCol)
    out.setCursorPos(x, barY)
    out.write(string.rep(" ", filled))
    bgColor(out, colors.black)
  else
    -- 無印コンピュータ用フォールバック: 文字でバーを表現
    out.setCursorPos(x, barY)
    out.write(string.rep("#", filled) .. string.rep("-", width - filled))
  end

  color(out, colors.white)
  out.setCursorPos(x + width + 1, barY)
  out.write(string.format("%5.1f%%", pct))
end

-- メイン描画。state は "RUNNING"/"DISARMED"/"SCRAMMED"。
function ui.render(out, r, state, reason, cfg)
  bgColor(out, colors.black)
  out.clear()
  local w, h = out.getSize()

  -- ヘッダ
  out.setCursorPos(1, 1)
  color(out, colors.cyan)
  out.write("=== FISSION CONTROL ===")
  color(out, colors.lightGray)
  out.write("  [" .. (cfg.profile or "?") .. "]")

  -- 状態バナー
  out.setCursorPos(1, 2)
  local sc = colors.white
  if state == "RUNNING" then sc = colors.green
  elseif state == "SCRAMMED" then sc = colors.red
  elseif state == "DISARMED" then sc = colors.lightGray end
  color(out, sc)
  out.write("STATE: " .. state)
  color(out, colors.white)
  out.write("  ")
  color(out, (state == "SCRAMMED") and colors.red or colors.lightGray)
  out.write(reason or "")

  local barW = math.max(10, math.min(w - 9, 30))
  local y = 4

  -- 温度（数値強調 + バーは scramTemp 基準）
  out.setCursorPos(1, y)
  color(out, colors.white)
  out.write("TEMP")
  local tcol = colors.green
  if r.temp then
    local frac = r.temp / cfg.safety.scramTemp
    if frac >= 0.95 then tcol = colors.red
    elseif frac >= 0.85 then tcol = colors.orange
    elseif frac >= 0.7 then tcol = colors.yellow end
  end
  out.setCursorPos(6, y)
  color(out, tcol)
  out.write(r.temp and string.format("%.0f K", r.temp) or "??? K")
  color(out, colors.lightGray)
  out.write(string.format("  (target %.0f / scram %.0f)", cfg.control.targetTemp, cfg.safety.scramTemp))
  y = y + 2

  -- 各種バー
  drawBar(out, 1, y, barW, r.damage,     "DAMAGE",  true);  y = y + 2
  drawBar(out, 1, y, barW, r.coolantPct, "COOLANT", false); y = y + 2
  drawBar(out, 1, y, barW, r.heatedPct,  "HEATED",  true);  y = y + 2
  drawBar(out, 1, y, barW, r.fuelPct,    "FUEL",    false); y = y + 2
  drawBar(out, 1, y, barW, r.wastePct,   "WASTE",   true);  y = y + 2

  -- タービン（任意・検出時のみ）
  if r.turbinePct ~= nil then
    drawBar(out, 1, y, barW, r.turbinePct, "TURBINE", true); y = y + 2
  end

  -- burn rate 行
  out.setCursorPos(1, y)
  color(out, colors.white)
  local br  = r.burnRate   and string.format("%.2f", r.burnRate)   or "?"
  local abr = r.actualBurn and string.format("%.2f", r.actualBurn) or "?"
  local mbr = r.maxBurn    and string.format("%.0f", r.maxBurn)    or "?"
  out.write(string.format("BURN set=%s act=%s max=%s mB/t", br, abr, mbr))
  y = y + 1
  if r.boilEff then
    out.setCursorPos(1, y)
    color(out, colors.lightGray)
    out.write(string.format("Boil eff: %.1f%%", (r.boilEff <= 1 and r.boilEff * 100 or r.boilEff)))
    y = y + 1
  end

  -- 操作ボタン（Advanced Monitor ならタッチ可、キーでも操作可）。
  -- 戻り値の buttons リストで当たり判定する（{x1,y1,x2,y2,action}）。
  local buttons = {}
  local function btn(x, y, label, action, active)
    local isC = out.isColor and out.isColor()
    if isC then
      bgColor(out, active and colors.cyan or colors.gray)
      color(out, active and colors.black or colors.white)
    end
    out.setCursorPos(x, y)
    out.write(label)
    if isC then bgColor(out, colors.black); color(out, colors.white) end
    buttons[#buttons + 1] = { x1 = x, y1 = y, x2 = x + #label - 1, y2 = y, action = action }
    return x + #label + 1
  end

  -- プロファイル行
  local py = h - 1
  local nx = 1
  nx = btn(nx, py, " SAFETY ",  "profile:safety",      cfg.profile == "safety")
  nx = btn(nx, py, " BALANCE ", "profile:balance",     cfg.profile == "balance")
  nx = btn(nx, py, " PERF ",    "profile:performance", cfg.profile == "performance")

  -- 点火/停止行 + キーヒント
  local ay = h
  local ax = 1
  ax = btn(ax, ay, " ARM ",   "arm",   state == "RUNNING")
  ax = btn(ax, ay, " SCRAM ", "scram", false)
  out.setCursorPos(ax, ay)
  color(out, colors.lightGray)
  out.write("R/S/Q")
  color(out, colors.white)

  return buttons
end

-- デバッグ: API 生値を term に一覧表示してスケールを確認する。
function ui.dumpRaw(reactor)
  local methods = {
    "getStatus", "getTemperature", "getDamagePercent",
    "getCoolantFilledPercentage", "getHeatedCoolantFilledPercentage",
    "getFuelFilledPercentage", "getWasteFilledPercentage",
    "getBurnRate", "getActualBurnRate", "getMaxBurnRate", "getBoilEfficiency",
  }
  print("=== RAW API DUMP (adapter: " .. tostring(reactor.name) .. ") ===")
  for _, m in ipairs(methods) do
    local v = reactor:call(m)
    print(string.format("  %-34s = %s", m, tostring(v)))
  end
  print("=== これらの値を見て config のしきい値を確認 ===")
  print("（%系が 0-1 の小数なら割合版。コードは自動で *100 する）")
  print("Enter で続行...")
  read()
end

return ui
