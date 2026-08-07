-- wokamark.session — mark / restore / auto-restore / auto-mark core logic
-- Depends on wokamark.storage (data) and wokamark.git (repo info).

local storage = require('wokamark.storage')
local git = require('wokamark.git')

local M = {}

-- config merged by init.setup; read here (never mutated)
local cfg = { auto_mark = true, debounce = 30 }
function M.set_config(c)
  cfg = c
end

-- ── mark ────────────────────────────────────────────────────────────

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
  local g = git.git_info(cwd)

  local workspaces = storage.read_index()
  local entry = {
    cwd = cwd,
    repo = g and g.repo or nil,
    branch = g and g.branch or nil,
    hash = g and g.hash or nil,
    alias = nil, -- user-facing alias; set via Manage r (display_name prefers it)
    path_slug = storage.path_slug(cwd),
    path_hash = storage.path_hash(cwd),
    last_used = os.date('%Y-%m-%dT%H:%M:%S'),
  }
  entry.session = storage.session_name(entry)

  -- 1) session file first. If mksession fails (name too long, unwritable
  -- dir, ...) the whole mark aborts: no index entry is written and no old
  -- session file is deleted, so the index never points at a missing file.
  vim.fn.mkdir(storage.sessions_dir(), 'p')
  local sess_path = storage.session_path(entry.session)
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
        storage.delete_session(w.session)
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
  if not storage.write_index(workspaces) then return end

  if not opts.silent then
    vim.notify('Wokamark: ' .. storage.display_name(entry), vim.log.levels.INFO)
  end
end

-- ── load ────────────────────────────────────────────────────────────

-- ── tree ownership ─────────────────────────────────────────────────
-- wokamark owns the startup layout: nvim-tree asks us whether to open.
-- Args given (file/dir) -> open the tree (matches get a session restored
-- first; if that session had no tree, the tree is added on the left).
-- Bare `nvim` -> no tree (a restored session brings its own layout).
function M.should_open_tree()
  return vim.fn.argc() > 0
end

-- Open nvim-tree when it is available and no tree window is open yet
-- (best-effort, never errors). Used after a wokamark load (WokaMarkOpen /
-- auto-restore) to (re)add the tree once nvim-tree itself is loaded.
function M.open_tree_if_available()
  if vim.fn.exists(':NvimTreeOpen') ~= 2 then return end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'NvimTree' then return end
  end
  pcall(vim.cmd, 'NvimTreeOpen')
  pcall(vim.cmd, 'wincmd p') -- keep focus on the edit window
end

function M.load_entry(entry)
  local p = storage.session_path(entry.session)
  if vim.fn.filereadable(p) == 0 then
    vim.notify('Wokamark: session file missing: ' .. p, vim.log.levels.WARN)
    return
  end
  -- The marked cwd may be gone (deleted/renamed dir, lost permission):
  -- fail the load with a WARN instead of letting :cd abort the command.
  local ok, err = pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(entry.cwd))
  if not ok then
    local reason = tostring(err):match('E%d+[^\n]*') or tostring(err)
    vim.notify('Wokamark: cannot cd to ' .. entry.cwd .. ': ' .. reason, vim.log.levels.WARN)
    return
  end
  pcall(vim.cmd, 'source ' .. vim.fn.fnameescape(p))
  open_tree_if_available()
  vim.notify('Wokamark: loaded ' .. storage.display_name(entry), vim.log.levels.INFO)
end

-- ── auto restore (path hash) ────────────────────────────────────────

-- Resolve the opened path to the directory that should be hashed:
-- a directory arg hashes itself, a file arg hashes its parent dir.
local function path_dir(p)
  local abs = vim.fn.fnamemodify(vim.fn.expand(p), ':p')
  if vim.fn.isdirectory(abs) == 1 then return storage.canon(abs) end
  return storage.canon(vim.fn.fnamemodify(abs, ':h'))
end

-- On VimEnter, restore the workspace whose path hash matches the opened
-- path (walking up ancestors, so opening any file under a marked workspace
-- restores it). No file args -> the startup cwd is the opened path.
-- Legacy entries without path_hash fall back to hashing their stored cwd.
function M.auto_restore()
  local opened = vim.fn.argv(0)
  if opened == '' then opened = vim.fn.getcwd() end
  local index = storage.read_index()
  if #index == 0 then return end
  local dir = path_dir(opened)
  while dir do
    local h = vim.fn.sha256(dir)
    for _, w in ipairs(index) do
      local wh = w.path_hash or (type(w.cwd) == 'string' and storage.path_hash(w.cwd) or nil)
      if wh and wh == h then
        vim.g.wokamark_restored = true -- tell nvim-tree (VeryLazy) to skip its auto-open
        M.load_entry(w)
        return
      end
    end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then break end -- reached '/'
    dir = parent
  end
end

-- ── auto mark (debounced) ───────────────────────────────────────────

local last_mark = {} -- cwd -> unix timestamp of last auto-mark

-- Debounced mark; only fires for real file buffers.
-- bufnr is captured by the autocmd at event time, so the buftype/name
-- checks apply to the buffer that triggered the event — not to whichever
-- buffer is current when the scheduled callback runs.
function M.auto_mark(bufnr)
  if not cfg.auto_mark then return end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.bo[bufnr].buftype ~= '' then return end -- skip terminal/tree/etc
  if vim.api.nvim_buf_get_name(bufnr) == '' then return end -- no file name
  local cwd = vim.fn.getcwd()
  local now = os.time()
  if (last_mark[cwd] or 0) + cfg.debounce > now then return end
  last_mark[cwd] = now
  vim.schedule(function()
    pcall(M.mark, { silent = true })
  end)
end

-- ── git HEAD change detection (CursorHold) ──────────────────────────

local head_mtime = {} -- cwd -> HEAD mtime

-- Cheap check (no subprocess): when .git/HEAD mtime changes
-- (commit/checkout), trigger an auto-mark.
function M.check_git_head()
  if not cfg.auto_mark then return end
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
