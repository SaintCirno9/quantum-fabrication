local function create_digitizer_logistic_icons(base_icon)
    return {
        {
            icon = base_icon,
            icon_size = 64,
            icon_mipmaps = 4,
        },
        {
            icon = "__quantum-fabricator__/graphics/icons/digitizer-chest.png",
            icon_size = 64,
            icon_mipmaps = 4,
            scale = 0.5,
            shift = {8, 8},
        },
    }
end

local function create_digitizer_logistic_chest(base_name, new_name, icon, order)
    local entity = table.deepcopy(data.raw["logistic-container"][base_name])
    entity.name = new_name
    entity.icon = nil
    entity.icons = create_digitizer_logistic_icons(icon)
    entity.minable = {mining_time = 0.2, result = new_name}
    entity.inventory_size = 48

    local item = {
        type = "item",
        name = new_name,
        icon = nil,
        icons = create_digitizer_logistic_icons(icon),
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
