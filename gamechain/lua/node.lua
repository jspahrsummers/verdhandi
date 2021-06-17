local Blockchain = require("gamechain.blockchain")
local Clock = require("gamechain.clock")
local message = require("gamechain.message")
local opcode = require("gamechain.opcode")
local Producer = require("gamechain.producer")
local PublicKey = require("gamechain.publickey")
local tohex = require("gamechain.tohex")
local timer = require("gamechain.timer")

local Node = {}
Node.__index = Node
Node.PEER_PING_MIN_INTERVAL = 50
Node.PEER_PING_MAX_JITTER = 20
Node.PEER_PING_TIMEOUT = 120

setmetatable(Node, {
	__call = function (cls, obj, ...)
		local self = setmetatable(obj or {}, cls)
		self:init(...)
		return self
	end,
})

local function peer_set_to_list(peer_set)
	local list = {}
	for peer, _ in pairs(peer_set) do
		list[#list + 1] = peer
	end

	table.sort(list)
	return list
end

local function producer_keys(producers)
	local keys = {}
	for _, producer in pairs(producers) do
		keys[#keys + 1] = producer.wallet_pubkey
	end

	return keys
end

function Node:init()
	assert(self.networker, "Node must be created with a networker to use")

	if not self.clock then
		self.clock = Clock.os()
	end

	if self.peer_list then
		self.peer_set = {}
		local t = self.clock:now()
		for _, peer in pairs(self.peer_list) do
			self.peer_set[peer] = t
		end

		self.peer_list = nil
	else
		self.peer_set = {}
	end

	self:_set_blockchain(self.chain or Blockchain {})
end

--- Runs the node logic forever, or until an error is raised.
-- This function never returns normally, but will regularly yield if wrapped into a coroutine.
function Node:run()
	math.randomseed(os.time())

	local peer_ping_interval = self.PEER_PING_MIN_INTERVAL + math.random() * self.PEER_PING_MAX_JITTER

	local coros = {
		self:_recv_loop(),
		timer.every(peer_ping_interval, function () self:_ping_peers() end, self.clock),
	}

	while true do
		for _, coro in ipairs(coros) do
			coroutine.resume(coro)
		end

		coroutine.yield()
	end
end

function Node:_recv_loop()
	return coroutine.create(function ()
		while true do
			local sender, bytes = self.networker:recv()
			self.peer_set[sender] = self.clock:now()

			local msg = message.decode(bytes)
			self:handle_message(sender, msg)

			coroutine.yield()
		end
	end)
end

function Node:_ping_peers()
	local current_time = self.clock:now()
	for peer, last_seen in pairs(self.peer_set) do
		if self.clock:diff_seconds(current_time, last_seen) >= self.PEER_PING_TIMEOUT then
			-- Drop unresponsive peer.
			self.peer_set[peer] = nil
		else
			local msg = message.ping(current_time)
			self.networker:send(peer, message.encode(msg))
		end

		coroutine.yield()
	end
end

function Node:create_wallet()
	if self.wallet_privkey then
		io.stderr:write(string.format("Warning: creating new wallet for node to replace wallet %s", self.wallet_privkey:public_key()))
	end

	-- TODO
	assert(false)
end

function Node:handle_message(sender, msg)
	local handlers = {
		[message.APP_DEFINED] = self.handle_app_defined,
		[message.PING] = self._handle_ping,
		[message.PONG] = self._handle_pong,
		[message.REQUEST_PEER_LIST] = self._handle_request_peer_list,
		[message.PEER_LIST] = self._handle_peer_list,
		[message.REQUEST_BLOCKCHAIN] = self._handle_request_blockchain,
		[message.BLOCKCHAIN] = self._handle_blockchain,
		[message.BLOCK_FORGED] = self._handle_block_forged,
	}

	local name = msg[1]
	local handler = handlers[name]
	if handler then
		handler(self, sender, table.unpack(msg, 2))
	else
		io.stderr:write("Non-producer node cannot handle message ", name)
	end
end

function Node:handle_app_defined(sender, ...)
	-- Does nothing by default. A custom handler can be provided at init time to override this method.
	io.stderr:write("Node received app-defined message it doesn't know how to handle")
end

function Node:_handle_ping(sender, token)
	local msg = message.pong(token)
	self.networker:send(sender, message.encode(msg))
end

function Node:_handle_pong(sender, token)
	-- This sender was already marked as active in the receive loop.
end

function Node:_handle_request_peer_list(sender, token)
	local msg = message.peer_list(token, peer_set_to_list(self.peer_set))
	self.networker:send(sender, message.encode(msg))
end

function Node:_handle_peer_list(sender, maybe_token, peers)
	local t = self.clock:now()
	for _, peer in pairs(peers) do
		if not self.peer_set[peer] then
			self.peer_set[peer] = t
		end
	end
end

function Node:_handle_request_blockchain(sender, token)
	if not self.chain then
		return
	end

	local msg = message.blockchain(token, self.chain)
	self.networker:send(sender, message.encode(msg))
end

function Node:_handle_blockchain(sender, token, blocks)
	-- TODO: This should reconcile the multiple blockchains somehow (e.g., longest chain rule, or build consensus using N different chains). For now, we just trust the first one we receive.
	if #self.chain > 0 then
		io.stderr:write(string.format("Peer node %s tried to replace our blockchain with:\n%s", sender, chain))
		return
	end

	self:_set_blockchain(Blockchain(blocks))
end

function Node:_set_blockchain(chain)
	self.chain = chain
	self.known_producers = {}

	for block in self.chain:traverse_latest() do
		local op = opcode.decode(block.data)
		if not op then
			io.stderr:write(string.format("Unable to parse block %s", tohex(block.hash)))
		elseif op[1] == opcode.PRODUCERS_CHANGED then
			for _, row in pairs(op[2]) do
				local address, wallet_pubkey, wallet_balance = table.unpack(row)
				self.known_producers[#self.known_producers + 1] = Producer {
					peer_address = address,
					wallet_pubkey = PublicKey(wallet_pubkey)
				}
			end
		end
	end
end

function Node:_handle_block_forged(sender, block)
	if not block:verify_signers(producer_keys(self.known_producers)) then
		io.stderr.write(string.format("Missing consensus for block sent by peer node %s:\n%s", sender, block))
		return
	end

	if not self.chain:add_block(block) then
		io.stderr.write(string.format("Peer node %s tried to add an incompatible block to our chain:\n%s", sender, block))
		return
	end
end

return Node