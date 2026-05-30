-- cc-fission-control 設定ファイル
-- すべて人間が読みやすい単位（温度=K、各種=%）で書く。
-- 値を変えたらプログラムを再起動して反映する。

local cfg = {
  -- バージョン表示。再インストール後にヘッダのこの番号が一致すれば「最新が動いてる」と確認できる。
  version = "b13",

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
  -- 自動出力制御（設計思想 v3 = auto-seek）:
  --   炉ごとの「捌ける最大 burn（理論上限）」を信号から自動発見して、その直下に滑らかに張り付く。
  --   仕組み: coolant を安全ゾーン(≈100%)に保ったまま境界をなぞる。上限以下は coolant=100 で
  --   信号が出ない＝余裕あり→ゆっくり攻める。境界を越えると coolant が下がり heated が上がる
  --   →即引く（非対称: 引きは攻めより速い）。＝目標値を手で設定しなくても理論上限まで自動で上がる。
  --   設計はシミュレーター（sim/）で 6 戦略を競わせ、隠し上限 250-950 全てで到達率≈100% かつ
  --   波 P2P<9・溶融ゼロを確認した方式を採用。温度/冷却フロア/タービンはハード安全層（下げのみ）。
  ---------------------------------------------------------------------------
  control = {
    enabled             = true,

    -- auto-seek 本体（速度は全て maxBurn の割合なので炉サイズに依らない）。
    -- coolant がこれ以上 & heated がこれ以下 = 余裕あり（安全ゾーン）→ 攻める。
    coolantHealthyPct   = 99.5,
    heatedHealthyPct    = 0.5,
    seekUpFraction      = 0.003,  -- 攻める速さ = maxBurn × これ /秒（max1000 で 3/秒、控えめ＝滑らか）
    seekBrakePct        = 99.95,  -- coolant がこれ未満（=境界直下）なら攻めを弱める
    seekBrakeFactor     = 0.25,   -- 境界直下での攻め係数（オーバーシュート抑制）
    seekDownFraction    = 0.0015, -- ストレス時の引き = maxBurn × これ × stress /秒（非対称・速い）
    seekBackoffFraction = 0.0003, -- 引きの微小固定分 = maxBurn × これ /秒

    -- 安全装置（温度）。softTemp/scramTemp は profiles から決まる。
    softTemp            = 1075, -- profiles から自動計算で上書き（target と scram の中間）
    lookahead           = 4,    -- 秒: 温度上昇率からこの秒数先を予測（オーバーシュート安全側）

    maxFallFraction     = 0.5,  -- ハード安全降圧の速さ上限 = maxBurn × これ /秒（下げは速くて安全）
    minBurnRate         = 0.0,  -- mB/t: 下限
    maxBurnRateFraction = 1.0,  -- 炉の上限に対する割合上限（auto-seek もこれで頭打ち＝手動キャップにも使える）

    -- ハード安全層（最終手前ガード）。scram(25/95) の手前で踏みとどまる。
    coolantFloorPct   = 40,   -- coolant がこれ未満 → 強く降圧（COOL-SAT）
    heatedCeilPct     = 60,   -- heated がこれ超 → 強く降圧
    coolingTrendFast  = 3.0,  -- %/秒: 急速に悪化（崖の入り口）→ 強く降圧
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
