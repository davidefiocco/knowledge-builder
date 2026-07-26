-- Tier 1 deterministic headless tests for knowledge-builder.
--
-- Run with:
--   KB_WORKSPACE=$(mktemp -d) nvim --headless -u dev/init.lua -l test/test_flow.lua
--
-- The LLM module is monkey-patched so no network access or token is required.

local passed, failed, skipped = 0, 0, 0
local errors = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("  ok  " .. name .. "\n")
  elseif type(err) == "table" and err.__skip then
    skipped = skipped + 1
    io.write("  -   " .. name .. " (skipped: " .. err.reason .. ")\n")
  else
    failed = failed + 1
    table.insert(errors, { name = name, error = tostring(err) })
    io.write("  X   " .. name .. ": " .. tostring(err) .. "\n")
  end
  io.flush()
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "assertion", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_truthy(val, msg)
  if not val then
    error(msg or "expected truthy value")
  end
end

local function assert_near(actual, expected, tol, msg)
  if math.abs((actual or -1) - expected) > (tol or 0.001) then
    error(string.format("%s: expected ~%s, got %s", msg or "assertion", tostring(expected), tostring(actual)))
  end
end

-- A deterministic stub for the LLM module. Returns canned syllabus, questions,
-- and grades based on the answer text, so the full flow runs offline.
local function install_llm_stub()
  local llm = require("knowledge-builder.llm")

  llm.chat_json = function(system_prompt, user_prompt, opts, callback)
    if type(opts) == "function" then
      callback = opts
    end
    if system_prompt:find("revising an existing syllabus") then
      callback({
        topics = {
          { name = "Topic A", description = "scope a", weight = 1.0 },
          { name = "Topic B", description = "scope b", weight = 1.5 },
          { name = "Topic C", description = "added by refine", weight = 1.0 },
        },
      })
    elseif system_prompt:find("curriculum designer") then
      callback({
        topics = {
          { name = "Topic A", description = "scope a", weight = 1.0 },
          { name = "Topic B", description = "scope b", weight = 1.5 },
        },
      })
    elseif system_prompt:find("examiner") then
      callback({
        {
          kind = "open",
          difficulty = "easy",
          prompt = "Explain X",
          reference = "X is the thing.",
        },
        {
          kind = "mcq",
          difficulty = "easy",
          prompt = "Pick the correct one",
          options = {
            { text = "Wrong", correct = false },
            { text = "Right", correct = true },
          },
        },
      })
    elseif system_prompt:find("grader") then
      -- Score 1.0 if the answer contains "good", else 0.2.
      local score = user_prompt:lower():find("good") and 1.0 or 0.2
      callback({ score = score, feedback = "stub feedback" })
    else
      callback(nil, "unexpected prompt in stub")
    end
  end

  llm.chat = function(_, opts, callback)
    if type(opts) == "function" then
      callback = opts
    end
    callback("stub response")
  end
end

io.write("\n== knowledge-builder - Tier 1 Tests ==\n\n")
io.flush()

-- Capture the genuine chat_json before the suite stub overwrites it, so the
-- retry test can exercise the real implementation against a stubbed llm.chat
-- on the same module instance.
local REAL_CHAT_JSON = require("knowledge-builder.llm").chat_json

install_llm_stub()

test("Modules load", function()
  assert_truthy(require("knowledge-builder.init"))
  assert_truthy(require("knowledge-builder.api"))
  assert_truthy(require("knowledge-builder.assess"))
  assert_truthy(require("knowledge-builder.project"))
end)

test("Config defaults present", function()
  local config = require("knowledge-builder.config")
  assert_truthy(config.get("storage.workspace"), "workspace nil")
  assert_eq(config.get("llm.model"), "Qwen/Qwen3-Coder-Next", "model")
  assert_near(config.get("assess.pass_threshold"), 0.6, 0.001, "threshold")
end)

test("utils.extract_json handles fenced and bare JSON", function()
  local utils = require("knowledge-builder.utils")
  assert_eq(utils.extract_json('```json\n{"a":1}\n```').a, 1, "fenced")
  assert_eq(utils.extract_json('prefix {"a":2} suffix').a, 2, "bare object")
  assert_eq(#utils.extract_json("here: [1,2,3]"), 3, "bare array")
  assert_eq(utils.extract_json("no json here"), nil, "none")
end)

test("utils.slugify produces clean slugs", function()
  local utils = require("knowledge-builder.utils")
  assert_eq(utils.slugify("Senior ML Engineer @ Acme!"), "senior-ml-engineer-acme", "slug")
end)

test("SSE chunk parsing extracts content tokens", function()
  local llm = require("knowledge-builder.llm")
  local tokens = {}
  local chunk = 'data: {"choices":[{"delta":{"content":"Hel"}}]}\n'
    .. 'data: {"choices":[{"delta":{"content":"lo"}}]}\n'
    .. "data: [DONE]\n"
  local done = llm.parse_sse_chunk(chunk, function(t)
    table.insert(tokens, t)
  end)
  assert_eq(table.concat(tokens), "Hello", "tokens")
  assert_eq(done, true, "done sentinel")
end)

local TEST_SLUG = "kb-test-project"

test("Project create + open round-trips", function()
  local project = require("knowledge-builder.project")
  -- Clean any prior run.
  local dir = project.dir(TEST_SLUG)
  if vim.fn.isdirectory(dir) == 1 then
    vim.fn.delete(dir, "rf")
  end
  local proj, err = project.create("KB Test Project", { slug = TEST_SLUG })
  assert_truthy(proj, "create failed: " .. tostring(err))
  assert_eq(proj.slug, TEST_SLUG, "slug")
  assert_truthy(vim.fn.filereadable(project.db_path(TEST_SLUG)) == 1, "db not created")

  local reopened = project.open(TEST_SLUG)
  assert_truthy(reopened, "reopen failed")
  assert_eq(reopened.name, "KB Test Project", "name persisted")
end)

test("Syllabus build_and_save persists topics + files", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local syllabus = require("knowledge-builder.syllabus")

  local done, result = false, nil
  syllabus.build_and_save("I want to be an ML engineer", function(topics, err)
    result = topics or err
    done = true
  end)
  vim.wait(5000, function()
    return done
  end, 20)
  assert_truthy(type(result) == "table", "no topics: " .. tostring(result))
  assert_eq(#result, 2, "topic count")

  assert_truthy(vim.fn.filereadable(project.syllabus_md_path(TEST_SLUG)) == 1, "syllabus.md missing")
  assert_truthy(vim.fn.filereadable(project.syllabus_json_path(TEST_SLUG)) == 1, "syllabus.json missing")

  local db = require("knowledge-builder.db")
  local topics = db.get_topics(project.db_path(TEST_SLUG))
  assert_eq(#topics, 2, "topics in db")
  assert_eq(topics[1].name, "Topic A", "first topic name")
end)

test("Syllabus refine revises and persists topics", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local syllabus = require("knowledge-builder.syllabus")

  local done, result = false, nil
  syllabus.refine("add a topic on Topic C", function(topics, err)
    result = topics or err
    done = true
  end)
  vim.wait(5000, function()
    return done
  end, 20)
  assert_truthy(type(result) == "table", "no topics: " .. tostring(result))
  assert_eq(#result, 3, "refined topic count")

  local db = require("knowledge-builder.db")
  local topics = db.get_topics(project.db_path(TEST_SLUG))
  assert_eq(#topics, 3, "refined topics persisted to db")
  assert_eq(topics[3].name, "Topic C", "added topic name")
end)

test("MCQ grading is deterministic", function()
  local assess = require("knowledge-builder.assess")
  local question = {
    kind = "mcq",
    payload = vim.json.encode({
      options = {
        { number = 1, text = "Wrong", correct = false },
        { number = 2, text = "Right", correct = true },
      },
    }),
  }
  local got
  assess.grade(question, "Answer: 2", function(r)
    got = r
  end)
  assert_eq(got.score, 1.0, "correct mcq")
  assert_eq(got.passed, true, "passed")

  assess.grade(question, "Answer: 1", function(r)
    got = r
  end)
  assert_eq(got.score, 0.0, "wrong mcq")
end)

test("Open-question grading routes through LLM stub", function()
  local assess = require("knowledge-builder.assess")
  local got
  assess.grade({ kind = "open", prompt = "Explain", reference = "ref" }, "this is a good answer", function(r)
    got = r
  end)
  assert_eq(got.score, 1.0, "good answer scores high")
  assert_eq(got.passed, true, "passed")
end)

test("Headless API: full test run via inject_run", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local api = require("knowledge-builder.init").api
  local db = require("knowledge-builder.db")
  local topics = db.get_topics(project.db_path(TEST_SLUG))

  local injected = api.inject_run("test", {
    { topic_id = topics[1].id, kind = "open", prompt = "Q1", reference = "r" },
    {
      topic_id = topics[2].id,
      kind = "mcq",
      prompt = "Q2",
      payload = {
        options = { { number = 1, text = "a", correct = true }, { number = 2, text = "b", correct = false } },
      },
    },
  })
  assert_eq(injected.ok, true, "inject ok")
  assert_eq(injected.total, 2, "two questions")

  local q1 = api.get_current_question()
  assert_eq(q1.question.prompt, "Q1", "first question")

  local r1 = api.submit_answer("a good answer")
  assert_eq(r1.passed, true, "q1 passed")
  assert_eq(r1.run_finished, false, "not finished")

  local q2 = api.get_current_question()
  assert_eq(q2.question.kind, "mcq", "second is mcq")

  local r2 = api.submit_answer("Answer: 1")
  assert_eq(r2.passed, true, "q2 correct")
  assert_eq(r2.run_finished, true, "finished")

  local final = api.finalize_run()
  assert_eq(final.ok, true, "finalize ok")
  -- levels is string-keyed (stable JSON object, not a sparse array).
  local key_a = tostring(topics[1].id)
  assert_truthy(final.levels[key_a] ~= nil, "topic A level set")
  assert_near(final.levels[key_a], 1.0, 0.001, "topic A score")
end)

test("Progress: second run computes delta vs first", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local api = require("knowledge-builder.init").api
  local db = require("knowledge-builder.db")
  local topics = db.get_topics(project.db_path(TEST_SLUG))

  -- A weaker second run: answer poorly so the score drops, then assert the
  -- delta vs. the previous (stronger) run is negative.
  api.inject_run("test", {
    { topic_id = topics[1].id, kind = "open", prompt = "Q1", reference = "r" },
  })
  api.get_current_question()
  api.submit_answer("bad")
  local final = api.finalize_run()

  local rows = require("knowledge-builder.progress").compute(final.run_id)
  local row_a
  for _, r in ipairs(rows) do
    if r.topic == topics[1].name then
      row_a = r
    end
  end
  assert_truthy(row_a, "topic A row present")
  assert_truthy(row_a.prev ~= nil, "previous score available")
  assert_truthy(row_a.delta ~= nil and row_a.delta < 0, "delta should be negative after worse run")
end)

test("chat_json retries once on invalid JSON then succeeds", function()
  -- Exercise the REAL chat_json (captured before the suite stub) against a
  -- stubbed llm.chat on the same module instance.
  local llm = require("knowledge-builder.llm")
  local saved_chat_json = llm.chat_json
  local saved_chat = llm.chat
  llm.chat_json = REAL_CHAT_JSON

  local calls = 0
  llm.chat = function(_, opts, callback)
    if type(opts) == "function" then
      callback = opts
    end
    calls = calls + 1
    if calls == 1 then
      callback("Sure! Here is my reasoning... not json at all")
    else
      callback('{"ok": true, "n": 7}')
    end
  end

  local got, got_err
  llm.chat_json("sys", "user", function(decoded, err)
    got, got_err = decoded, err
  end)

  assert_eq(got_err, nil, "should succeed after retry")
  assert_truthy(got and got.n == 7, "decoded retry payload")
  assert_eq(calls, 2, "should have retried exactly once")

  -- Test the give-up path with the same real implementation.
  calls = 0
  llm.chat = function(_, opts, callback)
    if type(opts) == "function" then
      callback = opts
    end
    calls = calls + 1
    callback("still not json")
  end
  local g2, e2
  llm.chat_json("sys", "user", function(decoded, err)
    g2, e2 = decoded, err
  end)
  assert_eq(g2, nil, "no decode on persistent failure")
  assert_truthy(e2 and e2:find("after retry"), "error mentions retry: " .. tostring(e2))
  assert_eq(calls, 2, "one initial + one retry")

  -- Restore the suite-wide stubs for subsequent tests.
  llm.chat = saved_chat
  llm.chat_json = saved_chat_json
end)

test("finalize_run levels encode as a JSON object, not a sparse array", function()
  local utils = require("knowledge-builder.utils")
  -- Simulate non-contiguous integer topic ids (the real-world case).
  local levels = { [8] = 1.0, [9] = 0.5 }
  local stringified = utils.stringify_keys(levels)
  local encoded = vim.json.encode(stringified)
  assert_truthy(encoded:sub(1, 1) == "{", "should encode as object, got: " .. encoded)
  assert_truthy(not encoded:find("null", 1, true), "should not contain null padding: " .. encoded)
  -- Round-trips back to the same scores under string keys.
  local decoded = vim.json.decode(encoded)
  assert_near(decoded["8"], 1.0, 0.001, "topic 8")
  assert_near(decoded["9"], 0.5, 0.001, "topic 9")
end)

test("start_run respects max_concurrency (no overlap at cap 1)", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local config = require("knowledge-builder.config")
  local llm = require("knowledge-builder.llm")
  local assess = require("knowledge-builder.assess")

  config.config.assess.max_concurrency = 1

  -- Wrap the stub to track concurrent in-flight generation calls.
  local original = llm.chat_json
  local in_flight, max_seen = 0, 0
  llm.chat_json = function(system_prompt, user_prompt, opts, callback)
    if system_prompt:find("examiner") then
      in_flight = in_flight + 1
      max_seen = math.max(max_seen, in_flight)
      -- Defer the callback so overlap would be observable if it happened.
      vim.defer_fn(function()
        in_flight = in_flight - 1
        original(system_prompt, user_prompt, opts, callback)
      end, 10)
    else
      original(system_prompt, user_prompt, opts, callback)
    end
  end

  local done = false
  assess.start_run("test", function(run, err)
    assert(run, err)
    done = true
  end)
  vim.wait(10000, function()
    return done
  end, 10)

  llm.chat_json = original
  assert_eq(max_seen, 1, "no more than 1 concurrent generation at cap 1, saw " .. max_seen)
end)

test("spinner: bar steps and finishes without error", function()
  local spinner = require("knowledge-builder.spinner")
  local p = spinner.start("Testing", { total = 3 })
  assert_eq(p.total, 3, "total set")
  assert_eq(p.completed, 0, "starts at 0")
  p:step("topic 1")
  p:step("topic 2")
  assert_eq(p.completed, 2, "two steps")
  assert_eq(p.detail, "topic 2", "detail updated")
  p:finish()
  assert_eq(p.done, true, "finished")
  assert_truthy(p.timer == nil, "timer released")
end)

test("spinner: indeterminate spinner cancels cleanly", function()
  local spinner = require("knowledge-builder.spinner")
  local p = spinner.start("Working")
  assert_truthy(p.total == nil, "no total => spinner mode")
  p:update("phase 2")
  assert_eq(p.detail, "phase 2", "detail updates")
  p:cancel()
  assert_eq(p.done, true, "cancelled")
  assert_truthy(p.timer == nil, "timer released")
end)

test("start_run fires on_start and on_progress callbacks", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local assess = require("knowledge-builder.assess")
  local config = require("knowledge-builder.config")
  config.config.assess.max_concurrency = 1

  local started_total, progress_calls = nil, 0
  local done = false
  assess.start_run("test", {
    on_start = function(total)
      started_total = total
    end,
    on_progress = function(completed, total, name)
      progress_calls = progress_calls + 1
      assert_truthy(completed >= 1 and completed <= total, "completed in range")
      assert_truthy(type(name) == "string", "topic name passed")
    end,
  }, function(run, err)
    assert(run, err)
    done = true
  end)
  vim.wait(10000, function()
    return done
  end, 10)

  local topics = require("knowledge-builder.db").get_topics(project.db_path(TEST_SLUG))
  assert_eq(started_total, #topics, "on_start got topic count")
  assert_eq(progress_calls, #topics, "on_progress fired once per topic")
end)

test("tutor chat: ephemeral placeholder, no persistent label", function()
  local llm = require("knowledge-builder.llm")
  local chat = require("knowledge-builder.chat")

  -- Stub streaming: emit two tokens then complete.
  local saved_stream = llm.stream
  llm.stream = function(_messages, _opts, on_delta, on_done)
    on_delta("Hello ")
    on_delta("there")
    on_done("Hello there")
  end

  chat.open({ title = "Tutor" })
  local st = chat._test.state()
  -- Type a user message after the prompt marker on the last line.
  local last = vim.api.nvim_buf_line_count(st.bufnr) - 1
  vim.bo[st.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(st.bufnr, last, last + 1, false, { "> what is a closure?" })

  chat._test.send()

  local text = table.concat(vim.api.nvim_buf_get_lines(st.bufnr, 0, -1, false), "\n")
  llm.stream = saved_stream

  assert_truthy(text:find("Hello there", 1, true), "streamed reply present")
  assert_truthy(not text:find("tutor:", 1, true), "no persistent 'tutor:' label")
  assert_truthy(not text:find("Thinking...", 1, true), "placeholder cleared")
  -- The assistant turn was recorded in message history.
  local msgs = st.messages
  assert_eq(msgs[#msgs].role, "assistant", "assistant message recorded")
  assert_eq(msgs[#msgs].content, "Hello there", "assistant content")

  -- Cleanup the float.
  if st.win then
    pcall(function()
      st.win:unmount()
    end)
  end
end)

test("help: :KB help opens a cheat sheet listing commands", function()
  local kb = require("knowledge-builder.init")
  assert_truthy(type(kb.help) == "function", "kb.help exists")

  -- Capture the buffer contents the float is populated with.
  local ui = require("knowledge-builder.ui")
  local captured
  local real_set_lines = ui.set_lines
  ui.set_lines = function(bufnr, lines, o)
    captured = lines
    return real_set_lines(bufnr, lines, o)
  end

  local ok = pcall(kb.help)
  ui.set_lines = real_set_lines
  assert_truthy(ok, "kb.help ran without error")

  local text = table.concat(captured or {}, "\n")
  assert_truthy(text:find(":KB test", 1, true), "lists test")
  assert_truthy(text:find(":KB results", 1, true), "lists results")
  assert_truthy(text:find(":help knowledge%-builder"), "points to full help")
end)

test("results report: per-question grading is retrievable", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local api = require("knowledge-builder.init").api
  local db = require("knowledge-builder.db")
  local topics = db.get_topics(project.db_path(TEST_SLUG))

  local injected = api.inject_run("test", {
    { topic_id = topics[1].id, kind = "open", prompt = "Explain X", reference = "r" },
    {
      topic_id = topics[2].id,
      kind = "mcq",
      prompt = "Pick one",
      payload = {
        options = { { number = 1, text = "a", correct = true }, { number = 2, text = "b", correct = false } },
      },
    },
  })
  assert_eq(injected.ok, true, "inject ok")

  api.get_current_question()
  api.submit_answer("this is a good answer")
  api.get_current_question()
  api.submit_answer("Answer: 1")
  local final = api.finalize_run()

  local res = api.get_run_report(final.run_id)
  assert_eq(res.ok, true, "report ok")
  local report = res.report
  assert_eq(report.run.id, final.run_id, "report run id")
  assert_truthy(report.overall ~= nil, "overall score present")

  -- Flatten questions across topics for assertions.
  local all = {}
  for _, topic in ipairs(report.topics) do
    for _, q in ipairs(topic.questions) do
      table.insert(all, q)
    end
  end
  assert_eq(#all, 2, "two questions in report")

  local open_q
  for _, q in ipairs(all) do
    if q.kind == "open" then
      open_q = q
    end
  end
  assert_truthy(open_q, "open question present")
  assert_eq(open_q.answer, "this is a good answer", "answer recorded")
  assert_eq(open_q.passed, true, "open question passed")
  assert_truthy(open_q.feedback and #open_q.feedback > 0, "feedback present")
  assert_truthy(open_q.graded, "marked graded")

  -- Unknown run id is reported as an error.
  local bad = api.get_run_report(999999)
  assert_eq(bad.ok, false, "missing run errors")
end)

test("exam navigation: answers persist across next/prev", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local db = require("knowledge-builder.db")
  local exam = require("knowledge-builder.exam")
  local topics = db.get_topics(project.db_path(TEST_SLUG))

  -- Build a 3-question run directly in the DB and open the exam on it.
  local run_id = db.create_run(project.db_path(TEST_SLUG), "test")
  local assess = require("knowledge-builder.assess")
  for i = 1, 3 do
    db.add_question(
      project.db_path(TEST_SLUG),
      run_id,
      assess._normalize_question(
        { kind = "open", difficulty = "easy", prompt = "Q" .. i, reference = "r" },
        topics[1].id,
        i
      )
    )
  end
  local questions = db.get_questions(project.db_path(TEST_SLUG), run_id)
  assert_eq(#questions, 3, "three questions stored")

  exam.open({ id = run_id, phase = "test", questions = questions })
  local t = exam._test

  -- Type an answer on Q1, move to Q2, type, move back to Q1: answer restored.
  t.set_answer("answer one")
  t.navigate(1)
  assert_eq(t.state().index, 2, "advanced to Q2")
  t.set_answer("answer two")
  t.navigate(-1)
  assert_eq(t.state().index, 1, "back on Q1")
  local restored = vim.api.nvim_buf_get_lines(t.state().answer_popup.bufnr, 0, -1, false)
  assert_eq(table.concat(restored, "\n"), "answer one", "Q1 answer restored")

  -- Forward again restores Q2's answer.
  t.navigate(1)
  local restored2 = vim.api.nvim_buf_get_lines(t.state().answer_popup.bufnr, 0, -1, false)
  assert_eq(table.concat(restored2, "\n"), "answer two", "Q2 answer restored")

  -- Navigation clamps at the ends.
  t.navigate(1) -- to Q3
  assert_eq(t.state().index, 3, "at Q3")
  t.navigate(1) -- clamp
  assert_eq(t.state().index, 3, "clamped at last")

  -- Grading the current question records a grade and does NOT advance.
  t.set_answer("a good answer")
  t.submit()
  vim.wait(2000, function()
    return t.state() and t.state().grades[3] ~= nil
  end, 20)
  assert_truthy(t.state().grades[3], "Q3 graded")
  assert_eq(t.state().index, 3, "stayed on Q3 after grading")

  -- Finish grades the remaining (ungraded) questions and tears down.
  t.finish()
  vim.wait(3000, function()
    return exam._test.state() == nil
  end, 20)
  assert_truthy(exam._test.state() == nil, "exam torn down after finish")

  local responses = db.get_responses(project.db_path(TEST_SLUG), run_id)
  assert_eq(#responses, 3, "all three questions graded after finish")
end)

-- ---------------------------------------------------------------------------
-- Expanded coverage: utils edge cases, config, llm curl args, errors, dispatch.
-- ---------------------------------------------------------------------------

test("utils.extract_json handles nested objects and tricky strings", function()
  local utils = require("knowledge-builder.utils")
  -- Nested braces inside the object.
  local nested = utils.extract_json('text {"a": {"b": [1,2]}, "c": 3} trailing')
  assert_truthy(nested and nested.a and nested.a.b, "nested object parsed")
  assert_eq(nested.c, 3, "sibling key parsed")
  -- Braces/brackets inside a string must not confuse the balance scanner.
  local strbrace = utils.extract_json('{"k": "a } b ] c"}')
  assert_eq(strbrace.k, "a } b ] c", "braces inside string preserved")
  -- Escaped quote inside a string.
  local esc = utils.extract_json('{"k": "a\\"b"}')
  assert_eq(esc.k, 'a"b', "escaped quote handled")
  -- Fenced JSON with language tag wins over surrounding prose.
  local fenced = utils.extract_json('Here:\n```json\n{"ok": true}\n```\nthanks')
  assert_eq(fenced.ok, true, "fenced json extracted")
  -- Array form.
  local arr = utils.extract_json("prefix [10, 20, 30]")
  assert_eq(#arr, 3, "array length")
  assert_eq(arr[2], 20, "array element")
end)

test("utils.round and stringify_keys behave", function()
  local utils = require("knowledge-builder.utils")
  assert_near(utils.round(0.6666, 2), 0.67, 0.0001, "round 2dp")
  assert_near(utils.round(0.125, 2), 0.13, 0.0001, "round half up")
  assert_near(utils.round(3.14159, 0), 3, 0.0001, "round to integer")
  assert_eq(utils.round(nil), 0, "nil -> 0")
  local s = utils.stringify_keys({ [3] = "a", [7] = "b" })
  assert_eq(s["3"], "a", "key 3 stringified")
  assert_eq(s["7"], "b", "key 7 stringified")
  assert_eq(next(utils.stringify_keys(nil)), nil, "nil -> empty table")
end)

test("utils.slugify handles unicode and empties", function()
  local utils = require("knowledge-builder.utils")
  assert_eq(utils.slugify("  Hello World  "), "hello-world", "spaces trimmed")
  assert_eq(utils.slugify("C++ & Rust!"), "c-rust", "symbols collapsed")
  local empty = utils.slugify("@@@")
  assert_truthy(empty:find("^project%-"), "empty slug gets fallback: " .. empty)
end)

test("config.get dotted lookups and missing keys", function()
  local config = require("knowledge-builder.config")
  assert_truthy(config.get("llm.api_url"), "nested key present")
  assert_eq(config.get("llm.does.not.exist", "fallback"), "fallback", "missing -> default")
  assert_eq(config.get("totally_absent"), nil, "absent top-level -> nil")
  -- Deep merge: setup overrides only the specified leaf, keeps siblings.
  local saved = vim.deepcopy(config.config)
  config.setup({ llm = { model = "custom-model" } })
  assert_eq(config.get("llm.model"), "custom-model", "override applied")
  assert_truthy(config.get("llm.api_url"), "sibling key preserved after merge")
  config.config = saved -- restore for later tests
end)

test("llm._build_curl_invocation routes auth + body through stdin, not argv", function()
  local llm = require("knowledge-builder.llm")
  local config = require("knowledge-builder.config")
  local env = config.get("llm.hf_token_env", "HF_TOKEN")

  -- With a token set, the header is present in the stdin config, never in argv.
  local saved = vim.env[env]
  vim.env[env] = "secret-token-123"
  local argv, stdin_cfg = llm._build_curl_invocation("http://x/api", '{"a":1}')
  local joined_argv = table.concat(argv, "\n")
  assert_truthy(not joined_argv:find("secret%-token%-123"), "token never on argv")
  assert_truthy(not joined_argv:find("Authorization"), "auth header never on argv")
  assert_truthy(not joined_argv:find('{"a":1}'), "payload never on argv")
  assert_truthy(stdin_cfg:find("Authorization: Bearer secret%-token%-123"), "auth header in stdin config")
  assert_truthy(stdin_cfg:find("data = "), "payload in stdin config")
  -- Timeout is non-sensitive, so it stays on argv; config is read from stdin.
  assert_truthy(joined_argv:find("%-%-max%-time"), "timeout flag on argv")
  assert_eq(argv[#argv - 1], "--config", "config flag on argv")
  assert_eq(argv[#argv], "-", "config source is stdin")

  -- With no token, the header is omitted (the Ollama case).
  vim.env[env] = nil
  local argv2, stdin_cfg2 = llm._build_curl_invocation("http://x/api", "{}")
  assert_truthy(not table.concat(argv2, "\n"):find("Authorization"), "no auth header on argv without token")
  assert_truthy(not stdin_cfg2:find("Authorization"), "no auth header in stdin without token")

  vim.env[env] = saved -- restore
end)

test("llm._build_payload reflects config + opt overrides", function()
  local llm = require("knowledge-builder.llm")
  local p = llm._build_payload({ { role = "user", content = "hi" } }, { max_tokens = 42, temperature = 0.0 })
  assert_eq(p.max_tokens, 42, "opt max_tokens override")
  assert_near(p.temperature, 0.0, 0.0001, "opt temperature override")
  assert_truthy(p.model, "model defaulted from config")
  assert_eq(p.messages[1].content, "hi", "messages passed through")
end)

test("syllabus.generate surfaces non-JSON errors after retry", function()
  -- Temporarily make the real chat_json path run against a chat that never
  -- returns JSON, so the corrective retry also fails and the error bubbles up.
  local llm = require("knowledge-builder.llm")
  local saved_chat_json = llm.chat_json
  local saved_chat = llm.chat
  llm.chat_json = REAL_CHAT_JSON
  llm.chat = function(_, opts, callback)
    if type(opts) == "function" then
      callback = opts
    end
    callback("I cannot comply, here is prose only.")
  end

  local syllabus = require("knowledge-builder.syllabus")
  local got_err
  syllabus.generate("be an ML engineer", function(_topics, err)
    got_err = err
  end)
  assert_truthy(got_err and got_err:find("JSON"), "JSON failure surfaced: " .. tostring(got_err))

  llm.chat = saved_chat
  llm.chat_json = saved_chat_json
end)

test("api error paths: missing run id and no active run", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local api = require("knowledge-builder.init").api

  assert_eq(api.get_run_report(nil).ok, false, "nil run_id errors")

  -- Run a complete inject->finalize cycle so run_state is cleared, then assert
  -- the run-dependent calls all report errors.
  local db = require("knowledge-builder.db")
  local topics = db.get_topics(project.db_path(TEST_SLUG))
  api.inject_run("test", { { topic_id = topics[1].id, kind = "open", prompt = "Q", reference = "r" } })
  api.get_current_question()
  api.submit_answer("good")
  api.finalize_run() -- clears run_state

  assert_eq(api.submit_answer("x").ok, false, "submit with no run errors")
  assert_eq(api.finalize_run().ok, false, "finalize with no run errors")
  assert_eq(api.get_current_question().ok, false, "get_current with no run errors")
end)

test("syllabus.refine errors without an active syllabus", function()
  local project = require("knowledge-builder.project")
  local syllabus = require("knowledge-builder.syllabus")

  -- Fresh project with no syllabus.
  local slug = "kb-empty-syllabus"
  if vim.fn.isdirectory(project.dir(slug)) == 1 then
    vim.fn.delete(project.dir(slug), "rf")
  end
  project.create("KB Empty Syllabus", { slug = slug })

  local got_err
  syllabus.refine("add a topic", function(_, err)
    got_err = err
  end)
  assert_truthy(got_err and got_err:find("syllabus", 1, true), "errors on empty syllabus: " .. tostring(got_err))

  vim.fn.delete(project.dir(slug), "rf")
  project.open(TEST_SLUG)
end)

test("project.create rejects duplicate slugs", function()
  local project = require("knowledge-builder.project")
  local slug = "kb-dup-slug"
  if vim.fn.isdirectory(project.dir(slug)) == 1 then
    vim.fn.delete(project.dir(slug), "rf")
  end
  local p1 = project.create("KB Dup", { slug = slug })
  assert_truthy(p1, "first create ok")
  local p2, err = project.create("KB Dup", { slug = slug })
  assert_truthy(p2 == nil, "second create rejected")
  assert_truthy(err and err:find("exists", 1, true), "error mentions exists")
  vim.fn.delete(project.dir(slug), "rf")
  project.open(TEST_SLUG)
end)

test("every :KB subcommand dispatches without crashing", function()
  -- Drive the registered :KB command for the safe (non-blocking) subcommands.
  -- start/test/review/tutor open UIs or prompts, so we only smoke the ones that
  -- are synchronous and side-effect-light; the rest are covered by unit tests.
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)

  -- Auto-cancel any interactive pickers/prompts so dispatch never blocks
  -- headlessly (e.g. :KB results offers a picker when several runs exist).
  local saved_select, saved_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(_, _, on_choice)
    on_choice(nil)
  end
  vim.ui.input = function(_, on_confirm)
    on_confirm(nil)
  end

  for _, sub in ipairs({ "help", "list", "progress", "results" }) do
    local ok = pcall(function()
      vim.cmd("KB " .. sub)
    end)
    assert_truthy(ok, ":KB " .. sub .. " dispatched")
  end

  vim.ui.select, vim.ui.input = saved_select, saved_input

  local function close_floats()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) then
        local okc, cfg = pcall(vim.api.nvim_win_get_config, w)
        if okc and cfg.relative ~= "" then
          pcall(vim.api.nvim_win_close, w, true)
        end
      end
    end
  end

  close_floats()
  -- Unknown subcommand should warn + show help, not error.
  assert_truthy(
    pcall(function()
      vim.cmd("KB definitely-not-a-command")
    end),
    "unknown subcommand handled"
  )
  close_floats()
end)

-- The you-vs-past-you comparison depends on topic ids surviving a syllabus
-- edit: `levels.topic_id` cascades on delete, so a topic row must stay alive
-- for its scores to remain.
test("refining the syllabus preserves topic ids and level history", function()
  local project = require("knowledge-builder.project")
  local db = require("knowledge-builder.db")
  local slug = "kb-refine-history"
  if vim.fn.isdirectory(project.dir(slug)) == 1 then
    vim.fn.delete(project.dir(slug), "rf")
  end
  project.create("KB Refine History", { slug = slug })
  local path = project.db_path(slug)

  project.save_syllabus({
    { name = "Alpha", description = "a", weight = 1.0 },
    { name = "Beta", description = "b", weight = 1.0 },
  })
  local before = db.get_topics(path)
  local alpha_id = before[1].id
  assert_eq(before[1].name, "Alpha", "first topic")

  -- Record a completed run with levels for both topics.
  local api = require("knowledge-builder.init").api
  api.inject_run("test", {
    { topic_id = before[1].id, kind = "open", prompt = "Q1", reference = "r" },
    { topic_id = before[2].id, kind = "open", prompt = "Q2", reference = "r" },
  })
  api.get_current_question()
  api.submit_answer("a good answer")
  api.get_current_question()
  api.submit_answer("a good answer")
  local first = api.finalize_run()
  assert_eq(#db.get_levels(path, first.run_id), 2, "two levels recorded")

  -- Refine: keep Alpha, drop Beta, add Gamma.
  project.save_syllabus({
    { name = "Alpha", description = "a revised", weight = 2.0 },
    { name = "Gamma", description = "g", weight = 1.0 },
  })

  assert_eq(#db.get_levels(path, first.run_id), 2, "level history survived the refine")
  local after = db.get_topics(path)
  assert_eq(#after, 2, "two active topics")
  assert_eq(after[1].id, alpha_id, "Alpha kept its id")
  assert_near(after[1].weight, 2.0, 0.001, "Alpha weight updated in place")

  -- Beta is archived, not deleted, so old runs stay interpretable.
  local all = db.get_topics(path, { include_archived = true })
  local beta
  for _, t in ipairs(all) do
    if t.name == "Beta" then
      beta = t
    end
  end
  assert_truthy(beta, "Beta still present")
  assert_eq(beta.archived, 1, "Beta archived")

  -- Questions from the earlier run still point at their topics.
  local questions = db.get_questions(path, first.run_id)
  assert_truthy(questions[1].topic_id ~= nil, "old question kept its topic_id")

  -- And a delta against the earlier run is still computable.
  api.inject_run("test", {
    { topic_id = alpha_id, kind = "open", prompt = "Q3", reference = "r" },
  })
  api.get_current_question()
  api.submit_answer("bad")
  local second = api.finalize_run()
  local rows = require("knowledge-builder.progress").compute(second.run_id)
  local alpha_row
  for _, r in ipairs(rows) do
    if r.topic == "Alpha" then
      alpha_row = r
    end
  end
  assert_truthy(alpha_row, "Alpha row present")
  assert_truthy(alpha_row.prev ~= nil, "previous score still available after refine")
  assert_truthy(alpha_row.delta ~= nil and alpha_row.delta < 0, "delta computed across the refine")
  assert_truthy(alpha_row.series and #alpha_row.series == 2, "trend series spans both runs")

  vim.fn.delete(project.dir(slug), "rf")
  project.open(TEST_SLUG)
end)

test("re-archived topic is restored, not duplicated", function()
  local project = require("knowledge-builder.project")
  local db = require("knowledge-builder.db")
  local slug = "kb-restore-topic"
  if vim.fn.isdirectory(project.dir(slug)) == 1 then
    vim.fn.delete(project.dir(slug), "rf")
  end
  project.create("KB Restore", { slug = slug })
  local path = project.db_path(slug)

  project.save_syllabus({ { name = "Alpha" }, { name = "Beta" } })
  local beta_id
  for _, t in ipairs(db.get_topics(path)) do
    if t.name == "Beta" then
      beta_id = t.id
    end
  end

  project.save_syllabus({ { name = "Alpha" } })
  assert_eq(#db.get_topics(path), 1, "Beta archived out of the active set")

  local stats = project.save_syllabus({ { name = "Alpha" }, { name = "Beta" } })
  assert_eq(stats.restored, 1, "Beta reported as restored")
  assert_eq(stats.added, 0, "Beta not re-added as a new topic")

  local active = db.get_topics(path)
  assert_eq(#active, 2, "both topics active again")
  for _, t in ipairs(active) do
    if t.name == "Beta" then
      assert_eq(t.id, beta_id, "Beta kept its original id")
    end
  end

  vim.fn.delete(project.dir(slug), "rf")
  project.open(TEST_SLUG)
end)

test("question allocation scales with topic weight and mastery", function()
  local assess = require("knowledge-builder.assess")
  local n = assess._questions_for_topic

  -- Base 2, no history: an untested topic gets the full 1.5x boost.
  assert_eq(n({ weight = 1.0 }, nil), 3, "untested topic")
  -- A mastered topic shrinks.
  assert_eq(n({ weight = 1.0 }, 1.0), 1, "mastered topic")
  -- A weak topic grows.
  assert_eq(n({ weight = 1.0 }, 0.0), 3, "weak topic")
  -- Weight amplifies: a central weak topic gets more than a peripheral one.
  assert_truthy(n({ weight = 2.0 }, 0.2) > n({ weight = 0.5 }, 0.2), "weight amplifies")
  -- Clamped to the configured ceiling.
  assert_truthy(n({ weight = 2.0 }, 0.0) <= 5, "respects max")
  assert_truthy(n({ weight = 0.5 }, 1.0) >= 1, "respects min")
end)

test("re-grading a question replaces its recorded response", function()
  local project = require("knowledge-builder.project")
  local db = require("knowledge-builder.db")
  project.open(TEST_SLUG)
  local path = project.db_path(TEST_SLUG)
  local topics = db.get_topics(path)

  local run_id = db.create_run(path, "test")
  local qid = db.add_question(path, run_id, {
    topic_id = topics[1].id,
    kind = "open",
    prompt = "Q",
    reference = "r",
    position = 1,
  })

  db.add_response(path, run_id, qid, { answer = "first", score = 0.2, passed = false })
  db.add_response(path, run_id, qid, { answer = "second", score = 0.9, passed = true })

  local responses = db.get_responses(path, run_id)
  assert_eq(#responses, 1, "one response per question")
  assert_eq(responses[1].answer, "second", "latest answer wins")
  assert_near(responses[1].score, 0.9, 0.001, "latest score wins")
end)

test("abandoning a run gives it the abandoned status", function()
  local project = require("knowledge-builder.project")
  local db = require("knowledge-builder.db")
  project.open(TEST_SLUG)
  local path = project.db_path(TEST_SLUG)

  local run_id = db.create_run(path, "test")
  db.abandon_run(path, run_id)

  local found
  for _, r in ipairs(db.get_runs(path)) do
    if r.id == run_id then
      found = r
    end
  end
  assert_eq(found.status, "abandoned", "status")

  -- A completed run keeps its status when abandon is called on it, which is
  -- what teardown does after a normal finish.
  local other = db.create_run(path, "test")
  db.complete_run(path, other)
  db.abandon_run(path, other)
  for _, r in ipairs(db.get_runs(path)) do
    if r.id == other then
      assert_eq(r.status, "completed", "completed run untouched")
    end
  end
end)

test("exam: MCQ digit keys are removed when leaving an MCQ question", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  local api = require("knowledge-builder.init").api
  local db = require("knowledge-builder.db")
  local exam = require("knowledge-builder.exam")
  local topics = db.get_topics(project.db_path(TEST_SLUG))

  local injected = api.inject_run("test", {
    {
      topic_id = topics[1].id,
      kind = "mcq",
      prompt = "Pick one",
      payload = {
        options = { { number = 1, text = "a", correct = true }, { number = 2, text = "b", correct = false } },
      },
    },
    { topic_id = topics[1].id, kind = "open", prompt = "Explain", reference = "r" },
  })
  assert_eq(injected.ok, true, "inject ok")

  exam.open({ id = injected.run_id, questions = db.get_questions(project.db_path(TEST_SLUG), injected.run_id) })
  local state = exam._test.state()
  local bufnr = state.answer_popup.bufnr

  local function digit_maps()
    local n = 0
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == "1" or m.lhs == "2" then
        n = n + 1
      end
    end
    return n
  end

  assert_eq(digit_maps(), 2, "MCQ registers digit shortcuts")
  exam._test.navigate(1)
  assert_eq(digit_maps(), 0, "digit shortcuts cleared on a non-MCQ question")

  -- Digits are ordinary input on a non-MCQ question.
  exam._test.set_answer("my real answer")
  assert_eq(require("knowledge-builder.utils").get_buffer_content(bufnr), "my real answer", "answer intact")

  exam._test.close()
end)

test("review: topics are offered weakest-first with their level", function()
  local project = require("knowledge-builder.project")
  local db = require("knowledge-builder.db")
  local slug = "kb-weak-order"
  if vim.fn.isdirectory(project.dir(slug)) == 1 then
    vim.fn.delete(project.dir(slug), "rf")
  end
  project.create("KB Weak Order", { slug = slug })
  local path = project.db_path(slug)

  project.save_syllabus({
    { name = "Strong", weight = 1.0 },
    { name = "Weak", weight = 1.0 },
  })
  local topics = db.get_topics(path)
  local api = require("knowledge-builder.init").api
  api.inject_run("test", {
    { topic_id = topics[1].id, kind = "open", prompt = "Q1", reference = "r" },
    { topic_id = topics[2].id, kind = "open", prompt = "Q2", reference = "r" },
  })
  api.get_current_question()
  api.submit_answer("a good answer")
  api.get_current_question()
  api.submit_answer("bad")
  api.finalize_run()

  local ranked = require("knowledge-builder.progress").weak_topics()
  assert_eq(ranked[1].topic.name, "Weak", "weakest topic first")
  assert_eq(ranked[2].topic.name, "Strong", "strongest topic last")
  assert_truthy(ranked[1].level < ranked[2].level, "levels ordered")

  vim.fn.delete(project.dir(slug), "rf")
  project.open(TEST_SLUG)
end)

test("tutor context includes weak topics and recent mistakes", function()
  local project = require("knowledge-builder.project")
  local db = require("knowledge-builder.db")
  local slug = "kb-tutor-context"
  if vim.fn.isdirectory(project.dir(slug)) == 1 then
    vim.fn.delete(project.dir(slug), "rf")
  end
  project.create("KB Tutor Context", { slug = slug })
  local path = project.db_path(slug)
  project.save_syllabus({ { name = "Recursion", description = "base cases" } })

  local topics = db.get_topics(path)
  local api = require("knowledge-builder.init").api
  api.inject_run("test", {
    { topic_id = topics[1].id, kind = "open", prompt = "What is a base case?", reference = "r" },
  })
  api.get_current_question()
  api.submit_answer("no idea")
  api.finalize_run()

  local context = require("knowledge-builder.review").tutor_context()
  assert_truthy(context:find("Recursion", 1, true), "names the weak topic")
  assert_truthy(context:find("base case", 1, true), "includes the failed question")
  assert_truthy(context:find("no idea", 1, true), "includes the student's answer")
  assert_truthy(context:find("stub feedback", 1, true), "includes grader feedback")

  vim.fn.delete(project.dir(slug), "rf")
  project.open(TEST_SLUG)
end)

test("progress: overall score is weighted by topic weight", function()
  local project = require("knowledge-builder.project")
  local db = require("knowledge-builder.db")
  local slug = "kb-weighted-overall"
  if vim.fn.isdirectory(project.dir(slug)) == 1 then
    vim.fn.delete(project.dir(slug), "rf")
  end
  project.create("KB Weighted", { slug = slug })
  local path = project.db_path(slug)
  project.save_syllabus({
    { name = "Heavy", weight = 2.0 },
    { name = "Light", weight = 0.5 },
  })
  local topics = db.get_topics(path)

  local api = require("knowledge-builder.init").api
  local injected = api.inject_run("test", {
    { topic_id = topics[1].id, kind = "open", prompt = "Q1", reference = "r" },
    { topic_id = topics[2].id, kind = "open", prompt = "Q2", reference = "r" },
  })
  api.get_current_question()
  api.submit_answer("bad") -- Heavy scores 0.2
  api.get_current_question()
  api.submit_answer("a good answer") -- Light scores 1.0
  api.finalize_run()

  local report = require("knowledge-builder.progress").build_report(injected.run_id)
  -- Unweighted would be 0.6; weighted is (0.2*2 + 1.0*0.5) / 2.5 = 0.36.
  assert_near(report.overall, 0.36, 0.001, "weighted overall")

  vim.fn.delete(project.dir(slug), "rf")
  project.open(TEST_SLUG)
end)

test("active project is restored in a fresh session", function()
  local project = require("knowledge-builder.project")
  project.open(TEST_SLUG)
  -- Simulate a restart: drop the in-memory current project.
  project._clear_current_for_test()
  assert_truthy(project.current() == nil, "no current project after reset")

  local restored = project.require_current()
  assert_truthy(restored, "project restored from disk")
  assert_eq(restored.slug, TEST_SLUG, "restored the last used project")
end)

test("chat trims the transcript sent to the model but keeps the buffer", function()
  local chat = require("knowledge-builder.chat")
  local config = require("knowledge-builder.config")
  local llm = require("knowledge-builder.llm")

  local saved_stream = llm.stream
  local saved_max = config.config.chat.max_history_messages
  config.config.chat.max_history_messages = 4

  local sent
  llm.stream = function(messages, _opts, _on_delta, on_done)
    sent = messages
    on_done("ok")
  end

  chat.open({ title = "Trim test" })
  local state = chat._test.state()
  -- Pre-load a long history, then send one more turn.
  for i = 1, 10 do
    table.insert(state.messages, { role = "user", content = "u" .. i })
    table.insert(state.messages, { role = "assistant", content = "a" .. i })
  end
  require("knowledge-builder.ui").set_lines(state.bufnr, { "> latest question" })
  chat._test.send()

  assert_truthy(sent, "stream called")
  assert_eq(#sent, 5, "system prompt plus the last 4 turns")
  assert_eq(sent[1].role, "system", "system prompt retained")
  assert_eq(sent[#sent].content, "latest question", "newest turn included")
  assert_truthy(#state.messages > 5, "full history kept in state")

  llm.stream = saved_stream
  config.config.chat.max_history_messages = saved_max
  pcall(function()
    state.win:unmount()
  end)
end)

test("llm.probe reports success and failure from the endpoint", function()
  local llm = require("knowledge-builder.llm")
  local saved = vim.system

  vim.system = function()
    return {
      wait = function()
        return { code = 0, stdout = vim.json.encode({ choices = { { message = { content = "hi" } } } }) }
      end,
    }
  end
  local ok, detail = llm.probe(100)
  assert_eq(ok, true, "probe succeeds: " .. tostring(detail))

  vim.system = function()
    return {
      wait = function()
        return { code = 0, stdout = vim.json.encode({ error = { message = "model not found" } }) }
      end,
    }
  end
  local ok2, detail2 = llm.probe(100)
  assert_eq(ok2, false, "probe surfaces API errors")
  assert_truthy(detail2:find("model not found", 1, true), "error message forwarded")

  vim.system = saved
end)

-- Cleanup the test project directory.
test("Cleanup test project", function()
  local project = require("knowledge-builder.project")
  local dir = project.dir(TEST_SLUG)
  if vim.fn.isdirectory(dir) == 1 then
    vim.fn.delete(dir, "rf")
  end
  assert_eq(vim.fn.isdirectory(dir), 0, "dir removed")
end)

io.write("\n" .. string.rep("=", 44) .. "\n")
io.write(string.format("  Results: %d passed, %d failed, %d skipped\n", passed, failed, skipped))
if #errors > 0 then
  io.write("\n  Failures:\n")
  for _, e in ipairs(errors) do
    io.write(string.format("    - %s: %s\n", e.name, e.error))
  end
end
io.write(string.rep("=", 44) .. "\n\n")
io.flush()

os.exit(failed > 0 and 1 or 0)
