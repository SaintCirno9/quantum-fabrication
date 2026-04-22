local tracking = require("scripts/tracking_utils")

local shared = {}

local function tables_equal(first, second)
    if first == second then return true end
    if type(first) ~= type(second) then return false end
    if type(first) ~= "table" then return false end

    for key, value in pairs(first) do
        if not tables_equal(value, second[key]) then return false end
    end

    for key, _ in pairs(second) do
        if first[key] == nil then return false end
    end

    return true
end

local function get_cloneable_settings_cache_key(entity)
    local position = entity.position
    return entity.surface_index .. "|" .. position.x .. "|" .. position.y
end

function shared.cleanup_recent_cloneable_settings()
    local recent_cloneable_settings = storage.recent_cloneable_settings
    if not recent_cloneable_settings then return end
    for key, cached in pairs(recent_cloneable_settings) do
        if not cached or cached.expire_tick < game.tick then
            recent_cloneable_settings[key] = nil
        end
    end
end

function shared.store_recent_cloneable_settings(entity)
    if not entity or not entity.valid or not Cloneable_entities[entity.name] then return end
    local settings = tracking.export_blueprint_settings(entity)
    if not settings then return end
    storage.recent_cloneable_settings = storage.recent_cloneable_settings or {}
    shared.cleanup_recent_cloneable_settings()
    storage.recent_cloneable_settings[get_cloneable_settings_cache_key(entity)] = {
        expire_tick = game.tick + 2,
        settings = settings,
    }
end

function shared.apply_recent_cloneable_settings(entity)
    if not entity or not entity.valid or not Cloneable_entities[entity.name] then return end
    local recent_cloneable_settings = storage.recent_cloneable_settings
    if not recent_cloneable_settings then return end
    shared.cleanup_recent_cloneable_settings()
    local key = get_cloneable_settings_cache_key(entity)
    local cached = recent_cloneable_settings[key]
    if not cached then return end
    recent_cloneable_settings[key] = nil
    if cached.expire_tick < game.tick then
        return
    end
    tracking.apply_blueprint_settings(entity, cached.settings)
end

function shared.apply_blueprint_entity_settings_to_stack(blueprint_stack, mapping)
    if not mapping or not blueprint_stack or not blueprint_stack.valid_for_read then return end

    for entity_number, entity in pairs(mapping) do
        if entity and entity.valid and Trackable_entities[entity.name] then
            local blueprint_settings = tracking.export_blueprint_settings(entity)
            if blueprint_settings then
                blueprint_stack.set_blueprint_entity_tag(entity_number, "qf_entity_settings", blueprint_settings)
            end
        end
    end
end

function shared.apply_blueprint_entity_settings_to_record(blueprint_record, mapping)
    if not mapping or not blueprint_record or not blueprint_record.valid or not blueprint_record.valid_for_write then return end

    for entity_number, entity in pairs(mapping) do
        if entity and entity.valid and Trackable_entities[entity.name] then
            local blueprint_settings = tracking.export_blueprint_settings(entity)
            if blueprint_settings then
                blueprint_record.set_blueprint_entity_tag(entity_number, "qf_entity_settings", blueprint_settings)
            end
        end
    end
end

local function bar_changed(source, destination)
    if source.type ~= "container" and source.type ~= "logistic-container" then return false end

    local source_inventory = source.get_inventory(defines.inventory.chest)
    local destination_inventory = destination.get_inventory(defines.inventory.chest)
    if not source_inventory or not destination_inventory then return false end
    if not source_inventory.supports_bar() or not destination_inventory.supports_bar() then return false end

    return source_inventory.get_bar() ~= destination_inventory.get_bar()
end

function shared.should_play_settings_paste_sound(source, destination)
    local source_data = tracking.get_entity_data(source)
    local destination_data = tracking.get_entity_data(destination)
    if not source_data or not destination_data then return false end
    if tables_equal(source_data.settings, destination_data.settings) then return false end
    if bar_changed(source, destination) then return false end

    return true
end

return shared
