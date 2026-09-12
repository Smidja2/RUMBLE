local V = ...
local B=V.require("RumbleBinary")
local T={}
local tile={0,1,8,9,2,3,10,11,16,17,24,25,18,19,26,27,4,5,12,13,6,7,14,15,20,21,28,29,22,23,30,31,32,33,40,41,34,35,42,43,48,49,56,57,50,51,58,59,36,37,44,45,38,39,46,47,52,53,60,61,54,55,62,63}
local lut={{2,8,-2,-8},{5,17,-5,-17},{9,29,-9,-29},{13,42,-13,-42},{18,60,-18,-60},{24,80,-24,-80},{33,106,-33,-106},{47,183,-47,-183}}
local floor=math.floor
local function band(v,mask) return v%(mask+1) end
local function rshift(v,n) return floor(v/2^n) end
local function clamp(v) if v<0 then return 0 elseif v>255 then return 255 else return v end end
local function signed3(v) return v>=4 and v-8 or v end
local function u32be8(s,o)
  local a,b,c,d=s:byte(o+1,o+4); return (a or 0)*16777216+(b or 0)*65536+(c or 0)*256+(d or 0)
end
local function etcPixel(r,g,b,x,y,bottom,tab)
  local index=x*4+y
  local b1,b2
  if index<8 then b1=floor(bottom/2^(index+24))%2; b2=floor(bottom/2^(index+7))%4>=2 and 2 or 0
  else b1=floor(bottom/2^(index+8))%2; b2=floor(bottom/2^(index-9))%4>=2 and 2 or 0 end
  local d=lut[tab+1][b1+b2+1]
  return clamp(r+d),clamp(g+d),clamp(b+d)
end
local function decodeEtcBlock(data,o)
  -- Rumble/CGFX stores each ETC color block byte-reversed before Ohana's little-endian UInt32 reads;
  -- reading the original bytes as two big-endian words is equivalent.
  local top=u32be8(data,o+4); local bottom=u32be8(data,o)
  local flip=floor(top/0x1000000)%2==1; local diff=floor(top/0x2000000)%2==1
  local r1,g1,b1,r2,g2,b2
  if diff then
    local rb=top%256; local gb=floor(top/256)%256; local bb0=floor(top/65536)%256
    local br=floor(rb/8); local bg=floor(gb/8); local bb=floor(bb0/8)
    r1=br*8+floor(br/4); g1=bg*8+floor(bg/4); b1=bb*8+floor(bb/4)
    local rr=br+signed3(top%8); local gg=bg+signed3(floor(top/256)%8); local bl=bb+signed3(floor(top/65536)%8)
    r2=clamp(rr*8+floor(rr/4)); g2=clamp(gg*8+floor(gg/4)); b2=clamp(bl*8+floor(bl/4))
  else
    local rb=top%256; local gb=floor(top/256)%256; local bb0=floor(top/65536)%256
    r1=floor(rb/16)*17; r2=(rb%16)*17; g1=floor(gb/16)*17; g2=(gb%16)*17; b1=floor(bb0/16)*17; b2=(bb0%16)*17
  end
  local tab1=floor(top/2^29)%8; local tab2=floor(top/2^26)%8; local p={}
  for y=0,3 do for x=0,3 do
    local use2=(not flip and x>=2) or (flip and y>=2)
    local r,g,bb=etcPixel(use2 and r2 or r1,use2 and g2 or g1,use2 and b2 or b1,x,y,bottom,use2 and tab2 or tab1)
    p[y*4+x+1]={r,g,bb,255}
  end end
  return p
end
local function set(im,x,y,c) local h=im:getHeight(); im:setPixel(x,h-1-y,c[1]/255,c[2]/255,c[3]/255,(c[4] or 255)/255) end

local function makeTexture(im)
  local tex=love.graphics.newImage(im)
  -- Nintendo CGFX/Rumble models frequently use tiled UVs outside the 0..1
  -- range (Charmander is a clear example). LÖVE defaults to clamp, which
  -- stretches edge texels across those polygons and makes parts look like
  -- the wrong color/texture. Rumble's samplers tile these textures.
  if tex and tex.setWrap then
    pcall(tex.setWrap,tex,"repeat","repeat")
  end
  return tex
end

function T.decode(data,w,h,fmt)
  assert(love and love.image and love.image.newImageData,'LÖVE ImageData unavailable')
  local im=love.image.newImageData(w,h)
  if fmt==12 then -- ETC1
    local blocks={}; local off=0
    for by=0,h/4-1 do for bx=0,w/4-1 do blocks[#blocks+1]=decodeEtcBlock(data,off); off=off+8 end end
    local order={}; local baseAcc,rowAcc,baseNum,rowNum=0,0,0,0; local total=(w/4)*(h/4)
    for i=0,total-1 do
      if i%(w/4)==0 and i>0 then if rowAcc<1 then rowAcc=1; rowNum=rowNum+2; baseNum=rowNum else rowAcc=0; baseNum=baseNum-2; rowNum=baseNum end end
      order[i+1]=baseNum; if baseAcc<1 then baseAcc=baseAcc+1;baseNum=baseNum+1 else baseAcc=0;baseNum=baseNum+3 end
    end
    local src=1
    for ty=0,h/4-1 do for tx=0,w/4-1 do
      local ord=order[src]+1; local block=blocks[ord]
      for y=0,3 do for x=0,3 do set(im,tx*4+x,ty*4+y,block[y*4+x+1]) end end
      src=src+1
    end end
    return makeTexture(im)
  end
  local off=0
  for ty=0,h/8-1 do for tx=0,w/8-1 do for pi=1,64 do
    local q=tile[pi]; local x=q%8; local y=floor(q/8); local c
    if fmt==3 then
      local lo,hi=data:byte(off+1,off+2); local v=(lo or 0)+(hi or 0)*256; off=off+2
      local r=floor(v/2048)%32; r=r*8+floor(r/4); local g=floor(v/32)%64; g=g*4+floor(g/16); local bb=v%32; bb=bb*8+floor(bb/4); c={r,g,bb,255}
    elseif fmt==0 then
      local a,r,g,bb=data:byte(off+1,off+4); off=off+4; c={r or 0,g or 0,bb or 0,a or 255}
    elseif fmt==7 then
      local l=data:byte(off+1) or 0; off=off+1; c={l,l,l,255}
    else error('unsupported Rumble texture format '..tostring(fmt)) end
    set(im,tx*8+x,ty*8+y,c)
  end end end
  return makeTexture(im)
end
return T
