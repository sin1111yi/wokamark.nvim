-- wokamark.ui — display: pickers, manage buffer, help window
-- Depends on wokamark.storage (data ops) and wokamark.session (mark/load).

local storage = require('wokamark.storage')
local session = require('wokamark.session')

local M = {}

local ns = vim.api.nvim_create_namespace('wokamark')

-- decorate entries with the text field the snacks matcher filters on;
-- decoration never reaches index.json (write_index persists a clean copy)
local function decorate_items(workspaces)
  return vim.tbl_map(function(w)
    w.text = storage.display_name(w) .. (w.repo and (' (' .. (w.branch or '') .. ')') or '')
    return w
  end, workspaces)
end

-- snacks format must return a Highlight[] (array of {text, hl?}),
-- a bare string crashes the picker renderer.
local function picker_format(item)
  local git_part = item.repo and (' (' .. (item.branch or '') .. ')') or ''
  return { { storage.display_name(item) .. git_part } }
end

-- preview return value is discarded by snacks; write via ctx.preview.
local function picker_preview(ctx)
  local w = ctx.item
  ctx.preview:set_title(w.name or w.repo or w.cwd)
  ctx.preview:set_lines({ w.cwd, '', 'last used: ' .. (w.last_used or '?') })
  return true
end

local function require_snacks()
  local ok, snacks = pcall(require, 'snacks.picker')
  if not ok then
    vim.notify('Wokamark: snacks.nvim required for picker', vim.log.levels.WARN)
    return nil
  end
  return snacks
end

-- :WokaMarkOpen — list all workspaces, select to restore
function M.open_picker()
  local workspaces = storage.read_index()
  if #workspaces == 0 then
    vim.notify('Wokamark: no workspaces marked yet (:WokaMarkCurrent)', vim.log.levels.INFO)
    return
  end
  local snacks = require_snacks()
  if not snacks then return end
  snacks.pick({
    title = 'Workspaces',
    items = decorate_items(workspaces),
    format = picker_format,
    preview = picker_preview,
    confirm = function(picker, item)
      picker:close()
      session.load_entry(item)
    end,
  })
end

-- :WokaMarkManage — lazygit-style management buffer (list + d/r/a/i/q).
-- A dedicated normal-mode UI instead of the snacks picker (whose default
-- insert-mode filter swallowed d/r/a/i and Esc closed the picker).
function M.manage_picker()
  local buf = vim.api.nvim_create_buf(false, true) -- scratch, unlisted
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'wokamark'
  vim.bo[buf].modifiable = true

  local function current_entry()
    local workspaces = storage.read_index()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    return workspaces[line]
  end

  local function redraw(keep_cursor)
    vim.bo[buf].modifiable = true -- redraw must re-enable before set_lines
    local workspaces = storage.read_index()
    local lines = {}
    for i, w in ipairs(workspaces) do
      local git = w.repo and (' (' .. (w.branch or '') .. ' [' .. (w.hash or '') .. '])') or ''
      lines[#lines + 1] = string.format('%2d  %s%s', i, storage.display_name(w), git)
    end
    if #lines == 0 then
      lines = { '  (no workspaces yet — :WokaMarkCurrent to mark this path)' }
    end
    -- bottom hint bar (lazygit style)
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  d 删除  r 重命名  a 添加  i 详情  <CR> 恢复  q 退出'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    -- hint bar in a theme-aware group (follows the active colorscheme)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local hint_line = #lines
    vim.api.nvim_buf_set_extmark(buf, ns, hint_line - 1, 0, {
      hl_group = 'Comment',
      end_col = #lines[hint_line],
    })
    local maxline = math.max(1, math.min(#workspaces, #lines))
    local row = keep_cursor and math.min(vim.api.nvim_win_get_cursor(0)[1], maxline) or 1
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    pcall(vim.api.nvim_win_set_option, 0, 'cursorline', true)
  end

  local function close_manage()
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local keymaps = {
    j = function() vim.api.nvim_win_set_cursor(0, { math.min(vim.api.nvim_buf_line_count(0), vim.api.nvim_win_get_cursor(0)[1] + 1), 0 }) end,
    k = function() vim.api.nvim_win_set_cursor(0, { math.max(1, vim.api.nvim_win_get_cursor(0)[1] - 1), 0 }) end,
    ['<Down>'] = function() vim.api.nvim_win_set_cursor(0, { math.min(vim.api.nvim_buf_line_count(0), vim.api.nvim_win_get_cursor(0)[1] + 1), 0 }) end,
    ['<Up>'] = function() vim.api.nvim_win_set_cursor(0, { math.max(1, vim.api.nvim_win_get_cursor(0)[1] - 1), 0 }) end,
    d = function()
      local e = current_entry()
      if not e then return end
      storage.delete_entry(e)
      redraw(true)
    end,
    r = function()
      local e = current_entry()
      if not e then return end
      local new_name = vim.fn.input('Wokamark rename: ', storage.display_name(e))
      if new_name ~= '' then storage.rename_entry(e, new_name) end
      redraw(true)
    end,
    a = function()
      session.mark({})
      redraw(true)
    end,
    i = function()
      local e = current_entry()
      if not e then return end
      local details = {
        '名称:     ' .. storage.display_name(e),
        'cwd:      ' .. (e.cwd or '-'),
        'repo:     ' .. (e.repo or '-'),
        'branch:   ' .. (e.branch or '-'),
        'commit:   ' .. (e.hash or '-'),
        'path hash:' .. (e.path_hash or '-'),
        'last used:' .. (e.last_used or '-'),
        'session:  ' .. (e.session or '-'),
      }
      vim.notify(table.concat(details, '\n'), vim.log.levels.INFO, { title = 'Wokamark' })
    end,
    ['<CR>'] = function()
      local e = current_entry()
      if not e then return end
      close_manage()
      session.load_entry(e)
    end,
    q = close_manage,
    ['<Esc>'] = close_manage,
  }
  for keys, fn in pairs(keymaps) do
    vim.keymap.set('n', keys, fn, { buffer = buf, silent = true, nowait = true })
  end

  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(30, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' WokaMark — Manage workspaces ',
    title_pos = 'center',
  })
  redraw(false)
end

-- ── help ────────────────────────────────────────────────────────────

-- Help lines, bilingual. With no argument, the system locale decides
-- (LC_ALL > LC_MESSAGES > LANG; zh* -> Chinese, else English). With a
-- 'zh'/'en' argument, that language is returned explicitly (used by the
-- trigger-help registration, which stores both languages).
function M.help_lines(lang)
  lang = lang or (vim.env.LC_ALL or vim.env.LC_MESSAGES or vim.env.LANG or ''):lower()
  if lang:match('^zh') then
    return {
      'WokaMark — 工作区会话管理',
      '',
      '命令:',
      '  :WokaMarkCurrent   标记当前路径（手动标记）',
      '  :WokaMarkOpen      打开选择器，选择工作区并恢复',
      '  :WokaMarkManage    管理选择器：d=删除 r=重命名 a=添加 i=详情',
      '  :WokaMarkHelp      显示本帮助',
      '',
      '自动标记:  默认开启，setup { auto_mark = true } 可配置',
      '自动恢复:  启动时按打开路径的哈希匹配已标记工作区',
      '',
      '存储:  ~/.local/state/nvim/wokamark/',
    }
  end
  return {
    'WokaMark — workspace session manager',
    '',
    'Commands:',
    '  :WokaMarkCurrent   mark the current path',
    '  :WokaMarkOpen      picker: select a workspace to restore',
    '  :WokaMarkManage    manage: d=delete r=rename a=add i=info',
    '  :WokaMarkHelp      show this help',
    '',
    'Auto-mark: on by default; setup { auto_mark = true } to configure',
    'Auto-restore: hash of the opened path matched on startup',
    '',
    'Storage:  ~/.local/state/nvim/wokamark/',
  }
end

function M.help()
  local lines = M.help_lines()
  local width = 64
  local height = #lines + 2
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
  })
  local close = function() pcall(vim.api.nvim_win_close, win, true) end
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
end

return M
