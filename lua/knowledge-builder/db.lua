-- knowledge-builder - Per-project SQLite layer
--
-- One DB per project directory. `db.connect(path)` caches connections keyed by
-- path.
local utils = require("knowledge-builder.utils")

local ok_sqlite, sqlite = pcall(require, "sqlite")
if not ok_sqlite then
  utils.notify("sqlite.lua not found. Install kkharji/sqlite.lua", "error")
  return {}
end

local db = {}
local connections = {}

-- sqlite.lua returns an unwrapped table for single-row results; normalise.
local function normalize_rows(results)
  if type(results) ~= "table" then
    return {}
  end
  if results[1] then
    return results
  end
  if next(results) ~= nil then
    return { results }
  end
  return {}
end

local function normalize_single(results)
  local rows = normalize_rows(results)
  return rows[1]
end

local function read_schema()
  local src = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(src, ":h:h:h")
  return vim.fn.readfile(plugin_root .. "/schema.sql")
end

local function create_tables(conn)
  -- Strip whole-line comments first so stray punctuation in comments never
  -- leaks into the statement that follows when splitting on ';'.
  local code_lines = {}
  for _, line in ipairs(read_schema()) do
    if not utils.trim(line):match("^%-%-") then
      table.insert(code_lines, line)
    end
  end
  local schema = table.concat(code_lines, "\n")
  for stmt in schema:gmatch("[^;]+") do
    stmt = utils.trim(stmt)
    if stmt ~= "" then
      conn:eval(stmt)
    end
  end
end

local function table_exists(conn, name)
  local rows =
    normalize_rows(conn:eval("SELECT name FROM sqlite_master WHERE type='table' AND name = :n", { n = name }))
  return #rows > 0
end

local function has_column(conn, tbl, column)
  for _, row in ipairs(normalize_rows(conn:eval("PRAGMA table_info(" .. tbl .. ")"))) do
    if row.name == column then
      return true
    end
  end
  return false
end

-- Bring a pre-existing database up to the current schema. Runs BEFORE
-- create_tables so that the unique indexes declared in schema.sql can be
-- created against already-deduplicated data.
local function migrate(conn)
  if table_exists(conn, "topics") then
    if not has_column(conn, "topics", "archived") then
      conn:eval("ALTER TABLE topics ADD COLUMN archived INTEGER NOT NULL DEFAULT 0")
    end
    -- Collapse duplicate topic names onto the lowest id, repointing anything
    -- that referenced the losing rows so no history is lost.
    local dupes = normalize_rows(conn:eval([[
      SELECT t.id AS dupe_id, (SELECT MIN(k.id) FROM topics k WHERE k.name = t.name) AS keep_id
      FROM topics t
      WHERE t.id > (SELECT MIN(k.id) FROM topics k WHERE k.name = t.name)
    ]]))
    for _, row in ipairs(dupes) do
      conn:eval(
        "UPDATE questions SET topic_id = :keep WHERE topic_id = :dupe",
        { keep = row.keep_id, dupe = row.dupe_id }
      )
      conn:eval("UPDATE levels SET topic_id = :keep WHERE topic_id = :dupe", { keep = row.keep_id, dupe = row.dupe_id })
      conn:eval("DELETE FROM topics WHERE id = :dupe", { dupe = row.dupe_id })
    end
    if #dupes > 0 then
      -- Merging topics can leave two snapshots for the same run; keep the last.
      conn:eval("DELETE FROM levels WHERE id NOT IN (SELECT MAX(id) FROM levels GROUP BY run_id, topic_id)")
    end
  end

  -- Keep only the most recent response per question (see schema.sql).
  if table_exists(conn, "responses") then
    conn:eval("DELETE FROM responses WHERE id NOT IN (SELECT MAX(id) FROM responses GROUP BY question_id)")
  end
end

function db.connect(path)
  assert(path and path ~= "", "db.connect requires a path")
  if connections[path] then
    return connections[path]
  end

  local conn = sqlite.new(path)
  if not conn then
    error("Failed to open database at: " .. path)
  end
  conn:open()
  conn:eval("PRAGMA foreign_keys = ON")
  migrate(conn)
  create_tables(conn)
  connections[path] = conn
  return conn
end

function db.close(path)
  local conn = connections[path]
  if conn then
    pcall(function()
      conn:close()
    end)
    connections[path] = nil
  end
end

-- Project metadata (single row, id = 1) ------------------------------------

function db.init_project(path, meta)
  local conn = db.connect(path)
  conn:eval(
    [[INSERT OR REPLACE INTO project (id, name, slug, description, source_inputs)
      VALUES (1, :name, :slug, :description, :source_inputs)]],
    {
      name = meta.name,
      slug = meta.slug,
      description = meta.description or "",
      source_inputs = meta.source_inputs or "",
    }
  )
end

function db.get_project(path)
  local conn = db.connect(path)
  return normalize_single(conn:eval("SELECT * FROM project WHERE id = 1"))
end

-- Topics (the syllabus) -----------------------------------------------------

-- Set the syllabus to exactly `topics`, preserving topic ids across calls.
--
-- Topics are matched by name: an existing one is updated in place (keeping its
-- id, and therefore its level history), a new one is inserted, and one that has
-- dropped out of the syllabus is ARCHIVED. Archiving keeps the row alive, which
-- is what keeps its `levels` rows from cascading away.
--
-- Returns { added, updated, archived, restored } for reporting.
function db.replace_topics(path, topics)
  local conn = db.connect(path)
  local stats = { added = 0, updated = 0, archived = 0, restored = 0 }

  local existing = {}
  for _, row in ipairs(normalize_rows(conn:eval("SELECT id, name, archived FROM topics"))) do
    existing[row.name] = row
  end

  conn:eval("BEGIN")
  local ok, err = pcall(function()
    local keep = {}
    for i, topic in ipairs(topics) do
      local prior = existing[topic.name]
      if prior then
        conn:eval(
          [[UPDATE topics SET description = :description, weight = :weight, source = :source,
              position = :position, archived = 0 WHERE id = :id]],
          {
            id = prior.id,
            description = topic.description or "",
            weight = topic.weight or 1.0,
            source = topic.source or "",
            position = i,
          }
        )
        keep[prior.id] = true
        if prior.archived == 1 then
          stats.restored = stats.restored + 1
        else
          stats.updated = stats.updated + 1
        end
      else
        conn:eval(
          [[INSERT INTO topics (name, description, weight, source, position, archived)
            VALUES (:name, :description, :weight, :source, :position, 0)]],
          {
            name = topic.name,
            description = topic.description or "",
            weight = topic.weight or 1.0,
            source = topic.source or "",
            position = i,
          }
        )
        local row = normalize_single(conn:eval("SELECT last_insert_rowid() as id"))
        if row then
          keep[row.id] = true
        end
        stats.added = stats.added + 1
      end
    end

    for _, row in ipairs(normalize_rows(conn:eval("SELECT id, archived FROM topics"))) do
      if not keep[row.id] and row.archived ~= 1 then
        conn:eval("UPDATE topics SET archived = 1 WHERE id = :id", { id = row.id })
        stats.archived = stats.archived + 1
      end
    end
  end)

  if not ok then
    conn:eval("ROLLBACK")
    error(err)
  end
  conn:eval("COMMIT")
  return stats
end

-- Active syllabus topics. Pass { include_archived = true } to also get topics
-- that have since been dropped (needed to label questions from older runs).
function db.get_topics(path, opts)
  opts = opts or {}
  local conn = db.connect(path)
  if opts.include_archived then
    return normalize_rows(conn:eval("SELECT * FROM topics ORDER BY position, id"))
  end
  return normalize_rows(conn:eval("SELECT * FROM topics WHERE archived = 0 ORDER BY position, id"))
end

-- Runs ----------------------------------------------------------------------

function db.create_run(path, phase)
  local conn = db.connect(path)
  conn:eval("INSERT INTO runs (phase, status) VALUES (:phase, 'in_progress')", { phase = phase })
  local row = normalize_single(conn:eval("SELECT last_insert_rowid() as id"))
  return row and row.id
end

function db.complete_run(path, run_id)
  local conn = db.connect(path)
  conn:eval("UPDATE runs SET status = 'completed', completed_at = CURRENT_TIMESTAMP WHERE id = :id", { id = run_id })
end

-- Mark a run the user walked away from. Guarded on 'in_progress' so calling it
-- after a run has already been finalized is a no-op.
function db.abandon_run(path, run_id)
  local conn = db.connect(path)
  conn:eval(
    [[UPDATE runs SET status = 'abandoned', completed_at = CURRENT_TIMESTAMP
      WHERE id = :id AND status = 'in_progress']],
    { id = run_id }
  )
end

function db.get_runs(path, phase)
  local conn = db.connect(path)
  if phase then
    return normalize_rows(conn:eval("SELECT * FROM runs WHERE phase = :phase ORDER BY id", { phase = phase }))
  end
  return normalize_rows(conn:eval("SELECT * FROM runs ORDER BY id"))
end

-- Questions -----------------------------------------------------------------

function db.add_question(path, run_id, q)
  local conn = db.connect(path)
  conn:eval(
    [[INSERT INTO questions (run_id, topic_id, kind, difficulty, prompt, reference, payload, position)
      VALUES (:run_id, :topic_id, :kind, :difficulty, :prompt, :reference, :payload, :position)]],
    {
      run_id = run_id,
      topic_id = q.topic_id,
      kind = q.kind,
      difficulty = q.difficulty or "medium",
      prompt = q.prompt,
      reference = q.reference or "",
      payload = type(q.payload) == "string" and q.payload or utils.json_encode(q.payload or {}),
      position = q.position or 0,
    }
  )
  local row = normalize_single(conn:eval("SELECT last_insert_rowid() as id"))
  return row and row.id
end

function db.get_questions(path, run_id)
  local conn = db.connect(path)
  return normalize_rows(
    conn:eval("SELECT * FROM questions WHERE run_id = :run_id ORDER BY position, id", { run_id = run_id })
  )
end

function db.get_question(path, question_id)
  local conn = db.connect(path)
  return normalize_single(conn:eval("SELECT * FROM questions WHERE id = :id", { id = question_id }))
end

-- Responses -----------------------------------------------------------------

-- Record an answer, replacing any existing one for the question so there is
-- exactly one authoritative response per question.
function db.add_response(path, run_id, question_id, resp)
  local conn = db.connect(path)
  conn:eval("DELETE FROM responses WHERE question_id = :question_id", { question_id = question_id })
  conn:eval(
    [[INSERT INTO responses (question_id, run_id, answer, score, passed, llm_feedback)
      VALUES (:question_id, :run_id, :answer, :score, :passed, :llm_feedback)]],
    {
      question_id = question_id,
      run_id = run_id,
      answer = resp.answer or "",
      score = resp.score,
      passed = resp.passed and 1 or 0,
      llm_feedback = resp.llm_feedback or "",
    }
  )
end

function db.get_responses(path, run_id)
  local conn = db.connect(path)
  return normalize_rows(conn:eval("SELECT * FROM responses WHERE run_id = :run_id ORDER BY id", { run_id = run_id }))
end

-- Levels (per-topic snapshots) ----------------------------------------------

function db.set_level(path, run_id, topic_id, score)
  local conn = db.connect(path)
  conn:eval(
    "INSERT INTO levels (run_id, topic_id, score) VALUES (:run_id, :topic_id, :score)",
    { run_id = run_id, topic_id = topic_id, score = score }
  )
end

function db.get_levels(path, run_id)
  local conn = db.connect(path)
  return normalize_rows(conn:eval("SELECT * FROM levels WHERE run_id = :run_id", { run_id = run_id }))
end

-- Most recent completed run's level per topic, optionally before a given run.
function db.get_latest_levels(path, before_run_id)
  local conn = db.connect(path)
  local query = [[
    SELECT l.topic_id, l.score, l.run_id
    FROM levels l
    JOIN runs r ON r.id = l.run_id
    WHERE r.status = 'completed'
  ]]
  local params = {}
  if before_run_id then
    query = query .. " AND l.run_id < :before"
    params.before = before_run_id
  end
  query = query .. " ORDER BY l.run_id DESC"
  local rows = normalize_rows(conn:eval(query, params))

  local latest = {}
  for _, row in ipairs(rows) do
    if latest[row.topic_id] == nil then
      latest[row.topic_id] = row.score
    end
  end
  return latest
end

-- Every recorded level, oldest first, for plotting a per-topic trend.
function db.get_level_history(path)
  local conn = db.connect(path)
  return normalize_rows(conn:eval([[
    SELECT l.topic_id, l.score, l.run_id
    FROM levels l
    JOIN runs r ON r.id = l.run_id
    WHERE r.status = 'completed'
    ORDER BY l.run_id ASC
  ]]))
end

-- Recently failed answers with the grader's feedback, newest first. Used to
-- ground the tutor in what the user actually got wrong.
function db.get_recent_failures(path, limit)
  local conn = db.connect(path)
  return normalize_rows(conn:eval(
    [[SELECT q.prompt, q.reference, q.topic_id, t.name AS topic_name,
             resp.answer, resp.score, resp.llm_feedback
      FROM responses resp
      JOIN questions q ON q.id = resp.question_id
      LEFT JOIN topics t ON t.id = q.topic_id
      WHERE resp.passed = 0
      ORDER BY resp.id DESC
      LIMIT :limit]],
    { limit = limit or 5 }
  ))
end

db._normalize_rows = normalize_rows
db._normalize_single = normalize_single

return db
