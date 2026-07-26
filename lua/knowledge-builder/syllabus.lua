-- knowledge-builder - Syllabus extraction
--
-- Turns free-form user inputs (job description, CV, notes) into a structured
-- list of topics, persisted to the active project.
local llm = require("knowledge-builder.llm")
local project = require("knowledge-builder.project")
local utils = require("knowledge-builder.utils")

local syllabus = {}

local SYSTEM_PROMPT = table.concat({
  "You are a curriculum designer. Given a user's inputs (which may include a job",
  "description, CV/resume, and free-form goals), produce a focused syllabus of the",
  "subjects they should master.",
  "",
  "Return ONLY a JSON object of this exact shape, no prose, no markdown fences:",
  '{ "topics": [',
  '  { "name": "Short topic name", "description": "1-2 sentence scope", "weight": 1.0 }',
  "] }",
  "",
  "Rules:",
  "- Between 4 and 10 topics, ordered from foundational to advanced.",
  "- weight is a float 0.5-2.0 reflecting how central the topic is to the user's goal.",
  "- Topics must be specific and assessable (e.g. 'SQL window functions', not 'databases').",
}, "\n")

-- Build the structured prompt and ask the model. callback(topics, err).
function syllabus.generate(source_inputs, callback)
  local user_prompt = "## User inputs\n\n" .. (source_inputs or "")
  llm.chat_json(SYSTEM_PROMPT, user_prompt, function(decoded, err, raw)
    if err then
      callback(nil, err, raw)
      return
    end
    local topics = decoded.topics or decoded
    if type(topics) ~= "table" or #topics == 0 then
      callback(nil, "Model returned no topics", raw)
      return
    end
    local cleaned = {}
    for _, t in ipairs(topics) do
      if type(t) == "table" and t.name and utils.trim(t.name) ~= "" then
        table.insert(cleaned, {
          name = utils.trim(t.name),
          description = utils.trim(t.description or ""),
          weight = tonumber(t.weight) or 1.0,
          source = "llm",
        })
      end
    end
    if #cleaned == 0 then
      callback(nil, "No valid topics parsed", raw)
      return
    end
    callback(cleaned)
  end)
end

-- Generate and persist to the active project.
function syllabus.build_and_save(source_inputs, callback)
  syllabus.generate(source_inputs, function(topics, err, raw)
    if err then
      callback(nil, err, raw)
      return
    end
    local proj = project.current()
    if proj then
      require("knowledge-builder.db").init_project(proj.db, {
        name = proj.name,
        slug = proj.slug,
        source_inputs = source_inputs or "",
      })
    end
    local ok = project.save_syllabus(topics)
    if not ok then
      callback(nil, "Failed to save syllabus")
      return
    end
    callback(topics)
  end)
end

-- Re-read topics from the active project's DB.
function syllabus.load()
  local proj = project.current()
  if not proj then
    return {}
  end
  return require("knowledge-builder.db").get_topics(proj.db)
end

local REFINE_SYSTEM_PROMPT = table.concat({
  "You are a curriculum designer revising an existing syllabus based on the user's",
  "instruction (e.g. add/remove/merge/split/reorder/reweight topics).",
  "",
  "Return ONLY a JSON object of this exact shape, no prose, no markdown fences:",
  '{ "topics": [',
  '  { "name": "Short topic name", "description": "1-2 sentence scope", "weight": 1.0 }',
  "] }",
  "",
  "Rules:",
  "- Apply the instruction faithfully; keep unaffected topics intact.",
  "- Preserve a sensible foundational-to-advanced ordering.",
  "- weight is a float 0.5-2.0 reflecting how central the topic is.",
  "- Topics must be specific and assessable.",
}, "\n")

-- Revise the active project's syllabus from a natural-language instruction and
-- persist the result. callback(topics, err).
function syllabus.refine(instruction, callback)
  local proj = project.current()
  if not proj then
    callback(nil, "No active project")
    return
  end
  local current_topics = require("knowledge-builder.db").get_topics(proj.db)
  if #current_topics == 0 then
    callback(nil, "Project has no syllabus yet. Run :KB start first.")
    return
  end

  local lines = { "## Current syllabus" }
  for i, t in ipairs(current_topics) do
    table.insert(
      lines,
      string.format("%d. %s (weight %s): %s", i, t.name, tostring(t.weight or 1.0), t.description or "")
    )
  end
  table.insert(lines, "")
  table.insert(lines, "## Instruction")
  table.insert(lines, instruction or "")
  local user_prompt = table.concat(lines, "\n")

  llm.chat_json(REFINE_SYSTEM_PROMPT, user_prompt, function(decoded, err, raw)
    if err then
      callback(nil, err, raw)
      return
    end
    local topics = decoded.topics or decoded
    if type(topics) ~= "table" or #topics == 0 then
      callback(nil, "Model returned no topics", raw)
      return
    end
    local cleaned = {}
    for _, t in ipairs(topics) do
      if type(t) == "table" and t.name and utils.trim(t.name) ~= "" then
        table.insert(cleaned, {
          name = utils.trim(t.name),
          description = utils.trim(t.description or ""),
          weight = tonumber(t.weight) or 1.0,
          source = "llm",
        })
      end
    end
    if #cleaned == 0 then
      callback(nil, "No valid topics parsed", raw)
      return
    end
    local stats = project.save_syllabus(cleaned)
    if not stats then
      callback(nil, "Failed to save syllabus")
      return
    end
    callback(cleaned, nil, raw, stats)
  end)
end

return syllabus
