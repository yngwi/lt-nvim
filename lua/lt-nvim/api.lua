local async = vim.async

local M = {}

-- Per-buffer request state (one in-flight check per buffer, no queue)
local tasks = {} -- bufnr → vim.async.Task

-- Per-buffer "work outstanding" flag: set when an edit schedules a (debounced)
-- check, cleared once diagnostics are published. Lets the statusline show
-- progress during the debounce window, before the curl job actually starts.
local pending = {} -- bufnr → true

-- Global session switch. When false, automatic checks are gated off; the LSP
-- stays attached so the statusline and :Lt commands keep working. Kept here
-- (not in the server closure) so the statusline can read it directly.
local enabled = true

-- Offline circuit breaker. A connection-level curl failure flips `offline` on
-- and suppresses automatic checks until the cooldown elapses; the next check
-- after that probes for recovery. Explicit user rechecks bypass the gate and
-- double as a manual probe.
local offline = false
local offline_until = 0 -- vim.uv.now() timestamp (ms)
local COOLDOWN_MS = 60000

-- curl exit codes meaning "couldn't reach the server" (vs. a real API error,
-- which comes back on a 0 exit with an error body).
local CONNECTION_FAILURE = {
	[5] = true, -- couldn't resolve proxy
	[6] = true, -- couldn't resolve host
	[7] = true, -- couldn't connect
	[28] = true, -- operation/connect timeout
	[35] = true, -- SSL connect error
}

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

	if config.picky and config.tier ~= "free" then
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
		replacements = vim.tbl_map(function(r)
			return r.value
		end, match.replacements or {}),
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
	local task
	task = async.run(function()
		local started, res = async.pawait(function(cb)
			local proc = vim.system({
				"curl",
				"-s",
				"--max-time",
				"30",
				"--connect-timeout",
				"5",
				"-X",
				"POST",
				config.api_url,
				"--data-binary",
				"@-",
			}, { stdin = body, text = true }, cb)
			-- vim.async closes the handle on resume and waits for `done`
			return {
				close = function(_, done)
					pcall(proc.kill, proc, "sigterm")
					if done then
						done()
					end
				end,
			}
		end)

		-- curl resumes in a fast event context; everything below notifies or
		-- touches buffers. A close during the request stops the task here, so a
		-- superseded check never reaches on_done.
		async.await(vim.schedule)

		-- Only clear the slot if it still points at us (a newer check may own it).
		if tasks[bufnr] == task then
			tasks[bufnr] = nil
		end

		if not started then
			vim.notify("lt-nvim: failed to start curl", vim.log.levels.ERROR)
			return on_done({}, nil)
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end

		local exit_code = res.code

		if CONNECTION_FAILURE[exit_code] then
			-- Transport failure (offline / captive portal): pause automatic checks
			-- and leave the last diagnostics in place instead of clearing them.
			local was_offline = offline
			offline = true
			offline_until = vim.uv.now() + COOLDOWN_MS
			M.clear_pending(bufnr)
			if not was_offline then
				vim.notify("lt-nvim: LanguageTool unreachable, pausing automatic checks", vim.log.levels.INFO)
			end
			return
		end

		if exit_code ~= 0 then
			vim.notify("lt-nvim: API request failed (exit " .. exit_code .. ")", vim.log.levels.WARN)
			return on_done({}, nil)
		end

		-- Reaching the server (even an API error body) means we're online.
		if offline then
			offline = false
			vim.notify("lt-nvim: connection restored, resuming checks", vim.log.levels.INFO)
		end

		local raw = (res.stdout or ""):gsub("%s+$", "")
		if raw == "" then
			return on_done({}, nil)
		end

		local ok, response = pcall(vim.json.decode, raw)
		if not ok then
			vim.notify(
				"lt-nvim: JSON parse error: " .. tostring(response) .. "\nRaw: " .. raw:sub(1, 200),
				vim.log.levels.WARN
			)
			return on_done({}, nil)
		end
		if not response then
			return on_done({}, nil)
		end

		-- Check for API errors
		if response.error or (response.status and response.status ~= "ok") then
			vim.notify(
				"lt-nvim: API error: " .. (response.message or response.error or "unknown error"),
				vim.log.levels.WARN
			)
			return on_done({}, nil)
		end

		local matches = {}
		for _, match in ipairs(response.matches or {}) do
			local n = normalize_match(match)
			if n then
				table.insert(matches, n)
			end
		end

		-- Extract detected language
		local detected_lang = nil
		if response.language and response.language.detectedLanguage then
			detected_lang = response.language.detectedLanguage.code
		elseif response.language then
			detected_lang = response.language.code
		end

		on_done(matches, detected_lang)
	end)

	tasks[bufnr] = task
end

--- Cancel any in-flight API work for a buffer.
---@param bufnr number
function M.cancel(bufnr)
	local task = tasks[bufnr]
	if task then
		-- Closing stops the task at its next checkpoint, so the superseded
		-- request's continuation never runs and on_done is never called.
		task:close()
		tasks[bufnr] = nil
	end
end

--- Returns true if an API check is in progress for the buffer.
---@param bufnr number
---@return boolean
function M.is_checking(bufnr)
	return tasks[bufnr] ~= nil
end

--- Global session switch: whether automatic checking is on.
---@return boolean
function M.is_enabled()
	return enabled
end

--- Set the global session switch.
---@param v boolean
function M.set_enabled(v)
	enabled = v and true or false
end

--- True while automatic checks are paused after a connection failure. Once the
--- cooldown elapses this returns false so the next check can probe for recovery,
--- even though the offline flag stays set until a check actually succeeds.
---@return boolean
function M.is_offline()
	if not offline then
		return false
	end
	return vim.uv.now() < offline_until
end

--- Mark that a check has been scheduled (e.g. on an edit) but not yet published.
---@param bufnr number
function M.mark_pending(bufnr)
	pending[bufnr] = true
end

--- Clear the pending flag (call once diagnostics have been published).
---@param bufnr number
function M.clear_pending(bufnr)
	pending[bufnr] = nil
end

--- Returns true if a check is either scheduled or in progress for the buffer.
---@param bufnr number
---@return boolean
function M.is_busy(bufnr)
	return tasks[bufnr] ~= nil or pending[bufnr] ~= nil
end

return M
