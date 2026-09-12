local mod = ...
local OptionRows = require("src.ui.OptionRows")

local RumbleSettingsMenu = {}
RumbleSettingsMenu.__index = RumbleSettingsMenu
RumbleSettingsMenu.isOpaque = true

local FOLLOWER_KEY="follower_count"
local WILDS_KEY="overworld_wilds"
local FLYING_KEY="flying_overworld"
local OUTLINE_KEY="rumble_toon_outline"
local SCALE_KEY="rumble_lore_scale"
local GROUND_ECOLOGY_KEY="rumble_ground_ecology"
local FLYING_ECOLOGY_KEY="rumble_flying_ecology"
local BATTLE_SCENE_KEY="rumble_battle_scene"
local SMOOTH_KEY="rumble_model_smoothing"

local function readOpt(game,key,default)
  if mod.options and type(mod.options.get)=="function" then
    local ok,v=pcall(mod.options.get,mod.options,key)
    if ok and v~=nil then return v end
  end
  local loader=game and game.mods
  local stored=loader and loader.modOptions and loader.modOptions[mod.id]
  if stored and stored[key]~=nil then return stored[key] end
  local opts=game and game.save and game.save.options
  stored=opts and opts.modOptions and opts.modOptions[mod.id]
  if stored and stored[key]~=nil then return stored[key] end
  return default
end

local function writeOpt(game,key,value)
  local opts=game and game.save and game.save.options
  if opts then
    opts.modOptions=opts.modOptions or {}
    opts.modOptions[mod.id]=opts.modOptions[mod.id] or {}
    opts.modOptions[mod.id][key]=value
  end
  local loader=game and game.mods
  if loader then
    loader.modOptions=loader.modOptions or {}
    loader.modOptions[mod.id]=loader.modOptions[mod.id] or {}
    loader.modOptions[mod.id][key]=value
  end
  if game and game.writeOptions then pcall(game.writeOptions,game) end
  if mod.events and type(mod.events.emit)=="function" then
    pcall(mod.events.emit,mod.events,"mod.options_changed",
      {mod=mod.id,key=key,value=value})
  end
end

local function boolValue(game,key,default)
  local v=readOpt(game,key,default)
  return v~=false and v~=0 and v~="NO" and v~="OFF"
end

local function rows(game)
  return {
    {
      id=mod.id..":"..FOLLOWER_KEY,
      label="RUMBLE FOLLOWERS",
      value=function()
        local n=math.floor(tonumber(readOpt(game,FOLLOWER_KEY,1)) or 1)
        if n<0 then n=0 elseif n>6 then n=6 end
        return n==0 and "OFF" or tostring(n)
      end,
      step=function(g,dir)
        local n=math.floor(tonumber(readOpt(g,FOLLOWER_KEY,1)) or 1)
        n=n+(dir or 1)
        if n>6 then n=0 elseif n<0 then n=6 end
        writeOpt(g,FOLLOWER_KEY,n)
        return true
      end,
    },
    {
      id=mod.id..":"..WILDS_KEY,
      label="RUMBLE OVERWORLD WILDS",
      value=function() return boolValue(game,WILDS_KEY,true) and "YES" or "NO" end,
      step=function(g,_dir)
        writeOpt(g,WILDS_KEY,not boolValue(g,WILDS_KEY,true))
        return true
      end,
    },
    {
      id=mod.id..":"..FLYING_KEY,
      label="RUMBLE FLYING OVERWORLD",
      value=function() return boolValue(game,FLYING_KEY,true) and "YES" or "NO" end,
      step=function(g,_dir)
        writeOpt(g,FLYING_KEY,not boolValue(g,FLYING_KEY,true))
        return true
      end,
    },
    {
      id=mod.id..":"..OUTLINE_KEY,
      label="RUMBLE TOON OUTLINE",
      value=function() return boolValue(game,OUTLINE_KEY,true) and "ON" or "OFF" end,
      step=function(g,_dir)
        writeOpt(g,OUTLINE_KEY,not boolValue(g,OUTLINE_KEY,true))
        return true
      end,
    },
    {
  id=mod.id..":"..GROUND_ECOLOGY_KEY,
  label="GROUND ECOLOGY",
  value=function() return boolValue(game,GROUND_ECOLOGY_KEY,true) and "ON" or "OFF" end,
  step=function(g,_dir)
    writeOpt(g,GROUND_ECOLOGY_KEY,not boolValue(g,GROUND_ECOLOGY_KEY,true))
    return true
  end,
},
{
  id=mod.id..":"..FLYING_ECOLOGY_KEY,
  label="FLYING ECOLOGY",
  value=function() return boolValue(game,FLYING_ECOLOGY_KEY,true) and "ON" or "OFF" end,
  step=function(g,_dir)
    writeOpt(g,FLYING_ECOLOGY_KEY,not boolValue(g,FLYING_ECOLOGY_KEY,true))
    return true
  end,
},
{
      id=mod.id..":"..BATTLE_SCENE_KEY,
      label="RUMBLE BATTLE SCENE",
      value=function() return boolValue(game,BATTLE_SCENE_KEY,true) and "ON" or "OFF" end,
      step=function(g,_dir)
        writeOpt(g,BATTLE_SCENE_KEY,not boolValue(g,BATTLE_SCENE_KEY,true))
        return true
      end,
    },
    {
      id=mod.id..":"..SMOOTH_KEY,
      label="RUMBLE MODEL SHADING",
      value=function() return boolValue(game,SMOOTH_KEY,false) and "SMOOTH" or "ORIGINAL" end,
      step=function(g,_dir)
        writeOpt(g,SMOOTH_KEY,not boolValue(g,SMOOTH_KEY,false))
        return true
      end,
    },
    {
      id=mod.id..":"..SCALE_KEY,
      label="RUMBLE LORE SCALE",
      value=function() return boolValue(game,SCALE_KEY,true) and "ON" or "OFF" end,
      step=function(g,_dir)
        writeOpt(g,SCALE_KEY,not boolValue(g,SCALE_KEY,true))
        return true
      end,
    },
  }
end

local function syncScroll(self)
  self.scroll=OptionRows.clampScroll(self.index,self.scroll or 0,
                                     #self.rows,#self.rows+1)
end

local function click(game)
  if not (game and game.data) then return end
  pcall(require("src.core.Sound").play,game.data,"Press_AB")
end

function RumbleSettingsMenu.new(game)
  local self=setmetatable({
    game=game,rows={},index=1,scroll=0,title="RUMBLE SETTINGS"
  },RumbleSettingsMenu)
  self:refresh()
  return self
end

function RumbleSettingsMenu:refresh()
  local old=self.rows[self.index]
  local oldId=old and old.id
  self.rows=rows(self.game)
  self.index=1
  if oldId then
    for i,row in ipairs(self.rows) do
      if row.id==oldId then self.index=i break end
    end
  end
  syncScroll(self)
end

function RumbleSettingsMenu:wantsFillScale() return true end
function RumbleSettingsMenu:drawsWidescreen() return true end

function RumbleSettingsMenu:update(_dt)
  local input=self.game.input
  local cancelRow=#self.rows+1
  if input:wasPressed("up") then
    self.index=self.index>1 and self.index-1 or cancelRow
  elseif input:wasPressed("down") then
    self.index=self.index<cancelRow and self.index+1 or 1
  elseif input:wasPressed("b") or input:wasPressed("start") then
    click(self.game)
    self.game.stack:pop()
    return
  else
    local row=self.rows[self.index]
    local changed=false
    if input:wasPressed("a") and self.index==cancelRow then
      click(self.game)
      self.game.stack:pop()
      return
    elseif row and input:wasPressed("left") and row.step then
      changed=row.step(self.game,-1) and true or false
    elseif row and (input:wasPressed("right") or input:wasPressed("a")) and row.step then
      changed=row.step(self.game,1) and true or false
    end
    if changed then self:refresh() end
  end
  syncScroll(self)
end

function RumbleSettingsMenu:drawPanel()
  OptionRows.draw(self.game,self.rows,self.index,self.scroll or 0,
                  "CANCEL",#self.rows+1)
end

function RumbleSettingsMenu:draw()
  self:drawPanel()
end

function RumbleSettingsMenu:drawWidescreen(winW,winH)
  local G=love.graphics
  G.setColor(1,1,1,1)
  G.rectangle("fill",0,0,winW,winH)
  local ok,Chrome=pcall(require,"src.ui.gen2.Chrome")
  if ok and Chrome and Chrome.fitScale then
    local scale=Chrome.fitScale(winW,winH)
    G.push()
    G.translate(Chrome.fitOrigin(winW,winH,scale))
    G.scale(scale,scale)
    self:drawPanel()
    G.pop()
  else
    self:drawPanel()
  end
end

return RumbleSettingsMenu
