local H={0.7,1,2,0.6,1.1,1.7,0.5,1,1.6,0.3,0.7,1.1,0.3,0.6,1,0.3,1.1,1.5,0.3,0.7,0.3,1.2,2,3.5,0.4,0.8,0.6,1,0.4,0.8,1.3,0.5,0.9,1.4,0.6,1.3,0.6,1.1,0.5,1,0.8,1.6,0.5,0.8,1.2,0.3,1,1,1.5,0.2,0.7,0.4,1,0.8,1.7,0.5,1,0.7,1.9,0.6,1,1.3,0.9,1.3,1.5,0.8,1.5,1.6,0.7,1,1.7,0.9,1.6,0.4,1,1.4,1,1.7,1.2,1.6,0.3,1,0.8,1.4,1.1,1.7,0.9,1.2,0.3,1.5,1.3,1.6,1.5,1.4,8.8,1,1.6,0.4,1.3,0.5,1.2,0.4,2,0.4,1,1.5,1.4,1.2,0.6,1.2,1,1.9,1.1,1.3,1.5,0.4,1.2,0.6,1.3,0.8,1.1,1.3,1.5,1.4,1.1,1.3,1.5,1.4,0.9,6.5,2.5,0.3,0.3,1,0.8,0.9,0.8,0.4,1,0.5,1.3,1.8,2.1,1.7,1.6,2,1.8,4,2.2,2,0.4}

local S={}
S.ANCHOR_METERS=0.6

-- Final visual size system:
-- SMALL   = 1.00x
-- MEDIUM  = 1.30x
-- LARGE   = 1.50x
-- SPECIAL = 2.00x (Onix + Gyarados only)
-- Mew     = 0.90x override
--
-- These multipliers are applied on top of the original automatic/base-mesh
-- sizing curve. They do not use raw mesh height as the final displayed height.

function S.heightMeters(species)
  return H[tonumber(species) or 4] or S.ANCHOR_METERS
end

-- Manual overrides requested by the user.
local FORCE_SMALL={
  [2]=true, -- Ivysaur
  [5]=true, -- Charmeleon
  [8]=true, -- Wartortle
  [58]=true, -- Growlithe (already <=0.9m, explicit for clarity)
}

local FORCE_MEDIUM={
  [24]=true,  -- Arbok
  [30]=true,  -- Nidorina
  [40]=true,  -- Wigglytuff
  [105]=true, -- Marowak
  [113]=true, -- Chansey
  [148]=true, -- Dragonair
}

local FORCE_LARGE={
  [18]=true, -- Pidgeot: explicit so Pidgey < Pidgeotto < Pidgeot
  [22]=true, -- Fearow
}

local SPECIAL={
  [95]=true,  -- Onix
  [130]=true, -- Gyarados
}

function S.overworldClass(species)
  species=tonumber(species) or 4

  if species==151 then return "MEW" end
  if SPECIAL[species] then return "SPECIAL" end
  if FORCE_LARGE[species] then return "LARGE" end
  if FORCE_MEDIUM[species] then return "MEDIUM" end
  if FORCE_SMALL[species] then return "SMALL" end

  local m=S.heightMeters(species)

  -- Revised buckets:
  -- 0.2-0.9m = SMALL
  -- 1.0-1.6m = MEDIUM
  -- 1.7m+ = LARGE
  --
  -- Arbok/Dragonair are manually brought down to MEDIUM above.
  -- Onix/Gyarados are manually moved to SPECIAL above.
  if m<=0.9 then return "SMALL" end
  if m<=1.6 then return "MEDIUM" end
  return "LARGE"
end

function S.relative(species)
  local class=S.overworldClass(species)
  if class=="MEW" then return 0.90 end
  if class=="SMALL" then return 1.00 end
  if class=="MEDIUM" then return 1.30 end
  if class=="LARGE" then return 1.50 end
  if class=="SPECIAL" then return 2.00 end
  return 1.00
end

-- Battle and overworld use the same four-bucket scale now.
function S.loreRelative(species)
  return S.relative(species)
end

function S.overworldRelative(species)
  return S.relative(species)
end

S.SPECIAL=SPECIAL
S.FORCE_SMALL=FORCE_SMALL
S.FORCE_MEDIUM=FORCE_MEDIUM
S.FORCE_LARGE=FORCE_LARGE

return S
