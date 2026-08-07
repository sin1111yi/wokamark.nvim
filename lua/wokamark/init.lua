-- wokamark.nvim — per-directory workspace session restore
-- Entry point: setup + config + trigger-help integration.
-- Logic lives in wokamark.{config,storage,git,session,ui}.
--
-- Commands (registered in plugin/wokamark.lua):
--   :WokaMarkCurrent   save current workspace (mark current path)
--   :WokaMarkOpen      picker over all workspaces; select -> restore
--   :WokaMarkManage    manage UI: d=delete r=rename a=add i=info
--   :WokaMarkHelp      floating help (locale-aware: zh* -> 中文)
-- Auto:
--   restore on VimEnter: hash of the opened path matched against marked
--     workspaces' path hashes, walking up ancestors
--   auto-mark on BufReadPost / InsertLeave / BufWritePost / git HEAD change
--     (debounced per cwd); enabled via setup { auto_mark = true } (default)

local config = require('wokamark.config')
local session = require('wokamark.session')
local ui = require('wokamark.ui')

local M = {}

M.config = config

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  session.set_config(M.config)
  -- Register the command cheatsheet with trigger-help when that plugin
  -- is available (best-effort: trigger-help not installed/loaded ->
  -- skip silently, never error).
  local ok, th = pcall(require, 'trigger_help')
  if ok and type(th.register_doc) == 'function' then
    pcall(th.register_doc, {
      id = 'wokamark',
      name = { en = 'wokamark usage', zh = 'wokamark 使用' },
      text = { en = ui.help_lines('en'), zh = ui.help_lines('zh') },
    })
  end
  return M
end

-- Aggregate the public API used by plugin/wokamark.lua command callbacks
-- and event hooks (keeps the plugin/ file unchanged).
M.mark = session.mark
M._mark_impl = session._mark_impl
M.load_entry = session.load_entry
M.open_picker = ui.open_picker
M.manage_picker = ui.manage_picker
M.help = ui.help
M.help_lines = ui.help_lines
M.auto_restore = session.auto_restore
M.auto_mark = session.auto_mark
M.check_git_head = session.check_git_head
M.should_open_tree = session.should_open_tree
M.open_tree_if_available = session.open_tree_if_available

return M
