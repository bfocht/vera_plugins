local THIS_PLUGIN = "Home Heartbeat Plugin v0.01"

local HHOD_SID    = "urn:upnp-hhod-svc:serviceId:HHOD1"

local DEBUG_MODE = true

local SECURITY_SID  = "urn:micasaverde-com:serviceId:SecuritySensor1"
local SWITCHPWR_SID = "urn:upnp-org:serviceId:SwitchPower1"
local HADEVICE_SID  = "urn:micasaverde-com:serviceId:HaDevice1"
local ALARM_SID     = "urn:micasaverde-com:serviceId:AlarmPartition2"

local BINARY_SCHEMA  = "urn:schemas-micasaverde-com:device:BinaryLight:1"
local MOTION_SCHEMA  = "urn:schemas-micasaverde-com:device:MotionSensor:1"
local TEMP_LEAK_SENSOR = "urn:schemas-micasaverde-com:device:TemperatureLeakSensor:1"

local ipAddress
local ipPort = 1098
local buffer = ""
local lastNewSate = 0
local lastNewStateInterval = 60 * 3

local child_id_lookup_table = {}
local child_list_ptr
local new_child_found = false
local sync_child_devices = false
local handle

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
-- STARTUP
------------------------------------------------------------
function startup(lul_device)
   ipAddress = luup.devices[lul_device].ip
   controller_id = lul_device
   sync_child_devices = true

   -----------------------------------------------------------
  -- Find my children and build lookup table of altid -> id
  ------------------------------------------------------------
  -- loop over all the devices registered on Vera
  child_id_lookup_table = {}
  local numberChilds = 0
  for k, v in pairs(luup.devices) do
      -- if I am the parent device
      if v.device_num_parent == luup.device then
          debug('Found Child ID: ' .. k .. ' AltID: ' .. v.id)
          child_id_lookup_table[v.id] = k
          numberChilds=numberChilds+1
      end
  end
  luup.variable_set(HHOD_SID, "ChildDeviceCount", numberChilds, lul_device)

  child_list_ptr = luup.chdev.start(controller_id);
  if (ipAddress ~= "") then
      log("Running Network Attached HHOD on " .. ipAddress)
      luup.io.open(lul_device, ipAddress, ipPort)
  else
     log("Can not connect to hhod on " .. ipAddress)
     return false, "Hhod", "Cannot connect to Hhod on " .. ipAddress
  end
  --kick off a status check
  sendCommand("S")
  handle = luup.task("Sync child devices", 1, "HHOD", -1)
end

------------------------------------------------------------
------------------------------------------------------------
-- Handle Incoming Data:
------------------------------------------------------------
------------------------------------------------------------
function incoming(lul_data)
  local data = tostring(lul_data)
  --debug(data)

  if (data == "STATE=NEW") then
    if (os.time() - lastNewSate > lastNewStateInterval) then
      lastNewSate = os.time()
      sendCommand("S")
    end
    return
  end

  if (data == "STATE=DONE") then
    --finished reading through devices
    --this will reboot the device
    if (sync_child_devices) then
        luup.task("Finished child sync", 4, "HHOD", handle)
        sync_child_devices = false
        luup.chdev.sync(controller_id, child_list_ptr)
    end

    if (new_child_found) then
      new_child_found = false
      sync_child_devices = true
      sendCommand("S")
    end
    return
  end

  local t = split_deliminated_string(data,',')
  if (t == nil) then
    return
  end

  local device_num   = t[1]
  local device_name  = t[2]
  local device_type  = t[3]
  local device_state = t[4]
  local device_mac   = t[9]

  if device_type == 'Water Sensor' or device_type == 'Power Sensor' or device_type == 'Tilt Sensor' then
    if (sync_child_devices) then
      luup.chdev.append(controller_id, child_list_ptr, device_mac, device_name, MOTION_SCHEMA, "D_MotionSensor1.xml", "", "", false)
      return
    end

    if child_id_lookup_table[device_mac] == nil then
      debug('child device not found')
      new_child_found = true
      return
    end

    --Water Sensors are reversed
    if device_type == 'Water Sensor' then
      if device_state == 'open' then
        device_state = 'closed'
      elseif device_state == 'closed' then
        device_state = 'open'
      end
    end

    --update status
    if device_state == 'open' then
      luup.variable_set(SECURITY_SID, "Tripped", 1, child_id_lookup_table[device_mac])
    elseif device_state == 'closed' then
      luup.variable_set(SECURITY_SID, "Tripped", 0, child_id_lookup_table[device_mac])
    end
  end
end
