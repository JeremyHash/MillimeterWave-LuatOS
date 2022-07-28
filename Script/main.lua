PROJECT = "毫米波-LuatOS"
VERSION = "1.0.0"

tag = PROJECT

sys = require("sys")

targetStatusTable = {
    ["00"] = "无目标",
    ["01"] = "运动目标",
    ["02"] = "静止目标",
    ["03"] = "运动&静止目标"
}

mqttClient = nil

DEVICE_ID = "002"
MQTT_TOPIC = "/luatos/esp32c3/MillimeterWave/" .. DEVICE_ID

SEND_TO_SERVER = true

CHECK_COUNT = 0

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

        wlan.init()

        wlan.setMode(wlan.STATION)
        wlan.connect("Xiaomi_AX6000", "Air123456", 1)

        local result, data = sys.waitUntil("IP_READY")
        log.info("wlan", "IP_READY", result, data)

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

    gpio12 = gpio.setup(12, 0)
    gpio13 = gpio.setup(13, 0)

    SLAVE_UARTID = 1

    local targetInfo = {}

    uart.setup(SLAVE_UARTID, 256000, 8, 1, uart.None)

    uart.on(SLAVE_UARTID, "receive", function(id, len)
        local data = uart.read(id, len)

        local hexData = string.toHex(data)
        -- log.debug("SLAVE_DATA", hexData)
        local s, e
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

            targetInfo["targetStatus"] = targetStatusTable[targetStatus]
            targetInfo["motionTargetDistance"] = tonumber(MSB_LSB_SWITCH(motionTargetDistance), 16) / 100 .. "m"
            targetInfo["motionTargetEnergy"] = tonumber(motionTargetEnergy, 16)
            targetInfo["stationaryTargetDistance"] = tonumber(MSB_LSB_SWITCH(stationaryTargetDistance), 16) / 100 .. "m"
            targetInfo["stationaryTargetEnergy"] = tonumber(stationaryTargetEnergy, 16)

            local infoString = json.encode(targetInfo)
            -- local info = targetStatusTable[targetStatus] .. ",运动目标距离" ..
            --                  tonumber(MSB_LSB_SWITCH(motionTargetDistance), 16) / 100 .. "m" .. ",运动目标能量" ..
            --                  tonumber(motionTargetEnergy, 16) .. ",静止目标距离" ..
            --                  tonumber(MSB_LSB_SWITCH(stationaryTargetDistance), 16) / 100 .. "m" ..
            --                  ",静止目标能量" .. tonumber(stationaryTargetEnergy, 16)
            if tonumber(motionTargetEnergy, 16) > 60 then
                if CHECK_COUNT < 5 then
                    CHECK_COUNT = CHECK_COUNT + 1
                else
                    gpio12(1)
                    gpio13(1)
                end
            elseif tonumber(stationaryTargetEnergy, 16) > 60 then
                if CHECK_COUNT < 5 then
                    CHECK_COUNT = CHECK_COUNT + 1
                else
                    gpio12(1)
                    gpio13(1)
                end
            else
                CHECK_COUNT = 0
                gpio12(0)
                gpio13(0)
            end
            log.info("info", infoString)
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
    end)

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
    waitRes, productCatgory, firmwareCatgory, primaryVersion, subVersion, patchVersion = sys.waitUntil("GET_VERSION")
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
    log.info("cmd", "结束配置")
    uart.write(SLAVE_UARTID, string.fromHex("FDFCFBFA0200FE0004030201"))
    waitRes = sys.waitUntil("DISABLE_SETTING_OK")
    if waitRes ~= true then
        log.error("cmd", "结束配置 FAIL")
        rtos.reboot()
    end
end)

sys.run()
