local json = require("dkjson")
local  https = require("ssl.https")

local GCAL_VERSION = "V 2.0"
local GCAL_SID = "urn:srs-com:serviceId:GCalIII"
local SECURITY_SID = "urn:micasaverde-com:serviceId:SecuritySensor1"
local SWITCHPWR_SID = "urn:upnp-org:serviceId:SwitchPower1"
local EMAIL_DEVICE_ID
local LUL_DEVICE
-- Variables that are 'global' for this plugin
local GC = {}
--Setup and file variables
CALENDAR_ID = ""
CLIENT_EMAIL = ""

GC.plugin_name = "GCal3" -- Do not change for this plugin

GC.libpath = "/usr/lib/lua/" -- default vera directory for modules
GC.basepath = "/etc/cmh-ludl/" -- default vera directory for uploads
GC.credentialfile = GC.plugin_name .. ".json"
GC.pemfile = "/tmp/" .. GC.plugin_name ..".pem" -- certificate to this file

-- Main plugin Variables
GC.timeZone = 0
GC.timeZonehr = 0
GC.timeZonemin = 0
GC.debug = 2 -- initial default, catches everything before variables initialized
GC.debugPre = "GCal3 " ..GCAL_VERSION .. ":"
GC.description = ""
GC.access_token = ""
GC.interrupt = 1
GC.handle = 0
GC.Interval = 60 * 60 * 6



-- Utility Functions
function DEBUG(level,s)
  if (level <= GC.debug) then
    s = GC.debugPre .. s
    luup.log(s)
  end
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
    luup.variable_set(GCAL_SID, "gc_NextEvent",string.gsub(filename,"/(.*)/","") .. " ??" , LUL_DEVICE)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , LUL_DEVICE)
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

function sendMail(subject, body)
  if EMAIL_DEVICE_ID == nil or EMAIL_DEVICE_ID == "" then
    return
  end
  luup.call_action( "urn:upnp-smtp-svc:serviceId:SND1", "SendMail", { subject = subject, body = body }, EMAIL_DEVICE_ID)
end

-- Authorization related functions
function checkforcredentials()
  DEBUG(3,"Function: checkforcredentials")

  local contents = readfromfile(GC.basepath .. GC.credentialfile)

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

  --make sure we have a pem file file
  command = "ls " ..  GC.pemfile
  result = os.execute(command)
  if result ~= 0 then
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
  CLIENT_EMAIL = credentials.client_email
  return true
end

function get_access_token()
  if (GC.access_token ~= nil and GC.access_token ~= "") then
    local url = "https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=" .. GC.access_token

    local body, code, _,status = https.request(url) -- check the token status
    if (status == nil or code == nil) then
      --request failed
      return nil
    end
    if (code ==200) then
      local tokencheck = json.decode(body)
      local time_to_expire = tokencheck.expires_in
      DEBUG(2,"Token will expire in " .. time_to_expire .." sec")
      if (time_to_expire > 10) then -- 10 seconds gives us some leeway
        return GC.access_token -- the current token was still valid
      end
    end
    DEBUG(2,"Token Info request status: " .. status)
  end

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

  local iss = CLIENT_EMAIL
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


function getStartMinMax()
  local now = os.time()
  local ta = os.date("!*t", now)
  local s1 = string.format("%d-%02d-%02dT%02d:%02d:%02d.000Z", ta.year, ta.month, ta.day, ta.hour, ta.min, ta.sec)
  ta = os.date("!*t", now + GC.Interval)
  s2 = string.format("%d-%02d-%02dT%02d:%02d:%02d.000Z", ta.year, ta.month, ta.day, ta.hour, ta.min, ta.sec)
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

function requestCalendar(startmin, startmax)
  DEBUG(3,"Function: requestCalendar")

  if (CALENDAR_ID == nil) then
    DEBUG(3,"Calendar ID is not set.")
    luup.variable_set(GCAL_SID, "gc_NextEvent","Missing Calendar ID", LUL_DEVICE)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , LUL_DEVICE)
    return nil
  end

  GC.access_token = get_access_token ()
  if GC.access_token == nil then
    GC.access_token = ""
    luup.variable_set(GCAL_SID, "gc_NextEvent","Fatal error - access token", LUL_DEVICE)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , LUL_DEVICE)
    DEBUG(1,"Fatal error trying to get access token")
  return nil
  end

  DEBUG(2,"Checking google calendar")

  local url = "https://www.googleapis.com/calendar/v3/calendars/".. CALENDAR_ID .. "/events?"
  url = url .. "access_token=" .. GC.access_token .. "&timeZone=utc"
  url = url .. "&singleEvents=true&orderBy=startTime"
  url = url .. "&timeMax=" .. startmax .. "&timeMin=" .. startmin
  url = url .. "&fields=items(summary%2Cend%2Cstart%2Clocation)"

  DEBUG(3,"Requested url: " .. url)

  local body,code,_,status = https.request(url) -- get the calendar data

  if (code ~= 200) then -- anything other than 200 is an error
    local errorMessage = "http error code: " .. code
    DEBUG(3, errorMessage)
    sendMail(errorMessage, errorMessage)
    luup.variable_set(GCAL_SID, "gc_NextEvent", errorMessage , LUL_DEVICE)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","", LUL_DEVICE)
  return nil
  end

  DEBUG(2,"Calendar request status: " .. status)
  -- make sure we have well formed json
  local goodjson = string.find(body, "items")
  if (not goodjson) then
      DEBUG(1,"Calendar data problem - no items tag. Retry later...")
      sendMail("Calendar data problem - no items tag", body)
      luup.variable_set(GCAL_SID, "gc_NextEvent","Bad Calendar data" , LUL_DEVICE)
      luup.variable_set(GCAL_SID, "gc_NextEventTime", "", LUL_DEVICE)
    return nil
  end

  local noitems = string.find(body, '%"items%"%:% %[%]') -- empty items array
  if (noitems) then
    DEBUG(1,"No event in the next day. Retry later...")
    luup.variable_set(GCAL_SID, "gc_NextEvent","No events found today" , LUL_DEVICE)
    luup.variable_set(GCAL_SID, "gc_NextEventTime", "", LUL_DEVICE)
    return "No Events"
  end

  DEBUG(2,"Calendar request status: " .. code)
  -- decode the calendar info
  local json_root = json.decode(body)
  local events = json_root.items

  if (events[1] == nil) then
    DEBUG(1,"Nil event in the next day. Retry later...")
    luup.variable_set(GCAL_SID, "gc_NextEvent","Nil events found today" , LUL_DEVICE)
    luup.variable_set(GCAL_SID, "gc_NextEventTime", "", LUL_DEVICE)
    return "No Events"
  end
  return events
end

function getEvent(eventlist)
  DEBUG(3,"Function: getEvent")

  -- iterate through each of the events and interpret any special instructions
  local numberEvents = table.getn(eventlist)
  DEBUG(2,"There were " .. numberEvents .. " events retrieved")

  for i=1,numberEvents do
    -- get the start and end times

    local starttime = strToTime(eventlist[i]['start'].date or eventlist[i]['start'].dateTime) + GC.timeZone
    local endtime   = strToTime(eventlist[i]['end'].date or eventlist[i]['end'].dateTime) + GC.timeZone

    -- get the title and any start / stop delta or parameter
    local eventname = (eventlist[i]['summary'] or "No Name")
    local location = (eventlist[i]['location'] or "None")

    local DEVICE_ID= string.match(location, "(.*):%d+")
    local DEVICE_NO= string.match(location, ".*:(%d+)")

    if (DEVICE_ID == "switch") then
         return { eventname, starttime, endtime, SWITCHPWR_SID, DEVICE_NO }
    end
  end
end

function checkGCal()
  local startmin, startmax = getStartMinMax()
  local events = nil

  events = requestCalendar(startmin, startmax)

  if (events == nil) then -- error from calendar
    DEBUG(3, "GCAL: Unable to retreive google calendar datas. Retry later...")
    return GC.Interval, "error", ""
  end

  if (events == "No Events") then -- request succeeded but no events were found
    DEBUG(3, "GCAL: No events in the next time window. Retry later...")
    return GC.Interval, "timeout", ""
  end

  local gcalval = getEvent(events)

  if (gcalval == nil) then -- error from calendar
    DEBUG(3, "GCAL: No event in the next time window. Retry later...")
    return GC.Interval, "timeout", ""
  end

  -- Compute the delay in seconds before the next event starts
  local now = os.time()
  local diff_start = gcalval[2] - now
  local diff_end = gcalval[3] - now

  --event has already started
  if (diff_start < 0) then
        if (GC.Interval < diff_end) then
          return GC.Interval, "timein", gcalval
        else
          return diff_end, "end", gcalval
        end
  end

  return diff_start, "start", gcalval
end

function parseCalendarID(newID)
  luup.variable_set(GCAL_SID, "gc_CalendarID","", LUL_DEVICE)
  CALENDAR_ID = ""
  GC.ical = false
  newID = string.gsub(newID,'%%','%%25') -- encode any %
  newID = string.gsub(newID,'%&','%%26') -- encode any &
  newID = string.gsub(newID,'#','%%23')  -- encode any #
  newID = string.gsub(newID,'+','%%2B')  -- encode any +
  newID = string.gsub(newID,'@','%%40')  -- encode any @
 if (string.find(newID,"ical") or string.find(newID,"iCal")) then -- treat as a public ical
   CALENDAR_ID = newID
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
  CALENDAR_ID = string.gsub(newID,'(.*)%?src=',"") -- ?src=
  CALENDAR_ID = string.gsub(CALENDAR_ID,'(.*)%%26src=',"") -- &src=
 end

  luup.variable_set(GCAL_SID, "gc_CalendarID", newID, LUL_DEVICE)
  DEBUG(3,"Calendar ID is: " .. CALENDAR_ID)
end

function GCalTimer(data)
  local stuff = json.decode(data)
  ----------------
  --stuff[1] = command : startup, timeout, start, end
  --stuff[2] = name ,starttime, endtime, sid, number
  --stuff[3] = interrupt number
  -----------------
  local command = stuff[1]
  local interrupt = stuff[3]

  local name = stuff[2][1]
  local starttime = stuff[2][2]
  local endtime = stuff[2][3]
  local sid = stuff[2][4]
  local dev_num = stuff[2][5]

  if (GC.interrupt > interrupt) then
    DEBUG(3, "GCAL: Timer: Interrupt call that have interrupt index: " .. interrupt)
    return
  end

  if (command == "start") then
    local logmessage="GCAL: Timer: \"" .. name .. "\"  has just started"
    DEBUG(3, logmessage)
    --trigger the device
    luup.variable_set(SECURITY_SID, "Tripped", 1, LUL_DEVICE)
    luup.call_action(sid, "SetTarget",{newTargetValue = "1"}, tonumber(dev_num))
    luup.variable_set(GCAL_SID, "gc_displaystatus", 100, LUL_DEVICE)
    sendMail(logmessage, logmessage)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","Ends at " .. os.date("%H:%M %b %d", endtime) , LUL_DEVICE)
    --set the end timeout
    local diff_end = endtime - os.time()
    data = json.encode({"end", stuff[2] ,GC.interrupt})
    luup.call_timer("GCalTimer", 1, diff_end, "", data)
  elseif (command == "end") then
    local logmessage="GCAL: Timer: \"" .. name .. "\"  has just finished"
    DEBUG(3, logmessage)
    luup.variable_set(SECURITY_SID, "Tripped", 0, LUL_DEVICE)
    luup.call_action(sid, "SetTarget",{newTargetValue = "0"}, tonumber(dev_num))
    luup.variable_set(GCAL_SID, "gc_displaystatus", 0, LUL_DEVICE)
    sendMail(logmessage, logmessage)
    luup.call_timer("GCalTimer", 1, 100, "", json.encode({"timeout", "", GC.interrupt}))
  else
    CheckCalendar()
  end
end

function CheckCalendar()
  https.timeout = 30
  timeout, command, gcalval = checkGCal()
  luup.task(tostring("Finish Calendar Check"), 4, GC.description, GC.handle)
  package.loaded.https = nil
  package.loaded.json = nil
  checktime = os.date("%H:%M %b %d", os.time() + timeout)

  if command == "start" then
    DEBUG(3, "GCAL: Timer: Next event \"" .. gcalval[1] .. "\" in " .. timeout .. " seconds")
    luup.variable_set(GCAL_SID, "gc_NextEvent", gcalval[1] , LUL_DEVICE)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","Starts at " .. checktime , LUL_DEVICE)
  elseif command == "end" then
    DEBUG(3, "GCAL: Timer: Event ends \"" .. gcalval[1] .. "\" in " .. timeout .. " seconds")
    luup.variable_set(GCAL_SID, "gc_NextEvent", gcalval[1] , LUL_DEVICE)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","Ends at " .. checktime , LUL_DEVICE)
  elseif command == "error" then
    -- error check again in an hour
    timeout = 60 * 60
  else
    luup.variable_set(GCAL_SID, "gc_NextEvent", command , LUL_DEVICE)
    luup.variable_set(GCAL_SID, "gc_NextEventTime", checktime, LUL_DEVICE)
  end

  data = json.encode({command, gcalval, GC.interrupt})
  luup.call_timer("GCalTimer", 1, timeout, "", data)
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
  return tz, tzhr, tzmin
end

function setupVariables(lul_device)
  -- Because variables do not exist before the first "variable_set"
  -- They are created here in the order that we want them to appear in the Advanced Tab
  local s1 = ""
  local n1 = 0

  s1 = luup.variable_get(GCAL_SID, "gc_CalendarID", lul_device)
  if (s1 == nil) then
    s1 = ""
    luup.variable_set(GCAL_SID, "gc_CalendarID",s1, lul_device)
  end
  CALENDAR_ID = s1

  n1 = luup.variable_get(GCAL_SID, "EmailDeviceID", lul_device)
  if (n1 == nil or n1 == "") then
    n1 = 0
    luup.variable_set(GCAL_SID, "EmailDeviceID","", lul_device)
  end
  EMAIL_DEVICE_ID = tonumber(n1)


  n1 = luup.variable_get(GCAL_SID, "gc_displaystatus", lul_device)
  if ((n1 == nil) or n1 == "" or (tonumber(n1) > 100)) then
    n1 = 100
    luup.variable_set(GCAL_SID, "gc_displaystatus",n1, lul_device)
  end
end

function GCalStartup(lul_device)
  LUL_DEVICE = lul_device
  --check for new credentials file
  local credentials = checkforcredentials()
  package.loaded.json = nil
  if not credentials then
    luup.variable_set(GCAL_SID, "gc_NextEvent","Fatal error: credentials" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
    DEBUG(1, "Fatal Error - Could not get credentials")
    return
  end

  setupVariables(lul_device)

  -- Check to make sure there is a Calendar ID else stop the plugin
  if (CALENDAR_ID == "") then
    luup.variable_set(GCAL_SID, "gc_NextEvent","The CalendarID is not set" , lul_device)
    luup.variable_set(GCAL_SID, "gc_NextEventTime","" , lul_device)
    DEBUG(1,GC.debugPre .. "The Calendar ID is not set ...")
  return
  end

  -- Get the Time Zone info
  GC.timeZone, GC.timeZonehr, GC.timeZonemin = getTimezone()
  DEBUG(1,GC.debugPre .. tostring(lul_device))
  GC.description = luup.devices[lul_device].description

  GC.handle = luup.task(tostring("Check Calendar"), 1, GC.description, -1)
  CheckCalendar()
  return true,'ok','GCal3'
end
