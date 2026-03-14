local M = {}

--- Returns a list of treesitter query strings for the given language,
--- merged with any user-provided queries. Returns nil if unsupported.
---@param lang string
---@param user_queries table<string, string[]>|nil
---@return string[]|nil
function M.get(lang, user_queries)
  local ok, builtin = pcall(require, "lt-nvim.queries." .. lang)
  local queries = ok and type(builtin) == "table" and #builtin > 0 and vim.deepcopy(builtin) or nil

  if user_queries and user_queries[lang] then
    if queries then
      vim.list_extend(queries, user_queries[lang])
    else
      queries = vim.deepcopy(user_queries[lang])
    end
  end

  return queries
end

return M
