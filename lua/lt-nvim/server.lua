local checker = require("lt-nvim.checker")
local api = require("lt-nvim.api")
local dictionary = require("lt-nvim.dictionary")
local util = require("lt-nvim.util")

local M = {}

--- Look up annotation_map to convert an LT offset to a buffer byte.
--- LT offsets count all bytes (markup + text) in the annotation.
---@param annotation_map table[]  sorted list of { full_offset, buffer_byte }
---@param lt_offset number
---@return number buffer_byte
local function map_to_buffer_byte(annotation_map, lt_offset)
  local entry = annotation_map[1]
  for _, e in ipairs(annotation_map) do
    if e.full_offset <= lt_offset then
      entry = e
    else
      break
    end
  end
  return entry.buffer_byte + (lt_offset - entry.full_offset)
end

--- Create the in-memory LSP server.
---@param dispatchers table  { notification, server_request, on_exit, on_error }
---@return table PublicClient
function M.create(dispatchers)
  local closing = false
  local buffers = {}

  local function get_config()
    return require("lt-nvim").get_config()
  end

  --- Get config with effective language resolved for a buffer.
  local function get_effective_config(buf)
    local config = get_config()
    local lang = buf.language_override
      or dictionary.get_project_language(buf.project_root)
    if lang then
      config = vim.tbl_extend("force", config, { language = lang })
    end
    return config
  end

  ---------------------------------------------------------------------------
  -- Diagnostic publishing
  ---------------------------------------------------------------------------

  local function publish_diagnostics(uri, matches, annotation_map)
    local buf = buffers[uri]
    if not buf or not buf.enabled then return end
    local bufnr = buf.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not annotation_map or #annotation_map == 0 then return end

    local diagnostics = {}
    local stored_matches = {}
    local buf_text = util.buf_get_text(bufnr)
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    for _, match in ipairs(matches) do
      -- LT AnnotatedText offsets count ALL bytes: markup + text concatenated.
      -- Matches may span across markup boundaries, so we clamp to text regions only.
      local match_start = match.offset
      local match_end = match.offset + match.length
      local clamped_start = nil
      local clamped_end = nil

      for _, e in ipairs(annotation_map) do
        if e.full_offset > match_end then break end
        local entry_end = e.full_offset + e.len
        if e.is_text and match_start < entry_end and match_end > e.full_offset then
          -- This text entry overlaps the match
          local s = math.max(match_start, e.full_offset)
          local en = math.min(match_end, entry_end)
          if not clamped_start or s < clamped_start then
            clamped_start = s
          end
          if not clamped_end or en > clamped_end then
            clamped_end = en
          end
        end
      end

      if not clamped_start then
        goto next_match
      end

      local start_buf_byte = map_to_buffer_byte(annotation_map, clamped_start --[[@as number]])
      local end_buf_byte = map_to_buffer_byte(annotation_map, clamped_end --[[@as number]])

      local start_pos = util.byte_to_position(bufnr, start_buf_byte, buf_lines)
      local end_pos = util.byte_to_position(bufnr, end_buf_byte, buf_lines)

      local severity
      if match.category == "TYPOS" then
        severity = 1
      elseif match.category == "GRAMMAR" then
        severity = 2
      else
        severity = 4
      end

      -- Extract the matched word from the buffer
      local matched_word = buf_text:sub(start_buf_byte + 1, end_buf_byte)

      -- Adjust replacements: when range was clamped (markup bytes removed),
      -- replacements may have trailing/leading whitespace that no longer applies.
      local was_clamped = (clamped_start > match_start) or (clamped_end < match_end)
      local replacements = match.replacements
      if was_clamped then
        replacements = {}
        for _, r in ipairs(match.replacements) do
          -- Trim whitespace that corresponds to the clamped markup
          local adjusted = r
          if clamped_end < match_end then
            adjusted = adjusted:gsub("%s+$", "")
          end
          if clamped_start > match_start then
            adjusted = adjusted:gsub("^%s+", "")
          end
          table.insert(replacements, adjusted)
        end
      end

      local diag = {
        range = {
          start = start_pos,
          ["end"] = end_pos,
        },
        severity = severity,
        source = "lt-nvim",
        message = match.message,
        code = match.rule_id,
        data = {
          replacements = replacements,
          category = match.category,
          rule_id = match.rule_id,
          matched_word = matched_word,
          sentence = match.sentence,
        },
      }

      table.insert(diagnostics, diag)
      table.insert(stored_matches, {
        match = vim.tbl_extend("force", match, { replacements = replacements }),
        range = diag.range,
        matched_word = matched_word,
      })
      ::next_match::
    end

    buf.matches = stored_matches

    dispatchers.notification("textDocument/publishDiagnostics", {
      uri = uri,
      diagnostics = diagnostics,
    })
  end

  ---------------------------------------------------------------------------
  -- Check triggering
  ---------------------------------------------------------------------------

  local function trigger_check(uri)
    local buf = buffers[uri]
    if not buf or not buf.enabled then return end
    local bufnr = buf.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local config = get_effective_config(buf)
    checker.check(bufnr, config, buf.cache, buf.project_root, function(matches, annotation_map, detected_lang)
      if not buffers[uri] or not vim.api.nvim_buf_is_valid(bufnr) then return end
      if detected_lang then
        buf.language = detected_lang
      end
      publish_diagnostics(uri, matches, annotation_map)
    end)
  end

  local function init_buffer(uri, bufnr)
    if buffers[uri] then return end

    local config = get_config()
    local check_fn, cancel_fn = util.debounce(function()
      trigger_check(uri)
    end, config.debounce_ms)

    -- Determine project root from the buffer's file path
    local file_path = vim.uri_to_fname(uri)
    local project_root = util.find_project_root(file_path)

    buffers[uri] = {
      bufnr = bufnr,
      enabled = true,
      check_fn = check_fn,
      cancel_fn = cancel_fn,
      cache = {},
      matches = {},
      language = nil,
      language_override = nil,
      project_root = project_root,
    }
  end

  local function cleanup_buffer(uri)
    local buf = buffers[uri]
    if not buf then return end
    buf.cancel_fn()
    api.cancel(buf.bufnr)
    buffers[uri] = nil
  end

  ---------------------------------------------------------------------------
  -- Code actions
  ---------------------------------------------------------------------------

  local function get_code_actions(uri, params)
    local buf = buffers[uri]
    if not buf then return {} end

    local req_range = params.range
    local actions = {}
    local config = get_config()

    for _, entry in ipairs(buf.matches) do
      local r = entry.range
      -- Check overlap
      local overlaps = r.start.line <= req_range["end"].line
        and r["end"].line >= req_range.start.line
      if overlaps then
        if r.start.line == req_range["end"].line
          and r.start.character > req_range["end"].character then
          overlaps = false
        end
        if r["end"].line == req_range.start.line
          and r["end"].character < req_range.start.character then
          overlaps = false
        end
      end

      if not overlaps then goto next_match end

      -- 1. Accept suggestion actions
      for _, replacement in ipairs(entry.match.replacements) do
        local title
        if replacement == "" then
          title = string.format("Remove '%s'", entry.matched_word)
        elseif replacement:match("^%s+$") then
          title = "Replace with whitespace"
        else
          title = string.format("'%s' → '%s'", entry.matched_word, replacement)
        end
        table.insert(actions, {
          title = title,
          kind = "quickfix",
          edit = {
            changes = {
              [uri] = {{
                range = r,
                newText = replacement,
              }},
            },
          },
        })
      end

      -- 2. Add to dictionary (for spelling-like rules)
      -- Offer when the matched text is a single word (no spaces)
      local rid = entry.match.rule_id
      local word = entry.matched_word
      local is_spelling = word and #word > 0 and not word:match("%s")
      if is_spelling then
        local dict_label = config.api_key and "server" or "local"
        table.insert(actions, {
          title = string.format("Add '%s' to %s dictionary", word, dict_label),
          kind = "quickfix",
          command = {
            title = "Add to dictionary",
            command = "lt-nvim.addToDictionary",
            arguments = { uri, word },
          },
        })
      end

      -- 3. Disable rule
      table.insert(actions, {
        title = string.format("Disable rule '%s'", rid),
        kind = "quickfix",
        command = {
          title = "Disable rule",
          command = "lt-nvim.disableRule",
          arguments = { uri, rid },
        },
      })

      -- 4. Hide false positive
      if entry.match.sentence then
        table.insert(actions, {
          title = "Hide false positive",
          kind = "quickfix",
          command = {
            title = "Hide false positive",
            command = "lt-nvim.hideFalsePositive",
            arguments = { uri, rid, entry.match.sentence },
          },
        })
      end

      ::next_match::
    end

    return actions
  end

  ---------------------------------------------------------------------------
  -- Command execution
  ---------------------------------------------------------------------------

  local function recheck_buffer(uri)
    local buf = buffers[uri]
    if not buf then return end
    local cfg = get_effective_config(buf)
    checker.force_check(buf.bufnr, cfg, buf.cache, buf.project_root, function(matches, amap, detected_lang)
      if buffers[uri] and vim.api.nvim_buf_is_valid(buf.bufnr) then
        if detected_lang then buf.language = detected_lang end
        publish_diagnostics(uri, matches, amap)
      end
    end)
  end

  local function execute_command(command, arguments)
    local config = get_config()

    if command == "lt-nvim.addToDictionary" then
      local uri, word = arguments[1], arguments[2]
      dictionary.add_word(word, config, function(success)
        if success then
          vim.notify(string.format("lt-nvim: added '%s' to dictionary", word), vim.log.levels.INFO)
          recheck_buffer(uri)
        end
      end)

    elseif command == "lt-nvim.disableRule" then
      local uri, rule_id = arguments[1], arguments[2]
      local buf = buffers[uri]
      local project_root = buf and buf.project_root or vim.fn.getcwd()
      dictionary.disable_rule(rule_id, project_root)
      vim.notify(string.format("lt-nvim: disabled rule '%s'", rule_id), vim.log.levels.INFO)
      recheck_buffer(uri)

    elseif command == "lt-nvim.hideFalsePositive" then
      local uri, rule_id, sentence = arguments[1], arguments[2], arguments[3]
      local buf = buffers[uri]
      local project_root = buf and buf.project_root or vim.fn.getcwd()
      dictionary.hide_false_positive(rule_id, sentence, project_root)
      vim.notify("lt-nvim: hidden false positive", vim.log.levels.INFO)
      recheck_buffer(uri)
    end
  end

  ---------------------------------------------------------------------------
  -- LSP request handler
  ---------------------------------------------------------------------------

  local function on_request(method, params, callback)
    if method == "initialize" then
      callback(nil, {
        capabilities = {
          textDocumentSync = {
            openClose = true,
            change = 1,
            save = true,
          },
          codeActionProvider = {
            codeActionKinds = { "quickfix" },
          },
          executeCommandProvider = {
            commands = {
              "lt-nvim.addToDictionary",
              "lt-nvim.disableRule",
              "lt-nvim.hideFalsePositive",
            },
          },
        },
      })
    elseif method == "shutdown" then
      for _, buf in pairs(buffers) do
        buf.cancel_fn()
        api.cancel(buf.bufnr)
      end
      closing = true
      callback(nil, nil)
    elseif method == "textDocument/codeAction" then
      local uri = params.textDocument.uri
      local actions = get_code_actions(uri, params)
      callback(nil, actions)
    elseif method == "workspace/executeCommand" then
      execute_command(params.command, params.arguments or {})
      callback(nil, nil)
    else
      callback({ code = -32601, message = "method not found: " .. method }, nil)
    end
  end

  ---------------------------------------------------------------------------
  -- LSP notification handler
  ---------------------------------------------------------------------------

  local function on_notify(method, params)
    if method == "initialized" then
      -- no-op
    elseif method == "exit" then
      dispatchers.on_exit(0, 0)
    elseif method == "textDocument/didOpen" then
      local uri = params.textDocument.uri
      local bufnr = vim.uri_to_bufnr(uri)
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        init_buffer(uri, bufnr)
        trigger_check(uri)
      end
    elseif method == "textDocument/didChange" then
      local uri = params.textDocument.uri
      local buf = buffers[uri]
      if buf and buf.enabled then
        buf.check_fn()
      end
    elseif method == "textDocument/didSave" then
      local uri = params.textDocument.uri
      trigger_check(uri)
    elseif method == "textDocument/didClose" then
      local uri = params.textDocument.uri
      cleanup_buffer(uri)

    -- Custom notifications
    elseif method == "lt-nvim/forceCheck" then
      local uri = params.uri
      local buf = buffers[uri]
      if buf and buf.enabled and vim.api.nvim_buf_is_valid(buf.bufnr) then
        recheck_buffer(uri)
      end
    elseif method == "lt-nvim/enable" then
      local uri = params.uri
      local buf = buffers[uri]
      if buf then
        buf.enabled = true
        trigger_check(uri)
      elseif params.bufnr then
        init_buffer(uri, params.bufnr)
        trigger_check(uri)
      end
    elseif method == "lt-nvim/disable" then
      local uri = params.uri
      local buf = buffers[uri]
      if buf then
        buf.enabled = false
        api.cancel(buf.bufnr)
        dispatchers.notification("textDocument/publishDiagnostics", {
          uri = uri,
          diagnostics = {},
        })
      end
    elseif method == "lt-nvim/toggle" then
      local uri = params.uri
      local buf = buffers[uri]
      if buf then
        if buf.enabled then
          on_notify("lt-nvim/disable", params)
        else
          on_notify("lt-nvim/enable", params)
        end
      end
    elseif method == "lt-nvim/setLanguage" then
      local uri = params.uri
      local buf = buffers[uri]
      if buf then
        local lang = params.language
        if lang == "auto" then
          buf.language_override = nil
          buf.language = nil
        else
          buf.language_override = lang
        end
        recheck_buffer(uri)
      end
    elseif method == "lt-nvim/info" then
      local uri = params.uri
      local buf = buffers[uri]
      local config = get_config()
      local effective_lang
      local status
      if buf then
        effective_lang = buf.language_override
          or dictionary.get_project_language(buf.project_root)
          or buf.language
        if not buf.enabled then
          status = "disabled"
        elseif api.is_checking(buf.bufnr) then
          status = "checking…"
        else
          status = "active"
        end
      else
        status = "not attached"
      end
      effective_lang = effective_lang or config.language
      vim.schedule(function()
        vim.notify(string.format(
          "lt-nvim: %s | %s tier | lang=%s",
          status,
          config.api_key and "Premium" or "Free",
          effective_lang
        ), vim.log.levels.INFO)
      end)
    end
  end

  return {
    request = on_request,
    notify = on_notify,
    is_closing = function() return closing end,
    terminate = function()
      closing = true
      for uri in pairs(buffers) do
        cleanup_buffer(uri)
      end
    end,
  }
end

return M
