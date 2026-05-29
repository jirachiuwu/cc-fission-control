-- fission.lua  —  Mekanism 核分裂炉 自動制御（CC: Tweaked）
--
-- 状態機械（安全最優先）:
--   DISARMED : 炉OFF。R/ARM を押すまで点火しない。
--   RUNNING  : 炉ON。温度に応じて burn rate を自動調整。
--   SCRAMMED : 安全トリップで緊急停止。再アームするまで再点火しない（ラッチ）。
--
-- 操作はキー（R/S/Q）とモニタータッチ（ボタン）の両対応。共通の関数を呼ぶ。
--
-- 鉄則:
--   * 安全判定が NG の瞬間に必ず scram する（毎サイクル評価）。
--   * トリップ後は自動再起動しない。人間の再アームを要求する。
--   * 重要値が読めなければ危険とみなす（reactor.lua のフェイルセーフ）。

local cfg     = require("config")
local Reactor = require("reactor")
local Turbine = require("turbine")
local state   = require("state")
local ui      = require("ui")

local reactor = Reactor.new(cfg.adapterName)
if not reactor:ok() then
  error("Fission Reactor Logic Adapter not found. Check adjacency or wired modem.", 0)
end

-- タービン（任意）。設定で有効なら検出する。
local turbine = nil
if cfg.turbine and cfg.turbine.enabled then
  local t = Turbine.new(cfg.turbine.name)
  if t:ok() then
    turbine = t
  elseif cfg.turbine.required then
    error("Turbine not found (turbine.required=true). Check connection.", 0)
  end
end

local out = ui.resolveOutput(cfg.monitorName)

-- 保存済み設定（プロファイル）を復元して config に反映する。
local function applyProfile(name)
  local p = cfg.profiles[name]
  if not p then return false end
  cfg.profile = name
  cfg.safety.scramTemp   = p.scramTemp
  cfg.control.targetTemp = p.targetTemp
  return true
end

do
  local saved = state.load()
  if saved.profile then applyProfile(saved.profile) end
end

-- 起動時デバッグダンプ
if cfg.debug then
  ui.dumpRaw(reactor)
end

-- 能力監査: メソッド名が MOD バージョンで違わないか起動時に確認する。
local missingCritical, missingOptional = reactor:audit()
if #missingCritical > 0 then
  term.clear(); term.setCursorPos(1, 1)
  print("!! Missing safety-critical methods (safety cannot work):")
  for _, m in ipairs(missingCritical) do print("   - " .. m) end
  print("")
  print("API names may differ by Mekanism version. Set config.debug=true to")
  print("dump raw values, then fix method names in reactor.lua. Aborting for safety.")
  error("aborting: critical methods missing", 0)
end
if #missingOptional > 0 then
  print("Note: these are display/optional only (no safety impact), not found:")
  for _, m in ipairs(missingOptional) do print("   - " .. m) end
  print("Press Enter to continue...")
  read()
end

-- 状態と最後に描画したボタン群。
local fsmState = "DISARMED"
local buttons = {}

-- 起動直後は安全のため炉を止める（既に動いていても一旦 scram）。
do
  local r0 = reactor:read()
  if r0.status and cfg.startDisarmed then
    reactor:scram()
  elseif r0.status then
    fsmState = "RUNNING"
  end
end

local function draw(r, msg)
  buttons = ui.render(out, r, fsmState, msg, cfg)
end

-- 状態を変えず現在値を読んで再描画する（操作直後の即時フィードバック用）。
local function refresh(msg)
  local r = reactor:read()
  r.turbinePct = turbine and turbine:energyPct() or nil
  draw(r, msg)
end

-- 共通アクション（キーとタッチで共有）-------------------------------------

local function doScram()
  reactor:scram()
  fsmState = "DISARMED"   -- 手動停止は DISARMED（トリップではない）
  refresh("MANUAL SCRAM")
end

local function doArm()
  local r = reactor:read()
  r.turbinePct = turbine and turbine:energyPct() or nil
  local safe, reason = reactor:checkSafety(r, cfg)
  if safe then
    reactor:activate()
    fsmState = "RUNNING"
    draw(r, "ARMED")
  else
    draw(r, "ARM DENIED: " .. reason)   -- tick で上書きされない（入力後 tick しない）
  end
end

local function doProfile(name)
  if applyProfile(name) then
    state.save({ profile = cfg.profile })   -- 再起動後も維持
    refresh("PROFILE -> " .. name)
  end
end

-- 1 サイクル分の制御ロジック。-------------------------------------------
local function tick()
  local r = reactor:read()
  local turbinePct = turbine and turbine:energyPct() or nil
  r.turbinePct = turbinePct
  local safe, reason = reactor:checkSafety(r, cfg)

  if not safe then
    if r.status then reactor:scram() end
    fsmState = "SCRAMMED"
    draw(r, reason)
    return
  end

  if fsmState == "RUNNING" then
    local msg
    if not r.status then
      reactor:activate()
      msg = "igniting..."
    else
      msg = reactor:autoAdjust(r, cfg, turbinePct) -- 制御内容を表示（自動制御の可視化）
    end
    draw(r, msg)
  else
    if r.status then reactor:scram() end
    draw(r, (fsmState == "SCRAMMED") and reason or "STANDBY (press ARM/R to start)")
  end
end

-- 入力処理 ---------------------------------------------------------------
local function handleAction(action)
  if action == "scram" then
    doScram()
  elseif action == "arm" then
    doArm()
  elseif action == "profile:safety" then
    doProfile("safety")
  elseif action == "profile:balance" then
    doProfile("balance")
  elseif action == "profile:performance" then
    doProfile("performance")
  end
end

local function onKey(key)
  if key == keys.s then doScram()
  elseif key == keys.r then doArm()
  elseif key == keys.q then return true end
  return false
end

local function onTouch(x, y)
  for _, b in ipairs(buttons) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
      handleAction(b.action)
      return
    end
  end
end

-- メインループ -----------------------------------------------------------
local function main()
  tick()
  local timer = os.startTimer(cfg.tickInterval)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      tick()
      timer = os.startTimer(cfg.tickInterval)
    elseif ev[1] == "key" then
      if onKey(ev[2]) then break end
      -- アクション関数が自分で即描画する（ここで tick() しない＝拒否メッセージ等が消えない）
    elseif ev[1] == "monitor_touch" then
      onTouch(ev[3], ev[4])
    elseif ev[1] == "monitor_resize" then
      tick() -- モニターサイズ変更に即追従して再描画
    elseif ev[1] == "terminate" then
      break
    end
  end
end

-- 終了時: 安全のため炉を止めてから抜ける。
local okRun, err = pcall(main)

reactor:scram()
if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
if out.clear then out.clear() end
if out.setCursorPos then out.setCursorPos(1, 1) end
print("fission-control stopped. Reactor SCRAMmed for safety.")
if not okRun then
  print("error: " .. tostring(err))
end
