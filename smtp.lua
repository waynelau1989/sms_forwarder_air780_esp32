local sys = require("sys")
local libnet = require("libnet")
local sysplus = require("sysplus")

local _M = {}

local LOG_TAG = "SMTP"

_M.SMTP_READY                  = 220

-- Returned in response to QUIT.
_M.SMTP_CLOSE                  = 221

-- Returned if client successfully authenticates.
_M.SMTP_AUTH_SUCCESS           = 235

-- Returned when some commands successfully complete.
_M.SMTP_DONE                   = 250

-- Returned for some multi-line authentication mechanisms where this code
-- indicates the next stage in the authentication step.
_M.SMTP_AUTH_CONTINUE          = 334

-- Returned in response to DATA command.
_M.SMTP_BEGIN_MAIL             = 354


local function smtp_write(smtp, data)
    local succ = libnet.tx(smtp.task_name, 3000, smtp.sock, data)
    if not succ then
        log.error(LOG_TAG, "send data failed:", data)
        return -1
    end
    return 0
end

local function smtp_read(smtp)
    local succ
    local sock_ev

    succ, sock_ev = libnet.wait(smtp.task_name, 5000, smtp.sock)
    if not succ then
        log.error(LOG_TAG, "socket wait failure")
        return -1
    end
    if not sock_ev then
        log.error(LOG_TAG, "socket wait timeout")
        return -1
    end

    succ, rlen = socket.rx(smtp.sock, smtp.rbuf)
    if not succ then
        log.error(LOG_TAG, "socket recv failure")
        return -1
    end

    -- log.info(LOG_TAG, "socket recv len:", rlen)
    return rlen
end

local function smtp_puts(smtp, data)
    log.info(LOG_TAG, "C:", data)

    data = data .. "\r\n"

    return smtp_write(smtp, data)
end

local function smtp_read_and_parse(smtp)
    local delim1 = string.byte("\r")
    local delim2 = string.byte("\n")
    local moreflag = string.byte("-")

    smtp.rbuf:del(0, smtp.rbuf:used())
    smtp.code = -1

    local pos = 0
    local more = true
    while (more) do
::READ::
        rc = smtp_read(smtp)
        if rc < 0 then
            log.error(LOG_TAG, "Recv smtp response failed!")
            return false
        end

::PARSE::
        local code = -1
        local flag = ""
        local line = ""
        for i=pos,smtp.rbuf:used() do
            if smtp.rbuf[i] == delim2 and i > 0 and smtp.rbuf[i-1] == delim1 then
                line = smtp.rbuf:toStr(pos, i-1)
                pos = i + 1
                break
            end
        end

        local len = string.len(line)

        if len == 0 then
            goto READ
        end

        log.info(LOG_TAG, "S:", line)
        if len > 3 then
            code = tonumber(string.sub(line, 1, 3))
            flag = string.sub(line, 4, 4)
        end

        if flag ~= "-" then
            smtp.code = code
            break
        end

        if pos < smtp.rbuf:used() then
            goto PARSE
        end
    end

    return true
end

local function smtp_cmd(smtp, cmd)
    local rc = smtp_puts(smtp, cmd)
    if not rc == 0 then
        log.error(LOG_TAG, "Send smtp command failed!")
        return rc
    end

    smtp_read_and_parse(smtp)

    return smtp.code
end

local function smtp_connect(smtp, config)
    smtp_port = config.smtp_port
    if smtp.tls then
        smtp_port = config.smtp_tls_port
    end

    local succ = libnet.connect(smtp.task_name, 5000, smtp.sock, config.smtp_addr, smtp_port)
    if not succ then
        return false
    end

    smtp_read_and_parse(smtp)

    if smtp.code ~= _M.SMTP_READY then
        return false
    end

    return true
end

local function smtp_ehlo(smtp)
    if smtp_cmd(smtp, "EHLO smtp") ~= _M.SMTP_DONE then
        return false
    end
    return true
end

local function smtp_auth_login(smtp, username, password)
    local rc

    local auth_str = "AUTH LOGIN "
    auth_str = auth_str .. string.toBase64(username)

    if smtp_cmd(smtp, auth_str) ~= _M.SMTP_AUTH_CONTINUE then
        return false
    end

    if smtp_cmd(smtp, string.toBase64(password)) ~= _M.SMTP_AUTH_SUCCESS then
        return false
    end

    return true
end

local function smtp_auth_plain(smtp, username, password)
    local auth_info = string.format("\0%s\0%s", username, password)
    local auth_str = "AUTH PLAIN "

    auth_str = auth_str .. string.toBase64(auth_info)
    rc = smtp_cmd(smtp, auth_str)
    if rc ~= _M.SMTP_DONE and rc ~= _M.SMTP_AUTH_SUCCESS then
        return false
    end

    return true
end

local function smtp_envelope_header(smtp, header, address)
    local cmd = header
    cmd = cmd .. ":<"
    cmd = cmd .. address
    cmd = cmd .. ">"

    if smtp_cmd(smtp, cmd) ~= _M.SMTP_DONE then
        return false
    end

    return true
end

local function smtp_mail(smtp, config, msg)
    if smtp_cmd(smtp, "DATA") ~= _M.SMTP_BEGIN_MAIL then
        return false
    end

    local header

    header = "From: "
    if config.from_name ~= "" then
        header = header .. "\""
        header = header .. config.from_name
        header = header .. "\" "
    end
    header = header .. "<"
    header = header .. config.from
    header = header .. ">"
    smtp_puts(smtp, header)

    header = "Subject: "
    header = header .. config.subject
    header = header .. ""
    smtp_puts(smtp, header)

    header = "To: "
    if config.to_name ~= "" then
        header = header .. "\""
        header = header .. config.to_name
        header = header .. "\" "
    end
    header = header .. "<"
    header = header .. config.to
    header = header .. ">"
    smtp_puts(smtp, header)

    msg = "\r\n" .. msg
    smtp_puts(smtp, msg)

    if smtp_cmd(smtp, ".") ~= _M.SMTP_DONE then
        return false
    end

    if smtp_cmd(smtp, "QUIT") ~= _M.SMTP_CLOSE then
        return false
    end

    return true
end

function _M.open(task_name, tls)
    local smtp = {}
    local succ

    smtp.from = ""
    smtp.to = ""
    smtp.rbuf = zbuff.create(4096)
    smtp.code = -1
    smtp.task_name = task_name
    smtp.sock = socket.create(nil, smtp.task_name)
    smtp.tls = tls
    socket.debug(smtp.sock, false)
    socket.config(smtp.sock, nil, nil, tls)

    log.info("SMTP", "task name:", smtp.task_name)

    succ = libnet.waitLink(smtp.task_name, 5000, smtp.sock)
    if not succ then
        log.error(LOG_TAG, "网络连接失败")
    end

    return smtp
end

function _M.close(smtp)
    socket.close(smtp.sock)
    socket.release(smtp.sock)
end


local function smtp_send_email_task_cb(msg)
    log.error(LOG_TAG, "未处理消息:", msg[1], msg[2], msg[3], msg[4])
end

local function smtp_send_email(task_name, config, msg)

    local tls = false
    if config.smtp_tls_port > 0 then
        tls = true
    end

    local smtp = _M.open(task_name, tls)

    if not smtp_connect(smtp, config) then
        log.error(LOG_TAG, "smtp connect failed!")
        return false
    end

    if not smtp_ehlo(smtp) then
        log.error(LOG_TAG, "smtp ehlo failed!")
        return false
    end

    if not smtp_auth_login(smtp, config.user, config.pass) then
        log.error(LOG_TAG, "smtp auth failed!")
        return false
    end

    if config.from == "" then
        config.from = config.user
    end

    if config.to == "" then
        config.to = config.from
    end

    if not smtp_envelope_header(smtp, "MAIL FROM", config.user) then
        log.error(LOG_TAG, "smtp envelope [MAIL FROM] failed!")
        return false
    end

    if not smtp_envelope_header(smtp, "RCPT TO", config.user) then
        log.error(LOG_TAG, "smtp envelope [RCPT TO] failed!")
        return false
    end

    if not smtp_mail(smtp, config, msg) then
        log.error(LOG_TAG, "smtp mail failed!")
        return false
    end

    return true
end

local SMTP_TASK = "SmtpTask"
function _M.send_email(config, msg)
    sysplus.taskInitEx(smtp_send_email, SMTP_TASK, nil, SMTP_TASK, config, msg)
end

return _M
