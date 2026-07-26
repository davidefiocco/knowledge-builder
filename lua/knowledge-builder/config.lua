-- knowledge-builder - Configuration
local config = {}

config.defaults = {
  storage = {
    -- Workspace root that holds one directory per project.
    workspace = vim.fn.stdpath("data") .. "/knowledge-builder/projects",
  },

  llm = {
    model = "Qwen/Qwen3-Coder-Next",
    api_url = "https://router.huggingface.co/v1/chat/completions",
    hf_token_env = "HF_TOKEN",
    temperature = 0.7,
    -- Lower temperature for grading so scores are more stable.
    grading_temperature = 0.1,
    max_tokens = 1024,
    -- Per-request wall-clock cap (seconds) passed to curl as --max-time, so a
    -- hung endpoint fails fast instead of stranding an orphaned curl process.
    timeout = 180,
  },

  assess = {
    -- Baseline questions per topic, before weighting and adaptation.
    questions_per_topic = 2,
    -- Hard floor/ceiling on the per-topic count after those adjustments.
    min_questions_per_topic = 1,
    max_questions_per_topic = 5,
    -- Scale the count by the topic's syllabus weight (0.5-2.0), so central
    -- topics get more questions than peripheral ones.
    weighting = true,
    -- Scale the count by your most recent score on the topic, so weak and
    -- untested topics get more questions than ones you've already mastered.
    adaptive = true,
    -- A response scoring >= this counts as "passed".
    pass_threshold = 0.6,
    -- Max concurrent question-generation requests. Keep at 1 for local
    -- single-instance backends (e.g. Ollama) that serialize requests; raise
    -- it for hosted APIs to generate topics in parallel.
    max_concurrency = 1,
  },

  ui = {
    width = 0.8,
    height = 0.8,
    border = "rounded",
  },

  chat = {
    -- Cap the turns replayed to the model (the system prompt is always kept),
    -- so a long tutor session can't grow past the context window.
    max_history_messages = 20,
  },

  keymaps = {
    exam = {
      submit = "<C-s>",
      next_question = "<C-n>",
      prev_question = "<C-p>",
      finish = "<C-f>",
      hint = "<C-g>",
      close = "q",
    },
    chat = {
      send = "<C-s>",
      close = "q",
    },
  },
}

config.config = vim.deepcopy(config.defaults)

function config.setup(user_config)
  config.config = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), user_config or {})
  vim.fn.mkdir(config.config.storage.workspace, "p")
  return config.config
end

function config.get(key, default)
  local value = config.config
  for _, k in ipairs(vim.split(key, ".", { plain = true })) do
    if type(value) ~= "table" then
      return default
    end
    value = value[k]
    if value == nil then
      return default
    end
  end
  return value
end

return config
