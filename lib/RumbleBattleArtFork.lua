local V = ...
local B = {}
local installed=false
local slots={player=nil,enemy=nil}
local lastBattler={player=nil,enemy=nil}
local API,hostMod,Voxel3D,BattleScene
local lastTime=nil
local BLACK_TEXTURE=nil

local function log(level,fmt,...)
  local L=V.log
  if L and type(L[level])=="function" then pcall(L[level],L,fmt,...) end
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
  local game=(battle and battle.game) or nil
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
  if side=="enemy" then
    return not battle.enemyHidden and not battle.enemySendingOut
  end
  return not battle.safari and not battle.demo and not battle.sendingOut
end

local function destroySide(side)
  local a=slots[side]
  if a then pcall(a.destroy,a) end
  slots[side]=nil
  lastBattler[side]=nil
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
    if not made then log("warn","Rumble model unavailable for %s dex=%s: %s",side,tostring(dex),tostring(err)); return nil end
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

local function drawActor(actor,side,arena,ctx)
  if not (actor and actor.visible and arena and ctx and Voxel3D and type(Voxel3D.draw)=="function") then return false end
  local own=side=="player" and arena.player or arena.enemy
  local other=side=="player" and arena.enemy or arena.player
  if not own then return false end
  local fx,fz=0,(side=="player" and -1 or 1)
  if other then fx,fz=other[1]-own[1],other[2]-own[2] end
  local yaw=math.atan2(fx,fz)
  actor:setPosition(own[1],tonumber(ctx.groundY) or 0,own[2])
  actor:setYaw(yaw)
  actor.rig:skin(yaw)
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
  if not (ok and BattleState) or BattleState.rumbleForkHook then return end
  BattleState.rumbleForkHook=true
  if type(BattleState.performMove)=="function" then
    local inner=BattleState.performMove
    BattleState.performMove=function(self,user,...)
      local side=sideOf(self,user); local a=battleEnabled() and side and slots[side]; if a then a:setAnimation("attack") end
      return inner(self,user,...)
    end
  end
  if type(BattleState.startGrowIn)=="function" then
    local inner=BattleState.startGrowIn
    BattleState.startGrowIn=function(self,battler,...)
      local side=sideOf(self,battler); local a=battleEnabled() and side and slots[side]; if a then a:setAnimation("entrance") end
      return inner(self,battler,...)
    end
  end
  if type(BattleState.onFaint)=="function" then
    local inner=BattleState.onFaint
    BattleState.onFaint=function(self,battler,...)
      local side=sideOf(self,battler); local a=battleEnabled() and side and slots[side]; if a then a:setAnimation("faint") end
      return inner(self,battler,...)
    end
  end
end

function B.install(host,api)
  if installed then return true end
  hostMod,API=host,api
  local lib=host and host.exports and host.exports.lib
  if not (lib and type(lib.require)=="function") then return false,"Battle Art Fork lib export unavailable" end
  local okv,v=pcall(lib.require,"Voxel3D"); if not okv or not v then return false,"Voxel3D unavailable" end
  Voxel3D=v
  local okb,bs=pcall(lib.require,"BattleScene"); if not okb or not bs or type(bs.render)~="function" then return false,"BattleScene unavailable" end
  BattleScene=bs
  local original=BattleScene.render
  BattleScene.render=function(state,arena,textures,token,battle,drawActors,externalCamera,externalModelShadow)
    -- Toggle OFF: Rumble does NOTHING to the battle presentation.
    -- Battle Art Fork receives its original actor provider unchanged.
    if not battleEnabled() then
      destroySide("player")
      destroySide("enemy")
      lastTime=nil
      return original(state,arena,textures,token,battle,drawActors,externalCamera,externalModelShadow)
    end

    step(battle)
    local replaceP=slots.player and slots.player.visible
    local replaceE=slots.enemy and slots.enemy.visible

    if not (replaceP or replaceE) then
      return original(state,arena,textures,token,battle,drawActors,externalCamera,externalModelShadow)
    end

    -- Fork 1.10.4 may already pass a drawActors provider.
    -- The old 1.3.9 bridge returned immediately here, so Rumble never rendered.
    -- Take over only once BOTH Rumble battlers are valid; until then keep the
    -- host provider intact to avoid blank/duplicate battle actors.
    if drawActors and not (replaceP and replaceE) then
      return original(state,arena,textures,token,battle,drawActors,externalCamera,externalModelShadow)
    end

    local cards={}
    if textures then
      if not replaceP and textures.player then cards.player=textures.player end
      if not replaceE and textures.enemy then cards.enemy=textures.enemy end
    end

    local provider={cards=cards}
    provider.draw=function(ctx)
      if replaceE then drawActor(slots.enemy,"enemy",arena,ctx) end
      if replaceP then drawActor(slots.player,"player",arena,ctx) end
    end

    local shadowArg=externalModelShadow
    if API and type(API.shadowEnabled)=="function" and not API.shadowEnabled() then
      shadowArg=nil
    end

    return original(state,arena,textures,token,battle,provider,externalCamera,shadowArg)
  end
  installHooks()
  installed=true
  log("info","Rumble Battle Art Fork 1.10.4 direct integration installed")
  return true
end

return B
