local queries = require("lt-nvim.queries")
local util = require("lt-nvim.util")

local M = {}

-------------------------------------------------------------------------------
-- Language aliases
-------------------------------------------------------------------------------

local lang_aliases = {
  sh = "bash", zsh = "bash",
  js = "javascript", ts = "typescript",
  jsx = "javascript", tsx = "typescript",
  py = "python", rb = "ruby", rs = "rust",
  yml = "yaml",
  ["c++"] = "cpp", cxx = "cpp", cc = "cpp",
  ["c#"] = "cs", csharp = "cs",
  objc = "c", ["objective-c"] = "c",
}

local function resolve_lang(lang)
  return lang_aliases[lang] or lang
end

-------------------------------------------------------------------------------
-- Annotation builder helper
-------------------------------------------------------------------------------

--- Accumulates annotation entries and builds annotation_map.
--- LT match offsets count both markup and text entries concatenated, measured in
--- UTF-16 code units (LanguageTool is Java; offsets are String char indices).
--- Each markup/text entry contributes the UTF-16 length of its own content
--- (markup contributes its markup content, NOT its interpretAs).
--- The annotation_map maps these full (UTF-16) offsets to buffer byte positions.
--- `full_offset` tracks position in LT's offset space (UTF-16 code units).
--- `buf_pos` tracks position in the buffer (bytes).
local function new_builder()
  return {
    annotation = {},
    annotation_map = {},  -- { full_offset, buffer_byte, is_text, len, text }[]
    full_offset = 0,      -- offset in markup+text concatenation, UTF-16 units (LT's space)
    buf_pos = 0,          -- current buffer byte position
    plain_parts = {},     -- text entries only (for empty-buffer detection)
    full_parts = {},      -- markup + text, in order (for cache invalidation)
  }
end

--- Add a text entry (LT will check this).
---@param b table  builder
---@param text string
---@param buffer_byte number  byte offset of this text in the buffer
local function add_text(b, text, buffer_byte)
  if #text == 0 then return end
  local char_len = vim.str_utfindex(text, "utf-16")
  table.insert(b.annotation, { text = text })
  -- Store the text so LT (UTF-16) offsets landing inside it can be converted to bytes.
  table.insert(b.annotation_map, { full_offset = b.full_offset, buffer_byte = buffer_byte, is_text = true, len = char_len, text = text })
  table.insert(b.plain_parts, text)
  table.insert(b.full_parts, text)
  b.full_offset = b.full_offset + char_len
  b.buf_pos = buffer_byte + #text
end

--- Add a markup entry (LT skips this for grammar but includes it in offset count).
---@param b table  builder
---@param markup string  the actual markup content in the buffer
---@param interpret_as string|nil  what LT sees for grammar purposes (default "")
local function add_markup(b, markup, interpret_as)
  if #markup == 0 then return end
  local entry = { markup = markup }
  if interpret_as and interpret_as ~= "" then
    entry.interpretAs = interpret_as
  end
  table.insert(b.annotation, entry)
  -- Markup content IS counted in LT's offset space (by its own UTF-16 length).
  local char_len = vim.str_utfindex(markup, "utf-16")
  table.insert(b.annotation_map, { full_offset = b.full_offset, buffer_byte = b.buf_pos, is_text = false, len = char_len })
  table.insert(b.full_parts, markup)
  b.full_offset = b.full_offset + char_len
  b.buf_pos = b.buf_pos + #markup
end

--- Finalize and return the result.
local function finish(b)
  return {
    annotation = b.annotation,
    annotation_map = b.annotation_map,
    plain_text = table.concat(b.plain_parts), -- text only, to detect "no prose to check"
    full_text = table.concat(b.full_parts),   -- markup + text, cache key (see checker.lua)
  }
end

-------------------------------------------------------------------------------
-- Comment/string delimiter detection
-------------------------------------------------------------------------------

local doc_line_patterns = {
  { pattern = "^(%s*///+ ?)", is_doc = true },
  { pattern = "^(%s*//!+ ?)", is_doc = true },
  { pattern = "^(%s*%-%-%-+ ?)", is_doc = true },
}

local regular_line_patterns = {
  { pattern = "^(%s*//+ ?)" },
  { pattern = "^(%s*%-%-+ ?)" },
  { pattern = "^(%s*#+ ?)" },
  { pattern = "^(%s*%%+ ?)" },
}

--- Detect and return the comment prefix and whether it's a doc comment.
---@return string|nil prefix, boolean is_doc
local function detect_line_comment_prefix(line)
  for _, entry in ipairs(doc_line_patterns) do
    local prefix = line:match(entry.pattern)
    if prefix then return prefix, true end
  end
  for _, entry in ipairs(regular_line_patterns) do
    local prefix = line:match(entry.pattern)
    if prefix then return prefix, false end
  end
  return nil, false
end

--- Detect block comment opening. Returns prefix, is_doc.
---@return string|nil prefix, boolean is_doc
local function detect_block_open(line)
  local prefix = line:match("^(%s*/%*[%*!] ?)")
  if prefix then return prefix, true end
  prefix = line:match("^(%s*/%* ?)")
  if prefix then return prefix, false end
  return nil, false
end

--- Detect and return the leading * prefix on a block comment line.
---@return string|nil prefix
local function detect_block_line_prefix(line)
  return line:match("^(%s*%*+ ?)")
end

--- Detect block comment closing suffix.
---@return string|nil suffix
local function detect_block_close(line)
  return line:match("(%s*%*/%s*)$")
end

local function is_url(text)
  return text:match("^https?://") ~= nil or text:match("^ftp://") ~= nil
end

-------------------------------------------------------------------------------
-- @tag handling for doc comments
-------------------------------------------------------------------------------

-- Tags that take a name/type argument before the description
local arg_tags = {
  param = true, parameter = true, arg = true, argument = true,
  throws = true, exception = true,
  type = true, typedef = true,
  property = true, prop = true,
  member = true, var = true,
  template = true,
  ["class"] = true, interface = true, extends = true, implements = true,
}

--- Detect @tag prefix in a doc comment content line.
--- Returns the byte length of the tag prefix (everything before the prose description),
--- or nil if no tag found.
---@param line string  content line (markers already stripped)
---@return number|nil tag_prefix_len
local function detect_tag_prefix(line)
  local tag_name = line:match("^@(%w+)")
  if not tag_name then return nil end

  if arg_tags[tag_name] then
    -- @param name - description  OR  @param name description
    local len = line:match("^@%w+%s+%S+%s+%-%s+()")
      or line:match("^@%w+%s+%S+%s+()")
    return len
  else
    -- @returns description
    return line:match("^@%w+%s+()")
  end
end

-------------------------------------------------------------------------------
-- Block comment annotation
-------------------------------------------------------------------------------

--- Annotate a block comment node (/* */ style).
--- Strips delimiters as markup, processes content as text (with doc handling).
---@param b table  builder
---@param node_text string
---@param node_buf_byte number
local function annotate_block_comment(b, node_text, node_buf_byte)
  local lines = vim.split(node_text, "\n", { plain = true })
  local is_doc = false

  -- First pass: parse each line into { prefix, content, suffix, buf_offset }
  local parsed = {}
  local byte_in_node = 0

  for i, line in ipairs(lines) do
    local prefix = ""
    local content = line
    local suffix = ""

    if i == 1 then
      local open_prefix, doc = detect_block_open(line)
      if open_prefix then
        is_doc = doc
        prefix = open_prefix
        content = line:sub(#prefix + 1)
      end
    elseif i == #lines then
      local close_suffix = detect_block_close(line)
      if close_suffix then
        suffix = close_suffix
        content = line:sub(1, #line - #suffix)
      end
      local star_prefix = detect_block_line_prefix(content)
      if star_prefix then
        prefix = star_prefix
        content = content:sub(#prefix + 1)
      end
    else
      local star_prefix = detect_block_line_prefix(line)
      if star_prefix then
        prefix = star_prefix
        content = line:sub(#prefix + 1)
      end
    end

    -- For doc comments, detect @tag prefixes in content
    local tag_prefix_len = nil
    if is_doc and vim.trim(content) ~= "" then
      tag_prefix_len = detect_tag_prefix(content)
    end

    table.insert(parsed, {
      prefix = prefix,
      content = content,
      suffix = suffix,
      tag_prefix_len = tag_prefix_len,
      has_content = vim.trim(content) ~= "",
      is_tag_only = content:match("^@") ~= nil and not tag_prefix_len,
      buf_offset = byte_in_node, -- offset of line start within node
    })

    byte_in_node = byte_in_node + #line + 1
  end

  -- Second pass: emit annotations.
  -- Track whether we've emitted any text yet, to avoid leading interpretAs newlines.
  local emitted_text = false

  for i, p in ipairs(parsed) do
    -- Newline between lines
    if i > 1 then
      -- Only emit interpretAs "\n" if we've already emitted text and this or
      -- a future line has content. Otherwise just emit invisible markup.
      if emitted_text and p.has_content then
        add_markup(b, "\n", "\n")
      else
        add_markup(b, "\n", "")
      end
    end

    -- Line prefix (/**,  * , etc.) → always markup
    if #p.prefix > 0 then
      add_markup(b, p.prefix, "")
    end

    -- Content
    if p.has_content then
      if p.tag_prefix_len then
        -- @tag with description: tag prefix → markup, description → text
        local tag_part = p.content:sub(1, p.tag_prefix_len - 1)
        local desc = p.content:sub(p.tag_prefix_len)
        add_markup(b, tag_part, "")
        if vim.trim(desc) ~= "" then
          add_text(b, desc, node_buf_byte + p.buf_offset + #p.prefix + p.tag_prefix_len - 1)
          emitted_text = true
        else
          add_markup(b, desc, "")
        end
      elseif p.is_tag_only then
        -- @tag with no extractable description
        add_markup(b, p.content, "")
      else
        -- Regular prose content
        add_text(b, p.content, node_buf_byte + p.buf_offset + #p.prefix)
        emitted_text = true
      end
    elseif #p.content > 0 then
      -- Whitespace-only content
      add_markup(b, p.content, "")
    end

    -- Line suffix ( */) → always markup
    if #p.suffix > 0 then
      add_markup(b, p.suffix, "")
    end
  end
end

-------------------------------------------------------------------------------
-- Line comment annotation
-------------------------------------------------------------------------------

--- Annotate a line comment node (// or # style).
---@param b table  builder
---@param node_text string
---@param node_buf_byte number
local function annotate_line_comment(b, node_text, node_buf_byte)
  local lines = vim.split(node_text, "\n", { plain = true })
  local byte_in_node = 0

  for i, line in ipairs(lines) do
    if i > 1 then
      add_markup(b, "\n", "\n")
    end

    local prefix, is_doc = detect_line_comment_prefix(line)
    if prefix then
      add_markup(b, prefix, "")
      local content = line:sub(#prefix + 1)

      if is_doc then
        local tag_prefix_len = detect_tag_prefix(content)
        if tag_prefix_len then
          add_markup(b, content:sub(1, tag_prefix_len - 1), "")
          local desc = content:sub(tag_prefix_len)
          if vim.trim(desc) ~= "" then
            add_text(b, desc, node_buf_byte + byte_in_node + #prefix + tag_prefix_len - 1)
          end
        elseif content:match("^@") then
          add_markup(b, content, "")
        elseif vim.trim(content) ~= "" then
          add_text(b, content, node_buf_byte + byte_in_node + #prefix)
        end
      elseif vim.trim(content) ~= "" then
        add_text(b, content, node_buf_byte + byte_in_node + #prefix)
      end
    else
      -- No recognized prefix — treat entire line as text
      if vim.trim(line) ~= "" then
        add_text(b, line, node_buf_byte + byte_in_node)
      end
    end

    byte_in_node = byte_in_node + #line + 1
  end
end

-------------------------------------------------------------------------------
-- String annotation
-------------------------------------------------------------------------------

--- Annotate a string node.
---@param b table  builder
---@param node_text string
---@param node_buf_byte number
local function annotate_string(b, node_text, node_buf_byte)
  -- Detect quote style
  local prefix_len = 0
  local suffix_len = 0

  if node_text:sub(1, 3) == '"""' or node_text:sub(1, 3) == "'''" then
    prefix_len = 3
    suffix_len = 3
  elseif node_text:sub(1, 1):match('["\']') then
    prefix_len = 1
    suffix_len = 1
  elseif node_text:sub(1, 1) == "`" then
    prefix_len = 1
    suffix_len = 1
  end

  if prefix_len > 0 then
    add_markup(b, node_text:sub(1, prefix_len), "")
  end

  local content = node_text:sub(prefix_len + 1, #node_text - suffix_len)
  -- Trim leading/trailing whitespace as markup (e.g. jsx_text indentation)
  local leading = content:match("^(%s+)")
  if leading then
    add_markup(b, leading, "")
    content = content:sub(#leading + 1)
    prefix_len = prefix_len + #leading
  end
  local trailing = content:match("(%s+)$")
  if trailing then
    content = content:sub(1, #content - #trailing)
  end
  if not is_url(content) and content ~= "" then
    add_text(b, content, node_buf_byte + prefix_len)
  elseif content ~= "" then
    add_markup(b, content, "")
  end
  if trailing then
    add_markup(b, trailing, "")
  end

  if suffix_len > 0 then
    add_markup(b, node_text:sub(#node_text - suffix_len + 1), "")
  end
end

-------------------------------------------------------------------------------
-- Shared node collection and annotation
-------------------------------------------------------------------------------

--- Collect treesitter comment/string nodes from a parsed tree.
---@param query_strings string[]
---@param lang string
---@param root userdata  treesitter root node
---@param source number|string  bufnr or source string
---@return table[]  sorted nodes
local function collect_nodes(query_strings, lang, root, source)
  local nodes = {}
  for _, query_str in ipairs(query_strings) do
    local parse_ok, query = pcall(vim.treesitter.query.parse, lang, query_str)
    if parse_ok and query then
      for id, node in query:iter_captures(root, source, 0, -1) do
        local capture_name = query.captures[id]
        local node_text = vim.treesitter.get_node_text(node, source)
        local _, _, sb = node:start()
        local _, _, eb = node:end_()
        table.insert(nodes, {
          start_byte = sb,
          end_byte = eb,
          capture = capture_name,
          text = node_text,
        })
      end
    end
  end
  table.sort(nodes, function(x, y) return x.start_byte < y.start_byte end)
  return nodes
end

--- Walk collected nodes, emitting markup for gaps and annotating each node.
---@param b table  builder
---@param nodes table[]
---@param full_text string
---@param base_byte number  byte offset to add to node positions
local function emit_nodes(b, nodes, full_text, base_byte)
  local pos = 0
  for _, node in ipairs(nodes) do
    if node.start_byte < pos then goto skip end

    if node.start_byte > pos then
      add_markup(b, full_text:sub(pos + 1, node.start_byte), "\n\n")
    end

    if node.capture == "lt_comment" then
      if node.text:match("^%s*/%*") then
        annotate_block_comment(b, node.text, base_byte + node.start_byte)
      else
        annotate_line_comment(b, node.text, base_byte + node.start_byte)
      end
    elseif node.capture == "lt_string" or node.capture == "lt_docstring" then
      annotate_string(b, node.text, base_byte + node.start_byte)
    end

    pos = node.end_byte
    ::skip::
  end

  if pos < #full_text then
    add_markup(b, full_text:sub(pos + 1), "")
  end
end

-------------------------------------------------------------------------------
-- Code file annotation (treesitter-based)
-------------------------------------------------------------------------------

--- Build annotation for a code buffer using treesitter.
--- Comment/string nodes become text, everything else becomes markup.
---@param b table  builder
---@param bufnr number
---@param lang string
---@param config table
---@return boolean success
local function annotate_code_buffer(b, bufnr, lang, config)
  local query_strings = queries.get(lang, config.user_queries)
  if not query_strings then return false end

  -- Don't pass lang explicitly; let Neovim resolve filetype -> parser language
  -- (e.g. typescriptreact -> tsx, javascriptreact -> javascript)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return false end

  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or #trees == 0 then return false end

  -- Use the parser's actual language name for query parsing,
  -- which may differ from the filetype (e.g. typescriptreact -> tsx)
  local parser_lang = parser:lang()
  local root = trees[1]:root()
  local buf_text = util.buf_get_text(bufnr)

  local nodes = collect_nodes(query_strings, parser_lang, root, bufnr)
  emit_nodes(b, nodes, buf_text, 0)

  return true
end

-------------------------------------------------------------------------------
-- Markdown annotation
-------------------------------------------------------------------------------

--- Regex-based comment extraction for code inside markdown fences.
local lang_comment_prefix = {
  bash = "#", sh = "#", zsh = "#", fish = "#", python = "#", ruby = "#",
  perl = "#", r = "#", yaml = "#", toml = "#", dockerfile = "#",
  lua = "%-%-",
  rust = "//", c = "//", cpp = "//", java = "//", javascript = "//",
  typescript = "//", go = "//", swift = "//", kotlin = "//", dart = "//",
  php = "//", csharp = "//", cs = "//",
  sql = "%-%-", haskell = "%-%-", elm = "%-%-",
  latex = "%%", tex = "%%",
  rst = "%.%.", typst = "//",
}

--- Annotate code text from a markdown fence using treesitter or regex fallback.
---@param b table  builder
---@param code_text string
---@param base_byte number
---@param lang string
---@param config table
local function annotate_fenced_code(b, code_text, base_byte, lang, config)
  lang = resolve_lang(lang)

  -- Try treesitter string parser
  local query_strings = queries.get(lang, config.user_queries)
  if query_strings then
    local ok, parser = pcall(vim.treesitter.get_string_parser, code_text, lang)
    if ok and parser then
      local parser_lang = parser:lang()
      local ok2, trees = pcall(parser.parse, parser)
      if ok2 and trees and #trees > 0 then
        local root = trees[1]:root()
        local nodes = collect_nodes(query_strings, parser_lang, root, code_text)
        if #nodes > 0 then
          emit_nodes(b, nodes, code_text, base_byte)
          return
        end
      end
    end
  end

  -- Regex fallback: extract line comments
  local prefix_pattern = lang_comment_prefix[lang] or "[#/][/]?"
  local lines = vim.split(code_text, "\n", { plain = true })
  local byte_pos = 0

  for i, line in ipairs(lines) do
    if i > 1 then
      add_markup(b, "\n", "")
    end
    local full_pattern = "^(%s*" .. prefix_pattern .. "+%s?)(.*)"
    local prefix, content = line:match(full_pattern)
    if prefix and content and vim.trim(content) ~= "" then
      add_markup(b, prefix, "")
      add_text(b, content, base_byte + byte_pos + #prefix)
    else
      add_markup(b, line, "")
    end
    byte_pos = byte_pos + #line + 1
  end
end

--- Detect a fenced code block delimiter (``` or ~~~).
--- Returns the language identifier and fence character on opening fences,
--- or nil if not a fence. Allows up to 3 spaces of indentation per CommonMark.
---@param line string
---@param in_fence boolean
---@param fence_char string|nil  the opening fence character (` or ~), used to match closing
---@return string|nil fence_lang, boolean is_open, string|nil fence_char
local function match_fence(line, in_fence, fence_char)
  if not in_fence then
    -- Capture the full first token of the info string (e.g. "c++", "c#",
    -- "objective-c"), not just its leading word characters.
    local lang = line:match("^%s?%s?%s?```([^%s`]*)")
    if lang then return lang, true, "`" end
    lang = line:match("^%s?%s?%s?~~~(%S*)")
    if lang then return lang, true, "~" end
  else
    local close_char = fence_char == "`" and "`" or "~"
    if line:match("^%s?%s?%s?" .. close_char:rep(3)) then return "", false, nil end
  end
  return nil, false, nil
end

--- True if a line is a GFM table delimiter row, e.g. "| --- | :--: |".
--- Requires a pipe so we don't mistake a thematic break / setext underline
--- ("---") for a table.
---@param line string
---@return boolean
local function is_table_delimiter_row(line)
  if not line:find("|", 1, true) then return false end
  local s = vim.trim(line)
  return s:match("^[|%-:%s]+$") ~= nil and s:find("%-") ~= nil
end

--- True if a line looks like a table row (contains a pipe).
---@param line string
---@return boolean
local function is_table_row(line)
  return line:find("|", 1, true) ~= nil
end

--- Annotate a single table row: pipes and per-cell padding whitespace become
--- markup, only the trimmed cell content becomes text. This stops LanguageTool
--- from flagging alignment whitespace (WHITESPACE_RULE), pipes, and dashes,
--- while still checking the actual cell prose. Each pipe is interpreted as a
--- newline so adjacent cells are checked as separate segments.
---@param b table  builder
---@param line string
---@param base_byte number  buffer byte offset of the line start
local function annotate_table_row(b, line, base_byte)
  local n = #line
  local pos = 1
  while pos <= n do
    if line:sub(pos, pos) == "|" then
      add_markup(b, "|", "\n")
      pos = pos + 1
    else
      local cell_start = pos
      while pos <= n and line:sub(pos, pos) ~= "|" do
        -- Treat an escaped pipe (\|) as cell content, not a boundary.
        if line:sub(pos, pos) == "\\" and line:sub(pos + 1, pos + 1) == "|" then
          pos = pos + 2
        else
          pos = pos + 1
        end
      end
      local cell = line:sub(cell_start, pos - 1)
      local lead = cell:match("^%s*")
      if #lead == #cell then
        -- Whole cell is whitespace (empty cell) — all markup.
        add_markup(b, cell, "")
      else
        local trail = cell:match("%s*$")
        local content = cell:sub(#lead + 1, #cell - #trail)
        if #lead > 0 then add_markup(b, lead, "") end
        add_text(b, content, base_byte + (cell_start - 1) + #lead)
        if #trail > 0 then add_markup(b, trail, "") end
      end
    end
  end
end

--- Build annotation for a markdown buffer using a line-based parser.
--- Fallback for when the `markdown` treesitter parser is unavailable; the
--- treesitter path (annotate_markdown_ts) is preferred and far more accurate.
---@param b table  builder
---@param buf_text string
---@param config table
local function annotate_markdown_regex(b, buf_text, config)
  local lines = vim.split(buf_text, "\n", { plain = true })
  local in_fence = false
  local in_frontmatter = false
  local in_table = false
  local fence_lang = nil
  local fence_char = nil
  local fence_lines = {}
  local fence_content_start = 0
  local byte_pos = 0

  for i, line in ipairs(lines) do
    local line_byte_len = #line + 1

    if i > 1 then
      if in_frontmatter then
        add_markup(b, "\n", "")
      else
        add_markup(b, "\n", "\n")
      end
    end

    -- YAML frontmatter: --- delimited block at start of file
    if i == 1 and line == "---" and config.skip_frontmatter then
      in_frontmatter = true
      add_markup(b, line, "")
      byte_pos = byte_pos + line_byte_len
      goto continue
    end
    if in_frontmatter then
      if line == "---" then
        in_frontmatter = false
        add_markup(b, line, "\n\n")
      else
        add_markup(b, line, "")
      end
      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    local fence_match, is_open, fc = match_fence(line, in_fence, fence_char)
    if fence_match and is_open then
      -- Opening fence delimiter
      add_markup(b, line, "\n\n")
      in_fence = true
      fence_lang = fence_match
      fence_char = fc
      fence_lines = {}
      fence_content_start = byte_pos + line_byte_len
    elseif fence_match and not is_open then
      -- Closing fence delimiter — process accumulated code
      if #fence_lines > 0 and fence_lang and fence_lang ~= "" then
        local code_text = table.concat(fence_lines, "\n")
        annotate_fenced_code(b, code_text, fence_content_start, fence_lang, config)
        -- The \n before closing fence was not added yet
        add_markup(b, "\n", "")
      end
      add_markup(b, line, "\n\n")
      in_fence = false
      fence_char = nil
      fence_lines = {}
    elseif in_fence then
      table.insert(fence_lines, line)
    elseif in_table and is_table_row(line) then
      -- Continuing an open table.
      if is_table_delimiter_row(line) then
        add_markup(b, line, "")
      else
        annotate_table_row(b, line, byte_pos)
      end
    elseif not in_table and is_table_row(line)
      and lines[i + 1] and is_table_delimiter_row(lines[i + 1]) then
      -- Header row: a table row directly followed by a delimiter row starts a table.
      in_table = true
      annotate_table_row(b, line, byte_pos)
    else
      in_table = false
      add_text(b, line, byte_pos)
    end

    byte_pos = byte_pos + line_byte_len
    ::continue::
  end
end

-------------------------------------------------------------------------------
-- Markdown annotation (treesitter)
-------------------------------------------------------------------------------
--
-- Inverts the regex approach: instead of "everything is prose except a few
-- hand-coded structures", walk the tree and mark ONLY genuine prose as text.
-- Prose lives in `inline` nodes and `pipe_table_cell`s; everything else
-- (markers, pipes, delimiter rows, code, HTML, link URLs, emphasis markers,
-- inline code) becomes markup. Inline runs are re-parsed with markdown_inline.

-- Inline node types emitted wholesale as markup. The value is the interpretAs
-- LanguageTool sees in their place. A dropped, space-surrounded element MUST map
-- to a non-empty placeholder word, or the two surrounding spaces collapse into a
-- CONSECUTIVE_SPACES / WHITESPACE_RULE false positive (verified against the API).
local inline_markup_types = {
  code_span = "code",
  uri_autolink = "link",
  email_autolink = "link",
  html_tag = "",
  entity_reference = "",
  numeric_character_reference = "",
  backslash_escape = "",
  emphasis_delimiter = "",
  code_span_delimiter = "",
  hard_line_break = "\n",
  link_destination = "",
  link_title = "",
  link_label = "",
}

-- Inline containers we descend into (their delimiters are markup, text is prose).
local inline_recurse_types = {
  emphasis = true, strong_emphasis = true, strikethrough = true, inline = true,
}

-- Inline link/image nodes: extract the visible label / alt text, hide the rest.
local inline_link_types = {
  inline_link = true, full_reference_link = true,
  collapsed_reference_link = true, shortcut_link = true, image = true,
}

-- Children of a link/image that are prose (visible text / alt text).
local inline_link_text_types = {
  link_text = true, image_description = true,
}

local walk_inline

--- Emit a byte range of `source` (0-based [from, to)) as prose text.
local function emit_inline_prose(b, source, from, to, base_byte)
  if to <= from then return end
  add_text(b, source:sub(from + 1, to), base_byte + from)
end

--- Annotate a markdown link/image: label/alt text as prose, everything else
--- (brackets, parentheses, destination, title, reference label) as markup.
local function annotate_md_link(b, node, source, base_byte, config)
  local _, _, pos = node:start()
  local _, _, node_end = node:end_()
  for child in node:iter_children() do
    local _, _, cs = child:start()
    local _, _, ce = child:end_()
    if cs > pos then
      add_markup(b, source:sub(pos + 1, cs), "")
    end
    if inline_link_text_types[child:type()] then
      walk_inline(b, child, source, base_byte, config)
    else
      add_markup(b, source:sub(cs + 1, ce), "")
    end
    pos = ce
  end
  if pos < node_end then
    add_markup(b, source:sub(pos + 1, node_end), "")
  end
end

--- Walk an inline (markdown_inline) subtree. Text between named children is
--- prose; named children are dispatched by type.
function walk_inline(b, node, source, base_byte, config)
  local _, _, pos = node:start()
  local _, _, node_end = node:end_()
  for child in node:iter_children() do
    local _, _, cs = child:start()
    local _, _, ce = child:end_()
    if cs > pos then
      emit_inline_prose(b, source, pos, cs, base_byte)
    end
    local t = child:type()
    local interp = inline_markup_types[t]
    if interp ~= nil then
      add_markup(b, source:sub(cs + 1, ce), interp)
    elseif inline_link_types[t] then
      annotate_md_link(b, child, source, base_byte, config)
    elseif inline_recurse_types[t] or child:named_child_count() > 0 then
      walk_inline(b, child, source, base_byte, config)
    else
      -- Anonymous leaf token (e.g. sentence punctuation) — prose.
      emit_inline_prose(b, source, cs, ce, base_byte)
    end
    pos = ce
  end
  if pos < node_end then
    emit_inline_prose(b, source, pos, node_end, base_byte)
  end
end

--- Parse a run of inline markdown and annotate prose vs inline markup.
---@param b table
---@param text string  the inline source
---@param base_byte number  buffer byte offset of text[0]
---@param config table
local function annotate_inline_content(b, text, base_byte, config)
  if text == "" then return end
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown_inline")
  if ok and parser then
    local ok2, trees = pcall(parser.parse, parser)
    if ok2 and trees and #trees > 0 then
      walk_inline(b, trees[1]:root(), text, base_byte, config)
      return
    end
  end
  add_text(b, text, base_byte)
end

--- Annotate a table cell: trim alignment padding as markup, inline-check the rest.
local function annotate_table_cell(b, text, base_byte, config)
  local lead = text:match("^%s*")
  if #lead == #text then
    add_markup(b, text, "")
    return
  end
  local trail = text:match("%s*$")
  local content = text:sub(#lead + 1, #text - #trail)
  if #lead > 0 then add_markup(b, lead, "") end
  annotate_inline_content(b, content, base_byte + #lead, config)
  if #trail > 0 then add_markup(b, trail, "") end
end

--- Annotate a fenced code block: fences/info string as markup, the code content
--- handed to the shared code extractor so comments inside are still checked.
local function annotate_fenced_block(b, node, buf_text, config)
  local _, _, node_start = node:start()
  local _, _, node_end = node:end_()

  local lang = ""
  for child in node:iter_children() do
    if child:type() == "info_string" then
      local _, _, is = child:start()
      local _, _, ie = child:end_()
      lang = vim.trim(buf_text:sub(is + 1, ie)):match("^(%S*)") or ""
    end
  end

  local pos = node_start
  for child in node:iter_children() do
    local _, _, cs = child:start()
    local _, _, ce = child:end_()
    if cs > pos then
      add_markup(b, buf_text:sub(pos + 1, cs), "")
    end
    if child:type() == "code_fence_content" and lang ~= "" then
      annotate_fenced_code(b, buf_text:sub(cs + 1, ce), cs, resolve_lang(lang), config)
    else
      add_markup(b, buf_text:sub(cs + 1, ce), "")
    end
    pos = ce
  end
  if pos < node_end then
    add_markup(b, buf_text:sub(pos + 1, node_end), "")
  end
end

local markdown_query = table.concat({
  "(inline) @lt_inline",
  "(pipe_table_cell) @lt_cell",
  "(fenced_code_block) @lt_code",
  "(minus_metadata) @lt_skip",
  "(plus_metadata) @lt_skip",
}, "\n")

--- Build annotation for a markdown buffer using treesitter.
--- Returns false if the markdown parser is unavailable (caller falls back).
---@param b table
---@param bufnr number
---@param config table
---@return boolean success
local function annotate_markdown_ts(b, bufnr, config)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if not ok or not parser then return false end
  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or #trees == 0 then return false end
  local ok3, query = pcall(vim.treesitter.query.parse, "markdown", markdown_query)
  if not ok3 or not query then return false end

  local root = trees[1]:root()
  local buf_text = util.buf_get_text(bufnr)

  -- Collect prose regions (and frontmatter to skip), sorted by position.
  local items = {}
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    local _, _, sb = node:start()
    local _, _, eb = node:end_()
    table.insert(items, { node = node, start_byte = sb, end_byte = eb, capture = query.captures[id] })
  end
  table.sort(items, function(x, y)
    if x.start_byte == y.start_byte then return x.end_byte > y.end_byte end
    return x.start_byte < y.start_byte
  end)

  local pos = 0
  for _, item in ipairs(items) do
    if item.start_byte >= pos then
      -- Gap before this region (markers, pipes, blank lines) → markup, with a
      -- paragraph break so adjacent blocks are checked as separate segments.
      if item.start_byte > pos then
        add_markup(b, buf_text:sub(pos + 1, item.start_byte), "\n\n")
      end
      local text = buf_text:sub(item.start_byte + 1, item.end_byte)
      if item.capture == "lt_inline" then
        annotate_inline_content(b, text, item.start_byte, config)
      elseif item.capture == "lt_cell" then
        annotate_table_cell(b, text, item.start_byte, config)
      elseif item.capture == "lt_code" then
        annotate_fenced_block(b, item.node, buf_text, config)
      else -- lt_skip: frontmatter — never prose
        add_markup(b, text, "")
      end
      pos = item.end_byte
    end
  end
  if pos < #buf_text then
    add_markup(b, buf_text:sub(pos + 1), "")
  end
  return true
end

-------------------------------------------------------------------------------
-- Org-mode annotation
-------------------------------------------------------------------------------

--- Org-mode TODO keywords (treated as markup in headings).
local org_todo_keywords = {
  TODO = true, DONE = true, NEXT = true, WAIT = true, WAITING = true,
  HOLD = true, CANCELLED = true, CANCELED = true,
}

--- Build annotation for an org-mode buffer.
---@param b table  builder
---@param buf_text string
---@param config table
local function annotate_org(b, buf_text, config)
  local lines = vim.split(buf_text, "\n", { plain = true })
  local in_src = false
  local src_lang = nil
  local src_lines = {}
  local src_content_start = 0
  local in_drawer = false
  local byte_pos = 0

  for i, line in ipairs(lines) do
    local line_byte_len = #line + 1
    local lower = line:lower()

    if i > 1 then
      if in_drawer then
        add_markup(b, "\n", "")
      else
        add_markup(b, "\n", "\n")
      end
    end

    -- Source block close
    if in_src and lower:match("^%s*#%+end_src%s*$") then
      if #src_lines > 0 and src_lang and src_lang ~= "" then
        local code_text = table.concat(src_lines, "\n")
        annotate_fenced_code(b, code_text, src_content_start, src_lang, config)
        add_markup(b, "\n", "")
      end
      add_markup(b, line, "\n\n")
      in_src = false
      src_lines = {}
      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    -- Accumulate source block lines
    if in_src then
      table.insert(src_lines, line)
      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    -- Source block open: #+begin_src lang
    if lower:match("^%s*#%+begin_src") then
      add_markup(b, line, "\n\n")
      in_src = true
      src_lang = line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+(%S+)") or ""
      src_lines = {}
      src_content_start = byte_pos + line_byte_len
      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    -- Other blocks (#+begin_example, #+begin_quote, etc.)
    if lower:match("^%s*#%+begin_") then
      add_markup(b, line, "\n\n")
      byte_pos = byte_pos + line_byte_len
      goto continue
    end
    if lower:match("^%s*#%+end_") then
      add_markup(b, line, "\n\n")
      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    -- Drawer open (:PROPERTIES:, :LOGBOOK:, etc.)
    if not in_drawer and line:match("^%s*:[A-Z]+:%s*$") then
      in_drawer = true
      add_markup(b, line, "")
      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    -- Drawer close
    if in_drawer then
      if lower:match("^%s*:end:%s*$") then
        in_drawer = false
      end
      add_markup(b, line, "")
      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    -- Directives (#+title:, #+author:, etc.)
    if line:match("^%s*#%+") then
      add_markup(b, line, "")
      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    -- Comments (# ...)
    if line:match("^%s*#%s") or line:match("^%s*#$") then
      local prefix = line:match("^(%s*#%s?)")
      if prefix then
        add_markup(b, prefix, "")
        local content = line:sub(#prefix + 1)
        if vim.trim(content) ~= "" then
          add_text(b, content, byte_pos + #prefix)
        end
      else
        add_markup(b, line, "")
      end
      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    -- Headings (* TODO [#A] Title :tag1:tag2:)
    local stars = line:match("^(%*+)%s")
    if stars then
      local after_stars = line:sub(#stars + 1)
      add_markup(b, stars, "")

      -- Strip leading space
      local sp = after_stars:match("^(%s+)")
      if sp then
        add_markup(b, sp, "")
        after_stars = after_stars:sub(#sp + 1)
      end

      -- Strip TODO keyword
      local word = after_stars:match("^(%u+)%s")
      if word and org_todo_keywords[word] then
        add_markup(b, word, "")
        after_stars = after_stars:sub(#word + 1)
        local sp2 = after_stars:match("^(%s+)")
        if sp2 then
          add_markup(b, sp2, "")
          after_stars = after_stars:sub(#sp2 + 1)
        end
      end

      -- Strip priority cookie [#A]
      local prio = after_stars:match("^(%[#.%]%s*)")
      if prio then
        add_markup(b, prio, "")
        after_stars = after_stars:sub(#prio + 1)
      end

      -- Strip trailing tags :tag1:tag2:
      local title, tags = after_stars:match("^(.-)(%s+:[%w_@#%%:]+:%s*)$")
      if title and tags then
        if vim.trim(title) ~= "" then
          add_text(b, title, byte_pos + #line - #after_stars)
        end
        add_markup(b, tags, "")
      elseif vim.trim(after_stars) ~= "" then
        add_text(b, after_stars, byte_pos + #line - #after_stars)
      end

      byte_pos = byte_pos + line_byte_len
      goto continue
    end

    -- Regular prose
    add_text(b, line, byte_pos)
    byte_pos = byte_pos + line_byte_len
    ::continue::
  end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Build an AnnotatedText structure from a buffer.
---@param bufnr number
---@param config table
---@return table|nil  { annotation, annotation_map, plain_text } or nil if no extraction possible
function M.build(bufnr, config)
  local ft = vim.bo[bufnr].filetype
  local b = new_builder()

  if ft == "markdown" then
    -- Prefer treesitter; fall back to the line-based parser if the parser is
    -- unavailable (ran == false) or the walk errors (ok == false). On error the
    -- builder may be partly filled, so discard it before falling back.
    local ok, ran = pcall(annotate_markdown_ts, b, bufnr, config)
    if not ok or not ran then
      b = new_builder()
      annotate_markdown_regex(b, util.buf_get_text(bufnr), config)
    end
  elseif ft == "org" then
    local text = util.buf_get_text(bufnr)
    annotate_org(b, text, config)
  elseif not annotate_code_buffer(b, bufnr, ft, config) then
    -- No treesitter queries/parser for this filetype; treat as plain text
    local text = util.buf_get_text(bufnr)
    add_text(b, text, 0)
  end

  local result = finish(b)
  if vim.trim(result.plain_text) == "" then
    return nil
  end
  return result
end

return M
