local M = {}

-- Per-buffer job state (one job per buffer, no queue)
local jobs = {} -- bufnr → job_id

--- Percent-encode a string for application/x-www-form-urlencoded.
---@param str string
---@return string
local function urlencode(str)
  return vim.uri_encode(str, "rfc2396")
end

--- Build the POST body for an AnnotatedText check.
---@param annotation_json string  JSON-encoded annotation data
---@param config table
---@return string
local function build_post_body(annotation_json, config)
  local parts = {
    "data=" .. urlencode(annotation_json),
    "language=" .. urlencode(config.language),
  }

  if config.username and config.api_key then
    table.insert(parts, "username=" .. urlencode(config.username))
    table.insert(parts, "apiKey=" .. urlencode(config.api_key))
  end

  if config.preferred_variants then
    table.insert(parts, "preferredVariants=" .. urlencode(config.preferred_variants))
  end

  if config.mother_tongue then
    table.insert(parts, "motherTongue=" .. urlencode(config.mother_tongue))
  end

  if #config.disabled_rules > 0 then
    table.insert(parts, "disabledRules=" .. urlencode(table.concat(config.disabled_rules, ",")))
  end

  if #config.disabled_categories > 0 then
    table.insert(parts, "disabledCategories=" .. urlencode(table.concat(config.disabled_categories, ",")))
  end

  if #config.enabled_rules > 0 then
    table.insert(parts, "enabledRules=" .. urlencode(table.concat(config.enabled_rules, ",")))
  end

  if #config.enabled_categories > 0 then
    table.insert(parts, "enabledCategories=" .. urlencode(table.concat(config.enabled_categories, ",")))
  end

  if config.picky and config.api_key then
    table.insert(parts, "level=picky")
  end

  return table.concat(parts, "&")
end

--- Normalize a raw LT match to our internal flat structure.
---@param match table raw match from LT API
---@return table|nil normalized match, nil if malformed
local function normalize_match(match)
  if not match.rule or not match.rule.category then
    return nil
  end
  return {
    message = match.message or "",
    offset = match.offset or 0,
    length = match.length or 0,
    replacements = vim.tbl_map(
      function(r) return r.value end,
      match.replacements or {}
    ),
    rule_id = match.rule.id or "UNKNOWN",
    category = match.rule.category.id or "UNKNOWN",
    sentence = match.sentence,
  }
end

--- Submit a buffer for checking against the LT API using AnnotatedText.
--- One request per buffer. Cancels any in-flight work for the buffer.
---@param bufnr number
---@param annotation_json string  JSON-encoded { annotation = [...] }
---@param config table
---@param on_done fun(matches: table[], detected_lang: string|nil)
function M.check(bufnr, annotation_json, config, on_done)
  M.cancel(bufnr)

  local body = build_post_body(annotation_json, config)
  local args = { "curl", "-s", "--max-time", "30", "--connect-timeout", "10", "-X", "POST", config.api_url, "--data-binary", "@-" }
  local stdout_data = {}

  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout_data, data)
      end
    end,
    on_exit = function(_, exit_code)
      jobs[bufnr] = nil

      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      if exit_code == 0 then
        local raw = table.concat(stdout_data, "\n"):gsub("%s+$", "")
        if raw == "" then
          vim.schedule(function() on_done({}, nil) end)
          return
        end

        local ok, response = pcall(vim.json.decode, raw)
        if not ok then
          vim.schedule(function()
            vim.notify("lt-nvim: JSON parse error: " .. tostring(response) .. "\nRaw: " .. raw:sub(1, 200), vim.log.levels.WARN)
            on_done({}, nil)
          end)
          return
        end

        if response then
          -- Check for API errors
          if response.error or (response.status and response.status ~= "ok") then
            local msg = response.message or response.error or "unknown error"
            vim.schedule(function()
              vim.notify("lt-nvim: API error: " .. msg, vim.log.levels.WARN)
              on_done({}, nil)
            end)
            return
          end

          local matches = {}
          if response.matches then
            for _, match in ipairs(response.matches) do
              local n = normalize_match(match)
              if n then
                table.insert(matches, n)
              end
            end
          end

          -- Extract detected language
          local detected_lang = nil
          if response.language and response.language.detectedLanguage then
            detected_lang = response.language.detectedLanguage.code
          elseif response.language then
            detected_lang = response.language.code
          end

          vim.schedule(function() on_done(matches, detected_lang) end)
        else
          vim.schedule(function() on_done({}, nil) end)
        end
      else
        vim.schedule(function()
          vim.notify("lt-nvim: API request failed (exit " .. exit_code .. ")", vim.log.levels.WARN)
          on_done({}, nil)
        end)
      end
    end,
  })

  if job_id > 0 then
    vim.fn.chansend(job_id, body)
    vim.fn.chanclose(job_id, "stdin")
    jobs[bufnr] = job_id
  else
    vim.schedule(function()
      vim.notify("lt-nvim: failed to start curl", vim.log.levels.ERROR)
      on_done({}, nil)
    end)
  end
end

--- Cancel any in-flight API work for a buffer.
---@param bufnr number
function M.cancel(bufnr)
  if jobs[bufnr] then
    pcall(vim.fn.jobstop, jobs[bufnr])
    jobs[bufnr] = nil
  end
end

--- Returns true if an API check is in progress for the buffer.
---@param bufnr number
---@return boolean
function M.is_checking(bufnr)
  return jobs[bufnr] ~= nil
end

return M
