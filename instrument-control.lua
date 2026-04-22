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
    capture = nil,
}
local wrapped_functions = setmetatable({}, {__mode = "k"})
local HOT_SPOT_PATTERNS = {
    {label = "on_tick 事件", pattern = "event(0)@", match = "prefix"},
    {label = "队列总调度", pattern = "tracking.on_tick_update_digitizer_queues", match = "exact"},
    {label = "队列唤醒 idle", pattern = "tracking.on_tick_update_digitizer_queues.wake_idle", match = "exact"},
    {label = "队列唤醒 long_idle", pattern = "tracking.on_tick_update_digitizer_queues.wake_long_idle", match = "exact"},
    {label = "队列处理 signal", pattern = "tracking.on_tick_update_digitizer_queues.signal", match = "exact"},
    {label = "队列处理 active", pattern = "tracking.on_tick_update_digitizer_queues.active", match = "exact"},
    {label = "signal 箱子更新", pattern = "tracking.update_entity.digitizer-chest.signal", match = "exact"},
    {label = "active 箱子更新", pattern = "tracking.update_entity.digitizer-chest.active", match = "exact"},
    {label = "idle 箱子更新", pattern = "tracking.update_entity.digitizer-chest.idle", match = "exact"},
    {label = "long_idle 箱子更新", pattern = "tracking.update_entity.digitizer-chest.long_idle", match = "exact"},
    {label = "processable 总检查", pattern = "tracking.digitizer_chest_has_processable_contents", match = "exact"},
    {label = "信号刷新", pattern = "tracking.refresh_digitizer_chest_signals", match = "exact"},
    {label = "限额剩余额度", pattern = "tracking.digitizer_intake_limit_remaining_capacity", match = "exact"},
    {label = "idle processable 细分", pattern = "tracking.update_entity.digitizer-chest.idle.processable", match = "prefix"},
    {label = "long_idle processable 细分", pattern = "tracking.update_entity.digitizer-chest.long_idle.processable", match = "prefix"},
    {label = "idle 无信号取内容", pattern = "tracking.update_entity.digitizer-chest.idle.no_signal.inventory.get_contents", match = "exact"},
    {label = "long_idle 无信号取内容", pattern = "tracking.update_entity.digitizer-chest.long_idle.no_signal.inventory.get_contents", match = "exact"},
}
local CAPTURE_TICK_PATTERNS = {
    {label = "on_tick 事件", pattern = "event(0)@", match = "prefix"},
    {label = "队列总调度", pattern = "tracking.on_tick_update_digitizer_queues", match = "exact"},
    {label = "队列唤醒 idle", pattern = "tracking.on_tick_update_digitizer_queues.wake_idle", match = "exact"},
    {label = "队列唤醒 long_idle", pattern = "tracking.on_tick_update_digitizer_queues.wake_long_idle", match = "exact"},
    {label = "队列处理 signal", pattern = "tracking.on_tick_update_digitizer_queues.signal", match = "exact"},
    {label = "队列处理 active", pattern = "tracking.on_tick_update_digitizer_queues.active", match = "exact"},
    {label = "signal 箱子更新", pattern = "tracking.update_entity.digitizer-chest.signal", match = "exact"},
    {label = "signal prepare", pattern = "tracking.update_entity.digitizer-chest.signal.signal.prepare", match = "exact"},
    {label = "signal 拉货", pattern = "tracking.update_entity.digitizer-chest.signal.signal.inventory_pull", match = "exact"},
    {label = "signal 拉货.storage", pattern = "tracking.update_entity.digitizer-chest.signal.signal.inventory_pull.storage", match = "exact"},
    {label = "active 箱子更新", pattern = "tracking.update_entity.digitizer-chest.active", match = "exact"},
    {label = "active 无信号入库", pattern = "tracking.update_entity.digitizer-chest.active.no_signal.inventory", match = "exact"},
    {label = "active 无信号入库.store", pattern = "tracking.update_entity.digitizer-chest.active.no_signal.inventory.store", match = "exact"},
    {label = "idle 箱子更新", pattern = "tracking.update_entity.digitizer-chest.idle", match = "exact"},
}

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

local function get_table_stat(stats_table, name)
    local stat = stats_table[name]
    if stat then
        return stat
    end
    stat = {
        samples = 0,
        total = nil,
    }
    stats_table[name] = stat
    return stat
end

local function begin_sample()
    local profiler = helpers.create_profiler(true)
    profiler.restart()
    return profiler
end

local function add_sample_to_stat(stat, profiler)
    if not stat.total then
        stat.total = helpers.create_profiler(true)
    end
    stat.total.add(profiler)
    stat.samples = stat.samples + 1
end

local function record_capture_tick_sample(name, profiler)
    local capture = instrument_state.capture
    if not capture or not game then
        return
    end
    local tick = game.tick
    if tick < capture.start_tick or tick > capture.end_tick then
        return
    end
    local tick_stats = capture.tick_stats[tick]
    if not tick_stats then
        tick_stats = {}
        capture.tick_stats[tick] = tick_stats
    end
    add_sample_to_stat(get_table_stat(tick_stats, name), profiler)
end

local function end_sample(name, profiler)
    add_sample_to_stat(get_stat(name), profiler)
    record_capture_tick_sample(name, profiler)
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

local function cancel_capture()
    instrument_state.capture = nil
end

local function get_export_player()
    for _, player in pairs(game.players) do
        if player and player.valid and player.connected then
            return player
        end
    end
end

local function create_stat_entry(name, stat)
    local average = helpers.create_profiler(true)
    average.add(stat.total)
    average.divide(stat.samples)
    return {
        name = name,
        samples = stat.samples,
        total = stat.total,
        average = average,
    }
end

local function stat_name_matches(name, pattern, match_mode)
    if match_mode == "prefix" then
        return name == pattern
            or string.sub(name, 1, #pattern) == pattern
            or string.sub(name, 1, #pattern + 1) == pattern .. "."
    end
    return name == pattern
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
        entries[#entries + 1] = create_stat_entry(name, stat)
    end
    return entries
end

local function collect_hotspot_groups_for_patterns(stats_table, patterns)
    local groups = {}
    for _, hotspot in ipairs(patterns) do
        local names = {}
        for name, stat in pairs(stats_table) do
            if stat.samples > 0 and stat.total and stat_name_matches(name, hotspot.pattern, hotspot.match) then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        if #names > 0 then
            local entries = {}
            for _, name in ipairs(names) do
                entries[#entries + 1] = create_stat_entry(name, stats_table[name])
            end
            groups[#groups + 1] = {
                label = hotspot.label,
                pattern = hotspot.pattern,
                entries = entries,
            }
        end
    end
    return groups
end

local function collect_hotspot_groups()
    return collect_hotspot_groups_for_patterns(instrument_state.stats, HOT_SPOT_PATTERNS)
end

local function collect_capture_tick_groups(capture)
    if not capture or not capture.tick_stats then
        return {}
    end
    local rows = {}
    for tick = capture.start_tick, capture.end_tick do
        local tick_stats = capture.tick_stats[tick]
        if tick_stats then
            local groups = collect_hotspot_groups_for_patterns(tick_stats, CAPTURE_TICK_PATTERNS)
            if #groups > 0 then
                rows[#rows + 1] = {
                    tick = tick,
                    groups = groups,
                }
            end
        end
    end
    return rows
end

local function get_report_header(tick, entry_count)
    return "[QF][Instr] tick=" .. tick .. " 条目=" .. entry_count .. "。函数级统计与事件级统计会重叠，不可直接相加。"
end

local function get_hotspot_header(tick, group_count)
    return "[QF][Instr] 尖峰重点项 tick=" .. tick .. " 分组=" .. group_count .. "。这些是定位尖峰时优先看的统计。"
end

local function get_capture_tick_header(capture, row_count)
    return "[QF][Instr] 逐 tick 热点 start_tick=" .. capture.start_tick .. " end_tick=" .. capture.end_tick .. " 命中tick=" .. row_count .. "。用于定位尖峰发生在哪一帧。"
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

local function report_hotspots(player)
    local groups = collect_hotspot_groups()
    print_line(player, get_hotspot_header(game.tick, #groups))
    if #groups == 0 then
        print_line(player, "[QF][Instr] 当前没有命中的尖峰重点项。")
        return
    end
    for _, group in ipairs(groups) do
        print_line(player, "[QF][Instr] " .. group.label .. " -> " .. group.pattern)
        for _, entry in ipairs(group.entries) do
            print_line(player, create_report_message(entry))
        end
    end
end

local function report_stats(player, filter_text)
    local entries = collect_stats(filter_text)
    print_line(player, get_report_header(game.tick, #entries))
    for _, entry in pairs(entries) do
        print_line(player, create_report_message(entry))
    end
end

local function export_stats(preferred_player, capture)
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
    local hotspot_groups = collect_hotspot_groups()
    local capture_tick_groups = collect_capture_tick_groups(capture)
    local path = AUTO_EXPORT_PATH_PREFIX .. tick .. ".txt"
    local header = get_report_header(tick, #entries)
    if #entries == 0 and #hotspot_groups == 0 and #capture_tick_groups == 0 then
        helpers.write_file(path, header .. "\n", false)
        return path
    end

    local messages = {}
    local lines = {header}
    if #hotspot_groups > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = get_hotspot_header(tick, #hotspot_groups)
        for _, group in ipairs(hotspot_groups) do
            lines[#lines + 1] = "[QF][Instr] " .. group.label .. " -> " .. group.pattern
            for _, entry in ipairs(group.entries) do
                lines[#lines + 1] = false
                messages[#messages + 1] = {
                    line_index = #lines,
                    value = create_report_message(entry),
                }
            end
        end
    end
    if #entries > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "[QF][Instr] 全量统计"
        for _, entry in ipairs(entries) do
            lines[#lines + 1] = false
            messages[#messages + 1] = {
                line_index = #lines,
                value = create_report_message(entry),
            }
        end
    end
    if #capture_tick_groups > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = get_capture_tick_header(capture, #capture_tick_groups)
        for _, row in ipairs(capture_tick_groups) do
            lines[#lines + 1] = "[QF][Instr] tick=" .. row.tick
            for _, group in ipairs(row.groups) do
                lines[#lines + 1] = "[QF][Instr] " .. group.label .. " -> " .. group.pattern
                for _, entry in ipairs(group.entries) do
                    lines[#lines + 1] = false
                    messages[#messages + 1] = {
                        line_index = #lines,
                        value = create_report_message(entry),
                    }
                end
            end
        end
    end

    local request_payload = {}
    for index, message in ipairs(messages) do
        request_payload[index] = message.value
    end

    local ids = player.request_translations(request_payload)
    if not ids then
        return nil
    end

    local export = {
        path = path,
        lines = lines,
        remaining = #ids,
    }
    for index, id in ipairs(ids) do
        instrument_state.pending_translations[id] = {
            export = export,
            line_index = messages[index].line_index,
        }
    end
    return path
end

commands.add_command("qf_instrument_report", nil, function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    local filter_text = command.parameter and command.parameter ~= "" and string.lower(command.parameter) or nil
    report_stats(player, filter_text)
end)

commands.add_command("qf_instrument_report_hotspots", nil, function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    report_hotspots(player)
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

commands.add_command("qf_instrument_capture", nil, function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    local duration_ticks = tonumber(command.parameter)
    if not duration_ticks or duration_ticks <= 0 then
        duration_ticks = 600
    else
        duration_ticks = math.floor(duration_ticks)
    end
    reset_stats()
    instrument_state.capture = {
        start_tick = game.tick,
        end_tick = game.tick + duration_ticks,
        player_index = command.player_index,
        tick_stats = {},
    }
    print_line(player, "[QF][Instr] 已开始窗口采样: start_tick=" .. game.tick .. " end_tick=" .. (game.tick + duration_ticks) .. " duration_ticks=" .. duration_ticks)
end)

commands.add_command("qf_instrument_capture_cancel", nil, function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    cancel_capture()
    print_line(player, "[QF][Instr] 窗口采样已取消。")
end)

original_on_nth_tick(1, function()
    local capture = instrument_state.capture
    if not capture or game.tick < capture.end_tick then
        return
    end

    local player = capture.player_index and game.get_player(capture.player_index) or nil
    instrument_state.capture = nil
    local path = export_stats(player, capture)
    if path then
        print_line(player, "[QF][Instr] 窗口采样导出已开始: " .. path)
    else
        print_line(player, "[QF][Instr] 窗口采样导出失败，没有可用统计或可用玩家。")
    end
end)

original_on_nth_tick(AUTO_EXPORT_NTH_TICK, function()
    export_stats()
end)
