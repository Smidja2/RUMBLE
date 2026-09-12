local V = ...
local B=V.require("RumbleBinary")
local Tex=V.require("RumbleTextureCodec")
local C={}
local function materialTextures(s,mats)
  local out={}
  for mi,m in ipairs(mats) do
    local names={}
    for k=0,3 do
      local map=B.rel(s,m.offset+628+k*4)
      if map~=0 then local th=B.rel(s,map+8); if th~=0 then local no=B.rel(s,th+0x18); if no~=0 then names[#names+1]=B.cstr(s,no) end end end
    end
    out[mi-1]=names
  end
  return out
end
local function attrValue(s,base,a)
  local v={}
  for j=0,a.length-1 do
    local o=base+a.offset
    local x
    if a.format==6 then x=B.f32(s,o+j*4) elseif a.format==1 then x=B.u8(s,o+j) elseif a.format==0 then x=B.i8(s,o+j) elseif a.format==2 then x=B.i16(s,o+j*2) else error('CGFX vertex format '..tostring(a.format)) end
    v[#v+1]=x*a.scale
  end
  return v
end
local function parseVertexGroup(s,off)
  local p=off+20; local bufferLen=B.u32(s,p); local buffer=B.rel(s,p+4); p=p+8; p=p+8
  local stride=B.u32(s,p); p=p+4; local ac=B.u32(s,p); local at=B.rel(s,p+4); local attrs={}
  for i=0,ac-1 do local a=B.rel(s,at+i*4); attrs[#attrs+1]={semantic=B.u32(s,a+4),format=B.u32(s,a+36)%16,length=B.u32(s,a+40),scale=B.f32(s,a+44),offset=B.u32(s,a+48)} end
  return {bufferLen=bufferLen,buffer=buffer,stride=stride,attrs=attrs,count=math.floor(bufferLen/stride)}
end
local function vertexAt(s,vg,index)
  local row={}; local base=vg.buffer+index*vg.stride
  for _,a in ipairs(vg.attrs) do row[a.semantic]=attrValue(s,base,a) end
  return row
end
local function indices(s,desc)
  local fmt=math.floor(B.u32(s,desc)/2)%2; local len=B.u32(s,desc+8); local io=B.rel(s,desc+12); local t={}
  if fmt==0 then for i=0,len-1 do t[#t+1]=B.u8(s,io+i) end else for i=0,len/2-1 do t[#t+1]=B.u16(s,io+i*2) end end
  return t
end
local function parseSkeleton(s,off)
  if off==0 then return {bones={},byJoint={}} end
  local q=off+12; local name=B.cstr(s,B.rel(s,q)); q=q+4; q=q+8; local count=B.u32(s,q); q=q+4; local dict=B.rel(s,q)
  local bones,byJoint={},{}
  for _,de in ipairs(B.dict(s,dict)) do
    local r=de.offset; local bn=B.cstr(s,B.rel(s,r)); r=r+4; local flags=B.u32(s,r);r=r+4;local joint=B.u32(s,r);r=r+4;local parent=B.i32(s,r);r=r+4;r=r+16
    local scale=B.vec3(s,r);r=r+12;local rot=B.vec3(s,r);r=r+12;local trans=B.vec3(s,r);r=r+12
    local localM=B.m43(s,r);r=r+48;local world=B.m43(s,r);r=r+48;local inverse=B.m43(s,r)
    local b={name=bn,joint=joint,parent=parent,localM=localM,world=world,inverse=inverse}; bones[#bones+1]=b;byJoint[joint]=b
  end
  table.sort(bones,function(a,b)return a.joint<b.joint end)
  return {name=name,bones=bones,byJoint=byJoint,count=count}
end
function C.parse(s)
  assert(s:sub(1,4)=='CGFX','not CGFX')
  local modelCount=B.u32(s,0x1c); local modelDict=B.rel(s,0x20); assert(modelCount>0,'CGFX has no model')
  local texCount=B.u32(s,0x24); local texDict=B.rel(s,0x28)
  local textures={}; if texCount>0 then for _,e in ipairs(B.dict(s,texDict)) do local o=e.offset; textures[e.name]={name=e.name,height=B.u32(s,o+0x18),width=B.u32(s,o+0x1c),format=B.u32(s,o+0x34),length=B.u32(s,o+0x44),data=s:sub(B.rel(s,o+0x48)+1,B.rel(s,o+0x48)+B.u32(s,o+0x44))} end end
  local me=B.dict(s,modelDict)[1]; local mo=me.offset; local p=mo; local typ=B.u32(s,p);p=p+4;assert(s:sub(p+1,p+4)=='CMDL');p=p+4;p=p+4;local modelName=B.cstr(s,B.rel(s,p));p=p+4;p=p+8
  p=p+4;p=p+4;p=p+4;p=p+4;local agc=B.u32(s,p);p=p+4;local ago=B.rel(s,p);p=p+4;p=p+36+96
  local objectCount=B.u32(s,p);local objectTable=B.rel(s,p+4);p=p+8;local matCount=B.u32(s,p);local matDict=B.rel(s,p+4);p=p+8;local shapeCount=B.u32(s,p);local shapeTable=B.rel(s,p+4);p=p+8
  local nodeCount=B.u32(s,p);local nodeDict=B.rel(s,p+4);p=p+8;p=p+12;local skeletonOff=(math.floor(typ/0x80)%2==1) and B.rel(s,p) or 0
  local mats=B.dict(s,matDict); local matTex=materialTextures(s,mats); local skeleton=parseSkeleton(s,skeletonOff)
  local shapes={}
  for si=0,shapeCount-1 do
    local so=B.rel(s,shapeTable+si*4); local q=so+16; q=q+8+4+4+12; local faceCount=B.u32(s,q);local faceTable=B.rel(s,q+4);q=q+8;q=q+4;local vgCount=B.u32(s,q);local vgTable=B.rel(s,q+4)
    local vg=assert(vgCount>0 and parseVertexGroup(s,B.rel(s,vgTable)) or nil,'shape has no vertex group')
    local expanded={}; local minY,maxY=1e9,-1e9
    for fi=0,faceCount-1 do
      local gp=B.rel(s,faceTable+fi*4); local nn=B.u32(s,gp);local no=B.rel(s,gp+4);local skin=B.u32(s,gp+8);local mc=B.u32(s,gp+12);local mt=B.rel(s,gp+16);local nodes={}
      for j=0,nn-1 do nodes[#nodes+1]=B.u32(s,no+j*4) end
      for mi=0,mc-1 do local main=B.rel(s,mt+mi*4);local dc=B.u32(s,main);local dt=B.rel(s,main+4)
        for di=0,dc-1 do local desc=B.rel(s,dt+di*4); for _,idx in ipairs(indices(s,desc)) do
          local rv=vertexAt(s,vg,idx); local pos=rv[0] or {0,0,0};local normal=rv[1] or {0,1,0};local uv=rv[4] or {0,0};local bis=rv[7];local bws=rv[8];local joints,weights={},{}
          if bis and #bis>0 then for j=1,#bis do local li=math.floor(bis[j]+0.5)+1; if nodes[li] then joints[#joints+1]=nodes[li];weights[#weights+1]=(bws and bws[j]) or (j==1 and 1 or 0) end end
          elseif #nodes>0 then joints[1]=nodes[1];weights[1]=1 end
          minY=math.min(minY,pos[2]);maxY=math.max(maxY,pos[2]);expanded[#expanded+1]={pos=pos,normal=normal,uv=uv,joints=joints,weights=weights,skin=skin}
        end end
      end
    end
    shapes[si]={vertices=expanded,minY=minY,maxY=maxY}
  end
  local objects={}; for i=0,objectCount-1 do local o=B.rel(s,objectTable+i*4);local shape=B.u32(s,o+0x18);local mat=B.u32(s,o+0x1c);objects[#objects+1]={shape=shape,material=mat,texture=(matTex[mat] or {})[1]} end
  local lo,hi=1e9,-1e9; for _,sh in pairs(shapes) do lo=math.min(lo,sh.minY);hi=math.max(hi,sh.maxY) end
  return {name=modelName,textures=textures,materials=mats,objects=objects,shapes=shapes,skeleton=skeleton,height=math.max(0.001,hi-lo),minY=lo,maxY=hi}
end
function C.buildTextures(parsed)
  local out={}; for name,t in pairs(parsed.textures) do out[name]=Tex.decode(t.data,t.width,t.height,t.format) end; return out
end
return C
