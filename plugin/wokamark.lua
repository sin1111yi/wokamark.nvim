-- plugin/wokamark.lua — command + event registration
-- Executed when the plugin is packadded (see config/loader.lua).
--
-- Guard: `:packadd` during config sourcing followed by nvim's startup
-- plugin-load phase sources this file twice (both add the plugin dir to
-- 'runtimepath', and the startup phase re-sources plugin/*.lua from every
-- rtp entry). Without a guard, every autocmd/command below would register
-- twice -> auto-restore and "loaded" notifications fire twice.
if vim.g.wokamark_plugin_loaded then
  return
end
vim.g.wokamark_plugin_loaded = true

vim.api.nvim_create_user_command('WokaMarkCurrent', function()
  require('wokamark').mark({})
end, { desc = 'WokaMark: mark current directory as a workspace' })

vim.api.nvim_create_user_command('WokaMarkOpen', function()
  require('wokamark').open_picker()
end, { desc = 'WokaMark: picker over workspaces; select to restore' })

vim.api.nvim_create_user_command('WokaMarkManage', function()
  require('wokamark').manage_picker()
end, { desc = 'WokaMark: manage workspaces (d delete / r rename / a add / i info)' })

vim.api.nvim_create_user_command('WokaMarkHelp', function()
  require('wokamark').help()
end, { desc = 'WokaMark: show floating help' })

-- Auto restore on startup: hash of the opened path (argv(0) is still the
-- real path at VimEnter time — plugin windows rewrite argv only later),
-- matched against marked workspace path hashes.
vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  callback = function()
    vim.schedule(function()
      pcall(require('wokamark').auto_restore)
    end)
  end,
})

-- Auto mark on file open / leave insert / save.
-- args.buf is captured in the event context: auto_mark judges buftype and
-- file name from THAT buffer, not from the buffer current once the
-- scheduled callback runs (vim.schedule re-enters after BufLeave etc.).
vim.api.nvim_create_autocmd({ 'BufReadPost', 'InsertLeave', 'BufWritePost' }, {
  callback = function(args)
    vim.schedule(function()
      pcall(require('wokamark').auto_mark, args.buf)
    end)
  end,
})

-- Git HEAD change detection (commit/checkout)
vim.api.nvim_create_autocmd('CursorHold', {
  callback = function()
    pcall(require('wokamark').check_git_head)
  end,
})
