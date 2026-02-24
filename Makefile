.PHONY: help check deps clean

LUAROCKS ?= luarocks
LUA ?= lua

# rock name → require() name
ROCKS := lua-cjson luafilesystem uuid ansicolors argparse busted luasocket
MODULES := cjson lfs uuid ansicolors argparse busted socket.http ltn12

help:
	@echo "Targets:"
	@echo "  make deps   - Install required Lua rocks (default tree)"
	@echo "  make check  - Verify rocks are accessible via require()"
	@echo "  make clean  - Remove the rocks"
	@echo ""
	@echo "Requires Lua and LuaRocks to already be installed."

check:
	@which $(LUAROCKS) > /dev/null || (echo "ERROR: luarocks not found. Install with Homebrew: brew install luarocks" && exit 1)
	@which $(LUA) > /dev/null || (echo "ERROR: lua not found. Install with Homebrew: brew install lua" && exit 1)
	@echo "Checking Lua modules..."
	@failed=0; \
	for m in $(MODULES); do \
		if $(LUA) -e "require('$$m')" >/dev/null 2>&1; then \
			echo "✓ $$m available"; \
		else \
			echo "✗ $$m missing"; \
			failed=1; \
		fi; \
	done; \
	exit $$failed

deps:
	@echo "Installing rocks into default LuaRocks tree..."
	@for r in $(ROCKS); do \
		echo "→ $(LUAROCKS) install $$r"; \
		$(LUAROCKS) install $$r || exit $$?; \
	done
	@echo "✓ Done"

clean:
	@echo "Removing rocks..."
	@for r in $(ROCKS); do \
		$(LUAROCKS) remove $$r >/dev/null 2>&1 || true; \
	done
	@echo "✓ Cleaned"

