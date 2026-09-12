local mod = ...
local Game = require("src.core.Game")
local V={mod=mod,path=mod.path}
local modules={}
local function chunkFor(rel)
  local source=mod:read(rel)
  if not source then error("RUMBLE_MAIN: missing "..rel,0) end
  local chunk,err=load(source,"@"..mod.path.."/"..rel)
  if not chunk then error("RUMBLE_MAIN compile error in "..rel..": "..tostring(err),0) end
  return chunk
end
function V.require(name)
  if modules[name]~=nil then return modules[name] end
  local value=chunkFor("lib/"..name..".lua")(V)
  modules[name]=value
  return value
end
V.log = mod.log

local Pack=V.require("RumblePack")
local Rig=V.require("RumbleRig")
local Replacement=V.require("RumbleReplacement")
local Mat4=V.require("Mat4")
local actors={}

-- Unified Rumble option: renderer-provided model shadows.
local SHADOW_KEY="rumble_shadow"
local OUTLINE_KEY="rumble_toon_outline"
local SCALE_KEY="rumble_lore_scale"
local BATTLE_SCENE_KEY="rumble_battle_scene"
local SMOOTH_KEY="rumble_model_smoothing"
local function storedOption(key,default)
  local loader=Game and Game.mods
  local stored=loader and loader.modOptions and loader.modOptions[mod.id]
  if stored and stored[key]~=nil then return stored[key] end

  local opts=Game and Game.save and Game.save.options
  stored=opts and opts.modOptions and opts.modOptions[mod.id]
  if stored and stored[key]~=nil then return stored[key] end

  return default
end

local function shadowEnabled()
  local v=storedOption(SHADOW_KEY,true)
  return v~=false and v~=0 and v~="OFF" and v~="NO"
end

local function outlineEnabled()
  local v=storedOption(OUTLINE_KEY,true)
  return v~=false and v~=0 and v~="OFF" and v~="NO"
end
local function loreScaleEnabled()
  local v=storedOption(SCALE_KEY,true)
  return v~=false and v~=0 and v~="OFF" and v~="NO"
end
local function battleSceneEnabled()
  local v=storedOption(BATTLE_SCENE_KEY,true)
  return v~=false and v~=0 and v~="OFF" and v~="NO"
end
local function modelSmoothingEnabled()
  local v=storedOption(SMOOTH_KEY,false)
  return v==true or v==1 or v=="ON" or v=="YES" or v=="SMOOTH"
end
local function setShadow(game,value)
  local opts=game and game.save and game.save.options
  if opts then
    opts.modOptions=opts.modOptions or {}; opts.modOptions[mod.id]=opts.modOptions[mod.id] or {}
    opts.modOptions[mod.id][SHADOW_KEY]=value
  end
  local loader=game and game.mods
  if loader then
    loader.modOptions=loader.modOptions or {}; loader.modOptions[mod.id]=loader.modOptions[mod.id] or {}
    loader.modOptions[mod.id][SHADOW_KEY]=value
  end
  if game and game.writeOptions then pcall(game.writeOptions,game) end
end

local nextId=1
local companionHandle=nil
local rendererMod=nil
local rendererId=nil
local Voxel3D=nil

-- Lightweight companion adapter for renderers that expose Voxel3D but do not
-- expose the native voxel_companion service (PotatoVoxel, Ascendant, Gen2).
local localSpecs={}
local localLastWorld=nil
local localCompanion=nil

local function liveGame()
  local ok,g=pcall(function() return mod.game end)
  if ok and type(g)=="table" then return g end
  local ok2,G=pcall(require,"src.core.Game")
  if ok2 and type(G)=="table" then return G end
  return nil
end

local function worldSnapshot()
  local g=liveGame()
  local ow=g and (g.overworld or g.world)
  local map=ow and ow.map
  local p=ow and ow.player
  if not (map and p) then return nil end

  -- Gen1Recomp/Potato entities are fundamentally 2D: px/py are world-pixel
  -- coordinates and cellX/cellY are map cells.  Rumble companion mods use
  -- x/z for the horizontal ground plane and y strictly for vertical height.
  -- Never feed the engine's map-Y into Rumble's vertical Y axis.
  local cx=tonumber(p.cellX)
  local cz=tonumber(p.cellY) or tonumber(p.cellZ)
  local px=tonumber(p.px)
  local pz=tonumber(p.py)
  local x=tonumber(p.x)
  local z=tonumber(p.z)
  if px~=nil then x=px+8 elseif x==nil and cx~=nil then x=cx*16+8 end
  if pz~=nil then z=pz+8 elseif z==nil and cz~=nil then z=cz*16+8 end

  return {
    id=tostring(map.id or map.name or map),
    map=map,
    player={
      x=x or 0,
      y=tonumber(p.worldY) or tonumber(p.height) or 0,
      z=z or 0,
      cellX=cx,
      cellY=cz, -- compatibility alias for older specs
      cellZ=cz, -- Rumble follower/wild/flying ground-plane axis
      facing=p.facing or "down",
    },
  }
end

local function makeLocalCompanion(host,lib)
  if localCompanion then return localCompanion end
  local OverworldBattle=nil
  if lib and type(lib.require)=="function" then
    local okb,b=pcall(lib.require,"OverworldBattle")
    if okb then OverworldBattle=b end
  end
  localCompanion={api=1}
  function localCompanion.register(spec)
    if type(spec)~="table" then return nil,"invalid companion spec" end
    localSpecs[#localSpecs+1]=spec
    table.sort(localSpecs,function(a,b) return (tonumber(a.priority) or 0)<(tonumber(b.priority) or 0) end)
    if type(spec.attach)=="function" then pcall(spec.attach,{}) end
    local handle={}
    function handle.dispose()
      for i=#localSpecs,1,-1 do if localSpecs[i]==spec then table.remove(localSpecs,i) break end end
      if type(spec.dispose)=="function" then pcall(spec.dispose) end
    end
    return handle
  end

  if Voxel3D and type(Voxel3D.endScene)=="function" and not Voxel3D.rumbleUniversalEndScene then
    Voxel3D.rumbleUniversalEndScene=true
    local inner=Voxel3D.endScene
    Voxel3D.endScene=function(...)
      local staged=false
      if OverworldBattle and type(OverworldBattle.arena)=="function" then
        local oka,a=pcall(OverworldBattle.arena)
        staged=oka and a~=nil
      end
      if not staged then
        local world=worldSnapshot()
        if world then
          if localLastWorld~=world.id then
            localLastWorld=world.id
            for _,spec in ipairs(localSpecs) do if type(spec.worldChanged)=="function" then pcall(spec.worldChanged,world) end end
          end
          local dt=1/60
          local okdt,g=pcall(function() return liveGame() end)
          if okdt and g then
            dt=tonumber(g.dt) or tonumber(g.deltaTime) or dt
          end
          dt=math.max(0,math.min(0.1,dt))
          local context={world=world,frame={dt=dt}}
          for _,spec in ipairs(localSpecs) do
            if type(spec.update)=="function" then pcall(spec.update,context.frame) end
            -- Gameplay companion specs draw themselves directly through Voxel3D.
            -- Skip the importer's generic packet renderer to avoid duplicate actors.
            if spec.id~="rumble.main" and spec.id~="rumble.importer" and spec.render and type(spec.render.opaque_after_terrain)=="function" then
              pcall(spec.render.opaque_after_terrain,context)
            end
          end
        end
      end
      return inner(...)
    end
  end
  return localCompanion
end

local function hostApi()
  if not (mod and type(mod.find)=="function") then return nil,"mod.find unavailable" end
  for _,id in ipairs({"BATTLE_ART_VOXEL_FORK","potato_voxel","VOXEL_ASCENDANT","BATTLE_ART_VOXEL_GEN2","DRAMALESS_SHAPE"}) do
    local ok,host=pcall(mod.find,id)
    if ok and host then
      local lib=host.exports and host.exports.lib
      local direct=host.exports and host.exports.Voxel3D
      local v3d=nil
      if lib and type(lib.require)=="function" then
        local okv,v=pcall(lib.require,"Voxel3D")
        if okv and v and type(v.draw)=="function" then v3d=v end
      elseif direct and type(direct.draw)=="function" then
        v3d=direct
      end
      local api=host.exports and host.exports.voxel_companion

      -- Battle Art Voxel Fork 1.10.4 has its own strict companion dispatcher.
      -- Rumble's v1.3.9 gameplay systems predate that dispatcher and render
      -- their follower/wild/flying actors directly through Voxel3D. Registering
      -- them into the Fork's native provider can leave the callbacks inactive
      -- even though battle integration itself works.
      --
      -- For Battle Art, keep using its PUBLIC Voxel3D implementation, but run
      -- Rumble's existing v1.3.9 overworld feature callbacks through Rumble's
      -- lightweight endScene adapter. This preserves the exact follower/wild/
      -- ecology code path that already works with Potato/Dramaless.
      if id=="BATTLE_ART_VOXEL_FORK" and v3d then
        Voxel3D=v3d
        rendererMod,rendererId=host,id
        return makeLocalCompanion(host,lib)
      end

      if api and tonumber(api.api)==1 and type(api.register)=="function" then
        Voxel3D=v3d or Voxel3D
        rendererMod,rendererId=host,id
        return api
      end
      if v3d then
        Voxel3D=v3d
        rendererMod,rendererId=host,id
        return makeLocalCompanion(host,lib)
      end
    end
  end
  return nil,"no supported voxel renderer found"
end

local function targetHeight(raw)
  local h=raw or 1
  local wh=13.5*math.sqrt(math.max(h,0.05))
  if wh<6 then wh=6 elseif wh>20 then wh=20 end
  return wh
end

local Actor={}; Actor.__index=Actor
function Actor:setPosition(x,y,z) self.x=x or self.x; self.y=y or self.y; self.z=z or self.z; return self end
function Actor:setYaw(yaw) self.yaw=yaw or 0; return self end
function Actor:setPitch(pitch) self.pitch=pitch or 0; return self end
function Actor:setRoll(roll) self.roll=roll or 0; return self end
function Actor:setScale(scale) self.scale=scale; return self end
function Actor:setAnimation(name)
  local map={idle=1,walk=2,run=2,attack=2,faint=3,entrance=4}
  self.anim=map[name] or tonumber(name) or 1
  self.animName=type(name)=="string" and name or nil
  self.time=0
  return self
end
function Actor:setVisible(v) self.visible=v~=false; return self end
function Actor:destroy()
  if self.dead then return end
  self.dead=true; actors[self.id]=nil
  if self.rig then self.rig:release() end
end
function Actor:update(dt)
  self.time=self.time+(dt or 0)
  local a=self.model.anims[self.anim] or self.model.anims[1]
  local name=self.animName
  local oneShot=(name=="attack" or name=="entrance" or name=="faint")
  local hold=(name=="faint")
  if oneShot and a and self.time>=a.seconds then
    if hold then
      self.time=math.max(0,a.seconds-1/30)
    else
      self.anim,self.animName,self.time=1,"idle",0
      a=self.model.anims[1]
    end
  end
  self.rig:pose(self.anim,self.time*30,not oneShot)
  self.rig:skin(self.yaw)
end
function Actor:matrix()
  local rawH=math.max(self.model.height or 1,1e-6)
  local autoScale=nil
  if loreScaleEnabled() then
    autoScale=self.fullLore and self.model.loreScale or self.model.overworldScale
  end
  -- Scale OFF restores the original v1.2.0 automatic sizing curve.
  local k=self.scale or autoScale or (targetHeight(rawH)/rawH)
  local floor=self.model.floor or 0
  local rot=Mat4.mul(Mat4.mul(Mat4.rotateY(self.yaw),Mat4.rotateX(self.pitch or 0)),Mat4.rotateZ(self.roll or 0))
  return Mat4.mul(Mat4.mul(Mat4.mul(Mat4.translate(self.x,self.y,self.z),rot),Mat4.scale(k,k,k)),Mat4.translate(0,-floor,0))
end
function Actor:render(context,phase,seq)
  if self.dead or not self.visible then return seq end
  local packets,nextSeq=self.rig:drawPackets(self:matrix(),phase,"rumble.main",seq)
  for _,cmd in ipairs(packets) do
    cmd.cacheKey=("rumble:%d:%d:%d"):format(self.id,self.model.species or 0,cmd.sequence)
    context.draw.mesh(cmd,context)
  end
  return nextSeq
end

local API={api=1,version="0.9.0"}
function API.available() return Pack.available() end
function API.load(species,shiny) return Pack.load(species,shiny) end
function API.createActor(species,opts)
  opts=opts or {}
  local model=Pack.load(species,opts.shiny==true)
  if not model then return nil,"Rumble model unavailable for species "..tostring(species) end
  local rig=Rig.new(model); if not rig then return nil,"could not create Rumble rig" end
  local id=nextId; nextId=nextId+1
  local a=setmetatable({id=id,model=model,rig=rig,x=opts.x or 0,y=opts.y or 0,z=opts.z or 0,yaw=opts.yaw or 0,pitch=opts.pitch or 0,roll=opts.roll or 0,scale=opts.scale,fullLore=opts.fullLore==true,anim=1,animName="idle",time=0,visible=opts.visible~=false,manual=opts.manual==true},Actor)
  actors[id]=a
  return a
end
function API.destroyActor(actor) if actor and actor.destroy then actor:destroy() end end
API.Mat4=Mat4
API.targetHeight=targetHeight
API.Voxel3D=function() return Voxel3D end
API.renderer=function() return rendererId end
API.shadowEnabled=shadowEnabled
API.outlineEnabled=outlineEnabled
API.loreScaleEnabled=loreScaleEnabled
API.battleSceneEnabled=battleSceneEnabled
API.modelSmoothingEnabled=modelSmoothingEnabled
function API.registerReplacementProvider(provider)
  local ok,why=Replacement.registerProvider(provider)
  if ok then Pack.invalidate() end
  return ok,why
end
function API.unregisterReplacementProvider(id)
  local ok=Replacement.unregisterProvider(id)
  if ok then Pack.invalidate() end
  return ok
end
_G.RUMBLE_API=API
mod.exports.rumble_main=API
-- Backward-compatible alias for older Rumble gameplay modules.
mod.exports.rumble_importer=API

local host,err=hostApi()
-- Export the resolved companion service through the importer so all Rumble
-- gameplay modules use one renderer-neutral registration point.
mod.exports.voxel_companion=host

-- Unified gameplay modules. Keeping the RUMBLE_MAIN id/API means Quest continues
-- to hook the same importer exactly as before.
local function loadFeature(rel)
  local source=mod:read(rel)
  if not source then error("RUMBLE_MAIN: missing embedded feature "..rel,0) end
  local chunk,err=load(source,"@"..mod.path.."/"..rel)
  if not chunk then error("RUMBLE_MAIN feature compile error in "..rel..": "..tostring(err),0) end
  return chunk(mod)
end
loadFeature("features/Follower.lua")
loadFeature("features/OverworldWilds.lua")
loadFeature("features/FlyingOverworld.lua")
loadFeature("features/GroundEcology.lua")

if host then
  local spec={
    api=1,id="rumble.main",name="Rumble Unified",version="0.9.0",priority=20,
    requires={"render_phases","world_snapshot"}, optional={},
    update=function(frame)
      local dt=(type(frame)=="table" and tonumber(frame.dt)) or 1/60
      for _,a in pairs(actors) do if not a.manual then a:update(dt) end end
    end,
    render={
      opaque_after_terrain=function(context)
        local seq=1; for _,a in pairs(actors) do seq=a:render(context,"opaque_after_terrain",seq) end
      end,
    },
    dispose=function() for _,a in pairs(actors) do if a.rig then a.rig:release() end end; actors={} end,
  }
  local ok,h=pcall(host.register,spec)
  if ok then companionHandle=h elseif mod.log then mod.log:error("Rumble Main companion registration failed: %s",tostring(h)) end
elseif mod.log then mod.log:error("Rumble Main disabled: %s",tostring(err)) end


-- Renderer-specific battle bridge. Battle Art Voxel Fork exposes a public
-- drawActors seam while its voxel camera/depth target are active.
do
  if rendererId=="BATTLE_ART_VOXEL_FORK" and rendererMod then
    local okBridge,Bridge=pcall(V.require,"RumbleBattleArtFork")
    if okBridge and Bridge then
      local ok,why=Bridge.install(rendererMod,API)
      if not ok and mod.log then mod.log:error("Rumble Battle Art Fork bridge unavailable: %s",tostring(why)) end
    elseif mod.log then
      mod.log:error("Rumble Battle Art Fork bridge load failed: %s",tostring(Bridge))
    end
  elseif rendererId=="potato_voxel" and rendererMod then
    local okBridge,Bridge=pcall(V.require,"RumblePotatoBattle")
    if okBridge and Bridge then
      local ok,why=Bridge.install(rendererMod,API)
      if not ok and mod.log then mod.log:error("Rumble Potato battle bridge unavailable: %s",tostring(why)) end
    elseif mod.log then
      mod.log:error("Rumble Potato battle bridge load failed: %s",tostring(Bridge))
    end
  elseif rendererId=="DRAMALESS_SHAPE" and rendererMod then
    local okBridge,Bridge=pcall(V.require,"RumbleBattleBridge")
    if okBridge and Bridge then
      local ok,why=Bridge.install(rendererMod,API)
      if not ok and mod.log then mod.log:error("Rumble Dramaless battle bridge unavailable: %s",tostring(why)) end
    end
  end
end
