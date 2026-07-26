-- Minimal Neovim config for local development and headless testing.
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    { "MunifTanjim/nui.nvim" },
    { "kkharji/sqlite.lua" },
  },
})

-- Use an isolated workspace so dev/test runs never touch real project data.
local workspace = os.getenv("KB_WORKSPACE")
if not workspace or workspace == "" then
  workspace = vim.fn.stdpath("data") .. "/knowledge-builder/projects"
end

-- Optional local-model overrides. Set KB_OLLAMA=1 to talk to a local Ollama
-- instead of the default Hugging Face endpoint (no token required).
local llm = {}
if os.getenv("KB_OLLAMA") == "1" then
  llm = {
    api_url = os.getenv("OLLAMA_URL") or "http://localhost:11434/v1/chat/completions",
    model = os.getenv("KB_OLLAMA_MODEL") or "gemma4:12b-it-qat",
    max_tokens = 2048,
  }
end

require("knowledge-builder").setup({
  storage = { workspace = workspace },
  llm = llm,
})

-- Neovim sources plugin/ files before this -u config runs, so the :KB command
-- would not otherwise be registered when launched via `-u dev/init.lua`.
-- Force-source the plugin file (clearing its load guard first).
vim.g.loaded_knowledge_builder = nil
vim.cmd("source " .. plugin_root .. "/plugin/knowledge-builder.lua")
