return function(context)
    local tracking = context.tracking
    local qs_utils = context.qs_utils
    local flib_table = context.flib_table
    local get_tracking_entity_name = context.get_tracking_entity_name
    local sync_digitizer_chest_fluid_setting = context.sync_digitizer_chest_fluid_setting
    local set_digitizer_chest_queue = context.set_digitizer_chest_queue
    local digitizer_chest_signal_recheck_ticks = context.digitizer_chest_signal_recheck_ticks
    local digitizer_chest_active_keepalive_ticks = context.digitizer_chest_active_keepalive_ticks
    local digitizer_chest_processable_recheck_ticks = context.digitizer_chest_processable_recheck_ticks

    function tracking.add_tracked_entity(request_data)
        local entity = request_data.entity
        local tracked_entity_name = get_tracking_entity_name(entity.name)
        local existing_entities = storage.tracked_entities[tracked_entity_name]
        if existing_entities and existing_entities[entity.unit_number] then
            return
        end

        local entity_data = {
            entity = entity,
            name = tracked_entity_name,
            surface_index = entity.surface_index,
            settings = {},
            unit_number = entity.unit_number,
        }
        local position = entity.position
        local surface = entity.surface
        local force = entity.force

        if tracked_entity_name == "digitizer-chest" then
            entity_data.inventory = entity.get_inventory(defines.inventory.chest)
            entity_data.settings.intake_limit = storage.options.default_intake_limit
            entity_data.settings.reserve_limit = storage.options.default_reserve_limit or 0
            entity_data.settings.decraft = storage.options.default_decraft
            entity_data.settings.fluid_enabled = entity.name == "digitizer-chest" and storage.options.default_digitizer_chest_fluid_enabled == true
            entity_data.signal_active = true
            entity_data.next_signal_check_tick = 0
            entity_data.signal_check_interval_ticks = digitizer_chest_signal_recheck_ticks
            entity_data.idle_empty_checks = 0
            entity_data.active_until_tick = game.tick + digitizer_chest_active_keepalive_ticks
            entity_data.cached_has_processable_contents = nil
            entity_data.next_processable_recheck_tick = 0
            entity_data.processable_check_interval_ticks = digitizer_chest_processable_recheck_ticks
            entity_data.inventory_processing = {
                items = {},
                fluids = {
                    name = "",
                    count = 0,
                    temperature = nil,
                },
                preprocessed_items = {},
            }
            sync_digitizer_chest_fluid_setting(entity_data)
        elseif entity.name == "dedigitizer-reactor" then
            local pseudo_container = surface.create_entity{
                name = "dedigitizer-reactor-container",
                position = position,
                force = force
            }
            pseudo_container.destructible = false
            pseudo_container.operable = false
            entity_data.container = pseudo_container
            entity_data.inventory = pseudo_container.get_inventory(defines.inventory.chest)

            local pseudo_fluid_container = surface.create_entity{
                name = "dedigitizer-reactor-container-fluid",
                position = position,
                force = force
            }
            entity_data.settings.item_filter = nil
            entity_data.settings.fluid_filter = nil

            local surface_index
            if surface.platform then
                surface_index = get_storage_index(surface.platform.space_location)
            end
            if not surface_index then surface_index = entity.surface_index end
            entity_data.settings.surface_index = surface_index

            entity_data.burnt_result_inventory = entity.get_inventory(defines.inventory.burnt_result)
            pseudo_fluid_container.destructible = false
            pseudo_fluid_container.operable = false
            entity_data.container_fluid = pseudo_fluid_container
        elseif entity.name == "qf-storage-reader" then
            local control_behavior = entity.get_control_behavior()
            if not control_behavior then return end
            control_behavior.get_section(1).filters = {{
                value = {
                    type = "virtual",
                    name = "signal-S",
                },
                min = entity_data.surface_index
            }}
        end
        storage.tracked_entities[tracked_entity_name][entity.unit_number] = entity_data
        if tracked_entity_name == "digitizer-chest" then
            set_digitizer_chest_queue(entity_data, "active")
            tracking.mark_digitizer_chest_dirty(entity_data)
        end
    end

    function tracking.remove_tracked_entity(entity_data)
        if not entity_data then return end
        local entity_name = entity_data.name
        if entity_name == "digitizer-chest" then
            tracking.remove_digitizer_chest_dispatch(entity_data)
            if entity_data.container_fluid and entity_data.container_fluid.valid then
                entity_data.container_fluid.destroy()
            end
        elseif entity_name == "dedigitizer-reactor" then
            entity_data.container.destroy()
            entity_data.container_fluid.destroy()
        end
        storage.tracked_entities[entity_name][entity_data.unit_number] = nil
    end

    function tracking.update_tracked_reactors()
        local entities = storage.tracked_entities["dedigitizer-reactor"]
        for _, entity_data in pairs(entities) do
            tracking.update_entity(entity_data)
        end
    end

    function tracking.get_entity_data(entity)
        local tracked_entity_name = get_tracking_entity_name(entity.name)
        if not storage.tracked_entities[tracked_entity_name] or not storage.tracked_entities[tracked_entity_name][entity.unit_number] then return end
        local entity_data = storage.tracked_entities[tracked_entity_name][entity.unit_number]
        if tracked_entity_name == "digitizer-chest" then
            sync_digitizer_chest_fluid_setting(entity_data)
        end
        return entity_data
    end

    function tracking.clone_settings(source, destination)
        local source_data = tracking.get_entity_data(source)
        if not source_data then return end
        local destination_data = tracking.get_entity_data(destination)
        if not destination_data and Trackable_entities[destination.name] then
            tracking.create_tracked_request({request_type = "entities", entity = destination})
            destination_data = tracking.get_entity_data(destination)
        end
        if not destination_data then return end
        destination_data.settings = flib_table.deep_copy(source_data.settings)
        tracking.invalidate_digitizer_chest_processable_cache(destination_data, true)
    end

    function tracking.export_blueprint_settings(entity)
        local entity_data = tracking.get_entity_data(entity)
        if not entity_data or not entity_data.settings then return nil end
        return flib_table.deep_copy(entity_data.settings)
    end

    function tracking.apply_blueprint_settings(entity, blueprint_settings)
        if not blueprint_settings then return end
        local entity_data = tracking.get_entity_data(entity)
        if not entity_data and Trackable_entities[entity.name] then
            tracking.create_tracked_request({request_type = "entities", entity = entity})
            entity_data = tracking.get_entity_data(entity)
        end
        if not entity_data then return end
        entity_data.settings = flib_table.deep_copy(blueprint_settings)
        tracking.invalidate_digitizer_chest_processable_cache(entity_data, true)
    end

    function tracking.update_entity(entity_data)
        local entity = entity_data.entity
        if not entity or not entity.valid then
            tracking.remove_tracked_entity(entity_data)
            return
        end
        local surface_index = entity_data.surface_index

        if entity_data.name == "digitizer-chest" then
            context.update_digitizer_chest_entity(entity_data)
            return
        end

        if entity.name == "dedigitizer-reactor" then
            local energy_consumption = Reactor_constants.idle_cost
            local energy_consumption_multiplier = 1
            local transfer_rate_multiplier = 1 * settings.global["qf-reactor-transfer-multi"].value

            local burnt_result_contents = entity_data.burnt_result_inventory.get_contents()
            if next(burnt_result_contents) then
                entity_data.inventory.insert(burnt_result_contents[1])
                entity_data.burnt_result_inventory.clear()
            end

            if entity_data.entity.temperature > Reactor_constants.min_temperature or settings.global["qf-reactor-free-transfer"].value then
                local signals = entity_data.entity.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)

                local item_filter
                local fluid_filter
                local quality_filter
                local surface_id
                local highest_count_item = 0
                local highest_count_fluid = 0
                local highest_count_quality = 0
                if signals then
                    for _, signal in pairs(signals) do
                        if signal.signal.type == "item" or signal.signal.type == nil then
                            if signal.count > highest_count_item then
                                highest_count_item = signal.count
                                item_filter = signal.signal.name
                            end
                        elseif signal.signal.type == "fluid" then
                            if signal.count > highest_count_fluid then
                                highest_count_fluid = signal.count
                                fluid_filter = signal.signal.name
                            end
                        elseif signal.signal.type == "virtual" and signal.signal.name == "signal-S" then
                            surface_id = signal.count
                        elseif signal.signal.type == "quality" then
                            if signal.count > highest_count_quality then
                                highest_count_quality = signal.count
                                quality_filter = signal.signal.name
                            end
                        end
                    end
                end
                if not item_filter and entity_data.settings.item_filter then
                    item_filter = entity_data.settings.item_filter.name
                end
                if not quality_filter and entity_data.settings.item_filter then
                    quality_filter = entity_data.settings.item_filter.quality
                end
                if not fluid_filter then
                    fluid_filter = entity_data.settings.fluid_filter
                end
                if not surface_id then
                    surface_id = entity_data.settings.surface_index
                end
                if not quality_filter then
                    quality_filter = QS_DEFAULT_QUALITY
                end
                if surface_id and surface_id ~= surface_index and storage.fabricator_inventory[surface_id] and (item_filter or fluid_filter) then
                    energy_consumption_multiplier = 5
                    transfer_rate_multiplier = 0.5
                else
                    surface_id = surface_index
                end
                if item_filter then
                    local qs_item = {
                        name = item_filter,
                        count = Reactor_constants.item_transfer_rate * transfer_rate_multiplier,
                        type = "item",
                        quality = quality_filter,
                        surface_index = surface_id
                    }
                    local empty_storage, full_inventory = qs_utils.pull_from_storage(qs_item, entity_data.inventory)
                    if empty_storage then
                        energy_consumption = energy_consumption + Reactor_constants.empty_storage_cost
                    end
                    if full_inventory and not empty_storage then
                        energy_consumption = energy_consumption + Reactor_constants.full_inventory_cost
                    end
                    if not empty_storage and not full_inventory then
                        energy_consumption = energy_consumption + Reactor_constants.active_cost
                    end
                end
                if fluid_filter then
                    local qs_item = {
                        name = fluid_filter,
                        count = Reactor_constants.fluid_transfer_rate * transfer_rate_multiplier,
                        type = "fluid",
                        quality = QS_DEFAULT_QUALITY,
                        surface_index = surface_id
                    }
                    local empty_storage, full_inventory = qs_utils.pull_from_storage(qs_item, entity_data.container_fluid)
                    if empty_storage then
                        energy_consumption = energy_consumption + Reactor_constants.empty_storage_cost
                    end
                    if full_inventory and not empty_storage then
                        energy_consumption = energy_consumption + Reactor_constants.full_inventory_cost
                    end
                    if not empty_storage and not full_inventory then
                        energy_consumption = energy_consumption + Reactor_constants.active_cost
                    end
                end
            end

            if energy_consumption > entity_data.entity.temperature then
                entity_data.entity.temperature = 0
            else
                entity_data.entity.temperature = entity_data.entity.temperature - (energy_consumption * energy_consumption_multiplier)
            end

            return
        end

        if entity.name == "qf-storage-reader" then
            local control_behavior = entity.get_control_behavior()
            if not control_behavior then return end
            while control_behavior.sections_count < 2 do
                control_behavior.add_section()
            end
            local storage_index
            for _, signal in pairs(control_behavior.get_section(1).filters) do
                if signal.value.name == "signal-S" then
                    storage_index = signal.min
                end
            end
            if not storage_index or not storage.fabricator_inventory[storage_index] then storage_index = entity_data.surface_index end
            local signals = qs_utils.get_storage_signals(storage_index)
            control_behavior.get_section(2).filters = signals
            return
        end
    end
end
