
-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

-- Player references
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local PlayerData = Player:WaitForChild("PlayerData")
local Currencies = PlayerData:WaitForChild("Currencies")

-- Game modules
local Modules = ReplicatedStorage:WaitForChild("Modules")
local CasesModule = require(Modules:WaitForChild("Cases"))

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local OpenCaseRemote = Remotes:WaitForChild("OpenCase")
local CreateBattleRemote = Remotes:WaitForChild("CreateBattle")
local CheckCooldownRemote = Remotes:WaitForChild("CheckCooldown")
local AddBotRemote = Remotes:WaitForChild("AddBot")
local StartBattleRemote = Remotes:WaitForChild("StartBattle")
local SellRemote = Remotes:WaitForChild("Sell")

-- Folders
local GiftsFolder = ReplicatedStorage:WaitForChild("Gifts")
local WildPrices = ReplicatedStorage:WaitForChild("Misc"):WaitForChild("WildPrices")

-- Suppress battle start events
StartBattleRemote.OnClientEvent:Connect(function() end)

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local Config = {
    BattleCooldown = { Min = 14, Max = 18 },
    CaseCooldown = { Min = 8, Max = 12 },
    SellInterval = 120,
    GalaxyTicketThreshold = 50,
    LightBalanceThreshold = 100000,
    AutoGalaxyWhenTickets = true,
}

local LevelCaseIds = {
    "LEVEL10", "LEVEL20", "LEVEL30", "LEVEL40", "LEVEL50", "LEVEL60",
    "LEVEL70", "LEVEL80", "LEVEL90", "LEVELS100", "LEVELS110", "LEVELS120"
}

local ItemWhitelist = {
    ["DesertEagle_PlasmaStorm"] = true,
    ["ButterflyKnife_Wrapped"] = true,
    ["iBUYPOWERHoloKato2014"] = true,
    ["SkeletonKnife_PlanetaryDevastation"] = true,
    ["Karambit_Interstellar"] = true,
    ["ButterflyKnife_DemonHound"] = true,
    ["AWP_IonCharge"] = true,
    
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local State = {
    -- Feature toggles
    AutoClaimGift = true,
    AutoCase = true,
    AutoGalaxyCase = true,
    AutoLightCase = true,
    AutoQuestOpen = true,
    AutoQuestPlay = true,
    AutoQuestWin = true,
    AutoLevelCases = true,
    AutoSell = true,
    AutoRejoinOnGift9 = true,
    AutoExchange = true,

    -- Case settings
    SelectedCase = "StarGazingCase",
    CaseQuantity = 5,
    WildMode = false,

    -- Timing
    LastBattleTime = 0,
    LastSellTime = 0,
    CaseReady = true,

    -- Level case tracking
    NextLevelCaseTime = math.huge,
    NextLevelCaseId = nil,
}

--------------------------------------------------------------------------------
-- Available Cases (built from game module)
--------------------------------------------------------------------------------

local AvailableCases = {}

local function isLevelCase(caseId)
    return caseId:match("^LEVELS?%d+$") ~= nil
end

local function buildAvailableCases()
    for caseId, data in pairs(CasesModule) do
        if not data.AdminOnly and not isLevelCase(caseId) then
            table.insert(AvailableCases, {
                Id = caseId,
                Name = data.Name or caseId,
                Price = data.Price or 0,
                Currency = data.Currency or "Cash",
            })
        end
    end
    
    table.sort(AvailableCases, function(a, b)
        if a.Currency == "Tickets" and b.Currency ~= "Tickets" then return true end
        if a.Currency ~= "Tickets" and b.Currency == "Tickets" then return false end
        return a.Price < b.Price
    end)
end

buildAvailableCases()

--------------------------------------------------------------------------------
-- Currency Helpers
--------------------------------------------------------------------------------

local function getBalance()
    return Currencies.Balance.Value
end

local function getTickets()
    return Currencies.Tickets.Value
end

local function getExperience()
    return Currencies.Experience.Value
end

local function getPlaytime()
    return Player.Playtime.Value
end

--------------------------------------------------------------------------------
-- Price Helpers
--------------------------------------------------------------------------------

local function getCasePrice(caseId)
    local data = CasesModule[caseId]
    return data and data.Price or 0
end

local function getWildPrice(caseId)
    local priceValue = WildPrices:FindFirstChild(caseId)
    return priceValue and priceValue.Value or getCasePrice(caseId)
end

local function formatPrice(price, currency)
    if price == 0 then return "Free" end
    
    local formatted = price % 1 == 0 and tostring(price) or string.format("%.2f", price)
    return currency == "Tickets" and formatted .. " GINGERBREAD" or "$" .. formatted
end

local function canAfford(caseId, quantity, useWild)
    if caseId:match("^Gift%d?$") then return true end
    
    local data = CasesModule[caseId]
    if not data then return false end
    
    local price = useWild and getWildPrice(caseId) or data.Price or 0
    if price <= 0 then return true end
    
    local totalCost = price * (quantity or 1)
    local funds = data.Currency == "Tickets" and getTickets() or getBalance()
    return funds >= totalCost
end

--------------------------------------------------------------------------------
-- UI Animation Suppression
--------------------------------------------------------------------------------

local function suppressOpenAnimation()
    local camera = workspace.CurrentCamera
    local openAnim = PlayerGui.OpenAnimation
    local main = PlayerGui.Main
    local windows = PlayerGui.Windows
    
    local connection
    connection = RunService.RenderStepped:Connect(function()
        if State.CaseReady then
            connection:Disconnect()
            return
        end
        
        camera.FieldOfView = 70
        openAnim.CaseOpeningScreen.Visible = false
        openAnim.EndPreview.Visible = false
        main.Enabled = true
        windows.Enabled = true
    end)
end

local function updateBattleUI()
    if State.AutoQuestWin or State.AutoQuestPlay then
        PlayerGui.Battle.BattleFrame.Visible = false
        PlayerGui.Main.Enabled = true
        PlayerGui.Windows.Enabled = true
    end
end

--------------------------------------------------------------------------------
-- Case Opening
--------------------------------------------------------------------------------

local function openCase(caseId, isGift, quantity, useWild)
    local checkId = isGift and "Gift" or caseId
    if not State.CaseReady or not canAfford(checkId, quantity, useWild) then
        return false
    end
    
    State.CaseReady = false
    suppressOpenAnimation()
    
    if isGift then
        OpenCaseRemote:InvokeServer(caseId, -1, false)
    else
        OpenCaseRemote:InvokeServer(caseId, quantity or 1, false, useWild or false)
    end
    
    local delay = math.random(Config.CaseCooldown.Min, Config.CaseCooldown.Max)
    task.delay(delay, function()
        State.CaseReady = true
    end)
    
    return true
end

--------------------------------------------------------------------------------
-- Gift System
--------------------------------------------------------------------------------

local function getGiftRequiredPlaytime(giftId)
    local value = GiftsFolder:FindFirstChild(giftId)
    return value and value.Value or math.huge
end

local function isGiftClaimed(giftId)
    return Player.ClaimedGifts[giftId].Value
end

local function markGiftClaimed(giftId)
    task.wait(1)
    Player.ClaimedGifts[giftId].Value = true
    PlayerGui.Windows.Rewards.ClaimedGifts[giftId].Value = true
end

local function getNextClaimableGift()
    local currentPlaytime = getPlaytime()
    for i = 1, 9 do
        local giftId = "Gift" .. i
        if not isGiftClaimed(giftId) and currentPlaytime >= getGiftRequiredPlaytime(giftId) then
            return giftId
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Quest System
--------------------------------------------------------------------------------

local function getQuestData(questType)
    local quests = PlayerData.Quests
    if not quests then return nil end
    
    for _, quest in ipairs(quests:GetChildren()) do
        if quest.Value == questType then
            local progress = quest.Progress.Value
            local requirement = quest.Requirement.Value
            return {
                Progress = progress,
                Requirement = requirement,
                Subject = quest.Subject.Value,
                Remaining = requirement - progress,
            }
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Battle System
--------------------------------------------------------------------------------

local function createBotBattle(mode)
    local battleId = CreateBattleRemote:InvokeServer({"PERCHANCE"}, 2, mode, false)
    task.wait(1)
    AddBotRemote:FireServer(battleId, Player)
end

--------------------------------------------------------------------------------
-- Level Case System
--------------------------------------------------------------------------------

local function updateLevelCaseCooldowns()
    State.NextLevelCaseTime = math.huge
    State.NextLevelCaseId = nil
    
    local playerXP = getExperience()
    
    for _, caseId in ipairs(LevelCaseIds) do
        local data = CasesModule[caseId]
        if data and playerXP >= (data.XPRequirement or 0) then
            local cooldownEnd = CheckCooldownRemote:InvokeServer(caseId)
            if cooldownEnd < State.NextLevelCaseTime then
                State.NextLevelCaseTime = cooldownEnd
                State.NextLevelCaseId = caseId
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Exchange System
--------------------------------------------------------------------------------

local ExchangeEvent = Remotes:WaitForChild("ExchangeEvent")

-- Lit simplement le texte du bouton pour savoir quoi envoyer
local function getExchangeAction()
    return PlayerGui.Windows.Exchange.Main.Content.Information.Action.ExchangeText.Text
end

--------------------------------------------------------------------------------
-- Inventory / Selling
--------------------------------------------------------------------------------

local function refreshInventoryUI()
    local currentWindow = PlayerGui:FindFirstChild("CurrentWindow")
    local previous = currentWindow.Value
    currentWindow.Value = "Inventory"
    task.wait(0.1)
    currentWindow.Value = previous
end

local function sellUnlockedItems()
    -- Exchange AVANT la vente
    if State.AutoExchange then
        local actionType = getExchangeAction()
        ExchangeEvent:FireServer(actionType)
        task.wait(0.1)
        
        -- Claim Galaxy category
        local args = {"Galaxy"}
        game:GetService("ReplicatedStorage"):WaitForChild("Remotes"):WaitForChild("ClaimCategoryIndex"):FireServer(unpack(args))
        task.wait(0.1)
    end

    -- Refresh l'inventaire pour avoir les données à jour
    refreshInventoryUI()
    
    local contents = PlayerGui.Windows.Inventory.InventoryFrame.Contents

    -- Vendre tout sauf whitelist
    local toSell = {}
    for _, frame in pairs(contents:GetChildren()) do
        if frame:IsA("Frame") then
            local itemId = frame:GetAttribute("ItemId")
            local locked = frame:GetAttribute("locked")

            if itemId and not locked and not ItemWhitelist[itemId] then
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
        SellRemote:InvokeServer(toSell)
    end
end

--------------------------------------------------------------------------------
-- Server Rejoin
--------------------------------------------------------------------------------

local function rejoinServer()
    if #Players:GetPlayers() <= 1 then
        Player:Kick("\nRejoining...")
        task.wait()
        TeleportService:Teleport(game.PlaceId, Player)
    else
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, Player)
    end
end

local function joinSpecificPlayer(targetUserId)
    local HttpService = game:GetService("HttpService")
    
    local success, result = pcall(function()
        return HttpService:JSONDecode(game:HttpGet(
            "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"
        ))
    end)
    
    if success and result.data then
        for _, server in pairs(result.data) do
            for _, playerId in pairs(server.playerIds or {}) do
                if playerId == targetUserId then
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, Player)
                    return true
                end
            end
        end
    end
    
    -- Si le joueur n'est pas trouvé, rejoindre normalement
    rejoinServer()
    return false
end

--------------------------------------------------------------------------------
-- UI Setup (Rayfield)
--------------------------------------------------------------------------------

local Rayfield = loadstring(game:HttpGet('https://raw.githubusercontent.com/spint990/ParadiseEnhancer/refs/heads/main/Rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "Auto Case & Gifts Helper",
    LoadingTitle = "Paradise Enhancer",
    LoadingSubtitle = "by Backlyne",
    Theme = "Default",
    ToggleUIKeybind = "K",
})

-- Build dropdown options
local function buildCaseOptions()
    local options = {}
    for _, caseData in ipairs(AvailableCases) do
        local unitPrice = State.WildMode and getWildPrice(caseData.Id) or caseData.Price
        local totalPrice = unitPrice * State.CaseQuantity
        local wildTag = State.WildMode and " (Wild)" or ""
        table.insert(options, caseData.Name .. wildTag .. " " .. formatPrice(totalPrice, caseData.Currency))
    end
    return options
end

local function updateDropdownSelection(dropdown)
    for _, caseData in ipairs(AvailableCases) do
        if caseData.Id == State.SelectedCase then
            local unitPrice = State.WildMode and getWildPrice(caseData.Id) or caseData.Price
            local wildTag = State.WildMode and " (Wild)" or ""
            dropdown:Set(caseData.Name .. wildTag .. " " .. formatPrice(unitPrice * State.CaseQuantity, caseData.Currency))
            break
        end
    end
end

-- UI element references
local Toggles = {}
local Labels = {}
local CaseDropdown

-- Cases Tab
local TabCases = Window:CreateTab("Cases", 4483362458)
TabCases:CreateSection("Case Auto-Opener")

TabCases:CreateButton({
    Name = "Join Player (8063800571)",
    Callback = function()
        joinSpecificPlayer(8063800571)
    end,
})

Toggles.AutoCase = TabCases:CreateToggle({
    Name = "Enable Auto Case Opening (Selected Case)",
    CurrentValue = true,
    Flag = "AutoCaseOpen",
    Callback = function(value)
        State.AutoCase = value
    end,
})

CaseDropdown = TabCases:CreateDropdown({
    Name = "Case to Open",
    Options = buildCaseOptions(),
    CurrentOption = {"Star Gazing Case" .. formatPrice(State.CaseQuantity * 10, "Tickets")},
    MultipleOptions = false,
    Flag = "SelectedCase",
    Callback = function(option)
        local optionName = type(option) == "table" and option[1] or option
        for _, caseData in ipairs(AvailableCases) do
            if optionName:find(caseData.Name, 1, true) == 1 then
                State.SelectedCase = caseData.Id
                break
            end
        end
    end,
})

TabCases:CreateDropdown({
    Name = "Number of Cases to Open at Once",
    Options = {"1", "2", "3", "4", "5"},
    CurrentOption = {"5"},
    MultipleOptions = false,
    Flag = "CaseQuantity",
    Callback = function(option)
        State.CaseQuantity = tonumber(type(option) == "table" and option[1] or option) or 1
        CaseDropdown:Refresh(buildCaseOptions())
        updateDropdownSelection(CaseDropdown)
    end,
})

TabCases:CreateToggle({
    Name = "Wild Mode (Higher Cost)",
    CurrentValue = false,
    Flag = "WildMode",
    Callback = function(value)
        State.WildMode = value
        CaseDropdown:Refresh(buildCaseOptions())
        updateDropdownSelection(CaseDropdown)
    end,
})

-- Quests Tab
local TabQuests = Window:CreateTab("Quest", 4483362458)
TabQuests:CreateSection("Quest Auto-Completion")

Toggles.QuestOpen = TabQuests:CreateToggle({
    Name = "Auto Quest Open Cases",
    CurrentValue = true,
    Flag = "AutoQuestOpen",
    Callback = function(value)
        State.AutoQuestOpen = value
    end,
})

Toggles.QuestPlay = TabQuests:CreateToggle({
    Name = "Auto Quest Play Battles",
    CurrentValue = true,
    Flag = "AutoQuestPlay",
    Callback = function(value)
        State.AutoQuestPlay = value
        updateBattleUI()
    end,
})

Toggles.QuestWin = TabQuests:CreateToggle({
    Name = "Auto Quest Win Battles",
    CurrentValue = true,
    Flag = "AutoQuestWin",
    Callback = function(value)
        State.AutoQuestWin = value
        updateBattleUI()
    end,
})

TabQuests:CreateSection("Status")
Labels.OpenCases = TabQuests:CreateLabel("Open Cases: -")
Labels.PlayBattles = TabQuests:CreateLabel("Play Battles: -")
Labels.WinBattles = TabQuests:CreateLabel("Win Battles: -")

local function updateQuestLabels()
    local openData = getQuestData("Open")
    local playData = getQuestData("Play")
    local winData = getQuestData("Win")
    
    if openData then
        local cost = openData.Remaining * getCasePrice(openData.Subject)
        Labels.OpenCases:Set(string.format("Open Cases: %d/%d (%s) - Cost: %s",
            openData.Progress, openData.Requirement, openData.Subject, formatPrice(cost, "Cash")))
    else
        Labels.OpenCases:Set("Open Cases: - No quest")
    end
    
    if playData then
        Labels.PlayBattles:Set(string.format("Play Battles: %d/%d (%s)",
            playData.Progress, playData.Requirement, playData.Subject))
    else
        Labels.PlayBattles:Set("Play Battles: - No quest")
    end
    
    if winData then
        Labels.WinBattles:Set(string.format("Win Battles: %d/%d", winData.Progress, winData.Requirement))
    else
        Labels.WinBattles:Set("Win Battles: - No quest")
    end
end

-- Misc Tab
local TabMisc = Window:CreateTab("Misc", 4483362458)
TabMisc:CreateSection("Gift AutoClaiming")

Toggles.ClaimGift = TabMisc:CreateToggle({
    Name = "Auto claim gift",
    CurrentValue = true,
    Flag = "AutoClaimGift",
    Callback = function(value)
        State.AutoClaimGift = value
    end,
})

TabMisc:CreateToggle({
    Name = "Auto Rejoin when Gift9 opened",
    CurrentValue = true,
    Flag = "AutoRejoinGift9",
    Callback = function(value)
        State.AutoRejoinOnGift9 = value
    end,
})

Toggles.LevelCases = TabMisc:CreateToggle({
    Name = "Auto Open LEVEL Cases",
    CurrentValue = true,
    Flag = "AutoOpenLevelCases",
    Callback = function(value)
        State.AutoLevelCases = value
        if value then
            updateLevelCaseCooldowns()
        end
    end,
})

Toggles.AutoGalaxyCase = TabMisc:CreateToggle({
    Name = "Auto Open Star Gazing Case (50+ Tickets)",
    CurrentValue = true,
    Flag = "AutoGalaxyCase",
    Callback = function(value)
        State.AutoGalaxyCase = value
    end,
})

Toggles.AutoLightCase = TabMisc:CreateToggle({
    Name = "Auto Open Light Case Wild (Balance > 140k)",
    CurrentValue = true,
    Flag = "AutoLightCase",
    Callback = function(value)
        State.AutoLightCase = value
    end,
})

TabMisc:CreateSection("Auto Sell")

Toggles.AutoSell = TabMisc:CreateToggle({
    Name = "Auto Sell Unlocked Items every 2 minutes",
    CurrentValue = true,
    Flag = "AutoSell",
    Callback = function(value)
        State.AutoSell = value
    end,
})

TabMisc:CreateSection("Auto Exchange")

Toggles.AutoExchange = TabMisc:CreateToggle({
    Name = "Auto Exchange When Possible",
    CurrentValue = true,
    Flag = "AutoExchange",
    Callback = function(value)
        State.AutoExchange = value
    end,
})

Labels.ExchangeStatus = TabMisc:CreateLabel("Exchange Status: Checking...")

TabMisc:CreateSection("Emergency Stop")

TabMisc:CreateButton({
    Name = "STOP & RESET UI",
    Callback = function()
        -- Disable all automation
        State.AutoClaimGift = false
        State.AutoCase = false
        State.AutoQuestOpen = false
        State.AutoQuestPlay = false
        State.AutoQuestWin = false
        State.AutoLevelCases = false
        State.AutoLightCase = false
        State.AutoSell = false
        State.AutoExchange = false

        -- Update UI toggles
        Toggles.ClaimGift:Set(false)
        Toggles.AutoCase:Set(false)
        Toggles.QuestOpen:Set(false)
        Toggles.QuestPlay:Set(false)
        Toggles.QuestWin:Set(false)
        Toggles.LevelCases:Set(false)
        Toggles.AutoLightCase:Set(false)
        Toggles.AutoSell:Set(false)
        Toggles.AutoExchange:Set(false)
        
        -- Wait for case cooldown
        if not State.CaseReady then
            repeat task.wait(0.1) until State.CaseReady
        end
        
        task.wait(1)
        
        -- Reset game UI
        PlayerGui.Battle.Enabled = false
        PlayerGui.Battle.BattleFrame.Visible = true
        PlayerGui.Main.Enabled = true
        PlayerGui.Windows.Enabled = true
        workspace.CurrentCamera.FieldOfView = 70
        
        Rayfield:Notify({
            Title = "Emergency Stop",
            Content = "All automations stopped & UI reset!",
            Duration = 5,
            Image = 4483362458,
        })
    end,
})

--------------------------------------------------------------------------------
-- Main Loop
--------------------------------------------------------------------------------

RunService.Heartbeat:Connect(function()
    local now = tick()

    updateBattleUI()

    -- Auto sell (every 2 minutes)
    if State.AutoSell and now - State.LastSellTime >= Config.SellInterval then
        State.LastSellTime = now
        sellUnlockedItems()
    end

    -- Priority 1: Gifts
    if State.AutoClaimGift then
        local gift = getNextClaimableGift()
        if gift and openCase(gift, true) then
            markGiftClaimed(gift)
            
            if gift == "Gift9" and State.AutoRejoinOnGift9 then
                task.wait(2)
                rejoinServer()
                return
            end
        end
    end
    
    -- Priority 2: Level cases
    if State.AutoLevelCases and State.NextLevelCaseId and State.NextLevelCaseTime <= os.time() then
        if openCase(State.NextLevelCaseId, false, 1) then
            task.delay(1, updateLevelCaseCooldowns)
        end
    
    -- Priority 3: Galaxy cases (tickets >= 50) - Automatique
    elseif State.AutoGalaxyCase and getTickets() >= Config.GalaxyTicketThreshold then
        openCase("StarGazingCase", false, 5, false)
    
    -- Priority 4: Light cases in wild mode (balance > 140k)
    elseif State.AutoLightCase and State.CaseReady and getBalance() > Config.LightBalanceThreshold then
        openCase("KATOWICE_CHALLENGERS", false, 5, true)
    
    -- Priority 5: Play quest battles
    elseif State.AutoQuestPlay and getQuestData("Play") and getQuestData("Play").Remaining > 0 then
        local playData = getQuestData("Play")
        local cooldown = math.random(Config.BattleCooldown.Min, Config.BattleCooldown.Max)
        if now - State.LastBattleTime >= cooldown then
            State.LastBattleTime = now
            createBotBattle(string.upper(playData.Subject))
        end
    
    -- Priority 6: Win quest battles
    elseif State.AutoQuestWin and getQuestData("Win") and getQuestData("Win").Remaining > 0 then
        local winData = getQuestData("Win")
        local cooldown = math.random(Config.BattleCooldown.Min, Config.BattleCooldown.Max)
        if now - State.LastBattleTime >= cooldown then
            State.LastBattleTime = now
            createBotBattle("CLASSIC")
        end
    
    -- Priority 7: Open quest cases
    elseif State.AutoQuestOpen and getQuestData("Open") and getQuestData("Open").Remaining > 0 then
        local openData = getQuestData("Open")
        openCase(openData.Subject, false, math.min(5, openData.Remaining), false)
    
    -- Priority 8: Selected case from dropdown - Auto Case Opening (dernière priorité)
    elseif State.AutoCase and State.SelectedCase then
        openCase(State.SelectedCase, false, State.CaseQuantity, State.WildMode)
    end
    
    -- Mise à jour du statut d'échange
    if State.AutoExchange and Labels.ExchangeStatus then
        local actionType = getExchangeAction()
        Labels.ExchangeStatus:Set("Exchange Status: " .. actionType)
    end
    
    updateQuestLabels()
end)

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

if State.AutoLevelCases then
    updateLevelCaseCooldowns()
end



