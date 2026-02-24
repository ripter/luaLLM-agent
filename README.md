# luaLLM-agent

A Lua-based agent built on top of luaLLM.

---

## Requirements

* **Lua 5.4**
* **LuaRocks**
* Required rocks:

  * `lua-cjson`
  * `luafilesystem`
  * `uuid`

---

## Quick Start (macOS + Homebrew)

### 1. Install Lua and LuaRocks

```bash
brew install lua luarocks
```

Verify:

```bash
lua -v
luarocks --version
```

You should see Lua 5.4.x.

---

### 2. Install Dependencies

From the project root:

```bash
make deps
```

This installs the required rocks into your default LuaRocks tree.

---

### 3. Run the Agent

Make the script executable:

```bash
chmod +x main.lua
```

Then run:

```bash
./main.lua
```

Alternatively:

```bash
lua main.lua
```

---

## Removing Dependencies

To uninstall the required rocks:

```bash
make clean
```

---

## Troubleshooting

### `luarocks: command not found`

Install it via Homebrew:

```bash
brew install luarocks
```

---

### `module 'cjson' not found`

1. Reinstall dependencies:

   ```bash
   make deps
   ```

2. Confirm Lua and LuaRocks are using the same version:

   ```bash
   lua -v
   luarocks config | grep lua_version
   ```

Both should report **5.4**.

---

### LuaRocks Installed, but `require()` Still Fails

Your shell may not have LuaRocks’ paths configured.

Run:

**zsh:**

```bash
eval "$(luarocks path)"
```

**fish:**

```fish
luarocks path | source
```

To make it permanent:

**zsh (`~/.zshrc`)**

```bash
eval "$(luarocks path)"
```

**fish (`~/.config/fish/config.fish`)**

```fish
luarocks path | source
```

Open a new terminal after editing your shell config.

