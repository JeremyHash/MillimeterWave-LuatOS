PROJECT = "毫米波-LuatOS"
VERSION = "1.0.0"

tag = PROJECT

sys = require("sys")

MOD_TYPE = "101pro"

SSID, PASSWD = "Xiaomi_AX6000", "Air123456"
-- SSID, PASSWD = "hgz", "12345678"

targetStatusTable = {
    ["00"] = "无目标",
    ["01"] = "运动目标",
    ["02"] = "静止目标",
    ["03"] = "运动&静止目标"
}

mqttClient = nil

DEVICE_ID = "Jeremy"
MQTT_TOPIC = "/luatos/esp32c3/MillimeterWave/" .. DEVICE_ID

SEND_TO_SERVER = true

CHECK_COUNT = 0

function printTable(tbl, lv)
    lv = lv and lv .. "\t" or ""
    print(lv .. "{")
    for k, v in pairs(tbl) do
        if type(k) == "string" then
            k = "\"" .. k .. "\""
        end
        if "string" == type(v) then
            local qv = string.match(string.format("%q", v), ".(.*).")
            v = qv == v and '"' .. v .. '"' or "'" .. v:toHex() .. "'"
        end
        if type(v) == "table" then
            print(lv .. "\t" .. tostring(k) .. " = ")
            printTable(v, lv)
        else

            print(lv .. "\t" .. tostring(k) .. " = " .. tostring(v) .. ",")
        end
    end
    print(lv .. "},")
end

function setMaxDistanceAndNoPersonDuration(maxMotionDistanceDoor, maxStationaryDistanceDoor, noPersonDuration)
    uart.write(SLAVE_UARTID,
        string.fromHex(
            "FDFCFBFA140060000000" .. maxMotionDistanceDoor .. "0100" .. maxStationaryDistanceDoor .. "0200" ..
                noPersonDuration .. "04030201"))

    local waitRes = sys.waitUntil("setMaxDistanceAndNoPersonDuration_OK", 2000)
    if waitRes == true then
        return true
    else
        return false
    end
end

function setDistanceDoorSensitivity(disranceDoor, MotionSensitivity, StationarySensitivity)
    uart.write(SLAVE_UARTID, string.fromHex(
        "FDFCFBFA140064000000" .. disranceDoor .. "0100" .. MotionSensitivity .. "0200" .. StationarySensitivity ..
            "04030201"))

    local waitRes = sys.waitUntil("setDistanceDoorSensitivity_OK", 2000)
    if waitRes == true then
        return true
    else
        return false
    end
end

function openEngineeringMode()
    uart.write(SLAVE_UARTID, string.fromHex("FDFCFBFA0200620004030201"))
    local waitRes = sys.waitUntil("openEngineeringMode_OK", 2000)
    if waitRes == true then
        return true
    else
        return false
    end
end

function closeEngineeringMode()
    uart.write(SLAVE_UARTID, string.fromHex("FDFCFBFA0200630004030201"))
    local waitRes = sys.waitUntil("closeEngineeringMode_OK", 2000)
    if waitRes == true then
        return true
    else
        return false
    end
end

function reverseTable(tab)
    local tmp = {}
    for i = 1, #tab do
        tmp[i] = table.remove(tab)
    end
    return tmp
end

function MSB_LSB_SWITCH(hexData)
    local len = string.len(hexData)
    local spiltTable = {}
    for i = 1, len - 1, 2 do
        table.insert(spiltTable, string.sub(hexData, i, i + 1))
    end
    local resTable = reverseTable(spiltTable)
    return table.concat(resTable)
end

if SEND_TO_SERVER == true then
    sys.taskInit(function()
        sys.wait(2000)
        wlan.init()
        wlan.setMode(wlan.STATION)

        log.info("SSID", SSID)
        log.info("PASSWD", PASSWD)
        wlan.connect(SSID, PASSWD, 1)

        local result, data = sys.waitUntil("IP_READY", 10000)
        log.info("wlan", "IP_READY", result, data)
        if result == false then
            log.error("WIFI", "连接失败，正在重启")
            rtos.reboot()
        end

        -- init	function: 420210FA
        -- tart	function: 42021642
        -- ubscribe	function: 420215E8
        -- nsubscribe	function: 420215A0
        -- ublish	function: 42021520
        -- top	function: 420214E8
        -- estroy	function: 420214B0

        -- VENT_ERROR	0
        -- VENT_CONNECTED	1
        -- VENT_DISCONNECTED	2
        -- VENT_SUBSCRIBED	3
        -- VENT_UNSUBSCRIBED	4
        -- VENT_PUBLISHED	5
        -- VENT_DATA	6

        mqttClient = espmqtt.init({
            uri = "mqtt://airtest.openluat.com:1883",
            client_id = (esp32.getmac():toHex())
        })
        local ok, err = espmqtt.start(mqttClient)
        log.info("mqttc", "start", ok, err)

        while 1 do
            local result, c, ret, topic, data = sys.waitUntil("ESPMQTT_EVT", 30000)
            log.info(tag .. ".ESPMQTT_EVT", result, c, ret)
            if result == false then
                log.info(tag .. ".ESPMQTT_EVT", "wait timeout")
            elseif c == mqttClient then
                if ret == espmqtt.EVENT_CONNECTED then
                    log.info(tag .. ".ESPMQTT_EVT", "MQTT_CONNECT_OK")
                    sys.publish("MQTT_CONNECT_OK")
                    break
                end
            else
                log.info(tag .. ".ESPMQTT_EVT", "not this mqttc")
            end
        end
        while 1 do
            local waitRes, data = sys.waitUntil("TARGET_INFO")
            espmqtt.publish(mqttClient, MQTT_TOPIC, data)
        end
    end)
end

sys.taskInit(function()
    if SEND_TO_SERVER == true then
        sys.waitUntil("MQTT_CONNECT_OK")
    end

    gpio6 = gpio.setup(6)
    gpio12 = gpio.setup(12, 1)
    gpio13 = gpio.setup(13, 1)

    SLAVE_UARTID = 1

    local targetInfo = {}

    uart.setup(SLAVE_UARTID, 256000, 8, 1, uart.None)

    uart.on(SLAVE_UARTID, "receive", function(id, len)
        local data = uart.read(id, len)

        if MOD_TYPE == "101" then
            -- log.info(tag .. ".data", data)
            -- ---ON---(R = 126)
            local targetStatus = string.match(data, "%a+")
            local targetDistance = string.match(data, "%d+")
            if targetStatus == nil then
                return
            end
            targetInfo["mod"] = "101"
            targetInfo["targetStatus"] = targetStatus
            targetInfo["targetDistance"] = targetDistance
            local infoString = json.encode(targetInfo)
            -- printTable(targetInfo)
            sys.publish("TARGET_INFO", infoString)
        else
            local hexData = string.toHex(data)
            -- log.debug("SLAVE_DATA", hexData)
            local s, e

            -- F4F3F2F11B0001AA0326011696006406060000080E160B06000064616461465500F8F7F6F5
            s, e = string.find(hexData, "F4F3F2F11B0001AA", 1, true)
            if s == 1 and e == 16 then
                local info = string.sub(hexData, 17, 62)
                local targetStatus = string.sub(info, 1, 2)
                local motionTargetDistance = string.sub(info, 3, 6)
                local motionTargetEnergy = string.sub(info, 7, 8)
                local stationaryTargetDistance = string.sub(info, 9, 12)
                local stationaryTargetEnergy = string.sub(info, 13, 14)
                local maxMotionDistanceDoor = string.sub(info, 15, 16)
                local maxStationaryDistanceDoor = string.sub(info, 17, 18)
                local motionDistanceDoor0Energy = string.sub(info, 19, 20)
                local motionDistanceDoor1Energy = string.sub(info, 21, 22)
                local motionDistanceDoor2Energy = string.sub(info, 23, 24)
                local motionDistanceDoor3Energy = string.sub(info, 25, 26)
                local motionDistanceDoor4Energy = string.sub(info, 27, 28)
                local motionDistanceDoor5Energy = string.sub(info, 29, 30)
                local motionDistanceDoor6Energy = string.sub(info, 31, 32)
                local stationaryDistanceDoor0Energy = string.sub(info, 33, 34)
                local stationaryDistanceDoor1Energy = string.sub(info, 35, 36)
                local stationaryDistanceDoor2Energy = string.sub(info, 37, 38)
                local stationaryDistanceDoor3Energy = string.sub(info, 39, 40)
                local stationaryDistanceDoor4Energy = string.sub(info, 41, 42)
                local stationaryDistanceDoor5Energy = string.sub(info, 43, 44)
                local stationaryDistanceDoor6Energy = string.sub(info, 45, 46)

                targetInfo["mod"] = "101pro"
                targetInfo["type"] = "EngineeringMode"
                targetInfo["targetStatus"] = targetStatusTable[targetStatus]
                targetInfo["motionTargetDistance"] = tonumber(MSB_LSB_SWITCH(motionTargetDistance), 16) / 100 .. "m"
                targetInfo["motionTargetEnergy"] = tonumber(motionTargetEnergy, 16)
                targetInfo["stationaryTargetDistance"] = tonumber(MSB_LSB_SWITCH(stationaryTargetDistance), 16) / 100 ..
                                                             "m"
                targetInfo["stationaryTargetEnergy"] = tonumber(stationaryTargetEnergy, 16)
                targetInfo["maxMotionDistanceDoor"] = tonumber(maxMotionDistanceDoor, 16)
                targetInfo["maxStationaryDistanceDoor"] = tonumber(maxStationaryDistanceDoor, 16)
                targetInfo["m0Energy"] = tonumber(motionDistanceDoor0Energy, 16)
                targetInfo["m1Energy"] = tonumber(motionDistanceDoor1Energy, 16)
                targetInfo["m2Energy"] = tonumber(motionDistanceDoor2Energy, 16)
                targetInfo["m3Energy"] = tonumber(motionDistanceDoor3Energy, 16)
                targetInfo["m4Energy"] = tonumber(motionDistanceDoor4Energy, 16)
                targetInfo["m5Energy"] = tonumber(motionDistanceDoor5Energy, 16)
                targetInfo["m6Energy"] = tonumber(motionDistanceDoor6Energy, 16)

                targetInfo["s0Energy"] = tonumber(stationaryDistanceDoor0Energy, 16)
                targetInfo["s1Energy"] = tonumber(stationaryDistanceDoor1Energy, 16)
                targetInfo["s2Energy"] = tonumber(stationaryDistanceDoor2Energy, 16)
                targetInfo["s3Energy"] = tonumber(stationaryDistanceDoor3Energy, 16)
                targetInfo["s4Energy"] = tonumber(stationaryDistanceDoor4Energy, 16)
                targetInfo["s5Energy"] = tonumber(stationaryDistanceDoor5Energy, 16)
                targetInfo["s6Energy"] = tonumber(stationaryDistanceDoor6Energy, 16)

                targetInfo["io6"] = gpio6()

                local infoString = json.encode(targetInfo)
                -- printTable(targetInfo)
                sys.publish("TARGET_INFO", infoString)
                return
            end

            s, e = string.find(hexData, "F4F3F2F10B0002AA", 1, true)
            if s == 1 and e == 16 then
                local info = string.sub(hexData, 17, 30)
                local targetStatus = string.sub(info, 1, 2)
                local motionTargetDistance = string.sub(info, 3, 6)
                local motionTargetEnergy = string.sub(info, 7, 8)
                local stationaryTargetDistance = string.sub(info, 9, 12)
                local stationaryTargetEnergy = string.sub(info, 13, 14)

                -- log.info("info", info, targetStatus, motionTargetDistance, motionTargetEnergy, stationaryTargetDistance,
                --     stationaryTargetEnergy)

                targetInfo["type"] = "BasicMode"
                targetInfo["targetStatus"] = targetStatusTable[targetStatus]
                targetInfo["motionTargetDistance"] = tonumber(MSB_LSB_SWITCH(motionTargetDistance), 16) / 100 .. "m"
                targetInfo["motionTargetEnergy"] = tonumber(motionTargetEnergy, 16)
                targetInfo["stationaryTargetDistance"] = tonumber(MSB_LSB_SWITCH(stationaryTargetDistance), 16) / 100 ..
                                                             "m"
                targetInfo["stationaryTargetEnergy"] = tonumber(stationaryTargetEnergy, 16)
                targetInfo["io6"] = gpio6()

                local infoString = json.encode(targetInfo)
                -- local info = targetStatusTable[targetStatus] .. ",运动目标距离" ..
                --                  tonumber(MSB_LSB_SWITCH(motionTargetDistance), 16) / 100 .. "m" .. ",运动目标能量" ..
                --                  tonumber(motionTargetEnergy, 16) .. ",静止目标距离" ..
                --                  tonumber(MSB_LSB_SWITCH(stationaryTargetDistance), 16) / 100 .. "m" ..
                --                  ",静止目标能量" .. tonumber(stationaryTargetEnergy, 16)
                -- if tonumber(motionTargetEnergy, 16) > 60 then
                --     if CHECK_COUNT < 5 then
                --         CHECK_COUNT = CHECK_COUNT + 1
                --     else
                --         gpio12(1)
                --         gpio13(1)
                --     end
                -- elseif tonumber(stationaryTargetEnergy, 16) > 60 then
                --     if CHECK_COUNT < 5 then
                --         CHECK_COUNT = CHECK_COUNT + 1
                --     else
                --         gpio12(1)
                --         gpio13(1)
                --     end
                -- else
                --     CHECK_COUNT = 0
                --     gpio12(0)
                --     gpio13(0)
                -- end
                -- log.info("info", infoString)
                sys.publish("TARGET_INFO", infoString)
                return
            end

            s, e = string.find(hexData, "FDFCFBFA180061010000AA", 1, true)
            if s == 1 and e == 22 then
                local info = string.sub(hexData, 23, 60)
                local maxDistanceDoorNum = string.sub(info, 1, 2)
                local maxMotionDistanceDoor = string.sub(info, 3, 4)
                local maxStationaryDistanceDoor = string.sub(info, 5, 6)
                local distanceDoorMotionSensitivity = string.sub(info, 7, 20)
                local distanceDoorStationarySensitivity = string.sub(info, 21, 34)
                local noPersonDuration = string.sub(info, 35, 38)
                sys.publish("GET_PARAMS", maxDistanceDoorNum, maxMotionDistanceDoor, maxStationaryDistanceDoor,
                    distanceDoorMotionSensitivity, distanceDoorStationarySensitivity, noPersonDuration)
                return
            end

            if hexData == "FDFCFBFA0400FE01000004030201" then
                sys.publish("DISABLE_SETTING_OK")
                return
            end

            if hexData == "FDFCFBFA04006201000004030201" then
                sys.publish("openEngineeringMode_OK")
                return
            end

            if hexData == "FDFCFBFA04006301000004030201" then
                sys.publish("closeEngineeringMode_OK")
                return
            end

            if hexData == "FDFCFBFA04006001000004030201" then
                sys.publish("setMaxDistanceAndNoPersonDuration_OK")
                return
            end

            if hexData == "FDFCFBFA04006401000004030201" then
                sys.publish("setDistanceDoorSensitivity_OK")
                return
            end

            s, e = string.find(hexData, "FDFCFBFA0E0000010000", 1, true)
            if s == 1 and e == 20 then
                local info = string.sub(hexData, 21, 40)
                local productCatgory = string.sub(info, 1, 4)
                local firmwareCatgory = string.sub(info, 5, 8)
                local primaryVersion = string.sub(info, 9, 12)
                local subVersion = string.sub(info, 13, 16)
                local patchVersion = string.sub(info, 17, 20)
                sys.publish("GET_VERSION", productCatgory, firmwareCatgory, primaryVersion, subVersion, patchVersion)
                return
            end

            if hexData == "FDFCFBFA0800FF0100000100400004030201" then
                sys.publish("ENABLE_SETTING_OK")
                return
            end
        end
    end)

    if MOD_TYPE == "101" then
        log.info(tag .. "MOD", "101 无需配置")
    else
        local waitRes
        log.info("cmd", "使能配置")
        uart.write(SLAVE_UARTID, string.fromHex("FDFCFBFA0400FF00010004030201"))
        waitRes = sys.waitUntil("ENABLE_SETTING_OK", 2000)
        if waitRes ~= true then
            log.error("cmd", "使能配置 FAIL")
            rtos.reboot()
        end
        log.info("cmd", "读取版本")
        uart.write(SLAVE_UARTID, string.fromHex("FDFCFBFA0200000004030201"))
        waitRes, productCatgory, firmwareCatgory, primaryVersion, subVersion, patchVersion =
            sys.waitUntil("GET_VERSION")
        if waitRes ~= true then
            log.error("cmd", "读取版本 FAIL")
            rtos.reboot()
        end
        log.info("版本信息",
            string.format("产品类型:0x%s,固件类型:0x%s,主版本号:0x%s,次版本号:0x%s,patch版本号:0x%s",
                MSB_LSB_SWITCH(productCatgory), MSB_LSB_SWITCH(firmwareCatgory), MSB_LSB_SWITCH(primaryVersion),
                MSB_LSB_SWITCH(subVersion), MSB_LSB_SWITCH(patchVersion)))

        log.info("cmd", "配置最大距离门与无人持续时间参数")
        if setMaxDistanceAndNoPersonDuration("06000000", "06000000", "01000000") ~= true then
            log.error("cmd", "配置最大距离门与无人持续时间参数 FAIL")
            rtos.reboot()
        end

        log.info("cmd", "读取参数")
        uart.write(SLAVE_UARTID, string.fromHex("FDFCFBFA0200610004030201"))
        waitRes, maxDistanceDoorNum, maxMotionDistanceDoor, maxStationaryDistanceDoor, DistanceDoorMotionSensitivity, DistanceDoorStationarySensitivity, NoPersonDuration =
            sys.waitUntil("GET_PARAMS")
        if waitRes ~= true then
            log.error("cmd", "读取参数 FAIL")
            rtos.reboot()
        end
        log.info("雷达参数", string.format(
            "最大距离门:0x%s,最大运动距离门:0x%s,最大静止距离门:0x%s,距离们运动灵敏度:0x%s,距离门静止灵敏度:0x%s,无人持续时间:0x%s",
            MSB_LSB_SWITCH(maxDistanceDoorNum), MSB_LSB_SWITCH(maxMotionDistanceDoor),
            MSB_LSB_SWITCH(maxStationaryDistanceDoor), MSB_LSB_SWITCH(DistanceDoorMotionSensitivity),
            MSB_LSB_SWITCH(DistanceDoorStationarySensitivity), MSB_LSB_SWITCH(NoPersonDuration)))
        log.info("cmd", "打开工程模式")
        if openEngineeringMode() ~= true then
            log.error("cmd", "打开工程模式 FAIL")
            rtos.reboot()
        end
        -- log.info("cmd", "关闭工程模式")
        -- if closeEngineeringMode() ~= true then
        --     log.error("cmd", "关闭工程模式 FAIL")
        --     rtos.reboot()
        -- end
        log.info("cmd", "结束配置")
        uart.write(SLAVE_UARTID, string.fromHex("FDFCFBFA0200FE0004030201"))
        waitRes = sys.waitUntil("DISABLE_SETTING_OK")
        if waitRes ~= true then
            log.error("cmd", "结束配置 FAIL")
            rtos.reboot()
        end
    end
end)

sys.run()
