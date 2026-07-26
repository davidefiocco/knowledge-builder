-- Minimal config to install plugin dependencies only (no knowledge-builder
-- setup). Used during the Docker build so dependencies are present before the
-- plugin itself is loaded.
--
-- Every failure path calls die(), because `nvim --headless` exits 0 after an
-- erroring init and the caller needs a non-zero status to act on.

local function die(msg)
  io.write("install_deps: " .. msg .. "\n")
  io.flush()
  vim.cmd("cquit 1")
end

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  local out = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
  if vim.v.shell_error ~= 0 then
    die("failed to clone lazy.nvim (git exit " .. vim.v.shell_error .. "):\n" .. out)
  end
end

vim.opt.rtp:prepend(lazypath)

local ok, lazy = pcall(require, "lazy")
if not ok then
  die("lazy.nvim is not loadable after clone: " .. tostring(lazy))
end

lazy.setup({
  spec = {
    { "MunifTanjim/nui.nvim" },
    { "kkharji/sqlite.lua" },
  },
})

-- `Lazy! sync` runs after this file, so verification happens on VimLeavePre:
-- confirm the modules the plugin actually needs are requirable.
vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = function()
    for _, mod in ipairs({ "nui.popup", "nui.layout", "sqlite" }) do
      local loaded = pcall(require, mod)
      if not loaded then
        die("dependency '" .. mod .. "' is not requirable after sync")
        return
      end
    end
  end,
})
