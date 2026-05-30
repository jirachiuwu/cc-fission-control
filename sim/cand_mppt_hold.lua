-- mppt_hold: Perturb & Observe (太陽光MPPT風)
-- 学習した持続可能最大値を固定保持し、定常では一切動かさない。
-- 段階的に上へ probe → 冷却が健全なら受理して持ち上げ、悪化したら直前の
-- 良値より下へ戻して step を半減し、境界を二分探索的に詰める。収束したら lock。
-- 定常 = 完全固定保持 → P2P ~ 0。
--
-- 物理的肝:
--   burn>cap のとき coolant が少しずつ減る（1tick で deficit*0.025）。
--   burn<cap のとき coolant が回復する（1.5倍速）。burn==cap は均衡で停滞。
--   よって probe で coolant を削ったら、必ず cap より下へ戻して 100 まで回復させ、
--   クリーンな健全判定を取り直す。そうしないと判定が固着し収束しない。
--   真の持続最大点 = coolant が満タンに回復し続ける最大 burn（cap のわずか下）。
function control(s)
  local m = s.mem
  if m.init == nil then
    m.init     = true
    m.hold     = s.maxBurn * 0.30      -- 開始点（cap よりかなり下）
    m.phase    = "settle"              -- settle / probe / lock
    m.timer    = 0
    m.good     = m.hold                -- 最後に健全だった保持値
    m.step     = s.maxBurn * 0.02      -- 1段の上げ幅（収束で半減）
    m.minStep  = s.maxBurn * 0.003     -- これ以下に縮んだら収束 → lock
    m.backoff  = s.maxBurn * 0.01      -- 不健全検知時に good から下げる量（回復用）
    m.margin   = s.maxBurn * 0.002     -- lock 時に boundary から引く安全マージン（cap の 0.2% 下で固定）
    m.settleN  = 10                    -- settle 観測 tick 数
    m.probeN   = 16                    -- probe 観測 tick 数
  end

  local coolant = s.coolant
  local heated  = s.heated
  -- 健全 = coolant が満タンに張り付き heated がほぼゼロ（= まだ余裕）
  local healthy = (coolant >= 99.5) and (heated <= 0.5)

  ----------------------------------------------------------------
  -- settle: 現在値で coolant が 100 まで回復・安定するのを待ってから判断
  ----------------------------------------------------------------
  if m.phase == "settle" then
    m.timer = m.timer + 1
    if m.timer >= m.settleN then
      m.timer = 0
      if healthy then
        -- 余裕あり → この値を good に確定し、1段上へ probe
        m.good  = m.hold
        m.hold  = m.hold + m.step
        m.phase = "probe"
      else
        -- まだ回復しきっていない → 待ち続ける（下げて回復促進）
        m.hold = m.good - m.backoff
        if m.hold < 0 then m.hold = 0 end
      end
    end
    return m.hold
  end

  ----------------------------------------------------------------
  -- probe: 1段上げた直後。coolant が下がるか観測
  ----------------------------------------------------------------
  if m.phase == "probe" then
    m.timer = m.timer + 1
    if not healthy then
      -- 下がった = cap を超えた境界。step 半減して詰める。
      -- good より下へ戻して coolant を 100 に回復させる（固着防止）。
      m.step  = m.step * 0.5
      m.timer = 0
      if m.step < m.minStep then
        -- 収束。境界(good+元step)の手前 = good から安全マージンだけ引いて固定
        m.hold  = m.good - m.margin
        if m.hold < 0 then m.hold = 0 end
        m.phase = "lock"
      else
        m.hold  = m.good - m.backoff   -- 回復させてから次の settle 判定へ
        if m.hold < 0 then m.hold = 0 end
        m.phase = "settle"
      end
      return m.hold
    end
    if m.timer >= m.probeN then
      -- probeN tick 健全のまま耐えた = まだ余裕 → 受理して次段へ
      m.timer = 0
      m.phase = "settle"
    end
    return m.hold
  end

  ----------------------------------------------------------------
  -- lock: 学習完了。good-margin を完全固定保持（定常で波ゼロ）。
  --        静的環境前提なので一切動かさない。
  ----------------------------------------------------------------
  return m.hold
end
