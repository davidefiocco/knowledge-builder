-- knowledge-builder - Lightweight progress indicators for long LLM phases
--
-- Two flavours, both rendered in-place on the command line via nvim_echo so
-- they don't flood the message history:
--   * indeterminate spinner  -> for single unbounded LLM calls (syllabus,
--     grading, review, hints); shows an animated frame + elapsed seconds.
--   * determinate bar         -> for multi-step phases with a known total
--     (question generation across N topics); shows [====    ] done/total.
--
-- Usage:
--   local p = spinner.start("Building syllabus")          -- spinner
--   ... later ...
--   p:finish("Syllabus ready: 6 topics")                  -- or p:cancel()
--
--   local p = spinner.start("Generating questions", { total = 6 })
--   p:step("Algorithms")   -- advance by one, optional label
--   p:finish("Questions ready")
local spinner = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local INTERVAL_MS = 100
local BAR_WIDTH = 20

local Handle = {}
Handle.__index = Handle

local function now_ms()
  return (vim.uv or vim.loop).now()
end

local function echo(chunks)
  -- false => don't add to :messages history; we overwrite the cmdline live.
  vim.api.nvim_echo(chunks, false, {})
end

local function clear_cmdline()
  vim.api.nvim_echo({ { "" } }, false, {})
end

function Handle:_render()
  if self.done then
    return
  end
  local elapsed = math.floor((now_ms() - self.start_ms) / 1000)
  local prefix = "[knowledge-builder] "
  local body

  if self.total then
    local ratio = self.total > 0 and (self.completed / self.total) or 0
    local filled = math.floor(ratio * BAR_WIDTH + 0.5)
    local bar = string.rep("=", filled) .. string.rep(" ", BAR_WIDTH - filled)
    body = string.format(
      "%s [%s] %d/%d%s (%ds)",
      self.label,
      bar,
      self.completed,
      self.total,
      self.detail and (" - " .. self.detail) or "",
      elapsed
    )
  else
    local frame = FRAMES[self.frame_idx]
    body = string.format("%s %s%s (%ds)", frame, self.label, self.detail and (" - " .. self.detail) or "", elapsed)
  end

  echo({ { prefix, "Comment" }, { body, "None" } })
end

function Handle:_tick()
  self.frame_idx = (self.frame_idx % #FRAMES) + 1
  self:_render()
end

-- Advance a determinate bar by `n` (default 1), with an optional detail label.
function Handle:step(detail, n)
  self.completed = self.completed + (n or 1)
  if detail ~= nil then
    self.detail = detail
  end
  self:_render()
end

-- Update the trailing detail text without advancing.
function Handle:update(detail)
  self.detail = detail
  self:_render()
end

function Handle:_stop()
  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end
  self.done = true
end

-- Stop the indicator and emit a final success notification.
function Handle:finish(msg, level)
  self:_stop()
  clear_cmdline()
  if msg then
    require("knowledge-builder.utils").notify(msg, level or "info")
  end
end

-- Stop the indicator without a success message (e.g. on error/abort).
function Handle:cancel()
  self:_stop()
  clear_cmdline()
end

-- Start an indicator. opts.total makes it a determinate bar; otherwise a
-- spinner. Returns a Handle.
function spinner.start(label, opts)
  opts = opts or {}
  local self = setmetatable({
    label = label or "Working",
    total = opts.total,
    completed = opts.completed or 0,
    detail = opts.detail,
    start_ms = now_ms(),
    frame_idx = 1,
    done = false,
  }, Handle)

  self:_render()

  -- Animate only the spinner; the bar advances on explicit step() calls but we
  -- still tick it so the elapsed counter moves.
  self.timer = (vim.uv or vim.loop).new_timer()
  self.timer:start(
    INTERVAL_MS,
    INTERVAL_MS,
    vim.schedule_wrap(function()
      if not self.done then
        self:_tick()
      end
    end)
  )

  return self
end

return spinner
