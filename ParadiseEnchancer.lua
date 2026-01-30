--[[
   Paradise Enhancer v2.0
   Optimized for multi-instance execution
]]

--------------------------------------------------------------------------------
-- SERVICES
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

--------------------------------------------------------------------------------
-- REFERENCES
--------------------------------------------------------------------------------

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local PlayerData = Player:WaitForChild("PlayerData")
local Currencies = PlayerData:WaitForChild("Currencies")
local Inventory = PlayerData:WaitForChild("Inventory")
local Quests = PlayerData:WaitForChild("Quests")
local ClaimedGifts = Player:WaitForChild("ClaimedGifts")
local Playtime = Player:WaitForChild("Playtime")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local CasesModule = require(Modules:WaitForChild("Cases"))
local ItemsModule = require(Modules:WaitForChild("Items"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Remote = {
OpenCase = Remotes:WaitForChild("OpenCase"),
CreateBattle = Remotes:WaitForChild("CreateBattle"),
CheckCooldown = Remotes:WaitForChild("CheckCooldown"),
AddBot = Remotes:WaitForChild("AddBot"),
StartBattle = Remotes:WaitForChild("StartBattle"),
Sell = Remotes:WaitForChild("Sell"),
Exchange = Remotes:WaitForChild("ExchangeEvent"),
ClaimIndex = Remotes:WaitForChild("ClaimCategoryIndex"),
}

local GiftsFolder = ReplicatedStorage:WaitForChild("Gifts")
local WildPrices = ReplicatedStorage.Misc.WildPrices

local UI = {
Main = PlayerGui:WaitForChild("Main"),
Windows = PlayerGui:WaitForChild("Windows"),
OpenAnimation = PlayerGui:WaitForChild("OpenAnimation"),
Battle = PlayerGui:WaitForChild("Battle"),
}
UI.Inventory = UI.Windows.Inventory
UI.Index = UI.Windows.Index

Remote.StartBattle.OnClientEvent:Connect(function() end)

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local Config = {
Cooldown = {
BattleMin = 14,
BattleMax = 18,
CaseMin = 8,
CaseMax = 12,
SellMin = 120,
SellMax = 300,
},
Threshold = {
GalaxyTickets = 50,
KatowiceBalance = 140000,
},
LevelCases = {
"LEVEL10", "LEVEL20", "LEVEL30", "LEVEL40", "LEVEL50", "LEVEL60",
"LEVEL70", "LEVEL80", "LEVEL90", "LEVELS100", "LEVELS110", "LEVELS120",
},
Whitelist = {
["DesertEagle_PlasmaStorm"] = true,
["ButterflyKnife_Wrapped"] = true,
["TitanHoloKato2014"] = true,
["SkeletonKnife_PlanetaryDevastation"] = true,
["Karambit_Interstellar"] = true,
["ButterflyKnife_DemonHound"] = true,
["AWP_IonCharge"] = true,
},
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local State = {
Features = {
ClaimGift = true,
OpenCase = true,
GalaxyCase = true,
KatowiceWild = true,
QuestOpen = true,
QuestPlay = true,
QuestWin = true,
LevelCases = true,
AutoSell = true,
RejoinOnGift9 = true,
},
Case = {
Selected = "StarGazingCase",
Quantity = 5,
WildMode = false,
},
Time = {
LastBattle = 0,
LastSell = 0,
NextSell = 0,
NextLevelCase = math.huge,
},
Ready = {
Case = true,
},
NextLevelCaseId = nil,
}

--------------------------------------------------------------------------------
-- CACHE
--------------------------------------------------------------------------------

local Cache = {}

Cache.GiftPlaytimes = {}
for i = 1, 9 do
local giftId = "Gift" .. i
Cache.GiftPlaytimes[giftId] = GiftsFolder[giftId].Value
end

Cache.IndexCategories = {}
do
local children = UI.Index.Categories:GetChildren()
table.sort(children, function(a, b)
return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
end)
for _, child in ipairs(children) do
if child:IsA("StringValue") and child.Value ~= "" then
table.insert(Cache.IndexCategories, child.Value)
end
end
end

Cache.Cases = {}
do
for caseId, data in pairs(CasesModule) do
local isLevelCase = caseId:match("^LEVELS?%d+$")
if not data.AdminOnly and not isLevelCase then
table.insert(Cache.Cases, {
Id = caseId,
Name = data.Name or caseId,
Price = data.Price or 0,
Currency = data.Currency or "Cash",
})
end
end
table.sort(Cache.Cases, function(a, b)
if a.Currency == "Tickets" and b.Currency ~= "Tickets" then return true end
if a.Currency ~= "Tickets" and b.Currency == "Tickets" then return false end
return a.Price < b.Price
end)
end

-- Note: Quests are NOT cached because they change when completed
-- We read directly from Quests folder to detect new quests

--------------------------------------------------------------------------------
-- UTILITY
--------------------------------------------------------------------------------

local Util = {}

function Util.getBalance()
return Currencies.Balance.Value
end

function Util.getTickets()
return Currencies.Tickets.Value
end

function Util.getExperience()
return Currencies.Experience.Value
end

function Util.getPlaytime()
return Playtime.Value
end

function Util.getCasePrice(caseId)
return CasesModule[caseId] and CasesModule[caseId].Price or 0
end

function Util.getWildPrice(caseId)
local priceObj = WildPrices:FindFirstChild(caseId)
return priceObj and priceObj.Value or Util.getCasePrice(caseId)
end

function Util.canAfford(caseId, quantity, useWild)
if caseId:match("^Gift%d?$") then return true end
local data = CasesModule[caseId]
if not data then return false end
local price = useWild and Util.getWildPrice(caseId) or data.Price or 0
if price <= 0 then return true end
local totalCost = price * (quantity or 1)
local currency = data.Currency == "Tickets" and Util.getTickets() or Util.getBalance()
return currency >= totalCost
end

function Util.randomCooldown(min, max)
return math.random(min, max)
end

function Util.formatPrice(price, currency)
if price == 0 then return "Free" end
local formatted = price % 1 == 0 and tostring(price) or string.format("%.2f", price)
return currency == "Tickets" and (formatted .. " GINGERBREAD") or ("$" .. formatted)
end

--------------------------------------------------------------------------------
-- UI SUPPRESSION
--------------------------------------------------------------------------------

local UISuppress = {}
local suppressConnection

function UISuppress.startSuppression()
local camera = workspace.CurrentCamera
local openScreen = UI.OpenAnimation.CaseOpeningScreen
local endPreview = UI.OpenAnimation.EndPreview
local mainUI = UI.Main
local windowsUI = UI.Windows

suppressConnection = RunService.RenderStepped:Connect(function()
if State.Ready.Case then
suppressConnection:Disconnect()
suppressConnection = nil
return
end
if camera.FieldOfView ~= 70 then camera.FieldOfView = 70 end
if openScreen.Visible then openScreen.Visible = false end
if endPreview.Visible then endPreview.Visible = false end
if not mainUI.Enabled then mainUI.Enabled = true end
if not windowsUI.Enabled then windowsUI.Enabled = true end
end)
end

function UISuppress.hideBattle()
UI.Battle.BattleFrame.Visible = false
UI.Main.Enabled = true
UI.Windows.Enabled = true
end

--------------------------------------------------------------------------------
-- CASE SYSTEM
--------------------------------------------------------------------------------

local CaseSystem = {}

function CaseSystem.open(caseId, isGift, quantity, useWild)
local checkId = isGift and "Gift" or caseId
if not State.Ready.Case then return false end
if not Util.canAfford(checkId, quantity, useWild) then return false end

State.Ready.Case = false
UISuppress.startSuppression()

if isGift then
Remote.OpenCase:InvokeServer(caseId, -1, false)
else
Remote.OpenCase:InvokeServer(caseId, quantity or 1, false, useWild or false)
end

task.delay(Util.randomCooldown(Config.Cooldown.CaseMin, Config.Cooldown.CaseMax), function()
State.Ready.Case = true
end)
return true
end

--------------------------------------------------------------------------------
-- GIFT SYSTEM
--------------------------------------------------------------------------------

local GiftSystem = {}

function GiftSystem.isClaimed(giftId)
return ClaimedGifts[giftId].Value
end

function GiftSystem.markClaimed(giftId)
task.wait(1)
ClaimedGifts[giftId].Value = true
UI.Windows.Rewards.ClaimedGifts[giftId].Value = true
end

function GiftSystem.getNextClaimable()
local currentPlaytime = Util.getPlaytime()
for i = 1, 9 do
local giftId = "Gift" .. i
if not GiftSystem.isClaimed(giftId) and currentPlaytime >= Cache.GiftPlaytimes[giftId] then
return giftId
end
end
return nil
end

--------------------------------------------------------------------------------
-- QUEST SYSTEM
--------------------------------------------------------------------------------

local QuestSystem = {}

-- Find quest by type directly from the Quests folder (no caching)
-- This ensures we always get the current quest, even after completion
function QuestSystem.findQuest(questType)
for _, quest in ipairs(Quests:GetChildren()) do
if quest.Value == questType then
return quest
end
end
return nil
end

function QuestSystem.getData(questType)
local quest = QuestSystem.findQuest(questType)
if not quest then return nil end

local progressObj = quest:FindFirstChild("Progress")
local requirementObj = quest:FindFirstChild("Requirement")
local subjectObj = quest:FindFirstChild("Subject")

if not progressObj or not requirementObj then return nil end

local progress = progressObj.Value
local requirement = requirementObj.Value
return {
Progress = progress,
Requirement = requirement,
Subject = subjectObj and subjectObj.Value or "",
Remaining = requirement - progress,
}
end

function QuestSystem.getOpen()
return QuestSystem.getData("Open")
end

function QuestSystem.getPlay()
return QuestSystem.getData("Play")
end

function QuestSystem.getWin()
return QuestSystem.getData("Win")
end

--------------------------------------------------------------------------------
-- BATTLE SYSTEM
--------------------------------------------------------------------------------

local BattleSystem = {}

function BattleSystem.createBotBattle(mode)
local battleId = Remote.CreateBattle:InvokeServer({"PERCHANCE"}, 2, mode, false)
task.wait(1)
Remote.AddBot:FireServer(battleId, Player)
end

--------------------------------------------------------------------------------
-- LEVEL CASE SYSTEM
--------------------------------------------------------------------------------

local LevelSystem = {}

function LevelSystem.updateCooldowns()
State.Time.NextLevelCase = math.huge
State.NextLevelCaseId = nil
local playerXP = Util.getExperience()

for _, caseId in ipairs(Config.LevelCases) do
local data = CasesModule[caseId]
if data and playerXP >= (data.XPRequirement or 0) then
local cooldownEnd = Remote.CheckCooldown:InvokeServer(caseId)
if cooldownEnd < State.Time.NextLevelCase then
State.Time.NextLevelCase = cooldownEnd
State.NextLevelCaseId = caseId
end
end
end
end

--------------------------------------------------------------------------------
-- ECONOMY SYSTEM
--------------------------------------------------------------------------------

local EconomySystem = {}

function EconomySystem.exchange()
Remote.Exchange:FireServer("Exchange")
task.wait(2)
Remote.Exchange:FireServer("Claim")
end

function EconomySystem.claimAllIndex()
for _, category in ipairs(Cache.IndexCategories) do
Remote.ClaimIndex:FireServer(category)
task.wait(2)
end
end

function EconomySystem.refreshInventoryUI()
local currentWindow = PlayerGui.CurrentWindow
local previous = currentWindow.Value
currentWindow.Value = "Inventory"
task.wait(0.1)
currentWindow.Value = previous
end

function EconomySystem.sellUnlocked()
EconomySystem.exchange()
task.wait(0.1)
EconomySystem.claimAllIndex()
task.wait(0.1)
EconomySystem.refreshInventoryUI()
task.wait(0.5)

local contents = UI.Inventory.InventoryFrame.Contents
local toSell = {}

for _, frame in pairs(contents:GetChildren()) do
if frame:IsA("Frame") then
local itemId = frame:GetAttribute("ItemId")
local locked = frame:GetAttribute("locked")
if itemId and not locked and not Config.Whitelist[itemId] then
table.insert(toSell, {
Name = itemId,
Wear = frame.Wear.Text,
Stattrak = frame.Stattrak.Visible,
Age = frame.Age.Value,
})
end
end
end

if #toSell > 0 then
Remote.Sell:InvokeServer(toSell)
end
end

--------------------------------------------------------------------------------
-- SERVER SYSTEM
--------------------------------------------------------------------------------

local ServerSystem = {}

function ServerSystem.rejoin()
if #Players:GetPlayers() <= 1 then
Player:Kick("\nRejoining...")
task.wait()
TeleportService:Teleport(game.PlaceId, Player)
else
TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, Player)
end
end

--------------------------------------------------------------------------------
-- UI (Rayfield)
--------------------------------------------------------------------------------

local Rayfield = loadstring(game:HttpGet('https://raw.githubusercontent.com/spint990/ParadiseEnhancer/refs/heads/main/Rayfield'))()

local Window = Rayfield:CreateWindow({
Name = "Paradise Enhancer v2.0",
LoadingTitle = "Paradise Enhancer",
LoadingSubtitle = "by Backlyne",
Theme = "Default",
ToggleUIKeybind = "K",
})

local CaseDropdown
local Labels = {}

local function buildCaseOptions()
local options = {}
for _, caseData in ipairs(Cache.Cases) do
local unitPrice = State.Case.WildMode and Util.getWildPrice(caseData.Id) or caseData.Price
local totalPrice = unitPrice * State.Case.Quantity
local wildTag = State.Case.WildMode and " (Wild)" or ""
table.insert(options, caseData.Name .. wildTag .. " " .. Util.formatPrice(totalPrice, caseData.Currency))
end
return options
end

local function updateDropdownSelection()
for _, caseData in ipairs(Cache.Cases) do
if caseData.Id == State.Case.Selected then
local unitPrice = State.Case.WildMode and Util.getWildPrice(caseData.Id) or caseData.Price
local wildTag = State.Case.WildMode and " (Wild)" or ""
CaseDropdown:Set(caseData.Name .. wildTag .. " " .. Util.formatPrice(unitPrice * State.Case.Quantity, caseData.Currency))
break
end
end
end

-- Tab: Cases
local TabCases = Window:CreateTab("Cases", 4483362458)
TabCases:CreateSection("Auto Case Opener")

TabCases:CreateToggle({
Name = "Enable Auto Case Opening",
CurrentValue = State.Features.OpenCase,
Flag = "AutoCaseOpen",
Callback = function(value)
State.Features.OpenCase = value
end,
})

CaseDropdown = TabCases:CreateDropdown({
Name = "Case to Open",
Options = buildCaseOptions(),
CurrentOption = {"Star Gazing Case " .. Util.formatPrice(State.Case.Quantity * 10, "Tickets")},
MultipleOptions = false,
Flag = "SelectedCase",
Callback = function(option)
local optionName = type(option) == "table" and option[1] or option
for _, caseData in ipairs(Cache.Cases) do
if optionName:find(caseData.Name, 1, true) == 1 then
State.Case.Selected = caseData.Id
break
end
end
end,
})

TabCases:CreateDropdown({
Name = "Quantity",
Options = {"1", "2", "3", "4", "5"},
CurrentOption = {"5"},
MultipleOptions = false,
Flag = "CaseQuantity",
Callback = function(option)
State.Case.Quantity = tonumber(type(option) == "table" and option[1] or option) or 1
CaseDropdown:Refresh(buildCaseOptions())
updateDropdownSelection()
end,
})

TabCases:CreateToggle({
Name = "Wild Mode",
CurrentValue = State.Case.WildMode,
Flag = "WildMode",
Callback = function(value)
State.Case.WildMode = value
CaseDropdown:Refresh(buildCaseOptions())
updateDropdownSelection()
end,
})

-- Tab: Quests
local TabQuests = Window:CreateTab("Quests", 4483362458)
TabQuests:CreateSection("Auto Quest Completion")

TabQuests:CreateToggle({
Name = "Auto Quest: Open Cases",
CurrentValue = State.Features.QuestOpen,
Flag = "AutoQuestOpen",
Callback = function(value)
State.Features.QuestOpen = value
end,
})

TabQuests:CreateToggle({
Name = "Auto Quest: Play Battles",
CurrentValue = State.Features.QuestPlay,
Flag = "AutoQuestPlay",
Callback = function(value)
State.Features.QuestPlay = value
if value then UISuppress.hideBattle() end
end,
})

TabQuests:CreateToggle({
Name = "Auto Quest: Win Battles",
CurrentValue = State.Features.QuestWin,
Flag = "AutoQuestWin",
Callback = function(value)
State.Features.QuestWin = value
if value then UISuppress.hideBattle() end
end,
})

TabQuests:CreateSection("Quest Status")
Labels.Open = TabQuests:CreateLabel("Open Cases: -")
Labels.Play = TabQuests:CreateLabel("Play Battles: -")
Labels.Win = TabQuests:CreateLabel("Win Battles: -")

-- Tab: Misc
local TabMisc = Window:CreateTab("Misc", 4483362458)
TabMisc:CreateSection("Gifts")

TabMisc:CreateToggle({
Name = "Auto Claim Gifts",
CurrentValue = State.Features.ClaimGift,
Flag = "AutoClaimGift",
Callback = function(value)
State.Features.ClaimGift = value
end,
})

TabMisc:CreateToggle({
Name = "Auto Rejoin on Gift 9",
CurrentValue = State.Features.RejoinOnGift9,
Flag = "AutoRejoinGift9",
Callback = function(value)
State.Features.RejoinOnGift9 = value
end,
})

TabMisc:CreateSection("Special Cases")

TabMisc:CreateToggle({
Name = "Auto Level Cases",
CurrentValue = State.Features.LevelCases,
Flag = "AutoOpenLevelCases",
Callback = function(value)
State.Features.LevelCases = value
if value then LevelSystem.updateCooldowns() end
end,
})

TabMisc:CreateToggle({
Name = "Auto Galaxy (50+ Tickets)",
CurrentValue = State.Features.GalaxyCase,
Flag = "AutoGalaxyCase",
Callback = function(value)
State.Features.GalaxyCase = value
end,
})

TabMisc:CreateToggle({
Name = "Auto Katowice Wild (140k+ Balance)",
CurrentValue = State.Features.KatowiceWild,
Flag = "AutoKatowiceCase",
Callback = function(value)
State.Features.KatowiceWild = value
end,
})

TabMisc:CreateSection("Inventory")

TabMisc:CreateToggle({
Name = "Auto Sell (2 min interval)",
CurrentValue = State.Features.AutoSell,
Flag = "AutoSell",
Callback = function(value)
State.Features.AutoSell = value
end,
})

--------------------------------------------------------------------------------
-- QUEST LABELS
--------------------------------------------------------------------------------

local function updateQuestLabels()
local openData = QuestSystem.getOpen()
local playData = QuestSystem.getPlay()
local winData = QuestSystem.getWin()

if openData then
local cost = openData.Remaining * Util.getCasePrice(openData.Subject)
Labels.Open:Set(string.format("Open: %d/%d (%s) - $%d", 
openData.Progress, openData.Requirement, openData.Subject, cost))
else
Labels.Open:Set("Open: No quest")
end

if playData then
Labels.Play:Set(string.format("Play: %d/%d (%s)", 
playData.Progress, playData.Requirement, playData.Subject))
else
Labels.Play:Set("Play: No quest")
end

if winData then
Labels.Win:Set(string.format("Win: %d/%d", winData.Progress, winData.Requirement))
else
Labels.Win:Set("Win: No quest")
end
end

--------------------------------------------------------------------------------
-- MAIN PROCESSOR
--------------------------------------------------------------------------------

local function processFeatures()
local now = tick()
local F = State.Features

if F.QuestWin or F.QuestPlay then
UISuppress.hideBattle()
end

if F.AutoSell and now >= State.Time.NextSell then
State.Time.LastSell = now
State.Time.NextSell = now + Util.randomCooldown(Config.Cooldown.SellMin, Config.Cooldown.SellMax)
task.spawn(EconomySystem.sellUnlocked)
end

-- Priority 1: Gifts
if F.ClaimGift then
local gift = GiftSystem.getNextClaimable()
if gift then
if CaseSystem.open(gift, true) then
GiftSystem.markClaimed(gift)
if gift == "Gift9" and F.RejoinOnGift9 then
task.wait(2)
ServerSystem.rejoin()
end
return true
end
end
end

-- Priority 2: Level Cases
if F.LevelCases and State.NextLevelCaseId then
if State.Time.NextLevelCase <= os.time() then
if CaseSystem.open(State.NextLevelCaseId, false, 1) then
task.delay(1, LevelSystem.updateCooldowns)
return true
end
end
end

-- Priority 3: Galaxy Cases
if F.GalaxyCase and Util.getTickets() >= Config.Threshold.GalaxyTickets then
if CaseSystem.open("StarGazingCase", false, 5, false) then
return true
end
end

-- Priority 4: Katowice Wild
if F.KatowiceWild and State.Ready.Case and Util.getBalance() > Config.Threshold.KatowiceBalance then
if CaseSystem.open("LIGHT", false, 5, true) then
return true
end
end

-- Priority 5: Quest Play Battles
if F.QuestPlay then
local playData = QuestSystem.getPlay()
if playData and playData.Remaining > 0 then
local cooldown = Util.randomCooldown(Config.Cooldown.BattleMin, Config.Cooldown.BattleMax)
if (now - State.Time.LastBattle) >= cooldown then
State.Time.LastBattle = now
BattleSystem.createBotBattle(string.upper(playData.Subject))
return true
end
end
end

-- Priority 6: Quest Win Battles
if F.QuestWin then
local winData = QuestSystem.getWin()
if winData and winData.Remaining > 0 then
local cooldown = Util.randomCooldown(Config.Cooldown.BattleMin, Config.Cooldown.BattleMax)
if (now - State.Time.LastBattle) >= cooldown then
State.Time.LastBattle = now
BattleSystem.createBotBattle("CLASSIC")
return true
end
end
end

-- Priority 7: Quest Open Cases
if F.QuestOpen then
local openData = QuestSystem.getOpen()
if openData and openData.Remaining > 0 then
local qty = math.min(5, openData.Remaining)
if CaseSystem.open(openData.Subject, false, qty, false) then
return true
end
end
end

-- Priority 8: Selected Case
if F.OpenCase and State.Case.Selected then
CaseSystem.open(State.Case.Selected, false, State.Case.Quantity, State.Case.WildMode)
end

return false
end

--------------------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------------------

-- Main processor loop (2x per second is sufficient for cooldown-based actions)
task.spawn(function()
while true do
processFeatures()
task.wait(0.5)
end
end)

-- Quest labels update loop (every 2 seconds, data changes rarely)
task.spawn(function()
while true do
updateQuestLabels()
task.wait(2)
end
end)

-- Init
if State.Features.LevelCases then
LevelSystem.updateCooldowns()
end
task.spawn(EconomySystem.claimAllIndex)
