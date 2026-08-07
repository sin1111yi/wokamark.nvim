# wokamark.nvim

Per-directory workspace session restore for Neovim (successor of `workmark.nvim`).

## Commands

- `:WokaMarkCurrent` — mark the current path (manual mark)
- `:WokaMarkOpen` — picker over all marked workspaces; select to restore
- `:WokaMarkManage` — manage picker with shortcuts:
  - `d` delete the selected workspace
  - `r` rename the selected workspace
  - `a` add (mark) the current path
  - `i` show full details (path / branch / commit / time / …)
- `:WokaMarkHelp` — floating help (locale-aware: `zh*` → 中文)

## Behavior

- **Auto-restore**: on `VimEnter`, the hash of the opened path (file args →
  parent dir; no args → startup cwd) is matched against marked workspaces'
  path hashes, walking up ancestors. Hit → restore that workspace's session.
- **Auto-mark**: on `BufReadPost` / `InsertLeave` / `BufWritePost` / git HEAD
  change, debounced (30 s per cwd). Disable with `setup { auto_mark = false }`.

## Setup

```lua
require('wokamark').setup({ auto_mark = true })
```

## Storage

`stdpath('state')/wokamark/index.json` + `sessions/<name>.vim`.

Requires [snacks.nvim](https://github.com/folke/snacks.nvim) for pickers.
