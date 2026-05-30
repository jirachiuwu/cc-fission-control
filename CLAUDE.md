# CLAUDE.md — cc-fission-control（開発再開の手引き）

Minecraft (Mekanism + ComputerCraft: Tweaked) の**核分裂炉 自動制御プログラム**（Lua, CC内で実行）。
GitHub: https://github.com/jirachiuwu/cc-fission-control （public）

このファイルは、次に開発を再開する Claude / 人間がすぐ文脈に入るための入口。

## まず読む順
1. この CLAUDE.md（全体像と作法）
2. [`docs/DESIGN.md`](docs/DESIGN.md) — 現行設計・実機の物理・制御アルゴリズム・config 全リファレンス
3. [`docs/DEVELOPMENT_LOG.md`](docs/DEVELOPMENT_LOG.md) — なぜこうなったか・教訓・**まだ粗い点 / 次にやれること**
4. [`docs/SIMULATOR.md`](docs/SIMULATOR.md) — ゲーム外で制御を検証する仕組み（開発の要）
5. [`README.md`](README.md) — ユーザー向け（導入・使い方）

## 現状（要約）
- 制御は **v4.2 = 二重制約 PI**（coolant 下限 + heated 上限の「先に効く方」で頭打ち）+ 変化率ゲート。version `b16`。
- 「炉ごとの理論上限を自動発見して張り付く」は概ね達成。ユーザー評価は「とりあえず OK、まだ詰められるくらい粗い」。
- 残タスクは DEVELOPMENT_LOG の「refinement backlog」（タービン蒸気の直接読み取り / setpoint 自動チューニング / ゲイン最適化 等）。

## 開発の鉄則（このプロジェクト固有）
- **物理を推測で実装しない。** 不明点はユーザー実測 or 現物で確かめる。`sim/` のモデルが現実とズレてたら**まずモデルを直す**（過去 v3 はこれで失敗）。
- **ゲーム外シミュで先に検証**してから実機。フロー: 候補 .lua を `sim/bench.py` で詰める → `reactor.lua` に移植 → `sim/verify_control.py` で統合テスト → version 上げ → commit/push。
- **画面に出す文字は ASCII 限定**（CC は日本語非対応）。コメントは日本語 OK。
- **デプロイ確認**: 変更は `config.version` を上げる。ユーザーがゲーム内で `wget run install.lua` を流し直さないと反映されない（よくある「変わらない」の原因）。ヘッダの version で確認。
- **安全 > 出力。** 下げは速く・上げは控えめ（非対称）。多重安全層（PI 制約 → COOL-SAT → SCRAM）。
- **速度/ゲインは maxBurn の割合**（炉サイズ非依存に保つ）。

## ビルド/実行
- CC 内: `wget run https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/install.lua` → `fission`。
- ローカル検証: `python -m pip install lupa` 済み前提で `python sim/bench.py sim/cand_pi4.lua 900 0.15 400` 等。

## 環境メモ
- ユーザーの炉は大型（maxBurn ~1000 級）、**タービン律速**寄り（蒸気がパンパンになりやすい）。
- サーバーは多 MOD・低 TPS になりがち（イベントキュー溢れ・peripheral 重い・モニター同期遅延の前提で設計済み）。
- スクショ共有: ユーザーは PowerShell ターミナルに画像を貼れない。Win+PrtScn で `C:\Users\roseria\Pictures\Screenshots\` に保存 → Read tool で画像を直接読める。

## 主要ファイル
`fission.lua`(メイン/ループ) / `reactor.lua`(制御本体 autoAdjust) / `config.lua`(全設定+version) /
`ui.lua`(描画) / `turbine.lua` / `state.lua` / `startup.lua` / `install.lua` / `sim/`(検証) / `docs/`。
