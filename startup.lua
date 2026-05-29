-- startup.lua
-- コンピュータ起動時に自動で制御プログラムを走らせる。
-- 全ファイル（config.lua / reactor.lua / ui.lua / fission.lua）をこのコンピュータの
-- ルート(/)に置いた前提。require は同じディレクトリの兄弟ファイルを解決する。
shell.run("/fission.lua")
