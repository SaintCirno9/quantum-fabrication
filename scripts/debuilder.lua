local qs_utils = require("scripts/qs_utils")
local qf_utils = require("scripts/qf_utils")
local utils = require("scripts/utils")

local AMMO_LOADER_RETURN_SETTING = "ammo_loader_return_items"
local AMMO_LOADER_ENABLED_SETTING = "ammo_loader_enabled"
local AMMO_LOADER_BYPASS_RESEARCH_SETTING = "ammo_loader_bypass_research"
local AMMO_LOADER_RETURN_TECH = "ammo-loader-tech-return-items"
local AMMO_LOADER_BURNERS_TECH = "ammo-loader-tech-burners"
local AMMO_LOADER_VEHICLES_TECH = "ammo-loader-tech-vehicles"
local AMMO_LOADER_ARTILLERY_TECH = "ammo-loader-tech-artillery"
local AMMO_LOADER_BURNER_STRUCTURES_SETTING = "ammo_loader_fill_burner_structures"
local AMMO_LOADER_TRAINS_SETTING = "ammo_loader_fill_locomotives"
local AMMO_LOADER_ARTILLERY_SETTING = "ammo_loader_fill_artillery"
local AMMO_LOADER_CHEST_RADIUS_SETTING = "ammo_loader_chest_radius"
local AMMO_LOADER_STORAGE_CHEST = "ammo-loader-chest-storage"

local AMMO_LOADER_PROVIDER_CHESTS = {
    "ammo-loader-chest",
    "ammo-loader-chest-requester",
    "ammo-loader-chest-passive-provider"
}

local AMMO_LOADER_TRACKED_INVENTORIES = {
    [defines.inventory.turret_ammo] = true,
    [defines.inventory.car_ammo] = true,
    [defines.inventory.character_ammo] = true,
    [defines.inventory.artillery_turret_ammo] = true,
    [defines.inventory.artillery_wagon_ammo] = true,
    [defines.inventory.fuel] = true,
    [defines.inventory.roboport_material] = true
}

local AMMO_LOADER_MOVING_ENTITY_TYPES = {
    ["character"] = true,
    ["car"] = true,
    ["artillery-wagon"] = true,
    ["locomotive"] = true,
    ["spider-vehicle"] = true
}

local is_ammo_loader_tracked_inventory

local function is_ammo_loader_tech_available(force, tech_name)
    if settings.startup[AMMO_LOADER_BYPASS_RESEARCH_SETTING].value then return true end
    local technology = force.technologies[tech_name]
    return technology and technology.researched or false
end

local function can_ammo_loader_return(entity)
    if not script.active_mods["ammo-loader"] then return false end
    if not settings.global[AMMO_LOADER_ENABLED_SETTING].value then return false end
    if not settings.global[AMMO_LOADER_RETURN_SETTING].value then return false end
    return is_ammo_loader_tech_available(entity.force, AMMO_LOADER_RETURN_TECH)
end

local function get_ammo_loader_chest_search(entity)
    local radius = settings.global[AMMO_LOADER_CHEST_RADIUS_SETTING].value
    local search = {
        force = entity.force,
        name = AMMO_LOADER_PROVIDER_CHESTS
    }
    if radius > 0 then
        local position = entity.position
        search.area = {
            {position.x - radius, position.y - radius},
            {position.x + radius, position.y + radius}
        }
    end
    return search
end

local function try_insert_into_ammo_loader_chest(entity, stack, chest_names, match_item_only, prefer_storage_filter)
    local search = get_ammo_loader_chest_search(entity)
    search.name = chest_names
    local best_entity
    local best_has_filter = false
    local best_distance

    for _, chest in pairs(entity.surface.find_entities_filtered(search)) do
        local inventory = chest.get_inventory(defines.inventory.chest)
        if inventory and inventory.can_insert({name = stack.name, count = stack.count, quality = stack.quality}) then
            if not match_item_only or inventory.get_item_count(stack.name) > 0 then
                local filter = nil
                if prefer_storage_filter and chest.name == AMMO_LOADER_STORAGE_CHEST then
                    filter = chest.storage_filter
                end
                local has_filter = prefer_storage_filter and filter and filter.name == stack.name or false
                local dx = chest.position.x - entity.position.x
                local dy = chest.position.y - entity.position.y
                local distance = dx * dx + dy * dy
                if not best_entity
                    or (has_filter and not best_has_filter)
                    or (has_filter == best_has_filter and distance < best_distance) then
                    best_entity = chest
                    best_has_filter = has_filter
                    best_distance = distance
                end
            end
        end
    end

    if not best_entity then return 0 end
    return best_entity.get_inventory(defines.inventory.chest).insert({
        name = stack.name,
        count = stack.count,
        quality = stack.quality
    })
end

local function add_to_ammo_loader_system(entity, inventory_index, qs_item)
    if not is_ammo_loader_tracked_inventory(entity, inventory_index) then return 0 end
    local inserted = try_insert_into_ammo_loader_chest(entity, qs_item, AMMO_LOADER_PROVIDER_CHESTS, true, false)
    if inserted >= qs_item.count then return inserted end

    local remaining = {
        name = qs_item.name,
        count = qs_item.count - inserted,
        quality = qs_item.quality
    }
    return inserted + try_insert_into_ammo_loader_chest(entity, remaining, {AMMO_LOADER_STORAGE_CHEST}, false, true)
end

is_ammo_loader_tracked_inventory = function(entity, inventory_index)
    if not AMMO_LOADER_TRACKED_INVENTORIES[inventory_index] then return false end
    if not can_ammo_loader_return(entity) then return false end

    if inventory_index == defines.inventory.turret_ammo then
        return entity.type == "ammo-turret"
    elseif inventory_index == defines.inventory.car_ammo then
        if entity.type == "spider-vehicle" then
            return true
        end
        return entity.type == "car" and is_ammo_loader_tech_available(entity.force, AMMO_LOADER_VEHICLES_TECH)
    elseif inventory_index == defines.inventory.character_ammo then
        return entity.type == "character"
    elseif inventory_index == defines.inventory.artillery_turret_ammo then
        return entity.type == "artillery-turret"
            and settings.global[AMMO_LOADER_ARTILLERY_SETTING].value
            and is_ammo_loader_tech_available(entity.force, AMMO_LOADER_ARTILLERY_TECH)
    elseif inventory_index == defines.inventory.artillery_wagon_ammo then
        return entity.type == "artillery-wagon"
            and settings.global[AMMO_LOADER_ARTILLERY_SETTING].value
            and is_ammo_loader_tech_available(entity.force, AMMO_LOADER_ARTILLERY_TECH)
    elseif inventory_index == defines.inventory.fuel then
        if not entity.burner then return false end
        if not is_ammo_loader_tech_available(entity.force, AMMO_LOADER_BURNERS_TECH) then return false end
        if entity.type == "car" or entity.type == "locomotive" then
            if not is_ammo_loader_tech_available(entity.force, AMMO_LOADER_VEHICLES_TECH) then return false end
        elseif not AMMO_LOADER_MOVING_ENTITY_TYPES[entity.type]
            and not settings.global[AMMO_LOADER_BURNER_STRUCTURES_SETTING].value then
            return false
        end
        if entity.type == "locomotive" and not settings.global[AMMO_LOADER_TRAINS_SETTING].value then
            return false
        end
        return true
    elseif inventory_index == defines.inventory.roboport_material then
        return entity.name == "repair-turret"
    end

    return false
end

---@param entity LuaEntity
---@param player_index? int id of a player who placed the order
---@return boolean --returns false if defabrication failed AND we'll need to retry later; true otherwise
function instant_defabrication(entity, player_index)
    if not storage.prototypes_data[entity.name] or Non_deconstructable_entities[entity.name] then return false end
    if entity.surface.platform then return true end
    
    if Mine_to_inventory_only_entities[entity.name] then
        return try_mine(entity, player_index)
    end

    local surface_index = entity.surface_index
    local qs_item = {
        name = storage.prototypes_data[entity.name].item_name,
        count = 1,
        type = "item",
        quality = entity.quality.name,
        surface_index = surface_index
    }
    if not qs_item.name then game.print("instant_defabrication error - item name not found for " .. entity.ghost_name .. ", this shouldn't happen") return false end

    local player_inventory = utils.get_player_inventory(nil, player_index)
    process_inventory(entity, player_inventory, surface_index)
    if Transport_belt_types[entity.type] then
        process_transport_line(entity, player_inventory, surface_index)
    end

    local destroyed = entity.destroy({raise_destroy = true})
    if destroyed then
        qs_utils.add_to_storage(qs_item, true)
    end
    return destroyed
end

function instant_detileation()
    local function add_to_storage(indices, surface_index)
        for name, value in pairs(indices) do
            qs_utils.add_to_storage({name = name, type = "item", count = value, surface_index = surface_index, quality = QS_DEFAULT_QUALITY})
        end
    end

    local function set_hidden_tiles(surface, tiles)
        for _, tile in pairs(tiles) do
            if tile.double_hidden_tile then
                surface.set_hidden_tile(tile.position, tile.double_hidden_tile)
            end
        end
    end

    utils.validate_surfaces()
    for surface_index, surface_data in pairs(storage.surface_data.planets) do
        local surface = surface_data.surface
        local tiles = surface.find_tiles_filtered({to_be_deconstructed = true})
        if next(tiles) then
            local final_tiles = {}
            local indices = {}
            local final_index = 1
            for _, tile in pairs(tiles) do
                local hidden_tile = tile.hidden_tile
                local double_hidden_tile = tile.double_hidden_tile
                if hidden_tile then
                    final_tiles[final_index] = {
                        name = hidden_tile,
                        position = tile.position,
                        double_hidden_tile = double_hidden_tile
                    }
                    final_index = final_index + 1
                end
                indices[storage.tile_link[tile.name]] = (indices[storage.tile_link[tile.name]] or 0) + 1
            end
            surface.set_tiles(final_tiles, true, true, true, true)
            set_hidden_tiles(surface, final_tiles)
            add_to_storage(indices, surface_index)
        end
    end
end

---@param qs_item QSItem
function decraft(qs_item)
    local recipe, craftable_count = qf_utils.get_craftable_recipe(qs_item, nil, true, true)
    if recipe and craftable_count > 0 then
        qf_utils.fabricate_recipe(recipe, qs_item.quality, qs_item.surface_index, nil, qs_item.count, true, craftable_count)
    end
end

---@param entity LuaEntity
---@param player_inventory? LuaInventory
---@param surface_index uint
function process_inventory(entity, player_inventory, surface_index)
    if entity.type == "linked-container" then return end
    local max_index = entity.get_max_inventory_index()
    if not max_index then return end
    for i = 1, max_index do
        ---@diagnostic disable-next-line: param-type-mismatch
        local inventory = entity.get_inventory(i)
        if inventory and not inventory.is_empty() then
            local inventory_contents = inventory.get_contents()
            for _, item in pairs(inventory_contents) do
                local qs_item = {
                    name = item.name,
                    count = item.count,
                    type = "item",
                    quality = item.quality,
                    surface_index = surface_index
                }
                if is_ammo_loader_tracked_inventory(entity, i) then
                    local inserted = add_to_ammo_loader_system(entity, i, qs_item)
                    if inserted > 0 then
                        inventory.remove({name = qs_item.name, count = inserted, quality = qs_item.quality})
                    end
                    qs_item.count = qs_item.count - inserted
                end
                if qs_item.count > 0 then
                    qs_utils.add_to_player_inventory(player_inventory, qs_item)
                end
            end
        end
    end
end

---@param entity LuaEntity
---@param player_inventory? LuaInventory
---@param surface_index uint
function process_transport_line(entity, player_inventory, surface_index)
    local max_lines = entity.get_max_transport_line_index()
    for line = 1, max_lines do
        local transport_line = entity.get_transport_line(line)
        local contents = transport_line.get_contents()
        for _, item in pairs(contents) do
            local qs_item = {
                name = item.name,
                count = item.count,
                type = "item",
                quality = item.quality,
                surface_index = surface_index
            }
            qs_utils.add_to_player_inventory(player_inventory, qs_item)
        end
    end
end

---@param entity LuaEntity
---@param player_index? int
function instant_deforestation(entity, player_index)
    if not settings.global["qf-deconstruct-non-buildables"].value then return end
    local player_inventory = utils.get_player_inventory(nil, player_index)
    local prototype = entity.prototype
    local surface_index = entity.surface_index
    if prototype.loot then
        process_loot(prototype.loot, player_inventory, surface_index)
    end
    if prototype.mineable_properties and prototype.mineable_properties.products then
        process_mining(prototype.mineable_properties, player_inventory, surface_index)
    end
    if prototype.type == "item-entity" then
        if Non_deconstructable_entities[entity.stack.name] then return end
        if Mine_to_inventory_only_entities[entity.stack.name] then
            return try_mine(entity, player_index)
        end
        local qs_item = {
            name = entity.stack.name,
            count = entity.stack.count or 1,
            type = "item",
            quality = entity.stack.quality.name or QS_DEFAULT_QUALITY,
            surface_index = surface_index
        }
        qs_utils.add_to_player_inventory(player_inventory, qs_item)
    elseif prototype.type == "temporary-container" then
        process_inventory(entity, player_inventory, surface_index)
    end
    if storage.trigger_techs_mine_actual[entity.name] then
        utils.research_technology(storage.trigger_techs_mine_actual[entity.name].technology)
    end
    entity.destroy({raise_destroy = true})
end

---@param loot table
---@param player_inventory? LuaInventory
---@param surface_index uint
function process_loot(loot, player_inventory, surface_index)
    for _, item in pairs(loot) do
        if item.probability >= math.random() then
            local qs_item = {
                name = item.item,
                count = math.random(item.count_min, item.count_max),
                type = "item",
                surface_index = surface_index,
                quality = QS_DEFAULT_QUALITY
            }
            if qs_item.count > 0 then
                qs_utils.add_to_player_inventory(player_inventory, qs_item)
            end
        end
    end
end

---@param mining_properties table
---@param player_inventory? LuaInventory
---@param surface_index uint
function process_mining(mining_properties, player_inventory, surface_index)
    if not mining_properties or not mining_properties.products then return end
    for _, item in pairs(mining_properties.products) do
        if item.probability >= math.random() then
            local qs_item = {
                name = item.name,
                count = 1,
                type = "item",
                surface_index = surface_index,
                quality = item.quality or QS_DEFAULT_QUALITY
            }
            if item.amount then
                qs_item.count = item.amount
            else
                qs_item.count = math.random(item.amount_min, item.amount_max)
            end
            if qs_item.count > 0 then
                qs_utils.add_to_player_inventory(player_inventory, qs_item)
            end
        end
    end
end

---Handles removing cliffs via explosions
---@param entity LuaEntity
---@param player_index? uint
function instant_decliffing(entity, player_index)
    if not entity or not entity.valid then return true end
    local entity_prototype = entity.prototype
    local cliff_explosive = entity_prototype.cliff_explosive_prototype
    if not cliff_explosive then return true end
    local qualities = utils.get_qualities()
    for _, quality in pairs(qualities) do
        local qs_item = {
            name = cliff_explosive,
            count = 1,
            type = "item",
            quality = quality.name,
            surface_index = entity.surface_index
        }
        local player_inventory = utils.get_player_inventory(nil, player_index)
        local in_storage, _, total = qs_utils.count_in_storage(qs_item, player_inventory)
        if total > 0 then
            if in_storage > 0 then
                qs_utils.remove_from_storage(qs_item)
            else
                if player_inventory then
                    player_inventory.remove({name = qs_item.name, count = 1, quality = qs_item.quality})
                end
            end
            entity.destroy({raise_destroy = true})
            return true
        end
    end
    return false
end

---Mines the entity if valid player_index was provided
---@param entity LuaEntity
---@param player_index? uint
---@return boolean --true if entity was mined
function try_mine(entity, player_index)
    if player_index then
        local player = game.get_player(player_index)
        if player then
            return player.mine_entity(entity)
        end
    end
    return false
end
