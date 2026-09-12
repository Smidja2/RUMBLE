local V = ...
local B = {}
local installed=false
local slots={player=nil,enemy=nil}
local lastBattler={player=nil,enemy=nil}
local API,Voxel3D,OverworldBattle
local lastTime=nil
local BLACK_TEXTURE=nil

local function log(level,fmt,...)
  local L=V.log
  if L and type(L[level])=="function" then pcall(L[level],L,fmt,...) end
end

local function liveGame()
  local ok,g=pcall(function() return V.mod.game end)
  if ok and type(g)=="table" then return g end
  local ok2,G=pcall(require,"src.core.Game")
  return ok2 and G or nil
end

local function currentBattle()
  local g=liveGame()
  local top=g and g.stack and g.stack.top and g.stack:top()
  return top
end

local function blackTexture()
  if BLACK_TEXTURE then return BLACK_TEXTURE end
  if not (love and love.image and love.graphics and love.image.newImageData and love.graphics.newImage) then return nil end
  local ok,data=pcall(love.image.newImageData,1,1)
  if not ok or not data then return nil end
  pcall(data.setPixel,data,0,0,0,0,0,1)
  local ok2,img=pcall(love.graphics.newImage,data)
  if ok2 then BLACK_TEXTURE=img end
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

local function battlerFor(battle,side)
  if not battle then return nil end
  return side=="player" and battle.player or battle.enemy
end

local function dexOf(battle,battler)
  local game=(battle and battle.game) or liveGame()
  local species=battler and battler.mon and battler.mon.species
  local def=game and game.data and game.data.pokemon and species and game.data.pokemon[species]
  return def and def.dex or tonumber(species)
end

local function showingTrainer(battle,side)
  if not battle then return false end
  if side=="enemy" then return battle.showEnemyTrainer and battle.trainerPic and true or false end
  return battle.showPlayerBack and battle.playerBackPic and true or false
end

local function sideVisible(battle,side)
  if not battle or showingTrainer(battle,side) then return false end
  local b=battlerFor(battle,side)
  if not b then return false end
  if side=="enemy" then return not battle.enemyHidden and not battle.enemySendingOut end
  return not battle.safari and not battle.demo and not battle.sendingOut
end

local function destroySide(side)
  local a=slots[side]
  if a then pcall(a.destroy,a) end
  slots[side]=nil; lastBattler[side]=nil
end

local function syncSide(battle,side)
  if not battleEnabled() then
    destroySide(side)
    return nil
  end
  local battler=battlerFor(battle,side)
  if not battler or showingTrainer(battle,side) then destroySide(side); return nil end
  local dex=dexOf(battle,battler)
  if not dex then destroySide(side); return nil end
  local a=slots[side]
  if not a or not a.model or a.model.species~=dex or lastBattler[side]~=battler then
    destroySide(side)
    local made,err=API.createActor(dex,{manual=true,visible=true,fullLore=true})
    if not made then log("warn","Potato battle: Rumble model unavailable for %s dex=%s: %s",side,tostring(dex),tostring(err)); return nil end
    a=made; slots[side]=a; lastBattler[side]=battler
    a:setAnimation("entrance")
  end
  a:setVisible(sideVisible(battle,side))
  return a
end

local function step(battle)
  syncSide(battle,"enemy"); syncSide(battle,"player")
  local now=(love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
  local dt=lastTime and math.max(0,math.min(.1,now-lastTime)) or 1/60
  lastTime=now
  for _,side in ipairs({"enemy","player"}) do local a=slots[side]; if a then pcall(a.update,a,dt) end end
end

local function drawActor(actor,side,arena)
  if not (actor and actor.visible and arena and Voxel3D and type(Voxel3D.draw)=="function") then return false end
  local own=side=="player" and arena.player or arena.enemy
  local other=side=="player" and arena.enemy or arena.player
  if not own then return false end
  local fx,fz=0,(side=="player" and -1 or 1)
  if other then fx,fz=other[1]-own[1],other[2]-own[2] end
  local yaw=math.atan2(fx,fz)
  local groundY=0
  if arena.map and type(arena.map.heightAt)=="function" then
    local okh,h=pcall(arena.map.heightAt,arena.map,own[1],own[2])
    if okh and tonumber(h) then groundY=tonumber(h) end
  end
  actor:setPosition(own[1],groundY,own[2]); actor:setYaw(yaw); actor.rig:skin(yaw)
  local matrix=actor:matrix()
  if type(Voxel3D.seams)=="function" then pcall(Voxel3D.seams,false) end
  if type(Voxel3D.glass)=="function" then pcall(Voxel3D.glass,false) end
  local black=blackTexture()
  if outlineEnabled() and black and love and love.graphics and love.graphics.setDepthMode then
    pcall(love.graphics.setDepthMode,"lequal",false)
    for _,part in ipairs(actor.rig.parts or {}) do if part.outlineMesh then pcall(Voxel3D.draw,part.outlineMesh,black,matrix,0,matrix) end end
    pcall(love.graphics.setDepthMode,"lequal",true)
  end
  local drew=false
  for _,part in ipairs(actor.rig.parts or {}) do
    if part.mesh and part.texture then if pcall(Voxel3D.draw,part.mesh,part.texture,matrix,0,matrix) then drew=true end end
  end
  if type(Voxel3D.glass)=="function" then pcall(Voxel3D.glass,true) end
  if type(Voxel3D.seams)=="function" then pcall(Voxel3D.seams,true) end
  return drew
end

local function sideOf(self,battler)
  if not self or not battler then return nil end
  if battler==self.player then return "player" end
  if battler==self.enemy then return "enemy" end
end

local function installHooks()
  local ok,BattleState=pcall(require,"src.battle.BattleState")
  if not (ok and BattleState) or BattleState.rumblePotatoHook then return end
  BattleState.rumblePotatoHook=true
  if type(BattleState.performMove)=="function" then
    local inner=BattleState.performMove
    BattleState.performMove=function(self,user,...)
      local side=sideOf(self,user); local a=side and slots[side]; if a then a:setAnimation("attack") end
      return inner(self,user,...)
    end
  end
  if type(BattleState.startGrowIn)=="function" then
    local inner=BattleState.startGrowIn
    BattleState.startGrowIn=function(self,battler,...)
      local side=sideOf(self,battler); local a=side and slots[side]; if a then a:setAnimation("entrance") end
      return inner(self,battler,...)
    end
  end
  if type(BattleState.onFaint)=="function" then
    local inner=BattleState.onFaint
    BattleState.onFaint=function(self,battler,...)
      local side=sideOf(self,battler); local a=side and slots[side]; if a then a:setAnimation("faint") end
      return inner(self,battler,...)
    end
  end
end

function B.install(host,api)
  if installed then return true end
  API=api
  local lib=host and host.exports and host.exports.lib
  if not (lib and type(lib.require)=="function") then return false,"Potato lib export unavailable" end
  local okv,v=pcall(lib.require,"Voxel3D"); if not okv or not v then return false,"Potato Voxel3D unavailable" end
  Voxel3D=v
  local oko,o=pcall(lib.require,"OverworldBattle"); if not oko or not o then return false,"Potato OverworldBattle unavailable" end
  OverworldBattle=o

  if type(OverworldBattle.textures)=="function" and not OverworldBattle.rumbleTexturesHook then
    OverworldBattle.rumbleTexturesHook=true
    local innerTextures=OverworldBattle.textures
    OverworldBattle.textures=function(battle)
      local out=innerTextures(battle)
      if not battle then return out end
      if not battleEnabled() then
        destroySide("player"); destroySide("enemy"); lastTime=nil
        return out
      end
      step(battle)
      if type(out)=="table" then
        if slots.enemy and slots.enemy.visible then out.enemy=nil end
        if slots.player and slots.player.visible then out.player=nil end
      end
      return out
    end
  end

  if type(Voxel3D.endScene)=="function" and not Voxel3D.rumblePotatoBattleEndScene then
    Voxel3D.rumblePotatoBattleEndScene=true
    local innerEnd=Voxel3D.endScene
    Voxel3D.endScene=function(...)
      local arena=nil
      if type(OverworldBattle.arena)=="function" then local ok,a=pcall(OverworldBattle.arena); if ok then arena=a end end
      if arena and battleEnabled() then
        local battle=currentBattle()
        if battle then step(battle) end
        if slots.enemy and slots.enemy.visible then drawActor(slots.enemy,"enemy",arena) end
        if slots.player and slots.player.visible then drawActor(slots.player,"player",arena) end
      end
      return innerEnd(...)
    end
  end

  installHooks()
  installed=true
  log("info","Rumble PotatoVoxel battle bridge installed")
  return true
end

return B
