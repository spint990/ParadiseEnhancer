-- ====================================
-- AUTO CASE OPENER + GIFTS + QUEST AUTOMATION
-- ====================================
-- Fonctionnalités:
--   • Auto-ouverture de cases (configurable)
--   • Auto-claim des gifts basé sur le temps de jeu
--   • Complétion automatique des quêtes (Open/Play/Win)
--   • Création automatique de battles avec bot
--   • Auto ouverture des cases LEVEL
-- ====================================

-- ====================================
-- SERVICES
-- ====================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

-- ====================================
-- RÉFÉRENCES JEU
-- ====================================
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local giftsFolder = ReplicatedStorage:WaitForChild("Gifts")

-- Modules du jeu (pour récupération dynamique des caisses)
local CasesModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Cases"))
local ItemsModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Items"))

-- Remotes
local openCaseRemote = remotes:WaitForChild("OpenCase")
local createBattleRemote = remotes:WaitForChild("CreateBattle")
local checkCooldownRemote = remotes:WaitForChild("CheckCooldown")
local addBotRemote = remotes:WaitForChild("AddBot")
local startBattleRemote = remotes:WaitForChild("StartBattle")
local sellRemote = remotes:WaitForChild("Sell")

-- Écouter le démarrage des batailles (silencieux)
startBattleRemote.OnClientEvent:Connect(function() end)

-- ====================================
-- CONSTANTES
-- ====================================
local CONFIG = {
    BATTLE_COOLDOWN = 8,
    AUTO_REJOIN_TIME = 60, -- Temps en secondes avant de rejoindre
}

local LEVEL_CASES = {
    "LEVEL10", "LEVEL20", "LEVEL30", "LEVEL40", "LEVEL50", "LEVEL60",
    "LEVEL70", "LEVEL80", "LEVEL90", "LEVELS100", "LEVELS110", "LEVELS120"
}

-- Cette table sera remplie dynamiquement depuis CasesModule
local AVAILABLE_CASES = {}

-- Fonction pour charger les caisses depuis le module du jeu
local function loadAvailableCases()
    
    for caseId, caseData in pairs(CasesModule) do
        -- Ne pas inclure les caisses admin only ni les caisses de niveau (LEVEL10, LEVELS100, etc.)
        local isLevelCase = caseId:match("^LEVEL%d+$") or caseId:match("^LEVELS%d+$")
        if not caseData.AdminOnly and not isLevelCase then
            -- Déterminer la devise (Tickets pour FESTIVE, sinon Cash/Balance)
            local currency = caseData.Currency or "Cash"
            
            table.insert(AVAILABLE_CASES, {
                id = caseId,
                name = caseData.Name or caseId,
                price = caseData.Price or 0,
                currency = currency,
                xpRequirement = caseData.XPRequirement,
                cooldown = caseData.Cooldown,
                category = caseData.Category or "Other",
                isNew = caseData.RecentlyAdded or false,
            })
        end
    end
    
    -- Trier : Caisses Tickets en premier, puis les autres par prix
    table.sort(AVAILABLE_CASES, function(a, b)
        -- Les caisses Tickets toujours en premier
        if a.currency == "Tickets" and b.currency ~= "Tickets" then return true end
        if a.currency ~= "Tickets" and b.currency == "Tickets" then return false end
        -- Sinon trier par prix
        return a.price < b.price
    end)
end

-- Charger les caisses au démarrage
loadAvailableCases()

-- ====================================
-- ÉTAT GLOBAL
-- ====================================
local State = {
    -- Toggles
    autoClaimGift = true,
    autoCase = true,
    autoQuestOpen = true,
    autoQuestPlay = true,
    autoQuestWin = true,
    autoOpenLevelCases = true,
    autoTeleportMeteor = false,
    autoRejoin = true,
    autoSell = false,
    
    -- Configuration
    selectedCase = AVAILABLE_CASES[1].id,
    itemWhitelist = {
        -- Ajoutez ici les items à ne jamais vendre
        ["ButterflyKnife_Frostwing"] = true,
        ["DriverGloves_RezantheRed"] = true,
        ["TitanHoloKato2014"] = true,
        ["M4A4_Gingerbread"] = true,
        ["DesertEagle_FreezingPoint"] = true,
    }, -- Items à ne jamais vendre
    caseQuantity = 5,
    wildMode = false,
    rejoinAtPlaytime = 3000, -- Playtime auquel rejoindre (en secondes) - 50 minutes
    
    -- Timers
    lastBattleCreateTime = 0,
    lastSellTime = 0,
    
    -- Level cases
    nextLevelCaseCooldown = 0,
    nextLevelCaseId = nil,
    
    -- Gifts
    nextGiftCooldown = 0,
    nextGiftId = nil,
    giftRequirements = {},
    
    -- Cooldown global pour toutes les caisses/gifts
    isCaseReady = true,
}

-- ====================================
-- INTERFACE RAYFIELD
-- ====================================
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "Auto Case & Gifts Helper",
    LoadingTitle = "Paradise Enchancer",
    LoadingSubtitle = "by Backlyne",
    Theme = "Default",
    ToggleUIKeybind = "K",
})

-- ====================================
-- FONCTIONS UTILITAIRES
-- ====================================
local function formatPrice(price, currency)
    currency = currency or "Cash"
    if price == 0 then return "Free" end
    
    if currency == "Tickets" then
        if price % 1 == 0 then return tostring(price) .. " GINGERBREAD" end
        return string.format("%.2f", price) .. " GINGERBREAD"
    else
        if price % 1 == 0 then return "$" .. tostring(price) end
        return "$" .. string.format("%.2f", price)
    end
end

-- Récupérer la Balance du joueur (monnaie principale)
local function getPlayerBalance()
    local balance = player.PlayerData.Currencies.Balance
    return balance and balance.Value or 0
end

-- Récupérer les Tickets (Gingerbread) du joueur
local function getPlayerTickets()
    local tickets = player.PlayerData.Currencies.Tickets
    return tickets and tickets.Value or 0
end

-- Récupérer l'XP du joueur (pour vérifier les cases LEVEL)
local function getPlayerExperience()
    local experience = player.PlayerData.Currencies.Experience
    return experience and experience.Value or 0
end

-- Récupérer le temps de jeu actuel du joueur
local function getCurrentPlayTime()
    local playTime = player.Playtime
    return playTime and playTime.Value or 0
end

local function getCasePrice(caseId)
    for _, caseData in ipairs(AVAILABLE_CASES) do
        if caseData.id == caseId then
            return caseData.price
        end
    end
    return 0
end

local function getWildPrice(caseId)
    local wildPriceValue = ReplicatedStorage.Misc.WildPrices:FindFirstChild(caseId)
    if wildPriceValue then
        return wildPriceValue.Value
    end
    return getCasePrice(caseId)
end

-- ====================================
-- FONCTIONS PRINCIPALES
-- ====================================

-- Masquer l'animation d'ouverture pendant toute la durée du cooldown
local function hideOpenAnimation()
    local openAnimation = playerGui.OpenAnimation
    local camera = workspace.CurrentCamera
    local main = playerGui.Main
    local windows = playerGui.Windows
    
    -- Sauvegarder le FOV initial pour le restaurer plus tard
    local originalFOV = camera.FieldOfView
    
    -- Connexion RenderStepped pour forcer les paramètres à chaque frame
    local connection
    connection = RunService.RenderStepped:Connect(function()
        if State.isCaseReady then
            -- Le cooldown est terminé, déconnecter et restaurer le FOV
            connection:Disconnect()
            camera.FieldOfView = originalFOV
            return
        end
        
        -- Forcer le FOV à 70 à chaque frame de rendu
        camera.FieldOfView = 70
        
        -- Forcer les écrans à être invisibles
        openAnimation.CaseOpeningScreen.Visible = false
        openAnimation.EndPreview.Visible = false
        
        -- Forcer Main et Windows à rester activés
        main.Enabled = true
        windows.Enabled = true
    end)
end

-- Vérifier si le joueur a assez d'argent pour ouvrir une case
local function hasEnoughMoney(caseId, quantity, useWild)
    local caseData = CasesModule[caseId]
    if not caseData then return false end
    
    local price = useWild and getWildPrice(caseId) or (caseData.Price or 0)
    
    -- Les cases gratuites sont toujours accessibles
    if price <= 0 then return true end
    
    local currency = caseData.Currency or "Cash"
    local totalCost = price * (quantity or 1)
    local playerMoney = currency == "Tickets" and getPlayerTickets() or getPlayerBalance()
    
    return playerMoney >= totalCost
end

-- Ouvrir un item (case ou gift)
local function openItem(itemName, isGift, quantity, useWild)
    -- Pour les gifts, utiliser "Gift" comme caseId pour la vérification
    local caseIdForCheck = isGift and "Gift" or itemName
    
    -- Vérifier le cooldown global et l'argent disponible
    if not State.isCaseReady or not hasEnoughMoney(caseIdForCheck, quantity, useWild) then
        return false
    end
    
    -- Mettre isCaseReady à false pour bloquer les ouvertures
    State.isCaseReady = false
    
    -- Lancer hideOpenAnimation immédiatement
    hideOpenAnimation()
    
    -- Appel serveur différent selon le type
    if isGift then
        openCaseRemote:InvokeServer(itemName, -1, false)
    else
        openCaseRemote:InvokeServer(itemName, quantity or 1, false, useWild or false)
    end
    
    -- Remettre le flag à true après 6 secondes
    task.delay(6, function()
        State.isCaseReady = true
    end)
    
    return true
end

-- Vérifier et retourner le premier gift disponible (dans l'ordre 1-9)
local function updateGiftCooldowns()
    State.nextGiftCooldown = math.huge
    State.nextGiftId = nil
    local availableNow = nil
    
    -- Parcourir les gifts dans l'ordre (1 à 9)
    for i = 1, 9 do
        local giftId = "Gift" .. i
        local claimedGift = player.ClaimedGifts:FindFirstChild(giftId)
        
        -- Vérifier si le gift n'a pas encore été claim
        if not claimedGift.Value then
            local cooldownEnd = checkCooldownRemote:InvokeServer(giftId)
            
            -- Si un gift est disponible maintenant, le retourner immédiatement (priorité au plus bas numéro)
            if cooldownEnd <= os.time() then
                if not availableNow then
                    availableNow = giftId
                end
            end
            
            -- Garder le prochain gift à venir (pour le warning)
            if not availableNow and cooldownEnd < State.nextGiftCooldown then
                State.nextGiftCooldown = cooldownEnd
                State.nextGiftId = giftId
            end
        end
    end
    
    -- Si un gift est disponible maintenant, mettre à jour les variables d'état
    if availableNow then
        State.nextGiftId = availableNow
        State.nextGiftCooldown = 0
    end
    
    return availableNow
end

-- Récupérer les données d'une quête par type
local function getQuestData(questType)
    local quests = player.PlayerData.Quests
    if not quests then return nil end
    
    for _, quest in ipairs(quests:GetChildren()) do
        if quest.Value == questType then
            local progress = quest.Progress
            local requirement = quest.Requirement
            local subject = quest.Subject
            
            if progress and requirement and subject then
                return {
                    progress = progress.Value,
                    requirement = requirement.Value,
                    subject = subject.Value,
                    remaining = requirement.Value - progress.Value
                }
            end
        end
    end
    return nil
end

-- Créer une battle avec un bot
local function createBattleWithBot(mode)
    local battleId = createBattleRemote:InvokeServer({"PERCHANCE"}, 2, mode, false)
    task.wait(1)
    addBotRemote:FireServer(battleId, player)
end

-- Vérifier et retourner la première case LEVEL disponible (basé sur XP requirement)
local function updateLevelCaseCooldowns()
    State.nextLevelCaseCooldown = math.huge
    State.nextLevelCaseId = nil
    local playerXP = getPlayerExperience()
    local availableNow = nil
    
    for _, caseId in ipairs(LEVEL_CASES) do
        local caseData = CasesModule[caseId]
        if caseData then
            local xpRequirement = caseData.XPRequirement or 0
            
            -- Vérifier si le joueur a assez d'XP
            if playerXP >= xpRequirement then
                local cooldownEnd = checkCooldownRemote:InvokeServer(caseId)
                
                if cooldownEnd < State.nextLevelCaseCooldown then
                    State.nextLevelCaseCooldown = cooldownEnd
                    State.nextLevelCaseId = caseId
                end
                
                if cooldownEnd <= os.time() and not availableNow then
                    availableNow = caseId
                end
            end
        end
    end
    
    return availableNow
end

-- Gérer l'état de l'UI Battle selon les toggles
local function updateBattleUIState()
    local battle = playerGui.Battle
    local battleFrame = battle.BattleFrame
    local isQuestActive = State.autoQuestWin or State.autoQuestPlay
    
    battle.Enabled = isQuestActive
    battleFrame.Visible = not isQuestActive
end

-- Garder Main et Windows activés si désactivés (seulement si quêtes auto actives)
local function keepUIEnabled()
    if not (State.autoQuestWin or State.autoQuestPlay) then return end
    
    local main = playerGui.Main
    local windows = playerGui.Windows
    
    if not main.Enabled then main.Enabled = true end
    if not windows.Enabled then windows.Enabled = true end
end

-- Rejoindre le serveur
local function rejoinServer()
    TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player)
end

-- Vendre tous les items non verrouillés de l'inventaire
local function sellUnlockedItems()
    -- Accéder à l'UI Inventory comme le fait le jeu
    local windowsGui = playerGui:FindFirstChild("Windows")
    if not windowsGui then return 0 end
    
    local inventoryWindow = windowsGui:FindFirstChild("Inventory")
    if not inventoryWindow then return 0 end
    
    local inventoryFrame = inventoryWindow:FindFirstChild("InventoryFrame")
    if not inventoryFrame then return 0 end
    
    local contents = inventoryFrame:FindFirstChild("Contents")
    if not contents then return 0 end
    
    local itemsToSell = {}
    
    -- Parcourir les frames GUI comme dans le script du jeu (ligne 383-410)
    for _, v in pairs(contents:GetChildren()) do
        if v:IsA("Frame") then
            -- Vérifier si l'item n'est pas verrouillé
            local isLocked = v:GetAttribute("locked")
            local itemId = v:GetAttribute("ItemId")
            
            -- Vérifier si l'item n'est pas verrouillé ET n'est pas dans la whitelist
            if not isLocked and itemId and not State.itemWhitelist[itemId] then
                local wearLabel = v:FindFirstChild("Wear")
                local stattrakLabel = v:FindFirstChild("Stattrak")
                local ageValue = v:FindFirstChild("Age")
                
                if wearLabel and stattrakLabel and ageValue then
                    table.insert(itemsToSell, {
                        Name = itemId,
                        Wear = wearLabel.Text,
                        Stattrak = stattrakLabel.Visible,
                        Age = ageValue.Value
                    })
                end
            end
        end
    end
    
    -- Vendre les items par batch
    if #itemsToSell > 0 then
        sellRemote:InvokeServer(itemsToSell)
        return #itemsToSell
    end
    
    return 0
end

-- ====================================
-- INTERFACE - TAB CASES
-- ====================================
local TabCases = Window:CreateTab("Cases", 4483362458)
TabCases:CreateSection("Case Auto-Opener")

local function getCaseDropdownOptions()
    local options = {}
    for _, caseData in ipairs(AVAILABLE_CASES) do
        local unitPrice = State.wildMode and getWildPrice(caseData.id) or caseData.price
        local totalPrice = unitPrice * State.caseQuantity
        local modeText = State.wildMode and " (Wild)" or ""
        table.insert(options, caseData.name .. modeText .. " " .. formatPrice(totalPrice, caseData.currency))
    end
    return options
end

local ToggleCases, DropdownCase

ToggleCases = TabCases:CreateToggle({
    Name = "Enable Auto Case Opening",
    CurrentValue = true,
    Flag = "AutoCaseOpen",
    Callback = function(value)
        State.autoCase = value
        if value then
            Rayfield:Notify({
                Title = "Auto Case Opening",
                Content = "Auto case opening enabled!",
                Duration = 3,
                Image = 4483362458,
            })
        end
    end,
})

DropdownCase = TabCases:CreateDropdown({
    Name = "Case to Open",
    Options = getCaseDropdownOptions(),
    CurrentOption = {AVAILABLE_CASES[1].name .. " " .. formatPrice(AVAILABLE_CASES[1].price, AVAILABLE_CASES[1].currency)},
    MultipleOptions = false,
    Flag = "SelectedCase",
    Callback = function(option)
        local optionName = type(option) == "table" and option[1] or option
        for _, caseData in ipairs(AVAILABLE_CASES) do
            if optionName:find(caseData.name, 1, true) == 1 then
                State.selectedCase = caseData.id
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
        local value = type(option) == "table" and option[1] or option
        State.caseQuantity = tonumber(value) or 1
        
        local newOptions = getCaseDropdownOptions()
        DropdownCase:Refresh(newOptions)
        
        if State.selectedCase then
            for _, caseData in ipairs(AVAILABLE_CASES) do
                if caseData.id == State.selectedCase then
                    local unitPrice = State.wildMode and getWildPrice(caseData.id) or caseData.price
                    local modeText = State.wildMode and " (Wild)" or ""
                    DropdownCase:Set(caseData.name .. modeText .. " " .. formatPrice(unitPrice * State.caseQuantity, caseData.currency))
                    break
                end
            end
        end
    end,
})

TabCases:CreateToggle({
    Name = "Wild Mode (Higher Cost)",
    CurrentValue = false,
    Flag = "WildMode",
    Callback = function(value)
        State.wildMode = value
        
        if value then
            Rayfield:Notify({
                Title = "Wild Mode",
                Content = "Wild mode enabled - Higher cost!",
                Duration = 3,
                Image = 4483362458,
            })
        end
        
        local newOptions = getCaseDropdownOptions()
        DropdownCase:Refresh(newOptions)
        
        if State.selectedCase then
            for _, caseData in ipairs(AVAILABLE_CASES) do
                if caseData.id == State.selectedCase then
                    local unitPrice = State.wildMode and getWildPrice(caseData.id) or caseData.price
                    local modeText = State.wildMode and " (Wild)" or ""
                    DropdownCase:Set(caseData.name .. modeText .. " " .. formatPrice(unitPrice * State.caseQuantity, caseData.currency))
                    break
                end
            end
        end
    end,
})

-- ====================================
-- INTERFACE - TAB QUESTS
-- ====================================
local TabQuests = Window:CreateTab("Quest", 4483362458)
TabQuests:CreateSection("Quest Auto-Completion")

TabQuests:CreateToggle({
    Name = "Auto Quest Open Cases",
    CurrentValue = true,
    Flag = "AutoQuestOpen",
    Callback = function(value)
        State.autoQuestOpen = value
        if value then
            Rayfield:Notify({
                Title = "Auto Quest Open",
                Content = "Auto quest open cases enabled!",
                Duration = 3,
                Image = 4483362458,
            })
        end
    end,
})

TabQuests:CreateToggle({
    Name = "Auto Quest Play Battles",
    CurrentValue = true,
    Flag = "AutoQuestPlay",
    Callback = function(value)
        State.autoQuestPlay = value
        if value then
            Rayfield:Notify({
                Title = "Auto Quest Play",
                Content = "Auto quest play battles enabled!",
                Duration = 3,
                Image = 4483362458,
            })
        end
        updateBattleUIState()
    end,
})

TabQuests:CreateToggle({
    Name = "Auto Quest Win Battles",
    CurrentValue = true,
    Flag = "AutoQuestWin",
    Callback = function(value)
        State.autoQuestWin = value
        if value then
            Rayfield:Notify({
                Title = "Auto Quest Win",
                Content = "Auto quest win battles enabled!",
                Duration = 3,
                Image = 4483362458,
            })
        end
        updateBattleUIState()
    end,
})

TabQuests:CreateSection("Status")
local LabelOpenCases = TabQuests:CreateLabel("Open Cases: -")
local LabelPlayBattles = TabQuests:CreateLabel("Play Battles: -")
local LabelWinBattles = TabQuests:CreateLabel("Win Battles: -")

local function updateQuestLabels()
    local openData = getQuestData("Open")
    local playData = getQuestData("Play")
    local winData = getQuestData("Win")
    
    if openData then
        local cost = openData.remaining * getCasePrice(openData.subject)
        LabelOpenCases:Set(string.format("Open Cases: %d/%d (%s) - Cost: %s", 
            openData.progress, openData.requirement, openData.subject, formatPrice(cost)))
    else
        LabelOpenCases:Set("Open Cases: - No quest")
    end
    
    if playData then
        LabelPlayBattles:Set(string.format("Play Battles: %d/%d (%s)", 
            playData.progress, playData.requirement, playData.subject))
    else
        LabelPlayBattles:Set("Play Battles: - No quest")
    end
    
    if winData then
        LabelWinBattles:Set(string.format("Win Battles: %d/%d", 
            winData.progress, winData.requirement))
    else
        LabelWinBattles:Set("Win Battles: - No quest")
    end
end

-- ====================================
-- INTERFACE - TAB MISC
-- ====================================
local TabMisc = Window:CreateTab("Misc", 4483362458)
TabMisc:CreateSection("Gift AutoClaiming")

TabMisc:CreateToggle({
    Name = "Auto claim gift",
    CurrentValue = true,
    Flag = "AutoClaimGift",
    Callback = function(value)
        State.autoClaimGift = value
        if value then
            Rayfield:Notify({
                Title = "Auto Claim Gift",
                Content = "Auto claim gifts enabled!",
                Duration = 3,
                Image = 4483362458,
            })
            updateGiftCooldowns()
        end
    end,
})

TabMisc:CreateToggle({
    Name = "Auto Open LEVEL Cases",
    CurrentValue = true,
    Flag = "AutoOpenLevelCases",
    Callback = function(value)
        State.autoOpenLevelCases = value
        if value then
            Rayfield:Notify({
                Title = "Auto Level Cases",
                Content = "Auto open LEVEL cases enabled!",
                Duration = 3,
                Image = 4483362458,
            })
            updateLevelCaseCooldowns()
        end
    end,
})

TabMisc:CreateSection("Teleport")

TabMisc:CreateToggle({
    Name = "Auto Teleport to Meteor",
    CurrentValue = false,
    Flag = "AutoTeleportMeteor",
    Callback = function(value)
        State.autoTeleportMeteor = value
        if value then
            Rayfield:Notify({
                Title = "Auto Teleport Meteor",
                Content = "Auto teleport to meteor enabled!",
                Duration = 3,
                Image = 4483362458,
            })
        end
    end,
})

TabMisc:CreateSection("Auto Rejoin")

TabMisc:CreateToggle({
    Name = "Auto Rejoin Server after 50min",
    CurrentValue = true,
    Flag = "AutoRejoin",
    Callback = function(value)
        State.autoRejoin = value
        if value then
            local currentPlayTime = getCurrentPlayTime()
            Rayfield:Notify({
                Title = "Auto Rejoin",
                Content = string.format("Auto rejoin at 50min playtime! (Current: %.1fmin)", currentPlayTime / 60),
                Duration = 3,
                Image = 4483362458,
            })
        end
    end,
})

TabMisc:CreateSection("Auto Sell")

TabMisc:CreateToggle({
    Name = "Auto Sell Unlocked Items",
    CurrentValue = false,
    Flag = "AutoSell",
    Callback = function(value)
        State.autoSell = value
        if value then
            Rayfield:Notify({
                Title = "Auto Sell",
                Content = "Auto sell unlocked items enabled!",
                Duration = 3,
                Image = 4483362458,
            })
        end
    end,
})

-- ====================================
-- BOUCLE PRINCIPALE
-- ====================================
RunService.Heartbeat:Connect(function(deltaTime)
    local currentTime = tick()
    
    -- Garder l'UI activée si nécessaire
    keepUIEnabled()
    
    -- Auto sell items (toutes les 10 secondes) - Pas de priorité, en parallèle
    if State.autoSell and currentTime - State.lastSellTime >= 10 then
        State.lastSellTime = currentTime
        sellUnlockedItems()
    end
    
    -- PRIORITÉ 0: Vérifier le playtime pour auto rejoin
    if State.autoRejoin then
        local currentPlayTime = getCurrentPlayTime()
        -- Rejoindre quand le playtime atteint la valeur cible (modulo pour gérer les cycles)
        if currentPlayTime % State.rejoinAtPlaytime == 0 and currentPlayTime > 0 then
            rejoinServer()
            return
        end
        -- Alternative: rejoindre à chaque multiple de rejoinAtPlaytime
        if currentPlayTime > 0 and currentPlayTime % State.rejoinAtPlaytime < 0.5 then
            rejoinServer()
            return
        end
    end
    
    -- PRIORITÉ 0: Auto claim gifts
    if State.autoClaimGift then
        if State.nextGiftCooldown <= os.time() and State.nextGiftId then
            if openItem(State.nextGiftId, true) then
                -- Marquer le gift comme claim
                player.ClaimedGifts[State.nextGiftId].Value = true
                task.delay(1, updateGiftCooldowns)
            end
        end
    end
    
    -- PRIORITÉ 1: Cases LEVEL
    if State.autoOpenLevelCases then
        if State.nextLevelCaseCooldown <= os.time() and State.nextLevelCaseId then
            if openItem(State.nextLevelCaseId, false, 1) then
                task.delay(1, updateLevelCaseCooldowns)
            end
        end
    end
    
    -- PRIORITÉ 2: Quest Open
    if State.autoQuestOpen then
        local openData = getQuestData("Open")
        if openData and openData.remaining > 0 then
            openItem(openData.subject, false, math.min(5, openData.remaining), false)
        end
    end
    
    -- PRIORITÉ 3: Auto case opener
    if State.autoCase then
        openItem(State.selectedCase, false, State.caseQuantity, State.wildMode)
    end
    
    -- Quest Play
    if State.autoQuestPlay then
        local playData = getQuestData("Play")
        if playData and playData.remaining > 0 and currentTime - State.lastBattleCreateTime >= CONFIG.BATTLE_COOLDOWN then
            State.lastBattleCreateTime = currentTime
            createBattleWithBot(string.upper(playData.subject))
        end
    end
    
    -- Quest Win (seulement si Play n'est pas actif ou pas de quête Play)
    if State.autoQuestWin and not (State.autoQuestPlay and getQuestData("Play")) then
        local winData = getQuestData("Win")
        if winData and winData.remaining > 0 and currentTime - State.lastBattleCreateTime >= CONFIG.BATTLE_COOLDOWN then
            State.lastBattleCreateTime = currentTime
            createBattleWithBot("CLASSIC")
        end
    end
    
    -- Mise à jour des labels
    updateQuestLabels()
end)

-- ====================================
-- INITIALISATION
-- ====================================

-- Détecter les météores dès qu'ils apparaissent dans workspace.Misc
local miscFolder = workspace:WaitForChild("Misc")

-- Fonction pour surveiller les nouveaux météores
local function watchForMeteors()
    miscFolder.ChildAdded:Connect(function(child)
        if State.autoTeleportMeteor and child.Name == "MeteorHitHitbox" and player.Character and player.Character.PrimaryPart then
            -- Attendre un court instant pour que le météore soit bien initialisé
            task.wait(0.05)
            
            -- Récupérer la position via la part "Hit"
            local hitPart = child:FindFirstChild("Hit")
            if hitPart and hitPart:IsA("BasePart") then
                local meteorPosition = hitPart.Position
                -- Se téléporter à la position X/Z du météore, Y au sol
                local targetPosition = Vector3.new(meteorPosition.X, 5, meteorPosition.Z)
                player.Character:SetPrimaryPartCFrame(CFrame.new(targetPosition))
            end
        end
    end)
end

-- Démarrer la surveillance
watchForMeteors()
