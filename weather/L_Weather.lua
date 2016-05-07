--
-- Device Implementation file to retrieve Weather information from the Weather Underground (WUI) service
-- on www.wunderground.com.
--
local http = require("socket.http")
-- 5 Second timeout
http.TIMEOUT = 5

local WEATHER_SERVICE = "urn:upnp-micasaverde-com:serviceId:Weather1"
local TEMPERATURE_SERVICE = "urn:upnp-org:serviceId:TemperatureSensor1"
local HADEVICE_SERVICE = "urn:micasaverde-com:serviceId:HaDevice1"
local HUMIDITY_SERVICE = "urn:micasaverde-com:serviceId:HumiditySensor1"

local SERVICE_LOC_URL = "https://api.wunderground.com/api/%s/conditions/forecast/q/%s.xml"
local SERVICE_LL_URL = "https://api.wunderground.com/api/%s/conditions/forecast/q/%#.6f,%#.6f.xml"

local MSG_CLASS = "WUIWeather"
local EMAIL_DEVICE_ID
local LONGITUDE
local LATITUDE
local METRIC
local PROVIDERKEY

local WEATHER_PATTERN, tmp = string.gsub([[<response>.*
        <current_observation>.*<observation_location>.*
        <full>(.-)</full>.*
        <latitude>(.-)</latitude>.*<longitude>(.-)</longitude>.*</observation_location>.*
        <observation_epoch>(%d-)</observation_epoch>.*
        <weather>(.*)</weather>.*
        <temp_f>(.-)</temp_f>.*<temp_c>(.-)</temp_c>.*
        <relative_humidity>(%d-)%%</relative_humidity>.*
        <wind_string>(.*)</wind_string>.*<wind_dir>(%a-)</wind_dir>.*<wind_mph>(.-)</wind_mph>.*<wind_kph>(.-)</wind_kph>.*<icon>(.-)</icon>.*
        </current_observation>.*
        <forecast>.*<simpleforecast><forecastdays><forecastday>.*<period>1</period>
        <high><fahrenheit>(.-)</fahrenheit><celsius>(.-)</celsius></high>
        <low><fahrenheit>(.-)</fahrenheit><celsius>(.-)</celsius></low>.*
        </forecastday>.*<forecastday>.*<period>2</period>.*
]], "%s*", "")

local taskHandle = -1
local TASK_ERROR = 2
local TASK_ERROR_PERM = -2
local TASK_SUCCESS = 4
local TASK_BUSY = 1

local function log(text, level)
    luup.log(string.format("%s: %s", MSG_CLASS, text), (level or 50))
end

local function task(text, mode)
    luup.log("task " .. text)
    if (mode == TASK_ERROR_PERM) then
        taskHandle = luup.task(text, TASK_ERROR, MSG_CLASS, taskHandle)
    else
        taskHandle = luup.task(text, mode, MSG_CLASS, taskHandle)

        -- Clear the previous error, since they're all transient
        if (mode ~= TASK_SUCCESS) then
            luup.call_delay("clearTask", 30, "", false)
        end
    end
end

function clearTask()
    task("Clearing...", TASK_SUCCESS)
end

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

local function findChild(parentDevice, label)
    for k, v in pairs(luup.devices) do
        if (v.device_num_parent == parentDevice and v.id == label) then
            return k
        end
    end
end

local function fetchWeather(key, latitude, longitude)
    if key == nil or latitude == nil or longitude == nil then
        return false, "Location or ProviderKey not set"
    end
    local st = os.time()

    local serverURL, xml, status
    serverURL = SERVICE_LL_URL:format(key, latitude, longitude)

    xml, status = http.request(serverURL)
    xml = xml:gsub(">%s*<", "><")

    local observationLoc, lat, long, epoch, condition,
          currentTempF, currentTempC,
          currentHumidity,
          windCondition, windDirection, windMPH, windKPH, icon,
          forecastHighTempF, forecastHighTempC, forecastLowTempF, forecastLowTempC
        = xml:match(WEATHER_PATTERN)

    if (lat == nil) then
        return false,
               string.format("Unable to parse result for url=%s, xml=%s", serverURL, (xml or "no result"))
    else
        return true,
              {observationLoc=observationLoc, lat=lat, long=long, epoch=epoch,
               condition=condition, conditionGroup=icon,
               currentTempF=currentTempF, currentTempC=currentTempC,
               currentHumidity=currentHumidity,
               windCondition=windCondition, windDirection=windDirection, windMPH=windMPH, windKPH=windKPH,
               forecastHighTempF=forecastHighTempF, forecastHighTempC=forecastHighTempC,
               forecastLowTempF=forecastLowTempF, forecastLowTempC=forecastLowTempC,
               serverURL=serverURL}
    end
end

function refreshCache()
    local status, result = fetchWeather(PROVIDERKEY, LATITUDE, LONGITUDE)

    if (status) then

        local windSpeed, currentTemp, forecastLowTemp, forecastHighTemp

        if (METRIC) then
            currentTemp = result.currentTempC
            forecastLowTemp = result.forecastLowTempC
            forecastHighTemp = result.forecastHighTempC
            windSpeed = result.windKPH
        else
            currentTemp = result.currentTempF
            forecastLowTemp = result.forecastLowTempF
            forecastHighTemp = result.forecastHighTempF
            windSpeed = result.windMPH
        end

        local weather_string = string.format("Requested [%s,%s], got [%s,%s] (%s).\n it is currently %s and %s (%s).  Humidity is %s%%.  Low is %s High is %s.  Condition is %s, Wind Condition is %s, Direction is %s, Speed is %s",
            LATITUDE,
            LONGITUDE,
            result.lat,
            result.long,
            result.observationLoc,
            currentTemp,
            result.condition,
            result.conditionGroup,
            result.currentHumidity,
            forecastLowTemp,
            forecastHighTemp,
            result.condition,
            result.windCondition,
            result.windDirection,
            windSpeed)

        if EMAIL_DEVICE_ID > 0 then
          luup.call_action( "urn:upnp-smtp-svc:serviceId:SND1", "SendMail", { subject = 'Weather Update', body = weather_string }, EMAIL_DEVICE_ID)
        end

        -- Store the current timestamp
        local ta = os.date("*t")
        local s = string.format("%d-%02d-%02d %02d:%02d:%02d", ta.year, ta.month, ta.day, ta.hour, ta.min, ta.sec)
        luup.variable_set(HADEVICE_SERVICE, "LastUpdate", s, PARENT_DEVICE)

        --store the observation location
        luup.variable_set(WEATHER_SERVICE, "LocationUsed", string.format("%s,%s", result.lat, result.long), PARENT_DEVICE)
        luup.variable_set(WEATHER_SERVICE, "LocationUsedText", result.observationLoc, PARENT_DEVICE)

        -- Store the current temperature
        luup.variable_set(TEMPERATURE_SERVICE, "CurrentTemperature", currentTemp, CURRENT_TEMPERATURE_DEVICE)
        -- Store the current temperature
        luup.variable_set(TEMPERATURE_SERVICE, "CurrentTemperature", forecastLowTemp, FORECAST_LOW_TEMPERATURE_DEVICE)

        -- Store the current temperature
        luup.variable_set(TEMPERATURE_SERVICE, "CurrentTemperature", forecastHighTemp, FORECAST_HIGH_TEMPERATURE_DEVICE)
        -- Store the current humidity
        luup.variable_set(HUMIDITY_SERVICE, "CurrentLevel", result.currentHumidity, CURRENT_HUMIDITY_DEVICE)
        -- Store the current Condition (eg. "Sunny"), note these values are subject to i18n
        luup.variable_set(WEATHER_SERVICE, "Condition", result.condition, PARENT_DEVICE)
        -- Store the current Condition Grouping (eg. "partlycloudy"), note these values are NOT subject to i18n
        luup.variable_set(WEATHER_SERVICE, "ConditionGroup", result.conditionGroup, PARENT_DEVICE)
        -- Store the current Wind Condition (eg: "W at 9 mph"), Direction (eg: "W") and Speed (eg: "9" or "14" if metric)
        luup.variable_set(WEATHER_SERVICE, "WindCondition", result.windCondition, PARENT_DEVICE)
        luup.variable_set(WEATHER_SERVICE, "WindDirection", result.windDirection, PARENT_DEVICE)
        luup.variable_set(WEATHER_SERVICE, "WindSpeed", windSpeed, PARENT_DEVICE)
    else
        log("fetchWeather returned error=" .. result)
    end
    task("Weather Check Complete",TASK_SUCCESS)
end

function startupDeferred()

    local metric = luup.variable_get(WEATHER_SERVICE, "Metric", parentDevice)
    if (metric == nil or metric == "") then
        luup.variable_set(WEATHER_SERVICE, "Metric", "0", parentDevice)
    else
        METRIC = metric == 1
    end

    local location = luup.variable_get(WEATHER_SERVICE, "Location", PARENT_DEVICE)
    if (location == nil or location == "") then
        luup.variable_set(WEATHER_SERVICE, "Location", "", PARENT_DEVICE)
    else
        t = split_deliminated_string(location,';')
        if t ~= nil then
            LATITUDE = t[1]
            LONGITUDE = t[2]
        end
    end

    local n1 = luup.variable_get(WEATHER_SERVICE, "EmailDeviceNumber", lul_device)
    if (n1 == nil or n1 == "") then
        n1 = 0
        luup.variable_set(WEATHER_SERVICE, "EmailDeviceNumber","", lul_device)
    end
    EMAIL_DEVICE_ID = tonumber(n1)

    PROVIDERKEY = luup.variable_get(WEATHER_SERVICE, "ProviderKey", PARENT_DEVICE)
    if (PROVIDERKEY == nil or PROVIDERKEY == "") then
        luup.variable_set(WEATHER_SERVICE, "ProviderKey", "", PARENT_DEVICE)
        luup.variable_set(WEATHER_SERVICE, "ProviderName", "WUI (Weather Underground)", PARENT_DEVICE)
        luup.variable_set(WEATHER_SERVICE, "ProviderURL", "http://www.wunderground.com", PARENT_DEVICE)

        local msg = "Registration Key needed from Weather Underground (www.wunderground.com)"
        task(msg, TASK_ERROR_PERM)
        return
    end
end

function startup(parentDevice)
    local CURRENT_TEMPERATURE_ID = "Weather-Current-Temperature"
    local FORECAST_HIGH_TEMPERATURE_ID = "Weather-Forecast-HighTemperature"
    local FORECAST_LOW_TEMPERATURE_ID = "Weather-Forecast-LowTemperature"
    local CURRENT_HUMIDITY_ID = "Weather-Current-Humidity"

    log("#" .. tostring(parentDevice) .. " starting up with id " .. luup.devices[parentDevice].id)

    --
    -- Build child devices for each type of metric we're gathering from WUI Weather.
    -- At this point that's:
    --     Weather-Current-Temperature - the last reported Temperature at your location
    --     Weather-Current-Humidity - the last reported Humidity Level at your location
    --
    local childDevices = luup.chdev.start(parentDevice)

    luup.chdev.append(parentDevice, childDevices,
        CURRENT_TEMPERATURE_ID, "Temperature",
        "urn:schemas-micasaverde-com:device:TemperatureSensor:1", "D_TemperatureSensor1.xml",
        "S_TemperatureSensor1.xml", "", true)

    luup.chdev.append(parentDevice, childDevices,
        FORECAST_LOW_TEMPERATURE_ID, "Low Temperature",
        "urn:schemas-micasaverde-com:device:TemperatureSensor:1", "D_TemperatureSensor1.xml",
        "S_TemperatureSensor1.xml", "", true)

    luup.chdev.append(parentDevice, childDevices,
        FORECAST_HIGH_TEMPERATURE_ID, "High Temperature",
        "urn:schemas-micasaverde-com:device:TemperatureSensor:1", "D_TemperatureSensor1.xml",
        "S_TemperatureSensor1.xml", "", true)

    luup.chdev.append(parentDevice, childDevices,
        CURRENT_HUMIDITY_ID, "Humidity",
        "urn:schemas-micasaverde-com:device:HumiditySensor:1", "D_HumiditySensor1.xml",
        "S_HumiditySensor1.xml", "", true)

    luup.chdev.sync(parentDevice, childDevices)

    --
    -- Note these are "pass-by-Global" values that refreshCache will later use.
    -- I need a var-args version of luup.call_timer(...) to pass these in a
    -- cleaner manner.
    --

    PARENT_DEVICE = parentDevice
    CURRENT_TEMPERATURE_DEVICE = findChild(parentDevice, CURRENT_TEMPERATURE_ID)
    FORECAST_LOW_TEMPERATURE_DEVICE = findChild(parentDevice, FORECAST_LOW_TEMPERATURE_ID)
    FORECAST_HIGH_TEMPERATURE_DEVICE = findChild(parentDevice, FORECAST_HIGH_TEMPERATURE_ID)
    CURRENT_HUMIDITY_DEVICE = findChild(parentDevice, CURRENT_HUMIDITY_ID)

    --
    -- Do this deferred to avoid slowing down startup processes.
    --
    luup.call_timer("startupDeferred", 1, "1", "")
end
