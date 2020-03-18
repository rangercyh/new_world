--[[
ModuleName :
Path : agentmgr.lua
Author : jinlei
CreateTime : 2018-11-11 02:13:31
Description :
--]]
local skynet = require "skynet"
local logger = require "common.logger"
local config_system = require "config_system"
local config_agentmgr = config_system.agentmgr or {}

local maxAgentCount = config_agentmgr.max_agent_count or 100
local agentPerDatabase = config_agentmgr.agent_per_database or 10
local maxEnterPerBatch = config_agentmgr.max_enter_per_batch or 10

local gate = ...

local totalAgentCount = 0
local freeAgentPool = {}
local function newAgent()
	local agent
	if #freeAgentPool > 0 then
		agent = table.remove(freeAgentPool)
	else
		agent = skynet.newservice("agent", gate, skynet.self())
		totalAgentCount = totalAgentCount + 1
	end
	return agent
end

local function freeAgent(agent)
	table.insert(freeAgentPool, agent)
end

local function getUseAgentCount()
	return totalAgentCount - #freeAgentPool
end

local databasePool = {}
local databaseIdx = 0
local function nextDB()
	databaseIdx = databaseIdx % #databasePool + 1
	return databasePool[databaseIdx]
end

local clsQueue = {}
clsQueue.__class_mt = {__index = clsQueue}
function clsQueue.New()
	local q = {
		_queue = {}
	}
	setmetatable(q, clsQueue)
	return q
end

function clsQueue:Pop()
	local value
	if #self._queue > 0 then
		value = table.remove(self._queue, 1)
	end
	return value
end

function clsQueue:Push(value)
	table.insert(self._queue, value)
end

function clsQueue:Remove(value)
	local q = self._queue
	for idx = 1, #q do
		if q[idx] == value then
			return table.remove(self._queue, idx)
		end
	end
end

local clientQueue = clsQueue.New()

local clientMap = { }		-- key --> client
local clientFd2KeyMap = {}	-- fd -- > key

function getClientByFd(fd)
	local key = clientFd2KeyMap[fd]
	return key and clientMap[key]
end

-- 客户端
local clsClient = {clientCount = 0 }
clsClient.__class_mt = {__index = clsClient}
function clsClient.New(clientData)
	local key = clientData.key
	local userInfo = clientData.userInfo
	local o = {
		key = key,
		salt = clientData.salt,
		userInfo = userInfo,
		userId = nil,
		fd = nil,
	}
	setmetatable(o, clsClient.__class_mt)
	return o
end

function clsClient:Init(fd)
	assert(not clientFd2KeyMap[fd])
	local key = self.key
	assert(not clientMap[key])

	clientMap[key] = self
	clientQueue:Push(key)	-- 开始排队

	self.fd = fd
	clsClient.clientCount = clsClient.clientCount + 1
end

function clsClient:EnterGame()
	assert(not self.agent)
	self.agent = newAgent()

	skynet.send(self.agent, "lua", "start", self.fd, self, true)
end

function clsClient:ReenterGame(fd)
	assert(fd and fd ~= self.fd)
	assert(self.agent)
	self.fd = fd
	skynet.send(self.agent, "lua", "start", self.fd, self, false)
end

function clsClient:SendBinMsg(msg)
	skynet.send(".watchdog", "lua", "SendMsg", self.fd, string.pack(">s2", msg))
end

function clsClient:SendMsg(protoName, args)
	self:SendBinMsg(sproto_helper.PackMsg(protoName, args))
end

function clsClient:Release()

end

local function onUpdate()
	if shutingdown then
		return
	end

	local maxEnterCount = math.min(maxEnterPerBatch, maxAgentCount - getUseAgentCount())
	for i = 1, maxEnterCount do
		local client = clientQueue:Pop()
		client:EnterGame()
	end

	for idx, client in clientQueue:



	skynet.timeout(100, onUpdate)
end

local SOCKET = {}
function SOCKET.data(fd, msg)
	logger.errorf("agentmgr.SOCKET.data,fd=%d", fd)
	skynet.send(".watchdog", "lua", "close", fd, "agentmgr can't accept message")
end

local function handleDisconnect(fd, reason)
	local client = getClientByFd(fd)
	if not client then
		return
	end
	client:Close(reason)
end

function SOCKET.disconnect(fd)
	logger.debugf("agentmgr.SOCKET.disconnect,fd=%d", fd)
	handleDisconnect(fd, "socket.disconnect")
end

function SOCKET.error(fd, msg)
	logger.debugf("agentmgr.SOCKET.error,fd=%d,msg=%s", fd, msg)
	handleDisconnect(fd, "socket.error")
end

local CMD = {}
function CMD.socket(cmd, ...)
	return SOCKET[cmd](...)
end

function CMD.NewClient(fd, clientData)
	local key = clientData.key
	local client = clientMap[key]
	if client then
		--TODO
	else
		client = clsClient.New(clientData)
		client:Init(clientData.fd)
	end
	skynet.send(".watchdog", "lua", "Forward", fd, skynet.self())
end

function CMD.OnAgentDisconnect(key, agent, fd)
	local client = clientMap[key]
	if not client then
		logger.errorf("agentmgr.CMD.OnAgentDisconnect,key=%s,agent=%08x,fd=%d", key, agent, fd)
		return
	end
end

function CMD.start()
	-- 启动多个数据库服务,负载均衡
	local databaseCount = math.ceil(maxAgentCount / agentPerDatabase)
	for i = 1, databaseCount do
		db = skynet.newservice("database")
		table.insert(databasePool, db)
	end

	-- 预分配一定数量的agent
	for i = 1, config_agentmgr.pre_alloc_agent_count or 0 do
		local agent = skynet.newservice("agent", gate, skynet.self(), nexDB())
		freeAgent(agent)
	end
	totalAgentCount = #freeAgentPool

	skynet.timeout(100, onUpdate)
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, subcmd, ...)
		if cmd == "socket" then
			local f = SOCKET[subcmd]
			f(...)
			-- socket api don't need return
		else
			local f = assert(CMD[cmd])
			skynet.ret(skynet.pack(f(subcmd, ...)))
		end
	end)

	skynet.register(".agentmgr")
end
