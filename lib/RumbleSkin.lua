local V = ...
local S={}

local function mul(a,b)
  local o={}
  for r=0,3 do
    for c=0,3 do
      local s=0
      for k=0,3 do
        s=s+a[r*4+k+1]*b[k*4+c+1]
      end
      o[r*4+c+1]=s
    end
  end
  return o
end

local function m43(v)
  return {
    v[1],v[2],v[3],v[4],
    v[5],v[6],v[7],v[8],
    v[9],v[10],v[11],v[12],
    0,0,0,1
  }
end

local function trans(v)
  return {
    1,0,0,v[1],
    0,1,0,v[2],
    0,0,1,v[3],
    0,0,0,1
  }
end

local function scl(v)
  return {
    v[1],0,0,0,
    0,v[2],0,0,
    0,0,v[3],0,
    0,0,0,1
  }
end

local function quat(q)
  local x,y,z,w=q[1],q[2],q[3],q[4]
  local n=math.sqrt(x*x+y*y+z*z+w*w)

  if n>0 then
    x,y,z,w=x/n,y/n,z/n,w/n
  end

  return {
    1-2*(y*y+z*z),2*(x*y-w*z),2*(x*z+w*y),0,
    2*(x*y+w*z),1-2*(x*x+z*z),2*(y*z-w*x),0,
    2*(x*z-w*y),2*(y*z+w*x),1-2*(x*x+y*y),0,
    0,0,0,1
  }
end

local function sample(c,f,d)
  if not c then return d end
  if c.constant then return c.constant end

  local v=c.values
  if not v or #v==0 then return d end

  return v[(math.floor(f)%#v)+1]
end

local function point(m,p)
  return
    m[1]*p[1]+m[2]*p[2]+m[3]*p[3]+m[4],
    m[5]*p[1]+m[6]*p[2]+m[7]*p[3]+m[8],
    m[9]*p[1]+m[10]*p[2]+m[11]*p[3]+m[12]
end

local function dir(m,p)
  return
    m[1]*p[1]+m[2]*p[2]+m[3]*p[3],
    m[5]*p[1]+m[6]*p[2]+m[7]*p[3],
    m[9]*p[1]+m[10]*p[2]+m[11]*p[3]
end

function S.pose(parsed,clip,frame)
  local worlds,skins={},{}

  for _,b in ipairs(parsed.skeleton.bones) do
    local ch=(clip and clip.channels[b.name]) or {}

    local dt=sample(ch.translation,frame,{0,0,0})
    local dq=sample(ch.rotation,frame,{0,0,0,1})
    local ds=sample(ch.scale,frame,{1,1,1})

    local localM=mul(
      mul(
        mul(trans(dt),m43(b.localM)),
        quat(dq)
      ),
      scl(ds)
    )

    local world=localM

    if b.parent>=0 then
      world=mul(worlds[b.parent],localM)
    end

    worlds[b.joint]=world
    skins[b.joint]=mul(world,m43(b.inverse))
  end

  return worlds,skins
end

-- Rumble cel/toon shading.
local function toonShade(nx,ny,nz)
  local raw=0.7725 + 0.06*nx + 0.225*ny + 0.11*nz

  if raw < 0.76 then
    return 0.52
  elseif raw < 0.90 then
    return 0.76
  else
    return 1.00
  end
end

local function smoothShadingEnabled()
  local api=rawget(_G,"RUMBLE_API")
  if api and type(api.modelSmoothingEnabled)=="function" then
    local ok,v=pcall(api.modelSmoothingEnabled)
    if ok then return v==true end
  end
  return false
end

-- inflate:
-- 0 = normal Pokémon mesh
-- positive value = push vertices outward along skinned normals
function S.shapeVertices(parsed,shape,clip,frame,inflate)

  local _,skins=S.pose(parsed,clip,frame)
  local out={}

  inflate=inflate or 0

  for i,v in ipairs(shape.vertices) do
    local px,py,pz=0,0,0
    local nx,ny,nz=0,0,0

    if #v.joints==0 then

      px,py,pz=
        v.pos[1],
        v.pos[2],
        v.pos[3]

      nx,ny,nz=
        v.normal[1],
        v.normal[2],
        v.normal[3]

    else

      for j=1,#v.joints do
        local w=v.weights[j] or 0

        if w>0 then
          local m=skins[v.joints[j]]

          if m then
            local x,y,z=point(m,v.pos)
            local a,b,c=dir(m,v.normal)

            px=px+x*w
            py=py+y*w
            pz=pz+z*w

            nx=nx+a*w
            ny=ny+b*w
            nz=nz+c*w
          end
        end
      end

    end

    local L=math.sqrt(nx*nx+ny*ny+nz*nz)

    if L>0 then
      nx=nx/L
      ny=ny/L
      nz=nz/L
    end

    -- Push ONLY the outline mesh outward.
    if inflate~=0 then
      px=px+nx*inflate
      py=py+ny*inflate
      pz=pz+nz*inflate
    end

    out[i]={
      px,
      py,
      pz,
      v.uv[1],
      v.uv[2],
      toonShade(nx,ny,nz)
    }
  end

  -- ORIGINAL keeps v1.3.9's deliberately flat per-triangle toon bands.
  -- SMOOTH keeps each vertex's normal-derived shade instead; the GPU then
  -- interpolates those values across the triangle, visually smoothing the
  -- existing Rumble mesh without changing geometry or animation.
  if not smoothShadingEnabled() then
    for i=1,#out,3 do
      if out[i+2] then
        local q=(out[i][6]+out[i+1][6]+out[i+2][6])/3
        local band
        if q < 0.64 then band=0.52 elseif q < 0.88 then band=0.76 else band=1.00 end
        out[i][6],out[i+1][6],out[i+2][6]=band,band,band
      end
    end
  end

  return out
end

return S