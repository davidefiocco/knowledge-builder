-- knowledge-builder - Headless scriptable API
--
-- UI-independent entry points returning plain JSON-serializable tables, so the
-- whole test flow can be driven over RPC from tests (pynvim) or other
-- automation. The interactive UI (exam.lua) is a parallel consumer of the same
-- assess.lua engine.
local assess = require("knowledge-builder.assess")
local db = require("knowledge-builder.db")
local project = require("knowledge-builder.project")
local syllabus = require("knowledge-builder.syllabus")
local utils = require("knowledge-builder.utils")

local api = {}

-- Active headless run state (separate from the interactive exam state).
local run_state = nil

local function err(msg)
  return { ok = false, error = msg }
end

-- Create or open a project. opts = { name, slug?, source_inputs? }
function api.create_project(opts)
  opts = opts or {}
  if not opts.name or opts.name == "" then
    return err("name required")
  end
  local proj, e = project.create(opts.name, opts)
  if not proj then
    return err(e)
  end
  return { ok = true, slug = proj.slug, dir = proj.dir }
end

function api.open_project(slug)
  local proj, e = project.open(slug)
  if not proj then
    return err(e)
  end
  return { ok = true, slug = proj.slug, name = proj.name }
end

function api.list_projects()
  return { ok = true, projects = project.list() }
end

-- Build the syllabus, blocking on the async LLM call via vim.wait. Returns
-- { ok, topics } or { ok = false, error }.
function api.build_syllabus(source_inputs, timeout_ms)
  local done, result = false, nil
  syllabus.build_and_save(source_inputs, function(topics, e)
    result = topics and { ok = true, topics = topics } or err(e)
    done = true
  end)
  vim.wait(timeout_ms or 60000, function()
    return done
  end, 50)
  if not done then
    return err("timeout building syllabus")
  end
  return result
end

function api.get_syllabus()
  local proj = project.current()
  if not proj then
    return err("no active project")
  end
  return { ok = true, topics = db.get_topics(proj.db) }
end

-- Directly set topics (useful for deterministic tests that skip the LLM).
function api.set_syllabus(topics)
  if not project.current() then
    return err("no active project")
  end
  local ok = project.save_syllabus(topics)
  return ok and { ok = true } or err("failed to save syllabus")
end

-- Start a run, generating questions via the LLM. `phase` defaults to "test";
-- it is kept as a parameter so callers can label runs (e.g. tests inject "test").
function api.start_run(phase, timeout_ms)
  local done, result = false, nil
  assess.start_run(phase or "test", function(run, e)
    if run then
      run_state = { id = run.id, questions = run.questions, index = 1 }
      result = { ok = true, run_id = run.id, total = #run.questions }
    else
      result = err(e)
    end
    done = true
  end)
  vim.wait(timeout_ms or 120000, function()
    return done
  end, 50)
  if not done then
    return err("timeout starting run")
  end
  return result
end

-- Inject a pre-built run (deterministic tests): questions is a list of
-- { topic_id, kind, prompt, reference, difficulty, payload }.
function api.inject_run(phase, questions)
  local proj = project.current()
  if not proj then
    return err("no active project")
  end
  local run_id = db.create_run(proj.db, phase or "test")
  for i, q in ipairs(questions) do
    q.position = i
    db.add_question(proj.db, run_id, q)
  end
  local stored = db.get_questions(proj.db, run_id)
  run_state = { id = run_id, questions = stored, index = 1 }
  return { ok = true, run_id = run_id, total = #stored }
end

-- Return the current pending question as plain data (or nil when finished).
function api.get_current_question()
  if not run_state then
    return err("no active run")
  end
  local q = run_state.questions[run_state.index]
  if not q then
    return { ok = true, done = true }
  end
  return {
    ok = true,
    done = false,
    index = run_state.index,
    total = #run_state.questions,
    question = {
      id = q.id,
      kind = q.kind,
      difficulty = q.difficulty,
      prompt = q.prompt,
      topic_id = q.topic_id,
      payload = assess.decode_payload(q),
    },
  }
end

-- Grade + record the answer for the current question, advance, and return the
-- grading result plus whether the run is finished after the advance.
function api.submit_answer(answer, timeout_ms)
  if not run_state then
    return err("no active run")
  end
  local q = run_state.questions[run_state.index]
  if not q then
    return err("no current question")
  end

  local done, result = false, nil
  assess.grade(q, answer, function(graded, e)
    if e then
      result = err(e)
    else
      graded.answer = answer
      assess.record(run_state.id, q, graded)
      result = {
        ok = true,
        score = graded.score,
        passed = graded.passed,
        feedback = graded.feedback,
      }
    end
    done = true
  end)
  vim.wait(timeout_ms or 60000, function()
    return done
  end, 50)
  if not done then
    return err("timeout grading answer")
  end

  run_state.index = run_state.index + 1
  result.run_finished = run_state.questions[run_state.index] == nil
  return result
end

-- Finalize the current run: compute levels, mark complete, return summary.
function api.finalize_run()
  if not run_state then
    return err("no active run")
  end
  local levels = assess.finalize(run_state.id)
  local rows = require("knowledge-builder.progress").compute(run_state.id)
  local run_id = run_state.id
  run_state = nil
  -- String-key the levels map so it serializes as a JSON object, not a sparse
  -- array padded with nulls (topic ids are non-contiguous integers).
  return { ok = true, run_id = run_id, levels = utils.stringify_keys(levels), progress = rows }
end

-- Per-question grading report for a completed run (UI-independent).
function api.get_run_report(run_id)
  if not project.current() then
    return err("no active project")
  end
  if not run_id then
    return err("run_id required")
  end
  local report, e = require("knowledge-builder.progress").build_report(run_id)
  if not report then
    return err(e)
  end
  return { ok = true, report = report }
end

-- JSON helpers so callers over RPC can request a string directly.
function api.get_current_question_json()
  return utils.json_encode(api.get_current_question())
end

function api.submit_answer_json(answer)
  return utils.json_encode(api.submit_answer(answer))
end

return api
