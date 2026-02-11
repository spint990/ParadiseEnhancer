--[[
    Paradise Enhancer (Refactored)
    Executor: Volt
    Optimized & Human-Like
    NO CONFIG SAVING
]]

--------------------------------------------------------------------------------
-- INIT & SAFETY CHECKS
--------------------------------------------------------------------------------

if not game:IsLoaded() then game.Loaded:Wait() end

-- Prevent multiple executions
if getgenv().ParadiseEnhancerRunning then
    warn("Paradise Enhancer is already running!")
    return
end
getgenv().ParadiseEnhancerRunning = true

--------------------------------------------------------------------------------
-- SERVICES
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TeleportService   = game:GetService("TeleportService")
local VirtualInputManager = game:GetService("VirtualInputManager")

--------------------------------------------------------------------------------
-- VARIABLES & REFERENCES
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
}

local GiftsFolder = ReplicatedStorage:WaitForChild("Gifts")
local WildPrices  = ReplicatedStorage.Misc.WildPrices

local UI_Refs = {
    Main          = PlayerGui:WaitForChild("Main"),
    Windows       = PlayerGui:WaitForChild("Windows"),
    OpenAnimation = PlayerGui:WaitForChild("OpenAnimation"),
    Battle        = PlayerGui:WaitForChild("Battle"),
}
-- Initialize sub-references safely
UI_Refs.Inventory = UI_Refs.Windows:WaitForChild("Inventory")

-- Suppress battle event callbacks to avoid client-side clutter (optimization)
local battleConnection
battleConnection = Remote.StartBattle.OnClientEvent:Connect(function() end)

--------------------------------------------------------------------------------
-- CONFIGURATION (IN-MEMORY ONLY)
--------------------------------------------------------------------------------

local Config = {
    -- Features
    AutoOpenCase      = false,
    AutoClaimGift     = true,
    AutoQuestOpen     = true,
    AutoQuestPlay     = true,
    AutoQuestWin      = true,
    AutoLevelCases    = true,
    AutoGalaxyCase    = true,  -- >50 Tickets
    AutoKatowice      = true,  -- >140k Money
    AutoSell          = true,
    AutoMeteor        = true,
    RejoinOnGift9     = true,
    
    -- Settings
    SelectedCase      = "DivineCase",
    CaseQuantity      = 5,
    WildMode          = true,
    
    -- Whitelist (Items to keep)
    Whitelist = {
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
}

--------------------------------------------------------------------------------
-- UTILITIES & RANDOMIZATION
--------------------------------------------------------------------------------

local Utils = {}
local RNG = Random.new()

function Utils.RandomFloat(min, max)
    return RNG:NextNumber(min, max)
end

function Utils.RandomDelay(min, max)
    local t = RNG:NextNumber(min, max)
    task.wait(t)
    return t
end

function Utils.FormatPrice(price, currency)
    if price == 0 then return "Free" end
    local str = (price % 1 == 0) and tostring(price) or string.format("%.2f", price)
    return (currency == "Tickets") and (str .. " GINGERBREAD") or ("$" .. str)
end

function Utils.GetBalance()  return Currencies.Balance.Value end
function Utils.GetTickets()  return Currencies.Tickets.Value end
function Utils.GetXP()       return Currencies.Experience.Value end
function Utils.GetPlaytime() return Playtime.Value end

--------------------------------------------------------------------------------
-- GAME LOGIC MANAGERS
--------------------------------------------------------------------------------

local State = {
    IsBusy = false,
    CaseReady = true,
    NextSell = 0,
    NextLevelCase = math.huge,
    NextLevelCaseId = nil,
    LastBattle = 0,
}

-- MODULE: CASES
local CaseManager = {}
CaseManager.Cache = {}

function CaseManager:Init()
    for caseId, data in pairs(CasesModule) do
        if not data.AdminOnly and not caseId:match("^LEVELS?%d+$") then
            table.insert(self.Cache, {
                Id       = caseId,
                Name     = data.Name or caseId,
                Price    = data.Price or 0,
                Currency = data.Currency or "Cash",
            })
        end
    end
    table.sort(self.Cache, function(a, b)
        if a.Currency == "Tickets" and b.Currency ~= "Tickets" then return true end
        if a.Currency ~= "Tickets" and b.Currency == "Tickets" then return false end
        return a.Price < b.Price
    end)
end

function CaseManager:GetPrice(caseId)
    local data = CasesModule[caseId]
    return data and data.Price or 0
end

function CaseManager:GetWildPrice(caseId)
    local obj = WildPrices:FindFirstChild(caseId)
    return obj and obj.Value or self:GetPrice(caseId)
end

function CaseManager:CanAfford(caseId, qty, useWild)
    if caseId:match("^Gift%d?$") then return true end
    local data = CasesModule[caseId]
    if not data then return false end
    
    local price = useWild and self:GetWildPrice(caseId) or (data.Price or 0)
    if price <= 0 then return true end
    
    local total = price * (qty or 1)
    local balance = (data.Currency == "Tickets") and Utils.GetTickets() or Utils.GetBalance()
    return balance >= total
end

-- Suppress opening animation for speed/optimization
local SuppressConnection
function CaseManager:StartSuppression()
    if SuppressConnection then return end

    local cam = workspace.CurrentCamera
    local openScreen = UI_Refs.OpenAnimation.CaseOpeningScreen
    local endPreview = UI_Refs.OpenAnimation.EndPreview
    
    SuppressConnection = RunService.Heartbeat:Connect(function()
        if State.CaseReady then
            if SuppressConnection then
                SuppressConnection:Disconnect()
                SuppressConnection = nil
            end
            return
        end
        if cam.FieldOfView ~= 70 then cam.FieldOfView = 70 end
        openScreen.Visible = false
        endPreview.Visible = false
        UI_Refs.Main.Enabled = true
        UI_Refs.Windows.Enabled = true
    end)
end

function CaseManager:Open(caseId, isGift, qty, useWild)
    local checkId = isGift and "Gift" or caseId
    -- Check if we recently failed this case (anti-spam)
    if self.Cache[checkId] and self.Cache[checkId].FailedTime and (os.time() - self.Cache[checkId].FailedTime) < 60 then
        return false
    end

    State.CaseReady = false
    State.IsBusy = true
    self:StartSuppression()
    
    -- Human behavior simulation
    Utils.RandomDelay(0.15, 0.4) 
    
    local success = false
    local result = nil
    
    if isGift then
        result = Remote.OpenCase:InvokeServer(caseId, -1, false)
    else
        result = Remote.OpenCase:InvokeServer(caseId, qty or 1, false, useWild or false)
    end
    
    if type(result) == "table" and next(result) then
        success = true
        self:RefreshGameUI() -- Update UI manually
    else
        -- Mark as failed to avoid spamming
        if not self.Cache[checkId] then self.Cache[checkId] = {} end
        self.Cache[checkId].FailedTime = os.time()
        
        -- If it was a level case, force update cooldowns
        if caseId:match("^LEVEL") then
             self:UpdateLevelCooldowns() 
        end
    end
    
    -- Cooldown & Busy Management
    task.delay(Utils.RandomFloat(8.0, 12.0), function()
        State.CaseReady = true
        State.IsBusy = false
    end)
    
    return success
end

function CaseManager:RefreshGameUI()
    -- Native Refresh: Trigger the game's loop to update UI by temporarily switching window state
    -- This mirrors EconomyManager:RefreshInventoryUI pattern and uses game's own logic (v_u_51)
    local win = PlayerGui:FindFirstChild("CurrentWindow")
    if not win then return end
    
    local prev = win.Value
    if prev == "Cases" then return end -- Already updating
    
    win.Value = "Cases"
    task.wait(0.1) -- Allow game loop to iterate
    win.Value = prev
end

function CaseManager:UpdateLevelCooldowns()
    State.NextLevelCase = math.huge
    State.NextLevelCaseId = nil
    
    -- Don't check if we are busy interacting
    if State.IsBusy then return end

    local xp = Utils.GetXP()
    
    local LevelCasesList = {
        "LEVEL10", "LEVEL20", "LEVEL30", "LEVEL40", "LEVEL50", "LEVEL60",
        "LEVEL70", "LEVEL80", "LEVEL90", "LEVELS100", "LEVELS110", "LEVELS120",
    }
    
    for _, caseId in ipairs(LevelCasesList) do
        local data = CasesModule[caseId]
        if data and xp >= (data.XPRequirement or 0) then
            -- Check our internal cache to avoid spamming known failed cases
            if self.Cache[caseId] and self.Cache[caseId].FailedTime and (os.time() - self.Cache[caseId].FailedTime) < 60 then
                continue 
            end

            -- Safe invoke
            local cooldown = Remote.CheckCooldown:InvokeServer(caseId) or math.huge
            
            -- If cooldown is basically now (0 or very small), it means ready
            -- But we compare against OS time. 
            -- Game logic: returns timestamp when it unlocks.
            -- If return is < os.time(), it IS ready.
            
            if cooldown < State.NextLevelCase then
                State.NextLevelCase = cooldown
                State.NextLevelCaseId = caseId
            end
        end
    end
end

-- MODULE: BATTLES
local BattleManager = {}

function BattleManager:HideUI()
    if UI_Refs.Battle and UI_Refs.Battle:FindFirstChild("BattleFrame") then
        UI_Refs.Battle.BattleFrame.Visible = false
    end
    UI_Refs.Main.Enabled = true
    UI_Refs.Windows.Enabled = true
end

function BattleManager:CreateBot(mode)
    if State.IsBusy then return end
    State.IsBusy = true
    
    Utils.RandomDelay(0.3, 0.6)
    local id = Remote.CreateBattle:InvokeServer({"PERCHANCE"}, 2, mode, false)
    task.wait(Utils.RandomFloat(0.8, 1.2))
    
    if id then
        Remote.AddBot:FireServer(id, Player)
    end
    
    -- Occupy state for duration of logic
    task.delay(Utils.RandomFloat(4.5, 6.5), function()
        State.IsBusy = false
    end)
end

-- MODULE: ECONOMY (SELLING)
local EconomyManager = {}

function EconomyManager:RefreshInventoryUI()
    local win = PlayerGui:FindFirstChild("CurrentWindow")
    if not win then return end
    local prev = win.Value
    win.Value = "Inventory"
    task.wait(0.1)
    win.Value = prev
end

function EconomyManager:SellUnlocked()
    self:RefreshInventoryUI()
    task.wait(0.5)
    
    local toSell = {}
    local invFrame = UI_Refs.Inventory:FindFirstChild("InventoryFrame")
    if invFrame and invFrame:FindFirstChild("Contents") then
        for _, frame in pairs(invFrame.Contents:GetChildren()) do
            if frame:IsA("Frame") then
                local itemId = frame:GetAttribute("ItemId")
                local locked = frame:GetAttribute("locked")
                
                -- Check blacklist/whitelist
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
        Utils.RandomDelay(0.8, 1.6)
        Remote.Sell:InvokeServer(toSell)
    end
end

-- MODULE: EXTRAS (METEOR & REJOIN)
local ExtrasManager = {}
ExtrasManager.Meteor = { Walking = false, Target = nil }

function ExtrasManager:StopWalking()
    self.Meteor.Walking = false
    self.Meteor.Target = nil
end

function ExtrasManager:WalkTo(targetPos)
    if self.Meteor.Walking then
        self.Meteor.Target = targetPos
        return
    end
    
    self.Meteor.Walking = true
    self.Meteor.Target = targetPos
    
    task.spawn(function()
        local hum = Player.Character and Player.Character:FindFirstChild("Humanoid")
        local root = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
        
        if not hum or not root then
            self:StopWalking()
            return
        end
        
        hum:MoveTo(targetPos)
        
        local lastPos = root.Position
        local stuckCount = 0
        
        while self.Meteor.Walking and self.Meteor.Target do
            hum = Player.Character and Player.Character:FindFirstChild("Humanoid")
            root = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
            if not hum or not root then break end
            
            local target = self.Meteor.Target
            local dist = (Vector3.new(root.Position.X, target.Y, root.Position.Z) - target).Magnitude
            if dist <= 5 then break end
            
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
            
            if self.Meteor.Target ~= target then break end
            task.wait(0.25)
        end
        
        self:StopWalking()
    end)
end

function ExtrasManager:InitMeteor()
    local temp = workspace:WaitForChild("Temp", 10)
    if not temp then return end
    
    local function checkChild(child)
        if not Config.AutoMeteor then return end
        if child.Name == "MeteorHitHitbox" then
            local hit = child:WaitForChild("Hit", 2)
            if hit then self:WalkTo(hit.Position) end
        elseif child:IsA("BasePart") and child.Name == "Hit" then
            self:WalkTo(child.Position)
        end
    end
    
    for _, child in ipairs(temp:GetChildren()) do checkChild(child) end
    temp.ChildAdded:Connect(checkChild)
    temp.ChildRemoved:Connect(function(child)
        if child.Name == "MeteorHitHitbox" then
             task.delay(0.5, function()
                for _, c in ipairs(temp:GetChildren()) do
                    if c.Name == "MeteorHitHitbox" then return end
                end
                self:StopWalking()
            end)
        end
    end)
end

function ExtrasManager:Rejoin()
    if #Players:GetPlayers() <= 1 then
        Player:Kick("\n[Paradise Enhancer] Rejoining for new server...")
        task.wait()
        TeleportService:Teleport(game.PlaceId, Player)
    else
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, Player)
    end
end

--------------------------------------------------------------------------------
-- MAIN LOGIC
--------------------------------------------------------------------------------

local function GetQuestData(questType)
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

local function MainLoop()
    while true do
        Utils.RandomDelay(0.7, 0.9)
        
        if State.IsBusy then continue end
        local now = tick()
        
        -- UI Cleanup
        if Config.AutoQuestWin or Config.AutoQuestPlay then
            BattleManager:HideUI()
        end
        
        -- 1. Auto Sell
        if Config.AutoSell and now >= State.NextSell then
            State.NextSell = now + Utils.RandomFloat(120, 300)
            State.IsBusy = true
            task.spawn(function()
                EconomyManager:SellUnlocked()
                State.IsBusy = false
            end)
            continue
        end
        
        -- 2. Gifts
        if Config.AutoClaimGift then
            local giftId = nil
            local pt = Utils.GetPlaytime()
            local GiftPlaytimes = {} -- Cache localized
            for i=1,9 do 
                local val = GiftsFolder:FindFirstChild("Gift"..i)
                if val then GiftPlaytimes["Gift"..i] = val.Value end
            end
            
            for i = 1, 9 do
                local id = "Gift" .. i
                local claimed = ClaimedGifts:FindFirstChild(id) and ClaimedGifts[id].Value
                if not claimed and pt >= (GiftPlaytimes[id] or math.huge) then
                    giftId = id
                    break
                end
            end
            
            if giftId then
                if CaseManager:Open(giftId, true) then
                    -- Mark claimed locally for visual update
                    task.delay(1, function()
                        local g = ClaimedGifts:FindFirstChild(giftId)
                        if g then g.Value = true end
                    end)
                    
                    if giftId == "Gift9" and Config.RejoinOnGift9 then
                        Utils.RandomDelay(2.5, 4.5)
                        ExtrasManager:Rejoin()
                    end
                    continue
                end
            end
        end
        
        -- 3. Level Cases
        if Config.AutoLevelCases and State.NextLevelCaseId and State.NextLevelCase <= os.time() then
            if CaseManager:Open(State.NextLevelCaseId, false, 1) then
                task.delay(1.5, function() CaseManager:UpdateLevelCooldowns() end)
                continue
            end
        end
        
        -- 4. High Value Cases (Katowice/Galaxy)
        if Config.AutoKatowice and State.CaseReady and Utils.GetBalance() > 140000 then
            if CaseManager:Open("LIGHT", false, 5, true) then continue end
        end
        
        if Config.AutoGalaxyCase and Utils.GetTickets() >= 50 then
            if CaseManager:Open("DivineCase", false, 5, false) then continue end
        end
        
        -- 5. Quest Battles
        local battleAction = false
        if Config.AutoQuestPlay and not battleAction then
            local q = GetQuestData("Play")
            if q and q.Remaining > 0 and (now - State.LastBattle) >= Utils.RandomFloat(14, 18) then
                State.LastBattle = now
                BattleManager:CreateBot(string.upper(q.Subject))
                battleAction = true
            end
        end
        
        if Config.AutoQuestWin and not battleAction then
            local q = GetQuestData("Win")
            if q and q.Remaining > 0 and (now - State.LastBattle) >= Utils.RandomFloat(14, 18) then
                State.LastBattle = now
                BattleManager:CreateBot("CLASSIC")
                battleAction = true
            end
        end
        
        if battleAction then continue end
        
        -- 6. Quest Opening
        if Config.AutoQuestOpen then
            local q = GetQuestData("Open")
            if q and q.Remaining > 0 then
                local qty = math.min(5, q.Remaining)
                if CaseManager:Open(q.Subject, false, qty, false) then continue end
            end
        end
        
        -- 7. Selected Case (Default)
        if Config.AutoOpenCase and Config.SelectedCase then
            CaseManager:Open(Config.SelectedCase, false, Config.CaseQuantity, Config.WildMode)
        end
    end
end

--------------------------------------------------------------------------------
-- RAYFIELD UI
--------------------------------------------------------------------------------

local Rayfield = loadstring(game:HttpGet('https://raw.githubusercontent.com/spint990/ParadiseEnhancer/refs/heads/main/Rayfield'))()
local Window = Rayfield:CreateWindow({
    Name = "Paradise Enhancer",
    LoadingTitle = "Paradise Enhancer",
    LoadingSubtitle = "by Backlyne",
    Theme = "Default",
    ToggleUIKeybind = "K",
})

-- Prepare Data for Dropdown
CaseManager:Init()
local CaseDropdown
local function RefreshDropdown()
    if not CaseDropdown then return end
    local opts = {}
    for _, c in ipairs(CaseManager.Cache) do
        local price = Config.WildMode and CaseManager:GetWildPrice(c.Id) or c.Price
        local total = price * Config.CaseQuantity
        local wild = Config.WildMode and " (Wild)" or ""
        table.insert(opts, c.Name .. wild .. " " .. Utils.FormatPrice(total, c.Currency))
    end
    CaseDropdown:Refresh(opts)
end

-- TABS
local TabMain  = Window:CreateTab("Cases", 4483362458)
local TabQuest = Window:CreateTab("Quests", 4483362458)
local TabAuto  = Window:CreateTab("Automation", 4483362458)

-- TAB: CASES
TabMain:CreateSection("Case Control")

TabMain:CreateToggle({
    Name = "Auto Open Selected",
    CurrentValue = Config.AutoOpenCase,
    Flag = "AutoOpenCase",
    Callback = function(v) 
        Config.AutoOpenCase = v 
    end,
})

CaseDropdown = TabMain:CreateDropdown({
    Name = "Select Case",
    Options = {"Loading..."}, -- Will be refreshed instantly
    CurrentOption = {"Loading..."},
    MultipleOptions = false,
    Flag = "SelectedCase",
    Callback = function(opt)
        local name = type(opt) == "table" and opt[1] or opt
        for _, c in ipairs(CaseManager.Cache) do
            if name:find(c.Name, 1, true) == 1 then
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

-- TAB: QUESTS
TabQuest:CreateSection("Quest Automation")
TabQuest:CreateToggle({
    Name = "Auto Quest: Open Cases",
    CurrentValue = Config.AutoQuestOpen,
    Flag = "AutoQuestOpen",
    Callback = function(v) Config.AutoQuestOpen = v end,
})
TabQuest:CreateToggle({
    Name = "Auto Quest: Play Battles",
    CurrentValue = Config.AutoQuestPlay,
    Flag = "AutoQuestPlay",
    Callback = function(v) 
        Config.AutoQuestPlay = v
        if v then BattleManager:HideUI() end
    end,
})
TabQuest:CreateToggle({
    Name = "Auto Quest: Win Battles",
    CurrentValue = Config.AutoQuestWin,
    Flag = "AutoQuestWin",
    Callback = function(v)
        Config.AutoQuestWin = v
        if v then BattleManager:HideUI() end
    end,
})

-- Label Updating
local Labels = {
    Open = TabQuest:CreateLabel("Open: ..."),
    Play = TabQuest:CreateLabel("Play: ..."),
    Win  = TabQuest:CreateLabel("Win: ..."),
}
task.spawn(function()
    while true do
        local o, p, w = GetQuestData("Open"), GetQuestData("Play"), GetQuestData("Win")
        if o then Labels.Open:Set("Open: " .. o.Progress .. "/" .. o.Requirement .. " " .. o.Subject) else Labels.Open:Set("Open: None") end
        if p then Labels.Play:Set("Play: " .. p.Progress .. "/" .. p.Requirement .. " " .. p.Subject) else Labels.Play:Set("Play: None") end
        if w then Labels.Win:Set("Win: "  .. w.Progress .. "/" .. w.Requirement .. " Wins")       else Labels.Win:Set("Win: None")  end
        task.wait(3)
    end
end)


-- TAB: AUTOMATION
TabAuto:CreateSection("Economy & Items")
TabAuto:CreateToggle({
    Name = "Auto Sell (Blacklist Safe)",
    CurrentValue = Config.AutoSell,
    Flag = "AutoSell",
    Callback = function(v) Config.AutoSell = v end,
})
TabAuto:CreateToggle({
    Name = "Claim Gifts",
    CurrentValue = Config.AutoClaimGift,
    Flag = "AutoClaimGift",
    Callback = function(v) Config.AutoClaimGift = v end,
})
TabAuto:CreateToggle({
    Name = "Rejoin on Gift 9",
    CurrentValue = Config.RejoinOnGift9,
    Flag = "RejoinOnGift9",
    Callback = function(v) Config.RejoinOnGift9 = v end,
})

TabAuto:CreateSection("Advanced Cases")
TabAuto:CreateToggle({
    Name = "Auto Level Cases",
    CurrentValue = Config.AutoLevelCases,
    Flag = "AutoLevelCases",
    Callback = function(v) 
        Config.AutoLevelCases = v
        if v then CaseManager:UpdateLevelCooldowns() end
    end,
})
TabAuto:CreateToggle({
    Name = "Auto Galaxy (>50 Tickets)",
    CurrentValue = Config.AutoGalaxyCase,
    Flag = "AutoGalaxyCase",
    Callback = function(v) Config.AutoGalaxyCase = v end,
})
TabAuto:CreateToggle({
    Name = "Auto Katowice (>140k Money)",
    CurrentValue = Config.AutoKatowice,
    Flag = "AutoKatowice",
    Callback = function(v) Config.AutoKatowice = v end,
})

TabAuto:CreateSection("Events")
TabAuto:CreateToggle({
    Name = "Meteor Walk",
    CurrentValue = Config.AutoMeteor,
    Flag = "AutoMeteor",
    Callback = function(v) 
        Config.AutoMeteor = v
        if not v then ExtrasManager:StopWalking() end
    end,
})

--------------------------------------------------------------------------------
-- STARTUP
--------------------------------------------------------------------------------

-- Initial refreshes
RefreshDropdown()
if Config.AutoLevelCases then CaseManager:UpdateLevelCooldowns() end
ExtrasManager:InitMeteor()

task.spawn(MainLoop)

Rayfield:Notify({
    Title = "Paradise Enhancer",
    Content = "Script Loaded. Optimized for Volt.",
    Duration = 5,
    Image = 4483362458,
})
