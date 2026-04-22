local utils = require("scripts/utils")

---@class QSItem Format for items/fluids used in storage and fabrication
---@field name string
---@field count int One of count or amount is required. Think about a way to change it
---@field type "item"|"fluid"
---@field quality? string Quality name
---@field temperature? number
---@field surface_index uint Surface where this item/fluid is stored or processed

---@class StorageStatusTable
---@field empty_storage boolean
---@field full_inventory boolean


---@class qs_utils
local qs_utils = {}
local decraft_queue_batch_size = 2
local decraft_queue_item_max_count = 64
local storage_signal_types = {"item", "fluid"}
local pull_item_insert_params = {
    name = "",
    count = 0,
    quality = QS_DEFAULT_QUALITY,
}
local pull_fluid_insert_params = {
    name = "",
    amount = 0,
    temperature = nil,
}

local function get_storage_signal_key(item_type, item_name, quality_name)
    return item_type .. "|" .. item_name .. "|" .. quality_name
end

local function get_storage_signal_count(count)
    local signal_count = count
    if signal_count > 2147483647 then signal_count = 2147483647 end
    return signal_count
end

local function ensure_storage_signal_cache(inventory)
    local filters = inventory.qf_storage_reader_filters
    local indices = inventory.qf_storage_reader_filter_indices
    if filters and indices and not inventory.qf_storage_reader_cache_dirty then
        return filters, indices, false
    end

    filters = {}
    indices = {}
    for _, item_type in pairs(storage_signal_types) do
        local stored_items = inventory[item_type]
        if stored_items then
            for item_name, item_by_quality in pairs(stored_items) do
                for quality_name, count in pairs(item_by_quality) do
                    if count > 0 then
                        local key = get_storage_signal_key(item_type, item_name, quality_name)
                        indices[key] = #filters + 1
                        filters[#filters + 1] = {
                            value = {type = item_type, quality = quality_name, name = item_name},
                            min = get_storage_signal_count(count),
                        }
                    end
                end
            end
        end
    end
    inventory.qf_storage_reader_filters = filters
    inventory.qf_storage_reader_filter_indices = indices
    inventory.qf_storage_reader_cache_dirty = false
    return filters, indices, true
end

local function mark_storage_signal_cache_dirty(inventory)
    local filters = inventory.qf_storage_reader_filters
    local indices = inventory.qf_storage_reader_filter_indices
    if not filters or not indices then
        return
    end
    inventory.qf_storage_reader_cache_dirty = true
end

local function ensure_storage_metadata(inventory)
    if not inventory then
        return
    end
    if inventory.qf_storage_version == nil then
        inventory.qf_storage_version = 0
    end
end

local function bump_storage_version(inventory)
    if not inventory then
        return
    end
    inventory.qf_storage_version = (inventory.qf_storage_version or 0) + 1
end

local function ensure_decraft_queue_storage()
    if not storage.decraft_queue then
        storage.decraft_queue = {}
    end
    if not storage.request_ids then
        storage.request_ids = {}
    end
    return storage.decraft_queue
end

local function get_decraft_queue_key(surface_index, item_name, quality_name)
    return surface_index .. "|" .. item_name .. "|" .. quality_name
end


---@param qs_item QSItem
---@param try_defabricate? boolean
---@param count_override? int
function qs_utils.add_to_storage(qs_item, try_defabricate, count_override)
    if not qs_item then return end
    local inventory = storage.fabricator_inventory[qs_item.surface_index]
    ensure_storage_metadata(inventory)
    local new_count = inventory[qs_item.type][qs_item.name][qs_item.quality] + (count_override or qs_item.count)
    inventory[qs_item.type][qs_item.name][qs_item.quality] = new_count
    mark_storage_signal_cache_dirty(inventory)
    bump_storage_version(inventory)
    if try_defabricate and settings.global["qf-allow-decrafting"].value and not storage.tiles[qs_item.name] then decraft(qs_item) end
end

---@param surface_index uint
---@param item_contents ItemWithQualityCounts
---@param try_defabricate? boolean
---@param item_count? uint
function qs_utils.add_item_contents_to_storage(surface_index, item_contents, try_defabricate, item_count)
    local inventory = storage.fabricator_inventory[surface_index]
    ensure_storage_metadata(inventory)
    local filters = inventory.qf_storage_reader_filters
    local indices = inventory.qf_storage_reader_filter_indices
    local stored_items = inventory.item
    local do_decraft = try_defabricate and settings.global["qf-allow-decrafting"].value
    local processed_item_count = item_count or #item_contents
    for index = 1, processed_item_count do
        local item = item_contents[index]
        local item_name = item.name
        local quality_name = item.quality
        local new_count = stored_items[item_name][quality_name] + item.count
        stored_items[item_name][quality_name] = new_count
        if do_decraft and not storage.tiles[item_name] then
            qs_utils.queue_decraft(surface_index, item_name, quality_name, item.count)
        end
    end
    if filters and indices then
        inventory.qf_storage_reader_cache_dirty = true
    end
    if processed_item_count > 0 then
        bump_storage_version(inventory)
    end
end

---@param surface_index uint
---@param item_name string
---@param quality_name string
---@param count uint
function qs_utils.queue_decraft(surface_index, item_name, quality_name, count)
    if count <= 0 or not settings.global["qf-allow-decrafting"].value then return end
    if not utils.is_placeable(item_name) or storage.tiles[item_name] then return end

    local queue = ensure_decraft_queue_storage()
    local queue_key = get_decraft_queue_key(surface_index, item_name, quality_name)
    local queued_item = queue[queue_key]
    if queued_item then
        queued_item.count = queued_item.count + count
        return
    end
    queue[queue_key] = {
        surface_index = surface_index,
        name = item_name,
        count = count,
        type = "item",
        quality = quality_name,
    }
end

---@param batch_size? uint
function qs_utils.process_decraft_queue(batch_size)
    local queue = ensure_decraft_queue_storage()
    local request_id_key = "decraft-queue"
    if not next(queue) then
        storage.request_ids[request_id_key] = nil
        return
    end

    local current_key = storage.request_ids[request_id_key]
    if current_key and not queue[current_key] then
        current_key = nil
    end
    if not current_key then
        current_key = next(queue)
    end

    local processed = 0
    local processing_batch_size = batch_size or decraft_queue_batch_size
    while current_key and processed < processing_batch_size do
        local key = current_key
        current_key = next(queue, key)
        local queued_item = queue[key]
        if queued_item then
            if not utils.is_placeable(queued_item.name) or storage.tiles[queued_item.name] then
                queue[key] = nil
            else
                local process_count = math.min(queued_item.count, decraft_queue_item_max_count)
                if process_count > 0 then
                    decraft({
                        surface_index = queued_item.surface_index,
                        name = queued_item.name,
                        count = process_count,
                        type = "item",
                        quality = queued_item.quality,
                    })
                end
                if queued_item.count > process_count then
                    queued_item.count = queued_item.count - process_count
                else
                    queue[key] = nil
                end
            end
        end
        processed = processed + 1
    end

    storage.request_ids[request_id_key] = current_key
end


---@param qs_item QSItem
---@param count_override? int
function qs_utils.remove_from_storage(qs_item, count_override)
    if not qs_item then return end
    local inventory = storage.fabricator_inventory[qs_item.surface_index]
    ensure_storage_metadata(inventory)
    local new_count = inventory[qs_item.type][qs_item.name][qs_item.quality] - (count_override or qs_item.count)
    inventory[qs_item.type][qs_item.name][qs_item.quality] = new_count
    mark_storage_signal_cache_dirty(inventory)
    bump_storage_version(inventory)
end

---Removes items from both the Storage and the player's inventory
---@param qs_item QSItem
---@param available? {storage: uint, inventory: uint|nil}
---@param player_inventory? LuaInventory
---@param count_override? uint
---@return uint --number of items removed from the storage
---@return uint|nil --number of items removed from the inventory
---@return boolean --true if all items were removed
function qs_utils.advanced_remove_from_storage(qs_item, available, player_inventory, count_override)
    local to_remove = count_override or qs_item.count
    local removed_from_storage, removed_from_inventory = 0, 0
    if not available then
        available = {}
        available.storage, available.inventory = qs_utils.count_in_storage(qs_item, player_inventory)
    end
    if available.storage >= to_remove then
        removed_from_storage = to_remove
        qs_utils.remove_from_storage(qs_item, to_remove)
        return removed_from_storage, removed_from_inventory, true
    elseif available.storage > 0 then
        removed_from_storage = available.storage
        qs_utils.remove_from_storage(qs_item, available.storage)
        to_remove = to_remove - available.storage
    end
    if player_inventory then
        if available.inventory >= to_remove then
            removed_from_inventory = to_remove
            player_inventory.remove({name = qs_item.name, count = to_remove, quality = qs_item.quality})
            return removed_from_storage, removed_from_inventory, true
        elseif available.inventory > 0 then
            removed_from_inventory = available.inventory
            player_inventory.remove({name = qs_item.name, count = available.inventory, quality = qs_item.quality})
            to_remove = to_remove - available.inventory
        end
    end
    return removed_from_storage, removed_from_inventory, false
end

---Actually it first adds all placeables/modules/ingredients to the storage and only then adds the leftovers to the player's inventory
---@param player_inventory? LuaInventory
---@param qs_item QSItem
function qs_utils.add_to_player_inventory(player_inventory, qs_item)
    if qs_item.type == "fluid" or utils.is_placeable(qs_item.name) or storage.ingredient[qs_item.name] or utils.is_module(qs_item.name) or not player_inventory then
        qs_utils.add_to_storage(qs_item, true)
    else
        local inserted = player_inventory.insert({name = qs_item.name, count = qs_item.count, quality = qs_item.quality})
        if qs_item.count - inserted > 0 then
            qs_item.count = qs_item.count - inserted
            qs_utils.add_to_storage(qs_item)
        end
    end
end

---Initializes the storage table for this particular item.
---@param qs_item QSItem
function qs_utils.storage_item_check(qs_item)
    qs_utils.set_default_quality(qs_item)
    if not storage.fabricator_inventory[qs_item.surface_index] then
        storage.fabricator_inventory[qs_item.surface_index] = {}
    end
    ensure_storage_metadata(storage.fabricator_inventory[qs_item.surface_index])
    if not storage.fabricator_inventory[qs_item.surface_index][qs_item.type] then
        storage.fabricator_inventory[qs_item.surface_index][qs_item.type] = {}
    end
    if not storage.fabricator_inventory[qs_item.surface_index][qs_item.type][qs_item.name] then
        storage.fabricator_inventory[qs_item.surface_index][qs_item.type][qs_item.name] = {}
    end
    if not storage.fabricator_inventory[qs_item.surface_index][qs_item.type][qs_item.name][qs_item.quality] then
        storage.fabricator_inventory[qs_item.surface_index][qs_item.type][qs_item.name][qs_item.quality] = 0
    end
end

---Because liquids may not have quality? Might not be needed
---@param qs_item QSItem
function qs_utils.set_default_quality(qs_item)
    if not qs_item.quality then qs_item.quality = QS_DEFAULT_QUALITY end
end

---Transfers items/fluids from storage to target inventory. Used by dedigitizing reactors and space requests
---@param qs_item QSItem
---@param target_inventory LuaInventory | LuaEntity
---@return boolean
---@return boolean
function qs_utils.pull_from_storage(qs_item, target_inventory)
    local storage_inventory = storage.fabricator_inventory[qs_item.surface_index]
    if not storage_inventory then
        return true, false
    end
    ensure_storage_metadata(storage_inventory)
    local item_type = qs_item.type
    local item_name = qs_item.name
    local item_quality = qs_item.quality
    local item_storage = storage_inventory[item_type][item_name]
    local in_storage = item_storage[item_quality]
    local to_be_provided = qs_item.count
    if in_storage <= 0 then
        return true, false
    end
    local empty_storage = false
    if in_storage < to_be_provided then
        to_be_provided = in_storage
        empty_storage = true
    end
    if qs_item.type == "item" then
        pull_item_insert_params.name = item_name
        pull_item_insert_params.count = to_be_provided
        pull_item_insert_params.quality = item_quality
        local inserted = target_inventory.insert(pull_item_insert_params)
        qs_item.count = inserted
        if inserted <= 0 then
            return empty_storage, true
        end
        local new_count = in_storage - inserted
        item_storage[item_quality] = new_count
        mark_storage_signal_cache_dirty(storage_inventory)
        bump_storage_version(storage_inventory)
        if inserted < to_be_provided then
            return empty_storage, true
        end
    elseif qs_item.type == "fluid" then
        local current_fluid = target_inventory.get_fluid_contents()
        for name, amount in pairs(current_fluid) do
            if name == item_name then
                pull_fluid_insert_params.name = item_name
                pull_fluid_insert_params.amount = to_be_provided
                if qs_item.temperature then
                    pull_fluid_insert_params.temperature = qs_item.temperature
                else
                    pull_fluid_insert_params.temperature = nil
                end
                ---@diagnostic disable-next-line: assign-type-mismatch
                local inserted = target_inventory.insert_fluid(pull_fluid_insert_params)
                qs_item.count = inserted
                if inserted <= 0 then
                    return empty_storage, true
                end
                local new_count = in_storage - inserted
                item_storage[item_quality] = new_count
                mark_storage_signal_cache_dirty(storage_inventory)
                bump_storage_version(storage_inventory)
                if inserted < to_be_provided then
                    return empty_storage, true
                end
                return empty_storage, false
            else
                qs_utils.add_to_storage({surface_index = qs_item.surface_index, name = name, count = target_inventory.remove_fluid{name = name, amount = amount}, type = "fluid", quality = QS_DEFAULT_QUALITY})
            end
        end
        pull_fluid_insert_params.name = item_name
        pull_fluid_insert_params.amount = to_be_provided
        if qs_item.temperature then
            pull_fluid_insert_params.temperature = qs_item.temperature
        else
            pull_fluid_insert_params.temperature = nil
        end
        ---@diagnostic disable-next-line: assign-type-mismatch
        local inserted = target_inventory.insert_fluid(pull_fluid_insert_params)
        qs_item.count = inserted
        if inserted <= 0 then
            return empty_storage, true
        end
        local new_count = in_storage - inserted
        item_storage[item_quality] = new_count
        mark_storage_signal_cache_dirty(storage_inventory)
        bump_storage_version(storage_inventory)
        if inserted < to_be_provided then
            return empty_storage, true
        end
    end
    return empty_storage, false
end

---How many of that item is available in the storage (and player_inventory if it's provided)
---@param qs_item QSItem
---@param player_inventory? LuaInventory
---@param player_surface_index? uint
---@return uint
---@return uint
---@return uint
function qs_utils.count_in_storage(qs_item, player_inventory, player_surface_index)
    local surface_storage = storage.fabricator_inventory[qs_item.surface_index]
    local in_storage = 0
    if surface_storage then
        in_storage = surface_storage[qs_item.type][qs_item.name][qs_item.quality]
    end
    local in_player_inventory = 0
    if player_inventory and qs_item.type == "item" then
        if not player_surface_index then
            local player = player_inventory.player_owner
            if player then
                player_surface_index = player.physical_surface_index
            else
                return in_storage, 0, in_storage
            end
        end
        if qs_item.surface_index == player_surface_index then
            in_player_inventory = player_inventory.get_item_count({name = qs_item.name, quality = qs_item.quality})
        end
    end
    return in_storage, in_player_inventory, in_storage + in_player_inventory
end

---@param surface_index uint
---@param player_inventory? LuaInventory
---@param player_surface_index? uint
---@return {[string]: uint}
function qs_utils.get_available_tiles(surface_index, player_inventory, player_surface_index)
    local result = {}
    for tile_name, _ in pairs(storage.tiles) do
        _, _, result[tile_name] = qs_utils.count_in_storage({
            name = tile_name,
            count = 1,
            surface_index = surface_index,
            quality = QS_DEFAULT_QUALITY,
            type = "item",
        }, player_inventory, player_surface_index)
    end
    return result
end

---Takes a stack of items from storage to the player's inventory. Only if the player is physically present on the same surface (to prevent some cheesing)
---@param qs_item QSItem
---@param player LuaPlayer
---@param requested_stacks? uint
---@param take_all? boolean
function qs_utils.take_from_storage(qs_item, player, requested_stacks, take_all)
    local item_name = qs_item.name
    local prototype = prototypes.item[item_name]
    if not prototype then return end
    local in_storage = qs_utils.count_in_storage(qs_item)
    if in_storage <= 0 then return end
    local quality_name = qs_item.quality
    local amount_to_take = in_storage
    if not take_all then
        amount_to_take = prototype.stack_size * (requested_stacks or 1)
    end
    if in_storage < amount_to_take then
        amount_to_take = in_storage
    end
    qs_item.count = amount_to_take
    if player.surface.platform and qs_item.surface_index == player.surface.index and player.surface.platform.hub then
        qs_utils.pull_from_storage(qs_item, player.surface.platform.hub)
    else
        local player_inventory = utils.get_player_inventory(player)
        if not player_inventory then return end
        qs_utils.pull_from_storage(qs_item, player_inventory)
    end
    update_removal_tab_label(player, item_name, quality_name, qs_item.surface_index)
end

---Adds item to temp table for statistics
---@param name string
---@param quality string
---@param type string
---@param surface_index uint
function qs_utils.add_temp_prod_statistics(name, quality, type, surface_index, count)
    local uniq_name = name .. "_" .. quality .. "_" .. type .. "_" .. surface_index
    if not storage.temp_statistics[uniq_name] then
        storage.temp_statistics[uniq_name] = {name = name, type = type, quality = quality, count = count, surface_index = surface_index}
    else
        storage.temp_statistics[uniq_name].count = storage.temp_statistics[uniq_name].count + count
    end
    storage.countdowns.temp_statistics = 2
end

---Processes the entire temp_statistics table at once and resets it
function qs_utils.add_production_statistics()
    local item_stats = {}
    local fluid_stats = {}
    for _, item in pairs(storage.temp_statistics) do
        local surface_index = item.surface_index
        if not item_stats[surface_index] then item_stats[surface_index] = game.forces["player"].get_item_production_statistics(surface_index) end
        if not fluid_stats[surface_index] then fluid_stats[surface_index] = game.forces["player"].get_fluid_production_statistics(surface_index) end
        if item.type == "item" then
            item_stats[surface_index].on_flow({name = item.name, quality = item.quality}, item.count)
        else
            fluid_stats[surface_index].on_flow(item.name, item.count)
        end
    end
    storage.temp_statistics = {}
end

---@param storage_index uint
---@return LogisticFilter[]
function qs_utils.get_storage_signals(storage_index)
    local inventory = storage.fabricator_inventory[storage_index]
    local signals = ensure_storage_signal_cache(inventory)
    return signals
end

-- Moves all items from the source storage to the target storage
---@param source_index uint
---@param target_index uint
function qs_utils.move_all_items(source_index, target_index)
    for _, type in pairs(storage_signal_types) do
        for name, item in pairs(storage.fabricator_inventory[source_index][type]) do
            for quality, count in pairs(item) do
                qs_utils.add_to_storage({type = type, name = name, count = count, quality = quality, surface_index = target_index})
                qs_utils.remove_from_storage({type = type, name = name, count = count, quality = quality, surface_index = source_index})
            end
        end
    end
end

-- Unifies all currently existing storage inventories by moving items to storage #1 and making them a reference to it
function qs_utils.unify_storage()
    for storage_index, _ in pairs(storage.fabricator_inventory) do
        if storage_index ~= 1 then
            qs_utils.move_all_items(storage_index, 1)
            storage.fabricator_inventory[storage_index] = storage.fabricator_inventory[1]
        end
    end
end

-- Removes reference to all existing storage inventories and processes factorissimo as well
function qs_utils.deunify_storage()
    for storage_index, _ in pairs(storage.fabricator_inventory) do
        if storage_index ~= 1 then
            storage.fabricator_inventory[storage_index] = nil
            initialize_fabricator_inventory(storage_index)
        end
    end
    -- Needed to restore factorissimo references
    if script.active_mods["factorissimo-2-notnotmelon"] then
        initialize_surfaces()
    end
end

return qs_utils
