--[[
    Paradise Enhancer (Refactored)
    Executor: Volt
    Optimized & Human-Like
    NO CONFIG SAVING
]]

--------------------------------------------------------------------------------
-- SERVICES & ARGS
--------------------------------------------------------------------------------
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
local ClaimedGifts = Player:WaitForChild("ClaimedGifts")
local Playtime     = Player:WaitForChild("Playtime")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Remote_OpenCase      = Remotes:WaitForChild("OpenCase")
local Remote_CreateBattle  = Remotes:WaitForChild("CreateBattle")
local Remote_CheckCooldown = Remotes:WaitForChild("CheckCooldown")
local Remote_AddBot        = Remotes:WaitForChild("AddBot")
local Remote_StartBattle   = Remotes:WaitForChild("StartBattle")
local Remote_Sell          = Remotes:WaitForChild("Sell")

local Rayfield
repeat
    pcall(function() Rayfield = loadstring(game:HttpGet('https://raw.githubusercontent.com/spint990/ParadiseEnhancer/refs/heads/main/Rayfield'))() end)
    if not Rayfield then task.wait(1) end
until Rayfield

local Modules     = ReplicatedStorage:WaitForChild("Modules")
local CasesModule = require(Modules:WaitForChild("Cases"))
local GiftsFolder = ReplicatedStorage:WaitForChild("Gifts")
local WildPrices  = ReplicatedStorage:WaitForChild("Misc"):WaitForChild("WildPrices")

local UI_Main          = PlayerGui:WaitForChild("Main")
local UI_Windows       = PlayerGui:WaitForChild("Windows")
local UI_OpenAnimation = PlayerGui:WaitForChild("OpenAnimation")
local UI_Battle        = PlayerGui:WaitForChild("Battle")
local UI_Inventory     = UI_Windows:WaitForChild("Inventory")

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
    
    SelectedCase      = "DivineCase",
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
    
    local xp = GetXP()
    
    local timeNow = os.time()
    local levelCases = {
        "LEVEL10", "LEVEL20", "LEVEL30", "LEVEL40", "LEVEL50", "LEVEL60",
        "LEVEL70", "LEVEL80", "LEVEL90", "LEVELS100", "LEVELS110", "LEVELS120"
    }

    for _, caseId in ipairs(levelCases) do
        local data = CasesModule[caseId]
        if data and xp >= (data.XPRequirement or 0) then            
            local remaining = Remote_CheckCooldown:InvokeServer(caseId)

            if remaining then
                local cooldownEnd = os.time() + remaining
                if cooldownEnd < State.NextLevelCase then
                    State.NextLevelCase = cooldownEnd
                    State.NextLevelCaseId = caseId
                end
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

local function CreateBattle(mode)
    if State.IsBusy then return end
    State.IsBusy = true
    
    mode = string.upper(mode)
    local id = Remote_CreateBattle:InvokeServer({"PERCHANCE"}, 2, mode, false)

    task.wait(math.random() * 0.8 + 1.2)

    if id then
        Remote_AddBot:FireServer(id, Player)

    end
    
    task.wait(math.random() * 0.2 + 0.3)
    UI_Main.Enabled = true
    UI_Windows.Enabled = true
    
    task.delay(math.random(13.5, 15.5), function()
        State.IsBusy = false
    end)
end

local function SellItems()
    -- Switch to logic that doesn't rely heavily on UI state if possible, 
    -- but reading inventory usually requires UI unless we parse remote data.
    -- We'll just read UI frames as it's reliable enough.
    
    local win = PlayerGui:FindFirstChild("CurrentWindow")
    if win then
        local prev = win.Value
        win.Value = "Inventory"
        task.wait(0.1)
        win.Value = prev
    end

    local toSell = {}
    local contents = UI_Inventory:FindFirstChild("InventoryFrame")
    if contents then contents = contents:FindFirstChild("Contents") end
    
    if contents then
        for _, frame in ipairs(contents:GetChildren()) do
            if frame:IsA("Frame") then
                local itemId = frame:GetAttribute("ItemId")
                local locked = frame:GetAttribute("locked")
                
                if itemId and not locked and not Whitelist[itemId] then
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
    -- Optimized find
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

--------------------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------------------

task.spawn(function()
    while true do
        task.wait(0.1)
        if State.IsBusy then continue end
        local now = os.time()

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
        if Config.AutoLightCase and State.CaseReady and GetBalance() > 140000 then
            if OpenCase("LIGHT", false, 5, true) then continue end
        end
        if Config.AutoTicketCase and GetTickets() >= 50 then
            if OpenCase("DivineCase", false, 5, false) then continue end
        end

        -- 5. Quest Battles
        local didBattle = false
        if Config.AutoQuestPlay or Config.AutoQuestWin then
             if true then
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
        end
        if didBattle then continue end

        -- 6. Quest Opening
        if Config.AutoQuestOpen then
            local q = GetQuest("Open")
            if q and q.Remaining > 0 then
                local qty = (q.Remaining > 5) and 5 or q.Remaining
                if OpenCase(q.Subject, false, qty, false) then continue end
            end
        end

        -- 7. Selected Case
        if Config.AutoOpenCase and Config.SelectedCase then
            OpenCase(Config.SelectedCase, false, Config.CaseQuantity, Config.WildMode)
        end
    end
end)


--------------------------------------------------------------------------------
-- RAYFIELD UI
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

local Label_Open = TabQuest:CreateLabel("Open: ...")
local Label_Play = TabQuest:CreateLabel("Play: ...")
local Label_Win  = TabQuest:CreateLabel("Win: ...")

task.spawn(function()
    while true do
        task.wait(3)
        local o, p, w = GetQuest("Open"), GetQuest("Play"), GetQuest("Win")
        Label_Open:Set(o and ("Open: "..o.Progress.."/"..o.Requirement.." "..o.Subject) or "Open: None")
        Label_Play:Set(p and ("Play: "..p.Progress.."/"..p.Requirement.." "..p.Subject) or "Play: None")
        Label_Win:Set(w and ("Win: "..w.Progress.."/"..w.Requirement) or "Win: None")
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
