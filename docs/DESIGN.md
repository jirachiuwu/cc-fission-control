# DESIGN — cc-fission-control 設計書

> 開発者向け。ユーザー向けの導入・使い方は [`../README.md`](../README.md)、開発の経緯と意図は
> [`DEVELOPMENT_LOG.md`](DEVELOPMENT_LOG.md)、再開時の手引きは [`../CLAUDE.md`](../CLAUDE.md)。

---

## 1. 目的

Minecraft (Mekanism + ComputerCraft: Tweaked) の**核分裂炉**を CC コンピュータから自動制御する。
ゴール: **炉ごとの「捌ける最大 burn rate（理論上限）」を信号から自動発見し、その直下に滑らかに張り付ける。**
手で目標値を設定しなくても、どの炉構成でも安全に最大出力で回す。溶融（メルトダウン）は絶対に避ける。

---

## 2. 実機の物理（制御設計の前提＝最重要）

この理解に到達するまでが開発の大半だった（[`DEVELOPMENT_LOG.md`](DEVELOPMENT_LOG.md) 参照）。

### 2.1 クーラント循環
- coolant（冷却材）は**常に循環**している。burn を上げるほど循環量が増え、**coolant タンクの表示 % は下がって、各 burn である平衡値に落ち着く**。
- **この低下は正常**（容量が減ってるのではなく、循環中の分が増えて残量表示が下がる）。低 burn でも 100% ではない。
- 平衡値 S(burn) は burn とともに低下。本当の限界（runout）は循環予備すら維持できず coolant が 0 へ向かう時。
- ⚠️ 初期の設計はここを誤解（「coolant=100% が健全」と仮定）し、coolant が 85% に下がった burn 65 で誤って停止した（v3 の失敗）。

### 2.2 タービン律速（もう一つの、しばしば支配的な限界）
- 炉の熱は coolant → heated coolant（高温）→ ボイラー → 蒸気 → タービン → 復水（水に戻す）で循環。
- **タービンの蒸気処理能力が不足すると**: 蒸気がタービンにパンパンに溜まる → ボイラーから水が消える →
  heated coolant（逆流した蒸気）が炉に溜まる → coolant が戻れず枯れる → runout。
- つまり多くの炉では**律速はタービン（蒸気スループット）**で、それは reactor の **`heatedPct`（加熱冷却材残量）の上昇**として現れる。
- 持続可能な最大 burn = `min`(冷却材供給の限界, タービン処理の限界)。

### 2.3 ラグ（復水の遅れ）
- burn を上げると coolant/heated は即座でなく**一次遅れ**で新しい平衡へ動く。
- ラグ中に「まだ設定値より上だから」と積分し続けると**行き過ぎ**て突き抜ける（v4 → v4.1 で対処）。

---

## 3. 制御アルゴリズム（v4.2 = 二重制約 PI + 変化率ゲート）

実装: [`../reactor.lua`](../reactor.lua) の `Reactor:autoAdjust(r, cfg, turbineEnergyPct)`。

### 3.1 中核: 二重制約 PI
2 つの制約の「先に効く方」で burn を頭打ちにする:
```
coolErr = coolantPct - coolantSetpoint      -- >0 = coolant に余裕（下限まで）
heatErr = heatedSetpoint - heatedPct        -- >0 = heated に余裕（上限まで）
err     = min(coolErr, heatErr)             -- 余裕の小さい方＝先に詰まる制約
```
- 積分器 `self._piI` を `Ki*err*dt` で更新し、出力 `out = piI + Kp*err`。
- err=0 で平衡＝coolant が下限 or heated が上限の**先に達した方**で張り付く。
  - 冷却材律速の炉 → coolant=setpoint（既定 12%）で止まる。
  - タービン律速の炉 → heated=setpoint（既定 60%）で止まる＝蒸気がパンパンになる前。

### 3.2 変化率ゲート（行き過ぎ防止）
- coolant が**落下中** or heated が**上昇中**（= まだ平衡に向かう過渡、復水/蒸気処理の追いつき待ち）は
  **「上げ」を止めて HOLD**。落ち着いたら（rate が `coolantSettleTol` 以内）また少し上げる。
- = 人間の「状態を見ながらゆっくり上げる」の自動化。ラグがあっても行き過ぎない。
- `err < 0`（制約を割った）時は常に下げる（ゲートしない）。

### 3.3 slew リミッタ + アンチワインドアップ
- 出力の変化速度を制限（上げ `piUpSlewFraction` は控えめ、下げ `piDownSlewFraction` は速く＝安全）。
- 起動時の積分巻き上がりによるオーバーシュートを抑える。積分器が slew 制限された出力を大きく超えないようクランプ。

### 3.4 積分器の外部同期
- 実 `burnRate` が指令 `piOut` より大きく下がっていたら（= SCRAM や手動操作）、積分器を実値に同期し直す。
  これをしないと SCRAM 解除後に巻き上がった積分器がいきなり最大 burn を命じて発振する。

### 3.5 ハード安全層（下げ方向のみ・PI の上に被さる）
評価順（先に該当したものを実行）:
1. `COOL!` — 温度がソフト上限 or 「温度上昇率からの予測」が scram 超え → burn 半減。
2. `COOL-SAT` — coolant < `coolantFloorPct`(5) / heated > `heatedCeilPct`(80) / coolant 急落
   (`coolingTrendFast` %/秒) → 強く降圧。タービン詰まり等の最終手前ガード。
3. `THROTTLE` — タービンのエネルギーバッファ満タン → 降圧。
4. （上記なし）→ 二重制約 PI core。
- さらに上位に `checkSafety`（[`../fission.lua`](../fission.lua) のループから毎 tick）: 温度/ダメージ/coolant<`minCoolantPct`(3)/
  heated/廃棄物/燃料 で **SCRAM**（炉停止 + ラッチ）。

### 3.6 画面ラベル
`SEEK+`（攻め中）/ `HOLD`（制約に張り付き安定）/ `SEEK-`（超過で降圧）/ `COOL!` `COOL-SAT` `THROTTLE` `SCRAM`。

---

## 4. アーキテクチャ（ファイル構成）

| ファイル | 役割 |
|---|---|
| [`../fission.lua`](../fission.lua) | メイン。状態機械(DISARMED/RUNNING/SCRAMMED) + **制御ループ(sleep) と入力ループ(pullEvent) を `parallel` で並走**。毎 tick `checkSafety`→`autoAdjust`。終了時 scram。|
| [`../reactor.lua`](../reactor.lua) | 炉アダプタの薄いラッパー。`read`（必要値のみ毎 tick + 表示用は間引き）/ `checkSafety`（フェイルセーフ判定）/ `autoAdjust`（制御の本体）/ `audit`（起動時にメソッド存在確認）。|
| [`../config.lua`](../config.lua) | 全チューナブル。`version` 文字列（画面ヘッダに出る = デプロイ確認用）。|
| [`../ui.lua`](../ui.lua) | モニター描画（無ければ term）。**ASCII 固定**（CC は日本語非対応）。`getSize()` ベースのレスポンシブ。ハートビート（更新間隔の実測表示）。タッチボタン。|
| [`../turbine.lua`](../turbine.lua) | 任意。Industrial Turbine の `getEnergyFilledPercentage` を読む。|
| [`../state.lua`](../state.lua) | プロファイル等の永続化（再起動後も保持）。|
| [`../startup.lua`](../startup.lua) | 起動時自動実行。|
| [`../install.lua`](../install.lua) | `wget run` 用インストーラ（全 .lua を落とす）。|
| `../sim/` | **設計検証用の物理シミュレーター**（[`SIMULATOR.md`](SIMULATOR.md)）。ゲーム外で制御ロジックを検証する要。|

### 4.1 重要な実装上の罠（再発防止）
- **CC は日本語を画面描画できない** → 画面/ターミナルに出す文字は全部 ASCII。コメントは日本語 OK。
- **イベントキュー上限 256** → フィルタ無し `os.pullEvent` ループは忙しいサーバーでタイマーを取りこぼす。
  制御は `sleep` ベース（フィルタ付き）の専用コルーチンで回す（`parallel`）。
- **peripheral 呼び出しは重い**（低 TPS サーバー）→ 毎 tick は安全/制御に必要な値だけ読み、表示専用値はキャッシュ間引き。
- **モニター同期遅延**: 低 TPS サーバーは画面更新が遅延しうる。ヘッダのハートビート（スピナー+実測秒）で「ループが回っているか」を可視化。

---

## 5. config リファレンス（主要）

| キー | 既定 | 意味 |
|---|---|---|
| `control.coolantSetpoint` | 12 | coolant をこの % 以上に保つ（冷却材律速で効く）。低い=高出力 |
| `control.heatedSetpoint` | 60 | heated をこの % 以下に保つ（タービン律速で効く）。高い=高出力だがパンパンに近づく |
| `control.coolantSettleTol` | 0.5 | %/秒。これより急に coolant 落下 / heated 上昇中は「上げ」を止め HOLD |
| `control.piKiFraction` / `piKpFraction` | 0.0008 / 0.002 | PI ゲイン（maxBurn 比＝炉サイズ非依存）|
| `control.piUpSlewFraction` / `piDownSlewFraction` | 0.006 / 0.10 | 上げ/下げの最大速度（maxBurn 比 /秒）|
| `control.maxBurnRateFraction` | 1.0 | 上限キャップ（手動キャップにも使える）|
| `control.coolantFloorPct` / `heatedCeilPct` | 5 / 80 | COOL-SAT 強制降圧の閾値（運転点の外側）|
| `control.coolingTrendFast` | 6.0 | %/秒。coolant 急落で COOL-SAT |
| `control.softTemp` / `lookahead` | (profile) / 4 | 温度安全。softTemp 到達 or 予測 scram 超えで burn 半減 |
| `safety.minCoolantPct` | 3 | coolant がこれ未満で SCRAM（運転点 12% より下）|
| `tickInterval` | 0.5 | 制御・描画周期（秒）|
| `coolantSetpoint`/`heatedSetpoint` 以外は基本いじらない | | |

---

## 6. 設計原則（このプロジェクトの判断軸）

1. **溶融は絶対回避** > 出力。安全層は多重（PI の制約 → COOL-SAT → SCRAM）。下げは速く、上げは控えめ（非対称）。
2. **炉サイズ非依存**: 速度・ゲインは全て `maxBurn` の割合。小炉でも大炉でも同じ挙動。
3. **炉構成非依存**: 上限を計算で決め打ちせず、信号（coolant/heated）から自動発見。隠しパラメータを変えた複数シミュで汎化を検証。
4. **推測で実装しない**: 物理の不明点はユーザー実測 or シミュで確かめてから。ゲーム外で `sim/` を回して暴走・発振・収束不能を事前に潰す。
5. **デプロイ確認可能に**: `config.version` を画面に出し、再インストールで最新が動いているか一目で分かる。
