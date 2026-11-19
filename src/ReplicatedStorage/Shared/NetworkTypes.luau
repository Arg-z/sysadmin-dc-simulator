--!strict
--[[
	NetworkTypes (ModuleScript, ReplicatedStorage/Shared)
	Definisi type ketat untuk seluruh simulasi. Type-only module (return nil).
]]

export type PortType = "WAN" | "RJ45" | "SFP" | "Console"
export type CableColorType = "LAN_Blue" | "WAN_Yellow" | "Mgmt_Red"
export type VMStatus = "running" | "throttled" | "stopped"
export type DeviceType = "Router" | "Switch" | "BareMetal" | "ColocationServer"
export type TicketCategory = "CloudVPS" | "Colocation" | "CustomBuild" | "Incident"
export type TicketStatus = "Available" | "Active" | "Completed" | "Failed"
export type TerminalMode = "Disconnected" | "LocalConsole" | "RemoteSSH"
export type IncidentType = "CableFault" | "DDoSFlood" | "NoisyNeighbor" | "DriveFailure"

export type PortData = {
	portId: string,
	portType: PortType,
	connectedToDeviceId: string?,
	connectedToPortId: string?,
	cableColor: CableColorType?,
	linkUp: boolean,
	vlanId: number,
	isTrunk: boolean?,
	trafficLoadMbps: number,
}

export type VMData = {
	name: string,
	cpu: number,
	ram: number,
	disk: number,
	assignedIp: string?,
	cpuThrottlePercent: number,
	currentLoadPercent: number,
	status: VMStatus,
	noisy: boolean?,
}

export type DeviceSpecs = {
	cpu: number,
	ram: number,
	disk: number,
	powerWatts: number,
}

export type DeviceNode = {
	id: string,
	name: string,
	deviceType: DeviceType,
	itemId: string,
	rackId: string?,
	uSlot: number?,
	uSize: number,
	ip: string?,
	gateway: string?,
	subnetMask: string,
	defaultVlan: number,
	interVlanRouting: boolean?,
	contractId: string?,
	ports: { [string]: PortData },
	specs: DeviceSpecs,
	vms: { [string]: VMData },
	blockedIps: { [string]: boolean },
	osInstalled: string?,
	isPowered: boolean,
	temperatureC: number,
	loadPercent: number,
	hasDegradedDrive: boolean,
	degradedBayIndex: number?,
	isUnderDDoS: boolean,
	ddosAttackerIp: string?,
	freeform: boolean,
	posX: number?,
	posZ: number?,
	rotY: number?,
}

export type RackData = {
	rackId: string,
	name: string,
	itemId: string,
	maxU: number,
	occupiedSlots: { [number]: string },
	totalPowerWatts: number,
	maxPowerWatts: number,
	pduPowered: boolean,
}

export type ContractTicket = {
	id: string,
	category: TicketCategory,
	clientName: string,
	title: string,
	description: string,
	requirements: { [string]: any },
	rewardPayout: number,
	payoutIntervalSec: number?,
	slaRemainingSec: number?,
	runtimeRemainingSec: number?,
	vlanId: number?,
	targetIp: string?,
	phase: string?,
	validationText: string?,
	targetDeviceId: string?,
	targetRackId: string?,
	targetUSlot: number?,
	status: TicketStatus,
	incidentType: string?,
	incidentData: { [string]: any }?,
}

export type TerminalSession = {
	mode: TerminalMode,
	targetDeviceId: string?,
	sshStack: { any },
}

export type ActiveCable = {
	cableId: string,
	aDeviceId: string,
	aPortId: string,
	bDeviceId: string,
	bPortId: string,
	color: CableColorType,
	beam: Beam,
	sheath: Beam?,
}

export type ConsoleLink = {
	deviceId: string,
	beam: Beam,
}

export type WorkbenchState = {
	chassis: string?,
	mobo: string?,
	cpuCount: number,
	cpuSockets: number,
	cpuCores: number,
	ramSlotsUsed: number,
	ramSlots: number,
	ramGb: number,
	storageBaysUsed: number,
	storageBays: number,
	storageGb: number,
	psu: string?,
	powered: boolean,
	osInstalled: string?,
	installing: boolean,
	stressRunning: boolean,
	tested: boolean,
	shipped: boolean,
	deviceId: string?,
	totalSpent: number,
	snapIndex: number?,
	benchModel: any?,
	lastCpuId: string?,
	lastRamId: string?,
}

export type DeviceSnapshot = {
	id: string,
	name: string,
	deviceType: DeviceType,
	ip: string?,
	isPowered: boolean,
	temperatureC: number,
	loadPercent: number,
	vmCount: number,
	peers: { string },
}

export type FacilitySnapshot = {
	plotIndex: number,
	balance: number,
	reputation: number,
	uptimePercent: number,
	powerWatts: number,
	avgTempC: number,
	storm: boolean,
	day: number,
	clockText: string,
	shiftPhase: string,
	incidentCount: number,
	lastSettlement: string?,
	settlementAmount: number?,
	devices: { DeviceSnapshot },
	vms: { { name: string, hostId: string, cpu: number, ram: number, disk: number, ip: string?, status: VMStatus, loadPercent: number } },
	objectives: { [string]: boolean },
	tickets: { { id: string, category: string, title: string, description: string, rewardPayout: number, status: string, requirementsText: string, slaRemainingSec: number?, payoutIntervalSec: number?, validationText: string?, vlanId: number?, incidentType: string? } },
}

export type Session = {
	player: Player,
	plotIndex: number,
	balance: number,
	reputation: number,
	day: number,
	terminal: TerminalSession,
	devices: { [string]: DeviceNode },
	deviceModels: { [string]: Model },
	racks: { [string]: RackData },
	rackModels: { [string]: Model },
	cables: { [string]: ActiveCable },
	pendingCableDeviceId: string?,
	pendingCablePortId: string?,
	pendingCableHighlight: SelectionBox?,
	consoleLink: ConsoleLink?,
	pendingPlacementItemId: string?,
	workbench: WorkbenchState,
	facility: { [string]: any },
	flags: { [string]: boolean },
	hookedDevices: { [string]: boolean },
	vmIpCounter: { [string]: number },
	cableCounter: number,
	deviceCounter: number,
	broadcastStorm: boolean,
	loadedFromSave: boolean,
	noSaveWarned: boolean,
	tickets: { any },
	cableSpools: { [string]: number },
	selectedCableColor: CableColorType,
	carry: any?,
	colocation: { [string]: any },
	rackSlots: { [string]: any },
	shift: {
		clockMinutes: number,
		stats: { contractsCompleted: number, incidentsResolved: number, incidentsFailed: number },
		lastSettlementText: string?,
		lastSettlementAmount: number?,
	},
	incidentFaults: { [string]: boolean },
	incidentCooldownSec: number,
	incidentRotationIndex: number,
	spareParts: { [string]: number },
	stormLit: boolean,
}

return nil
