local mod = ...
local Game = require("src.core.Game")
local Map = require("src.world.Map")

local CELL = 16
local MAX_WILDS = 4
local MIN_RADIUS = 3
local MAX_RADIUS = 8
local DESPAWN_RADIUS = 13
local SPAWN_DELAY = 0.55
local INITIAL_SPAWN_TARGET = 3
local INITIAL_SPAWN_ATTEMPTS = 8
local WALK_SPEED = 34
local FLEE_SPEED = 54
local FLEE_REPATH = 0.18
local WANDER_MIN = 0.80
local WANDER_MAX = 2.40
local FLY_ENTRY_HEIGHT = 46
local FLY_SETTLE_HEIGHT = 15
local FLY_ENTRY_TIME = 0.70
local LEVITATE_SETTLE_HEIGHT = 10
local LEVITATE_ENTRY_HEIGHT = 28
local LEVITATE_ENTRY_TIME = 0.52
local GHOST_TOSS_HEIGHT = 24
local GHOST_TOSS_TIME = 0.46
local GROUND_EMERGE_DEPTH = 9
local GROUND_EMERGE_TIME = 0.42
local BUCKETS = {51,102,141,166,191,216,229,242,253,256}


-- Unified Rumble option: Overworld Wilds YES / NO
local WILDS_KEY="overworld_wilds"
local function wildsEnabled()
  local loader=Game and Game.mods
  local stored=loader and loader.modOptions and loader.modOptions[mod.id]
  local v=stored and stored[WILDS_KEY]

  if v==nil then
    local opts=Game and Game.save and Game.save.options
    stored=opts and opts.modOptions and opts.modOptions[mod.id]
    v=stored and stored[WILDS_KEY]
  end

  if v==nil then return true end
  return v~=false and v~=0 and v~="NO" and v~="OFF"
end
local function setWilds(game,value)
  local opts=game and game.save and game.save.options
  if opts then
    opts.modOptions=opts.modOptions or {}; opts.modOptions[mod.id]=opts.modOptions[mod.id] or {}
    opts.modOptions[mod.id][WILDS_KEY]=value
  end
  local loader=game and game.mods
  if loader then
    loader.modOptions=loader.modOptions or {}; loader.modOptions[mod.id]=loader.modOptions[mod.id] or {}
    loader.modOptions[mod.id][WILDS_KEY]=value
  end
  if game and game.writeOptions then pcall(game.writeOptions,game) end
end

local wilds = {}
local mapId = nil
local spawnClock = 0
local needsInitialFill = true
local servicesReady = false
local Voxel3D = nil
local BLACK_TEXTURE = nil

local function rnd(a,b)
  if love and love.math and love.math.random then return love.math.random(a,b) end
  return math.random(a,b)
end
local function rnd01()
  if love and love.math and love.math.random then return love.math.random() end
  return math.random()
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
  if not (love and love.image and love.graphics and love.image.newImageData and love.graphics.newImage) then return nil end
  local ok, data = pcall(love.image.newImageData,1,1)
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

local function speciesOfDex(dex)
  dex=tonumber(dex)
  if not dex then return nil end
  dex=math.floor(dex)
  local data=Game and Game.data
  local pokemon=data and data.pokemon
  if type(pokemon)~="table" then return nil end
  for k,v in pairs(pokemon) do
    if type(v)=="table" then
      local d=tonumber(v.dex) or tonumber(k)
      if d and math.floor(d)==dex then
        return v.id or v.species or k
      end
    end
  end
  return nil
end

local function encounterDef(id)
  local e=Game and Game.data and Game.data.encounters
  return type(e)=="table" and e[id] or nil
end
local function grassTable(enc)
  local t=enc and enc.grass
  if type(t)~="table" or type(t.slots)~="table" or #t.slots==0 then return nil end
  if (tonumber(t.rate) or 0)<=0 then return nil end
  return t
end
local function pickEncounter(enc)
  local t=grassTable(enc)
  if not t then return nil end
  local buckets=t.buckets or BUCKETS
  local p=rnd(0,255)
  for i,thr in ipairs(buckets) do
    if p<thr then
      local slot=t.slots[i] or t.slots[#t.slots]
      if slot and slot.species then
        return dexOfSpecies(slot.species), slot.level or 1, slot.species
      end
      return nil
    end
  end
  local slot=t.slots[#t.slots]
  if slot and slot.species then
    return dexOfSpecies(slot.species), slot.level or 1, slot.species
  end
  return nil
end

local VISUAL_AERIAL={
  [12]=true,[15]=true,[16]=true,[17]=true,[18]=true,
  [21]=true,[22]=true,[41]=true,[42]=true,[49]=true,[83]=true,
}
-- Slow local hoverers: they levitate above valid terrain instead of walking.
local VISUAL_LEVITATING={
  [81]=true,[82]=true,       -- Magnemite / Magneton
  [92]=true,[93]=true,       -- Gastly / Haunter
  [109]=true,[110]=true,     -- Koffing / Weezing
}
local GHOST_LEVITATING={ [92]=true,[93]=true }

local function speciesDef(species,dex)
  local pokemon=Game and Game.data and Game.data.pokemon
  if type(pokemon)~="table" then return nil end
  return pokemon[species] or pokemon[tostring(species or ""):upper()] or pokemon[dex]
end
local function aerialDex(dex,species)
  if VISUAL_AERIAL[dex] then return true end
  local def=speciesDef(species,dex)
  if type(def)~="table" then return false end
  local types=def.types or def.type
  if type(types)=="string" then return types:upper():find("FLYING",1,true)~=nil end
  if type(types)=="table" then
    for _,t in pairs(types) do
      if tostring(t):upper()=="FLYING" then return true end
    end
  end
  return false
end

local WILDERNESS_HINTS={
  "FOREST","CAVE","MT_","MOON","ROCK_TUNNEL","DIGLETT","POKEMON_TOWER",
  "SEAFOAM","VICTORY_ROAD","POWER_PLANT","MANSION","UNKNOWN_DUNGEON","CERULEAN_CAVE"
}
local WILDERNESS_TILESETS={FOREST=true,CAVERN=true,CEMETERY=true,FACILITY=true,MANSION=true}
local function routeMap(map)
  if not map then return false end
  local id=tostring(map.id or ""):upper()
  return id:match("^ROUTE_?%d+$")~=nil
end

local function wilderness(map)
  if not map then return false end
  local id=tostring(map.id or ""):upper()
  local ts=tostring(map.def and map.def.tileset or ""):upper()
  if WILDERNESS_TILESETS[ts] then return true end
  for _,h in ipairs(WILDERNESS_HINTS) do if id:find(h,1,true) then return true end end
  return false
end

local function cemeteryLike(map)
  if not map then return false end
  local id=tostring(map.id or ""):upper()
  local ts=tostring(map.def and map.def.tileset or ""):upper()
  return ts=="CEMETERY" or id:find("POKEMON_TOWER",1,true)~=nil
end

local function inBounds(map,x,z)
  return map and map.inBounds and map:inBounds(x,z)
end
local function grass(map,x,z)
  return inBounds(map,x,z) and map.isGrassCell and map:isGrassCell(x,z)
end
local function walkable(map,x,z)
  return inBounds(map,x,z) and map.isWalkableCell and map:isWalkableCell(x,z)
end
local function forestLike(map)
  if not map then return false end
  local id=tostring(map.id or ""):upper()
  local ts=tostring(map.def and map.def.tileset or ""):upper()
  return ts:find("FOREST",1,true)~=nil or id:find("FOREST",1,true)~=nil
end
local function treeEdge(map,x,z)
  if not walkable(map,x,z) then return false end
  -- Never spawn inside the tree/wall. A tree-edge spawn is a passable cell
  -- immediately beside at least one blocked cell, so the Pokemon appears to
  -- emerge from foliage while remaining on valid terrain.
  local dirs={{1,0},{-1,0},{0,1},{0,-1}}
  for _,d in ipairs(dirs) do
    local nx,nz=x+d[1],z+d[2]
    if inBounds(map,nx,nz) and not walkable(map,nx,nz) then return true end
  end
  return false
end

local function playerCell(ow)
  local p=ow and ow.player
  if not p then return nil,nil end
  return tonumber(p.cellX), tonumber(p.cellY or p.cellZ)
end

local function occupied(ow,x,z)
  local px,pz=playerCell(ow)
  if px==x and pz==z then return true end
  for _,e in ipairs(ow and ow.entities or {}) do
    if e then
      local ex=tonumber(e.cellX)
      local ez=tonumber(e.cellY or e.cellZ)
      if ex==x and ez==z then return true end
    end
  end
  for _,w in ipairs(wilds) do
    if w.cellX==x and w.cellZ==z then return true end
    if w.targetX==x and w.targetZ==z then return true end
  end
  return false
end

local function nearbyGrass(ow)
  local map=ow.map
  local px,pz=playerCell(ow)
  if not px then return false end
  for dz=-MAX_RADIUS,MAX_RADIUS do
    for dx=-MAX_RADIUS,MAX_RADIUS do
      if grass(map,px+dx,pz+dz) then return true end
    end
  end
  return false
end

local function candidate(ow,useWalkable,preferOutsideGrass)
  local px,pz=playerCell(ow)
  if not px then return nil end
  for _=1,100 do
    local dx=rnd(-MAX_RADIUS,MAX_RADIUS)
    local dz=rnd(-MAX_RADIUS,MAX_RADIUS)
    local d=math.abs(dx)+math.abs(dz)
    if d>=MIN_RADIUS and d<=MAX_RADIUS then
      local x,z=px+dx,pz+dz
      local ok
      if useWalkable then
        ok=walkable(ow.map,x,z)
        if ok and preferOutsideGrass then ok=not grass(ow.map,x,z) end
      else
        ok=grass(ow.map,x,z)
      end
      if ok and not occupied(ow,x,z) then return x,z end
    end
  end
  return nil
end

local function candidateTreeEdge(ow)
  local px,pz=playerCell(ow)
  if not px then return nil end
  for _=1,120 do
    local dx=rnd(-MAX_RADIUS,MAX_RADIUS)
    local dz=rnd(-MAX_RADIUS,MAX_RADIUS)
    local d=math.abs(dx)+math.abs(dz)
    if d>=MIN_RADIUS and d<=MAX_RADIUS then
      local x,z=px+dx,pz+dz
      if treeEdge(ow.map,x,z) and not occupied(ow,x,z) then return x,z end
    end
  end
  return nil
end

local function yawForFacing(f)
  if f=="right" then return math.pi*0.5 end
  if f=="up" then return math.pi end
  if f=="left" then return -math.pi*0.5 end
  return 0
end
local function tilePos(x,z,y)
  return x*CELL+8, tonumber(y) or 0, z*CELL+8
end

local function destroyWild(w)
  if not (w and w.actor) then return end
  local ok=pcall(function() w.actor:destroy() end)
  if not ok then
    local imp=findImporter()
    if imp and type(imp.destroyActor)=="function" then pcall(imp.destroyActor,w.actor) end
  end
end
local function clearWilds()
  for _,w in ipairs(wilds) do destroyWild(w) end
  wilds={}
  spawnClock=0
  needsInitialFill=true
end

local function spawnOne(ow,world,instant)
  local enc=encounterDef(ow.map.id)
  if not grassTable(enc) then return false end

  -- Species is chosen first so its movement type controls HOW it enters the
  -- overworld, while the encounter table remains the sole source of WHAT can
  -- spawn on this map.
  local dex,level,species=pickEncounter(enc)
  if not dex or not species then return false end
  local isAerial=aerialDex(dex,species)
  local isLevitating=VISUAL_LEVITATING[dex] or false
  local isGhostLevitator=GHOST_LEVITATING[dex] or false
  local isCocoon=(dex==11 or dex==14) -- Metapod / Kakuna

  local useWalkable=false
  local outsideGrass=false
  local cx,cz

  if isLevitating then
    -- Levitaters use safe walkable terrain only as an XY anchor. They never
    -- become ground walkers; their model remains hovering above the floor.
    useWalkable=true
    cx,cz=candidate(ow,true,false)
  elseif isAerial then
    -- Aerial encounters descend into any safe open/walkable space. Prefer
    -- non-grass on routes so they visibly arrive from the sky instead of
    -- looking like a grass pop-in.
    useWalkable=true
    cx,cz=candidate(ow,true,routeMap(ow.map))
    if not cx then cx,cz=candidate(ow,true,false) end
  else
    -- Ground encounters visibly emerge from habitat: grass normally, or a
    -- valid passable tile beside forest/tree collision in forest maps.
    -- Metapod/Kakuna strongly prefer tree edges and remain stationary after
    -- appearing, instead of wandering like Caterpie/Weedle.
    if forestLike(ow.map) and (isCocoon or rnd01()<0.45) then
      useWalkable=true
      cx,cz=candidateTreeEdge(ow)
    end
    if not cx and nearbyGrass(ow) then
      useWalkable=false
      cx,cz=candidate(ow,false,false)
    end
    if not cx and wilderness(ow.map) then
      useWalkable=true
      cx,cz=candidate(ow,true,false)
    end
  end

  if not cx then return false end
  local imp=findImporter()
  if not imp then return false end
  local py=(world and world.player and world.player.y) or 0
  local x,floorY,z=tilePos(cx,cz,py)
  local settleY=isAerial and (floorY+FLY_SETTLE_HEIGHT)
      or (isLevitating and (floorY+LEVITATE_SETTLE_HEIGHT) or floorY)
  local ghostToss=(not instant) and isGhostLevitator and cemeteryLike(ow.map)
  local entryKind=isAerial and "fly_down"
      or (isLevitating and (ghostToss and "ghost_toss" or "levitate_in") or "emerge")
  local entryStartY
  if isAerial then
    entryStartY=floorY+FLY_ENTRY_HEIGHT
  elseif isLevitating then
    -- In cemeteries Gastly/Haunter burst upward from the slab/floor; elsewhere
    -- levitating species simply rise smoothly into their hover position.
    entryStartY=ghostToss and floorY or (floorY-GROUND_EMERGE_DEPTH)
  else
    entryStartY=floorY-GROUND_EMERGE_DEPTH
  end
  local startY=instant and settleY or entryStartY
  local facing=({"down","left","up","right"})[rnd(1,4)]
  local actor=imp.createActor(dex,{manual=true,visible=false,x=x,y=startY,z=z,yaw=yawForFacing(facing)})
  if not actor then return false end
  actor:setAnimation((isAerial or isLevitating) and "walk" or "idle")
  actor:setPosition(x,startY,z)
  actor:setYaw(yawForFacing(facing))
  actor:setVisible(false)
  wilds[#wilds+1]={
    dex=dex,species=species,level=level,actor=actor,cellX=cx,cellZ=cz,
    current={x=x,y=startY,z=z},target=nil,facing=facing,
    nextMove=WANDER_MIN+rnd01()*(WANDER_MAX-WANDER_MIN),lastAnim=(isAerial or isLevitating) and "walk" or "idle",
    useWalkable=useWalkable,
    routeRoamer=routeMap(ow.map) and useWalkable,
    aerial=isAerial,levitating=isLevitating,ghostLevitator=isGhostLevitator,
    stationary=isCocoon,spawnY=floorY,settleY=settleY,
    entry=(not instant) and {kind=entryKind,time=0,
      duration=isAerial and FLY_ENTRY_TIME or (isLevitating and (ghostToss and GHOST_TOSS_TIME or LEVITATE_ENTRY_TIME) or GROUND_EMERGE_TIME),
      startY=entryStartY,endY=settleY} or nil,
  }
  return true
end

local DIRS={{1,0,"right"},{-1,0,"left"},{0,1,"down"},{0,-1,"up"}}
local function chooseMove(w,ow)
  if rnd01()<0.35 then return end
  local d=DIRS[rnd(1,#DIRS)]
  local nx,nz=w.cellX+d[1],w.cellZ+d[2]
  local valid
  if w.useWalkable then valid=walkable(ow.map,nx,nz)
  else valid=grass(ow.map,nx,nz) end
  if not valid or occupied(ow,nx,nz) then return end
  local x,y,z=tilePos(nx,nz,w.current.y)
  w.target={x=x,y=y,z=z}
  w.targetX,w.targetZ=nx,nz
  w.facing=d[3]
end

local function wildIsAlive(target)
  if not target then return false end
  for _,w in ipairs(wilds) do
    if w==target then return true end
  end
  return false
end

local function chooseFleeMove(w,ow)
  if not (w and ow and ow.map and w.flee) then return false end
  local best,bestScore=nil,-math.huge
  local threatX=tonumber(w.flee.x) or w.current.x
  local threatZ=tonumber(w.flee.z) or w.current.z

  for _,d in ipairs(DIRS) do
    local nx,nz=w.cellX+d[1],w.cellZ+d[2]
    local valid=w.useWalkable and walkable(ow.map,nx,nz) or grass(ow.map,nx,nz)
    if valid and not occupied(ow,nx,nz) then
      local tx,ty,tz=tilePos(nx,nz,w.current.y)
      local dx,dz=tx-threatX,tz-threatZ
      local score=dx*dx+dz*dz+rnd01()*40
      if score>bestScore then
        bestScore=score
        best={nx=nx,nz=nz,x=tx,y=ty,z=tz,facing=d[3]}
      end
    end
  end

  if not best then return false end
  w.target={x=best.x,y=best.y,z=best.z}
  w.targetX,w.targetZ=best.nx,best.nz
  w.facing=best.facing
  w.flee.repath=FLEE_REPATH
  return true
end

local function beginFlee(w,fromX,fromZ,duration)
  if not wildIsAlive(w) then return false end
  w.flee=w.flee or {}
  w.flee.x=tonumber(fromX) or w.current.x
  w.flee.z=tonumber(fromZ) or w.current.z
  w.flee.timer=math.max(tonumber(duration) or 3.5,w.flee.timer or 0)
  w.flee.repath=0
  return true
end

local function updateThreat(w,fromX,fromZ)
  if not (w and w.flee) then return false end
  w.flee.x=tonumber(fromX) or w.flee.x
  w.flee.z=tonumber(fromZ) or w.flee.z
  return true
end

local function nearestDex(dex,x,z,radius)
  dex=tonumber(dex)
  local best,bestD=nil,math.huge
  local r=tonumber(radius) or CELL*10
  for _,w in ipairs(wilds) do
    if w.dex==dex and w.current then
      local dx=w.current.x-(tonumber(x) or 0)
      local dz=w.current.z-(tonumber(z) or 0)
      local d=math.sqrt(dx*dx+dz*dz)
      if d<=r and d<bestD then
        best,bestD=w,d
      end
    end
  end
  return best,bestD
end

-- ESCAPE_NO_ENCOUNTER_GUARD: escape state returns before normal collision/encounter AI.
local function updateWild(w,ow,dt)
  dt=math.max(0,math.min(0.1,tonumber(dt) or 1/60))
  if w.escapeFinished then
    w.current=nil
    if w.actor then w.actor:destroy(); w.actor=nil end
    return
  end

  if w.entry then
    local e=w.entry
    e.time=(e.time or 0)+dt
    local t=math.min(1,e.time/math.max(0.01,e.duration or 0.5))
    -- Smoothstep keeps the arrival from snapping at either end.
    local q=t*t*(3-2*t)
    if e.kind=="ghost_toss" then
      -- Quick upward burst, slight overshoot, then settle back to hover height.
      local base=e.startY or w.current.y
      local target=e.endY or w.current.y
      local linear=base+(target-base)*q
      w.current.y=linear+math.sin(math.pi*t)*GHOST_TOSS_HEIGHT
    else
      w.current.y=(e.startY or w.current.y)+((e.endY or w.current.y)-(e.startY or w.current.y))*q
    end
    if e.kind=="fly_down" then
      -- Small forward drift makes aerial encounters read as flying in rather
      -- than vertically teleporting down.
      local yaw=yawForFacing(w.facing)
      w.current.x=w.current.x+math.sin(yaw)*7*dt*(1-t)
      w.current.z=w.current.z+math.cos(yaw)*7*dt*(1-t)
      w.actor:setYaw(yaw)
      if w.lastAnim~="walk" then w.actor:setAnimation("walk");w.lastAnim="walk" end
    else
      if w.lastAnim~="idle" then w.actor:setAnimation("idle");w.lastAnim="idle" end
    end
    w.actor:setPosition(w.current.x,w.current.y,w.current.z)
    w.actor:setVisible(false)
    w.actor:update(dt)
    if t>=1 then
      w.current.y=e.endY or w.current.y
      w.entry=nil
      w.nextMove=0.35+rnd01()*0.65
    end
    return
  end

  if w.escapeNoEncounter then
    local e=w.escapeNoEncounter
    e.time=(e.time or 0)+dt
    if e.phase=="fall" then
      e.vy=(e.vy or 0)-70*dt
      w.current.y=w.current.y+e.vy*dt
      w.current.x=w.current.x+(e.vx or 0)*dt
      w.current.z=w.current.z+(e.vz or 0)*dt
      if w.current.y<=(e.floorY or 0) then
        w.current.y=e.floorY or 0
        e.phase="flee"; e.time=0
      end
      w.actor:setVisible(true)
      w.actor:setPosition(w.current.x,w.current.y,w.current.z)
      w.actor:setYaw(e.yaw or 0)
      if w.lastAnim~="idle" then w.actor:setAnimation("idle"); w.lastAnim="idle" end
      w.actor:update(dt)
      return
    end

    local speed=e.speed or 34
    w.current.x=w.current.x+math.sin(e.yaw or 0)*speed*dt
    w.current.z=w.current.z+math.cos(e.yaw or 0)*speed*dt
    w.actor:setVisible(true)
    w.actor:setPosition(w.current.x,w.current.y,w.current.z)
    w.actor:setYaw(e.yaw or 0)
    if w.lastAnim~="walk" then w.actor:setAnimation("walk"); w.lastAnim="walk" end
    w.actor:update(dt)
    if e.time>4.0 then w.escapeFinished=true end
    return
  end

  if w.carried then
    local c=w.carried
    c.stale=(c.stale or 0)+dt
    if c.stale>0.75 then
      -- Carrier vanished/interrupted without normal cleanup: never leave this
      -- wild permanently suspended at the last carried coordinates.
      w.carried=nil
      w.actor:setVisible(true)
      return
    end
    w.target,w.targetX,w.targetZ=nil,nil,nil
    w.flee=nil
    w.current.x,w.current.y,w.current.z=c.x,c.y,c.z
    w.actor:setPosition(c.x,c.y,c.z)
    w.actor:setYaw(c.yaw or 0)
    w.actor:setVisible(false)
    if w.lastAnim~="idle" then w.actor:setAnimation("idle");w.lastAnim="idle" end
    w.actor:update(dt)
    return
  end

  if w.flee then
    w.flee.timer=(w.flee.timer or 0)-dt
    w.flee.repath=(w.flee.repath or 0)-dt
    if w.flee.timer<=0 then
      w.flee=nil
      w.nextMove=0.25+rnd01()*0.5
    elseif (not w.target) or w.flee.repath<=0 then
      chooseFleeMove(w,ow)
    end
  end

  if w.stationary and not w.flee then
    w.target,w.targetX,w.targetZ=nil,nil,nil
    w.nextMove=999999
  elseif w.target then
    local c,t=w.current,w.target
    local dx,dz=t.x-c.x,t.z-c.z
    local dist=math.sqrt(dx*dx+dz*dz)
    if dist<=0.15 then
      c.x,c.y,c.z=t.x,t.y,t.z
      w.cellX,w.cellZ=w.targetX,w.targetZ
      w.target,w.targetX,w.targetZ=nil,nil,nil
      if w.flee and w.flee.timer>0 then chooseFleeMove(w,ow) end
    else
      local speed=w.flee and FLEE_SPEED or WALK_SPEED
      local step=math.min(dist,speed*dt)
      c.x=c.x+dx/dist*step
      c.z=c.z+dz/dist*step
    end
  elseif w.flee and w.flee.timer>0 then
    chooseFleeMove(w,ow)
  else
    w.nextMove=w.nextMove-dt
    if w.nextMove<=0 then
      w.nextMove=WANDER_MIN+rnd01()*(WANDER_MAX-WANDER_MIN)
      chooseMove(w,ow)
    end
  end

  local moving=w.target~=nil
  local yaw=moving and math.atan2(w.target.x-w.current.x,w.target.z-w.current.z) or yawForFacing(w.facing)
  if (w.aerial or w.levitating) and not w.carried then
    local hoverSpeed=w.levitating and 1.55 or 2.4
    local hoverAmp=w.levitating and 0.8 or 1.2
    w.hoverPhase=(w.hoverPhase or rnd01()*6.28318)+dt*hoverSpeed
    w.current.y=(w.settleY or w.current.y)+math.sin(w.hoverPhase)*hoverAmp
  end
  w.actor:setPosition(w.current.x,w.current.y,w.current.z)
  w.actor:setYaw(yaw)
  w.actor:setVisible(false)
  local anim=moving and "walk" or "idle"
  if w.lastAnim~=anim then w.actor:setAnimation(anim);w.lastAnim=anim end
  w.actor:update(dt)
end

local function cullFar(ow)
  local px,pz=playerCell(ow)
  if not px then return end
  for i=#wilds,1,-1 do
    local w=wilds[i]
    if not w.carried then
      local d=math.abs(w.cellX-px)+math.abs(w.cellZ-pz)
      if d>DESPAWN_RADIUS then destroyWild(w);table.remove(wilds,i) end
    end
  end
end

local encounterLock = false

local function removeWildAt(index)
  local w=wilds[index]
  if not w then return nil end
  destroyWild(w)
  table.remove(wilds,index)
  return w
end

local function startVisibleEncounter(ow,w)
  if encounterLock or not (ow and w and w.species) then return false end
  if Game.stack and Game.stack.top and Game.stack:top() ~= ow then return false end

  encounterLock=true

  local BattleState=require("src.battle.BattleState")
  local battle=BattleState.newWild(Game,w.species,w.level)

  battle.checkpointOrigin={
    kind="wild_encounter",
    map=ow.map.id,
  }

  -- Preserve the engine's special wild battle modes.
  local ghost=Map.ghostBattles and Map.ghostBattles(ow.map.def)
  if ghost and not (ghost.unlessItem and Game.save.inventory[ghost.unlessItem]) then
    battle:makeGhost()
  end
  if Game.save.safari and Map.inRegion
     and Map.inRegion(ow.map.def,"SAFARI","SAFARI_ZONE") then
    battle:makeSafari(Game.save.safari)
  end

  battle.onFinish=function(result)
    encounterLock=false
    ow:afterBattle(result,battle)
  end

  ow:pushBattle(battle)
  return true
end

local function startDexEncounter(dex,level,onFinish)
  local ow=Game and Game.overworld
  if encounterLock or not ow then return false end
  if Game.stack and Game.stack.top and Game.stack:top() ~= ow then return false end

  local species=speciesOfDex(dex)
  if not species then return false end
  encounterLock=true

  local BattleState=require("src.battle.BattleState")
  local battle=BattleState.newWild(Game,species,tonumber(level) or 5)
  battle.checkpointOrigin={kind="wild_encounter",map=ow.map and ow.map.id}

  local ghost=ow.map and Map.ghostBattles and Map.ghostBattles(ow.map.def)
  if ghost and not (ghost.unlessItem and Game.save.inventory[ghost.unlessItem]) then
    battle:makeGhost()
  end
  if Game.save.safari and ow.map and Map.inRegion
     and Map.inRegion(ow.map.def,"SAFARI","SAFARI_ZONE") then
    battle:makeSafari(Game.save.safari)
  end

  battle.onFinish=function(result)
    encounterLock=false
    if type(onFinish)=="function" then pcall(onFinish,result) end
    ow:afterBattle(result,battle)
  end

  ow:pushBattle(battle)
  return true
end

local function checkVisibleEncounter(ow)
  if encounterLock or not (ow and ow.player) then return false end
  if Game.stack and Game.stack.top and Game.stack:top() ~= ow then return false end

  local px,pz=playerCell(ow)
  if px==nil or pz==nil then return false end

  -- The models are visual actors rather than blocking map NPCs. When the
  -- trainer completes a step onto one of their occupied tiles, battle that
  -- exact visible Pokemon and remove only that overworld actor.
  for i=#wilds,1,-1 do
    local w=wilds[i]
    local hit=(w.cellX==px and w.cellZ==pz)
    if not hit and w.targetX and w.targetZ then
      -- Also catch a Pokemon that is finishing a wander onto the same tile.
      hit=(w.targetX==px and w.targetZ==pz)
    end
    if hit then
      local victim=removeWildAt(i)
      if victim then
        return startVisibleEncounter(ow,victim)
      end
    end
  end
  return false
end

local function drawWild(w)
  if not (w and w.actor and Voxel3D and type(Voxel3D.draw)=="function") then return end
  local actor=w.actor
  local matrix=actor:matrix()
  if type(Voxel3D.seams)=="function" then pcall(Voxel3D.seams,false) end
  if type(Voxel3D.glass)=="function" then pcall(Voxel3D.glass,false) end
  local black=blackTexture()
  if outlineEnabled() and black and love and love.graphics and love.graphics.setDepthMode then
    pcall(love.graphics.setDepthMode,"lequal",false)
    for _,part in ipairs(actor.rig.parts or {}) do
      if part.outlineMesh then pcall(Voxel3D.draw,part.outlineMesh,black,matrix,0,matrix) end
    end
    pcall(love.graphics.setDepthMode,"lequal",true)
  end
  for _,part in ipairs(actor.rig.parts or {}) do
    if part.mesh and part.texture then pcall(Voxel3D.draw,part.mesh,part.texture,matrix,0,matrix) end
  end
  if type(Voxel3D.glass)=="function" then pcall(Voxel3D.glass,true) end
  if type(Voxel3D.seams)=="function" then pcall(Voxel3D.seams,true) end
end

local companion=findDramaless()
if not companion then error("RUMBLE_OVERWORLD_WILDS: RUMBLE_MAIN compatible voxel_companion API unavailable",0) end

local spec={
  api=1,id="rumble.overworld.wilds",name="Rumble Overworld Wilds",version="0.1.2",priority=25,
  requires={"render_phases","world_snapshot"},optional={},
  attach=function(_) servicesReady=true end,
  worldChanged=function(_) encounterLock=false;clearWilds();mapId=nil end,
  render={
    opaque_after_terrain=function(context)
      local world=context and context.world
      local ow=Game and Game.overworld
      if not wildsEnabled() then
        if #wilds>0 then clearWilds() end
        return
      end
      if not (servicesReady and world and world.id and ow and ow.map and ow.player) then return end
      if mapId~=ow.map.id then clearWilds();mapId=ow.map.id end
      local enc=encounterDef(ow.map.id)
      if not grassTable(enc) then
        if #wilds>0 then clearWilds() end
        return
      end
      local dt=(context.frame and context.frame.dt) or 1/60

      -- Touching a visible wild starts a normal engine wild battle against
      -- THAT displayed species/level.
      if checkVisibleEncounter(ow) then return end

      cullFar(ow)
      for _,w in ipairs(wilds) do updateWild(w,ow,dt) end

      -- A moving wild can finish onto the trainer's tile this same frame.
      if checkVisibleEncounter(ow) then return end

      -- Seed several visible wilds when a valid map first loads instead of
      -- making the player watch the population appear one-by-one. Refills after
      -- despawn/encounter still use the normal staggered delay.
      if needsInitialFill then
        local attempts=0
        while #wilds<math.min(MAX_WILDS,INITIAL_SPAWN_TARGET) and attempts<INITIAL_SPAWN_ATTEMPTS do
          spawnOne(ow,world,true)
          attempts=attempts+1
        end
        needsInitialFill=false
        spawnClock=SPAWN_DELAY
      else
        spawnClock=spawnClock-dt
        if #wilds<MAX_WILDS and spawnClock<=0 then
          spawnOne(ow,world,false)
          spawnClock=SPAWN_DELAY
        end
      end
      for _,w in ipairs(wilds) do drawWild(w) end
    end,
  },
  invalidate=function() encounterLock=false;clearWilds();mapId=nil end,
  dispose=function()
    clearWilds()
    if BLACK_TEXTURE and BLACK_TEXTURE.release then pcall(BLACK_TEXTURE.release,BLACK_TEXTURE) end
    BLACK_TEXTURE=nil
  end,
}
local handle,err=companion.register(spec)
if not handle then error("RUMBLE_OVERWORLD_WILDS registration failed: "..tostring(err),0) end

local function setCarried(w,x,y,z,yaw)
  if not wildIsAlive(w) then return false end
  w.carried=w.carried or {}
  w.carried.x=tonumber(x) or w.current.x
  w.carried.y=tonumber(y) or w.current.y
  w.carried.z=tonumber(z) or w.current.z
  w.carried.yaw=tonumber(yaw) or 0
  w.carried.stale=0
  w.flee=nil
  w.target,w.targetX,w.targetZ=nil,nil,nil
  return true
end

local function dropAndFlee(w,yaw)
  if not wildIsAlive(w) then return false end
  local c=w.carried
  w.carried=nil
  w.flee=nil
  w.target,w.targetX,w.targetZ=nil,nil,nil
  local floorY=tonumber(w.spawnY) or tonumber(w.y) or 0
  local heading=tonumber(yaw) or (c and tonumber(c.yaw)) or 0
  w.escapeNoEncounter={
    phase="fall",time=0,floorY=floorY,vy=-8,
    vx=math.sin(heading)*8,vz=math.cos(heading)*8,
    yaw=heading,speed=34,
  }
  if w.actor then w.actor:setVisible(true) end
  return true
end

local function consumeWild(w)
  if not w then return false end
  for i=#wilds,1,-1 do
    if wilds[i]==w then
      destroyWild(w)
      table.remove(wilds,i)
      return true
    end
  end
  return false
end

mod.exports.rumble_overworld_wilds={
  api=2,version="0.2.0",
  count=function() return #wilds end,
  clear=clearWilds,
  nearestDex=nearestDex,
  isAlive=wildIsAlive,
  beginFlee=beginFlee,
  updateThreat=updateThreat,
  setCarried=setCarried,
  dropAndFlee=dropAndFlee,
  consumeWild=consumeWild,
  startDexEncounter=startDexEncounter,
}
