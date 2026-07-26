-- knowledge-builder per-project database schema.
--
-- Each project lives in its own directory with its own knowledge.db, so this
-- schema describes a single project. Project-level metadata (name, slug,
-- source inputs) is stored in the single-row `project` table; the syllabus is
-- a set of `topics`; every test/review pass is a `run`.

CREATE TABLE IF NOT EXISTS project (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    name TEXT NOT NULL,
    slug TEXT NOT NULL,
    description TEXT DEFAULT '',
    source_inputs TEXT DEFAULT '',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- The persistent syllabus. A project owns ONE set of topics; runs reuse them
-- so progress can be compared across runs ("you vs. past you").
--
-- Topic ids are STABLE: refining the syllabus upserts by name, and a topic
-- dropped from the syllabus is archived. `levels` cascades on topic delete, so
-- keeping rows alive is what preserves the score history.
CREATE TABLE IF NOT EXISTS topics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT DEFAULT '',
    weight REAL DEFAULT 1.0,
    source TEXT DEFAULT '',
    position INTEGER DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_topics_name ON topics(name);

-- One row per pass over the syllabus: a graded 'test' or a 'review' pass.
CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    phase TEXT NOT NULL CHECK (phase IN ('test', 'review')),
    status TEXT NOT NULL DEFAULT 'in_progress'
        CHECK (status IN ('in_progress', 'completed', 'abandoned')),
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP
);

-- Questions generated for a run. `payload` holds kind-specific JSON
-- (e.g. MCQ options, code test cases / harness).
CREATE TABLE IF NOT EXISTS questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER NOT NULL,
    topic_id INTEGER,
    kind TEXT NOT NULL CHECK (kind IN ('code', 'open', 'mcq')),
    difficulty TEXT CHECK (difficulty IN ('easy', 'medium', 'hard')),
    prompt TEXT NOT NULL,
    reference TEXT DEFAULT '',
    payload TEXT DEFAULT '{}',
    position INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE,
    FOREIGN KEY (topic_id) REFERENCES topics(id) ON DELETE SET NULL
);

-- A user's answer to a question, with LLM-derived score (0..1) and feedback.
-- Exactly one row per question: re-grading replaces it, so every reader sees
-- the same authoritative result.
CREATE TABLE IF NOT EXISTS responses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    question_id INTEGER NOT NULL,
    run_id INTEGER NOT NULL,
    answer TEXT,
    score REAL,
    passed INTEGER,
    llm_feedback TEXT DEFAULT '',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (question_id) REFERENCES questions(id) ON DELETE CASCADE,
    FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_responses_question_unique ON responses(question_id);

-- Per-topic level snapshot for a run. Enables delta vs. previous runs.
CREATE TABLE IF NOT EXISTS levels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER NOT NULL,
    topic_id INTEGER NOT NULL,
    score REAL NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE,
    FOREIGN KEY (topic_id) REFERENCES topics(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_questions_run ON questions(run_id);
CREATE INDEX IF NOT EXISTS idx_responses_run ON responses(run_id);
CREATE INDEX IF NOT EXISTS idx_levels_run ON levels(run_id);
CREATE INDEX IF NOT EXISTS idx_levels_topic ON levels(topic_id);
