-- Manual end-to-end smoke test driven by a LOCAL Ollama model as the user.
--
-- The plugin (syllabus/questions/grading) AND the simulated user both run
-- against local Ollama via its OpenAI-compatible endpoint. The full transcript
-- is written to $KB_TRANSCRIPT (default /tmp/kb_transcript.json) so a human (or
-- another agent) can judge whether the machinery behaved correctly.
--
-- Run (no token needed for a local endpoint):
--   KB_WORKSPACE=$(mktemp -d) \
--     nvim --headless -u dev/init.lua -l test/ollama_smoke.lua

local OLLAMA_URL = os.getenv("OLLAMA_URL") or "http://localhost:11434/v1/chat/completions"
local MODEL = os.getenv("KB_OLLAMA_MODEL") or "gemma4:12b-it-qat"
local TRANSCRIPT_PATH = os.getenv("KB_TRANSCRIPT") or "/tmp/kb_transcript.json"

-- Point the plugin at local Ollama. No token is set, so the client omits the
-- Authorization header (Ollama ignores it anyway).
require("knowledge-builder").setup({
  storage = { workspace = os.getenv("KB_WORKSPACE") },
  llm = {
    api_url = OLLAMA_URL,
    model = MODEL,
    -- No token needed for a local endpoint; the Authorization header is
    -- omitted automatically when the token env var is unset.
    -- Generous budget: gemma4 is a thinking model and spends tokens on
    -- reasoning before the visible answer/JSON.
    max_tokens = 2048,
    temperature = 0.4,
    grading_temperature = 0.1,
  },
  assess = { questions_per_topic = 1, pass_threshold = 0.6 },
})

local api = require("knowledge-builder.api")
local utils = require("knowledge-builder.utils")

local function log(msg)
  io.write(msg .. "\n")
  io.flush()
end

-- A blocking Ollama chat call for the simulated user (separate from the plugin).
local function user_llm(prompt)
  local payload = vim.json.encode({
    model = MODEL,
    messages = {
      {
        role = "system",
        content = "You are a mid-level software engineer taking a knowledge test. "
          .. "Answer each question genuinely at that level, concisely. "
          .. "For multiple choice, reply exactly 'Answer: <number>'.",
      },
      { role = "user", content = prompt },
    },
    max_tokens = 2048,
    stream = false,
  })
  local result = vim
    .system({
      "curl",
      "-s",
      OLLAMA_URL,
      "-H",
      "Content-Type: application/json",
      "-d",
      payload,
    }, { text = true })
    :wait()
  local body = utils.json_decode(result.stdout)
  local choice = body and body.choices and body.choices[1]
  return choice and choice.message and choice.message.content or "(no answer)"
end

local transcript = { model = MODEL, exchanges = {} }

log("== Ollama smoke test (" .. MODEL .. ") ==")

-- 1. Project
local created = api.create_project({ name = "Ollama Smoke", source_inputs = "Python backend engineer" })
assert(created.ok, "create_project failed: " .. vim.inspect(created))
log("project: " .. created.slug)

-- 2. Syllabus (plugin -> Ollama)
log("building syllabus...")
local built =
  api.build_syllabus("Junior-to-mid Python backend engineer: REST APIs, SQL databases, and automated testing.", 180000)
assert(built.ok, "build_syllabus failed: " .. vim.inspect(built))

-- Local single-instance Ollama serializes requests and each thinking-model
-- call is slow, so cap the syllabus to keep the run tractable for a smoke test.
local MAX_TOPICS = tonumber(os.getenv("KB_MAX_TOPICS") or "2")
if #built.topics > MAX_TOPICS then
  local trimmed = {}
  for i = 1, MAX_TOPICS do
    trimmed[i] = built.topics[i]
  end
  api.set_syllabus(trimmed)
  built.topics = trimmed
end

transcript.syllabus = built.topics
log("syllabus topics (capped to " .. MAX_TOPICS .. "): " .. #built.topics)
for _, t in ipairs(built.topics) do
  log("  - " .. t.name)
end

-- 3. Start a test run (plugin -> Ollama generates questions)
log("generating questions...")
local run = api.start_run("test", 300000)
assert(run.ok, "start_run failed: " .. vim.inspect(run))
transcript.run_id = run.run_id
log("questions: " .. run.total)

-- 4. Answer each question with the user LLM, grade via the plugin
while true do
  local cur = api.get_current_question()
  assert(cur.ok, "get_current_question failed: " .. vim.inspect(cur))
  if cur.done then
    break
  end
  local q = cur.question
  local prompt = "## Question (" .. q.kind .. ")\n" .. q.prompt
  if q.kind == "mcq" and q.payload and q.payload.options then
    local opts = {}
    for _, o in ipairs(q.payload.options) do
      table.insert(opts, o.number .. ". " .. o.text)
    end
    prompt = prompt .. "\n\n## Options\n" .. table.concat(opts, "\n")
  end

  log(string.format("Q%d/%d [%s]: answering...", cur.index, cur.total, q.kind))
  local answer = user_llm(prompt)
  local graded = api.submit_answer(answer, 180000)
  assert(graded.ok, "submit_answer failed: " .. vim.inspect(graded))

  table.insert(transcript.exchanges, {
    index = cur.index,
    kind = q.kind,
    difficulty = q.difficulty,
    prompt = q.prompt,
    options = q.payload and q.payload.options or nil,
    answer = answer,
    score = graded.score,
    passed = graded.passed,
    feedback = graded.feedback,
  })
  log(string.format("  -> score %.2f (%s)", graded.score or -1, graded.feedback or ""))

  if graded.run_finished then
    break
  end
end

-- 5. Finalize + levels
local final = api.finalize_run()
assert(final.ok, "finalize_run failed: " .. vim.inspect(final))
transcript.levels = final.levels
transcript.progress = final.progress

-- 6. Generate review material for the first topic (the learning artifact) and
-- capture it for judging usefulness.
log("generating review material for: " .. built.topics[1].name .. " ...")
local review_done, review_content = false, nil
local review_llm = require("knowledge-builder.llm")
review_llm.chat({
  {
    role = "system",
    content = "You are an expert technical writer. Produce concise, well-structured review "
      .. "material in Markdown: a short overview, key concepts, one worked example, and "
      .. "3 self-check questions. Do not wrap the document in a code fence.",
  },
  {
    role = "user",
    content = "## Topic\n" .. built.topics[1].name .. "\n\n## Scope\n" .. (built.topics[1].description or ""),
  },
}, { max_tokens = 2048 }, function(content, err)
  review_content = err and ("(error: " .. err .. ")") or content
  review_done = true
end)
vim.wait(180000, function()
  return review_done
end, 100)
transcript.review_material = { topic = built.topics[1].name, content = review_content }
log("review material chars: " .. #(review_content or ""))

vim.fn.writefile(vim.split(vim.json.encode(transcript), "\n"), TRANSCRIPT_PATH)
log("\ntranscript written to " .. TRANSCRIPT_PATH)
log("DONE")

os.exit(0)
