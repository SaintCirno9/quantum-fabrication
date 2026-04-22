local flib_dictionary = require("__flib__.dictionary")
local tracking = require("scripts/tracking_utils")
local qs_utils = require("scripts/qs_utils")
local utils = require("scripts/utils")
local player_events = require("scripts/events/player")

local handlers = {}

function handlers.on_tick(event)
    flib_dictionary.on_tick(event)
    tracking.on_tick_update_digitizer_queues()
    qs_utils.process_decraft_queue(8)
    if storage.qf_enabled == false then return end
    tracking.on_tick_update_requests()
    tracking.update_lost_module_requests_neo()
end

function handlers.post_research_recheck()
    for _, player in pairs(game.players) do
        storage.player_gui[player.index].filtered_data_ok = false
    end
    process_ingredient_filter()
    process_recipe_enablement()
    handlers.find_trigger_techs()
end

function handlers.find_trigger_techs()
    storage.trigger_techs_actual = {}
    storage.trigger_techs_mine_actual = {}
    for name, prototype in pairs(storage.trigger_techs) do
        if utils.is_researchable(prototype.technology) then
            storage.trigger_techs_actual[name] = prototype
        end
    end
    for name, prototype in pairs(storage.trigger_techs_mine) do
        if utils.is_researchable(prototype.technology) then
            storage.trigger_techs_mine_actual[name] = prototype
        end
    end
end

function handlers.on_research_changed(event)
    Research_finished = true
end

function handlers.get_registered_nth_ticks()
    local nth_tick_map = {
        [11] = true,
        [29] = true,
        [338] = true,
    }
    for _, nth_tick in pairs(tracking.get_registered_nth_ticks()) do
        nth_tick_map[nth_tick] = true
    end
    for _, nth_tick in pairs(get_space_platform_nth_ticks()) do
        nth_tick_map[nth_tick] = true
    end
    local result = {}
    for nth_tick, _ in pairs(nth_tick_map) do
        table.insert(result, nth_tick)
    end
    return result
end

function handlers.on_registered_nth_tick(event)
    if event.nth_tick == 338 then
        if Research_finished then
            handlers.post_research_recheck()
            Research_finished = false
        end
    end
    if event.nth_tick == 29 then
        player_events.refresh_digitizer_hover_texts()
    end
    if event.nth_tick == 11 then
        for type, countdown in pairs(storage.countdowns) do
            if countdown then
                local gated_by_qf_toggle = type == "tile_creation" or type == "in_combat" or type == "tile_removal"
                if not gated_by_qf_toggle or storage.qf_enabled then
                    storage.countdowns[type] = storage.countdowns[type] - 1
                    if storage.countdowns[type] == 0 then
                        storage.countdowns[type] = nil
                        if type == "tile_creation" then
                            instant_tileation()
                            schedule_space_sendoff(2, nil, true)
                        elseif type == "temp_statistics" then
                            qs_utils.add_production_statistics()
                        elseif type == "in_combat" then
                            register_request_table("revivals")
                        elseif type == "tile_removal" then
                            instant_detileation()
                        end
                    end
                end
            end
        end
    end
    tracking.on_fixed_nth_tick(event)
    tracking.on_tracked_entity_nth_tick(event)
    on_space_platform_nth_tick(event)
end

function handlers.repair_tracking()
    utils.validate_surfaces()
    tracking.recheck_trackable_entities(true)
    tracking.sync_digitizer_chest_fluid_settings()
    tracking.rebuild_digitizer_chest_queues()
    tracking.recheck_all_item_request_proxies()
    register_request_table("revivals")
    register_request_table("destroys")
    register_request_table("upgrades")

    if not storage.countdowns.tile_creation then
        for _, surface_data in pairs(storage.surface_data.planets) do
            if surface_data.surface.count_entities_filtered({name = "tile-ghost"}) > 0 then
                storage.countdowns.tile_creation = 2
                break
            end
        end
    end

    if not storage.countdowns.tile_removal then
        for _, surface_data in pairs(storage.surface_data.planets) do
            if surface_data.surface.count_entities_filtered({type = "deconstructible-tile-proxy", force = "player"}) > 0 then
                storage.countdowns.tile_removal = 2
                break
            end
        end
    end

    schedule_space_sendoff(2, nil, true)
end

return handlers
