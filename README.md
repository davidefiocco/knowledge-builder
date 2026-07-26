# knowledge-builder

A Neovim plugin that builds a personalized learning loop from your own inputs.

1. **Build a syllabus** — it derives one on the fly from your inputs (a job
   description, your CV, or free-form goals).
2. **Test** — it generates a fresh set of questions over the syllabus and grades
   you. Run a test as often as you like; the questions differ each time, and your
   results are tracked across the sequence of runs.
3. **Review** (optionally) — between tests it generates study material and lets
   you talk to a streaming tutor about your weak topics.

Your progress is tracked per topic across runs, so you can see how you improve
against your past self.

The flow is driven by generative models, so the content is dynamic and tailored
to you. Open and code answers are graded by an LLM; multiple-choice answers are
graded deterministically.

## Projects

Everything is persisted in a **project**: a directory under the workspace root
(default `~/.local/share/nvim/knowledge-builder/projects/<slug>/`):

```
<slug>/
  knowledge.db      SQLite (schema in schema.sql)
  syllabus.json     structured syllabus (source of truth)
  syllabus.md       human-readable, editable
  materials/        generated review material
```

A project owns **one persistent syllabus**. Each test (and review) pass is a
**run** that reuses that syllabus, which is what makes "you vs. past you"
progress possible across successive tests.

Topic identity is stable across syllabus edits: refining matches topics by name
and updates them in place, so scores carry over. A topic dropped from the
syllabus is archived rather than deleted — it leaves the active syllabus but
keeps its history, and re-adding it by the same name restores it.

The last project you opened is remembered, so a new Neovim session picks up
where you left off instead of asking you to `:KB open` again.

## Requirements

- Neovim 0.10+
- [`nui.nvim`](https://github.com/MunifTanjim/nui.nvim)
- [`sqlite.lua`](https://github.com/kkharji/sqlite.lua)
- `curl` on `PATH`
- An LLM token in `$HF_TOKEN` (OpenAI-compatible HF router by default)

Run `:checkhealth knowledge-builder` to verify. It checks the dependencies and
then sends a one-token request to your configured endpoint, so a wrong URL, a
bad token, or an unpulled local model surfaces immediately rather than several
minutes into a run.

## Try it locally

To play with the plugin without adding it to your own config, launch Neovim with
the bundled dev config (it auto-installs `nui.nvim` + `sqlite.lua` via lazy.nvim
and registers `:KB`):

```bash
cd knowledge-builder

# Against a local Ollama (fully offline, no token needed):
KB_OLLAMA=1 nvim -u dev/init.lua

# Or against the default Hugging Face endpoint:
HF_TOKEN=... nvim -u dev/init.lua
```

Then, inside Neovim:

```
:checkhealth knowledge-builder   " verify deps + endpoint
:KB start                        " name a project, paste a JD/CV or goals
:KB test                         " answer the generated questions
:KB progress                     " see your per-topic levels
```

Optional environment variables for the dev config:

- `KB_OLLAMA=1` — use a local Ollama instead of Hugging Face
- `OLLAMA_URL` / `KB_OLLAMA_MODEL` — override the Ollama endpoint / model
- `KB_WORKSPACE` — use a throwaway projects dir (e.g. `KB_WORKSPACE=$(mktemp -d)`)

Note: local "thinking" models are slow (tens of seconds per call), so expect a
test to take a few minutes.

## Install (lazy.nvim)

```lua
{
  dir = "/path/to/knowledge-builder",
  dependencies = { "MunifTanjim/nui.nvim", "kkharji/sqlite.lua" },
  config = function()
    require("knowledge-builder").setup({})
  end,
}
```

## Commands

Forgot what's available? Run `:KB help` (or just `:KB`) for an in-editor cheat
sheet, `:help knowledge-builder` for the full docs, or press `<Tab>` after `:KB `
to cycle the subcommands.

| Command | Description |
| --- | --- |
| `:KB help` | Show an in-editor cheat sheet of commands and keys (also shown for a bare `:KB`) |
| `:KB start` | Create a project, provide inputs (JD/CV/text), build the syllabus |
| `:KB open [name]` | Open an existing project (pickers if name omitted) |
| `:KB list` | List projects |
| `:KB syllabus refine <instruction>` | Revise the syllabus from a natural-language note (e.g. "add Kubernetes, merge topics 2 and 3") |
| `:KB test` | Take a test over the syllabus — fresh questions each run; results tracked across runs |
| `:KB review [topic]` | Generate review material for a topic (picker is ordered weakest-first) |
| `:KB tutor` | Open the streaming tutor chat, briefed on your weak topics and recent mistakes |
| `:KB progress` | Per-topic levels, the delta vs. your previous run, and a sparkline across all runs |
| `:KB results [run]` | Show a per-question grading report (your answer, score, pass/fail, feedback) for a completed run. No arg = latest; picker if there are several |

### Test keys

- `Ctrl-s` grade the current answer (stays on the question; the header shows the score)
- `Ctrl-n` / `Ctrl-p` next / previous question — your typed answers are remembered, so you can skip ahead and come back
- `Ctrl-f` finish: grade any remaining answers and show the run summary
- `1`-`9` choose an MCQ option
- `Ctrl-g` ask for a non-revealing hint
- `q` close (abandons the run without finishing)

### Tutor keys

- `Ctrl-s` send the message (responses stream in)
- `q` close

## Seeding the syllabus from files (incl. PDFs)

`:KB start` reads its inputs as **plain text** — you can paste the path to a
`.txt` file (a CV, job description, notes) at the prompt. PDFs are binary, so
convert them to text first with the bundled helper:

```bash
# One PDF -> cv.txt beside it
uv run tools/pdf_to_text.py cv.pdf

# Merge several into one seed file
uv run tools/pdf_to_text.py cv.pdf job_description.pdf -o seed.txt

# Or pipe straight into the offline syllabus generator
uv run tools/pdf_to_text.py cv.pdf --stdout | HF_TOKEN=... uv run tools/extract_syllabus.py -
```

Then point `:KB start` at the resulting `.txt` (or feed `syllabus.json` from
`extract_syllabus.py` directly into a project). `uv` pulls in the small `pypdf`
dependency automatically. Scanned/image-only PDFs won't yield text (you'd need
OCR first).

## Configuration

```lua
require("knowledge-builder").setup({
  storage = { workspace = vim.fn.stdpath("data") .. "/knowledge-builder/projects" },
  llm = {
    model = "Qwen/Qwen3-Coder-Next",
    api_url = "https://router.huggingface.co/v1/chat/completions",
    hf_token_env = "HF_TOKEN",
    grading_temperature = 0.1,
    timeout = 180, -- per-request curl --max-time (seconds)
  },
  assess = {
    questions_per_topic = 2,      -- baseline, before weighting/adaptation
    min_questions_per_topic = 1,
    max_questions_per_topic = 5,
    weighting = true,             -- scale by the topic's syllabus weight
    adaptive = true,              -- scale by your last score on the topic
    pass_threshold = 0.6,
    -- Keep at 1 for local single-instance backends (e.g. Ollama) that
    -- serialize requests; raise it for hosted APIs to parallelize generation
    -- and end-of-test grading.
    max_concurrency = 1,
  },
  chat = { max_history_messages = 20 },
})
```

### Adaptive question allocation

Each run decides how many questions a topic gets from two multipliers on top of
`questions_per_topic`, clamped to the min/max:

- **Weight** — the topic's syllabus weight (0.5–2.0), so central topics get more
  airtime than peripheral ones.
- **Mastery** — your most recent score. A topic you scored 0 on, or have never
  been tested on, is scaled by 1.5; one you aced is scaled by 0.5.

So successive tests concentrate on your weak spots instead of re-asking what
you've already demonstrated. Set `weighting` or `adaptive` to `false` for a flat
count. Topic weight also makes the overall percentage in `:KB results` a
weighted mean rather than a plain average.

### Using a local model (Ollama)

knowledge-builder talks to any OpenAI-compatible endpoint, so a local Ollama
works with no HuggingFace dependency. Just point `llm.api_url` at it and pick a
model — no token is required for a local endpoint (the `Authorization` header is
omitted automatically when the token env var is unset):

```lua
require("knowledge-builder").setup({
  llm = {
    api_url = "http://localhost:11434/v1/chat/completions",
    model = "gemma4:12b-it-qat",
    max_tokens = 2048, -- thinking models need a generous budget
  },
  assess = { max_concurrency = 1 }, -- keep at 1 for local single-instance backends
})
```

## Architecture

```
init.lua        public API + :KB dispatch
config.lua      defaults, setup()
project.lua     per-project directories, current-project state
db.lua          per-project SQLite (schema.sql)
syllabus.lua    extract + persist the syllabus
assess.lua      run engine: generate questions, grade, compute levels  (UI-agnostic)
exam.lua        interactive code/open/MCQ panes (drives assess.lua)
progress.lua    per-topic levels + you-vs-past-self deltas
review.lua      review material generation
chat.lua        streaming tutor scratch buffer
llm.lua         curl-based LLM client (buffered + SSE streaming)
spinner.lua     progress bar / spinner for long generation phases
ui.lua          shared float/scratch helpers
api.lua         headless scriptable API (JSON in/out) for tests & automation
health.lua      :checkhealth
```

The **scriptable core** (`api.lua` over `assess.lua`) means the whole flow is
drivable without the UI: `get_current_question()` / `submit_answer()` return
plain JSON, and the interactive UI is a thin shell on top.

## Testing

Two tiers:

### Tier 1 - deterministic (default)

Fast headless tests with the LLM mocked. No token or network needed.

```bash
KB_WORKSPACE=$(mktemp -d) nvim --headless -u dev/init.lua -l test/test_flow.lua
```

Or in a clean environment via Docker:

```bash
docker build -t knowledge-builder-test .
docker run --rm knowledge-builder-test
```

### Tier 2 - LLM-in-the-loop (opt-in)

A Python + `pynvim` harness with two LLM roles: a **simulated-user** agent that
answers each question and a **judge** agent (LLM-as-judge) that verifies the
interaction was coherent and graded sanely. Gated behind a marker and a token.

```bash
HF_TOKEN=... uv run -m pytest test/test_llm_loop.py -m llm -v
```

Default `pytest` runs exclude it (`addopts = -m "not llm"` in `pytest.ini`).

## Documentation

In-editor help is available at `:help knowledge-builder` (see
`doc/knowledge-builder.txt`).

## Notes

- Open/code answers are graded by an LLM (rubric prompt to a 0-1 score plus
  feedback); MCQ is graded deterministically.
- LLM grading is non-deterministic; raw feedback is stored for transparency.
- Re-grading a question replaces its result, so there is exactly one recorded
  answer per question.
- Closing a test with `q` marks the run abandoned. Only completed runs feed
  `:KB progress` and the `:KB results` picker.
