return function(context)
    local tracking = context.tracking
    local flib_table = context.flib_table
    local utils = context.utils

    local tracked_entity_nth_ticks = {Update_rate.reactors}

    function tracking.on_tick_update_requests()
        for i = 1, 3 do
            if next(storage.tracked_requests[On_tick_requests[i]]) then
                storage.request_ids[On_tick_requests[i]] = flib_table.for_n_of(storage.tracked_requests[On_tick_requests[i]], storage.request_ids[On_tick_requests[i]], 3, function(request_entry)
                    return tracking.on_tick_update_handler(request_entry, On_tick_requests[i])
                end)
            end
        end
    end

    function tracking.get_registered_nth_ticks()
        local nth_tick_map = {
            [5] = true,
            [8] = true,
            [9] = true,
            [19] = true,
            [84] = true,
        }
        for _, nth_tick in pairs(tracked_entity_nth_ticks) do
            nth_tick_map[nth_tick] = true
        end
        local result = {}
        for nth_tick, _ in pairs(nth_tick_map) do
            table.insert(result, nth_tick)
        end
        return result
    end

    function tracking.on_fixed_nth_tick(event)
        if event.nth_tick == 5 then
            if storage.qf_enabled == false then return end
            if next(storage.tracked_requests["repairs"]) and not storage.countdowns.in_combat then
                storage.request_ids["repairs"] = flib_table.for_n_of(storage.tracked_requests["repairs"], storage.request_ids["repairs"], 2, function(request_table)
                    if not request_table.entity.valid then return nil, true, false end
                    if instant_repair(request_table.entity) then
                        return nil, true, false
                    else
                        return nil, false, false
                    end
                end)
            end
            return
        end
        if event.nth_tick == 9 then
            if storage.qf_enabled == false then return end
            if next(storage.tracked_requests["item_requests"]) then
                storage.request_ids["item_requests"] = flib_table.for_n_of(storage.tracked_requests["item_requests"], storage.request_ids["item_requests"], 2, function(request_table)
                    return tracking.update_item_request_proxy(request_table)
                end)
            end
            return
        end
        if event.nth_tick == 19 then
            if storage.qf_enabled == false then return end
            if next(storage.tracked_requests["cliffs"]) then
                storage.request_ids["cliffs"] = flib_table.for_n_of(storage.tracked_requests["cliffs"], storage.request_ids["cliffs"], 3, function(request_table)
                    if not request_table.entity.valid then return nil, true, false end
                    if instant_decliffing(request_table.entity, request_table.player_index) then
                        return nil, true, false
                    else
                        return nil, false, false
                    end
                end)
            end
            return
        end
        if event.nth_tick == 84 then
            if next(storage.tracked_entities["qf-storage-reader"]) then
                storage.request_ids["qf-storage-reader"] = flib_table.for_n_of(storage.tracked_entities["qf-storage-reader"], storage.request_ids["qf-storage-reader"], 2, function(entity_data)
                    tracking.update_entity(entity_data)
                end)
            end
            return
        end
        if event.nth_tick == 8 then
            if storage.qf_enabled == false then return end
            if next(storage.tracked_requests["construction"]) then
                storage.request_ids["construction"] = flib_table.for_n_of(storage.tracked_requests["construction"], storage.request_ids["construction"], 3, function(request_table)
                    local entity = request_table.entity
                    local player_index = request_table.player_index
                    if not entity.valid then return nil, true, false end
                    if instant_fabrication(entity, player_index) then
                        return nil, true, false
                    else
                        return nil, false, false
                    end
                end)
            end
        end
    end

    function tracking.on_tracked_entity_nth_tick(event)
        if event.nth_tick == Update_rate.reactors then
            tracking.update_tracked_reactors()
        end
    end

    function tracking.update_item_request_proxy(request_table)
        local entity = request_table.entity
        if not entity.valid then return nil, true, false end
        local item_request_proxy = request_table.item_request_proxy
        if not item_request_proxy.valid then return nil, true, false end
        local insert_plan = item_request_proxy.insert_plan
        local removal_plan = item_request_proxy.removal_plan
        local player_index = request_table.player_index

        if not item_request_proxy or not item_request_proxy.valid then
            return nil, true, false
        end
        if not next(insert_plan) and not next(removal_plan) then
            request_table.item_request_proxy.destroy()
            return nil, true, false
        end
        local player_inventory = utils.get_player_inventory(nil, player_index)
        if handle_item_requests(entity, item_request_proxy.item_requests, insert_plan, removal_plan, player_inventory) then
            request_table.item_request_proxy.destroy()
            return nil, true, false
        end
        return nil, false, false
    end

    function tracking.on_tick_update_handler(entity, request_type)
        local request_table = entity
        local player_index = storage.request_player_ids[request_type]
        if request_table.entity then
            entity = request_table.entity
            if request_table.player_index ~= nil then
                player_index = request_table.player_index
            end
        end
        if not entity.valid then return nil, true, false end
        if request_type == "revivals" then
            if not instant_fabrication(entity, player_index) then
                tracking.create_tracked_request({
                    entity = entity,
                    player_index = player_index,
                    request_type = "construction"
                })
            end
            return nil, true, false
        elseif request_type == "destroys" then
            if instant_defabrication(entity, player_index) then
                return nil, true, false
            else
                return nil, false, false
            end
        elseif request_type == "upgrades" then
            local target, quality_prototype = entity.get_upgrade_target()
            if not target then return nil, true, false end
            local quality
            if not quality_prototype then
                quality = QS_DEFAULT_QUALITY
            else
                quality = quality_prototype.name
            end
            local status = instant_upgrade(entity, target, quality, player_index)
            if status == "success" then
                return nil, true, false
            end
        end
        return nil, false, false
    end

    function tracking.update_lost_module_requests(player)
        utils.validate_surfaces()
        for _, surface_data in pairs(storage.surface_data.planets) do
            for _, entity in pairs(surface_data.surface.find_entities_filtered{name = "item-request-proxy"}) do
                if entity.proxy_target and not storage.tracked_requests["item_requests"][entity.proxy_target.unit_number] then
                    tracking.create_tracked_request({
                        entity = entity.proxy_target,
                        player_index = player.index,
                        item_request_proxy = entity,
                        request_type = "item_requests"
                    })
                end
            end
        end
    end

    local function scan_item_request_proxy_chunks(chunks, request_id_key, amount, remove_after_scan)
        if not chunks or not next(chunks) then return end
        storage.request_ids[request_id_key] = flib_table.for_n_of(chunks, storage.request_ids[request_id_key] or 1, amount, function(chunk)
            local surface = game.surfaces[chunk.surface_index]
            if not surface then return nil, true, false end
            for _, entity in pairs(surface.find_entities_filtered{name = "item-request-proxy", area = chunk.area}) do
                if entity.proxy_target and not storage.tracked_requests["item_requests"][entity.proxy_target.unit_number] then
                    tracking.create_tracked_request({
                        entity = entity.proxy_target,
                        item_request_proxy = entity,
                        request_type = "item_requests"
                    })
                end
            end
            return nil, remove_after_scan, false
        end)
    end

    function tracking.update_lost_module_requests_neo()
        scan_item_request_proxy_chunks(storage.dirty_chunks, "item_proxies_dirty", 4, true)
    end

    function tracking.recheck_all_item_request_proxies()
        if not storage.chunks then return end
        for _, chunk in pairs(storage.chunks) do
            local surface = game.surfaces[chunk.surface_index]
            if surface then
                for _, entity in pairs(surface.find_entities_filtered{name = "item-request-proxy", area = chunk.area}) do
                    if entity.proxy_target and not storage.tracked_requests["item_requests"][entity.proxy_target.unit_number] then
                        tracking.create_tracked_request({
                            entity = entity.proxy_target,
                            item_request_proxy = entity,
                            request_type = "item_requests"
                        })
                    end
                end
            end
        end
    end
end
