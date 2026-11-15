--[[
  ABOVE [ARCANE] — Autohit hub
  Auto Farm (nodes) · Auto Fight (enemies) · Auto Bow · Magic Aim · Speed · Jump · Fly
  Every feature has a rebindable key. Click a key button, then press the new key.
  Esc cancels a rebind, Backspace clears it. Binds and sliders persist to AboveHub.json.
  Unload: getgenv().AboveAutohit.Unload()
]]

local VERSION = "3.0"

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local Http       = game:GetService("HttpService")

local env = getgenv and getgenv() or _G
if env.AboveAutohit and env.AboveAutohit.Unload then pcall(env.AboveAutohit.Unload) end

local lp = Players.LocalPlayer

--------------------------------------------------------------------
-- Remotes / game modules
--------------------------------------------------------------------
local Remotes       = RS:WaitForChild("Remotes")
local RequestSwing  = Remotes:WaitForChild("RequestSwing")
local RequestEquip  = Remotes:WaitForChild("RequestEquipSlot")
local RequestShoot  = Remotes:FindFirstChild("RequestShoot")
local RequestSprint = Remotes:FindFirstChild("RequestSprint")

local BAL, WCFG
pcall(function() BAL  = require(RS.Shared.Ballistics) end)
pcall(function() WCFG = require(RS.Shared.Config.WeaponConfig) end)

--------------------------------------------------------------------
-- State + persisted config
--------------------------------------------------------------------
local CONFIG_FILE = "AboveHub.json"

local State = {
	Farm = false, Fight = false, Bow = false, Magic = true, Blink = false,
	Speed = false, Jump = false, Fly = false,
}

local Values = {
	Speed    = 32,    -- WalkSpeed
	Jump     = 75,    -- JumpPower
	FlySpeed = 60,    -- studs/s
	Draw     = 12,    -- bow draw %, 12 = max fire rate, 100 = max damage
	Reach    = 12,    -- melee reach in studs
	BlinkRange = 150, -- how far Blink Shot will hop for a target
}

local Binds = {
	Menu = "RightShift", Farm = "H", Fight = "J", Bow = "B", Magic = "N", Blink = "V",
	Speed = "U", Jump = "K", Fly = "F",
}

local SWING_INTERVAL = 0.32 -- client cadence ~0.30s, server tolerance 0.15s
local PICK_TARGETS = { Stone = true, Coal = true, IronOre = true, Clay = true, Sand = true, GoldOre = true }
local AXE_TARGETS  = { Tree = true, Pine = true }

local function saveConfig()
	if not writefile then return end
	pcall(function()
		writefile(CONFIG_FILE, Http:JSONEncode({ Binds = Binds, Values = Values }))
	end)
end

local function loadConfig()
	if not (readfile and isfile) then return end
	pcall(function()
		if not isfile(CONFIG_FILE) then return end
		local data = Http:JSONDecode(readfile(CONFIG_FILE))
		for k, v in pairs(data.Binds or {}) do if Binds[k] ~= nil then Binds[k] = v end end
		for k, v in pairs(data.Values or {}) do if type(v) == "number" and Values[k] then Values[k] = v end end
	end)
end
loadConfig()

local conns = {}
local alive = true
local function track(c) conns[#conns + 1] = c; return c end

--------------------------------------------------------------------
-- Character helpers
--------------------------------------------------------------------
local function getChar() return lp.Character end
local function getHRP() local c = getChar(); return c and c:FindFirstChild("HumanoidRootPart") end
local function getHum() local c = getChar(); return c and c:FindFirstChildOfClass("Humanoid") end

--------------------------------------------------------------------
-- Targets (cached scan)
--------------------------------------------------------------------
local function hitPart(inst)
	if inst:IsA("BasePart") then return inst end
	local hb = inst:FindFirstChild("HB")
	if hb and hb:IsA("BasePart") then return hb end
	if inst:IsA("Model") and inst.PrimaryPart then return inst.PrimaryPart end
	return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function targetAlive(inst)
	if not inst.Parent then return false end
	local hum = inst:FindFirstChildOfClass("Humanoid")
	return not (hum and hum.Health <= 0)
end

local nodes, enemies, lastScan = {}, {}, 0
local function rescan()
	local n, e = {}, {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Model") and d:GetAttribute("NodeType") then
			n[#n + 1] = d
		elseif d:GetAttribute("EnemyId") and (d:IsA("BasePart") or d:IsA("Model"))
			and not Players:GetPlayerFromCharacter(d) then
			e[#e + 1] = d
		end
	end
	nodes, enemies, lastScan = n, e, os.clock()
end

local function nearestIn(list, origin, range)
	local best, bestPart, bestD = nil, nil, range
	for _, inst in ipairs(list) do
		if targetAlive(inst) then
			local p = hitPart(inst)
			if p then
				local d = (p.Position - origin).Magnitude
				if d <= bestD then best, bestPart, bestD = inst, p, d end
			end
		end
	end
	return best, bestPart
end

--------------------------------------------------------------------
-- Equip (cached, re-asserted on every rescan)
--------------------------------------------------------------------
local equipped
local function equip(slot)
	if slot and slot ~= equipped then
		RequestEquip:FireServer(slot)
		equipped = slot
	end
end

local function slotForNode(model)
	local nt = model:GetAttribute("NodeType") or model.Name
	return (PICK_TARGETS[nt] and "Pickaxe") or (AXE_TARGETS[nt] and "Axe")
end

--------------------------------------------------------------------
-- Bow
--------------------------------------------------------------------
local projCache = {}
local function heldProjectile()
	if not WCFG then return end
	local c = getChar()
	local ht = c and c:FindFirstChild("HeldTool")
	local id = ht and ht:GetAttribute("ItemId")
	local w = id and WCFG.Weapons and WCFG.Weapons[id]
	if not (w and w.ranged) then return end
	if projCache[id] == nil then
		local ok, cfg = pcall(WCFG.projectileOf, id)
		projCache[id] = (ok and type(cfg) == "table") and cfg or false
	end
	return projCache[id] or nil
end

local function aimAt(origin, target, proj, draw)
	local rel = target - origin
	if BAL and WCFG then
		local okS, speed = pcall(WCFG.launchSpeed, proj, draw)
		if okS and type(speed) == "number" and speed > 0 then
			local okD, dir = pcall(BAL.aimDirection, rel, speed, proj.gravity or 0)
			if okD and typeof(dir) == "Vector3" and dir.Magnitude > 0 then return dir.Unit end
		end
	end
	if rel.Magnitude < 1e-3 then return end
	return rel.Unit
end

local SHOT_SLACK = ((WCFG and WCFG.ShotOriginSlackStuds) or 12) - 0.5

local function shotOrigin(hrp)
	local c = getChar()
	local ht = c and c:FindFirstChild("HeldTool")
	local att = ht and ht:FindFirstChild((WCFG and WCFG.ShotOriginAttachment) or "ShotOrigin", true)
	if att and att:IsA("Attachment") then return att.WorldPosition end
	return hrp.Position
end

-- nearest enemy the arrow can actually reach: a blocked line just buries the arrow in a ledge
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
local function nearestVisibleEnemy(origin, range)
	local c = getChar()
	losParams.FilterDescendantsInstances = c and { c } or {}
	local best, bestD = nil, range
	for _, inst in ipairs(enemies) do
		if targetAlive(inst) then
			local p = hitPart(inst)
			if p then
				local rel = p.Position - origin
				local d = rel.Magnitude
				if d < bestD then
					local hit = workspace:Raycast(origin, rel, losParams)
					if not hit or hit.Instance == p or hit.Instance:IsDescendantOf(inst) then
						best, bestD = p, d
					end
				end
			end
		end
	end
	return best
end

local bowBusy = false -- true while the bow has a target, so melee does not steal the equip
local function setAim(on)
	if RequestSprint then pcall(function() RequestSprint:FireServer(on, "Aim") end) end
end

local bowRunning = false
local function bowLoop()
	if bowRunning then return end
	bowRunning = true
	setAim(true)
	local shotId = math.random(1e5, 1e6)
	while alive and State.Bow do
		local hrp = getHRP()
		local draw = math.clamp(Values.Draw / 100, 0.12, 1)
		local target
		if hrp and State.Magic then
			if State.Blink then
				-- blink ignores walls: we fire from right above the target
				local _, part = nearestIn(enemies, hrp.Position, Values.BlinkRange)
				target = part
			else
				target = nearestVisibleEnemy(shotOrigin(hrp), 300)
			end
		end
		bowBusy = target ~= nil
		if hrp and (target or not State.Magic) then
			-- only re-equip when the bow isn't already out: re-equipping restarts the draw timer
			if not heldProjectile() then
				equipped = nil
				equip("Weapon")
				task.wait(0.4)
			end
			local proj = heldProjectile()
			if proj then
				-- Blink: hop next to the target so the server sees us there, shoot, hop back
				local home
				if target and State.Blink then
					home = hrp.CFrame
					hrp.CFrame = CFrame.new(target.Position + Vector3.new(0, 6, 6), target.Position)
					for _ = 1, 3 do RunService.Heartbeat:Wait() end
					task.wait(0.12) -- let the position replicate before the shot arrives
				end
				local origin = shotOrigin(hrp)
				local aimPos
				if target then
					-- server accepts a launch point up to ShotOriginSlackStuds (12) from the bow:
					-- spawn the arrow as close to the target as that allows
					local rel = target.Position - origin
					local push = math.min(rel.Magnitude - 1.5, SHOT_SLACK)
					if push > 0 then origin += rel.Unit * push end
					aimPos = target.Position
				end
				local dir = aimPos and aimAt(origin, aimPos, proj, draw)
					or (workspace.CurrentCamera and workspace.CurrentCamera.CFrame.LookVector)
				if dir then
					shotId += 1
					RequestShoot:FireServer(origin, dir, draw, shotId)
				end
				if home then
					task.wait(0.15)
					local r = getHRP()
					if r then r.CFrame = home; r.AssemblyLinearVelocity = Vector3.zero end
				end
				-- server gates on cooldown AND draw time; firing faster is discarded
				local wait = math.max(proj.cooldownSeconds or 0.25, draw * (proj.drawSeconds or 1)) + 0.03
				task.wait(wait)
			else
				task.wait(0.3)
			end
		else
			task.wait(0.2)
		end
	end
	bowBusy = false
	setAim(false)
	bowRunning = false
end

--------------------------------------------------------------------
-- Melee scheduler: Fight (enemies) has priority over Farm (nodes)
--------------------------------------------------------------------
local lastSwing = 0
track(RunService.Heartbeat:Connect(function()
	if not alive then return end
	if os.clock() - lastScan > 1.5 then
		rescan()
		equipped = nil
	end
	if not (State.Farm or State.Fight) then return end
	if os.clock() - lastSwing < SWING_INTERVAL then return end
	local hrp = getHRP()
	if not hrp then return end

	if State.Fight and not State.Bow then
		local _, part = nearestIn(enemies, hrp.Position, Values.Reach)
		if part then
			lastSwing = os.clock()
			equip("Weapon")
			RequestSwing:FireServer(part)
			return
		end
	end
	if State.Farm and not bowBusy then
		local model, part = nearestIn(nodes, hrp.Position, Values.Reach)
		if part then
			lastSwing = os.clock()
			equip(slotForNode(model))
			RequestSwing:FireServer(part)
		end
	end
end))

--------------------------------------------------------------------
-- Speed / Jump — polled, so the game's sprint script can't storm a listener
--------------------------------------------------------------------
local DEFAULT_SPEED, DEFAULT_JUMP = 16, 50

task.spawn(function()
	while alive do
		local hum = getHum()
		if hum then
			if State.Speed and hum.WalkSpeed ~= Values.Speed then hum.WalkSpeed = Values.Speed end
			if State.Jump and hum.JumpPower ~= Values.Jump then
				pcall(function() hum.UseJumpPower = true; hum.JumpPower = Values.Jump end)
			end
		end
		task.wait(0.15)
	end
end)

local function resetSpeed() local h = getHum(); if h then h.WalkSpeed = DEFAULT_SPEED end end
local function resetJump() local h = getHum(); if h then pcall(function() h.JumpPower = DEFAULT_JUMP end) end end

--------------------------------------------------------------------
-- Fly — LinearVelocity + AlignOrientation on the root, camera-relative
--------------------------------------------------------------------
local flyParts
local function stopFly()
	if flyParts then
		for _, p in ipairs(flyParts) do pcall(function() p:Destroy() end) end
		flyParts = nil
	end
	local hum = getHum()
	if hum then hum.PlatformStand = false; hum:ChangeState(Enum.HumanoidStateType.Freefall) end
end

local function startFly()
	stopFly()
	local hrp, hum = getHRP(), getHum()
	if not (hrp and hum) then return end
	local att = Instance.new("Attachment"); att.Name = "AHFlyAtt"; att.Parent = hrp
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = Vector3.zero
	lv.Parent = hrp
	local ao = Instance.new("AlignOrientation")
	ao.Attachment0 = att
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.MaxTorque = math.huge
	ao.Responsiveness = 50
	ao.Parent = hrp
	hum.PlatformStand = true
	flyParts = { lv, ao, att }
end

track(RunService.RenderStepped:Connect(function()
	if not (State.Fly and flyParts) then return end
	local hum, cam = getHum(), workspace.CurrentCamera
	if not (hum and cam) then return end
	local lv, ao = flyParts[1], flyParts[2]
	local move = hum.MoveDirection -- already camera-relative on the XZ plane
	local look = cam.CFrame.LookVector
	-- tilt horizontal input along the camera pitch so W flies where you look
	local dir = Vector3.zero
	if move.Magnitude > 0 then
		local flatLook = Vector3.new(look.X, 0, look.Z)
		local forward = flatLook.Magnitude > 0 and move:Dot(flatLook.Unit) or 0
		dir = move + Vector3.new(0, look.Y * forward, 0)
	end
	if UIS:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
	if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
	lv.VectorVelocity = dir.Magnitude > 0 and dir.Unit * Values.FlySpeed or Vector3.zero
	ao.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(look.X, 0, look.Z).Magnitude > 0 and Vector3.new(look.X, 0, look.Z) or Vector3.zAxis)
end))

--------------------------------------------------------------------
-- Respawn handling
--------------------------------------------------------------------
track(lp.CharacterAdded:Connect(function(char)
	char:WaitForChild("HumanoidRootPart", 10)
	task.wait(0.5)
	equipped = nil
	flyParts = nil
	if State.Fly then startFly() end
	if State.Bow then setAim(true) end
end))

--------------------------------------------------------------------
-- Feature table (drives UI + keybinds)
--------------------------------------------------------------------
local Features -- forward

local function setFeature(name, on)
	State[name] = on
	if name == "Bow" then
		if on then task.spawn(bowLoop) end
	elseif name == "Speed" then
		if not on then resetSpeed() end
	elseif name == "Jump" then
		if not on then resetJump() end
	elseif name == "Fly" then
		if on then startFly() else stopFly() end
	end
	if Features and Features[name] and Features[name].refresh then Features[name].refresh() end
end

--------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------
local guiParent = (gethui and gethui()) or lp:WaitForChild("PlayerGui")
for _, g in ipairs(guiParent:GetChildren()) do if g.Name == "AboveAutohitGui" then g:Destroy() end end

local C = {
	bg = Color3.fromRGB(18, 18, 22), panel = Color3.fromRGB(28, 28, 34),
	text = Color3.fromRGB(220, 220, 225), dim = Color3.fromRGB(130, 130, 140),
	on = Color3.fromRGB(70, 200, 120), off = Color3.fromRGB(60, 60, 68),
	accent = Color3.fromRGB(110, 150, 255),
}

local function corner(p, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 6); c.Parent = p end

local gui = Instance.new("ScreenGui")
gui.Name = "AboveAutohitGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999
gui.Parent = guiParent

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(260, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.new(0, 20, 0.5, -200)
frame.BackgroundColor3 = C.bg
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui
corner(frame, 8)

local pad = Instance.new("UIPadding")
pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 10)
pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
pad.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 5)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = frame

local order = 0
local function nextOrder() order += 1; return order end

-- title bar doubles as drag handle
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 24)
title.BackgroundTransparency = 1
title.Text = "ABOVE Autohit  v" .. VERSION
title.TextColor3 = C.accent
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.LayoutOrder = nextOrder()
title.Active = true
title.Parent = frame

do
	local dragging, dragStart, startPos
	track(title.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, i.Position, frame.Position
		end
	end))
	track(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	track(UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))
end

local function section(text)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, 16)
	l.BackgroundTransparency = 1
	l.Text = text:upper()
	l.TextColor3 = C.dim
	l.Font = Enum.Font.GothamBold
	l.TextSize = 11
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.LayoutOrder = nextOrder()
	l.Parent = frame
end

-- rebind capture
local listeningFor -- feature name currently waiting for a key
local bindButtons = {}

local function bindText(name)
	local k = Binds[name]
	return (k and k ~= "") and k or "—"
end

local function refreshBinds()
	for name, b in pairs(bindButtons) do
		b.Text = listeningFor == name and "..." or bindText(name)
	end
end

local function makeBindButton(parent, name)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(70, 22)
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, 0, 0.5, 0)
	b.BackgroundColor3 = C.off
	b.TextColor3 = C.text
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 12
	b.AutoButtonColor = true
	b.Parent = parent
	corner(b, 5)
	bindButtons[name] = b
	track(b.MouseButton1Click:Connect(function()
		listeningFor = (listeningFor == name) and nil or name
		refreshBinds()
	end))
	return b
end

Features = {}
local function featureRow(name, label)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 26)
	row.BackgroundColor3 = C.panel
	row.BorderSizePixel = 0
	row.LayoutOrder = nextOrder()
	row.Parent = frame
	corner(row, 6)

	local toggle = Instance.new("TextButton")
	toggle.Size = UDim2.new(1, -78, 1, 0)
	toggle.BackgroundTransparency = 1
	toggle.TextXAlignment = Enum.TextXAlignment.Left
	toggle.Font = Enum.Font.GothamMedium
	toggle.TextSize = 13
	toggle.Parent = row
	local tp = Instance.new("UIPadding"); tp.PaddingLeft = UDim.new(0, 26); tp.Parent = toggle

	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(12, 12)
	dot.Position = UDim2.new(0, 8, 0.5, -6)
	dot.BorderSizePixel = 0
	dot.Parent = row
	corner(dot, 6)

	makeBindButton(row, name)

	local f = {}
	function f.refresh()
		local on = State[name]
		dot.BackgroundColor3 = on and C.on or C.off
		toggle.Text = label
		toggle.TextColor3 = on and C.text or C.dim
	end
	track(toggle.MouseButton1Click:Connect(function() setFeature(name, not State[name]) end))
	f.refresh()
	Features[name] = f
end

local function slider(label, key, minV, maxV, suffix)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.new(1, 0, 0, 30)
	holder.BackgroundTransparency = 1
	holder.LayoutOrder = nextOrder()
	holder.Parent = frame

	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, 14)
	l.BackgroundTransparency = 1
	l.TextColor3 = C.dim
	l.Font = Enum.Font.Gotham
	l.TextSize = 12
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = holder

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, 0, 0, 8)
	bar.Position = UDim2.fromOffset(0, 18)
	bar.BackgroundColor3 = C.off
	bar.BorderSizePixel = 0
	bar.Active = true
	bar.Parent = holder
	corner(bar, 4)

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = C.accent
	fill.BorderSizePixel = 0
	fill.Parent = bar
	corner(fill, 4)

	local function render()
		local v = Values[key]
		fill.Size = UDim2.new((v - minV) / (maxV - minV), 0, 1, 0)
		l.Text = string.format("%s: %d%s", label, v, suffix or "")
	end
	local function setFromX(x)
		local pct = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
		Values[key] = math.floor(minV + (maxV - minV) * pct + 0.5)
		render()
	end

	local dragging = false
	track(bar.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true; setFromX(i.Position.X)
		end
	end))
	track(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			setFromX(i.Position.X)
		end
	end))
	track(UIS.InputEnded:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
			dragging = false; saveConfig()
		end
	end))
	Values[key] = math.clamp(Values[key], minV, maxV)
	render()
end

section("Combat / Gather")
featureRow("Farm",  "Auto Farm")
featureRow("Fight", "Auto Fight")
slider("Reach", "Reach", 4, 20, " studs")
featureRow("Bow",   "Auto Bow")
featureRow("Magic", "Magic Aim")
featureRow("Blink", "Blink Shot")
slider("Blink range", "BlinkRange", 20, 300, " studs")
slider("Bow draw (low = fast, high = damage)", "Draw", 12, 100, "%")

section("Movement")
featureRow("Speed", "Speed")
slider("WalkSpeed", "Speed", 16, 150)
featureRow("Jump",  "Jump")
slider("JumpPower", "Jump", 50, 300)
featureRow("Fly",   "Fly  (Space / Ctrl)")
slider("Fly speed", "FlySpeed", 10, 250)

section("Menu")
do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 26)
	row.BackgroundColor3 = C.panel
	row.BorderSizePixel = 0
	row.LayoutOrder = nextOrder()
	row.Parent = frame
	corner(row, 6)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -78, 1, 0)
	l.Position = UDim2.fromOffset(10, 0)
	l.BackgroundTransparency = 1
	l.Text = "Show / hide menu"
	l.TextColor3 = C.text
	l.Font = Enum.Font.GothamMedium
	l.TextSize = 13
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = row
	makeBindButton(row, "Menu")
end

refreshBinds()

--------------------------------------------------------------------
-- Keyboard: rebind capture first, then feature binds
--------------------------------------------------------------------
track(UIS.InputBegan:Connect(function(input, gpe)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local key = input.KeyCode.Name

	if listeningFor then
		if input.KeyCode == Enum.KeyCode.Escape then
			-- cancel
		elseif input.KeyCode == Enum.KeyCode.Backspace then
			Binds[listeningFor] = ""
		else
			-- one key per action: steal it from whoever had it
			for k, v in pairs(Binds) do if v == key then Binds[k] = "" end end
			Binds[listeningFor] = key
		end
		listeningFor = nil
		refreshBinds()
		saveConfig()
		return
	end

	if gpe then return end
	for name, bound in pairs(Binds) do
		if bound ~= "" and bound == key then
			if name == "Menu" then
				frame.Visible = not frame.Visible
			else
				setFeature(name, not State[name])
			end
			return
		end
	end
end))

--------------------------------------------------------------------
-- Unload
--------------------------------------------------------------------
env.AboveAutohit = {
	State = State, Values = Values, Binds = Binds, Set = setFeature,
	Unload = function()
		alive = false
		State.Bow = false
		setAim(false)
		if State.Fly then stopFly() end
		if State.Speed then resetSpeed() end
		if State.Jump then resetJump() end
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		pcall(function() gui:Destroy() end)
		env.AboveAutohit = nil
	end,
}

rescan()
print(("[Autohit v%s] loaded — %s toggles the menu"):format(VERSION, bindText("Menu")))
