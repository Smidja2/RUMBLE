local L={}
function L.decompress(data)
  local B=require and nil -- deliberately unused; standalone string decoder
  local function u16(o) local a,b=data:byte(o+1,o+2); return (a or 0)+(b or 0)*256 end
  local function u32(o) local a,b,c,d=data:byte(o+1,o+4); return (a or 0)+(b or 0)*256+(c or 0)*65536+(d or 0)*16777216 end
  local header=u32(0); assert(header%256==0x40,'not Nintendo LZH8 (0x40)')
  local outLen=math.floor(header/256); local pos=4
  if outLen==0 then outLen=u32(pos); pos=pos+4 end
  local bitPos, pool, left=pos,0,0
  local function bits(n)
    local out,produced=0,0
    while produced<n do
      if left==0 then pool=data:byte(bitPos+1) or error('LZH8 EOF'); left=8; bitPos=bitPos+1 end
      local take=math.min(left,n-produced)
      local div=2^(left-take); local mask=2^take
      local part=math.floor(pool/div)%mask
      out=out*mask+part; left=left-take; produced=produced+take
    end
    return out
  end
  local lengthBytes=(u16(pos)+1)*4; pos=pos+2
  local lengthTable={}; bitPos=pos; left=0; local start=pos-2; local i=1
  while bitPos-start<lengthBytes and i<1024 do lengthTable[i]=bits(9); i=i+1 end
  pos=start+lengthBytes; bitPos=pos; left=0
  local dispBytes=((data:byte(pos+1) or 0)+1)*4; pos=pos+1
  local dispTable={}; bitPos=pos; left=0; start=pos-1; i=1
  while bitPos-start<dispBytes and i<64 do dispTable[i]=bits(5); i=i+1 end
  pos=start+dispBytes; bitPos=pos; left=0
  local out={}; local decoded=0
  while decoded<outLen do
    local off=1
    while true do
      local child=bits(1); local v=lengthTable[off] or 0; local payload=v%128
      local nxt=math.floor(off/2)*2+(payload+1)*2+child
      local leafMask=child==0 and 256 or 128
      if math.floor(v/leafMask)%2==1 then
        local sym=lengthTable[nxt] or 0
        if sym<256 then
          decoded=decoded+1; out[decoded]=string.char(sym)
        else
          local run=(sym%256)+3; local doff=1
          while true do
            local dc=bits(1); local dv=dispTable[doff] or 0; local dp=dv%8
            local dnxt=math.floor(doff/2)*2+(dp+1)*2+dc
            local dmask=dc==0 and 16 or 8
            if math.floor(dv/dmask)%2==1 then
              local dl=dispTable[dnxt] or 0; local dist=0
              if dl~=0 then dist=1; for _=dl-1,1,-1 do dist=dist*2+bits(1) end end
              for _=1,run do
                if decoded>=outLen then break end
                local src=decoded-dist
                assert(src>=1,'invalid LZH8 back-reference')
                decoded=decoded+1; out[decoded]=out[src]
              end
              break
            end
            doff=dnxt
          end
        end
        break
      end
      off=nxt
    end
  end
  return table.concat(out)
end
return L
