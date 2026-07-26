-- knowledge-builder - :KB user command
if vim.g.loaded_knowledge_builder then
  return
end
vim.g.loaded_knowledge_builder = true

vim.api.nvim_create_user_command("KB", function(opts)
  local kb = require("knowledge-builder.init")
  local args = opts.fargs
  local sub = args[1] or "help"

  if sub == "help" then
    kb.help()
  elseif sub == "start" then
    kb.start()
  elseif sub == "open" then
    kb.open(args[2])
  elseif sub == "list" then
    kb.list()
  elseif sub == "syllabus" then
    local instruction = #args > 2 and table.concat(vim.list_slice(args, 3), " ") or nil
    kb.syllabus(args[2], instruction)
  elseif sub == "review" then
    kb.review(args[2])
  elseif sub == "tutor" then
    kb.tutor()
  elseif sub == "test" then
    kb.test()
  elseif sub == "progress" then
    kb.progress()
  elseif sub == "results" then
    kb.results(args[2])
  else
    require("knowledge-builder.utils").notify("Unknown subcommand: " .. sub, "warn")
    kb.help()
  end
end, {
  nargs = "*",
  complete = function(arg_lead, cmd_line)
    local parts = vim.split(cmd_line, "%s+")
    if #parts <= 2 then
      local subs = { "help", "start", "open", "list", "test", "review", "tutor", "progress", "results", "syllabus" }
      return vim.tbl_filter(function(s)
        return s:find(arg_lead, 1, true) == 1
      end, subs)
    end
    if parts[2] == "syllabus" and #parts <= 3 then
      return vim.tbl_filter(function(s)
        return s:find(arg_lead, 1, true) == 1
      end, { "refine" })
    end
    if parts[2] == "open" then
      local labels = {}
      for _, p in ipairs(require("knowledge-builder.project").list()) do
        table.insert(labels, p.slug)
      end
      return vim.tbl_filter(function(s)
        return s:find(arg_lead, 1, true) == 1
      end, labels)
    end
    return {}
  end,
  desc = "knowledge-builder commands",
})
