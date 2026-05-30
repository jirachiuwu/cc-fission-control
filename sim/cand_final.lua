-- cand_final: reactor.lua へ移植する最終統合版（auto-seek core + ハード安全層）。
-- 思想: coolant を安全ゾーン(≈100)に保ったまま境界（捌ける最大 burn）をなぞって張り付く。
--   健全(coolant高/heated低) → ゆっくり攻める（境界直下はブレーキ）
--   ストレス(coolant下降/heated上昇) → 度合いに比例して引く（非対称: 引きは速く）
--   ハード安全層(下げ方向のみ): 急速悪化/フロア割れ → 強降圧
-- mem.cmd = 出力指令の積分器。使用信号: coolant/heated/temp/burn/maxBurn/dt のみ。

function control(s)
  local m = s.mem
  local dt = s.dt
  if not m.init then
    m.init = true
    m.cmd = s.burn
    m.prevCoolant = s.coolant
    m.cRate = 0
  end

  local coolant, heated, temp = s.coolant, s.heated, s.temp

  -- coolant 変化率 EMA（急速悪化検知 + ブレーキ用）
  local dCool = (coolant - m.prevCoolant) / dt
  m.prevCoolant = coolant
  m.cRate = m.cRate * 0.6 + dCool * 0.4

  -- ===== ハード安全層（下げ方向のみ・最終手前ガード）=====
  local coolantFloor = 40
  local heatedCeil   = 60
  local fastDrop     = 3.0     -- %/秒 これ以上の速さで coolant 下降 → 急悪化
  if coolant < coolantFloor or heated > heatedCeil or m.cRate < -fastDrop then
    m.cmd = m.cmd - s.maxBurn * 0.5 * dt   -- 強く下げる
    if m.cmd < 0 then m.cmd = 0 end
    return m.cmd
  end

  -- ===== auto-seek core（境界をなぞって張り付く）=====
  -- 速度は全て maxBurn の割合（/秒）にして炉サイズに依らず汎用化。
  local coolantHealthy = 99.5    -- これ以上 & heated 低 = 余裕あり（安全ゾーン）
  local heatedHealthy  = 0.5
  local upFrac      = 0.003      -- 健全時の上げ速度 = maxBurn × これ /秒（max1000で 3/s）
  local downFrac    = 0.0015     -- ストレス時の引き = maxBurn × これ × stress /秒
  local backoffFrac = 0.0003     -- 引きの微小固定分 = maxBurn × これ /秒

  local stress = 0.0
  if coolant < coolantHealthy then stress = stress + (coolantHealthy - coolant) end
  if heated  > heatedHealthy  then stress = stress + (heated - heatedHealthy) end

  if stress <= 0.0 then
    -- 余裕あり: ゆっくり攻める。境界直下(coolantが100からわずかに下降)はブレーキ。
    local g = s.maxBurn * upFrac
    if coolant < 99.95 then g = g * 0.25 end
    m.cmd = m.cmd + g * dt
  else
    -- ストレス: 度合いに比例して引く（非対称・安全側）
    m.cmd = m.cmd - (s.maxBurn * (downFrac * stress + backoffFrac)) * dt
  end

  if m.cmd < 0 then m.cmd = 0 end
  if m.cmd > s.maxBurn then m.cmd = s.maxBurn end
  return m.cmd
end
