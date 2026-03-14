local M = {}

local defaults = {
  api_url = nil, -- auto-selected based on credentials
  language = "auto",
  preferred_variants = nil,
  mother_tongue = nil,
  debounce_ms = 1000,
  picky = false,
  disabled_rules = {},
  disabled_categories = {},
  skip_frontmatter = true,
  enabled_rules = {},
  enabled_categories = {},
  enabled_filetypes = {
    "text", "markdown", "gitcommit",
    "lua", "python", "rust",
    "javascript", "javascriptreact",
    "typescript", "typescriptreact",
    "go", "java", "c", "cpp", "cs",
    "php", "bash", "sh", "html",
  },
  user_queries = {},
}

--- Read an environment variable, returning nil instead of vim.NIL when absent.
---@param name string
---@return string|nil
local function env(name)
  local v = vim.fn.getenv(name)
  if v == vim.NIL then
    return nil
  end
  return v
end

--- Merge user opts over defaults, resolve credentials, validate.
---@param opts table|nil
---@return table config
function M.resolve(opts)
  local config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Credential resolution: explicit opts > environment variables
  config.api_key = config.api_key or env("LT_API_KEY")
  config.username = config.username or env("LT_USERNAME")

  -- Validation: both must be set, or neither
  local has_key = config.api_key ~= nil
  local has_user = config.username ~= nil
  if has_key ~= has_user then
    vim.notify(
      "lt-nvim: both api_key and username must be set for Premium; falling back to free tier",
      vim.log.levels.WARN
    )
    config.api_key = nil
    config.username = nil
  end

  -- Auto-select API URL if not explicitly set
  if not config.api_url then
    if config.api_key then
      config.api_url = "https://api.languagetoolplus.com/v2/check"
    else
      config.api_url = "https://api.languagetool.org/v2/check"
    end
  end

  return config
end

--- Returns the default config (for use before setup() is called).
---@return table
function M.defaults()
  return vim.deepcopy(defaults)
end

return M
