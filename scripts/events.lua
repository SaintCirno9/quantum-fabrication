local utils = require("scripts/utils")
local qs_utils = require("scripts/qs_utils")
local flib_dictionary = require("__flib__.dictionary")
local tracking = require("scripts/tracking_utils")
local flib_table = require("__flib__.table")
local chunks_utils = require("scripts/chunks_utils")

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

local function cleanup_recent_cloneable_settings()
    local recent_cloneable_settings = storage.recent_cloneable_settings
    if not recent_cloneable_settings then return end
    for key, cached in pairs(recent_cloneable_settings) do
        if not cached or cached.expire_tick < game.tick then
            recent_cloneable_settings[key] = nil
        end
    end
end

local function store_recent_cloneable_settings(entity)
    if not entity or not entity.valid or not Cloneable_entities[entity.name] then return end
    local settings = tracking.export_blueprint_settings(entity)
    if not settings then return end
    storage.recent_cloneable_settings = storage.recent_cloneable_settings or {}
    cleanup_recent_cloneable_settings()
    storage.recent_cloneable_settings[get_cloneable_settings_cache_key(entity)] = {
        expire_tick = game.tick + 2,
        settings = settings,
    }
end

local function apply_recent_cloneable_settings(entity)
    if not entity or not entity.valid or not Cloneable_entities[entity.name] then return end
    local recent_cloneable_settings = storage.recent_cloneable_settings
    if not recent_cloneable_settings then return end
    cleanup_recent_cloneable_settings()
    local key = get_cloneable_settings_cache_key(entity)
    local cached = recent_cloneable_settings[key]
    if not cached then return end
    recent_cloneable_settings[key] = nil
    if cached.expire_tick < game.tick then
        return
    end
    tracking.apply_blueprint_settings(entity, cached.settings)
end

local function apply_blueprint_entity_settings_to_stack(blueprint_stack, mapping)
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

local function apply_blueprint_entity_settings_to_record(blueprint_record, mapping)
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

local function should_play_settings_paste_sound(source, destination)
    local source_data = tracking.get_entity_data(source)
    local destination_data = tracking.get_entity_data(destination)
    if not source_data or not destination_data then return false end
    if tables_equal(source_data.settings, destination_data.settings) then return false end
    if bar_changed(source, destination) then return false end

    return true
end

---@class QSPrototypeData
---@field name string
---@field type string
---@field localised_name LocalisedString
---@field localised_description LocalisedString
---@field item_name string

---@alias RecipeName string
---@alias ItemName string
---@alias ItemCount uint
---@alias SurfaceIndex uint
---@alias SurfaceName string
---@alias QualityName string

---@class QSUnpackedRecipeData
---@field ingredients table
---@field products table
---@field localised_name LocalisedString
---@field localised_description LocalisedString
---@field enabled boolean
---@field name string
---@field placeable_product string
---@field group_name string
---@field subgroup_name string
---@field order string
---@field priority_style string

---@class SurfaceData
---@field surface_index uint
---@field surface LuaSurface
---@field type "platforms"|"planets"
---@field platform? LuaSpacePlatform
---@field hub? LuaEntity
---@field hub_inventory? LuaInventory
---@field planet? LuaPlanet
---@field rocket_silo? LuaEntity

function on_init()
    flib_dictionary.on_init()
    build_dictionaries()
    ---@type table <SurfaceIndex, table <"item"|"fluid", table <ItemName, table <QualityName, ItemCount>>>>
    storage.fabricator_inventory = {}
    ---@type table <RecipeName, QSUnpackedRecipeData>
    storage.unpacked_recipes = {}
    ---@type table <ItemName, boolean>
    storage.placeable = {}
    ---@type table <ItemName, boolean>
    storage.tiles = {}
    storage.recipe = {}
    ---@type table <ItemName, boolean>
    storage.modules = {}
    ---@type table <ItemName, boolean>
    storage.removable = {}
    ---@type table <ItemName, boolean>
    storage.ingredient = {}
    ---@type table <ItemName, { ["count"]: uint; ["recipes"]: table <RecipeName, boolean> }>
    storage.ingredient_filter = {}
    storage.player_gui = {}
    storage.options = {
        auto_recheck_item_request_proxies = true,
        default_intake_limit = 0,
        default_reserve_limit = 0,
        default_decraft = true,
        default_digitizer_chest_fluid_enabled = false,
    }
    storage.sorted_lists = {}
    ---@type table <string, table<uint, RequestData>>
    storage.tracked_requests = {
        construction = {},
        item_requests = {},
        upgrades = {},
        revivals = {},
        destroys = {},
        cliffs = {},
        repairs = {},
    }
    storage.countdowns = {
        tile_creation = nil,
        tile_removal = nil,
        revivals = nil,
        destroys = nil,
        upgrades = nil,
        in_combat = nil,
    }
    storage.space_countdowns = {
        space_sendoff = nil,
    }
    storage.space_sendoff_dirty_platforms = {}
    storage.space_sendoff_full_scan = false
    storage.space_sendoff_next_tick = nil
    --Because cliffs do not have unit number
    storage.cliff_ids = 0
    storage.request_ids = {
        cliffs = 1,
        revivals = 1,
        destroys = 1,
        upgrades = 1,
        repairs = 1,
        item_proxies_dirty = 1,
        ["digitizer-chest"] = 1,
        ["digitizer-chest-signal"] = 1,
        ["digitizer-chest-active"] = 1,
        ["digitizer-chest-idle"] = 1,
        ["digitizer-chest-long_idle"] = 1,
    }
    storage.request_player_ids = {
        revivals = 1,
        destroys = 1,
        upgrades = 1,
        repairs = 1,
        tiles = 1,
    }
    ---@type table <string, table<uint, EntityData>>
    storage.tracked_entities = {
        ["digitizer-chest"] = {},
        ["dedigitizer-reactor"] = {},
        ["qf-storage-reader"] = {},
    }
    storage.tracked_entity_queues = {
        ["digitizer-chest"] = {
            signal = {},
            active = {},
            idle = {},
            long_idle = {},
        },
    }
    ---@type { platforms: SurfaceData[], planets: SurfaceData[] }
    storage.surface_data = {
        platforms = {},
        planets = {},
    }
    storage.recent_cloneable_settings = {}
    ---@type table <string, QSPrototypeData>
    storage.prototypes_data = {}
    storage.craft_data = {}
    storage.filtered_data = {}
    storage.temp_statistics = {}
    -- Spaghetti-cause table used to store priorities of duplicate recipes
    storage.recipe_priority = {}
    -- Enables the mod function by default
    storage.qf_enabled = true
    if not Actual_non_duplicates then Actual_non_duplicates = {} end
    process_data()
    init_players()
end

function init_players()
    for _, player in pairs(game.players) do
        on_player_created({player_index = player.index})
    end
end

function on_player_created(event)
    game.get_player(event.player_index).set_shortcut_toggled("qf-fabricator-enable", storage.qf_enabled)
    if not storage.player_gui[event.player_index] then
        storage.player_gui[event.player_index] = {
            item_group_selection = 1,
            selected_tab_index = 1,
            tooltip_workaround = 0,
            show_storage = false,
            quality = {
                index = 1,
                name = "normal"
            },
            fabricator_gui_position = nil,
            options = {
                calculate_numbers = true,
                mark_red = true,
                sort_ingredients = 1
            },
            space_storage_mode = "planet",
            gui = {},
            translation_complete = false,
            filtered_data_ok = false,
            digitizer_hover_render_id = nil,
            digitizer_hover_unit_number = nil,
            digitizer_hover_text = nil,
        }
    end
end

local Digitizer_queue_display_names = {
    signal = "信号",
    active = "活跃",
    idle = "空闲",
    long_idle = "深度空闲",
}

local function get_digitizer_hover_text(entity_data)
    local queue_name = entity_data.queue_name or "active"
    local full_pass_seconds = tracking.get_digitizer_queue_full_pass_seconds(queue_name)
    local queue_text = "队列: " .. (Digitizer_queue_display_names[queue_name] or queue_name) .. " " .. string.format("%.2fS", full_pass_seconds)
    local container_fluid = entity_data.container_fluid
    if not container_fluid or not container_fluid.valid then
        return queue_text
    end

    local fluid_lines = {}
    local index = 1
    for fluid_name, amount in pairs(container_fluid.get_fluid_contents()) do
        fluid_lines[index] = fluid_name .. " : " .. string.format("%.1f", amount)
        index = index + 1
    end
    if index == 1 then
        return queue_text
    end
    table.sort(fluid_lines)
    return queue_text .. " | " .. table.concat(fluid_lines, " | ")
end

local function destroy_digitizer_hover_text(player_index)
    local player_data = storage.player_gui[player_index]
    if not player_data then return end

    local render_id = player_data.digitizer_hover_render_id
    if render_id then
        local render_object = rendering.get_object_by_id(render_id)
        if render_object then
            render_object.destroy()
        end
    end

    player_data.digitizer_hover_render_id = nil
    player_data.digitizer_hover_unit_number = nil
    player_data.digitizer_hover_text = nil
end

local function update_digitizer_hover_text(player_index)
    local player = game.get_player(player_index)
    if not player or not player.valid then return end

    local player_data = storage.player_gui[player_index]
    if not player_data then return end

    local selected = player.selected
    if not selected or not selected.valid then
        destroy_digitizer_hover_text(player_index)
        return
    end

    local entity_data = tracking.get_entity_data(selected)
    if not entity_data or entity_data.name ~= "digitizer-chest" then
        destroy_digitizer_hover_text(player_index)
        return
    end

    local queue_text = get_digitizer_hover_text(entity_data)
    local render_object = player_data.digitizer_hover_render_id and rendering.get_object_by_id(player_data.digitizer_hover_render_id)

    if not render_object or player_data.digitizer_hover_unit_number ~= selected.unit_number then
        destroy_digitizer_hover_text(player_index)
        render_object = rendering.draw_text{
            text = queue_text,
            surface = selected.surface,
            target = {
                entity = selected,
                offset = {0, -1.75},
            },
            color = {r = 1, g = 1, b = 1},
            alignment = "center",
            vertical_alignment = "middle",
            players = {player_index},
            scale = 1.1,
        }
        player_data.digitizer_hover_render_id = render_object.id
        player_data.digitizer_hover_unit_number = selected.unit_number
        player_data.digitizer_hover_text = queue_text
        return
    end

    if player_data.digitizer_hover_text ~= queue_text then
        render_object.text = queue_text
        player_data.digitizer_hover_text = queue_text
    end
end

function on_selected_entity_changed(event)
    update_digitizer_hover_text(event.player_index)
end

function on_pre_player_left_game(event)
    destroy_digitizer_hover_text(event.player_index)
end

local function refresh_digitizer_hover_texts()
    for _, player in pairs(game.connected_players) do
        update_digitizer_hover_text(player.index)
    end
end

function on_config_changed()
    local disable_legacy_digitizer_chest_fluid_interfaces = storage.options == nil or storage.options.default_digitizer_chest_fluid_enabled == nil
    storage.options = storage.options or {}
    storage.recent_cloneable_settings = storage.recent_cloneable_settings or {}
    storage.space_sendoff_dirty_platforms = storage.space_sendoff_dirty_platforms or {}
    if storage.space_sendoff_full_scan == nil then
        storage.space_sendoff_full_scan = false
    end
    if storage.options.default_reserve_limit == nil then
        storage.options.default_reserve_limit = 0
    end
    if storage.options.default_digitizer_chest_fluid_enabled == nil then
        storage.options.default_digitizer_chest_fluid_enabled = false
    end
    if storage.qf_enabled == nil then
        storage.qf_enabled = true
    end
    for _, player in pairs(game.players) do
        if storage.player_gui[player.index].space_storage_mode == nil then
            storage.player_gui[player.index].space_storage_mode = "planet"
        end
        storage.player_gui[player.index].translation_complete = false
        storage.player_gui[player.index].filtered_data_ok = false
        local main_frame = player.gui.screen.qf_fabricator_frame
        if main_frame then main_frame.destroy() end
    end
    flib_dictionary.on_configuration_changed()
    build_dictionaries()
    process_data()
    process_sorted_lists()
    tracking.recheck_trackable_entities()
    if disable_legacy_digitizer_chest_fluid_interfaces then
        tracking.disable_legacy_digitizer_chest_fluid_interfaces()
    else
        tracking.sync_digitizer_chest_fluid_settings()
    end
    tracking.rebuild_digitizer_chest_queues()
end

function on_mod_settings_changed(event)
    if event.setting == "qf-unified-storage" then
        if settings.global["qf-unified-storage"].value then
            qs_utils.unify_storage()
        else
            qs_utils.deunify_storage()
        end
    end
end

---Check every existing surface (except space platforms) and initialize fabricator inventories for all items and qualities. Doesn't overwrite anything
function initialize_surfaces()
    for _, surface in pairs(game.surfaces) do
        initialize_surface(surface)
    end
end


---@param surface LuaSurface
function initialize_surface(surface)
    local surface_platform = surface.platform
    local surface_planet = surface.planet
    local surface_index = surface.index

    local data = {
        surface_index = surface_index,
        surface = surface,
    }
    initialize_fabricator_inventory(surface_index)

    if not surface_platform then
        data.type = "planets"
        if script.active_mods["factorissimo-2-notnotmelon"] and surface.name:find("%-factory%-floor$") then
            local planet_name = surface.name:gsub("%-factory%-floor", "")
            local planet_surface_index = storage.planet_surface_link[planet_name]
            storage.fabricator_inventory[surface_index] = storage.fabricator_inventory[planet_surface_index]
        end
        -- Making the new storage a reference to the storage #1 if unified storage is enabled (workaround)
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

function on_surface_created(event)
    local surface = game.surfaces[event.surface_index]
    update_planet_surface_link()
    initialize_surface(surface)
    utils.validate_surfaces()
end


function on_surface_deleted(event)
    local surface_index = event.surface_index
    utils.validate_surfaces()
    storage.fabricator_inventory[surface_index] = nil
    storage.surface_data.platforms[surface_index] = nil
    storage.surface_data.planets[surface_index] = nil
    if storage.space_sendoff_dirty_platforms then
        storage.space_sendoff_dirty_platforms[surface_index] = nil
    end
end

---comment
---@param surface_index SurfaceIndex
---@param value? uint
function initialize_fabricator_inventory(surface_index, value)
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


function on_built_entity(event)
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
                apply_recent_cloneable_settings(entity)
            end
        end
        ::continue::
    end
end

function on_player_setup_blueprint(event)
    local mapping = event.mapping and event.mapping.get()
    if not mapping then return end

    apply_blueprint_entity_settings_to_stack(event.stack, mapping)
    apply_blueprint_entity_settings_to_record(event.record, mapping)
end

function on_space_platform_built_entity(event)
    chunks_utils.add_chunk(event.entity.surface_index, event.entity.position)
    on_built_entity(event)
end

function on_pre_player_mined_item(event)
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

function on_marked_for_deconstruction(event)
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
            else  --if entity.prototype.type == "tree" or entity.prototype.type == "simple-entity" or entity.prototype.type == "item-entity" or entity.prototype.type == "fish" or entity.prototype.type == "plant" then
                instant_deforestation(entity, player_index)
            end
        end
    end
end

function on_destroyed(event)
    local entity = event.entity
    if entity and entity.valid then
        store_recent_cloneable_settings(entity)
        if Trackable_entities[entity.name] then
            local entity_data = tracking.get_entity_data(entity)
            tracking.remove_tracked_entity(entity_data)
        end
    end
end

function on_upgrade(event)
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

function on_cancelled_upgrade(event)
    local entity = event.entity
    local player_index = event.player_index
    if entity and entity.valid and player_index then
        tracking.remove_tracked_request("upgrades", entity.unit_number)
    end
end

function on_entity_damaged(event)
    local entity = event.entity
    if entity.force.name == "player" and entity.unit_number and not storage.tracked_requests["repairs"][entity.unit_number] then
        tracking.create_tracked_request({request_type = "repairs", entity = entity, player_index = event.player_index})
        storage.countdowns.in_combat = 30
    end
end

function on_entity_cloned(event)
    local source = event.source
    local destination = event.destination
    chunks_utils.add_chunk(destination.surface_index, destination.position)
    if Cloneable_entities[source.name] then
        tracking.clone_settings(source, destination)
    end
end

function on_entity_settings_pasted(event)
    local source = event.source
    local destination = event.destination
    chunks_utils.add_chunk(destination.surface_index, destination.position)
    if Cloneable_entities[source.name] and source.name == destination.name then
        local play_paste_sound = event.player_index and should_play_settings_paste_sound(source, destination)
        tracking.clone_settings(source, destination)
        if play_paste_sound then
            local player = game.get_player(event.player_index)
            if player then player.play_sound{path = "utility/entity_settings_pasted"} end
        end
    end
end

---@param player_index uint
---@param sort_type "item_name"|"amount"|"localised_name"
function sort_ingredients(player_index, sort_type)
    for _, recipe in pairs(storage.unpacked_recipes) do
        if sort_type == "item_name" then
            table.sort(storage.unpacked_recipes[recipe.name].ingredients, function(a, b) return a.name < b.name end)
        elseif sort_type == "amount" then
            table.sort(storage.unpacked_recipes[recipe.name].ingredients, function(a, b) return a.amount < b.amount end)
        elseif sort_type == "localised_name" then
            local locale = game.get_player(player_index).locale
            table.sort(storage.unpacked_recipes[recipe.name].ingredients, function(a, b) return get_translation(player_index, a.name, "unknown", locale) < get_translation(player_index, b.name, "unknown", locale) end)
        end
    end
end

function on_player_joined_game(event)
    flib_dictionary.on_player_joined_game(event)
end

function on_player_fast_transferred(event)
    if not event.from_player then return end
    local entity = event.entity
    if not entity or not entity.valid then return end

    if entity.name ~= "digitizer-chest"
        and entity.name ~= "digitizer-passive-provider-chest"
        and entity.name ~= "digitizer-requester-chest" then
        return
    end

    local entity_data = tracking.get_entity_data(entity)
    if not entity_data then
        tracking.create_tracked_request({request_type = "entities", entity = entity, player_index = event.player_index})
        entity_data = tracking.get_entity_data(entity)
    end
    if not entity_data then return end

    tracking.invalidate_digitizer_chest_processable_cache(entity_data, true)
    tracking.update_entity(entity_data)
end

function on_tick(event)
    flib_dictionary.on_tick(event)
    if storage.qf_enabled == false then return end
    tracking.on_tick_update_digitizer_queues()
    tracking.on_tick_update_requests()
    tracking.update_lost_module_requests_neo()
    qs_utils.process_decraft_queue(8)
end

function post_research_recheck()
    for _, player in pairs(game.players) do
        storage.player_gui[player.index].filtered_data_ok = false
    end
    process_ingredient_filter()
    process_recipe_enablement()
    find_trigger_techs()
end

---Grabs the currently researchable trigger techs
function find_trigger_techs()
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


--TODO: test if this is doing anything useful at all
function on_research_changed(event)
    Research_finished = true
end

local function get_registered_nth_ticks()
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

local function on_registered_nth_tick(event)
    if event.nth_tick == 338 then
        if Research_finished then
            post_research_recheck()
            Research_finished = false
        end
    end
    if event.nth_tick == 29 then
        refresh_digitizer_hover_texts()
    end
    if event.nth_tick == 11 then
        if storage.qf_enabled then
            for type, countdown in pairs(storage.countdowns) do
                if countdown then
                    storage.countdowns[type] = storage.countdowns[type] - 1
                    if countdown == 0 then
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

function repair_tracking()
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

function on_console_command(command)
    local player_index = command.player_index
    local name = command.name
    if name == "qf_hesoyam" then
        debug_storage(250000)
        game.print("CHEAT: Fabricator inventory updated")
    elseif name == "qf_repair_tracking" then
        repair_tracking()
        game.print("Tracking repair finished")
    elseif name == "qf_update_module_requests" then
        ---@diagnostic disable-next-line: param-type-mismatch
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
    elseif name == "qf_dump_digitizer_queues" then
        local limit = tonumber(command.parameter)
        tracking.dump_digitizer_chest_queues(limit, player_index)
        game.print("Digitizer queue dump printed to chat")
    end
end

function debug_storage(amount)
    utils.validate_surfaces()
    for surface_index, _ in pairs(storage.surface_data.planets) do
            initialize_fabricator_inventory(surface_index, amount)
    end
end

function on_lua_shortcut(event)
    local player = game.get_player(event.player_index)
    if not player then return end
    if event.prototype_name == "qf-fabricator-gui" then
        toggle_qf_gui(player)
    elseif event.prototype_name == "qf-fabricator-enable" then
        storage.qf_enabled = not storage.qf_enabled
        ---@diagnostic disable-next-line: redefined-local
        for _, player in pairs(game.players) do
            player.set_shortcut_toggled("qf-fabricator-enable", storage.qf_enabled)
        end
    end
end

commands.add_command("qf_update_module_requests", nil, on_console_command)
commands.add_command("qf_repair_tracking", nil, on_console_command)
commands.add_command("qf_hesoyam", nil, on_console_command)
commands.add_command("qf_hesoyam_harder", nil, on_console_command)
commands.add_command("qf_debug_command", nil, on_console_command)
commands.add_command("qf_reprocess_recipes", nil, on_console_command)
commands.add_command("qf_dump_digitizer_queues", nil, on_console_command)
script.on_nth_tick(get_registered_nth_ticks(), on_registered_nth_tick)

script.on_event(defines.events.on_runtime_mod_setting_changed, on_mod_settings_changed)
script.on_init(on_init)
script.on_configuration_changed(on_config_changed)

script.on_event(defines.events.on_string_translated, on_string_translated)
script.on_event(defines.events.on_player_joined_game, on_player_joined_game)
script.on_event(defines.events.on_pre_player_left_game, on_pre_player_left_game)
script.on_event(defines.events.on_player_fast_transferred, on_player_fast_transferred)
script.on_event(defines.events.on_selected_entity_changed, on_selected_entity_changed)
script.on_event(defines.events.on_tick, on_tick)

script.on_event("qf-fabricator-gui-search", on_fabricator_gui_search_event)
script.on_event("qf-fabricator-gui-toggle", on_fabricator_gui_toggle_event)
script.on_event(defines.events.on_lua_shortcut, on_lua_shortcut)

script.on_event(defines.events.on_player_created, on_player_created)

script.on_event(defines.events.on_research_finished, on_research_changed)
script.on_event(defines.events.on_research_reversed, on_research_changed)

script.on_event(defines.events.on_built_entity, on_built_entity)
script.on_event(defines.events.on_robot_built_entity, on_built_entity)
script.on_event(defines.events.script_raised_built, on_built_entity)
script.on_event(defines.events.script_raised_revive, on_built_entity)
script.on_event(defines.events.on_player_setup_blueprint, on_player_setup_blueprint)

script.on_event(defines.events.on_marked_for_upgrade, on_upgrade)
script.on_event(defines.events.on_cancelled_upgrade, on_cancelled_upgrade)

script.on_event(defines.events.on_entity_died, on_destroyed)
script.on_event(defines.events.script_raised_destroy, on_destroyed)
script.on_event(defines.events.on_player_mined_entity, on_destroyed)
script.on_event(defines.events.on_robot_mined_entity, on_destroyed)

script.on_event(defines.events.on_pre_player_mined_item, on_pre_player_mined_item)
script.on_event(defines.events.on_marked_for_deconstruction, on_marked_for_deconstruction)

script.on_event(defines.events.on_surface_created, on_surface_created)
script.on_event(defines.events.on_surface_deleted, on_surface_deleted)

script.on_event(defines.events.on_entity_cloned, on_entity_cloned)
script.on_event(defines.events.on_entity_settings_pasted, on_entity_settings_pasted)

script.on_event(defines.events.on_space_platform_built_entity, on_space_platform_built_entity)

if settings.startup["qf-enable-auto-repair"].value then
    script.on_event(defines.events.on_entity_damaged, on_entity_damaged, {{filter = "type", type = "unit", invert = true}})
end
