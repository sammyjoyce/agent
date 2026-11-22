-- Optional Rex Lua action helpers for Beep Boop.
-- Load separately from core execution (`require('agent_actions')`) when
-- connected to an attached Rex app with Remote Control enabled.

local function trim(text)
  if type(text) ~= "string" then return "" end
  return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function json_decode_lines(stdout)
  local events = {}
  if type(stdout) ~= "string" then return events end
  for line in stdout:gmatch("[^\r\n]+") do
    local trimmed = trim(line)
    if trimmed ~= "" then
      local ok, value = pcall(rex.json.decode, trimmed)
      if ok and type(value) == "table" then
        table.insert(events, value)
      end
    end
  end
  return events
end

local function task_icon(task)
  if type(task) ~= "table" or type(task.state) ~= "table" then
    return "terminal"
  end
  local kind = task.state.state
  if kind == "waiting" then return "clock" end
  if kind == "resolved" then return "star" end
  return "terminal"
end

local function task_detail(task)
  if type(task) ~= "table" or type(task.state) ~= "table" then return "" end
  local kind = task.state.state or "open"
  if kind == "waiting" and type(task.state.actor) == "string" and task.state.actor ~= "" then
    return "waiting: " .. task.state.actor
  end
  return kind
end

local function session_id_for_task(task)
  if type(task) ~= "table" or type(task.worker) ~= "table" then return nil end
  local binding = task.worker.binding
  if type(binding) == "table" and type(binding.session_id) == "string" and binding.session_id ~= "" then
    return binding.session_id
  end
  return nil
end

local function build_pick_items(tasks)
  local items = {}
  if type(tasks) ~= "table" then return items end
  for _, task in ipairs(tasks) do
    local session_id = session_id_for_task(task)
    if session_id ~= nil then
      local host = type(task.worker.host) == "table" and task.worker.host.name or nil
      local summary = trim(task.summary)
      local subtitle = host ~= nil and summary ~= "" and (host .. " · " .. summary)
        or host
        or (summary ~= "" and summary or nil)
      table.insert(items, {
        id = session_id,
        title = type(task.title) == "string" and task.title ~= "" and task.title or task.id,
        subtitle = subtitle,
        detail = task_detail(task),
        icon = task_icon(task),
      })
    end
  end
  return items
end

local function select_session(ctx, session_id)
  if type(ctx) == "table" and type(ctx.client_id) == "string" and ctx.client_id ~= "" then
    return rex.call("client.perform", {
      client_id = ctx.client_id,
      action = "session.select",
      args = { session_id = session_id },
      origin = "lua",
    })
  end
  return rex.client.queue("session.select", { session_id = session_id })
end

rex.action {
  name = "agent_jump_to_task",
  title = "Beep Boop: Jump to Active or Waiting Task",
  args = {
    session_id = "string?",
  },
  run = function(ctx, args)
    local session_id = type(args) == "table" and args.session_id or nil
    if session_id == nil or session_id == "" then
      local res = rex.exec.run({ "beep-boop", "--json", "tasks", "list" }, { timeout = 10 })
      if not res.ok then
        return { error = "Could not list Beep Boop tasks" }
      end
      local tasks = nil
      for _, event in ipairs(json_decode_lines(res.stdout)) do
        if event.type == "tasks" and type(event.tasks) == "table" then
          tasks = event.tasks
        end
      end
      local items = build_pick_items(tasks)
      if #items == 0 then
        return { empty = true }
      end
      local picked, why = rex.ui.pick {
        title = "Jump to Beep Boop task",
        placeholder = "Filter tasks by title, host, or state",
        items = items,
      }
      if picked == nil then
        return { cancelled = why }
      end
      session_id = picked
    end
    select_session(ctx, session_id)
    return { selected = session_id }
  end,
}

rex.action {
  name = "agent_quick_prompt",
  title = "Beep Boop: Quick Prompt to Main Chat",
  args = {
    prompt = "string?",
  },
  run = function(ctx, args)
    local prompt = type(args) == "table" and args.prompt or nil
    if prompt == nil or trim(prompt) == "" then
      local entered, why = rex.ui.input {
        title = "Send prompt to Beep Boop main chat",
        placeholder = "What should Beep Boop work on?",
        confirm = "Send to Main",
      }
      if entered == nil then
        return { cancelled = why }
      end
      prompt = entered
    end
    prompt = trim(prompt)
    if prompt == "" then
      return { empty = true }
    end
    local res = rex.exec.run({ "beep-boop", "--json", "chat", "--", prompt }, { timeout = 30 })
    if not res.ok then
      return { error = "Beep Boop chat command failed", exit_code = res.code }
    end
    return { sent = true, events = json_decode_lines(res.stdout) }
  end,
}
