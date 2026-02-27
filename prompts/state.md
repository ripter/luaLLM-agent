Write a Lua module state.lua for persisting agent task state.

Requirements:
- Uses cjson.safe for encoding/decoding
- Uses lfs for file operations
- state.init(dir) — set state directory path (e.g. from config), ensure it exists
- state.save(task) — write task table as JSON to current_task.json. Use atomic writes: write to .tmp file first, then os.rename() over the real file.
- state.load() — read and parse current_task.json. Return the task table or nil if no file exists. If file exists but is invalid JSON, return nil, "corrupt".
- state.clear() — remove current_task.json (and .tmp if present)
- state.exists() — return true if current_task.json exists

Follow the same module style as the context files.