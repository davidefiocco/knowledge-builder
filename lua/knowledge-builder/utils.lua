-- knowledge-builder - Utility Functions
local utils = {}

function utils.notify(msg, level)
  level = level or "info"
  vim.notify("[knowledge-builder] " .. msg, vim.log.levels[level:upper()])
end

function utils.trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return s:match("^%s*(.-)%s*$")
end

function utils.split_lines(str)
  return vim.split(str or "", "\n", { plain = true })
end

function utils.get_buffer_content(bufnr)
  bufnr = bufnr or 0
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function utils.json_decode(str)
  local ok, result = pcall(vim.json.decode, str)
  if ok then
    return result
  end
  return nil, result
end

function utils.json_encode(value)
  return vim.json.encode(value)
end

-- Models often wrap JSON in ```json ... ``` fences or add prose. Pull out the
-- first balanced JSON object/array so structured parsing is robust.
function utils.extract_json(text)
  if type(text) ~= "string" then
    return nil
  end
  local fenced = text:match("```json%s*(.-)%s*```") or text:match("```%s*(.-)%s*```")
  if fenced then
    local decoded = utils.json_decode(fenced)
    if decoded ~= nil then
      return decoded
    end
  end

  local first = text:find("[%[{]")
  if not first then
    return nil
  end
  local open_char = text:sub(first, first)
  local close_char = open_char == "{" and "}" or "]"
  local depth, in_str, escaped = 0, false, false
  for i = first, #text do
    local c = text:sub(i, i)
    if in_str then
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        in_str = false
      end
    else
      if c == '"' then
        in_str = true
      elseif c == open_char then
        depth = depth + 1
      elseif c == close_char then
        depth = depth - 1
        if depth == 0 then
          return utils.json_decode(text:sub(first, i))
        end
      end
    end
  end
  return nil
end

function utils.slugify(name)
  local slug = (name or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    slug = "project-" .. os.time()
  end
  return slug
end

-- Convert a table keyed by integer ids into one keyed by string ids. This
-- prevents vim.json.encode from emitting a sparse array padded with nulls when
-- the keys are non-contiguous integers (e.g. topic ids).
function utils.stringify_keys(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do
    out[tostring(k)] = v
  end
  return out
end

function utils.round(value, decimals)
  decimals = decimals or 2
  local mult = 10 ^ decimals
  return math.floor((value or 0) * mult + 0.5) / mult
end

function utils.close_win(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
end

return utils
