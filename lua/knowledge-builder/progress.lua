-- knowledge-builder - Progress tracking & you-vs-past-self comparison
local db = require("knowledge-builder.db")
local project = require("knowledge-builder.project")
local ui = require("knowledge-builder.ui")
local utils = require("knowledge-builder.utils")

local progress = {}

local function bar(score)
  local filled = math.floor((score or 0) * 10 + 0.5)
  return string.rep("#", filled) .. string.rep(".", 10 - filled)
end

local function fmt_delta(delta)
  if delta == nil then
    return "  (new)"
  end
  local pct = utils.round(delta * 100, 0)
  if pct > 0 then
    return string.format(" +%d%%", pct)
  elseif pct < 0 then
    return string.format(" %d%%", pct)
  end
  return "  +0%"
end

-- Per-topic score series across every completed run, oldest first.
-- Returns { [topic_id] = { score, ... } }.
local function history_for(db_path)
  local series = {}
  for _, row in ipairs(db.get_level_history(db_path)) do
    series[row.topic_id] = series[row.topic_id] or {}
    table.insert(series[row.topic_id], row.score)
  end
  return series
end

function progress.history()
  local proj = project.require_current()
  return proj and history_for(proj.db) or {}
end

-- Compute per-topic levels for a run alongside the previous completed run's
-- levels. Returns a list of { topic, score, prev, delta, series }.
function progress.compute(run_id)
  local proj = project.require_current()
  if not proj then
    return {}
  end
  local topics = db.get_topics(proj.db)

  local current = {}
  for _, lvl in ipairs(db.get_levels(proj.db, run_id)) do
    current[lvl.topic_id] = lvl.score
  end
  local previous = db.get_latest_levels(proj.db, run_id)
  local series = history_for(proj.db)

  local rows = {}
  for _, t in ipairs(topics) do
    local score = current[t.id]
    if score ~= nil then
      local prev = previous[t.id]
      table.insert(rows, {
        topic = t.name,
        topic_id = t.id,
        score = score,
        prev = prev,
        delta = prev ~= nil and utils.round(score - prev, 3) or nil,
        series = series[t.id],
      })
    end
  end
  return rows
end

-- Active topics ordered weakest-first, so review can lead with what needs it.
-- `level` is nil for a topic that has never been tested.
-- Sort key treats untested topics as mid-pack, then weights by topic weight so
-- a central topic outranks a peripheral one at the same score.
function progress.weak_topics()
  local proj = project.require_current()
  if not proj then
    return {}
  end
  local latest = db.get_latest_levels(proj.db)
  local rows = {}
  for _, t in ipairs(db.get_topics(proj.db)) do
    local level = latest[t.id]
    table.insert(rows, {
      topic = t,
      level = level,
      priority = (1 - (level or 0.5)) * (t.weight or 1.0),
    })
  end
  table.sort(rows, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return (a.topic.position or 0) < (b.topic.position or 0)
  end)
  return rows
end

local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

-- Render a score series (each 0..1) as a compact sparkline.
local function sparkline(series)
  if not series or #series == 0 then
    return ""
  end
  local out = {}
  for _, s in ipairs(series) do
    local idx = math.floor(math.max(0, math.min(1, s or 0)) * (#SPARK - 1) + 0.5) + 1
    table.insert(out, SPARK[idx])
  end
  return table.concat(out)
end

local function render(rows, title)
  local lines = { "", "  " .. title, "" }
  if #rows == 0 then
    table.insert(lines, "  No completed runs yet.")
  end
  local has_trend = false
  for _, r in ipairs(rows) do
    if r.series and #r.series > 1 then
      has_trend = true
    end
    table.insert(
      lines,
      string.format(
        "  %-28s [%s] %3d%%%s  %s",
        r.topic:sub(1, 28),
        bar(r.score),
        math.floor(r.score * 100 + 0.5),
        fmt_delta(r.delta),
        sparkline(r.series)
      )
    )
  end
  if has_trend then
    table.insert(lines, "")
    table.insert(lines, "  Trailing column: every completed run, oldest to newest.")
  end
  table.insert(lines, "")
  table.insert(lines, "  (q to close)")
  return lines
end

-- Shown automatically after finishing an exam run.
function progress.show_run_summary(run_id, _levels)
  local rows = run_id and progress.compute(run_id) or {}
  local win = ui.float({ width = 0.6, height = 0.5, title = "Run complete" })
  ui.set_lines(win.bufnr, render(rows, "Results vs. your previous run"), { lock = true })
  ui.map_close(win.bufnr, function()
    win:unmount()
  end)
end

-- Build a per-question grading report for a run, grouped by topic. Returns
-- { run = {...}, topics = { { name, questions = { {...} } } }, overall = pct }.
function progress.build_report(run_id)
  local proj = project.require_current()
  if not proj then
    return nil, "No active project"
  end
  local runs = db.get_runs(proj.db)
  local run
  for _, r in ipairs(runs) do
    if r.id == run_id then
      run = r
    end
  end
  if not run then
    return nil, "Run " .. tostring(run_id) .. " not found"
  end

  -- Include archived topics: a run predating a syllabus refine can still
  -- reference topics that have since been dropped.
  local topic_name, topic_weight = {}, {}
  for _, t in ipairs(db.get_topics(proj.db, { include_archived = true })) do
    topic_name[t.id] = t.name
    topic_weight[t.id] = t.weight or 1.0
  end

  local resp_by_q = {}
  for _, r in ipairs(db.get_responses(proj.db, run_id)) do
    resp_by_q[r.question_id] = r
  end

  local groups, order = {}, {}
  -- The overall figure is weighted by topic weight, so a topic the syllabus
  -- marks as central counts for more than a peripheral one.
  local weighted_score, weight_total, graded_count = 0, 0, 0
  for _, q in ipairs(db.get_questions(proj.db, run_id)) do
    local tname = topic_name[q.topic_id] or "(unknown topic)"
    if not groups[tname] then
      groups[tname] = {}
      table.insert(order, tname)
    end
    local r = resp_by_q[q.id]
    if r and r.score ~= nil then
      local w = topic_weight[q.topic_id] or 1.0
      weighted_score = weighted_score + r.score * w
      weight_total = weight_total + w
      graded_count = graded_count + 1
    end
    table.insert(groups[tname], {
      kind = q.kind,
      difficulty = q.difficulty,
      prompt = q.prompt,
      reference = q.reference,
      answer = r and r.answer or nil,
      score = r and r.score or nil,
      passed = r and (r.passed == 1 or r.passed == true) or false,
      feedback = r and r.llm_feedback or nil,
      graded = r ~= nil and r.score ~= nil,
    })
  end

  local topics = {}
  for _, name in ipairs(order) do
    table.insert(topics, { name = name, questions = groups[name] })
  end

  return {
    run = run,
    topics = topics,
    overall = weight_total > 0 and (weighted_score / weight_total) or nil,
    graded_count = graded_count,
  }
end

local function render_report(report)
  local run = report.run
  local lines = {
    "",
    string.format("  %s run #%d  (%s)", run.phase, run.id, run.status),
  }
  if report.overall ~= nil then
    table.insert(
      lines,
      string.format(
        "  Overall: %d%%  (weighted) across %d graded question(s)",
        math.floor(report.overall * 100 + 0.5),
        report.graded_count
      )
    )
  end
  table.insert(lines, "  " .. string.rep("=", 60))

  for _, topic in ipairs(report.topics) do
    table.insert(lines, "")
    table.insert(lines, "  ## " .. topic.name)
    for i, q in ipairs(topic.questions) do
      local badge
      if not q.graded then
        badge = "—  not graded"
      else
        badge = string.format("%s %d%%", q.passed and "PASS" or "FAIL", math.floor((q.score or 0) * 100 + 0.5))
      end
      table.insert(lines, "")
      table.insert(lines, string.format("  Q%d [%s · %s]  %s", i, q.kind, q.difficulty or "medium", badge))
      for _, l in ipairs(utils.split_lines(q.prompt or "")) do
        table.insert(lines, "    " .. l)
      end
      if q.answer and utils.trim(q.answer) ~= "" then
        table.insert(lines, "    Your answer:")
        for _, l in ipairs(utils.split_lines(q.answer)) do
          table.insert(lines, "      " .. l)
        end
      else
        table.insert(lines, "    Your answer: (blank)")
      end
      if q.feedback and utils.trim(q.feedback) ~= "" then
        table.insert(lines, "    Feedback: " .. q.feedback)
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  (q to close)")
  return lines
end

-- Show the per-question grading report for a run in a scrollable float.
function progress.show_results(run_id)
  local report, e = progress.build_report(run_id)
  if not report then
    utils.notify(e or "No report", "warn")
    return
  end
  local win = ui.float({ width = 0.7, height = 0.7, title = "Results: run #" .. report.run.id })
  ui.set_lines(win.bufnr, render_report(report), { lock = true })
  ui.map_close(win.bufnr, function()
    win:unmount()
  end)
end

-- Return completed runs (most recent first) for selection.
function progress.completed_runs()
  local proj = project.require_current()
  if not proj then
    return {}
  end
  local runs = db.get_runs(proj.db)
  local completed = {}
  for i = #runs, 1, -1 do
    if runs[i].status == "completed" then
      table.insert(completed, runs[i])
    end
  end
  return completed
end

-- :KB progress — most recent completed run vs. the one before it.
function progress.show()
  local proj = project.require_current()
  if not proj then
    return
  end
  local runs = db.get_runs(proj.db)
  local last_completed
  for i = #runs, 1, -1 do
    if runs[i].status == "completed" then
      last_completed = runs[i]
      break
    end
  end

  local rows = last_completed and progress.compute(last_completed.id) or {}
  local title = last_completed and ("Latest " .. last_completed.phase .. " run vs. previous") or "Progress"
  local win = ui.float({ width = 0.6, height = 0.5, title = "Progress: " .. proj.name })
  ui.set_lines(win.bufnr, render(rows, title), { lock = true })
  ui.map_close(win.bufnr, function()
    win:unmount()
  end)
end

return progress
