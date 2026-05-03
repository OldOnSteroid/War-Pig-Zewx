local town = {}

town.list = {
    cerrigar = {
        id = 'cerrigar',
        display_name = 'Cerrigar',
        zone_name = 'Scos_Cerrigar',
        waypoint_sno = 0x76D58,
        npc_enum = {
            BLACKSMITH = 'TWN_Scos_Cerrigar_Crafter_Blacksmith',
            JEWELER = 'TWN_Scos_Cerrigar_Crafter_Jeweler',
            SILVERSMITH = 'TWN_Scos_Cerrigar_Vendor_Silversmith',
            WEAPON = 'TWN_Scos_Cerrigar_Vendor_Weapons',
            STASH = 'Stash',
            GAMBLER = 'TWN_Scos_Cerrigar_Vendor_Gambler',
            ALCHEMIST = 'TWN_Scos_Cerrigar_Crafter_Alchemist',
            HEALER = 'TWN_Scos_Cerrigar_Service_Healer',
            PIT_TOWER = 'TWN_Kehj_IronWolves_PitKey_Crafter',
            PORTAL = 'TownPortal',
        },
        npc_loc_enum = {
            BLACKSMITH = vec3:new(-1685.359375, -596.5830078125, 37.8603515625),
            SILVERSMITH = vec3:new(-1676.4697265625, -581.1435546875, 37.861328125),
            WEAPON = vec3:new(-1658.69921875, -620.0205078125, 37.888671875),
            STASH = vec3:new(-1684.1199951172, -592.11602783203, 37.606800079346),
            GAMBLER = vec3:new(-1675.5791015625, -599.30859375, 36.9267578125),
            ALCHEMIST = vec3:new(-1671.6494140625, -607.0947265625, 37.7255859375),
            HEALER = vec3:new(-1671.0791015625, -600.92578125, 36.9130859375),
            PORTAL = vec3:new(-1656.7141113281, -598.21716308594, 36.28515625),
        },
        npc_via_loc_enum = {},
        walls = {},
        reset_positions = {
            default                 = vec3:new(-1661.931640625, -596.4111328125, 36.90625),
            stash_restock_stocktake = vec3:new(-1684.3427734375, -595.40625, 37.6484375),
            salvage                 = vec3:new(-1680.57421875, -597.4794921875, 37.572265625),
            sell_gamble             = vec3:new(-1670.6953125, -598.2548828125, 36.8857421875),
        },
    },
    temis = {
        id = 'temis',
        display_name = 'Temis',
        zone_name = 'Skov_Temis',
        waypoint_sno = 0x1CE51E,
        npc_enum = {
            BLACKSMITH = 'TWN_Skov_Temis_Crafter_Blacksmith',
            JEWELER = 'TWN_Skov_Temis_Crafter_Jeweler',
            SILVERSMITH = 'TWN_Skov_Vendor_Silversmith',
            WEAPON = 'TWN_Skov_Temis_Vendor_Weapons',
            STASH = 'Stash',
            GAMBLER = 'TWN_Skov_Temis_Vendor_Gambler',
            ALCHEMIST = 'TWN_Skov_Temis_Crafter_Alchemist',
            HEALER = 'TWN_Skov_Temis_Service_Healer',
            PIT_TOWER = 'TWN_Kehj_IronWolves_PitKey_Crafter',
            PORTAL = 'TownPortal',
        },
        npc_loc_enum = {
            BLACKSMITH = vec3:new(2575.3134765625, -481.890625, 31.5029296875),
            JEWELER = vec3:new(2599.4873046875, -481.2578125, 30.5166015625),
            SILVERSMITH = vec3:new(2634.7548828125, -477.6875, 28.919921875),
            WEAPON = vec3:new(2621.7822265625, -456.6396484375, 29.5615234375),
            STASH = vec3:new(2574.0361328125, -486.248046875, 31.5029296875),
            GAMBLER = vec3:new(2566.2158203125, -478.7431640625, 30.927734375),
            ALCHEMIST = vec3:new(2599.4521484375, -483.7548828125, 30.5166015625),
            HEALER = vec3:new(2590.2822265625, -466.7939453125, 30.927734375),
            PIT_TOWER = vec3:new(2572.708984375, -498.4921875, 30.5166015625),
            PORTAL = vec3:new(2578.1103515625, -482.2646484375, 31.5029296875),
        },
        npc_via_loc_enum = {
            GAMBLER = vec3:new(2568.7685546875, -471.8046875, 30.5166015625),
            JEWELER = vec3:new(2621.5869140625, -500.4306640625, 28.919921875),
        },
        walls = {
            {
                inside_anchor = vec3:new(2566.2158203125, -478.7431640625, 30.927734375),
                via = vec3:new(2568.7685546875, -471.8046875, 30.5166015625),
                radius = 5,
            },
        },
        reset_positions = {
            default                 = vec3:new(2578.1103515625, -482.2646484375, 31.5029296875),
            stash_restock_stocktake = vec3:new(2574.0361328125, -486.248046875, 31.5029296875),
            salvage                 = vec3:new(2575.3134765625, -481.890625, 31.5029296875),
            sell_gamble             = vec3:new(2566.2158203125, -478.7431640625, 30.927734375),
        },
    },
}

town.default = 'temis'

town.options = { 'Temis', 'Cerrigar' }
town.option_to_id = { [0] = 'temis', [1] = 'cerrigar' }
town.id_to_option = { temis = 0, cerrigar = 1 }

function town.get(choice)
    return town.list[choice] or town.list[town.default]
end

return town
