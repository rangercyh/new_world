--[[
ModuleName :
Path : lualib/auth/main.lua
Author : jinlei
CreateTime : 2020-03-21 00:10:00
Description :
--]]
local skynet = require "skynet"
local skynet_queue = require "skynet.queue"
local logger = require "common.logger"
local config = require "config_system"
local sproto_helper = require "common.sproto_helper"

local clientMap = { }

local function genSalt()
	local a = math.random(1 << 31)
	local b = math.random(1 << 31)
	local c = math.random(1 << 31)
	return string.format("%08x%08x%08x", a, b, c)
end

-- 客户端
local clsClient = { }
function clsClient.New(fd, address)
	local o = {
		fd = fd,
		address = address,
		salt = genSalt(),
		userInfo = nil,
		mq = skynet_queue(),
	}
	setmetatable(o, {__index = clsClient})
	return o
end

function clsClient:HandShake(args)
	self.userInfo = args
	return {code = 0, salt = self.salt, patch = config.client_patch}
end

function clsClient:Auth(args)
	--TODO: 处理登录超时
	--TODO: 认证合法性
	--TODO: 检查是否封号
	local ok = true
	if ok then
		-- TODO: 校验成功
		skynet.send(".agentmgr", "lua", "NewClient", self.fd, self)
	else
		-- TODO: 校验失败
	end
	self.finish = true
	return {code = 0}
end

function clsClient:Release()
	local fd = self.fd
	clientMap[fd] = nil
	skynet.send(".gate", "lua", "close", fd)
end

function clsClient:SendBinMsg(msg)
	skynet.send(".gate", "lua", "SendMsg", self.fd, string.pack(">s2", msg))
end

function clsClient:HandleClientMsg(msg)
	self.mq(function()
		if self.finish then --认证结束
			self:Release()
			return
		end

		local ok, result = sproto_helper.DispatchAndHandleRequest(self, msg)
		if not ok then
			self:Release()
			return
		end

		if result then
			self:SendBinMsg(result)
		end
	end)
end

local SOCKET = {}
function SOCKET.data(fd, msg)
	logger.debugf("SOCKET.data:fd=%d,msg=%s", fd, tostring(msg))
	local client = clientMap[fd]
	if not client then
		return
	end
	client:HandleClientMsg(msg)
end

function SOCKET.open(fd, address)
	logger.debugf("SOCKET.open:fd=%d,address=%s", fd, address)
	assert(not clientMap[fd])
	local client = clsClient.New(fd, address)
	clientMap[fd] = client
end

local function handleSocketClose(fd)
	local client = clientMap[fd]
	if not client then
		return
	end
	clientMap[fd] = nil
end

function SOCKET.close(fd)
	logger.debugf("SOCKET.close:fd=%d", fd)
	handleSocketClose(fd)
end

function SOCKET.error(fd, msg)
	logger.debugf("SOCKET.error:fd=%d,msg=%s", fd, msg)
	handleSocketClose(fd)
end

function SOCKET.warning(fd, sz)
	logger.debugf("SOCKET.warning:fd=%d,sz=%s", fd, sz)
end

local CMD = {}
function CMD.socket(cmd, ...)
	return SOCKET[cmd](...)
end

function GetCmdHandler(cmd)
	return CMD[cmd]
end

function SystemStartup(module)
	sproto_helper.RegMsgHandler("AUTH_HandShake", clsClient.HandShake)
	sproto_helper.RegMsgHandler("AUTH_Auth", clsClient.Auth)
end
