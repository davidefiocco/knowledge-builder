-- knowledge-builder - Streaming tutor chat buffer
--
-- A scratch buffer where the user converses with a tutor LLM. Responses stream
-- token-by-token. An optional system context (e.g. the topic being reviewed)
-- grounds the tutor.
local config = require("knowledge-builder.config")
local llm = require("knowledge-builder.llm")
local ui = require("knowledge-builder.ui")
local utils = require("knowledge-builder.utils")

local chat = {}

local state = nil

local PROMPT_MARK = "> "

local function default_system(context)
  local base = "You are a patient, concise tutor. Explain clearly, use small examples, "
    .. "and check understanding. Keep answers focused."
  if context and context ~= "" then
    base = base .. "\n\nThe student is currently reviewing:\n" .. context
  end
  return base
end

local function append(lines)
  ui.append_lines(state.bufnr, lines)
  if vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), 0 })
  end
end

local function start_input()
  append({ "", PROMPT_MARK })
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), #PROMPT_MARK })
  vim.cmd("startinsert!")
end

-- Read the user's typed message: everything after the last prompt marker.
local function read_pending_input()
  local total = vim.api.nvim_buf_line_count(state.bufnr)
  local collected = {}
  for i = total, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(state.bufnr, i - 1, i, false)[1] or ""
    if line:sub(1, #PROMPT_MARK) == PROMPT_MARK then
      table.insert(collected, 1, line:sub(#PROMPT_MARK + 1))
      break
    end
    table.insert(collected, 1, line)
  end
  return utils.trim(table.concat(collected, "\n"))
end

-- The transcript the model sees: the system prompt plus the most recent turns.
-- The full history stays in state.messages for the buffer; only what we send is
-- trimmed, so a long session can't creep past the context window.
local function payload_messages()
  local max_turns = config.get("chat.max_history_messages", 20)
  local system = state.messages[1]
  local turns = {}
  for i = 2, #state.messages do
    table.insert(turns, state.messages[i])
  end
  if #turns <= max_turns then
    return state.messages
  end
  local trimmed = { system }
  for i = #turns - max_turns + 1, #turns do
    table.insert(trimmed, turns[i])
  end
  return trimmed
end

local function send()
  if state.streaming then
    return
  end
  local message = read_pending_input()
  if message == "" then
    return
  end
  vim.cmd("stopinsert")
  table.insert(state.messages, { role = "user", content = message })

  -- Show an ephemeral placeholder on its own line; the first streamed token
  -- (or an error) replaces it.
  append({ "", "Thinking..." })
  vim.bo[state.bufnr].modifiable = false
  state.streaming = true

  local acc = {}
  local placeholder_active = true

  local function clear_placeholder()
    if not placeholder_active then
      return
    end
    placeholder_active = false
    if vim.api.nvim_buf_is_valid(state.bufnr) then
      local last = vim.api.nvim_buf_line_count(state.bufnr) - 1
      local was_modifiable = vim.bo[state.bufnr].modifiable
      vim.bo[state.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(state.bufnr, last, last + 1, false, { "" })
      vim.bo[state.bufnr].modifiable = was_modifiable
    end
  end

  llm.stream(payload_messages(), {}, function(token)
    clear_placeholder()
    table.insert(acc, token)
    ui.append_text(state.bufnr, token)
    if vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), 0 })
    end
  end, function(full, err)
    state.streaming = false
    if err then
      clear_placeholder()
      append({ "[error: " .. err .. "]" })
    else
      -- A reply with zero tokens (rare) still needs the placeholder gone.
      clear_placeholder()
      table.insert(state.messages, { role = "assistant", content = full or table.concat(acc) })
    end
    start_input()
  end)
end

-- Open a tutor chat. opts = { context = "...", title = "..." }
function chat.open(opts)
  opts = opts or {}
  local win = ui.float({
    width = config.get("ui.width"),
    height = config.get("ui.height"),
    title = opts.title or "Tutor",
    filetype = "markdown",
  })

  state = {
    bufnr = win.bufnr,
    winid = win.winid,
    win = win,
    messages = { { role = "system", content = default_system(opts.context) } },
    streaming = false,
  }

  local km = config.get("keymaps.chat", {})
  vim.keymap.set({ "n", "i" }, km.send or "<C-s>", send, { buffer = state.bufnr, silent = true })
  vim.keymap.set("n", km.close or "q", function()
    win:unmount()
    state = nil
  end, { buffer = state.bufnr, silent = true, nowait = true })

  -- The context can be several lines (weak topics, recent mistakes), and
  -- nvim_buf_set_lines rejects embedded newlines, so split it.
  local header = { "# Tutor", "" }
  if opts.context and opts.context ~= "" then
    table.insert(header, "The tutor has been briefed on:")
    for _, line in ipairs(utils.split_lines(opts.context)) do
      table.insert(header, "  " .. line)
    end
  else
    table.insert(header, "Ask anything. Send with Ctrl-s.")
  end
  table.insert(header, "")
  ui.set_lines(state.bufnr, header)
  start_input()
end

-- Internal hooks for headless tests.
chat._test = {
  state = function()
    return state
  end,
  send = function()
    send()
  end,
}

return chat
