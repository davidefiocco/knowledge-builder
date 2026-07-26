-- knowledge-builder - Review material generation
--
-- Generates study material for a topic (or the whole syllabus), saves it under
-- the project's materials/ directory, opens it, and offers the tutor chat.
local chat = require("knowledge-builder.chat")
local db = require("knowledge-builder.db")
local llm = require("knowledge-builder.llm")
local project = require("knowledge-builder.project")
local utils = require("knowledge-builder.utils")

local review = {}

local SYSTEM_PROMPT = table.concat({
  "You are an expert technical writer. Produce concise, well-structured review",
  "material in Markdown for the given topic. Include: a short overview, key",
  "concepts with brief explanations, one or two worked examples, and 3-5",
  "self-check questions at the end. Do not wrap the whole document in a code fence.",
}, "\n")

-- Offer topics weakest-first with their current level, so the obvious next
-- thing to review is the first thing in the list.
local function pick_topic(callback)
  local proj = project.require_current()
  if not proj then
    return
  end
  local ranked = require("knowledge-builder.progress").weak_topics()
  if #ranked == 0 then
    utils.notify("No syllabus yet. Run :KB start first.", "warn")
    return
  end
  local labels = {}
  for _, row in ipairs(ranked) do
    local level = row.level and string.format("%3d%%", math.floor(row.level * 100 + 0.5)) or " -- "
    table.insert(labels, string.format("%s  %s", level, row.topic.name))
  end
  vim.ui.select(labels, { prompt = "Review which topic? (weakest first)" }, function(choice, idx)
    if choice and idx then
      callback(ranked[idx].topic)
    end
  end)
end

local function generate_for(topic)
  local proj = project.current()
  local handle = require("knowledge-builder.spinner").start("Generating review material", { detail = topic.name })
  local user = string.format("## Topic\n%s\n\n## Scope\n%s", topic.name, topic.description or "")
  llm.chat({
    { role = "system", content = SYSTEM_PROMPT },
    { role = "user", content = user },
  }, { max_tokens = 2048 }, function(content, err)
    if err then
      handle:cancel()
      utils.notify("Generation failed: " .. err, "error")
      return
    end
    local path = project.materials_dir(proj.slug) .. "/" .. utils.slugify(topic.name) .. ".md"
    vim.fn.writefile(utils.split_lines(content), path)

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    handle:finish("Saved material to " .. path .. " — :KB tutor to discuss")
    review._last_topic = topic
  end)
end

-- :KB review [topic]
function review.start(topic_name)
  local proj = project.require_current()
  if not proj then
    return
  end
  if topic_name and topic_name ~= "" then
    local topics = db.get_topics(proj.db)
    for _, t in ipairs(topics) do
      if t.name:lower():find(topic_name:lower(), 1, true) then
        generate_for(t)
        return
      end
    end
    utils.notify("No topic matching '" .. topic_name .. "'", "warn")
    return
  end
  pick_topic(generate_for)
end

-- Assemble what the tutor should know: the topic in focus, the weakest topics
-- from the latest run, and the questions you actually got wrong (with the
-- grader's feedback) so it can address the real gaps rather than guess.
function review.tutor_context()
  local proj = project.current()
  local parts = {}

  if review._last_topic then
    table.insert(parts, "Focus topic: " .. review._last_topic.name .. " — " .. (review._last_topic.description or ""))
  end
  if not proj then
    return table.concat(parts, "\n\n")
  end

  local ranked = require("knowledge-builder.progress").weak_topics()
  local weak = {}
  for i, row in ipairs(ranked) do
    if i > 3 then
      break
    end
    if row.level ~= nil then
      table.insert(weak, string.format("%s (%d%%)", row.topic.name, math.floor(row.level * 100 + 0.5)))
    else
      table.insert(weak, row.topic.name .. " (not yet tested)")
    end
  end
  if #weak > 0 then
    table.insert(parts, "Weakest topics: " .. table.concat(weak, ", "))
  end

  local failures = db.get_recent_failures(proj.db, 5)
  if #failures > 0 then
    local lines = { "Recent questions the student got wrong:" }
    for _, f in ipairs(failures) do
      table.insert(lines, string.format("- [%s] %s", f.topic_name or "general", utils.trim(f.prompt or "")))
      if utils.trim(f.answer or "") ~= "" then
        table.insert(lines, "  Their answer: " .. utils.trim(f.answer))
      end
      if utils.trim(f.llm_feedback or "") ~= "" then
        table.insert(lines, "  Grader said: " .. utils.trim(f.llm_feedback))
      end
    end
    table.insert(parts, table.concat(lines, "\n"))
  end

  return table.concat(parts, "\n\n")
end

-- :KB tutor — open the streaming tutor, grounded in the student's weak spots.
function review.tutor()
  local context = review.tutor_context()
  chat.open({ context = context ~= "" and context or nil, title = "Tutor" })
end

return review
