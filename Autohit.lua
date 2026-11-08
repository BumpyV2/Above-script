-- Auto Hit — Farm / Fight / Speed
-- Loader:  loadstring(game:HttpGet("<RAW_URL>?v="..tick()))()
local VERSION = "2.5"

--------------------------------------------------------------------
-- Teardown any previous copy (connections, loops, GUI)
--------------------------------------------------------------------
pcall(function()
	_G._autoHitAlive = false
	if _G._autoHitConns then
		for _, c in _G._autoHitConns do
			pcall(function() c:Disconnect() end)
		end
	end
	if _G._autoHitKey then pcall(function() _G._autoHitKey:Disconnect() end) end
	_G._autoHitKey = nil
end)
task.wait(0.7)

local Players      = game:GetService("Players")
local UIS          = game:GetService("UserInputService")
local plr          = Players.LocalPlayer

pcall(function()
	for _, g in plr.PlayerGui:GetChildren() do
		if g.Name == "AutoHitGui" then g:Destroy() end
	end
end)

--------------------------------------------------------------------
-- Remotes (wait, in case the loader runs before replication finishes)
--------------------------------------------------------------------
local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes", 15)
if not Remotes then
	warn("[AutoHit] Remotes folder not found — aborting")
	return
end
local RequestEquip = Remotes:WaitForChild("RequestEquipSlot", 10)
local RequestSwing = Remotes:WaitForChild("RequestSwing", 10)
if not (RequestEquip and RequestSwing) then
	warn("[AutoHit] Required remotes missing — aborting")
	return
end

_G._autoHitAlive = true
_G._autoHitConns = {}

-- track every connection so the next load can clean up after this one
local function track(conn)
	table.insert(_G._autoHitConns, conn)
	return conn
end

local farmOn    = false
local fightOn   = false
local speedOn   = false
local speedVal  = 32
local origSpeed = 16
local teleporting = false -- pause loops during zone transitions

local SCAN_RANGE   = 12
local LOOP_DELAY   = 0.55
local FARM_LOOPS   = 3 -- reduced from 6 to prevent crash

local PICK_TARGETS = {Stone=1, Coal=1, IronOre=1, Clay=1, Sand=1, GoldOre=1}
local AXE_TARGETS  = {Tree=1, Pine=1}

-- Debug trail — survives a crash if the executor has writefile.
local LOG_ENABLED = true
local logBuf, swings = {}, 0
local function dlog(msg)
	if not LOG_ENABLED then return end
	logBuf[#logBuf + 1] = string.format("[%7.1f] %s", os.clock(), msg)
	if #logBuf > 600 then table.remove(logBuf, 1) end
end

task.spawn(function()
	while _G._autoHitAlive do
		task.wait(2)
		if LOG_ENABLED and #logBuf > 0 then
			pcall(function() writefile("AutoHit_debug.txt", table.concat(logBuf, "\n")) end)
		end
	end
end)

task.spawn(function()
	while _G._autoHitAlive do
		task.wait(5)
		local c = plr.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		dlog(string.format("stat swings/5s=%d farm=%s fight=%s speed=%s ws=%s",
			swings, tostring(farmOn), tostring(fightOn), tostring(speedOn),
			tostring(h and h.WalkSpeed or "nil")))
		swings = 0
	end
end)

-- Speed enforcement by POLLING, not by listening.
-- Reacting to WalkSpeed changes fought the game's own sprint script: each
-- listener re-triggered the other, which storms the client. Polling cannot.
local speedLoopRunning = false
local function startSpeedEnforcer()
	if speedLoopRunning then return end
	speedLoopRunning = true
	task.spawn(function()
		dlog("speed enforcer start")
		while _G._autoHitAlive and speedOn do
			local c = plr.Character
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			if hum and hum.WalkSpeed ~= speedVal then
				hum.WalkSpeed = speedVal
			end
			task.wait(0.15)
		end
		speedLoopRunning = false
		dlog("speed enforcer stop")
	end)
end

-- Detect teleport/respawn — pause all loops
track(plr.CharacterRemoving:Connect(function()
	teleporting = true
	dlog("character removing, paused")
end))

track(plr.CharacterAdded:Connect(function(char)
	char:WaitForChild("HumanoidRootPart", 10)
	task.wait(1) -- let zone load
	teleporting = false

	dlog("character added, resumed")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and speedOn then
		hum.WalkSpeed = speedVal
		startSpeedEnforcer()
	end
end))

local function getHRP()
	local c = plr.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local c = plr.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local ZONE_NAMES = {"Hub", "Ruins"}

local function getZones()
	local zones = {}
	for _, n in ZONE_NAMES do
		local z = workspace:FindFirstChild(n)
		if z then table.insert(zones, z) end
	end
	return zones
end

local function getResourceFolders()
	local folders = {}
	for _, zone in getZones() do
		local rf = zone:FindFirstChild("ResourceField")
		if rf then table.insert(folders, rf) end
	end
	return folders
end

local function getMobFolders()
	local folders = {}
	for _, zone in getZones() do
		local g = zone:FindFirstChild("Guardians")
		if g then table.insert(folders, g) end
	end
	local ev = workspace:FindFirstChild("EnemyViews")
	if ev then table.insert(folders, ev) end
	return folders
end

local function nearestHB(folders)
	local hrp = getHRP()
	if not hrp then return nil, nil end
	-- Sentinel is SCAN_RANGE, not SCAN_RANGE+1: anything selected here must also
	-- satisfy isAlive() below, or the caller spins without ever yielding.
	local best, bestDist, bestModel = nil, SCAN_RANGE, nil
	for _, folder in folders do
		if folder and folder:IsA("Instance") then
			for _, m in folder:GetChildren() do
				local hb = m:FindFirstChild("HB")
				if hb and hb:IsA("BasePart") then
					local d = (hb.Position - hrp.Position).Magnitude
					if d < bestDist then
						best, bestDist, bestModel = hb, d, m
					end
				end
			end
		end
	end
	return best, bestModel
end

local function isAlive(hb)
	if not hb or not hb.Parent then return false end
	local hrp = getHRP()
	if not hrp then return false end
	return (hb.Position - hrp.Position).Magnitude <= SCAN_RANGE
end

-- GUI
local gui = Instance.new("ScreenGui")
gui.Name = "AutoHitGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = plr.PlayerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 220, 0, 140)
frame.Position = UDim2.new(0, 20, 0.5, -70)
frame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
frame.BackgroundTransparency = 0.15
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = frame

local function makeToggleRow(parent, yOff, label, key)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -16, 0, 26)
	row.Position = UDim2.new(0, 8, 0, yOff)
	row.BackgroundTransparency = 1
	row.Parent = parent
	local dot = Instance.new("Frame")
	dot.Size = UDim2.new(0, 12, 0, 12)
	dot.Position = UDim2.new(0, 0, 0.5, -6)
	dot.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	dot.BorderSizePixel = 0
	dot.Parent = row
	local dc = Instance.new("UICorner"); dc.CornerRadius = UDim.new(1, 0); dc.Parent = dot
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -20, 1, 0)
	lbl.Position = UDim2.new(0, 20, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = label.."  ["..key.."]"
	lbl.TextColor3 = Color3.fromRGB(180, 180, 180)
	lbl.TextSize = 14
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Parent = row
	return dot, lbl
end

local farmDot, farmLbl   = makeToggleRow(frame, 10, "Auto Farm", "H")
local fightDot, fightLbl = makeToggleRow(frame, 40, "Auto Fight", "J")
local speedDot, speedLbl = makeToggleRow(frame, 70, "Speed", "U")

local sliderBg = Instance.new("Frame")
sliderBg.Size = UDim2.new(1, -50, 0, 8)
sliderBg.Position = UDim2.new(0, 28, 0, 105)
sliderBg.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
sliderBg.BorderSizePixel = 0
sliderBg.Parent = frame
local sc = Instance.new("UICorner"); sc.CornerRadius = UDim.new(1, 0); sc.Parent = sliderBg

local sliderFill = Instance.new("Frame")
sliderFill.Size = UDim2.new(0.2, 0, 1, 0)
sliderFill.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
sliderFill.BorderSizePixel = 0
sliderFill.Parent = sliderBg
local sf = Instance.new("UICorner"); sf.CornerRadius = UDim.new(1, 0); sf.Parent = sliderFill

local sliderValLbl = Instance.new("TextLabel")
sliderValLbl.Size = UDim2.new(0, 36, 0, 16)
sliderValLbl.Position = UDim2.new(1, -36, 0, 101)
sliderValLbl.BackgroundTransparency = 1
sliderValLbl.Text = tostring(speedVal)
sliderValLbl.TextColor3 = Color3.fromRGB(0, 170, 255)
sliderValLbl.TextSize = 13
sliderValLbl.Font = Enum.Font.GothamBold
sliderValLbl.TextXAlignment = Enum.TextXAlignment.Right
sliderValLbl.Parent = frame

local MIN_SPEED, MAX_SPEED = 16, 100
local draggingSlider = false

local function updateSlider(pct)
	pct = math.clamp(pct, 0, 1)
	speedVal = math.floor(MIN_SPEED + (MAX_SPEED - MIN_SPEED) * pct + 0.5)
	sliderFill.Size = UDim2.new(pct, 0, 1, 0)
	sliderValLbl.Text = tostring(speedVal)
	if speedOn then
		local hum = getHumanoid()
		if hum then hum.WalkSpeed = speedVal end
	end
end
updateSlider((speedVal - MIN_SPEED) / (MAX_SPEED - MIN_SPEED))

track(sliderBg.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = true
		updateSlider((input.Position.X - sliderBg.AbsolutePosition.X) / sliderBg.AbsoluteSize.X)
	end
end))
track(UIS.InputChanged:Connect(function(input)
	if draggingSlider and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		updateSlider((input.Position.X - sliderBg.AbsolutePosition.X) / sliderBg.AbsoluteSize.X)
	end
end))
track(UIS.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = false
	end
end))

local function refreshDot(dot, lbl, on, color)
	dot.BackgroundColor3 = on and color or Color3.fromRGB(60, 60, 60)
	lbl.TextColor3 = on and color or Color3.fromRGB(180, 180, 180)
end

-- Farm — pauses during teleport
local function farmLoop()
	while _G._autoHitAlive and farmOn do
		task.wait() -- unconditional yield: no branch below can spin the thread
		if teleporting then
			task.wait(0.5)
			continue
		end
		local folders = getResourceFolders()
		if #folders > 0 then
			local hb, model = nearestHB(folders)
			if hb then
				if not isAlive(hb) then
					dlog("WARN target selected but not alive: "..tostring(model and model.Name))
					task.wait(0.2)
					continue
				end
				local name = model.Name
				if PICK_TARGETS[name] then RequestEquip:FireServer("Pickaxe")
				elseif AXE_TARGETS[name] then RequestEquip:FireServer("Axe") end
				while _G._autoHitAlive and farmOn and not teleporting and isAlive(hb) do
					RequestSwing:FireServer(hb); swings += 1; task.wait(LOOP_DELAY)
				end
			else task.wait(0.2) end
		else task.wait(1) end
	end
end

local function startFarm()
	for i = 1, FARM_LOOPS do
		task.delay((i - 1) * (LOOP_DELAY / FARM_LOOPS), function() farmLoop() end)
	end
end

-- Fight — pauses during teleport
local function fightLoop()
	while _G._autoHitAlive and fightOn do
		task.wait() -- unconditional yield: no branch below can spin the thread
		if teleporting then
			task.wait(0.5)
			continue
		end
		local folders = getMobFolders()
		local hb = nearestHB(folders)
		if hb then
			RequestEquip:FireServer("Weapon")
			while _G._autoHitAlive and fightOn and not teleporting and isAlive(hb) do
				RequestSwing:FireServer(hb); swings += 1; task.wait(LOOP_DELAY)
			end
		else task.wait(0.2) end
	end
end

-- Speed
local function applySpeed(on)
	local hum = getHumanoid()
	if not hum then return end
	if on then
		origSpeed = 16; hum.WalkSpeed = speedVal; startSpeedEnforcer()
	else
		hum.WalkSpeed = origSpeed
	end
end

-- Keybinds
_G._autoHitKey = track(UIS.InputBegan:Connect(function(input, gpe)
	if gpe or not _G._autoHitAlive then return end
	if input.KeyCode == Enum.KeyCode.H then
		farmOn = not farmOn; refreshDot(farmDot, farmLbl, farmOn, Color3.fromRGB(0,200,80))
		dlog("farm -> "..tostring(farmOn)); if farmOn then startFarm() end
	elseif input.KeyCode == Enum.KeyCode.J then
		fightOn = not fightOn; refreshDot(fightDot, fightLbl, fightOn, Color3.fromRGB(255,160,0))
		dlog("fight -> "..tostring(fightOn)); if fightOn then task.spawn(fightLoop) end
	elseif input.KeyCode == Enum.KeyCode.U then
		speedOn = not speedOn; refreshDot(speedDot, speedLbl, speedOn, Color3.fromRGB(0,170,255))
		dlog("speed -> "..tostring(speedOn).." @"..tostring(speedVal)); applySpeed(speedOn)
	end
end))

dlog("loaded")
print(("[AutoHit v%s] Loaded — H=Farm  J=Fight  U=Speed"):format(VERSION))
