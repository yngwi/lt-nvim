-- Guard: only register once
if vim.g.loaded_lt_nvim then
  return
end
vim.g.loaded_lt_nvim = true

local registered = false

local function register_lsp()
  if registered then return end
  registered = true

  local lt = require("lt-nvim")

  vim.lsp.config("lt-nvim", {
    name = "lt-nvim",
    cmd = require("lt-nvim.server").create,
    filetypes = lt.get_filetypes(),
    root_markers = {},
    single_file_support = true,
  })

  vim.lsp.enable("lt-nvim")
end

-- Try immediately if setup() was already called (e.g. lazy.nvim runs config
-- before plugin/ files load).
if require("lt-nvim").is_setup() then
  register_lsp()
else
  -- Listen on both UIEnter (universal) and VeryLazy (lazy.nvim deferred setup).
  -- Whichever fires first wins; the guard prevents double registration.
  vim.api.nvim_create_autocmd("UIEnter", {
    once = true,
    callback = register_lsp,
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = "VeryLazy",
    once = true,
    callback = register_lsp,
  })
end
