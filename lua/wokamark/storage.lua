-- wokamark.storage — index/session file persistence + path/session naming
-- Pure data layer: no UI, no git. Everything here either reads/writes the
-- index.json + session files, or derives names/hashes from paths.

local M = {}

local state_dir = vim.fn.stdpath('state') .. '/wokamark'
local index_file = state_dir .. '/index.json'
local sessions_dir = state_dir .. '/sessions'

-- fields persisted to index.json (pickers decorate entries with text/score/
-- match_tick/idx — never write those back)
local INDEX_FIELDS = { 'cwd', 'repo', 'branch', 'hash', 'path_slug', 'path_hash', 'session', 'last_used', 'name', 'alias' }

-- ext4 NAME_MAX is 255 bytes; a pathological cwd (e.g. 120 dashes, which
-- double to 240) can blow past it and make mksession fail. Names longer
-- than MAX_NAME_BYTES are degraded to a readable UTF-8-safe prefix + an
-- 8-hex sha256 suffix (readable AND usable). Same input -> same name.
local MAX_NAME_BYTES = 240

-- Canonical absolute path used for hashing: absolute, dot-segments
-- collapsed, trailing slashes stripped ('/' stays '/'). Both sides of a
-- match (mark-time cwd, restore-time opened path) go through the same
-- function so equal directories always produce equal hashes.
function M.canon(p)
  local abs = vim.fn.fnamemodify(vim.fn.expand(p), ':p')
  abs = abs:gsub('/+$', '')
  if abs == '' then abs = '/' end
  return abs
end

-- cwd -> path slug (readable fallback name when no git repo)
function M.path_slug(cwd)
  local s = cwd:gsub('^/', ''):gsub('/', '-')
  return s ~= '' and s or 'root'
end

-- path hash: sha256 of the canonical directory path (auto-restore key)
function M.path_hash(cwd)
  return vim.fn.sha256(M.canon(cwd))
end

function M.read_index()
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

function M.write_index(workspaces)
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
-- can only come from '/', so the mapping stays reversible and collision-free.
-- Empty result (e.g. cwd == '/') falls back to 'root', same as path_slug.
function M.escape_segment(s)
  s = s:gsub('^/+', '')
  s = s:gsub('-', '--')
  s = s:gsub('[/\\]', '-')
  if s == '' then return 'root' end
  return s
end

-- Truncate a UTF-8 string to at most maxbytes bytes without splitting a
-- multi-byte character (byte counts matter: ext4 NAME_MAX is 255 bytes).
function M.truncate_utf8(s, maxbytes)
  if #s <= maxbytes then return s end
  local cut = maxbytes
  while cut > 0 do
    local b = s:byte(cut)
    if b and b >= 0x80 and b < 0xC0 then -- continuation byte: inside multi-byte char
      cut = cut - 1
    else
      break
    end
  end
  return s:sub(1, cut)
end

-- display name shown in lists (alias > repo > cwd)
function M.display_name(w)
  return w.alias or w.name or w.repo or w.cwd
end

-- session file name:
--   with git:    <repo>-<branch>-<hash>-<cwd-escaped>.vim
--   without git: <cwd-escaped>.vim
-- The escaped cwd fingerprint makes same-named repos in different parent
-- dirs map to distinct files. The cwd is escaped from the stored cwd, so
-- legacy index entries pick up the new scheme on their next mark too.
function M.session_name(w)
  local cwd = M.escape_segment(w.cwd or '')
  local name
  if w.repo then
    local branch = M.escape_segment(w.branch or 'HEAD')
    name = ('%s-%s-%s-%s'):format(w.repo, branch, w.hash or 'unknown', cwd)
  else
    name = cwd
  end
  if #name > MAX_NAME_BYTES then
    local digest = vim.fn.sha256(name):sub(1, 8)
    name = M.truncate_utf8(name, MAX_NAME_BYTES - 9) .. '-' .. digest
  end
  return name .. '.vim'
end

function M.session_path(name)
  return sessions_dir .. '/' .. name
end

-- delete old session file (when overwriting an existing workspace entry)
function M.delete_session(name)
  local p = M.session_path(name)
  if name and vim.fn.filereadable(p) == 1 then
    vim.fn.delete(p)
  end
end

-- delete one workspace entry (session file first, then index)
function M.delete_entry(entry)
  M.delete_session(entry.session)
  local workspaces = M.read_index()
  local remaining = vim.tbl_filter(function(x)
    return not (x.session == entry.session)
  end, workspaces)
  if #remaining == #workspaces then
    vim.notify('Wokamark: workspace not found', vim.log.levels.WARN)
    return
  end
  M.write_index(remaining)
  vim.notify('Wokamark: deleted ' .. M.display_name(entry), vim.log.levels.INFO)
end

-- rename a workspace (sets the user-facing alias; session file untouched)
function M.rename_entry(entry, new_name)
  local workspaces = M.read_index()
  for _, w in ipairs(workspaces) do
    if w.session == entry.session then
      w.alias = new_name
      if M.write_index(workspaces) then
        vim.notify('Wokamark: renamed to "' .. new_name .. '"', vim.log.levels.INFO)
      end
      return
    end
  end
  vim.notify('Wokamark: workspace not found', vim.log.levels.WARN)
end

function M.sessions_dir()
  return sessions_dir
end

function M.index_file()
  return index_file
end

return M
