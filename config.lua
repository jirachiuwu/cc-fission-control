-- cc-fission-control 設定ファイル
-- すべて人間が読みやすい単位（温度=K、各種=%）で書く。
-- 値を変えたらプログラムを再起動して反映する。

local cfg = {
  -- ロジックアダプタの周辺機器名。nil なら自動検出（型名 or getTemperature を持つ機器を総当たり）。
  adapterName = nil,

  -- モニターの周辺機器名。nil なら自動検出。GUI 不要なら "none" でターミナル表示のみ。
  monitorName = nil,

  -- 冷却方式: "sodium"（ソーダリウム）or "water"（水）。表示と既定しきい値の説明に使う。
  coolantType = "sodium",

  ---------------------------------------------------------------------------
  -- 運転プロファイル。下の profiles から 1 つ選ぶ。
  --   "safety"      : 安全重視。マージン厚め、温度低め
  --   "balance"     : 効率と安全の中間
  --   "performance" : 高出力寄り（ソーダリウム高冷却前提）。ダメージ開始 1200K の手前まで攻める
  -- 迷ったら初回は "balance" → 挙動を見て "performance" に上げる。
  ---------------------------------------------------------------------------
  profile = "balance",

  profiles = {
    safety      = { targetTemp = 1000, scramTemp = 1150 },
    balance     = { targetTemp = 1100, scramTemp = 1180 },
    performance = { targetTemp = 1150, scramTemp = 1190 },
  },

  ---------------------------------------------------------------------------
  -- 安全しきい値（SCRAM = 緊急停止のトリガー）
  -- scramTemp は上のプロファイルで上書きされる。それ以外は共通。
  -- 核分裂炉は 1200K でダメージが入り始め、ダメージ 100% で爆発（マップ消失）。
  ---------------------------------------------------------------------------
  safety = {
    scramTemp           = 1180, -- profiles で上書きされる（フォールバック値）
    scramDamagePct      = 1.0,  -- %: ダメージがこれを超えたらSCRAM
    minCoolantPct       = 25,   -- %: 冷却材がこれ未満でSCRAM
    maxHeatedCoolantPct = 95,   -- %: 加熱冷却材の出口が詰まりかけでSCRAM（最後の砦）
    maxWastePct         = 92,   -- %: 廃棄物タンクが満杯近くでSCRAM
    minFuelPct          = 1,    -- %: 燃料切れでSCRAM
  },

  ---------------------------------------------------------------------------
  -- 自動出力制御（burn rate を温度に合わせて増減）
  -- targetTemp は上のプロファイルで上書きされる。
  ---------------------------------------------------------------------------
  control = {
    enabled             = true,
    targetTemp          = 1100, -- profiles で上書きされる（フォールバック値）
    tempDeadband        = 15,   -- K: 目標±この範囲は触らない（発振=ハンチング防止）
    -- 比例制御: 温度誤差の割合 × 炉の最大burn × aggressiveness = 1tick の増減量。
    -- 誤差が大きいほど大きく動くので速く収束する。大きいほど機敏だが行き過ぎやすい。
    aggressiveness      = 0.6,
    -- 1tick の増減を「炉の最大burn × これ」までに制限（暴れ・行き過ぎ防止の上限）。
    maxStepFraction     = 0.34,
    minBurnRate         = 0.1,  -- mB/t: 自動制御時の下限
    maxBurnRateFraction = 1.0,  -- 炉の上限(=燃料集合体数)に対する割合上限
  },

  ---------------------------------------------------------------------------
  -- タービン監視（Industrial Turbine）。エネルギーバッファが満タン近くだと
  -- 蒸気の行き場が無くなり加熱冷却材が逆流→過熱するので、満タン手前で出力を絞る。
  ---------------------------------------------------------------------------
  turbine = {
    enabled       = true, -- false で完全無効
    name          = nil,  -- nil なら自動検出（getEnergyFilledPercentage を持つ機器）
    throttleAtPct = 99,   -- %: タービンエネルギーがこれ以上なら burn rate を上げず下げる
    required      = false,-- true にするとタービン未検出で起動を中止する
  },

  -- メインループ間隔（秒）
  tickInterval = 1,

  -- 起動方針: true なら最初は disarmed（炉OFF）でスタート、R キーで人間が点火。
  startDisarmed = true,

  -- デバッグ: 起動時に API の生値を一覧表示してスケールを確認する。
  debug = false,
}

-- 選択プロファイルを安全/制御しきい値へ反映する（config が唯一の真実になるよう、ここで解決）。
local p = cfg.profiles[cfg.profile]
if p then
  cfg.safety.scramTemp  = p.scramTemp
  cfg.control.targetTemp = p.targetTemp
end

return cfg
