local utils = require("scripts/utils")
local qs_utils = require("scripts/qs_utils")

local handlers = {}

---@class SurfaceData
---@field surface_index uint
---@field surface LuaSurface
---@field type "platforms"|"planets"
---@field platform? LuaSpacePlatform
---@field hub? LuaEntity
---@field hub_inventory? LuaInventory
---@field planet? LuaPlanet
---@field rocket_silo? LuaEntity

function handlers.initialize_surfaces()
    for _, surface in pairs(game.surfaces) do
        handlers.initialize_surface(surface)
    end
end

---@param surface LuaSurface
function handlers.initialize_surface(surface)
    local surface_platform = surface.platform
    local surface_planet = surface.planet
    local surface_index = surface.index

    local data = {
        surface_index = surface_index,
        surface = surface,
    }
    handlers.initialize_fabricator_inventory(surface_index)

    if not surface_platform then
        data.type = "planets"
        if script.active_mods["factorissimo-2-notnotmelon"] and surface.name:find("%-factory%-floor$") then
            local planet_name = surface.name:gsub("%-factory%-floor", "")
            local planet_surface_index = storage.planet_surface_link[planet_name]
            storage.fabricator_inventory[surface_index] = storage.fabricator_inventory[planet_surface_index]
        end
        if settings.global["qf-unified-storage"].value then
            storage.fabricator_inventory[surface_index] = storage.fabricator_inventory[1]
        end
        local rocket_silo = surface.find_entities_filtered({type = "rocket-silo", limit = 1})[1]
        if rocket_silo then
            data.rocket_silo = rocket_silo
        end
        if surface_planet then
            data.planet = surface_planet
        end
    else
        data.type = "platforms"
        data.platform = surface_platform
        local hub = surface_platform.hub
        if hub then
            data.hub = hub
            data.hub_inventory = hub.get_inventory(defines.inventory.hub_main)
        end
    end
    storage.surface_data[data.type][surface_index] = data
end

function handlers.on_surface_created(event)
    local surface = game.surfaces[event.surface_index]
    update_planet_surface_link()
    handlers.initialize_surface(surface)
    utils.validate_surfaces()
end

function handlers.on_surface_deleted(event)
    local surface_index = event.surface_index
    utils.validate_surfaces()
    storage.fabricator_inventory[surface_index] = nil
    storage.surface_data.platforms[surface_index] = nil
    storage.surface_data.planets[surface_index] = nil
    if storage.space_sendoff_dirty_platforms then
        storage.space_sendoff_dirty_platforms[surface_index] = nil
    end
end

---@param surface_index uint
---@param value? uint
function handlers.initialize_fabricator_inventory(surface_index, value)
    local qualities = utils.get_qualities()
    for _, type in pairs({"item", "fluid"}) do
        for _, thing in pairs(prototypes[type]) do
            if not thing.parameter then
                for _, quality in pairs(qualities) do
                    local qs_item = {
                        name = thing.name,
                        type = type,
                        count = value,
                        quality = quality.name,
                        surface_index = surface_index
                    }
                    if qs_item.type == "fluid" then
                        qs_item.quality = QS_DEFAULT_QUALITY
                    end
                    qs_utils.storage_item_check(qs_item)
                    if value then
                        qs_utils.add_to_storage(qs_item)
                    end
                end
            end
        end
    end
end

return handlers
