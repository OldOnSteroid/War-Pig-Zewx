local enums = {
    chest_types = {
        usz_rewardGizmo_1H = 150,
        usz_rewardGizmo_2H = 150,
        usz_rewardGizmo_ChestArmor = 75,
        usz_rewardGizmo_Rings = 75,
        usz_rewardGizmo_Amulet = 125,
        usz_rewardGizmo_Gloves = 75,
        usz_rewardGizmo_Legs = 75,
        usz_rewardGizmo_Boots = 75,
        usz_rewardGizmo_Helm = 75,
        usz_rewardGizmo_Uber = 250,
        Helltide_RewardChest_Random = 75,
    },
    helltide_tps = {
        {name = "Frac_Tundra_S", id = 0xACE9B, file = "menestad", maiden = "menestad_to_maiden", region = "Frac_"},
        {name = "Scos_Coast", id = 0x27E01, file = "marowen", maiden = "marowen_to_maiden", region = "Scos_"},
        {name = "Kehj_Oasis", id = 0xDEAFC, file = "ironwolfs", maiden = "ironwolfs_to_maiden", region = "Kehj_"},
        {name = "Hawe_Verge", id = 0x9346B, file = "wejinhani", maiden = "wejinhani_to_maiden", region = "Hawe_"},
        {name = "Step_South", id = 0x462E2, file = "jirandai", maiden = "jirandai_to_maiden", region = "Step_"}
    },
    -- Hardcoded maiden altar positions per helltide zone. Lifted from the archived
    -- helltide_maiden_auto plugin (verified against the last waypoint of each
    -- *_to_maiden.lua file — values match within ~5u). Looked up by current
    -- zone name in tasks/helltide.lua. Kehj has two zone names that share the
    -- same maiden, so both keys point at the same vec3.
    maiden_positions = {
        Frac_Tundra_S    = vec3:new(-1517.776733,  -20.840151, 105.299805),
        Scos_Coast       = vec3:new(-1982.549438, -1143.823364,  12.758240),
        Kehj_Oasis       = vec3:new(  120.874367,  -746.962341,   7.089052),
        Kehj_HighDesert  = vec3:new(  120.874367,  -746.962341,   7.089052),
        Hawe_Verge       = vec3:new(-1070.214600,   449.095276,  16.321373),
        Hawe_ZakFort     = vec3:new( -680.988770,   725.340576,   0.389648),
        Step_South       = vec3:new( -464.924530,  -327.773132,  36.178608),
    },
    -- Skin name for the maiden altar gizmo. Three altars per maiden site;
    -- inserting a heart into one consumes the heart and that altar goes
    -- non-interactable (or vanishes from the actor list). After all 3 are
    -- spent — across all players in the pile — the Maiden boss spawns.
    -- We chase whichever altar is closest + interactable; no per-spawn cap.
    maiden_altar_skin = "S04_SMP_Succuboss_Altar_A_Dyn",
}

return enums