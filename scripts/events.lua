local init_events = require("scripts/events/init")
local player_events = require("scripts/events/player")
local surface_events = require("scripts/events/surface")
local entity_events = require("scripts/events/entity")
local tick_events = require("scripts/events/tick")
local console_events = require("scripts/events/console")
local shortcut_events = require("scripts/events/shortcut")

initialize_surfaces = surface_events.initialize_surfaces
initialize_surface = surface_events.initialize_surface
initialize_fabricator_inventory = surface_events.initialize_fabricator_inventory
sort_ingredients = player_events.sort_ingredients
post_research_recheck = tick_events.post_research_recheck
find_trigger_techs = tick_events.find_trigger_techs
repair_tracking = tick_events.repair_tracking
debug_storage = console_events.debug_storage

commands.add_command("qf_update_module_requests", nil, console_events.on_console_command)
commands.add_command("qf_repair_tracking", nil, console_events.on_console_command)
commands.add_command("qf_hesoyam", nil, console_events.on_console_command)
commands.add_command("qf_hesoyam_harder", nil, console_events.on_console_command)
commands.add_command("qf_debug_command", nil, console_events.on_console_command)
commands.add_command("qf_reprocess_recipes", nil, console_events.on_console_command)
commands.add_command("qf_dump_digitizer_queues", nil, console_events.on_console_command)
script.on_nth_tick(tick_events.get_registered_nth_ticks(), tick_events.on_registered_nth_tick)

script.on_event(defines.events.on_runtime_mod_setting_changed, init_events.on_mod_settings_changed)
script.on_init(init_events.on_init)
script.on_configuration_changed(init_events.on_config_changed)

script.on_event(defines.events.on_string_translated, on_string_translated)
script.on_event(defines.events.on_player_joined_game, player_events.on_player_joined_game)
script.on_event(defines.events.on_pre_player_left_game, player_events.on_pre_player_left_game)
script.on_event(defines.events.on_player_fast_transferred, player_events.on_player_fast_transferred)
script.on_event(defines.events.on_selected_entity_changed, player_events.on_selected_entity_changed)
script.on_event(defines.events.on_tick, tick_events.on_tick)

script.on_event("qf-fabricator-gui-search", on_fabricator_gui_search_event)
script.on_event("qf-fabricator-gui-toggle", on_fabricator_gui_toggle_event)
script.on_event(defines.events.on_lua_shortcut, shortcut_events.on_lua_shortcut)

script.on_event(defines.events.on_player_created, init_events.on_player_created)

script.on_event(defines.events.on_research_finished, tick_events.on_research_changed)
script.on_event(defines.events.on_research_reversed, tick_events.on_research_changed)

script.on_event(defines.events.on_built_entity, entity_events.on_built_entity)
script.on_event(defines.events.on_robot_built_entity, entity_events.on_built_entity)
script.on_event(defines.events.script_raised_built, entity_events.on_built_entity)
script.on_event(defines.events.script_raised_revive, entity_events.on_built_entity)
script.on_event(defines.events.on_player_setup_blueprint, entity_events.on_player_setup_blueprint)

script.on_event(defines.events.on_marked_for_upgrade, entity_events.on_upgrade)
script.on_event(defines.events.on_cancelled_upgrade, entity_events.on_cancelled_upgrade)

script.on_event(defines.events.on_entity_died, entity_events.on_destroyed)
script.on_event(defines.events.script_raised_destroy, entity_events.on_destroyed)
script.on_event(defines.events.on_player_mined_entity, entity_events.on_destroyed)
script.on_event(defines.events.on_robot_mined_entity, entity_events.on_destroyed)

script.on_event(defines.events.on_pre_player_mined_item, entity_events.on_pre_player_mined_item)
script.on_event(defines.events.on_marked_for_deconstruction, entity_events.on_marked_for_deconstruction)

script.on_event(defines.events.on_surface_created, surface_events.on_surface_created)
script.on_event(defines.events.on_surface_deleted, surface_events.on_surface_deleted)

script.on_event(defines.events.on_entity_cloned, entity_events.on_entity_cloned)
script.on_event(defines.events.on_entity_settings_pasted, entity_events.on_entity_settings_pasted)

script.on_event(defines.events.on_space_platform_built_entity, entity_events.on_space_platform_built_entity)

if settings.startup["qf-enable-auto-repair"].value then
    script.on_event(defines.events.on_entity_damaged, entity_events.on_entity_damaged, {{filter = "type", type = "unit", invert = true}})
end
