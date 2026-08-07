-- wokamark.git — git repository information (pure helper, no deps)

local M = {}

-- run git in a given cwd, return trimmed stdout or nil
function M.git_cmd(args, cwd)
  local obj = vim.system({ 'git', unpack(args) }, { cwd = cwd, text = true })
  local res = obj:wait()
  if res.code ~= 0 then return nil end
  local out = vim.trim(res.stdout)
  return out ~= '' and out or nil
end

-- git info for a cwd, or nil when not in a repo
function M.git_info(cwd)
  local root = M.git_cmd({ 'rev-parse', '--show-toplevel' }, cwd)
  if not root then return nil end
  return {
    root = root,
    repo = vim.fn.fnamemodify(root, ':t'),
    branch = M.git_cmd({ 'rev-parse', '--abbrev-ref', 'HEAD' }, cwd) or 'HEAD',
    hash = M.git_cmd({ 'rev-parse', '--short', 'HEAD' }, cwd) or 'unknown',
  }
end

return M
