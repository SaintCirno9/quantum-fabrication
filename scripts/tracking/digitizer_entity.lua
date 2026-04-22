return function(context)
    local tracking = context.tracking
    local qs_utils = context.qs_utils
    local sync_digitizer_chest_fluid_setting = context.sync_digitizer_chest_fluid_setting
    local get_digitizer_update_temp_data = context.get_digitizer_update_temp_data
    local refresh_digitizer_chest_signals = context.refresh_digitizer_chest_signals
    local digitizer_chest_has_processable_contents = context.digitizer_chest_has_processable_contents
    local digitizer_chest_has_contents = context.digitizer_chest_has_contents
    local set_digitizer_chest_queue = context.set_digitizer_chest_queue
    local get_digitizer_signal_request_parse = context.get_digitizer_signal_request_parse
    local load_digitizer_signal_request_processing = context.load_digitizer_signal_request_processing
    local digitizer_chest_reads_contents = context.digitizer_chest_reads_contents
    local digitizer_intake_limit_remaining_capacity = context.digitizer_intake_limit_remaining_capacity
    local get_container_fluid_state = context.get_container_fluid_state
    local fluid_temperatures_match = context.fluid_temperatures_match
    local fabricate_digitizer_requested_item = context.fabricate_digitizer_requested_item
    local digitizer_chest_signal_recheck_ticks = context.digitizer_chest_signal_recheck_ticks
    local digitizer_chest_active_keepalive_ticks = context.digitizer_chest_active_keepalive_ticks
    local digitizer_chest_idle_to_long_idle_checks = context.digitizer_chest_idle_to_long_idle_checks

    function context.update_digitizer_chest_entity(entity_data)
        local entity = entity_data.entity
        local surface_index = entity_data.surface_index

        if entity.name == "digitizer-chest"
            and (
                entity_data.settings.fluid_enabled == nil
                or (entity_data.settings.fluid_enabled and not (entity_data.container_fluid and entity_data.container_fluid.valid))
                or (not entity_data.settings.fluid_enabled and entity_data.container_fluid ~= nil)
            ) then
            sync_digitizer_chest_fluid_setting(entity_data)
        end
        local inventory = entity_data.inventory
        local fetchable = settings.global["qf-super-digitizing-chests"].value
        local requester_buffered = entity.name == "digitizer-requester-chest"
        local signal_fetchable = fetchable or requester_buffered
        local limit_value = entity_data.settings.intake_limit
        local reserve_limit = entity_data.settings.reserve_limit or 0
        local decraft = entity_data.settings.decraft
        local storage_index = surface_index
        local update_temp_data = get_digitizer_update_temp_data(entity_data, storage_index)
        local item_qs_item = update_temp_data.item_qs_item
        local item_qs_fluid = update_temp_data.item_qs_fluid
        local item_remove_params = update_temp_data.item_remove_params
        local fluid_remove_params = update_temp_data.fluid_remove_params
        local batch_item_contents = update_temp_data.batch_item_contents
        if entity_data.signal_active == nil then
            entity_data.signal_active = true
        end
        if entity_data.next_signal_check_tick == nil then
            entity_data.next_signal_check_tick = 0
        end
        if entity_data.signal_check_interval_ticks == nil then
            entity_data.signal_check_interval_ticks = digitizer_chest_signal_recheck_ticks
        end
        if entity_data.active_until_tick == nil then
            entity_data.active_until_tick = 0
        end
        local signals = refresh_digitizer_chest_signals(entity_data)
        if not entity_data.signal_active then
            entity_data.has_unmet_signal_requests = false
            entity_data.parsed_signal_requests = nil
            local storage_surface = storage.fabricator_inventory[storage_index]
            local storage_items = storage_surface.item
            local storage_fluids = storage_surface.fluid
            local moved_contents = false
            if inventory and not inventory.is_empty() then
                local inventory_contents = inventory.get_contents()
                item_qs_item.surface_index = storage_index
                if limit_value == 0 then
                    if next(inventory_contents) then
                        if reserve_limit == 0 then
                            qs_utils.add_item_contents_to_storage(storage_index, inventory_contents, decraft)
                            inventory.clear()
                            moved_contents = true
                        else
                            for _, item in pairs(inventory_contents) do
                                local removable_count = item.count - reserve_limit
                                if removable_count > 0 then
                                    item_qs_item.name = item.name
                                    item_qs_item.count = removable_count
                                    item_qs_item.quality = item.quality
                                    qs_utils.add_to_storage(item_qs_item, decraft)
                                    item_remove_params.name = item.name
                                    item_remove_params.count = removable_count
                                    item_remove_params.quality = item.quality
                                    inventory.remove(item_remove_params)
                                    moved_contents = true
                                end
                            end
                        end
                    end
                else
                    for _, item in pairs(inventory_contents) do
                        local removable_count = item.count - reserve_limit
                        local remaining_capacity = digitizer_intake_limit_remaining_capacity(item.name, item.quality, storage_index, storage_items, limit_value, decraft)
                        if removable_count > 0 and remaining_capacity > 0 then
                            item_qs_item.name = item.name
                            item_qs_item.count = math.min(removable_count, remaining_capacity)
                            item_qs_item.quality = item.quality
                            qs_utils.add_to_storage(item_qs_item, decraft)
                            item_remove_params.name = item.name
                            item_remove_params.count = item_qs_item.count
                            item_remove_params.quality = item.quality
                            inventory.remove(item_remove_params)
                            moved_contents = true
                        end
                    end
                end
            end
            local fluid_contents = entity_data.container_fluid and entity_data.container_fluid.get_fluid_contents()
            if fluid_contents then
                item_qs_fluid.surface_index = storage_index
                if limit_value == 0 then
                    for name, count in pairs(fluid_contents) do
                        local removable_count = count - reserve_limit
                        if removable_count > 0 then
                            item_qs_fluid.name = name
                            item_qs_fluid.count = removable_count
                            qs_utils.add_to_storage(item_qs_fluid)
                            fluid_remove_params.name = name
                            fluid_remove_params.amount = removable_count
                            entity_data.container_fluid.remove_fluid(fluid_remove_params)
                            moved_contents = true
                        end
                    end
                else
                    for name, count in pairs(fluid_contents) do
                        local removable_count = count - reserve_limit
                        local remaining_capacity = limit_value - storage_fluids[name][QS_DEFAULT_QUALITY]
                        if removable_count > 0 and remaining_capacity > 0 then
                            item_qs_fluid.name = name
                            item_qs_fluid.count = math.min(removable_count, remaining_capacity)
                            qs_utils.add_to_storage(item_qs_fluid)
                            fluid_remove_params.name = name
                            fluid_remove_params.amount = item_qs_fluid.count
                            entity_data.container_fluid.remove_fluid(fluid_remove_params)
                            moved_contents = true
                        end
                    end
                end
            end
            if moved_contents then
                entity_data.active_until_tick = game.tick + digitizer_chest_active_keepalive_ticks
            end
            local has_processable_contents = digitizer_chest_has_processable_contents(entity_data)
            if has_processable_contents or game.tick <= entity_data.active_until_tick then
                entity_data.idle_empty_checks = 0
                set_digitizer_chest_queue(entity_data, "active")
            else
                local has_contents = digitizer_chest_has_contents(entity_data)
                entity_data.idle_empty_checks = (entity_data.idle_empty_checks or 0) + 1
                if not has_contents and entity_data.idle_empty_checks >= digitizer_chest_idle_to_long_idle_checks then
                    set_digitizer_chest_queue(entity_data, "long_idle")
                else
                    set_digitizer_chest_queue(entity_data, "idle")
                end
            end
            return
        end
        entity_data.idle_empty_checks = 0
        local had_unmet_signal_requests = entity_data.has_unmet_signal_requests == true
        local has_unmet_signal_requests_after = false
        local pulled_signal_contents = false
        local read_contents = false

        local parsed = get_digitizer_signal_request_parse(entity_data, signals, signal_fetchable)
        local fixed_quantity = parsed and parsed.fixed_quantity or 0
        local processing_items = parsed and parsed.items or {}
        local processing_items_mutable = false
        local processing_fluid_name = parsed and parsed.fluids.name or ""
        local processing_fluid_count = parsed and parsed.fluids.count or 0
        local processing_fluid_temperature = parsed and parsed.fluids.temperature or nil
        if parsed and parsed.limit_value then
            limit_value = parsed.limit_value
        end
        if parsed and parsed.decraft ~= nil then
            decraft = parsed.decraft
        end
        if parsed then
            storage_index = parsed.storage_index
        end

        local function ensure_processing_items_mutable()
            if processing_items_mutable or not parsed then
                return
            end
            processing_items = load_digitizer_signal_request_processing(entity_data, parsed).items
            processing_items_mutable = true
        end

        if not storage.fabricator_inventory[storage_index] or not signal_fetchable then
            storage_index = surface_index
        end
        local storage_surface = storage.fabricator_inventory[storage_index]
        local storage_items = storage_surface.item
        local storage_fluids = storage_surface.fluid

        if inventory then
            read_contents = digitizer_chest_reads_contents(entity)
            local inventory_contents
            if not inventory.is_empty() then
                inventory_contents = inventory.get_contents()
                ensure_processing_items_mutable()
                item_qs_item.surface_index = storage_index
                local batch_item_count = 0
                for _, item in pairs(inventory_contents) do
                    local total_count = item.count
                    item_qs_item.name = item.name
                    item_qs_item.count = total_count
                    item_qs_item.quality = item.quality
                    local removable = true
                    local item_by_quality = processing_items[item.name]
                    local requested_count = item_by_quality and item_by_quality[item.quality]
                    if requested_count then
                        if read_contents and fixed_quantity == 0 then
                            requested_count = requested_count - total_count
                        end
                        if item_qs_item.count == requested_count then
                            item_by_quality[item.quality] = nil
                            removable = false
                        elseif item_qs_item.count > requested_count then
                            item_qs_item.count = item_qs_item.count - requested_count
                            item_by_quality[item.quality] = nil
                        else
                            item_by_quality[item.quality] = requested_count - item_qs_item.count
                            removable = false
                        end
                    end
                    if removable then
                        local removable_count = total_count - reserve_limit
                        if item_qs_item.count > removable_count then
                            item_qs_item.count = removable_count
                        end
                        if limit_value ~= 0 then
                            local remaining_capacity = digitizer_intake_limit_remaining_capacity(item_qs_item.name, item_qs_item.quality, storage_index, storage_items, limit_value, decraft)
                            if item_qs_item.count > remaining_capacity then
                                item_qs_item.count = remaining_capacity
                            end
                        end
                        if item_qs_item.count > 0 then
                            batch_item_count = batch_item_count + 1
                            local batch_item = batch_item_contents[batch_item_count]
                            if batch_item then
                                batch_item.name = item_qs_item.name
                                batch_item.count = item_qs_item.count
                                batch_item.quality = item_qs_item.quality
                            else
                                batch_item_contents[batch_item_count] = {
                                    name = item_qs_item.name,
                                    count = item_qs_item.count,
                                    quality = item_qs_item.quality
                                }
                            end
                        end
                    end
                end
                if batch_item_count > 0 then
                    qs_utils.add_item_contents_to_storage(storage_index, batch_item_contents, decraft, batch_item_count)
                    for index = 1, batch_item_count do
                        local batch_item = batch_item_contents[index]
                        if batch_item then
                            item_remove_params.name = batch_item.name
                            item_remove_params.count = batch_item.count
                            item_remove_params.quality = batch_item.quality
                            inventory.remove(item_remove_params)
                        end
                    end
                end
            end
            for item_name, item_by_quality in pairs(processing_items) do
                for item_quality, item_count in pairs(item_by_quality) do
                    if item_count > 0 then
                        local remaining_item_count = item_count
                        item_qs_item.name = item_name
                        item_qs_item.count = item_count
                        item_qs_item.quality = item_quality
                        item_qs_item.surface_index = storage_index
                        local requested_item_count = item_qs_item.count
                        local empty_storage, full_inventory = qs_utils.pull_from_storage(item_qs_item, inventory)
                        local pulled_item_count = item_qs_item.count
                        if empty_storage and pulled_item_count == requested_item_count then
                            pulled_item_count = 0
                        end
                        remaining_item_count = remaining_item_count - pulled_item_count
                        if pulled_item_count > 0 then
                            pulled_signal_contents = true
                        end
                        if remaining_item_count > 0 and not full_inventory and fetchable then
                            item_qs_item.count = remaining_item_count
                            fabricate_digitizer_requested_item(item_qs_item, inventory)
                            if item_qs_item.count > 0 then
                                pulled_signal_contents = true
                            end
                            remaining_item_count = remaining_item_count - item_qs_item.count
                        end
                        if processing_items_mutable then
                            if remaining_item_count > 0 then
                                item_by_quality[item_quality] = remaining_item_count
                            else
                                item_by_quality[item_quality] = nil
                            end
                        end
                        if remaining_item_count > 0 then
                            has_unmet_signal_requests_after = true
                        end
                        if full_inventory then
                            has_unmet_signal_requests_after = true
                        end
                    end
                end
            end
        end
        local fluid_contents = entity_data.container_fluid and entity_data.container_fluid.get_fluid_contents()
        if fluid_contents then
            local current_fluid = get_container_fluid_state(entity_data.container_fluid)
            item_qs_fluid.surface_index = storage_index
            item_qs_fluid.temperature = nil
            for name, count in pairs(fluid_contents) do
                item_qs_fluid.name = name
                item_qs_fluid.count = count
                local removable = true
                local replace_requested_fluid = processing_fluid_count > 0
                    and name == processing_fluid_name
                    and not fluid_temperatures_match(current_fluid and current_fluid.temperature or nil, processing_fluid_temperature)
                if processing_fluid_count > 0 then
                    if not replace_requested_fluid and item_qs_fluid.count == processing_fluid_count then
                        processing_fluid_count = 0
                        removable = false
                    elseif not replace_requested_fluid and item_qs_fluid.count > processing_fluid_count then
                        item_qs_fluid.count = item_qs_fluid.count - processing_fluid_count
                        processing_fluid_count = 0
                    elseif not replace_requested_fluid then
                        processing_fluid_count = processing_fluid_count - item_qs_fluid.count
                        removable = false
                    end
                end
                if removable then
                    local removable_count = count
                    if not replace_requested_fluid then
                        removable_count = count - reserve_limit
                    end
                    if item_qs_fluid.count > removable_count then
                        item_qs_fluid.count = removable_count
                    end
                    if not replace_requested_fluid and limit_value ~= 0 then
                        local remaining_capacity = limit_value - storage_fluids[name][QS_DEFAULT_QUALITY]
                        if item_qs_fluid.count > remaining_capacity then
                            item_qs_fluid.count = remaining_capacity
                        end
                    end
                    if item_qs_fluid.count > 0 then
                        qs_utils.add_to_storage(item_qs_fluid)
                        fluid_remove_params.name = name
                        fluid_remove_params.amount = item_qs_fluid.count
                        entity_data.container_fluid.remove_fluid(fluid_remove_params)
                    end
                end
            end
            if processing_fluid_count > 0 then
                local remaining_fluid_count = processing_fluid_count
                item_qs_fluid.name = processing_fluid_name
                item_qs_fluid.count = processing_fluid_count
                item_qs_fluid.temperature = processing_fluid_temperature
                item_qs_fluid.surface_index = storage_index
                local requested_fluid_count = item_qs_fluid.count
                local empty_storage, full_inventory = qs_utils.pull_from_storage(item_qs_fluid, entity_data.container_fluid)
                local pulled_fluid_count = item_qs_fluid.count
                if empty_storage and pulled_fluid_count == requested_fluid_count then
                    pulled_fluid_count = 0
                end
                remaining_fluid_count = remaining_fluid_count - pulled_fluid_count
                if pulled_fluid_count > 0 then
                    pulled_signal_contents = true
                end
                processing_fluid_count = remaining_fluid_count
                if remaining_fluid_count > 0 or full_inventory then
                    has_unmet_signal_requests_after = true
                end
            end
        end
        if had_unmet_signal_requests or pulled_signal_contents then
            entity_data.active_until_tick = game.tick + digitizer_chest_active_keepalive_ticks
        end
        entity_data.has_unmet_signal_requests = has_unmet_signal_requests_after
        if has_unmet_signal_requests_after or game.tick <= entity_data.active_until_tick then
            set_digitizer_chest_queue(entity_data, "signal")
        else
            set_digitizer_chest_queue(entity_data, "idle")
        end
    end
end
