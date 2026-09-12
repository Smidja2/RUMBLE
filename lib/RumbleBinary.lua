local V = ...
local B={}
local floor=math.floor
local function byte(s,i) return string.byte(s,i+1) or 0 end
function B.u8(s,o) return byte(s,o) end
function B.i8(s,o) local v=byte(s,o); return v>=128 and v-256 or v end
function B.u16(s,o) return byte(s,o)+byte(s,o+1)*256 end
function B.i16(s,o) local v=B.u16(s,o); return v>=32768 and v-65536 or v end
function B.u32(s,o) return byte(s,o)+byte(s,o+1)*256+byte(s,o+2)*65536+byte(s,o+3)*16777216 end
function B.i32(s,o) local v=B.u32(s,o); return v>=2147483648 and v-4294967296 or v end
function B.u64(s,o) return B.u32(s,o)+B.u32(s,o+4)*4294967296 end
function B.rel(s,o) local v=B.i32(s,o); if v==0 then return 0 end; return o+v end
function B.cstr(s,o)
  local e=o
  while e<#s and byte(s,e)~=0 do e=e+1 end
  return s:sub(o+1,e)
end
function B.ascii16(s,o,n)
  local t={}
  for i=0,n-1,2 do local c=byte(s,o+i); if c~=0 then t[#t+1]=string.char(c) end end
  return table.concat(t)
end
function B.f32(s,o)
  local u=B.u32(s,o)
  local sign=(u>=2147483648) and -1 or 1
  if u>=2147483648 then u=u-2147483648 end
  local exp=floor(u/8388608); local frac=u-exp*8388608
  if exp==255 then return frac==0 and sign*math.huge or 0/0 end
  if exp==0 then return sign*(frac/8388608)*2^-126 end
  return sign*(1+frac/8388608)*2^(exp-127)
end
function B.vec3(s,o) return {B.f32(s,o),B.f32(s,o+4),B.f32(s,o+8)} end
function B.m43(s,o)
  local t={}; for i=0,11 do t[#t+1]=B.f32(s,o+i*4) end; return t
end
function B.dict(s,o)
  assert(s:sub(o+1,o+4)=='DICT','expected DICT at '..tostring(o))
  local n=B.u32(s,o+8); local out={}
  for i=0,n-1 do
    local p=o+0x1c+i*0x10
    out[#out+1]={name=B.cstr(s,B.rel(s,p+8)), offset=B.rel(s,p+12)}
  end
  return out
end
return B
