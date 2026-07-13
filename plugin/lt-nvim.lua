-- Guard: only register once
if vim.g.loaded_lt_nvim then
  return
end
vim.g.loaded_lt_nvim = true

local function register_lsp()
  require("lt-nvim").register_lsp()
end

-- Normally setup() registers the LSP directly, so attach works regardless of
-- when the plugin loads. These paths are a fallback for configs that never call
-- setup(): register immediately if it already ran, otherwise on the next
-- UIEnter/VeryLazy. (register_lsp is idempotent, so this never double-registers.)
if require("lt-nvim").is_setup() then
  register_lsp()
else
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
