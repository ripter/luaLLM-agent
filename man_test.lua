-- test_exec.lua
local luallm = require("src.luallm")
local cjson = require("cjson.safe")

local result, err = luallm.exec("status")

if err then
  print("ERROR:", err)
else
  print("SUCCESS:")
  for k,v in pairs(result) do
    print(k, v)
  end
  print(cjson.encode(result))
end

