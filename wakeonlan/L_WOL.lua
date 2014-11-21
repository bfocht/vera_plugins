module("L_WOL", package.seeall)


local THIS_PLUGIN = "Wake-on-LAN Plugin v2.00"

local WOL_SID    = "urn:upnp-wol-svc:serviceId:WOL1"
local SWITCHPWR_SID = "urn:upnp-org:serviceId:SwitchPower1"

local BINARY_SCHEMA  = "urn:schemas-micasaverde-com:device:BinaryLight:1"

------------------------------------------------------------
local function trim(s)
  return s:gsub("^%s*", ""):gsub("%s*$","")
end

------------------------------------------------------------  
local function log(text, level)
    luup.log("WOL: " .. text, (level or 50))
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
---------------------------------------------------------------------------
function checkAddress (address)
	if (address == nil) then
	 return nil
	end
	address=trim(address)
	-- check if the MAC address is valid
	if (#address ~= 17) then
		log ("(checkAddress) ERROR: Incorrect MAC address length.")
		return nil
	end

	newAddress = address:upper()
	local addressPattern = "[%dA-F][%dA-F][:-][%dA-F][%dA-F][:-][%dA-F][%dA-F][:-][%dA-F][%dA-F][:-][%dA-F][%dA-F][:-][%dA-F][%dA-F]"
	if (string.find (newAddress, addressPattern) == nil) then
		log("(checkAddress) ERROR: Invalid MAC address.")
		return nil
	else -- Replace '-' with ':'.
		newAddress = newAddress:gsub ("-", ":")
	end
	
	return newAddress
end

---------------------------------------------------------------------------
local function add_children(parent, child_list_ptr, schema, dev_file, csv_dev_list, csv_name_list)
  local dev_list = split_deliminated_string(csv_dev_list,',')
  local name_list = split_deliminated_string(csv_name_list,',')
  for idx, dev_addr in ipairs(dev_list) do
      ---make sure address is valid
      dev_addr = checkAddress(dev_addr)
      if (dev_addr and dev_addr ~= "") then
      dev_name = name_list[idx]    
         --make sure name is valid, if not make one up
         if (dev_name == nil or dev_name == "") then
           dev_name = "Computer "..idx
         end
            luup.chdev.append(parent, child_list_ptr, dev_addr, "WOL_"..dev_name, schema, dev_file, "", "", false)
      end
   end
end

---------------------------------------------------------------------------
-- STARTUP
---------------------------------------------------------------------------
function startup(lul_device)

	log("Startup " .. THIS_PLUGIN)
		
	------------------------------------------------------------
	-- Create a new Child Device List
	child_devices = luup.chdev.start(lul_device);

	------------------------------------------------------------
	-- Get a list of child devices (computers)
   	local com_ADDR     = luup.variable_get(WOL_SID,"ComputerAddressList",lul_device)
   	local com_NAME     = luup.variable_get(WOL_SID,"ComputerNameList",lul_device)

   	------------------------------------------------------------
	-- If all child devices are empty add a few examples
	if (com_ADDR == nil) then
		luup.variable_set (WOL_SID, "ComputerAddressList", "00:00:00:00:00:00", lul_device)
		luup.variable_set (WOL_SID, "ComputerNameList", "ComputerName", lul_device)
	end
		
	------------------------------------------------------------
	-- Add Computers
   	add_children(lul_device, child_devices, BINARY_SCHEMA,  "D_BinaryLight1.xml", com_ADDR, com_NAME)

	luup.chdev.sync(lul_device, child_devices)
		
	return true
end

---------------------------------------------------------------------------
function switch_set_target(lul_device, lul_settings)
	local address = luup.devices[lul_device].id
	address = checkAddress(address)

	if (address and lul_settings.newTargetValue=="1") then
	  	command = "wol " .. address
	  	log ("Executing wol with command: " .. command)
	  	local wolRetCode = os.execute (command)

	  	if (wolRetCode == 0) then
	  		log("SUCCESS: Magic packet sent.")
	  		luup.variable_set(SWITCHPWR_SID,"Status",lul_settings.newTargetValue, lul_device)
	  	else

	  		log("FAILURE: Magic packet not sent.")
	  		luup.variable_set(SWITCHPWR_SID,"Status",0, lul_device)
	  	end
	else
		luup.variable_set(SWITCHPWR_SID,"Status",0, lul_device)
	end
	return true
end

---------------------------------------------------------------------------
