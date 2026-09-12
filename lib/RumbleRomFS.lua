local V = ...
local B = V.require("RumbleBinary")
local R={}; R.__index=R
local IMPORT_ID="rumble_pii_pack"
local PACK_SIZE=1663232
local EXPECT_COUNT=152
local RECORD_SIZE=48
local HEADER_SIZE=16
local MAX_READ=8*1024*1024

local EMBEDDED_PATH="assets/rumble_pii.pack"
local embedded=nil
local embeddedChecked=false

local function embeddedPack()
  if embeddedChecked then return embedded end
  embeddedChecked=true
  if V.mod and type(V.mod.read)=="function" then
    local ok,data=pcall(function() return V.mod:read(EMBEDDED_PATH) end)
    if ok and type(data)=="string" and #data>0 then
      assert(#data==PACK_SIZE,"wrong embedded rumble_pii.pack size: "..tostring(#data))
      embedded=data
      if V.log then V.log:info("Rumble Main using embedded /pii asset pack") end
    end
  end
  return embedded
end

local function info()
  local data=embeddedPack()
  if data then return {size=#data,embedded=true} end
  assert(V.mod and V.mod.imports and type(V.mod.imports.info)=="function",
    "Rumble Main has no embedded /pii pack and Gen1Recomp mod.imports API is unavailable")
  local x,err=V.mod.imports:info(IMPORT_ID)
  assert(x,"missing Rumble /pii asset pack: "..tostring(err))
  if x.size then assert(tonumber(x.size)==PACK_SIZE,
    "wrong rumble_pii.pack size: "..tostring(x.size)) end
  return x
end

local function read(off,n)
  assert(n<=MAX_READ,"internal Rumble pack read exceeds 8 MiB")
  local data=embeddedPack()
  if data then
    local out=data:sub(off+1,off+n)
    assert(#out==n,"short embedded Rumble pack read")
    return out
  end
  local s,err=V.mod.imports:read(IMPORT_ID,off,n)
  assert(type(s)=="string","Rumble pack read failed @"..tostring(off)..": "..tostring(err))
  assert(#s==n,"short Rumble pack read")
  return s
end

local function cstr36(s)
  local z=s:find("\0",1,true)
  if z then return s:sub(1,z-1) end
  return s
end

function R.open()
  info()
  local h=read(0,HEADER_SIZE)
  assert(h:sub(1,8)=="RPII1\0\0\0","invalid Rumble /pii pack")
  local count=B.u32(h,8)
  local recsz=B.u32(h,12)
  assert(count==EXPECT_COUNT,"unexpected Rumble /pii resource count: "..tostring(count))
  assert(recsz==RECORD_SIZE,"unsupported Rumble /pii record size")
  local self=setmetatable({files={},basenames={}},R)
  local tableBytes=read(HEADER_SIZE,count*RECORD_SIZE)
  for i=0,count-1 do
    local o=i*RECORD_SIZE
    local name=cstr36(tableBytes:sub(o+1,o+36))
    local dataOffset=B.u32(tableBytes,o+36)
    local dataSize=B.u32(tableBytes,o+40)
    local p="/pii/"..name
    local e={dataOffset=dataOffset,dataSize=dataSize,name=name}
    self.files[p]=e
    self.basenames[name]=e
  end
  if V.log then V.log:info("Rumble compact /pii pack ready: %d resources",count) end
  return self
end

function R:read(path)
  local e=assert(self.files[path],"Rumble /pii file not found: "..tostring(path))
  return read(e.dataOffset,e.dataSize)
end

function R:listPii()
  local t={}
  for p in pairs(self.files) do t[#t+1]=p end
  table.sort(t)
  return t
end
return R
