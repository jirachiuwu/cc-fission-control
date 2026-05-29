-- install.lua  —  cc-fission-control インストーラ
-- ゲーム内コンピュータで:  wget run <このファイルのraw URL>
-- 全ファイルをこのコンピュータのルート(/)に落とす。

local BASE = "https://raw.githubusercontent.com/jirachiuwu/cc-fission-control/main/"

local files = { "config.lua", "reactor.lua", "turbine.lua", "state.lua", "ui.lua", "fission.lua", "startup.lua" }

print("Installing cc-fission-control...")
for _, f in ipairs(files) do
  if fs.exists(f) then fs.delete(f) end
  local url = BASE .. f
  write("  " .. f .. " ... ")
  local ok = shell.run("wget", url, f)
  print(ok and "OK" or "FAILED")
end

print("")
print("Done. Next:")
print("  1) edit config.lua  (set debug=true on first run)")
print("  2) run 'fission', press R / tap ARM to start")
