-- knowledge-builder - Shared UI helpers (nui floats + scratch buffers)
local config = require("knowledge-builder.config")

local ok_nui, NuiPopup = pcall(require, "nui.popup")
if not ok_nui then
  require("knowledge-builder.utils").notify("nui.nvim not found. Install MunifTanjim/nui.nvim", "error")
  return {}
end

local ui = {}

function ui.scratch_buf(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  if opts.filetype then
    vim.bo[bufnr].filetype = opts.filetype
  end
  return bufnr
end

local function dim(value, total, fallback)
  value = value or fallback
  if value >= 1 then
    return math.floor(value)
  end
  return math.floor(total * value)
end

function ui.float(opts)
  opts = opts or {}
  local border = { style = opts.border or config.get("ui.border", "rounded") }
  if opts.title then
    border.text = { top = " " .. opts.title .. " ", top_align = "center" }
  end

  local win = NuiPopup({
    enter = opts.enter ~= false,
    focusable = true,
    relative = "editor",
    position = opts.position or "50%",
    size = {
      width = dim(opts.width, vim.o.columns, 0.6),
      height = dim(opts.height, vim.o.lines, 0.6),
    },
    border = border,
    buf_options = {
      buftype = "nofile",
      bufhidden = "wipe",
      swapfile = false,
      filetype = opts.filetype,
    },
    win_options = {
      wrap = opts.wrap ~= false,
      linebreak = true,
    },
  })
  win:mount()
  return win
end

function ui.set_lines(bufnr, lines, opts)
  opts = opts or {}
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if opts.lock then
    vim.bo[bufnr].modifiable = false
  else
    vim.bo[bufnr].modifiable = was_modifiable
  end
end

function ui.append_lines(bufnr, lines)
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
  vim.bo[bufnr].modifiable = was_modifiable
end

-- Append raw text (possibly multi-line) to the last line of a buffer. Used for
-- streaming tokens into a chat buffer.
function ui.append_text(bufnr, text)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  local last_line = vim.api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ""
  local parts = vim.split(last_line .. text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, last, last + 1, false, parts)
  vim.bo[bufnr].modifiable = was_modifiable
end

function ui.map_close(bufnr, close_fn, keys)
  for _, key in ipairs(keys or { "q", "<Esc>" }) do
    vim.keymap.set("n", key, close_fn, { buffer = bufnr, silent = true, nowait = true })
  end
end

return ui
