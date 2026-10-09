if vim.g.loaded_lt_nvim then
	return
end
vim.g.loaded_lt_nvim = true

local function register_lsp()
	require("lt-nvim").register_lsp()
end

-- Fallback for configs that never call setup(). register_lsp is idempotent.
vim.api.nvim_create_autocmd("UIEnter", {
	once = true,
	callback = register_lsp,
})
vim.api.nvim_create_autocmd("User", {
	pattern = "VeryLazy",
	once = true,
	callback = register_lsp,
})
