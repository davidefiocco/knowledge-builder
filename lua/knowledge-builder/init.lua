-- knowledge-builder - Main entry point
local config = require("knowledge-builder.config")
local project = require("knowledge-builder.project")
local utils = require("knowledge-builder.utils")

local kb = {}

function kb.setup(opts)
  config.setup(opts or {})
  return kb
end

-- :KB start — create a project, gather inputs, build the syllabus.
function kb.start()
  vim.ui.input({ prompt = "Project name: " }, function(name)
    if not name or utils.trim(name) == "" then
      return
    end
    local proj, err = project.create(name)
    if not proj then
      -- Project may already exist; offer to open it instead.
      if err and err:find("already exists") then
        local slug = utils.slugify(name)
        project.open(slug)
        utils.notify("Opened existing project '" .. slug .. "'")
      else
        utils.notify(err or "Failed to create project", "error")
        return
      end
    else
      utils.notify("Created project '" .. proj.slug .. "'")
    end

    vim.ui.input({ prompt = "Paste a file path with JD/CV, or leave blank to type: " }, function(path)
      local function with_inputs(text)
        if not text or utils.trim(text) == "" then
          utils.notify("No inputs provided; you can edit syllabus.md and re-run.", "warn")
          return
        end
        local handle = require("knowledge-builder.spinner").start("Building syllabus")
        require("knowledge-builder.syllabus").build_and_save(text, function(topics, serr)
          if serr then
            handle:cancel()
            utils.notify("Syllabus failed: " .. serr, "error")
            return
          end
          handle:finish(
            string.format("Syllabus ready: %d topics. Run :KB test (or :KB syllabus refine to adjust)", #topics)
          )
          vim.cmd("edit " .. vim.fn.fnameescape(project.syllabus_md_path(project.current().slug)))
        end)
      end

      if path and utils.trim(path) ~= "" and vim.fn.filereadable(path) == 1 then
        with_inputs(table.concat(vim.fn.readfile(path), "\n"))
      else
        vim.ui.input({ prompt = "Describe your goal / paste inputs: " }, with_inputs)
      end
    end)
  end)
end

function kb.open(slug)
  if not slug or slug == "" then
    local projects = project.list()
    if #projects == 0 then
      utils.notify("No projects yet. Run :KB start", "warn")
      return
    end
    local labels = {}
    for _, p in ipairs(projects) do
      table.insert(labels, p.slug)
    end
    vim.ui.select(labels, { prompt = "Open project:" }, function(choice)
      if choice then
        project.open(choice)
        utils.notify("Opened '" .. choice .. "'")
      end
    end)
    return
  end
  local proj, err = project.open(slug)
  if not proj then
    utils.notify(err or "Failed to open", "error")
    return
  end
  utils.notify("Opened '" .. proj.slug .. "'")
end

-- :KB syllabus refine <instruction> — LLM revises the current syllabus.
function kb.syllabus(action, instruction)
  if not project.require_current() then
    return
  end
  if action ~= "refine" then
    utils.notify("Usage: :KB syllabus refine <instruction>", "warn")
    return
  end

  local function run(text)
    if not text or utils.trim(text) == "" then
      utils.notify("No instruction provided", "warn")
      return
    end
    local handle = require("knowledge-builder.spinner").start("Refining syllabus")
    require("knowledge-builder.syllabus").refine(text, function(topics, err, _raw, stats)
      if err then
        handle:cancel()
        utils.notify("Refine failed: " .. err, "error")
        return
      end
      local summary = string.format("Syllabus updated: %d topics", #topics)
      if stats then
        summary = summary
          .. string.format(
            " (%d new, %d kept, %d archived)",
            stats.added,
            stats.updated + stats.restored,
            stats.archived
          )
      end
      handle:finish(summary .. ".")
      vim.cmd("edit! " .. vim.fn.fnameescape(project.syllabus_md_path(project.current().slug)))
    end)
  end

  if instruction and utils.trim(instruction) ~= "" then
    run(instruction)
  else
    vim.ui.input({ prompt = "How should the syllabus change? " }, run)
  end
end

-- :KB test — generate a fresh set of questions over the syllabus, grade them,
-- and record the run. Run it as often as you like; questions differ each time
-- and :KB progress / :KB results track how you do across the sequence of runs.
function kb.test()
  if not project.require_current() then
    return
  end
  require("knowledge-builder.exam").run("test")
end

function kb.review(topic)
  if not project.require_current() then
    return
  end
  require("knowledge-builder.review").start(topic)
end

function kb.tutor()
  if not project.require_current() then
    return
  end
  require("knowledge-builder.review").tutor()
end

function kb.progress()
  if not project.require_current() then
    return
  end
  require("knowledge-builder.progress").show()
end

-- :KB results [run_id] — per-question grading report. With no id, shows the
-- latest completed run; with multiple completed runs, offers a picker.
function kb.results(run_arg)
  if not project.require_current() then
    return
  end
  local progress = require("knowledge-builder.progress")

  local explicit = run_arg and tonumber(run_arg)
  if explicit then
    progress.show_results(explicit)
    return
  end

  local completed = progress.completed_runs()
  if #completed == 0 then
    utils.notify("No completed runs yet. Run :KB test first.", "warn")
    return
  end
  if #completed == 1 then
    progress.show_results(completed[1].id)
    return
  end

  local labels = {}
  for _, r in ipairs(completed) do
    table.insert(labels, string.format("#%d  %s  (%s)", r.id, r.phase, r.completed_at or r.status))
  end
  vim.ui.select(labels, { prompt = "Show results for which run?" }, function(_, idx)
    if idx then
      progress.show_results(completed[idx].id)
    end
  end)
end

function kb.list()
  local projects = project.list()
  if #projects == 0 then
    utils.notify("No projects yet. Run :KB start", "info")
    return
  end
  local lines = {}
  for _, p in ipairs(projects) do
    table.insert(lines, "  " .. p.slug .. "  (" .. p.name .. ")")
  end
  utils.notify("Projects:\n" .. table.concat(lines, "\n"))
end

-- A compact in-editor cheat sheet of commands and keys.
local HELP_LINES = {
  "",
  "  knowledge-builder — test → review → re-test learning loop",
  "  " .. string.rep("=", 60),
  "",
  "  Build your syllabus from a job description, CV, or goals; test",
  "  yourself, review weak topics with a tutor, then test again and track",
  "  progress against your past self.",
  "",
  "  COMMANDS",
  "    :KB start                 Create a project + build the syllabus",
  "    :KB open [name]           Open an existing project (picker if blank)",
  "    :KB list                  List projects",
  "    :KB syllabus refine <…>   Revise the syllabus from an instruction",
  "    :KB test                  Take a test (fresh questions each run)",
  "    :KB review [topic]        Generate study material for a topic",
  "    :KB tutor                 Open the streaming tutor chat",
  "    :KB progress              Per-topic levels vs. your previous run",
  "    :KB results [run]         Per-question grades, answers & feedback",
  "    :KB help                  Show this cheat sheet",
  "",
  "  EXAM KEYS",
  "    C-s grade · C-n/C-p next/prev · C-f finish · C-g hint · q close",
  "    1-9 choose an MCQ option",
  "",
  "  TUTOR KEYS",
  "    C-s send · q close",
  "",
  "  Diagnostics:  :checkhealth knowledge-builder",
  "  Full help:    :help knowledge-builder",
  "",
  "  (q to close)",
}

function kb.help()
  local ui = require("knowledge-builder.ui")
  local win = ui.float({ width = 0.7, height = 0.7, title = "knowledge-builder help" })
  ui.set_lines(win.bufnr, HELP_LINES, { lock = true })
  ui.map_close(win.bufnr, function()
    win:unmount()
  end)
end

-- Expose the scriptable API for headless/test use.
kb.api = require("knowledge-builder.api")

return kb
