# wokamark.nvim

**Per-directory workspace session restore for Neovim**

Successor of `workmark.nvim`.

When Neovim opens, the workspace (directory) whose path hash matches the
opened path is auto-restored — window layout, buffers and cursor positions
all come back. Marking, restoring and managing are done through commands; no
manual session-file loading.

---

## Features

- **Auto-restore** — opened path is hashed and matched against marked
  workspaces (walking up ancestor directories); hit → session restored
- **Auto-mark** — editing, saving and git branch changes auto-record the
  workspace (debounced; can be disabled)
- **Alias** — each workspace can carry a display alias (does not touch the
  auto-generated session filename)
- **Manage UI** — lazygit-style management window with `d/r/a/i` shortcuts
- **Trigger-help integration** — command cheatsheet auto-registers with
  trigger-help.nvim

---

## Commands

| Command | Description |
|---------|-------------|
| `:WokaMarkCurrent` | Mark the current path |
| `:WokaMarkOpen` | Picker over marked workspaces; select to restore |
| `:WokaMarkManage` | Manage UI (list + shortcuts) |
| `:WokaMarkHelp` | Floating help (locale-aware) |

### Manage shortcuts

| Key | Action |
|-----|--------|
| `d` | Delete the selected workspace |
| `r` | Rename (set alias) |
| `a` | Add (mark current path) |
| `i` | Show full details (path/branch/time) |
| `<CR>` | Restore selected workspace |
| `q` / `<Esc>` | Close the manage window |

---

## Behavior

### Auto-restore

On startup, the hash of the opened path is matched against marked
workspaces' path hashes, walking up ancestor directories (a file arg hashes
its parent dir; no args → the startup cwd is hashed). Hit → restore.

```
nvim ~/projects/wokamark.nvim   → matches a marked workspace → restored
nvim                            → startup cwd matched → restored (if marked)
```

### Auto-mark

On `BufReadPost` / `InsertLeave` / `BufWritePost` / git HEAD change,
debounced (30 s per directory). Enabled by default:

```lua
require('wokamark').setup({ auto_mark = false })  -- disable
```

### Alias

Every workspace can carry a user-facing alias. It only affects display — the
session filename stays auto-generated (`<repo>-<branch>-<hash>-<cwd>.vim`):

```
:WokaMarkManage → r → type alias → list shows it immediately
```

Display priority: `alias > repo > cwd`.

---

## Installation

### lazy.nvim (recommended)

```lua
-- plugin spec
{
  'sin1111yi/wokamark.nvim',
  lazy = false, -- eager: needs VimEnter hooks for auto-restore
  config = function()
    require('wokamark').setup({ auto_mark = true })
  end,
}
```

Then `:Lazy sync` inside Neovim.

#### Dev mode (local source)

While developing, load from a local checkout instead of GitHub:

```lua
require('lazy').setup({
  dev = {
    path = '~/Development',                  -- local dev directory
    patterns = { 'github.com/sin1111yi/' },   -- repos matching this URL pattern
    fallback = true,                          -- fall back to GitHub when missing
  },
  -- ...
})
```

`:Lazy dev` lists dev plugins; `:Lazy dev <plugin>` toggles dev mode.
When `~/Development/wokamark.nvim` exists it is used; other machines without
it fall back to the GitHub install.

### vim.pack (legacy)

```lua
-- plugins.lua
local local_plugins = vim.env.NVIM_LOCAL_PLUGINS or vim.fn.expand('~/projects')
vim.pack.add({
  local_plugins .. '/wokamark.nvim',
  -- ...
})
-- nvim --headless -c 'lua vim.pack.update()' -c 'qa!'
```

```lua
vim.cmd('packadd wokamark.nvim')
require('wokamark').setup({ auto_mark = true })
```

---

## Trigger-help integration

On setup, wokamark registers its command cheatsheet with trigger-help.nvim
via `require('trigger_help').register_doc({ id = 'wokamark', ... })` when
that plugin is available — best-effort: trigger-help missing → skipped
silently.

```
:TriggerHelp wokamark       open the wokamark cheatsheet directly
:TriggerHelp → [wokamark]   browse from the selector
```

---

## Storage

```
stdpath('state')/wokamark/index.json   — workspace index (path_hash / alias)
stdpath('state')/wokamark/sessions/    — mksession session files
```

- `path_hash` = SHA-256 of the path (auto-restore match key)
- the index persists only whitelisted fields (decorative fields are not
  written back)

---

## Dependencies

- [snacks.nvim](https://github.com/folke/snacks.nvim) — picker (`:WokaMarkOpen`)
- [trigger-help.nvim](https://github.com/sin1111yi/trigger-help.nvim) —
  optional (registers the cheatsheet)

---

## License

MIT
