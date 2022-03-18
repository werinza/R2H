--[[
Copyright (c) 2022 werinza
based on code of thlassist.lua (under Copyright (c) 2021 LeonAirRC)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

-- gps.getstrig() is a typo error made by JETI during impelementation of API 1.5
-- change to gps.getstring() when implemented by JETI

-- remove following comment for luacheck program
---     if active at Jeti it causes system Error in : attempt to index a nil value (local 'json')
-- local form, system, lcd, gps, json, FONT_BIG, FONT_BOLD, FONT_MINI

local appName = "R2H"
local verstr = "1.0.0"

local latSensorIndex
local lonSensorIndex
local sensorIndices
local gpsSensorIDs
local gpsSensorParams
local otherSensorIDs
local otherSensorParams
local gpsSensorLabels
local otherSensorLabels

local curColorAirplane = 1
local curColorPosvec = 1
local curColorRollPitch = 1
local compassPoti
local threshold = {1.0, 1.0}
local audioSwitch
local pauseVoice = 8000   -- ms pause between voice audio
local beepInterval = {3500, 7000}   -- ms beep in this intervall after voice audio
local lastTimeVoice = 0

local lastTimeLoop = 0
local homeGps
local homeGpsTime = 0
local waitHomeGps = 10000  -- ms to wait before establishing homeGps
local curGps
local prevGps
local curHeading = 0.0
local bearing = 0.0
local curHeight = 0.0
local prevHeight = 0.0
local fieldElev = 0.0
local curDistance = 0.0
local prevDistance = 0.0
local curRoll
local curPitch

local renderer   -- exists only if Tx display is color
local colorTab = {{254, 20, 20}, {20, 254, 20}, {20, 20, 254}}
local curForm

-------------------------------------------------------------------------
-- read language dependent form texts
-------------------------------------------------------------------------
local text = io.readall("Apps/R2H/lang.jsn")
assert(text ~= nil, "The file R2H/lang.jsn is missing")
text = json.decode(text)
local lang = text[system.getLocale()] or text["en"]
text = nil

-------------------------------------------------------------------------
-- check if voice files exist
-------------------------------------------------------------------------
local voiceFiles = false
local fileL = io.open(lang.audioLeftFile,"r")
local fileR = io.open(lang.audioRightFile,"r")
if fileL and fileR then
    voiceFiles = true
end
if fileL then
    io.close(fileL)
end
if fileR then
    io.close(fileR)
end

-------------------------------------------------------------------------
-- callback functions
-------------------------------------------------------------------------
local function onLatSensorChanged(value)
    latSensorIndex = value - 1
    system.pSave("lat", latSensorIndex)
end

local function onLonSensorChanged(value)
    lonSensorIndex = value - 1
    system.pSave("lon", lonSensorIndex)
end

local function onOtherSensorChanged(value, index)
    sensorIndices[index] = value - 1
    system.pSave("others", sensorIndices)
end

local function onFieldElevChanged(value)
    fieldElev = value
    system.pSave("field", fieldElev)
end

local function onColorAirplaneChanged(value)
    curColorAirplane = value
    system.pSave("colair", curColorAirplane)
end

local function onColorPosvecChanged(value)
    curColorPosvec = value
    system.pSave("posvec", curColorPosvec)
end

local function onColorRollPitchChanged(value)
    curColorRollPitch = value
    system.pSave("rolpit", curColorRollPitch)
end

local function onCompassPotiChanged(value)
    compassPoti = value
    system.pSave("compoti", compassPoti)
end

local function onAudioSwitchChanged(value)
    audioSwitch = system.getInputsVal(value) ~= 0.0 and value or nil
    system.pSave("audiosw", audioSwitch)
end

local function onKeyPressed(keyCode)
    if curForm ~= 1 and (keyCode == KEY_ESC or keyCode == KEY_5) then
        form.preventDefault()
        form.reinit(1)
    end
end

-------------------------------------------------------------------------
-- draw functions called by printTelemetry()
-------------------------------------------------------------------------
-- draw compass
local function drawCompass(cW, cH, radius, angle)
    local rotation

    -- draw circle at center with radius
    lcd.drawCircle(cW, cH, radius)
    -- display compass direction (in degrees) above circle
    if angle > 0 then
        local angleDisp = -angle + 360
        local txt = tostring(angleDisp) .. "Â°"
        lcd.drawText(cW - lcd.getTextWidth(FONT_NORMAL, txt) / 2, cH - radius - 17, txt, FONT_NORMAL)
    end
    -- draw north marker
    rotation = math.rad(angle)   -- convert to radians
    local x, y = math.sin(rotation), math.cos(rotation)
    lcd.drawLine(cW + x * (radius - 5), cH - y * (radius - 5),
                 cW + x * (radius + 10) , cH - y * (radius + 10))
    -- draw compass labels within circle
    local radius2 = radius * 0.85
    local miniHeight = lcd.getTextHeight(FONT_MINI)
    for k, v in ipairs(lang.compassLabelList) do
        rotation = math.rad((k - 1) * 90 + angle)   -- convert to radians
        x, y = math.sin(rotation) * radius2, math.cos(rotation) * radius2
        lcd.drawText(cW + x - 2, cH - y - miniHeight / 2, v, FONT_MINI)
    end
end
-------------------------------------------------------------------------
-- draw position vector
local function drawPosition(cW, cH, radius, angbear)
    local rotation
    local colorProfile
    local colorNew = {}

    rotation = math.rad(angbear)   -- convert to radians
    local x, y = math.sin(rotation) * radius, math.cos(rotation) * radius
    if renderer and curColorPosvec > 1 then
        colorProfile = system.getProperty("Color")
        for k, v in ipairs(colorTab[curColorPosvec - 1]) do
            colorNew[k] = v
        end
        lcd.setColor(colorNew[1], colorNew[2], colorNew[3])
        -- draw 3 lines to make it wider
        lcd.drawLine(cW, cH, cW + x, cH - y)
        lcd.drawLine(cW - 1, cH - 1, cW + x - 1, cH - y - 1)
        lcd.drawLine(cW + 1, cH + 1, cW + x + 1, cH - y + 1)
        -- restore current drawing color
        if colorProfile == 7 or colorProfile == 9 or colorProfile == 10 or colorProfile == 11 then  -- white
            lcd.setColor(255, 255, 255)
        else   -- black
            lcd.setColor(0, 0, 0)
        end
    else
        lcd.drawLine(cW - 1, cH - 1, cW + x - 1, cH - y - 1)
        lcd.drawLine(cW + 1, cH + 1, cW + x + 1, cH - y + 1)
    end
end
-------------------------------------------------------------------------
-- draw plane shape
local function drawPlane(cW, cH, radius, angbear, anghead)
    local planeShape = {{0, -8}, {-0.5, -7.7}, {-1.1, -5.8}, {-1.1, -1.6}, {-7.1, 2.2}, {-7.1, 3.7},
                        {-1.1, 1.8}, {-1.1, 6}, {-2.6, 7.1}, {-2.6, 8.2}, {0, 7.4}, {2.6, 8.2},
                        {2.6, 7.1}, {1.1, 6}, {1.1, 1.8}, {7.1, 3.7}, {7.1, 2.2}, {1.1, -1.6},
                        {1.1, -5.8}, {0.5, -7.7}}  -- plane shape for color display
    local planeArrow = {{0, -7}, {-6, 7}, {0, 4}, {6, 7}, {0, -7}}  -- is an arrow shape for black/white display
    local mult = 2.5  -- draw plane with mult times size of shape table
    local rotation
    local colorProfile
    local colorNew = {}

    rotation = math.rad(angbear)   -- convert to radians
    local x, y = math.sin(rotation) * radius, math.cos(rotation) * radius

    rotation = math.rad(anghead)  -- convert to radians
    local sin, cos = math.sin(rotation) * mult, math.cos(rotation) * mult
    if renderer then
        renderer:reset()
        if curColorAirplane > 1 then
            colorProfile = system.getProperty("Color")
            for k, v in ipairs(colorTab[curColorAirplane - 1]) do
                colorNew[k] = v
            end
            lcd.setColor(colorNew[1], colorNew[2], colorNew[3])
            for _,point in ipairs(planeShape) do
                renderer:addPoint(cW + x + point[1] * cos - point[2] * sin,
                                  cH - y + point[1] * sin + point[2] * cos)
            end
            renderer:renderPolygon()
            -- restore current drawing color
            if colorProfile == 7 or colorProfile == 9 or colorProfile == 10 or colorProfile == 11 then  -- white
                lcd.setColor(255, 255, 255)
            else   -- black
                lcd.setColor(0, 0, 0)
            end
        else
            for _, point in ipairs(planeShape) do
                renderer:addPoint(cW + x + point[1] * cos - point[2] * sin,
                                  cH - y + point[1] * sin + point[2] * cos)
            end
            renderer:renderPolygon()
        end
    else
        for i = 1, #planeArrow - 1 do
            lcd.drawLine(cW + x + planeArrow[i][1] * cos - planeArrow[i][2] * sin,
                         cH - y + planeArrow[i][1] * sin + planeArrow[i][2] * cos,
                         cW + x + planeArrow[i + 1][1] * cos - planeArrow[i + 1][2] * sin,
                         cH - y + planeArrow[i + 1][1] * sin + planeArrow[i + 1][2] * cos)
        end
    end
end
-------------------------------------------------------------------------
-- draw roll sensor (value is in intervall -179 to 179, positive values are bend to right side)
local function drawRoll(cW, cH)
    local rollIndicator = {{-30, -8}, {-30, -3}, {0, 0}, {30, -3}, {30, -8}}
    local colorProfile
    local colorNew = {}
    local offset = 27

    local x, y = math.sin(0) * offset, math.cos(0) * offset
    local rotation = math.rad(curRoll)  -- convert to radians
    local sin, cos = math.sin(rotation), math.cos(rotation)
    if renderer and curColorRollPitch > 1 then
        colorProfile = system.getProperty("Color")
        for k, v in ipairs(colorTab[curColorRollPitch - 1]) do
            colorNew[k] = v
        end
        lcd.setColor(colorNew[1], colorNew[2], colorNew[3])
        for i = 1, #rollIndicator - 1 do
            lcd.drawLine(cW + x + rollIndicator[i][1] * cos - rollIndicator[i][2] * sin,
                         cH - y + rollIndicator[i][1] * sin + rollIndicator[i][2] * cos,
                         cW + x + rollIndicator[i + 1][1] * cos - rollIndicator[i + 1][2] * sin,
                         cH - y + rollIndicator[i + 1][1] * sin + rollIndicator[i + 1][2] * cos)
        end
        lcd.drawCircle(cW, cH - offset, 3)
        -- restore current drawing color
        if colorProfile == 7 or colorProfile == 9 or colorProfile == 10 or colorProfile == 11 then  -- white
            lcd.setColor(255, 255, 255)
        else   -- black
            lcd.setColor(0, 0, 0)
        end
    else
        for i = 1, #rollIndicator - 1 do
            lcd.drawLine(cW + x + rollIndicator[i][1] * cos - rollIndicator[i][2] * sin,
                         cH - y + rollIndicator[i][1] * sin + rollIndicator[i][2] * cos,
                         cW + x + rollIndicator[i + 1][1] * cos - rollIndicator[i + 1][2] * sin,
                         cH - y + rollIndicator[i + 1][1] * sin + rollIndicator[i + 1][2] * cos)
        end
        lcd.drawCircle(cW, cH - offset, 3)
    end
end
-------------------------------------------------------------------------
-- draw pitch sensor (value is in intervall -89 to 89, positive values are nose up)
local function drawPitch(cW, cH)
    local pitchIndicator = {{-25, -8}, {-25, 0}, {0, 0}, {25, 0}, {20, 0}, {15, -4}, {10, 0}}
    local colorProfile
    local colorNew = {}
    local offset = -27

    local x, y = math.sin(0) * offset, math.cos(0) * offset
    local rotation = math.rad(-curPitch)  -- convert to radians
    local sin, cos = math.sin(rotation), math.cos(rotation)
    if renderer and curColorRollPitch > 1 then
        colorProfile = system.getProperty("Color")
        for k, v in ipairs(colorTab[curColorRollPitch - 1]) do
            colorNew[k] = v
        end
        lcd.setColor(colorNew[1], colorNew[2], colorNew[3])
        for i = 1, #pitchIndicator - 1 do
            lcd.drawLine(cW + x + pitchIndicator[i][1] * cos - pitchIndicator[i][2] * sin,
                         cH - y + pitchIndicator[i][1] * sin + pitchIndicator[i][2] * cos,
                         cW + x + pitchIndicator[i + 1][1] * cos - pitchIndicator[i + 1][2] * sin,
                         cH - y + pitchIndicator[i + 1][1] * sin + pitchIndicator[i + 1][2] * cos)
        end
        -- restore current drawing color
        if colorProfile == 7 or colorProfile == 9 or colorProfile == 10 or colorProfile == 11 then  -- white
            lcd.setColor(255, 255, 255)
        else   -- black
            lcd.setColor(0, 0, 0)
        end
    else
        for i = 1, #pitchIndicator - 1 do
            lcd.drawLine(cW + x + pitchIndicator[i][1] * cos - pitchIndicator[i][2] * sin,
                         cH - y + pitchIndicator[i][1] * sin + pitchIndicator[i][2] * cos,
                         cW + x + pitchIndicator[i + 1][1] * cos - pitchIndicator[i + 1][2] * sin,
                         cH - y + pitchIndicator[i + 1][1] * sin + pitchIndicator[i + 1][2] * cos)
        end
    end
end
-------------------------------------------------------------------------
-- draw height
local function drawHeight(cH)
    lcd.drawText(0, cH - 15, lang.heightTitle)
    local heightOut = tostring(math.floor(curHeight)) .. "m"
    lcd.drawText(0, cH, heightOut, FONT_BIG)
    if math.abs(curHeight - prevHeight) > threshold[1] then
        if curHeight < prevHeight then
            if renderer then
                lcd.drawImage(0, cH + 30, ":down")
            else
                lcd.drawFilledRectangle(10, cH + 30, 10, 20)
                lcd.drawFilledRectangle(0, cH + 50, 30, 3)
            end
        else
            if renderer then
                lcd.drawImage(0, cH - 45, ":up")
            else   -- because JETI arrow image was blurred on black/white display
                lcd.drawFilledRectangle(10, cH - 45, 10, 20)
                lcd.drawFilledRectangle(0, cH - 47, 30, 3)
            end
        end
    end
end
-------------------------------------------------------------------------
-- draw distance
local function drawDistance(wid, cH, audio)
    lcd.drawText(wid - 30,cH - 15, lang.distanceTitle)
    local distanceOut = tostring(math.floor(curDistance)) .. "m"
    lcd.drawText(wid - lcd.getTextWidth(FONT_BIG, distanceOut) - 3, cH, distanceOut, FONT_BIG)

    if math.abs(curDistance - prevDistance) > threshold[2] then  -- filter
        if curDistance < prevDistance then
            if renderer then
                lcd.drawImage(wid - 25, cH + 30, ":down")
            else
                lcd.drawFilledRectangle(wid - 20, cH + 30, 10, 20)
                lcd.drawFilledRectangle(wid - 30, cH + 50, 30, 3)
            end
            if audio then   -- play distance audio
                system.playBeep(4, 2500, 100)
            end
        else
            if renderer then
                lcd.drawImage(wid - 25, cH - 45, ":up")
            else
                lcd.drawFilledRectangle(wid - 20, cH - 45, 10, 20)
                lcd.drawFilledRectangle(wid - 30, cH - 47, 30, 3)
            end
            if audio then  -- play distance audio
                system.playBeep(4, 400, 100)
            end
        end
    end
end

-------------------------------------------------------------------------
-- prints the telemetry frame, is called in regular intervals by transmitter
-- width = 319 and height = 239 pixels on color displays
-------------------------------------------------------------------------
local function printTelemetry(width, height)
    local centerW = width // 2
    local centerH = height // 2
    local radius = centerH * 0.8
    local compassRota
    local txt
    local curTime = system.getTimeCounter()

    -- check if crucial sensors assigned
    if (latSensorIndex == 0 or lonSensorIndex == 0) and system.getTime() % 2 == 0 then
        lcd.drawText((width - lcd.getTextWidth(FONT_BOLD, lang.sensorMissingText)) / 2, 50,
                     lang.sensorMissingText, FONT_BOLD)
    end

    -- check if compass to be rotated and how much
    compassRota = 0
    if compassPoti then
        local rot = system.getInputsVal(compassPoti) * 180
        rot = (rot + 360) % 360
        -- modify to closest 5° step
        compassRota = math.ceil(rot / 5) * 5
        -- stabilize around 0 to avoid jitter of potentiometer
        if compassRota == 360 or compassRota >= -5 and compassRota <= 5 then
            compassRota = 0
        end
    end

    -- draw compass
    drawCompass(centerW, centerH, radius, compassRota)

     -- check if audio to be played
    local doAudio = false
    if audioSwitch and system.getInputsVal(audioSwitch) > 0 then
        doAudio = true
    end

    -- draw graphics if gps values available
    if homeGps and curGps then
        -- display compass direction of position (seen from home)
        txt = tostring(math.floor(bearing)) .. "Â°"
        lcd.drawText(0, 0, " Posit.  " .. txt, FONT_BIG)
        -- display angle with which the aircraft must be turned to get home
        local turnBy = math.floor((bearing + 180) % 360 - curHeading)
        if turnBy > 180 then
            turnBy = turnBy - 360
        elseif turnBy < -180 then
            turnBy = turnBy + 360
        end
        txt = lang.turnByTitle .. "  " .. tostring(math.floor(turnBy)) .. "Â°"
        lcd.drawText(width - lcd.getTextWidth(FONT_BIG, txt) - 5, 0, txt, FONT_BIG)
        -- check if turn instructions to be played
        if doAudio and curTime > lastTimeVoice + pauseVoice then
            if voiceFiles then
                if turnBy < 0 then
                    system.playFile(lang.audioLeftFile, AUDIO_QUEUE) -- audio foreground queue
                else
                    system.playFile(lang.audioRightFile, AUDIO_QUEUE)
                end
                system.playNumber(math.abs(turnBy), 0, "°")  -- "°" must be hex 22 B0 22 and not 22 C2 B0 22 (which is needed for text output)
            else  -- play positive and negative values if audio files absent
                system.playNumber(turnBy, 0, "°")  -- foreground queue
            end
            lastTimeVoice = curTime
        end

        -- draw position vector, i.e. a line from center (representing home) to a circle point (representing curGps)
        drawPosition(centerW, centerH, radius, compassRota + bearing)

        -- draw plane with center at end of position vector and rotated by current heading + compass rotation
        drawPlane(centerW, centerH, radius, compassRota + bearing, compassRota + curHeading)

        -- display height above ground at left margin
        if sensorIndices[2] ~= 0 or sensorIndices[3] ~= 0 then
            drawHeight(centerH)
        end

         -- display distance from home at right margin and play beep if in beepInterval after lastTimeVoice
        if doAudio and curTime > lastTimeVoice + beepInterval[1] and curTime < lastTimeVoice + beepInterval[2] then
            drawDistance(width, centerH, true)
        else
            drawDistance(width, centerH, false)
        end
    else
        if system.getTime() % 2 == 0 then
            lcd.drawText((width - lcd.getTextWidth(FONT_BOLD, lang.sensorWaitingText)) / 2, 0,
                         lang.sensorWaitingText, FONT_BOLD)
        end
    end

    -- draw roll indicator
    if sensorIndices[4] ~= 0 and curRoll then
        drawRoll(centerW, centerH)
    end

    -- draw pitch indicator
    if sensorIndices[5] ~= 0 and curPitch then
        drawPitch(centerW, centerH)
    end
end

-------------------------------------------------------------------------
-- loop function is called in regular intervals (we evaluate only once per halve a second)
-------------------------------------------------------------------------
local function looptst()
    homeGps = gps.newPoint(48.71853, 10.73993)
    curGps = gps.newPoint(48.72083, 10.74574)
    prevGps = gps.newPoint(48.72120, 10.74418)
    bearing = 300    -- position
    curHeading = 180
    curHeight = 123
    prevHeight = 100
    curDistance = 200
    prevDistance = 300
    curRoll = 35
    curPitch = -10
end

local function loop()
    local curTime = system.getTimeCounter()

    -- process roll and pitch sensors
    if sensorIndices[4] ~= 0 then  -- roll sensor
        local valRoll = system.getSensorValueByID(otherSensorIDs[sensorIndices[4]],
                                                  otherSensorParams[sensorIndices[4]])
        if valRoll.valid then
            curRoll = valRoll.value
            if curRoll < -179 then
                curRoll = -179
            elseif curRoll > 179 then
                curRoll = 179
            end
        else
            curRoll = nil
        end
    end

    if sensorIndices[5] ~= 0 then  -- pitch sensor
        local valPitch = system.getSensorValueByID(otherSensorIDs[sensorIndices[5]],
                                                   otherSensorParams[sensorIndices[5]])
        if valPitch.valid then
            curPitch = valPitch.value
            if curPitch < -89 then
                curPitch = -89
            elseif curPitch > 89 then
                curPitch = 89
            end
        else
            curPitch = nil
        end
    end

    -- once GPS has settled do updates every 100ms, acts like a filter
    if homeGps and curTime < lastTimeLoop + 100 then
        return
    end

    -- save previous values
    prevGps = curGps
    prevHeight = curHeight
    prevDistance = curDistance

    -- read current sensor values
    local latitude, longitude
    if latSensorIndex ~= 0 and lonSensorIndex ~= 0 then
        curGps = gps.getPosition(gpsSensorIDs[latSensorIndex], gpsSensorParams[latSensorIndex],
                                 gpsSensorParams[lonSensorIndex])
        if not homeGps and curGps then
            -- set home after waitHomeGps ms
            latitude, longitude = gps.getValue(curGps)
            if latitude ~= 0.0 and longitude ~= 0.0 then
                if homeGpsTime == 0 then
                    homeGpsTime = curTime
                end
                if curTime > homeGpsTime + waitHomeGps then
                    homeGps = curGps
                end
            end
        end
        if homeGps and curGps then
            bearing = gps.getBearing(homeGps, curGps)
            curDistance = gps.getDistance(homeGps, curGps)
            lastTimeLoop = curTime
        end

        if prevGps and curGps then
            curHeading = gps.getBearing(prevGps, curGps)
        end
    end

    if sensorIndices[1] ~= 0 then   -- heading sensor
        local valHead = system.getSensorValueByID(otherSensorIDs[sensorIndices[1]],
                                                  otherSensorParams[sensorIndices[1]])
        if valHead.valid then
            curHeading = valHead.value  -- sensor has higher priority than bearing value and overwrites it
        end
    end

    if sensorIndices[2] ~= 0 then  -- altitude GPS sensor
        local valAlti = system.getSensorValueByID(otherSensorIDs[sensorIndices[2]],
                                                  otherSensorParams[sensorIndices[2]])
        if valAlti.valid then
            curHeight = valAlti.value - fieldElev
        end
    end

    if sensorIndices[3] ~= 0 then  -- altimeter sensor
        local valBaro = system.getSensorValueByID(otherSensorIDs[sensorIndices[3]],
                                                  otherSensorParams[sensorIndices[3]])
        if valBaro.valid then
            curHeight = valBaro.value  -- altimeter has higher priority than altitude GPS because more precise
        end
    end
end

-------------------------------------------------------------------------
-- initialize forms
-------------------------------------------------------------------------
local function initForm(formID)
    if not formID or formID == 1 then

        form.setTitle(appName)
        form.addRow(1)
        form.addLink(function () form.reinit(12) end, { label = lang.gpsSensorsFormTitle .. " >>" })
        form.addRow(1)
        form.addLink(function () form.reinit(13) end, { label = lang.positionSensorsFormTitle .. " >>" })
        form.addRow(1)
        form.addLink(function () form.reinit(14) end, { label = lang.telemetryFormTitle .. " >>" })
        form.setFocusedRow(1)

    elseif formID == 12 then

        form.setTitle(lang.gpsSensorsFormTitle)
        form.addRow(2)
        form.addLabel({ label = lang.latSensorText })
        form.addSelectbox(gpsSensorLabels, latSensorIndex + 1, true, onLatSensorChanged)
        form.addRow(2)
        form.addLabel({ label = lang.lonSensorText })
        form.addSelectbox(gpsSensorLabels, lonSensorIndex + 1, true, onLonSensorChanged)
        form.addRow(2)
        form.addLabel({ label = lang.headingSensorText })
        form.addSelectbox(otherSensorLabels, sensorIndices[1] + 1, true,
                          function(value) onOtherSensorChanged(value, 1) end)
        form.addRow(2)
        form.addLabel({ label = lang.altitudeGpsText })
        form.addSelectbox(otherSensorLabels, sensorIndices[2] + 1, true,
                          function(value) onOtherSensorChanged(value, 2) end)
        form.addRow(2)
        form.addLabel({ label = lang.fieldElevText })
        form.addIntbox(fieldElev, 1, 2000, 1, 0, 1, onFieldElevChanged)
        form.addRow(2)
        form.addLabel({ label = lang.altimeterText })
        form.addSelectbox(otherSensorLabels, sensorIndices[3] + 1, true,
                          function(value) onOtherSensorChanged(value, 3) end)
        form.addRow(1)
        form.addLink(function () form.reinit(1) end, {label = lang.backMain})
        form.setFocusedRow(1)

    elseif formID == 13 then

        form.setTitle(lang.positionSensorsFormTitle)
        form.addRow(2)
        form.addLabel({ label = lang.rollSensorText })
        form.addSelectbox(otherSensorLabels, sensorIndices[4] + 1, true,
                          function(value) onOtherSensorChanged(value, 4) end)
        form.addRow(2)
        form.addLabel({ label = lang.pitchSensorText })
        form.addSelectbox(otherSensorLabels, sensorIndices[5] + 1, true,
                          function(value) onOtherSensorChanged(value, 5) end)
        form.addRow(1)
        form.addLink(function () form.reinit(1) end, {label = lang.backMain})
        form.setFocusedRow(1)

    else

        form.setTitle(lang.telemetryFormTitle)
        form.addRow(2)
        form.addLabel({ label = lang.colorAirplaneText })
        form.addSelectbox(lang.colorList, curColorAirplane, true,
                          function(value) onColorAirplaneChanged(value) end)
        form.addRow(2)
        form.addLabel({ label = lang.colorPosvecText })
        form.addSelectbox(lang.colorList, curColorPosvec, true,
                          function(value) onColorPosvecChanged(value) end)
        form.addRow(2)
        form.addLabel({ label = lang.colorRollPitchText })
        form.addSelectbox(lang.colorList, curColorRollPitch, true,
                          function(value) onColorRollPitchChanged(value) end)
        form.addRow(2)
        form.addLabel({ label = lang.compassPotiText })
        form.addInputbox(compassPoti, true, onCompassPotiChanged)
        form.addRow(2)
        form.addLabel({ label = lang.audioSwitchText })
        form.addInputbox(audioSwitch, false, onAudioSwitchChanged)
        form.addRow(1)
        form.addLink(function () form.reinit(1) end, {label = lang.backMain})
        form.setFocusedRow(1)

    end
    curForm = formID
    collectgarbage()
end

-------------------------------------------------------------------------
-- Application initialization.
-------------------------------------------------------------------------
local function init()
    gpsSensorLabels = {"..."}
    otherSensorLabels = {"..."}
    gpsSensorIDs = {}
    gpsSensorParams = {}
    otherSensorIDs = {}
    otherSensorParams = {}

    -- read current sensors
    local sensors = system.getSensors()
    for _,sensor in ipairs(sensors) do
        if sensor.param ~= 0 and sensor.type == 9 then
            -- it is GPS lon/lat
            gpsSensorLabels[#gpsSensorLabels+1] = string.format("%s: %s", sensor.sensorName, sensor.label)
            gpsSensorIDs[#gpsSensorIDs+1] = sensor.id
            gpsSensorParams[#gpsSensorParams+1] = sensor.param
        elseif sensor.param ~= 0 and sensor.type ~= 5 then
            -- other sensor (not a date/timer)
            otherSensorLabels[#otherSensorLabels+1] = string.format("%s: %s [%s]",
                                                                    sensor.sensorName, sensor.label, sensor.unit)
            otherSensorIDs[#otherSensorIDs+1] = sensor.id
            otherSensorParams[#otherSensorParams+1] = sensor.param
        end
    end

    -- get stored values from model jsn
    latSensorIndex = system.pLoad("lat", 0)
    lonSensorIndex = system.pLoad("lon", 0)
    sensorIndices = system.pLoad("others") or {0, 0, 0, 0, 0}
    local numberSensors = system.pLoad("numsen", 0)
    if numberSensors > 0 then
        if numberSensors ~= #gpsSensorIDs + #otherSensorIDs then
            latSensorIndex = 0
            lonSensorIndex = 0
            for i = 1, 5 do
                sensorIndices[i] = 0
            end
        end
    else
        system.pSave("numsen", #gpsSensorIDs + #otherSensorIDs)
    end
    fieldElev = system.pLoad("field", 1000)
    curColorAirplane = system.pLoad("colair", 1)
    curColorPosvec = system.pLoad("posvec", 1)
    curColorRollPitch = system.pLoad("rolpit", 1)
    compassPoti = system.pLoad("compoti")
    audioSwitch = system.pLoad("audiosw")
    system.registerForm(1, MENU_APPS, appName, initForm, onKeyPressed)
    system.registerTelemetry(2, appName .. " - Return to Home", 4, printTelemetry)

    -- comment pcall for testing black/white in JETI Studio dc-sim
    pcall(function() renderer = lcd.renderer() end)
    collectgarbage()
end

local function destroy()
    system.unregisterTelemetry(2)
    collectgarbage()
end

-------------------------------------------------------------------------
-- Application interface
-------------------------------------------------------------------------
return { init = init, loop = loop, destroy = destroy, author = "werinza", version = verstr, name = appName }
