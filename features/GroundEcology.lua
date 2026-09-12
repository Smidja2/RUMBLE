local GROUND_ECOLOGY_KEY="rumble_ground_ecology"
local OVERWORLD_WILDS_KEY="overworld_wilds"

local mod=...
local Game=require("src.core.Game")

local function optionValue(key,default)
  local loader=Game and Game.mods
  local st=loader and loader.modOptions and loader.modOptions[mod.id]
  local v=st and st[key]
  if v==nil then
    local opts=Game and Game.save and Game.save.options
    st=opts and opts.modOptions and opts.modOptions[mod.id]
    v=st and st[key]
  end
  if v==nil then return default end
  return v
end
local function optionOn(key,default)
  local v=optionValue(key,default)
  return v~=false and v~=0 and v~="OFF" and v~="NO"
end
local function groundEcologyEnabled()
  return optionOn(OVERWORLD_WILDS_KEY,true) and optionOn(GROUND_ECOLOGY_KEY,true)
end

-- Ground ecology test layer: one ambient event at a time, independent of the
-- four normal OverworldWilds. Touching any participant starts a real battle.
local CELL=16
local EVENT_CHANCE=0.24
local RESPAWN_MIN=14.0
local RESPAWN_MAX=30.0
local EVENT_LIFE=22.0
local WALK=27
local RUN=72
local TOUCH_RADIUS=10
local PLAY_ALERT_RADIUS=CELL*3.4
local PLAY_FLEE_SPEED=88 -- deliberately faster than the trainer
local PLAY_REGROUP_RADIUS=CELL*1.65
local MIN_R=4
local MAX_R=8

local PREDATOR_PREY_BY_BIOME={
  route={
    {pred=23,prey=19,name="Ekans / Rattata"},
    {pred=52,prey=19,name="Meowth / Rattata"},
    {pred=58,prey=19,name="Growlithe / Rattata"},
    {pred=53,prey=19,name="Persian / Rattata"},
  },
  forest={
    {pred=16,prey=10,name="Pidgey / Caterpie"},
    {pred=21,prey=13,name="Spearow / Weedle"},
    {pred=23,prey=10,name="Ekans / Caterpie"},
    {pred=48,prey=10,name="Venonat / Caterpie"},
  },
  cave={
    {pred=23,prey=41,name="Ekans / Zubat"},
    {pred=41,prey=46,name="Zubat / Paras"},
    {pred=50,prey=46,name="Diglett / Paras"},
    {pred=27,prey=46,name="Sandshrew / Paras"},
  },
}
local PREDATOR_PREY=PREDATOR_PREY_BY_BIOME.route
local PLAY_POOLS={
  route={1,19,29,32,37,58,77,133},             -- Bulbasaur,Rattata,Nidoran,Vulpix,Growlithe,Ponyta,Eevee
  forest={10,13,16,19,25,43,46,48},            -- Caterpie,Weedle,Pidgey,Rattata,Pikachu,Oddish,Paras,Venonat
  cave={27,41,46,50,66,74},                    -- Sandshrew,Zubat,Paras,Diglett,Machop,Geodude
}
local PLAY_DEX=PLAY_POOLS.route

-- Rival-vs-rival ambient battles. Pools are biome-scoped instead of choosing
-- arbitrary species everywhere. These are visual scuffles, not trainer battles.
local RIVAL_POOLS={
  route={
    {19,19},{29,32},{37,58},{52,56},{58,77},{21,19},{23,19},
  },
  forest={
    {10,13},{11,14},{25,19},{43,46},{46,48},{16,21},
  },
  cave={
    {41,74},{74,74},{27,41},{23,41},{50,74},{66,74},
  },
  building={
    {19,52},{52,56},{63,19},{88,19},{100,52},
  },
}

local events={}
local MAX_EVENTS=3
local event=nil
local clock=4.0
local mapId=nil
local Voxel3D=nil
local BLACK=nil
local servicesReady=false
local battleLock=false

local function rnd(a,b) return (love and love.math and love.math.random) and love.math.random(a,b) or math.random(a,b) end
local function rnd01() return (love and love.math and love.math.random) and love.math.random() or math.random() end
local function importer()
  local a=mod.exports and (mod.exports.rumble_main or mod.exports.rumble_importer)
  return a
end
local function wildAPI() return mod.exports and mod.exports.rumble_overworld_wilds or {} end
local function companion() return mod.exports and mod.exports.voxel_companion end
local function enabled() return groundEcologyEnabled() end
local function playerCell(ow)
  local p=ow and ow.player
  return p and tonumber(p.cellX),p and tonumber(p.cellY or p.cellZ)
end
local function biome(map)
  if not map then return nil end
  local id=tostring(map.id or ""):upper()
  local ts=tostring(map.def and map.def.tileset or ""):upper()
  if id:match("^ROUTE_?%d+$") then return "route" end
  if id:find("FOREST",1,true) or ts=="FOREST" then return "forest" end
  if id:find("CAVE",1,true) or id:find("MT_",1,true) or id:find("MOON",1,true)
     or id:find("ROCK_TUNNEL",1,true) or ts=="CAVERN" then return "cave" end
  -- Interior/building tilesets: keep this conservative so towns themselves
  -- don't suddenly fill with fighting Pokemon.
  if ts=="INTERIOR" or ts=="HOUSE" or ts=="FACILITY" or ts=="MANSION"
     or id:find("GATE",1,true) or id:find("BUILDING",1,true) then return "building" end
  return nil
end
local function route(map) return biome(map)=="route" end
local function walkable(map,x,z)
  return map and map.inBounds and map:inBounds(x,z) and map.isWalkableCell and map:isWalkableCell(x,z)
end
local function occupied(ow,x,z)
  local px,pz=playerCell(ow); if px==x and pz==z then return true end
  for _,e in ipairs(ow and ow.entities or {}) do
    if tonumber(e.cellX)==x and tonumber(e.cellY or e.cellZ)==z then return true end
  end
  return false
end
local function pos(cx,cz,y) return cx*CELL+8,y or 0,cz*CELL+8 end
local function candidate(ow)
  local px,pz=playerCell(ow); if not px then return nil end
  for _=1,100 do
    local dx,dz=rnd(-MAX_R,MAX_R),rnd(-MAX_R,MAX_R)
    local d=math.abs(dx)+math.abs(dz)
    local x,z=px+dx,pz+dz
    if d>=MIN_R and d<=MAX_R and walkable(ow.map,x,z) and not occupied(ow,x,z) then return x,z end
  end
end
local function makeActor(dex,cx,cz,y)
  local api=importer(); if not api or type(api.createActor)~="function" then return nil end
  local x,yy,z=pos(cx,cz,y)
  local a=api.createActor(dex,{manual=true,visible=false,x=x,y=yy,z=z})
  if not a then return nil end
  a:setAnimation("idle"); a:setVisible(false)
  return {dex=dex,actor=a,x=x,y=yy,z=z,cx=cx,cz=cz,tx=nil,tz=nil,mode="idle",
          timer=0,contact=false,phase=rnd01()*6.28}
end
local function destroyMember(m)
  if m and m.actor then pcall(function() m.actor:destroy() end); m.actor=nil end
end
local function clear()
  for _,e in ipairs(events) do
    for _,m in ipairs(e.members or {}) do destroyMember(m) end
  end
  events={}
  battleLock=false
end
local function black()
  if BLACK then return BLACK end
  if not (love and love.image and love.graphics) then return nil end
  local ok,d=pcall(love.image.newImageData,1,1); if not ok then return nil end
  pcall(d.setPixel,d,0,0,0,0,0,1)
  local ok2,i=pcall(love.graphics.newImage,d); if ok2 then BLACK=i end
  return BLACK
end
local function draw(m)
  if not (m.actor and Voxel3D and type(Voxel3D.draw)=="function") then return end
  local mat=m.actor:matrix()
  local b=black()
  local api=importer()
  local outline=not api or type(api.outlineEnabled)~="function" or api.outlineEnabled()
  if outline and b and love.graphics.setDepthMode then
    pcall(love.graphics.setDepthMode,"lequal",false)
    for _,p in ipairs(m.actor.rig.parts or {}) do if p.outlineMesh then pcall(Voxel3D.draw,p.outlineMesh,b,mat,0,mat) end end
    pcall(love.graphics.setDepthMode,"lequal",true)
  end
  for _,p in ipairs(m.actor.rig.parts or {}) do if p.mesh and p.texture then pcall(Voxel3D.draw,p.mesh,p.texture,mat,0,mat) end end
end
local function setTarget(m,cx,cz)
  m.tcx,m.tcz=cx,cz
  m.tx,m.ty,m.tz=pos(cx,cz,m.y)
end
local function moveToward(m,dt,speed)
  if not m.tx then return true end
  local dx,dz=m.tx-m.x,m.tz-m.z
  local d=math.sqrt(dx*dx+dz*dz)
  if d<0.5 then
    m.x,m.z=m.tx,m.tz; m.cx,m.cz=m.tcx,m.tcz
    m.tx,m.tz=nil,nil; return true
  end
  local q=math.min(d,speed*dt)
  m.x=m.x+dx/d*q; m.z=m.z+dz/d*q
  m.actor:setYaw(math.atan2(dx,dz))
  return false
end
local function randomStep(ow,m)
  local dirs={{1,0},{-1,0},{0,1},{0,-1}}
  for _=1,8 do
    local d=dirs[rnd(1,4)]; local x,z=m.cx+d[1],m.cz+d[2]
    if walkable(ow.map,x,z) and not occupied(ow,x,z) then setTarget(m,x,z); return end
  end
end
local function awayStep(ow,m,px,pz)
  local best,score=nil,-1e9
  for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
    local x,z=m.cx+d[1],m.cz+d[2]
    if walkable(ow.map,x,z) then
      local s=(x-px)^2+(z-pz)^2+rnd01()
      if s>score then score=s;best={x,z} end
    end
  end
  if best then setTarget(m,best[1],best[2]) end
end

local function spawn(ow,world)
  if not groundEcologyEnabled() then return false end
  local bio=biome(ow.map)
  if not bio then return false end
  local cx,cz=candidate(ow); if not cx then return false end
  local y=(world and world.player and world.player.y) or 0
  local e={members={},age=0,battlePause=false,biome=bio}

  local roll=rnd01()
  local canNature=(bio=="route" or bio=="forest" or bio=="cave")
  if canNature and roll<0.34 then
    e.kind="hunt"
    local pool=PREDATOR_PREY_BY_BIOME[bio] or PREDATOR_PREY_BY_BIOME.route
    local pair=pool[rnd(1,#pool)]
    e.name=pair.name
    local predm=makeActor(pair.pred,cx,cz,y)
    local prey=nil
    if walkable(ow.map,cx+1,cz) then prey=makeActor(pair.prey,cx+1,cz,y) end
    if not prey and walkable(ow.map,cx,cz+1) then prey=makeActor(pair.prey,cx,cz+1,y) end
    if not predm or not prey then destroyMember(predm);destroyMember(prey);return false end
    predm.role="pred";prey.role="prey"; e.members={predm,prey}

  elseif canNature and roll<0.68 then
    e.kind="play"
    local pool=PLAY_POOLS[bio] or PLAY_POOLS.route
    local n=rnd(2,3)
    local first=pool[rnd(1,#pool)]
    -- Strong same-species bias: most groups are same species, but mixed play
    -- remains possible where it makes ecological sense.
    local sameSpecies=(rnd01()<0.68)
    for i=1,n do
      local dex
      if i==1 or sameSpecies then dex=first
      else dex=(rnd01()<0.45) and first or pool[rnd(1,#pool)] end
      local offsets={{0,0},{1,0},{0,1},{-1,0},{0,-1}}
      local o=offsets[i] or offsets[1]
      local m=nil
      if walkable(ow.map,cx+o[1],cz+o[2]) then m=makeActor(dex,cx+o[1],cz+o[2],y) end
      if m then m.role="play";e.members[#e.members+1]=m end
    end
    if #e.members<2 then for _,m in ipairs(e.members) do destroyMember(m) end return false end

  else
    e.kind="rival"
    local pool=RIVAL_POOLS[bio] or RIVAL_POOLS.route
    local pair=pool[rnd(1,#pool)]
    local m1=makeActor(pair[1],cx,cz,y)
    local m2=nil
    if walkable(ow.map,cx+1,cz) then m2=makeActor(pair[2],cx+1,cz,y) end
    if not m2 and walkable(ow.map,cx,cz+1) then m2=makeActor(pair[2],cx,cz+1,y) end
    if not m1 or not m2 then destroyMember(m1);destroyMember(m2);return false end
    m1.role="rival";m2.role="rival";m1.partner=m2;m2.partner=m1
    m1.timer=.25+rnd01()*.5;m2.timer=.45+rnd01()*.5
    e.members={m1,m2}
  end
  events[#events+1]=e
  event=e
  return true
end

local function resultRemovesPokemon(result)
  -- Engine versions expose battle outcome differently. Recognize the common
  -- KO/catch markers; unknown/escape/win outcomes are treated as survivor.
  if type(result)=="string" then
    local s=result:lower()
    return s:find("caught",1,true) or s:find("capture",1,true) or s:find("faint",1,true) or s=="ko"
  elseif type(result)=="table" then
    if result.caught or result.captured or result.fainted or result.ko or result.wildFainted then return true end
    local s=tostring(result.result or result.outcome or result.reason or ""):lower()
    return s:find("caught",1,true) or s:find("capture",1,true) or s:find("faint",1,true) or s=="ko"
  end
  return false
end
local function removeMember(target,ev)
  ev=ev or event
  if not ev then return end
  for i=#ev.members,1,-1 do
    if ev.members[i]==target then
      destroyMember(target)
      table.remove(ev.members,i)
      break
    end
  end
end

local function touch(world,m)
  local p=world and world.player; if not p then return false end
  local px,pz=tonumber(p.x),tonumber(p.z)
  if not px or not pz then return false end
  local dx,dz=m.x-px,m.z-pz
  return dx*dx+dz*dz<=TOUCH_RADIUS*TOUCH_RADIUS
end
local function playerWorld(world)
  local p=world and world.player
  return p and tonumber(p.x),p and tonumber(p.z)
end
local function alertPlayGroup(ow,world,ev)
  ev=ev or event
  if not event or ev.kind~="play" or ev.playFlee then return false end
  local px,pz=playerWorld(world); if not px then return false end
  for _,m in ipairs(ev.members) do
    local dx,dz=m.x-px,m.z-pz
    if dx*dx+dz*dz<=PLAY_ALERT_RADIUS*PLAY_ALERT_RADIUS then
      ev.playFlee=true
      ev.playFleeTimer=5.0
      local pcx,pcz=playerCell(ow)
      for _,o in ipairs(ev.members) do
        o.mode="play_flee";o.timer=5.0;o.contact=false
        if pcx then awayStep(ow,o,pcx,pcz) end
      end
      return true
    end
  end
  return false
end

local function beginBattle(ow,world,m,ev)
  local api=wildAPI()
  ev=ev or event
  if battleLock or not ev or not api or type(api.startDexEncounter)~="function" then return false end
  battleLock=true;ev.battlePause=true;m.contact=true
  local started=api.startDexEncounter(m.dex,5,function(result)
    if resultRemovesPokemon(result) then
      removeMember(m,ev)
    else
      m.mode="scatter";m.timer=3.2
    end
    local px,pz=playerCell(ow)
    for _,o in ipairs(ev.members or {}) do
      o.mode="scatter";o.timer=math.max(o.timer or 0,3.2);o.contact=true
      if px then awayStep(ow,o,px,pz) end
    end
    ev.battlePause=false
    ev.age=math.max(ev.age or 0,EVENT_LIFE-5)
    battleLock=false
  end)
  if not started then battleLock=false;ev.battlePause=false;m.contact=false end
  return started
end

local function updateMember(ow,m,dt,ev)
  ev=ev or event
  if m.mode=="play_flee" then
    m.timer=(m.timer or 0)-dt
    local px,pz=playerCell(ow)
    if not m.tx and px then awayStep(ow,m,px,pz) end
    moveToward(m,dt,PLAY_FLEE_SPEED)
    -- Keep the play group escaping as a loose pack: a member that gets too
    -- far ahead briefly eases off while the others catch up.
    local cx,cz,n=0,0,0
    for _,o in ipairs(ev.members or {}) do cx=cx+o.x;cz=cz+o.z;n=n+1 end
    if n>1 then
      cx,cz=cx/n,cz/n
      local dx,dz=m.x-cx,m.z-cz
      if dx*dx+dz*dz>PLAY_REGROUP_RADIUS*PLAY_REGROUP_RADIUS then
        m.tx,m.tz=nil,nil
      end
    end
    if m.timer<=0 then m.mode="exit" end
  elseif m.mode=="scatter" then
    m.timer=m.timer-dt
    if not m.tx then local px,pz=playerCell(ow);if px then awayStep(ow,m,px,pz) end end
    moveToward(m,dt,RUN)
    if m.timer<=0 then m.mode="exit" end
  elseif m.mode=="exit" then
    if not m.tx then local px,pz=playerCell(ow);if px then awayStep(ow,m,px,pz) end end
    moveToward(m,dt,RUN)
  elseif ev.kind=="rival" then
    local other=m.partner
    m.timer=(m.timer or 0)-dt
    if other and m.timer<=0 then
      local dx,dz=other.x-m.x,other.z-m.z
      local dist=math.sqrt(dx*dx+dz*dz)
      m.actor:setYaw(math.atan2(dx,dz))
      if dist>CELL*1.15 and not m.tx then
        local sx=dx==0 and 0 or (dx>0 and 1 or -1)
        local sz=dz==0 and 0 or (dz>0 and 1 or -1)
        local nx,nz=m.cx+sx,m.cz+(sx==0 and sz or 0)
        if walkable(ow.map,nx,nz) then setTarget(m,nx,nz) end
      elseif dist<CELL*0.62 and not m.tx then
        awayStep(ow,m,other.cx,other.cz)
      else
        -- Short attack burst, then idle/reposition. Offset timers stop both
        -- rivals from looking mechanically synchronized.
        m.actor:setAnimation("attack")
        m.timer=.65+rnd01()*1.15
      end
    end
    moveToward(m,dt,WALK*1.25)
  elseif ev.kind=="hunt" then
    local other=ev.members[m==ev.members[1] and 2 or 1]
    if other then
      if m.role=="prey" then
        local dx,dz=m.x-other.x,m.z-other.z
        if dx*dx+dz*dz<(CELL*3)^2 and not m.tx then
          local px,pz=other.cx,other.cz;awayStep(ow,m,px,pz)
        end
      elseif not m.tx then
        local dx,dz=other.cx-m.cx,other.cz-m.cz
        local sx=dx==0 and 0 or (dx>0 and 1 or -1)
        local sz=dz==0 and 0 or (dz>0 and 1 or -1)
        local nx,nz=m.cx+sx,m.cz+(sx==0 and sz or 0)
        if walkable(ow.map,nx,nz) then setTarget(m,nx,nz) end
      end
    end
    moveToward(m,dt,m.role=="prey" and RUN*0.78 or WALK*1.35)
  else
    m.timer=m.timer-dt
    if not m.tx and m.timer<=0 then randomStep(ow,m);m.timer=.35+rnd01()*.7 end
    moveToward(m,dt,WALK*1.15)
  end
  local moving=m.tx~=nil
  m.actor:setPosition(m.x,m.y,m.z)
  m.actor:setVisible(false)
  if not (ev.kind=="rival" and not moving and (m.timer or 0)>0.45) then
    m.actor:setAnimation(moving and "walk" or "idle")
  end
  m.actor:update(dt)
end

local comp=companion()
if not comp then error("RUMBLE_GROUND_ECOLOGY: voxel companion unavailable",0) end
local imp=importer()
if imp and type(imp.Voxel3D)=="function" then local ok,v=pcall(imp.Voxel3D);if ok then Voxel3D=v end end

local spec={
 api=1,id="rumble.ground.ecology",name="Rumble Ground Ecology",version="0.2.0",priority=27,
 requires={"render_phases","world_snapshot"},optional={},
 attach=function() servicesReady=true end,
 worldChanged=function() clear();mapId=nil;clock=RESPAWN_MIN+rnd01()*(RESPAWN_MAX-RESPAWN_MIN) end,
 render={opaque_after_terrain=function(context)
   local world=context and context.world
   local ow=Game and Game.overworld
   if not groundEcologyEnabled() then
     if #events>0 then clear() end
     return
   end
   if not (servicesReady and world and ow and ow.map and ow.player) then return end
   if mapId~=ow.map.id then
     clear();mapId=ow.map.id
     clock=RESPAWN_MIN+rnd01()*(RESPAWN_MAX-RESPAWN_MIN)
   end
   if not biome(ow.map) then
     if #events>0 then clear() end
     return
   end

   local dt=(context.frame and context.frame.dt) or 1/60

   -- Each event now updates independently.
   for i=#events,1,-1 do
     local ev=events[i]
     event=ev
     if not ev.battlePause then
       ev.age=(ev.age or 0)+dt
       if ev.kind=="play" then alertPlayGroup(ow,world,ev) end
       if ev.playFlee then
         ev.playFleeTimer=(ev.playFleeTimer or 0)-dt
         if ev.playFleeTimer<=0 then ev.age=EVENT_LIFE+1 end
       end
       for _,m in ipairs(ev.members or {}) do
         local hit=touch(world,m)
         if hit and not m.contact then
           if beginBattle(ow,world,m,ev) then return end
         elseif not hit then
           m.contact=false
         end
       end
       for _,m in ipairs(ev.members or {}) do updateMember(ow,m,dt,ev) end
     end
     for _,m in ipairs(ev.members or {}) do draw(m) end
     if (ev.age or 0)>EVENT_LIFE or #(ev.members or {})==0 then
       for _,m in ipairs(ev.members or {}) do destroyMember(m) end
       table.remove(events,i)
     end
   end
   event=nil

   clock=clock-dt
   if clock<=0 then
     if #events<MAX_EVENTS and rnd01()<EVENT_CHANCE then spawn(ow,world) end
     clock=RESPAWN_MIN+rnd01()*(RESPAWN_MAX-RESPAWN_MIN)
   end
  end},
  invalidate=function() clear();mapId=nil end,
 dispose=function() clear();if BLACK and BLACK.release then pcall(BLACK.release,BLACK) end;BLACK=nil end,
}
local h,err=comp.register(spec)
if not h then error("RUMBLE_GROUND_ECOLOGY registration failed: "..tostring(err),0) end
mod.exports.rumble_ground_ecology={api=1,clear=clear}


-- Shared ecology snapshot for flying hunters. FlyingOverworld may inspect live
-- play groups without taking ownership of them.
_G.RUMBLE_GROUND_ECOLOGY=_G.RUMBLE_GROUND_ECOLOGY or {}
_G.RUMBLE_GROUND_ECOLOGY.events=function() return events end
_G.RUMBLE_GROUND_ECOLOGY.playGroups=function()
  local out={}
  for _,e in ipairs(events) do
    if e.kind=="play" and not e.battlePause then out[#out+1]=e end
  end
  return out
end

_G.RUMBLE_GROUND_ECOLOGY.enabled=groundEcologyEnabled
