# wokamark.nvim

**Per-directory workspace session restore for Neovim**
**Neovim 按目录工作区会话保存与恢复**

Successor of `workmark.nvim`（workmark.nvim 的继任者）。

打开 Neovim 时，根据打开路径自动恢复对应工作区（目录）的会话——窗口布局、buffer、光标位置全部还原。标记、恢复、管理全部通过命令完成，无需手动加载 session 文件。

---

## Features / 特性

- **Auto-restore / 自动恢复** — 打开路径哈希匹配已标记工作区，命中即恢复
- **Auto-mark / 自动标记** — 编辑/保存/切换 git 分支时自动记录（可关闭）
- **Alias / 别名** — 每个工作区可设置展示别名（不影响文件名）
- **Manage UI / 管理界面** — lazygit 风格管理窗口，`d/r/a/i` 快捷键
- **Trigger-help integration / 集成 trigger-help** — 命令速查自动注册进 trigger-help 文档浏览

---

## Commands / 命令

| 命令 | 说明 | Description |
|------|------|-------------|
| `:WokaMarkCurrent` | 标记当前路径 | Mark the current path |
| `:WokaMarkOpen` | 打开选择器，选择工作区恢复 | Picker over marked workspaces; select to restore |
| `:WokaMarkManage` | 管理界面（列表 + 快捷键） | Manage UI (list + shortcuts) |
| `:WokaMarkHelp` | 浮动帮助窗口 | Floating help (locale-aware) |

### Manage shortcuts / 管理快捷键

| 键 | 动作 | Action |
|----|------|--------|
| `d` | 删除当前工作区 | Delete the selected workspace |
| `r` | 重命名（设置别名） | Rename (set alias) |
| `a` | 添加（标记当前路径） | Add (mark current path) |
| `i` | 查看详情（路径/分支/时间等） | Show full details |
| `<CR>` | 恢复选中工作区 | Restore selected workspace |
| `q` / `<Esc>` | 关闭管理窗口 | Close the manage window |

---

## Behavior / 行为

### Auto-restore / 自动恢复

On startup, the hash of the opened path is matched against marked workspaces'
path hashes, walking up ancestor directories:

启动时计算打开路径的哈希（有文件参数 → 取父目录；无参数 → 取启动目录），
与已标记工作区的路径哈希匹配，沿祖先目录逐级查找。命中 → 自动恢复该工作区会话。

```
nvim ~/projects/wokamark.nvim   → 匹配到标记过的工作区 → 恢复
nvim                            → 启动目录匹配 → 恢复（若标记过）
```

### Auto-mark / 自动标记

On `BufReadPost` / `InsertLeave` / `BufWritePost` / git HEAD change,
debounced (30 s per directory):

编辑文件、离开插入模式、保存、git 分支切换时自动标记当前目录
（每目录 30 秒防抖合并）。默认开启：

```lua
require('wokamark').setup({ auto_mark = false })  -- 关闭自动标记
```

### Alias / 别名

Every workspace can carry a user-facing alias. It only affects display —
the session file name stays auto-generated (`<repo>-<branch>-<hash>-<cwd>.vim`):

每个工作区可有展示别名——只影响显示，**不改动自动生成的 session 文件名**。

```
:WokaMarkManage → r → 输入别名 → 列表立即显示别名
```

Display priority: `alias > repo > cwd`（显示优先级：别名 > 仓库名 > 路径）。

---

## Installation / 安装

Source repo: `~/projects/wokamark.nvim` (git). Install via vim.pack local path
(`plugins.lua`):

源码仓库：`~/projects/wokamark.nvim`（git）。通过 vim.pack 本地路径安装：

```lua
-- plugins.lua
local local_plugins = vim.env.NVIM_LOCAL_PLUGINS or vim.fn.expand('~/projects')
vim.pack.add({
  local_plugins .. '/wokamark.nvim',
  -- ...
})
-- nvim --headless -c 'lua vim.pack.update()' -c 'qa!'
```

Then in your config (`loader.lua` or similar):

配置中加载：

```lua
vim.cmd('packadd wokamark.nvim')
require('wokamark').setup({ auto_mark = true })
```

---

## Trigger-help integration / 集成 trigger-help

On setup, wokamark registers its command cheatsheet with trigger-help.nvim via
`require('trigger_help').register_doc({ id = 'wokamark', ... })` when that
plugin is available — best-effort: trigger-help missing → skipped silently.

setup 时 wokamark 会向 trigger-help.nvim 注册命令速查文档
（`require('trigger_help').register_doc({ id = 'wokamark', ... })`）。
trigger-help 未安装则静默跳过。

```
:TriggerHelp wokamark       直接打开 wokamark 速查
:TriggerHelp → [wokamark]   从 selector 浏览
```

---

## Storage / 数据存储

```
stdpath('state')/wokamark/index.json   — 工作区索引（含 path_hash / alias）
stdpath('state')/wokamark/sessions/    — mksession 会话文件
```

- `path_hash` = 路径的 SHA-256（自动恢复匹配键）
- 索引只持久化白名单字段（装饰字段不写回）

---

## Dependencies / 依赖

- [snacks.nvim](https://github.com/folke/snacks.nvim) — picker（`:WokaMarkOpen`）
- [trigger-help.nvim](https://github.com/) — 可选（集成注册速查文档）

---

## License

MIT
