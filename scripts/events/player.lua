local flib_dictionary = require("__flib__.dictionary")
local tracking = require("scripts/tracking_utils")

local handlers = {}

local Digitizer_queue_display_names = {
    signal = "信号",
    active = "活跃",
    idle = "空闲",
    long_idle = "深度空闲",
}

local function get_digitizer_hover_text(entity_data)
    local queue_name = entity_data.queue_name or "active"
    local full_pass_seconds = tracking.get_digitizer_queue_full_pass_seconds(queue_name)
    local queue_text = "队列: " .. (Digitizer_queue_display_names[queue_name] or queue_name) .. " " .. string.format("%.2fS", full_pass_seconds)
    local container_fluid = entity_data.container_fluid
    if not container_fluid or not container_fluid.valid then
        return queue_text
    end

    local fluid_lines = {}
    local index = 1
    for fluid_name, amount in pairs(container_fluid.get_fluid_contents()) do
        fluid_lines[index] = fluid_name .. " : " .. string.format("%.1f", amount)
        index = index + 1
    end
    if index == 1 then
        return queue_text
    end
    table.sort(fluid_lines)
    return queue_text .. " | " .. table.concat(fluid_lines, " | ")
end

local function destroy_digitizer_hover_text(player_index)
    local player_data = storage.player_gui[player_index]
    if not player_data then return end

    local render_id = player_data.digitizer_hover_render_id
    if render_id then
        local render_object = rendering.get_object_by_id(render_id)
        if render_object then
            render_object.destroy()
        end
    end

    player_data.digitizer_hover_render_id = nil
    player_data.digitizer_hover_unit_number = nil
    player_data.digitizer_hover_text = nil
end

local function update_digitizer_hover_text(player_index)
    local player = game.get_player(player_index)
    if not player or not player.valid then return end

    local player_data = storage.player_gui[player_index]
    if not player_data then return end

    local selected = player.selected
    if not selected or not selected.valid then
        destroy_digitizer_hover_text(player_index)
        return
    end

    local entity_data = tracking.get_entity_data(selected)
    if not entity_data or entity_data.name ~= "digitizer-chest" then
        destroy_digitizer_hover_text(player_index)
        return
    end

    local queue_text = get_digitizer_hover_text(entity_data)
    local render_object = player_data.digitizer_hover_render_id and rendering.get_object_by_id(player_data.digitizer_hover_render_id)

    if not render_object or player_data.digitizer_hover_unit_number ~= selected.unit_number then
        destroy_digitizer_hover_text(player_index)
        render_object = rendering.draw_text{
            text = queue_text,
            surface = selected.surface,
            target = {
                entity = selected,
                offset = {0, -1.75},
            },
            color = {r = 1, g = 1, b = 1},
            alignment = "center",
            vertical_alignment = "middle",
            players = {player_index},
            scale = 1.1,
        }
        player_data.digitizer_hover_render_id = render_object.id
        player_data.digitizer_hover_unit_number = selected.unit_number
        player_data.digitizer_hover_text = queue_text
        return
    end

    if player_data.digitizer_hover_text ~= queue_text then
        render_object.text = queue_text
        player_data.digitizer_hover_text = queue_text
    end
end

function handlers.on_selected_entity_changed(event)
    update_digitizer_hover_text(event.player_index)
end

function handlers.on_pre_player_left_game(event)
    destroy_digitizer_hover_text(event.player_index)
end

function handlers.refresh_digitizer_hover_texts()
    for _, player in pairs(game.connected_players) do
        update_digitizer_hover_text(player.index)
    end
end

---@param player_index uint
---@param sort_type "item_name"|"amount"|"localised_name"
function handlers.sort_ingredients(player_index, sort_type)
    for _, recipe in pairs(storage.unpacked_recipes) do
        if sort_type == "item_name" then
            table.sort(storage.unpacked_recipes[recipe.name].ingredients, function(a, b) return a.name < b.name end)
        elseif sort_type == "amount" then
            table.sort(storage.unpacked_recipes[recipe.name].ingredients, function(a, b) return a.amount < b.amount end)
        elseif sort_type == "localised_name" then
            local locale = game.get_player(player_index).locale
            table.sort(storage.unpacked_recipes[recipe.name].ingredients, function(a, b) return get_translation(player_index, a.name, "unknown", locale) < get_translation(player_index, b.name, "unknown", locale) end)
        end
    end
end

function handlers.on_player_joined_game(event)
    flib_dictionary.on_player_joined_game(event)
end

function handlers.on_player_fast_transferred(event)
    if not event.from_player then return end
    local entity = event.entity
    if not entity or not entity.valid then return end

    if entity.name ~= "digitizer-chest"
        and entity.name ~= "digitizer-passive-provider-chest"
        and entity.name ~= "digitizer-requester-chest" then
        return
    end

    local entity_data = tracking.get_entity_data(entity)
    if not entity_data then
        tracking.create_tracked_request({request_type = "entities", entity = entity, player_index = event.player_index})
        entity_data = tracking.get_entity_data(entity)
    end
    if not entity_data then return end

    tracking.invalidate_digitizer_chest_processable_cache(entity_data, true)
end

return handlers
