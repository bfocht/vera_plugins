local DEBUG_MODE = true

local SECURITY_SID  = "urn:micasaverde-com:serviceId:SecuritySensor1"
local MOCHAD_SID    = "urn:micasaverde-com:serviceId:mochad1"
local SWITCHPWR_SID = "urn:upnp-org:serviceId:SwitchPower1"
local HADEVICE_SID  = "urn:micasaverde-com:serviceId:HaDevice1"
local DIMMING_SID   = "urn:upnp-org:serviceId:Dimming1"
local ALARM_SID     = "urn:micasaverde-com:serviceId:AlarmPartition2"

local BINARY_SCHEMA  = "urn:schemas-micasaverde-com:device:BinaryLight:1"
local DIMMING_SCHEMA = "urn:schemas-micasaverde-com:device:DimmableLight:1"
local MOTION_SCHEMA  = "urn:schemas-micasaverde-com:device:MotionSensor:1"
local ALARM_SCHEMA = "urn:schemas-micasaverde-com:device:AlarmPartition:2"

local ipAddress
local ipPort = 1099
local buffer = ""

local controller_id
local power_line_command
local child_id_lookup_table = {}
local last_rf_selected_unit = {}
local socket = require("socket")

------------------------------------------------------------
local function trim(s)
  return s:gsub("^%s*", ""):gsub("%s*$","")
end

------------------------------------------------------------  
local function log(text, level)
    luup.log("MOCHAD: " .. text, (level or 1))
end

------------------------------------------------------------  	
local function debug(text)
  if (DEBUG_MODE == true) then
      log((text or "<empty>"), 50)
  end
end

------------------------------------------------------------
local function x10_id(dev_id)
   local xid =  dev_id:sub(3)
   return xid
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
-- converts a security address to bcd
local function convertBCD(addr)
    local data = tostring(addr)  
    local t = split_deliminated_string(data ,':')
     -- this can happen!
    if (t == nil) then
            return 0
    end
    local value1 = tonumber(t[1], 16)
    local value2 = tonumber(t[2], 16)*256
    local value3 = value1+value2
    local bcd = ""
    local fieldstart = 1
    repeat
      local nextb = string.sub(value3, fieldstart, fieldstart)
      nextb = nextb + 3
      if nextb >9 then
	nextb = nextb - 10
      end
      bcd = bcd..nextb
      fieldstart = fieldstart + 1
      until fieldstart > string.len(value3)  or fieldstart > 5
      if fieldstart == 5 then
        bcd = "3"..bcd  -- must be a five digit security code
      end
    return bcd  
end
------------------------------------------------------------

local function is_type(dev, type)
  local named_devs = luup.variable_get(MOCHAD_SID, type, controller_id)
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
local function add_children(parent, child_list_ptr, prefix, schema, dev_file, dev_type, csv_dev_list)
  local dev_list = split_deliminated_string(csv_dev_list,',')
  for idx, dev_name in ipairs(dev_list) do
      dev_name = trim(dev_name)
      if (dev_name and dev_name ~= "") then
         debug("Adding " .. dev_type .. " " .. dev_name)
         luup.chdev.append(parent, child_list_ptr, prefix .. dev_name, "X10 " .. dev_name, schema, dev_file, "", "", false)
      end
   end
end

------------------------------------------------------------	
local function dim(current_value)
   local new_value
   new_value = current_value - 10;
   if (1 > new_value) then
       new_value = 1
   end
   return new_value
end

------------------------------------------------------------	
local function bright(current_value)
   local new_value
   new_value = current_value + 10;
   if (new_value > 100) then
       new_value = 100
   end   
   return new_value
end

------------------------------------------------------------
function poll()
   log("poll() called")
   luup.call_delay("poll", "300", "")
   luup.io.write(string.char(13))
end

------------------------------------------------------------
-- STARTUP
------------------------------------------------------------
function startup(lul_device)

   ------------------------------------------------------------
   -- Open Connection to Mochad
   ------------------------------------------------------------
   controller_id = lul_device
   
   ipAddress = luup.devices[lul_device].ip
  
   if (ipAddress ~= "") then
        log("Running Network Attached I_Mochad1.xml on " .. ipAddress)
        luup.io.open(lul_device, ipAddress, ipPort)
   else
       log("Can not connect to mochad on " .. ipAddress)
       return false, "Mochad", "Cannot connect to Mochad on " .. ipAddress
   end
  
   ------------------------------------------------------------
   -- Create a new Child Device List
   child_devices = luup.chdev.start(lul_device);
   ------------------------------------------------------------
   
   -- Vera gets angry with me when I accidently add two child devices
   -- with the same name but different schemas. (as well it should!)
   -- To avoid that I am appending a prefix before the X10 code of the child device
   -- A-A01 is an applicance module at A01
   -- D-A01 is a dimmer at A01
   -- X-A01 is a dimmer at A01
   -- M-A01 is a motion sensor at A01

   ---------------
   -- Get a list of child devices
   local app_ID     = luup.variable_get(MOCHAD_SID, "BinaryModules",      lul_device)
   local dim_ID     = luup.variable_get(MOCHAD_SID, "DimmableModules",    lul_device)
   local xdim_ID    = luup.variable_get(MOCHAD_SID, "SoftstartModules",   lul_device)
   local motion_ID  = luup.variable_get(MOCHAD_SID, "MotionSensors",      lul_device)
   local rfsec_m_ID = luup.variable_get(MOCHAD_SID, "RFSecMotionSensors", lul_device)
   local rfsec_d_ID = luup.variable_get(MOCHAD_SID, "RFSecDoorSensors",   lul_device)
      
   ---------------
   -- If all child devices are empty add a few examples
    if ((app_ID == nil) and (dim_ID == nil) and (xdim_ID == nil) and (motion_ID == nil) and (rfsec_m_ID==nil) and (rfsec_d_ID==nil)) then
        luup.variable_set(MOCHAD_SID, "BinaryModules",      "",	lul_device)
        luup.variable_set(MOCHAD_SID, "DimmableModules",    "",	lul_device)
        luup.variable_set(MOCHAD_SID, "SoftstartModules",   "",	lul_device)
        luup.variable_set(MOCHAD_SID, "MotionSensors",      "",	lul_device)
        luup.variable_set(MOCHAD_SID, "RFSecMotionSensors", "",	lul_device)
        luup.variable_set(MOCHAD_SID, "RFSecDoorSensors",   "",	lul_device)	
        luup.variable_set(MOCHAD_SID, "RFSecRemote",   "076300",	lul_device)	
    end

    power_line_command = luup.variable_get(MOCHAD_SID, "PowerLineCommand", lul_device)
    if (power_line_command == nil) then
        power_line_command = '0'
        luup.variable_set(MOCHAD_SID, "PowerLineCommand", power_line_command, lul_device)
    end
    
   ------------------------------------------------------------
   -- APPLIANCE MODULES
   add_children(lul_device, child_devices, 'A-', BINARY_SCHEMA,  "D_BinaryLight1.xml",  "Binary Light", app_ID)
   -- DIMMABLE LIGHTS
   add_children(lul_device, child_devices, 'D-', DIMMING_SCHEMA, "D_DimmableLight1.xml", "Dimmable Light", dim_ID)
   -- SOFTSTART DIMMABLE LIGHTS --
   add_children(lul_device, child_devices, 'X-', DIMMING_SCHEMA, "D_DimmableLight1.xml", "Dimmable Light", xdim_ID)
   -- MOTION SENSORS --
   add_children(lul_device, child_devices, 'M-', MOTION_SCHEMA,  "D_MotionSensor1.xml",  "Motion Sensor", motion_ID)
   -- RFSEC MOTION SENSORS --
   add_children(lul_device, child_devices, 'R-', MOTION_SCHEMA,  "D_MotionSensor1.xml",  "RFSec Motion Sensor", rfsec_m_ID)
   -- RFSEC DOOR/WINDOW SENSORS --
   add_children(lul_device, child_devices, 'S-', MOTION_SCHEMA,  "D_MotionSensor1.xml",  "RFSec Door/Window Sensor", rfsec_d_ID)
    
   --add Alarm partition
   luup.chdev.append(lul_device, child_devices, "X10_partition", "X10 Alarm Partition", ALARM_SCHEMA, "D_MochadAlarm1.xml", nil, nil, false)
   
   luup.chdev.sync(lul_device, child_devices)
   
   ------------------------------------------------------------
   -- Find my children and build lookup table of altid -> id
   ------------------------------------------------------------
   -- loop over all the devices registered on Vera
   for k, v in pairs(luup.devices) do
       -- if I am the parent device
       if v.device_num_parent == luup.device then
           debug('Found Child ID: ' .. k .. ' AltID: ' .. v.id)
           child_id_lookup_table[v.id] = k
       end
   end
   
end

------------------------------------------------------------
------------------------------------------------------------
-- Handle Actions:
------------------------------------------------------------
------------------------------------------------------------

------------------------------------------------------------
function switch_set_target(lul_device, lul_settings)
    local prefix = ((power_line_command == '1') and 'pl ' or 'rf ')
    local dev_x10_id = x10_id(luup.devices[lul_device].id)
    local lul_command = 'off'    
    local lul_reverse = luup.variable_get(HADEVICE_SID,"ReverseOnOff",lul_device)
    if( lul_settings.newTargetValue=="1" or (lul_settings.newTargetValue=="0" and lul_reverse=="1") ) then
        lul_command = 'on'
    end
    luup.variable_set(SWITCHPWR_SID,"Status",lul_settings.newTargetValue, lul_device)
    sendCommand(prefix ..  dev_x10_id .. ' ' .. lul_command)
end

------------------------------------------------------------
function set_pl_dim(lul_device, lul_settings, dev_x10_id)
    local dim_level
    local command
    
    if(lul_settings.newLoadlevelTarget == '0') then
        sendCommand('pl ' .. dev_x10_id .. ' off')
    else
        -- For PL commands we can send a target dim level:
        -- We need to support both extended dim (xdim) and normal dim X10 modules
        -- Older x10 modules use "dim" and scale from 0 to 31.
        -- Newer "soft-start" modules use "xdim" and scale from 0 to 63.
        if 'X' == string.sub(luup.devices[lul_device].id,1,1) then
            dim_level = math.floor(lul_settings.newLoadlevelTarget *63/100)
            command =  'xdim ' .. dim_level
        else
            dim_level = math.floor(lul_settings.newLoadlevelTarget *31/100)
            command =  'dim ' .. dim_level
        end
        sendCommand('pl ' .. dev_x10_id .. ' ' .. command)
    end
end

------------------------------------------------------------
function set_rf_dim(lul_device, lul_settings, dev_x10_id)
    -- For RF commands we have to send a series of "dim" / "brighten" commands
    -- ActiveHome sends 9 dim/brights to move from 0% to 100%. For now I'm going
    -- to assume that each dim/brighten corrisponds to 10%
   
    current_dim_level = luup.variable_get(DIMMING_SID,"LoadLevelStatus",lul_device)
   
    -- if we want to set it to zero just go ahead and send an off
    if(lul_settings.newLoadlevelTarget == '0') then
        sendCommand('rf ' .. dev_x10_id .. ' off')
    -- if we want to set it to '100' and it is currently off we can send an on
    elseif ((lul_settings.newLoadlevelTarget == '100') and (current_dim_level == '0')) then
        sendCommand('rf ' .. dev_x10_id .. ' on')
    else
        -- We need to send out an RF command to this device
        -- to make it the last RF device used.
        sendCommand('rf ' .. dev_x10_id .. ' ' .. ((current_dim_level=='0') and 'off' or 'on'))
        luup.sleep(1000)
        
        local curr_step = math.floor(current_dim_level/10)
        local desired_step = math.floor(lul_settings.newLoadlevelTarget/10)
        
        while (desired_step > curr_step) do
            sendCommand('rf ' .. dev_x10_id .. ' bright')
            curr_step = curr_step + 1
            luup.sleep(1000)
        end
        
        while (curr_step > desired_step) do
            sendCommand('rf ' .. dev_x10_id .. ' dim')
            curr_step = curr_step - 1
            luup.sleep(1000)
        end
    end
end

------------------------------------------------------------
function light_set_level(lul_device, lul_settings)
    local lul_command
    local dev_x10_id = x10_id(luup.devices[lul_device].id)
    local current_dim_level
    
    if power_line_command == '1' then
        set_pl_dim(lul_device, lul_settings, dev_x10_id)
    else
        set_rf_dim(lul_device, lul_settings, dev_x10_id)
    end
    luup.variable_set(DIMMING_SID,"LoadLevelStatus",lul_settings.newLoadlevelTarget, lul_device)
end
------------------------------------------------------------
function requestArmMode (lul_device, state, pinCode)
	
	local dev_x10_id = luup.variable_get(MOCHAD_SID, "RFSecRemote",   controller_id)
	if  (dev_x10_id == nil) then
	   return false
	end
	
	debug (string.format ("(requestArmMode) device=%d, state=%s", lul_device, state))

	-- All the arming commands are implicitly 'forced',
	-- so for the 'Force' request use 'Away' instead.
	-- state = (state == "Force") and "Armed" or state

	local command
	if (state == "Disarmed") then
		command = "DISARM"
	elseif ((state == "Armed") or (state == "Force") or (state == "ArmedInstant")) then
		command = "ARM" 
	elseif (state == "Stay") then
		command = "ARM_HOME_MAX"
	elseif (state == "StayInstant") then
		command = "ARM_HOME_MIN"
	elseif (state == "Night") then
		command = "ARM_HOME_MAX" 
	elseif (state == "NightInstant") then
		command = "ARM_HOME_MIN"
	elseif (state == "Vacation") then
		command = "ARM" 
	else
		log ("(requestArmMode) ERROR: Invalid state requested.")
		return false
	end
	
	
	luup.variable_set(ALARM_SID, "DetailedArmMode",  state,	lul_device)	
	
	local prefix = 'RFSEC '
	sendCommand(prefix ..  dev_x10_id .. ' ' .. command)
	
	debug ("(requestArmMode) SUCCESS: Succesfully changed to the requested arm mode.")
	return true
end


function requestQuickArmMode (device, state)
	requestArmMode (device, state, "0000")
	return true
end

function requestPanicMode (device, state)
	log ("(requestPanicMode) Panic Modes not supported.")
	return true
end

------------------------------------------------------------
------------------------------------------------------------
-- Handle Incoming Data:
------------------------------------------------------------
------------------------------------------------------------

------------------------------------------------------------
local function rxsec_incoming_data(addr, new_state)
    local trip
    local altit
    local bcdaddr = convertBCD(addr)
    --debug("Security Device triggered " .. bcdaddr)
    -- Handle RFSec Motion Sensors:
    if ( is_type(bcdaddr, "RFSecMotionSensors") ) then
        altid = 'R-' .. bcdaddr
        if (new_state == "Motion_alert_MS10A") then
            trip = '1'
        elseif (new_state == "Motion_normal_MS10A") then
            trip = '0'
        end

    -- Handle RFSec Door Sensors:	
    elseif (is_type(bcdaddr, "RFSecDoorSensors") ) then
        altid = 'S-' .. bcdaddr
        if( new_state:sub(1, 13) == "Contact_alert" ) then
            trip = '1'
        elseif (new_state:sub(1, 14) == "Contact_normal") then
            trip = '0'
        end
    else
      log("Security Device not found " .. bcdaddr,2)
    end
    
    if (trip ~= nil_) then
        luup.variable_set(SECURITY_SID, "Tripped", trip, child_id_lookup_table[altid])
    end
end

------------------------------------------------------------
local function set_dim_level(altid, dim_mod_func)
    local curr_dim = luup.variable_get(DIMMING_SID,"LoadLevelStatus",child_id_lookup_table[altid])
    luup.variable_set(DIMMING_SID, "LoadLevelStatus", dim_mod_func(curr_dim),child_id_lookup_table[altid])
end

------------------------------------------------------------
local function set_light_toggle(prefix, addr, new_state)
    local altid = prefix .. addr
    local new_dim    = ((new_state == 'On') and 100 or 0)
    local new_toggle = ((new_state == 'On') and '1' or '0')
    luup.variable_set(SWITCHPWR_SID,"Status", new_toggle, child_id_lookup_table[altid])
    luup.variable_set(DIMMING_SID, "LoadLevelStatus", new_dim, child_id_lookup_table[altid])
    last_rf_selected_unit[addr:sub(1,1)] = addr;
end

------------------------------------------------------------
function incoming(lul_data)

     local data = tostring(lul_data)     
     local t = split_deliminated_string(data,' ')
     
     -- if you are messing around with mochad on the command line, or polling,
     -- this can happen!
     if (t == nil) then
        return
     end
     
     local rx_tx     = t[3]
     local rx_type   = t[4]
     local addr      = t[6]
     local new_state = t[8]
     local addr_found = false
     if (rx_tx == 'Rx') then
     
         debug('Recieved '..data)
         
         ------------
         -- Check to see if it is an RFSEC device:
         if (rx_type == 'RFSEC') then
            rxsec_incoming_data(addr, new_state)
            
        -------------
        -- Otherwise this is a normal X10 House/Unit Code Command:
         elseif  (rx_type == 'RF') then
            
            -- Handle Dim/Bright commands
            if ((new_state == 'Dim') or ((new_state == 'Dim'))) then
                local unit_code  = last_rf_selected_unit[addr]
                
                if (unit_code ~= nil) then
                    -- figure out if we are dimming or brightening
                    dim_mod_command = ((new_state=='Dim') and Dim or Bright)
                    
                    -- and set the new level
                    if (is_type(unit_code, "DimmableModules")) then
                        set_dim_level('D-' .. unit_code, dim_mod_command)
                        addr_found = true
                    end
                    if (is_type(unit_code, "SoftstartModules")) then
                        set_dim_level('X-' .. unit_code, dim_mod_command)
                        addr_found = true
                    end
                end
            end
            
            -- Handle Motion Sensors
            if (is_type(addr, "MotionSensors")) then
                local tripped = ((new_state == 'On') and '1' or '0')
                luup.variable_set(SECURITY_SID, "Tripped", tripped, child_id_lookup_table['M-' .. addr])
                addr_found = true
            end
             
             -- Handle Binary Modules
            if (is_type(addr, "BinaryModules")) then
                local status = ((new_state == 'On') and '1' or '0')
                luup.variable_set(SWITCHPWR_SID,"Status", status, child_id_lookup_table['A-' .. addr])
                addr_found = true
            end
            
            -- Handle Dimmable Modules
            if (is_type(addr, "DimmableModules")) then
                set_light_toggle('D-', addr, new_state)
                addr_found = true
            end

            -- Handle SoftStart Modules
            if (is_type(addr, "SoftstartModules")) then
                set_light_toggle('X-', addr, new_state)
                addr_found = true
           end
           if (addr_found == false) then
               log("Module not found " .. addr,2)
           end
       end
    end
 end
