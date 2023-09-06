local config = {}

config.log_level = log.LOG_INFO

-- ESP32板子型号
-- esp32c3 / esp32s3
config.board_type = "esp32s3"

-- 是否禁止RNDIS
-- 禁止RNDIS可以防止流量流失
config.disable_rndis = true

config.wifi = {
    ssid = "Wi-Fi名",
    password = "Wi-Fi密码"
}

config.notification_channel = {
    -- 合宙推送服务器
    luatos = {
        enabled = true,
        token = ""
    },
    -- Bark
    bark = {
        enabled = true,
        api_key = ""
    },
    -- Server酱
    server_chan = {
        enabled = false,
        send_key = ""
    },
    -- 钉钉Webhook机器人
    ding_talk = {
        enabled = true,
        -- Webhook地址
        webhook_url = "",
        -- 机器人安全设定中的关键词
        keyword = ""
    },
    -- PushPlus 推送加
    pushplus = {
        enabled = true,
        token = ""
    }
}

config.email = {
    enabled = false

    -- smtp.qq.com
    smtp_addr = "smtp.qq.com",

    smtp_port = 587,

    -- set to 0 for disable tls
    smtp_tls_port = 465,

    -- 邮箱账号,例如：123456789@qq.com
    user = "",

    -- 邮箱密码, 注意：QQ邮箱需要设置一个专用的第三方登录密码
    pass = "",

    -- 发送账号，留空则与user保持相同
    from = "",

    -- 显示名称
    from_name = "ESP32",

    -- 接收账号, 留空则与user保持相同（自己发给自己）
    to = "",

    -- 显示名称
    to_name = "",

    -- 主题
    subject = "10086",
}

return config
