Write a Lua module graph.lua — a task graph (DAG) engine for planning multi-step tasks.

A task graph is a table with this shape:
{
  nodes = {
    { id = "1", action = "skill", skill_name = "read_csv", skill_args = {path="..."}, depends_on = {}, status = "pending", retries = 0, max_retries = 3, result = nil },
    { id = "2", action = "llm_call", prompt_template = "Summarize: {1}", depends_on = {"1"}, status = "pending", retries = 0, max_retries = 3, result = nil },
    { id = "3", action = "decision", condition = "length > 1000", if_true = "4", if_false = "5", depends_on = {"2"}, status = "pending", retries = 0, max_retries = 3, result = nil },
  },
  metadata = { prompt = "...", created_at = "...", model = "..." }
}

Requirements:
- graph.validate(g) — check: all node IDs unique, all depends_on reference valid IDs, no cycles. Return true or false + list of error strings.
- graph.topological_sort(g) — return ordered list of node IDs, or nil + "cycle detected"
- graph.get_ready_nodes(g) — return nodes where status=="pending" and all depends_on nodes have status=="complete"
- graph.is_complete(g) — true if every node is "complete" or "skipped"
- graph.mark_downstream_skipped(g, failed_node_id) — find all nodes that transitively depend on failed_node_id, set their status to "skipped"
- graph.from_json(json_string) — parse JSON, validate, return graph table or nil + errors
- All functions are pure: no I/O, no side effects, no requires beyond cjson.safe

Use cjson.safe for JSON parsing. Follow the same module style as context files.
