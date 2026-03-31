--[[
    Paradise Enhancer (Refactored)
    Executor: Volt
    Optimized & Human-Like
    NO CONFIG SAVING
]]

--------------------------------------------------------------------------------
-- SERVICES & ARGS
--------------------------------------------------------------------------------
if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(15) -- Ajout sécurité chargement

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TeleportService   = game:GetService("TeleportService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local Player       = Players.LocalPlayer
local PlayerGui    = Player:WaitForChild("PlayerGui")
local PlayerData   = Player:WaitForChild("PlayerData")
local Currencies   = PlayerData:WaitForChild("Currencies")
local Quests       = PlayerData:WaitForChild("Quests")
local CalendarQuests = PlayerData:WaitForChild("CalendarQuests")
local ClaimedGifts = Player:WaitForChild("ClaimedGifts")
local Playtime     = Player:WaitForChild("Playtime")
local Inventory    = PlayerData:WaitForChild("Inventory")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Remote_OpenCase      = Remotes:WaitForChild("OpenCase")
local Remote_CreateBattle  = Remotes:WaitForChild("CreateBattle")
local Remote_CheckCooldown = Remotes:WaitForChild("CheckCooldown")
local Remote_AddBot        = Remotes:WaitForChild("AddBot")
local Remote_StartBattle   = Remotes:WaitForChild("StartBattle")
local Remote_Sell          = Remotes:WaitForChild("Sell")
local Remote_CreateMatch      = Remotes:WaitForChild("CreateMatch")
local Remote_RollDice         = Remotes:WaitForChild("RollDice")
local Remote_Upgrade          = Remotes:WaitForChild("Upgrade")
local Remote_AddBotCoinFlip   = Remotes:WaitForChild("AddBotCoinFlip")



local Modules     = ReplicatedStorage:WaitForChild("Modules")
local CasesModule = require(Modules:WaitForChild("Cases"))
local ItemsModule = require(Modules:WaitForChild("Items"))
local GiftsFolder = ReplicatedStorage:WaitForChild("Gifts")
local WildPrices  = ReplicatedStorage:WaitForChild("Misc"):WaitForChild("WildPrices")

local UI_Main          = PlayerGui:WaitForChild("Main")
local UI_Windows       = PlayerGui:WaitForChild("Windows")
local UI_OpenAnimation = PlayerGui:WaitForChild("OpenAnimation")
local UI_Battle        = PlayerGui:WaitForChild("Battle")
local UI_Inventory     = UI_Windows:WaitForChild("Inventory")
local UI_DiceRoll      = UI_Windows:WaitForChild("DiceRoll")
local UI_Upgrader      = UI_Windows:WaitForChild("Upgrader")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
-- No config saving, purely runtime state
local Config = {
    AutoOpenCase      = false,
    AutoClaimGift     = true,
    AutoQuestOpen     = true,
    AutoQuestPlay     = true,
    AutoQuestWin      = true,
    AutoLevelCases    = true,
    AutoTicketCase    = true,  -- >50 Tickets
    AutoLightCase     = true,  -- >140k Money
    AutoSell          = true,
    AutoMeteor        = true,
    RejoinOnGift9     = true,
    AutoCalendarQuest = true,
    AutoUpgrader      = true,
    SelectedCase      = "DangerCase",
    CaseQuantity      = 5,
    WildMode          = false, 
}

-- Whitelist lookup table for O(1) checking
local Whitelist = {
    ["DesertEagle_PlasmaStorm"]            = true,
    ["ButterflyKnife_Wrapped"]             = true,
    ["TitanHoloKato2014"]                  = true,
    ["SkeletonKnife_PlanetaryDevastation"] = true,
    ["Karambit_Interstellar"]              = true,
    ["ButterflyKnife_DemonHound"]          = true,
    ["AWP_IonCharge"]                      = true,
    ["Karambit_Intervention"]              = true,
    ["NomadKnife_DivineDeparture"]         = true,
    ["MotoGloves_Utopia"]                  = true,
    ["ButterflyKnife_ValentineWrapped"]    = true,
    ["FAMAS_Diamonds"]                     = true,
    ["AWP_EvilSon"]                        = true,
    ["SSG08_ToxicWaste"] = true,
    ["HunterKnife_Ammonia"] = true,
    ["ButterflyKnife_RadioactiveActivation"] = true,
    ["AWP_OozingToxicity"] = true,
    ["AUG_BlackVoid"] = true,
    ["AK47_Sweetheart"] = true,
    ["FalchionKnife_CelestialIntervention"] = true,
    ["HuntsmanKnife_BiologicalHazard"] = true,
}

--------------------------------------------------------------------------------
-- RUNTIME STATE
--------------------------------------------------------------------------------
local State = {
    IsBusy = false,
    CaseReady = true,
    NextSell = 0,
    NextLevelCase = 9e9, -- math.huge
    NextLevelCaseId = nil,
    LastBattle = 0,
    LevelFailures = {},
}

local Cache_Cases = {} -- Stores case info for dropdown


--------------------------------------------------------------------------------
-- FUNCTIONS (DIRECT)
--------------------------------------------------------------------------------

local function GetBalance()  return Currencies.Balance.Value end
local function GetTickets()  return Currencies.Tickets.Value end
local function GetXP()       return Currencies.Experience.Value end
local function GetPlaytime() return Playtime.Value end

local function FormatPrice(price, currency)
    if price == 0 then return "Free" end
    -- simplified formatting for UI
    return (currency == "Tickets" and (price.." GINGERBREAD") or ("$"..price))
end

local function GetWildPrice(caseId)
    local obj = WildPrices:FindFirstChild(caseId)
    if obj then return obj.Value end
    local data = CasesModule[caseId]
    return data and data.Price or 0
end

-- Populate Cache
for caseId, data in pairs(CasesModule) do
    if not data.AdminOnly and not caseId:find("^LEVEL") then
        table.insert(Cache_Cases, {
            Id       = caseId,
            Name     = data.Name or caseId,
            Price    = data.Price or 0,
            Currency = data.Currency or "Cash",
        })
    end
end
table.sort(Cache_Cases, function(a, b)
    if a.Currency == "Tickets" and b.Currency ~= "Tickets" then return true end
    if a.Currency ~= "Tickets" and b.Currency == "Tickets" then return false end
    return a.Price < b.Price
end)


local function SuppressAnimation()
    if not State.CaseReady then
        local cam = workspace.CurrentCamera
        cam.FieldOfView = 70
        UI_OpenAnimation.CaseOpeningScreen.Visible = false
        UI_OpenAnimation.EndPreview.Visible = false
        UI_Main.Enabled = true
        UI_Windows.Enabled = true
    end
end
RunService.Heartbeat:Connect(SuppressAnimation)




local function UpdateLevelCooldowns()
    State.NextLevelCase = 9e9
    State.NextLevelCaseId = nil
    
    local now = workspace:GetServerTimeNow()
    local xp = GetXP()
    local levelCases = {
        "LEVELS120", "LEVELS110", "LEVELS100", "LEVEL90", "LEVEL80", "LEVEL70",
        "LEVEL60", "LEVEL50", "LEVEL40", "LEVEL30", "LEVEL20", "LEVEL10"
    }

    for _, caseId in ipairs(levelCases) do
        -- Skip recently failed cases (15s cooldown on failures)
        if State.LevelFailures[caseId] and (now - State.LevelFailures[caseId] < 15) then
            -- print("[DEBUG] Skipping failed case:", caseId)
            continue
        end

        local data = CasesModule[caseId]
        if data and xp >= (data.XPRequirement or 0) then            
            local remaining = Remote_CheckCooldown:InvokeServer(caseId)
            local cooldownEnd

            if remaining then
                if type(remaining) == "number" and remaining > 1000000000 then
                     cooldownEnd = remaining
                elseif type(remaining) == "number" then
                     cooldownEnd = now + remaining
                else
                     -- Fallback for non-number truthy value? Assume wait.
                     cooldownEnd = now + 999
                end
            else
                 -- ready
                 cooldownEnd = now
            end

            -- Update optimal case
            if cooldownEnd < State.NextLevelCase then
                State.NextLevelCase = cooldownEnd
                State.NextLevelCaseId = caseId
            end
        end
    end
end
-- Initial check
task.spawn(UpdateLevelCooldowns)




local function OpenCase(caseId, isGift, qty, useWild)
    local key = isGift and "Gift" or caseId
    State.CaseReady = false
    State.IsBusy = true

    local result
    if isGift then
        result = Remote_OpenCase:InvokeServer(caseId, -1, false)
    else
        result = Remote_OpenCase:InvokeServer(caseId, qty or 1, false, useWild or false)
    end
    
    local success = (type(result) == "table" and next(result))
    
    if not success then
        if caseId:find("^LEVEL") then
            State.LevelFailures[caseId] = workspace:GetServerTimeNow()
            
            State.NextLevelCase = 9e9
            State.NextLevelCaseId = nil
            task.spawn(UpdateLevelCooldowns)
        end
    end

    -- Cooldown reset
    task.delay(math.random(8, 10), function()
        State.CaseReady = true
        State.IsBusy = false
    end)
    
    UI_Main.Enabled = true
    UI_Windows.Enabled = true
    
    return success
end

local function HideBattleUI()
    if UI_Battle:FindFirstChild("BattleFrame") then
        UI_Battle.BattleFrame.Visible = false
    end
    UI_Main.Enabled = true
    UI_Windows.Enabled = true
end

local BattlesFolder = ReplicatedStorage:WaitForChild("Battles")

local function FindPlayerBattle()
    for _, battle in ipairs(BattlesFolder:GetChildren()) do
        local players = battle:FindFirstChild("Players")
        if players then
            for _, p in ipairs(players:GetChildren()) do
                if p.Name == Player.Name then
                    return tonumber(battle.Name)
                end
            end
        end
    end
    return nil
end

local function CreateBattle(mode)
    if State.IsBusy then return end
    State.IsBusy = true
    
    mode = string.upper(mode)
    Remote_CreateBattle:InvokeServer({"PERCHANCE"}, 2, mode, false)

    task.wait(math.random() * 0.8 + 1.2)

    local battleId = FindPlayerBattle()
    if battleId then
        Remote_AddBot:FireServer(battleId, Player)
    end
    
    task.wait(math.random() * 0.2 + 0.3)
    UI_Main.Enabled = true
    UI_Windows.Enabled = true
    
    task.delay(math.random(13.5, 15.5), function()
        State.IsBusy = false
    end)
end

local function SellItems()
    -- First, trigger inventory rendering by setting CurrentWindow to "Inventory"
    local currentWindow = PlayerGui:FindFirstChild("CurrentWindow")
    if currentWindow then
        local prevWindow = currentWindow.Value
        currentWindow.Value = "Inventory"
        task.wait(0.1) -- Wait for inventory to render
    end

    local toSell = {}
    local inventoryFrame = UI_Inventory:FindFirstChild("InventoryFrame")
    if inventoryFrame then
        local contents = inventoryFrame:FindFirstChild("Contents")
        if contents then
            for _, frame in ipairs(contents:GetChildren()) do
                if frame:IsA("Frame") then
                    local itemId = frame:GetAttribute("ItemId")
                    local locked = frame:GetAttribute("locked")
                    
                    -- Check if item is not locked and not in whitelist
                    if itemId and locked ~= true and not Whitelist[itemId] then
                        -- Get UUID from attribute "UUIData" (not from a Value object)
                        local uuid = frame:GetAttribute("UUIData")
                        local wear = frame:FindFirstChild("Wear")
                        local stattrak = frame:FindFirstChild("Stattrak")
                        local age = frame:FindFirstChild("Age")
                        
                        if uuid and wear then
                            table.insert(toSell, {
                                Name     = itemId,
                                Wear     = wear.Text,
                                Stattrak = stattrak and stattrak.Visible or false,
                                Age      = age and age.Value or 0,
                                UUID     = uuid,
                            })
                        end
                    end
                end
            end
        end
    end
    
    if #toSell > 0 then
        Remote_Sell:InvokeServer(toSell)
    end
end


local Meteor = { Walking = false, Target = nil }

local function StopMeteorWalk()
    Meteor.Walking = false
    Meteor.Target = nil
end

local function WalkTo(targetPos)
    if Meteor.Walking then
        Meteor.Target = targetPos
        return
    end
    
    Meteor.Walking = true
    Meteor.Target = targetPos
    
    task.spawn(function()
        local char = Player.Character
        local hum = char and char:FindFirstChild("Humanoid")
        
        while Meteor.Walking and Meteor.Target and char and hum do
            hum:MoveTo(Meteor.Target)
            
            local root = char.HumanoidRootPart
            if (Vector3.new(root.Position.X, Meteor.Target.Y, root.Position.Z) - Meteor.Target).Magnitude < 5 then
                break
            end
            
            task.wait(0.25)
            char = Player.Character -- refresh ref
            hum = char and char:FindFirstChild("Humanoid")
        end
        StopMeteorWalk()
    end)
end

local function InitMeteor()
    local temp = workspace:WaitForChild("Temp", 5)
    if not temp then return end

    local function check(child)
        if not Config.AutoMeteor then return end
        if child.Name == "MeteorHitHitbox" then
            local hit = child:FindFirstChild("Hit") 
            if hit then WalkTo(hit.Position) end
        elseif child.Name == "Hit" and child:IsA("BasePart") then
            WalkTo(child.Position)
        end
    end

    temp.ChildAdded:Connect(check)
    for _, c in ipairs(temp:GetChildren()) do check(c) end
    
    temp.ChildRemoved:Connect(function(child)
        if child.Name == "MeteorHitHitbox" then
            StopMeteorWalk()
        end
    end)
end
task.spawn(InitMeteor)


local function Rejoin()
    if #Players:GetPlayers() <= 1 then

        Player:Kick("Rejoining...")
        task.wait()
        TeleportService:Teleport(game.PlaceId, Player)
    else

        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, Player)
    end
end

local function GetQuest(qType)
    for _, q in ipairs(Quests:GetChildren()) do
        if q.Value == qType then
            local p = q.Progress.Value
            local r = q.Requirement.Value
            return {
                Progress = p,
                Requirement = r,
                Subject = q.Subject.Value,
                Remaining = r - p
            }
        end
    end
end

local function GetCalendarQuests()
    local quests = {}
    for i = 1, 5 do
        local q = CalendarQuests:FindFirstChild(tostring(i))
        if q then
            local p = q.Progress.Value
            local r = q.Requirement.Value
            table.insert(quests, {
                Id = i,
                Type = q.Value,
                Progress = p,
                Requirement = r,
                Subject = q.Subject.Value,
                Remaining = r - p,
                Reward = q.Reward.Value
            })
        end
    end
    return quests
end

local DiceRollsFolder = ReplicatedStorage:WaitForChild("DiceRolls")

local function FindPlayerDiceRoll()
    for _, match in ipairs(DiceRollsFolder:GetChildren()) do
        local players = match:FindFirstChild("Players")
        if players then
            for _, p in ipairs(players:GetChildren()) do
                if p.Name == Player.Name then
                    return match.Name
                end
            end
        end
    end
    return nil
end

local function PlayDiceRoll()
    if State.IsBusy then return end
    State.IsBusy = true
    
    Remote_CreateMatch:FireServer("Dice Roll", "1")
    
    UI_DiceRoll.Visible = false
    UI_Main.Enabled = true
    UI_Main.ActionBar.Visible = true
    UI_Main.Currencies.Visible = true
    UI_Main.SidePanel.Visible = true

    task.wait(math.random(1.0, 3.0))
    
    local matchId = FindPlayerDiceRoll()
    if matchId then
        Remote_RollDice:FireServer(matchId, 3)
    end
    
    UI_DiceRoll.Visible = false
    UI_Main.Enabled = true
    UI_Main.ActionBar.Visible = true
    UI_Main.Currencies.Visible = true
    UI_Main.SidePanel.Visible = true

    task.delay(math.random(12, 15), function()
        State.IsBusy = false
    end)
end

local CoinflipFolder = ReplicatedStorage:WaitForChild("Coinflip")

local function FindPlayerCoinflip()
    for _, match in ipairs(CoinflipFolder:GetChildren()) do
        local players = match:FindFirstChild("Players")
        if players then
            for _, p in ipairs(players:GetChildren()) do
                if p.Name == Player.Name then
                    return match.Name
                end
            end
        end
    end
    return nil
end

local function PlayCoinflip()
    if State.IsBusy then return end
    State.IsBusy = true
    
    Remote_CreateMatch:FireServer("Coinflip", "1")
    
    task.wait(math.random(1.0, 3.0))
    
    Remote_AddBotCoinFlip:FireServer("1")
    
    task.delay(math.random(12, 15), function()
        State.IsBusy = false
    end)
end

local function DoUpgrade()
    if State.IsBusy then return end
    State.IsBusy = true
    
    local cheapestItem = nil
    local cheapestPrice = math.huge
    
    for _, item in ipairs(Inventory:GetChildren()) do
        if item:GetAttribute("Locked") == true then continue end
        if Whitelist[item.Name] then continue end
        
        local itemData = ItemsModule[item.Name]
        if not itemData or not itemData.Wears then continue end
        
        local wear = item:GetAttribute("Wear")
        local stattrak = item:GetAttribute("Stattrak") == true
        local uuid = item:GetAttribute("UUID")
        
        local wearData = itemData.Wears[wear]
        if not wearData then continue end
        
        local price = stattrak and (wearData.StatTrak or wearData.Normal or 0) or (wearData.Normal or 0)
        
        if price > 0 and price < cheapestPrice then
            cheapestPrice = price
            cheapestItem = {
                UUID = uuid,
                Price = price,
                ItemId = item.Name,
                Wear = wear,
                Stattrak = stattrak
            }
        end
    end
    
    if not cheapestItem then
        State.IsBusy = false
        return false
    end
    
    local targetSkin = {
        Key = "P250_FacilityDraft",
        Name = "P250 | Facility Draft",
        Stattrak = false,
        Price = 0.01,
        Wear = "Field-Tested"
    }
    
    local selectedItems = {
        {
            Price = cheapestItem.Price,
            UUID = cheapestItem.UUID
        }
    }
    
    Remote_Upgrade:FireServer(selectedItems, targetSkin)
    
    task.delay(math.random(6, 8), function()
        State.IsBusy = false
    end)
    
    return true
end



--------------------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------------------

task.spawn(function()
    while true do
        task.wait(0.1)
        if State.IsBusy then continue end
        local now = workspace:GetServerTimeNow()

        -- Disable Avatar Prompt
        pcall(function() game:GetService("CoreGui").AvatarEditorPromptsApp.Children.PromptFrame:Destroy() end)
        
        if Config.AutoQuestWin or Config.AutoQuestPlay then HideBattleUI() end

        -- 1. Auto Sell
        if Config.AutoSell and now >= State.NextSell then
            State.NextSell = now + math.random(120, 300)
            State.IsBusy = true
            task.spawn(function()
                SellItems()
                State.IsBusy = false
            end)
            continue
        end

        -- 2. Gifts
        if Config.AutoClaimGift then
            local giftId
            local pt = Playtime.Value
            
            for i=1,9 do
                local id = "Gift"..i
                local gVal = GiftsFolder:FindFirstChild(id)
                local claimed = ClaimedGifts:FindFirstChild(id)
                
                if gVal and claimed and not claimed.Value and pt >= gVal.Value then
                    giftId = id
                    break
                end
            end
            
            if giftId then
                if OpenCase(giftId, true) then
                    if giftId == "Gift9" and Config.RejoinOnGift9 then
                        task.wait(math.random(1, 3))
                        Rejoin()
                    end
                    continue
                end
            end
        end

        -- 3. Level Cases
        if Config.AutoLevelCases and State.NextLevelCaseId and now >= State.NextLevelCase then
           if OpenCase(State.NextLevelCaseId, false, 1) then
               task.delay(1, UpdateLevelCooldowns)
               continue
           end
        end

        -- 4. High Value Logic
        if State.CaseReady and not State.IsBusy then
            if Config.AutoLightCase and GetBalance() > 140000 then
                if OpenCase("LIGHT", false, 5, true) then continue end
            end
            if Config.AutoTicketCase and GetTickets() >= 50 then
                if OpenCase("BloodCase", false, 5, false) then continue end
            end
        end

        -- 5. Calendar Quests (Open & Play & Win Dice Roll)
        if Config.AutoCalendarQuest and State.CaseReady and not State.IsBusy then
            local calQuests = GetCalendarQuests()
            local didCalQuest = false
            for _, cq in ipairs(calQuests) do
                if cq.Remaining > 0 and not didCalQuest and State.CaseReady then
                    if cq.Type == "Open" then
                        local qty = (cq.Remaining > 5) and 5 or cq.Remaining
                        if OpenCase(cq.Subject, false, qty, false) then
                            didCalQuest = true
                        end
                    elseif cq.Type == "Play" then
                        State.LastBattle = now
                        CreateBattle(cq.Subject)
                        didCalQuest = true
                    elseif cq.Type == "Win" and cq.Subject == "Dice Roll" then
                        PlayDiceRoll()
                        didCalQuest = true
                    elseif cq.Type == "Win" and cq.Subject == "Coinflip" then
                        PlayCoinflip()
                        didCalQuest = true
                    elseif cq.Type == "Win" and cq.Subject == "Upgrader" then
                        if Config.AutoUpgrader and DoUpgrade() then
                            didCalQuest = true
                        end
                    end
                end
            end
            if didCalQuest then continue end
        end

        -- 6. Quest Battles
        local didBattle = false
        if Config.AutoQuestPlay or Config.AutoQuestWin then

                 local qPlay = Config.AutoQuestPlay and GetQuest("Play")
                 if qPlay and qPlay.Remaining > 0 then
                     State.LastBattle = now
                     CreateBattle(qPlay.Subject)
                     didBattle = true
                 else
                     local qWin = Config.AutoQuestWin and GetQuest("Win")
                     if qWin and qWin.Remaining > 0 then
                         State.LastBattle = now
                         CreateBattle("CLASSIC")
                         didBattle = true
                     end
                 end

        end
        if didBattle then continue end

        -- 7. Quest Opening
        if Config.AutoQuestOpen then
            local q = GetQuest("Open")
            if q and q.Remaining > 0 then
                local qty = (q.Remaining > 5) and 5 or q.Remaining
                if OpenCase(q.Subject, false, qty, false) then continue end
            end
        end

        -- 8. Selected Case
        if Config.AutoOpenCase and Config.SelectedCase then
            OpenCase(Config.SelectedCase, false, Config.CaseQuantity, Config.WildMode)
        end
    end
end)


--------------------------------------------------------------------------------
-- RAYFIELD UI LOAD
--------------------------------------------------------------------------------
local Rayfield
repeat
    pcall(function() 
        Rayfield = loadstring(game:HttpGet('https://raw.githubusercontent.com/spint990/ParadiseEnhancer/refs/heads/main/Rayfield?v='..tostring(math.random(1, 1000000))))() 
    end)
    if not Rayfield then task.wait(1) end
until Rayfield

--------------------------------------------------------------------------------
-- RAYFIELD UI WINDOW
--------------------------------------------------------------------------------

local Window = Rayfield:CreateWindow({
    Name = "Paradise Enhancer",
    LoadingTitle = "Volt Optimized",
    LoadingSubtitle = "by Backlyne",
    Theme = "Default",
    ToggleUIKeybind = "K",
})

local TabMain  = Window:CreateTab("Cases", 4483362458)
local TabQuest = Window:CreateTab("Quests", 4483362458)
local TabAuto  = Window:CreateTab("Automation", 4483362458)

local CaseDropdown

local function RefreshDropdown()
    if not CaseDropdown then return end
    local opts = {}
    for _, c in ipairs(Cache_Cases) do
        local price = Config.WildMode and GetWildPrice(c.Id) or c.Price
        local total = price * Config.CaseQuantity
        local wild = Config.WildMode and " (Wild)" or ""
        table.insert(opts, c.Name .. wild .. " " .. FormatPrice(total, c.Currency))
    end
    CaseDropdown:Refresh(opts)
end

TabMain:CreateSection("Case Control")
TabMain:CreateToggle({
    Name = "Auto Open Selected",
    CurrentValue = Config.AutoOpenCase,
    Flag = "AutoOpenCase",
    Callback = function(v) Config.AutoOpenCase = v end,
})

CaseDropdown = TabMain:CreateDropdown({
    Name = "Select Case",
    Options = {"Loading..."},
    CurrentOption = {"Loading..."},
    MultipleOptions = false,
    Flag = "SelectedCase",
    Callback = function(opt)
        local name = type(opt) == "table" and opt[1] or opt
        for _, c in ipairs(Cache_Cases) do
            if name:find(c.Name, 1, true) then
                Config.SelectedCase = c.Id
                break
            end
        end
    end,
})

TabMain:CreateDropdown({
    Name = "Quantity",
    Options = {"1", "2", "3", "4", "5"},
    CurrentOption = {tostring(Config.CaseQuantity)},
    MultipleOptions = false,
    Flag = "CaseQuantity",
    Callback = function(opt)
        Config.CaseQuantity = tonumber(type(opt) == "table" and opt[1] or opt) or 1
        RefreshDropdown()
    end,
})

TabMain:CreateToggle({
    Name = "Wild Mode",
    CurrentValue = Config.WildMode,
    Flag = "WildMode",
    Callback = function(v)
        Config.WildMode = v
        RefreshDropdown()
    end,
})

-- Quests
TabQuest:CreateSection("Quest Automation")
TabQuest:CreateToggle({ Name = "Auto Quest: Open Cases", CurrentValue = Config.AutoQuestOpen, Flag = "AutoQuestOpen", Callback = function(v) Config.AutoQuestOpen = v end })
TabQuest:CreateToggle({ Name = "Auto Quest: Play Battles", CurrentValue = Config.AutoQuestPlay, Flag = "AutoQuestPlay", Callback = function(v) Config.AutoQuestPlay = v if v then HideBattleUI() end end })
TabQuest:CreateToggle({ Name = "Auto Quest: Win Battles", CurrentValue = Config.AutoQuestWin, Flag = "AutoQuestWin", Callback = function(v) Config.AutoQuestWin = v if v then HideBattleUI() end end })
TabQuest:CreateSection("Calendar Quests")
TabQuest:CreateToggle({ Name = "Auto Calendar Quests", CurrentValue = Config.AutoCalendarQuest, Flag = "AutoCalendarQuest", Callback = function(v) Config.AutoCalendarQuest = v end })
TabQuest:CreateToggle({ Name = "Auto Win Upgrader Quest", CurrentValue = Config.AutoUpgrader, Flag = "AutoUpgrader", Callback = function(v) Config.AutoUpgrader = v end })

local Label_Open = TabQuest:CreateLabel("Open: ...")
local Label_Play = TabQuest:CreateLabel("Play: ...")
local Label_Win  = TabQuest:CreateLabel("Win: ...")
local Label_Cal  = TabQuest:CreateLabel("Calendar: ...")

task.spawn(function()
    while true do
        task.wait(3)
        local o, p, w = GetQuest("Open"), GetQuest("Play"), GetQuest("Win")
        Label_Open:Set(o and ("Open: "..o.Progress.."/"..o.Requirement.." "..o.Subject) or "Open: None")
        Label_Play:Set(p and ("Play: "..p.Progress.."/"..p.Requirement.." "..p.Subject) or "Play: None")
        Label_Win:Set(w and ("Win: "..w.Progress.."/"..w.Requirement) or "Win: None")
        local calQuests = GetCalendarQuests()
        local calText = "Calendar: "
        local activeCal = 0
        for _, cq in ipairs(calQuests) do
            if cq.Remaining > 0 then
                activeCal = activeCal + 1
                calText = calText .. cq.Type .. " "
            end
        end
        Label_Cal:Set(activeCal > 0 and calText or "Calendar: Done")
    end
end)

-- Auto
TabAuto:CreateSection("Economy & Items")
TabAuto:CreateToggle({ Name = "Auto Sell (Blacklist Safe)", CurrentValue = Config.AutoSell, Flag = "AutoSell", Callback = function(v) Config.AutoSell = v end })
TabAuto:CreateToggle({ Name = "Claim Gifts", CurrentValue = Config.AutoClaimGift, Flag = "AutoClaimGift", Callback = function(v) Config.AutoClaimGift = v end })
TabAuto:CreateToggle({ Name = "Rejoin on Gift 9", CurrentValue = Config.RejoinOnGift9, Flag = "RejoinOnGift9", Callback = function(v) Config.RejoinOnGift9 = v end })
TabAuto:CreateSection("Advanced Cases")
TabAuto:CreateToggle({ Name = "Auto Level Cases", CurrentValue = Config.AutoLevelCases, Flag = "AutoLevelCases", Callback = function(v) Config.AutoLevelCases = v if v then UpdateLevelCooldowns() end end })
TabAuto:CreateToggle({ Name = "Auto Ticket Case (>50 Tickets)", CurrentValue = Config.AutoTicketCase, Flag = "AutoTicketCase", Callback = function(v) Config.AutoTicketCase = v end })
TabAuto:CreateToggle({ Name = "Auto Light Case (>140k Money)", CurrentValue = Config.AutoLightCase, Flag = "AutoLightCase", Callback = function(v) Config.AutoLightCase = v end })
TabAuto:CreateSection("Events")
TabAuto:CreateToggle({ Name = "Meteor Walk", CurrentValue = Config.AutoMeteor, Flag = "AutoMeteor", Callback = function(v) Config.AutoMeteor = v if not v then StopMeteorWalk() end end })

RefreshDropdown()
