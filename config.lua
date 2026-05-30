-- cc-fission-control 設定ファイル
-- すべて人間が読みやすい単位（温度=K、各種=%）で書く。
-- 値を変えたらプログラムを再起動して反映する。

local cfg = {
  -- バージョン表示。再インストール後にヘッダのこの番号が一致すれば「最新が動いてる」と確認できる。
  version = "b15",

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
    -- ※実機は coolant が常時循環して 7〜15% 程度で運転する（循環で減るのは正常）。
    -- SCRAM 閾値は運転点(coolantSetpoint=12)・COOL-SAT フロア(5)より下の「runout 直前」に置く。
    minCoolantPct       = 3,    -- %: 冷却材がこれ未満（runout 直前）でSCRAM
    maxHeatedCoolantPct = 95,   -- %: 加熱冷却材の出口が詰まりかけでSCRAM（最後の砦）
    maxWastePct         = 92,   -- %: 廃棄物タンクが満杯近くでSCRAM
    minFuelPct          = 1,    -- %: 燃料切れでSCRAM
  },

  ---------------------------------------------------------------------------
  -- 自動出力制御（設計思想 v4 = PI on coolant、実機の循環物理に合わせて再設計）:
  --   実機: coolant は常に循環し、burn を上げるほど表示 % が下がって各点で安定する（循環で減るのは正常）。
  --   本当の限界(runout)は coolant が循環予備すら維持できず 0 へ向かう時。
  --   → coolant を「低い設定値 coolantSetpoint(既定 12%)」に PI 制御で保てば、burn が自動で
  --      「coolant がその予備分になる点」= 理論上限の直下まで上がって張り付く。
  --   ★出力をもっと攻めたい → coolantSetpoint を下げる（例 8）。安全マージン厚く → 上げる（例 20）。
  --   設計は循環物理モデル（sim/）で複数 runout 上限を検証。全上限で coolant=設定値に張り付き、
  --   burn が runout の ~88%（持続可能最大）、波ゼロ、溶融ゼロを確認。
  ---------------------------------------------------------------------------
  control = {
    enabled             = true,

    -- ★最重要★ coolant をこの % に保つよう burn を自動調整。低いほど高出力（runout に近い）。
    -- 自分の炉で手動運転時に coolant が安定する低い値の少し上に設定するのが安全（実機は 7〜15% 程度）。
    coolantSetpoint     = 12,

    -- PI ゲイン（maxBurn の割合なので炉サイズに依らない）。通常いじらない。
    piKiFraction        = 0.0008, -- 積分ゲイン（定常で coolant を設定値ぴったりに合わせる主役）
    piKpFraction        = 0.002,  -- 比例ゲイン（過渡のダンピング）
    -- 変化率ゲート: coolant がこの速さ(%/秒)より急に落下中は「上げ」を止めて HOLD（復水待ち、行き過ぎ防止）。
    coolantSettleTol    = 0.5,
    piUpSlewFraction    = 0.006,  -- 上げの最大速度 = maxBurn × これ /秒（起動オーバーシュート防止、控えめ）
    piDownSlewFraction  = 0.10,   -- 下げの最大速度 = maxBurn × これ /秒（下げは速くて安全）

    -- 安全装置（温度）。softTemp/scramTemp は profiles から決まる。
    softTemp            = 1075, -- profiles から自動計算で上書き
    lookahead           = 4,    -- 秒: 温度上昇率からこの秒数先を予測（オーバーシュート安全側）

    maxFallFraction     = 0.5,  -- ハード安全降圧の速さ上限 = maxBurn × これ /秒
    minBurnRate         = 0.0,  -- mB/t: 下限
    maxBurnRateFraction = 1.0,  -- 炉の上限に対する割合上限（手動キャップにも使える）

    -- ハード安全層（最終手前ガード）。運転点（coolant≈設定値 / heated は高め）の外側に置く。
    coolantFloorPct   = 5,    -- coolant がこれ未満（runout 直前）→ 強く降圧（COOL-SAT）
    heatedCeilPct     = 80,   -- heated がこれ超 → 強く降圧（運転中 heated は数十%まで上がるので高めに）
    coolingTrendFast  = 6.0,  -- %/秒: coolant がこの速さ以上で急落（runout への落下）→ 強く降圧
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
