# InverseVolumetricAudio
Like Volumetric-Audio, but inverse!

### Usage
```lua
local InverseVolumetricAudio = require(game.ReplicatedStorage.InverseVolumetricAudio)

local sound = script:WaitForChild("Blizzard_inside_House")

local shedGroup = {
	shapeParts = {workspace:WaitForChild("Shed").PartA},
	windowParts = workspace:WaitForChild("Shed").Windows:GetChildren()
}

local inverseAudio = InverseVolumetricAudio.new({shedGroup}, sound, {
	FadeMode = InverseVolumetricAudio.FadeMode.Inside,
	MinVolume = 0.2,
	MaxVolume = 1.25,
	FalloffDistance = 14,
})
```
