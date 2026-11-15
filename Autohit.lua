--[[
  ABOVE [ARCANE] — Autohit
  Swings at the nearest resource node / enemy within reach via RequestSwing.
  Toggle: RightShift   |   Unload: getgenv().AboveAutohit.Unload()
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

local env = getgenv and getgenv() or _G
if env.AboveAutohit and env.AboveAutohit.Unload then env.AboveAutohit.Unload() end

local Settings = {
	Enabled   = true,
	Interval  = 0.32,          -- client cadence is ~0.30s; server tolerance is 0.15s
	Reach     = 12,            -- studs from HRP to target hitbox
	Nodes     = true,          -- trees, stone, ore, coal, sand, clay
	Enemies   = true,          -- slimes, guardians, ruins boss
	NodeTypes = nil,           -- e.g. {Tree=true, IronOre=true}; nil = all
	ToggleKey = Enum.KeyCode.RightShift,
}

local lp = Players.LocalPlayer
local Remotes = RS:WaitForChild("Remotes")
local RequestSwing = Remotes:WaitForChild("RequestSwing")
local RequestEquip = Remotes:WaitForChild("RequestEquipSlot")

-- the server only credits hits from the right tool class
local PICK_TARGETS = { Stone = true, Coal = true, IronOre = true, Clay = true, Sand = true, GoldOre = true }
local AXE_TARGETS  = { Tree = true, Pine = true }

local equipped
local function equipFor(model, isEnemy)
	local slot
	if isEnemy then
		slot = "Weapon"
	else
		local nt = model:GetAttribute("NodeType") or model.Name
		slot = (PICK_TARGETS[nt] and "Pickaxe") or (AXE_TARGETS[nt] and "Axe")
	end
	if slot and slot ~= equipped then
		RequestEquip:FireServer(slot)
		equipped = slot
	end
end

local function hrp()
	local c = lp.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function hitPart(model)
	if model:IsA("BasePart") then return model end
	local hb = model:FindFirstChild("HB")
	if hb and hb:IsA("BasePart") then return hb end
	if model:IsA("Model") and model.PrimaryPart then return model.PrimaryPart end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function alive(model)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health <= 0 then return false end
	return model.Parent ~= nil
end

local function isPlayerChar(model)
	return Players:GetPlayerFromCharacter(model) ~= nil
end

-- Nodes: Models tagged with a NodeType attribute (hit via their HB part).
-- Enemies: anything tagged with EnemyId (hub guardians are bare Parts, the slime art is a child model).
local function collect()
	local list = {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if Settings.Nodes and d:IsA("Model") then
			local nt = d:GetAttribute("NodeType")
			if nt and (not Settings.NodeTypes or Settings.NodeTypes[nt]) then
				list[#list + 1] = { model = d, enemy = false }
			end
		end
		if Settings.Enemies and d:GetAttribute("EnemyId") and (d:IsA("BasePart") or d:IsA("Model")) and not isPlayerChar(d) then
			list[#list + 1] = { model = d, enemy = true }
		end
	end
	return list
end

-- target cache refreshed every second instead of walking workspace every swing
local cache, lastScan = {}, 0
local function nearest()
	local root = hrp()
	if not root then return end
	if os.clock() - lastScan > 1.5 then
		cache = collect(); lastScan = os.clock()
		equipped = nil -- re-assert the tool in case it was swapped by hand
	end
	local best, bestD
	for _, t in ipairs(cache) do
		local m = t.model
		if m.Parent and alive(m) then
			local p = hitPart(m)
			if p then
				local d = (p.Position - root.Position).Magnitude
				-- enemies win over nodes when both are in reach
				if d <= Settings.Reach then
					local score = t.enemy and d - 1000 or d
					if not bestD or score < bestD then best, bestD = t, score end
				end
			end
		end
	end
	if best then return hitPart(best.model), best.model, best.enemy end
end

local conns, last = {}, 0
conns[#conns + 1] = RunService.Heartbeat:Connect(function()
	if not Settings.Enabled then return end
	local now = os.clock()
	if now - last < Settings.Interval then return end
	local part, model, isEnemy = nearest()
	if part then
		last = now
		equipFor(model, isEnemy)
		RequestSwing:FireServer(part)
	end
end)

conns[#conns + 1] = UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Settings.ToggleKey then
		Settings.Enabled = not Settings.Enabled
		print("[Autohit]", Settings.Enabled and "ON" or "OFF")
	end
end)

env.AboveAutohit = {
	Settings = Settings,
	Unload = function()
		for _, c in ipairs(conns) do c:Disconnect() end
		env.AboveAutohit = nil
		print("[Autohit] unloaded")
	end,
}

print("[Autohit] loaded — RightShift to toggle")
