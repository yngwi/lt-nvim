local M = {}

function M.check()
  local health = vim.health

  health.start("lt-nvim")

  -- 1. Neovim version
  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim >= 0.11")
  else
    health.error("Neovim >= 0.11 required (vim.lsp.config / vim.lsp.enable)")
  end

  -- 2. curl
  if vim.fn.executable("curl") == 1 then
    health.ok("curl found on PATH")
  else
    health.error("curl not found on PATH — required for API communication")
  end

  -- 3. Credentials
  local config = require("lt-nvim").get_config()

  if config.api_key then
    local source = vim.fn.getenv("LT_API_KEY") ~= vim.NIL and "env" or "config"
    health.ok("LT_API_KEY set (from " .. source .. ")")
  else
    health.info("LT_API_KEY not set — using free tier")
  end

  if config.username then
    local source = vim.fn.getenv("LT_USERNAME") ~= vim.NIL and "env" or "config"
    health.ok("LT_USERNAME set (from " .. source .. ")")
  else
    health.info("LT_USERNAME not set — using free tier")
  end

  -- 4. LSP server status
  local clients = vim.lsp.get_clients({ name = "lt-nvim" })
  if #clients > 0 then
    health.ok("LSP server running (" .. #clients .. " client(s))")
  else
    health.info("LSP server not currently attached to any buffer")
  end

  -- 5. Language parsers
  health.start("lt-nvim: treesitter parsers")
  local skip_parser = { text = true, markdown = true }
  for _, ft in ipairs(config.enabled_filetypes) do
    if not skip_parser[ft] then
      local ok = pcall(vim.treesitter.language.inspect, ft)
      if ok then
        health.ok(ft .. " — parser installed")
      else
        health.warn(ft .. " — parser not installed (comments/strings won't be extracted)")
      end
    end
  end

  -- 6. API info
  health.start("lt-nvim: API")
  health.info("Endpoint: " .. config.api_url)
  health.info("Tier: " .. (config.api_key and "Premium" or "Free"))
end

return M
