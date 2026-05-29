-- cc-fission-control 設定ファイル
-- すべて人間が読みやすい単位（温度=K、各種=%）で書く。
-- 値を変えたらプログラムを再起動して反映する。

local cfg = {
  -- バージョン表示。再インストール後にヘッダのこの番号が一致すれば「最新が動いてる」と確認できる。
  version = "b12",

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
  -- 自動出力制御（設計思想 v2）:
  --   「温度を追って限界まで攻める」のではなく、「自分の構成で安全と分かっている burn rate を
  --    設定 → そこまで緩やかに上げて保持 → 温度/冷却/タービン異常時だけ自動で下げる」。
  --   Mekanism の冷却限界は崖（タービンが詰まると一気に dry out → 即メルトダウン）なので、
  --   探りに行かず、既知の安全値を保持するのが正解（cc-mek-scada と同じ思想）。
  ---------------------------------------------------------------------------
  control = {
    enabled             = true,

    -- ★最重要★ 保持したい burn rate（mB/t、絶対値）。自分の炉で安全に回せる値を入れる。
    -- 手動で安全に回せてた値をそのまま設定するのが確実。nil なら下の Fraction を使う。
    targetBurnRate      = nil,
    -- targetBurnRate=nil のとき使う、炉の最大 burn に対する割合（保守的な既定 = 10%）。
    -- まずこれで安全に回し、様子を見て targetBurnRate に実値を入れて上げていく。
    targetBurnFraction  = 0.10,

    -- 温度は「設定値」ではなく安全装置として使う（限界探しには使わない）。
    -- softTemp/scramTemp は profiles から決まる。softTemp 到達 or 予測で scram 超えなら burn 半減。
    softTemp            = 1075, -- profiles から自動計算で上書き（target と scram の中間）
    lookahead           = 4,    -- 秒: 温度上昇率からこの秒数先を予測（オーバーシュート安全側）

    -- ランプ/降圧の速さ（毎秒、tickInterval で自動スケール）。
    maxRiseFraction     = 0.01, -- 目標へ上げる速さ上限 = maxBurn × これ /秒（max1000 で 10/秒）
    maxFallFraction     = 0.5,  -- 安全降圧の速さ上限 = maxBurn × これ /秒（下げは速くて安全）

    minBurnRate         = 0.0,  -- mB/t: 下限
    maxBurnRateFraction = 1.0,  -- 炉の上限に対する割合上限（targetBurnRate もこれで頭打ち）

    -- 冷却の追従はクーラント残量で見る（満タン近く = 冷却が追いついている / 下がる = 過負荷）。
    -- 残量が目標を下回ったら、温度に関係なく緩やかに burn を下げて目標へ戻す＝持続可能点に張り付く。
    -- 復水が追いつけば残量は目標に戻り、また温度制御が上げる。少しの過渡では floor まで落ちない。
    coolantTargetPct  = 90,   -- coolant をこれ以上にキープ（下回ったら緩降圧）
    heatedTargetPct   = 10,   -- heated をこれ以下にキープ
    -- 強制降圧（最終手前ガード / 急速悪化の速い保険）。scram(25/95) の手前で踏みとどまる。
    coolantFloorPct   = 40,   -- coolant がこれ未満 → 強く降圧
    heatedCeilPct     = 60,   -- heated がこれ超 → 強く降圧
    coolingTrendFast  = 3.0,  -- %/秒: 急速に悪化（過渡）したら強く降圧
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
