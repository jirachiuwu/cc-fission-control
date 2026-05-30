# cc-fission-control

Mekanism の**核分裂炉（Fission Reactor）**を ComputerCraft: Tweaked から自動制御する Lua プログラム。Minecraft 1.20.1 / ソーダリウム冷却構成を想定。

**安全装置（自動 SCRAM）+ 自動 burn rate 調整 + モニター GUI** の 3 点入り。

> ⚠️ 核分裂炉は暴走するとマップが消し飛ぶ。このプログラムは安全最優先で組んであるが、**しきい値（config.lua）は自分の構成に合わせて確認・調整してから本運用すること**。まずは予備の世界 or 小規模炉で挙動を確認するのを強く推奨。

---

## 機能

- **自動 SCRAM（緊急停止）**: 毎サイクル炉の状態を評価し、危険なら即停止
  - 高温（プロファイル依存、ダメージ開始 1200K の手前で SCRAM）+ ソフトリミットで手前から減速
  - ダメージ検知（既定 1% 超で停止）
  - 冷却材不足 / 加熱冷却材の詰まり / 廃棄物満杯 / 燃料切れ
  - **フェイルセーフ**: 温度などの重要値が読めなければ「危険」とみなして停止
- **トリップ後ラッチ**: 安全停止したら自動再起動しない。人間が `R` で再アームするまで再点火しない（原発制御の鉄則）
- **起動時の能力監査**: メソッド名が MOD バージョンで違う場合、黙って安全無効化せず起動を中止して知らせる
- **自動 burn rate 調整**: 目標温度に向けて burn rate を比例制御（デッドバンドで発振防止、炉の上限で自動クランプ）
- **3 段階プロファイル**: `safety` / `balance` / `performance` を config 一行で切替（目標温度・SCRAM 温度が変わる）
- **タービン監視（任意）**: Industrial Turbine のエネルギーが満タン近くなら出力を絞る（蒸気逆流→過熱を未然に防ぐ）
- **モニター GUI**: 温度・ダメージ・冷却材・加熱冷却材・燃料・廃棄物・タービンのバー、burn rate、状態バナー。画面表示は ASCII（CC: Tweaked は日本語を描画できないため）。**モニターサイズに自動追従**（`getSize()` ベースのレスポンシブ、`monitor_resize` で即再描画、入らない項目は優先度順に省略）
- **制御の可視化**: RUNNING 中は状態行に制御内容を表示（`SEEK+`=上限へ攻め中 / `SEEK-`=境界で微調整 / `COOL!` / `COOL-SAT` / `THROTTLE`）。自動制御が効いているか一目で分かる

## 運転プロファイル

`config.lua` の `profile` を変えるだけ（ダメージ開始は 1200K）。

| プロファイル | 目標温度 | SCRAM 温度 | 用途 |
|---|---|---|---|
| `safety` | 850K | 1050K | マージン厚め。まず安全に |
| `balance` | 1000K | 1150K | 効率と安全の中間（既定）|
| `performance` | 1100K | 1175K | 高出力寄り（ソーダリウム高冷却前提）|

> ダメージ開始は 1200K。上記は手前で止まるよう余裕を持たせてある。初回は `safety` か `balance` で挙動を見て、問題なければ上げる。

## 必要なもの

| | |
|---|---|
| Minecraft | 1.20.1 |
| MOD | Mekanism + ComputerCraft: Tweaked |
| ブロック | Fission Reactor Logic Adapter（炉に設置済み）|
| ブロック（任意）| タービン監視を使うなら Industrial Turbine 側にも Logic Adapter / Turbine Valve をコンピュータに繋ぐ |
| コンピュータ | Advanced Computer 推奨（色表示）。Advanced Monitor があれば GUI が綺麗 |

Logic Adapter はコンピュータに**隣接**させるか、**有線モデム（Wired Modem）**で繋ぐ。モニター・タービンも同様。タービン未接続でも `config.turbine.required=false`（既定）なら炉だけで普通に動く。

## API の検証について

安全に関わる炉のメソッド（`getStatus` / `getTemperature` / `getDamagePercent` / `getCoolantFilledPercentage` / `getHeatedCoolantFilledPercentage` / `getWasteFilledPercentage` / `getBurnRate` / `setBurnRate` / `getMaxBurnRate` / `scram` / `activate`）と、タービンの `getEnergyFilledPercentage` は、実運用スクリプトと照合して名称を確認済み（パーセント系はいずれも 0-1 の割合で、コードが自動で ×100 する）。`getFuelFilledPercentage` / `getActualBurnRate` / `getBoilEfficiency` は使用例が確認できなかったため、未実装でも起動時に警告するだけで安全には影響しない設計にしている。

## 操作

キーと、**Advanced Monitor のタッチ**の両対応。

| キー | 画面ボタン | 動作 |
|---|---|---|
| `R` | `ARM` | アーム/点火（その瞬間が安全な時だけ許可。SCRAM 後の再アームもこれ）|
| `S` | `SCRAM` | 手動 SCRAM（即停止、DISARMED へ）|
| `Q` | — | プログラム終了（**終了時は安全のため炉を SCRAM する**）|
| — | `SAFETY`/`BALANCE`/`PERF` | 運転プロファイルをその場で切替（即反映 + ファイル保存）|

- プロファイルは画面タッチで切り替えられ、`state` ファイルに**保存**される（再起動後も維持）。`config.lua` の `profile` は初期値。
- 状態: `DISARMED`（待機・炉OFF）/ `RUNNING`（稼働・自動制御中）/ `SCRAMMED`（安全トリップ・要再アーム）

## ComputerCraft セッティング（物理セットアップ）

ファイルを入れる前に、ゲーム内のブロック配線を済ませる。

### 1. 炉に Logic Adapter を付ける
- 核分裂炉マルチブロックの**外壁の任意の 1 ブロック**を **Fission Reactor Logic Adapter** に置き換える（Casing と差し替え）。これが CC から炉を読む口になる。

### 2. コンピュータを用意
- **Advanced Computer**（金色）を推奨。色付き GUI が出る。普通の Computer でも文字バーで動く。
- 出先表示が欲しいなら **Advanced Monitor** を 2x3 以上で並べると見やすい。

### 3. 配線（2 通りのどちらか）

**A) 隣接させる（最小構成）**
```
[Logic Adapter] ─ 隣接 ─ [Computer] ─ 隣接 ─ [Monitor]
```
ブロックを直接くっつけるだけ。小規模ならこれで十分。

**B) 有線モデムで離す（推奨・実用的）**
```
[Logic Adapter]──[Wired Modem]
                      │ (Networking Cable)
[Computer]──[Wired Modem]──┼──(cable)──[Wired Modem]──[Monitor]
                      │
              [Wired Modem]──[Turbine Valve / Logic Adapter]（タービン監視する場合）
```
- 各機器（Logic Adapter / Monitor / タービン）に **Wired Modem** を貼り、**Networking Cable** でコンピュータのモデムまで繋ぐ。
- 貼った Wired Modem を**右クリックして有効化**（赤→明るくなる）。これで `peripheral` として認識される。
- コンピュータ側にもモデムを貼って有効化する。

> このプログラムは周辺機器を**自動検出**する（炉=getTemperature を持つ機器、タービン=getEnergyFilledPercentage を持つ機器、モニター=monitor）。複数あって誤検出する場合だけ `config.lua` の `adapterName` / `turbine.name` / `monitorName` に正確な名前を指定する。名前は CC のコマンド `peripherals`（または各モデムを右クリックした時のチャット表示）で確認できる。

### 4. タービン監視を使う場合（任意）
- Industrial Turbine 側にも **Turbine Valve** か Logic Adapter を置き、上記 B の配線でコンピュータのネットワークに繋ぐ。
- 使わないなら何もしなくてよい（`config.turbine.required=false` が既定なので炉だけで動く）。

## インストール

ゲーム内のコンピュータのターミナルで、以下のどれか。

### 方法 A: installer 一発（公開後・推奨）
```
wget run https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/install.lua
```
`install.lua` が全ファイルを自動で落とす。

### 方法 B: 個別 wget
```
wget https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/config.lua  config.lua
wget https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/reactor.lua reactor.lua
wget https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/turbine.lua turbine.lua
wget https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/state.lua   state.lua
wget https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/ui.lua      ui.lua
wget https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/fission.lua  fission.lua
wget https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/startup.lua  startup.lua
```
> 全ファイルはコンピュータのルート（`/`）に置く。`require` は同じディレクトリの兄弟ファイルを解決する。

### 起動
```
fission
```
`startup.lua` を入れておけば、コンピュータ再起動で自動実行される。

## セットアップ手順（最短）

1. 上記でファイルを入れる
2. `config.lua` を開いて初回は `debug = true` にする
3. `fission` を実行 → 起動時に API の生値が出るので、`%` 系の値が `0-1` の小数か `0-100` かを確認（コードは両対応だが念のため）+ しきい値が自分の構成に合うか見る
4. `debug = false` に戻す
5. `fission` 実行 → `R` で点火

## config.lua の主なしきい値

| キー | 既定 | 説明 |
|---|---|---|
| `safety.scramTemp` | (profile) | これ以上の温度で即SCRAM（K、プロファイルで決まる）|
| `safety.scramDamagePct` | 1.0 | ダメージがこれを超えたらSCRAM（%）|
| `safety.minCoolantPct` | 25 | 冷却材がこれ未満でSCRAM（%）|
| `safety.maxHeatedCoolantPct` | 95 | 加熱冷却材の詰まりでSCRAM（%）|
| `safety.maxWastePct` | 92 | 廃棄物満杯でSCRAM（%）|
| `control` (auto-seek) | — | 炉ごとの理論上限を自動発見して張り付く。設定不要。詳細は下の「自動制御の仕組み」|
| `control.maxBurnRateFraction` | 1.0 | 炉上限に対する burn rate の割合上限（手動キャップにも使える）|
| `turbine.enabled` | true | タービン監視の ON/OFF |
| `turbine.throttleAtPct` | 99 | タービンエネルギーがこれ以上なら出力を絞る（%）|
| `turbine.required` | false | true でタービン未検出時に起動中止 |

## 自動制御の仕組み / チューニング（設計思想 v4 = PI on coolant）

**炉ごとの理論上限を自動発見して、その直下に滑らかに張り付く。** 目標 burn を手で設定しなくていい。

### 実機の物理（ここが肝）
Mekanism の coolant は**常に循環**している。burn を上げるほど循環量が増え、**coolant タンクの表示 % は下がって各 burn である値に落ち着く**（循環で減るのは正常、容量が減ってるわけじゃない）。本当の限界(runout)は循環予備すら維持できず coolant が 0 へ向かう時。→「coolant が 99% 未満なら危険」みたいな高い閾値はナンセンス。

### 制御
**coolant を「低い設定値 `coolantSetpoint`（既定 12%）」に PI 制御で保つ。** すると burn が自動で「coolant がその予備分になる点」＝**理論上限の直下**まで上がって張り付く。coolant が設定値より上（循環に余裕）→ `SEEK+`、設定値ぴったり → `HOLD`、下 → `SEEK-`。起動オーバーシュートと波は slew リミッタ（上げ gentle・下げ速い）+ アンチワインドアップで抑制 → 定常は波ゼロ。

**★出力をもっと攻めたい → `coolantSetpoint` を下げる（例 8）。安全マージンを厚く → 上げる（例 20）。** これが唯一の主ツマミ。

**安全層（ハード・下げのみ）**: `COOL!`（温度→半減）/ `COOL-SAT`（coolant フロア割れ・heated 上限超・急落→強降圧）/ `THROTTLE`（タービン満タン）/ `SCRAM`（coolant < 3% 等の最終手前）。

### 設計の検証（シミュレーター）
`sim/` に**実機の循環物理モデル**を構築（`sim/bench.py`）。複数の runout 上限で検証し、**全上限で coolant=設定値に張り付き・burn が runout の ~88%（持続可能最大）・波ゼロ・溶融ゼロ**を確認。実物 `reactor.lua` を循環モデルで回す統合テスト（`sim/verify_control.py`）でも、coolant が循環で下がりながら理論上限の直下に滑らかに張り付くこと・SCRAM 誤発振が無いことを確認。

| キー | 既定 | 説明 |
|---|---|---|
| **`control.coolantSetpoint`** | 12 | **★唯一の主ツマミ。coolant をこの % に保つよう burn を自動調整。低いほど高出力（runout に近い）。** 手動時に coolant が安定する低い値の少し上に |
| `control.piKiFraction` / `piKpFraction` | 0.0008 / 0.002 | PI ゲイン（炉サイズ非依存）。通常いじらない |
| `control.piUpSlewFraction` / `piDownSlewFraction` | 0.006 / 0.10 | 上げ/下げの最大速度（炉最大 /秒）。上げが遅ければ上げる |
| `control.maxBurnRateFraction` | 1.0 | 上限キャップ（手動キャップにも使える）|
| `control.coolantFloorPct` / `heatedCeilPct` | 5 / 80 | 割ると `COOL-SAT` 強制降圧（運転点 coolant≈設定値 / heated は数十% の外側に設定）|
| `control.coolingTrendFast` | 6.0 | %/秒。coolant がこの速さ以上で急落→即 `COOL-SAT` |
| `safety.minCoolantPct` | 3 | coolant がこれ未満（runout 直前）で SCRAM |
| `tickInterval` | 0.5 | 制御・描画の周期（秒）|

> **そのまま入れれば自動で理論上限まで上がって張り付く。** 主なツマミは `coolantSetpoint` ひとつ：高出力なら下げる、安全マージンを厚くするなら上げる。
> 画面右上のスピナーと `0.5s` は**実測の更新間隔**。回っていれば制御は生きている。

## 仕組み

`peripheral.find("fissionReactorLogicAdapter")`（取れなければ `getTemperature` を持つ機器を総当たり）でアダプタを掴み、毎サイクル `getTemperature` / `getDamagePercent` / `get*FilledPercentage` 等を読む。coolant を低い設定値(既定 12%)に PI 制御で保つよう `setBurnRate` を調整し、理論上限の直下に張り付く。温度・冷却フロア・タービンの異常時はハード安全層が降圧、危険なら `scram()`。

`%` 系の API は版によって割合(0-1)と %(0-100) のどちらも返しうるため、`1.0 以下なら割合とみなして ×100` で正規化している（`reactor.lua` の `toPct`）。

## ⚠️ 免責

このプログラムはベストエフォートの安全装置を実装しているが、MOD のバージョン差・config の設定ミス・想定外の構成により正しく動作しない可能性がある。**重要な世界で使う前に必ずテスト**すること。炉の暴走による損害について作者は責任を負わない。

## License

MIT
