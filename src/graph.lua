--- src/graph.lua
--- Task graph (DAG) engine for planning and executing multi-step tasks.
--- All public functions are pure: no I/O, no side effects, no global mutation.
--- Rocks: cjson (cjson.safe)

local cjson = require("cjson.safe")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Deep-copy a table (or return non-table values unchanged).
local function copy_table(src)
  if type(src) ~= "table" then return src end
  local out = {}
  for k, v in pairs(src) do
    out[k] = copy_table(v)
  end
  return out
end

--- Count entries in a hash-keyed table (safe replacement for # on non-arrays).
local function table_size(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--- Build a { [id] = node } lookup map from g.nodes.
--- Only nodes with string IDs are included.
local function build_node_map(nodes)
  local map = {}
  for _, node in ipairs(nodes or {}) do
    if type(node) == "table" and type(node.id) == "string" then
      map[node.id] = node
    end
  end
  return map
end

--- Iterative DFS cycle detection.
--- nodes_map: { [id] = node }
--- color:     { [id] = 0|1|2 }  (0=white, 1=gray, 2=black)
--- Returns (false) or (true, cycle_description_string).
local function detect_cycle_dfs(nodes_map, start_id, color)
  -- Explicit stack to avoid Lua call-stack limits on large graphs.
  -- Each frame: { id, dep_index }  where dep_index is the next depends_on entry to visit.
  local stack = { { id = start_id, dep_idx = 1 } }
  local path  = { start_id }   -- tracks current ancestry for reporting
  color[start_id] = 1           -- gray

  while #stack > 0 do
    local frame = stack[#stack]
    local node  = nodes_map[frame.id]
    local deps  = (node and node.depends_on) or {}

    if frame.dep_idx > #deps then
      -- All children processed: mark black and pop
      color[frame.id] = 2
      stack[#stack]   = nil
      path[#path]     = nil
    else
      local dep_id = deps[frame.dep_idx]
      frame.dep_idx  = frame.dep_idx + 1

      if color[dep_id] == 1 then
        -- Back edge → cycle
        return true, table.concat(path, " -> ") .. " -> " .. dep_id
      elseif color[dep_id] == 0 then
        color[dep_id] = 1
        path[#path + 1] = dep_id
        stack[#stack + 1] = { id = dep_id, dep_idx = 1 }
      end
      -- color == 2 (already fully processed): skip
    end
  end

  return false
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Validate a task graph table.
--- Returns (true) or (false, list_of_error_strings).
function M.validate(g)
  local errors = {}

  local function err(msg)
    errors[#errors + 1] = msg
  end

  if type(g) ~= "table" then
    return false, { "graph must be a table" }
  end

  if type(g.nodes) ~= "table" then
    return false, { "graph.nodes must be a table" }
  end

  local seen_ids = {}

  for i, node in ipairs(g.nodes) do
    if type(node) ~= "table" then
      err("node[" .. i .. "] must be a table")
      goto continue
    end

    if type(node.id) ~= "string" or node.id == "" then
      err("node[" .. i .. "] missing or invalid 'id' field (must be a non-empty string)")
      goto continue
    end

    if seen_ids[node.id] then
      err("duplicate node ID: " .. node.id)
    else
      seen_ids[node.id] = true
    end

    -- Validate action-specific required fields
    if node.action == "skill" then
      if type(node.skill_name) ~= "string" or node.skill_name == "" then
        err("node '" .. node.id .. "' action='skill' requires 'skill_name' (non-empty string)")
      end
    elseif node.action == "llm_call" then
      if type(node.prompt_template) ~= "string" or node.prompt_template == "" then
        err("node '" .. node.id .. "' action='llm_call' requires 'prompt_template' (non-empty string)")
      end
    elseif node.action == "decision" then
      if type(node.condition) ~= "string" or node.condition == "" then
        err("node '" .. node.id .. "' action='decision' requires 'condition' (non-empty string)")
      end
      if type(node.if_true) ~= "string" or node.if_true == "" then
        err("node '" .. node.id .. "' action='decision' requires 'if_true' (non-empty string)")
      end
      if type(node.if_false) ~= "string" or node.if_false == "" then
        err("node '" .. node.id .. "' action='decision' requires 'if_false' (non-empty string)")
      end
    else
      err("node '" .. node.id .. "' has invalid or missing 'action': " .. tostring(node.action))
    end

    -- Validate depends_on
    if node.depends_on ~= nil then
      if type(node.depends_on) ~= "table" then
        err("node '" .. node.id .. "'.depends_on must be an array")
      else
        for j, dep_id in ipairs(node.depends_on) do
          if type(dep_id) ~= "string" then
            err("node '" .. node.id .. "'.depends_on[" .. j .. "] must be a string ID")
          end
        end
      end
    end

    -- Validate optional status
    if node.status ~= nil and type(node.status) ~= "string" then
      err("node '" .. node.id .. "'.status must be a string")
    end

    -- Validate optional retry counters
    if node.retries ~= nil and type(node.retries) ~= "number" then
      err("node '" .. node.id .. "'.retries must be a number")
    end
    if node.max_retries ~= nil and type(node.max_retries) ~= "number" then
      err("node '" .. node.id .. "'.max_retries must be a number")
    end

    ::continue::
  end

  -- Check all depends_on references point to known IDs
  for _, node in ipairs(g.nodes) do
    if type(node) == "table" and type(node.id) == "string" then
      for _, dep_id in ipairs(node.depends_on or {}) do
        if type(dep_id) == "string" and not seen_ids[dep_id] then
          err("node '" .. node.id .. "' depends on unknown node ID: '" .. dep_id .. "'")
        end
      end
    end
  end

  -- Detect cycles using iterative DFS (Fix #1: pass nodes_map, not seen_ids set)
  local nodes_map = build_node_map(g.nodes)
  local color     = {}
  for node_id in pairs(seen_ids) do
    color[node_id] = 0  -- white
  end

  for node_id in pairs(seen_ids) do
    if color[node_id] == 0 then
      local found, cycle_path = detect_cycle_dfs(nodes_map, node_id, color)
      if found then
        err("cycle detected: " .. cycle_path)
      end
    end
  end

  if #errors > 0 then
    return false, errors
  end
  return true
end

--- Topological sort using Kahn's algorithm.
--- Returns an ordered list of node IDs (dependencies before dependents),
--- or (nil, "cycle detected") if the graph contains a cycle.
--- Assumes g is a table with a nodes array; does not require prior validation.
function M.topological_sort(g)
  if type(g) ~= "table" or type(g.nodes) ~= "table" then
    return nil, "invalid graph"
  end

  -- Fix #2: removed the inverted validate branch entirely.
  -- Kahn's algorithm handles both valid and cyclic graphs correctly on its own.

  local in_degree = {}
  local adj       = {}  -- adj[dep_id][node_id] = true  (dep must come before node)
  local node_ids  = {}

  for _, node in ipairs(g.nodes) do
    if type(node) == "table" and type(node.id) == "string" then
      local id = node.id
      node_ids[id]  = true
      in_degree[id] = in_degree[id] or 0
      adj[id]       = adj[id] or {}
    end
  end

  for _, node in ipairs(g.nodes) do
    if type(node) == "table" and type(node.id) == "string" then
      local id = node.id
      for _, dep_id in ipairs(node.depends_on or {}) do
        if node_ids[dep_id] then
          adj[dep_id]     = adj[dep_id] or {}
          adj[dep_id][id] = true
          in_degree[id]   = (in_degree[id] or 0) + 1
        end
      end
    end
  end

  -- Seed queue with all zero-in-degree nodes (sorted for deterministic output)
  local queue = {}
  for id in pairs(node_ids) do
    if (in_degree[id] or 0) == 0 then
      queue[#queue + 1] = id
    end
  end
  table.sort(queue)

  local result     = {}
  local node_count = table_size(node_ids)  -- Fix #5: use table_size, not #node_ids

  while #queue > 0 do
    local u = table.remove(queue, 1)
    result[#result + 1] = u

    -- Collect and sort successors for deterministic output
    local successors = {}
    for v in pairs(adj[u] or {}) do
      in_degree[v] = (in_degree[v] or 0) - 1
      if in_degree[v] == 0 then
        successors[#successors + 1] = v
      end
    end
    table.sort(successors)
    for _, v in ipairs(successors) do
      queue[#queue + 1] = v
    end
  end

  if #result ~= node_count then
    return nil, "cycle detected"
  end

  return result
end

--- Return all nodes where status == "pending" and every node in depends_on
--- has status == "complete".  Nodes with no depends_on are immediately ready.
--- Returns a list of node tables (not IDs).
function M.get_ready_nodes(g)
  if type(g) ~= "table" or type(g.nodes) ~= "table" then
    return {}
  end

  local completed = {}
  for _, node in ipairs(g.nodes) do
    if type(node) == "table" and type(node.id) == "string" then
      if node.status == "complete" then
        completed[node.id] = true
      end
    end
  end

  local ready = {}
  for _, node in ipairs(g.nodes) do
    if type(node) == "table" and type(node.id) == "string" then
      if node.status == "pending" then
        local all_done = true
        for _, dep_id in ipairs(node.depends_on or {}) do
          if not completed[dep_id] then
            all_done = false
            break
          end
        end
        if all_done then
          ready[#ready + 1] = node
        end
      end
    end
  end

  return ready
end

--- Return true if every node has status "complete" or "skipped".
--- Returns false for an empty graph (Fix #3: vacuous truth is wrong here).
function M.is_complete(g)
  if type(g) ~= "table" or type(g.nodes) ~= "table" then
    return false
  end

  -- Fix #3: an empty graph is not complete
  if #g.nodes == 0 then
    return false
  end

  for _, node in ipairs(g.nodes) do
    if type(node) == "table" then
      local status = node.status or "pending"
      if status ~= "complete" and status ~= "skipped" then
        return false
      end
    end
  end

  return true
end

--- Return a new graph with all nodes that transitively depend on failed_node_id
--- having their status set to "skipped".  The failed node itself is not modified.
--- Fix #4: returns a deep copy rather than mutating the input graph.
function M.mark_downstream_skipped(g, failed_node_id)
  if type(g) ~= "table" or type(g.nodes) ~= "table" or
     type(failed_node_id) ~= "string" then
    return copy_table(g)
  end

  -- Build forward adjacency: dependents[id] = { downstream_id = true, ... }
  local dependents = {}
  for _, node in ipairs(g.nodes) do
    if type(node) == "table" and type(node.id) == "string" then
      dependents[node.id] = dependents[node.id] or {}
      for _, dep_id in ipairs(node.depends_on or {}) do
        dependents[dep_id] = dependents[dep_id] or {}
        dependents[dep_id][node.id] = true
      end
    end
  end

  -- BFS from failed_node_id to collect all downstream IDs
  local to_skip  = {}
  local queue    = {}
  local visited  = { [failed_node_id] = true }

  for downstream_id in pairs(dependents[failed_node_id] or {}) do
    if not visited[downstream_id] then
      visited[downstream_id]  = true
      to_skip[downstream_id]  = true
      queue[#queue + 1]       = downstream_id
    end
  end

  while #queue > 0 do
    local current = table.remove(queue, 1)
    for downstream_id in pairs(dependents[current] or {}) do
      if not visited[downstream_id] then
        visited[downstream_id]  = true
        to_skip[downstream_id]  = true
        queue[#queue + 1]       = downstream_id
      end
    end
  end

  -- Deep-copy the graph and apply status changes to the copy
  local new_g = copy_table(g)
  for _, node in ipairs(new_g.nodes) do
    if type(node) == "table" and type(node.id) == "string" then
      if to_skip[node.id] then
        node.status = "skipped"
      end
    end
  end

  return new_g
end

--- Parse a JSON string, validate the resulting graph, and return it.
--- Returns (graph_table) or (nil, error_string).
function M.from_json(json_string)
  if type(json_string) ~= "string" then
    return nil, "input must be a JSON string"
  end

  local parsed, decode_err = cjson.decode(json_string)
  if parsed == nil then
    return nil, "JSON parse error: " .. tostring(decode_err)
  end

  if type(parsed) ~= "table" then
    return nil, "parsed JSON must be an object"
  end

  local valid, errors = M.validate(parsed)
  if not valid then
    return nil, "validation failed:\n  " .. table.concat(errors, "\n  ")
  end

  return parsed
end

return M
