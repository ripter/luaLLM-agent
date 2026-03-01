# Lua Jokes

## plan
model: Qwen3-Coder-Next-Q8_0
sanitize_fences: true
context: false
output: agent_wrote/joke.lua
test_runner: busted

## system prompt
You are a Lua code generator. Output ONLY valid Lua code. No markdown fences.
No explanations, no commentary. Start with the first line of code.

## prompt
generate a program with tests that tells a random joke about lua each time it is called.
It should have at least 20 random jokes
