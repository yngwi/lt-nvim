local M = {}

function M.check()
	local health = vim.health

	health.start("lt-nvim")

	if vim.fn.has("nvim-0.11") == 1 then
		health.ok("Neovim >= 0.11")
	else
		health.error("Neovim >= 0.11 required (vim.lsp.config / vim.lsp.enable)")
	end

	if vim.fn.executable("curl") == 1 then
		health.ok("curl found on PATH")
	else
		health.error("curl not found on PATH — required for API communication")
	end

	local config = require("lt-nvim").get_config()

	if config.tier == "selfhosted" then
		health.ok("Self-hosted server: " .. config.api_url)
	else
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
	end

	local clients = vim.lsp.get_clients({ name = "lt-nvim" })
	if #clients > 0 then
		health.ok("LSP server running (" .. #clients .. " client(s))")
	else
		health.info("LSP server not currently attached to any buffer")
	end

	health.start("lt-nvim: treesitter parsers")
	local function check_parser(ft, lang, consequence)
		if pcall(vim.treesitter.language.inspect, lang) then
			health.ok(ft .. " — parser " .. lang .. " installed")
		else
			health.warn(ft .. " — parser " .. lang .. " not installed (" .. consequence .. ")")
		end
	end
	for _, ft in ipairs(config.enabled_filetypes) do
		if ft == "markdown" then
			check_parser(ft, "markdown", "falls back to the line-based parser")
			check_parser(ft, "markdown_inline", "inline markup is checked as prose")
		elseif require("lt-nvim.queries").get(ft, config.user_queries) then
			check_parser(ft, vim.treesitter.language.get_lang(ft) or ft, "the whole buffer is checked as prose")
		end
	end

	health.start("lt-nvim: API")
	health.info("Endpoint: " .. config.api_url)
	local tier_label = config.tier == "premium" and "Premium" or config.tier == "selfhosted" and "Self-hosted" or "Free"
	health.info("Tier: " .. tier_label)
end

return M
