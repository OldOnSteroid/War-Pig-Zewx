-- ============================================================
--  Reaper - data/enums.lua
-- ============================================================

local enums = {}

-- -------------------------------------------------------
-- Altar actor skin names (interact to summon the boss)
-- -------------------------------------------------------
enums.altar_names = {
    "Boss_WT4_Varshan",
    "Boss_WT3_Varshan",
    "Boss_WT4_Duriel",
    "Boss_WT4_PenitantKnight",    -- WT4 altar (old/typo spelling — keep for safety)
    "Boss_WT4_PenitentKnight",    -- WT4 altar (correct spelling)
    "Boss_WT3_PenitentKnight",    -- WT3 altar
    "Boss_WT4_Andariel",
    "Boss_WT4_MegaDemon",
    "Boss_WT4_S2VampireLord",
    "Boss_WT5_Urivar",
    "Boss_WT_Belial",
    "Boss_WT5_Harbinger",
    "Boss_EGB_Butcher",
}

-- -------------------------------------------------------
-- Boss definitions
-- Belial is included for farming runs but excluded from
-- the Belial chest boss-selection list (it's the host boss).
-- harbinger and urivar are WT5 variants accessible via Belial chest.
-- -------------------------------------------------------
enums.boss_zones = {
    { id="duriel",    zone_prefix="Boss_WT4_Duriel",         label="Duriel"              },
    { id="andariel",  zone_prefix="Boss_WT4_Andariel",       label="Andariel"            },
    { id="varshan",   zone_prefix="_Varshan",                 label="Varshan"             },
    { id="grigoire",  zone_prefix="Boss_WT3_PenitentKnight", label="Grigoire"            },
    { id="zir",       zone_prefix="Boss_WT4_S2VampireLord",  label="Lord Zir"            },
    { id="beast",     zone_prefix="Boss_WT4_MegaDemon",      label="Beast in Ice"        },
    { id="harbinger", zone_prefix="Boss_WT5_Harbinger",      label="Harbinger of Hatred" },
    { id="urivar",    zone_prefix="Boss_WT5_Urivar",         label="Urivar"              },
    { id="butcher",   zone_prefix="S12_Boss_Butcher",        label="Bloody Butcher"      },
    { id="belial",    zone_prefix="Boss_Kehj_Belial",        label="Belial"              },
}

-- Bosses selectable in the Belial chest UI (excludes Belial itself).
--
-- Order mirrors the in-game chest dialog after a recent game update:
--   Page 1 (no scroll): Beast, Butcher, Grigoire, Urivar, Varshan,
--                       Lord Zir, Andariel
--   Page 2 (after scroll): Varshan, Lord Zir, Andariel, Astaroth, Bartuc,
--                          Duriel, Harbinger of Hatred
-- Bosses that appear on BOTH pages (Varshan / Zir / Andariel) are
-- targeted via page 1 (no scroll required), so we list them only once.
-- See tasks/belial_chest.lua for the page assignment + click coords.
enums.belial_chest_bosses = {
    { id="beast",     label="Beast in the Ice"    },
    { id="butcher",   label="Bloody Butcher"      },
    { id="grigoire",  label="Grigoire"            },
    { id="urivar",    label="Urivar"              },
    { id="varshan",   label="Varshan"             },
    { id="zir",       label="Lord Zir"            },
    { id="andariel",  label="Andariel"            },
    { id="astaroth",  label="Astaroth"            },
    { id="bartuc",    label="Bartuc"              },
    { id="duriel",    label="Duriel"              },
    { id="harbinger", label="Harbinger of Hatred" },
}

-- -------------------------------------------------------
-- Town / utility positions
-- -------------------------------------------------------
enums.positions = {
    portal_position = vec3:new(-1656.7141113281, -598.21716308594, 36.28515625),

    boss_room = {
        ["Boss_WT4_S2VampireLord"]  = vec3:new(-10.556, -10.419, -3.120),
        ["Boss_WT4_Duriel"]         = vec3:new(-3.616,   -2.309,  -3.689),
        ["Boss_WT3_PenitentKnight"] = vec3:new( 2.0051,   1.5871,  2.0),
        ["Boss_WT4_Andariel"]       = vec3:new( 8.2821,  -8.7344, -6.223),
        ["Boss_WT4_MegaDemon"]      = vec3:new( 4.9245,   5.3086,  0.127),
        ["_Varshan"]                = vec3:new(-3.2805,  -3.1949, -3.304),
        ["Boss_WT5_Harbinger"]      = vec3:new( 2.9,     15.0,    0.0),
    },
}

function enums.positions.getBossRoomPosition(world_name)
    local pos = enums.positions.boss_room[world_name]
    return pos or vec3:new(0, 0, 0)
end

-- -------------------------------------------------------
-- Chest skin name patterns
-- -------------------------------------------------------
enums.chest_patterns = {
    "^EGB_Chest",
    "^Boss_WT_Belial_",
    "^Chest_Boss",
    -- Doom/seasonal "S12_Prop_Theme_Chest_" was removed from D4 (2026-05-03)
    -- and is intentionally absent from this list; do not add back.
}

-- -------------------------------------------------------
-- Misc skin names
-- -------------------------------------------------------
enums.misc = {
    portal           = "TownPortal",
    suppressor       = "monsterAffix_suppressor_barrier",
    dungeon_entrance = "Portal_Dungeon_Generic",
}

-- -------------------------------------------------------
-- Waypoint IDs
-- -------------------------------------------------------
enums.waypoints = {
    GATES_OF_THE_NECROPOLIS  = 0x182415,
    KURAST_DOCKS             = 0x181CE3,
    SAMUK                    = 0x192273,
    KURAST_BAZAR             = 0x1EAACC,
    THE_DEN                  = 0x156710,
    GEA_KUL                  = 0xB66AB,
    IRON_WOLVES_ENCAMPMENT   = 0xDEAFC,
    IMPERIAL_LIBRARY         = 0x10D63D,
    DENSHAR                  = 0x8AF45,
    TARSARAK                 = 0x8C7B7,
    ZARBINZET                = 0xA46E5,
    JIRANDAI                 = 0x462E2,
    ALZUUDA                  = 0x792DA,
    WEJINHANI                = 0x9346B,
    RUINS_OF_RAKHAT_KEEP     = 0xF77C2,
    THE_TREE_OF_WHISPERS     = 0x90557,
    BACKWATER                = 0xA491F,
    KED_BARDU                = 0x34CE7,
    HIDDEN_OVERLOOK          = 0x460D4,
    FATES_RETREAT            = 0xEEEB3,
    FAROBRU                  = 0x2D392,
    TUR_DULRA                = 0x8D596,
    MAROWEN                  = 0x27E01,
    BRAESTAIG                = 0x7FD82,
    CERRIGAR                 = 0x76D58,
    FIREBREAK_MANOR          = 0x803EE,
    CORBACH                  = 0x22EBE,
    TIRMAIR                  = 0xB92BE,
    UNDER_THE_FAT_GOOSE_INN  = 0xEED6B,
    MENESTAD                 = 0xACE9B,
    KYOVASHAD                = 0x6CC71,
    BEAR_TRIBE_REFUGE        = 0x8234E,
    MARGRAVE                 = 0x90A86,
    YELESNA                  = 0x833F8,
    NEVESK                   = 0x6D945,
    NOSTRAVA                 = 0x8547F,
}

return enums
