-- rate_null 戦略: coolant の変化率(EMA)を 0 付近に保つ。
-- 減り続けるなら burn を下げ、横ばい/満タンなら上げる。比例ゲインで滑らかに。
-- 使用信号: coolant, heated, temp, burn, maxBurn, dt のみ（cap 禁止）。

function control(s)
  local m = s.mem
  local dt = s.dt
  local coolant = s.coolant

  -- 初期化
  if m.init == nil then
    m.init = true
    m.burn = 100          -- 制御出力（連続的に動かす内部状態）
    m.prevCoolant = coolant
    m.rateEMA = 0         -- coolant 変化率の EMA（per second）
  end

  -- coolant の変化率を計測（per second 化）
  local dCool = (coolant - m.prevCoolant) / dt
  m.prevCoolant = coolant
  -- EMA で平滑化（rate のノイズを均す）
  local alpha = 0.30
  m.rateEMA = m.rateEMA + alpha * (dCool - m.rateEMA)

  local burn = m.burn

  -- 目標: coolant の変化率 ~ 0 を維持しつつ、coolant が高い間はゆっくり攻める。
  -- coolant が 100 張り付き = まだ cap 以下 = 余裕あり → スロー上昇シーク。
  -- coolant が減りつつある = cap 超過 → 比例して下げる。

  local setpoint = 0.0      -- 望む coolant 変化率
  local err = m.rateEMA - setpoint   -- 負 = 減っている

  if coolant >= 99.5 then
    -- 満タン張り付き: cap 以下なので攻める。スロー上昇（オーバーシュート小）。
    burn = burn + 5.0 * dt
  else
    -- coolant が 100 未満 = 既に境界を越えている。
    -- 変化率に比例して補正。減っているなら強く下げる（kP 高めで崖余裕確保）。
    local kP = 20.0
    burn = burn + kP * err * dt
    -- coolant が低くなりすぎないよう、低水準では追加で下げる（崖回避）
    if coolant < 30 then
      burn = burn - (30 - coolant) * 0.5 * dt
    end
  end

  -- クランプ
  if burn < 0 then burn = 0 end
  if burn > s.maxBurn then burn = s.maxBurn end
  m.burn = burn
  return burn
end
