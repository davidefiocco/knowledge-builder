-- knowledge-builder - Project management
--
-- A "project" is a directory under the configured workspace root. It owns:
--   <workspace>/<slug>/knowledge.db    SQLite DB (schema.sql)
--   <workspace>/<slug>/syllabus.md     human-readable syllabus (editable)
--   <workspace>/<slug>/syllabus.json   structured syllabus (source of truth)
--   <workspace>/<slug>/materials/      generated review material
--
-- The project owns ONE persistent syllabus; test/review runs reuse it.
local config = require("knowledge-builder.config")
local db = require("knowledge-builder.db")
local utils = require("knowledge-builder.utils")

local project = {}

local current = nil

local function workspace()
  return config.get("storage.workspace")
end

-- The slug of the last project opened, so a new Neovim session picks up where
-- the previous one left off instead of demanding `:KB open` every time.
local function last_project_file()
  return workspace() .. "/.last-project"
end

local function remember(slug)
  pcall(vim.fn.writefile, { slug }, last_project_file())
end

local function recall()
  local path = last_project_file()
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local lines = vim.fn.readfile(path)
  local slug = utils.trim(lines[1] or "")
  return slug ~= "" and slug or nil
end

function project.dir(slug)
  return workspace() .. "/" .. slug
end

function project.db_path(slug)
  return project.dir(slug) .. "/knowledge.db"
end

function project.syllabus_json_path(slug)
  return project.dir(slug) .. "/syllabus.json"
end

function project.syllabus_md_path(slug)
  return project.dir(slug) .. "/syllabus.md"
end

function project.materials_dir(slug)
  return project.dir(slug) .. "/materials"
end

function project.list()
  local root = workspace()
  vim.fn.mkdir(root, "p")
  local result = {}
  for _, name in ipairs(vim.fn.readdir(root) or {}) do
    local dir = root .. "/" .. name
    if vim.fn.isdirectory(dir) == 1 and vim.fn.filereadable(dir .. "/knowledge.db") == 1 then
      local meta = db.get_project(dir .. "/knowledge.db") or {}
      table.insert(result, {
        slug = name,
        name = meta.name or name,
        dir = dir,
      })
    end
  end
  table.sort(result, function(a, b)
    return a.slug < b.slug
  end)
  return result
end

-- Create a new project directory and initialise its DB.
function project.create(name, opts)
  opts = opts or {}
  local slug = opts.slug or utils.slugify(name)
  local dir = project.dir(slug)
  if vim.fn.isdirectory(dir) == 1 then
    return nil, "Project '" .. slug .. "' already exists"
  end
  vim.fn.mkdir(project.materials_dir(slug), "p")

  local path = project.db_path(slug)
  db.init_project(path, {
    name = name,
    slug = slug,
    description = opts.description or "",
    source_inputs = opts.source_inputs or "",
  })

  current = { slug = slug, name = name, dir = dir, db = path }
  remember(slug)
  return current
end

function project.open(slug)
  local dir = project.dir(slug)
  if vim.fn.filereadable(dir .. "/knowledge.db") ~= 1 then
    return nil, "No project named '" .. slug .. "'"
  end
  local path = project.db_path(slug)
  local meta = db.get_project(path) or {}
  current = { slug = slug, name = meta.name or slug, dir = dir, db = path }
  remember(slug)
  return current
end

function project.current()
  return current
end

-- Re-open the project this workspace was last using. Returns it, or nil if
-- there is no record or the directory has since gone away.
function project.restore_last()
  if current then
    return current
  end
  local slug = recall()
  if not slug then
    return nil
  end
  return project.open(slug)
end

-- Returns the current project or nil with a notify. Falls back to the last
-- project used, so commands work straight after a Neovim restart.
function project.require_current()
  if current then
    return current
  end
  local restored = project.restore_last()
  if restored then
    utils.notify("Resumed project '" .. restored.slug .. "'")
    return restored
  end
  utils.notify("No active project. Run :KB start or :KB open <name>", "warn")
  return nil
end

-- Write both the structured and human-readable syllabus files alongside the DB
-- and persist topics to the project DB.
-- Returns false on failure, otherwise a { added, updated, archived, restored }
-- summary of how the syllabus changed.
function project.save_syllabus(topics)
  local proj = project.require_current()
  if not proj then
    return false
  end
  local stats = db.replace_topics(proj.db, topics)

  vim.fn.writefile(vim.split(utils.json_encode({ topics = topics }), "\n"), project.syllabus_json_path(proj.slug))

  local md = { "# Syllabus: " .. proj.name, "" }
  for i, topic in ipairs(topics) do
    table.insert(md, string.format("## %d. %s", i, topic.name))
    if topic.description and topic.description ~= "" then
      table.insert(md, "")
      table.insert(md, topic.description)
    end
    table.insert(md, "")
  end
  vim.fn.writefile(md, project.syllabus_md_path(proj.slug))
  return stats
end

function project._set_current_for_test(slug)
  return project.open(slug)
end

-- Simulate a fresh Neovim session (in-memory state gone, on-disk record kept).
function project._clear_current_for_test()
  current = nil
end

return project
