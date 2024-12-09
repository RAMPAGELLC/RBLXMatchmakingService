# MatchmakingService

The `MatchmakingService` module provides a robust system for creating, joining, and managing parties for matchmaking in Roblox games. It supports both public, private, and Roblox studio parties and includes functionality for broadcasting updates and handling data persistence.

## Dependencies
* https://github.com/Ulferno/luau-cron

## Configuration

Edit the `config.luau` file to adjust the constants used by the `MatchmakingService`.

```lua
return {
    LOBBY_TOPIC = "Matchmaking_Lobby_Update",
    PARTY_DATASTORE_NAME = "PartyData",
    PUBLIC_PARTY_UPDATE_INTERVAL = 10, -- Seconds
    PARTY_DEFAULT_MAX_SIZE = 10,
    BLOCK_JOINING_MID_GAME = false,
}
```

## Usage

### Creating a Party
```lua
local MatchmakingService = require(game.ServerScriptService.MatchmakingService)
local matchmaking = MatchmakingService.new()

local leaderId = 123456
local isPublic = true
local attributes = { Map = "Desert", Mode = "Deathmatch" }
local maxSize = 8
local partyCode = matchmaking:CreateParty(leaderId, isPublic, attributes, maxSize)
print("Party created with code:", partyCode)
```

### Joining a Party

```lua
local playerId = 654321
local success, message = matchmaking:JoinParty(playerId, partyCode)
if success then
    print("Joined party successfully")
else
    print("Failed to join party:", message)
end
```

### Leaving a Party

```lua
local success = matchmaking:LeaveParty(playerId, partyCode)
if success then
    print("Left party successfully")
else
    print("Failed to leave party")
end
```

### Starting a Game

```lua
local success = matchmaking:StartGame(partyCode)
if success then
    print("Game started successfully")
else
    print("Failed to start game")
end
```

### Custom Matchmaking Logic

Override the `MatchPlayers` method to implement custom matchmaking logic. 

By-default we have reserver-server functionality & cross-server party-member teleportation. You can customize the place id by updating the party attributes field 'PlaceId'.

```lua
function MatchmakingService:MatchPlayers(partyData: Types.PartyData): boolean
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
			TeleportService:TeleportToPrivateServer(placeId, partyData.ReservedServerCode, { player })
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
```

### Fetching Public Parties
```lua
local publicParties = matchmaking:GetPublicParties()
for code, party in pairs(publicParties) do
    print("Public party code:", code, "Leader:", party.Leader)
end
```

### Getting Party Data for the Reserved Server
```lua
local partyData = matchmaking:GetPartyDataForReservedServer()
if partyData then
    print("Party data for reserved server:", partyData)
else
    print("No party data found for reserved server")
end
```

### Checking if This is a Party Reserved Server
```lua
local isReservedServer = matchmaking:IsPartyReservedServer()
if isReservedServer then
    print("This is a party reserved server")
else
    print("This is not a party reserved server")
end
```

## License
This project is licensed under the MIT License.