local function create_digitizer_logistic_chest(base_name, new_name, icon, order)
    local entity = table.deepcopy(data.raw["logistic-container"][base_name])
    entity.name = new_name
    entity.icon = icon
    entity.icon_size = 64
    entity.icon_mipmaps = 4
    entity.minable = {mining_time = 0.2, result = new_name}
    entity.inventory_size = 48

    local item = {
        type = "item",
        name = new_name,
        icon = icon,
        icon_size = 64,
        icon_mipmaps = 4,
        subgroup = "logistic-network",
        order = order,
        place_result = new_name,
        stack_size = 50
    }

    local recipe = {
        type = "recipe",
        name = new_name,
        enabled = false,
        ingredients = {
            {type = "item", name = "digitizer-chest", amount = 1},
            {type = "item", name = base_name, amount = 1},
            {type = "item", name = "advanced-circuit", amount = 4}
        },
        results = {{type = "item", name = new_name, amount = 1}}
    }

    return entity, item, recipe
end

local provider_entity, provider_item, provider_recipe = create_digitizer_logistic_chest(
    "passive-provider-chest",
    "digitizer-passive-provider-chest",
    "__base__/graphics/icons/passive-provider-chest.png",
    "c[signal]-a[digitizer-passive-provider-chest]"
)

local requester_entity, requester_item, requester_recipe = create_digitizer_logistic_chest(
    "requester-chest",
    "digitizer-requester-chest",
    "__base__/graphics/icons/requester-chest.png",
    "c[signal]-b[digitizer-requester-chest]"
)

local matter_digitization = data.raw.technology["matter-digitization"]
if matter_digitization and matter_digitization.effects then
    table.insert(matter_digitization.effects, {type = "unlock-recipe", recipe = "digitizer-passive-provider-chest"})
    table.insert(matter_digitization.effects, {type = "unlock-recipe", recipe = "digitizer-requester-chest"})
end

data:extend{
    provider_entity,
    provider_item,
    provider_recipe,
    requester_entity,
    requester_item,
    requester_recipe
}
