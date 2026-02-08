--[[
    Paradise Enhancer
    Multi-instance automation for Case Paradise
    Optimized & Human-Like
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
-- UTIL & RANDOMIZATION
--------------------------------------------------------------------------------

local RNG = Random.new()

local function randomFloat(min, max)
    return RNG:NextNumber(min, max)
end

local function randomDelay(min, max)
    local delayTime = RNG:NextNumber(min, max)
    task.wait(delayTime)
    return delayTime
end

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
    OpenCase      = Remotes:WaitForChild("OpenCase"),
    CreateBattle  = Remotes:WaitForChild("CreateBattle"),
    CheckCooldown = Remotes:WaitForChild("CheckCooldown"),
    AddBot        = Remotes:WaitForChild("AddBot"),
    StartBattle   = Remotes:WaitForChild("StartBattle"),
    Sell          = Remotes:WaitForChild("Sell"),
    Exchange      = Remotes:WaitForChild("ExchangeEvent"),
    ClaimIndex    = Remotes:WaitForChild("ClaimCategoryIndex"),
}

local GiftsFolder = ReplicatedStorage:WaitForChild("Gifts")
local WildPrices  = ReplicatedStorage.Misc.WildPrices

local UI = {
    Main          = PlayerGui:WaitForChild("Main"),
    Windows       = PlayerGui:WaitForChild("Windows"),
    OpenAnimation = PlayerGui:WaitForChild("OpenAnimation"),
    Battle        = PlayerGui:WaitForChild("Battle"),
}
-- Initialize sub-references safely
UI.Inventory = UI.Windows:WaitForChild("Inventory")
UI.Index     = UI.Windows:WaitForChild("Index")

-- Suppress battle event callbacks to avoid client-side clutter
Remote.StartBattle.OnClientEvent:Connect(function() end)

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local Config = {
    Cooldown = {
        BattleMin = 14.0, BattleMax = 18.0,
        CaseMin   = 8.0,  CaseMax   = 12.0,
        SellMin   = 120.0, SellMax  = 300.0,
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
        DesertEagle_PlasmaStorm            = true,
        ButterflyKnife_Wrapped             = true,
        TitanHoloKato2014                  = true,
        SkeletonKnife_PlanetaryDevastation = true,
        Karambit_Interstellar              = true,
        ButterflyKnife_DemonHound          = true,
        AWP_IonCharge                      = true,
        Karambit_Intervention         = true,
        NomadKnife_DivineDeparture    = true,
        MotoGloves_Utopia                = true,
    },
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local State = {
    -- Feature toggles
    ClaimGift     = true,
    OpenCase      = true,
    GalaxyCase    = true,
    KatowiceWild  = true,
    QuestOpen     = true,
    QuestPlay     = true,
    QuestWin      = true,
    LevelCases    = true,
    AutoSell      = true,
    RejoinOnGift9 = true,
    MeteorWalk    = true,
    
    -- Case settings
    SelectedCase  = "DivineCase",
    CaseQuantity  = 5,
    WildMode      = false,
    CaseReady     = true,
    
    -- Timing
    LastBattle      = 0,
    NextSell        = 0,
    NextLevelCase   = math.huge,
    NextLevelCaseId = nil,
    
    -- Global Busy
    IsBusy          = false,
}

--------------------------------------------------------------------------------
-- CACHE
--------------------------------------------------------------------------------

local Cache = {
    GiftPlaytimes   = {},
    IndexCategories = {},
    Cases           = {},
}

-- Init Gift Playtimes
for i = 1, 9 do
    local id = "Gift" .. i
    local val = GiftsFolder:FindFirstChild(id)
    Cache.GiftPlaytimes[id] = val and val.Value or 0
end

-- Init Index Categories (Sorted)
do
    local categories = UI.Index.Categories:GetChildren()
    table.sort(categories, function(a, b)
        return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
    end)
    for _, child in ipairs(categories) do
        if child:IsA("StringValue") and child.Value ~= "" then
            table.insert(Cache.IndexCategories, child.Value)
        end
    end
end

-- Init Cases List
do
    for caseId, data in pairs(CasesModule) do
        if not data.AdminOnly and not caseId:match("^LEVELS?%d+$") then
            table.insert(Cache.Cases, {
                Id       = caseId,
                Name     = data.Name or caseId,
                Price    = data.Price or 0,
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
    local balance = (data.Currency == "Tickets") and getTickets() or getBalance()
    return balance >= total
end

local function formatPrice(price, currency)
    if price == 0 then return "Free" end
    local str = (price % 1 == 0) and tostring(price) or string.format("%.2f", price)
    return (currency == "Tickets") and (str .. " GINGERBREAD") or ("$" .. str)
end

--------------------------------------------------------------------------------
-- UI SUPPRESSION
--------------------------------------------------------------------------------

local suppressConn = nil

local function startSuppression()
    if suppressConn then return end

    local cam = workspace.CurrentCamera
    local openScreen = UI.OpenAnimation.CaseOpeningScreen
    local endPreview = UI.OpenAnimation.EndPreview
    
    -- Use Heartbeat to keep UI hidden during opening
    suppressConn = RunService.Heartbeat:Connect(function()
        if State.CaseReady then
            if suppressConn then
                suppressConn:Disconnect()
                suppressConn = nil
            end
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
    if UI.Battle and UI.Battle:FindFirstChild("BattleFrame") then
        UI.Battle.BattleFrame.Visible = false
    end
    UI.Main.Enabled = true
    UI.Windows.Enabled = true
end

--------------------------------------------------------------------------------
-- CASE OPENING
--------------------------------------------------------------------------------

local function openCase(caseId, isGift, qty, useWild)
    local checkId = isGift and "Gift" or caseId
    if not State.CaseReady or State.IsBusy or not canAfford(checkId, qty, useWild) then
        return false
    end
    
    State.CaseReady = false
    State.IsBusy = true
    startSuppression()
    
    -- Humanize: Small random delay before sending remote
    randomDelay(0.1, 0.3)
    
    if isGift then
        Remote.OpenCase:InvokeServer(caseId, -1, false)
    else
        Remote.OpenCase:InvokeServer(caseId, qty or 1, false, useWild or false)
    end
    
    -- Cooldown reset & Busy release
    task.delay(randomFloat(Config.Cooldown.CaseMin, Config.Cooldown.CaseMax), function()
        State.CaseReady = true
        State.IsBusy = false
    end)
    
    return true
end

--------------------------------------------------------------------------------
-- GIFTS
--------------------------------------------------------------------------------

local function isGiftClaimed(id)
    local giftVal = ClaimedGifts:FindFirstChild(id)
    return giftVal and giftVal.Value
end

local function markGiftClaimed(id)
    task.wait(1)
    local giftVal = ClaimedGifts:FindFirstChild(id)
    if giftVal then giftVal.Value = true end
    
    local rewardGift = UI.Windows.Rewards.ClaimedGifts:FindFirstChild(id)
    if rewardGift then rewardGift.Value = true end
end

local function getNextGift()
    local pt = getPlaytime()
    for i = 1, 9 do
        local id = "Gift" .. i
        if not isGiftClaimed(id) and pt >= (Cache.GiftPlaytimes[id] or math.huge) then
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
                    Remaining   = math.max(0, req.Value - prog.Value),
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
    if State.IsBusy then return end
    State.IsBusy = true
    
    randomDelay(0.2, 0.5) -- Random reaction time
    local id = Remote.CreateBattle:InvokeServer({"PERCHANCE"}, 2, mode, false)
    task.wait(randomFloat(0.8, 1.2)) -- Wait for battle creation
    if id then
        Remote.AddBot:FireServer(id, Player)
    end
    
    -- Assume busy for a minimum battle setup time
    task.delay(randomFloat(4.0, 6.0), function()
        State.IsBusy = false
    end)
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
        randomDelay(1.5, 2.5) -- Human-like spacing
    end
end

local function refreshInventoryUI()
    local win = PlayerGui:FindFirstChild("CurrentWindow")
    if not win then return end
    
    local prev = win.Value
    win.Value = "Inventory"
    task.wait(0.1)
    win.Value = prev
end

local function sellUnlocked()
    -- Exchange and claim
    Remote.Exchange:FireServer("Exchange")
    task.wait(2.0)
    Remote.Exchange:FireServer("Claim")
    task.wait(0.2)
    
    claimAllIndex()
    task.wait(0.2)
    refreshInventoryUI()
    task.wait(0.5)
    
    -- Collect sellable items
    local toSell = {}
    local invFrame = UI.Inventory:FindFirstChild("InventoryFrame")
    if invFrame and invFrame:FindFirstChild("Contents") then
        for _, frame in pairs(invFrame.Contents:GetChildren()) do
            if frame:IsA("Frame") then
                local itemId = frame:GetAttribute("ItemId")
                local locked = frame:GetAttribute("locked")
                if itemId and not locked and not Config.Whitelist[itemId] then
                    table.insert(toSell, {
                        Name     = itemId,
                        Wear     = frame.Wear.Text,
                        Stattrak = frame.Stattrak.Visible,
                        Age      = frame.Age.Value,
                    })
                end
            end
        end
    end
    
    if #toSell > 0 then
        randomDelay(0.5, 1.5) -- Hesitation before selling
        Remote.Sell:InvokeServer(toSell)
    end
end

--------------------------------------------------------------------------------
-- SERVER REJOIN
--------------------------------------------------------------------------------

local function rejoin()
    if #Players:GetPlayers() <= 1 then
        Player:Kick("\nRejoining for optimization...")
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

local function stopWalking()
    Meteor.Walking = false
    Meteor.Target = nil
end

local function walkToMeteor(targetPos)
    if Meteor.Walking then
        Meteor.Target = targetPos
        return
    end
    
    Meteor.Walking = true
    Meteor.Target = targetPos
    
    task.spawn(function()
        local hum = Player.Character and Player.Character:FindFirstChild("Humanoid")
        local root = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
        
        if not hum or not root then
            stopWalking()
            return
        end
        
        -- Start moving
        hum:MoveTo(targetPos)
        
        local lastPos = root.Position
        local stuckCount = 0
        
        while Meteor.Walking and Meteor.Target do
            hum = Player.Character and Player.Character:FindFirstChild("Humanoid")
            root = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
            if not hum or not root then break end
            
            local target = Meteor.Target
            local dist = (Vector3.new(root.Position.X, target.Y, root.Position.Z) - target).Magnitude
            if dist <= 5 then break end
            
            -- Check if stuck (Enhanced)
            local moved = (root.Position - lastPos).Magnitude
            if moved < 2 then
                stuckCount = stuckCount + 1
                if stuckCount >= 2 then
                    hum.Jump = true
                    stuckCount = 0
                end
            else
                stuckCount = 0
            end
            

            lastPos = root.Position
            
            hum:MoveTo(target)
            
            if Meteor.Target ~= target then break end
            
            task.wait(0.25)
        end
        
        stopWalking()
    end)
end

local function initMeteor()
    local temp = workspace:WaitForChild("Temp", 10)
    if not temp then return end
    
    -- Function to handle findings
    local function checkChild(child)
        if not State.MeteorWalk then return end
        
        if child.Name == "MeteorHitHitbox" then
            local hit = child:WaitForChild("Hit", 2)
            if hit then walkToMeteor(hit.Position) end
        elseif child:IsA("BasePart") and child.Name == "Hit" then
            walkToMeteor(child.Position)
        end
    end
    
    -- Check existing
    for _, child in ipairs(temp:GetChildren()) do
        checkChild(child)
    end
    
    -- Connect new
    temp.ChildAdded:Connect(checkChild)
    
    -- Cleanup
    temp.ChildRemoved:Connect(function(child)
        if child.Name ~= "MeteorHitHitbox" then return end
        task.delay(0.5, function()
            -- Double check it's strictly gone
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
        table.insert(opts, c.Name .. wild .. " " .. formatPrice(total, c.Currency))
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

-- TABS
local TabCases     = Window:CreateTab("Cases", 4483362458)
local TabQuests    = Window:CreateTab("Quests", 4483362458)
local TabAuto      = Window:CreateTab("Automation", 4483362458)

-- Tab: Cases
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
        if CaseDropdown and CaseDropdown.Refresh then
            CaseDropdown:Refresh(buildCaseOptions())
        end
        updateDropdown()
    end,
})

TabCases:CreateToggle({
    Name = "Wild Mode",
    CurrentValue = State.WildMode,
    Flag = "WildMode",
    Callback = function(v)
        State.WildMode = v
        if CaseDropdown and CaseDropdown.Refresh then
            CaseDropdown:Refresh(buildCaseOptions())
        end
        updateDropdown()
    end,
})

-- Tab: Quests
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
-- AUTO-UPDATERS
--------------------------------------------------------------------------------

-- Main Logic Loop
task.spawn(function()
    while true do
        -- Randomize tick interval slightly (0.7 to 0.9s)
        randomDelay(0.7, 0.9)
        
        -- Global Busy Check (prevents doing two things at once)
        if State.IsBusy then continue end

        local now = tick()
        
        -- 1. UI Cleanup (Non-blocking, high priority)
        if State.QuestWin or State.QuestPlay then
            hideBattleUI()
        end
        
        -- Priority 1: Selling (Takes time, should block everything else)
        if State.AutoSell and now >= State.NextSell then
            State.NextSell = now + randomFloat(Config.Cooldown.SellMin, Config.Cooldown.SellMax)
            State.IsBusy = true
            task.spawn(function()
                sellUnlocked()
                State.IsBusy = false
            end)
            continue -- Skip other actions this tick
        end
        
        -- Priority 2: Gifts (Free stuff first)
        if State.ClaimGift then
            local gift = getNextGift()
            if gift then
                -- openCase handles its own localized caching, but we need to respect global busy
                if openCase(gift, true) then
                    markGiftClaimed(gift)
                    if gift == "Gift9" and State.RejoinOnGift9 then
                         task.wait(randomFloat(2.0, 4.0))
                         rejoin()
                    end
                    continue -- Action taken
                end
            end
        end
        
        -- Priority 3: Level Cases (Rare/High Value)
        if State.LevelCases and State.NextLevelCaseId and State.NextLevelCase <= os.time() then
            if openCase(State.NextLevelCaseId, false, 1) then
                task.delay(1.0, updateLevelCooldowns)
                continue
            end
        end
        
        -- Priority 4: Katowice Wild (High Value Economy)
        if State.KatowiceWild and State.CaseReady and getBalance() > Config.Threshold.KatowiceBalance then
            if openCase("LIGHT", false, 5, true) then continue end
        end
        
        -- Priority 5: Galaxy Cases (Ticket Dump)
        if State.GalaxyCase and getTickets() >= Config.Threshold.GalaxyTickets then
            if openCase("DivineCase", false, 5, false) then continue end
        end
        
        -- Priority 6: Quest Battles (Play/Win) - SHARED COOLDOWN
        -- Only check battles if we didn't just open a case
        local battleActionTaken = false
        
        if State.QuestPlay and not battleActionTaken then
            local play = getQuestData("Play")
            if play and play.Remaining > 0 then
                local cd = randomFloat(Config.Cooldown.BattleMin, Config.Cooldown.BattleMax)
                if (now - State.LastBattle) >= cd then
                    State.LastBattle = now
                    createBotBattle(string.upper(play.Subject))
                    battleActionTaken = true
                end
            end
        end
        
        if State.QuestWin and not battleActionTaken then
            local win = getQuestData("Win")
            if win and win.Remaining > 0 then
                local cd = randomFloat(Config.Cooldown.BattleMin, Config.Cooldown.BattleMax)
                if (now - State.LastBattle) >= cd then
                    State.LastBattle = now
                    createBotBattle("CLASSIC")
                    battleActionTaken = true
                end
            end
        end
        
        if battleActionTaken then continue end
        
        -- Priority 7: Quest Openings
        if State.QuestOpen then
            local open = getQuestData("Open")
            if open and open.Remaining > 0 then
                local qty = math.min(5, open.Remaining)
                if openCase(open.Subject, false, qty, false) then continue end
            end
        end
        
        -- Priority 8: Selected Case (Filler)
        if State.OpenCase and State.SelectedCase then
            openCase(State.SelectedCase, false, State.CaseQuantity, State.WildMode)
        end
    end
end)

-- UI Update Loop (Lower frequency is fine)
task.spawn(function()
    while true do
        updateQuestLabels()
        task.wait(3.0)
    end
end)

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------

if State.LevelCases then updateLevelCooldowns() end
initMeteor()
