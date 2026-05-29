-- test_monitor.lua  —  モニター更新の切り分けテスト（fission とは無関係）
--
-- モニターに 0.5 秒ごとにカウントアップする数字だけを出す。
--   * 数字が自分で増えていく → モニター同期は正常。問題は fission のループ側
--   * 数字が固まる/タップした時だけ飛ぶ → サーバーがモニター同期を間引いている
--     （低 TPS 等のサーバー側要因。コードのせいではない）
--
-- 実行: wget run https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/test_monitor.lua
-- 終了: Ctrl+T

local m = peripheral.find("monitor") or term
if m.setTextScale then m.setTextScale(1) end

local i = 0
while true do
  i = i + 1
  if m.setBackgroundColor then m.setBackgroundColor(colors.black) end
  m.clear()
  m.setCursorPos(1, 1)
  if m.setTextColor then m.setTextColor(colors.white) end
  m.write("monitor test")
  m.setCursorPos(1, 2)
  m.write("tick = " .. i)
  m.setCursorPos(1, 3)
  m.write("epoch = " .. os.epoch("utc"))
  m.setCursorPos(1, 5)
  m.write("counts up by itself = monitor OK")
  m.setCursorPos(1, 6)
  m.write("frozen/jumps on tap = server sync lag")
  sleep(0.5)
end
