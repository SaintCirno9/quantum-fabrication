local tracking = require("scripts/tracking_utils")
local utils = require("scripts/utils")
local surface_events = require("scripts/events/surface")
local tick_events = require("scripts/events/tick")

local handlers = {}

function handlers.on_console_command(command)
    local player_index = command.player_index
    local name = command.name
    if name == "qf_hesoyam" then
        handlers.debug_storage(250000)
        game.print("CHEAT: Fabricator inventory updated")
    elseif name == "qf_repair_tracking" then
        tick_events.repair_tracking()
        game.print("Tracking repair finished")
    elseif name == "qf_update_module_requests" then
        tracking.update_lost_module_requests(game.get_player(player_index))
        game.print("Updating item request proxy tracking")
    elseif name == "qf_reprocess_recipes" then
        reprocess_recipes()
        game.print("Reprocessing recipes...")
    elseif name == "qf_debug_command" then
        game.print("Reprocessing recipes...")
        storage.unpacked_recipes = {}
        Product_craft_data_anti_overwrite_flag = true
        for product, _ in pairs(storage.duplicate_recipes) do
            table.sort(storage.product_craft_data[product], function(a, b) return a.suitability > b.suitability end)
        end
        process_tiles()
        process_entities()
        process_recipes()
        process_unpacking()
        process_ingredient_filter()
        Product_craft_data_anti_overwrite_flag = false
    end
end

function handlers.debug_storage(amount)
    utils.validate_surfaces()
    for surface_index, _ in pairs(storage.surface_data.planets) do
        surface_events.initialize_fabricator_inventory(surface_index, amount)
    end
end

return handlers
