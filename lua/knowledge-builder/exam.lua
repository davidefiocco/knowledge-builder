-- knowledge-builder - Interactive exam UI
--
-- Walks the user through a run's questions one at a time. The prompt is shown
-- in a read-only pane (top) and the answer is typed into an editable pane
-- (bottom): a code buffer, a prose buffer, or an MCQ selection.
local assess = require("knowledge-builder.assess")
local config = require("knowledge-builder.config")
local spinner = require("knowledge-builder.spinner")
local ui = require("knowledge-builder.ui")
local utils = require("knowledge-builder.utils")

local ok_layout, NuiLayout = pcall(require, "nui.layout")
local ok_popup, NuiPopup = pcall(require, "nui.popup")

local exam = {}

local state = nil

-- Close the UI. `opts.abandon` marks a run the user walked away from, giving it
-- a terminal status so it stays out of progress and results.
local function teardown(opts)
  opts = opts or {}
  if state and opts.abandon and state.run_id then
    local proj = require("knowledge-builder.project").current()
    if proj then
      require("knowledge-builder.db").abandon_run(proj.db, state.run_id)
    end
  end
  if state and state.layout then
    pcall(function()
      state.layout:unmount()
    end)
  end
  state = nil
end

local function prompt_lines(question, index, total, status)
  local header =
    string.format("Question %d / %d  [%s · %s]", index, total, question.kind, question.difficulty or "medium")
  if status then
    header = header .. "  " .. status
  end
  local lines = {
    header,
    string.rep("-", 50),
    "",
  }
  for _, l in ipairs(utils.split_lines(question.prompt)) do
    table.insert(lines, l)
  end
  if question.kind == "mcq" then
    local payload = assess.decode_payload(question)
    table.insert(lines, "")
    for _, opt in ipairs(payload.options or {}) do
      table.insert(lines, string.format("  %d. %s", opt.number, opt.text))
    end
    table.insert(lines, "")
    table.insert(lines, "(press 1-9 to choose, then submit)")
  end
  return lines
end

local function answer_seed(question)
  if question.kind == "code" then
    return { "# Write your solution below", "" }
  elseif question.kind == "mcq" then
    return { "Answer: " }
  end
  return { "" }
end

-- Persist the text currently in the answer pane for the active question, so it
-- can be restored when the user navigates back.
local function save_current_answer()
  if not state or not state.index then
    return
  end
  state.answers[state.index] = utils.get_buffer_content(state.answer_popup.bufnr)
end

-- A short status badge for a question (graded score, or unanswered).
local function status_for(index)
  local graded = state.grades[index]
  if graded then
    return string.format("✓ graded %d%%", math.floor((graded.score or 0) * 100))
  end
  if state.answers[index] and utils.trim(state.answers[index]) ~= "" then
    return "• answered (not graded)"
  end
  return "○ unanswered"
end

local function answer_filetype(question)
  if question.kind == "code" then
    return "python"
  elseif question.kind == "mcq" then
    return "text"
  end
  return "markdown"
end

local function show_question(index)
  if index < 1 or index > #state.questions then
    return
  end
  -- Preserve whatever the user typed for the question we're leaving (skip when
  -- (re)rendering the same question, e.g. the initial mount).
  if state.rendered and state.index ~= index then
    save_current_answer()
  end

  local q = state.questions[index]
  state.index = index
  state.rendered = true

  ui.set_lines(state.prompt_popup.bufnr, prompt_lines(q, index, #state.questions, status_for(index)), { lock = true })

  vim.bo[state.answer_popup.bufnr].modifiable = true
  vim.bo[state.answer_popup.bufnr].filetype = answer_filetype(q)
  -- Restore the saved answer for this question, or seed a fresh one.
  local saved = state.answers[index]
  if saved ~= nil then
    ui.set_lines(state.answer_popup.bufnr, utils.split_lines(saved))
  else
    ui.set_lines(state.answer_popup.bufnr, answer_seed(q))
  end

  -- Digit shortcuts are scoped to MCQ questions: on a code or open question the
  -- same keys are ordinary input (motion counts), so clear them on the way out.
  for _, key in ipairs(state.digit_keys) do
    pcall(vim.keymap.del, "n", key, { buffer = state.answer_popup.bufnr })
  end
  state.digit_keys = {}

  if q.kind == "mcq" then
    local payload = assess.decode_payload(q)
    for i = 1, math.min(9, #(payload.options or {})) do
      local key = tostring(i)
      vim.keymap.set("n", key, function()
        ui.set_lines(state.answer_popup.bufnr, { "Answer: " .. i })
      end, { buffer = state.answer_popup.bufnr, nowait = true, silent = true })
      table.insert(state.digit_keys, key)
    end
  end

  vim.api.nvim_set_current_win(state.answer_popup.winid)
end

-- Refresh just the prompt header (e.g. after a grade) without resetting the
-- answer pane the user is typing in.
local function refresh_status()
  local q = state.questions[state.index]
  ui.set_lines(
    state.prompt_popup.bufnr,
    prompt_lines(q, state.index, #state.questions, status_for(state.index)),
    { lock = true }
  )
end

-- Move relative to the current question (+1 next, -1 prev). No grading.
local function navigate(delta)
  local target = state.index + delta
  if target < 1 or target > #state.questions then
    utils.notify(delta > 0 and "Already at the last question" or "Already at the first question", "info")
    return
  end
  show_question(target)
end

-- Grade the current question, record it, and update the header. Does NOT
-- advance, so the user stays in control of navigation. callback() runs after a
-- successful grade (used by finish()).
local function grade_current(callback)
  local qi = state.index
  local q = state.questions[qi]
  local answer = utils.get_buffer_content(state.answer_popup.bufnr)
  state.answers[qi] = answer

  local handle = spinner.start("Grading answer")
  assess.grade(q, answer, function(result, err)
    handle:cancel()
    if err then
      utils.notify("Grading failed: " .. err, "error")
      return
    end
    result.answer = answer
    assess.record(state.run_id, q, result)
    if not state then
      return
    end
    state.grades[qi] = result

    local pct = math.floor((result.score or 0) * 100)
    utils.notify(string.format("Q%d: %d%% — %s", qi, pct, result.feedback or ""))
    -- Only repaint the header if the graded question is still on screen.
    if state.index == qi then
      refresh_status()
    end
    if callback then
      callback()
    end
  end)
end

local function submit_current()
  grade_current()
end

-- Count how many questions still lack a grade.
local function ungraded_indices()
  local pending = {}
  for i = 1, #state.questions do
    if not state.grades[i] then
      table.insert(pending, i)
    end
  end
  return pending
end

-- End the run: grade any answered-but-ungraded questions, then finalize.
-- Unanswered questions are graded too (they score 0 against an empty answer).
local function finish_run()
  save_current_answer()
  local pending = ungraded_indices()
  -- Grading is async, so hold the identifiers locally: the UI may be torn down
  -- (or replaced) before the last callback lands.
  local run_id = state.run_id

  local function done()
    local levels = assess.finalize(run_id)
    teardown()
    require("knowledge-builder.progress").show_run_summary(run_id, levels)
  end

  if #pending == 0 then
    done()
    return
  end

  -- Grade the remaining answers with the same in-flight cap the generation
  -- phase uses: 1 keeps local single-instance backends happy, higher values let
  -- a hosted API finish a long test far faster.
  local handle = spinner.start("Grading remaining answers", { total = #pending })
  local max_concurrency = math.max(1, config.get("assess.max_concurrency", 1))
  local next_pending, completed, active = 1, 0, 0
  local launch

  local function on_graded(qi)
    active = active - 1
    completed = completed + 1
    handle.completed = completed
    handle:update("Q" .. qi)
    if completed == #pending then
      handle:finish()
      done()
      return
    end
    launch()
  end

  launch = function()
    while active < max_concurrency and next_pending <= #pending do
      local qi = pending[next_pending]
      next_pending = next_pending + 1
      active = active + 1
      local q = state.questions[qi]
      local answer = state.answers[qi] or ""
      assess.grade(q, answer, function(result, err)
        if not err and result then
          result.answer = answer
          assess.record(run_id, q, result)
          if state then
            state.grades[qi] = result
          end
        end
        on_graded(qi)
      end)
    end
  end
  launch()
end

local function setup_keymaps()
  local km = config.get("keymaps.exam", {})
  for _, bufnr in ipairs({ state.answer_popup.bufnr, state.prompt_popup.bufnr }) do
    vim.keymap.set({ "n", "i" }, km.submit or "<C-s>", function()
      submit_current()
    end, { buffer = bufnr, silent = true })
    vim.keymap.set({ "n", "i" }, km.next_question or "<C-n>", function()
      navigate(1)
    end, { buffer = bufnr, silent = true })
    vim.keymap.set({ "n", "i" }, km.prev_question or "<C-p>", function()
      navigate(-1)
    end, { buffer = bufnr, silent = true })
    vim.keymap.set({ "n", "i" }, km.finish or "<C-f>", function()
      finish_run()
    end, { buffer = bufnr, silent = true })
    vim.keymap.set("n", km.close or "q", function()
      teardown({ abandon = true })
    end, { buffer = bufnr, silent = true, nowait = true })
    vim.keymap.set("n", km.hint or "<C-g>", function()
      exam.show_hint()
    end, { buffer = bufnr, silent = true })
  end
end

function exam.show_hint()
  local q = state and state.questions[state.index]
  if not q then
    return
  end
  local llm = require("knowledge-builder.llm")
  -- The MCQ answer pane only ever holds "Answer: N", which is noise for a hint,
  -- so only forward the current attempt for free-text (code/open) questions.
  local attempt = q.kind ~= "mcq" and utils.get_buffer_content(state.answer_popup.bufnr) or ""
  local user = "## Question\n" .. q.prompt
  if utils.trim(attempt) ~= "" then
    user = user .. "\n\n## Current attempt\n" .. attempt
  end
  local handle = spinner.start("Generating hint")
  llm.chat({
    { role = "system", content = "You are a tutor. Give one short, non-revealing hint. Do NOT give the answer." },
    { role = "user", content = user },
  }, function(hint, err)
    handle:cancel()
    if err then
      utils.notify("Hint failed: " .. err, "error")
      return
    end
    utils.notify("Hint: " .. (hint or ""))
  end)
end

-- Open the exam UI for an already-started run.
function exam.open(run)
  if not (ok_layout and ok_popup) then
    utils.notify("nui.nvim layout not available", "error")
    return
  end
  teardown()

  local prompt_popup = NuiPopup({
    border = { style = config.get("ui.border"), text = { top = " Question " } },
    buf_options = { modifiable = false, filetype = "markdown" },
    win_options = { wrap = true, linebreak = true },
  })
  local answer_popup = NuiPopup({
    enter = true,
    border = {
      style = config.get("ui.border"),
      text = { top = " Answer  (C-s grade · C-n/C-p nav · C-g hint · C-f finish) " },
    },
    buf_options = { modifiable = true },
    win_options = { wrap = true, linebreak = true },
  })

  local layout = NuiLayout(
    {
      relative = "editor",
      position = "50%",
      size = { width = "85%", height = "85%" },
    },
    NuiLayout.Box({
      NuiLayout.Box(prompt_popup, { size = "50%" }),
      NuiLayout.Box(answer_popup, { size = "50%" }),
    }, { dir = "col" })
  )
  layout:mount()

  state = {
    layout = layout,
    prompt_popup = prompt_popup,
    answer_popup = answer_popup,
    run_id = run.id,
    questions = run.questions,
    index = 1,
    answers = {},
    grades = {},
    digit_keys = {},
  }

  setup_keymaps()
  show_question(1)

  if run.errors and #run.errors > 0 then
    utils.notify("Some topics failed to generate: " .. table.concat(run.errors, "; "), "warn")
  end
end

-- Convenience: start a run for a phase and open the UI.
function exam.run(phase)
  local handle
  assess.start_run(phase, {
    on_start = function(total)
      handle = spinner.start("Generating " .. phase .. " questions", { total = total })
    end,
    on_progress = function(completed, _total, topic_name)
      if handle then
        handle.completed = completed
        handle:update(topic_name)
      end
    end,
  }, function(run, err)
    if handle then
      if err then
        handle:cancel()
      else
        handle:finish()
      end
    end
    if err then
      utils.notify(err, "error")
      return
    end
    exam.open(run)
  end)
end

-- Internal hooks for headless tests (navigation/grading without keypresses).
exam._test = {
  state = function()
    return state
  end,
  navigate = function(delta)
    navigate(delta)
  end,
  submit = function()
    submit_current()
  end,
  finish = function()
    finish_run()
  end,
  set_answer = function(text)
    ui.set_lines(state.answer_popup.bufnr, utils.split_lines(text))
  end,
  close = function()
    teardown({ abandon = true })
  end,
}

return exam
