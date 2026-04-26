local qs_utils = require("scripts/qs_utils")
local flib_dictionary = require("__flib__.dictionary")
local tracking = require("scripts/tracking_utils")

local handlers = {}

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

function handlers.on_init()
    flib_dictionary.on_init()
    build_dictionaries()
    storage.fabricator_inventory = {}
    storage.unpacked_recipes = {}
    storage.placeable = {}
    storage.tiles = {}
    storage.recipe = {}
    storage.modules = {}
    storage.removable = {}
    storage.ingredient = {}
    storage.ingredient_filter = {}
    storage.player_gui = {}
    storage.options = {
        auto_recheck_item_request_proxies = true,
        default_intake_limit = 0,
        default_reserve_limit = 0,
        default_decraft = true,
        default_digitizer_chest_fluid_enabled = false,
        default_preserve_freshness = false,
    }
    storage.sorted_lists = {}
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
    storage.surface_data = {
        platforms = {},
        planets = {},
    }
    storage.recent_cloneable_settings = {}
    storage.prototypes_data = {}
    storage.craft_data = {}
    storage.filtered_data = {}
    storage.temp_statistics = {}
    storage.recipe_priority = {}
    storage.qf_enabled = true
    if not Actual_non_duplicates then Actual_non_duplicates = {} end
    process_data()
    handlers.init_players()
end

function handlers.init_players()
    for _, player in pairs(game.players) do
        handlers.on_player_created({player_index = player.index})
    end
end

function handlers.on_player_created(event)
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

function handlers.on_config_changed()
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
    if storage.options.default_preserve_freshness == nil then
        storage.options.default_preserve_freshness = false
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

function handlers.on_mod_settings_changed(event)
    if event.setting == "qf-unified-storage" then
        if settings.global["qf-unified-storage"].value then
            qs_utils.unify_storage()
        else
            qs_utils.deunify_storage()
        end
    end
end

return handlers
