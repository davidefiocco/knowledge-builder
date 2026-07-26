-- knowledge-builder - Test run engine
--
-- This module is UI-agnostic: it generates questions for the active project's
-- syllabus, records answers, grades them via the LLM, and computes per-topic
-- levels. exam.lua (interactive) and api.lua (headless) both drive it.
local config = require("knowledge-builder.config")
local db = require("knowledge-builder.db")
local llm = require("knowledge-builder.llm")
local project = require("knowledge-builder.project")
local utils = require("knowledge-builder.utils")

local assess = {}

local GEN_SYSTEM_PROMPT = table.concat({
  "You are an examiner. Generate assessment questions for a specific topic.",
  "Return ONLY a JSON array, no prose or fences. Each element:",
  "{",
  '  "kind": "code" | "open" | "mcq",',
  '  "difficulty": "easy" | "medium" | "hard",',
  '  "prompt": "The question text shown to the candidate",',
  '  "reference": "Reference answer / rubric the grader can use",',
  '  "options": [ { "text": "...", "correct": true|false } ]   // only for mcq',
  "}",
  "Rules:",
  "- Mix kinds across the set. Use 'code' for programming tasks, 'open' for",
  "  conceptual explanation, 'mcq' for quick checks (exactly one correct option).",
  "- 'reference' must let a grader judge an answer without seeing the candidate.",
  "- Keep prompts self-contained.",
}, "\n")

local GRADE_SYSTEM_PROMPT = table.concat({
  "You are a strict but fair grader. Given a question, a reference answer/rubric,",
  "and a candidate's answer, score the answer.",
  'Return ONLY JSON: { "score": 0.0-1.0, "feedback": "one or two sentences" }.',
  "Be objective; partial credit is allowed for open/code answers.",
}, "\n")

-- Generate questions for one topic. callback(questions, err)
local function generate_for_topic(topic, n, callback)
  local user = string.format(
    "## Topic\n%s\n\n## Scope\n%s\n\nGenerate %d question(s) of mixed kind and difficulty.",
    topic.name,
    topic.description or "",
    n
  )
  llm.chat_json(GEN_SYSTEM_PROMPT, user, function(decoded, err, raw)
    if err then
      callback(nil, err, raw)
      return
    end
    local arr = decoded
    if type(decoded) == "table" and decoded.questions then
      arr = decoded.questions
    end
    if type(arr) ~= "table" then
      callback(nil, "Unexpected question format", raw)
      return
    end
    callback(arr)
  end)
end

-- How many questions to generate for a topic in this run.
--
-- Two multipliers on top of the configured base:
--   * the topic's own `weight` (0.5-2.0), so central topics get more airtime;
--   * mastery, so a topic you keep acing shrinks toward the floor and a weak or
--     never-tested one grows. `level` is the most recent score (nil = untested,
--     treated as needing full attention).
-- The result is clamped to [min_questions_per_topic, max_questions_per_topic].
local function questions_for_topic(topic, level)
  local base = config.get("assess.questions_per_topic", 2)
  local min_n = config.get("assess.min_questions_per_topic", 1)
  local max_n = config.get("assess.max_questions_per_topic", 5)

  local n = base
  if config.get("assess.weighting", true) then
    n = n * (tonumber(topic.weight) or 1.0)
  end
  if config.get("assess.adaptive", true) then
    -- level 0 -> 1.5x, level 0.5 -> 1.0x, level 1 -> 0.5x, untested -> 1.5x.
    n = n * (level == nil and 1.5 or (1.5 - math.max(0, math.min(1, level))))
  end

  n = math.floor(n + 0.5)
  return math.max(min_n, math.min(max_n, n))
end

-- Normalise a raw LLM question into the DB shape.
local function normalize_question(raw, topic_id, position)
  local kind = raw.kind
  if kind ~= "code" and kind ~= "open" and kind ~= "mcq" then
    kind = "open"
  end
  local payload = {}
  if kind == "mcq" and type(raw.options) == "table" then
    payload.options = {}
    for i, opt in ipairs(raw.options) do
      table.insert(payload.options, {
        number = i,
        text = type(opt) == "table" and opt.text or tostring(opt),
        correct = type(opt) == "table" and opt.correct == true or false,
      })
    end
  end
  return {
    topic_id = topic_id,
    kind = kind,
    difficulty = raw.difficulty or "medium",
    prompt = utils.trim(raw.prompt or ""),
    reference = utils.trim(raw.reference or ""),
    payload = payload,
    position = position,
  }
end

-- Start a run (phase is a free-form label, e.g. 'test') and generate all
-- questions.
-- callback(run, err) where run = { id, questions = { ... } }
-- opts.on_progress(completed, total, topic_name) is called as each topic's
-- questions finish generating, for UI progress reporting. opts.on_start(total)
-- is called once before generation begins.
function assess.start_run(phase, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  local on_progress = opts.on_progress
  local proj = project.require_current()
  if not proj then
    callback(nil, "No active project")
    return
  end
  local topics = db.get_topics(proj.db)
  if #topics == 0 then
    callback(nil, "Project has no syllabus. Run :KB start first.")
    return
  end

  local run_id = db.create_run(proj.db, phase)
  -- Allocate question counts up front from each topic's weight and your most
  -- recent score on it, so a run concentrates on what you're weakest at.
  local latest_levels = db.get_latest_levels(proj.db)
  local per_topic = {}
  for _, topic in ipairs(topics) do
    per_topic[topic.id] = questions_for_topic(topic, latest_levels[topic.id])
  end

  -- Generate with a bounded number of in-flight requests. Local single-instance
  -- backends (e.g. Ollama) serialize requests, so firing one call per topic at
  -- once just queues them and risks timeouts; a small cap (default 1) keeps the
  -- pipeline tractable. Hosted APIs can raise this for throughput.
  local max_concurrency = math.max(1, config.get("assess.max_concurrency", 1))

  local errors = {}
  local position = 0
  local next_topic = 1
  local completed = 0
  local total = #topics
  local active = 0

  if opts.on_start then
    opts.on_start(total)
  end

  local launch_next

  local function on_topic_done(topic, questions, err)
    if err then
      table.insert(errors, topic.name .. ": " .. err)
    elseif questions then
      -- Models are loose about honouring the requested count; cap it so the
      -- weight/mastery allocation actually holds.
      local budget = per_topic[topic.id] or #questions
      for i, raw in ipairs(questions) do
        if i > budget then
          break
        end
        position = position + 1
        db.add_question(proj.db, run_id, normalize_question(raw, topic.id, position))
      end
    end
    active = active - 1
    completed = completed + 1
    if on_progress then
      on_progress(completed, total, topic.name)
    end
    if completed == total then
      local stored = db.get_questions(proj.db, run_id)
      if #stored == 0 then
        callback(nil, "Question generation failed: " .. table.concat(errors, "; "))
        return
      end
      callback({ id = run_id, phase = phase, questions = stored, errors = errors })
      return
    end
    launch_next()
  end

  launch_next = function()
    while active < max_concurrency and next_topic <= total do
      local topic = topics[next_topic]
      next_topic = next_topic + 1
      active = active + 1
      generate_for_topic(topic, per_topic[topic.id], function(questions, err)
        on_topic_done(topic, questions, err)
      end)
    end
  end

  launch_next()
end

-- Decode a stored question's payload JSON.
function assess.decode_payload(question)
  if not question then
    return {}
  end
  return utils.json_decode(question.payload or "{}") or {}
end

-- Grade an MCQ deterministically; everything else via the LLM grader.
-- callback(result, err) where result = { score, passed, feedback }
function assess.grade(question, answer, callback)
  local threshold = config.get("assess.pass_threshold", 0.6)

  if question.kind == "mcq" then
    local payload = assess.decode_payload(question)
    local chosen = tonumber((answer or ""):match("%d+"))
    local correct_num
    for _, opt in ipairs(payload.options or {}) do
      if opt.correct then
        correct_num = opt.number
      end
    end
    local score = (chosen and correct_num and chosen == correct_num) and 1.0 or 0.0
    callback({
      score = score,
      passed = score >= threshold,
      feedback = score == 1.0 and "Correct." or ("Incorrect. The correct option was " .. tostring(correct_num) .. "."),
    })
    return
  end

  local user = string.format(
    "## Question\n%s\n\n## Reference / rubric\n%s\n\n## Candidate answer\n%s",
    question.prompt or "",
    question.reference or "",
    answer or ""
  )
  llm.chat_json(
    GRADE_SYSTEM_PROMPT,
    user,
    { temperature = config.get("llm.grading_temperature") },
    function(decoded, err)
      if err then
        callback(nil, err)
        return
      end
      local score = tonumber(decoded.score) or 0
      score = math.max(0, math.min(1, score))
      callback({
        score = score,
        passed = score >= threshold,
        feedback = decoded.feedback or "",
      })
    end
  )
end

-- Record a graded answer to the DB.
function assess.record(run_id, question, result)
  local proj = project.require_current()
  if not proj then
    return
  end
  db.add_response(proj.db, run_id, question.id, {
    answer = result.answer or "",
    score = result.score,
    passed = result.passed,
    llm_feedback = result.feedback or "",
  })
end

-- After all answers, compute and persist per-topic level snapshots, then mark
-- the run complete. Returns the levels table { topic_id = avg_score }.
function assess.finalize(run_id)
  local proj = project.require_current()
  if not proj then
    return {}
  end
  local questions = db.get_questions(proj.db, run_id)
  local responses = db.get_responses(proj.db, run_id)

  local by_question = {}
  for _, r in ipairs(responses) do
    by_question[r.question_id] = r
  end

  local sums, counts = {}, {}
  for _, q in ipairs(questions) do
    local r = by_question[q.id]
    if q.topic_id and r and r.score ~= nil then
      sums[q.topic_id] = (sums[q.topic_id] or 0) + r.score
      counts[q.topic_id] = (counts[q.topic_id] or 0) + 1
    end
  end

  local levels = {}
  for topic_id, sum in pairs(sums) do
    local avg = sum / counts[topic_id]
    levels[topic_id] = utils.round(avg, 3)
    db.set_level(proj.db, run_id, topic_id, levels[topic_id])
  end

  db.complete_run(proj.db, run_id)
  return levels
end

assess._normalize_question = normalize_question
assess._questions_for_topic = questions_for_topic

return assess
