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

  -- ダメージ開始 1200K に対しマージン厚め。scram はその手前、softTemp はさらに手前。
  profiles = {
    safety      = { targetTemp = 850,  scramTemp = 1050 },
    balance     = { targetTemp = 1000, scramTemp = 1150 },
    performance = { targetTemp = 1100, scramTemp = 1175 },
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
    targetTemp          = 1000, -- profiles で上書き
    softTemp            = 1075, -- profiles から自動計算で上書き（target と scram の中間）
    tempDeadband        = 10,   -- K: 目標±この範囲は触らない（発振防止）

    -- 予測: 温度上昇率からこの秒数先を予測し、目標/上限を超えそうなら手前で上げを止める。
    -- オーバーシュート（熱の遅れで行き過ぎる）防止の核。
    lookahead           = 4,

    -- 非対称制御（毎秒あたりの強さ。tickInterval で自動スケール＝周期を変えても挙動同じ）。
    -- 上げは「ごく控えめ」、下げは強め（加熱は慎重、冷却は全力＝原発の鉄則）。
    -- ※上げ幅は maxBurn に対する割合。大型炉（例 max 1000）だと割合が大きいと一気に
    --   冷却を超えて即爆発するので、上げ上限は小さめ（既定 0.5%/秒）が安全。
    --   小型炉で遅すぎると感じたら maxRiseFraction を上げる。冷却が追いつかず溶けるなら下げる。
    riseGain            = 0.10,  -- 上げの比例ゲイン（毎秒）
    maxRiseFraction     = 0.005, -- 上げ上限 = maxBurn × これ /秒（max1000 なら 5 mB/t/秒）
    fallGain            = 1.0,   -- 下げの比例ゲイン（上げより強い、毎秒）
    maxFallFraction     = 0.5,   -- 下げ上限 = maxBurn × これ /秒

    minBurnRate         = 0.0,  -- mB/t: 自動制御時の下限（0 まで絞れる）
    maxBurnRateFraction = 1.0,  -- 炉の上限(=燃料集合体数)に対する割合上限

    -- 冷却の追従は「残量レベル」でなく「変化率（トレンド）」で見る。
    -- 復水は待てば追いつくので、少し減った程度では止めない。減り「続けている」時だけ抑える。
    -- coolant が下降 / heated が上昇のトレンド = 復水/排出が追いついていない兆候（温度より先に出る）。
    coolingTrendTol   = 0.8,  -- %/秒: coolant がこの速さ以上で下降 or heated が上昇 → 昇圧停止（待って様子見）
    coolingTrendFast  = 3.0,  -- %/秒: この速さ以上で悪化 → 強制降圧（待つ余裕なし）
    -- 絶対フロア/シーリング（トレンド無視の最終手前ガード。scram(25/95) の手前で踏みとどまる）。
    coolantFloorPct   = 30,   -- coolant がこれ未満 → 強制降圧
    heatedCeilPct     = 85,   -- heated がこれ超 → 強制降圧
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

  -- メインループ間隔（秒）。0.5 = 2回/秒。短いほど反応・表示が速い。
  tickInterval = 0.5,

  -- 表示専用の値（actualBurn / boilEff / fuelPct / maxBurn）を何秒ごとに読むか。
  -- 重い peripheral 呼び出しを毎 tick しないための間引き（安全/制御に必要な値は毎 tick 読む）。
  extrasRefreshSec = 2,

  -- 起動方針: true なら最初は disarmed（炉OFF）でスタート、R キーで人間が点火。
  startDisarmed = true,

  -- デバッグ: 起動時に API の生値を一覧表示してスケールを確認する。
  debug = false,
}

-- 選択プロファイルを安全/制御しきい値へ反映する（config が唯一の真実になるよう、ここで解決）。
local p = cfg.profiles[cfg.profile]
if p then
  cfg.safety.scramTemp   = p.scramTemp
  cfg.control.targetTemp = p.targetTemp
  -- ソフトリミット = target と scram の中間。ここで burn を半減して hard scram を避ける。
  cfg.control.softTemp   = p.targetTemp + (p.scramTemp - p.targetTemp) * 0.5
end

return cfg
