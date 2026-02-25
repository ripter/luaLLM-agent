--- src/graph.test.lua
--- Busted tests for src/graph.lua

local _src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = _src .. "?.lua;" .. package.path

local graph = require("graph")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a minimal valid skill node.
local function skill_node(id, deps)
  return {
    id         = id,
    action     = "skill",
    skill_name = "do_thing",
    depends_on = deps or {},
    status     = "pending",
    retries    = 0,
    max_retries = 3,
  }
end

--- Build a minimal valid llm_call node.
local function llm_node(id, deps)
  return {
    id              = id,
    action          = "llm_call",
    prompt_template = "Summarize: {" .. id .. "}",
    depends_on      = deps or {},
    status          = "pending",
  }
end

--- Build a minimal valid decision node.
local function decision_node(id, deps, if_true, if_false)
  return {
    id         = id,
    action     = "decision",
    condition  = "length > 100",
    if_true    = if_true  or "yes",
    if_false   = if_false or "no",
    depends_on = deps or {},
    status     = "pending",
  }
end

--- Build a graph from a list of nodes.
local function make_graph(nodes, metadata)
  return { nodes = nodes, metadata = metadata or {} }
end

-- ---------------------------------------------------------------------------
-- graph.validate
-- ---------------------------------------------------------------------------

describe("graph.validate", function()

  it("accepts a minimal valid skill graph", function()
    local g = make_graph({ skill_node("1") })
    local ok, errs = graph.validate(g)
    assert.is_true(ok, table.concat(errs or {}, ", "))
  end)

  it("accepts all three action types", function()
    local g = make_graph({
      skill_node("1"),
      llm_node("2", {"1"}),
      decision_node("3", {"2"}, "4", "5"),
      skill_node("4", {"3"}),
      skill_node("5", {"3"}),
    })
    local ok, errs = graph.validate(g)
    assert.is_true(ok, table.concat(errs or {}, ", "))
  end)

  it("rejects non-table input", function()
    local ok, errs = graph.validate("not a table")
    assert.is_false(ok)
    assert.is_truthy(errs[1]:find("must be a table", 1, true))
  end)

  it("rejects missing nodes field", function()
    local ok, errs = graph.validate({})
    assert.is_false(ok)
    assert.is_truthy(errs[1]:find("nodes", 1, true))
  end)

  it("rejects duplicate node IDs", function()
    local g = make_graph({ skill_node("1"), skill_node("1") })
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("duplicate", 1, true) then found = true end
    end
    assert.is_true(found, "expected duplicate error")
  end)

  it("rejects depends_on referencing unknown ID", function()
    local g = make_graph({ skill_node("1", {"nonexistent"}) })
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("nonexistent", 1, true) then found = true end
    end
    assert.is_true(found)
  end)

  it("detects a direct cycle (A -> A)", function()
    local n = skill_node("A", {"A"})
    local g = make_graph({ n })
    -- Add A to seen_ids so self-reference can be detected
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("cycle", 1, true) then found = true end
    end
    assert.is_true(found, "expected cycle error")
  end)

  it("detects a two-node cycle (A -> B -> A)", function()
    local a = skill_node("A", {"B"})
    local b = skill_node("B", {"A"})
    local ok, errs = graph.validate(make_graph({ a, b }))
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("cycle", 1, true) then found = true end
    end
    assert.is_true(found)
  end)

  it("detects a three-node cycle (A -> B -> C -> A)", function()
    local g = make_graph({
      skill_node("A", {"C"}),
      skill_node("B", {"A"}),
      skill_node("C", {"B"}),
    })
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("cycle", 1, true) then found = true end
    end
    assert.is_true(found)
  end)

  it("rejects skill node missing skill_name", function()
    local g = make_graph({ { id = "1", action = "skill", depends_on = {} } })
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("skill_name", 1, true) then found = true end
    end
    assert.is_true(found)
  end)

  it("rejects llm_call node missing prompt_template", function()
    local g = make_graph({ { id = "1", action = "llm_call", depends_on = {} } })
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("prompt_template", 1, true) then found = true end
    end
    assert.is_true(found)
  end)

  it("rejects decision node missing condition", function()
    local g = make_graph({ {
      id = "1", action = "decision", depends_on = {},
      if_true = "x", if_false = "y"
      -- condition missing
    } })
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("condition", 1, true) then found = true end
    end
    assert.is_true(found)
  end)

  it("rejects decision node missing if_true", function()
    local g = make_graph({ {
      id = "1", action = "decision", depends_on = {},
      condition = "x > 0", if_false = "no"
    } })
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("if_true", 1, true) then found = true end
    end
    assert.is_true(found)
  end)

  it("rejects unknown action type", function()
    local g = make_graph({ { id = "1", action = "teleport", depends_on = {} } })
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("invalid", 1, true) or e:find("action", 1, true) then found = true end
    end
    assert.is_true(found)
  end)

  it("collects multiple errors in one pass", function()
    local g = make_graph({
      { id = "1", action = "skill", depends_on = {} },        -- missing skill_name
      { id = "1", action = "llm_call", depends_on = {} },     -- duplicate id + missing prompt_template
    })
    local ok, errs = graph.validate(g)
    assert.is_false(ok)
    assert.is_true(#errs >= 2, "expected at least 2 errors, got " .. #errs)
  end)

  it("accepts node with all optional fields present", function()
    local g = make_graph({ {
      id          = "1",
      action      = "skill",
      skill_name  = "read_csv",
      depends_on  = {},
      status      = "pending",
      retries     = 0,
      max_retries = 3,
      result      = nil,
    } })
    local ok, errs = graph.validate(g)
    assert.is_true(ok, table.concat(errs or {}, ", "))
  end)

  it("does not modify the input graph", function()
    local g = make_graph({ skill_node("1"), skill_node("2", {"1"}) })
    local before = { n = #g.nodes, id0 = g.nodes[1].id }
    graph.validate(g)
    assert.equals(before.n,   #g.nodes)
    assert.equals(before.id0, g.nodes[1].id)
  end)

end)

-- ---------------------------------------------------------------------------
-- graph.topological_sort
-- ---------------------------------------------------------------------------

describe("graph.topological_sort", function()

  it("returns single node graph", function()
    local g = make_graph({ skill_node("1") })
    local result, err = graph.topological_sort(g)
    assert.is_nil(err)
    assert.equals(1, #result)
    assert.equals("1", result[1])
  end)

  it("dependency comes before dependent", function()
    local g = make_graph({
      skill_node("1"),
      llm_node("2", {"1"}),
    })
    local result, err = graph.topological_sort(g)
    assert.is_nil(err)
    assert.equals(2, #result)
    -- "1" must appear before "2"
    local pos = {}
    for i, id in ipairs(result) do pos[id] = i end
    assert.is_true(pos["1"] < pos["2"], "1 must precede 2")
  end)

  it("chain A -> B -> C has A first, C last", function()
    local g = make_graph({
      skill_node("A"),
      skill_node("B", {"A"}),
      skill_node("C", {"B"}),
    })
    local result, err = graph.topological_sort(g)
    assert.is_nil(err)
    assert.equals(3, #result)
    local pos = {}
    for i, id in ipairs(result) do pos[id] = i end
    assert.is_true(pos["A"] < pos["B"])
    assert.is_true(pos["B"] < pos["C"])
  end)

  it("diamond dependency: A -> B, A -> C, B -> D, C -> D", function()
    local g = make_graph({
      skill_node("A"),
      skill_node("B", {"A"}),
      skill_node("C", {"A"}),
      skill_node("D", {"B", "C"}),
    })
    local result, err = graph.topological_sort(g)
    assert.is_nil(err)
    assert.equals(4, #result)
    local pos = {}
    for i, id in ipairs(result) do pos[id] = i end
    assert.is_true(pos["A"] < pos["B"])
    assert.is_true(pos["A"] < pos["C"])
    assert.is_true(pos["B"] < pos["D"])
    assert.is_true(pos["C"] < pos["D"])
  end)

  it("returns nil + 'cycle detected' for cyclic graph", function()
    local g = make_graph({
      skill_node("A", {"B"}),
      skill_node("B", {"A"}),
    })
    local result, err = graph.topological_sort(g)
    assert.is_nil(result)
    assert.is_truthy(err:find("cycle", 1, true))
  end)

  it("returns nil + error for invalid graph input", function()
    local result, err = graph.topological_sort("not a graph")
    assert.is_nil(result)
    assert.is_truthy(err)
  end)

  it("result contains all node IDs", function()
    local g = make_graph({
      skill_node("x"),
      skill_node("y", {"x"}),
      skill_node("z", {"x"}),
    })
    local result, err = graph.topological_sort(g)
    assert.is_nil(err)
    local id_set = {}
    for _, id in ipairs(result) do id_set[id] = true end
    assert.is_true(id_set["x"])
    assert.is_true(id_set["y"])
    assert.is_true(id_set["z"])
  end)

end)

-- ---------------------------------------------------------------------------
-- graph.get_ready_nodes
-- ---------------------------------------------------------------------------

describe("graph.get_ready_nodes", function()

  it("returns pending node with no dependencies", function()
    local g = make_graph({ skill_node("1") })
    local ready = graph.get_ready_nodes(g)
    assert.equals(1, #ready)
    assert.equals("1", ready[1].id)
  end)

  it("returns empty list when dependency is not complete", function()
    local g = make_graph({
      skill_node("1"),
      skill_node("2", {"1"}),
    })
    local ready = graph.get_ready_nodes(g)
    -- Only "1" is ready; "2" is blocked
    assert.equals(1, #ready)
    assert.equals("1", ready[1].id)
  end)

  it("returns dependent node once dependency is complete", function()
    local g = make_graph({
      { id = "1", action = "skill", skill_name = "x", depends_on = {}, status = "complete" },
      skill_node("2", {"1"}),
    })
    local ready = graph.get_ready_nodes(g)
    assert.equals(1, #ready)
    assert.equals("2", ready[1].id)
  end)

  it("returns multiple independent ready nodes", function()
    local g = make_graph({
      skill_node("A"),
      skill_node("B"),
      skill_node("C"),
    })
    local ready = graph.get_ready_nodes(g)
    assert.equals(3, #ready)
  end)

  it("does not return completed nodes", function()
    local g = make_graph({
      { id = "1", action = "skill", skill_name = "x", depends_on = {}, status = "complete" },
    })
    local ready = graph.get_ready_nodes(g)
    assert.equals(0, #ready)
  end)

  it("does not return skipped nodes", function()
    local g = make_graph({
      { id = "1", action = "skill", skill_name = "x", depends_on = {}, status = "skipped" },
    })
    local ready = graph.get_ready_nodes(g)
    assert.equals(0, #ready)
  end)

  it("returns empty list for invalid input", function()
    assert.same({}, graph.get_ready_nodes(nil))
    assert.same({}, graph.get_ready_nodes("bad"))
    assert.same({}, graph.get_ready_nodes({}))
  end)

  it("node with multiple deps only ready when all complete", function()
    local g = make_graph({
      { id = "A", action = "skill", skill_name = "x", depends_on = {}, status = "complete" },
      { id = "B", action = "skill", skill_name = "x", depends_on = {}, status = "pending" },
      skill_node("C", {"A", "B"}),
    })
    local ready = graph.get_ready_nodes(g)
    -- B is ready, C is not (B not complete)
    local ids = {}
    for _, n in ipairs(ready) do ids[n.id] = true end
    assert.is_true(ids["B"])
    assert.is_nil(ids["C"])
  end)

end)

-- ---------------------------------------------------------------------------
-- graph.is_complete
-- ---------------------------------------------------------------------------

describe("graph.is_complete", function()

  it("returns true when all nodes are complete", function()
    local g = make_graph({
      { id = "1", action = "skill", skill_name = "x", depends_on = {}, status = "complete" },
      { id = "2", action = "skill", skill_name = "x", depends_on = {}, status = "complete" },
    })
    assert.is_true(graph.is_complete(g))
  end)

  it("returns true when all nodes are skipped", function()
    local g = make_graph({
      { id = "1", action = "skill", skill_name = "x", depends_on = {}, status = "skipped" },
    })
    assert.is_true(graph.is_complete(g))
  end)

  it("returns true for mixed complete and skipped", function()
    local g = make_graph({
      { id = "1", action = "skill", skill_name = "x", depends_on = {}, status = "complete" },
      { id = "2", action = "skill", skill_name = "x", depends_on = {}, status = "skipped" },
    })
    assert.is_true(graph.is_complete(g))
  end)

  it("returns false when any node is pending", function()
    local g = make_graph({
      { id = "1", action = "skill", skill_name = "x", depends_on = {}, status = "complete" },
      skill_node("2"),
    })
    assert.is_false(graph.is_complete(g))
  end)

  it("returns false when any node is running", function()
    local g = make_graph({
      { id = "1", action = "skill", skill_name = "x", depends_on = {}, status = "running" },
    })
    assert.is_false(graph.is_complete(g))
  end)

  it("returns false for empty graph (fix #3)", function()
    assert.is_false(graph.is_complete(make_graph({})))
  end)

  it("returns false for invalid input", function()
    assert.is_false(graph.is_complete(nil))
    assert.is_false(graph.is_complete("bad"))
  end)

  it("treats missing status as pending", function()
    local g = make_graph({
      { id = "1", action = "skill", skill_name = "x", depends_on = {} },
    })
    assert.is_false(graph.is_complete(g))
  end)

end)

-- ---------------------------------------------------------------------------
-- graph.mark_downstream_skipped
-- ---------------------------------------------------------------------------

describe("graph.mark_downstream_skipped", function()

  it("marks direct dependent as skipped", function()
    local g = make_graph({
      skill_node("A"),
      skill_node("B", {"A"}),
    })
    local new_g = graph.mark_downstream_skipped(g, "A")
    local b = new_g.nodes[2]
    assert.equals("skipped", b.status)
  end)

  it("does not mark the failed node itself as skipped", function()
    local g = make_graph({
      skill_node("A"),
      skill_node("B", {"A"}),
    })
    local new_g = graph.mark_downstream_skipped(g, "A")
    assert.equals("pending", new_g.nodes[1].status)
  end)

  it("marks transitive dependents as skipped", function()
    local g = make_graph({
      skill_node("A"),
      skill_node("B", {"A"}),
      skill_node("C", {"B"}),
      skill_node("D", {"C"}),
    })
    local new_g = graph.mark_downstream_skipped(g, "A")
    local statuses = {}
    for _, n in ipairs(new_g.nodes) do statuses[n.id] = n.status end
    assert.equals("pending",  statuses["A"])
    assert.equals("skipped",  statuses["B"])
    assert.equals("skipped",  statuses["C"])
    assert.equals("skipped",  statuses["D"])
  end)

  it("does not mark unrelated nodes as skipped", function()
    local g = make_graph({
      skill_node("A"),
      skill_node("B", {"A"}),
      skill_node("C"),   -- independent
    })
    local new_g = graph.mark_downstream_skipped(g, "A")
    local statuses = {}
    for _, n in ipairs(new_g.nodes) do statuses[n.id] = n.status end
    assert.equals("pending", statuses["C"])
  end)

  it("does not mutate the original graph (fix #4)", function()
    local g = make_graph({
      skill_node("A"),
      skill_node("B", {"A"}),
    })
    local original_status = g.nodes[2].status
    graph.mark_downstream_skipped(g, "A")
    assert.equals(original_status, g.nodes[2].status, "original graph must not be modified")
  end)

  it("returns a new graph table, not the same reference", function()
    local g = make_graph({ skill_node("A"), skill_node("B", {"A"}) })
    local new_g = graph.mark_downstream_skipped(g, "A")
    assert.is_true(new_g ~= g, "must return a new table")
  end)

  it("handles node with no downstream dependents", function()
    local g = make_graph({
      skill_node("A"),
      skill_node("B", {"A"}),
    })
    -- B has no dependents — nothing to skip
    local new_g = graph.mark_downstream_skipped(g, "B")
    for _, n in ipairs(new_g.nodes) do
      assert.equals("pending", n.status)
    end
  end)

  it("handles unknown failed_node_id gracefully", function()
    local g = make_graph({ skill_node("A") })
    local new_g = graph.mark_downstream_skipped(g, "nonexistent")
    assert.equals("pending", new_g.nodes[1].status)
  end)

  it("handles diamond: skips both branches and merge node", function()
    --   A
    --  / \
    -- B   C
    --  \ /
    --   D
    local g = make_graph({
      skill_node("A"),
      skill_node("B", {"A"}),
      skill_node("C", {"A"}),
      skill_node("D", {"B", "C"}),
    })
    local new_g = graph.mark_downstream_skipped(g, "A")
    local statuses = {}
    for _, n in ipairs(new_g.nodes) do statuses[n.id] = n.status end
    assert.equals("pending", statuses["A"])
    assert.equals("skipped", statuses["B"])
    assert.equals("skipped", statuses["C"])
    assert.equals("skipped", statuses["D"])
  end)

end)

-- ---------------------------------------------------------------------------
-- graph.from_json
-- ---------------------------------------------------------------------------

describe("graph.from_json", function()

  it("parses and returns a valid graph", function()
    local json = [[{
      "nodes": [
        {"id":"1","action":"skill","skill_name":"read_csv","depends_on":[],"status":"pending","retries":0,"max_retries":3}
      ],
      "metadata": {"prompt":"test"}
    }]]
    local g, err = graph.from_json(json)
    assert.is_nil(err)
    assert.is_table(g)
    assert.equals(1, #g.nodes)
    assert.equals("1", g.nodes[1].id)
  end)

  it("returns error for non-string input", function()
    local g, err = graph.from_json(42)
    assert.is_nil(g)
    assert.is_truthy(err:find("JSON string", 1, true))
  end)

  it("returns error for malformed JSON", function()
    local g, err = graph.from_json("{not valid json")
    assert.is_nil(g)
    assert.is_truthy(err:find("JSON parse error", 1, true))
  end)

  it("returns error for JSON that fails validation", function()
    local json = [[{"nodes": [{"id":"1","action":"skill","depends_on":[]}]}]]  -- missing skill_name
    local g, err = graph.from_json(json)
    assert.is_nil(g)
    assert.is_truthy(err:find("validation failed", 1, true))
  end)

  it("returns error for JSON array instead of object", function()
    local g, err = graph.from_json("[]")
    -- An array is still a table in Lua/cjson, so validation will catch it
    -- (no .nodes field) rather than the type check
    assert.is_nil(g)
    assert.is_truthy(err)
  end)

  it("returns a graph that passes validate", function()
    local json = [[{
      "nodes": [
        {"id":"A","action":"skill","skill_name":"s","depends_on":[]},
        {"id":"B","action":"llm_call","prompt_template":"do {A}","depends_on":["A"]}
      ]
    }]]
    local g, err = graph.from_json(json)
    assert.is_nil(err)
    local ok, verr = graph.validate(g)
    assert.is_true(ok, table.concat(verr or {}, ", "))
  end)

end)
