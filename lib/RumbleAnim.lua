local V = ...
local B=V.require("RumbleBinary")
local A={}
local function qcurve(s,o)
  local start=B.f32(s,o);local finish=B.f32(s,o+4);local flags=B.u32(s,o+12);local p=o+16
  if flags%2==1 then return {constant={B.f32(s,p),B.f32(s,p+4),B.f32(s,p+8),B.f32(s,p+12)}} end
  local v={};for _=1,math.floor(finish-start+0.5) do v[#v+1]={B.f32(s,p),B.f32(s,p+4),B.f32(s,p+8),B.f32(s,p+12)};p=p+20 end;return {values=v}
end
local function vcurve(s,o)
  local start=B.f32(s,o);local finish=B.f32(s,o+4);local flags=B.u32(s,o+12);local p=o+16
  if flags%2==1 then return {constant={B.f32(s,p),B.f32(s,p+4),B.f32(s,p+8)}} end
  local v={};for _=1,math.floor(finish-start+0.5) do v[#v+1]={B.f32(s,p),B.f32(s,p+4),B.f32(s,p+8)};p=p+16 end;return {values=v}
end
function A.parse(s)
  assert(s:sub(1,4)=='CGFX','animation resource is not CGFX'); local field=0x14+8+9*8;local count=B.u32(s,field);local dict=B.rel(s,field+4);local out={}
  if count==0 then return out end
  for _,e in ipairs(B.dict(s,dict)) do local o=e.offset;local name=B.cstr(s,B.rel(s,o+8));local clip={name=name,loop=B.u32(s,o+16)~=0,frames=math.floor(B.f32(s,o+20)+0.5),channels={}};local md=B.rel(s,o+28)
    for _,m in ipairs(B.dict(s,md)) do local mo=m.offset;local flags=B.u32(s,mo);local path=B.cstr(s,B.rel(s,mo+4));local prim=B.u32(s,mo+8);local p=mo+12
      if prim==8 then local ch={}; if math.floor(flags/16)%2==1 then p=p+4 else ch.rotation=qcurve(s,B.rel(s,p));p=p+4 end; if math.floor(flags/8)%2==1 then p=p+4 else ch.translation=vcurve(s,B.rel(s,p));p=p+4 end; if math.floor(flags/32)%2==1 then p=p+4 else ch.scale=vcurve(s,B.rel(s,p));p=p+4 end;clip.channels[path]=ch end
    end
    out[name]=clip
  end
  return out
end
function A.family(modelName)
  local f=(modelName or ''):match('_([^_]+)$') or 'nomove'
  if f=='bird' then return 'bird' end
  return f
end
function A.choose(all,family,moving)
  local names
  if moving then names={'Pii_anim_'..family..'_run','Pii_anim_'..family..'_run_half','Pii_anim_'..family,'Pii_anim_'..family..'_kamae','Pii_anim_nomove_kamae'}
  else names={'Pii_anim_'..family..'_kamae','Pii_anim_'..family,'Pii_anim_nomove_kamae'} end
  for _,n in ipairs(names) do if all[n] then return n,all[n] end end
  return next(all)
end

function A.chooseState(all,family,state)
  local idleName,idle=A.choose(all,family,false)
  local runName,run=A.choose(all,family,true)
  if state=="idle" then return idleName,idle end
  if state=="attack" or state=="entrance" then return runName or idleName,run or idle end
  if state=="faint" then return idleName,idle end
  return idleName,idle
end
return A
