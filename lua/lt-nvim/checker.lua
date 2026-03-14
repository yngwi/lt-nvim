local annotator = require("lt-nvim.annotator")
local api = require("lt-nvim.api")
local dictionary = require("lt-nvim.dictionary")

local M = {}

--- Run a check cycle: build AnnotatedText, diff against cache, send to API if changed.
---@param bufnr number
---@param config table
---@param cache table  per-buffer cache (mutated in place)
---@param project_root string
---@param on_done fun(matches: table[], annotation_map: table[], detected_lang: string|nil)
function M.check(bufnr, config, cache, project_root, on_done)
  local result = annotator.build(bufnr, config)
  if not result then
    on_done({}, {}, nil)
    return
  end

  -- Cache check: if the text content hasn't changed, reuse cached matches
  if cache.plain_text and cache.plain_text == result.plain_text and cache.matches then
    on_done(cache.matches, result.annotation_map, cache.detected_lang)
    return
  end

  -- Build the JSON for the data parameter
  local annotation_json = vim.json.encode({ annotation = result.annotation })

  -- Shallow copy so we can override disabled_rules without mutating the original
  local merged_config = vim.tbl_extend("force", {}, config)
  local dict_rules = dictionary.get_disabled_rules(project_root)
  if #dict_rules > 0 then
    local all_rules = vim.list_extend(vim.list_extend({}, config.disabled_rules), dict_rules)
    merged_config.disabled_rules = all_rules
  end

  api.check(bufnr, annotation_json, merged_config, function(matches, detected_lang)
    -- Post-filter: dictionary words, disabled rules, false positives
    matches = dictionary.filter_matches(matches, result.plain_text, config, project_root)

    -- Update cache
    cache.plain_text = result.plain_text
    cache.matches = matches
    cache.annotation_map = result.annotation_map
    cache.detected_lang = detected_lang

    on_done(matches, result.annotation_map, detected_lang)
  end)
end

--- Force re-check: clear cache, re-check.
---@param bufnr number
---@param config table
---@param cache table
---@param project_root string
---@param on_done fun(matches: table[], annotation_map: table[], detected_lang: string|nil)
function M.force_check(bufnr, config, cache, project_root, on_done)
  cache.plain_text = nil
  cache.matches = nil
  cache.annotation_map = nil
  cache.detected_lang = nil
  M.check(bufnr, config, cache, project_root, on_done)
end

return M
