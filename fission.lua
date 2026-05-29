-- fission.lua  —  Mekanism 核分裂炉 自動制御（CC: Tweaked）
--
-- 状態機械（安全最優先）:
--   DISARMED : 炉OFF。人間が R を押すまで点火しない。
--   RUNNING  : 炉ON。温度に応じて burn rate を自動調整。
--   SCRAMMED : 安全トリップで緊急停止。R で再アームするまで再点火しない（ラッチ）。
--
-- 鉄則:
--   * 安全判定が NG の瞬間に必ず scram する（毎サイクル評価）。
--   * トリップ後は自動再起動しない。人間の R 入力を要求する。
--   * 重要値が読めなければ危険とみなす（reactor.lua のフェイルセーフ）。

local cfg     = require("config")
local Reactor = require("reactor")
local Turbine = require("turbine")
local ui      = require("ui")

local reactor = Reactor.new(cfg.adapterName)
if not reactor:ok() then
  error("核分裂炉の Logic Adapter が見つからない。隣接 or 有線モデム接続を確認。", 0)
end

-- タービン（任意）。設定で有効なら検出する。
local turbine = nil
if cfg.turbine and cfg.turbine.enabled then
  local t = Turbine.new(cfg.turbine.name)
  if t:ok() then
    turbine = t
  elseif cfg.turbine.required then
    error("タービンが見つからない（turbine.required=true）。接続を確認。", 0)
  end
end

local out = ui.resolveOutput(cfg.monitorName)

-- 起動時デバッグダンプ
if cfg.debug then
  ui.dumpRaw(reactor)
end

-- 能力監査: メソッド名が MOD バージョンで違わないか起動時に確認する。
-- critical が欠けると安全チェックが無効化されるため、その場合は点火を拒否して終了。
local missingCritical, missingOptional = reactor:audit()
if #missingCritical > 0 then
  term.clear(); term.setCursorPos(1, 1)
  print("!! 重要メソッドが見つからない（安全チェックが成立しない）:")
  for _, m in ipairs(missingCritical) do print("   - " .. m) end
  print("")
  print("MOD バージョン差で API 名が違う可能性。config.debug=true で生値を確認し、")
  print("reactor.lua のメソッド名を実際の名前に直すこと。安全のため起動を中止する。")
  error("critical method 不足のため起動中止", 0)
end
if #missingOptional > 0 then
  print("注意: 以下は表示/補助用で安全には影響しないが、未実装:")
  for _, m in ipairs(missingOptional) do print("   - " .. m) end
  print("（燃料切れ自動停止が無効になる場合があるが、燃料切れ自体は炉を傷めない）")
  print("Enter で続行...")
  read()
end

-- 初期状態。起動直後は安全のため炉を止める（既に動いていても一旦 scram）。
local state = "DISARMED"
do
  local r0 = reactor:read()
  if r0.status and cfg.startDisarmed then
    reactor:scram()
  elseif r0.status then
    state = "RUNNING" -- startDisarmed=false かつ既に稼働中なら制御を引き継ぐ
  end
end

-- 1 サイクル分の制御ロジック。
local function tick()
  local r = reactor:read()
  local turbinePct = turbine and turbine:energyPct() or nil
  r.turbinePct = turbinePct -- UI 表示用に載せる
  local safe, reason = reactor:checkSafety(r, cfg)

  if not safe then
    -- 危険: 無条件で停止 + ラッチ
    if r.status then reactor:scram() end
    state = "SCRAMMED"
    ui.render(out, r, state, reason, cfg)
    return
  end

  -- 安全な場合の挙動は state による
  if state == "RUNNING" then
    if not r.status then
      -- 何らかの理由で炉が止まっている → 再点火（安全圏なので）
      reactor:activate()
    else
      reactor:autoAdjust(r, cfg, turbinePct)
    end
    local msg = "正常"
    if turbinePct and cfg.turbine.enabled and turbinePct >= cfg.turbine.throttleAtPct then
      msg = "タービン満タン → 出力抑制中"
    end
    ui.render(out, r, state, msg, cfg)
  else
    -- DISARMED / SCRAMMED: 炉は止めたまま待機
    if r.status then reactor:scram() end
    ui.render(out, r, state, (state == "SCRAMMED") and reason or "待機中 (Rで点火)", cfg)
  end
end

-- キー入力の処理。
local function onKey(key)
  if key == keys.s then
    reactor:scram()
    state = "DISARMED"     -- 手動停止は DISARMED（トリップではない）
  elseif key == keys.r then
    -- 再アーム: 今の瞬間が安全な時だけ許可する
    local r = reactor:read()
    local safe, reason = reactor:checkSafety(r, cfg)
    if safe then
      reactor:activate()
      state = "RUNNING"
    else
      ui.render(out, r, "SCRAMMED", "点火拒否: " .. reason, cfg)
    end
  elseif key == keys.q then
    return true -- ループ終了
  end
  return false
end

-- メインループ: タイマーで tick、その間にキーイベントを拾う。
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
    elseif ev[1] == "terminate" then
      break
    end
  end
end

-- プログラム終了時の挙動: 安全のため炉を止めてから抜ける。
local okRun, err = pcall(main)

reactor:scram()
if out.setBackgroundColor then out.setBackgroundColor(colors.black) end
if out.clear then out.clear() end
if out.setCursorPos then out.setCursorPos(1, 1) end
print("fission-control を終了。炉は安全のため SCRAM しました。")
if not okRun then
  print("エラー: " .. tostring(err))
end
