# InverseVolumetricAudio
Like Volumetric-Audio, but inverse!

Easily add outside ambient audio to your game that dims when you are inside. Sound volumes can be configured with windows to clamp the audios position too!

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
