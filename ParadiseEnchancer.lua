--[[
    Paradise Enhancer
    Multi-instance automation for Case Paradise
]]

--------------------------------------------------------------------------------
-- SERVICES
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TeleportService   = game:GetService("TeleportService")
local PathfindingService = game:GetService("PathfindingService")

--------------------------------------------------------------------------------
-- REFERENCES
--------------------------------------------------------------------------------

local Player       = Players.LocalPlayer
local PlayerGui    = Player:WaitForChild("PlayerGui")
local PlayerData   = Player:WaitForChild("PlayerData")
local Currencies   = PlayerData:WaitForChild("Currencies")
local Quests       = PlayerData:WaitForChild("Quests")
local ClaimedGifts = Player:WaitForChild("ClaimedGifts")
local Playtime     = Player:WaitForChild("Playtime")

local Modules     = ReplicatedStorage:WaitForChild("Modules")
local CasesModule = require(Modules:WaitForChild("Cases"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Remote = {
    OpenCase     = Remotes:WaitForChild("OpenCase"),
    CreateBattle = Remotes:WaitForChild("CreateBattle"),
    CheckCooldown = Remotes:WaitForChild("CheckCooldown"),
    AddBot       = Remotes:WaitForChild("AddBot"),
    StartBattle  = Remotes:WaitForChild("StartBattle"),
    Sell         = Remotes:WaitForChild("Sell"),
    Exchange     = Remotes:WaitForChild("ExchangeEvent"),
    ClaimIndex   = Remotes:WaitForChild("ClaimCategoryIndex"),
}

local GiftsFolder = ReplicatedStorage:WaitForChild("Gifts")
local WildPrices  = ReplicatedStorage.Misc.WildPrices

local UI = {
    Main          = PlayerGui:WaitForChild("Main"),
    Windows       = PlayerGui:WaitForChild("Windows"),
    OpenAnimation = PlayerGui:WaitForChild("OpenAnimation"),
    Battle        = PlayerGui:WaitForChild("Battle"),
}
UI.Inventory = UI.Windows.Inventory
UI.Index     = UI.Windows.Index

-- Suppress battle event callbacks
Remote.StartBattle.OnClientEvent:Connect(function() end)

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local Config = {
    Cooldown = {
        BattleMin = 14, BattleMax = 18,
        CaseMin   = 8,  CaseMax   = 12,
        SellMin   = 120, SellMax  = 300,
    },
    Threshold = {
        GalaxyTickets   = 50,
        KatowiceBalance = 140000,
    },
    LevelCases = {
        "LEVEL10", "LEVEL20", "LEVEL30", "LEVEL40", "LEVEL50", "LEVEL60",
        "LEVEL70", "LEVEL80", "LEVEL90", "LEVELS100", "LEVELS110", "LEVELS120",
    },
    Whitelist = {
        DesertEagle_PlasmaStorm       = true,
        ButterflyKnife_Wrapped        = true,
        TitanHoloKato2014             = true,
        SkeletonKnife_PlanetaryDevastation = true,
        Karambit_Interstellar         = true,
        ButterflyKnife_DemonHound     = true,
        AWP_IonCharge                 = true,
    },
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local State = {
    -- Feature toggles
    ClaimGift    = true,
    OpenCase     = true,
    GalaxyCase   = true,
    KatowiceWild = true,
    QuestOpen    = true,
    QuestPlay    = true,
    QuestWin     = true,
    LevelCases   = true,
    AutoSell     = true,
    RejoinOnGift9 = true,
    MeteorWalk   = true,
    
    -- Case settings
    SelectedCase = "DivineCase",
    CaseQuantity = 5,
    WildMode     = false,
    CaseReady    = true,
    
    -- Timing
    LastBattle   = 0,
    NextSell     = 0,
    NextLevelCase = math.huge,
    NextLevelCaseId = nil,
}

--------------------------------------------------------------------------------
-- CACHE
--------------------------------------------------------------------------------

local Cache = {
    GiftPlaytimes = {},
    IndexCategories = {},
    Cases = {},
}

-- Gift playtime requirements
for i = 1, 9 do
    local id = "Gift" .. i
    Cache.GiftPlaytimes[id] = GiftsFolder[id].Value
end

-- Index categories (sorted)
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

-- Case list (excluding admin/level cases)
do
    for caseId, data in pairs(CasesModule) do
        if not data.AdminOnly and not caseId:match("^LEVELS?%d+$") then
            Cache.Cases[#Cache.Cases + 1] = {
                Id       = caseId,
                Name     = data.Name or caseId,
                Price    = data.Price or 0,
                Currency = data.Currency or "Cash",
            }
        end
    end
    table.sort(Cache.Cases, function(a, b)
        if a.Currency == "Tickets" and b.Currency ~= "Tickets" then return true end
        if a.Currency ~= "Tickets" and b.Currency == "Tickets" then return false end
        return a.Price < b.Price
    end)
end

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function getBalance()  return Currencies.Balance.Value end
local function getTickets()  return Currencies.Tickets.Value end
local function getXP()       return Currencies.Experience.Value end
local function getPlaytime() return Playtime.Value end

local function getCasePrice(caseId)
    local data = CasesModule[caseId]
    return data and data.Price or 0
end

local function getWildPrice(caseId)
    local obj = WildPrices:FindFirstChild(caseId)
    return obj and obj.Value or getCasePrice(caseId)
end

local function canAfford(caseId, qty, useWild)
    if caseId:match("^Gift%d?$") then return true end
    local data = CasesModule[caseId]
    if not data then return false end
    
    local price = useWild and getWildPrice(caseId) or (data.Price or 0)
    if price <= 0 then return true end
    
    local total = price * (qty or 1)
    local balance = data.Currency == "Tickets" and getTickets() or getBalance()
    return balance >= total
end

local function randomDelay(min, max)
    return math.random(min, max)
end

local function formatPrice(price, currency)
    if price == 0 then return "Free" end
    local str = price % 1 == 0 and tostring(price) or string.format("%.2f", price)
    return currency == "Tickets" and (str .. " GINGERBREAD") or ("$" .. str)
end

--------------------------------------------------------------------------------
-- UI SUPPRESSION
--------------------------------------------------------------------------------

local suppressConn = nil

local function startSuppression()
    local cam = workspace.CurrentCamera
    local openScreen = UI.OpenAnimation.CaseOpeningScreen
    local endPreview = UI.OpenAnimation.EndPreview
    
    suppressConn = RunService.RenderStepped:Connect(function()
        if State.CaseReady then
            suppressConn:Disconnect()
            suppressConn = nil
            return
        end
        if cam.FieldOfView ~= 70 then cam.FieldOfView = 70 end
        openScreen.Visible = false
        endPreview.Visible = false
        UI.Main.Enabled = true
        UI.Windows.Enabled = true
    end)
end

local function hideBattleUI()
    UI.Battle.BattleFrame.Visible = false
    UI.Main.Enabled = true
    UI.Windows.Enabled = true
end

--------------------------------------------------------------------------------
-- CASE OPENING
--------------------------------------------------------------------------------

local function openCase(caseId, isGift, qty, useWild)
    local checkId = isGift and "Gift" or caseId
    if not State.CaseReady or not canAfford(checkId, qty, useWild) then
        return false
    end
    
    State.CaseReady = false
    startSuppression()
    
    if isGift then
        Remote.OpenCase:InvokeServer(caseId, -1, false)
    else
        Remote.OpenCase:InvokeServer(caseId, qty or 1, false, useWild or false)
    end
    
    task.delay(randomDelay(Config.Cooldown.CaseMin, Config.Cooldown.CaseMax), function()
        State.CaseReady = true
    end)
    return true
end

--------------------------------------------------------------------------------
-- GIFTS
--------------------------------------------------------------------------------

local function isGiftClaimed(id)
    return ClaimedGifts[id].Value
end

local function markGiftClaimed(id)
    task.wait(1)
    ClaimedGifts[id].Value = true
    UI.Windows.Rewards.ClaimedGifts[id].Value = true
end

local function getNextGift()
    local pt = getPlaytime()
    for i = 1, 9 do
        local id = "Gift" .. i
        if not isGiftClaimed(id) and pt >= Cache.GiftPlaytimes[id] then
            return id
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- QUESTS
--------------------------------------------------------------------------------

local function getQuestData(questType)
    for _, quest in ipairs(Quests:GetChildren()) do
        if quest.Value == questType then
            local prog = quest:FindFirstChild("Progress")
            local req  = quest:FindFirstChild("Requirement")
            local subj = quest:FindFirstChild("Subject")
            if prog and req then
                return {
                    Progress    = prog.Value,
                    Requirement = req.Value,
                    Subject     = subj and subj.Value or "",
                    Remaining   = req.Value - prog.Value,
                }
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- BATTLES
--------------------------------------------------------------------------------

local function createBotBattle(mode)
    local id = Remote.CreateBattle:InvokeServer({"PERCHANCE"}, 2, mode, false)
    task.wait(1)
    Remote.AddBot:FireServer(id, Player)
end

--------------------------------------------------------------------------------
-- LEVEL CASES
--------------------------------------------------------------------------------

local function updateLevelCooldowns()
    State.NextLevelCase = math.huge
    State.NextLevelCaseId = nil
    local xp = getXP()
    
    for _, caseId in ipairs(Config.LevelCases) do
        local data = CasesModule[caseId]
        if data and xp >= (data.XPRequirement or 0) then
            local cooldown = Remote.CheckCooldown:InvokeServer(caseId)
            if cooldown < State.NextLevelCase then
                State.NextLevelCase = cooldown
                State.NextLevelCaseId = caseId
            end
        end
    end
end

--------------------------------------------------------------------------------
-- ECONOMY
--------------------------------------------------------------------------------

local function claimAllIndex()
    for _, cat in ipairs(Cache.IndexCategories) do
        Remote.ClaimIndex:FireServer(cat)
        task.wait(2)
    end
end

local function refreshInventoryUI()
    local win = PlayerGui.CurrentWindow
    local prev = win.Value
    win.Value = "Inventory"
    task.wait(0.1)
    win.Value = prev
end

local function sellUnlocked()
    -- Exchange and claim
    Remote.Exchange:FireServer("Exchange")
    task.wait(2)
    Remote.Exchange:FireServer("Claim")
    task.wait(0.1)
    claimAllIndex()
    task.wait(0.1)
    refreshInventoryUI()
    task.wait(0.5)
    
    -- Collect sellable items
    local toSell = {}
    for _, frame in pairs(UI.Inventory.InventoryFrame.Contents:GetChildren()) do
        if frame:IsA("Frame") then
            local itemId = frame:GetAttribute("ItemId")
            local locked = frame:GetAttribute("locked")
            if itemId and not locked and not Config.Whitelist[itemId] then
                toSell[#toSell + 1] = {
                    Name     = itemId,
                    Wear     = frame.Wear.Text,
                    Stattrak = frame.Stattrak.Visible,
                    Age      = frame.Age.Value,
                }
            end
        end
    end
    
    if #toSell > 0 then
        Remote.Sell:InvokeServer(toSell)
    end
end

--------------------------------------------------------------------------------
-- SERVER
--------------------------------------------------------------------------------

local function rejoin()
    if #Players:GetPlayers() <= 1 then
        Player:Kick("\nRejoining...")
        task.wait()
        TeleportService:Teleport(game.PlaceId, Player)
    else
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, Player)
    end
end

--------------------------------------------------------------------------------
-- METEOR WALK
--------------------------------------------------------------------------------

local Meteor = {
    Walking = false,
    Target  = nil,
}

local function getCharacter()
    return Player.Character or Player.CharacterAdded:Wait()
end

local function getHumanoid()
    local char = getCharacter()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
    local char = getCharacter()
    return char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char.PrimaryPart)
end

local function walkToMeteor(targetPos)
    if Meteor.Walking then
        Meteor.Target = targetPos
        return
    end
    
    Meteor.Walking = true
    Meteor.Target = targetPos
    
    task.spawn(function()
        local hum = getHumanoid()
        local root = getRoot()
        if not hum or not root then
            Meteor.Walking = false
            return
        end
        
        local path = PathfindingService:CreatePath({
            AgentRadius = 2,
            AgentHeight = 5,
            AgentCanJump = true,
            AgentCanClimb = false,
            WaypointSpacing = 4,
        })
        
        while Meteor.Walking and Meteor.Target do
            root = getRoot()
            hum = getHumanoid()
            if not root or not hum then break end
            
            local target = Meteor.Target
            local dist = (Vector3.new(root.Position.X, target.Y, root.Position.Z) - target).Magnitude
            if dist <= 3 then break end
            
            local ok = pcall(function()
                path:ComputeAsync(root.Position, target)
            end)
            
            if ok and path.Status == Enum.PathStatus.Success then
                for _, wp in ipairs(path:GetWaypoints()) do
                    if not Meteor.Walking or Meteor.Target ~= target then break end
                    
                    root = getRoot()
                    if not root then break end
                    
                    if wp.Action == Enum.PathWaypointAction.Jump then
                        hum.Jump = true
                    end
                    
                    hum:MoveTo(wp.Position)
                    
                    local timeout = 0
                    while timeout < 20 and Meteor.Walking do
                        root = getRoot()
                        if not root then break end
                        
                        local wpDist = (Vector3.new(root.Position.X, wp.Position.Y, root.Position.Z) - wp.Position).Magnitude
                        if wpDist <= 4 then break end
                        
                        timeout = timeout + 1
                        task.wait(0.1)
                    end
                    
                    if timeout >= 20 then break end
                end
            else
                hum:MoveTo(target)
                task.wait(0.5)
            end
            
            task.wait(0.1)
        end
        
        Meteor.Walking = false
        Meteor.Target = nil
    end)
end

local function stopWalking()
    Meteor.Walking = false
    Meteor.Target = nil
end

local function initMeteor()
    local temp = workspace:WaitForChild("Temp", 10)
    if not temp then return end
    
    -- Handle existing hitboxes
    for _, child in ipairs(temp:GetChildren()) do
        if child.Name == "MeteorHitHitbox" and State.MeteorWalk then
            local hit = child:FindFirstChild("Hit")
            if hit then walkToMeteor(hit.Position) end
        end
    end
    
    -- New hitboxes
    temp.ChildAdded:Connect(function(child)
        if not State.MeteorWalk then return end
        if child.Name == "MeteorHitHitbox" then
            local hit = child:WaitForChild("Hit", 2)
            if hit then walkToMeteor(hit.Position) end
        elseif child:IsA("BasePart") and child.Name == "Hit" then
            walkToMeteor(child.Position)
        end
    end)
    
    -- Hitbox removed
    temp.ChildRemoved:Connect(function(child)
        if child.Name ~= "MeteorHitHitbox" then return end
        task.delay(0.5, function()
            for _, c in ipairs(temp:GetChildren()) do
                if c.Name == "MeteorHitHitbox" then return end
            end
            stopWalking()
        end)
    end)
end

--------------------------------------------------------------------------------
-- UI (RAYFIELD)
--------------------------------------------------------------------------------

local Rayfield = loadstring(game:HttpGet('https://raw.githubusercontent.com/spint990/ParadiseEnhancer/refs/heads/main/Rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "Paradise Enhancer",
    LoadingTitle = "Paradise Enhancer",
    LoadingSubtitle = "by Backlyne",
    Theme = "Default",
    ToggleUIKeybind = "K",
})

local CaseDropdown
local Labels = {}

local function buildCaseOptions()
    local opts = {}
    for _, c in ipairs(Cache.Cases) do
        local price = State.WildMode and getWildPrice(c.Id) or c.Price
        local total = price * State.CaseQuantity
        local wild = State.WildMode and " (Wild)" or ""
        opts[#opts + 1] = c.Name .. wild .. " " .. formatPrice(total, c.Currency)
    end
    return opts
end

local function updateDropdown()
    for _, c in ipairs(Cache.Cases) do
        if c.Id == State.SelectedCase then
            local price = State.WildMode and getWildPrice(c.Id) or c.Price
            local wild = State.WildMode and " (Wild)" or ""
            CaseDropdown:Set(c.Name .. wild .. " " .. formatPrice(price * State.CaseQuantity, c.Currency))
            break
        end
    end
end

-- Tab: Cases
local TabCases = Window:CreateTab("Cases", 4483362458)
TabCases:CreateSection("Case Opening")

TabCases:CreateToggle({
    Name = "Auto Open",
    CurrentValue = State.OpenCase,
    Flag = "AutoCaseOpen",
    Callback = function(v) State.OpenCase = v end,
})

CaseDropdown = TabCases:CreateDropdown({
    Name = "Select Case",
    Options = buildCaseOptions(),
    CurrentOption = {"Divine Case " .. formatPrice(State.CaseQuantity * 10, "Tickets")},
    MultipleOptions = false,
    Flag = "SelectedCase",
    Callback = function(opt)
        local name = type(opt) == "table" and opt[1] or opt
        for _, c in ipairs(Cache.Cases) do
            if name:find(c.Name, 1, true) == 1 then
                State.SelectedCase = c.Id
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
    Callback = function(opt)
        State.CaseQuantity = tonumber(type(opt) == "table" and opt[1] or opt) or 1
        CaseDropdown:Refresh(buildCaseOptions())
        updateDropdown()
    end,
})

TabCases:CreateToggle({
    Name = "Wild Mode",
    CurrentValue = State.WildMode,
    Flag = "WildMode",
    Callback = function(v)
        State.WildMode = v
        CaseDropdown:Refresh(buildCaseOptions())
        updateDropdown()
    end,
})

-- Tab: Quests
local TabQuests = Window:CreateTab("Quests", 4483362458)
TabQuests:CreateSection("Quest Automation")

TabQuests:CreateToggle({
    Name = "Open Cases",
    CurrentValue = State.QuestOpen,
    Flag = "AutoQuestOpen",
    Callback = function(v) State.QuestOpen = v end,
})

TabQuests:CreateToggle({
    Name = "Play Battles",
    CurrentValue = State.QuestPlay,
    Flag = "AutoQuestPlay",
    Callback = function(v)
        State.QuestPlay = v
        if v then hideBattleUI() end
    end,
})

TabQuests:CreateToggle({
    Name = "Win Battles",
    CurrentValue = State.QuestWin,
    Flag = "AutoQuestWin",
    Callback = function(v)
        State.QuestWin = v
        if v then hideBattleUI() end
    end,
})

TabQuests:CreateSection("Progress")
Labels.Open = TabQuests:CreateLabel("Open: -")
Labels.Play = TabQuests:CreateLabel("Play: -")
Labels.Win  = TabQuests:CreateLabel("Win: -")

-- Tab: Automation
local TabAuto = Window:CreateTab("Automation", 4483362458)
TabAuto:CreateSection("Gifts")

TabAuto:CreateToggle({
    Name = "Claim Gifts",
    CurrentValue = State.ClaimGift,
    Flag = "AutoClaimGift",
    Callback = function(v) State.ClaimGift = v end,
})

TabAuto:CreateToggle({
    Name = "Rejoin on Gift 9",
    CurrentValue = State.RejoinOnGift9,
    Flag = "AutoRejoinGift9",
    Callback = function(v) State.RejoinOnGift9 = v end,
})

TabAuto:CreateSection("Special Cases")

TabAuto:CreateToggle({
    Name = "Level Cases",
    CurrentValue = State.LevelCases,
    Flag = "AutoOpenLevelCases",
    Callback = function(v)
        State.LevelCases = v
        if v then updateLevelCooldowns() end
    end,
})

TabAuto:CreateToggle({
    Name = "Galaxy (50+ Tickets)",
    CurrentValue = State.GalaxyCase,
    Flag = "AutoGalaxyCase",
    Callback = function(v) State.GalaxyCase = v end,
})

TabAuto:CreateToggle({
    Name = "Katowice Wild (140k+)",
    CurrentValue = State.KatowiceWild,
    Flag = "AutoKatowiceCase",
    Callback = function(v) State.KatowiceWild = v end,
})

TabAuto:CreateSection("Economy")

TabAuto:CreateToggle({
    Name = "Sell Items",
    CurrentValue = State.AutoSell,
    Flag = "AutoSell",
    Callback = function(v) State.AutoSell = v end,
})

TabAuto:CreateSection("Events")

TabAuto:CreateToggle({
    Name = "Meteor Walk",
    CurrentValue = State.MeteorWalk,
    Flag = "AutoMeteorWalk",
    Callback = function(v)
        State.MeteorWalk = v
        if not v then stopWalking() end
    end,
})

--------------------------------------------------------------------------------
-- QUEST LABELS UPDATE
--------------------------------------------------------------------------------

local function updateQuestLabels()
    local open = getQuestData("Open")
    local play = getQuestData("Play")
    local win  = getQuestData("Win")
    
    if open then
        local cost = open.Remaining * getCasePrice(open.Subject)
        Labels.Open:Set(string.format("%d/%d %s ($%d)", open.Progress, open.Requirement, open.Subject, cost))
    else
        Labels.Open:Set("None")
    end
    
    if play then
        Labels.Play:Set(string.format("%d/%d %s", play.Progress, play.Requirement, play.Subject))
    else
        Labels.Play:Set("None")
    end
    
    if win then
        Labels.Win:Set(string.format("%d/%d wins", win.Progress, win.Requirement))
    else
        Labels.Win:Set("None")
    end
end

--------------------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------------------

local function tick_now() return tick() end

local function process()
    local now = tick_now()
    
    -- Hide battle UI if needed
    if State.QuestWin or State.QuestPlay then
        hideBattleUI()
    end
    
    -- Auto sell on interval
    if State.AutoSell and now >= State.NextSell then
        State.NextSell = now + randomDelay(Config.Cooldown.SellMin, Config.Cooldown.SellMax)
        task.spawn(sellUnlocked)
    end
    
    -- P1: Gifts
    if State.ClaimGift then
        local gift = getNextGift()
        if gift and openCase(gift, true) then
            markGiftClaimed(gift)
            if gift == "Gift9" and State.RejoinOnGift9 then
                task.wait(2)
                rejoin()
            end
            return
        end
    end
    
    -- P2: Level Cases
    if State.LevelCases and State.NextLevelCaseId and State.NextLevelCase <= os.time() then
        if openCase(State.NextLevelCaseId, false, 1) then
            task.delay(1, updateLevelCooldowns)
            return
        end
    end
    
    -- P3: Galaxy Cases
    if State.GalaxyCase and getTickets() >= Config.Threshold.GalaxyTickets then
        if openCase("DivineCase", false, 5, false) then return end
    end
    
    -- P4: Katowice Wild
    if State.KatowiceWild and State.CaseReady and getBalance() > Config.Threshold.KatowiceBalance then
        if openCase("LIGHT", false, 5, true) then return end
    end
    
    -- P5: Quest Play
    if State.QuestPlay then
        local play = getQuestData("Play")
        if play and play.Remaining > 0 then
            local cd = randomDelay(Config.Cooldown.BattleMin, Config.Cooldown.BattleMax)
            if (now - State.LastBattle) >= cd then
                State.LastBattle = now
                createBotBattle(string.upper(play.Subject))
                return
            end
        end
    end
    
    -- P6: Quest Win
    if State.QuestWin then
        local win = getQuestData("Win")
        if win and win.Remaining > 0 then
            local cd = randomDelay(Config.Cooldown.BattleMin, Config.Cooldown.BattleMax)
            if (now - State.LastBattle) >= cd then
                State.LastBattle = now
                createBotBattle("CLASSIC")
                return
            end
        end
    end
    
    -- P7: Quest Open
    if State.QuestOpen then
        local open = getQuestData("Open")
        if open and open.Remaining > 0 then
            local qty = math.min(5, open.Remaining)
            if openCase(open.Subject, false, qty, false) then return end
        end
    end
    
    -- P8: Selected Case
    if State.OpenCase and State.SelectedCase then
        openCase(State.SelectedCase, false, State.CaseQuantity, State.WildMode)
    end
end

-- Main loop (0.5s interval)
task.spawn(function()
    while true do
        process()
        task.wait(0.5)
    end
end)

-- Quest label update (2s interval)
task.spawn(function()
    while true do
        updateQuestLabels()
        task.wait(2)
    end
end)

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------

if State.LevelCases then updateLevelCooldowns() end
task.spawn(claimAllIndex)
initMeteor()
