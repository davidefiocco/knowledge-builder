-- knowledge-builder - :checkhealth support
local config = require("knowledge-builder.config")

local health = {}

function health.check()
  vim.health.start("knowledge-builder")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim 0.10+ is required")
  end

  if pcall(require, "nui.popup") then
    vim.health.ok("nui.nvim found")
  else
    vim.health.error("nui.nvim not found", { "Install MunifTanjim/nui.nvim" })
  end

  if pcall(require, "sqlite") then
    vim.health.ok("sqlite.lua found")
  else
    vim.health.error("sqlite.lua not found", { "Install kkharji/sqlite.lua" })
  end

  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl found (needed for LLM calls)")
  else
    vim.health.error("curl not found", { "Install curl to talk to the LLM endpoint" })
  end

  local api_url = config.get("llm.api_url", "")
  local model = config.get("llm.model", "")
  vim.health.info("Endpoint: " .. api_url)
  vim.health.info("Model: " .. model)

  local is_local = api_url:find("localhost", 1, true) or api_url:find("127.0.0.1", 1, true)
  local env = config.get("llm.hf_token_env", "HF_TOKEN")
  if vim.env[env] and vim.env[env] ~= "" then
    vim.health.ok("$" .. env .. " is set")
  elseif is_local then
    vim.health.ok("No token set (not needed for a local endpoint)")
  else
    vim.health.warn(
      "$" .. env .. " not set",
      { "Set " .. env .. " to authenticate, or point llm.api_url at a local endpoint (e.g. Ollama)" }
    )
  end

  -- Actually talk to the endpoint. A reachable URL with a valid token and a
  -- model that exists is the difference between :KB test working and failing
  -- several minutes into a run.
  if vim.fn.executable("curl") == 1 then
    local ok, detail = require("knowledge-builder.llm").probe(15000)
    if ok then
      vim.health.ok("Endpoint reachable and model '" .. model .. "' responded")
    else
      vim.health.error("Endpoint probe failed: " .. tostring(detail), {
        "Check llm.api_url and llm.model",
        "For Ollama, confirm it is running and the model is pulled (`ollama list`)",
        "For a hosted API, confirm $" .. env .. " is valid",
      })
    end
  end

  local workspace = config.get("storage.workspace")
  if workspace and vim.fn.isdirectory(workspace) == 1 then
    vim.health.ok("Workspace: " .. workspace)
  else
    vim.health.info("Workspace not yet created: " .. (workspace or "nil"))
  end

  local proj = require("knowledge-builder.project").restore_last()
  if proj then
    vim.health.info("Active project: " .. proj.slug)
  end
end

return health
