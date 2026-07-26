-- knowledge-builder - LLM client
--
-- Talks to an OpenAI-compatible chat-completions endpoint (HF router by
-- default) via curl. Provides both a buffered call and an SSE streaming call.
local config = require("knowledge-builder.config")
local utils = require("knowledge-builder.utils")

local llm = {}

-- Build the curl invocation for a request. Sensitive bits (Authorization
-- header, request body) go through stdin via `curl --config -` so the token
-- never appears in the process list (`ps`); the timeout and -s flags stay on
-- argv because they aren't sensitive. The Authorization header is only added
-- when a token is available, so no-auth local endpoints (e.g. Ollama) work
-- without any token env var.
local function q(s)
  return (s or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function build_curl_invocation(api_url, payload, opts)
  opts = opts or {}
  local timeout = config.get("llm.timeout", 180)
  local argv = { "curl", "-s", "--max-time", tostring(timeout), "--config", "-" }

  local lines = {
    "silent",
    string.format('url = "%s"', q(api_url)),
    'header = "Content-Type: application/json"',
  }
  if opts.no_buffer then
    table.insert(lines, "no-buffer")
  end
  local env = config.get("llm.hf_token_env", "HF_TOKEN")
  local token = env and vim.env[env]
  if token and token ~= "" then
    table.insert(lines, string.format('header = "Authorization: Bearer %s"', q(token)))
  end
  table.insert(lines, 'request = "POST"')
  table.insert(lines, string.format('data = "%s"', q(payload)))
  return argv, table.concat(lines, "\n") .. "\n"
end

local function build_payload(messages, opts)
  opts = opts or {}
  return {
    model = opts.model or config.get("llm.model"),
    messages = messages,
    temperature = opts.temperature or config.get("llm.temperature"),
    max_tokens = opts.max_tokens or config.get("llm.max_tokens"),
    stream = opts.stream or false,
  }
end

-- Buffered (non-streaming) chat completion.
-- callback(content, err)
function llm.chat(messages, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}

  local payload = vim.json.encode(build_payload(messages, opts))
  local api_url = config.get("llm.api_url")

  local argv, stdin_cfg = build_curl_invocation(api_url, payload)
  vim.system(argv, { text = true, stdin = stdin_cfg }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, "curl failed (exit " .. tostring(result.code) .. "): " .. (result.stderr or ""))
        return
      end
      local body, decode_err = utils.json_decode(result.stdout)
      if not body then
        callback(nil, "Failed to parse API response: " .. tostring(decode_err))
        return
      end
      if body.error then
        callback(nil, body.error.message or vim.inspect(body.error))
        return
      end
      local choice = body.choices and body.choices[1]
      if not choice or not choice.message then
        callback(nil, "No response from model")
        return
      end
      callback(choice.message.content)
    end)
  end)
end

-- Convenience wrapper: send system+user, expect JSON back, decode it.
-- callback(decoded, err, raw)
--
-- Some models (especially "thinking" models) occasionally wrap JSON in prose or
-- reasoning. If the first response can't be parsed, we do one corrective retry
-- that feeds the bad output back and asks for JSON only. opts.no_json_retry
-- disables this.
function llm.chat_json(system_prompt, user_prompt, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  local messages = {
    { role = "system", content = system_prompt },
    { role = "user", content = user_prompt },
  }

  llm.chat(messages, opts, function(content, err)
    if err then
      callback(nil, err)
      return
    end
    local decoded = utils.extract_json(content)
    if decoded ~= nil then
      callback(decoded, nil, content)
      return
    end

    if opts.no_json_retry then
      callback(nil, "Model did not return valid JSON", content)
      return
    end

    -- One corrective retry: show the model its own output and demand JSON only.
    local retry_messages = {
      { role = "system", content = system_prompt },
      { role = "user", content = user_prompt },
      { role = "assistant", content = content },
      {
        role = "user",
        content = "That was not valid JSON. Reply with ONLY the JSON value, "
          .. "no prose, no markdown fences, no reasoning.",
      },
    }
    local retry_opts = vim.tbl_extend("force", opts, { no_json_retry = true })
    llm.chat(retry_messages, retry_opts, function(content2, err2)
      if err2 then
        callback(nil, err2)
        return
      end
      local decoded2 = utils.extract_json(content2)
      if decoded2 == nil then
        callback(nil, "Model did not return valid JSON (after retry)", content2)
        return
      end
      callback(decoded2, nil, content2)
    end)
  end)
end

-- Parse one or more SSE lines, invoking on_delta for each content token and
-- on_done when the [DONE] sentinel arrives. Returns whether the stream is done.
-- Exposed for unit testing.
function llm.parse_sse_chunk(chunk, on_delta)
  local done = false
  for line in (chunk or ""):gmatch("[^\n]+") do
    line = utils.trim(line)
    if line:sub(1, 5) == "data:" then
      local data = utils.trim(line:sub(6))
      if data == "[DONE]" then
        done = true
      elseif data ~= "" then
        local obj = utils.json_decode(data)
        local delta = obj and obj.choices and obj.choices[1] and obj.choices[1].delta
        if delta and delta.content and delta.content ~= "" then
          on_delta(delta.content)
        end
      end
    end
  end
  return done
end

-- Streaming chat completion. on_delta(token) is called as tokens arrive;
-- on_done(full_text, err) when the stream completes.
function llm.stream(messages, opts, on_delta, on_done)
  opts = opts or {}
  opts.stream = true
  local payload = vim.json.encode(build_payload(messages, opts))
  local api_url = config.get("llm.api_url")

  local full = {}
  local pending = ""

  local function handle_stdout(data)
    if not data then
      return
    end
    pending = pending .. data
    -- Process complete lines; keep any trailing partial line buffered.
    local last_nl = pending:find("\n[^\n]*$")
    local process = pending
    if last_nl then
      process = pending:sub(1, last_nl)
      pending = pending:sub(last_nl + 1)
    else
      return
    end
    llm.parse_sse_chunk(process, function(tok)
      table.insert(full, tok)
      vim.schedule(function()
        on_delta(tok)
      end)
    end)
  end

  local argv, stdin_cfg = build_curl_invocation(api_url, payload, { no_buffer = true })
  vim.system(argv, {
    text = true,
    stdin = stdin_cfg,
    stdout = function(_, data)
      if data then
        handle_stdout(data)
      end
    end,
  }, function(result)
    vim.schedule(function()
      if pending ~= "" then
        llm.parse_sse_chunk(pending, function(tok)
          table.insert(full, tok)
          on_delta(tok)
        end)
      end
      if result.code ~= 0 then
        on_done(nil, "curl failed (exit " .. tostring(result.code) .. ")")
        return
      end
      on_done(table.concat(full))
    end)
  end)
end

-- Synchronous one-token round trip against the configured endpoint and model.
-- Used by :checkhealth to catch a wrong URL, a missing token, or an unpulled
-- local model before the user waits through a whole syllabus build.
-- Returns ok (boolean), detail (string).
function llm.probe(timeout_ms)
  local payload = vim.json.encode(build_payload({
    { role = "user", content = "ping" },
  }, { max_tokens = 1, temperature = 0 }))

  local argv, stdin_cfg = build_curl_invocation(config.get("llm.api_url"), payload)
  local ok, result = pcall(function()
    return vim.system(argv, { text = true, stdin = stdin_cfg }):wait(timeout_ms or 15000)
  end)
  if not ok then
    return false, tostring(result)
  end
  if result.code ~= 0 then
    return false, "curl exit " .. tostring(result.code) .. " " .. utils.trim(result.stderr or "")
  end

  local body, decode_err = utils.json_decode(result.stdout)
  if not body then
    return false, "unparseable response: " .. tostring(decode_err)
  end
  if body.error then
    return false,
      type(body.error) == "table" and (body.error.message or vim.inspect(body.error)) or tostring(body.error)
  end
  if not (body.choices and body.choices[1]) then
    return false, "response had no choices"
  end
  return true, "endpoint answered"
end

-- Exposed for unit testing the curl invocation construction (token on/off,
-- timeout present, payload routed through stdin so it's not in argv).
llm._build_curl_invocation = build_curl_invocation
llm._build_payload = build_payload

return llm
