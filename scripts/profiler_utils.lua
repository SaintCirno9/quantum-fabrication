---@class profiler_utils
local profiler_utils = {}

local function ensure_profiler_storage()
    if not storage.qf_profilers then
        storage.qf_profilers = {}
    end
    return storage.qf_profilers
end

---@param profiler_name string
---@return table?
local function get_profiler_state(profiler_name)
    local profilers = ensure_profiler_storage()
    return profilers[profiler_name]
end

---@param profiler_name string
---@param ticks? uint
---@param label? string
function profiler_utils.start(profiler_name, ticks, label)
    if not profiler_name or profiler_name == "" then return end
    local profile_ticks = math.max(1, math.floor(tonumber(ticks) or 3600))
    local profilers = ensure_profiler_storage()
    profilers[profiler_name] = {
        active = true,
        end_tick = game.tick + profile_ticks,
        samples = 0,
        hits = 0,
        total = game.create_profiler(true),
        label = label or profiler_name,
    }
    local state = profilers[profiler_name]
    game.print({
        "",
        "[QF][",
        state.label,
        "] 已启动，持续tick=",
        profile_ticks,
        "，结束tick=",
        state.end_tick
    })
end

---@param profiler_name string
---@param reason? string
---@return boolean
function profiler_utils.stop(profiler_name, reason)
    if not profiler_name or profiler_name == "" then return false end
    local profilers = ensure_profiler_storage()
    local state = profilers[profiler_name]
    if not state then
        game.print({"", "[QF][", profiler_name, "] 当前未运行。"})
        return false
    end
    local final_reason = reason or "手动停止"
    local total = state.total
    if not total then
        game.print({"", "[QF][", state.label, "] ", final_reason, "，无可用数据。"})
        profilers[profiler_name] = nil
        return true
    end
    if state.samples <= 0 then
        game.print({"", "[QF][", state.label, "] ", final_reason, "，采样为 0。"})
        profilers[profiler_name] = nil
        return true
    end
    local average = game.create_profiler(true)
    average.add(total)
    average.divide(state.samples)
    game.print({
        "",
        "[QF][",
        state.label,
        "] ",
        final_reason,
        " 调用=",
        state.samples,
        " 命中=",
        state.hits,
        " 总耗时=",
        total,
        " 平均=",
        average
    })
    profilers[profiler_name] = nil
    return true
end

---@param profiler_name string
---@return LuaProfiler?
function profiler_utils.begin_sample(profiler_name)
    local state = get_profiler_state(profiler_name)
    if not state or not state.active then return nil end
    local profiler = game.create_profiler(true)
    profiler.restart()
    return profiler
end

---@param profiler_name string
---@param profiler? LuaProfiler
---@param hit? boolean
function profiler_utils.end_sample(profiler_name, profiler, hit)
    local state = get_profiler_state(profiler_name)
    if not state or not state.active then return end
    if profiler then
        profiler.stop()
        state.total.add(profiler)
    end
    state.samples = state.samples + 1
    if hit then
        state.hits = state.hits + 1
    end
end

function profiler_utils.on_tick()
    local profilers = ensure_profiler_storage()
    for profiler_name, state in pairs(profilers) do
        if state.active and game.tick >= state.end_tick then
            profiler_utils.stop(profiler_name, "到时自动停止")
        end
    end
end

return profiler_utils
