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
smtp.STRING_GETDELIMFD_ERROR     = -1

-- Found a new line and can process more lines in the next call.
smtp.STRING_GETDELIMFD_NEXT      =  0

-- Found a new line and unable to read any more lines at this time.
smtp.STRING_GETDELIMFD_DONE      =  1

smtp.SMTP_INTERNAL_ERROR         =  -1

-- Returned when ready to begin processing next step.
smtp.SMTP_READY                  = 220

-- Returned in response to QUIT.
smtp.SMTP_CLOSE                  = 221

-- Returned if client successfully authenticates.
smtp.SMTP_AUTH_SUCCESS           = 235

-- Returned when some commands successfully complete.
SMTP_DONE                        = 250

-- Returned for some multi-line authentication mechanisms where this code
-- indicates the next stage in the authentication step.
smtp.SMTP_AUTH_CONTINUE          = 334

-- Returned in response to DATA command.
smtp.SMTP_BEGIN_MAIL             = 354


local LOG_TAG = "SMTP"

local function smtp_status_code_set(ctrl, sc)
    if(sc >= smtp.SMTP_STATUS_LAST) then
        return smtp_status_code_set(smtp, smtp.SMTP_STATUS_PARAM)
    end
    ctrl.status_code = sc
    return sc
end

local function smtp_str_getdelimfd_read(ctrl)
    local succ
    local sock_ev
    gdfd = ctrl.gdfd

    succ, sock_ev = libnet.wait(ctrl.task_name, 5000, ctrl.sock_ctrl)
    if not succ then
        log.error(LOG_TAG, "socket wait failure")
        return -1
    end
    if not sock_ev then
        log.error(LOG_TAG, "socket wait timeout")
        return -1
    end

    succ, rlen = socket.rx(ctrl.sock_ctrl, gdfd.rbuf)
    if not succ then
        log.error(LOG_TAG, "socket recv failure")
        return -1
    end

    -- log.info(LOG_TAG, "socket recv len:", rlen)
    return rlen
end

local function smtp_str_getdelimfd_search_delim(gdfd)
    local buf_len = gdfd.rbuf:used()
    gdfd.delim_pos = -1

    if buf_len < 1 then
        return false
    end

    buf_len = buf_len - 1
    for i=0,buf_len do
        if gdfd.rbuf[i] == gdfd.delim then
            gdfd.delim_pos = i
            return true
        end
    end
    return false
end

local function smtp_str_getdelimfd_set_line_and_buf(gdfd)
    local delim_len
    gdfd.line = ""

    if gdfd.delim_pos < 1 then
        return false
    end

    delim_len = gdfd.delim_pos + 1

    gdfd.line = gdfd.rbuf:toStr(0, gdfd.delim_len)

    gdfd.tbuf:del(0, gdfd.tbuf:used())
    gdfd.tbuf:copy(0, gdfd.rbuf, delim_len, gdfd.rbuf:used() - delim_len)

    gdfd.rbuf:del(0, gdfd.rbuf:used())
    gdfd.rbuf:copy(0, gdfd.tbuf)

    return true
end

local function smtp_str_getdelimfd(ctrl)
    local gdfd = ctrl.gdfd
    local bytes_read = -1;
    while(true) do
        if smtp_str_getdelimfd_search_delim(gdfd) then
            if smtp_str_getdelimfd_set_line_and_buf(gdfd) then
                return smtp.STRING_GETDELIMFD_NEXT;
            end
            return smtp.STRING_GETDELIMFD_ERROR
        elseif bytes_read == 0 then
            gdfd.delim_pos = gdfd.rbuf:used()
            if smtp_str_getdelimfd_set_line_and_buf(gdfd) then
                return smtp.STRING_GETDELIMFD_DONE;
            end
        end

        bytes_read = smtp_str_getdelimfd_read(ctrl)
        if bytes_read < 0 then
            return smtp.STRING_GETDELIMFD_ERROR
        end
    end

    return smtp.STRING_GETDELIMFD_ERROR
end

local function smtp_getline(ctrl)
    local gdfd = ctrl.gdfd
    local rc = smtp_str_getdelimfd(ctrl)
    if rc == smtp.STRING_GETDELIMFD_ERROR then
        smtp_status_code_set(ctrl, rc)
        return rc
    end

    if string.len(gdfd.line) > 0 then
        log.info(LOG_TAG, "[Server]", gdfd.line)
    end

    return rc
end

local function smtp_puts(ctrl, data)
    local succ = libnet.tx(ctrl.task_name, 3000, ctrl.sock_ctrl, data)
    if not succ then
        log.error(LOG_TAG, "send data failed:", data)
        return smtp.SMTP_STATUS_SEND
    end
    return smtp.SMTP_STATUS_OK
end

local function smtp_parse_cmd_line(line)
    local cmd = {}
    cmd.more = false
    cmd.code =  smtp.SMTP_INTERNAL_ERROR

    if (string.len(line) < 5) then
        return cmd
    end

    local code_str = string.sub(line, 1, 3)
    local ulcode = tonumber(code_str);

    -- log.info(LOG_TAG, "resp code:", ulcode)

    if ulcode > smtp.SMTP_BEGIN_MAIL then
        return cmd
    end

    cmd.code = ulcode

    if string.sub(line, 4, 4) == "-" then
        cmd.more = true
    end

    return cmd
end

local function smtp_read_and_parse_code(ctrl)
    local cmd
    while(true) do
        local rc = smtp_getline(ctrl)
        if rc == smtp.STRING_GETDELIMFD_ERROR then
            return smtp.SMTP_INTERNAL_ERROR
        end
        cmd = smtp_parse_cmd_line(ctrl.gdfd.line)

        if rc == smtp.STRING_GETDELIMFD_DONE or not cmd.more then
            break
        end
    end
    return cmd.code
end

local function smtp_ehlo(ctrl)
    local rc = smtp_puts(ctrl, "EHLO smtp\r\n")
    if rc == smtp.SMTP_STATUS_OK then
        smtp_read_and_parse_code(ctrl)
    end
    return ctrl.status_code
end


local function smtp_initiate_handshake(ctrl)
    if smtp_getline(ctrl) == smtp.STRING_GETDELIMFD_ERROR then
        return ctrl.status_code
    end

    if smtp_ehlo(ctrl) ~= smtp.SMTP_STATUS_OK then
        log.error(LOG_TAG, "ehlo failed!")
        return ctrl.status_code
    end

    return ctrl.status_code
end

function smtp.open(task_name, server, port)
    local smtp_ctrl = {}
    local succ

    smtp_ctrl.gdfd = {}
    smtp_ctrl.gdfd.rbuf = zbuff.create(1024)
    smtp_ctrl.gdfd.tbuf = zbuff.create(1024)
    smtp_ctrl.gdfd.delim = string.byte("\n")
    smtp_ctrl.gdfd.delim_pos = -1
    smtp_ctrl.gdfd.line = ""

    smtp_ctrl.status_code = -1
    smtp_ctrl.task_name = task_name
    smtp_ctrl.sock_ctrl = socket.create(nil, smtp_ctrl.task_name)
    socket.debug(smtp_ctrl.sock_ctrl, false)
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
        log.info(LOG_TAG, "连接SMTP服务器成功")
    else
        socket.close(smtp_ctrl.sock_ctrl)
        socket.release(smtp_ctrl.sock_ctrl)
        log.error(LOG_TAG, "连接SMTP服务器失败")
    end

    if smtp_initiate_handshake(smtp_ctrl) ~= smtp.SMTP_STATUS_OK then
        return smtp_ctrl
    end

    return smtp_ctrl
end

local function smtp_auth_plain(ctrl, user, pass)
    local abuf = zbuff.create(128)

    abuf:write(0)
    abuf:write(user)
    abuf:write(0)
    abuf:write(pass)

    local bstr = string.toBase64(abuf:toStr())
    -- log.info(LOG_TAG, "base64 auth info:", bstr)

    local sbuf = zbuff.create(256)
    sbuf:write("AUTH PLAIN ")
    sbuf:write(bstr)
    sbuf:write("\r\n")

    if smtp_puts(ctrl, sbuf:toStr()) ~= smtp.SMTP_STATUS_OK then
        return -1
    end

    if smtp_read_and_parse_code(ctrl) ~= smtp.SMTP_AUTH_SUCCESS then
        return -1;
    end

    return smtp.SMTP_STATUS_OK
end

function smtp.auth(ctrl, user, pass)
    local rc

    rc = smtp_auth_plain(ctrl, user, pass)
    if rc < 0 then
        return smtp_status_code_set(smtp.SMTP_STATUS_AUTH)
    end

    return ctrl.status_code
end

local function smtp_send_email_task_cb(msg)
    log.error(LOG_TAG, "未处理消息:", msg[1], msg[2], msg[3], msg[4])
end

local function smtp_send_email(task_name, email_cfgs, msg)

    local smtp_ctrl = smtp.open(task_name, email_cfgs.smtp_addr, email_cfgs.smtp_port)

    if smtp_ctrl.status_code ~= smtp.SMTP_STATUS_OK then
        log.error(LOG_TAG, "smtp open failed!")
        return false
    else
        log.info(LOG_TAG, "smtp open succeed!")
    end

    if smtp.auth(smtp_ctrl, email_cfgs.user, email_cfgs.pass) ~= smtp.SMTP_STATUS_OK then
        log.error(LOG_TAG, "smtp auth failed!")
        return false
    else
        log.info(LOG_TAG, "smtp auth succeed!")
    end
end

local SEND_EMAIL_TASK   = "SendEmailTask"
function smtp.send_email(email_cfgs, msg)
    sysplus.taskInitEx(smtp_send_email, SEND_EMAIL_TASK, nil,
                        SEND_EMAIL_TASK, email_cfgs, msg)
end


return smtp

