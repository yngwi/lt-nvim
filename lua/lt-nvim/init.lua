local config_mod = require("lt-nvim.config")
local api = require("lt-nvim.api")

local M = {}

local resolved_config = nil

--- Notify the lt-nvim LSP server attached to the current buffer.
---@return boolean success true if a server was found
local function notify_server(method, params)
  local clients = vim.lsp.get_clients({ name = "lt-nvim", bufnr = 0 })
  if clients[1] then
    clients[1]:notify(method, params)
    return true
  end
  return false
end

local subcommands = {
  recheck = {
    desc = "Clear cache and re-check current buffer",
    fn = function()
      notify_server("lt-nvim/forceCheck", { uri = vim.uri_from_bufnr(0) })
    end,
  },
  toggle = {
    desc = "Toggle checking for current buffer",
    fn = function()
      notify_server("lt-nvim/toggle", {
        uri = vim.uri_from_bufnr(0),
        bufnr = vim.api.nvim_get_current_buf(),
      })
    end,
  },
  enable = {
    desc = "Enable checking for current buffer",
    fn = function()
      notify_server("lt-nvim/enable", {
        uri = vim.uri_from_bufnr(0),
        bufnr = vim.api.nvim_get_current_buf(),
      })
    end,
  },
  disable = {
    desc = "Disable checking for current buffer",
    fn = function()
      notify_server("lt-nvim/disable", { uri = vim.uri_from_bufnr(0) })
    end,
  },
  info = {
    desc = "Show LanguageTool status for current buffer",
    fn = function()
      if not notify_server("lt-nvim/info", { uri = vim.uri_from_bufnr(0) }) then
        vim.notify("lt-nvim: server not attached to this buffer", vim.log.levels.INFO)
      end
    end,
  },
}

--- Returns true if setup() has been called.
---@return boolean
function M.is_setup()
  return resolved_config ~= nil
end

--- Set up the plugin. Must be called before the LSP server starts.
---@param opts table|nil
function M.setup(opts)
  resolved_config = config_mod.resolve(opts)

  if vim.fn.executable("curl") ~= 1 then
    vim.notify("lt-nvim: curl not found on PATH", vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_create_user_command("Lt", function(cmd)
    local args = vim.split(cmd.args, "%s+", { trimempty = true })
    local sub = args[1] or ""

    if sub == "" then
      local entries = {}
      for name, def in pairs(subcommands) do
        table.insert(entries, string.format("  %-10s %s", name, def.desc))
      end
      table.sort(entries)
      table.insert(entries, 1, "Lt subcommands:")
      vim.notify(table.concat(entries, "\n"), vim.log.levels.INFO)
      return
    end

    if sub == "lang" then
      local lang = args[2]
      if not lang then
        vim.notify("Usage: Lt lang <code|auto>", vim.log.levels.INFO)
        return
      end
      notify_server("lt-nvim/setLanguage", {
        uri = vim.uri_from_bufnr(0),
        language = lang,
      })
      return
    end

    local handler = subcommands[sub]
    if handler then
      handler.fn()
    else
      vim.notify("Lt: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    desc = "LanguageTool commands",
    complete = function(_, cmdline)
      local parts = vim.split(cmdline, "%s+", { trimempty = true })
      local trailing_space = cmdline:match("%s$") ~= nil
      local nparts = #parts + (trailing_space and 1 or 0)
      if nparts <= 2 then
        local names = vim.tbl_keys(subcommands)
        table.insert(names, "lang")
        table.sort(names)
        return names
      end
      if parts[2] == "lang" and nparts <= 3 then
        return { "auto" }
      end
      return {}
    end,
  })
end

--- Returns the list of enabled filetypes.
---@return string[]
function M.get_filetypes()
  if resolved_config then
    return resolved_config.enabled_filetypes
  end
  return config_mod.defaults().enabled_filetypes
end

--- Returns the resolved config table.
---@return table
function M.get_config()
  if resolved_config then
    return resolved_config
  end
  return config_mod.defaults()
end

--- Statusline component.
---@return string
function M.statusline()
  local bufnr = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ name = "lt-nvim", bufnr = bufnr })
  if #clients == 0 then
    return ""
  end

  if api.is_checking(bufnr) then
    return "LT …"
  end

  local diagnostics = vim.diagnostic.get(bufnr, { namespace = vim.lsp.diagnostic.get_namespace(clients[1].id, false) })
  local count = #diagnostics
  if count > 0 then
    return string.format("LT: %d", count)
  end

  return "LT"
end

return M
