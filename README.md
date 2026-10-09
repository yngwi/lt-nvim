# lt-nvim

LanguageTool grammar/spell checking for Neovim. Runs as an in-memory LSP server, uses treesitter to extract prose from code (comments, strings, docstrings), and reports results as native diagnostics with code actions.

Supports the free public API, LanguageTool Premium, and self-hosted servers.

## Features

- Diagnostics via the standard LSP pipeline
- Code actions: accept suggestion, add to dictionary, disable rule, hide false positive
- Extracts prose from code files via treesitter (comments, docstrings, template strings)
- Doc comment `@tag` handling (strips tag prefixes, checks only descriptions)
- Markdown support with YAML and TOML frontmatter skipping and comment checking inside fenced code blocks
- Org-mode support with heading/drawer/directive handling and source block comment extraction
- LaTeX, reStructuredText, and Typst support via treesitter
- Uses the [AnnotatedText](https://languagetool.org/http-api/) API to preserve document structure
- Per-buffer caching
- Statusline component
- `:checkhealth` integration

## Requirements

- Neovim >= 0.11
- `curl` on PATH
- Treesitter parsers for your languages (`:TSInstall lua python typescript ...`)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "yngwi/lt-nvim",
  config = function()
    require("lt-nvim").setup()
  end,
}
```

For local development:

```lua
{
  dir = "~/projects/lt-nvim",
  config = function()
    require("lt-nvim").setup()
  end,
}
```

The plugin works with any plugin manager. If you don't use lazy.nvim, just ensure `require("lt-nvim").setup()` is called before buffers are opened.

## Configuration

### Credentials

Set environment variables for LanguageTool Premium:

```sh
export LT_API_KEY="your-key"
export LT_USERNAME="your@email.com"
```

Or pass them directly:

```lua
require("lt-nvim").setup({
  api_key = "your-key",
  username = "your@email.com",
})
```

Credentials are optional. Without them, the plugin uses the free API tier (lower rate limits, no `level=picky`). The API endpoint is auto-selected based on whether credentials are present.

### Self-hosted server

To use a self-hosted LanguageTool server, set `api_url` to your server's check endpoint:

```lua
require("lt-nvim").setup({
  api_url = "http://localhost:8081/v2/check",
})
```

The plugin selects the self-hosted tier when the URL doesn't match the known LanguageTool cloud endpoints. No credentials are needed.

Self-hosted behavior:

- Dictionary words are stored locally (the server-side words API is not used)
- Picky mode is supported (set `picky = true`)
- All other features work identically to the cloud API

### Options

All options with their defaults:

```lua
require("lt-nvim").setup({
  -- API endpoint (auto-selected if nil: languagetoolplus.com for Premium,
  -- languagetool.org for free)
  api_url = nil,

  -- Start with automatic checking on (false: off until :Lt enable or :Lt toggle)
  start_enabled = true,

  -- Language to check against ("auto" for automatic detection)
  language = "auto",

  -- Preferred language variants when language="auto" (e.g. "en-US,de-DE")
  preferred_variants = nil,

  -- Your native language for false-friends checks (e.g. "de")
  mother_tongue = nil,

  -- Milliseconds to wait after last edit before checking
  debounce_ms = 1000,

  -- Enable picky mode (Premium and self-hosted only, activates additional rules)
  picky = false,

  -- Skip YAML (---) or TOML (+++) frontmatter in markdown files (false: check its values)
  skip_frontmatter = true,

  -- Rule IDs to disable (e.g. {"WHITESPACE_RULE", "EN_QUOTES"})
  disabled_rules = {},

  -- Category IDs to disable (e.g. {"TYPOGRAPHY"})
  disabled_categories = {},

  -- Rule IDs to explicitly enable (e.g. {"EN_QUOTES"})
  enabled_rules = {},

  -- Category IDs to explicitly enable
  enabled_categories = {},

  -- Filetypes to attach to
  enabled_filetypes = {
    "text", "markdown", "gitcommit",
    "lua", "python", "rust",
    "javascript", "javascriptreact",
    "typescript", "typescriptreact",
    "go", "java", "c", "cpp", "cs",
    "php", "bash", "sh", "html",
    "tex", "plaintex", "rst", "typst",
    "mail", "org",
  },

  -- Additional treesitter queries per language
  user_queries = {},
})
```

## Usage

### Diagnostics

lt-nvim appears as an LSP server. Diagnostics show automatically for supported filetypes. Use your usual diagnostic navigation keymaps (`[d`, `]d`, etc.).

Severity mapping:

- Error: spelling (TYPOS category)
- Warning: grammar (GRAMMAR category)
- Hint: style, punctuation, and other rules

### Code actions

Trigger code actions with your usual keymap (e.g. `<leader>ca` or `vim.lsp.buf.code_action()`). Available actions:

| Action | Description |
| --- | --- |
| `'word' → 'fix'` | Replace with LanguageTool's suggestion |
| `Add 'word' to server/local dictionary` | Premium: server-side dictionary. Free/self-hosted: local file |
| `Disable rule 'RULE_ID'` | Suppress this rule for all future checks |
| `Hide false positive` | Suppress this specific rule+sentence combination |

### Commands

All commands are under `:Lt` with tab completion:

| Command           | Description                                          |
| ----------------- | ---------------------------------------------------- |
| `:Lt recheck`     | Clear cache and re-check current buffer              |
| `:Lt toggle`      | Toggle automatic checking in all buffers             |
| `:Lt enable`      | Enable automatic checking in all buffers             |
| `:Lt disable`     | Disable checking and clear diagnostics everywhere    |
| `:Lt lang <code>` | Set language for current buffer (e.g. `de`, `en-US`) |
| `:Lt lang auto`   | Reset to automatic language detection                |
| `:Lt info`        | Show status (language, tier, checking state)         |

While checking is disabled, `:Lt recheck` does nothing and `:Lt lang` takes effect on the next check.

When LanguageTool is unreachable, lt-nvim keeps the last diagnostics and pauses automatic checks for 60 seconds. `:Lt recheck` retries at once.

### Statusline

Add to lualine:

```lua
lualine_x = { require("lt-nvim").statusline }
```

Shows:

- `LT` -- attached, no issues
- `LT: 3` -- 3 diagnostics
- `LT …` -- check in progress
- `LT off` -- checking disabled
- `LT ⚠` -- automatic checks paused after a connection failure
- (empty) -- not attached

### Health check

```vim
:checkhealth lt-nvim
```

Reports on: Neovim version, curl, credentials, LSP server status, treesitter parsers, and API info.

## How it works

### Architecture

lt-nvim runs as an in-memory LSP server via `vim.lsp.config()` and `vim.lsp.enable()`. No external process is spawned.

```text
Neovim LSP client
     |
     v
server.lua (in-memory LSP server)
  |-- didOpen / didChange / didSave
  |     |
  |     v
  |   checker.lua
  |     |-- annotator.lua (treesitter -> AnnotatedText)
  |     |-- cache (skip if annotated content unchanged)
  |     '-- api.lua (curl -> LT API)
  |           |
  |           v
  |   publishDiagnostics
  |
  '-- textDocument/codeAction
        '-- reads stored matches, returns actions
```

### AnnotatedText

lt-nvim builds [AnnotatedText](https://languagetool.org/http-api/) -- a JSON structure that marks code as `markup` and prose as `text`. LanguageTool checks only the text portions while preserving offset information.

### Treesitter queries

Each supported language has a query file in `lua/lt-nvim/queries/` that identifies comment nodes (and docstrings/template strings where appropriate). The annotator uses these to determine what is prose (text) vs. code (markup).

To add support for a new language, add a query file:

```lua
-- lua/lt-nvim/queries/go.lua
return {
  "(comment) @lt_comment",
  "(interpreted_string_literal) @lt_string",
}
```

And add the filetype to `enabled_filetypes` in your setup call.

You can also extend existing languages via `user_queries`:

```lua
require("lt-nvim").setup({
  user_queries = {
    go = { "(comment) @lt_comment" },
  },
})
```

### Doc comment handling

For doc comments (`///`, `/**`, `---`, etc.), lt-nvim strips `@tag` prefixes (like `@param name`) as markup so only the prose description is checked. This works for JSDoc, PHPDoc, Luadoc, Doxygen, and Rust doc comment styles. Types (`{string}` in JSDoc, `string` in PHPDoc) and Doxygen directions (`@param[in]`) are markup too.

In Lua, `---@param`, `---@field` and `---@return` annotations also hide the name and type, so only the description is checked; a `#` before the description is hidden too. Other `---@` annotations are markup entirely.

Tag descriptions and comments after code on the same line are lowercase fragments by convention, so `UPPERCASE_SENTENCE_START` matches at their start are not reported.

## Data storage

Global data, shared across all projects:

```text
~/.local/share/nvim/lt-nvim/dictionary.txt    (Linux)
~/AppData/Local/nvim-data/lt-nvim/dictionary.txt  (Windows)
```

- `dictionary.txt` -- word dictionary (free and self-hosted tiers; Premium uses the server-side dictionary)

Project-local data, per project root (found via `.git`, `.hg`, `.svn`, or cwd):

```text
<project-root>/.lt-nvim.json
```

Contains disabled rules, hidden false positives, and an optional language override. Example:

```json
{
  "language": "en-US",
  "disabled_rules": ["WHITESPACE_RULE", "EN_QUOTES"],
  "false_positives": [{ "rule_id": "MORFOLOGIK_RULE_EN_US", "sentence": "..." }]
}
```

This file is safe to commit to version control if your team shares rule preferences.

## Rate limits

|                | Free   | Premium |
| -------------- | ------ | ------- |
| Requests/min   | 20     | 80      |
| Characters/min | 75,000 | 300,000 |

## License

MIT
