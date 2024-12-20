-- Copyright (c) 2024 RAMPAGE Interactive. All rights reserved.
-- Copyright (c) 2024 Metatable Games. All rights reserved.
-- Written by vq9o <business@vq9o.com>

type PlayerUserId = number
type void = nil

export type PartyData = {
	Code: string,
	Leader: PlayerUserId,
	Members: { PlayerUserId },
	IsPublic: boolean,
	GameStarted: boolean,
	IsStudio: boolean,
	Attributes: { [string]: any },
	MaxSize: number?,
	ReservedServerCode: string?,
}

export type MatchmakingService = {
	ServerId: string,

	PlayerCache: { [PlayerUserId]: boolean },
	Parties: { [string]: PartyData },
	PublicParties: { [string]: PartyData },

	DataStore: GlobalDataStore,

	IsStudio: boolean,
	IsAPartyReservedServer: boolean,
	PartyDataForReservedServer: PartyData?,

	PartyUpdated: BindableEvent,

	new: () -> MatchmakingService,
    
	CreateParty: (
		self: MatchmakingService,
		leaderId: PlayerUserId,
		isPublic: boolean?,
		attributes: { [string]: any }?,
		maxSize: number?
	) -> string,

	CreateInternalStudioParty: (
		self: MatchmakingService,
		leaderId: number,
		attributes: { [string]: any }?,
		maxSize: number?
	) -> string,

	OnLobbyMatchmake: (self: MatchmakingService, player: Player) -> void,
	DisbandParty: (partyCode: string) -> (boolean, string?),
	HandleLeaderDisconnect: (self: MatchmakingService, partyCode: string, partyData: PartyData) -> void,
	IsPlayerConnected: (self: MatchmakingService, playerId: PlayerUserId) -> boolean,
	CheckForDisconnectedPlayers: (self: MatchmakingService) -> void,
	JoinParty: (self: MatchmakingService, playerId: PlayerUserId, code: string) -> (boolean, string?),
	LeaveParty: (self: MatchmakingService, playerId: PlayerUserId, code: string) -> boolean,
	StartGame: (self: MatchmakingService, code: string) -> boolean,
	MatchPlayers: (self: MatchmakingService, players: { PlayerUserId }) -> void,
	SaveParty: (self: MatchmakingService, code: string, data: PartyData) -> (boolean, string?),
	GetParty: (self: MatchmakingService, code: string) -> PartyData?,
	DeleteParty: (self: MatchmakingService, code: string) -> (boolean, string?),
	BroadcastLobbyUpdate: (self: MatchmakingService, action: string, data: PartyData) -> void,
	SubscribeToLobbyUpdates: (self: MatchmakingService) -> void,
	FetchPublicParties: (self: MatchmakingService) -> void,
	GetPublicParties: (self: MatchmakingService) -> { [string]: PartyData },
	IsPartyReservedServer: (self: MatchmakingService, partyCode: string?) -> boolean,
	GetPartyDataForReservedServer: (self: MatchmakingService) -> PartyData?,
}

return {}