-- CONFIGURATION
local DETECTION_PREFIX = "SMART_GC"
local DETECTION_RANGE = 5000
local DETECTION_INTERVAL = 10
local ALLY_PREFIX = "*"
local DEBUG = true
local LOG_ENABLED = false
local COOLDOWN_DURATION = 30  -- secondes d'attente avant de pouvoir poursuivre un nouvel ennemi

-- NOUVELLES CONFIGURATIONS D'OPTIMISATION
local MIN_MOVE_DISTANCE = 500  -- distance minimale pour créer une nouvelle route
local MAX_CONCURRENT_TRACKERS = 5  -- limite du nombre de poursuites simultanées
local ROUTE_UPDATE_INTERVAL = 15  -- intervalle de mise à jour des routes (secondes)
local TERRAIN_CHECK_POINTS = 3  -- nombre de points intermédiaires pour contournement

-- VARIABLES INTERNES
local markerIdCounter = 1
local detectedUnitsByGroup = {}
local detectionLog = {}
local groupMoveFlags = {}
local groupInitialPositions = {}
local groupCooldowns = {}
local groupInitialTasks = {}
local activeTrackers = 0  -- compteur de poursuites actives
local lastRouteUpdate = {}  -- timestamp dernière mise à jour route par groupe

-- DEBUG
local function debugMessage(msg)
    if DEBUG then
        trigger.action.outText("[DEBUG] " .. msg, 5)
    end
end

-- NETTOYAGE MÉMOIRE OPTIMISÉ
local function cleanMemory()
    local cleanedCount = 0
    for groupName, detectedTable in pairs(detectedUnitsByGroup) do
        for enemyUnit, _ in pairs(detectedTable) do
            if not enemyUnit or not enemyUnit:isExist() or enemyUnit:getLife() <= 0 then
                debugMessage("Nettoyage mémoire: " .. tostring(enemyUnit))
                detectedUnitsByGroup[groupName][enemyUnit] = nil
                cleanedCount = cleanedCount + 1
            end
        end
    end
    if cleanedCount > 0 then
        debugMessage("Mémoire nettoyée: " .. cleanedCount .. " unités supprimées")
    end
end

-- LOG DES DÉTECTIONS
local function logDetection(groupName, enemyName, distance, bearing)
    if LOG_ENABLED then
        table.insert(detectionLog, {
            time = timer.getAbsTime(),
            group = groupName,
            target = enemyName,
            distance = distance,
            bearing = bearing
        })
    end
end

-- VÉRIFIE LIGNE DE VUE AVEC CACHE
local lineOfSightCache = {}
local function hasLineOfSight(unit1, unit2)
    if not unit1 or not unit2 then return false end
    
    local cacheKey = tostring(unit1) .. "_" .. tostring(unit2)
    local currentTime = timer.getTime()
    
    -- Utiliser le cache si moins de 5 secondes
    if lineOfSightCache[cacheKey] and (currentTime - lineOfSightCache[cacheKey].time) < 5 then
        return lineOfSightCache[cacheKey].result
    end
    
    local result = land.isVisible(unit1:getPoint(), unit2:getPoint())
    lineOfSightCache[cacheKey] = {result = result, time = currentTime}
    
    return result
end

-- CALCUL CAP
local function calculateBearing(fromPos, toPos)
    local dx = toPos.x - fromPos.x
    local dz = toPos.z - fromPos.z
    local angle = math.deg(math.atan2(dz, dx))
    if angle < 0 then angle = angle + 360 end
    return math.floor(angle + 0.5) % 360
end

-- OBTENIR VITESSE OPTIMALE POUR UNE UNITÉ
local function getOptimalSpeed(unit)
    if not unit or not unit:isExist() then return 50 end
    
    local unitDesc = unit:getDesc()
    if unitDesc and unitDesc.speedMax then
        -- Utiliser 80% de la vitesse max de l'unité
        return unitDesc.speedMax * 0.8
    end
    
    return 50  -- valeur par défaut
end

-- CALCULER POINTS INTERMÉDIAIRES POUR CONTOURNEMENT TERRAIN
local function calculateIntermediatePoints(startPos, endPos, numPoints)
    local points = {}
    table.insert(points, startPos)
    
    for i = 1, numPoints do
        local ratio = i / (numPoints + 1)
        local interpX = startPos.x + (endPos.x - startPos.x) * ratio
        local interpZ = startPos.z + (endPos.z - startPos.z) * ratio
        local interpY = land.getHeight({x = interpX, y = interpZ})
        
        -- Ajouter une marge de sécurité en altitude
        if interpY then
            interpY = interpY + 10
        else
            interpY = startPos.y
        end
        
        table.insert(points, {x = interpX, y = interpY, z = interpZ})
    end
    
    table.insert(points, endPos)
    return points
end

-- ENVOI MESSAGES AUX ALLIÉS OPTIMISÉ
local messageCooldown = {}
local function sendMessageToAllies(enemyUnit, message)
    if not enemyUnit or not enemyUnit:isExist() then return end
    
    local messageKey = enemyUnit:getName()
    local currentTime = timer.getTime()
    
    -- Éviter le spam de messages (cooldown de 30 secondes par cible)
    if messageCooldown[messageKey] and (currentTime - messageCooldown[messageKey]) < 30 then
        return
    end
    messageCooldown[messageKey] = currentTime
    
    local coalitionSide = enemyUnit:getCoalition()
    local groups = coalition.getGroups(coalitionSide)
    for _, group in ipairs(groups or {}) do
        for _, unit in ipairs(group:getUnits() or {}) do
            if unit:isExist() and unit:getLife() > 0 then
                local unitName = unit:getName()
                if unitName and string.sub(unitName, 1, 1) == ALLY_PREFIX then
                    trigger.action.outTextForUnit(unit:getID(), message, 10)
                end
            end
        end
    end
end

-- MARQUEUR OPTIMISÉ
local function addMarkerToMap(unit, label)
    if DEBUG and unit and unit:isExist() then
        local pos = unit:getPoint()
        local markerId = markerIdCounter
        markerIdCounter = markerIdCounter + 1
        local markerPos = { x = pos.x, y = pos.y, z = pos.z }
        local text = label .. " (ID: " .. markerId .. ")"
        trigger.action.markToAll(markerId, text, markerPos)
        debugMessage("Marqueur ajouté: " .. label .. " avec ID " .. markerId)
        
        -- Auto-suppression du marqueur après 60 secondes
        timer.scheduleFunction(function()
            trigger.action.removeMark(markerId)
        end, nil, timer.getTime() + 60)
    end
end

-- SAUVEGARDE POSITION & TÂCHE INITIALE
local function saveInitialState(groupName)
    local group = Group.getByName(groupName)
    if group and group:isExist() then
        local units = group:getUnits()
        if #units > 0 then
            local position = units[1]:getPoint()
            groupInitialPositions[groupName] = position
            debugMessage(groupName .. " position initiale enregistrée.")
        end

        -- Sauvegarde de la mission avec MIST si disponible
        if mist and mist.getGroupRoute then
            local mistTask = mist.getGroupRoute(groupName, true)
            if mistTask then
                groupInitialTasks[groupName] = mistTask
                debugMessage(groupName .. " tâche initiale sauvegardée avec mist.")
            end
        end
    end
end

-- RETOUR À LA BASE AMÉLIORÉ
local function returnToOrigin(groupName)
    local group = Group.getByName(groupName)
    if not group or not group:isExist() then return end

    groupMoveFlags[groupName] = nil
    groupCooldowns[groupName] = timer.getTime() + COOLDOWN_DURATION
    activeTrackers = math.max(0, activeTrackers - 1)
    lastRouteUpdate[groupName] = nil

    -- Restauration de la mission initiale si disponible
    if groupInitialTasks[groupName] and mist and mist.goRoute then
        mist.goRoute(group, groupInitialTasks[groupName])
        debugMessage(groupName .. " retourne à sa tâche initiale.")
        return
    end

    -- Sinon, déplacement vers position initiale avec points intermédiaires
    local origin = groupInitialPositions[groupName]
    if origin then
        local currentPos = group:getUnits()[1]:getPoint()
        local optimalSpeed = getOptimalSpeed(group:getUnits()[1])
        
        -- Calculer points intermédiaires pour éviter le terrain
        local waypoints = calculateIntermediatePoints(currentPos, origin, 2)
        local routePoints = {}
        
        for i, point in ipairs(waypoints) do
            table.insert(routePoints, {
                x = point.x,
                y = point.z,
                action = "Off Road",
                speed = optimalSpeed,
                type = "Turning Point",
                formation = "Diamond",
                alt = point.y,
                alt_type = "BARO"
            })
        end
        
        local moveTask = {
            id = 'Mission',
            params = {
                route = {
                    points = routePoints
                }
            }
        }
        
        group:getController():setTask(moveTask)
        debugMessage(groupName .. " retourne à sa position initiale avec " .. #routePoints .. " waypoints.")
    end
end

-- POURSUITE DE L'ENNEMI AMÉLIORÉE
local function trackAndMoveGroupToEnemy(groupName, enemyUnit)
    if not enemyUnit or not enemyUnit:isExist() then return end

    -- Vérifier cooldown
    if groupCooldowns[groupName] and timer.getTime() < groupCooldowns[groupName] then
        debugMessage(groupName .. " est en cooldown.")
        return
    end
    
    -- Vérifier limite de poursuites simultanées
    if activeTrackers >= MAX_CONCURRENT_TRACKERS and not groupMoveFlags[groupName] then
        debugMessage("Limite de poursuites atteinte (" .. MAX_CONCURRENT_TRACKERS .. "), " .. groupName .. " en attente.")
        return
    end

    local function moveTask()
        local group = Group.getByName(groupName)
        if not group or not group:isExist() then
            groupMoveFlags[groupName] = nil
            activeTrackers = math.max(0, activeTrackers - 1)
            return
        end

        if not enemyUnit or not enemyUnit:isExist() or enemyUnit:getLife() <= 0 then
            debugMessage("Cible détruite ou non existante, retour du groupe: " .. groupName)
            returnToOrigin(groupName)
            return
        end

        local p1 = group:getUnits()[1]:getPoint()
        local p2 = enemyUnit:getPoint()
        local distance = math.sqrt((p1.x - p2.x)^2 + (p1.z - p2.z)^2)

        -- Vérifier si mise à jour nécessaire
        local currentTime = timer.getTime()
        local needsUpdate = false
        
        if not lastRouteUpdate[groupName] then
            needsUpdate = true
        elseif (currentTime - lastRouteUpdate[groupName]) > ROUTE_UPDATE_INTERVAL then
            needsUpdate = true
        elseif distance > MIN_MOVE_DISTANCE then
            needsUpdate = true
        end

        if distance > DETECTION_RANGE or not hasLineOfSight(group:getUnits()[1], enemyUnit) then
            debugMessage("Cible hors portée ou vue, retour: " .. groupName)
            returnToOrigin(groupName)
            return
        end

        -- Créer nouvelle route seulement si nécessaire
        if needsUpdate then
            local optimalSpeed = getOptimalSpeed(group:getUnits()[1])
            
            -- Calculer route avec points intermédiaires
            local waypoints = calculateIntermediatePoints(p1, p2, TERRAIN_CHECK_POINTS)
            local routePoints = {}
            
            for i, point in ipairs(waypoints) do
                table.insert(routePoints, {
                    x = point.x,
                    y = point.z,
                    action = "Off Road",
                    speed = optimalSpeed,
                    type = "Turning Point",
                    formation = "Diamond",
                    alt = point.y,
                    alt_type = "BARO"
                })
            end

            local task = {
                id = 'Mission',
                params = {
                    route = {
                        points = routePoints
                    }
                }
            }

            group:getController():setTask(task)
            lastRouteUpdate[groupName] = currentTime
            debugMessage(groupName .. " route mise à jour vers cible à " .. math.floor(distance) .. "m")
        end
        
        return timer.getTime() + ROUTE_UPDATE_INTERVAL
    end

    if not groupMoveFlags[groupName] then
        groupMoveFlags[groupName] = true
        activeTrackers = activeTrackers + 1
        timer.scheduleFunction(moveTask, nil, timer.getTime() + 1)
        debugMessage("Suivi de la cible démarré pour " .. groupName .. " (trackers actifs: " .. activeTrackers .. ")")
    end
end

-- FONCTION PRINCIPALE DE DÉTECTION OPTIMISÉE
local function detectEnemies()
    cleanMemory()
    
    local detectionCount = 0
    local processedGroups = 0

    for _, side in pairs({ coalition.side.BLUE, coalition.side.RED }) do
        local groups = coalition.getGroups(side)
        for _, group in ipairs(groups or {}) do
            local groupName = group:getName()
            if string.sub(groupName, 1, #DETECTION_PREFIX) == DETECTION_PREFIX then
                processedGroups = processedGroups + 1
                
                if not detectedUnitsByGroup[groupName] then
                    detectedUnitsByGroup[groupName] = {}
                    saveInitialState(groupName)
                end

                local groupUnits = group:getUnits() or {}
                for _, unit in ipairs(groupUnits) do
                    if unit:isExist() and unit:getLife() > 0 then
                        if DEBUG and processedGroups <= 3 then  -- Limiter les marqueurs de debug
                            addMarkerToMap(unit, "Détecteur: " .. unit:getName())
                        end

                        local enemySide = (side == coalition.side.BLUE) and coalition.side.RED or coalition.side.BLUE
                        local enemyGroups = coalition.getGroups(enemySide)

                        for _, enemyGroup in ipairs(enemyGroups or {}) do
                            local enemyUnits = enemyGroup:getUnits() or {}
                            for _, enemyUnit in ipairs(enemyUnits) do
                                if enemyUnit:isExist() and enemyUnit:getLife() > 0 then
                                    local p1 = unit:getPoint()
                                    local p2 = enemyUnit:getPoint()
                                    local distance = math.sqrt((p1.x - p2.x)^2 + (p1.z - p2.z)^2)

                                    if distance <= DETECTION_RANGE and hasLineOfSight(unit, enemyUnit) then
                                        if not detectedUnitsByGroup[groupName][enemyUnit] then
                                            detectedUnitsByGroup[groupName][enemyUnit] = true
                                            detectionCount = detectionCount + 1
                                            
                                            local bearing = calculateBearing(p2, p1)
                                            local message = string.format("%s détecte %s à %d m (cap %d°)", 
                                                groupName, enemyUnit:getName(), math.floor(distance), bearing)
                                            
                                            sendMessageToAllies(enemyUnit, message)
                                            logDetection(groupName, enemyUnit:getName(), math.floor(distance), bearing)
                                            trackAndMoveGroupToEnemy(groupName, enemyUnit)
                                        end
                                    else
                                        detectedUnitsByGroup[groupName][enemyUnit] = nil
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    if DEBUG and detectionCount > 0 then
        debugMessage("Cycle détection: " .. detectionCount .. " nouvelles détections, " .. 
                    processedGroups .. " groupes traités, " .. activeTrackers .. " poursuites actives")
    end

    return timer.getTime() + DETECTION_INTERVAL
end

-- FONCTION DE NETTOYAGE PÉRIODIQUE DU CACHE
local function cleanupCache()
    local currentTime = timer.getTime()
    local cleanedEntries = 0
    
    -- Nettoyer le cache de ligne de vue
    for key, data in pairs(lineOfSightCache) do
        if (currentTime - data.time) > 30 then  -- Cache expiré après 30 secondes
            lineOfSightCache[key] = nil
            cleanedEntries = cleanedEntries + 1
        end
    end
    
    -- Nettoyer le cooldown des messages
    for key, time in pairs(messageCooldown) do
        if (currentTime - time) > 60 then  -- Cooldown expiré après 60 secondes
            messageCooldown[key] = nil
        end
    end
    
    if DEBUG and cleanedEntries > 0 then
        debugMessage("Cache nettoyé: " .. cleanedEntries .. " entrées supprimées")
    end
    
    return timer.getTime() + 60  -- Nettoyer toutes les minutes
end

-- INITIALISATION & LANCEMENT DU SCRIPT
debugMessage("Système de détection SMART_GC initialisé")
debugMessage("Configuration: Portée=" .. DETECTION_RANGE .. "m, Intervalle=" .. DETECTION_INTERVAL .. "s")
debugMessage("Limites: Max trackers=" .. MAX_CONCURRENT_TRACKERS .. ", Points terrain=" .. TERRAIN_CHECK_POINTS)

timer.scheduleFunction(detectEnemies, nil, timer.getTime() + DETECTION_INTERVAL)
timer.scheduleFunction(cleanupCache, nil, timer.getTime() + 60)