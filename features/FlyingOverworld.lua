local FLYING_ECOLOGY_KEY="rumble_flying_ecology"
local function flyingStoredOption(key,default)
  local game=_G.game or _G.Game or _G.GAME
  local stores={game and game.options,game and game.settings,_G.options,_G.settings}
  for _,t in ipairs(stores) do
    if type(t)=="table" and t[key]~=nil then return t[key] end
  end
  return default
end
local function flyingEcologyEnabled()
  local v=flyingStoredOption(FLYING_ECOLOGY_KEY,true)
  return v~=false and v~=0 and v~="OFF" and v~="NO"
end

local mod = ...

local Game = require("src.core.Game")
local Map = require("src.world.Map")

local CELL = 16

-- One flock for the first stable test. Each flock is 3-5 members.
local MIN_FLOCK = 3
local MAX_FLOCK = 7

local SPAWN_MIN_RADIUS = 6
local SPAWN_MAX_RADIUS = 10
local CRUISE_RADIUS = 11
local AIR_MIN = 42 -- v1.4.8: +50% cruise altitude
local AIR_MAX = 63 -- v1.4.8: +50% cruise altitude
local FLIGHT_SPEED = 38

-- Non-bird aerial ecology stays much lower and remains local to its spawn area.
local INSECT_AIR_MIN = 12
local INSECT_AIR_MAX = 22
local BAT_AIR_MIN = 10
local BAT_AIR_MAX = 18
local LOCAL_ROAM_RADIUS_MIN = 10
local LOCAL_ROAM_RADIUS_MAX = 26
local LOCAL_ROAM_SPEED_MIN = 0.35
local LOCAL_ROAM_SPEED_MAX = 0.75

local PERCH_CHANCE = 0.28
local PERCH_MIN = 3.5
local PERCH_MAX = 7.0
local PERCH_TIME_MULT_MIN = 1.5
local PERCH_TIME_MULT_MAX = 3.5
local FOLLOW_KEEP_RADIUS = CELL*14
local FOLLOW_LEG_LENGTH = CELL*18
-- Fallback only. Actual perching uses map/tileset-aware offsets below.
local DEFAULT_PERCH_Y = 32

-- Gen1Recomp exposes the current map's tileset, but not the rendered 3D roof
-- surface height. These offsets are therefore a compatibility layer for the
-- Dramaless 3D architecture rather than a true geometry query.
local TILESET_ROOF_HEIGHT = {
  OVERWORLD = 32,
  GATE = 30,
  FOREST_GATE = 30,
  POKECENTER = 34,
  MART = 34,
  GYM = 40,
  MANSION = 46,
  LAB = 38,
  HOUSE = 32,
  REDS_HOUSE_1 = 32,
  REDS_HOUSE_2 = 32,
  PLATEAU = 42,
}

-- Map-specific overrides win over tileset defaults. These are intentionally
-- conservative test values for cities known to contain taller architecture.
local MAP_ROOF_HEIGHT = {
  CELADON_CITY = 42,
  SAFFRON_CITY = 42,
  CINNABAR_ISLAND = 38,
  INDIGO_PLATEAU = 42,
}

local function roofOffsetForMap(map)
  if not map then return DEFAULT_PERCH_Y end

  local def=map.def or {}
  local id=tostring(map.id or def.id or ""):upper()
  local tileset=tostring(def.tileset or map.tileset or ""):upper()

  -- Exact map override.
  if MAP_ROOF_HEIGHT[id] then
    return MAP_ROOF_HEIGHT[id]
  end

  -- Exact tileset lookup.
  if TILESET_ROOF_HEIGHT[tileset] then
    return TILESET_ROOF_HEIGHT[tileset]
  end

  -- Compatibility patterns for builds whose tileset IDs are more descriptive.
  if tileset:find("MANSION",1,true) then return 46 end
  if tileset:find("GYM",1,true) then return 40 end
  if tileset:find("LAB",1,true) then return 38 end
  if tileset:find("POKECENTER",1,true) or tileset:find("POKEMON_CENTER",1,true) then return 34 end
  if tileset:find("MART",1,true) then return 34 end
  if tileset:find("GATE",1,true) then return 30 end
  if tileset:find("HOUSE",1,true) then return 32 end

  -- Map-name fallback for tall-city cases even if all outdoor cities share
  -- a generic OVERWORLD tileset.
  if id:find("CELADON",1,true) or id:find("SAFFRON",1,true) then return 42 end
  if id:find("CINNABAR",1,true) then return 38 end
  if id:find("PLATEAU",1,true) then return 42 end

  return DEFAULT_PERCH_Y
end
local TAKEOFF_STAGGER = 0.35
local REGROUP_SPEED = 42
local REGROUP_RADIUS = 16
local PERCH_TURN_MIN = 0.8
local PERCH_TURN_MAX = 2.8
local PERCH_TURN_ARC = math.rad(85)

-- Living-world predator/prey interaction.
local HUNT_SCAN_MIN = 4.0
local HUNT_SCAN_MAX = 8.0
local HUNT_RADIUS = CELL*10
local HUNT_ORBIT_RADIUS = 24
local HUNT_ORBIT_HEIGHT = 36 -- v1.4.8: +50% ecology orbit altitude
local HUNT_CIRCLE_LOOPS_MIN = 1
local HUNT_CIRCLE_LOOPS_MAX = 3
local HUNT_ORBIT_SPEED = 1.85
local HUNT_SWOOP_SPEED = 64
local HUNT_PURSUIT_SPEED = 48
local HUNT_PURSUIT_TIME = 4.5
local HUNT_REJOIN_SPEED = 58
local HUNT_TOUCH_RADIUS = 11
local HUNT_TOUCH_VERTICAL = 7
local HUNT_PICKUP_AFTER = 0.80
local HUNT_CARRY_TIME = 6.5
local HUNT_CARRY_DROP = 7
local HUNT_CARRY_DROP_BY_SPECIES = {
  [13]=3.8, -- Weedle: compact body, keep it close to the claws
  [10]=5.0, -- Caterpie: slightly lower
  [19]=7.0, -- Rattata: preserve the established spacing
}
local function carryDropFor(prey)
  local dex=prey and tonumber(prey.dex)
  return HUNT_CARRY_DROP_BY_SPECIES[dex] or HUNT_CARRY_DROP
end
local HUNT_CARRY_CLIMB = 27 -- v1.4.8: +50% carry climb altitude
local HUNT_MAX_ATTACKERS = 4
local HUNT_NORMAL_MAX_ATTACKERS = 3
local HUNT_STAGGER_MIN = 0.22
local HUNT_STAGGER_MAX = 0.48
local HUNT_ORBIT_SPREAD = 5
local HUNT_HEIGHT_SPREAD = 5

local servicesReady = false
local Voxel3D = nil
local BLACK_TEXTURE = nil

-- Unified Rumble option: Flying Overworld YES / NO
local FLYING_KEY="flying_overworld"
local function flyingEnabled()
  local loader=Game and Game.mods
  local stored=loader and loader.modOptions and loader.modOptions[mod.id]
  local v=stored and stored[FLYING_KEY]

  if v==nil then
    local opts=Game and Game.save and Game.save.options
    stored=opts and opts.modOptions and opts.modOptions[mod.id]
    v=stored and stored[FLYING_KEY]
  end

  if v==nil then return true end
  return v~=false and v~=0 and v~="NO" and v~="OFF"
end
local function setFlying(game,value)
  local opts=game and game.save and game.save.options
  if opts then
    opts.modOptions=opts.modOptions or {}; opts.modOptions[mod.id]=opts.modOptions[mod.id] or {}
    opts.modOptions[mod.id][FLYING_KEY]=value
  end
  local loader=game and game.mods
  if loader then
    loader.modOptions=loader.modOptions or {}; loader.modOptions[mod.id]=loader.modOptions[mod.id] or {}
    loader.modOptions[mod.id][FLYING_KEY]=value
  end
  if game and game.writeOptions then pcall(game.writeOptions,game) end
end
if mod.hooks and type(mod.hooks.wrap)=="function" then
  mod.hooks:wrap("ui.options.rows",function(next,game,rows)
    local out=next(game,rows); if type(out)~="table" then return out end
    out[#out+1]={
      id=mod.id..":settings",
      label="RUMBLE SETTINGS",
      value=function() return "OPEN" end,
      activate=function(g)
        require("src.ui.Screens").push(g,"RumbleUnifiedSettings")
      end,
    }
    return out
  end)
end

if mod.content and mod.content.screens and type(mod.content.screens.register)=="function" then
  mod.content.screens:register("RumbleUnifiedSettings",{
    new=function(game)
      local source=mod:read("features/RumbleSettingsMenu.lua")
      if not source then error("RUMBLE_MAIN: missing RumbleSettingsMenu.lua",0) end
      local chunk,err=load(source,"@"..mod.path.."/features/RumbleSettingsMenu.lua")
      if not chunk then error("RUMBLE_MAIN: Rumble settings menu compile error: "..tostring(err),0) end
      local Menu=chunk(mod)
      return Menu.new(game)
    end,
  })
end

local flock = nil
local lastMap = nil
local transitionPending = false
local hiddenIndoors = false
local huntClock = 2.0

local AERIAL = {
  [12]=true,  -- Butterfree
  [15]=true,  -- Beedrill
  [16]=true, [17]=true, [18]=true, -- Pidgey line
  [21]=true, [22]=true,             -- Spearow line
  [41]=true, [42]=true,             -- Zubat line
  [49]=true,                        -- Venomoth
  [83]=true,                        -- Farfetch'd
}

local function rnd(a,b)
  if love and love.math and love.math.random then return love.math.random(a,b) end
  return math.random(a,b)
end

local function rnd01()
  if love and love.math and love.math.random then return love.math.random() end
  return math.random()
end

local function randf(a,b)
  return a + (b-a) * rnd01()
end

local function findImporter()
  local api = mod.exports and (mod.exports.rumble_main or mod.exports.rumble_importer)
  if api and tonumber(api.api)==1 and type(api.createActor)=="function" then return api end
  if not (mod and type(mod.find)=="function") then return nil end
  local ok,host=pcall(mod.find,"RUMBLE_MAIN")
  if not ok or not host then return nil end
  api=host.exports and (host.exports.rumble_main or host.exports.rumble_importer)
  if not api or tonumber(api.api)~=1 or type(api.createActor)~="function" then return nil end
  return api
end

local function findDramaless()
  local api=mod.exports and mod.exports.voxel_companion
  local importer=mod.exports and (mod.exports.rumble_main or mod.exports.rumble_importer)
  if api and tonumber(api.api)==1 and type(api.register)=="function" then
    if importer and type(importer.Voxel3D)=="function" then
      local okv,v=pcall(importer.Voxel3D)
      if okv and v and type(v.draw)=="function" then Voxel3D=v end
    end
    return api
  end
  if not (mod and type(mod.find)=="function") then return nil end
  local ok,host=pcall(mod.find,"RUMBLE_MAIN")
  if not ok or not host then return nil end
  api=host.exports and host.exports.voxel_companion
  importer=host.exports and (host.exports.rumble_main or host.exports.rumble_importer)
  if not api or tonumber(api.api)~=1 or type(api.register)~="function" then return nil end
  if importer and type(importer.Voxel3D)=="function" then
    local okv,v=pcall(importer.Voxel3D)
    if okv and v and type(v.draw)=="function" then Voxel3D=v end
  end
  return api
end

local function outlineEnabled()
  local api=findImporter()
  if api and type(api.outlineEnabled)=="function" then
    local ok,v=pcall(api.outlineEnabled)
    if ok then return v~=false end
  end
  return true
end

local function blackTexture()
  if BLACK_TEXTURE then return BLACK_TEXTURE end
  if not (love and love.image and love.graphics
      and love.image.newImageData and love.graphics.newImage) then return nil end
  local ok,data=pcall(love.image.newImageData,1,1)
  if not ok or not data then return nil end
  pcall(data.setPixel,data,0,0,0,0,0,1)
  local ok2,img=pcall(love.graphics.newImage,data)
  if ok2 and img then BLACK_TEXTURE=img end
  return BLACK_TEXTURE
end

local function dexOfSpecies(species)
  if type(species)=="number" then
    local n=math.floor(species)
    if n>=1 and n<=151 then return n end
  end
  local data=Game and Game.data
  local pokemon=data and data.pokemon
  if type(pokemon)~="table" or species==nil then return nil end

  local key=tostring(species):upper()
  local def=pokemon[species] or pokemon[key]
  local dex=def and tonumber(def.dex)
  if dex then
    dex=math.floor(dex)
    if dex>=1 and dex<=151 then return dex end
  end

  for k,v in pairs(pokemon) do
    if type(v)=="table" then
      local n=tostring(v.name or v.species or ""):upper()
      if n==key then
        local d=tonumber(v.dex) or tonumber(k)
        if d and d>=1 and d<=151 then return math.floor(d) end
      end
    end
  end
  return nil
end

local function mapEncounterAerial(mapId)
  local e=Game and Game.data and Game.data.encounters
  local enc=type(e)=="table" and e[mapId] or nil
  local grass=enc and enc.grass
  local slots=grass and grass.slots
  if type(slots)~="table" then return nil end

  local choices={}
  for _,slot in ipairs(slots) do
    local dex=slot and dexOfSpecies(slot.species)
    if dex and AERIAL[dex] then
      choices[#choices+1]=dex
    end
  end
  if #choices>0 then return choices[rnd(1,#choices)] end
  return nil
end

local function fallbackDex(mapId)
  local id=tostring(mapId or ""):upper()
  if id:find("VIRIDIAN_FOREST",1,true) or id:find("FOREST",1,true) then
    return (rnd01()<0.55) and 12 or 15
  end
  if id:find("MT_MOON",1,true) or id:find("ROCK_TUNNEL",1,true) then
    return 41
  end

  local route=tonumber(id:match("^ROUTE_(%d+)$"))
  if route then
    if route>=9 and route<=23 then
      return (rnd01()<0.62) and 21 or 16
    end
    return (rnd01()<0.72) and 16 or 21
  end

  -- Towns/cities: mostly Pidgey, occasional Spearow.
  return (rnd01()<0.82) and 16 or 21
end

local function localAerialProfile(mapId)
  local id=tostring(mapId or ""):upper()
  local localDex=mapEncounterAerial(mapId)

  -- Butterfree / Beedrill / Venomoth appear only as local solo/pair roamers.
  if localDex==12 or localDex==15 or localDex==49 then
    return {kind="insect",dex=localDex,count=rnd(1,2),airMin=INSECT_AIR_MIN,airMax=INSECT_AIR_MAX}
  end

  -- Forest fallback when encounter metadata is unavailable.
  if id:find("VIRIDIAN_FOREST",1,true) or id:find("FOREST",1,true) then
    local dex=(rnd01()<0.55) and 12 or 15
    return {kind="insect",dex=dex,count=rnd(1,2),airMin=INSECT_AIR_MIN,airMax=INSECT_AIR_MAX}
  end

  -- Cave bats stay in a local low-altitude swarm: 1-5 Zubat or 1-2 Golbat.
  local cave=id:find("CAVE",1,true) or id:find("TUNNEL",1,true) or
             id:find("MT_MOON",1,true) or id:find("ROCK_TUNNEL",1,true) or
             id:find("SEAFOAM",1,true) or id:find("VICTORY_ROAD",1,true)
  if cave or localDex==41 or localDex==42 then
    if rnd01()<0.72 then
      return {kind="bat",dex=41,count=rnd(1,5),airMin=BAT_AIR_MIN,airMax=BAT_AIR_MAX}
    end
    return {kind="bat",dex=42,count=rnd(1,2),airMin=BAT_AIR_MIN,airMax=BAT_AIR_MAX}
  end

  return nil
end

local PAIR_CHANCE=0.24
local OPTIONAL_PAIRS={
  -- Keep bird families pure: Pidgey-line never shares a flock with Spearow/Fearow.
  {name="fearow_pair",dex={22,22},evolved=true},
  {name="fearow_trio",dex={22,22,22},evolved=true},
  {name="pidgeot_pair",dex={18,18},evolved=true},
  {name="pidgeot_pidgeotto",dex={18,17},evolved=true},
  {name="evolved_trio_pidgeot",dex={18,18,17},evolved=true},
}

local function choosePair()
  if rnd01()>=PAIR_CHANCE then return nil end
  return OPTIONAL_PAIRS[rnd(1,#OPTIONAL_PAIRS)]
end

local function chooseFamily(mapId)
  -- Use the local encounter table to bias the normal flock family where possible.
  local localDex=mapEncounterAerial(mapId)
  if localDex==21 or localDex==22 then return "spearow" end
  if localDex==16 or localDex==17 or localDex==18 then return "pidgey" end

  -- Otherwise mix the two iconic bird families.
  return (rnd01()<0.62) and "pidgey" or "spearow"
end

local function familyDex(family,index)
  if family=="spearow" then
    if index==1 then return 22 end -- Fearow leader
    return 21                    -- Spearow followers
  end
  if index==1 then return 18 end -- Pidgeot leader
  if index==2 then return 17 end -- one Pidgeotto can peel off to hunt
  -- Remaining followers are mostly Pidgey, occasional Pidgeotto.
  return (rnd01()<0.78) and 16 or 17
end

local function playerPos(world)
  local p=world and world.player
  if not p then return nil,nil,nil end
  return tonumber(p.x),tonumber(p.y) or 0,tonumber(p.z)
end

local function yawFromVector(dx,dz)
  if math.abs(dx)+math.abs(dz)<0.001 then return 0 end
  return math.atan2(dx,dz)
end

local function destroyEntry(e)
  if not (e and e.actor) then return end
  local ok=pcall(function() e.actor:destroy() end)
  if not ok then
    local imp=findImporter()
    if imp and type(imp.destroyActor)=="function" then
      pcall(imp.destroyActor,e.actor)
    end
  end
end

local function clearFlock()
  if flock and flock.hunt and flock.hunt.attackers then
    for _,e in ipairs(flock.hunt.attackers) do
      e.detached=nil
      e.huntState=nil
    end
  end
  if flock and flock.members then
    for _,e in ipairs(flock.members) do destroyEntry(e) end
  end
  flock=nil
end

local FORMATIONS = {
  {0,0},
  {-10,8},{10,8},
  {-18,16},{18,16},
  {-26,24},{26,24},
}

-- Evolved-only groups cruise abreast rather than in a trailing V.
-- Spacing is deliberately semi-close: visibly separate silhouettes without
-- looking like unrelated birds.
local EVOLVED_FORMATIONS = {
  [2]={{-9,0},{9,0}},
  [3]={{-14,0},{0,0},{14,0}},
}
local function formationFor(f,i)
  if f and f.evolvedFormation then
    local row=EVOLVED_FORMATIONS[#(f.members or {})] or EVOLVED_FORMATIONS[f.plannedCount or 0]
    if row and row[i] then return row[i] end
  end
  return FORMATIONS[i] or {0,0}
end

local function animatedCurve(c)
  return c and c.values and #c.values>1
end

local function counterpartNames(name)
  local out={}
  local function add(v) if v and v~=name then out[#out+1]=v end end
  add((name:gsub("[Ll][Ee][Ff][Tt]","right",1)))
  add((name:gsub("[Rr][Ii][Gg][Hh][Tt]","left",1)))
  add((name:gsub("_L","_R",1)))
  add((name:gsub("_R","_L",1)))
  add((name:gsub("_l","_r",1)))
  add((name:gsub("_r","_l",1)))
  add((name:gsub("%.L",".R",1)))
  add((name:gsub("%.R",".L",1)))
  add((name:gsub("%.l",".r",1)))
  add((name:gsub("%.r",".l",1)))
  add((name:gsub("^L_","R_",1)))
  add((name:gsub("^R_","L_",1)))
  add((name:gsub("^l_","r_",1)))
  add((name:gsub("^r_","l_",1)))
  add((name:gsub("^Lwing","Rwing",1)))
  add((name:gsub("^Rwing","Lwing",1)))
  add((name:gsub("^lwing","rwing",1)))
  add((name:gsub("^rwing","lwing",1)))
  add((name:gsub("wingL$","wingR",1)))
  add((name:gsub("wingR$","wingL",1)))
  add((name:gsub("wingl$","wingr",1)))
  add((name:gsub("wingr$","wingl",1)))
  return out
end

-- Rumble's generic moving state can contain a one-sided bird wing channel.
-- Give Flying actors their own copy of that clip and mirror any missing or
-- static L/R channel from the animated side. This stays local to Flying and
-- does not modify the importer's cached model used by battles/followers.
local function installSymmetricFlightClip(actor)
  if not (actor and actor.model and actor.rig) then return end
  local model=actor.model
  if tostring(model.family or ""):lower()~="bird" then return end
  local srcAnim=model.anims and model.anims[2]
  local srcClip=srcAnim and srcAnim.clip
  local bones=model.parsed and model.parsed.skeleton and model.parsed.skeleton.bones
  if not (srcClip and type(srcClip.channels)=="table" and type(bones)=="table") then return end

  local m={}
  for k,v in pairs(model) do m[k]=v end
  m.anims={}
  for i,a in ipairs(model.anims or {}) do
    local na={}; for k,v in pairs(a) do na[k]=v end
    m.anims[i]=na
  end
  local clip={}; for k,v in pairs(srcClip) do clip[k]=v end
  clip.channels={}; for k,v in pairs(srcClip.channels) do clip.channels[k]=v end
  m.anims[2].clip=clip

  local names={}
  for _,b in ipairs(bones) do if b.name then names[b.name]=true end end
  local done={}
  for _,b in ipairs(bones) do
    local aName=b.name
    if aName then
      for _,bName in ipairs(counterpartNames(aName)) do
        if names[bName] then
          local key=(aName<bName) and (aName.."|"..bName) or (bName.."|"..aName)
          if not done[key] then
            done[key]=true
            local ca,cb=clip.channels[aName],clip.channels[bName]
            if ca and not cb then
              clip.channels[bName]=ca
            elseif cb and not ca then
              clip.channels[aName]=cb
            elseif ca and cb then
              local ar,br=ca.rotation,cb.rotation
              if animatedCurve(ar) and not animatedCurve(br) then
                local nc={}; for k,v in pairs(cb) do nc[k]=v end; nc.rotation=ar; clip.channels[bName]=nc
              elseif animatedCurve(br) and not animatedCurve(ar) then
                local nc={}; for k,v in pairs(ca) do nc[k]=v end; nc.rotation=br; clip.channels[aName]=nc
              end
            end
          end
          break
        end
      end
    end
  end

  actor.model=m
  actor.rig.model=m
end

local function makeActor(dex,x,y,z)
  local imp=findImporter()
  if not imp then return nil end
  local actor=imp.createActor(dex,{
    manual=true,visible=false,x=x,y=y,z=z,yaw=0
  })
  if not actor then return nil end
  actor:setPosition(x,y,z)
  actor:setYaw(0)
  installSymmetricFlightClip(actor)
  actor:setAnimation("walk")
  actor:setVisible(false)
  return {
    dex=dex, actor=actor,
    x=x,y=y,z=z,
    phase=randf(0,math.pi*2),
    flapPhase=randf(0,math.pi*2),
  }
end

local function outdoorMap()
  local ow=Game and Game.overworld
  local map=ow and ow.map
  if not (map and map.def) then return nil end
  local ok,out=pcall(Map.isOutdoor,map.def)
  if ok and out then return map end
  return nil
end

local function mapWarps(map)
  if not map then return {} end
  local def=map.def or {}
  local t=def.warps or map.warps
  return type(t)=="table" and t or {}
end

local function warpAnchors(map)
  local warps=mapWarps(map)
  local raw={}
  for _,w in ipairs(warps) do
    local x=tonumber(w.x or w[1])
    local z=tonumber(w.y or w.z or w[2])
    if x and z then
      raw[#raw+1]={x=x*CELL+8,z=z*CELL+8}
    end
  end

  -- A single building can have two adjacent warp tiles. Collapse nearby warp
  -- cells into one rooftop/building anchor so they are not treated as separate
  -- buildings.
  local clustered={}
  local mergeDist=CELL*3.0
  for _,a in ipairs(raw) do
    local merged=false
    for _,c in ipairs(clustered) do
      local dx,dz=a.x-c.x,a.z-c.z
      if dx*dx+dz*dz <= mergeDist*mergeDist then
        c.x=(c.x*c.n+a.x)/(c.n+1)
        c.z=(c.z*c.n+a.z)/(c.n+1)
        c.n=c.n+1
        merged=true
        break
      end
    end
    if not merged then
      clustered[#clustered+1]={x=a.x,z=a.z,n=1}
    end
  end
  return clustered
end

local function choosePerchAnchors(map,count)
  local anchors=warpAnchors(map)
  if #anchors==0 then return nil end

  -- Pick one building first, then ONLY use other buildings near it.
  -- This prevents one flock member from being sent to a building on the
  -- opposite side of the map.
  local primaryIndex=rnd(1,#anchors)
  local primary=anchors[primaryIndex]

  local nearby={primary}
  local MAX_BUILDING_SPREAD=CELL*8

  for i,a in ipairs(anchors) do
    if i~=primaryIndex then
      local dx,dz=a.x-primary.x,a.z-primary.z
      local d=math.sqrt(dx*dx+dz*dz)
      if d<=MAX_BUILDING_SPREAD then
        nearby[#nearby+1]=a
      end
    end
  end

  -- Sort the selected cluster by distance to the primary building so the
  -- nearest roofs are preferred first.
  table.sort(nearby,function(a,b)
    local dax,daz=a.x-primary.x,a.z-primary.z
    local dbx,dbz=b.x-primary.x,b.z-primary.z
    return dax*dax+daz*daz < dbx*dbx+dbz*dbz
  end)

  -- Use up to 3 nearby buildings. If only one/two are nearby, distribute the
  -- entire 3-7 member flock across those roofs instead of reaching farther.
  local wanted=math.min(#nearby,3)
  local out={}
  for i=1,wanted do out[#out+1]=nearby[i] end
  return out
end

local function newCrossing(world)
  local px,py,pz=playerPos(world)
  if not px then return nil,nil end

  -- Pick one of four map-crossing directions. Start well offscreen on one
  -- side and finish well offscreen on the opposite side.
  local span=CELL*18
  local lateral=randf(-CELL*5,CELL*5)
  local altitude=py+randf(AIR_MIN,AIR_MAX)
  local side=rnd(1,4)

  if side==1 then
    return {x=px-span,y=altitude,z=pz+lateral},
           {x=px+span,y=altitude+randf(-5,5),z=pz+lateral+randf(-CELL*3,CELL*3)}
  elseif side==2 then
    return {x=px+span,y=altitude,z=pz+lateral},
           {x=px-span,y=altitude+randf(-5,5),z=pz+lateral+randf(-CELL*3,CELL*3)}
  elseif side==3 then
    return {x=px+lateral,y=altitude,z=pz-span},
           {x=px+lateral+randf(-CELL*3,CELL*3),y=altitude+randf(-5,5),z=pz+span}
  else
    return {x=px+lateral,y=altitude,z=pz+span},
           {x=px+lateral+randf(-CELL*3,CELL*3),y=altitude+randf(-5,5),z=pz-span}
  end
end

local function enterFlight(world)
  if not flock then return end
  local start,target=newCrossing(world)
  if not start then return end
  flock.mode="fly"
  flock.perchTimer=0
  flock.perchTried=false
  flock.center={x=start.x,y=start.y,z=start.z}
  flock.target=target
  flock.waypointTimer=999999
  local dx,dz=target.x-start.x,target.z-start.z
  flock.heading=yawFromVector(dx,dz)
end

local function tryPerch(world,map)
  if not flock or not map then return false end

  local anchors=choosePerchAnchors(map,#(flock.members or {}))
  if not anchors or #anchors==0 then return false end

  local _,py,_=playerPos(world)
  local perchY=(py or 0)+roofOffsetForMap(map)

  flock.mode="perch_approach"
  flock.perchTimer=randf(PERCH_MIN,PERCH_MAX)*randf(PERCH_TIME_MULT_MIN,PERCH_TIME_MULT_MAX)
  flock.perchAnchors={}
  flock.perchStarted=false
  flock.takeoffClock=0
  flock.regroupPoint=nil

  -- Leader takes the first building. Followers are distributed round-robin
  -- across the other available rooftops.
  for i,e in ipairs(flock.members or {}) do
    local ai=((i-1)%#anchors)+1
    local a=anchors[ai]
    local localIndex=math.floor((i-1)/#anchors)
    local side=(localIndex==0) and 0 or (((localIndex%2)==1) and -1 or 1)
    local spread=side*(8+math.ceil(localIndex/2)*7)

    local assigned={
      x=a.x+spread,
      y=perchY + (e.isLeader and 4 or 1.5),
      z=a.z + localIndex*4
    }
    flock.perchAnchors[i]=assigned
    e.perchYaw=(flock.heading or 0) + randf(-PERCH_TURN_ARC,PERCH_TURN_ARC)
    e.perchTargetYaw=e.perchYaw
    e.perchTurnTimer=randf(PERCH_TURN_MIN,PERCH_TURN_MAX)
    e.actor:setAnimation("walk")
  end
  return true
end

local function spawnFlock(world,map)
  if flock then return true end
  local px,py,pz=playerPos(world)
  if not px then return false end

  local mapId=tostring(map.id or "")
  local localProfile=localAerialProfile(mapId)
  if localProfile then
    local heading=randf(0,math.pi*2)
    local spawnRadius=randf(CELL*4,CELL*7)
    local cx=px+math.sin(heading)*spawnRadius
    local cz=pz+math.cos(heading)*spawnRadius
    local cy=py+randf(localProfile.airMin,localProfile.airMax)
    local f={
      family=localProfile.kind,
      dex=localProfile.dex,
      localRoam=true,
      plannedCount=localProfile.count,
      members={},
      center={x=cx,y=cy,z=cz},
      home={x=cx,y=cy,z=cz},
      mode="local_roam",
      age=0,
      finished=false,
      heading=heading,
    }

    for i=1,localProfile.count do
      local angle=randf(0,math.pi*2)
      local radius=randf(LOCAL_ROAM_RADIUS_MIN,LOCAL_ROAM_RADIUS_MAX)
      local ex=cx+math.cos(angle)*radius
      local ez=cz+math.sin(angle)*radius
      local ey=cy+randf(-2.5,2.5)
      local e=makeActor(localProfile.dex,ex,ey,ez)
      if e then
        e.roamAngle=angle
        e.roamRadius=radius
        e.roamSpeed=randf(LOCAL_ROAM_SPEED_MIN,LOCAL_ROAM_SPEED_MAX)*(rnd01()<0.5 and -1 or 1)
        e.roamHeight=randf(-2.5,2.5)
        f.members[#f.members+1]=e
      end
    end

    if #f.members<1 then return false end
    flock=f
    return true
  end

  local pair=choosePair()
  local family=pair and pair.name or chooseFamily(mapId)
  local count=pair and #pair.dex or rnd(MIN_FLOCK,MAX_FLOCK)
  local start,target=newCrossing(world)
  if not start then return false end

  local f={
    family=family,
    dex=pair and pair.dex[1] or familyDex(family,1),
    optionalPair=pair and pair.name or nil,
    evolvedFormation=pair and pair.evolved==true or false,
    plannedCount=count,
    members={},
    center={x=start.x,y=start.y,z=start.z},
    target=target,
    mode="fly",
    waypointTimer=999999,
    perchTimer=0,
    heading=yawFromVector(target.x-start.x,target.z-start.z),
    age=0,
    finished=false,
    perchTried=false,
  }

  for i=1,count do
    local dex=pair and pair.dex[i] or familyDex(family,i)
    local o=formationFor(f,i)
    -- Evolved 2-3 bird groups fly abreast; normal flocks retain the V.
    local y=start.y + ((i==1) and 5 or 0)
    local e=makeActor(dex,start.x+o[1],y,start.z+o[2])
    if e then
      e.isLeader=(i==1)
      f.members[#f.members+1]=e
    end
  end

  local required=pair and #pair.dex or MIN_FLOCK
  if #f.members<required then
    for _,e in ipairs(f.members) do destroyEntry(e) end
    return false
  end

  flock=f
  return true
end

local function rotateOffset(side,back,heading)
  -- Local formation: side is perpendicular to heading, back trails leader.
  local fx=math.sin(heading)
  local fz=math.cos(heading)
  local rx=fz
  local rz=-fx
  return rx*side-fx*back, rz*side-fz*back
end

local function continueAcrossNewMap(world)
  if not flock then return false end
  local px,py,pz=playerPos(world)
  if not px then return false end

  -- Preserve flock composition and heading, but relocate it just behind the
  -- player on the new outdoor map so the SAME flock continues naturally.
  local heading=flock.heading or 0
  local fx=math.sin(heading)
  local fz=math.cos(heading)
  local span=CELL*16

  -- Put the flock a little way behind the player along its existing heading,
  -- then let it cross the new map in the same direction.
  flock.center={
    x=px-fx*CELL*7,
    y=py+randf(AIR_MIN,AIR_MAX),
    z=pz-fz*CELL*7,
  }
  flock.target={
    x=px+fx*span,
    y=flock.center.y+randf(-4,4),
    z=pz+fz*span,
  }
  flock.mode="fly"
  flock.finished=false
  flock.waypointTimer=999999
  flock.perchTimer=0

  for i,e in ipairs(flock.members or {}) do
    local o=formationFor(flock,i)
    local ox,oz=rotateOffset(o[1],o[2],heading)
    local leaderLift=e.isLeader and 5 or 0
    e.x=flock.center.x+ox
    e.y=flock.center.y+leaderLift
    e.z=flock.center.z+oz
    e.actor:setPosition(e.x,e.y,e.z)
    e.actor:setYaw(heading)
    e.actor:setAnimation("walk")
    e.actor:setVisible(false)
  end
  return true
end


local function wildAPI()
  local api=mod.exports and mod.exports.rumble_overworld_wilds
  if api and tonumber(api.api or 0)>=2 then return api end
  return nil
end

local function shuffledFollowers()
  local out={}
  if not (flock and flock.members) then return out end
  for _,e in ipairs(flock.members) do
    if not e.isLeader then out[#out+1]=e end
  end
  for i=#out,2,-1 do
    local j=rnd(1,i)
    out[i],out[j]=out[j],out[i]
  end
  return out
end

local function chooseAttackers()
  if not (flock and flock.members and #flock.members>0) then return nil end
  local members=flock.members

  -- Special two-bird pairs always participate together.
  if flock.optionalPair and #members==2 then
    return {members[1],members[2]},true
  end
  local leader=members[1]
  for _,e in ipairs(members) do
    if e.isLeader then leader=e break end
  end

  local followers=shuffledFollowers()
  local attackers={}

  -- Rare leader-led hunt. Pidgeot initiates, then 1-3 flockmates may follow.
  -- Total hunting party is capped at four so the sky still retains a flock.
  local leaderFirst=(leader and #followers>0 and rnd01()<0.14)
  if leaderFirst then
    attackers[#attackers+1]=leader
    local maxTotal=math.min(HUNT_MAX_ATTACKERS,#members)
    local total=rnd(2,maxTotal)
    for _,e in ipairs(followers) do
      if #attackers>=total then break end
      attackers[#attackers+1]=e
    end
    return attackers,true
  end

  -- Normal hunt: only 1-3 non-leader birds detach. Bias toward 1-2.
  local maxNormal=math.min(HUNT_NORMAL_MAX_ATTACKERS,#followers)
  if maxNormal<=0 then return nil,false end
  local roll=rnd01()
  local count=1
  if maxNormal>=2 and roll>=0.45 then count=2 end
  if maxNormal>=3 and roll>=0.82 then count=3 end

  for i=1,count do attackers[#attackers+1]=followers[i] end

  -- Pidgeot normally stays with the flock. On an occasional coordinated hunt,
  -- it can replace the last selected follower and attacks LAST.
  if leader and count>=2 and rnd01()<0.18 then
    attackers[#attackers]=leader
  end

  return attackers,false
end

local function beginHunt(world)
  if not (flock and flock.mode=="fly" and not flock.hunt) then return false end
  local api=wildAPI()
  if not api or type(api.nearestDex)~="function" then return false end

  -- Pick the nearest Caterpie, Weedle, or Rattata to the flock center.
  local c=flock.center
  if not c then return false end
  local caterpie,caterpieDist=api.nearestDex(10,c.x,c.z,HUNT_RADIUS)
  local weedle,weedleDist=api.nearestDex(13,c.x,c.z,HUNT_RADIUS)
  local rattata,rattataDist=api.nearestDex(19,c.x,c.z,HUNT_RADIUS)

  local prey=nil
  local preyDist=math.huge
  if caterpie and (caterpieDist or math.huge)<preyDist then
    prey=caterpie;preyDist=caterpieDist or math.huge
  end
  if weedle and (weedleDist or math.huge)<preyDist then
    prey=weedle;preyDist=weedleDist or math.huge
  end
  if rattata and (rattataDist or math.huge)<preyDist then
    prey=rattata;preyDist=rattataDist or math.huge
  end
  if not prey then return false end

  local attackers,leaderFirst=chooseAttackers()
  if not attackers or #attackers==0 then return false end

  -- Pidgey (#016) cannot carry any prey, so it is also excluded from Rattata
  -- pursuit selection. Pidgeotto/Pidgeot/Fearow can continue the hunt.
  if tonumber(prey.dex)==19 then
    local filtered={}
    for _,bird in ipairs(attackers) do
      if tonumber(bird.dex)~=16 then filtered[#filtered+1]=bird end
    end
    attackers=filtered
    if #attackers==0 then return false end
  end

  local pairPattern=nil
  if flock.optionalPair and #attackers==2 then
    local roll=rnd(1,3)
    pairPattern=(roll==1 and "dual_dive") or
                (roll==2 and "dive_and_circle") or
                "circle_then_alternate"
  end

  local hunt={
    prey=prey,
    attackers=attackers,
    leaderFirst=leaderFirst,
    mode="circle",
    pursuit=HUNT_PURSUIT_TIME,
    activeIndex=1,
    battlePause=false,
    completed=0,
    pairPattern=pairPattern,
    pairClock=0,
    carrier=nil,
  }

  for i,e in ipairs(attackers) do
    local dx=e.x-prey.current.x
    local dz=e.z-prey.current.z
    e.detached=true
    e.huntState={
      mode="circle",
      angle=math.atan2(dz,dx)+(i-1)*(math.pi*2/math.max(1,#attackers)),
      swept=0,
      loops=rnd(HUNT_CIRCLE_LOOPS_MIN,HUNT_CIRCLE_LOOPS_MAX),
      orbitRadius=HUNT_ORBIT_RADIUS+(i-1)*HUNT_ORBIT_SPREAD,
      orbitHeight=HUNT_ORBIT_HEIGHT+((i-1)%3)*HUNT_HEIGHT_SPREAD,
      delay=(i-1)*randf(HUNT_STAGGER_MIN,HUNT_STAGGER_MAX),
      pursuit=HUNT_PURSUIT_TIME,
      finished=false,
    }
    e.actor:setAnimation("walk")
  end

  if pairPattern=="dual_dive" then
    -- Both circle briefly, then commit together.
    for _,e in ipairs(attackers) do
      e.huntState.loops=1
      e.huntState.pairDual=true
    end
  elseif pairPattern=="dive_and_circle" then
    -- Bird 1 dives immediately while bird 2 keeps orbiting the path/prey.
    attackers[1].huntState.mode="swoop"
    attackers[1].huntState.delay=0
    attackers[2].huntState.mode="pair_guard_circle"
    attackers[2].huntState.delay=0
    attackers[2].huntState.guardTime=HUNT_PURSUIT_TIME+1.8
  elseif pairPattern=="circle_then_alternate" then
    -- Both make a visible orbit first, then take turns diving.
    for _,e in ipairs(attackers) do e.huntState.loops=1 end
  end

  flock.hunt=hunt
  return true
end


local function playerTouchesHunter(world,hunter)
  local px,py,pz=playerPos(world)
  if not px then return false end
  local dx,dy,dz=px-hunter.x,py-(hunter.y or 0),pz-hunter.z
  -- Horizontal overlap alone is not contact: an airborne hunter must also be
  -- close to the player's height before it can trigger an encounter.
  return dx*dx+dz*dz <= HUNT_TOUCH_RADIUS*HUNT_TOUCH_RADIUS
     and math.abs(dy) <= HUNT_TOUCH_VERTICAL
end

local function removeHunterFromFlock(target)
  if not (flock and target) then return end
  if flock.members then
    for i=#flock.members,1,-1 do
      if flock.members[i]==target then
        table.remove(flock.members,i)
        break
      end
    end
  end
  if flock.hunt and flock.hunt.attackers then
    for i=#flock.hunt.attackers,1,-1 do
      if flock.hunt.attackers[i]==target then
        table.remove(flock.hunt.attackers,i)
        break
      end
    end
  end
  target.detached=nil
  target.huntState=nil
  if target.actor then target.actor:setVisible(false) end
end

local function releaseHunter(e)
  if not e then return end
  e.detached=nil
  e.huntState=nil
end

local function forceHuntersExit()
  local h=flock and flock.hunt
  if not h then return end
  for _,e in ipairs(h.attackers or {}) do
    if e.huntState then e.huntState.mode="exit" end
  end
  h.mode="exit"
end

local function cleanupCarriedPrey(h,api,drop)
  if not h or not h.carrier then return false end
  local prey=h.prey
  local carrier=h.carrier
  if prey then
    if drop and type(api.dropAndFlee)=="function" then
      pcall(api.dropAndFlee,prey,(carrier.actorYaw or 0)+math.pi)
    elseif type(api.consumeWild)=="function" then
      pcall(api.consumeWild,prey)
    end
  end
  if carrier.huntState then carrier.huntState.carryTime=nil end
  h.prey=nil
  h.carrier=nil
  return true
end

local function updateOneHunter(world,e,h,dt,index)
  local s=e.huntState
  local api=wildAPI()
  local prey=h.prey
  if not s then return true end

  if h.battlePause then
    e.actor:setPosition(e.x,e.y,e.z)
    e.actor:setVisible(false)
    e.actor:update(dt)
    return false
  end

  -- Edge-trigger the contact. A hunter may only open one battle until the
  -- player has physically separated from it again.
  local touching=playerTouchesHunter(world,e)
  if not touching then s.contactLatched=false end

  if touching and not s.contactLatched and type(api.startDexEncounter)=="function" then
    s.contactLatched=true

    -- If the player touches the bird that is carrying prey, resolve the prey
    -- BEFORE pausing ecology for battle. Otherwise the prey actor stays frozen
    -- at its last airborne position for the whole encounter.
    if h.carrier==e then
      cleanupCarriedPrey(h,api,true)
      prey=nil
    end

    h.battlePause=true
    local battledBird=e
    local started=api.startDexEncounter(e.dex,math.max(5,tonumber(prey and prey.level) or 5),function(result)
      if flock and flock.hunt==h then
        h.battlePause=false

        -- Never leave the battled hunter sitting on top of the player after
        -- returning to the overworld. It exits this active hunting party
        -- immediately, which also prevents a KO/catch from reopening battle.
        if battledBird and battledBird.huntState then
          battledBird.huntState.mode="exit"
          battledBird.huntState.exitTime=0
          battledBird.huntState.contactLatched=true
        end

        if prey and type(api.beginFlee)=="function"
           and type(api.isAlive)=="function" and api.isAlive(prey) then
          api.beginFlee(prey,battledBird.x,battledBird.z,3.0)
        end

        -- All other hunters abort the attack and return to formation.
        for _,bird in ipairs(h.attackers) do
          if bird~=battledBird and bird.huntState then
            bird.huntState.mode="rejoin"
          end
        end
      end
    end)
    if started then return false end
    h.battlePause=false
    s.contactLatched=false
  end

  if s.delay and s.delay>0 then
    s.delay=s.delay-dt
  elseif s.mode=="circle" then
    if not (prey and type(api.isAlive)=="function" and api.isAlive(prey)) then
      s.mode="rejoin"
    else
      local prev=s.angle
      s.angle=s.angle+HUNT_ORBIT_SPEED*dt
      s.swept=s.swept+math.abs(s.angle-prev)
      local tx=prey.current.x+math.cos(s.angle)*s.orbitRadius
      local tz=prey.current.z+math.sin(s.angle)*s.orbitRadius
      local ty=prey.current.y+s.orbitHeight
      local dx,dy,dz=tx-e.x,ty-e.y,tz-e.z
      local dist=math.sqrt(dx*dx+dy*dy+dz*dz)
      if dist>0.01 then
        local step=math.min(dist,HUNT_PURSUIT_SPEED*dt)
        e.x=e.x+dx/dist*step; e.y=e.y+dy/dist*step; e.z=e.z+dz/dist*step
      end
      e.actor:setYaw(yawFromVector(dx,dz))
      if s.swept>=math.pi*2*s.loops then s.mode="wait_swoop" end
    end

  elseif s.mode=="wait_swoop" then
    if h.pairPattern=="dual_dive" then
      -- Pair commits at the same time after both have finished circling.
      local ready=true
      for _,bird in ipairs(h.attackers) do
        if bird.huntState and bird.huntState.mode=="circle" then ready=false break end
      end
      if ready then
        for _,bird in ipairs(h.attackers) do
          if bird.huntState and bird.huntState.mode=="wait_swoop" then
            bird.huntState.mode="swoop"
          end
        end
      end
    else
      -- Normal/alternating attacks: current attacker commits to the dive.
      if index==h.activeIndex then s.mode="swoop" end
    end

  elseif s.mode=="pair_guard_circle" then
    -- One member continuously encircles the path/prey while its partner dives.
    if not (prey and type(api.isAlive)=="function" and api.isAlive(prey)) then
      s.mode="rejoin"
    else
      s.angle=s.angle+HUNT_ORBIT_SPEED*0.72*dt
      s.guardTime=(s.guardTime or 0)-dt
      local tx=prey.current.x+math.cos(s.angle)*(HUNT_ORBIT_RADIUS+HUNT_ORBIT_SPREAD)
      local tz=prey.current.z+math.sin(s.angle)*(HUNT_ORBIT_RADIUS+HUNT_ORBIT_SPREAD)
      local ty=prey.current.y+HUNT_ORBIT_HEIGHT+HUNT_HEIGHT_SPREAD
      local dx,dy,dz=tx-e.x,ty-e.y,tz-e.z
      local dist=math.sqrt(dx*dx+dy*dy+dz*dz)
      if dist>0.01 then
        local step=math.min(dist,HUNT_PURSUIT_SPEED*dt)
        e.x=e.x+dx/dist*step; e.y=e.y+dy/dist*step; e.z=e.z+dz/dist*step
      end
      e.actor:setYaw(yawFromVector(dx,dz))
      local partner=h.attackers[1]
      local ps=partner and partner.huntState
      if s.guardTime<=0 or not ps or ps.mode=="rejoin" or ps.mode=="exit" then s.mode="rejoin" end
    end

  elseif s.mode=="swoop" then
    if not (prey and type(api.isAlive)=="function" and api.isAlive(prey)) then
      s.mode="rejoin"
    else
      local tx,tz=prey.current.x,prey.current.z
      local ty=prey.current.y+4
      local dx,dy,dz=tx-e.x,ty-e.y,tz-e.z
      local dist=math.sqrt(dx*dx+dy*dy+dz*dz)
      if dist>0.01 then
        local step=math.min(dist,HUNT_SWOOP_SPEED*dt)
        e.x=e.x+dx/dist*step; e.y=e.y+dy/dist*step; e.z=e.z+dz/dist*step
      end
      e.actor:setYaw(yawFromVector(dx,dz))
      if math.sqrt(dx*dx+dz*dz)<=CELL*1.25 then
        if type(api.beginFlee)=="function" then
          api.beginFlee(prey,e.x,e.z,HUNT_PURSUIT_TIME+1.0)
        end
        s.mode="pursuit"
        s.pursuit=HUNT_PURSUIT_TIME
      end
    end

  elseif s.mode=="pursuit" then
    if not (prey and type(api.isAlive)=="function" and api.isAlive(prey)) then
      s.mode="rejoin"
    else
      if type(api.updateThreat)=="function" then api.updateThreat(prey,e.x,e.z) end
      s.pursuit=s.pursuit-dt
      local tx,tz=prey.current.x,prey.current.z
      local ty=prey.current.y+8
      local dx,dy,dz=tx-e.x,ty-e.y,tz-e.z
      local dist=math.sqrt(dx*dx+dy*dy+dz*dz)
      if dist>0.01 then
        local step=math.min(dist,HUNT_PURSUIT_SPEED*dt)
        e.x=e.x+dx/dist*step; e.y=e.y+dy/dist*step; e.z=e.z+dz/dist*step
      end
      e.actor:setYaw(yawFromVector(dx,dz))
      -- Each attacker makes a short pass. Pair choreography decides whether
      -- the pass is simultaneous or sequential.
      if s.pursuit<=HUNT_PURSUIT_TIME-HUNT_PICKUP_AFTER then
        -- The first attacker to finish a clean pursuit becomes the carrier.
        -- We move the prey's existing Rumble actor; no duplicate model is made.
        -- Pidgey (#016) and Spearow (#021) may swoop/chase prey, but neither
        -- species can carry any prey. Evolved birds retain normal carry behavior.
        if tonumber(e.dex)~=16 and tonumber(e.dex)~=21 and not h.carrier and type(api.setCarried)=="function"
           and prey and type(api.isAlive)=="function" and api.isAlive(prey) then
          h.carrier=e
          s.mode="carry"
          s.carryTime=HUNT_CARRY_TIME
          s.carryHeading=(flock and flock.heading) or e.actorYaw or 0
          api.setCarried(prey,e.x,e.y-carryDropFor(prey),e.z,s.carryHeading)

          -- Once prey is caught, every other hunter gives up the chase and
          -- reforms around the flock while this bird visibly carries the prey.
          for _,bird in ipairs(h.attackers or {}) do
            if bird~=e and bird.huntState then bird.huntState.mode="rejoin" end
          end
        else
          s.mode="rejoin"
          if h.pairPattern~="dual_dive" and h.pairPattern~="dive_and_circle" then
            h.activeIndex=math.min(#h.attackers,h.activeIndex+1)
          end
        end
      end
    end

  elseif s.mode=="carry" then
    -- Carry the captured prey below the bird while climbing and flying along
    -- the flock's route. The prey remains a live rendered Rumble actor.
    s.carryTime=(s.carryTime or HUNT_CARRY_TIME)-dt
    local heading=(flock and flock.heading) or s.carryHeading or 0
    local speed=HUNT_REJOIN_SPEED*0.82
    e.x=e.x+math.sin(heading)*speed*dt
    e.z=e.z+math.cos(heading)*speed*dt
    local desiredY=((flock and flock.center and flock.center.y) or e.y)+HUNT_CARRY_CLIMB
    if e.y<desiredY then e.y=math.min(desiredY,e.y+22*dt) end
    e.actor:setYaw(heading)

    if prey and type(api.isAlive)=="function" and api.isAlive(prey)
       and type(api.setCarried)=="function" then
      api.setCarried(prey,e.x,e.y-carryDropFor(prey),e.z,heading)
    end

    if s.carryTime<=0 then
      if prey and type(api.consumeWild)=="function" then api.consumeWild(prey) end
      h.prey=nil
      h.carrier=nil
      s.mode="rejoin"
    end

  elseif s.mode=="rejoin" then
    local c=flock.center
    if not c then s.mode="exit" else
      local dx,dy,dz=c.x-e.x,(c.y+2)-e.y,c.z-e.z
      local dist=math.sqrt(dx*dx+dy*dy+dz*dz)
      if dist<=8 then
        releaseHunter(e)
        return true
      end
      local step=math.min(dist,HUNT_REJOIN_SPEED*dt)
      e.x=e.x+dx/dist*step; e.y=e.y+dy/dist*step; e.z=e.z+dz/dist*step
      e.actor:setYaw(yawFromVector(dx,dz))
    end

  elseif s.mode=="exit" then
    -- If the flock has gone excessively far off-map, do not pop the hunter.
    -- It climbs and flies outward first; once well clear it may be released.
    local heading=(flock and flock.heading) or 0
    e.x=e.x+math.sin(heading)*HUNT_REJOIN_SPEED*dt
    e.z=e.z+math.cos(heading)*HUNT_REJOIN_SPEED*dt
    e.y=e.y+30*dt
    e.actor:setYaw(heading)
    s.exitTime=(s.exitTime or 0)+dt
    if s.exitTime>=1.5 then
      removeHunterFromFlock(e)
      return true
    end
  end

  e.actor:setPosition(e.x,e.y,e.z)
  e.actor:setVisible(false)
  e.actor:update(dt)
  return false
end

local function updateHunt(world,dt)
  local h=flock and flock.hunt
  if not h then return false end
  local api=wildAPI()
  if not api then
    for _,e in ipairs(h.attackers or {}) do releaseHunter(e) end
    flock.hunt=nil
    return false
  end

  if h.prey and type(api.isAlive)=="function" and not api.isAlive(h.prey) and not h.carrier then
    for _,e in ipairs(h.attackers or {}) do
      if e.huntState then e.huntState.mode="rejoin" end
    end
  end

  local done=0
  for i,e in ipairs(h.attackers or {}) do
    if not e.huntState or updateOneHunter(world,e,h,dt,i) then done=done+1 end
  end

  if done>=#(h.attackers or {}) then
    flock.hunt=nil
    huntClock=randf(HUNT_SCAN_MIN,HUNT_SCAN_MAX)
    return false
  end
  return true
end


local function updateFlight(world,map,dt)
  if not flock then return end
  flock.age=flock.age+dt

  -- Insects and cave bats remain close to their spawn point and never use
  -- bird crossing, hunting, carrying, or rooftop-perching behavior.
  if flock.localRoam and flock.mode=="local_roam" then
    local home=flock.home or flock.center
    if not home then return end
    for i,e in ipairs(flock.members or {}) do
      e.roamAngle=(e.roamAngle or 0)+(e.roamSpeed or 0.5)*dt
      local radius=e.roamRadius or 16
      local tx=home.x+math.cos(e.roamAngle)*radius
      local tz=home.z+math.sin(e.roamAngle)*radius
      local ty=home.y+(e.roamHeight or 0)+math.sin(flock.age*2.2+(e.phase or i))*1.8
      local dx,dz=tx-e.x,tz-e.z
      e.x=e.x+(tx-e.x)*math.min(1,dt*2.8)
      e.y=e.y+(ty-e.y)*math.min(1,dt*2.8)
      e.z=e.z+(tz-e.z)*math.min(1,dt*2.8)
      if math.abs(dx)+math.abs(dz)>0.05 then e.actor:setYaw(yawFromVector(dx,dz)) end
      e.actor:setPosition(e.x,e.y,e.z)
      e.actor:setVisible(false)
      e.actor:update(dt)
    end
    return
  end

  if flock.mode=="fly" then
    huntClock=huntClock-dt
    if not flock.hunt and huntClock<=0 then
      beginHunt(world)
      huntClock=randf(HUNT_SCAN_MIN,HUNT_SCAN_MAX)
    end
  end
  if flock.hunt then updateHunt(world,dt) end

  -- APPROACH: each bird flies to its assigned building/roof position.
  if flock.mode=="perch_approach" then
    local allClose=true

    for i,e in ipairs(flock.members) do
      local a=flock.perchAnchors and flock.perchAnchors[i]
      if a then
        local dx,dy,dz=a.x-e.x,a.y-e.y,a.z-e.z
        local dist=math.sqrt(dx*dx+dy*dy+dz*dz)
        if dist>2.5 then
          allClose=false
          local step=math.min(dist,FLIGHT_SPEED*dt)
          if dist>0.001 then
            e.x=e.x+dx/dist*step
            e.y=e.y+dy/dist*step
            e.z=e.z+dz/dist*step
          end
          if math.sqrt(dx*dx+dz*dz)>0.5 then
            e.actor:setYaw(yawFromVector(dx,dz))
          end
        end

        e.actor:setPosition(e.x,e.y,e.z)
        e.actor:setVisible(false)
        e.actor:update(dt)
      end
    end

    if allClose then
      flock.mode="perched"
      for _,e in ipairs(flock.members) do e.actor:setAnimation("idle") end
    end
    return
  end

  -- PERCHED: keep each Pokemon on its own assigned building.
  if flock.mode=="perched" then
    flock.perchTimer=flock.perchTimer-dt

    for i,e in ipairs(flock.members) do
      local a=flock.perchAnchors and flock.perchAnchors[i]
      if a then
        local ty=a.y + math.sin(flock.age*1.8+e.phase)*0.06
        e.x=e.x+(a.x-e.x)*math.min(1,dt*7.0)
        e.y=e.y+(ty-e.y)*math.min(1,dt*7.0)
        e.z=e.z+(a.z-e.z)*math.min(1,dt*7.0)
        e.actor:setPosition(e.x,e.y,e.z)

        -- Each perched bird has its own relaxed facing. At irregular intervals
        -- it looks somewhere else instead of every member rotating in sync.
        e.perchTurnTimer=(e.perchTurnTimer or 0)-dt
        if e.perchTurnTimer<=0 then
          local base=flock.heading or 0
          e.perchTargetYaw=base+randf(-PERCH_TURN_ARC,PERCH_TURN_ARC)
          e.perchTurnTimer=randf(PERCH_TURN_MIN,PERCH_TURN_MAX)
        end

        local current=e.perchYaw or e.perchTargetYaw or 0
        local target=e.perchTargetYaw or current
        local delta=(target-current+math.pi)%(math.pi*2)-math.pi
        current=current+delta*math.min(1,dt*2.4)
        e.perchYaw=current
        e.actor:setYaw(current)

        e.actor:setVisible(false)
        e.actor:update(dt)
      end
    end

    if flock.perchTimer<=0 then
      flock.mode="takeoff"
      flock.takeoffClock=0

      -- Rendezvous is ahead of the flock's existing travel direction and well
      -- above the rooftops. Everybody will physically fly here; no snapping.
      local heading=flock.heading or 0
      local fx,fz=math.sin(heading),math.cos(heading)
      local sx,sy,sz=0,0,0
      for _,e in ipairs(flock.members) do
        sx=sx+e.x; sy=sy+e.y; sz=sz+e.z
        e.launched=false
        e.actor:setAnimation("walk")
      end
      local n=math.max(1,#flock.members)
      flock.regroupPoint={
        x=sx/n + fx*CELL*7,
        y=sy/n + 26,
        z=sz/n + fz*CELL*7
      }
    end
    return
  end

  -- LEADER-FIRST TAKEOFF:
  -- Pidgeot/Fearow flies all the way to the rendezvous point first.
  -- Every follower stays perched until the leader has actually arrived.
  if flock.mode=="takeoff" then
    flock.takeoffClock=flock.takeoffClock+dt
    local r=flock.regroupPoint
    local leader=flock.members and flock.members[1]
    if not (r and leader) then
      flock.mode="fly"
      return
    end

    -- Move only the leader.
    local dx,dy,dz=r.x-leader.x,r.y-leader.y,r.z-leader.z
    local dist=math.sqrt(dx*dx+dy*dy+dz*dz)

    if dist>REGROUP_RADIUS then
      local step=math.min(dist,REGROUP_SPEED*dt)
      if dist>0.001 then
        leader.x=leader.x+dx/dist*step
        leader.y=leader.y+dy/dist*step
        leader.z=leader.z+dz/dist*step
      end
      if math.sqrt(dx*dx+dz*dz)>0.5 then
        leader.actor:setYaw(yawFromVector(dx,dz))
      end
    else
      -- Leader reached rendezvous. Now release the followers.
      flock.mode="followers_takeoff"
      flock.takeoffClock=0
      leader.atRendezvous=true

      -- As soon as the leader reaches rendezvous, turn back toward the roofs
      -- so it appears to watch the rest of the flock come in.
      local sx,sz=0,0
      local count=0
      for i=2,#flock.members do
        local f=flock.members[i]
        sx=sx+f.x
        sz=sz+f.z
        count=count+1
      end
      if count>0 then
        leader.watchYaw=yawFromVector(sx/count-leader.x,sz/count-leader.z)
      else
        leader.watchYaw=(flock.heading or 0)+math.pi
      end
    end

    leader.actor:setPosition(leader.x,leader.y,leader.z)
    leader.actor:setVisible(false)
    leader.actor:update(dt)

    -- Followers remain exactly on their rooftops.
    for i=2,#flock.members do
      local e=flock.members[i]
      e.actor:setPosition(e.x,e.y,e.z)
      e.actor:setVisible(false)
      e.actor:update(dt)
    end
    return
  end

  -- FOLLOWERS TAKE OFF ONLY AFTER THE LEADER IS WAITING AT RENDEZVOUS.
  if flock.mode=="followers_takeoff" then
    flock.takeoffClock=flock.takeoffClock+dt
    local r=flock.regroupPoint
    local leader=flock.members and flock.members[1]
    if not (r and leader) then
      flock.mode="fly"
      return
    end

    -- Keep the leader hovering/waiting at the rendezvous point.
    leader.x=leader.x+(r.x-leader.x)*math.min(1,dt*4.0)
    leader.y=leader.y+(r.y-leader.y)*math.min(1,dt*4.0)
    leader.z=leader.z+(r.z-leader.z)*math.min(1,dt*4.0)

    -- Continuously face back toward the approaching followers. This makes the
    -- leader look like it is checking the flock instead of staring forward.
    local sx,sz=0,0
    local scount=0
    for i=2,#flock.members do
      local f=flock.members[i]
      sx=sx+f.x
      sz=sz+f.z
      scount=scount+1
    end
    if scount>0 then
      local desired=yawFromVector(sx/scount-leader.x,sz/scount-leader.z)
      local current=leader.watchYaw or desired
      local delta=(desired-current+math.pi)%(math.pi*2)-math.pi
      leader.watchYaw=current+delta*math.min(1,dt*3.5)
      leader.actor:setYaw(leader.watchYaw)
    else
      leader.actor:setYaw((flock.heading or 0)+math.pi)
    end

    leader.actor:setPosition(leader.x,leader.y,leader.z)
    leader.actor:setVisible(false)
    leader.actor:update(dt)

    local allReady=true

    for i=2,#flock.members do
      local e=flock.members[i]
      -- Small stagger only among the followers, after the leader has arrived.
      local launchAt=(i-2)*TAKEOFF_STAGGER

      if flock.takeoffClock>=launchAt then
        e.launched=true

        local dx,dy,dz=r.x-e.x,r.y-e.y,r.z-e.z
        local dist=math.sqrt(dx*dx+dy*dy+dz*dz)

        if dist>REGROUP_RADIUS then
          allReady=false
          local step=math.min(dist,REGROUP_SPEED*dt)
          if dist>0.001 then
            e.x=e.x+dx/dist*step
            e.y=e.y+dy/dist*step
            e.z=e.z+dz/dist*step
          end
          if math.sqrt(dx*dx+dz*dz)>0.5 then
            e.actor:setYaw(yawFromVector(dx,dz))
          end
        end
      else
        allReady=false
      end

      e.actor:setPosition(e.x,e.y,e.z)
      e.actor:setVisible(false)
      e.actor:update(dt)
    end

    if allReady then
      -- Everybody physically reached the leader. Rebuild formation from their
      -- live positions; there is no recenter teleport.
      local cx,cy,cz=0,0,0
      for _,e in ipairs(flock.members) do
        cx=cx+e.x
        cy=cy+e.y
        cz=cz+e.z
        e.launched=nil
        e.atRendezvous=nil
        e.perchYaw=nil
        e.perchTargetYaw=nil
        e.perchTurnTimer=nil
        e.watchYaw=nil
      end

      local n=math.max(1,#flock.members)
      flock.center={x=cx/n,y=cy/n,z=cz/n}

      local heading=flock.heading or 0
      local fx,fz=math.sin(heading),math.cos(heading)
      flock.target={
        x=flock.center.x+fx*CELL*18,
        y=flock.center.y+randf(-3,3),
        z=flock.center.z+fz*CELL*18
      }

      flock.mode="fly"
      flock.perchAnchors=nil
      flock.regroupPoint=nil
      flock.perchTried=true
    end
    return
  end

  -- NORMAL STRAIGHT CROSS-MAP FLIGHT
  local c=flock.center
  local t=flock.target
  if not (c and t) then return end

  local dx,dy,dz=t.x-c.x,t.y-c.y,t.z-c.z
  local dist=math.sqrt(dx*dx+dy*dy+dz*dz)

  if dist<6 then
    local px,_,pz=playerPos(world)
    local dplayer=math.huge
    if px then dplayer=math.sqrt((c.x-px)^2+(c.z-pz)^2) end

    -- If the player is actively following the flock, do not cull it at the
    -- end of the original crossing. Extend the same flock farther ahead.
    if dplayer<=FOLLOW_KEEP_RADIUS then
      local heading=flock.heading or 0
      local fx,fz=math.sin(heading),math.cos(heading)
      flock.target={
        x=c.x+fx*FOLLOW_LEG_LENGTH,
        y=c.y+randf(-4,4),
        z=c.z+fz*FOLLOW_LEG_LENGTH,
      }
      flock.finished=false
      flock.perchTried=false
      return
    end

    flock.finished=true
    return
  end

  local horizontal=math.sqrt(dx*dx+dz*dz)
  if horizontal>0.5 then flock.heading=yawFromVector(dx,dz) end

  if not flock.hunt and not flock.perchTried then
    local px,_,pz=playerPos(world)
    if px then
      local dplayer=math.sqrt((c.x-px)^2+(c.z-pz)^2)
      if dplayer<CELL*8 and rnd01()<PERCH_CHANCE then
        flock.perchTried=true
        if tryPerch(world,map) then return end
      elseif dplayer<CELL*5 then
        flock.perchTried=true
      end
    end
  end

  local step=math.min(dist,FLIGHT_SPEED*dt)
  c.x=c.x+dx/dist*step
  c.y=c.y+dy/dist*step
  c.z=c.z+dz/dist*step

  for i,e in ipairs(flock.members) do
    if not e.detached then
      local o=formationFor(flock,i)
      local ox,oz=rotateOffset(o[1],o[2],flock.heading)
      local bob=math.sin(flock.age*5.0+e.phase)*1.4
      local sideDrift=math.sin(flock.age*1.2+e.phase)*0.8
      local leaderLift=e.isLeader and 5 or 0

      local tx=c.x+ox+sideDrift
      local ty=c.y+leaderLift+bob
      local tz=c.z+oz

      e.x=e.x+(tx-e.x)*math.min(1,dt*5.0)
      e.y=e.y+(ty-e.y)*math.min(1,dt*5.0)
      e.z=e.z+(tz-e.z)*math.min(1,dt*5.0)

      e.actor:setPosition(e.x,e.y,e.z)
      e.actor:setYaw(flock.heading)
      e.actor:setVisible(false)
      e.actor:update(dt)
    end
  end
end

local function drawActor(e)
  local actor=e and e.actor
  if not (actor and Voxel3D and type(Voxel3D.draw)=="function") then return end

  local matrix=actor:matrix()
  if type(Voxel3D.seams)=="function" then pcall(Voxel3D.seams,false) end
  if type(Voxel3D.glass)=="function" then pcall(Voxel3D.glass,false) end

  local black=blackTexture()
  if outlineEnabled() and black and love and love.graphics and love.graphics.setDepthMode then
    pcall(love.graphics.setDepthMode,"lequal",false)
    for _,part in ipairs(actor.rig.parts or {}) do
      if part.outlineMesh then
        pcall(Voxel3D.draw,part.outlineMesh,black,matrix,0,matrix)
      end
    end
    pcall(love.graphics.setDepthMode,"lequal",true)
  end

  for _,part in ipairs(actor.rig.parts or {}) do
    if part.mesh and part.texture then
      pcall(Voxel3D.draw,part.mesh,part.texture,matrix,0,matrix)
    end
  end

  if type(Voxel3D.glass)=="function" then pcall(Voxel3D.glass,true) end
  if type(Voxel3D.seams)=="function" then pcall(Voxel3D.seams,true) end
end

local companion=findDramaless()
if not companion then
  error("RUMBLE_FLYING_OVERWORLD: RUMBLE_MAIN compatible voxel_companion API unavailable",0)
end

local spec={
  api=1,
  id="rumble.flying.overworld",
  name="Rumble Flying Overworld",
  version="0.7.3",
  priority=31,
  requires={"render_phases","world_snapshot"},
  optional={},

  attach=function(_services)
    servicesReady=true
  end,

  worldChanged=function(_world)
    -- Do NOT destroy the flock here. Gen1Recomp fires worldChanged during map
    -- transitions, which caused the visible flock to pop out instantly.
    -- We keep its actors and relocate them once the next outdoor map is ready.
    transitionPending=true
    lastMap=nil
  end,

  render={
    opaque_after_terrain=function(context)
      if not flyingEcologyEnabled() then return end
      local world=context and context.world
      local map=outdoorMap()
      if not flyingEnabled() then
        if not (flock and flock.hunt) then clearFlock() end
        return
      end

      -- Keep the flock alive while passing through indoor/loading maps.
      -- It is simply not drawn until another outdoor map is ready.
      if not (servicesReady and world and world.player and world.id and map) then
        hiddenIndoors=true
        return
      end

      local id=tostring(map.id or world.id)

      if lastMap~=id then
        local hadFlock=(flock~=nil)
        lastMap=id

        if hadFlock and flock and flock.localRoam then
          -- Insects/bats belong to the map where they spawned. Never drag them
          -- through a connection into the next map.
          clearFlock()
          hadFlock=false
        elseif hadFlock and (transitionPending or hiddenIndoors) then
          -- Outdoor -> outdoor, or indoor transition -> outdoor:
          -- preserve the exact same bird flock and continue its trip.
          continueAcrossNewMap(world)
        end

        transitionPending=false
        hiddenIndoors=false
      end

      if not flock then
        spawnFlock(world,map)
      end

      local dt=(context.frame and context.frame.dt) or 1/60
      dt=math.max(0,math.min(0.1,tonumber(dt) or 1/60))

      updateFlight(world,map,dt)

      if flock and flock.finished then
        if not (flock and flock.hunt) then clearFlock() end
        spawnFlock(world,map)
      end

      if flock and flock.members then
        for _,e in ipairs(flock.members) do drawActor(e) end
      end
    end,
  },

  invalidate=function()
    -- Keep the flock alive across ordinary renderer invalidation.
  end,

  dispose=function()
    clearFlock()
    if BLACK_TEXTURE and BLACK_TEXTURE.release then
      pcall(BLACK_TEXTURE.release,BLACK_TEXTURE)
    end
    BLACK_TEXTURE=nil
  end,
}

local handle,err=companion.register(spec)
if not handle then
  error("RUMBLE_FLYING_OVERWORLD registration failed: "..tostring(err),0)
end

mod.exports.rumble_flying_overworld={
  api=1,
  version="0.7.3",
  clear=function() clearFlock() end,
  flockSize=function()
    return flock and flock.members and #flock.members or 0
  end,
  flockDex=function()
    return flock and flock.dex or nil
  end,
  roofOffset=function()
    local ow=Game and Game.overworld
    return roofOffsetForMap(ow and ow.map)
  end,
  tileset=function()
    local ow=Game and Game.overworld
    local map=ow and ow.map
    local def=map and map.def or {}
    return tostring(def and def.tileset or "")
  end,
}


-- v1.2.9 cross-ecology bridge.
-- Aerial flocks can discover an already-existing ground play group instead of
-- requiring the ground layer to be empty. The actual hunt controller can claim
-- one group at a time; the ground group remains encounterable by the player.
local PLAY_HUNT_CHANCE=0.18
local PLAY_HELP_CHANCE=0.30
local function availableGroundPlayGroup()
  local api=_G.RUMBLE_GROUND_ECOLOGY
  if not api or type(api.playGroups)~="function" then return nil end
  local groups=api.playGroups()
  local candidates={}
  for _,e in ipairs(groups or {}) do
    if not e.claimedByFlying and e.members and #e.members>=2 then
      candidates[#candidates+1]=e
    end
  end
  if #candidates==0 then return nil end
  return candidates[math.random(1,#candidates)]
end

-- Exported bridge used by the flock hunt state machine. Keeping the claim API
-- separate prevents ground events from blocking ordinary Caterpie/Weedle hunts.
_G.RUMBLE_FLYING_PLAY_HUNT=_G.RUMBLE_FLYING_PLAY_HUNT or {}
_G.RUMBLE_FLYING_PLAY_HUNT.tryClaim=function()
  if not flyingEcologyEnabled() then return nil end
  local ge=_G.RUMBLE_GROUND_ECOLOGY
  if ge and type(ge.enabled)=="function" and not ge.enabled() then return nil end
  if math.random()>=PLAY_HUNT_CHANCE then return nil end
  local e=availableGroundPlayGroup()
  if not e then return nil end
  e.claimedByFlying=true
  e.flyingOutcome=(math.random()<PLAY_HELP_CHANCE) and "return_help" or "abandon"
  e.flyingTargetIndex=math.random(1,#e.members)
  e.flyingFriendIndex=(e.flyingTargetIndex==1 and 2 or 1)
  e.flyingPhase="flee_together"
  return e
end
_G.RUMBLE_FLYING_PLAY_HUNT.release=function(e)
  if not e then return end
  e.claimedByFlying=nil;e.flyingOutcome=nil;e.flyingTargetIndex=nil
  e.flyingFriendIndex=nil;e.flyingPhase=nil
end
