--[[
    Paradise Enhancer v2
    Executor: Volt
    Human-like, single action at a time, no config saving

    Priority (sequential, one at a time):
      1. Gifts (free items)
      2. Level Cases (cooldown-based free cases)
      3. MoonCase (spend 50+ tickets)
      4. LIGHT Wild Mode (spend 120k+ dollars for Titan Holo hunt)
      5. Calendar Quests (daily quests including RPS/Dice/Upgrader/Open/Play)
      6. Normal Quests (Play/Win/Open)

    Parallel (run continuously in background):
      - Sell (periodic)
      - Event drops / Meteor walk
      - Bonuses: Rewards
]]

if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(math.random(15, 30))
print("[Enhancer] v2 loaded — starting script")

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TeleportService   = game:GetService("TeleportService")

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
local Remote_OpenCase          = Remotes:WaitForChild("OpenCase")
local Remote_CreateBattle      = Remotes:WaitForChild("CreateBattle")
local Remote_CheckCooldown     = Remotes:WaitForChild("CheckCooldown")
local Remote_AddBot            = Remotes:WaitForChild("AddBot")
local Remote_Sell              = Remotes:WaitForChild("Sell")
local Remote_CreateMatch       = Remotes:WaitForChild("CreateMatch")
local Remote_RollDice          = Remotes:WaitForChild("RollDice")
local Remote_Upgrade           = Remotes:WaitForChild("Upgrade")
local Remote_ClaimCategoryIndex = Remotes:WaitForChild("ClaimCategoryIndex")
local Remote_ResetCalendar     = Remotes:WaitForChild("ResetCalendar")

local Remote_UpdateRewards     = Remotes:WaitForChild("UpdateRewards")
local Remote_AddBotCoinFlip    = Remotes:WaitForChild("AddBotCoinFlip")
local Remote_RPSChoice         = Remotes:WaitForChild("RPSChoice")
local Remote_LeaveMatch        = Remotes:WaitForChild("LeaveMatch")

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
local UI_CoinFlip      = UI_Windows:WaitForChild("CoinFlip")

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local Config = {
    AutoClaimGift     = true,
    AutoLevelCases    = true,
    AutoCalendarQuest = true,
    AutoTicketCase    = true,
    AutoLightCase     = true,
    AutoSell          = true,
    AutoQuestOpen     = true,
    AutoQuestPlay     = true,
    AutoQuestWin      = true,
    AutoUpgrader      = true,
    AutoMeteor        = true,

    RejoinOnGift9     = true,

    TicketThreshold   = 50,
    DollarThreshold   = 120000,
}

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
    ["SSG08_ToxicWaste"]                   = true,
    ["HunterKnife_Ammonia"]                = true,
    ["ButterflyKnife_RadioactiveActivation"] = true,
    ["AWP_OozingToxicity"]                 = true,
    ["AUG_BlackVoid"]                      = true,
    ["AK47_Sweetheart"]                    = true,
    ["FalchionKnife_CelestialIntervention"] = true,
    ["HuntsmanKnife_BiologicalHazard"]     = true,
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local State = {
    IsBusy = false,
    NextSell = 0,
    NextLevelCase = 9e9,
    NextLevelCaseId = nil,
    LevelFailures = {},


}

local Cache_Cases = {}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------
local function GetBalance() return Currencies.Balance.Value end
local function GetTickets() return Currencies.Tickets.Value end
local function GetXP()      return Currencies.Experience.Value end

local function GetWildPrice(caseId)
    local obj = WildPrices:FindFirstChild(caseId)
    if obj then return obj.Value end
    local data = CasesModule[caseId]
    return data and data.Price or 0
end

local function HumanWait(lo, hi)
    task.wait(math.random() * (hi - lo) + lo)
end

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

--------------------------------------------------------------------------------
-- SUPPRESS ANIMATION
--------------------------------------------------------------------------------
RunService.Heartbeat:Connect(function()
    if State.IsBusy then
        local cam = workspace.CurrentCamera
        cam.FieldOfView = 70
        UI_OpenAnimation.CaseOpeningScreen.Visible = false
        UI_OpenAnimation.EndPreview.Visible = false
        UI_CoinFlip.Visible = false
        UI_Main.Enabled = true
        UI_Windows.Enabled = true
    end
end)

--------------------------------------------------------------------------------
-- LEVEL COOLDOWNS
--------------------------------------------------------------------------------
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
        if State.LevelFailures[caseId] and (now - State.LevelFailures[caseId] < 15) then
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
                    cooldownEnd = now + 999
                end
            else
                cooldownEnd = now
            end
            if cooldownEnd < State.NextLevelCase then
                State.NextLevelCase = cooldownEnd
                State.NextLevelCaseId = caseId
                print("[Enhancer] LevelCooldown: "..caseId.." ready in "..math.floor(math.max(0, cooldownEnd - now)).."s")
            end
        end
    end
end
task.spawn(UpdateLevelCooldowns)

--------------------------------------------------------------------------------
-- CORE: OPEN CASE
--------------------------------------------------------------------------------
local function OpenCase(caseId, isGift, qty, useWild)
    if State.IsBusy then return false end
    State.IsBusy = true

    print("[Enhancer] OpenCase:", caseId, "qty="..(qty or 1), "wild="..tostring(useWild or false), "gift="..tostring(isGift))

    local result
    if isGift then
        result = Remote_OpenCase:InvokeServer(caseId, -1, false)
    else
        result = Remote_OpenCase:InvokeServer(caseId, qty or 1, false, useWild or false)
    end

    local success = (type(result) == "table" and next(result))
    print("[Enhancer] OpenCase result:", caseId, "success="..tostring(success))

    if not success and caseId:find("^LEVEL") then
        State.LevelFailures[caseId] = workspace:GetServerTimeNow()
        State.NextLevelCase = 9e9
        State.NextLevelCaseId = nil
        task.spawn(UpdateLevelCooldowns)
    end

    UI_Main.Enabled = true
    UI_Windows.Enabled = true

    task.delay(math.random(10, 18), function()
        State.IsBusy = false
    end)

    return success
end

--------------------------------------------------------------------------------
-- CORE: BATTLE
--------------------------------------------------------------------------------
local function HideBattleUI()
    if UI_Battle:FindFirstChild("BattleFrame") then
        UI_Battle.BattleFrame.Visible = false
    end
    UI_CoinFlip.Visible = false
    UI_Main.Enabled = true
    UI_Windows.Enabled = true
end

local function CreateBattle(mode)
    if State.IsBusy then return end
    State.IsBusy = true
    mode = string.upper(mode)
    print("[Enhancer] CreateBattle:", mode)

    local id = Remote_CreateBattle:InvokeServer({"PERCHANCE"}, 2, mode, false)
    HumanWait(2.5, 5.0)

    if id then
        Remote_AddBot:FireServer(id, Player)
    end

    HumanWait(1.0, 2.5)
    UI_Main.Enabled = true
    UI_Windows.Enabled = true

    task.delay(math.random(20, 30), function()
        State.IsBusy = false
    end)
end

--------------------------------------------------------------------------------
-- CORE: DICE ROLL
--------------------------------------------------------------------------------
local function PlayDiceRoll()
    if State.IsBusy then return end
    State.IsBusy = true
    print("[Enhancer] PlayDiceRoll: creating match")

    Remote_CreateMatch:FireServer("Dice Roll", "1")
    UI_DiceRoll.Visible = false
    UI_Main.Enabled = true

    HumanWait(3.0, 7.0)

    Remote_RollDice:FireServer("1", 3)
    print("[Enhancer] PlayDiceRoll: dice rolled")
    UI_DiceRoll.Visible = false
    UI_Main.Enabled = true
    UI_Windows.Enabled = true

    task.delay(math.random(18, 28), function()
        State.IsBusy = false
    end)
end

--------------------------------------------------------------------------------
-- CORE: COINFLIP
-- Flow: CreateMatch("Coinflip", price) -> wait OnClientEvent -> AddBot(matchId) -> wait -> LeaveMatch(matchId, "CoinFlip")
--------------------------------------------------------------------------------
local Coinflip_MatchId = nil
local Coinflip_Waiting = false

local function PlayCoinflip()
    if State.IsBusy then return end
    State.IsBusy = true
    Coinflip_MatchId = nil
    Coinflip_Waiting = true
    print("[Enhancer] PlayCoinflip: creating match")

    Remote_CreateMatch:FireServer("Coinflip", "1")
    UI_CoinFlip.Visible = false
    UI_Main.Enabled = true
    UI_Windows.Enabled = true

    local timeout = 0
    while not Coinflip_MatchId and timeout < 10 do
        task.wait(0.5)
        timeout = timeout + 0.5
    end

    Coinflip_Waiting = false

    if not Coinflip_MatchId then
        print("[Enhancer] PlayCoinflip: timeout, no match created")
        State.IsBusy = false
        return
    end

    print("[Enhancer] PlayCoinflip: matchId="..tostring(Coinflip_MatchId))
    HumanWait(1.5, 4.0)

    Remote_AddBotCoinFlip:FireServer(Coinflip_MatchId)
    print("[Enhancer] PlayCoinflip: bot added")

    task.delay(math.random(18, 28), function()
        pcall(function()
            Remote_LeaveMatch:FireServer(Coinflip_MatchId, "CoinFlip")
        end)
        UI_Main.Enabled = true
        UI_Windows.Enabled = true
        Coinflip_MatchId = nil
        State.IsBusy = false
    end)
end

--------------------------------------------------------------------------------
-- CORE: ROCK PAPER SCISSORS
-- Flow: CreateMatch -> wait CreateRPS event -> add bot -> send choice -> leave
--------------------------------------------------------------------------------
local RPS_MatchId = nil

Remotes:WaitForChild("CreateRPS").OnClientEvent:Connect(function(matchId)
    RPS_MatchId = matchId
end)

Remotes:WaitForChild("CreateMatch").OnClientEvent:Connect(function(matchId)
    if Coinflip_Waiting then
        Coinflip_MatchId = matchId
    end
end)

local function PlayRPS()
    if State.IsBusy then return end
    State.IsBusy = true
    RPS_MatchId = nil
    print("[Enhancer] PlayRPS: creating match")

    Remote_CreateMatch:FireServer("Rock Paper Scissors", "1")

    local timeout = 0
    while not RPS_MatchId and timeout < 10 do
        task.wait(0.5)
        timeout = timeout + 0.5
    end

    if not RPS_MatchId then
        print("[Enhancer] PlayRPS: timeout, no match created")
        State.IsBusy = false
        return
    end

    print("[Enhancer] PlayRPS: matchId="..tostring(RPS_MatchId))
    HumanWait(1.5, 4.0)

    Remote_AddBotCoinFlip:FireServer(RPS_MatchId, "Rock Paper Scissors")
    print("[Enhancer] PlayRPS: bot added")

    HumanWait(3.5, 7.0)

    local choices = {"Rock", "Paper", "Scissors"}
    local choice = choices[math.random(1, 3)]
    Remote_RPSChoice:FireServer(RPS_MatchId, choice)
    print("[Enhancer] PlayRPS: choice="..choice)

    task.delay(math.random(14, 22), function()
        pcall(function()
            Remote_LeaveMatch:FireServer(RPS_MatchId, "Rock Paper Scissors")
        end)
        UI_Main.Enabled = true
        UI_Windows.Enabled = true
        RPS_MatchId = nil
        State.IsBusy = false
    end)
end

--------------------------------------------------------------------------------
-- CORE: UPGRADER
--------------------------------------------------------------------------------
local function DoUpgrade()
    if State.IsBusy then return false end
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
            }
        end
    end

    if not cheapestItem then
        print("[Enhancer] DoUpgrade: no eligible item found")
        State.IsBusy = false
        return false
    end

    print("[Enhancer] DoUpgrade: upgrading item $"..cheapestPrice.." -> P250 Facility Draft")
    Remote_Upgrade:FireServer({
        { Price = cheapestItem.Price, UUID = cheapestItem.UUID }
    }, {
        Key = "P250_FacilityDraft",
        Name = "P250 | Facility Draft",
        Stattrak = false,
        Price = 0.01,
        Wear = "Field-Tested"
    })

    task.delay(math.random(10, 18), function()
        State.IsBusy = false
    end)
    return true
end

--------------------------------------------------------------------------------
-- CORE: SELL
--------------------------------------------------------------------------------
local function SellItems()
    if State.IsBusy then return end
    State.IsBusy = true

    local currentWindow = PlayerGui:FindFirstChild("CurrentWindow")
    if currentWindow then
        currentWindow.Value = "Inventory"
        task.wait(0.15)
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
                    if itemId and locked ~= true and not Whitelist[itemId] then
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
        print("[Enhancer] Sell: selling "..#toSell.." items")
        Remote_Sell:InvokeServer(toSell)
    else
        print("[Enhancer] Sell: nothing to sell")
    end

    task.delay(math.random(6, 12), function()
        State.IsBusy = false
    end)
end

--------------------------------------------------------------------------------
-- METEOR
--------------------------------------------------------------------------------
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
            local root = char:FindFirstChild("HumanoidRootPart")
            if root and (Vector3.new(root.Position.X, Meteor.Target.Y, root.Position.Z) - Meteor.Target).Magnitude < 5 then
                break
            end
            task.wait(0.25)
            char = Player.Character
            hum = char and char:FindFirstChild("Humanoid")
        end
        StopMeteorWalk()
    end)
end

task.spawn(function()
    local temp = workspace:WaitForChild("Temp", 5)
    if not temp then return end
    local function check(child)
        if not Config.AutoMeteor then return end
        if child.Name == "MeteorHitHitbox" then
            local hit = child:FindFirstChild("Hit")
            if hit then
                print("[Enhancer] Meteor: walking to hit position")
                WalkTo(hit.Position)
            end
        elseif child.Name == "Hit" and child:IsA("BasePart") then
            print("[Enhancer] Meteor: walking to hit part")
            WalkTo(child.Position)
        end
    end
    temp.ChildAdded:Connect(check)
    for _, c in ipairs(temp:GetChildren()) do check(c) end
    temp.ChildRemoved:Connect(function(child)
        if child.Name == "MeteorHitHitbox" then StopMeteorWalk() end
    end)
end)

--------------------------------------------------------------------------------
-- SUPPRESS AVATAR EDITOR POPUP
--------------------------------------------------------------------------------
task.spawn(function()
    local CoreGui = game:GetService("CoreGui")
    local function killPrompt()
        pcall(function()
            local app = CoreGui:FindFirstChild("AvatarEditorPromptsApp")
            if not app then return end
            local ch = app:FindFirstChild("Children")
            if not ch then return end
            for _, child in ipairs(ch:GetChildren()) do
                if child:IsA("ScreenGui") or child:IsA("BillboardGui") or child:IsA("SurfaceGui") then
                    child.Enabled = false
                end
                if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("ImageLabel") or child:IsA("ImageButton") then
                    child.Visible = false
                end
            end
        end)
    end
    pcall(function()
        local app = CoreGui:WaitForChild("AvatarEditorPromptsApp", 30)
        if app then
            local ch = app:WaitForChild("Children", 30)
            if ch then
                ch.ChildAdded:Connect(function(child)
                    task.wait()
                    pcall(function() child.Enabled = false end)
                    pcall(function() child.Visible = false end)
                    killPrompt()
                end)
            end
        end
    end)
    while true do
        killPrompt()
        task.wait(0.5)
    end
end)

--------------------------------------------------------------------------------
-- REJOIN
--------------------------------------------------------------------------------
local function Rejoin()
    print("[Enhancer] Rejoining server...")
    if #Players:GetPlayers() <= 1 then
        Player:Kick("Rejoining...")
        task.wait()
        TeleportService:Teleport(game.PlaceId, Player)
    else
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, Player)
    end
end

--------------------------------------------------------------------------------
-- QUEST HELPERS
--------------------------------------------------------------------------------
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

local function IsSubject(subject, match)
    if not subject then return false end
    return string.lower(subject:gsub("%s+", "")) == string.lower(match:gsub("%s+", ""))
end

--------------------------------------------------------------------------------
-- BONUS FUNCTIONS (run in parallel, don't block main loop)
-- Rewards: auto-claim free gift rewards

local function TryClaimRewards()
    local rewardsWin = UI_Windows:FindFirstChild("Rewards")
    if not rewardsWin then return end
    local claimedGifts = rewardsWin:FindFirstChild("ClaimedGifts")
    if not claimedGifts then return end
    for _, giftObj in ipairs(GiftsFolder:GetChildren()) do
        local giftId = giftObj.Name
        local claimed = claimedGifts:FindFirstChild(giftId)
        if claimed and not claimed.Value then
            local ok, result = pcall(function()
                return Remote_UpdateRewards:InvokeServer(giftId)
            end)
            if ok and result == true then
                claimed.Value = true
                Remote_OpenCase:InvokeServer(giftId, -1, false)
                print("[Enhancer] Reward claimed:", giftId)
            end
        end
    end
end


--------------------------------------------------------------------------------
-- PARALLEL LOOP: Sell (continuous, does not block)
--------------------------------------------------------------------------------
task.spawn(function()
    while true do
        task.wait(math.random(5, 15))

        if Config.AutoSell and not State.IsBusy and workspace:GetServerTimeNow() >= State.NextSell then
            State.NextSell = workspace:GetServerTimeNow() + math.random(90, 240)
            pcall(SellItems)
        end
    end
end)

--------------------------------------------------------------------------------
-- MAIN SEQUENTIAL LOOP (one action at a time)
-- Priority: Gifts -> Level Cases -> MoonCase -> LIGHT Wild -> Calendar Quests -> Quests
--------------------------------------------------------------------------------
task.spawn(function()
    while true do
        task.wait(math.random(2.0, 5.0))
        if State.IsBusy then continue end
        local now = workspace:GetServerTimeNow()



        if Config.AutoQuestWin or Config.AutoQuestPlay then HideBattleUI() end

        -- 1. GIFTS
        if Config.AutoClaimGift then
            local giftId
            local pt = Playtime.Value
            for i = 1, 9 do
                local id = "Gift"..i
                local gVal = GiftsFolder:FindFirstChild(id)
                local claimed = ClaimedGifts:FindFirstChild(id)
                if gVal and claimed and not claimed.Value and pt >= gVal.Value then
                    giftId = id
                    break
                end
            end
            if giftId then
                print("[Enhancer] Gift: claiming "..giftId)
                if OpenCase(giftId, true) then
                    if giftId == "Gift9" and Config.RejoinOnGift9 then
                        HumanWait(1, 3)
                        Rejoin()
                    end
                    continue
                end
            end
        end

        -- 2. LEVEL CASES
        if Config.AutoLevelCases and State.NextLevelCaseId and now >= State.NextLevelCase then
            print("[Enhancer] LevelCase: opening "..tostring(State.NextLevelCaseId))
            if OpenCase(State.NextLevelCaseId, false, 1) then
                task.delay(1, UpdateLevelCooldowns)
                continue
            end
        end

        -- 3. MOONCASE (spend tickets)
        if Config.AutoTicketCase and not State.IsBusy then
            local tickets = GetTickets()
            if tickets >= Config.TicketThreshold then
                print("[Enhancer] Opening 5x MoonCase ("..tickets.." tickets)")
                if OpenCase("MoonCase", false, 5, false) then continue end
            end
        end

        -- 4. LIGHT WILD MODE (Titan Holo hunt)
        if Config.AutoLightCase and not State.IsBusy then
            local balance = GetBalance()
            if balance >= Config.DollarThreshold then
                print("[Enhancer] Opening 5x LIGHT Wild ($"..balance..")")
                if OpenCase("LIGHT", false, 5, true) then continue end
            end
        end

        -- 5. CALENDAR QUESTS
        if Config.AutoCalendarQuest and not State.IsBusy then
            local calQuests = GetCalendarQuests()
            for _, cq in ipairs(calQuests) do
                if cq.Remaining > 0 then
                    print("[Enhancer] CalQuest detected: type="..tostring(cq.Type).." subject="..tostring(cq.Subject).." progress="..cq.Progress.."/"..cq.Requirement)
                end
            end
            local didCal = false
            for _, cq in ipairs(calQuests) do
                if cq.Remaining > 0 and not didCal and not State.IsBusy then
                    if cq.Type == "Open" then
                        local qty = (cq.Remaining > 5) and 5 or cq.Remaining
                        print("[Enhancer] CalQuest: Open "..tostring(cq.Subject).." x"..qty)
                        if OpenCase(cq.Subject, false, qty, false) then
                            didCal = true
                        end
                    elseif cq.Type == "Play" then
                        print("[Enhancer] CalQuest: Play "..tostring(cq.Subject))
                        CreateBattle(cq.Subject)
                        didCal = true
                    elseif cq.Type == "Win" then
                        if IsSubject(cq.Subject, "Dice Roll") then
                            print("[Enhancer] CalQuest: Win Dice Roll")
                            PlayDiceRoll()
                            didCal = true
                        elseif IsSubject(cq.Subject, "Rock Paper Scissors") then
                            print("[Enhancer] CalQuest: Win RPS")
                            PlayRPS()
                            didCal = true
                        elseif IsSubject(cq.Subject, "Coinflip") then
                            print("[Enhancer] CalQuest: Win Coinflip (subject="..tostring(cq.Subject)..")")
                            PlayCoinflip()
                            didCal = true
                        elseif IsSubject(cq.Subject, "Upgrader") then
                            print("[Enhancer] CalQuest: Win Upgrader")
                            if Config.AutoUpgrader and DoUpgrade() then
                                didCal = true
                            end
                        end
                    end
                end
            end
            if didCal then continue end
        end

        -- 6. NORMAL QUESTS (Play -> Win -> Open)
        if not State.IsBusy then
            local didQuest = false

            if Config.AutoQuestPlay then
                local qPlay = GetQuest("Play")
                if qPlay and qPlay.Remaining > 0 then
                    print("[Enhancer] Quest detected: Play subject="..tostring(qPlay.Subject).." progress="..qPlay.Progress.."/"..qPlay.Requirement)
                    print("[Enhancer] Quest: Play "..tostring(qPlay.Subject))
                    CreateBattle(qPlay.Subject)
                    didQuest = true
                end
            end

            if not didQuest and Config.AutoQuestWin then
                local qWin = GetQuest("Win")
                if qWin and qWin.Remaining > 0 then
                    print("[Enhancer] Quest detected: Win subject="..tostring(qWin.Subject).." progress="..qWin.Progress.."/"..qWin.Requirement)
                    print("[Enhancer] Quest: Win "..tostring(qWin.Subject))
                    if IsSubject(qWin.Subject, "Dice Roll") then
                        PlayDiceRoll()
                    elseif IsSubject(qWin.Subject, "Rock Paper Scissors") then
                        PlayRPS()
                    elseif IsSubject(qWin.Subject, "Coinflip") then
                        PlayCoinflip()
                    elseif IsSubject(qWin.Subject, "Upgrader") then
                        if Config.AutoUpgrader then DoUpgrade() end
                    else
                        CreateBattle("CLASSIC")
                    end
                    didQuest = true
                end
            end

            if not didQuest and Config.AutoQuestOpen then
                local q = GetQuest("Open")
                if q and q.Remaining > 0 then
                    local qty = (q.Remaining > 5) and 5 or q.Remaining
                    print("[Enhancer] Quest: Open "..tostring(q.Subject).." x"..qty)
                    if OpenCase(q.Subject, false, qty, false) then
                        didQuest = true
                    end
                end
            end

            if didQuest then continue end
        end
    end
end)

--------------------------------------------------------------------------------
-- RAYFIELD UI
--------------------------------------------------------------------------------
local Rayfield
repeat
    pcall(function()
        Rayfield = loadstring(game:HttpGet('https://raw.githubusercontent.com/spint990/ParadiseEnhancer/refs/heads/main/Rayfield?v='..tostring(math.random(1, 1000000))))()
    end)
    if not Rayfield then task.wait(1) end
until Rayfield

local Window = Rayfield:CreateWindow({
    Name = "Paradise Enhancer v2",
    LoadingTitle = "Volt Optimized",
    LoadingSubtitle = "by Backlyne",
    Theme = "Default",
    ToggleUIKeybind = "K",
})

local TabMain  = Window:CreateTab("Economy", 4483362458)
local TabQuest = Window:CreateTab("Quests", 4483362458)
local TabAuto  = Window:CreateTab("Automation", 4483362458)
local TabTools = Window:CreateTab("Tools", 4483362458)

TabMain:CreateSection("Status")
local Label_Balance = TabMain:CreateLabel("$0")
local Label_Tickets = TabMain:CreateLabel("Tickets: 0")
local Label_Status  = TabMain:CreateLabel("Idle")

TabMain:CreateSection("Economy Cycle")
TabMain:CreateToggle({ Name = "Auto MoonCase (50+ Tickets)", CurrentValue = Config.AutoTicketCase, Flag = "AutoTicketCase", Callback = function(v) Config.AutoTicketCase = v end })
TabMain:CreateToggle({ Name = "Auto LIGHT Wild (120k+ $)", CurrentValue = Config.AutoLightCase, Flag = "AutoLightCase", Callback = function(v) Config.AutoLightCase = v end })
TabMain:CreateToggle({ Name = "Auto Sell (Blacklist Safe)", CurrentValue = Config.AutoSell, Flag = "AutoSell", Callback = function(v) Config.AutoSell = v end })

TabQuest:CreateSection("Calendar Quests")
TabQuest:CreateToggle({ Name = "Auto Calendar Quests", CurrentValue = Config.AutoCalendarQuest, Flag = "AutoCalendarQuest", Callback = function(v) Config.AutoCalendarQuest = v end })
TabQuest:CreateToggle({ Name = "Auto Win Upgrader Quest", CurrentValue = Config.AutoUpgrader, Flag = "AutoUpgrader", Callback = function(v) Config.AutoUpgrader = v end })
TabQuest:CreateSection("Normal Quests")
TabQuest:CreateToggle({ Name = "Auto Quest: Open Cases", CurrentValue = Config.AutoQuestOpen, Flag = "AutoQuestOpen", Callback = function(v) Config.AutoQuestOpen = v end })
TabQuest:CreateToggle({ Name = "Auto Quest: Play Battles", CurrentValue = Config.AutoQuestPlay, Flag = "AutoQuestPlay", Callback = function(v) Config.AutoQuestPlay = v if v then HideBattleUI() end end })
TabQuest:CreateToggle({ Name = "Auto Quest: Win Battles", CurrentValue = Config.AutoQuestWin, Flag = "AutoQuestWin", Callback = function(v) Config.AutoQuestWin = v if v then HideBattleUI() end end })

local Label_Open = TabQuest:CreateLabel("Open: ...")
local Label_Play = TabQuest:CreateLabel("Play: ...")
local Label_Win  = TabQuest:CreateLabel("Win: ...")
local Label_Cal  = TabQuest:CreateLabel("Calendar: ...")

TabAuto:CreateSection("Free Cases & Gifts")
TabAuto:CreateToggle({ Name = "Claim Gifts", CurrentValue = Config.AutoClaimGift, Flag = "AutoClaimGift", Callback = function(v) Config.AutoClaimGift = v end })
TabAuto:CreateToggle({ Name = "Rejoin on Gift 9", CurrentValue = Config.RejoinOnGift9, Flag = "RejoinOnGift9", Callback = function(v) Config.RejoinOnGift9 = v end })
TabAuto:CreateToggle({ Name = "Auto Level Cases", CurrentValue = Config.AutoLevelCases, Flag = "AutoLevelCases", Callback = function(v) Config.AutoLevelCases = v if v then UpdateLevelCooldowns() end end })
TabAuto:CreateSection("Events")
TabAuto:CreateToggle({ Name = "Meteor Walk", CurrentValue = Config.AutoMeteor, Flag = "AutoMeteor", Callback = function(v) Config.AutoMeteor = v if not v then StopMeteorWalk() end end })

TabTools:CreateSection("Quick Actions")
TabTools:CreateButton({ Name = "Force Sell Now", Callback = function() SellItems() end })
TabTools:CreateButton({ Name = "Claim All Rewards", Callback = function() TryClaimRewards() end })

task.spawn(function()
    while true do
        task.wait(3)
        local bal = GetBalance()
        local tick = GetTickets()
        Label_Balance:Set("$"..bal)
        Label_Tickets:Set("Tickets: "..tick)

        if tick >= Config.TicketThreshold then
            Label_Status:Set("MoonCase ready: "..tick.."T")
        elseif bal >= Config.DollarThreshold then
            Label_Status:Set("LIGHT Wild ready: $"..bal)
        else
            Label_Status:Set("Farming... ($"..bal.." / T"..tick..")")
        end

        local o, p, w = GetQuest("Open"), GetQuest("Play"), GetQuest("Win")
        Label_Open:Set(o and ("Open: "..o.Progress.."/"..o.Requirement.." "..o.Subject) or "Open: None")
        Label_Play:Set(p and ("Play: "..p.Progress.."/"..p.Requirement.." "..p.Subject) or "Play: None")
        Label_Win:Set(w and ("Win: "..w.Progress.."/"..w.Requirement.." "..(w.Subject or "")) or "Win: None")
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
