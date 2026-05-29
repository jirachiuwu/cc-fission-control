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
- **制御の可視化**: RUNNING 中は状態行に制御内容を表示（例 `RAISE 2.0->2.5` = 温度不足で出力上昇中 / `HOLD` / `LOWER` / `THROTTLE`）。自動制御が効いているか一目で分かる

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
| `control.targetTemp` | (profile) | 自動制御の目標温度（K、プロファイルで決まる）|
| `control.maxBurnRateFraction` | 1.0 | 炉上限に対する burn rate の割合上限 |
| `turbine.enabled` | true | タービン監視の ON/OFF |
| `turbine.throttleAtPct` | 99 | タービンエネルギーがこれ以上なら出力を絞る（%）|
| `turbine.required` | false | true でタービン未検出時に起動中止 |

## 自動制御の仕組み / チューニング

制御は **`tickInterval` 秒ごと（既定 1 秒）に 1 回**判定する。核分裂炉は熱に遅れ（thermal lag）があり、攻めた制御は**オーバーシュート（行き過ぎ）→ 過熱事故**を起こす。そこで安全側の 3 段構え:

1. **緊急冷却**: 温度がソフト上限（target と scram の中間）に達する、または**温度上昇率から予測した数秒先**が scram 超え → burn rate を**半減**して叩き落とす（hard scram に到達させない）
2. **冷却の追従をトレンドで見る（メルトダウン予防の本命）**: burn を上げると、ある点で**復水（冷却材の戻り）が追いつかなくなる**。ただし復水は待てば追いつくので、残量が少し減っただけでは止めない。見るのは**変化率**：coolant が下がり「続けている」/ heated が上がり「続けている」＝追いついていない兆候（温度より先に出る）。じわじわ下降 → **上げずに待つ**（`CATCHUP` 表示、復水の回復待ち）。横ばい/回復に戻れば**また上げる**（＝捌ける上限まで攻める）。急悪化やフロア割れ → 温度無視で**下げる**（`COOL-SAT`）
3. **非対称制御**: 上げは控えめ（`maxRiseFraction`）、下げは強め（`maxFallFraction`）。加熱は慎重・冷却は全力
4. **予測で先回り**: このまま上げると目標を超えそうなら、目標未満でも上げを止める（画面に `WAIT` 表示）

| キー | 既定 | 説明 |
|---|---|---|
| `control.lookahead` | 4 | 温度上昇率から何 tick 先を予測してオーバーシュートを防ぐか |
| `control.riseGain` / `maxRiseFraction` | 0.20 / 0.08 | 上げの強さ / 1tick の上げ上限（炉最大burn 比）。**遅いと感じたら上げる** |
| `control.fallGain` / `maxFallFraction` | 1.0 / 0.5 | 下げの強さ / 1tick の下げ上限 |
| `control.tempDeadband` | 10 | 目標±この範囲は触らない（発振防止）|
| `control.softTemp` | (自動) | 緊急冷却の発動温度（target と scram の中間、プロファイルから自動計算）|
| `control.coolingTrendTol` | 0.8 | %/秒。coolant がこの速さ以上で下降 / heated が上昇 → **上げずに待つ**（`CATCHUP`）|
| `control.coolingTrendFast` | 3.0 | %/秒。この速さ以上で悪化 → **強制降圧**（`COOL-SAT`）|
| `control.coolantFloorPct` / `heatedCeilPct` | 30 / 85 | 残量がここまで来たらトレンド無視で**降圧**（scram 25/95 の手前ガード）|
| `tickInterval` | 0.5 | 制御・描画の周期（秒）。0.5 = 2回/秒。ゲインは周期で自動スケールするので変えても挙動同じ |
| `extrasRefreshSec` | 2 | 表示専用の重い値を読む間隔（秒）。peripheral 呼び出しを間引いて重い鯖でも軽くする |

> 画面右上の `|/-\` スピナーと `0.5s` は**実測の更新間隔**。これが回っていれば制御は動いている。もしモニター表示が固まって見えるのにボタンを押すとスピナー（と数値）が一気に進む場合は、サーバー（低 TPS）がモニターのクライアント同期を間引いているのが原因で、プログラム自体は動いている。

> **遅い**と感じたら `riseGain` / `maxRiseFraction` を上げる。**振動/行き過ぎ**するなら下げる。安全マージンが薄いと感じたらプロファイルの `scramTemp` を下げる。画面の `dT` は温度上昇率（+で上昇中）。

## 仕組み

`peripheral.find("fissionReactorLogicAdapter")`（取れなければ `getTemperature` を持つ機器を総当たり）でアダプタを掴み、毎サイクル `getTemperature` / `getDamagePercent` / `get*FilledPercentage` 等を読む。安全判定を通れば、目標温度との差分で `setBurnRate` を比例調整。危険なら `scram()`。

`%` 系の API は版によって割合(0-1)と %(0-100) のどちらも返しうるため、`1.0 以下なら割合とみなして ×100` で正規化している（`reactor.lua` の `toPct`）。

## ⚠️ 免責

このプログラムはベストエフォートの安全装置を実装しているが、MOD のバージョン差・config の設定ミス・想定外の構成により正しく動作しない可能性がある。**重要な世界で使う前に必ずテスト**すること。炉の暴走による損害について作者は責任を負わない。

## License

MIT
