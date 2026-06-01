-- InverseVolumetricAudio.lua

--[[
	Designed by Andrew Hamilton (orange451).
	Vibe Coded with Grok.
]]

local RunService = game:GetService("RunService")

-- =============================================
-- Fade Mode Enum
-- =============================================
local FadeMode = {
	Outside = "Outside",
	Inside = "Inside",
}

export type FadeMode = "Outside" | "Inside"

-- Configuration defaults
local DEFAULT_MIN_VOLUME = 0.08
local DEFAULT_MAX_VOLUME = 1.0
local DEFAULT_FALLOFF_DISTANCE = 60
local DEFAULT_FADE_MODE: FadeMode = FadeMode.Outside

-- Smoothing
local SMOOTHING_FACTOR = 0.82

-- Main module
local InverseVolumetricAudio = {}
InverseVolumetricAudio.__index = InverseVolumetricAudio
InverseVolumetricAudio.FadeMode = FadeMode

export type InverseVolumetricAudio = {
	ShapeGroups: {{BasePart}},
	Sound: Sound,
	FadeMode: FadeMode,
	MinVolume: number,
	MaxVolume: number,
	FalloffDistance: number,

	-- Internal
	_emitters: {{
		shapeParts: {BasePart},
		windowParts: {BasePart},
		attachment: Attachment,
		sound: Sound,
		_smoothedVolume: number,
	}},
	_connection: RBXScriptConnection?,
}

-- Reliable inside check
local function isPointInsidePart(point: Vector3, part: BasePart): boolean
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local hs = part.Size / 2

	if part.Shape == Enum.PartType.Block then
		return math.abs(localPoint.X) <= hs.X + 0.01
			and math.abs(localPoint.Y) <= hs.Y + 0.01
			and math.abs(localPoint.Z) <= hs.Z + 0.01
	elseif part.Shape == Enum.PartType.Ball then
		return localPoint.Magnitude <= hs.X + 0.01
	elseif part.Shape == Enum.PartType.Cylinder then
		local xz = Vector2.new(localPoint.X, localPoint.Z)
		return xz.Magnitude <= hs.X + 0.01 and math.abs(localPoint.Y) <= hs.Y + 0.01
	end

	-- Fallback
	return math.abs(localPoint.X) <= hs.X + 0.01
		and math.abs(localPoint.Y) <= hs.Y + 0.01
		and math.abs(localPoint.Z) <= hs.Z + 0.01
end

-- Correct closest surface point
local function getClosestSurfacePoint(listenerPos: Vector3, part: BasePart): Vector3
	local cframe = part.CFrame
	local localPos = cframe:PointToObjectSpace(listenerPos)
	local hs = part.Size / 2

	local surfaceLocal: Vector3

	if part.Shape == Enum.PartType.Block then
		local dx = math.abs(localPos.X) - hs.X
		local dy = math.abs(localPos.Y) - hs.Y
		local dz = math.abs(localPos.Z) - hs.Z

		if dx > 0 or dy > 0 or dz > 0 then
			surfaceLocal = Vector3.new(
				math.clamp(localPos.X, -hs.X, hs.X),
				math.clamp(localPos.Y, -hs.Y, hs.Y),
				math.clamp(localPos.Z, -hs.Z, hs.Z)
			)
		else
			local distX = hs.X - math.abs(localPos.X)
			local distY = hs.Y - math.abs(localPos.Y)
			local distZ = hs.Z - math.abs(localPos.Z)
			local minDist = math.min(distX, distY, distZ)

			if minDist == distX then
				surfaceLocal = Vector3.new(localPos.X > 0 and hs.X or -hs.X, localPos.Y, localPos.Z)
			elseif minDist == distY then
				surfaceLocal = Vector3.new(localPos.X, localPos.Y > 0 and hs.Y or -hs.Y, localPos.Z)
			else
				surfaceLocal = Vector3.new(localPos.X, localPos.Y, localPos.Z > 0 and hs.Z or -hs.Z)
			end
		end

	elseif part.Shape == Enum.PartType.Ball then
		local radius = hs.X
		local dir = localPos.Unit
		if dir.Magnitude == 0 then dir = Vector3.new(1, 0, 0) end
		surfaceLocal = dir * radius

	elseif part.Shape == Enum.PartType.Cylinder then
		local radius = hs.X
		local halfH = hs.Y
		local xz = Vector2.new(localPos.X, localPos.Z)
		local xzLen = xz.Magnitude

		local surfaceXZ = if xzLen > 0 then xz.Unit * radius else Vector2.new(radius, 0)
		local surfaceY = math.clamp(localPos.Y, -halfH, halfH)

		if xzLen < radius and math.abs(localPos.Y) < halfH then
			local toSide = radius - xzLen
			local toCap = halfH - math.abs(localPos.Y)
			if toSide < toCap then
				surfaceLocal = Vector3.new(surfaceXZ.X, localPos.Y, surfaceXZ.Y)
			else
				surfaceLocal = Vector3.new(localPos.X, localPos.Y > 0 and halfH or -halfH, localPos.Z)
			end
		else
			surfaceLocal = Vector3.new(surfaceXZ.X, surfaceY, surfaceXZ.Y)
		end
	else
		surfaceLocal = Vector3.new(
			math.clamp(localPos.X, -hs.X, hs.X),
			math.clamp(localPos.Y, -hs.Y, hs.Y),
			math.clamp(localPos.Z, -hs.Z, hs.Z)
		)
	end

	return cframe:PointToWorldSpace(surfaceLocal)
end

function InverseVolumetricAudio.new(
	shapeGroups: {{               -- { shapeParts: {BasePart}, windowParts: {BasePart}? }
		shapeParts: {BasePart},
		windowParts: {BasePart}?
	}},
	sound: Sound,
	config: {
		FadeMode: FadeMode?,
		MinVolume: number?,
		MaxVolume: number?,
		FalloffDistance: number?
	}?
): InverseVolumetricAudio

	assert(#shapeGroups > 0, "At least one shape group is required")
	assert(sound, "Sound instance is required")

	local self = setmetatable({}, InverseVolumetricAudio)

	self.ShapeGroups = {}
	self._emitters = {}

	for _, def in shapeGroups do
		local shapeParts = def.shapeParts or {}
		local windowParts = def.windowParts or {}

		local clonedShape = table.clone(shapeParts)
		local clonedWindows = table.clone(windowParts)

		local attachment = Instance.new("Attachment")
		attachment.Name = "InverseVolumetricEmitter"
		attachment.Parent = workspace.Terrain

		local clonedSound = sound:Clone()
		clonedSound.Parent = attachment
		clonedSound.RollOffMode = Enum.RollOffMode.Inverse
		clonedSound.RollOffMinDistance = 1024
		clonedSound.RollOffMaxDistance = 1024--(config and config.FalloffDistance or DEFAULT_FALLOFF_DISTANCE) * 2.5
		clonedSound.Volume = 0
		clonedSound.Looped = true
		clonedSound.Playing = true

		table.insert(self._emitters, {
			shapeParts = clonedShape,
			windowParts = clonedWindows,
			attachment = attachment,
			sound = clonedSound,
			_smoothedVolume = 0,
		})
	end

	self.Sound = sound
	self.FadeMode = config and config.FadeMode or DEFAULT_FADE_MODE
	self.MinVolume = config and config.MinVolume or DEFAULT_MIN_VOLUME
	self.MaxVolume = config and config.MaxVolume or DEFAULT_MAX_VOLUME
	self.FalloffDistance = config and config.FalloffDistance or DEFAULT_FALLOFF_DISTANCE

	self:Start()
	return self
end

function InverseVolumetricAudio:Start()
	if self._connection then return end
	self._connection = RunService.RenderStepped:Connect(function()
		self:_update()
	end)
end

function InverseVolumetricAudio:Stop()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

function InverseVolumetricAudio:Destroy()
	self:Stop()
	for _, e in self._emitters do
		e.sound:Destroy()
		e.attachment:Destroy()
	end
	self._emitters = {}
end

function InverseVolumetricAudio:_update()
	local listenerPos = workspace.CurrentCamera.CFrame.Position

	-- Step 1: Detect if we are inside ANY shape group
	local insideAnyShape = false
	for _, emitter in self._emitters do
		for _, part in emitter.shapeParts do
			if part and part.Parent and isPointInsidePart(listenerPos, part) then
				insideAnyShape = true
				break
			end
		end
		if insideAnyShape then break end
	end

	-- Step 2: When outside everything, find the loudest group (prevents stacking)
	local bestVolume = 0
	local bestEmitterIndex = 1

	if not insideAnyShape then
		for i, emitter in self._emitters do
			local rawMinDist = math.huge
			for _, part in emitter.shapeParts do
				if not part or not part.Parent then continue end
				local surface = getClosestSurfacePoint(listenerPos, part)
				local dist = (listenerPos - surface).Magnitude
				if dist < rawMinDist then
					rawMinDist = dist
				end
			end

			local groupVolume: number
			if self.FadeMode == FadeMode.Outside then
				groupVolume = self.MinVolume + (self.MaxVolume - self.MinVolume) * math.clamp(rawMinDist / self.FalloffDistance, 0, 1)
			else
				groupVolume = self.MaxVolume
			end

			if groupVolume > bestVolume then
				bestVolume = groupVolume
				bestEmitterIndex = i
			end
		end
	end

	-- Step 3: Update every emitter
	for i, emitter in self._emitters do
		local isInsideThisGroup = false
		local rawMinDistToShape = math.huge
		local closestShapeSurface = listenerPos

		for _, part in emitter.shapeParts do
			if not part or not part.Parent then continue end

			if isPointInsidePart(listenerPos, part) then
				isInsideThisGroup = true
			end

			local surface = getClosestSurfacePoint(listenerPos, part)
			local dist = (listenerPos - surface).Magnitude
			if dist < rawMinDistToShape then
				rawMinDistToShape = dist
				closestShapeSurface = surface
			end
		end

		-- Determine emitter position (window logic)
		local emitterPos = listenerPos
		if isInsideThisGroup then
			if #emitter.windowParts > 0 then
				local winDist = math.huge
				for _, winPart in emitter.windowParts do
					if not winPart or not winPart.Parent then continue end
					local winSurface = getClosestSurfacePoint(listenerPos, winPart)
					local d = (listenerPos - winSurface).Magnitude
					if d < winDist then
						winDist = d
						emitterPos = winSurface
					end
				end
			else
				emitterPos = closestShapeSurface
			end
		end

		-- Volume logic
		local targetVolume: number

		if insideAnyShape then
			-- Inside any shape
			if isInsideThisGroup then
				-- The group we are inside uses normal fade based on distance to attachment
				local distToAttachment = (listenerPos - emitterPos).Magnitude
				local normalized = math.clamp(distToAttachment / self.FalloffDistance, 0, 1)
				targetVolume = self.MaxVolume - (self.MaxVolume - self.MinVolume) * normalized
			else
				-- All other groups are completely silent
				targetVolume = 0
			end
		else
			-- Outside all shapes → only the best (loudest) emitter plays
			targetVolume = (i == bestEmitterIndex) and bestVolume or 0
		end

		-- Per-emitter smoothing
		emitter._smoothedVolume = emitter._smoothedVolume * SMOOTHING_FACTOR + targetVolume * (1 - SMOOTHING_FACTOR)

		emitter.sound.Volume = emitter._smoothedVolume
		emitter.attachment.WorldPosition = emitterPos
	end
end

return InverseVolumetricAudio
