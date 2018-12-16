-- @name            Ambassador Library
-- @author          brianush1
-- @description     A library that allows for easy communication between client and server
-- @version         0.03

--[[
	Changelog:

	0.03:
		- Allow passing metatables

	0.02:
		- Fix bug of objects transmitted back and forth making new copies
		  e.g. object A transmitted Client -> Server -> Client != object A
]]

local Ambassador = {}

local Server = game:GetService("RunService"):IsServer()

function getName(server, name, target)
	return (server and "Server" or "Client") .. "Ambassador/" .. name .. "/" .. target.Name
end

local InvokationType = {
	RequestAmbassador = 0
}

function createRemote(name)
	if Server then
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = game:GetService("ReplicatedStorage")
		return remote
	else
		return game:GetService("ReplicatedStorage"):WaitForChild("Ambassador/RemoteRequestHandler"):InvokeServer(name)
	end
end

function getRemote(name)
	if Server then
		local remote = game:GetService("ReplicatedStorage"):FindFirstChild("Ambassador/" .. name)

		if remote then return remote end

		remote = Instance.new("RemoteFunction")
		remote.Name = "Ambassador/" .. name
		remote.Parent = game:GetService("ReplicatedStorage")
		return remote
	else
		return game:GetService("ReplicatedStorage"):WaitForChild("Ambassador/" .. name)
	end
end

function remoteInvokeHandler(name, func)
	local remote = getRemote(name)
	if Server then
		remote.OnServerInvoke = func
	else
		remote.OnClientInvoke = func
	end
end

local objects = {}

function generateObjectId(object)
	if objects[object] then return objects[object] end

	local id = game:GetService("HttpService"):GenerateGUID()
	objects[id] = object
	objects[object] = id
	return id
end

function pack(...)
	return select("#", ...), {...}
end

if Server then

	remoteInvokeHandler("RemoteRequestHandler", function(player, name)
		return createRemote(name)
	end)

	remoteInvokeHandler("FunctionCall", function(player, id, data)
		local success, result = pcall(function()
			return encodeTransmittion(objects[id](decodeTransmittion(data)))
		end)

		if success then
			return result
		else
			warn("Error: " .. result)
			error("An error occurred on the server", 0)
		end
	end)

else

	remoteInvokeHandler("FunctionCall", function(id, data)
		return encodeTransmittion(objects[id](decodeTransmittion(data)))
	end)

end

function encode(...)
	if select("#", ...) ~= 1 then
		local length = select("#", ...)
		local encoded = {}

		for i = 1, length do
			encoded[i] = encode((select(i, ...)))
		end

		return {
			type = "vararg",
			length = length,
			value = encoded
		}
	end

	local data = ...
	local dataType = type(data)

	if data ~= nil and objects[data] then
		return {
			type = "remoteObject",
			id = objects[data]
		}
	end

	if dataType == "string" or dataType == "number" or dataType == "boolean" or dataType == "nil" then
		return data
	elseif dataType == "table" then
		local meta = getmetatable(data)

		if type(meta) ~= "table" and meta ~= nil then error("Cannot encode locked metatable", 0) end

		local encoded = {}

		for key, value in pairs(data) do
			encoded[encode(key)] = encode(value)
		end

		return {
			type = meta and "metatable" or "regtable",
			id = generateObjectId(data),
			meta = meta and encode(meta),
			value = encoded
		}
	elseif dataType == "function" then
		local player = game.Players.LocalPlayer
		if player then player = player.Name end
		return {
			type = "function",
			player = player,
			id = generateObjectId(data)
		}
	end

	error("Cannot encode '" .. dataType .. "'", 0)
end

function decode(data)
	local dataType = type(data)
	if dataType == "string" or dataType == "number" or dataType == "boolean" then
		return data
	elseif dataType == "table" then
		dataType = data.type

		if data.id and objects[data.id] then
			return objects[data.id]
		end

		if dataType == "regtable" then
			local decoded = {}
	
			for key, value in pairs(data.value) do
				decoded[decode(key)] = decode(value)
			end
	
			local result = decoded

			objects[data.id] = result
			objects[result] = data.id

			return result
		elseif dataType == "metatable" then
			local meta = decode(data.meta)

			meta.__metatable = "The metatable is locked"

			local decoded = {}
	
			for key, value in pairs(data.value) do
				decoded[decode(key)] = decode(value)
			end

			local result = setmetatable(decoded, {
				__metatable = "The metatable is locked",
				__index = function(self, key)
					return meta.__index and meta:__index(key) or meta[key]
				end
			})

			objects[data.id] = result
			objects[result] = data.id

			return result
		elseif dataType == "vararg" then
			local decoded = {}

			for index, value in ipairs(data.value) do
				decoded[index] = decode(value)
			end

			return unpack(decoded, 1, data.length)
		elseif dataType == "function" then
			local result = function(...)
				if Server then
					local player = game:GetService("Players"):FindFirstChild(data.player)
					return decodeTransmittion(getRemote("FunctionCall"):InvokeClient(player, data.id, encodeTransmittion(...)))
				else
					return decodeTransmittion(getRemote("FunctionCall"):InvokeServer(data.id, encodeTransmittion(...)))
				end
			end

			objects[data.id] = result
			objects[result] = data.id

			return result
		end
	end

	error("Cannot decode '" .. dataType .. "'", 0)
end

function encodeTransmittion(...)
	return encode(...) --game:GetService("HttpService"):JSONEncode(encode(...))
end

function decodeTransmittion(data)
	return decode(data) --decode(game:GetService("HttpService"):JSONDecode(data))
end

function Ambassador:Send(name, target, data)
	assert(not (Server and not data), "Expected target for server ambassador")

	if not Server then
		data = target
		target = game.Players.LocalPlayer
	end

	local remote = createRemote(getName(Server, name, target))

	local function invokationHandler(type, ...)
		if type == InvokationType.RequestAmbassador then
			return encodeTransmittion(data)
		else
			error("Unknown request", 0)
		end
	end

	if Server then
		function remote.OnServerInvoke(player, ...)
			return invokationHandler(...)
		end
	else
		remote.OnClientInvoke = invokationHandler
	end
end

function Ambassador:Await(name, target, timeout)
	assert(not (Server and not target), "Expected target for client ambassador")

	if not Server then
		timeout = target
		target = game.Players.LocalPlayer
	end

	timeout = timeout or 30

	local remote
	local start = tick()
	repeat
		remote = game:GetService("ReplicatedStorage"):FindFirstChild(getName(not Server, name, target))

		if tick() - start > timeout then
			return false, "Timeout"
		end

		wait() until remote

	if Server then
		return true, decodeTransmittion(remote:InvokeClient(target, InvokationType.RequestAmbassador))
	else
		return true, decodeTransmittion(remote:InvokeServer(InvokationType.RequestAmbassador))
	end
end

function Ambassador:Receive(...)
	local success, ambassador = Ambassador:Await(...)
	assert(success, "Could not receive ambassador")
	return ambassador
end

return Ambassador
