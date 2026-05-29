-- install.lua  —  cc-fission-control インストーラ
-- ゲーム内コンピュータで:  wget run <このファイルのraw URL>
-- 全ファイルをこのコンピュータのルート(/)に落とす。

local BASE = "https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/"

local files = { "config.lua", "reactor.lua", "turbine.lua", "state.lua", "ui.lua", "fission.lua", "startup.lua" }

print("cc-fission-control をインストールします...")
for _, f in ipairs(files) do
  if fs.exists(f) then fs.delete(f) end
  local url = BASE .. f
  write("  " .. f .. " ... ")
  local ok = shell.run("wget", url, f)
  print(ok and "OK" or "失敗")
end

print("")
print("完了。次の手順:")
print("  1) edit config.lua  でしきい値を確認（初回は debug=true 推奨）")
print("  2) fission  で起動、R キーで点火")
