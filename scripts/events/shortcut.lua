local handlers = {}

function handlers.on_lua_shortcut(event)
    local player = game.get_player(event.player_index)
    if not player then return end
    if event.prototype_name == "qf-fabricator-gui" then
        toggle_qf_gui(player)
    elseif event.prototype_name == "qf-fabricator-enable" then
        storage.qf_enabled = not storage.qf_enabled
        for _, current_player in pairs(game.players) do
            current_player.set_shortcut_toggled("qf-fabricator-enable", storage.qf_enabled)
        end
    end
end

return handlers
