--[[
  ABOVE [ARCANE] — Autohit hub
  Auto Farm (nodes, optional travel) · Auto Fight (enemies) · Auto Bow · Magic Aim · Speed · Jump · Fly
  Every feature has a rebindable key. Click a key button, then press the new key.
  Esc cancels a rebind, Backspace clears it. Binds and sliders persist to AboveHub.json.
  Unload: getgenv().AboveAutohit.Unload()
]]

local VERSION = "3.2"

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

local EquippedChanged = Remotes:FindFirstChild("EquippedChanged")
local HitConfirmed    = Remotes:FindFirstChild("HitConfirmed")

local BAL, WCFG, TCFG, ECFG
pcall(function() ECFG = require(RS.Shared.Config.EnemyConfig) end)
pcall(function() BAL  = require(RS.Shared.Ballistics) end)
pcall(function() WCFG = require(RS.Shared.Config.WeaponConfig) end)
pcall(function() TCFG = require(RS.Shared.Config.ToolConfig) end)

--------------------------------------------------------------------
-- State + persisted config
--------------------------------------------------------------------
local CONFIG_FILE = "AboveHub.json"

local State = {
	Farm = false, Travel = false, Fight = false, Bow = false, Magic = true, Blink = false,
	Speed = false, Jump = false, Fly = false, FlyNoclip = true,
}

local Values = {
	Speed    = 32,    -- WalkSpeed
	Jump     = 75,    -- JumpPower
	FlySpeed = 60,    -- studs/s
	Draw     = 12,    -- bow draw %, 12 = max fire rate, 100 = max damage
	Reach    = 12,    -- melee reach in studs
	BlinkRange = 150, -- how far Blink Shot will hop for a target
	BlinkDepth = 8,   -- studs under the slime to shoot from (0 = beside it, visible)
	SwingEarly = 10,  -- hundredths of a second to swing before the tool's cooldown (server slack 0.15)
	TravelSpeed = 40, -- studs/s for Farm Travel (40 tested clean)
	TravelRange = 400,-- how far Farm Travel will go for a node
	BowRange = 300,   -- Auto Bow target range without Blink
	BowLead = 100,    -- % of measured target velocity to lead by (0 = aim at body)
}

local Binds = {
	Menu = "RightShift", Farm = "H", Travel = "G", Fight = "J", Bow = "B", Magic = "N", Blink = "V",
	Speed = "U", Jump = "K", Fly = "F", FlyNoclip = "",
}

-- Which enemy kinds Auto Bow shoots (EnemyId -> bool). Filled from EnemyConfig later.
local ShootTypes = {
	GreenSlime = true, BlueSlime = true, PinkSlime = true, OrangeSlime = true, KingSlime = true,
	Skeleton = true, SkeletonArcher = true, SkeletonKnight = true, Morten = true,
}
local BOSS_IDS = { Morten = true, KingSlime = true }

-- Which node types Farm will hit / travel to. Filled from ToolConfig.Nodes below.
local FarmTypes = {}

-- Node rules come from the game's ToolConfig; these are the fallback if it fails to load.
local NODE_RULES = {
	Stone = { requires = "Pickaxe" }, Coal = { requires = "Pickaxe" }, IronOre = { requires = "Pickaxe" },
	Clay = { requires = "Pickaxe", minTier = "Stone" }, Sand = { requires = "Pickaxe", minTier = "Stone" },
	GoldOre = { requires = "Pickaxe", minTier = "Iron" },
	Tree = { requires = "Axe" }, Pine = { requires = "Axe", minTier = "Iron" },
}
if TCFG and type(TCFG.Nodes) == "table" then NODE_RULES = TCFG.Nodes end
for nt in pairs(NODE_RULES) do FarmTypes[nt] = true end

local function saveConfig()
	if not writefile then return end
	pcall(function()
		writefile(CONFIG_FILE, Http:JSONEncode({ Binds = Binds, Values = Values, FarmTypes = FarmTypes, ShootTypes = ShootTypes }))
	end)
end

local function loadConfig()
	if not (readfile and isfile) then return end
	pcall(function()
		if not isfile(CONFIG_FILE) then return end
		local data = Http:JSONDecode(readfile(CONFIG_FILE))
		for k, v in pairs(data.Binds or {}) do if Binds[k] ~= nil then Binds[k] = v end end
		for k, v in pairs(data.Values or {}) do if type(v) == "number" and Values[k] then Values[k] = v end end
		for k, v in pairs(data.FarmTypes or {}) do if FarmTypes[k] ~= nil and type(v) == "boolean" then FarmTypes[k] = v end end
		for k, v in pairs(data.ShootTypes or {}) do if type(v) == "boolean" then ShootTypes[k] = v end end
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
	if hum and hum.Health <= 0 then return false end
	-- Empty guardian spawn slots keep their EnemyId but the slime art is fully transparent.
	-- Those were the "teleports to nothing".
	if inst:GetAttribute("EnemyId") then
		local art = inst:FindFirstChildWhichIsA("Model")
		if art then
			for _, p in ipairs(art:GetDescendants()) do
				if p:IsA("BasePart") and p.Transparency < 1 then return true end
			end
			return false
		end
	end
	return true
end

-- Event-driven index: a full workspace:GetDescendants() every 1.5s was the biggest
-- per-frame cost in v3.0. Now nodes/enemies are tracked as they stream in and out,
-- with a slow full rescan as a safety net.
local nodeSet, enemySet = {}, {}
local nodes, enemies = {}, {}
local listDirty = true
local lastScan = 0
local FULL_RESCAN = 15

local function classify(d)
	if d:IsA("Model") and d:GetAttribute("NodeType") then
		if not nodeSet[d] then nodeSet[d] = true; listDirty = true end
	elseif (d:IsA("BasePart") or d:IsA("Model")) and d:GetAttribute("EnemyId")
		and not Players:GetPlayerFromCharacter(d) then
		if not enemySet[d] then enemySet[d] = true; listDirty = true end
	end
end

local function unclassify(d)
	if nodeSet[d] then nodeSet[d] = nil; listDirty = true end
	if enemySet[d] then enemySet[d] = nil; listDirty = true end
end

local function rebuildLists()
	if not listDirty then return end
	local n, e = {}, {}
	for d in pairs(nodeSet) do if d.Parent then n[#n + 1] = d else nodeSet[d] = nil end end
	for d in pairs(enemySet) do if d.Parent then e[#e + 1] = d else enemySet[d] = nil end end
	nodes, enemies, listDirty = n, e, false
end

local function rescan()
	table.clear(nodeSet); table.clear(enemySet)
	for _, d in ipairs(workspace:GetDescendants()) do classify(d) end
	listDirty = true
	rebuildLists()
	lastScan = os.clock()
end

track(workspace.DescendantAdded:Connect(function(d)
	-- attributes are set right after the instance replicates; check on the next frame too
	classify(d)
	if d:IsA("Model") then task.defer(function() if d.Parent then classify(d) end end) end
end))
track(workspace.DescendantRemoving:Connect(unclassify))

local function nearestIn(list, origin, range, accept)
	local best, bestPart, bestD = nil, nil, range
	for _, inst in ipairs(list) do
		if (not accept or accept(inst)) and targetAlive(inst) then
			local p = hitPart(inst)
			if p then
				local d = (p.Position - origin).Magnitude
				if d <= bestD then best, bestPart, bestD = inst, p, d end
			end
		end
	end
	return best, bestPart, bestD
end

--------------------------------------------------------------------
-- Equip + swing cooldown, both taken from the server's EquippedChanged
-- (slot, itemId, cooldownSeconds). Cooldown is rolled per item.
--------------------------------------------------------------------
local curSlot           -- what the server says is in hand
local slotItem = {}     -- slot -> itemId last seen in that slot
local slotCooldown = {} -- slot -> server swing cooldown
local DEFAULT_COOLDOWN = 0.65
local pendingEquip, pendingAt = nil, 0

if EquippedChanged then
	track(EquippedChanged.OnClientEvent:Connect(function(slot, itemId, cooldown)
		curSlot = slot
		if slot then
			if itemId then slotItem[slot] = itemId end
			if type(cooldown) == "number" and cooldown > 0 then slotCooldown[slot] = cooldown end
		end
		if pendingEquip == slot then pendingEquip = nil end
	end))
end

-- read what the game already has in hand at load time
pcall(function()
	local AC = require(lp.PlayerScripts.Client.Controllers.AnimationController)
	local ups = debug.getupvalues(AC.playSwing)
	local cd, slot = ups[3], ups[4]
	if type(slot) == "string" and type(cd) == "number" then curSlot = slot; slotCooldown[slot] = cd end
end)
pcall(function()
	local ht = lp.Character and lp.Character:FindFirstChild("HeldTool")
	local id = ht and ht:GetAttribute("ItemId")
	if id and curSlot then slotItem[curSlot] = id end
end)

local function equip(slot)
	if not slot or slot == curSlot then return true end
	-- one request in flight at a time; re-asking resets the swing timer server-side
	if pendingEquip == slot and os.clock() - pendingAt < 0.8 then return false end
	pendingEquip, pendingAt = slot, os.clock()
	RequestEquip:FireServer(slot)
	return false
end

local function swingInterval(slot)
	local cd = slotCooldown[slot] or DEFAULT_COOLDOWN
	return math.max(0.1, cd - Values.SwingEarly / 100)
end

local function slotForNode(model)
	local nt = model:GetAttribute("NodeType") or model.Name
	local rule = NODE_RULES[nt]
	return rule and rule.requires
end

-- false only when we KNOW the tool in that slot is below the node's minTier
local function tierOk(nt, slot)
	local rule = NODE_RULES[nt]
	if not (rule and rule.minTier and TCFG and TCFG.TierRank and TCFG.Tools) then return true end
	local item = slotItem[slot]
	local tool = item and TCFG.Tools[item]
	if not tool then return true end
	local have, need = TCFG.TierRank[tool.tier], TCFG.TierRank[rule.minTier]
	return not (have and need) or have >= need
end

-- nodes the server refused (tier, ownership, anything we don't model) get benched
local nodeBench = setmetatable({}, { __mode = "k" })
local nodeRefusals = setmetatable({}, { __mode = "k" })
if HitConfirmed then
	track(HitConfirmed.OnClientEvent:Connect(function(inst, result)
		if typeof(inst) ~= "Instance" or not nodeSet[inst] then return end
		if result == "Hit" or result == "Destroyed" then
			nodeRefusals[inst] = nil
		else
			local n = (nodeRefusals[inst] or 0) + 1
			nodeRefusals[inst] = n
			if n >= 3 then nodeBench[inst] = os.clock() + 20; nodeRefusals[inst] = nil end
		end
	end))
end

local function nodeEligible(model)
	local nt = model:GetAttribute("NodeType")
	if not (nt and FarmTypes[nt]) then return false end
	local b = nodeBench[model]
	if b and os.clock() < b then return false end
	local slot = slotForNode(model)
	return slot ~= nil and tierOk(nt, slot)
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

local BLINK_SIDE = 2.5 -- horizontal offset of the launch point from the slime
local BLINK_DWELL = 0.35 -- tested: 0.12s is too short at 40ms ping, 0.35s lands consistently

-- Some guardians take arrows without losing health. Track health per shot and
-- skip a target for a while once two clean hits did nothing.
local immuneUntil = setmetatable({}, { __mode = "k" })
local noDamage = setmetatable({}, { __mode = "k" })
local function healthOf(part)
	local bar = part:FindFirstChild("Health")
	bar = bar and bar:FindFirstChild("Bar")
	return bar and bar.Size.X.Scale
end
local function isImmune(part)
	local t = immuneUntil[part]
	return t and os.clock() < t
end

-- Which enemy kinds the bow shoots. Bosses are shot first whenever one is in range.
local isBossType = function(id) return id == "Morten" or id == "KingSlime" end
if ECFG and type(ECFG.Enemies) == "table" then
	for id, cfg in pairs(ECFG.Enemies) do
		if ShootTypes[id] == nil then ShootTypes[id] = true end
		if type(cfg) == "table" and (cfg.behavior == "Boss" or (cfg.scale or 1) >= 4) then BOSS_IDS[id] = true end
	end
	isBossType = function(id) return BOSS_IDS[id] == true end
end

local function enemyKind(inst)
	return inst and inst:GetAttribute("EnemyId")
end

-- the instance carrying EnemyId for a hit part (slimes keep it on the parent model)
local function enemyOf(part)
	local x = part
	while x and x ~= workspace do
		if x:GetAttribute("EnemyId") then return x end
		x = x.Parent
	end
	return part
end

local function shootable(inst)
	local id = enemyKind(inst)
	-- unknown ids (new mobs the config didn't list) are shot unless switched off
	return id ~= nil and ShootTypes[id] ~= false
end

-- Rigged enemies (skeletons, Morten) and bosses are never "immune": a health bar that
-- didn't move after a shot on those is a miss, not a dead spawn slot.
local function immunityApplies(inst)
	return not (inst:GetAttribute("Rigged") or inst:GetAttribute("Boss"))
end

-- nearest enemy the arrow can actually reach: a blocked line just buries the arrow in a ledge
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
local function losClear(origin, p, inst)
	local hit = workspace:Raycast(origin, p.Position - origin, losParams)
	if not hit then return true end
	local h = hit.Instance
	if h == p or h:IsDescendantOf(inst) then return true end
	-- the visible skeleton/boss rig lives under EnemyViews; hitting any enemy is fine
	local ev = workspace:FindFirstChild("EnemyViews")
	if ev and h:IsDescendantOf(ev) then return true end
	return enemySet[h] == true
end

local function pickBowTarget(origin, range, needLos)
	local c = getChar()
	losParams.FilterDescendantsInstances = c and { c } or {}
	local best, bestD, bestBoss = nil, range, false
	for _, inst in ipairs(enemies) do
		if shootable(inst) and targetAlive(inst) then
			local p = hitPart(inst)
			if p and not isImmune(p) then
				local d = (p.Position - origin).Magnitude
				local boss = isBossType(enemyKind(inst))
				-- a boss in range beats any mob; among equals, nearest wins
				local better = (boss and not bestBoss) or (boss == bestBoss and d < bestD)
				if d <= range and better and (not needLos or losClear(origin, p, inst)) then
					best, bestD, bestBoss = p, d, boss
				end
			end
		end
	end
	return best
end

local function nearestVisibleEnemy(origin, range)
	return pickBowTarget(origin, range, true)
end

-- Velocity of the current bow target, sampled every frame. Rigged enemies are moved by
-- CFrame server-side, so AssemblyLinearVelocity reads zero; measure it instead.
local velTarget, velLastPos, velLastT, velEst = nil, nil, 0, Vector3.zero
local function trackVelocity(part)
	if part ~= velTarget then
		velTarget, velLastPos, velLastT, velEst = part, part and part.Position, os.clock(), Vector3.zero
	end
end
track(RunService.Heartbeat:Connect(function()
	local p = velTarget
	if not (p and p.Parent) then return end
	local now = os.clock()
	local dt = now - velLastT
	if dt < 1 / 30 then return end
	local v = (p.Position - velLastPos) / dt
	if v.Magnitude > 60 then v = Vector3.zero end -- teleport / respawn, not movement
	velEst = velEst:Lerp(v, 0.35)
	velLastPos, velLastT = p.Position, now
end))

-- where to aim so a moving target walks into the arrow
local function leadPosition(origin, part, proj, draw)
	local pos = part.Position
	if part ~= velTarget or velEst.Magnitude < 0.5 or Values.BowLead <= 0 then return pos end
	local speed = 150
	if WCFG and proj then
		local ok, s = pcall(WCFG.launchSpeed, proj, draw)
		if ok and type(s) == "number" and s > 0 then speed = s end
	end
	local flat = Vector3.new(velEst.X, 0, velEst.Z) * (Values.BowLead / 100) -- ground mobs: ignore bobbing
	local aim = pos
	for _ = 1, 2 do
		local t = (aim - origin).Magnitude / speed + 0.05 -- + server tick
		aim = pos + flat * t
	end
	return aim
end

local bowBusy = false -- true while the bow has a target, so melee does not steal the equip
local function setAim(on)
	if RequestSprint then pcall(function() RequestSprint:FireServer(on, "Aim") end) end
end

local lockedTarget

-- noclip for the blink: drop collision on the rig, restore it exactly afterwards
local function setNoclip(char, on, saved)
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") then
			if on then
				if saved[p] == nil then saved[p] = p.CanCollide end
				p.CanCollide = false
			elseif saved[p] ~= nil then
				p.CanCollide = saved[p]
			end
		end
	end
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
				-- stick to one target until it dies, goes dormant, gets switched off or a boss shows up
				-- (blink ignores walls: we fire from right next to the target)
				local best = pickBowTarget(hrp.Position, Values.BlinkRange, false)
				local lockInst = lockedTarget and enemyOf(lockedTarget)
				local keep = lockInst and lockedTarget.Parent and targetAlive(lockInst)
					and shootable(lockInst) and not isImmune(lockedTarget)
					and not (best and best ~= lockedTarget and isBossType(enemyKind(enemyOf(best)))
						and not isBossType(enemyKind(lockInst)))
				target = keep and lockedTarget or best
				lockedTarget = target
			else
				target = nearestVisibleEnemy(shotOrigin(hrp), Values.BowRange)
			end
		end
		trackVelocity(target)
		bowBusy = target ~= nil
		if hrp and (target or not State.Magic) then
			-- only re-equip when the bow isn't already out: re-equipping restarts the draw timer
			if not heldProjectile() then
				pendingEquip = nil
				RequestEquip:FireServer("Weapon")
				task.wait(0.4)
			end
			local proj = heldProjectile()
			if proj then
				-- Blink: hop next to the target so the server sees us there, shoot, hop back
				local home
				local collide = {}
				if target and State.Blink then
					home = hrp.CFrame
					-- Stand BlinkDepth studs under the slime (0 = beside it, above ground), noclipped.
					-- Hold the spot for a moment: a single CFrame set gets interpolated server-side,
					-- so the shot is either rejected or fired from somewhere mid-path.
					-- stand under (or beside) the slime, offset to the same side the arrow will come from
					local stand = Values.BlinkDepth > 0
						and CFrame.new(target.Position + Vector3.new(0, -Values.BlinkDepth, BLINK_SIDE))
						or CFrame.new(target.Position + Vector3.new(0, 6, 6), target.Position)
					local char = getChar()
					local t0 = os.clock()
					while os.clock() - t0 < BLINK_DWELL do
						if char then setNoclip(char, true, collide) end
						hrp.CFrame = stand
						hrp.AssemblyLinearVelocity = Vector3.zero
						RunService.Heartbeat:Wait()
					end
				end
				local origin = shotOrigin(hrp)
				local aimPos
				if target then
					-- server accepts a launch point up to ShotOriginSlackStuds (12) from the bow
					local bow = origin
					if home and Values.BlinkDepth > 0 then
						-- Underground: launching from the bow (or pushed straight up) starts the arrow
						-- inside the terrain. Launch from beside the slime at its own height instead.
						origin = target.Position + Vector3.new(0, 0.5, BLINK_SIDE)
						local off = origin - bow
						if off.Magnitude > SHOT_SLACK then origin = bow + off.Unit * SHOT_SLACK end
						aimPos = target.Position
					else
						-- spawn the arrow as close to the (led) target as the slack allows
						aimPos = leadPosition(origin, target, proj, draw)
						local rel = aimPos - origin
						local push = math.min(rel.Magnitude - 1.5, SHOT_SLACK)
						if push > 0 then
							origin += rel.Unit * push
							aimPos = leadPosition(origin, target, proj, draw)
						end
					end
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
					local char = getChar()
					if char then setNoclip(char, false, collide) end
				end
				if target and immunityApplies(enemyOf(target)) then
					local before = healthOf(target)
					task.delay(0.6, function()
						if not target.Parent then noDamage[target] = nil return end
						if before and healthOf(target) == before then
							noDamage[target] = (noDamage[target] or 0) + 1
							if noDamage[target] >= 2 then
								immuneUntil[target] = os.clock() + 30
								noDamage[target] = 0
							end
						else
							noDamage[target] = 0
						end
					end)
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
local farmTarget -- sticky: finish one node before starting the next (nodes heal when left alone)
local traveling = false

local function swingReady(slot)
	return os.clock() - lastSwing >= swingInterval(slot)
end

track(RunService.Heartbeat:Connect(function()
	if not alive then return end
	if os.clock() - lastScan > FULL_RESCAN then rescan() else rebuildLists() end
	if not (State.Farm or State.Fight) then return end
	local hrp = getHRP()
	if not hrp then return end

	if State.Fight and not State.Bow then
		local _, part = nearestIn(enemies, hrp.Position, Values.Reach)
		if part then
			if equip("Weapon") and swingReady("Weapon") then
				lastSwing = os.clock()
				RequestSwing:FireServer(part)
			end
			return
		end
	end
	if State.Farm and not bowBusy then
		local model, part
		if farmTarget and farmTarget.Parent and nodeEligible(farmTarget) then
			local p = hitPart(farmTarget)
			if p and (p.Position - hrp.Position).Magnitude <= Values.Reach then model, part = farmTarget, p end
		end
		if not model then
			model, part = nearestIn(nodes, hrp.Position, Values.Reach, nodeEligible)
			farmTarget = model
		end
		if part then
			local slot = slotForNode(model)
			if equip(slot) and swingReady(slot) then
				lastSwing = os.clock()
				RequestSwing:FireServer(part)
			end
		end
	end
end))

--------------------------------------------------------------------
-- Farm Travel: fly (noclip, stepped CFrame) to the nearest eligible node,
-- stand beside it, let the scheduler above break it, repeat.
-- Server reach is ~16 studs (20 is refused); we stand 5 off the hitbox.
--------------------------------------------------------------------
local STAND_OFF = 5
local seatBlocked = false

local function blockSeats(on)
	local hum = getHum()
	if not hum then return end
	if on and not seatBlocked then
		hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
		if hum.SeatPart then hum.Sit = false end
		seatBlocked = true
	elseif not on and seatBlocked then
		hum:SetStateEnabled(Enum.HumanoidStateType.Seated, true)
		seatBlocked = false
	end
end

local function standSpot(part, from)
	local flat = (from - part.Position) * Vector3.new(1, 0, 1)
	flat = flat.Magnitude > 0.1 and flat.Unit or Vector3.xAxis
	local half = math.max(part.Size.X, part.Size.Z) / 2
	return part.Position + flat * (half + STAND_OFF) + Vector3.new(0, 1.5, 0)
end

-- returns true on arrival; aborts if the toggle drops, the character changes or the node dies
local function travelTo(goal, model)
	local char, hrp = getChar(), getHRP()
	if not (char and hrp) then return false end
	local saved = {}
	for _, p in ipairs(char:GetDescendants()) do if p:IsA("BasePart") then saved[p] = p.CanCollide end end
	traveling = true
	local ok = false
	local t0 = os.clock()
	local limit = (goal - hrp.Position).Magnitude / math.max(Values.TravelSpeed, 1) + 3
	while alive and State.Farm and State.Travel and hrp.Parent and model.Parent do
		local dt = RunService.Heartbeat:Wait()
		for p in pairs(saved) do p.CanCollide = false end
		local d = goal - hrp.Position
		if d.Magnitude <= 0.5 then ok = true break end
		if os.clock() - t0 > limit then break end
		hrp.CFrame = CFrame.new(hrp.Position + d.Unit * math.min(d.Magnitude, Values.TravelSpeed * dt))
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
	if ok then
		-- hold a few frames so the server's smoothed position catches up before we swing
		for _ = 1, 8 do
			if not hrp.Parent then break end
			hrp.CFrame = CFrame.new(goal)
			hrp.AssemblyLinearVelocity = Vector3.zero
			RunService.Heartbeat:Wait()
		end
	end
	-- always restore collision, or the rig drops through the floor
	for p, v in pairs(saved) do if p.Parent then p.CanCollide = v end end
	traveling = false
	return ok
end

local travelRunning = false
local function travelLoop()
	if travelRunning then return end
	travelRunning = true
	blockSeats(true)
	while alive and State.Travel do
		local hrp = getHRP()
		if not (State.Farm and hrp) or bowBusy then
			task.wait(0.25)
		else
			local here = nearestIn(nodes, hrp.Position, Values.Reach, nodeEligible)
			if here then
				task.wait(0.1) -- scheduler is working a node in reach
			else
				local model, part = nearestIn(nodes, hrp.Position, Values.TravelRange, nodeEligible)
				if model then
					farmTarget = model
					-- equip on the way so the first swing lands on arrival
					equip(slotForNode(model))
					if not travelTo(standSpot(part, hrp.Position), model) then task.wait(0.2) end
				else
					task.wait(0.5) -- nothing in range: wait for respawns
				end
			end
		end
	end
	blockSeats(false)
	travelRunning = false
end

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
local flyCollide = {} -- part -> original CanCollide while fly noclip is active

local function restoreFlyCollide()
	for p, v in pairs(flyCollide) do if p.Parent then p.CanCollide = v end end
	table.clear(flyCollide)
end

-- Stepped runs before physics, so the Humanoid can't re-enable collision in between
track(RunService.Stepped:Connect(function()
	if not (State.Fly and State.FlyNoclip and flyParts) then
		if next(flyCollide) then restoreFlyCollide() end
		return
	end
	local char = getChar()
	if not char then return end
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") then
			if flyCollide[p] == nil then flyCollide[p] = p.CanCollide end
			p.CanCollide = false
		end
	end
end))

local function stopFly()
	if flyParts then
		for _, p in ipairs(flyParts) do pcall(function() p:Destroy() end) end
		flyParts = nil
	end
	restoreFlyCollide()
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
	curSlot, pendingEquip, farmTarget = nil, nil, nil
	flyParts = nil
	seatBlocked = false
	if State.Travel then blockSeats(true) end
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
	elseif name == "Travel" then
		if on then
			if not State.Farm then State.Farm = true; if Features and Features.Farm then Features.Farm.refresh() end end
			task.spawn(travelLoop)
		end
	elseif name == "Farm" then
		if not on then farmTarget = nil end
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

-- window = title bar + scrolling body, capped to the screen height
local win = Instance.new("Frame")
win.Size = UDim2.fromOffset(260, 400)
win.Position = UDim2.new(0, 20, 0, 60)
win.BackgroundColor3 = C.bg
win.BorderSizePixel = 0
win.Active = true
win.Parent = gui
corner(win, 8)

local order = 0
local function nextOrder() order += 1; return order end

-- title bar doubles as drag handle
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 30)
title.Position = UDim2.fromOffset(10, 2)
title.BackgroundTransparency = 1
title.Text = "ABOVE Autohit  v" .. VERSION
title.TextColor3 = C.accent
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Active = true
title.Parent = win

local frame = Instance.new("ScrollingFrame")
frame.Position = UDim2.fromOffset(0, 32)
frame.Size = UDim2.new(1, 0, 1, -38)
frame.BackgroundTransparency = 1
frame.BorderSizePixel = 0
frame.ScrollBarThickness = 4
frame.ScrollBarImageColor3 = C.accent
frame.ScrollingDirection = Enum.ScrollingDirection.Y
frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
frame.CanvasSize = UDim2.new()
frame.Parent = win

local pad = Instance.new("UIPadding")
pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 2), UDim.new(0, 8)
pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 12)
pad.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 5)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = frame

-- fit the window to its content, but never taller than the screen
local function fitWindow()
	local cam = workspace.CurrentCamera
	local screenH = cam and cam.ViewportSize.Y or 800
	local want = layout.AbsoluteContentSize.Y + 32 + 6 + 10
	win.Size = UDim2.fromOffset(260, math.min(want, screenH - 80))
end
track(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fitWindow))
if workspace.CurrentCamera then
	track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitWindow))
end
task.defer(fitWindow)

do
	local dragging, dragStart, startPos
	track(title.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, i.Position, win.Position
		end
	end))
	track(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
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

local function chips(tbl, names, onToggle)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.new(1, 0, 0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.BackgroundTransparency = 1
	holder.LayoutOrder = nextOrder()
	holder.Parent = frame
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0.25, -4, 0, 20)
	grid.CellPadding = UDim2.fromOffset(4, 4)
	grid.SortOrder = Enum.SortOrder.Name
	grid.Parent = holder
	for i, nt in ipairs(names) do
		local b = Instance.new("TextButton")
		b.Name = string.format("%02d", i)
		b.Text = (nt:gsub("Skeleton(%u)", "Skel %1"):gsub("Slime$", ""))
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 11
		b.AutoButtonColor = true
		b.BorderSizePixel = 0
		b.Parent = holder
		corner(b, 4)
		local function paint()
			local on = tbl[nt] ~= false
			b.BackgroundColor3 = on and C.on or C.off
			b.TextColor3 = on and C.bg or C.dim
		end
		paint()
		track(b.MouseButton1Click:Connect(function()
			tbl[nt] = tbl[nt] == false
			if onToggle then onToggle(nt, tbl[nt]) end
			paint(); saveConfig()
		end))
	end
end

section("Farm")
featureRow("Farm",   "Auto Farm")
featureRow("Travel", "Farm Travel")
do
	local names = {}
	for nt in pairs(FarmTypes) do names[#names + 1] = nt end
	table.sort(names)
	chips(FarmTypes, names, function(nt)
		if farmTarget and farmTarget:GetAttribute("NodeType") == nt then farmTarget = nil end
	end)
end
slider("Reach", "Reach", 4, 16, " studs")
slider("Swing early (0.01s, server slack 0.15)", "SwingEarly", 0, 14, "")
slider("Travel speed", "TravelSpeed", 15, 80, " st/s")
slider("Travel range", "TravelRange", 50, 1000, " studs")

section("Combat")
featureRow("Fight", "Auto Fight")
featureRow("Bow",   "Auto Bow")
featureRow("Magic", "Magic Aim")
featureRow("Blink", "Blink Shot")
do
	-- mobs ordered weakest to strongest, bosses on their own row
	local hpOf = function(id)
		local e = ECFG and ECFG.Enemies and ECFG.Enemies[id]
		return (type(e) == "table" and e.hp) or 0
	end
	local mobs, bosses = {}, {}
	for id in pairs(ShootTypes) do
		if isBossType(id) then bosses[#bosses + 1] = id else mobs[#mobs + 1] = id end
	end
	local byHp = function(a, b) if hpOf(a) ~= hpOf(b) then return hpOf(a) < hpOf(b) end return a < b end
	table.sort(mobs, byHp); table.sort(bosses, byHp)
	local unlock = function() lockedTarget = nil end
	section("Bow targets: mobs")
	chips(ShootTypes, mobs, unlock)
	section("Bow targets: bosses (shot first)")
	chips(ShootTypes, bosses, unlock)
end
slider("Bow range", "BowRange", 50, 500, " studs")
slider("Bow lead (moving targets)", "BowLead", 0, 150, "%")
slider("Blink range", "BlinkRange", 20, 300, " studs")
slider("Blink depth (0 = above ground)", "BlinkDepth", 0, 15, " studs")
slider("Bow draw (low = fast, high = damage)", "Draw", 12, 100, "%")

section("Movement")
featureRow("Speed", "Speed")
slider("WalkSpeed", "Speed", 16, 150)
featureRow("Jump",  "Jump")
slider("JumpPower", "Jump", 50, 300)
featureRow("Fly",   "Fly  (Space / Ctrl)")
featureRow("FlyNoclip", "Fly noclip")
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
				win.Visible = not win.Visible
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
	State = State, Values = Values, Binds = Binds, FarmTypes = FarmTypes, ShootTypes = ShootTypes, Set = setFeature,
	Debug = function()
		return { slot = curSlot, items = slotItem, cooldowns = slotCooldown, target = farmTarget,
			nodes = #nodes, enemies = #enemies, traveling = traveling,
			bowTarget = velTarget, bowVel = velEst }
	end,
	Unload = function()
		alive = false
		State.Bow = false
		State.Travel = false
		setAim(false)
		blockSeats(false)
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
