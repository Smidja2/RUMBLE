local V = ...
local RomFS=V.require("RumbleRomFS")
local LZH=V.require("RumbleLZH8")
local CGFX=V.require("RumbleCGFX")
local Anim=V.require("RumbleAnim")
local Species=V.require("RumbleSpecies")
local Replacement=V.require("RumbleReplacement")
local SpeciesScale=V.require("RumbleSpeciesScale")
local R={}
R.FPS=30
R.NONE=0xFFFF
R.N_MOVES=165
local rom,animations,index
local cache={}
local failed=nil

local function init()
  if rom then return true end
  if failed then return false,failed end
  local ok,err=pcall(function()
    rom=RomFS.open(); index={}
    for _,p in ipairs(rom:listPii()) do index[p:match("/([^/]+)$")]=p end
    animations=Anim.parse(LZH.decompress(rom:read("/pii/anim.bcres.cx")))
  end)
  if not ok then
    failed=tostring(err)
    if V.log then
      V.log:error("RUMBLE INIT FAILED: %s",failed)
      V.log:error("Rumble models will fall back to sprites until this is fixed.")
    end
    return false,failed
  end
  if V.log then V.log:info("Rumble RomFS ready: %d /pii resources",#rom:listPii()) end
  return true
end

function R.available()
  local ok=init()
  return ok and true or false
end

local function radiusOf(parsed)
  local r=0
  for _,sh in pairs(parsed.shapes or {}) do
    for _,v in ipairs(sh.vertices or {}) do
      local x,z=v.pos[1] or 0,v.pos[3] or 0
      local q=math.sqrt(x*x+z*z); if q>r then r=q end
    end
  end
  return r
end

local function clipFor(family,state)
  local _,clip=Anim.chooseState(animations,family,state)
  return clip
end

function R.load(species,shiny)
  if not (species and species>=1 and species<=151) then return nil end
  if cache[species] then return cache[species] end
  local ok,err=init(); if not ok then return nil end
  local base=Species.base(species,nil,index)
  if not base then return nil end
  local path=index[base..".bcres.cx"]
  if not path then return nil end
  local good,res=pcall(function()
    local parsed=CGFX.parse(LZH.decompress(rom:read(path)))
    local textures=CGFX.buildTextures(parsed)
    local family=Anim.family(parsed.name)
    local idle=clipFor(family,"idle")
    local attack=clipFor(family,"attack") or idle
    local faint=clipFor(family,"faint") or idle
    local entrance=clipFor(family,"entrance") or attack or idle
    assert(idle,"no Rumble animation for family "..tostring(family))
    local anims={
      {name="idle",clip=idle,frames=idle.frames or 1,seconds=math.max(1,idle.frames or 1)/R.FPS},
      {name="attack",clip=attack,frames=attack.frames or 1,seconds=math.max(1,attack.frames or 1)/R.FPS},
      {name="faint",clip=faint,frames=faint.frames or 1,seconds=math.max(1,faint.frames or 1)/R.FPS},
      {name="entrance",clip=entrance,frames=entrance.frames or 1,seconds=math.max(1,entrance.frames or 1)/R.FPS},
    }
    local ctx={}; ctx[1]=0;ctx[2]=1;ctx[3]=2;ctx[4]=3
    for i=5,20 do ctx[i]=0 end
    local moveAnim,moveAux={},{}
    for i=1,R.N_MOVES do moveAnim[i]=1;moveAux[i]=-1 end
    local replacement=Replacement.load(species)
    local renderHeight=(replacement and replacement.height) or parsed.height
    local renderFloor=(replacement and replacement.minY) or parsed.minY
    local renderRadius=(replacement and replacement.radius) or radiusOf(parsed)

    -- v1.3.7: the replacement/base mesh automatic size is the true baseline.
    -- The four visual buckets only multiply that known-good automatic size.
    local function originalTargetHeight(raw)
      local h=raw or 1
      local wh=13.5*math.sqrt(math.max(h,0.05))
      if wh<6 then wh=6 elseif wh>20 then wh=20 end
      return wh
    end

    local originalAutoScale=originalTargetHeight(renderHeight)/math.max(renderHeight,1e-6)
    local classScale=SpeciesScale.relative(species)
    local loreScale=originalAutoScale*classScale
    local overworldScale=originalAutoScale*classScale

    return {
      _rumble=true,species=species,shiny=false,staticPose=false,
      rootScale=overworldScale,loreScale=loreScale,overworldScale=overworldScale,
      displayHeightLore=renderHeight*loreScale,
      displayHeightOverworld=renderHeight*overworldScale,
      height=renderHeight,floor=renderFloor,radius=renderRadius,
      parsed=parsed,texturesByName=textures,replacement=replacement,anims=anims,ctx=ctx,
      moveAnim=moveAnim,moveAux=moveAux,auxAnims={},family=family,
    }
  end)
  if not good then
    if V.log then V.log:warn("Rumble species %03d failed: %s",species,tostring(res)) end
    return nil
  end
  cache[species]=res
  return res
end

function R.keep() end
function R.invalidate()
  for _,m in pairs(cache) do
    for _,img in pairs(m.texturesByName or {}) do if img and img.release then pcall(img.release,img) end end
  end
  cache={}
  Replacement.invalidate()
end
return R
