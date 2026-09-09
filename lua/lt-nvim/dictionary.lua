local async = vim.async

local M = {}

local data_dir = vim.fn.stdpath("data") .. "/lt-nvim"

-- Global state: word dictionary (shared across all projects)
local local_words = {} -- set: { [word] = true }

-- Project-local state: cached per project root
local project_configs = {} -- project_root → { disabled_rules = {}, false_positives = {} }

-------------------------------------------------------------------------------
-- File I/O helpers
-------------------------------------------------------------------------------

local function ensure_dir(dir)
	vim.fn.mkdir(dir, "p")
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

local function write_file(path, content)
	local dir = vim.fn.fnamemodify(path, ":h")
	ensure_dir(dir)
	async.run(function()
		local err_open, fd = async.await(4, vim.uv.fs_open, path, "w", 438)
		if err_open or not fd then
			async.await(vim.schedule)
			return vim.notify("lt-nvim: failed to write " .. path, vim.log.levels.ERROR)
		end
		local err_write = async.await(4, vim.uv.fs_write, fd, content, nil)
		vim.uv.fs_close(fd)
		if err_write then
			async.await(vim.schedule)
			vim.notify("lt-nvim: failed to write " .. path, vim.log.levels.ERROR)
		end
	end)
end

-------------------------------------------------------------------------------
-- Global dictionary (word list)
-------------------------------------------------------------------------------

function M.load()
	local dict_path = data_dir .. "/dictionary.txt"
	local dict_content = read_file(dict_path)
	local_words = {}
	if dict_content then
		for word in dict_content:gmatch("[^\n]+") do
			local trimmed = vim.trim(word)
			if trimmed ~= "" then
				local_words[trimmed] = true
			end
		end
	end
end

local function save_local_words()
	local words = {}
	for word in pairs(local_words) do
		table.insert(words, word)
	end
	table.sort(words)
	write_file(data_dir .. "/dictionary.txt", table.concat(words, "\n") .. "\n")
end

--- Add a word to the dictionary.
--- Premium: uses server-side API. Free: uses local file.
---@param word string
---@param config table  resolved config (needs api_key, username, api_url)
---@param callback fun(success: boolean)
function M.add_word(word, config, callback)
	if config.tier ~= "premium" then
		-- Free: local dictionary
		local_words[word] = true
		save_local_words()
		return callback(true)
	end

	-- Premium: POST /v2/words/add (piped via stdin to hide credentials)
	local api_base = config.api_url:gsub("/v2/check$", "")
	local body = "word="
		.. vim.uri_encode(word, "rfc2396")
		.. "&username="
		.. vim.uri_encode(config.username, "rfc2396")
		.. "&apiKey="
		.. vim.uri_encode(config.api_key, "rfc2396")

	async.run(function()
		local started, res = async.pawait(
			4,
			vim.system,
			{ "curl", "-s", "-X", "POST", api_base .. "/v2/words/add", "--data-binary", "@-" },
			{ stdin = body, text = true }
		)
		async.await(vim.schedule)

		if not started then
			vim.notify("lt-nvim: failed to start curl", vim.log.levels.ERROR)
			return callback(false)
		end

		-- curl exits 0 even on HTTP 4xx (no -f), so success must be confirmed
		-- from the response body: LT returns {"added": true} on success.
		local raw = vim.trim(res.stdout or "")
		local ok, resp = pcall(vim.json.decode, raw)
		if res.code == 0 and ok and type(resp) == "table" and resp.added == true then
			return callback(true)
		end

		local msg = "unknown error"
		if ok and type(resp) == "table" and (resp.message or resp.error) then
			msg = resp.message or resp.error
		elseif raw ~= "" then
			msg = raw:sub(1, 200)
		end
		vim.notify("lt-nvim: failed to add word to server dictionary: " .. msg, vim.log.levels.WARN)
		callback(false)
	end)
end

--- Check if a word is in the local dictionary.
---@param word string
---@return boolean
function M.has_local_word(word)
	return local_words[word] == true
end

-------------------------------------------------------------------------------
-- Project-local config (.lt-nvim.json)
-------------------------------------------------------------------------------

--- Load or return cached project config for a given project root.
---@param project_root string
---@return table  { disabled_rules = {set}, false_positives = {list} }
local function get_project_config(project_root)
	if project_configs[project_root] then
		return project_configs[project_root]
	end

	local pc = { disabled_rules = {}, false_positives = {}, language = nil }
	local path = project_root .. "/.lt-nvim.json"
	local content = read_file(path)
	if content then
		local ok, data = pcall(vim.json.decode, content)
		if ok and type(data) == "table" then
			if data.disabled_rules then
				for _, id in ipairs(data.disabled_rules) do
					pc.disabled_rules[id] = true
				end
			end
			if data.false_positives then
				pc.false_positives = data.false_positives
			end
			if data.language then
				pc.language = data.language
			end
		elseif content:match("%S") then
			vim.notify("lt-nvim: failed to parse " .. path, vim.log.levels.WARN)
		end
	end

	project_configs[project_root] = pc
	return pc
end

--- Save project config to .lt-nvim.json.
---@param project_root string
local function save_project_config(project_root)
	local pc = project_configs[project_root]
	if not pc then
		return
	end

	local rules = {}
	for id in pairs(pc.disabled_rules) do
		table.insert(rules, id)
	end
	table.sort(rules)

	local data = {
		disabled_rules = rules,
		false_positives = pc.false_positives,
		language = pc.language,
	}
	write_file(project_root .. "/.lt-nvim.json", vim.json.encode(data) .. "\n")
end

-------------------------------------------------------------------------------
-- Disabled rules (project-local)
-------------------------------------------------------------------------------

--- Disable a rule for the given project.
---@param rule_id string
---@param project_root string
function M.disable_rule(rule_id, project_root)
	local pc = get_project_config(project_root)
	pc.disabled_rules[rule_id] = true
	save_project_config(project_root)
end

--- Get the project-level language override, if set.
---@param project_root string
---@return string|nil
function M.get_project_language(project_root)
	local pc = get_project_config(project_root)
	return pc.language
end

--- Get all disabled rule IDs for the given project (for merging into API request).
---@param project_root string
---@return string[]
function M.get_disabled_rules(project_root)
	local pc = get_project_config(project_root)
	local rules = {}
	for id in pairs(pc.disabled_rules) do
		table.insert(rules, id)
	end
	return rules
end

-------------------------------------------------------------------------------
-- False positives (project-local)
-------------------------------------------------------------------------------

--- Hide a false positive (rule + sentence combination).
---@param rule_id string
---@param sentence string
---@param project_root string
function M.hide_false_positive(rule_id, sentence, project_root)
	local pc = get_project_config(project_root)
	table.insert(pc.false_positives, { rule_id = rule_id, sentence = sentence })
	save_project_config(project_root)
end

--- Check if a match is a hidden false positive.
---@param rule_id string
---@param sentence string|nil
---@param project_root string
---@return boolean
function M.is_false_positive(rule_id, sentence, project_root)
	if not sentence then
		return false
	end
	local pc = get_project_config(project_root)
	for _, fp in ipairs(pc.false_positives) do
		if fp.rule_id == rule_id and fp.sentence == sentence then
			return true
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- Filtering
-------------------------------------------------------------------------------

--- Filter matches: remove disabled rules and hidden false positives.
--- Local-dictionary suppression happens later in publish_diagnostics, where the
--- matched word can be extracted correctly from the buffer (see server.lua).
---@param matches table[]  normalized matches
---@param project_root string
---@return table[] filtered
function M.filter_matches(matches, project_root)
	local pc = get_project_config(project_root)
	local result = {}

	for _, match in ipairs(matches) do
		-- Skip disabled rules
		if pc.disabled_rules[match.rule_id] then
			goto continue
		end

		-- Skip false positives
		if M.is_false_positive(match.rule_id, match.sentence, project_root) then
			goto continue
		end

		table.insert(result, match)
		::continue::
	end

	return result
end

-- Load global dictionary on require
M.load()

return M
