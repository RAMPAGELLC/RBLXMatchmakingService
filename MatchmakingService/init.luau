-- Copyright (c) 2024 RAMPAGE Interactive. All rights reserved.
-- Copyright (c) 2024 Metatable Games. All rights reserved.
-- Written by vq9o <business@vq9o.com>

local MatchmakingService = {}
MatchmakingService.__index = MatchmakingService

-- Services
local MessagingService = game:GetService("MessagingService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Config = require(script:WaitForChild("Config"))
local Types = require(script:WaitForChild("Types"))

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

-- Initialization
function MatchmakingService.new(): Types.MatchmakingService
	local self = setmetatable({}, MatchmakingService)

	self.Parties = {} -- In-memory party cache
	self.PublicParties = {} -- Cached public parties

	self.DataStore = DataStoreService:GetDataStore(Config.PARTY_DATASTORE_NAME)
	self.IsStudio = RunService:IsStudio()

	self:SubscribeToLobbyUpdates()
    self:SubscribeToTeleportPlayer()

	-- Periodically fetch public parties for clients
	task.spawn(function()
		while task.wait(Config.PUBLIC_PARTY_UPDATE_INTERVAL) do
			self:FetchPublicParties()
		end
	end)

	return self
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
        ReservedServerCode = nil 
	}

	self.Parties[partyCode] = partyData
	self:SaveParty(partyCode, partyData)

	if isPublic then
		self.PublicParties[partyCode] = partyData
		self:BroadcastLobbyUpdate("Create", partyData)
	end

	return partyCode
end

function MatchmakingService:CreateInternalStudioParty(leaderId: number, attributes: { [string]: any }?, maxSize: number?): string
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

	for i, member in ipairs(partyData.Members) do
		if member == playerId then
			table.remove(partyData.Members, i)
			break
		end
	end

	if #partyData.Members == 0 then
		self:DeleteParty(code)
	else
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

-- Matchmaking Logic (Override for customization)
function MatchmakingService:MatchPlayers(partyData: Types.PartyData): boolean
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
			local s,e = pcall(function()
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
		self.DataStore:SetAsync(code, data)
	end)

	if not success then
		return false, err
	end

    if data.IsPublic then
        self:BroadcastLobbyUpdate("Update", data)
    end

	return true
end

function MatchmakingService:GetParty(code: string): Types.PartyData?
	if self.Parties[code] then
		return self.Parties[code]
	end

	local success, data = pcall(function()
		return self.DataStore:GetAsync(code)
	end)

	if success then
		self.Parties[code] = data
		return data
	else
		return nil
	end
end

function MatchmakingService:DeleteParty(code: string): (boolean, string?)
	self.Parties[code] = nil
	local success, err = pcall(function()
		self.DataStore:RemoveAsync(code)
	end)
	if not success then
		return false, err
	end

	if self.PublicParties[code] then
		self.PublicParties[code] = nil
		self:BroadcastLobbyUpdate("Remove", { Code = code })
	end

	return true
end

-- Lobby Updates
function MatchmakingService:BroadcastLobbyUpdate(action: string, data: Types.PartyData)
	MessagingService:PublishAsync(Config.LOBBY_TOPIC, { Action = action, Party = data })
end

function MatchmakingService:SubscribeToLobbyUpdates()
	MessagingService:SubscribeAsync(Config.LOBBY_TOPIC, function(message)
		local data = message.Data

		if data.Action == "Create" then
			self.PublicParties[data.Party.Code] = data.Party
		elseif data.Action == "Update" then
			self.PublicParties[data.Party.Code] = data.Party
		elseif data.Action == "Remove" then
			self.PublicParties[data.Party.Code] = nil
		end
	end)
end

function MatchmakingService:SubscribeToTeleportPlayer()
    MessagingService:SubscribeAsync("TeleportPlayer", function(message)
        local data = message.Data
        local player = Players:GetPlayerByUserId(data.playerId)

        if player then
            local s,e = pcall(function()
				TeleportService:TeleportToPrivateServer(data.placeId, data.reservedServerCode, { player })
			end)

			if not s then
				warn(e)
			end
        end
    end)
end

function MatchmakingService:FetchPublicParties()
	-- Public parties are filtered for the current environment (studio and production)

	local publicParties = {}

	for code, party in pairs(self.PublicParties) do
		if party.IsStudio == self.IsStudio then
			publicParties[code] = party
		end
	end

	self.PublicParties = publicParties
end

function MatchmakingService:GetPublicParties(): { [string]: Types.PartyData }
	return self.PublicParties
end

-- Check if this is a party reserved server
function MatchmakingService:IsPartyReservedServer(): boolean
    local reservedServerCode = game.PrivateServerId

    if reservedServerCode and reservedServerCode ~= "" then
        for _, party in pairs(self.Parties) do
            if party.ReservedServerCode == reservedServerCode then
                return true
            end
        end
    end

    return false
end

-- Get party data for the reserved server
function MatchmakingService:GetPartyDataForReservedServer(): Types.PartyData?
    local reservedServerCode = game.PrivateServerId

    if reservedServerCode and reservedServerCode ~= "" then
        for _, party in pairs(self.Parties) do
            if party.ReservedServerCode == reservedServerCode then
                return party
            end
        end
    end

    return nil
end

return MatchmakingService