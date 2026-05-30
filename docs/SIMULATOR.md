# SIMULATOR — ゲーム外で制御を設計・検証する仕組み

> `sim/` は、ゲーム内で走らせる前に制御ロジックを机上で検証するためのもの。
> 実物の `reactor.lua` / `config.lua` を **lupa(LuaJIT)** でそのまま Python から読み込み、
> Mekanism 風の物理モデルに対して毎 tick 走らせて挙動を数値化する。

---

## なぜ必要か
- ゲーム内の試行錯誤はコスト高（メルトダウン = ワールド破壊、再インストール、サーバー再起動）。
- 制御の暴走・発振・収束不能・行き過ぎは、物理モデルがそこそこ正しければ机上で露見する。
- ⚠️ ただし**モデルが現実と合っている範囲でしか正しくない**（DEVELOPMENT_LOG の v3 の戒め）。
  実機の挙動が想定と違ったら、まずモデルを直す。

## セットアップ
```
python -m pip install lupa     # LuaJIT 同梱、これだけ
```
ローカルに Lua インタプリタは不要（lupa が内蔵）。Python 3.x。

## ファイル

| ファイル | 役割 |
|---|---|
| `sim/bench.py` | **候補制御を物理モデルで走らせ指標を JSON 出力**。引数: `<候補.lua> [B0] [kSettle] [Bt]` |
| `sim/bench_multi.py` | 候補を複数の隠し上限でまとめて回し汎化を見る（旧 cliff モデル時代のもの。現行モデルは bench.py に引数で）|
| `sim/verify_control.py` | **実物の reactor.lua を循環モデルで回す統合テスト**（ポートのバグ検出）|
| `sim/cand_*.lua` | 各制御戦略の候補。`function control(s)` を定義。設計の履歴でもある |
| `sim/cand_pi4.lua` | 現行採用の二重制約 PI（reactor.lua の autoAdjust と等価ロジック）|

## 物理モデル（`sim/bench.py`）
- `maxBurn=1000`、`B0`=coolant runout 上限、`Bt`=タービン上限（蒸気飽和）、`kSettle`=復水の速さ（小=遅れ大）。
- 各 tick:
  - `heated → 100*burn/Bt` に一次遅れで追従（タービン上限に近づくほど上昇、Bt で飽和）。
  - `coolant → 100*(1-burn/B0) - backup` に追従（heated>80 で backup＝ボイラー水枯れで coolant 道連れ）。
  - 温度は burn に緩く比例 + coolant<5% で急騰。`temp>=1200` で melt。
- = 「上限以下は安定、超えると coolant 枯れ or 蒸気飽和で崖」を近似。

## 候補インターフェース
候補 `.lua` 内に定義:
```lua
-- s = { burn, temp, coolant, heated, maxBurn, dt, t, mem }
--   mem は永続テーブル（コントローラの内部状態）。使う信号は coolant/heated/temp/burn/maxBurn/dt のみ。
function control(s)
  ...
  return 新しい burn rate（数値）
end
```
実 MOD（reactor.lua）が読めるのと同じ信号だけを使う（cap 等の隠し値は禁止＝カンニング）。

## 指標の読み方（bench.py の JSON）
- `ssMean` 定常 burn 平均（高いほど良いが、律速点に対しての話）。
- `ssP2P` 定常 burn の山谷差（小さいほど滑らか）。`0` が理想。
- `ssCoolant` / `ssHeated` 定常の冷却状態（運転点）。
- `melted` true なら失格。
- `maxBurnReached` 過渡の最大（runout を大きく超えていたら起動オーバーシュート過大）。
- `ratioToRunout` ssMean/B0。

## 使い方の例
```
# 二重制約PIを各律速で
python sim/bench.py sim/cand_pi4.lua 900 0.15 400   # タービン律速 (B0=900, Bt=400)
python sim/bench.py sim/cand_pi4.lua 600 0.15 2000  # 冷却材律速
# 復水ラグを大きくして行き過ぎを見る
python sim/bench.py sim/cand_pi4.lua 645 0.04 900
# 実物 reactor.lua の統合テスト
python sim/verify_control.py
```

## 開発フロー（制御を変える時）
1. `sim/cand_X.lua` に候補ロジックを書く。
2. `python sim/bench.py sim/cand_X.lua <B0> <kSettle> <Bt>` を**複数条件**で回してチューニング
   （律速違い・ラグ違い・サイズ違いで汎化を確認、melt をゼロに、波を最小化）。
3. 良ければ `reactor.lua` の `autoAdjust` に移植（+ 必要な config キー追加）。
4. `python sim/verify_control.py` で**実物 reactor.lua の統合テスト**（ポートのバグ・config 整合・SCRAM 誤発振を検出）。
5. `config.version` を上げて commit/push。ゲーム内で `install.lua` 流し直し → ヘッダの version 一致を確認。

## ワークフロー（設計パネル）方式
v3 では複数戦略を**並列エージェントで競わせて**客観スコアで選んだ（MPPT / PI-coolant / PI-heated / integral-seek / rate-null / freestyle）。
大きな設計刷新の時は同じ手が使える: 各戦略を候補 .lua として書かせ、ベンチでスコア化し、汎化で過学習を弾いて勝者を選ぶ。
