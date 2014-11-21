local GCAL_VERSION = "V 0.9"  
local GCAL_SID = "urn:srs-com:serviceId:GCalIII"
local SECURITY_SID = "urn:micasaverde-com:serviceId:SecuritySensor1"
-- Variables that are 'global' for this plugin
local GC = {}
--Setup and file variables
GC.CalendarID = ""

-- GC.plugin_name server several purposes - do not change
-- it identifies and names key files
-- also creates a subdirectory in /etc/cmh-ludl of the same name

GC.plugin_name = "GCal3" -- Do not change for this plugin

-- make the file names and paths available
GC.libpath = "/usr/lib/lua/" -- default vera directory for modules
GC.basepath = "/etc/cmh-ludl/" -- default vera directory for uploads
GC.jwt = GC.libpath .. "googlejwt.sh"
GC.jsonlua = GC.libpath .. "json.lua"
GC.pluginpath = GC.basepath .. GC.plugin_name .."/" -- putting the credentials in a sub directory to keep things uncluttered
GC.credentialfile = GC.plugin_name .. ".json" -- the service account credential file downloaded from google developer console
GC.pemfile = GC.pluginpath .. GC.plugin_name ..".pem" -- certificate to this file
GC.semfile = GC.pluginpath .. GC.plugin_name ..".sem" -- semaphore file  

-- Main plugin Variables
GC.timeZone = 0
GC.timeZonehr = 0
GC.timeZonemin = 0
GC.now =0
GC.utc = 0
GC.startofDay = 0
GC.endofDay = 0
GC.Events = {}
GC.nextTimeCheck = os.time()
GC.trippedID = ""
GC.trippedEvent = ""
GC.trippedStatus = 0
GC.trippedIndex = 0
GC.retrip = "true"
GC.debug = 3 -- initial default, catches everything before variables initialized
GC.debugPre = "GCal3 " ..GCAL_VERSION .. ":"
GC.Keyword = ""
GC.ignoreKeyword = "false"
GC.exactKeyword = "true"
GC.triggerNoKeyword = "false"
GC.ignoreAllDayEvent = "false"
GC.StartDelta = 0
GC.EndDelta = 0
GC.CalendarID = ""
GC.access_token = ""


-- Utility Functions

function upperCase(str)
  str = string.upper(str)
  local minusChars={"à","á","â","ã","ä","å","æ","ç","è","é","ê","ë","ì","í","î","ï","ð","ñ","ò","ó","ô","õ","ö","÷","ø","ù","ú","û","ü","ý","þ","ÿ"}
	local majusChars={"À","Á","Â","Ã","Ä","Å","Æ","Ç","È","É","Ê","Ë","Ì","Í","Î","Ï","Ð","Ñ","Ò","Ó","Ô","Õ","Ö","÷","Ø","Ù","Ú","Û","Ü","Ý","Þ","ß"}
	for i = 1, #minusChars, 1 do
		str = string.gsub(str, minusChars[i], majusChars[i])
	end
	return str 
end

function DEBUG(level,s)
  if (level <= GC.debug) then
    s = GC.debugPre .. s
    luup.log(s)
  end
end

function trimString( s )
  return string.match( s,"^()%s*$") and "" or string.match(s,"^%s*(.*%S)" )
end

function strToTime(s)
  local _,_,year,month,day = string.find(s, "(%d+)-(%d+)-(%d+)")
  local _,_,hour,minute,second = string.find(s, "(%d+):(%d+):(%d+)")
  if (hour == nil) then -- an all-day event has no time component so adjust to utc
    hour = - GC.timeZonehr
    minute = - GC.timeZonemin
    second = 0
  end
  return os.time({isdst=os.date("*t").isdst,year=year,month=month,day=day,hour=hour,min=minute,sec=second})
end

function compare(a,b) -- used for sorting a table by the first column
  return a[1] < b[1]
end

-- system, file i/o and related functions

function os_command (command) 
 local stdout = io.popen(command)
    local result = stdout:read("*a")
    stdout:close()
 return result
end

function readfromfile(filename)
  local command = "ls " .. filename
  local result = os.execute(command) -- does the file exist
  DEBUG(3,"Command " .. command .. " returned " ..result)
  
  if (result ~= 0) then -- return since we cannot read the file
    luup.variable_set(GCAL_SID, "gc_NextEvent",string.gsub(filename,"/(.*)/","") .. " ??" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
    return nil
  end
  
	local f = io.open(filename, "r")
  if not f then return nil end
	local c = f:read "*a"
	f:close()
	return c
end

function writetofile (filename,package)
  local f = assert(io.open(filename, "w"))
  local t = f:write(package)
  f:close()
  return t    
end

function getfile(filename,url)
     DEBUG(3,"Downloading " .. filename)
    package.loaded.http = nil
    local http = require("socket.http")
    http.TIMEOUT = 30
    DEBUG(3,"Attempting to download " .. url)
    local page, status = http.request(url)
    package.loaded.http = nil

    if (status == 200) then
      DEBUG(3,"Writing file " .. filename)
      local _ = writetofile(filename,page)
      return true
    else
      DEBUG(3,"Error downloading " .. filename)
      DEBUG(3,"Error code " ..status)
      return false
    end
end

-- Authorization related functions

function checkforcredentials(json)
  DEBUG(3,"Function: checkforcredentials")

  -- check to see if there is a new credential file
  -- when you upload the credential  vera compresses it using lzo
  -- so it needs to be decompressed
  -- the credentials file needs to be split into component parts
  local newcredentials = false
  
  local command = "ls " .. GC.basepath .. GC.credentialfile .. ".lzo"
  local result = os.execute(command) -- check to see if there is a new credential file
  DEBUG(3,"Command " .. command .. " returned " ..result)
  
  if (result == 0) then
  newcredentials = true 
    --decompress the lzo file
    command = "pluto-lzo d " .. GC.basepath .. GC.credentialfile .. ".lzo " .. GC.pluginpath .. GC.credentialfile
    result = os.execute(command)
    DEBUG(3,"Command " .. command .. " returned " ..result)
    if result ~= 0 then
      DEBUG(3,"Could not decompress the file - " .. GC.basepath .. GC.credentialfile .. ".lzo")  
    return nil
    end
    -- don't need the lzo file any more so delete it
    command = "rm -f " .. GC.basepath .. GC.credentialfile .. ".lzo"
    result = os.execute(command)
    DEBUG(3,"Command " .. command .. " returned " ..result)	-- remove the lzo file
  end 
  
  --make sure we have a credentials file
  command = "ls " .. GC.pluginpath .. GC.credentialfile
  result = os.execute(command) -- check to see if there is a file
  DEBUG(3,"Command " .. command .. " returned " ..result)
  if result ~= 0 then -- we don't have a credential file
    DEBUG(3,"Could not find the credentials file: ")
    return nil
  end
  
  -- now we can decompose the credentialsfile
  
  local contents = readfromfile(GC.pluginpath .. GC.credentialfile)
    
  if (not string.find(contents, '"type": "service_account"')) then
    DEBUG(3,"The credentials are not for a service account")
    return nil
  end
  if (not string.find(contents, '"private_key":')) then
    DEBUG(3,"The credentials file does not contain a private key")
    return nil
  end
  if (not string.find(contents, '"client_email":')) then
    DEBUG(3,"The credentials file does not contain a client email")
    return nil
  end
  
  local credentials = json.decode(contents)
  
  if newcredentials then -- get the private key and write to file
    local pem = credentials.private_key
    local command = "rm -f ".. GC.pemfile
    local result = os.execute(command) -- delete the old one
    DEBUG(3,"Command " .. command .. " returned " ..result)
    result = writetofile (GC.pemfile,pem) -- create the new one
    if not result then
      DEBUG(3,"Could not create the file - " .. GC.pemfile)
      return nil
    end
  end
  
   -- get the service account email name 
  GC.ClientEmail = credentials.client_email
  return true
end

function get_access_token(https,json)
  DEBUG(3, "Function: get_access_token")
  -- First check to see if we have an existing unexpired token
  -- get the access token from the file
  local url = "https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=" .. GC.access_token
  local body, code, _,status = https.request(url) -- check the token status
  DEBUG(2,"Token info status: " .. status)
    if (code ==200) then  
      local tokencheck = json.decode(body)
      local time_to_expire = tokencheck.expires_in
      DEBUG(2,"Token will expire in " .. time_to_expire .." sec")
      if (time_to_expire > 10) then -- 10 seconds gives us some leeway
        return GC.access_token -- the current token was still valid
      end
    end
  DEBUG(2,"Token Info request status: " .. status)
  DEBUG(2,"Getting a new token")
  -- get a new token  
  local str = '\'{"alg":"RS256","typ":"JWT"}\''
  local command = "echo -n " .. str .. " | openssl base64 -e"
  local jwt1= os_command(command)
  if not jwt1 then
    DEBUG(3,"Error encoding jwt1")
  return nil
  end
  jwt1 = string.gsub(jwt1,"\n","")

  local iss = GC.ClientEmail 
  local scope = "https://www.googleapis.com/auth/calendar"
  local aud = "https://accounts.google.com/o/oauth2/token"
  local exp = tostring(os.time() + 3600)
  local iat = tostring(os.time())
 
  str = '\'{"iss":"' .. iss .. '","scope":"' .. scope .. '","aud":"' .. aud .. '","exp":' .. exp .. ', "iat":' .. iat .. '}\''
  command = "echo -n " .. str .. " | openssl base64 -e"
  local jwt2 = os_command(command)
  if not jwt2 then
    DEBUG(3,"Error encoding jwt2")
  return nil
  end
  jwt2 = string.gsub(jwt2,"\n","")
 
  local jwt3 = jwt1 .. "." .. jwt2
  jwt3 = string.gsub(jwt3,"\n","")
  jwt3 = string.gsub(jwt3,"=","")
  jwt3 = string.gsub(jwt3,"/","_")
  jwt3 = string.gsub(jwt3,"%+","-")
  command ="echo -n " .. jwt3 .. " | openssl sha -sha256 -sign " .. GC.pemfile .. " | openssl base64 -e"
  local jwt4 = os_command(command)
  if not jwt4 then
    DEBUG(3,"Error encoding jwt4")
  return nil  
  end
  jwt4 = string.gsub(jwt4,"\n","")
 
  local jwt5 = string.gsub(jwt4,"\n","")
  jwt5 = string.gsub(jwt5,"=","")
  jwt5 = string.gsub(jwt5,"/","_")
  jwt5 = string.gsub(jwt5,"%+","-")
  command = "curl -k -s -H " .. '"Content-type: application/x-www-form-urlencoded"' .. " -X POST " ..'"https://accounts.google.com/o/oauth2/token"' .. " -d " .. '"grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=' .. jwt3 .. "." .. jwt5 ..'"'
  
  local token = os_command(command)
  
  if not token then
    DEBUG(3,"Error getting token")
  return nil
  end
 
  if (string.find(token, '"error":')) then
    DEBUG(3,"The token request returned an error")
    return nil
  end
 
  if (not string.find(token, '\"access_token\" :')) then
    DEBUG(3,"The token request did not provide an access token")
    return nil
  end
 
  local jsontoken = json.decode(token)
  return jsontoken.access_token 
end

-- plugin specifc functions
function releaseSemaphore(s)
  local _ = writetofile(GC.semfile,"0") -- release the semaphore
  DEBUG(1,"Device " .. GC.lul_device .. " released the semaphore - reason: " .. s)
end

function getSemaphore()
  -- to avoid race conditions if there are multiple plugin instances
  -- we set set up a semaphore using a file
  -- return true if semaphore claimed, false if not
  DEBUG(3,"Checking semaphore")
  local contents = tostring(readfromfile(GC.semfile))
  DEBUG(3,"Semaphore file returned " .. (contents or "nil"))
  if ((contents == "0") or (contents == "nil")) then -- noone holds the semaphore
    local result = writetofile(GC.semfile,GC.lul_device) -- try to claim it
    if not result then
      DEBUG(3,"Could not create the file - " .. GC.semfile)
    return false
    end
    DEBUG(2,"Device " .. GC.lul_device .. " requested semaphore")
  end
  
  contents = tostring(readfromfile(GC.semfile))
  if (contents == GC.lul_device) then -- successfully claimed
    DEBUG(1,"Device " .. GC.lul_device .. " claimed semaphore")
    return true
  end
  DEBUG(3,"Device " .. contents .. " blocked semaphore request from device " .. GC.lul_device)
  return false
end





 function getStartMinMax(startdelta,enddelta)
  local s1, s2, s3 = ""
 -- startmin and startmax use utc but startmin must be at least start of today local time
  local starttime = GC.now
  local endofday = starttime
  local ta = os.date("*t", starttime)
  s1 = string.format("%d-%02d-%02dT%02d:%02d:%02d", ta.year, ta.month, ta.day, 00, 00, 00)
  starttime = strToTime(s1)
  s3 = string.format("%d-%02d-%02dT%02d:%02d:%02d", ta.year, ta.month, ta.day, 23, 59, 59)
  endofday = strToTime(s3)
  GC.startofDay = starttime - GC.timeZone
  GC.endofDay = endofday - GC.timeZone

  -- startmax use utc and look forward 24 hrs plus gc_Interval
  local endtime = GC.utc + 86400 + GC.Interval

  -- adjust fo any start and end delta
  if (startdelta < 0) then -- look back further in time
    starttime=starttime - (startdelta * 60)
  end
  if (enddelta >= 0) then -- look forward further in time
    endtime = endtime + (enddelta * 60)
  end

  ta = os.date("*t", starttime)
  s1 = string.format("%d-%02d-%02dT%02d:%02d:%02d.000Z", ta.year, ta.month, ta.day, ta.hour, ta.min, ta.sec)
  ta = os.date("*t", endtime)
  s2 = string.format("%d-%02d-%02dT%02d:%02d:%02d.000Z", ta.year, ta.month, ta.day, ta.hour, ta.min, ta.sec)
  DEBUG(3,"StartMin is " .. s1 .. " StartMax is " .. s2)
  DEBUG(3,"End of day is " .. s3)
  return s1, s2
end

function formatDate(line) -- used to interpret ical
  local _,_,year,month,day = string.find(line,":(%d%d%d%d)(%d%d)(%d%d)") -- get the date
  local datetime = year .. "-" .. month .. "-" .. day -- format for google
  local _,_,hour,min,sec = string.find(line,"T(%d%d)(%d%d)(%d%d)Z")
  if (hour ~= nil) then
    datetime = datetime .. "T" .. hour .. ":" .. min .. ":" .. sec .. "Z"
  else
    _,_,hour,min,sec = string.find(line,"T(%d%d)(%d%d%)(d%d)")
    if (hour ~= nil) then -- this is a local time format and needs to be converted to utc
      hour = hour - GC.timeZonehr
      min = min - GC.timeZonemin
      datetime = datetime .. "T" .. hour .. ":" .. min .. ":" .. sec .. "Z"
    end
  end
  return datetime
end


function requestiCalendar(startmin, startmax, https)
  DEBUG(3,"Function: requestiCalendar")
  startmin = string.gsub(startmin,"%.000Z","Z")
  local startminTime = strToTime(startmin)
  startmax = string.gsub(startmax,"%.000Z","Z")
  local startmaxTime = strToTime(startmax)

  if (GC.CalendarID == nil) then
    DEBUG(3,"Calendar ID is not set.")
    luup.variable_set(GCAL_SID, "gc_NextEvent","Missing Calendar ID", lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
    return nil
  end

  DEBUG(2,"Checking iCal calendar")
     
  local url =  GC.CalendarID
  
  luup.variable_set(GCAL_SID, "gc_NextEvent","Accessing Calendar", lul_device)
  luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
  
  DEBUG(3,"Requested url: " .. url)
 
  local body,code,_ , status = https.request(url) -- get the calendar data
    
  if (code ~= 200) then -- anything other than 200 is an error
    local errorMessage = "http error code: " .. code
    DEBUG(3,"Http request error. Code : " .. code)
    luup.variable_set(GCAL_SID, "gc_NextEvent",errorMessage , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","", lul_device)
    return nil
  end
 
   DEBUG(2,"iCalendar request status: " .. status)

  local ical, icalevent = {}
  local eventStart, eventEnd, eventName, eventDescription = ""
  -- Parse the iCal data
  for line in body:gmatch("(.-)[\r\n]+") do

    if line:match("^BEGIN:VCALENDAR") then DEBUG(3,"Start parsing iCal") end
    if line:match("^END:VCALENDAR") then DEBUG(3,"End parsing iCal") end
    if line:match("^BEGIN:VEVENT") then
       icalevent = {}
       eventStart, eventEnd, eventName, eventDescription = ""
    end
    if line:match("^DTEND") then eventEnd = formatDate(line) end
    if line:match("^DTSTART") then eventStart = formatDate(line) end
    if line:match("^SUMMARY") then _,_,eventName = string.find(line,":(.-)$") end
    if line:match("^DESCRIPTION") then _,_,eventDescription = string.find(line,":(.*)$") end -- only gets one line     
    if line:match("^END:VEVENT") then
      if ((strToTime(eventStart) >= startminTime) and (strToTime(eventStart) <= startmaxTime)) then 
        if string.find(eventStart,"T") then 
          icalevent = {["start"] = {["dateTime"] = eventStart},["end"] = {["dateTime"] = eventEnd},["summary"] = eventName,["description"] = eventDescription}
        else
         icalevent = {["start"] = {["date"] = eventStart},["end"] = {["date"] = eventEnd},["summary"] = eventName,["description"] = eventDescription}
        end 
        table.insert(ical, icalevent)
      end
    end
  end
  
  if (#ical == 0) then
    DEBUG(1,"No events found. Retry later")
    luup.variable_set(GCAL_SID, "gc_NextEvent","No events found today" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime", "", lul_device)
    luup.variable_set(GCAL_SID, "gc_EventsToday",0, lul_device)
    luup.variable_set(GCAL_SID, "gc_EventsLeftToday",0, lul_device)
    local _ = setTrippedOff(GC.trippedStatus)
    return "No Events"
  else
    return ical
  end
end
function requestCalendar(startmin, startmax, https, json)
  DEBUG(3,"Function: requestCalendar")

  if (GC.CalendarID == nil) then
    DEBUG(3,"Calendar ID is not set.")
    luup.variable_set(GCAL_SID, "gc_NextEvent","Missing Calendar ID", lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
    return nil
  end
 
  GC.access_token = get_access_token (https, json)
  if GC.access_token == nil then
    luup.variable_set(GCAL_SID, "gc_NextEvent","Fatal error - access token", lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
    DEBUG(1,"Fatal error trying to get access token")
  return nil
  end
 
  DEBUG(2,"Checking google calendar")
     
  local url = "https://www.googleapis.com/calendar/v3/calendars/".. GC.CalendarID .. "/events?"
  url = url .. "access_token=" .. GC.access_token .. "&timeZone=utc"
  url = url .. "&singleEvents=true&orderBy=startTime"
  url = url .. "&timeMax=" .. startmax .. "&timeMin=" .. startmin
  url = url .. "&fields=items(description%2Cend%2Cstart%2Csummary)"
  
  luup.variable_set(GCAL_SID, "gc_NextEvent","Accessing Calendar", lul_device)
  luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
  
  DEBUG(3,"Requested url: " .. url)
 
  local body,code,_,status = https.request(url) -- get the calendar data
  
  if (code ~= 200) then -- anything other than 200 is an error
    local errorMessage = "http error code: " .. code
    DEBUG(3,"Http request error. Code : " .. code)
    luup.variable_set(GCAL_SID, "gc_NextEvent",errorMessage , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","", lul_device)
  return nil
  end

  DEBUG(2,"Calendar request status: " .. status)
-- make sure we have well formed json
 local goodjson = string.find(body, "items")
  if (not goodjson) then
    DEBUG(1,"Calendar data problem - no items tag. Retry later...")
    luup.variable_set(GCAL_SID, "gc_NextEvent","Bad Calendar data" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime", "", lul_device)
  return nil 
end

 local noitems = string.find(body, '%"items%"%:% %[%]') -- empty items array
 if (noitems) then
    DEBUG(1,"No event in the next day. Retry later...")
    luup.variable_set(GCAL_SID, "gc_NextEvent","No events found today" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime", "", lul_device)
    luup.variable_set(GCAL_SID, "gc_EventsToday",0, lul_device)
    luup.variable_set(GCAL_SID, "gc_EventsLeftToday",0, lul_device)
    local _ = setTrippedOff(GC.trippedStatus)
  return "No Events" 
end

  DEBUG(2,"Calendar request status: " .. code)


 -- decode the calendar info
 local json_root = json.decode(body)
 
 local events = json_root.items

  if (events[1] == nil) then
    DEBUG(1,"Nil event in the next day. Retry later...")
    luup.variable_set(GCAL_SID, "gc_NextEvent","Nil events found today" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime", "", lul_device)
    luup.variable_set(GCAL_SID, "gc_EventsToday",0, lul_device)
    luup.variable_set(GCAL_SID, "gc_EventsLeftToday",0, lul_device)
    local _ = setTrippedOff(GC.trippedStatus)
  return "No Events"
  end
  luup.variable_set(GCAL_SID, "gc_NextEvent","Calendar Access Success", lul_device)
  luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)

return events -- an table of calendar events
end

function allDay(start)
  -- Get the start time for the event
  local _,_,esHour,_,_ = string.find(start, "(%d+):(%d+):(%d+)")
  local allDayEvent
  if (esHour == nil) then -- an all day event has no hour component
    allDayEvent = os.date("%d %b", strToTime(start))
  else
    allDayEvent = ""
  end
  return allDayEvent
end

function saveEvents(json)
  DEBUG(3,"Function: saveEvents")
  local eventsJson = {}
  local jsonEvents = {}
  local activeEventsJson = {}
  local jsonActiveEvents = {}
  local numberEvents = table.getn(GC.Events)
  
  if numberEvents == 0 then
    luup.variable_set(GCAL_SID, "gc_jsonEvents","[]", lul_device)
    luup.variable_set(GCAL_SID, "gc_jsonActiveEvents","[]", lul_device)
    luup.variable_set(GCAL_SID, "gc_ActiveEvents","", lul_device)
    return
  end
  
  for i = 1,numberEvents do
    -- convert datetime to local time for easier use by others
    jsonEvents = {["eventStart"] = (GC.Events[i][1] + GC.timeZone),["eventEnd"] = (GC.Events[i][2] + GC.timeZone),["eventName"] = GC.Events[i][3],["eventParameter"] = GC.Events[i][4]}
    table.insert(eventsJson, jsonEvents)
  end
  
  local ActiveEvents = ""
  local eventtitle = ""
  local eventparameter = ""
  
  for i = 1,numberEvents do
    if ((GC.Events[i][1] <= GC.utc) and (GC.utc < GC.Events[i][2])) then -- we are inside the event
      eventtitle = GC.Events[i][3]
      eventparameter = GC.Events[i][4]
      if (ActiveEvents == "" ) then
        ActiveEvents = eventtitle
      else  
        ActiveEvents = ActiveEvents .. " , " .. eventtitle
      end
      jsonActiveEvents = {["eventName"] = eventtitle,["eventParameter"] = eventparameter}
      table.insert(activeEventsJson, jsonActiveEvents)
    end
  end
  luup.variable_set(GCAL_SID, "gc_ActiveEvents",ActiveEvents, lul_device)
  DEBUG(3, "Active Events: " .. ActiveEvents)
   
  local eventList =json.encode(eventsJson) -- encode the table for storage as a string
  
  eventList = string.gsub(eventList, '"', "'") -- format the quotes correctly
  luup.variable_set(GCAL_SID, "gc_jsonEvents",eventList, lul_device)
  DEBUG(3,"json event list " .. eventList)

  eventList =json.encode(activeEventsJson) -- encode the table for storage as a string
  eventList = string.gsub(eventList, '"', "'") -- format the quotes correctly
  luup.variable_set(GCAL_SID, "gc_jsonActiveEvents",eventList, lul_device)
  DEBUG(2,"json active event list " .. eventList)
  
  -- log it with sample code
  if (GC.debug == 3) then getjsonEvents(json) end
  
  return
end

function getjsonEvents(json) -- this is really some sample code and useful for debugging
  DEBUG(3,"Function: getjsonEvents")
  local jsonEvents = luup.variable_get(GCAL_SID, "gc_jsonEvents",lul_device)

  if (jsonEvents == "[]") then -- equivalent of a nul so don't try
    return
  end

  local eventList =json.decode(jsonEvents)
  local numberEvents = table.getn(eventList)
  local startevent, startDate, startTime, endevent, endTime, eventname, event
  
  for i = 1,numberEvents do
    startevent = eventList[i].eventStart
    --startEvent = os.date("%Y-%m-%dT%H:%M:%S",startevent)
    startDate = os.date("%Y-%m-%d", startevent)
    startTime = os.date("%H:%M:%S", startevent)
    endevent = eventList[i].eventEnd
    endTime = os.date("%H:%M:%S", endevent)
    eventname = eventList[i].eventName
    event = "On " .. startDate .. " event " .. eventname .. " will start at " .. startTime .. " and end at " .. endTime
    DEBUG(3,"Event " .. i .. ": " .. event)
  end
  return
end

-- ***********************************************************
-- This function extracts the events from the calendar data
-- , does keyword matching where appropriate,
-- interprets start and end offsets, filters out
-- unwanted events
-- ***********************************************************

function getEvents(eventlist, keyword,startdelta, enddelta, ignoreAllDayEvent, ignoreKeyword, exactKeyword)
  DEBUG(3,"Function: getEvents")
  
  -- Create a global array of events. Each row [i] contains:
  -- [i][1] -- starttime in utc
  -- [i][2] -- endtime in utc
  -- [i][3] -- title as uppercase string
  -- [i][4] -- optional parameter as mixed case string
  -- [i][5] -- if All Day event then date in dd Mon format else ""
  -- [i][6] -- unique event end id == concatination of title,endtime
  -- [i][7] -- unique event start id == concatination of title,startime

  luup.variable_set(GCAL_SID, "gc_NextEvent","Checking Events", lul_device)
  luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)

  local globalstartend = "[" .. startdelta .. "," .. enddelta .. "]"

  GC.Events = {} -- reset the Events
  local keywordarray = {}

  -- if one or more keywords, parse them into a usable form
  if (keyword ~= "") then
    local i = 0
    for key in string.gmatch(keyword,"([^;]+)") do
      i = i + 1
      keywordarray[i] = {}
      local _,_,keywordstartend = string.find(key,"%[(.-)%]") -- does the keyword have a start / stop delta i.e. something in []?
      local _,_,keywordparameter = string.find(key,"%{(.-)%}") -- does the keyword have a parameter i.e. something in {}?
      if (keywordstartend ~= nil) then
        keywordarray[i][2] = "[" .. keywordstartend .. "]"
        key = string.gsub(key, "%[(.-)%]", "") -- remove anything in []
      else
        keywordarray[i][2] = ""
      end
      if (keywordparameter ~= nil) then
        keywordarray[i][3] = keywordparameter
        key = string.gsub(key, "%{(.-)%}", "") -- remove anything in {}
      else
        keywordarray[i][3] = ""
      end
      keywordarray[i][1] = trimString(upperCase(key))
    end
  else
    keywordarray[1] = {}
    keywordarray[1][1] = "" -- no keyword
    keywordarray[1][2] = ""
    keywordarray[1][3] = ""
  end

  -- iterate through each of the events and interpret any special instructions
  local numberEvents = table.getn(eventlist)
  DEBUG(2,"There were " .. numberEvents .. " events retrieved")
  local j = 1
  local EventsToday = 0
  local EventsLeftToday = 0
  for i=1,numberEvents do
    
    -- get the start and end times
    local eventStart = (eventlist[i]['start'].date or eventlist[i]['start'].dateTime)
    local allDayEvent = allDay(eventStart) -- flag if all day event
    local starttime = strToTime(eventStart)
    local endtime = strToTime(eventlist[i]['end'].date or eventlist[i]['end'].dateTime)
    
    -- get the title and any start / stop delta or parameter
    local eventname = (eventlist[i]['summary'] or "No Name")
    eventname = trimString(eventname)
    local _,_,eventstartend = string.find(eventname,"%[(.-)%]") -- does the event have a start / stop delta
    local _,_,eventparameter = string.find(eventname,"%{(.-)%}") -- does the event have a parameter
    local eventtitle = string.gsub(eventname, "%{(.-)%}", "") -- remove anything in {}
    eventtitle = string.gsub(eventtitle, "%[(.-)%]", "") -- remove anything in []
    eventtitle= trimString(upperCase(eventtitle)) -- force to upper case and trim

    -- get the description and any start / stop delta or parameter
    local description = (eventlist[i]['description'] or "none")
    description = trimString(upperCase(description))
    local _,_,descriptionstartend = string.find(description,"%[(.-)%]") -- does the description have a start / stop delta
    local _,_,descriptionparameter = string.find(description,"%{(.-)%}") -- does the description have a parameter
    local descriptiontext = string.gsub(description, "%{(.-)%}", "") -- remove anything in {}
    descriptiontext = string.gsub(descriptiontext, "%[(.-)%]", "") -- remove anything in []
    descriptiontext = trimString(upperCase(descriptiontext))

    -- see if we have a keyword match in the title or the desciption
    local matchedEvent = false
    local matchAllEvents = false
    local matchedDescription = false
    local keyindex = 1
    local numkeywords = table.getn(keywordarray)

    if (keyword == "") then -- all events match
        matchAllEvents = true
    else
      for j = 1,numkeywords do
      if (exactKeyword == "true") then -- we test for an exact match
        if ((eventtitle == keywordarray[j][1]) or (descriptiontext == keywordarray[j][1])) then
          matchedEvent = true
          keyindex = j
          break
        end
      else -- we test for a loose match
        matchedEvent = string.find(eventtitle,keywordarray[j][1])
        matchedDescription = string.find(descriptiontext,keywordarray[j][1])
        matchedEvent = matchedEvent or matchedDescription
        if matchedEvent then
          keyindex = j
          break
        end
      end
      end
  end

  -- add start/end delta if specified
  local effectiveEventName
  eventname = eventtitle

  if (matchedEvent and (keywordarray[keyindex][2] ~= "")) then -- offset specified for the keyword takes precedence
    eventname = eventname .. keywordarray[keyindex][2]
  elseif (eventstartend ~= nil) then
    eventname = eventname .. "[" .. eventstartend .. "]"
  elseif (descriptionstartend ~= nil) then
    eventname = eventname .. "[" .. descriptionstartend .. "]"
  else -- use the global value
    eventname = eventname .. globalstartend
  end

  -- add parameter if specified
  local value = ""
  if (matchedEvent and (keywordarray[keyindex][3] ~= "")) then -- parameter specified for the keyword takes precedence
    value = trimString(keywordarray[keyindex][3])
  elseif (eventparameter ~= nil) then
    value = trimString(eventparameter)
  elseif (descriptionparameter ~= nil) then
    value = trimString(descriptionparameter)
  end

  effectiveEventName = eventname .. "{" ..value .. "}" -- this normalizes the 'value' parameter
  DEBUG(3,"Effective Event Name " .. effectiveEventName)

  -- apply any start end offsets
  local _,_,startoffset,endoffset = string.find(eventname,"%[%s*([+-]?%d+)%s*,%s*([+-]?%d+)%s*%]") -- look in the title
  startoffset = tonumber(startoffset)
  endoffset = tonumber(endoffset)
  if (startoffset and endoffset) then
    starttime = starttime + (startoffset * 60)
    endtime = endtime + (endoffset * 60)
  end

  -- filter out unwanted events
  if ((ignoreAllDayEvent == "true") and (allDayEvent ~= "")) then -- it's an all day event and to be ignored
    DEBUG(2,"All Day Event " .. effectiveEventName .. " Ignored")
  elseif ((ignoreKeyword == "true") and matchedEvent) then -- matched keyword and to be ignored
    DEBUG(2,"Event matched keyword " .. effectiveEventName .. " Ignored")
  elseif ((endtime - starttime) < 60) then -- event must be at least 1 minute
    DEBUG(2,"Event less than 1 minute: " .. effectiveEventName .. " Ignored")
  elseif ((not matchAllEvents and matchedEvent) or matchAllEvents or (ignoreKeyword == "true") ) then -- good to go
    
    -- add a new entry into the list of valid events
    GC.Events[j] = {}
    GC.Events[j][1] = starttime
    GC.Events[j][2] = endtime
    GC.Events[j][3] = eventtitle
    GC.Events[j][4] = value
    if ((startoffset == 0) and (endoffset == 0)) then
      GC.Events[j][5] = allDayEvent
    else
      GC.Events[j][5] = ""
    end
    local ta = os.date("*t", endtime + GC.timeZone)
    local s1 = string.format("%02d/%02d %02d:%02d",ta.month, ta.day, ta.hour, ta.min)
    GC.Events[j][6] = eventtitle .. " " ..s1
    ta = os.date("*t", starttime + GC.timeZone)
    s1 = string.format("%02d/%02d %02d:%02d",ta.month, ta.day, ta.hour, ta.min)
    GC.Events[j][7] = eventtitle .. " " ..s1
    j = j + 1
    if (((starttime >= GC.startofDay) and (starttime <= GC.endofDay)) or ((endtime >= GC.startofDay) and (endtime <= GC.endofDay)))   then
      EventsToday = EventsToday + 1
    end
    if (((starttime > GC.utc + 1) and (starttime < GC.endofDay)) or ((endtime > GC.utc + 1) and ((endtime - 2) < GC.endofDay))) then -- minus 2 sec to catch all day event
      EventsLeftToday = EventsLeftToday + 1
    end
  end
  end
  -- sort the events by time
  table.sort(GC.Events, compare)
 
  DEBUG(3, "Events Today = " .. tostring(EventsToday))
  DEBUG(3, "Events Left Today = " .. tostring(EventsLeftToday))
  luup.variable_set(GCAL_SID, "gc_EventsToday",EventsToday, lul_device)
  luup.variable_set(GCAL_SID, "gc_EventsLeftToday",EventsLeftToday, lul_device)
end

-- ************************************************************
-- This function determines if there is an event to trigger on
-- ************************************************************

function nextEvent()
  local eventtitle = "No more events today"
  local nextEventTime = ""
  local nextEvent = -1
  local index
  local numberEvents = table.getn(GC.Events)

  GC.nextTimeCheck = GC.now + GC.Interval
  
  for i = 1,numberEvents do
    if ((GC.Events[i][1] <= GC.utc) and (GC.utc < GC.Events[i][2])) then -- we are inside the first event
      nextEvent = i
      index = i
      eventtitle = GC.Events[i][3]
      GC.nextTimeCheck = GC.Events[i][2] + GC.timeZone -- in local time
    break
    elseif ((nextEvent == -1) and (GC.Events[i][1] > GC.utc)) then -- future event
      nextEvent = 0
      index = i
      eventtitle = GC.Events[i][3]
      GC.nextTimeCheck = GC.Events[i][1] + GC.timeZone -- in local time
      break -- only need the first one
    end
  end
  -- check for nested or overlap events
  if (nextEvent > 0) then
  for i = 1,numberEvents do
    if (GC.Events[i][1] > GC.Events[index][1]) and (GC.Events[i][1] < GC.Events[index][2]) then -- start time inside next event
      if (((GC.Events[i][1] + GC.timeZone) < GC.nextTimeCheck) and (GC.Events[i][1] > GC.utc)) then -- select the earliest time in the future
        GC.nextTimeCheck = GC.Events[i][1] + GC.timeZone
      end
    end
    if (GC.Events[i][2] > GC.Events[index][1]) and (GC.Events[i][2] < GC.Events[index][2]) then -- end time inside next event
      if (((GC.Events[i][2] + GC.timeZone) < GC.nextTimeCheck) and (GC.Events[i][2] > GC.utc)) then -- select the earliest time in the future
        GC.nextTimeCheck = GC.Events[i][2] + GC.timeZone
      end
    end
  end
  end
  if (nextEvent ~= -1) then
    nextEventTime = os.date("%H:%M %b %d", GC.Events[index][1] + GC.timeZone) .. " to " .. os.date("%H:%M %b %d", GC.Events[index][2] + GC.timeZone)
  end
  luup.variable_set(GCAL_SID, "gc_NextEvent",eventtitle , lul_device)
  luup.variable_set(GCAL_SID, "gc_NextEventTime",nextEventTime , lul_device)
  DEBUG(2,"Next Event: " .. eventtitle .. " -- " .. nextEventTime)
  return nextEvent
end

function setTrippedOff(tripped)
  DEBUG(3,"Function: setTrippedOff")
  
  luup.variable_set(GCAL_SID, "gc_Value", "", lul_device)
  GC.trippedEvent = ""
  luup.variable_set(GCAL_SID, "gc_TrippedEvent",GC.trippedEvent, lul_device)
  
  if (tonumber(tripped) == 1) then
    luup.variable_set(SECURITY_SID, "Tripped", 0, lul_device)
    DEBUG(1,"Event-End " .. GC.trippedID .. " Finished")
  else
    DEBUG(1,"Event-End " .. GC.trippedID .. " Inactive")
  end
  
  GC.trippedID = ""
  luup.variable_set(GCAL_SID, "gc_TrippedID", GC.trippedID, lul_device)
  luup.variable_set(GCAL_SID, "gc_displaystatus",0, lul_device) 
end

function setTripped(i, tripped)
  GC.trippedIndex = i
  if ((GC.Events[i][6] == GC.trippedID)) then -- in the same event
    if (tonumber(tripped) == 1) then
      DEBUG(1,"Event-Start " .. GC.Events[i][7] .. " is already Tripped")
    else
      DEBUG(1,"Event-Start " .. GC.Events[i][7] .. " is already Active")
    end
    return
  end

  if (tonumber(tripped) == 1 and (GC.Events[i][6] ~= GC.trippedID)) then -- logically a new event
    if ((GC.Events[i][7] == GC.trippedID) and (GC.retrip == "false")) then
      -- if the name and time for the start of the next event = the prior event finish and we should not retrip
      GC.trippedID = GC.Events[i][6] -- update with the continuation event
      luup.variable_set(GCAL_SID, "gc_TrippedID",GC.trippedID, lul_device)
      DEBUG(1,"Continuing Event-End " .. GC.trippedID)
      return
    else -- finish the previous and start the new event
      tripped = setTrippedOff(1)
      DEBUG(2,"waiting 15 sec to trigger the next event")
      luup.call_timer("setTrippedOn",1,15,"","") -- wait 15 sec for the off status to propogate
    end
    return
  end
  if (tonumber(tripped) == 0) then
    tripped = setTrippedOff(0) -- could have been a non-tripped but active event
    DEBUG(2,"waiting 15 sec to activate the next event")
    luup.call_timer("setTrippedOn",1,15,"","") -- wait 15 sec for the off status to propogate
    --tripped = setTrippedOn()
  end
end

function setTrippedOn()
  local i = GC.trippedIndex

  luup.variable_set(GCAL_SID, "gc_NextEvent", GC.Events[i][3], lul_device)
  luup.variable_set(GCAL_SID, "gc_Value", GC.Events[i][4], lul_device)
  GC.trippedEvent = GC.Events[i][3]
  luup.variable_set(GCAL_SID, "gc_TrippedEvent",GC.trippedEvent, lul_device)
  GC.trippedID = GC.Events[i][6] -- the end id for the event
  luup.variable_set(GCAL_SID, "gc_TrippedID",GC.trippedID, lul_device)
  
  if (GC.Keyword ~= "") or (GC.triggerNoKeyword == "true") then
    luup.variable_set(SECURITY_SID, "Tripped", 1, lul_device)
    luup.variable_set(GCAL_SID, "gc_displaystatus",100, lul_device)
    DEBUG(1,"Event-Start " .. GC.Events[i][7] .. " Tripped")
  else
  luup.variable_set(GCAL_SID, "gc_displaystatus",50, lul_device)
    DEBUG(1,"Event-Start " .. GC.Events[i][7] .. " Active")
  end
end

function setNextTimeCheck()
  if ((GC.nextTimeCheck - GC.now) > GC.Interval) then -- min check interval is gc_Interval
    GC.nextTimeCheck = GC.now + GC.Interval
  end
  if (GC.nextTimeCheck == GC.now) then -- unlikely but could happen
    GC.nextTimeCheck = GC.now + 10 -- check again in 10 seconds
  end
  if (GC.nextTimeCheck > (GC.endofDay + GC.timeZone)) then -- force a check at midnight each day
    GC.nextTimeCheck = GC.endofDay + GC.timeZone + 2 -- 1 second after midnight
  end
  return (GC.nextTimeCheck - GC.now)
end

-- ********************************************************************
-- This is the plugin execution sequence
-- ********************************************************************

function checkGCal(https, json) -- this is the main program loop
  --get the value of variables that may have changed during a reload
  GC.trippedID = luup.variable_get(GCAL_SID, "gc_TrippedID", lul_device)
  GC.trippedEvent = luup.variable_get(GCAL_SID, "gc_TrippedEvent", lul_device)
  GC.trippedStatus = luup.variable_get(SECURITY_SID, "Tripped", lul_device)
  GC.Interval = luup.variable_get(GCAL_SID,"gc_Interval", lul_device)
  GC.Interval = tonumber(GC.Interval) * 60 -- convert to seconds since it's specified in minutes
  luup.variable_set(GCAL_SID, "gc_jsonEvents","[]", lul_device) -- reset the variable


  -- to avoid race conditions if there are multiple plugin instances
  -- we set set up a semaphore using a file
  if not getSemaphore() then
    return 5 -- could not get semaphore so try again later
  end  
 
  -- get the start and stop window for requesting events from google
  local startmin, startmax = getStartMinMax(GC.StartDelta,GC.EndDelta)
  local events = nil 
  
  -- get the calendar information
  if GC.ical then
    events = requestiCalendar(startmin, startmax, https)
  else
    events = requestCalendar(startmin, startmax, https, json)
  end
  
  local _ = releaseSemaphore("calendar check complete")

  if (events == nil) then -- error from calendar
    GC.nextTimeCheck = GC.now + GC.Interval
    return setNextTimeCheck()
  end

  if (events == "No Events") then -- request succeeded but no events were found
    if (tonumber(GC.trippedStatus) == 1) then -- plugin was tripped and no events today
      local _ = setTrippedOff(GC.trippedStatus)
    end
    GC.nextTimeCheck = GC.now + GC.Interval
    return setNextTimeCheck()
  end

  -- get all the events in the current calendar window
  local _ = getEvents(events, GC.Keyword, GC.StartDelta, GC.EndDelta, GC.ignoreAllDayEvent, GC.ignoreKeyword, GC.exactKeyword)

  -- update time since there may have been a semaphore or calendar related delay
  GC.now = os.time()
  GC.utc = GC.now - GC.timeZone

  -- save a events, both calendar and active
  local _ = saveEvents(json)
    
  -- identify the active or next event
  local numActiveEvent = nextEvent()

  if (tonumber(numActiveEvent) < 1) then -- there were no active events so make sure any previous are off
    DEBUG(3,"Cancel any active event")
    GC.trippedStatus = setTrippedOff(GC.trippedStatus)
  else
    GC.trippedStatus = setTripped(numActiveEvent, GC.trippedStatus)
  end

  -- when to do the next check
  local delay = setNextTimeCheck()

  return delay
end

-- ********************************************************************
-- This is the main program loop - it repeats by calling itself
-- (non-recursive) using the luup.call_timer at interval determined
-- from either event start / finish times or a maximum interval
-- set by gc_Interval
-- ********************************************************************
function parseCalendarID(newID)
  luup.variable_set(GCAL_SID, "gc_CalendarID","", lul_device)
  GC.CalendarID = ""
  GC.ical = false
  newID = string.gsub(newID,'%%','%%25') -- encode any %
  newID = string.gsub(newID,'%&','%%26') -- encode any &
  newID = string.gsub(newID,'#','%%23')  -- encode any #
  newID = string.gsub(newID,'+','%%2B')  -- encode any +
  newID = string.gsub(newID,'@','%%40')  -- encode any @
 if (string.find(newID,"ical") or string.find(newID,"iCal")) then -- treat as a public ical
   GC.CalendarID = newID
   GC.ical = true
 else -- a regular google calendar   
 -- there are several forms of the calendar url so we try to make a good one 
  if string.find(newID,'(.-)src="http') then -- eliminate anything before src="http
    newID = string.gsub(newID,'(.-)src="http',"")
    newID = "http" .. newID
  end
  if string.find(newID,'calendar.google.com(.*)') then -- eliminate anything after calendar.google.com
    newID = string.gsub(newID,'calendar.google.com(.*)',"")
    newID = newID .. "calendar.google.com"
  end
  if string.find(newID,'gmail.com(.*)') then -- eliminate anything after gmail.com
    newID = string.gsub(newID,'gmail.com(.*)',"")
    newID = newID .. "gmail.com"
  end
  GC.CalendarID = string.gsub(newID,'(.*)%?src=',"") -- ?src=
  GC.CalendarID = string.gsub(GC.CalendarID,'(.*)%%26src=',"") -- &src=
  -- newID = url_decode(newID)
 end

  luup.variable_set(GCAL_SID, "gc_CalendarID", newID, lul_device)
  DEBUG(3,"Calendar ID is: " .. GC.CalendarID)
end

function GCalMain()
  local delay
  local lastCheck , nextCheck
  GC.now = os.time()
  GC.utc = GC.now - GC.timeZone
  lastCheck = os.date("%Y-%m-%d at %H:%M:%S", GC.now)
  luup.variable_set(GCAL_SID, "gc_lastCheck", lastCheck, lul_device)
  
  local  https = require("ssl.https")
  https.timeout = 30
  local json = require("json")
  
  delay = checkGCal(https, json)
  
  package.loaded.https = nil
  package.loaded.json = nil
  
  nextCheck = os.date("%Y-%m-%d at %H:%M:%S", GC.now + delay)
  luup.variable_set(GCAL_SID, "gc_nextCheck", nextCheck , lul_device)
  DEBUG(1,"Next check will be in " .. delay .. " sec on " .. nextCheck)
  delay = tonumber(delay)
  luup.call_timer("GCalMain", 1,delay,"","")
end

-- ****************************************************************
-- startup and related functions are all here
-- ****************************************************************

function getTimezone()
  local now = os.time()
  local date = os.date("!*t", now)
  date.isdst = os.date("*t").isdst
  local tz = (now - os.time(date))
  local tzhr = math.floor(tz/3600) -- whole hour
  local tzmin = math.floor(tz%3600/60 + 0.5) -- nearest integer 
  if (tzhr < 0) then
    tzmin = -tzmin
  end
  DEBUG(3, GC.debugPre .. "Timezone is " ..tzhr .. " hrs and " .. tzmin .. " min")
  return tz, tzhr, tzmin
end

function setupVariables()
  -- Because variables do not exist before the first "variable_set"
  -- They are created here in the order that we want them to appear in the Advanced Tab
  local s1 = ""
  local n1 = 0
  n1 = luup.variable_get(SECURITY_SID, "Armed", lul_device)
  n1 = tonumber(n1) or 0
  luup.variable_set(SECURITY_SID, "Armed",n1, lul_device)

  n1 = luup.variable_get(SECURITY_SID, "Tripped", lul_device)
  n1 = tonumber(n1) or 0
  luup.variable_set(SECURITY_SID, "Tripped",n1, lul_device)

  s1 = luup.variable_get(GCAL_SID, "gc_TrippedEvent", lul_device)
  if (s1 == nil) then s1 = "" end
  luup.variable_set(GCAL_SID, "gc_TrippedEvent",s1, lul_device)
    
  s1 = luup.variable_get(GCAL_SID, "gc_TrippedID", lul_device)
  if (s1 == nil) then s1 = "" end
  luup.variable_set(GCAL_SID, "gc_TrippedID",s1, lul_device)

  s1 = luup.variable_get(GCAL_SID, "gc_Value", lul_device)
  if (s1 == nil) then s1 = "" end
  luup.variable_set(GCAL_SID, "gc_Value",s1, lul_device)

  luup.variable_set(GCAL_SID, "gc_NextEvent","", lul_device)

  luup.variable_set(GCAL_SID, "gc_NextEventTime","", lul_device)

  n1 = luup.variable_get(GCAL_SID,"gc_Interval", lul_device)
  if ((n1 == nil) or (tonumber(n1) < 1)) then n1 = 180 end -- defaults to 3 hrs
  luup.variable_set(GCAL_SID, "gc_Interval",n1, lul_device)
  GC.Interval = n1

  n1 = luup.variable_get(GCAL_SID, "gc_StartDelta", lul_device)
  n1 = tonumber(n1) or 0
  luup.variable_set(GCAL_SID, "gc_StartDelta",n1, lul_device)
  GC.StartDelta = n1

  n1 = luup.variable_get(GCAL_SID, "gc_EndDelta", lul_device)
  n1 = tonumber(n1) or 0
  luup.variable_set(GCAL_SID, "gc_EndDelta",n1, lul_device)
  GC.EndDelta = n1

  s1 = luup.variable_get(GCAL_SID, "gc_Keyword", lul_device)
  if (s1 == nil) then s1 = "" end
  luup.variable_set(GCAL_SID, "gc_Keyword",s1, lul_device)
  GC.Keyword = s1

  s1 = luup.variable_get(GCAL_SID, "gc_exactKeyword", lul_device)
  if (s1 ~= "false") then s1 = "true" end
  luup.variable_set(GCAL_SID, "gc_exactKeyword",s1, lul_device)
  GC.exactKeyword = s1

  s1 = luup.variable_get(GCAL_SID, "gc_ignoreKeyword", lul_device)
  if (s1 ~= "true") then s1 = "false" end
  luup.variable_set(GCAL_SID, "gc_ignoreKeyword",s1, lul_device)
  GC.ignoreKeyword = s1
  
  s1 = luup.variable_get(GCAL_SID, "gc_triggerNoKeyword", lul_device)
  if (s1 ~= "true") then s1 = "false" end
  luup.variable_set(GCAL_SID, "gc_triggerNoKeyword",s1, lul_device)
  GC.triggerNoKeyword = s1

  s1 = luup.variable_get(GCAL_SID, "gc_ignoreAllDayEvent", lul_device)
  if (s1 ~= "true") then s1 = "false" end
  luup.variable_set(GCAL_SID, "gc_ignoreAllDayEvent",s1, lul_device)
  GC.ignoreAllDayEvent = s1

  s1 = luup.variable_get(GCAL_SID, "gc_retrip", lul_device)
  if (s1 ~= "false") then s1 = "true" end
  luup.variable_set(GCAL_SID, "gc_retrip",s1, lul_device)
  GC.retrip = s1

  s1 = luup.variable_get(GCAL_SID, "gc_CalendarID", lul_device)
  if (s1 == nil) then s1 = "" end
  luup.variable_set(GCAL_SID, "gc_CalendarID",s1, lul_device)
  if (string.find(s1,"ical") or string.find(s1,"iCal")) then -- treat as a public ical
   GC.CalendarID = s1
   GC.ical = true
  else
   GC.CalendarID = string.gsub(s1,"(.-)?src=","")
  end
  
  s1 = luup.variable_get(GCAL_SID, "gc_jsonEvents", lul_device)
  if (s1 ~= "[]") then s1 = "[]" end
  luup.variable_set(GCAL_SID, "gc_jsonEvents",s1, lul_device)
  
  s1 = luup.variable_get(GCAL_SID, "gc_jsonActiveEvents", lul_device)
  if (s1 ~= "[]") then s1 = "[]" end
  luup.variable_set(GCAL_SID, "gc_jsonActiveEvents",s1, lul_device)
  
  s1 = luup.variable_get(GCAL_SID, "gc_ActiveEvents", lul_device)
  if (s1 == nil) then s1 = "" end
  luup.variable_set(GCAL_SID, "gc_ActiveEvents",s1, lul_device)

   n1 = luup.variable_get(GCAL_SID, "gc_EventsToday", lul_device)
  n1 = tonumber(n1) or 0
  luup.variable_set(GCAL_SID, "gc_EventsToday",n1, lul_device)
   
  n1 = luup.variable_get(GCAL_SID, "gc_EventsLeftToday", lul_device)
  n1 = tonumber(n1) or 0
  luup.variable_set(GCAL_SID, "gc_EventsLeftToday",n1, lul_device)
   
  s1 = luup.variable_get(GCAL_SID, "gc_lastCheck", lul_device)
  if (s1 == nil) then s1 = os.date("%Y-%m-%dT%H:%M:%S", os.time()) end
  luup.variable_set(GCAL_SID, "gc_lastCheck",s1, lul_device)

  s1 = luup.variable_get(GCAL_SID, "gc_nextCheck", lul_device)
  if (s1 == nil) then s1 = os.date("%Y-%m-%dT%H:%M:%S", os.time()) end
  luup.variable_set(GCAL_SID, "gc_nextCheck",s1, lul_device)

  n1 = luup.variable_get(GCAL_SID, "gc_debug", lul_device)
  n1 = tonumber(n1) or 1
  luup.variable_set(GCAL_SID, "gc_debug",n1, lul_device)
  GC.debug = n1
  
  n1 = luup.variable_get(GCAL_SID, "gc_displaystatus", lul_device)
  n1 = tonumber(n1) or 0
  if (n1 > 100) then n1 = 100 end
  luup.variable_set(GCAL_SID, "gc_displaystatus",n1, lul_device)

end

function GCalStartup(delayed)
  GC.lul_device = tostring(luup.device)
  DEBUG(3,"Delay = " .. (delayed or "not set"))
  if (delayed ~= "delayedstart") then
   DEBUG(3,"Device # " .. GC.lul_device .. " initializing")
 
    -- make sure we have a plugin specific directory
    local command = "ls " .. GC.pluginpath 
    local result = os.execute(command)
    DEBUG(3,"Command " .. command .. " returned " ..result)
  
    if (result ~= 0) then -- if the directory does not exist, it gets created
      command = "mkdir " .. GC.pluginpath 
      result = os.execute(command)
      DEBUG(3,"Command " .. command .. " returned " ..result)
      if (result ~= 0) then
       DEBUG(1, "Fatal Error could not create plugin directory")
      return
      end
    end
    -- force a reset of the semaphore file
    command = "rm -f " .. GC.semfile 
    result = os.execute(command)
    DEBUG(3,"Command " .. command .. " returned " ..result)
    
    -- clean up any token files from previous version
    command = "rm -f  " .. "*.token" 
    result = os.execute(command)
    DEBUG(3,"Command " .. command .. " returned " ..result)
    
    -- clean up the old script file
    command = "rm -f  " .. GC.jwt 
    result = os.execute(command)
    DEBUG(3,"Command " .. command .. " returned " ..result)
    
    luup.call_timer("GCalStartup", 1,2,"","delayedstart")
    return
  end

   
  if not getSemaphore() then
    luup.variable_set(GCAL_SID, "gc_NextEvent","Waiting for startup" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
    luup.call_timer("GCalStartup", 1,10,"","delayedstart") -- could not get semaphore try later
    return 
  end

  -- Initialize all the plugin variables
  local _ = setupVariables()
  DEBUG(1,GC.debugPre .. "Variables initialized ...")

  -- check to see if we have json.lua module
  local command = "ls " .. GC.jsonlua
  local result = os.execute(command)
  DEBUG(3,"Command " .. command .. " returned " ..result)
  
  if (result ~= 0) then
    local location = "http://code.mios.com/trac/mios_google_calendar_ii_plugin/raw-attachment/wiki/WikiStart/json.lua"
    result = getfile(GC.jsonlua,location)
    if (not result) then 
      luup.variable_set(GCAL_SID, "gc_NextEvent","Fatal error: " .. GC.jsonlua , lul_device)
      luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
      DEBUG(3, "Fatal Error - Could not download file" .. GC.jsonlua)
      local _ = releaseSemaphore("Fatal Error getting json.lua")
    return
    end
  end
  
   -- check to see if openssl is on the system
    local stdout = io.popen("opkg list-installed | awk '/openssl-util/ {print $3}'")
    local version = stdout:read("*a")
    version = version:match("([^%s]+)") or false
    stdout:close()
    DEBUG(3, "Existing openssl version is: " .. tostring(version))
    if not version then
      DEBUG(3,"Installing openssl")
      local command = "opkg update && opkg install openssl-util"  -- install the default version for the vera model
      -- 'http://downloads.openwrt.org/attitude_adjustment/12.09/ramips/rt3883/packages/openssl-util_1.0.1e-1_ramips.ipk'
      local result = os.execute (command)
      DEBUG(3,"Command " .. command .. " returned " ..tostring(result))
      if (result ~= 0) then
        luup.variable_set(GCAL_SID, "gc_NextEvent","Fatal error: openssl" , lul_device)
        luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
        DEBUG(3,"Fatal error could not install openssl")
        local _ = releaseSemaphore("Fatal error getting openssl")
      return
      end
    end

  --check for new credentials file
  local json = require("json")
  local credentials = checkforcredentials(json)
  package.loaded.json = nil
  if not credentials then
    luup.variable_set(GCAL_SID, "gc_NextEvent","Fatal error: credentials" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
    DEBUG(1, "Fatal Error - Could not get credentials")
      local _ = releaseSemaphore("Fatal error getting credentials")
    return
  end
   
    -- Check to make sure there is a Calendar ID else stop the plugin
  if (GC.CalendarID == "") then
    luup.variable_set(GCAL_SID, "gc_NextEvent","The CalendarID is not set" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
    DEBUG(1,GC.debugPre .. "The Calendar ID is not set ...")
    local _ = releaseSemaphore("No Calendar ID")
  return
  end

  -- Get the Time Zone info
  GC.timeZone, GC.timeZonehr, GC.timeZonemin = getTimezone()

  -- warp speed Mr. Sulu
  DEBUG(1,GC.debugPre .. "Running Plugin ...")
  luup.variable_set(GCAL_SID, "gc_NextEvent","Successfully Initialized" , lul_device)
  luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
  luup.call_timer("GCalMain",1,2,"","")
  
  local _ = releaseSemaphore("initialization complete")
  
end
