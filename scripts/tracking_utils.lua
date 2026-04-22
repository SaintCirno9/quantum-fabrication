---@diagnostic disable: need-check-nil
local qs_utils = require("scripts/qs_utils")
local qf_utils = require("scripts/qf_utils")
local flib_table = require("__flib__.table")
local utils = require("scripts/utils")

--@diagnostic disable: need-check-nil
---@class tracking
local tracking = {}
local digitizer_chest_signal_recheck_ticks = 30
local digitizer_chest_signal_recheck_max_ticks = 240

local function is_prime_tick(value)
    if value < 2 then
        return false
    end
    if value == 2 then
        return true
    end
    if value % 2 == 0 then
        return false
    end
    local divisor = 3
    while divisor * divisor <= value do
        if value % divisor == 0 then
            return false
        end
        divisor = divisor + 2
    end
    return true
end

local function get_next_prime_tick(value)
    local candidate = math.max(value, 2)
    if candidate == 2 then
        return candidate
    end
    if candidate % 2 == 0 then
        candidate = candidate + 1
    end
    while not is_prime_tick(candidate) do
        candidate = candidate + 2
    end
    return candidate
end

local digitizer_chest_signal_nth_tick = settings.startup["qf-digitizer-signal-nth-tick"].value
local digitizer_chest_active_nth_tick = settings.startup["qf-digitizer-active-nth-tick"].value
local digitizer_chest_idle_nth_tick = settings.startup["qf-digitizer-idle-nth-tick"].value
local digitizer_chest_long_idle_nth_tick = get_next_prime_tick(math.max(digitizer_chest_idle_nth_tick * 5, 60))
local digitizer_chest_idle_to_long_idle_checks = 3
local digitizer_chest_active_keepalive_ticks = math.max(digitizer_chest_active_nth_tick * 4, 60)
local digitizer_chest_processable_recheck_ticks = digitizer_chest_active_nth_tick
local digitizer_chest_processable_recheck_max_ticks = digitizer_chest_idle_nth_tick
local digitizer_queue_dynamic_batch_divisor = 6
local digitizer_queue_full_pass_seconds_cache_version = 4
local digitizer_queue_max_work_per_tick = {
    signal = 8,
    active = 16,
}
local digitizer_queue_budget_max_work_per_tick = {
    idle_wakeup = 2,
    long_idle_wakeup = 1,
}

local Digitizer_chest_entities = {
    ["digitizer-chest"] = true,
    ["digitizer-passive-provider-chest"] = true,
    ["digitizer-requester-chest"] = true,
}
local Digitizer_chest_queue_names = {"signal", "active", "idle", "long_idle"}
local Digitizer_signal_item_fetchable_cache = {}

local function begin_instrument_sample()
    if not qf_instrument_begin_sample then
        return nil
    end
    return qf_instrument_begin_sample()
end

local function end_instrument_sample(profiler, stat_name)
    if profiler and stat_name then
        qf_instrument_end_sample(stat_name, profiler)
    end
end

local function is_digitizer_chest_entity(entity_name)
    return Digitizer_chest_entities[entity_name] == true
end

local function get_tracking_entity_name(entity_name)
    if is_digitizer_chest_entity(entity_name) then
        return "digitizer-chest"
    end
    return entity_name
end

---@class RequestData
---@field entity LuaEntity
---@field player_index? uint
---@field request_type "entities"|"revivals"|"destroys"|"upgrades"|"construction"|"item_requests"|"cliffs"|"repairs"
---@field target? LuaEntityPrototype
---@field quality? string
---@field item_request_proxy? LuaEntity
---@field position? TilePosition

---@class EntityData
---@field entity? LuaEntity
---@field name string
---@field surface_index uint
---@field settings EntitySettings
---@field inventory? LuaInventory
---@field container? LuaEntity
---@field container_fluid? LuaEntity
---@field item_filter? string
---@field fluid_filter? string
---@field item_transfer_status? string
---@field fluid_transfer_status? string
---@field burnt_result_inventory? LuaInventory
---@field unit_number uint
---@field signal_active? boolean
---@field next_signal_check_tick? uint
---@field signal_check_interval_ticks? uint
---@field cached_signals? table
---@field queue_name? "signal"|"active"|"idle"|"long_idle"
---@field idle_empty_checks? uint
---@field active_until_tick? uint
---@field cached_has_processable_contents? boolean
---@field next_processable_recheck_tick? uint
---@field processable_check_interval_ticks? uint
---@field inventory_processing? table
---@field has_unmet_signal_requests? boolean
---@field parsed_signal_requests? table

---@class EntitySettings
---@field intake_limit? uint
---@field item_filter? { name: string?, quality: string? }
---@field fluid_filter? string
---@field surface_index? uint
---@field decraft? boolean
---@field fluid_enabled? boolean

local function create_digitizer_chest_fluid_container(entity_data)
    if not entity_data or not entity_data.entity or not entity_data.entity.valid then return end
    if entity_data.entity.name ~= "digitizer-chest" then return end
    if entity_data.container_fluid and entity_data.container_fluid.valid then return end
    local pseudo_fluid_container = entity_data.entity.surface.create_entity{
        name = "digitizer-chest-fluid",
        position = entity_data.entity.position,
        force = entity_data.entity.force
    }
    pseudo_fluid_container.destructible = false
    pseudo_fluid_container.operable = false
    entity_data.container_fluid = pseudo_fluid_container
end

local function store_digitizer_chest_fluids(entity_data)
    local container_fluid = entity_data.container_fluid
    if not container_fluid or not container_fluid.valid then
        entity_data.container_fluid = nil
        return
    end
    for name, count in pairs(container_fluid.get_fluid_contents()) do
        if count > 0 then
            local removed = container_fluid.remove_fluid{
                name = name,
                amount = count,
            }
            if removed > 0 then
                qs_utils.add_to_storage({
                    surface_index = entity_data.surface_index,
                    name = name,
                    count = removed,
                    type = "fluid",
                    quality = QS_DEFAULT_QUALITY,
                })
            end
        end
    end
end

local function sync_digitizer_chest_fluid_setting(entity_data)
    if not entity_data or entity_data.name ~= "digitizer-chest" then return end
    local entity = entity_data.entity
    if not entity or not entity.valid then return end
    if entity.name ~= "digitizer-chest" then
        entity_data.settings.fluid_enabled = false
        if entity_data.container_fluid and entity_data.container_fluid.valid then
            entity_data.container_fluid.destroy()
        end
        entity_data.container_fluid = nil
        return
    end
    if entity_data.settings.fluid_enabled == nil then
        entity_data.settings.fluid_enabled = false
    end
    if entity_data.settings.fluid_enabled then
        create_digitizer_chest_fluid_container(entity_data)
        return
    end
    store_digitizer_chest_fluids(entity_data)
    if entity_data.container_fluid and entity_data.container_fluid.valid then
        entity_data.container_fluid.destroy()
    end
    entity_data.container_fluid = nil
end

---Creates a request to be executed later if conditions are met
---@param request_data RequestData
function tracking.create_tracked_request(request_data)
    if not request_data.entity.valid then return end
    local request_type = request_data.request_type
    if request_type == "entities" then
        tracking.add_tracked_entity(request_data)
    else
        tracking.add_request(request_data)
    end
end

function tracking.recheck_trackable_entities(force_full)
    for _, surface in pairs(game.surfaces) do
        for entity_name, _ in pairs(Trackable_entities) do
            local entities = surface.find_entities_filtered { name = entity_name }
            for _, entity in pairs(entities) do
                local tracked_entity_name = get_tracking_entity_name(entity_name)
                if not storage.tracked_entities[tracked_entity_name][entity.unit_number] then
                    tracking.create_tracked_request({ request_type = "entities", entity = entity })
                end
            end
        end
    end
end

function tracking.sync_digitizer_chest_fluid_settings()
    local tracked_entities = storage.tracked_entities and storage.tracked_entities["digitizer-chest"]
    if not tracked_entities then return end
    for _, entity_data in pairs(tracked_entities) do
        sync_digitizer_chest_fluid_setting(entity_data)
    end
end

function tracking.disable_legacy_digitizer_chest_fluid_interfaces()
    local tracked_entities = storage.tracked_entities and storage.tracked_entities["digitizer-chest"]
    if tracked_entities then
        for _, entity_data in pairs(tracked_entities) do
            if entity_data.entity and entity_data.entity.valid and entity_data.entity.name == "digitizer-chest" then
                entity_data.settings.fluid_enabled = false
                sync_digitizer_chest_fluid_setting(entity_data)
            end
        end
    end
    for _, surface in pairs(game.surfaces) do
        for _, entity in pairs(surface.find_entities_filtered{name = "digitizer-chest-fluid"}) do
            if entity.valid then
                entity.destroy()
            end
        end
    end
end

---@param entity_data EntityData?
---@param enabled boolean
function tracking.set_digitizer_chest_fluid_enabled(entity_data, enabled)
    if not entity_data then return end
    entity_data.settings.fluid_enabled = enabled == true
    sync_digitizer_chest_fluid_setting(entity_data)
    tracking.invalidate_digitizer_chest_processable_cache(entity_data, true)
end

---@param request_data RequestData
function tracking.add_request(request_data)
    local request_type = request_data.request_type
    local request_table = {
        entity = request_data.entity,
        player_index = request_data.player_index,
    }
    local index
    if request_type == "upgrades" then
        request_table.target = request_data.target
        request_table.quality = request_data.quality
    elseif request_type == "item_requests" then
        request_table.item_request_proxy = request_data.item_request_proxy
    end

    if request_type == "cliffs" then
        storage.cliff_ids = storage.cliff_ids + 1
        index = storage.cliff_ids
    else
        index = request_table.entity.unit_number
    end
    request_table.index = index

    storage.tracked_requests[request_type][index] = request_table
end

---@param request_type "revivals"|"destroys"|"upgrades"|"construction"|"item_requests"|"cliffs"|"repairs"
---@param request_id uint
function tracking.remove_tracked_request(request_type, request_id)
    storage.tracked_requests[request_type][request_id] = nil
end

function tracking.rebuild_digitizer_chest_queues()
    if not storage.tracked_entities then return end
    local tracked_entities = storage.tracked_entities["digitizer-chest"]
    if not tracked_entities then return end

    storage.tracked_entity_queues = storage.tracked_entity_queues or {}
    storage.tracked_entity_queues["digitizer-chest"] = {
        signal = {},
        active = {},
        idle = {},
        long_idle = {},
        signal_size = 0,
        active_size = 0,
        idle_size = 0,
        long_idle_size = 0,
    }
    local queues = storage.tracked_entity_queues["digitizer-chest"]

    storage.request_ids = storage.request_ids or {}
    storage.request_ids["digitizer-chest"] = 1
    storage.request_ids["digitizer-chest-signal"] = 1
    storage.request_ids["digitizer-chest-active"] = 1
    storage.request_ids["digitizer-chest-idle"] = 1
    storage.request_ids["digitizer-chest-long_idle"] = 1
    storage.digitizer_chest_queues_ready = true

    for unit_number, entity_data in pairs(tracked_entities) do
        local entity = entity_data.entity
        if not entity or not entity.valid then
            tracked_entities[unit_number] = nil
        else
            entity_data.signal_active = true
            entity_data.next_signal_check_tick = 0
            entity_data.signal_check_interval_ticks = digitizer_chest_signal_recheck_ticks
            entity_data.cached_signals = nil
            entity_data.idle_empty_checks = 0
            entity_data.active_until_tick = game.tick + digitizer_chest_active_keepalive_ticks
            entity_data.queue_name = "active"
            queues.active[unit_number] = entity_data
            queues.active_size = queues.active_size + 1
        end
    end
end

function tracking.dump_digitizer_chest_queues(max_entries, player_index)
    local limit = tonumber(max_entries)
    local print_details = limit ~= nil
    if print_details and limit < 1 then
        limit = 1
    end

    local player = player_index and game.get_player(player_index) or nil
    local output = player and function(text) player.print(text) end or function(text) game.print(text) end

    local tracked_queues = storage.tracked_entity_queues and storage.tracked_entity_queues["digitizer-chest"]
    if not tracked_queues then
        output("[QF][QueueDump] No digitizer queue storage")
        return
    end
    local queues = {
        signal = tracked_queues.signal or {},
        active = tracked_queues.active or {},
        idle = tracked_queues.idle or {},
        long_idle = tracked_queues.long_idle or {},
    }
    local queue_names = Digitizer_chest_queue_names
    local total = 0
    for _, queue_name in pairs(queue_names) do
        for _, _ in pairs(queues[queue_name]) do
            total = total + 1
        end
    end

    local queue_runtime = {
        signal = {nth_tick = digitizer_chest_signal_nth_tick, base_batch_size = 4, iterations = 1},
        active = {nth_tick = digitizer_chest_active_nth_tick, base_batch_size = 4, iterations = 1},
        idle = {nth_tick = digitizer_chest_idle_nth_tick, base_batch_size = 2, iterations = 1},
        long_idle = {nth_tick = digitizer_chest_long_idle_nth_tick, base_batch_size = 1, iterations = 1},
    }

    output("[QF][QueueDump] Begin tick=" .. game.tick .. " total=" .. total)
    for _, queue_name in pairs(queue_names) do
        local queue = queues[queue_name]
        local entries = {}
        for unit_number, entity_data in pairs(queue) do
            entries[#entries + 1] = {unit_number = unit_number, entity_data = entity_data}
        end
        table.sort(entries, function(a, b) return a.unit_number < b.unit_number end)
        local runtime = queue_runtime[queue_name]
        local dynamic_batch_size = runtime.base_batch_size
        if #entries > runtime.base_batch_size then
            dynamic_batch_size = math.ceil(#entries / digitizer_queue_dynamic_batch_divisor)
            if dynamic_batch_size < runtime.base_batch_size then
                dynamic_batch_size = runtime.base_batch_size
            end
        end
        local work_per_tick = runtime.iterations * dynamic_batch_size / runtime.nth_tick
        local max_work_per_tick = digitizer_queue_max_work_per_tick[queue_name]
        if max_work_per_tick and work_per_tick > max_work_per_tick then
            work_per_tick = max_work_per_tick
        end
        local runs_needed = 0
        local estimated_ticks = 0
        local estimated_seconds = 0
        if #entries > 0 and work_per_tick > 0 then
            estimated_ticks = math.ceil(#entries / work_per_tick)
            runs_needed = math.ceil(estimated_ticks / runtime.nth_tick)
            estimated_seconds = estimated_ticks / 60
        end
        output("[QF][QueueDump] Queue "
            .. queue_name
            .. " count=" .. #entries
            .. " nth_tick=" .. runtime.nth_tick
            .. " base_batch=" .. runtime.base_batch_size
            .. " dynamic_batch=" .. dynamic_batch_size
            .. " work_per_tick=" .. string.format("%.2f", work_per_tick)
            .. " runs=" .. runs_needed
            .. " full_pass_ticks=" .. estimated_ticks
            .. " full_pass_seconds=" .. string.format("%.2f", estimated_seconds))
        if not print_details then
            goto continue
        end
        local dumped = 0
        for _, row in pairs(entries) do
            if dumped >= limit then
                break
            end
            dumped = dumped + 1
            local entity_data = row.entity_data
            local entity = entity_data and entity_data.entity
            local entity_name = "nil"
            local valid = false
            local surface_index = -1
            if entity and entity.valid then
                valid = true
                entity_name = entity.name
                surface_index = entity.surface_index
            end

            local inventory_count = 0
            if entity_data and entity_data.inventory and not entity_data.inventory.is_empty() then
                local inventory_contents = entity_data.inventory.get_contents()
                for _, item in pairs(inventory_contents) do
                    inventory_count = inventory_count + item.count
                end
            end

            local fluid_count = 0
            if entity_data and entity_data.container_fluid and entity_data.container_fluid.valid then
                local fluids = entity_data.container_fluid.get_fluid_contents()
                for _, amount in pairs(fluids) do
                    fluid_count = fluid_count + amount
                end
            end

            local signal_count = entity_data and entity_data.cached_signals and #entity_data.cached_signals or 0
            local queue_state = entity_data and entity_data.queue_name or "nil"
            local next_signal_check_tick = entity_data and entity_data.next_signal_check_tick or -1
            local signal_check_interval_ticks = entity_data and entity_data.signal_check_interval_ticks or -1
            local has_live_signal = false
            if valid then
                local live_signals = entity.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
                has_live_signal = live_signals ~= nil and next(live_signals) ~= nil
            end

            output("[QF][QueueDump] "
                .. queue_name
                .. " unit=" .. row.unit_number
                .. " name=" .. entity_name
                .. " valid=" .. tostring(valid)
                .. " surface=" .. surface_index
                .. " inv=" .. inventory_count
                .. " fluid=" .. fluid_count
                .. " queue_name=" .. queue_state
                .. " signal_active=" .. tostring(entity_data and entity_data.signal_active or false)
                .. " cached_signal_count=" .. signal_count
                .. " next_signal_check_tick=" .. next_signal_check_tick
                .. " signal_check_interval_ticks=" .. signal_check_interval_ticks
                .. " live_signal=" .. tostring(has_live_signal))
        end
        if #entries > limit then
            output("[QF][QueueDump] Queue " .. queue_name .. " truncated=" .. (#entries - limit))
        end
        ::continue::
    end
    output("[QF][QueueDump] End")
end

local function signals_equal_ordered(signals_a, signals_b)
    if signals_a == signals_b then
        return true
    end
    if not signals_a or not signals_b then
        return false
    end
    if #signals_a ~= #signals_b then
        return false
    end
    for index = 1, #signals_a do
        local signal_a = signals_a[index]
        local signal_b = signals_b[index]
        if not signal_a or not signal_b then
            return false
        end
        local value_a = signal_a.signal
        local value_b = signal_b.signal
        if not value_a or not value_b then
            return false
        end
        if signal_a.count ~= signal_b.count
            or value_a.type ~= value_b.type
            or value_a.name ~= value_b.name
            or value_a.quality ~= value_b.quality then
            return false
        end
    end
    return true
end

local function begin_digitizer_phase_sample(entity_data, phase_name)
    local profiler = begin_instrument_sample()
    if not profiler then
        return nil, nil
    end
    return profiler, "tracking.update_entity.digitizer-chest." .. (entity_data.queue_name or "unknown") .. "." .. phase_name
end

local function end_digitizer_phase_sample(profiler, stat_name)
    end_instrument_sample(profiler, stat_name)
end

local function refresh_digitizer_chest_signals(entity_data)
    local profiler = begin_instrument_sample()
    if entity_data.signal_active == nil then
        entity_data.signal_active = true
    end
    if entity_data.signals_changed == nil then
        entity_data.signals_changed = false
    end
    if entity_data.next_signal_check_tick == nil then
        entity_data.next_signal_check_tick = 0
    end
    if entity_data.signal_check_interval_ticks == nil then
        entity_data.signal_check_interval_ticks = digitizer_chest_signal_recheck_ticks
    end

    local checked_now = false
    if game.tick >= entity_data.next_signal_check_tick then
        checked_now = true
        local new_signals = entity_data.entity.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
        entity_data.signal_active = new_signals ~= nil and next(new_signals) ~= nil
        local changed = not signals_equal_ordered(entity_data.cached_signals, new_signals)
        entity_data.signals_changed = changed
        if not changed then
            entity_data.signal_check_interval_ticks = math.min(digitizer_chest_signal_recheck_max_ticks, entity_data.signal_check_interval_ticks * 2)
        else
            entity_data.signal_check_interval_ticks = digitizer_chest_signal_recheck_ticks
            entity_data.cached_signals = new_signals
        end
        entity_data.next_signal_check_tick = game.tick + entity_data.signal_check_interval_ticks
    else
        entity_data.signals_changed = false
    end

    end_instrument_sample(profiler, "tracking.refresh_digitizer_chest_signals")
    return entity_data.cached_signals, checked_now
end

local function get_digitizer_inventory_processing(entity_data)
    local inventory_processing = entity_data.inventory_processing
    if inventory_processing then
        return inventory_processing
    end
    inventory_processing = {
        items = {},
        fluids = {
            name = "",
            count = 0,
            temperature = nil,
        },
        preprocessed_items = {},
    }
    entity_data.inventory_processing = inventory_processing
    return inventory_processing
end

local function get_digitizer_update_temp_data(entity_data, storage_index)
    local update_temp_data = entity_data.update_temp_data
    if update_temp_data then
        update_temp_data.item_qs_item.surface_index = storage_index
        update_temp_data.item_qs_fluid.surface_index = storage_index
        update_temp_data.batch_item_contents = update_temp_data.batch_item_contents or {}
        return update_temp_data
    end
    update_temp_data = {
        item_qs_item = {
            name = "",
            count = 0,
            type = "item",
            quality = QS_DEFAULT_QUALITY,
            surface_index = storage_index
        },
        item_qs_fluid = {
            name = "",
            count = 0,
            type = "fluid",
            quality = QS_DEFAULT_QUALITY,
            temperature = nil,
            surface_index = storage_index
        },
        item_remove_params = {
            name = "",
            count = 0,
            quality = QS_DEFAULT_QUALITY
        },
        fluid_remove_params = {
            name = "",
            amount = 0
        },
        batch_item_contents = {},
    }
    entity_data.update_temp_data = update_temp_data
    return update_temp_data
end

local function digitizer_chest_reads_contents(entity)
    if entity.name == "digitizer-passive-provider-chest" or entity.name == "digitizer-requester-chest" then
        return true
    end
    if entity.name ~= "digitizer-chest" then
        return false
    end
    local control_behavior = entity.get_control_behavior()
    if not control_behavior then
        return false
    end
    ---@diagnostic disable-next-line: undefined-field
    return control_behavior.read_contents == true
end

local function reset_digitizer_inventory_processing(inventory_processing)
    for _, item_by_quality in pairs(inventory_processing.items) do
        for quality_name, _ in pairs(item_by_quality) do
            item_by_quality[quality_name] = nil
        end
    end
    for item_name, _ in pairs(inventory_processing.preprocessed_items) do
        inventory_processing.preprocessed_items[item_name] = nil
    end
    inventory_processing.fluids.name = ""
    inventory_processing.fluids.count = 0
    inventory_processing.fluids.temperature = nil
end

local function fluid_temperatures_match(current_temperature, requested_temperature)
    if requested_temperature == nil then
        return true
    end
    if current_temperature == nil then
        return false
    end
    return math.abs(current_temperature - requested_temperature) < 0.001
end

local function get_container_fluid_state(container_fluid)
    if not container_fluid or not container_fluid.valid then
        return nil
    end
    local fluidbox = container_fluid.fluidbox
    if not fluidbox then
        return nil
    end
    for index = 1, #fluidbox do
        local fluid = fluidbox[index]
        if fluid and fluid.amount and fluid.amount > 0 then
            return fluid
        end
    end
    return nil
end

local function add_digitizer_requested_item(items, item_name, quality_name, count)
    local item_by_quality = items[item_name]
    if not item_by_quality then
        item_by_quality = {}
        items[item_name] = item_by_quality
    end
    item_by_quality[quality_name] = (item_by_quality[quality_name] or 0) + count
end

local function is_digitizer_signal_fetchable_item(item_name)
    local cached = Digitizer_signal_item_fetchable_cache[item_name]
    if cached ~= nil then
        return cached
    end
    local item_prototype = prototypes.item[item_name]
    cached = item_prototype ~= nil and not item_prototype.parameter
    Digitizer_signal_item_fetchable_cache[item_name] = cached
    return cached
end

local function get_digitizer_signal_request_parse(entity_data, signals, signal_fetchable)
    if not signals then
        return nil
    end

    local cached = entity_data.parsed_signal_requests
    if cached and cached.signals == signals and cached.signal_fetchable == signal_fetchable then
        return cached
    end

    local parsed = cached
    if not parsed then
        parsed = {
            signals = nil,
            signal_fetchable = false,
            storage_index = entity_data.surface_index,
            fixed_quantity = 0,
            limit_value = nil,
            decraft = nil,
            items = {},
            preprocessed_items = {},
            fluids = {
                name = "",
                count = 0,
                temperature = nil,
            },
        }
        entity_data.parsed_signal_requests = parsed
    else
        parsed.items = parsed.items or {}
        parsed.preprocessed_items = parsed.preprocessed_items or {}
        parsed.fluids = parsed.fluids or {
            name = "",
            count = 0,
            temperature = nil,
        }
        for item_name, item_by_quality in pairs(parsed.items) do
            for item_quality, _ in pairs(item_by_quality) do
                item_by_quality[item_quality] = nil
            end
            parsed.items[item_name] = nil
        end
        for item_name, _ in pairs(parsed.preprocessed_items) do
            parsed.preprocessed_items[item_name] = nil
        end
    end

    parsed.signals = signals
    parsed.signal_fetchable = signal_fetchable
    parsed.storage_index = entity_data.surface_index
    parsed.fixed_quantity = 0
    parsed.limit_value = nil
    parsed.decraft = nil
    parsed.fluids.name = ""
    parsed.fluids.count = 0
    parsed.fluids.temperature = nil

    local preprocessed_items = parsed.preprocessed_items
    local quality = QS_DEFAULT_QUALITY

    for _, signal in pairs(signals) do
        if signal.count > 0 then
            if signal.signal.type == "virtual" then
                if signal.signal.name == "signal-S" then
                    parsed.storage_index = signal.count
                elseif signal.signal.name == "signal-L" then
                    parsed.limit_value = signal.count
                elseif signal.signal.name == "signal-D" then
                    parsed.decraft = true
                elseif signal.signal.name == "signal-F" then
                    parsed.fixed_quantity = signal.count
                elseif signal.signal.name == "signal-T" then
                    parsed.fluids.temperature = signal.count
                end
            elseif signal.signal.type == "quality" then
                quality = signal.signal.name
            elseif signal_fetchable and (signal.signal.type == nil or signal.signal.type == "item") then
                if not is_digitizer_signal_fetchable_item(signal.signal.name) then
                    goto continue
                end
                local item_quality = signal.signal.quality
                if item_quality then
                    add_digitizer_requested_item(parsed.items, signal.signal.name, item_quality, signal.count)
                else
                    preprocessed_items[signal.signal.name] = (preprocessed_items[signal.signal.name] or 0) + signal.count
                end
            elseif signal_fetchable and signal.signal.type == "fluid" then
                if signal.count > parsed.fluids.count then
                    parsed.fluids.name = signal.signal.name
                    parsed.fluids.count = signal.count
                end
            end
        end
        ::continue::
    end

    for item_name, item_count in pairs(preprocessed_items) do
        add_digitizer_requested_item(parsed.items, item_name, quality, item_count)
    end

    if parsed.fixed_quantity > 0 then
        for _, item_by_quality in pairs(parsed.items) do
            for item_quality, _ in pairs(item_by_quality) do
                item_by_quality[item_quality] = parsed.fixed_quantity
            end
        end
        if parsed.fluids.count > 0 then
            parsed.fluids.count = parsed.fixed_quantity
        end
    end

    return parsed
end

local function load_digitizer_signal_request_processing(entity_data, parsed)
    local inventory_processing = get_digitizer_inventory_processing(entity_data)
    reset_digitizer_inventory_processing(inventory_processing)

    if not parsed then
        return inventory_processing
    end

    for item_name, item_by_quality in pairs(parsed.items) do
        local processing_item_by_quality = inventory_processing.items[item_name]
        if not processing_item_by_quality then
            processing_item_by_quality = {}
            inventory_processing.items[item_name] = processing_item_by_quality
        end
        for item_quality, item_count in pairs(item_by_quality) do
            processing_item_by_quality[item_quality] = item_count
        end
    end

    inventory_processing.fluids.name = parsed.fluids.name
    inventory_processing.fluids.count = parsed.fluids.count
    inventory_processing.fluids.temperature = parsed.fluids.temperature
    return inventory_processing
end

local ensure_digitizer_chest_queue_storage

local function get_digitizer_recipe_product_amount(recipe, item_name)
    for _, product in pairs(recipe.products) do
        if product.type == "item" and product.name == item_name then
            return product.amount or 1
        end
    end
    return 1
end

local function fabricate_digitizer_requested_item(qs_item, target_inventory)
    if storage.tiles[qs_item.name] or not utils.is_placeable(qs_item.name) or not storage.product_craft_data[qs_item.name] then
        return
    end

    local recipe, craftable_count = qf_utils.get_craftable_recipe(qs_item, nil, false, true)
    if not recipe or not craftable_count or craftable_count <= 0 then
        return
    end

    local product_amount = get_digitizer_recipe_product_amount(recipe, qs_item.name)
    local multiplier = math.ceil(qs_item.count / product_amount)
    if craftable_count < multiplier then
        multiplier = craftable_count
    end
    if multiplier <= 0 then
        return
    end

    local ingredients = recipe.ingredients
    local products = recipe.products
    local quality = qs_item.quality
    local surface_index = qs_item.surface_index
    local requested_name = qs_item.name

    for _, ingredient in pairs(ingredients) do
        local ingredient_qs_item = {
            name = ingredient.name,
            type = ingredient.type,
            count = ingredient.amount * multiplier,
            quality = quality,
            surface_index = surface_index
        }
        if ingredient_qs_item.type == "fluid" then
            ingredient_qs_item.quality = QS_DEFAULT_QUALITY
        end

        local in_storage = qs_utils.count_in_storage(ingredient_qs_item, nil, surface_index)
        if in_storage > 0 then
            if in_storage >= ingredient_qs_item.count then
                qs_utils.remove_from_storage(ingredient_qs_item)
            else
                qs_utils.remove_from_storage(ingredient_qs_item, in_storage)
            end
        end
        qs_utils.add_temp_prod_statistics(ingredient_qs_item.name, ingredient_qs_item.quality, ingredient_qs_item.type, surface_index, ingredient_qs_item.count * -1)
    end

    local inserted_requested_count = 0
    for _, product in pairs(products) do
        local product_qs_item = {
            name = product.name,
            type = product.type,
            count = product.amount * multiplier,
            quality = quality,
            surface_index = surface_index
        }
        if product_qs_item.type == "fluid" then
            product_qs_item.quality = QS_DEFAULT_QUALITY
        end

        if product_qs_item.type == "item" and product_qs_item.name == requested_name then
            local inserted = target_inventory.insert({
                name = product_qs_item.name,
                count = product_qs_item.count,
                quality = product_qs_item.quality
            })
            inserted_requested_count = inserted_requested_count + inserted
            if inserted < product_qs_item.count then
                product_qs_item.count = product_qs_item.count - inserted
                qs_utils.add_to_storage(product_qs_item, false)
            end
        else
            qs_utils.add_to_storage(product_qs_item, false)
        end
        qs_utils.add_temp_prod_statistics(product_qs_item.name, product_qs_item.quality, product_qs_item.type, surface_index, product.amount * multiplier)
    end

    qs_item.count = inserted_requested_count
end

local function digitizer_intake_limit_remaining_capacity(item_name, quality_name, storage_index, storage_items, limit_value, decraft)
    local profiler = begin_instrument_sample()
    local stored_count = storage_items[item_name][quality_name]
    local remaining_capacity = limit_value - stored_count
    if remaining_capacity <= 0 then
        end_instrument_sample(profiler, "tracking.digitizer_intake_limit_remaining_capacity")
        return 0
    end
    if not decraft or not utils.is_placeable(item_name) or storage.tiles[item_name] or not storage.product_craft_data[item_name] then
        end_instrument_sample(profiler, "tracking.digitizer_intake_limit_remaining_capacity")
        return remaining_capacity
    end

    local qs_item = {
        name = item_name,
        count = 1,
        type = "item",
        quality = quality_name,
        surface_index = storage_index
    }
    local recipe_profiler = begin_instrument_sample()
    local recipe, craftable_count = qf_utils.get_craftable_recipe(qs_item, nil, false, true)
    end_instrument_sample(recipe_profiler, "tracking.digitizer_intake_limit_remaining_capacity.get_craftable_recipe")
    if not recipe or not craftable_count or craftable_count <= 0 then
        end_instrument_sample(profiler, "tracking.digitizer_intake_limit_remaining_capacity")
        return remaining_capacity
    end

    local product_amount = get_digitizer_recipe_product_amount(recipe, item_name)
    remaining_capacity = remaining_capacity - craftable_count * product_amount
    if remaining_capacity <= 0 then
        end_instrument_sample(profiler, "tracking.digitizer_intake_limit_remaining_capacity")
        return 0
    end
    end_instrument_sample(profiler, "tracking.digitizer_intake_limit_remaining_capacity")
    return remaining_capacity
end

local function get_digitizer_queue_size_key(queue_name)
    return queue_name .. "_size"
end

local function get_digitizer_queue_size(queues, queue_name)
    return queues[get_digitizer_queue_size_key(queue_name)] or 0
end

local get_dynamic_digitizer_queue_batch

local function get_digitizer_queue_effective_work_per_tick(queues, queue_name, nth_tick, base_batch_size)
    local queue_size = get_digitizer_queue_size(queues, queue_name)
    if queue_size <= 0 then
        return 0
    end
    local work_per_tick = get_dynamic_digitizer_queue_batch(queues, queue_name, base_batch_size) / nth_tick
    local max_work_per_tick = digitizer_queue_max_work_per_tick[queue_name]
    if max_work_per_tick and work_per_tick > max_work_per_tick then
        work_per_tick = max_work_per_tick
    end
    return work_per_tick
end

local function get_digitizer_budget_effective_work_per_tick(queues, budget_key, queue_name, nth_tick, base_batch_size)
    local work_per_tick = get_digitizer_queue_effective_work_per_tick(queues, queue_name, nth_tick, base_batch_size)
    local max_work_per_tick = digitizer_queue_budget_max_work_per_tick[budget_key]
    if max_work_per_tick and work_per_tick > max_work_per_tick then
        work_per_tick = max_work_per_tick
    end
    return work_per_tick
end

local function get_digitizer_queue_full_pass_seconds(queues, queue_name)
    local full_pass_seconds = queues.full_pass_seconds
    if not full_pass_seconds then
        return 0
    end
    return full_pass_seconds[queue_name] or 0
end

local function update_digitizer_queue_full_pass_seconds(queues, queue_name)
    local queue_size = get_digitizer_queue_size(queues, queue_name)
    local nth_tick = digitizer_chest_signal_nth_tick
    local base_batch_size = 4
    if queue_name == "active" then
        nth_tick = digitizer_chest_active_nth_tick
        base_batch_size = 4
    elseif queue_name == "idle" then
        nth_tick = digitizer_chest_idle_nth_tick
        base_batch_size = 2
    elseif queue_name == "long_idle" then
        nth_tick = digitizer_chest_long_idle_nth_tick
        base_batch_size = 1
    end

    local full_pass_seconds = 0
    local work_per_tick = get_digitizer_queue_effective_work_per_tick(queues, queue_name, nth_tick, base_batch_size)
    if queue_size > 0 and work_per_tick > 0 then
        full_pass_seconds = math.ceil(queue_size / work_per_tick) / 60
    end

    queues.full_pass_seconds = queues.full_pass_seconds or {}
    queues.full_pass_seconds[queue_name] = full_pass_seconds
end

local function refresh_digitizer_queue_full_pass_seconds(queues)
    queues.full_pass_seconds = queues.full_pass_seconds or {}
    for _, queue_name in pairs(Digitizer_chest_queue_names) do
        update_digitizer_queue_full_pass_seconds(queues, queue_name)
    end
    storage.digitizer_queue_full_pass_seconds_cache_version = digitizer_queue_full_pass_seconds_cache_version
end

function tracking.get_digitizer_queue_full_pass_seconds(queue_name)
    local queues = ensure_digitizer_chest_queue_storage()
    return get_digitizer_queue_full_pass_seconds(queues, queue_name)
end

local function add_digitizer_queue_entry(queues, queue_name, unit_number, entity_data)
    local queue = queues[queue_name]
    if not queue[unit_number] then
        local size_key = get_digitizer_queue_size_key(queue_name)
        queues[size_key] = (queues[size_key] or 0) + 1
        update_digitizer_queue_full_pass_seconds(queues, queue_name)
    end
    queue[unit_number] = entity_data
end

local function remove_digitizer_queue_entry(queues, queue_name, unit_number)
    local queue = queues[queue_name]
    if not queue or queue[unit_number] == nil then
        return false
    end
    queue[unit_number] = nil
    local size_key = get_digitizer_queue_size_key(queue_name)
    if (queues[size_key] or 0) > 0 then
        queues[size_key] = queues[size_key] - 1
    end
    update_digitizer_queue_full_pass_seconds(queues, queue_name)
    return true
end

local function remove_digitizer_queue_entry_from_all(queues, unit_number)
    for _, queue_name in pairs(Digitizer_chest_queue_names) do
        if remove_digitizer_queue_entry(queues, queue_name, unit_number) then
            return
        end
    end
end

ensure_digitizer_chest_queue_storage = function()
    if not storage.tracked_entity_queues then
        storage.tracked_entity_queues = {}
    end

    local queues = storage.tracked_entity_queues["digitizer-chest"]
    if not queues then
        queues = {
            signal = {},
            active = {},
            idle = {},
            long_idle = {},
            full_pass_seconds = {},
            signal_size = 0,
            active_size = 0,
            idle_size = 0,
            long_idle_size = 0,
        }
        storage.tracked_entity_queues["digitizer-chest"] = queues
    end
    queues.signal = queues.signal or {}
    queues.active = queues.active or {}
    queues.idle = queues.idle or {}
    queues.long_idle = queues.long_idle or {}
    queues.full_pass_seconds = queues.full_pass_seconds or {}
    queues.signal_size = queues.signal_size or table_size(queues.signal)
    queues.active_size = queues.active_size or table_size(queues.active)
    queues.idle_size = queues.idle_size or table_size(queues.idle)
    queues.long_idle_size = queues.long_idle_size or table_size(queues.long_idle)

    if not storage.request_ids then
        storage.request_ids = {}
    end
    storage.request_ids["digitizer-chest-signal"] = storage.request_ids["digitizer-chest-signal"] or 1
    storage.request_ids["digitizer-chest-active"] = storage.request_ids["digitizer-chest-active"] or 1
    storage.request_ids["digitizer-chest-idle"] = storage.request_ids["digitizer-chest-idle"] or 1
    storage.request_ids["digitizer-chest-long_idle"] = storage.request_ids["digitizer-chest-long_idle"] or 1

    local tracked_entities = storage.tracked_entities and storage.tracked_entities["digitizer-chest"]
    local needs_rebuild = not storage.digitizer_chest_queues_ready
    if not needs_rebuild
        and tracked_entities
        and next(tracked_entities)
        and queues.signal_size == 0
        and queues.active_size == 0
        and queues.idle_size == 0
        and queues.long_idle_size == 0 then
        needs_rebuild = true
    end
    if not needs_rebuild then
        if storage.digitizer_queue_full_pass_seconds_cache_version ~= digitizer_queue_full_pass_seconds_cache_version then
            refresh_digitizer_queue_full_pass_seconds(queues)
        end
        return queues
    end

    queues.signal = {}
    queues.active = {}
    queues.idle = {}
    queues.long_idle = {}
    queues.signal_size = 0
    queues.active_size = 0
    queues.idle_size = 0
    queues.long_idle_size = 0
    queues.full_pass_seconds = {}

    if tracked_entities then
        for unit_number, entity_data in pairs(tracked_entities) do
            local queue_name = entity_data.queue_name
            if queue_name ~= "signal" and queue_name ~= "active" and queue_name ~= "idle" and queue_name ~= "long_idle" then
                queue_name = "active"
                entity_data.queue_name = queue_name
            end
            add_digitizer_queue_entry(queues, queue_name, unit_number, entity_data)
        end
    end

    refresh_digitizer_queue_full_pass_seconds(queues)

    storage.digitizer_chest_queues_ready = true
    return queues
end

local function set_digitizer_chest_queue(entity_data, queue_name)
    local queues = ensure_digitizer_chest_queue_storage()
    local unit_number = entity_data.unit_number
    if queue_name ~= "signal" and queue_name ~= "active" and queue_name ~= "idle" and queue_name ~= "long_idle" then
        queue_name = "active"
    end

    if entity_data.queue_name == queue_name and queues[queue_name][unit_number] == entity_data then
        return
    end

    local previous_queue = entity_data.queue_name

    if previous_queue and queues[previous_queue] then
        remove_digitizer_queue_entry(queues, previous_queue, unit_number)
    else
        remove_digitizer_queue_entry_from_all(queues, unit_number)
    end

    add_digitizer_queue_entry(queues, queue_name, unit_number, entity_data)
    entity_data.queue_name = queue_name
    if queue_name == "active" and entity_data.name == "digitizer-chest" then
        entity_data.cached_has_processable_contents = nil
        entity_data.next_processable_recheck_tick = 0
        entity_data.processable_check_interval_ticks = digitizer_chest_processable_recheck_ticks
    end
end

local function can_use_digitizer_processable_cache(entity_data)
    local queue_name = entity_data and entity_data.queue_name
    return queue_name == "idle" or queue_name == "long_idle"
end

local function cache_digitizer_processable_contents(entity_data, has_processable_contents)
    if not entity_data or entity_data.name ~= "digitizer-chest" then return end
    local current_interval = entity_data.processable_check_interval_ticks or digitizer_chest_processable_recheck_ticks
    entity_data.cached_has_processable_contents = has_processable_contents == true
    entity_data.next_processable_recheck_tick = game.tick + current_interval
    if has_processable_contents then
        entity_data.processable_check_interval_ticks = digitizer_chest_processable_recheck_ticks
    else
        entity_data.processable_check_interval_ticks = math.min(
            digitizer_chest_processable_recheck_max_ticks,
            math.max(digitizer_chest_processable_recheck_ticks, current_interval * 2)
        )
    end
end

---@param entity_data EntityData?
---@param wake_queue? boolean
function tracking.invalidate_digitizer_chest_processable_cache(entity_data, wake_queue)
    if not entity_data or entity_data.name ~= "digitizer-chest" then return end
    entity_data.cached_has_processable_contents = nil
    entity_data.next_processable_recheck_tick = 0
    entity_data.processable_check_interval_ticks = digitizer_chest_processable_recheck_ticks
    if wake_queue and entity_data.queue_name == "long_idle" then
        set_digitizer_chest_queue(entity_data, "idle")
    end
end

get_dynamic_digitizer_queue_batch = function(queues, queue_name, base_batch_size)
    local queue_size = get_digitizer_queue_size(queues, queue_name)
    if queue_size <= base_batch_size then
        return base_batch_size
    end
    local dynamic_batch_size = math.ceil(queue_size / digitizer_queue_dynamic_batch_divisor)
    if dynamic_batch_size < base_batch_size then
        dynamic_batch_size = base_batch_size
    end
    return dynamic_batch_size
end

local function process_digitizer_chest_queue(queue_name, iterations, batch_size)
    local queues = ensure_digitizer_chest_queue_storage()
    local queue = queues[queue_name]
    local request_id_key = "digitizer-chest-" .. queue_name
    local queue_size = get_digitizer_queue_size(queues, queue_name)
    if queue_size <= 0 then
        storage.request_ids[request_id_key] = nil
        return
    end
    local dynamic_batch_size = get_dynamic_digitizer_queue_batch(queues, queue_name, batch_size)

    local current_key = storage.request_ids[request_id_key]
    if current_key and not queue[current_key] then
        current_key = nil
    end
    if not current_key then
        current_key = next(queue)
    end

    for _ = 1, iterations do
        if not current_key then
            break
        end

        local processed = 0
        while current_key and processed < dynamic_batch_size do
            local key = current_key
            current_key = next(queue, key)
            local entity_data = queue[key]
            if entity_data then
                tracking.update_entity(entity_data)
            end
            processed = processed + 1
        end
    end

    storage.request_ids[request_id_key] = current_key
end

local function process_digitizer_chest_queue_budgeted(queue_name, max_processed)
    if max_processed <= 0 then
        return
    end

    local queues = ensure_digitizer_chest_queue_storage()
    local queue = queues[queue_name]
    local request_id_key = "digitizer-chest-" .. queue_name
    local queue_size = get_digitizer_queue_size(queues, queue_name)
    if queue_size <= 0 then
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
    while current_key and processed < max_processed do
        local key = current_key
        current_key = next(queue, key)
        local entity_data = queue[key]
        if entity_data then
            tracking.update_entity(entity_data)
        end
        processed = processed + 1
    end

    storage.request_ids[request_id_key] = current_key
end

local function digitizer_chest_has_contents(entity_data)
    if entity_data.inventory and not entity_data.inventory.is_empty() then
        return true
    end
    if entity_data.container_fluid then
        local fluid_contents = entity_data.container_fluid.get_fluid_contents()
        if fluid_contents and next(fluid_contents) then
            return true
        end
    end
    return false
end

local function digitizer_chest_has_processable_contents(entity_data)
    local profiler = begin_instrument_sample()
    if can_use_digitizer_processable_cache(entity_data) then
        local next_recheck_tick = entity_data.next_processable_recheck_tick or 0
        if entity_data.cached_has_processable_contents ~= nil and game.tick < next_recheck_tick then
            end_instrument_sample(profiler, "tracking.digitizer_chest_has_processable_contents")
            return entity_data.cached_has_processable_contents
        end
    end

    local has_processable_contents = false
    if digitizer_chest_has_contents(entity_data) then
        local limit_value = entity_data.settings.intake_limit or 0
        if limit_value == 0 then
            has_processable_contents = true
        else
            local storage_surface = storage.fabricator_inventory[entity_data.surface_index]
            local storage_items = storage_surface.item
            local storage_fluids = storage_surface.fluid

            if entity_data.inventory and not entity_data.inventory.is_empty() then
                for _, item in pairs(entity_data.inventory.get_contents()) do
                    if digitizer_intake_limit_remaining_capacity(item.name, item.quality, entity_data.surface_index, storage_items, limit_value, entity_data.settings.decraft) > 0 then
                        has_processable_contents = true
                        break
                    end
                end
            end

            if not has_processable_contents and entity_data.container_fluid then
                local fluid_contents = entity_data.container_fluid.get_fluid_contents()
                if fluid_contents then
                    for name, _ in pairs(fluid_contents) do
                        if storage_fluids[name][QS_DEFAULT_QUALITY] < limit_value then
                            has_processable_contents = true
                            break
                        end
                    end
                end
            end
        end
    end

    if can_use_digitizer_processable_cache(entity_data) then
        cache_digitizer_processable_contents(entity_data, has_processable_contents)
    end

    end_instrument_sample(profiler, "tracking.digitizer_chest_has_processable_contents")
    return has_processable_contents
end

local function digitizer_chest_has_unmet_signal_requests(entity_data, signals)
    local profiler = begin_instrument_sample()
    if not entity_data.signal_active then
        end_instrument_sample(profiler, "tracking.digitizer_chest_has_unmet_signal_requests")
        return false
    end

    local entity = entity_data.entity
    local fetchable = settings.global["qf-super-digitizing-chests"].value
    local requester_buffered = entity.name == "digitizer-requester-chest"
    local signal_fetchable = fetchable or requester_buffered
    if not signal_fetchable then
        end_instrument_sample(profiler, "tracking.digitizer_chest_has_unmet_signal_requests")
        return false
    end

    local parsed = get_digitizer_signal_request_parse(entity_data, signals, signal_fetchable)
    if not parsed then
        end_instrument_sample(profiler, "tracking.digitizer_chest_has_unmet_signal_requests")
        return false
    end

    local storage_index = parsed.storage_index
    local fixed_quantity = parsed.fixed_quantity
    local inventory_processing = load_digitizer_signal_request_processing(entity_data, parsed)
    local processing_items = inventory_processing.items
    local processing_fluids = inventory_processing.fluids

    local read_contents = digitizer_chest_reads_contents(entity)
    local inventory_contents = entity_data.inventory and entity_data.inventory.get_contents() or nil
    local inventory_counts = nil
    if inventory_contents then
        inventory_counts = {}
        for _, item in pairs(inventory_contents) do
            local item_by_quality = inventory_counts[item.name]
            if not item_by_quality then
                item_by_quality = {}
                inventory_counts[item.name] = item_by_quality
            end
            item_by_quality[item.quality] = item.count
            if read_contents and fixed_quantity == 0 then
                local processing_item_by_quality = processing_items[item.name]
                if processing_item_by_quality and processing_item_by_quality[item.quality] then
                    processing_item_by_quality[item.quality] = processing_item_by_quality[item.quality] - item.count
                end
            end
        end
    end

    for item_name, item_by_quality in pairs(processing_items) do
        local current_item_by_quality = inventory_counts and inventory_counts[item_name]
        for item_quality, item_count in pairs(item_by_quality) do
            local current_count = current_item_by_quality and current_item_by_quality[item_quality] or 0
            if current_count < item_count then
                end_instrument_sample(profiler, "tracking.digitizer_chest_has_unmet_signal_requests")
                return true
            end
        end
    end

    local current_fluid = get_container_fluid_state(entity_data.container_fluid)
    if processing_fluids.count > 0 and entity_data.container_fluid and entity_data.container_fluid.valid then
        local current_fluid_amount = 0
        if current_fluid
            and current_fluid.name == processing_fluids.name
            and fluid_temperatures_match(current_fluid.temperature, processing_fluids.temperature)
        then
            current_fluid_amount = current_fluid.amount
        end
        if read_contents and fixed_quantity == 0 and processing_fluids.name ~= "" then
            processing_fluids.count = processing_fluids.count - current_fluid_amount
        end
    end

    if processing_fluids.count > 0 and entity_data.container_fluid and entity_data.container_fluid.valid then
        local current_fluid_amount = 0
        if current_fluid
            and current_fluid.name == processing_fluids.name
            and fluid_temperatures_match(current_fluid.temperature, processing_fluids.temperature)
        then
            current_fluid_amount = current_fluid.amount
        end
        if current_fluid_amount < processing_fluids.count then
            end_instrument_sample(profiler, "tracking.digitizer_chest_has_unmet_signal_requests")
            return true
        end
    end

    end_instrument_sample(profiler, "tracking.digitizer_chest_has_unmet_signal_requests")
    return false
end

local function wake_digitizer_chest_idle_queue(iterations, batch_size)
    local queues = ensure_digitizer_chest_queue_storage()
    local queue = queues.idle
    local request_id_key = "digitizer-chest-idle-wakeup"
    if get_digitizer_queue_size(queues, "idle") <= 0 then
        storage.request_ids[request_id_key] = nil
        return
    end
    local dynamic_batch_size = get_dynamic_digitizer_queue_batch(queues, "idle", batch_size)

    local current_key = storage.request_ids[request_id_key]
    if current_key and not queue[current_key] then
        current_key = nil
    end
    if not current_key then
        current_key = next(queue)
    end

    for _ = 1, iterations do
        if not current_key then
            break
        end

        local processed = 0
        while current_key and processed < dynamic_batch_size do
            local key = current_key
            current_key = next(queue, key)
            local entity_data = queue[key]
            if entity_data then
                local entity = entity_data.entity
                if not entity or not entity.valid then
                    tracking.remove_tracked_entity(entity_data)
                else
                    local signals, signals_checked = refresh_digitizer_chest_signals(entity_data)
                    if signals and entity_data.signal_active then
                        if entity_data.signals_changed or signals_checked then
                            entity_data.has_unmet_signal_requests = digitizer_chest_has_unmet_signal_requests(entity_data, signals)
                        end
                        if entity_data.has_unmet_signal_requests then
                            entity_data.idle_empty_checks = 0
                            set_digitizer_chest_queue(entity_data, "active")
                        end
                    elseif digitizer_chest_has_processable_contents(entity_data) then
                        entity_data.idle_empty_checks = 0
                        set_digitizer_chest_queue(entity_data, "active")
                    end
                end
            end
            processed = processed + 1
        end
    end

    storage.request_ids[request_id_key] = current_key
end

local function wake_digitizer_chest_idle_queue_budgeted(max_processed)
    if max_processed <= 0 then
        return
    end

    local queues = ensure_digitizer_chest_queue_storage()
    local queue = queues.idle
    local request_id_key = "digitizer-chest-idle-wakeup"
    if get_digitizer_queue_size(queues, "idle") <= 0 then
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
    while current_key and processed < max_processed do
        local key = current_key
        current_key = next(queue, key)
        local entity_data = queue[key]
        if entity_data then
            local entity = entity_data.entity
            if not entity or not entity.valid then
                tracking.remove_tracked_entity(entity_data)
            else
                local signals, signals_checked = refresh_digitizer_chest_signals(entity_data)
                if signals and entity_data.signal_active then
                    if entity_data.signals_changed or signals_checked then
                        entity_data.has_unmet_signal_requests = digitizer_chest_has_unmet_signal_requests(entity_data, signals)
                    end
                    if entity_data.has_unmet_signal_requests then
                        entity_data.idle_empty_checks = 0
                        set_digitizer_chest_queue(entity_data, "active")
                    end
                elseif digitizer_chest_has_processable_contents(entity_data) then
                    entity_data.idle_empty_checks = 0
                    set_digitizer_chest_queue(entity_data, "active")
                end
            end
        end
        processed = processed + 1
    end

    storage.request_ids[request_id_key] = current_key
end

local function wake_digitizer_chest_long_idle_queue(iterations, batch_size)
    local queues = ensure_digitizer_chest_queue_storage()
    local queue = queues.long_idle
    local request_id_key = "digitizer-chest-long-idle-wakeup"
    if get_digitizer_queue_size(queues, "long_idle") <= 0 then
        storage.request_ids[request_id_key] = nil
        return
    end
    local dynamic_batch_size = get_dynamic_digitizer_queue_batch(queues, "long_idle", batch_size)

    local current_key = storage.request_ids[request_id_key]
    if current_key and not queue[current_key] then
        current_key = nil
    end
    if not current_key then
        current_key = next(queue)
    end

    for _ = 1, iterations do
        if not current_key then
            break
        end

        local processed = 0
        while current_key and processed < dynamic_batch_size do
            local key = current_key
            current_key = next(queue, key)
            local entity_data = queue[key]
            if entity_data then
                local entity = entity_data.entity
                if not entity or not entity.valid then
                    tracking.remove_tracked_entity(entity_data)
                else
                    local signals, signals_checked = refresh_digitizer_chest_signals(entity_data)
                    if signals and entity_data.signal_active then
                        if entity_data.signals_changed or signals_checked then
                            entity_data.has_unmet_signal_requests = digitizer_chest_has_unmet_signal_requests(entity_data, signals)
                        end
                        if entity_data.has_unmet_signal_requests then
                            entity_data.idle_empty_checks = 0
                            set_digitizer_chest_queue(entity_data, "active")
                        elseif digitizer_chest_has_contents(entity_data) then
                            entity_data.idle_empty_checks = 0
                            set_digitizer_chest_queue(entity_data, "idle")
                        elseif game.tick >= (entity_data.next_signal_check_tick or 0) then
                            set_digitizer_chest_queue(entity_data, "idle")
                        end
                    elseif digitizer_chest_has_processable_contents(entity_data) then
                        entity_data.idle_empty_checks = 0
                        set_digitizer_chest_queue(entity_data, "active")
                    elseif digitizer_chest_has_contents(entity_data) then
                        entity_data.idle_empty_checks = 0
                        set_digitizer_chest_queue(entity_data, "idle")
                    elseif game.tick >= (entity_data.next_signal_check_tick or 0) then
                        set_digitizer_chest_queue(entity_data, "idle")
                    end
                end
            end
            processed = processed + 1
        end
    end

    storage.request_ids[request_id_key] = current_key
end

local function wake_digitizer_chest_long_idle_queue_budgeted(max_processed)
    if max_processed <= 0 then
        return
    end

    local queues = ensure_digitizer_chest_queue_storage()
    local queue = queues.long_idle
    local request_id_key = "digitizer-chest-long-idle-wakeup"
    if get_digitizer_queue_size(queues, "long_idle") <= 0 then
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
    while current_key and processed < max_processed do
        local key = current_key
        current_key = next(queue, key)
        local entity_data = queue[key]
        if entity_data then
            local entity = entity_data.entity
            if not entity or not entity.valid then
                tracking.remove_tracked_entity(entity_data)
            else
                local signals, signals_checked = refresh_digitizer_chest_signals(entity_data)
                if signals and entity_data.signal_active then
                    if entity_data.signals_changed or signals_checked then
                        entity_data.has_unmet_signal_requests = digitizer_chest_has_unmet_signal_requests(entity_data, signals)
                    end
                    if entity_data.has_unmet_signal_requests then
                        entity_data.idle_empty_checks = 0
                        set_digitizer_chest_queue(entity_data, "active")
                    elseif digitizer_chest_has_contents(entity_data) then
                        entity_data.idle_empty_checks = 0
                        set_digitizer_chest_queue(entity_data, "idle")
                    elseif game.tick >= (entity_data.next_signal_check_tick or 0) then
                        set_digitizer_chest_queue(entity_data, "idle")
                    end
                elseif digitizer_chest_has_processable_contents(entity_data) then
                    entity_data.idle_empty_checks = 0
                    set_digitizer_chest_queue(entity_data, "active")
                elseif digitizer_chest_has_contents(entity_data) then
                    entity_data.idle_empty_checks = 0
                    set_digitizer_chest_queue(entity_data, "idle")
                elseif game.tick >= (entity_data.next_signal_check_tick or 0) then
                    set_digitizer_chest_queue(entity_data, "idle")
                end
            end
        end
        processed = processed + 1
    end

    storage.request_ids[request_id_key] = current_key
end

local function get_digitizer_queue_tick_budgets()
    storage.digitizer_queue_tick_budgets = storage.digitizer_queue_tick_budgets or {}
    return storage.digitizer_queue_tick_budgets
end

local function get_budgeted_digitizer_queue_work(queues, budget_key, queue_name, nth_tick, base_batch_size)
    local budgets = get_digitizer_queue_tick_budgets()
    local queue_size = get_digitizer_queue_size(queues, queue_name)
    if queue_size <= 0 then
        budgets[budget_key] = 0
        return 0
    end

    local budget = (budgets[budget_key] or 0) + get_digitizer_budget_effective_work_per_tick(queues, budget_key, queue_name, nth_tick, base_batch_size)
    local work = math.floor(budget)
    budgets[budget_key] = budget - work
    return work
end

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

function tracking.on_tick_update_digitizer_queues()
    local queues = ensure_digitizer_chest_queue_storage()

    wake_digitizer_chest_idle_queue_budgeted(get_budgeted_digitizer_queue_work(
        queues, "idle_wakeup", "idle", digitizer_chest_active_nth_tick, 4))

    wake_digitizer_chest_long_idle_queue_budgeted(get_budgeted_digitizer_queue_work(
        queues, "long_idle_wakeup", "long_idle", digitizer_chest_idle_nth_tick, 4))

    process_digitizer_chest_queue_budgeted("signal", get_budgeted_digitizer_queue_work(
        queues, "signal", "signal", digitizer_chest_signal_nth_tick, 4))

    process_digitizer_chest_queue_budgeted("active", get_budgeted_digitizer_queue_work(
        queues, "active", "active", digitizer_chest_active_nth_tick, 4))

    process_digitizer_chest_queue_budgeted("idle", get_budgeted_digitizer_queue_work(
        queues, "idle", "idle", digitizer_chest_idle_nth_tick, 2))

    process_digitizer_chest_queue_budgeted("long_idle", get_budgeted_digitizer_queue_work(
        queues, "long_idle", "long_idle", digitizer_chest_long_idle_nth_tick, 1))
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

---@param request_table RequestData
---@return nil
---@return boolean --true to remove the request from the table, false to keep it
---@return boolean
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

---comment
---@param entity RequestData|LuaEntity
---@param request_type string
---@return nil
---@return boolean --true to remove the request from the table, false to keep it
---@return boolean
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

---@param player LuaPlayer
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

---Updated way to get item request proxies
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

---Adds an entity to be tracked and creates necessary hidden entities
---@param request_data RequestData
function tracking.add_tracked_entity(request_data)
    local entity = request_data.entity
    local player_index = request_data.player_index
    local tracked_entity_name = get_tracking_entity_name(entity.name)
    local existing_entities = storage.tracked_entities[tracked_entity_name]
    if existing_entities and existing_entities[entity.unit_number] then
        return
    end

    ---@type EntityData
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
        ---@diagnostic disable-next-line: need-check-nil
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
        ---@diagnostic disable-next-line: undefined-field
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
    end
end

---Remove tracked entity from the data and clear hidden entities
---@param entity_data? EntityData
function tracking.remove_tracked_entity(entity_data)
    if not entity_data then return end
    local entity_name = entity_data.name
    if entity_name == "digitizer-chest" then
        local queues = ensure_digitizer_chest_queue_storage()
        if entity_data.queue_name and queues[entity_data.queue_name] then
            remove_digitizer_queue_entry(queues, entity_data.queue_name, entity_data.unit_number)
        else
            remove_digitizer_queue_entry_from_all(queues, entity_data.unit_number)
        end
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

---@param entity LuaEntity
---@return EntityData?
function tracking.get_entity_data(entity)
    local tracked_entity_name = get_tracking_entity_name(entity.name)
    if not storage.tracked_entities[tracked_entity_name] or not storage.tracked_entities[tracked_entity_name][entity.unit_number] then return end
    local entity_data = storage.tracked_entities[tracked_entity_name][entity.unit_number]
    if tracked_entity_name == "digitizer-chest" then
        sync_digitizer_chest_fluid_setting(entity_data)
    end
    return entity_data
end

---@param source LuaEntity
---@param destination LuaEntity
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

---@param entity LuaEntity
---@return Tags?
function tracking.export_blueprint_settings(entity)
    local entity_data = tracking.get_entity_data(entity)
    if not entity_data or not entity_data.settings then return nil end
    return flib_table.deep_copy(entity_data.settings)
end

---@param entity LuaEntity
---@param blueprint_settings Tags?
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

---@param entity_data EntityData
function tracking.update_entity(entity_data)
    local entity = entity_data.entity
    if not entity or not entity.valid then
        tracking.remove_tracked_entity(entity_data)
        return
    end
    local surface_index = entity_data.surface_index

    if entity_data.name == "digitizer-chest" then
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
                local no_signal_inventory_profiler, no_signal_inventory_stat_name = begin_digitizer_phase_sample(entity_data, "no_signal.inventory")
                local no_signal_get_contents_profiler, no_signal_get_contents_stat_name = begin_digitizer_phase_sample(entity_data, "no_signal.inventory.get_contents")
                local inventory_contents = inventory.get_contents()
                end_digitizer_phase_sample(no_signal_get_contents_profiler, no_signal_get_contents_stat_name)
                item_qs_item.surface_index = storage_index
                -- 这里会先按 removable_count 入仓，再尝试从箱子里移除；reserve_limit 为负时会保留当前放大量行为
                if limit_value == 0 then
                    if next(inventory_contents) then
                        local no_signal_store_profiler, no_signal_store_stat_name = begin_digitizer_phase_sample(entity_data, "no_signal.inventory.store")
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
                        end_digitizer_phase_sample(no_signal_store_profiler, no_signal_store_stat_name)
                    end
                else
                    local no_signal_limited_profiler, no_signal_limited_stat_name = begin_digitizer_phase_sample(entity_data, "no_signal.inventory.store_limited")
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
                    end_digitizer_phase_sample(no_signal_limited_profiler, no_signal_limited_stat_name)
                end
                end_digitizer_phase_sample(no_signal_inventory_profiler, no_signal_inventory_stat_name)
            end
            local fluid_contents = entity_data.container_fluid and entity_data.container_fluid.get_fluid_contents()
            if fluid_contents then
                local no_signal_fluid_profiler, no_signal_fluid_stat_name = begin_digitizer_phase_sample(entity_data, "no_signal.fluid")
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
                end_digitizer_phase_sample(no_signal_fluid_profiler, no_signal_fluid_stat_name)
            end
            local no_signal_queue_profiler, no_signal_queue_stat_name = begin_digitizer_phase_sample(entity_data, "no_signal.queue")
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
            end_digitizer_phase_sample(no_signal_queue_profiler, no_signal_queue_stat_name)
            return
        end
        entity_data.idle_empty_checks = 0
        local had_unmet_signal_requests = entity_data.has_unmet_signal_requests == true
        local has_unmet_signal_requests_after = false
        local pulled_signal_contents = false
        local read_contents = false

        local signal_prepare_profiler, signal_prepare_stat_name = begin_digitizer_phase_sample(entity_data, "signal.prepare")
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
        end_digitizer_phase_sample(signal_prepare_profiler, signal_prepare_stat_name)

        local function ensure_processing_items_mutable()
            if processing_items_mutable or not parsed then
                return
            end
            processing_items = load_digitizer_signal_request_processing(entity_data, parsed).items
            processing_items_mutable = true
        end

        -- We are only allower to select storage_index if the map setting is enabled
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
                local signal_balance_profiler, signal_balance_stat_name = begin_digitizer_phase_sample(entity_data, "signal.inventory_balance")
                local signal_get_contents_profiler, signal_get_contents_stat_name = begin_digitizer_phase_sample(entity_data, "signal.inventory.get_contents")
                inventory_contents = inventory.get_contents()
                end_digitizer_phase_sample(signal_get_contents_profiler, signal_get_contents_stat_name)
                ensure_processing_items_mutable()
                item_qs_item.surface_index = storage_index
                local batch_item_count = 0
                for _, item in pairs(inventory_contents) do
                    local total_count = item.count
                    item_qs_item.name = item.name
                    item_qs_item.count = total_count
                    item_qs_item.quality = item.quality
                    local removable = true
                    -- if we have a signal for this item and that quality...
                    local item_by_quality = processing_items[item.name]
                    local requested_count = item_by_quality and item_by_quality[item.quality]
                    if requested_count then
                        if read_contents and fixed_quantity == 0 then
                            requested_count = requested_count - total_count
                        end
                        -- Deciding what to do with items - store, fetch or ignore
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
                end_digitizer_phase_sample(signal_balance_profiler, signal_balance_stat_name)
            end
            local signal_pull_profiler, signal_pull_stat_name = begin_digitizer_phase_sample(entity_data, "signal.inventory_pull")
            for item_name, item_by_quality in pairs(processing_items) do
                for item_quality, item_count in pairs(item_by_quality) do
                    if item_count > 0 then
                        local remaining_item_count = item_count
                        item_qs_item.name = item_name
                        item_qs_item.count = item_count
                        item_qs_item.quality = item_quality
                        item_qs_item.surface_index = storage_index
                        local requested_item_count = item_qs_item.count
                        local storage_pull_profiler, storage_pull_stat_name = begin_digitizer_phase_sample(entity_data, "signal.inventory_pull.storage")
                        local empty_storage, full_inventory = qs_utils.pull_from_storage(item_qs_item, inventory)
                        end_digitizer_phase_sample(storage_pull_profiler, storage_pull_stat_name)
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
                            local fabricate_pull_profiler, fabricate_pull_stat_name = begin_digitizer_phase_sample(entity_data, "signal.inventory_pull.fabricate")
                            fabricate_digitizer_requested_item(item_qs_item, inventory)
                            end_digitizer_phase_sample(fabricate_pull_profiler, fabricate_pull_stat_name)
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
            end_digitizer_phase_sample(signal_pull_profiler, signal_pull_stat_name)
        end
        local fluid_contents = entity_data.container_fluid and entity_data.container_fluid.get_fluid_contents()
        if fluid_contents then
            local signal_fluid_profiler, signal_fluid_stat_name = begin_digitizer_phase_sample(entity_data, "signal.fluid")
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
            end_digitizer_phase_sample(signal_fluid_profiler, signal_fluid_stat_name)
        end
        if had_unmet_signal_requests or pulled_signal_contents then
            entity_data.active_until_tick = game.tick + digitizer_chest_active_keepalive_ticks
        end
        entity_data.has_unmet_signal_requests = has_unmet_signal_requests_after
        local signal_queue_profiler, signal_queue_stat_name = begin_digitizer_phase_sample(entity_data, "signal.queue")
        if has_unmet_signal_requests_after or game.tick <= entity_data.active_until_tick then
            set_digitizer_chest_queue(entity_data, "signal")
        else
            set_digitizer_chest_queue(entity_data, "idle")
        end
        end_digitizer_phase_sample(signal_queue_profiler, signal_queue_stat_name)
        return
    end

    if entity_data.entity.name == "dedigitizer-reactor" then
        local energy_consumption = Reactor_constants.idle_cost
        local energy_consumption_multiplier = 1
        local transfer_rate_multiplier = 1 * settings.global["qf-reactor-transfer-multi"].value

        local burnt_result_contents = entity_data.burnt_result_inventory.get_contents()
        if next(burnt_result_contents) then
            ---@diagnostic disable-next-line: param-type-mismatch
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

    if entity_data.entity.name == "qf-storage-reader" then
        ---@type LuaConstantCombinatorControlBehavior
        ---@diagnostic disable-next-line: assign-type-mismatch
        local control_behavior = entity.get_control_behavior()
        if not control_behavior then return end
        while control_behavior.sections_count < 2 do
            control_behavior.add_section()
        end
        local storage_index
        local read_config_profiler = begin_instrument_sample()
        for _, signal in pairs(control_behavior.get_section(1).filters) do
            if signal.value.name == "signal-S" then
                storage_index = signal.min
            end
        end
        if not storage_index or not storage.fabricator_inventory[storage_index] then storage_index = entity_data.surface_index end
        end_instrument_sample(read_config_profiler, "tracking.update_entity.qf-storage-reader.read_config")
        local signals = qs_utils.get_storage_signals(storage_index)
        local write_filters_profiler = begin_instrument_sample()
        control_behavior.get_section(2).filters = signals
        end_instrument_sample(write_filters_profiler, "tracking.update_entity.qf-storage-reader.write_filters")
        return
    end
end


return tracking
