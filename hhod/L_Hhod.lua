local THIS_PLUGIN = "Home Heartbeat Plugin v0.01"

local HHOD_SID    = "urn:upnp-hhod-svc:serviceId:HHOD1"
local SWITCHPWR_SID = "urn:upnp-org:serviceId:SwitchPower1"

local BINARY_SCHEMA  = "urn:schemas-micasaverde-com:device:BinaryLight:1"

local DEBUG_MODE = true

local SECURITY_SID  = "urn:micasaverde-com:serviceId:SecuritySensor1"
local SWITCHPWR_SID = "urn:upnp-org:serviceId:SwitchPower1"
local HADEVICE_SID  = "urn:micasaverde-com:serviceId:HaDevice1"
local DIMMING_SID   = "urn:upnp-org:serviceId:Dimming1"
local ALARM_SID     = "urn:micasaverde-com:serviceId:AlarmPartition2"
local BINARY_SCHEMA  = "urn:schemas-micasaverde-com:device:BinaryLight:1"
local DIMMING_SCHEMA = "urn:schemas-micasaverde-com:device:DimmableLight:1"
local MOTION_SCHEMA  = "urn:schemas-micasaverde-com:device:MotionSensor:1"


local ipAddress
local ipPort = 1098
local buffer = ""
local lastNewSate = 0
local lastNewStateInterval = 60 * 3


local controller_id
local socket = require("socket")

------------------------------------------------------------
local function trim(s)
  return s:gsub("^%s*", ""):gsub("%s*$","")
end

------------------------------------------------------------  
local function log(text, level)
    luup.log("HHOD: " .. text, (level or 1))
end

------------------------------------------------------------  	
local function debug(text)
  if (DEBUG_MODE == true) then
      log((text or "<empty>"), 50)
  end
end

------------------------------------------------------------
local function sendCommand(command)
    if luup.io.write(command)==false then
        log("cannot send: " .. tostring(command),1)
        luup.set_failure(true)
        return false
    else
        debug('Wrote: ' .. command);
        return true
    end
end

------------------------------------------------------------
-- convert a 'sep' seperated string into a lua list
local function split_deliminated_string(s,sep)
  if s==nil then
      return {}
  end
  s = s .. sep        -- ending seperator
  local t = {}        -- table to collect fields
  local fieldstart = 1
  repeat
      local nexti = string.find(s, sep, fieldstart)
      table.insert(t, string.sub(s, fieldstart, nexti-1))
      fieldstart = nexti + 1
  until fieldstart > string.len(s)
  return t
end
------------------------------------------------------------

local function is_type(dev, type)
  local named_devs = luup.variable_get(HHOD_SID, type, controller_id)
  if( named_devs==nil ) then
      return false
  end
  t = split_deliminated_string(named_devs,',')
  for i,element in ipairs(t) do
      if element == dev then
          return true
      end
  end
  return false
end

------------------------------------------------------------
-- function poll()
--    log("poll() called")
--    luup.call_delay("poll", "300", "")
--    luup.io.write(string.char(13))
-- end

------------------------------------------------------------
-- STARTUP
------------------------------------------------------------
function startup(lul_device)
   ipAddress = luup.devices[lul_device].ip
  
   if (ipAddress ~= "") then
        log("Running Network Attached HHOD on " .. ipAddress)
        luup.io.open(lul_device, ipAddress, ipPort)
   else
       log("Can not connect to hhod on " .. ipAddress)
       return false, "Hhod", "Cannot connect to Hhod on " .. ipAddress
   end 
end

------------------------------------------------------------
------------------------------------------------------------
-- Handle Incoming Data:
------------------------------------------------------------
------------------------------------------------------------
function incoming(lul_data)
  local data = tostring(lul_data)
  
  if (data == "STATE=NEW") then
    if (os.time() - lastNewSate > lastNewStateInterval) then
      lastNewSate = os.time()
      sendCommand("S")
      log(data,50)
    end
  else
    log(data,1)
    local t = split_deliminated_string(data,',')
    if (t == nil) then
      return
    end
  end 
end
