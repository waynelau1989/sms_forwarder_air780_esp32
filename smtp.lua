local smtp = {}

local libnet = require("libnet")
local sysplus = require("sysplus")

-- Successful operation completed
smtp.SMTP_STATUS_OK              = 0

-- Memory allocation failed.
smtp.SMTP_STATUS_NOMEM           = 1

-- Failed to connect to the mail server.
smtp.SMTP_STATUS_CONNECT         = 2

-- Failed to handshake or negotiate a TLS connection with the server.
smtp.SMTP_STATUS_HANDSHAKE       = 3

-- Failed to authenticate with the given credentials.
smtp.SMTP_STATUS_AUTH            = 4

-- Failed to send bytes to the server.
smtp.SMTP_STATUS_SEND            = 5

-- Failed to receive bytes from the server.
smtp.SMTP_STATUS_RECV            = 6

-- Failed to properly close a connection.
smtp.SMTP_STATUS_CLOSE           = 7

-- SMTP server sent back an unexpected status code.
smtp.SMTP_STATUS_SERVER_RESPONSE = 8

-- Invalid parameter.
smtp.SMTP_STATUS_PARAM           = 9

-- Failed to open or read a local file.
smtp.SMTP_STATUS_FILE            = 10

-- Failed to get the local date and time.
smtp.SMTP_STATUS_DATE            = 11

-- Indicates the last status code in the enumeration, useful for
-- bounds checking.
-- Not a valid status code.
smtp.SMTP_STATUS_LAST            = 12

-- An error occurred during the getdelim processing.
smtp.STRING_GETDELIM_ERROR       = -1

-- Found a new line and can process more lines in the next call.
smtp.STRING_GETDELIM_NEXT        =  0

-- Found a new line and unable to read any more lines at this time.
smtp.STRING_GETDELIM_DONE        =  1


local LOG_TAG = "SMTP"

local function smtp_status_code_set(ctrl, sc)
    if(sc >= smtp.SMTP_STATUS_LAST) then
        return smtp_status_code_set(smtp, smtp.SMTP_STATUS_PARAM)
    end
    ctrl.status_code = sc
    return sc
end

local function smtp_puts(ctrl, data)
    local succ = libnet.tx(ctrl.task_name, 3000, ctrl.sock_ctrl, data)
    if not succ then
        log.error(LOG_TAG, "send data failed:", data)
        return smtp.SMTP_STATUS_SEND
    end
    return smtp.SMTP_STATUS_OK
end

local function smtp_str_getdelim_search_delim(ctrl)
end

local function smtp_str_getdelim(ctrl)
  bytes_read = -1;
end


local function smtp_gets(ctrl)
    local succ = libnet.wait(ctrl.task_name, 3000, ctrl.sock_ctrl)
    if not succ then
        log.error(LOG_TAG, "socket recv timeout")
        return
    end
    log.info(LOG_TAG, "smtp gets...")
    socket.rx(ctrl.sock_ctrl, ctrl.rbuf)
    rlen = ctrl.rbuf:used()
    log.info(LOG_TAG, "recv len:", rlen)
    rmsg = ctrl.rbuf:toStr(0, rlen)
    log.info(LOG_TAG, "recv msg:", string.toHex(rmsg, " "))
end

local function smtp_read_and_parse_code(ctrl)
  -- do {
  --   rc = smtp_getline(smtp);
  --   if(rc == STRING_GETDELIMFD_ERROR){
  --     return SMTP_INTERNAL_ERROR;
  --   }

  --   smtp_parse_cmd_line(smtp->gdfd.line, &cmd);
  -- }while (rc != STRING_GETDELIMFD_DONE && cmd.more);
end


function smtp.auth()
end

local function smtp_ehlo(ctrl)
    log.info(LOG_TAG, "smtp ehlo...")
    rc = smtp_puts(ctrl, "EHLO smtp\r\n")
    log.info(LOG_TAG, "smtp puts rc:", rc)
    if rc == smtp.SMTP_STATUS_OK then
        smtp_gets(ctrl)
    end
    return ctrl.status_code
end

function smtp.open(task_name, server, port)
    local smtp_ctrl = {}
    local succ

    smtp_ctrl.gdfd.delim = 0x0A
    -- smtp_ctrl.gdfd.delim = 0x0A

    smtp_ctrl.delim = 0x0A
    smtp_ctrl.status_code = -1
    smtp_ctrl.task_name = task_name
    smtp_ctrl.sock_ctrl = socket.create(nil, smtp_ctrl.task_name)
    -- socket.debug(smtp_ctrl.sock_ctrl, true)
    socket.config(smtp_ctrl.sock_ctrl, nil, nil, true)
    log.info("SMTP", "task name:", smtp_ctrl.task_name)

    succ = libnet.waitLink(smtp_ctrl.task_name, 5000, smtp_ctrl.sock_ctrl)
    if not succ then
        log.error(LOG_TAG, "连接SMTP服务器失败")
        return smtp_ctrl
    end

    succ = libnet.connect(smtp_ctrl.task_name, 5000, smtp_ctrl.sock_ctrl, server, port)
    if succ then
        smtp_ctrl.status_code = smtp.SMTP_STATUS_OK
        smtp_ctrl.rbuf = zbuff.create(1000)
        log.info(LOG_TAG, "连接SMTP服务器成功")
    else
        socket.close(smtp_ctrl.sock_ctrl)
        socket.release(smtp_ctrl.sock_ctrl)
        log.error(LOG_TAG, "连接SMTP服务器失败")
    end

    return smtp_ctrl
end

-- function smtp.auth(ctrl, server, port)
-- end
local function smtp_send_email_task_cb(msg)
    log.error(LOG_TAG, "未处理消息:", msg[1], msg[2], msg[3], msg[4])
end

local function smtp_send_email(task_name, server, port, msg)
    log.info(LOG_TAG, "send email:", server, port, msg)
    smtp_ctrl = smtp.open(task_name, server, port)
    smtp_ehlo(smtp_ctrl)
end

local SEND_EMAIL_TASK   = "SendEmailTask"
function smtp.send_email(server, port, msg)
    sysplus.taskInitEx(smtp_send_email, SEND_EMAIL_TASK, smtp_send_email_task_cb,
                        SEND_EMAIL_TASK, server, port, msg)
end


return smtp

