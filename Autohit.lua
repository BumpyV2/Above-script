-- Auto Hit — Farm / Fight / Speed / Jump / Bow
local VERSION = "2.7"

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
local CS           = game:GetService("CollectionService")
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
local RequestShoot  = Remotes:FindFirstChild("RequestShoot")
local RequestSprint = Remotes:FindFirstChild("RequestSprint")
if not (RequestEquip and RequestSwing) then
	warn("[AutoHit] Required remotes missing — aborting")
	return
end

-- The game's own ballistics solver + weapon table. Using them means the arc
-- we send the server is the exact arc the server expects for that draw.
local Shared       = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
local Ballistics   = Shared and Shared:FindFirstChild("Ballistics")
local WeaponCfgMod = Shared and Shared:FindFirstChild("Config") and Shared.Config:FindFirstChild("WeaponConfig")
local okB, BAL = pcall(function() return require(Ballistics) end)
local okW, WCFG = pcall(function() return require(WeaponCfgMod) end)
if not okB then BAL = nil end
if not okW then WCFG = nil end

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
local jumpOn    = false
local bowOn     = false
local magicOn   = true
local speedVal  = 32
local jumpVal   = 50
local bowDelay  = 0.25 -- seconds between shots
local drawFrac  = 1.00 -- 0.12 .. 1.00
local origSpeed = 16
local origJump  = 50
local teleporting = false -- pause loops during zone transitions

local SCAN_RANGE   = 12
local LOOP_DELAY   = 0.55
local FARM_LOOPS   = 3

local MIN_SPEED, MAX_SPEED = 16, 100
local MIN_JUMP,  MAX_JUMP  = 50, 300
local MIN_RATE,  MAX_RATE  = 50, 1000 -- ms between shots
local MIN_DRAW,  MAX_DRAW  = 12, 100  -- percent of a full draw

local PICK_TARGETS = {Stone=1, Coal=1, IronOre=1, Clay=1, Sand=1, GoldOre=1}
local AXE_TARGETS  = {Tree=1, Pine=1}

-- Debug trail — survives a crash if the executor has writefile.
local LOG_ENABLED = true
local logBuf, swings, shots = {}, 0, 0
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

local function getHRP()
	local c = plr.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local c = plr.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

task.spawn(function()
	while _G._autoHitAlive do
		task.wait(5)
		local h = getHumanoid()
		dlog(string.format("stat swings/5s=%d shots/5s=%d farm=%s fight=%s speed=%s jump=%s bow=%s magic=%s ws=%s jp=%s",
			swings, shots, tostring(farmOn), tostring(fightOn), tostring(speedOn), tostring(jumpOn),
			tostring(bowOn), tostring(magicOn),
			tostring(h and h.WalkSpeed or "nil"), tostring(h and h.JumpPower or "nil")))
		swings, shots = 0, 0
	end
end)

--------------------------------------------------------------------
-- Speed / Jump enforcement by POLLING, not by listening.
-- Reacting to property changes fought the game's own sprint script: each
-- listener re-triggered the other, which storms the client. Polling cannot.
--------------------------------------------------------------------
local speedLoopRunning = false
local function startSpeedEnforcer()
	if speedLoopRunning then return end
	speedLoopRunning = true
	task.spawn(function()
		dlog("speed enforcer start")
		while _G._autoHitAlive and speedOn do
			local hum = getHumanoid()
			if hum and hum.WalkSpeed ~= speedVal then
				hum.WalkSpeed = speedVal
			end
			task.wait(0.15)
		end
		speedLoopRunning = false
		dlog("speed enforcer stop")
	end)
end

-- Newer rigs default to JumpHeight; force the JumpPower model so one
-- number controls it, and pcall in case the property is locked.
local function setJump(hum, v)
	if not hum then return end
	pcall(function()
		hum.UseJumpPower = true
		hum.JumpPower = v
	end)
end

local jumpLoopRunning = false
local function startJumpEnforcer()
	if jumpLoopRunning then return end
	jumpLoopRunning = true
	task.spawn(function()
		dlog("jump enforcer start")
		while _G._autoHitAlive and jumpOn do
			local hum = getHumanoid()
			if hum and hum.JumpPower ~= jumpVal then
				setJump(hum, jumpVal)
			end
			task.wait(0.15)
		end
		jumpLoopRunning = false
		dlog("jump enforcer stop")
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
	if hum and jumpOn then
		setJump(hum, jumpVal)
		startJumpEnforcer()
	end
end))

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

--------------------------------------------------------------------
-- Ranged targeting
--------------------------------------------------------------------
-- What the bow is actually holding right now. HeldTool carries an ItemId
-- attribute; WeaponConfig maps that to the projectile the server expects.
local projCache = {}
local function heldProjectile()
	if not WCFG then return nil, nil end
	local char = plr.Character
	local ht = char and char:FindFirstChild("HeldTool")
	local id = ht and ht:GetAttribute("ItemId")
	if not id then return nil, nil end
	local w = WCFG.Weapons and WCFG.Weapons[id]
	if not (w and w.ranged) then return nil, id end
	local cached = projCache[id]
	if cached == nil then
		local ok, cfg = pcall(WCFG.projectileOf, id)
		cached = (ok and type(cfg) == "table") and cfg or false
		projCache[id] = cached
	end
	if not cached then return nil, id end
	return cached, id
end

local function nearestEnemyPoint(origin, range)
	local best, bestD = nil, range
	local seen = {}
	local function consider(model)
		if not model or seen[model] then return end
		seen[model] = true
		local hb = model:FindFirstChild("HB")
		local part = (hb and hb:IsA("BasePart") and hb)
			or model:FindFirstChild("HumanoidRootPart")
			or (model:IsA("Model") and model.PrimaryPart)
		if not (part and part:IsA("BasePart")) then return end
		local hum = model:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health <= 0 then return end
		local d = (part.Position - origin).Magnitude
		if d < bestD then best, bestD = part.Position, d end
	end
	for _, m in CS:GetTagged("Enemy") do consider(m) end
	for _, folder in getMobFolders() do
		for _, m in folder:GetChildren() do consider(m) end
	end
	return best
end

-- Solve the launch direction that actually lands on the target, using the
-- game's own solver so the arc matches what the server simulates.
local function solveDirection(origin, target, proj)
	local rel = target - origin
	if BAL and BAL.aimDirection and WCFG and WCFG.launchSpeed then
		local okS, speed = pcall(WCFG.launchSpeed, proj, drawFrac)
		if okS and type(speed) == "number" and speed > 0 then
			local okD, dir = pcall(BAL.aimDirection, rel, speed, proj.gravity or 0)
			if okD and typeof(dir) == "Vector3" and dir.Magnitude > 0 then
				return dir.Unit
			end
		end
	end
	-- Fallback: straight line with a little loft so gravity does not eat it.
	if rel.Magnitude < 0.001 then return nil end
	if (proj.gravity or 0) > 0 then
		local flat = Vector3.new(rel.X, 0, rel.Z)
		if flat.Magnitude > 0.001 then
			return (flat.Unit + Vector3.new(0, 0.15, 0)).Unit
		end
	end
	return rel.Unit
end

--------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "AutoHitGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = plr.PlayerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 220, 0, 300)
frame.Position = UDim2.new(0, 20, 0.5, -150)
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

-- One factory for every slider, so adding another is three lines.
local function makeSlider(parent, yOff, minV, maxV, initV, color, onChange)
	local bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, -66, 0, 8)
	bg.Position = UDim2.new(0, 28, 0, yOff)
	bg.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
	bg.BorderSizePixel = 0
	bg.Parent = parent
	local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(1, 0); bc.Parent = bg

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = bg
	local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = fill

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0, 40, 0, 16)
	lbl.Position = UDim2.new(1, -46, 0, yOff - 4)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = color
	lbl.TextSize = 13
	lbl.Font = Enum.Font.GothamBold
	lbl.TextXAlignment = Enum.TextXAlignment.Right
	lbl.Parent = parent

	local dragging = false

	local function apply(pct)
		pct = math.clamp(pct, 0, 1)
		local v = math.floor(minV + (maxV - minV) * pct + 0.5)
		fill.Size = UDim2.new(pct, 0, 1, 0)
		lbl.Text = tostring(v)
		onChange(v)
	end

	apply((initV - minV) / (maxV - minV))

	track(bg.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			apply((input.Position.X - bg.AbsolutePosition.X) / bg.AbsoluteSize.X)
		end
	end))
	track(UIS.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			apply((input.Position.X - bg.AbsolutePosition.X) / bg.AbsoluteSize.X)
		end
	end))
	track(UIS.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

local farmDot,  farmLbl  = makeToggleRow(frame, 10,  "Auto Farm",  "H")
local fightDot, fightLbl = makeToggleRow(frame, 40,  "Auto Fight", "J")
local speedDot, speedLbl = makeToggleRow(frame, 70,  "Speed",      "U")

makeSlider(frame, 104, MIN_SPEED, MAX_SPEED, speedVal, Color3.fromRGB(0, 170, 255), function(v)
	speedVal = v
	if speedOn then
		local hum = getHumanoid()
		if hum then hum.WalkSpeed = speedVal end
	end
end)

local jumpDot, jumpLbl = makeToggleRow(frame, 126, "Jump", "K")

makeSlider(frame, 160, MIN_JUMP, MAX_JUMP, jumpVal, Color3.fromRGB(190, 120, 255), function(v)
	jumpVal = v
	if jumpOn then setJump(getHumanoid(), jumpVal) end
end)

local bowDot,   bowLbl   = makeToggleRow(frame, 182, "Auto Bow",  "B")

makeSlider(frame, 216, MIN_RATE, MAX_RATE, math.floor(bowDelay * 1000 + 0.5), Color3.fromRGB(255, 210, 90), function(v)
	bowDelay = v / 1000
end)

makeSlider(frame, 238, MIN_DRAW, MAX_DRAW, math.floor(drawFrac * 100 + 0.5), Color3.fromRGB(255, 150, 90), function(v)
	drawFrac = v / 100
end)

local magicDot, magicLbl = makeToggleRow(frame, 258, "Magic Aim", "N")

local function refreshDot(dot, lbl, on, color)
	dot.BackgroundColor3 = on and color or Color3.fromRGB(60, 60, 60)
	lbl.TextColor3 = on and color or Color3.fromRGB(180, 180, 180)
end

--------------------------------------------------------------------
-- Loops
--------------------------------------------------------------------
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

-- Bow — fires RequestShoot directly, so the arrow goes where we aim it
-- rather than where the camera points.
local shotId = 0
local function bowLoop()
	while _G._autoHitAlive and bowOn do
		task.wait() -- unconditional yield: no branch below can spin the thread
		if teleporting or not RequestShoot then
			task.wait(0.5)
			continue
		end
		local hrp = getHRP()
		local proj = heldProjectile()
		if not (hrp and proj) then
			task.wait(0.3)
			continue
		end
		local origin = hrp.Position
		local dir
		if magicOn then
			local target = nearestEnemyPoint(origin, math.min(proj.rangeStuds or 300, 300))
			if target then dir = solveDirection(origin, target, proj) end
		end
		if not dir then
			local cam = workspace.CurrentCamera
			dir = cam and cam.CFrame.LookVector
		end
		if dir then
			shotId += 1
			RequestShoot:FireServer(origin, dir.Unit, drawFrac, shotId)
			shots += 1
		end
		task.wait(bowDelay)
	end
end

--------------------------------------------------------------------
-- Apply
--------------------------------------------------------------------
local function applySpeed(on)
	local hum = getHumanoid()
	if not hum then return end
	if on then
		origSpeed = 16; hum.WalkSpeed = speedVal; startSpeedEnforcer()
	else
		hum.WalkSpeed = origSpeed
	end
end

-- The server starts the draw timer from the aim signal, so hold it open
-- for as long as the bow is on.
local function applyBow(on)
	if RequestSprint then
		pcall(function() RequestSprint:FireServer(on, "Aim") end)
	end
	if on then task.spawn(bowLoop) end
end

local function applyJump(on)
	local hum = getHumanoid()
	if not hum then return end
	if on then
		setJump(hum, jumpVal); startJumpEnforcer()
	else
		setJump(hum, origJump)
	end
end

--------------------------------------------------------------------
-- Keybinds
--------------------------------------------------------------------
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
	elseif input.KeyCode == Enum.KeyCode.K then
		jumpOn = not jumpOn; refreshDot(jumpDot, jumpLbl, jumpOn, Color3.fromRGB(190,120,255))
		dlog("jump -> "..tostring(jumpOn).." @"..tostring(jumpVal)); applyJump(jumpOn)
	elseif input.KeyCode == Enum.KeyCode.B then
		bowOn = not bowOn; refreshDot(bowDot, bowLbl, bowOn, Color3.fromRGB(255,210,90))
		dlog("bow -> "..tostring(bowOn).." delay="..tostring(bowDelay).." draw="..tostring(drawFrac))
		applyBow(bowOn)
	elseif input.KeyCode == Enum.KeyCode.N then
		magicOn = not magicOn; refreshDot(magicDot, magicLbl, magicOn, Color3.fromRGB(255,120,200))
		dlog("magic -> "..tostring(magicOn))
	end
end))

refreshDot(magicDot, magicLbl, magicOn, Color3.fromRGB(255,120,200))

dlog("loaded shoot="..tostring(RequestShoot ~= nil).." bal="..tostring(BAL ~= nil).." wcfg="..tostring(WCFG ~= nil))
print(("[AutoHit v%s] Loaded — H=Farm  J=Fight  U=Speed  K=Jump  B=Bow  N=MagicAim"):format(VERSION))
