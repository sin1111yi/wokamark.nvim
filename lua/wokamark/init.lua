-- wokamark.nvim — per-directory workspace session restore
-- Commands:
--   :WokaMarkCurrent   save current workspace (mark current path)
--   :WokaMarkOpen      picker over all workspaces; select -> restore
--   :WokaMarkManage    manage picker: d=delete r=rename a=add i=info
--   :WokaMarkHelp      floating help (locale-aware: zh* -> 中文)
-- Auto:
--   restore on VimEnter: hash of the opened path (argv(0), or cwd when no
--     file args) matched against the marked workspaces' path hashes, walking
--     up ancestor directories. argv(0) is the real path at VimEnter time
--     (plugin windows rewrite argv only later), so it is read there, early.
--   auto-mark on BufReadPost / InsertLeave / BufWritePost / git HEAD change
--     (debounced per cwd). Enabled via setup { auto_mark = true } (default).
--
-- Storage: stdpath('state')/wokamark/index.json + sessions/<name>.vim

local M = {}

-- config with defaults (zero hardcoding: tunables live here, not in code)
M.config = {
  auto_mark = true, -- debounced auto-marking on file events
  debounce = 30,    -- seconds between auto-marks for the same cwd
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  return M
end

local state_dir = vim.fn.stdpath('state') .. '/wokamark'
local index_file = state_dir .. '/index.json'
local sessions_dir = state_dir .. '/sessions'

-- git helper: run git in a given cwd, return trimmed stdout or nil
local function git_cmd(args, cwd)
  local obj = vim.system({ 'git', unpack(args) }, { cwd = cwd, text = true })
  local res = obj:wait()
  if res.code ~= 0 then return nil end
  local out = vim.trim(res.stdout)
  return out ~= '' and out or nil
end

-- git info for a cwd, or nil when not in a repo
local function git_info(cwd)
  local root = git_cmd({ 'rev-parse', '--show-toplevel' }, cwd)
  if not root then return nil end
  return {
    root = root,
    repo = vim.fn.fnamemodify(root, ':t'),
    branch = git_cmd({ 'rev-parse', '--abbrev-ref', 'HEAD' }, cwd) or 'HEAD',
    hash = git_cmd({ 'rev-parse', '--short', 'HEAD' }, cwd) or 'unknown',
  }
end

-- cwd -> path slug (readable fallback name when no git repo)
local function path_slug(cwd)
  local s = cwd:gsub('^/', ''):gsub('/', '-')
  return s ~= '' and s or 'root'
end

-- Canonical absolute path used for hashing: absolute, dot-segments
-- collapsed, trailing slashes stripped ('/' stays '/'). Both sides of a
-- match (mark-time cwd, restore-time opened path) go through the same
-- function so equal directories always produce equal hashes.
local function canon(p)
  local abs = vim.fn.fnamemodify(vim.fn.expand(p), ':p')
  abs = abs:gsub('/+$', '')
  if abs == '' then abs = '/' end
  return abs
end

-- path hash: sha256 of the canonical directory path (auto-restore key)
local function path_hash(cwd)
  return vim.fn.sha256(canon(cwd))
end

local function read_index()
  if vim.fn.filereadable(index_file) == 0 then return {} end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(index_file), '\n'))
  -- index.json may be valid JSON yet not the expected shape (e.g. a scalar
  -- or array after a botched write): decode succeeds but indexing
  -- data.workspaces would throw. Any non-table shape -> treat as empty.
  if not ok or type(data) ~= 'table' or type(data.workspaces) ~= 'table' then
    return {}
  end
  return data.workspaces
end

-- fields persisted to index.json (pickers decorate entries with text/score/
-- match_tick/idx — never write those back)
local INDEX_FIELDS = { 'cwd', 'repo', 'branch', 'hash', 'path_slug', 'path_hash', 'session', 'last_used', 'name' }

local function write_index(workspaces)
  vim.fn.mkdir(state_dir, 'p')
  local clean = vim.tbl_map(function(w)
    local c = {}
    for _, k in ipairs(INDEX_FIELDS) do
      if w[k] ~= nil then c[k] = w[k] end
    end
    return c
  end, workspaces)
  local ok, err = pcall(vim.fn.writefile, vim.split(vim.json.encode({ workspaces = clean }), '\n', { plain = true }), index_file)
  if not ok then
    local reason = (tostring(err):match('E%d+[^\n]*')) or tostring(err)
    vim.notify('Wokamark: failed to write index (' .. reason .. ')', vim.log.levels.WARN)
    return false
  end
  return true
end

-- Reversible escaping for a path segment embedded in a session file name.
-- Rule (user-approved): '/' -> '-', '-' -> '--', leading '/' dropped.
-- Escape '-' FIRST, then '/' — with that order a single '-' in the output
-- can only come from '/', so the mapping stays reversible and collision-free
-- for the slug cases that used to collide (e.g. '/a/b-c' vs '/a-b/c').
--   '/home/u/work/foo' -> 'home-u-work-foo'
--   '/a/b-c'           -> 'a-b--c'
--   '/a-b/c'           -> 'a--b-c'
-- Empty result (e.g. cwd == '/') falls back to 'root', same as path_slug.
local function escape_segment(s)
  s = s:gsub('^/+', '')
  s = s:gsub('-', '--')
  s = s:gsub('[/\\]', '-')
  if s == '' then return 'root' end
  return s
end

-- Truncate a UTF-8 string to at most maxbytes bytes without splitting a
-- multi-byte character (byte counts matter: ext4 NAME_MAX is 255 bytes).
local function truncate_utf8(s, maxbytes)
  if #s <= maxbytes then return s end
  local cut = maxbytes
  while cut > 0 do
    local b = s:byte(cut)
    -- continuation bytes (10xxxxxx) mean we are inside a multi-byte char
    if b and b >= 0x80 and b < 0xC0 then
      cut = cut - 1
    else
      break
    end
  end
  return s:sub(1, cut)
end

-- display name shown in lists (alias > repo > cwd)
local function display_name(w)
  return w.alias or w.name or w.repo or w.cwd
end

-- session file name:
--   with git:    <repo>-<branch>-<hash>-<cwd-escaped>.vim
--   without git: <cwd-escaped>.vim
-- The escaped cwd fingerprint makes same-named repos in different parent
-- dirs map to distinct files (previously they collided on
-- repo-branch-hash.vim and mksession! silently overwrote each other).
-- The cwd is escaped from the stored cwd, so legacy index entries pick up
-- the new scheme on their next mark too.
--
-- ext4 NAME_MAX is 255 bytes; a pathological cwd (e.g. 120 dashes, which
-- double to 240) can blow past it and make mksession fail. Names longer
-- than MAX_NAME_BYTES are degraded to a readable UTF-8-safe prefix + an
-- 8-hex sha256 suffix, so the file always lands on disk (readable AND
-- usable, as agreed). Same input -> same name, so overwrite semantics
-- are unaffected.
local MAX_NAME_BYTES = 240
local function session_name(w)
  local cwd = escape_segment(w.cwd or '')
  local name
  if w.repo then
    local branch = escape_segment(w.branch or 'HEAD')
    name = ('%s-%s-%s-%s'):format(w.repo, branch, w.hash or 'unknown', cwd)
  else
    name = cwd
  end
  if #name > MAX_NAME_BYTES then
    local digest = vim.fn.sha256(name):sub(1, 8)
    name = truncate_utf8(name, MAX_NAME_BYTES - 9) .. '-' .. digest
  end
  return name .. '.vim'
end

local function session_path(name)
  return sessions_dir .. '/' .. name
end

-- delete old session file (when overwriting an existing workspace entry)
local function delete_session(name)
  local p = session_path(name)
  if name and vim.fn.filereadable(p) == 1 then
    vim.fn.delete(p)
  end
end

-- ── public: mark ────────────────────────────────────────────────────

-- Save a workspace. opts.target: directory to mark (default: current cwd);
-- opts.silent suppresses the notify. With a target we cd there for the
-- duration of the save, then restore the previous cwd.
function M.mark(opts)
  opts = opts or {}
  local target = opts.target and vim.fn.fnamemodify(opts.target, ':p') or nil
  if target and vim.fn.isdirectory(target) ~= 1 then
    vim.notify('Wokamark: not a directory: ' .. target, vim.log.levels.WARN)
    return
  end
  local prev = vim.fn.getcwd()
  if target and prev ~= target then
    vim.cmd('cd ' .. vim.fn.fnameescape(target))
  end
  local ok, err = pcall(M._mark_impl, opts)
  if target and prev ~= target then
    pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(prev))
  end
  if not ok then
    local reason = tostring(err):match('E%d+[^\n]*') or tostring(err)
    vim.notify('Wokamark: mark failed (' .. reason .. ')', vim.log.levels.WARN)
  end
end

-- mark implementation (runs with cwd == target)
function M._mark_impl(opts)
  opts = opts or {}
  local cwd = vim.fn.getcwd()
  local git = git_info(cwd)

  local workspaces = read_index()
  local entry = {
    cwd = cwd,
    repo = git and git.repo or nil,
    branch = git and git.branch or nil,
    hash = git and git.hash or nil,
    alias = nil, -- user-facing alias; set via Manage r (display_name prefers it)
    path_slug = path_slug(cwd),
    path_hash = path_hash(cwd),
    last_used = os.date('%Y-%m-%dT%H:%M:%S'),
  }
  entry.session = session_name(entry)

  -- 1) session file first. If mksession fails (name too long, unwritable
  -- dir, ...) the whole mark aborts: no index entry is written and no old
  -- session file is deleted, so the index never points at a missing file.
  vim.fn.mkdir(sessions_dir, 'p')
  local sess_path = session_path(entry.session)
  local ok, err = pcall(vim.cmd, 'mksession! ' .. vim.fn.fnameescape(sess_path))
  if not ok or vim.fn.filereadable(sess_path) == 0 then
    local errmsg = err and tostring(err) or 'mksession failed'
    local reason = errmsg:match('E%d+[^\n]*') or errmsg
    vim.notify('Wokamark: mark failed, session not saved (' .. reason .. ')', vim.log.levels.WARN)
    return
  end

  -- 2) smart overwrite: same cwd + same branch -> replace, keep old session
  -- file removed; different branch -> new entry (keeps multiple).
  -- Old session files are only removed after the new one is safely on disk.
  local replaced = false
  for _, w in ipairs(workspaces) do
    if w.cwd == cwd and w.branch == entry.branch then
      if w.session and w.session ~= entry.session then
        delete_session(w.session)
      end
      w.repo = entry.repo
      w.branch = entry.branch
      w.hash = entry.hash
      w.path_slug = entry.path_slug
      w.path_hash = entry.path_hash
      w.session = entry.session
      w.last_used = entry.last_used
      replaced = true
      break
    end
  end
  if not replaced then
    table.insert(workspaces, entry)
  end
  -- index 写失败（只读/磁盘满）：WARN 已由 write_index 发出，中止并保留旧状态
  if not write_index(workspaces) then return end

  if not opts.silent then
    vim.notify('Wokamark: ' .. display_name(entry), vim.log.levels.INFO)
  end
end

-- ── public: load ────────────────────────────────────────────────────

-- Open nvim-tree after a load, when the plugin is available and no tree
-- window is open yet (best-effort, never errors).
local function open_tree_if_available()
  if vim.fn.exists(':NvimTreeOpen') ~= 2 then return end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'NvimTree' then return end
  end
  pcall(vim.cmd, 'NvimTreeOpen')
  pcall(vim.cmd, 'wincmd p') -- keep focus on the edit window
end

local function load_entry(entry)
  local p = session_path(entry.session)
  if vim.fn.filereadable(p) == 0 then
    vim.notify('Wokamark: session file missing: ' .. p, vim.log.levels.WARN)
    return
  end
  -- The marked cwd may be gone (deleted/renamed dir, lost permission):
  -- fail the load with a WARN instead of letting :cd abort the command.
  local ok, err = pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(entry.cwd))
  if not ok then
    -- keep the user-facing part of the error (E344/E472...), drop internal frames
    local reason = tostring(err):match('E%d+[^\n]*') or tostring(err)
    vim.notify('Wokamark: cannot cd to ' .. entry.cwd .. ': ' .. reason, vim.log.levels.WARN)
    return
  end
  pcall(vim.cmd, 'source ' .. vim.fn.fnameescape(p))
  open_tree_if_available()
  vim.notify('Wokamark: loaded ' .. display_name(entry), vim.log.levels.INFO)
end

-- ── pickers (WokaMarkOpen / WokaMarkManage) ─────────────────────────

-- decorate entries with the text field the snacks matcher filters on;
-- decoration never reaches index.json (write_index persists a clean copy)
local function decorate_items(workspaces)
  return vim.tbl_map(function(w)
    w.text = display_name(w) .. (w.repo and (' (' .. (w.branch or '') .. ')') or '')
    return w
  end, workspaces)
end

-- snacks format must return a Highlight[] (array of {text, hl?}),
-- a bare string crashes the picker renderer.
local function picker_format(item)
  local git_part = item.repo and (' (' .. (item.branch or '') .. ')') or ''
  return { { display_name(item) .. git_part } }
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
  local workspaces = read_index()
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
      load_entry(item)
    end,
  })
end

-- ── public: manage (d/r/a/i) ────────────────────────────────────────

-- delete one workspace entry (session file first, then index)
function M._delete(entry)
  delete_session(entry.session)
  local workspaces = read_index()
  local remaining = vim.tbl_filter(function(x)
    return not (x.session == entry.session)
  end, workspaces)
  if #remaining == #workspaces then
    vim.notify('Wokamark: workspace not found', vim.log.levels.WARN)
    return
  end
  write_index(remaining)
  vim.notify('Wokamark: deleted ' .. display_name(entry), vim.log.levels.INFO)
end

-- rename a workspace (sets the user-facing alias; session file untouched)
function M._rename(entry, new_name)
  local workspaces = read_index()
  for _, w in ipairs(workspaces) do
    if w.session == entry.session then
      w.alias = new_name
      if write_index(workspaces) then
        vim.notify('Wokamark: renamed to "' .. new_name .. '"', vim.log.levels.INFO)
      end
      return
    end
  end
  vim.notify('Wokamark: workspace not found', vim.log.levels.WARN)
end

-- :WokaMarkManage — lazygit-style management buffer (list + d/r/a/i/q).
-- A dedicated normal-mode UI instead of the snacks picker (whose default
-- insert-mode filter swallowed d/r/a/i and Esc closed the picker).
function M.manage_picker()
  local manage = {}
  local buf = vim.api.nvim_create_buf(false, true) -- scratch, unlisted
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'wokamark'
  vim.bo[buf].modifiable = true

  local function current_entry()
    local workspaces = read_index()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    return workspaces[line]
  end

  local function redraw(keep_cursor)
    vim.bo[buf].modifiable = true -- redraw must re-enable before set_lines
    local workspaces = read_index()
    local lines = {}
    for i, w in ipairs(workspaces) do
      local git = w.repo and (' (' .. (w.branch or '') .. ' [' .. (w.hash or '') .. '])') or ''
      lines[#lines + 1] = string.format('%2d  %s%s', i, display_name(w), git)
    end
    if #lines == 0 then
      lines = { '  (no workspaces yet — :WokaMarkCurrent to mark this path)' }
    end
    -- bottom hint bar (lazygit style)
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  d 删除  r 重命名  a 添加  i 详情  <CR> 恢复  q 退出'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    local maxline = math.max(1, math.min(#workspaces, #lines))
    local row = keep_cursor and math.min(vim.api.nvim_win_get_cursor(0)[1], maxline) or 1
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    -- highlight the entry lines (odd lines) with cursorline
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
      M._delete(e)
      redraw(true)
    end,
    r = function()
      local e = current_entry()
      if not e then return end
      local new_name = vim.fn.input('Wokamark rename: ', display_name(e))
      if new_name ~= '' then M._rename(e, new_name) end
      redraw(true)
    end,
    a = function()
      M.mark({})
      redraw(true)
    end,
    i = function()
      local e = current_entry()
      if not e then return end
      local details = {
        '名称:     ' .. display_name(e),
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
      load_entry(e)
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

-- ── public: help (centered floating window) ─────────────────────────

-- Language follows the system locale (LC_ALL > LC_MESSAGES > LANG);
-- zh* -> 中文, anything else -> English.
local function help_lines()
  local lang = vim.env.LC_ALL or vim.env.LC_MESSAGES or vim.env.LANG or ''
  lang = lang:lower()
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
  local lines = help_lines()
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

-- ── public: auto restore (path hash) ────────────────────────────────

-- Resolve the opened path to the directory that should be hashed:
-- a directory arg hashes itself, a file arg hashes its parent dir.
local function path_dir(p)
  local abs = vim.fn.fnamemodify(vim.fn.expand(p), ':p')
  if vim.fn.isdirectory(abs) == 1 then return canon(abs) end
  return canon(vim.fn.fnamemodify(abs, ':h'))
end

-- On VimEnter, restore the workspace whose path hash matches the opened
-- path (walking up ancestors, so opening any file under a marked workspace
-- restores it). No file args -> the startup cwd is the opened path.
-- Legacy entries without path_hash fall back to hashing their stored cwd.
function M.auto_restore()
  local opened = vim.fn.argv(0)
  if opened == '' then opened = vim.fn.getcwd() end
  local index = read_index()
  if #index == 0 then return end
  local dir = path_dir(opened)
  while dir do
    local h = vim.fn.sha256(dir)
    for _, w in ipairs(index) do
      local wh = w.path_hash or (type(w.cwd) == 'string' and path_hash(w.cwd) or nil)
      if wh and wh == h then
        load_entry(w)
        return
      end
    end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then break end -- reached '/'
    dir = parent
  end
end

-- ── public: auto mark (debounced) ───────────────────────────────────

local last_mark = {} -- cwd -> unix timestamp of last auto-mark

-- Debounced mark; only fires for real file buffers.
-- bufnr is captured by the autocmd at event time, so the buftype/name
-- checks apply to the buffer that triggered the event — not to whichever
-- buffer is current when the scheduled callback runs (that was the race:
-- after a BufLeave/BufEnter the checks read the switched-to buffer).
function M.auto_mark(bufnr)
  if not M.config.auto_mark then return end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.bo[bufnr].buftype ~= '' then return end -- skip terminal/tree/etc
  if vim.api.nvim_buf_get_name(bufnr) == '' then return end -- no file name
  local cwd = vim.fn.getcwd()
  local now = os.time()
  if (last_mark[cwd] or 0) + M.config.debounce > now then return end
  last_mark[cwd] = now
  vim.schedule(function()
    pcall(M.mark, { silent = true })
  end)
end

-- ── public: git HEAD change detection (CursorHold) ──────────────────

local head_mtime = {} -- cwd -> HEAD mtime

-- Cheap check (no subprocess): when .git/HEAD mtime changes
-- (commit/checkout), trigger an auto-mark.
function M.check_git_head()
  if not M.config.auto_mark then return end
  local cwd = vim.fn.getcwd()
  local mt = vim.fn.getftime(cwd .. '/.git/HEAD')
  if mt == -1 then return end -- not a git repo top level
  local last = head_mtime[cwd]
  if last ~= nil and mt ~= last then
    M.auto_mark()
  end
  head_mtime[cwd] = mt
end

return M
