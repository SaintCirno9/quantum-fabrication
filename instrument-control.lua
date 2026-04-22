local TARGET_MOD_NAME = "quantum-fabricator"
local AUTO_EXPORT_NTH_TICK = 18000
local AUTO_EXPORT_PATH_PREFIX = "qf-instrument/summary-"

if script.mod_name ~= TARGET_MOD_NAME then
    return
end

local original_require = require
local original_script = script
local original_on_event = original_script.on_event
local original_on_nth_tick = original_script.on_nth_tick

script = setmetatable({}, {__index = original_script})

local instrument_state = {
    stats = {},
    pending_translations = {},
}
local wrapped_functions = setmetatable({}, {__mode = "k"})

local module_function_wraps = {
    ["scripts/tracking_utils"] = {
        prefix = "tracking",
        functions = {
            "on_tick_update_digitizer_queues",
            "on_tick_update_requests",
            "update_lost_module_requests_neo",
            "update_item_request_proxy",
            "on_tick_update_handler",
            "update_tracked_reactors",
            "update_entity",
        }
    },
    ["scripts/qs_utils"] = {
        prefix = "qs_utils",
        functions = {
            "add_to_storage",
            "advanced_remove_from_storage",
            "count_in_storage",
            "pull_from_storage",
            "get_storage_signals",
        }
    },
    ["scripts/qf_utils"] = {
        prefix = "qf_utils",
        functions = {
            "how_many_can_craft",
            "get_craftable_recipe",
            "fabricate_recipe",
            "is_recipe_craftable",
        }
    },
}

local global_function_wraps = {
    ["scripts/builder"] = {
        "instant_fabrication",
        "instant_upgrade",
    },
    ["scripts/debuilder"] = {
        "instant_defabrication",
        "decraft",
    },
}

local function get_stat(name)
    local stat = instrument_state.stats[name]
    if stat then
        return stat
    end
    stat = {
        samples = 0,
        total = nil,
    }
    instrument_state.stats[name] = stat
    return stat
end

local function begin_sample()
    local profiler = helpers.create_profiler(true)
    profiler.restart()
    return profiler
end

local function end_sample(name, profiler)
    local stat = get_stat(name)
    if not stat.total then
        stat.total = helpers.create_profiler(true)
    end
    stat.total.add(profiler)
    stat.samples = stat.samples + 1
end

function _G.qf_instrument_begin_sample()
    return begin_sample()
end

function _G.qf_instrument_end_sample(name, profiler)
    if not profiler then
        return
    end
    profiler.stop()
    end_sample(name, profiler)
end

local function get_instrument_stat_name(name, ...)
    if name ~= "tracking.update_entity" then
        return name
    end
    local entity_data = select(1, ...)
    if type(entity_data) ~= "table" then
        return name
    end

    local entity_name = entity_data.name
    if not entity_name then
        local entity = entity_data.entity
        if entity and entity.valid then
            entity_name = entity.name
        end
    end
    if not entity_name then
        entity_name = "unknown"
    end

    if entity_name == "digitizer-chest" then
        local queue_name = entity_data.queue_name or "unknown"
        return name .. "." .. entity_name .. "." .. queue_name
    end
    return name .. "." .. entity_name
end

local function instrument_function(name, fn)
    if type(fn) ~= "function" then
        return fn
    end
    if wrapped_functions[fn] then
        return fn
    end
    local wrapped = function(...)
        local profiler = begin_sample()
        local stat_name = get_instrument_stat_name(name, ...)
        local results = table.pack(fn(...))
        profiler.stop()
        end_sample(name, profiler)
        if stat_name ~= name then
            end_sample(stat_name, profiler)
        end
        return table.unpack(results, 1, results.n)
    end
    wrapped_functions[wrapped] = true
    return wrapped
end

local function get_registration_label(kind, key, handler)
    local info = debug.getinfo(handler, "Sn")
    local source = info and info.short_src or "?"
    local line = info and info.linedefined or 0
    local key_text
    if type(key) == "table" then
        local values = {}
        for _, value in pairs(key) do
            values[#values + 1] = tostring(value)
        end
        table.sort(values)
        key_text = table.concat(values, ",")
    else
        key_text = tostring(key)
    end
    return kind .. "(" .. key_text .. ")@" .. source .. ":" .. line
end

local function wrap_module_functions(module_name, module)
    local config = module_function_wraps[module_name]
    if not config or type(module) ~= "table" then
        return
    end
    for _, function_name in pairs(config.functions) do
        if type(module[function_name]) == "function" then
            module[function_name] = instrument_function(config.prefix .. "." .. function_name, module[function_name])
        end
    end
end

local function wrap_global_functions(module_name)
    local function_names = global_function_wraps[module_name]
    if not function_names then
        return
    end
    for _, function_name in pairs(function_names) do
        if type(_G[function_name]) == "function" then
            _G[function_name] = instrument_function(function_name, _G[function_name])
        end
    end
end

function require(module_name)
    local module = original_require(module_name)
    wrap_module_functions(module_name, module)
    wrap_global_functions(module_name)
    return module
end

local function handle_translation_export(event)
    local pending = instrument_state.pending_translations[event.id]
    if not pending then
        return
    end
    instrument_state.pending_translations[event.id] = nil

    local export = pending.export
    export.lines[pending.line_index] = event.result
    export.remaining = export.remaining - 1
    if export.remaining == 0 then
        helpers.write_file(export.path, table.concat(export.lines, "\n") .. "\n", false)
    end
end

function script.on_event(event, handler, filters)
    if type(handler) == "function" then
        if event == defines.events.on_string_translated then
            local original_handler = handler
            handler = function(event_data)
                handle_translation_export(event_data)
                return original_handler(event_data)
            end
        end
        handler = instrument_function(get_registration_label("event", event, handler), handler)
    end
    return original_on_event(event, handler, filters)
end

function script.on_nth_tick(tick, handler)
    if type(handler) == "function" then
        handler = instrument_function(get_registration_label("nth", tick, handler), handler)
    end
    return original_on_nth_tick(tick, handler)
end

local function print_line(player, message)
    if player then
        player.print(message)
    else
        game.print(message)
    end
end

local function reset_stats()
    instrument_state.stats = {}
    instrument_state.pending_translations = {}
end

local function get_export_player()
    for _, player in pairs(game.players) do
        if player and player.valid and player.connected then
            return player
        end
    end
end

local function collect_stats(filter_text)
    local names = {}
    for name, stat in pairs(instrument_state.stats) do
        if stat.samples > 0 and stat.total then
            if not filter_text or string.find(string.lower(name), filter_text, 1, true) then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)

    local entries = {}
    for _, name in pairs(names) do
        local stat = instrument_state.stats[name]
        local average = helpers.create_profiler(true)
        average.add(stat.total)
        average.divide(stat.samples)
        entries[#entries + 1] = {
            name = name,
            samples = stat.samples,
            total = stat.total,
            average = average,
        }
    end
    return entries
end

local function get_report_header(tick, entry_count)
    return "[QF][Instr] tick=" .. tick .. " 条目=" .. entry_count .. "。函数级统计与事件级统计会重叠，不可直接相加。"
end

local function create_report_message(entry)
    return {
        "",
        "[QF][Instr] ",
        entry.name,
        " 调用=",
        entry.samples,
        " 总耗时=",
        entry.total,
        " 平均=",
        entry.average
    }
end

local function report_stats(player, filter_text)
    local entries = collect_stats(filter_text)
    print_line(player, get_report_header(game.tick, #entries))
    for _, entry in pairs(entries) do
        print_line(player, create_report_message(entry))
    end
end

local function export_stats(preferred_player)
    if not next(instrument_state.stats) then
        return nil
    end
    local player = preferred_player
    if not (player and player.valid and player.connected) then
        player = get_export_player()
    end
    if not player then
        return nil
    end
    local tick = game.tick
    local entries = collect_stats(nil)
    local path = AUTO_EXPORT_PATH_PREFIX .. tick .. ".txt"
    local header = get_report_header(tick, #entries)
    if #entries == 0 then
        helpers.write_file(path, header .. "\n", false)
        return path
    end

    local messages = {}
    for index, entry in ipairs(entries) do
        messages[index] = create_report_message(entry)
    end

    local ids = player.request_translations(messages)
    if not ids then
        return nil
    end

    local export = {
        path = path,
        lines = {header},
        remaining = #ids,
    }
    for index, id in ipairs(ids) do
        instrument_state.pending_translations[id] = {
            export = export,
            line_index = index + 1,
        }
    end
    return path
end

commands.add_command("qf_instrument_report", nil, function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    local filter_text = command.parameter and command.parameter ~= "" and string.lower(command.parameter) or nil
    report_stats(player, filter_text)
end)

commands.add_command("qf_instrument_reset", nil, function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    reset_stats()
    print_line(player, "[QF][Instr] 统计已重置。")
end)

commands.add_command("qf_instrument_export", nil, function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    local path = export_stats(player)
    if path then
        print_line(player, "[QF][Instr] 导出已开始: " .. path)
    else
        print_line(player, "[QF][Instr] 导出失败，没有可用统计或可用玩家。")
    end
end)

original_on_nth_tick(AUTO_EXPORT_NTH_TICK, function()
    export_stats()
end)
