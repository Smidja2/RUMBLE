local V = ...
local B = {}

local slots = { player=nil, enemy=nil }
local lastBattler = { player=nil, enemy=nil }
local installed = false
local hostMod, provider, API
local originals = {}
local lastTime = nil

local BLACK_TEXTURE=nil
local function blackTexture()
  if BLACK_TEXTURE then return BLACK_TEXTURE end
  if not (love and love.image and love.graphics and love.image.newImageData and love.graphics.newImage) then return nil end
  local ok,data=pcall(love.image.newImageData,1,1)
  if not ok or not data then return nil end
  pcall(data.setPixel,data,0,0,0,0,0,1)
  local ok2,img=pcall(love.graphics.newImage,data)
  if ok2 and img then BLACK_TEXTURE=img end
  return BLACK_TEXTURE
end

local function outlineEnabled()
  if API and type(API.outlineEnabled)=="function" then
    local ok,v=pcall(API.outlineEnabled)
    if ok then return v~=false end
  end
  return true
end

local function battleEnabled()
  if API and type(API.battleSceneEnabled)=="function" then
    local ok,v=pcall(API.battleSceneEnabled)
    if ok then return v~=false end
  end
  return true
end

local function log(level, fmt, ...)
  local L=V.log
  if L and type(L[level])=="function" then pcall(L[level],L,fmt,...) end
end

local function dexOf(context, battler)
  local battle=context and context.battle
  local game=(battle and battle.game) or (context and context.game)
  local species=battler and battler.mon and battler.mon.species
  local def=game and game.data and game.data.pokemon and species and game.data.pokemon[species]
  return def and def.dex or nil
end

local function fxHidden(battle,battler)
  if not (battle and battler and type(battle.fxHidden)=="function") then return false end
  local ok,v=pcall(battle.fxHidden,battle,battler)
  return ok and v and true or false
end

local function showingTrainer(battle,side)
  if not battle then return false end
  if side=="enemy" then return battle.showEnemyTrainer and battle.trainerPic and true or false end
  return battle.showPlayerBack and battle.playerBackPic and true or false
end

local function sideVisible(battle,side)
  if not battle or showingTrainer(battle,side) then return false end
  if side=="enemy" then
    return battle.enemy and battle.enemy.sprite
      and not battle.enemyHidden and not battle.enemySendingOut
      and not fxHidden(battle,battle.enemy) and true or false
  end
  return battle.player and battle.player.sprite
    and not battle.safari and not battle.demo and not battle.sendingOut
    and not fxHidden(battle,battle.player) and true or false
end

local function battlerFor(context,side)
  local battle=context and context.battle
  return battle and (side=="player" and battle.player or battle.enemy) or nil
end

local function destroySide(side)
  local a=slots[side]
  if a then pcall(a.destroy,a) end
  slots[side]=nil
  lastBattler[side]=nil
end

local function syncSide(context,side)
  if not battleEnabled() then
    destroySide(side)
    return nil
  end
  local battle=context and context.battle
  local battler=battlerFor(context,side)
  if not battler or showingTrainer(battle,side) then
    if slots[side] then destroySide(side) end
    return nil
  end
  local dex=dexOf(context,battler)
  if not dex then
    if slots[side] then destroySide(side) end
    return nil
  end
  local a=slots[side]
  if not a or a.model.species~=dex or lastBattler[side]~=battler then
    destroySide(side)
    local made,err=API.createActor(dex,{manual=true,visible=true,fullLore=true})
    if not made then
      log("warn","Rumble battle model unavailable: side=%s dex=%s error=%s",tostring(side),tostring(dex),tostring(err))
      return nil
    end
    a=made
    slots[side]=a
    lastBattler[side]=battler
    a:setAnimation("entrance")
  end
  a:setVisible(sideVisible(battle,side))
  return a
end

local function faceVector(context,side)
  local arena=context and context.arena
  local own=arena and arena[side]
  local other=arena and arena[side=="player" and "enemy" or "player"]
  if own and other then return other[1]-own[1],other[2]-own[2] end
  return 0, side=="player" and -1 or 1
end

local function drawWorld3D(actor,context,side)
  if not (actor and actor.visible and context) then return false end
  local cell=context.arena and context.arena[side]
  if not cell then return false end

  -- drawWorld is invoked by Dramaless from inside the active Voxel3D scene.
  -- Keep the Rumble mesh in true 3D so the GPU performs perspective-correct
  -- texture interpolation.  The old standalone bridge projected every vertex
  -- to screen-space first; LOVE then interpolated UVs affinely, which visibly
  -- slid/warped face, eye and body textures across angled polygons.
  local hostLib=hostMod and hostMod.exports and hostMod.exports.lib
  local Voxel3D=hostLib and type(hostLib.require)=="function" and hostLib.require("Voxel3D") or nil
  if not (Voxel3D and type(Voxel3D.draw)=="function") then return false end

  local ground=tonumber(context.groundY) or 0
  local fx,fz=faceVector(context,side)
  local yaw=math.atan2(fx,fz)
  actor:setPosition(cell[1],ground,cell[2])
  actor:setYaw(yaw)
  actor.rig:skin(yaw)
  local matrix=actor:matrix()

  if type(Voxel3D.seams)=="function" then pcall(Voxel3D.seams,false) end
  if type(Voxel3D.glass)=="function" then pcall(Voxel3D.glass,false) end

  local drew=false

  -- Toon outline: expanded black shell first, depth-tested but not written.
  -- The real model immediately covers the interior, leaving only a clean rim.
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
      local ok=pcall(Voxel3D.draw,part.mesh,part.texture,matrix,0,matrix)
      if ok then drew=true end
    end
  end

  if type(Voxel3D.glass)=="function" then pcall(Voxel3D.glass,true) end
  if type(Voxel3D.seams)=="function" then pcall(Voxel3D.seams,true) end
  return drew
end

local function stepActors(context)
  syncSide(context,"enemy")
  syncSide(context,"player")
  local now=(love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
  local dt=lastTime and math.max(0,math.min(.1,now-lastTime)) or 1/60
  lastTime=now
  for _,side in ipairs({"enemy","player"}) do
    local a=slots[side]
    if a then pcall(a.update,a,dt) end
  end
end

local function sideOf(battle,battler)
  if not battle or not battler then return nil end
  if battler==battle.player then return "player" end
  if battler==battle.enemy then return "enemy" end
end

local function installBattleHooks()
  local ok,BattleState=pcall(require,"src.battle.BattleState")
  if not (ok and BattleState) or BattleState.rumbleImporterBattleHook then return end
  BattleState.rumbleImporterBattleHook=true
  if type(BattleState.performMove)=="function" then
    local inner=BattleState.performMove
    BattleState.performMove=function(self,user,...)
      local side=sideOf(self,user); local a=side and slots[side]
      if a then a:setAnimation("attack") end
      return inner(self,user,...)
    end
  end
  if type(BattleState.startGrowIn)=="function" then
    local inner=BattleState.startGrowIn
    BattleState.startGrowIn=function(self,battler,...)
      local side=sideOf(self,battler); local a=side and slots[side]
      if a then a:setAnimation("entrance") end
      return inner(self,battler,...)
    end
  end
  if type(BattleState.onFaint)=="function" then
    local inner=BattleState.onFaint
    BattleState.onFaint=function(self,battler,...)
      local side=sideOf(self,battler); local a=side and slots[side]
      if a then a:setAnimation("faint") end
      return inner(self,battler,...)
    end
  end
end

function B.install(host,api)
  if installed then return true end
  hostMod,API=host,api
  provider=host and host.exports and host.exports.voxelCardProvider
  if type(provider)~="table" then return false,"Dramaless voxelCardProvider export unavailable" end
  originals.begin=provider.begin
  originals.update=provider.update
  originals.drawWorld=provider.drawWorld
  originals.covers=provider.covers
  originals.showing=provider.showing
  originals.center=provider.center
  originals.footprint=provider.footprint
  originals.finish=provider.finish
  originals.invalidate=provider.invalidate

  provider.begin=function(self,context,...)
    destroySide("player"); destroySide("enemy"); lastTime=nil
    if not battleEnabled() then
      return type(originals.begin)=="function" and originals.begin(self,context,...) or true
    end
    local r=true
    if type(originals.begin)=="function" then r=originals.begin(self,context,...) end
    stepActors(context)
    return r
  end
  provider.update=function(self,context,...)
    if not battleEnabled() then
      destroySide("player"); destroySide("enemy"); lastTime=nil
      if type(originals.update)=="function" then return originals.update(self,context,...) end
      return
    end
    if type(originals.update)=="function" then pcall(originals.update,self,context,...) end
    stepActors(context)
  end
  provider.drawWorld=function(self,context,...)
    if not battleEnabled() then
      destroySide("player"); destroySide("enemy"); lastTime=nil
      return type(originals.drawWorld)=="function" and originals.drawWorld(self,context,...) or false
    end
    stepActors(context)
    local de=drawWorld3D(slots.enemy,context,"enemy")
    local dp=drawWorld3D(slots.player,context,"player")
    -- If neither Rumble side could draw, preserve Dramaless's native cards.
    if not (de or dp) and type(originals.drawWorld)=="function" then
      return originals.drawWorld(self,context,...)
    end
    provider._rumbleDrawn={enemy=de,player=dp}
    return de or dp
  end
  provider.covers=function(self,context,side)
    local d=provider._rumbleDrawn
    if d and d[side] then return true end
    return type(originals.covers)=="function" and originals.covers(self,context,side) or false
  end
  provider.showing=function(self,context,side)
    local a=slots[side]
    if a and a.visible then return true end
    return type(originals.showing)=="function" and originals.showing(self,context,side) or false
  end
  provider.center=function(self,context,side)
    local a=slots[side]; local cell=context and context.arena and context.arena[side]
    if a and cell then
      return {cell[1],(tonumber(context.groundY) or 0)+(a.model.displayHeightLore or API.targetHeight(a.model.height or 1))*.5,cell[2]}
    end
    return type(originals.center)=="function" and originals.center(self,context,side) or nil
  end
  provider.footprint=function(self,context,side)
    local a=slots[side]; local cell=context and context.arena and context.arena[side]
    if a and cell then
      local h=a.model.displayHeightLore or API.targetHeight(a.model.height or 1)
      return {x=cell[1],y=tonumber(context.groundY) or 0,z=cell[2],radius=math.max(3,h*.35),height=h}
    end
    return type(originals.footprint)=="function" and originals.footprint(self,context,side) or nil
  end
  provider.finish=function(self,...)
    destroySide("player"); destroySide("enemy"); lastTime=nil; provider._rumbleDrawn=nil
    if type(originals.finish)=="function" then return originals.finish(self,...) end
  end
  provider.invalidate=function(self,...)
    destroySide("player"); destroySide("enemy"); lastTime=nil; provider._rumbleDrawn=nil
    if type(originals.invalidate)=="function" then return originals.invalidate(self,...) end
  end
  installBattleHooks()
  installed=true
  log("info","Rumble battle bridge installed on Dramaless voxelCardProvider")
  return true
end

return B
