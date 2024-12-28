-- Copyright (c) 2024 RAMPAGE Interactive. All rights reserved.
-- Copyright (c) 2024 Metatable Games. All rights reserved.
-- Written by vq9o <business@vq9o.com>

local MatchmakingService = {}
MatchmakingService.__index = MatchmakingService

-- Services
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local Config = require(script:WaitForChild("Config"))
local Types = require(script:WaitForChild("Types"))
local cron = require(script.Parent:WaitForChild("luaucron"))

-- TODO: Delete party properly from MSS on server shutdonw/party all left.

-- Utilities
local function generateCode(length)
	local characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	local code = ""

	for i = 1, length do
		local randomIndex = math.random(1, #characters)
		code = code .. string.sub(characters, randomIndex, randomIndex)
	end

	return code
end

local function printDictionary(dictionary: table?, indent: number)
	assert(not indent or (indent and typeof(indent) == "number"), "Indent must be a number")

	if not dictionary or (dictionary and not typeof(dictionary) == "table") then
		return
	end

	if RunService:IsStudio() then
		warn(dictionary)
		return
	end

	indent = indent or 0 -- Default indentation level
	local spacing = string.rep("  ", indent) -- Indentation spacing

	for key, value in pairs(dictionary) do
		if type(value) == "table" then
			print(spacing .. tostring(key) .. ":")
			printDictionary(value, indent + 1) -- Recursive call for nested tables
		else
			print(spacing .. tostring(key) .. ": " .. tostring(value))
		end
	end
end

function MatchmakingService.new(): Types.MatchmakingService & typeof(MatchmakingService)
	local self = setmetatable({}, MatchmakingService)

	self.ActivePartiesMap = MemoryStoreService:GetSortedMap(Config.PARTY_MSS_NAME)
	self.ServerId = HttpService:GenerateGUID(false)
	self.PlayerCache = {} -- In-memory temp player cache
	self.Parties = {} -- In-memory party cache
	self.IsStudio = RunService:IsStudio()
	self.PartyUpdated = Instance.new("BindableEvent")
	self.PartiesInitilized = false

	self:InitializeParties()

	-- Yield until all parties are loaded into Memory.
	repeat
		task.wait(0.1)
	until self.PartiesInitilized

	self:SubscribeToLobbyUpdates()
	self:SubscribeToTeleportPlayer()

	self.IsAPartyReservedServer = self:IsPartyReservedServer()
	self.PartyReservedServerData = self:GetPartyDataForReservedServer()

	--warn("IsAPartyReservedServer", self.IsAPartyReservedServer)
	--printDictionary(self.PartyReservedServerData)

	if self.IsAPartyReservedServer then
		-- Delete party on server shutdown
		game:BindToClose(function()
			self:DeleteParty(self.PartyReservedServerData.Code)
		end)
	end

	for i, player: Player in pairs(Players:GetPlayers()) do
		self:PlayerAdded(player)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		self:PlayerAdded(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self.PlayerCache[player.UserId] = { false, os.time() + (5 * 60) }

		-- Delete the party as all members left!
		if self.IsAPartyReservedServer and (#Players:GetPlayers() <= 0) then
			self:DeleteParty(self.PartyReservedServerData.Code)
		end
	end)

	cron.schedule("*/1 * * * *", function()
		for i, v in pairs(self.PlayerCache) do
			if v[2] == nil or v[1] then
				continue
			end

			if os.time() >= v[2] then
				self.PlayerCache[i] = nil
			end
		end
	end)

	return self
end

-- Initialize parties from MemoryStore
function MatchmakingService:InitializeParties()
	local attempts = 0
	local success, result

	repeat
		success, result = pcall(function()
			return self.ActivePartiesMap:GetRangeAsync(Enum.SortDirection.Ascending, 200)
		end)
		if not success then
			attempts += 1
			task.wait(1)
		end
	until success or attempts >= 3

	if not success or type(result) ~= "table" then
		warn("Failed to initialize parties after retries: " .. tostring(result))
		return
	end

	for _, entry in ipairs(result) do
		local code = entry.key
		local partyData = entry.value

		if code and partyData and type(partyData) == "table" then
			self.Parties[code] = partyData
		else
			warn("Invalid party data entry:", entry)
		end
	end

	self.PartiesInitilized = true
end

function MatchmakingService:PlayerAdded(player: Player)
	if
		Config.PARTY_SERVER_SIZE_HARD_LIMIT
		and self.IsAPartyReservedServer
		and self.PartyReservedServerData.MaxSize > 0
		and #Players:GetPlayers() > self.PartyReservedServerData.MaxSize
	then
		player:Kick(
			"[RBLXMatchmakingService]: This server is reserved for an matchmake party, the party is currently full!"
		)

		return
	end

	self.PlayerCache[player.UserId] = { true }

	MessagingService:PublishAsync(
		Config.LOBBY_TOPIC,
		{ Action = "DeletePlayerCache", IgnoreServerId = self.ServerId, PlayerId = player.UserId }
	)
end

function MatchmakingService:DeleteParty(code: string): (boolean, string?)
	local success, err = pcall(function()
		self.ActivePartiesMap:RemoveAsync(code)
	end)

	if not success then
		warn("Failed to delete party data from MemoryStoreService for code:", code, "Error:", tostring(err))
		return false, err
	end

	if self.Parties[code] then
		self.Parties[code] = nil
		self:BroadcastLobbyUpdate("Remove", { Code = code })
	end

	self.PartyUpdated:Fire("PARTY_DELETED", code)

	return true
end

function MatchmakingService:DisbandParty(partyCode: string): (boolean, string?)
	return self:DeleteParty(partyCode)
end

function MatchmakingService:HandleLeaderDisconnect(partyCode: string, partyData: Types.PartyData)
	if #partyData.Members > 0 and Config.REASSIGN_LEADER_INSTEAD_OF_DISBAND then
		partyData.Leader = partyData.Members[1]
		self:SaveParty(partyData.Code, partyData)
	else
		self:DisbandParty(partyCode)
	end
end

function MatchmakingService:IsPlayerConnected(playerId: number, callback: (isConnected: boolean) -> nil): boolean
	local player = Players:GetPlayerByUserId(playerId)

	if player then
		return true
	end

	local IsConnected: boolean = false

	local con
	con = MessagingService:SubscribeAsync("PlayerConnectionStatus", function(message)
		local data = message.Data

		if data.PlayerId == playerId then
			IsConnected = data.IsConnected
			con:Disconnect()

			if callback then
				callback(IsConnected)
			end
		end
	end)

	MessagingService:PublishAsync("CheckPlayerConnection", { PlayerId = playerId })

	local waitTime = 0

	if callback then
		task.spawn(function()
			repeat
				waitTime += 1
				task.wait(1)
			until IsConnected or waitTime >= 5

			return callback(IsConnected)
		end)

		return false
	end

	repeat
		waitTime += 1
		task.wait(1)
	until IsConnected or waitTime >= 3

	return IsConnected
end

function MatchmakingService:CheckForDisconnectedPlayers()
	for partyCode, partyData in pairs(self.Parties) do
		if partyData.GameStarted or self:IsPartyReservedServer(partyCode) then
			continue
		end

		for _, memberId: number in pairs(partyData.Members) do
			self:IsPlayerConnected(memberId, function(isConnected: boolean)
				if not isConnected then
					table.remove(partyData.Members, table.find(partyData.Members, memberId))
					self:SaveParty(partyData.Code, partyData)

					if memberId == partyData.Leader then
						self:HandleLeaderDisconnect(partyCode, partyData)
					end
				end
			end)
		end
	end
end

-- Party Creation
function MatchmakingService:CreateParty(
	leaderId: number,
	isPublic: boolean?,
	attributes: { [string]: any }?,
	maxSize: number?
): string
	local partyCode = generateCode(6)

	local partyData: Types.PartyData = {
		Code = partyCode,
		Leader = leaderId,
		Members = { leaderId },
		IsPublic = isPublic or false,
		GameStarted = false,
		IsStudio = self.IsStudio,
		Attributes = attributes or {},
		MaxSize = maxSize or Config.PARTY_DEFAULT_MAX_SIZE,
		ReservedServerCode = nil,
	}

	self.Parties[partyCode] = partyData
	self:SaveParty(partyCode, partyData)

	if isPublic then
		self:BroadcastLobbyUpdate("Create", partyData)
	end

	return partyCode
end

function MatchmakingService:CreateInternalStudioParty(
	leaderId: number,
	attributes: { [string]: any }?,
	maxSize: number?
): string
	assert(self.IsStudio, "Internal studio parties can only be created in Studio mode")
	return self:CreateParty(leaderId, false, attributes, maxSize)
end

-- Join Party
function MatchmakingService:JoinParty(playerId: number, code: string): (boolean, string?)
	local partyData = self:GetParty(code)

	if not partyData then
		return false, "Party not found"
	end

	if partyData.GameStarted and Config.BLOCK_JOINING_MID_GAME then
		return false, "Game already started"
	end

	if partyData.IsStudio ~= self.IsStudio then
		return false, "Cannot join Roblox studio parties from production and vice versa"
	end

	if partyData.MaxSize ~= nil and partyData.MaxSize > 0 and #partyData.Members >= (partyData.MaxSize or 10) then
		return false, "Party is full"
	end

	table.insert(partyData.Members, playerId)
	self:SaveParty(code, partyData)

	return true
end

-- Leave Party
function MatchmakingService:LeaveParty(playerId: number, code: string): boolean
	local partyData = self:GetParty(code)

	if not partyData then
		return false, "Party not found"
	end

	if #partyData.Members <= 1 then
		self:DeleteParty(code)
	else
		for i, member in ipairs(partyData.Members) do
			if member == playerId then
				table.remove(partyData.Members, i)
				break
			end
		end

		self:SaveParty(code, partyData)
	end

	return true
end

-- Start Game
function MatchmakingService:StartGame(code: string): boolean
	local partyData = self:GetParty(code)

	if not partyData then
		return false, "Party not found"
	end

	if partyData.GameStarted then
		return false, "Game already started"
	end

	partyData.GameStarted = true

	self:SaveParty(code, partyData)
	self:MatchPlayers(partyData)

	return true
end

function MatchmakingService:OnLobbyMatchmake(func: (partyData: Types.PartyData) -> boolean)
	self.CustomOnLobbyMatchmake = func
end

function MatchmakingService:MatchPlayers(partyData: Types.PartyData): boolean
	if self.CustomOnLobbyMatchmake ~= nil then
		return self.CustomOnLobbyMatchmake(partyData)
	end

	-- Default behavior: Reserve a server and teleport players
	local placeId = partyData.Attributes.PlaceId or game.PlaceId

	if partyData.ReservedServerCode == nil then
		local reservedServerCode, errorMessage = TeleportService:ReserveServer(placeId)

		if not reservedServerCode then
			warn("Failed to reserve server: " .. errorMessage)
			return false
		end

		partyData.ReservedServerCode = reservedServerCode
		self:SaveParty(partyData.Code, partyData)
	end

	for _, playerId in ipairs(partyData.Members) do
		local player = Players:GetPlayerByUserId(playerId)

		if player then
			local s, e = pcall(function()
				TeleportService:TeleportToPrivateServer(placeId, partyData.ReservedServerCode, { player })
			end)

			if not s then
				warn(e)
			end
		else
			MessagingService:PublishAsync("TeleportPlayer", {
				playerId = playerId,
				placeId = placeId,
				reservedServerCode = partyData.ReservedServerCode,
			})
		end
	end

	return true
end

-- Data Handling
function MatchmakingService:SaveParty(code: string, data: Types.PartyData): (boolean, string?)
	self.Parties[code] = data

	local success, err = pcall(function()
		self.ActivePartiesMap:SetAsync(code, data, Config.PARTY_EXPIRATION_TIME)
	end)

	if not success then
		warn("Failed to save party data to MemoryStoreService for code:", code, "Error:", tostring(err))
		return false, err
	end

	self:BroadcastLobbyUpdate("Update", data)
	self.PartyUpdated:Fire("PARTY_UPDATED", data)

	return true
end

function MatchmakingService:GetParty(code: string): Types.PartyData?
	if self.Parties[code] then
		return self.Parties[code]
	end

	local success, data = pcall(function()
		return self.ActivePartiesMap:GetAsync(code)
	end)

	if success and data then
		self.Parties[code] = data -- Cache in memory
		return data
	else
		warn("Failed to get party data from MemoryStoreService for code:", code, "Error:", tostring(data))
		return nil
	end
end

-- Lobby Updates
function MatchmakingService:BroadcastLobbyUpdate(action: string, data: Types.PartyData?)
	MessagingService:PublishAsync(Config.LOBBY_TOPIC, { Action = action, Party = data })
end

function MatchmakingService:SubscribeToLobbyUpdates()
	MessagingService:SubscribeAsync(Config.LOBBY_TOPIC, function(message)
		local data = message.Data

		if data.Action == "Create" then
			self.Parties[data.Party.Code] = data.Party
			self.PartyUpdated:Fire("PARTY_CREATED", data.Party)
		elseif data.Action == "Update" then
			self.Parties[data.Party.Code] = data.Party
			self.PartyUpdated:Fire("PARTY_UPDATED", data.Party)
		elseif data.Action == "Remove" then
			self.Parties[data.Party.Code] = nil
			self.PartyUpdated:Fire("PARTY_DELETED", data.Party.Code)
		elseif data.Action == "DeletePlayerCache" then
			if self.ServerId == data.IgnoreServerId then
				return
			end

			self.PlayerCache[data.PlayerId] = nil
		elseif data.Action == "CheckPlayerConnection" then
			if self.PlayerCache[data.PlayerId] then
				MessagingService:PublishAsync(
					"PlayerConnectionStatus",
					{ PlayerId = data.PlayerId, IsConnected = self.PlayerCache[data.PlayerId][1] }
				)
			end
		end
	end)
end

function MatchmakingService:SubscribeToTeleportPlayer()
	MessagingService:SubscribeAsync("TeleportPlayer", function(message)
		local data = message.Data
		local player = Players:GetPlayerByUserId(data.playerId)

		if player then
			local s, e = pcall(function()
				TeleportService:TeleportToPrivateServer(data.placeId, data.reservedServerCode, { player })
			end)

			if not s then
				warn(e)
			end
		end
	end)
end

function MatchmakingService:GetActiveParties(): { [string]: Types.PartyData }
	return self.Parties
end

function MatchmakingService:GetPublicParties(): { [string]: Types.PartyData }
	-- Public parties are filtered for the current environment (studio and production)
	local publicParties = {}

	for code, party: Types.PartyData in pairs(self.Parties) do
		if party.IsStudio == self.IsStudio and party.IsPublic then
			publicParties[code] = party
		end
	end

	return publicParties
end

-- Check if this is a party reserved server
function MatchmakingService:IsPartyReservedServer(partyCode: string?): boolean
	if partyCode then
		local partyData = self.Parties[partyCode]

		return partyData and partyData.PrivateServerId ~= nil
	end

	local PrivateServerId = game.PrivateServerId

	if PrivateServerId and PrivateServerId ~= "" then
		for _, party in pairs(self.Parties) do
			if party.PrivateServerId == PrivateServerId then
				return true
			end
		end
	end

	return false
end

-- Get party data for the reserved server
function MatchmakingService:GetPartyDataForReservedServer(): Types.PartyData?
	local PrivateServerId = game.PrivateServerId

	if PrivateServerId and PrivateServerId ~= "" then
		for _, party in pairs(self.Parties) do
			if party.PrivateServerId == PrivateServerId then
				return party -- Found the matching party
			end
		end
	end

	warn("No party matches the reserved server code:", PrivateServerId)
	return nil
end

type FriendData = {
	VisitorId: number,
	UserName: string,
	DisplayName: string,
	LastOnline: string,
	IsOnline: boolean,
	LastLocation: string,
	PlaceId: number,
	GameId: string,
	LocationType: number, -- https://create.roblox.com/docs/reference/engine/classes/Player#GetFriendsOnline
}

function MatchmakingService:GetFriendLobbies(
	Player: Player,
	MaxFriends: number?,
	IncludeStartedGames: boolean?
): { Types.PartyData }
	MaxFriends = MaxFriends or 200
	IncludeStartedGames = IncludeStartedGames or false

	assert(MaxFriends <= 200, "MaxFriends cannot be more than 200 (Roblox API limit!)")

	local FriendLobbies = {}
	local success, result = pcall(Player.GetFriendsOnline, Player, MaxFriends)

	if not success then
		warn("Failed to get friends online for player:", Player.UserId, "Error:", result)
		return {}
	end

	for _, v: FriendData in pairs(result) do
		if not v.IsOnline then
			continue
		end

		if v.PlaceId == nil then
			continue
		end

		if v.PlaceId ~= game.PlaceId then
			continue
		end

		for _, party: Types.PartyData in pairs(self.Parties) do
			if party.GameStarted and not IncludeStartedGames then
				continue
			end

			if party.Leader == v.VisitorId or table.find(party.Members, v.VisitorId) then
				table.insert(FriendLobbies, party)
			end
		end
	end

	return FriendLobbies
end

return MatchmakingService
