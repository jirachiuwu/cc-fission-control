-- integral_seek: スロー積分シーク
-- 冷却健全（coolant 高安定・heated 低・温度安定）なら積分で burn をゆっくり上げ続け、
-- ストレス兆候（coolant 下降 / heated 上昇 / 温度上昇）が出たら積分を下げる。
-- デッドバンドと低ゲインで波最小化。cap は使わない（信号から推定）。

function control(s)
  local mem = s.mem
  local dt = s.dt or 0.5

  -- 内部状態初期化
  if mem.init == nil then
    mem.init = true
    mem.cmd = 100.0          -- 出力する burn 指令（積分器）
    mem.prevCoolant = s.coolant
    mem.prevHeated = s.heated
    mem.prevTemp = s.temp
  end

  local coolant = s.coolant
  local heated = s.heated
  local temp = s.temp

  -- 健全しきい値（デッドバンド）
  -- coolant が満タン近く、heated がほぼゼロ、温度が基準近く = 余裕あり
  local coolantOK = 99.5     -- これ以上なら健全
  local heatedOK = 0.5       -- これ以下なら健全
  local tempOK = 355.0       -- これ以下なら健全

  -- ストレス度（0=健全、正=ストレス）を信号から合成
  local stress = 0.0
  if coolant < coolantOK then stress = stress + (coolantOK - coolant) end
  if heated > heatedOK then stress = stress + (heated - heatedOK) end
  if temp > tempOK then stress = stress + (temp - tempOK) * 0.1 end

  -- 上げゲイン / 下げゲイン（毎秒基準 × dt）
  local upGain = 3.0         -- 健全時に積分で上げる速度
  local downGain = 30.0      -- ストレス時に下げる速度（上げより速く＝安全側）

  if stress <= 0.0 then
    -- 完全健全: ゆっくり上げる。
    -- ただし coolant が満タン(100)から少しでも下がっていたら境界の直下なので
    -- 上げ速度を半分に抑える（先読みブレーキ＝オーバーシュート抑制）。
    local g = upGain
    if coolant < 99.95 then g = g * 0.25 end
    mem.cmd = mem.cmd + g * dt
  else
    -- ストレス: 度合いに比例して下げる（小さい比例ゲイン + 微小固定オフセット）
    mem.cmd = mem.cmd - (downGain * (stress * 0.05) + 0.3) * dt
  end

  -- クランプ
  if mem.cmd < 0 then mem.cmd = 0 end
  if mem.cmd > s.maxBurn then mem.cmd = s.maxBurn end

  return mem.cmd
end
