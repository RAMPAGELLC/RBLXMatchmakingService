-- Copyright (c) 2024 RAMPAGE Interactive. All rights reserved.
-- Copyright (c) 2024 Metatable Games. All rights reserved.
-- Written by vq9o <business@vq9o.com>

type PlayerUserId = number

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

	JoinParty: (self: MatchmakingService, playerId: PlayerUserId, code: string) -> (boolean, string?),
	LeaveParty: (self: MatchmakingService, playerId: PlayerUserId, code: string) -> boolean,
	StartGame: (self: MatchmakingService, code: string) -> boolean,
	MatchPlayers: (self: MatchmakingService, players: { PlayerUserId }) -> (),
	SaveParty: (self: MatchmakingService, code: string, data: PartyData) -> (boolean, string?),
	GetParty: (self: MatchmakingService, code: string) -> PartyData?,
	DeleteParty: (self: MatchmakingService, code: string) -> (boolean, string?),
	BroadcastLobbyUpdate: (self: MatchmakingService, action: string, data: PartyData) -> (),
	SubscribeToLobbyUpdates: (self: MatchmakingService) -> (),
	FetchPublicParties: (self: MatchmakingService) -> (),
	GetPublicParties: (self: MatchmakingService) -> { [string]: PartyData },
	IsPartyReservedServer: (self: MatchmakingService) -> boolean,
	GetPartyDataForReservedServer: (self: MatchmakingService) -> PartyData?,
}

return {}