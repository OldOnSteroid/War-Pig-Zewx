-- List of pylons with their priorities
local pylons = {
    "ChaoticOffering",         -- Chaos Rifts
    "AetherGoblins",           -- Monsters now have 100% additional health, Aether Events can spawn Aether Goblins
    "ThrivingMasses",          -- Masses deal unavoidable damage, Wave start, spawn an Aetheric Mass
    "FiendishMasses",          -- Masses spawn aether fiend on death, Aether Masses grant +3 Aether.
	"FiendishLegions",         -- Elite and Aether Fiend damage +25%, Aether Fiends have a chance to spawn in place of Elites.
    "BlisteringHordes",        -- Normal Monster Spawn Aether Events 50% Faster
	"SurgingElites",           -- Chance for Elite Doubled, Aether Fiends grant +2 Aether
    "BlightedVerge",           -- Masses spawn more often, Soulspires spawn less often.
    "UnstoppableElites",       -- Elites are Unstoppable, Aether Fiends grant +2 Aether
    "EmpoweredElites",         -- Elite damage +25%, Aether Fiends grant +2 Aether
    "MassingMasses",           -- Aetheric Masses have 100% additional health, Aetheric Masses now have a chance to spawn more Aetheric Masses on Death.
    "GorgingMasses",           -- Slaying Aetheric Masses slows you, chance to spawn another mass on death
    "PuffingMasses",           -- Damage from Masses applies Vulnerable, Masses drop +1 Aether per Offering, doubled for Mass Offerings
    "EmpoweredMasses",         -- Aetheric Mass damage: +25%, Aetheric Mass grants +1 Aether
    "ColossalFiends",          -- Aether Lords cause Hellfire to erupt around them, Aether Fiends spawn as Aether Lords and drop 3x Aether
    "GestatingMasses",         -- Masses spawn an Aether lord on Death, Aether Lords Grant +3 Aether
    "InfernalLords",           -- Aether Lords Now Spawn, they grant +3 Aether
    "RuthlessLords",           -- Aether Lords gain health and damage for each spawn, Aether Lords grant +5 aether
	"InfernalStalker",         -- An Infernal demon has your scent, Slay it to gain +100 Aether
    "HellishMasses",           -- Masses explode on death, Masses have a chance to spawn Hellborne on death
    "SummonedHellborne",       -- Hellborne can now spawn with Aether Events, Hellborne grant +1 additional Aether.
    "AmbushingHellborne",      -- Hellborne can now spawn as ambushes, Hellborne grant +1 additional Aether.
    "ForceChaosWaves",         -- Force ALL waves to be Chaos Waves
    "ForceNextChaosWave",      -- Force next offering to have a Chaos Wave
    "ForceNoChaosWaves",       -- Turn off all access to Chaos Waves
    "HellsWrath",              -- Hellfire intensifies, At the end of each wave spawn 15-25 Aether.
    "SkulkingHellborne",       -- Hellborne Hunting You, Hellborne +1 Aether
    "SurgingHellborne",        -- +1 Hellborne when Spawned, Hellborne Grant +1 Aether
    "EmpoweredHellborne",      -- Hellborne +25% Damage, Hellborne grant +1 Aether
    "RagingHellfire",          -- Hellfire rains upon you, at the end of each wave spawn 3-9 Aether
    "InvigoratingHellborne",   -- Hellborne Damage +25%, Slaying Hellborne Invigorates you
    "EmpoweredCouncil",        -- Fell Council +50% Damage, Council grants +15 Aether
    "IncreasedEvadeCooldown",  -- Increase Evade Cooldown +2 Sec, Council grants +15 Aether
    "IncreasedPotionCooldown", -- Increase potion cooldown +2 Sec, Council Grants +15 Aether
    "ReduceAllResistance",     -- Reduce All Resist -10%, Council grants +15 Aether
    "MeteoricHellborne",       -- Hellfire now spawns Hellborne, +1 Aether
    "DeadlySpires",            -- Soulspires Drain Health, Soulspires grant +2 Aether
    "AetherRush",              -- Normal Monsters Damage +25%, Gathering Aether Increases Movement Speed
    "EnergizingMasses",        -- Slaying Aetheric Masses slow you, While slowed this way, you have UNLIMITED RESOURCES
    "GreedySpires",            -- Soulspire requires 2x kills, Soulspires grant 2x Aether
    "UnstableFiends",          -- Elite Damage +25%, Aether Fiends explode and damage FOES
	"EnduringLords",           -- Aether Lords no longer despawn at round end, Aether Lords health is greatly increased.
    "CorruptingSpires",        -- Soulspires empower nearby foes, they also pull enemies inward
    "BlightedSpires",          -- Soulspires no longer invigorate, Soulspires spawns aether event.
    "TransitiveSpires",        -- Soulspires have double health, While standing near a Soulspire, all enemies killed count as in-range
    "CovetedSpires",           -- Soulspires spawn less often, Soulspires grant 2x additional Aether.
    "TreasuredSpires",         -- Soulspires spawn less often, Soulspires grant 2.25x additional Aether.
    "PreciousSpires",          -- Soulspires spawn less often, Soulspires grant 2.5x additional Aether.
    "DesolateVerge",           -- Soulspires spawn more often, Masses spawn less often.
    "AnchoredMasses",          -- Aetheric Masses have greatly increased attack speed, Aetheric Masses now have a chance to spawn a Soulspire on death.
}

return pylons
