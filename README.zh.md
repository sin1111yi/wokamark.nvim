# wokamark.nvim

**Neovim 按目录工作区会话保存与恢复**

`workmark.nvim` 的继任者。

打开 Neovim 时，根据打开路径自动恢复对应工作区（目录）的会话——窗口布局、buffer、光标位置全部还原。标记、恢复、管理全部通过命令完成，无需手动加载 session 文件。

---

## 特性

- **自动恢复** — 打开路径哈希匹配已标记工作区（沿祖先目录逐级查找），命中即恢复
- **自动标记** — 编辑/保存/切换 git 分支时自动记录（防抖；可关闭）
- **别名** — 每个工作区可设置展示别名（不影响自动生成的 session 文件名）
- **管理界面** — lazygit 风格管理窗口，`d/r/a/i` 快捷键
- **集成 trigger-help** — 命令速查自动注册进 trigger-help 文档浏览

---

## 命令

| 命令 | 说明 |
|------|------|
| `:WokaMarkCurrent` | 标记当前路径 |
| `:WokaMarkOpen` | 打开选择器，选择工作区恢复 |
| `:WokaMarkManage` | 管理界面（列表 + 快捷键） |
| `:WokaMarkHelp` | 浮动帮助窗口（按 locale 语言） |

### 管理快捷键

| 键 | 动作 |
|----|------|
| `d` | 删除当前工作区 |
| `r` | 重命名（设置别名） |
| `a` | 添加（标记当前路径） |
| `i` | 查看详情（路径/分支/时间等） |
| `<CR>` | 恢复选中工作区 |
| `q` / `<Esc>` | 关闭管理窗口 |

---

## 行为

### 自动恢复

启动时计算打开路径的哈希（有文件参数 → 取父目录；无参数 → 取启动目录），与已标记工作区的路径哈希匹配，沿祖先目录逐级查找。命中 → 自动恢复该工作区会话。

```
nvim ~/projects/wokamark.nvim   → 匹配到标记过的工作区 → 恢复
nvim                            → 启动目录匹配 → 恢复（若标记过）
```

### 自动标记

编辑文件、离开插入模式、保存、git 分支切换时自动标记当前目录（每目录 30 秒防抖合并）。默认开启：

```lua
require('wokamark').setup({ auto_mark = false })  -- 关闭自动标记
```

### 别名

每个工作区可有展示别名——只影响显示，**不改动自动生成的 session 文件名**（`<repo>-<branch>-<hash>-<cwd>.vim`）。

```
:WokaMarkManage → r → 输入别名 → 列表立即显示别名
```

显示优先级：`别名 > 仓库名 > 路径`。

---

## 安装

### lazy.nvim（推荐）

```lua
-- 插件 spec
{
  'sin1111yi/wokamark.nvim',
  lazy = false, -- eager：自动恢复需要 VimEnter 钩子
  config = function()
    require('wokamark').setup({ auto_mark = true })
  end,
}
```

然后在 nvim 内 `:Lazy sync`。

#### Dev 模式（本地源码）

开发时从本地目录加载（而不是 GitHub）：

```lua
require('lazy').setup({
  dev = {
    path = '~/Development',                  -- 本地开发目录
    patterns = { 'github.com/sin1111yi/' },   -- 匹配该 URL 模式的插件
    fallback = true,                          -- 本地不存在时回退 GitHub
  },
  -- ...
})
```

`:Lazy dev` 列出 dev 插件；`:Lazy dev <插件名>` 切换 dev 模式。
当 `~/Development/wokamark.nvim` 存在时用它；其他没有该目录的机器自动回退 GitHub 安装。

### vim.pack（旧方式）

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

## 集成 trigger-help

setup 时 wokamark 会向 trigger-help.nvim 注册命令速查文档（`require('trigger_help').register_doc({ id = 'wokamark', ... })`）。trigger-help 未安装则静默跳过。

```
:TriggerHelp wokamark       直接打开 wokamark 速查
:TriggerHelp → [wokamark]   从 selector 浏览
```

---

## 数据存储

```
stdpath('state')/wokamark/index.json   — 工作区索引（含 path_hash / alias）
stdpath('state')/wokamark/sessions/    — mksession 会话文件
```

- `path_hash` = 路径的 SHA-256（自动恢复匹配键）
- 索引只持久化白名单字段（装饰字段不写回）

---

## 依赖

- [snacks.nvim](https://github.com/folke/snacks.nvim) — picker（`:WokaMarkOpen`）
- [trigger-help.nvim](https://github.com/sin1111yi/trigger-help.nvim) — 可选（注册速查文档）

---

## License

MIT
