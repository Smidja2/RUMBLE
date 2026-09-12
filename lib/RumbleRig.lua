local V = ...
local Skin = V.require("RumbleSkin")

local R = {}
R.__index = R

local FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexShade", "float", 1 },
}

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

local function smoothShadingEnabled()
  local api=rawget(_G,"RUMBLE_API")
  if api and type(api.modelSmoothingEnabled)=="function" then
    local ok,v=pcall(api.modelSmoothingEnabled)
    if ok then return v==true end
  end
  return false
end

local function toonShade(nx,ny,nz)
  local L=math.sqrt(nx*nx+ny*ny+nz*nz)
  if L>0 then nx,ny,nz=nx/L,ny/L,nz/L end
  local raw=0.7725+0.06*nx+0.225*ny+0.11*nz
  if raw<0.76 then return 0.52 elseif raw<0.90 then return 0.76 else return 1.00 end
end

local function replacementRows(parsed,meta,clip,frame,inflate)
  local _,skins=Skin.pose(parsed,clip,frame)
  local out={}
  inflate=inflate or 0

  for i,v in ipairs(meta or {}) do
    local px,py,pz=0,0,0
    local nx,ny,nz=0,0,0
    local total=0

    if not v.joints or #v.joints==0 then
      px,py,pz=v.p[1],v.p[2],v.p[3]
      nx,ny,nz=v.n[1],v.n[2],v.n[3]
    else
      for j=1,#v.joints do
        local joint=v.joints[j]
        local w=(v.w and v.w[j]) or 0
        local m=joint and skins[joint]
        if m and w>0 then
          local x,y,z=point(m,v.p)
          local a,b,c=dir(m,v.n)
          px,py,pz=px+x*w,py+y*w,pz+z*w
          nx,ny,nz=nx+a*w,ny+b*w,nz+c*w
          total=total+w
        end
      end
      if total<=0 then
        px,py,pz=v.p[1],v.p[2],v.p[3]
        nx,ny,nz=v.n[1],v.n[2],v.n[3]
      elseif math.abs(total-1)>0.0001 then
        px,py,pz=px/total,py/total,pz/total
        nx,ny,nz=nx/total,ny/total,nz/total
      end
    end

    local L=math.sqrt(nx*nx+ny*ny+nz*nz)
    if L>0 then nx,ny,nz=nx/L,ny/L,nz/L end

    if inflate~=0 then
      px,py,pz=px+nx*inflate,py+ny*inflate,pz+nz*inflate
    end

    out[i]={
      px,py,pz,
      v.uv[1],1-v.uv[2],
      toonShade(nx,ny,nz)
    }
  end

  if not smoothShadingEnabled() then
    for i=1,#out,3 do
      if out[i+2] then
        local q=(out[i][6]+out[i+1][6]+out[i+2][6])/3
        local band=(q<0.64 and 0.52) or (q<0.88 and 0.76) or 1.00
        out[i][6],out[i+1][6],out[i+2][6]=band,band,band
      end
    end
  end
  return out
end

local function newReplacement(self,repl)
  local byName={}
  for _,b in ipairs(self.model.parsed.skeleton.bones or {}) do byName[b.name]=b.joint end

  -- Replacement meshes and the packed Rumble skeleton occasionally disagree
  -- about which X side is called LEFT/RIGHT.  That makes one animated wing
  -- travel through the torso even though the mesh and animation are valid.
  -- Resolve paired wing labels from their bind-pose X side instead of assuming
  -- the names use the same handedness. This only changes LEFT_WING/RIGHT_WING.
  local wingMap={LEFT_WING=byName.LEFT_WING,RIGHT_WING=byName.RIGHT_WING}
  if wingMap.LEFT_WING and wingMap.RIGHT_WING then
    local worlds=select(1,Skin.pose(self.model.parsed,nil,0)) or {}
    local lx=(worlds[wingMap.LEFT_WING] and worlds[wingMap.LEFT_WING][4]) or 0
    local rx=(worlds[wingMap.RIGHT_WING] and worlds[wingMap.RIGHT_WING][4]) or 0
    local sumL,nL,sumR,nR=0,0,0,0
    for _,gg in ipairs(repl.groups or {}) do
      for _,vv in ipairs(gg.vertices or {}) do
        for _,jn in ipairs(vv.j or {}) do
          if jn=="LEFT_WING" then sumL=sumL+(vv.p[1] or 0);nL=nL+1
          elseif jn=="RIGHT_WING" then sumR=sumR+(vv.p[1] or 0);nR=nR+1 end
        end
      end
    end
    local ml=nL>0 and sumL/nL or 0
    local mr=nR>0 and sumR/nR or 0
    local function sign(x) return x>1e-5 and 1 or (x<-1e-5 and -1 or 0) end
    -- Swap only when both pairs give a clear opposite-side match.
    if sign(ml)~=0 and sign(mr)~=0 and sign(lx)~=0 and sign(rx)~=0
       and sign(ml)==sign(rx) and sign(mr)==sign(lx)
       and sign(ml)~=sign(lx) then
      wingMap.LEFT_WING,wingMap.RIGHT_WING=wingMap.RIGHT_WING,wingMap.LEFT_WING
    end
  end

  for _,g in ipairs(repl.groups or {}) do
    local meta={}
    for i,v in ipairs(g.vertices or {}) do
      local joints={}
      for j,name in ipairs(v.j or {}) do
        if name=="LEFT_WING" or name=="RIGHT_WING" then joints[j]=wingMap[name]
        else joints[j]=byName[name] end
      end
      meta[i]={p=v.p,n=v.n,uv=v.uv,joints=joints,w=v.w}
    end

    local rows=replacementRows(self.model.parsed,meta,nil,0,0)
    local outlineRows=replacementRows(self.model.parsed,meta,nil,0,self.outlineInflate)
    local ok,mesh=pcall(love.graphics.newMesh,FORMAT,rows,"triangles","dynamic")
    local okO,outlineMesh=pcall(love.graphics.newMesh,FORMAT,outlineRows,"triangles","dynamic")
    if ok and mesh then
      if g.image and mesh.setTexture then pcall(mesh.setTexture,mesh,g.image) end
      if okO and outlineMesh and g.image and outlineMesh.setTexture then pcall(outlineMesh.setTexture,outlineMesh,g.image) end
      self.parts[#self.parts+1]={
        mesh=mesh,outlineMesh=(okO and outlineMesh) or nil,
        replacement=true,meta=meta,texture=g.image,
        rows=rows,outlineRows=outlineRows,
      }
    end
  end
end

local function newLegacy(self)
  for _,obj in ipairs(self.model.parsed.objects or {}) do
    local shape=self.model.parsed.shapes[obj.shape]
    if shape and shape.vertices and #shape.vertices>0 then
      local rows=Skin.shapeVertices(self.model.parsed,shape,nil,0,0)
      local outlineRows=Skin.shapeVertices(self.model.parsed,shape,nil,0,self.outlineInflate)
      local ok,mesh=pcall(love.graphics.newMesh,FORMAT,rows,"triangles","dynamic")
      local okO,outlineMesh=pcall(love.graphics.newMesh,FORMAT,outlineRows,"triangles","dynamic")
      if ok and mesh then
        local texture=self.model.texturesByName[obj.texture]
        if texture and mesh.setTexture then pcall(mesh.setTexture,mesh,texture) end
        if okO and outlineMesh and texture and outlineMesh.setTexture then pcall(outlineMesh.setTexture,outlineMesh,texture) end
        self.parts[#self.parts+1]={
          mesh=mesh,outlineMesh=(okO and outlineMesh) or nil,
          shape=shape,texture=texture,rows=rows,outlineRows=outlineRows,
        }
      end
    end
  end
end

function R.new(model)
  if not (model and model._rumble and love and love.graphics and love.graphics.newMesh) then return nil end
  local self=setmetatable({model=model,parts={},frameAt=0,clip=nil,lo=0,hi=model.height or 1,girth=0},R)
  local modelHeight=math.max(tonumber(model.height) or 1,0.001)
  self.outlineInflate=modelHeight*0.035

  if model.replacement and model.replacement.groups and #model.replacement.groups>0 then
    newReplacement(self,model.replacement)
  end
  if #self.parts==0 then newLegacy(self) end
  if #self.parts==0 then return nil end

  self:pose(1,0,true)
  self:skin(0)
  return self
end

function R:release()
  for _,p in ipairs(self.parts) do
    if p.mesh and p.mesh.release then pcall(p.mesh.release,p.mesh) end
    if p.outlineMesh and p.outlineMesh.release then pcall(p.outlineMesh.release,p.outlineMesh) end
  end
  self.parts={}
end

function R:pose(animIndex,frame,wrap)
  local a=self.model.anims[animIndex or 1] or self.model.anims[1]
  self.clip=a and a.clip or nil
  local frames=(a and a.frames) or 1
  local f=frame or 0
  if wrap and frames>0 then f=f%frames elseif f>=frames then f=math.max(0,frames-1) end
  self.frameAt=f
  return true
end

function R:skin(yaw)
  local lo,hi,girth=math.huge,-math.huge,0
  for _,p in ipairs(self.parts) do
    local ok,rows
    if p.replacement then
      ok,rows=pcall(replacementRows,self.model.parsed,p.meta,self.clip,self.frameAt,0)
    else
      ok,rows=pcall(Skin.shapeVertices,self.model.parsed,p.shape,self.clip,self.frameAt,0)
    end
    if ok and type(rows)=="table" and #rows>0 then
      p.rows=rows
      pcall(p.mesh.setVertices,p.mesh,rows)
    end

    if p.outlineMesh then
      local okO,outlineRows
      if p.replacement then
        okO,outlineRows=pcall(replacementRows,self.model.parsed,p.meta,self.clip,self.frameAt,self.outlineInflate)
      else
        okO,outlineRows=pcall(Skin.shapeVertices,self.model.parsed,p.shape,self.clip,self.frameAt,self.outlineInflate)
      end
      if okO and type(outlineRows)=="table" and #outlineRows>0 then
        p.outlineRows=outlineRows
        pcall(p.outlineMesh.setVertices,p.outlineMesh,outlineRows)
      end
    end

    for _,v in ipairs(p.rows or {}) do
      local x,y,z=v[1],v[2],v[3]
      if y<lo then lo=y end
      if y>hi then hi=y end
      local q=math.sqrt(x*x+z*z)
      if q>girth then girth=q end
    end
  end
  if lo==math.huge then lo,hi=0,self.model.height or 1 end
  self.lo,self.hi,self.girth=lo,hi,girth
  return true
end

function R:posedBounds() return self.lo,self.hi,self.girth end

function R:drawPackets(modelMatrix,phase,owner,seq0)
  local out,seq={},seq0 or 1
  for _,p in ipairs(self.parts) do
    out[#out+1]={
      schemaVersion=1,
      cacheKey=("rumble:%d:%d"):format(self.model.species or 0,seq),
      kind="mesh", owner=owner or "rumble.main", phase=phase,
      sequence=seq, sortKey=("rumble:%04d:%04d"):format(self.model.species or 0,seq),
      material="companion.default", mesh=p.mesh, model=modelMatrix,
    }
    seq=seq+1
  end
  return out,seq
end

return R
