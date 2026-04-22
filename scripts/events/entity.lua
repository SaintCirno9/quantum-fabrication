local utils = require("scripts/utils")
local tracking = require("scripts/tracking_utils")
local chunks_utils = require("scripts/chunks_utils")
local shared = require("scripts/events/shared")

local handlers = {}

function handlers.on_built_entity(event)
    local entity = event.entity
    local player_index = event.player_index
    if player_index and not settings.get_player_settings(player_index)["qf-use-player-inventory"].value then
        player_index = nil
    end
    if entity and entity.valid then
        chunks_utils.add_chunk(entity.surface_index, entity.position)
        if entity.type == "entity-ghost" then
            tracking.create_tracked_request({
                request_type = "revivals",
                entity = entity,
                player_index = player_index
            })
            schedule_space_sendoff(2, nil, true)
        elseif entity.type == "tile-ghost" then
            storage.countdowns.tile_creation = 10
            storage.request_player_ids.tiles = player_index
            goto continue
        end
        if Trackable_entities[entity.name] then
            tracking.create_tracked_request({request_type = "entities", entity = entity, player_index = event.player_index})
            if event.tags and event.tags.qf_entity_settings then
                tracking.apply_blueprint_settings(entity, event.tags.qf_entity_settings)
            else
                shared.apply_recent_cloneable_settings(entity)
            end
        end
        ::continue::
    end
end

function handlers.on_player_setup_blueprint(event)
    local mapping = event.mapping and event.mapping.get()
    if not mapping then return end

    shared.apply_blueprint_entity_settings_to_stack(event.stack, mapping)
    shared.apply_blueprint_entity_settings_to_record(event.record, mapping)
end

function handlers.on_space_platform_built_entity(event)
    chunks_utils.add_chunk(event.entity.surface_index, event.entity.position)
    handlers.on_built_entity(event)
end

function handlers.on_pre_player_mined_item(event)
    local entity = event.entity
    local player_index = event.player_index
    if settings.get_player_settings(player_index)["qf-direct-mining-puts-in-storage"].value then
        if entity.can_be_destroyed() and entity.type ~= "entity-ghost" then
            if storage.prototypes_data[entity.name] then
                local item_name = storage.prototypes_data[entity.name].item_name
                if utils.is_placeable(item_name) then
                    instant_defabrication(entity, player_index)
                end
            end
        end
    end
end

function handlers.on_marked_for_deconstruction(event)
    local entity = event.entity
    local player_index = event.player_index
    if player_index and not settings.get_player_settings(player_index)["qf-use-player-inventory"].value then
        player_index = nil
    end
    if entity and entity.valid then
        if entity.can_be_destroyed() and entity.type ~= "entity-ghost" then
            if storage.prototypes_data[entity.name] then
                local item_name = storage.prototypes_data[entity.name].item_name
                if utils.is_placeable(item_name) then
                    tracking.create_tracked_request({
                        request_type = "destroys",
                        entity = entity,
                        player_index = player_index
                    })
                    schedule_space_sendoff(2, nil, true)
                end
            elseif entity.type == "deconstructible-tile-proxy" then
                storage.countdowns.tile_removal = 10
            elseif entity.type == "cliff" then
                if not instant_decliffing(entity, player_index) then
                    tracking.create_tracked_request({
                        entity = entity,
                        player_index = player_index,
                        request_type = "cliffs"
                    })
                end
            else
                instant_deforestation(entity, player_index)
            end
        end
    end
end

function handlers.on_destroyed(event)
    local entity = event.entity
    if entity and entity.valid then
        shared.store_recent_cloneable_settings(entity)
        if Trackable_entities[entity.name] then
            local entity_data = tracking.get_entity_data(entity)
            tracking.remove_tracked_entity(entity_data)
        end
    end
end

function handlers.on_upgrade(event)
    local entity = event.entity
    local player_index = event.player_index
    if player_index and not settings.get_player_settings(player_index)["qf-use-player-inventory"].value then
        player_index = nil
    end
    if entity and entity.valid then
        tracking.create_tracked_request({
            request_type = "upgrades",
            entity = entity,
            player_index = player_index
        })
        schedule_space_sendoff(2, nil, true)
    end
end

function handlers.on_cancelled_upgrade(event)
    local entity = event.entity
    local player_index = event.player_index
    if entity and entity.valid and player_index then
        tracking.remove_tracked_request("upgrades", entity.unit_number)
    end
end

function handlers.on_entity_damaged(event)
    local entity = event.entity
    if entity.force.name == "player" and entity.unit_number and not storage.tracked_requests["repairs"][entity.unit_number] then
        tracking.create_tracked_request({request_type = "repairs", entity = entity, player_index = event.player_index})
        storage.countdowns.in_combat = 30
    end
end

function handlers.on_entity_cloned(event)
    local source = event.source
    local destination = event.destination
    chunks_utils.add_chunk(destination.surface_index, destination.position)
    if Cloneable_entities[source.name] then
        tracking.clone_settings(source, destination)
    end
end

function handlers.on_entity_settings_pasted(event)
    local source = event.source
    local destination = event.destination
    chunks_utils.add_chunk(destination.surface_index, destination.position)
    if Cloneable_entities[source.name] and source.name == destination.name then
        local play_paste_sound = event.player_index and shared.should_play_settings_paste_sound(source, destination)
        tracking.clone_settings(source, destination)
        if play_paste_sound then
            local player = game.get_player(event.player_index)
            if player then player.play_sound{path = "utility/entity_settings_pasted"} end
        end
    end
end

return handlers
