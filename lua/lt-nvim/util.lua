local M = {}

--- Returns a debounced wrapper and a cancel function.
--- The wrapped function will only fire after `ms` milliseconds of inactivity.
---@param fn function
---@param ms number
---@return function wrapper, function cancel
function M.debounce(fn, ms)
  local timer = vim.uv.new_timer()
  local function wrapper(...)
    local args = { ... }
    timer:stop()
    timer:start(ms, 0, function()
      timer:stop()
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
  local function cancel()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
  return wrapper, cancel
end

--- Returns full buffer content as a single string, lines joined with \n.
---@param bufnr number
---@return string
function M.buf_get_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

--- Converts a byte offset in the buffer to an LSP position { line, character }.
--- Both line and character are 0-indexed. Character is in UTF-16 code units.
---@param bufnr number
---@param byte_offset number
---@param lines string[]|nil  pre-fetched buffer lines (avoids repeated nvim_buf_get_lines calls)
---@return { line: number, character: number }
function M.byte_to_position(bufnr, byte_offset, lines)
  lines = lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local remaining = byte_offset
  for i, line in ipairs(lines) do
    -- +1 for the newline character
    local line_len = #line + 1
    if remaining < line_len then
      -- remaining is the byte column within this line
      local col_utf16 = vim.str_utfindex(line, "utf-16", remaining)
      return { line = i - 1, character = col_utf16 }
    end
    remaining = remaining - line_len
  end
  -- Past the end of buffer — clamp to last position
  local last_line = lines[#lines] or ""
  local col_utf16 = vim.str_utfindex(last_line, "utf-16", #last_line)
  return { line = #lines - 1, character = col_utf16 }
end

--- Find the project root for a given file path.
--- Walks up from the file looking for VCS markers, falls back to cwd.
---@param path string  absolute file path
---@return string root  absolute directory path
function M.find_project_root(path)
  return vim.fs.root(path, { ".git", ".hg", ".svn" }) or vim.fn.getcwd()
end

return M
