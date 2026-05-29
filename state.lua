-- state.lua
-- 画面操作で変えた設定（プロファイル等）をファイルに保存し、次回起動で復元する。
-- config.lua は「初期値/定義」、この state は「運用中の上書き」を担う。

local M = {}
local PATH = "/fission_state"

function M.load()
  if fs.exists(PATH) then
    local f = fs.open(PATH, "r")
    if f then
      local s = f.readAll()
      f.close()
      local ok, t = pcall(textutils.unserialize, s)
      if ok and type(t) == "table" then
        return t
      end
    end
  end
  return {}
end

function M.save(t)
  local f = fs.open(PATH, "w")
  if f then
    f.write(textutils.serialize(t))
    f.close()
  end
end

return M
