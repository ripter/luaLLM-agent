-- test_complete.lua
local luallm = require("src.luallm")

local messages = {
  { role = "user", content = "Say hello in one short sentence." }
}

local response, err = luallm.complete("GLM-4.5-Air-Q4_1", messages)

if err then
  print("ERROR:", err)
else
  print("SUCCESS:")
  print(require("cjson").encode(response))
end

