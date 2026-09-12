local V = ...
local R={}
local cache={}
local imageCache={}
local providers={}

-- v1.4.9: all loose Pii replacement PNGs are stored in one compact pack.
-- Replacement Lua files keep their original assets/###/Pii_*.png paths; this
-- resolver makes those paths transparent to the rest of the renderer.
local texturePack=nil
local texturePackChecked=false
local TEXTURE_PACK_PATH="assets/rumble_textures.pack"
local TEXTURE_PACK_MAGIC="RPTX1\0\0\0"
local TEXTURE_PACK_RECSIZE=72

local function u32le(s,o)
  local a,b,c,d=s:byte(o+1,o+4)
  if not d then return nil end
  return a+b*256+c*65536+d*16777216
end

local function packedTexture(rel)
  if not texturePackChecked then
    texturePackChecked=true
    local ok,data=pcall(function() return V.mod:read(TEXTURE_PACK_PATH) end)
    if ok and type(data)=="string" and #data>=16 and data:sub(1,8)==TEXTURE_PACK_MAGIC then
      local count=u32le(data,8)
      local recsz=u32le(data,12)
      if recsz==TEXTURE_PACK_RECSIZE then
        local index={}
        local pos=17
        for _=1,count do
          local raw=data:sub(pos,pos+63)
          local z=raw:find("\0",1,true)
          local name=z and raw:sub(1,z-1) or raw
          local off=u32le(data,pos+63)
          local size=u32le(data,pos+67)
          if name~="" and off and size then index[name]={off=off,size=size} end
          pos=pos+recsz
        end
        texturePack={data=data,index=index}
        if V.log then V.log:info("Rumble packed replacement textures ready: %d images",count) end
      elseif V.log then
        V.log:warn("Unsupported Rumble texture pack record size: %s",tostring(recsz))
      end
    end
  end
  local e=texturePack and texturePack.index[rel]
  if not e then return nil end
  return texturePack.data:sub(e.off+1,e.off+e.size)
end

local function providerReplacement(species)
  if #providers==0 then return nil end
  local ordered={}
  for i,p in ipairs(providers) do ordered[i]=p end
  table.sort(ordered,function(a,b) return (tonumber(a.priority) or 0)>(tonumber(b.priority) or 0) end)
  for _,provider in ipairs(ordered) do
    local fn=provider and (provider.load or provider.get or provider.modelFor)
    if type(fn)=="function" then
      local ok,repl=pcall(fn,species)
      if not ok then ok,repl=pcall(fn,provider,species) end
      if ok and type(repl)=="table" and repl.groups and #repl.groups>0 then
        repl._externalProvider=provider.id or provider.name or "external"
        return repl
      elseif not ok and V.log then
        V.log:warn("Replacement provider %s failed for %03d: %s",tostring(provider.id or provider.name),species,tostring(repl))
      end
    end
  end
  return nil
end

function R.registerProvider(provider)
  if type(provider)~="table" then return false,"provider must be a table" end
  local fn=provider.load or provider.get or provider.modelFor
  if type(fn)~="function" then return false,"provider needs load/get/modelFor" end
  for i=#providers,1,-1 do
    if providers[i]==provider or (provider.id and providers[i].id==provider.id) then table.remove(providers,i) end
  end
  providers[#providers+1]=provider
  cache={}
  if V.log then V.log:info("Rumble replacement provider registered: %s",tostring(provider.id or provider.name or "external")) end
  return true
end

function R.unregisterProvider(id)
  local removed=false
  for i=#providers,1,-1 do
    local p=providers[i]
    if p==id or p.id==id then table.remove(providers,i); removed=true end
  end
  if removed then cache={} end
  return removed
end

-- Maximum-compression build: all 151 replacement Lua meshes live in one pack.
local replacementSourcePack=nil
local replacementSourceIndex=nil
local REPLACEMENT_PACK_PATH="assets/rumble_replacements.pack"
local REPLACEMENT_PACK_MAGIC="RPLU1\0\0\0"
local REPLACEMENT_PACK_RECSIZE=16

local function replacementSource(species)
  if not replacementSourcePack then
    local data=assert(V.mod:read(REPLACEMENT_PACK_PATH),"RUMBLE replacement source pack missing")
    assert(data:sub(1,8)==REPLACEMENT_PACK_MAGIC,"invalid RUMBLE replacement source pack")
    local count=u32le(data,8)
    local recsz=u32le(data,12)
    assert(recsz==REPLACEMENT_PACK_RECSIZE,"unsupported RUMBLE replacement source record size")
    local index={}
    local pos=17
    for _=1,count do
      local sp=u32le(data,pos-1)
      local off=u32le(data,pos+3)
      local size=u32le(data,pos+7)
      if sp and off and size then index[sp]={off=off,size=size} end
      pos=pos+recsz
    end
    replacementSourcePack=data
    replacementSourceIndex=index
    if V.log then V.log:info("Rumble packed replacement sources ready: %d species",count) end
  end
  local e=replacementSourceIndex and replacementSourceIndex[species]
  if not e then return nil end
  return replacementSourcePack:sub(e.off+1,e.off+e.size)
end

local function chunk(rel)
  local species=tonumber(rel:match("(%d+)%.lua$"))
  local source=species and replacementSource(species) or nil
  if not source then error("RUMBLE replacement missing "..rel,0) end
  local fn,err=load(source,"@"..V.path.."/"..rel)
  if not fn then error("RUMBLE replacement compile error "..rel..": "..tostring(err),0) end
  return fn
end

local function loadImage(rel,wrap)
  local key=rel.."|"..tostring(wrap or "clamp")
  if imageCache[key] then return imageCache[key] end
  local bytes=packedTexture(rel)
  if not bytes then bytes=V.mod:read(rel) end
  if not bytes then return nil end

  local ok,img=pcall(function()
    local fd=love.filesystem.newFileData(bytes,rel)
    local data=love.image.newImageData(fd)
    local tex=love.graphics.newImage(data)
    if tex and tex.setWrap then
      local w=(wrap=="repeat") and "repeat" or "clamp"
      pcall(tex.setWrap,tex,w,w)
    end
    return tex
  end)
  if not ok then
    if V.log then V.log:warn("Replacement texture failed %s: %s",rel,tostring(img)) end
    return nil
  end
  imageCache[key]=img
  return img
end

function R.load(species)
  species=tonumber(species)
  if not species or species<1 or species>151 then return nil end
  if cache[species] then return cache[species] end

  local external=providerReplacement(species)
  if external then
    local minY,maxY=math.huge,-math.huge
    local radius=0
    for _,g in ipairs(external.groups or {}) do
      for _,v in ipairs(g.vertices or {}) do
        local p=v.p or {0,0,0}
        local x,y,z=p[1] or 0,p[2] or 0,p[3] or 0
        if y<minY then minY=y end
        if y>maxY then maxY=y end
        local rr=math.sqrt(x*x+z*z); if rr>radius then radius=rr end
      end
    end
    if minY==math.huge then minY,maxY=0,tonumber(external.height) or 1 end
    external.minY=minY
    external.maxY=maxY
    external.height=math.max(tonumber(external.height) or (maxY-minY),0.001)
    external.radius=radius
    cache[species]=external
    return external
  end

  local rel=("replacements/%03d.lua"):format(species)
  local ok,repl=pcall(function() return chunk(rel)() end)
  if not ok or type(repl)~="table" then
    if V.log then V.log:warn("Replacement mesh %03d failed: %s",species,tostring(repl)) end
    return nil
  end

  local minY,maxY=math.huge,-math.huge
  local radius=0
  for _,g in ipairs(repl.groups or {}) do
    g.image=loadImage(g.texture,g.wrap)
    for _,v in ipairs(g.vertices or {}) do
      local p=v.p or {0,0,0}
      local x,y,z=p[1] or 0,p[2] or 0,p[3] or 0
      if y<minY then minY=y end
      if y>maxY then maxY=y end
      local rr=math.sqrt(x*x+z*z)
      if rr>radius then radius=rr end
    end
  end
  if minY==math.huge then minY,maxY=0,tonumber(repl.height) or 1 end
  repl.minY=minY
  repl.maxY=maxY
  repl.height=math.max(tonumber(repl.height) or (maxY-minY),0.001)
  repl.radius=radius
  cache[species]=repl
  return repl
end

function R.invalidate()
  cache={}
  for _,img in pairs(imageCache) do
    if img and img.release then pcall(img.release,img) end
  end
  imageCache={}
end

return R
