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

## 自動制御の仕組み / チューニング（設計思想 v3 = auto-seek）

**炉ごとの「捌ける最大 burn（理論上限）」を信号から自動発見して、その直下に滑らかに張り付く。** 目標値を手で設定しなくていい。どの炉でも勝手に理論上限まで上がる。

仕組み: **coolant を安全ゾーン(≈100%)に保ったまま境界をなぞる。**
- 上限以下では coolant=100% に張り付く＝信号が出ない＝**余裕あり → ゆっくり攻める**（`SEEK+`）。境界直下（coolant が 100 からわずかに下降）では攻めを弱めてオーバーシュート抑制。
- 境界を越えると coolant が下がり heated が上がる → **即引く**（`SEEK-`、非対称: 引きは攻めより速い）。
- 結果、理論上限の**直下に張り付いて微小に上下するだけ**（波がごく小さい）。

**安全層（ハード・下げ方向のみ）**: `COOL!`（温度ソフト上限/予測scram→半減）/ `COOL-SAT`（冷却フロア割れ・**急速悪化＝崖の入り口を %/秒で検知**→強降圧）/ `THROTTLE`（タービン満タン→降圧）。

### 設計の検証（シミュレーター）
`sim/` に物理ベンチを構築し、**6 つの制御戦略を競わせて客観評価**した（`sim/bench.py` / `sim/bench_multi.py`）。勝者（採用方式）は **隠し上限 250/600/850/950 の全てで到達率 ≈ 100%（理論上限に張り付く）× 波 P2P < 9 × 溶融ゼロ**。実物 `reactor.lua` を物理モデルで回した統合テスト（`sim/verify_control.py`）でも別の上限で同等を確認。

| キー | 既定 | 説明 |
|---|---|---|
| `control.coolantHealthyPct` / `heatedHealthyPct` | 99.5 / 0.5 | これより健全なら「余裕あり」と判断して攻める。**もっと安全マージンが欲しいなら coolantHealthy を上げる**（例 99.8）|
| `control.seekUpFraction` | 0.003 | 攻める速さ（炉最大 /秒）。**もっと速く上限に着けたいなら上げる**（例 0.006）。波が出るなら下げる |
| `control.seekDownFraction` / `seekBackoffFraction` | 0.0015 / 0.0003 | ストレス時の引きの強さ（炉最大基準）。非対称で攻めより速い |
| `control.seekBrakePct` / `seekBrakeFactor` | 99.95 / 0.25 | 境界直下で攻めを弱める閾値と係数（オーバーシュート抑制）|
| `control.maxBurnRateFraction` | 1.0 | 上限キャップ。**燃料節約等で出力を頭打ちにしたいなら下げる**（手動キャップにも使える）|
| `control.softTemp` | (自動) | これ以上で burn 半減（profile から自動）|
| `control.coolantFloorPct` / `heatedCeilPct` | 40 / 60 | 割ると `COOL-SAT` 強制降圧 |
| `control.coolingTrendFast` | 3.0 | %/秒。**急速悪化（崖の入り口）で即 `COOL-SAT`** ＝最重要保険 |
| `tickInterval` | 0.5 | 制御・描画の周期（秒）。2回/秒 |

> **そのまま入れれば自動で理論上限まで上がって張り付く。** チューニング不要。もし張り付きが遅いと感じたら `seekUpFraction` を上げる、波が気になるなら下げる、安全マージンを厚くしたいなら `coolantHealthyPct` を上げる。
> 画面右上の `|/-\` スピナーと `0.5s` は**実測の更新間隔**。回っていれば制御は生きている。

## 仕組み

`peripheral.find("fissionReactorLogicAdapter")`（取れなければ `getTemperature` を持つ機器を総当たり）でアダプタを掴み、毎サイクル `getTemperature` / `getDamagePercent` / `get*FilledPercentage` 等を読む。coolant を安全ゾーン(≈100%)に保ちつつ、余裕があれば `setBurnRate` を少し上げ・冷却が崩れ始めたら即下げる auto-seek で理論上限の直下に張り付く。温度・冷却フロア・タービンの異常時はハード安全層が降圧、危険なら `scram()`。

`%` 系の API は版によって割合(0-1)と %(0-100) のどちらも返しうるため、`1.0 以下なら割合とみなして ×100` で正規化している（`reactor.lua` の `toPct`）。

## ⚠️ 免責

このプログラムはベストエフォートの安全装置を実装しているが、MOD のバージョン差・config の設定ミス・想定外の構成により正しく動作しない可能性がある。**重要な世界で使う前に必ずテスト**すること。炉の暴走による損害について作者は責任を負わない。

## License

MIT
