# RUMBLE UNIFIED

RUMBLE UNIFIED brings Pokémon Rumble-style 3D Pokémon into Gen1Recomp, with model scaling, followers, visible overworld Pokémon, improved shading, and compatibility with other 3D model/rendering mods.

The goal is to provide one unified Pokémon presentation system that works across the overworld and battles while adding lightweight behaviors that make Kanto feel more alive.

## Main Features

### Pokémon Rumble Models

Replaces Pokémon with 3D Pokémon Rumble-style models while retaining the original Gen 1 gameplay and encounter system.

Assets are consolidated into packed files rather than hundreds of individual asset folders, significantly reducing the distributed mod size.

### True Scaling

Optional species-based scaling gives Pokémon more believable size differences while remaining practical for Pokémon Red's small maps.

Pokémon are grouped into manageable size ranges rather than using unrestricted Pokédex measurements.

Special Pokémon such as Onix and Gyarados can be considerably larger, while small Pokémon remain close to normal overworld scale.

True Scaling can be enabled or disabled from RUMBLE SETTINGS.

### Followers

Adds support for up to six Pokémon following the player in the overworld.

Follower movement includes spacing and overlap handling to keep parties organized while walking through maps and connections.

Follower count can be selected from:

`0 / 1 / 2 / 3 / 4 / 5 / 6`

### Visible Overworld Pokémon

Wild Pokémon from the map's existing encounter table can appear physically in the overworld.

Entering a map immediately populates the area so the player does not have to watch Pokémon spawn one at a time. Later replacement spawns use small habitat-based animations.

Flying Pokémon can descend into the area, ground Pokémon can emerge from grass or nearby vegetation, cocoons such as Metapod and Kakuna remain stationary, and levitating Pokémon hover rather than walk.

Touching a visible Pokémon starts an encounter with that Pokémon.

Overworld Wilds can be completely disabled from RUMBLE SETTINGS.

### Wildlife & Flying Behavior

Visible Pokémon use lightweight ecology behaviors to make the overworld less static.

Bird Pokémon fly in species-appropriate flocks, circle, perch, swoop and occasionally interact with smaller Pokémon. Pidgey and Spearow can swoop but cannot carry prey, while larger eligible birds can.

Butterfree, Beedrill and Venomoth roam locally at lower altitude in small groups. Zubat and Golbat form low-flying cave swarms.

Ground Pokémon can occasionally chase, flee, interact with rivals or form small play groups. Caterpie, Weedle and Rattata can participate in predator/prey interactions.

These systems are intentionally lightweight and do not replace the game's normal encounter tables.

### Hovering & Ghost Pokémon

Magnemite, Magneton, Koffing, Weezing, Gastly and Haunter use dedicated hovering movement rather than walking along the ground.

Gastly and Haunter can also rise from the floor in cemetery environments such as Pokémon Tower when appearing as replacement overworld spawns.

### Shading & Toon Outline

RUMBLE UNIFIED includes rendering options intended to make the models fit naturally with Gen1Recomp's 3D presentation.

Toon outlines can be enabled or disabled, allowing either a cleaner 3D appearance or a more stylized Pokémon look.

Model quality can also be adjusted through the Poly Quality option for a balance between appearance and performance.

### Battle Models

Rumble models can also be used during Pokémon battles.

The Battle Scene setting allows switching between:

`Rumble / Default`

This makes it possible to use the overworld features while retaining the preferred battle presentation.

## Compatibility

RUMBLE UNIFIED is designed to coexist with the major Gen1Recomp Pokémon rendering/model options rather than requiring one specific renderer.

### Pokémon Quest Models

Compatible with the Pokémon Quest model setup. RUMBLE UNIFIED's gameplay systems—including followers, overworld wilds, flying behavior and ecology—can continue to operate when Quest models are being used.

### Pokémon Stadium Models

Compatible with the separate Pokémon Stadium model replacement setup.

Stadium models can replace the visual Pokémon models while the unified overworld systems continue handling followers, scaling, visible wild Pokémon and ecology behavior.

### Other Renderers

The mod has also been developed with Gen1Recomp's alternate 3D rendering setups in mind, including Dramaless/Potato Voxel/Voxel Ascendant-style configurations where supported.

The behavioral systems are kept separate from the model source whenever possible so changing the visual model set does not require rebuilding the entire ecology system.

## RUMBLE SETTINGS

Major features are controlled from a single RUMBLE SETTINGS menu:

`Followers — 0–6`

`Overworld Wilds — Yes / No`

`Flying — Yes / No`

`Toon Outline — On / Off`

`True Scaling — On / Off`

`Poly Quality — Low / High`

`Battle Scene — Rumble / Default`

## Performance

The current build uses consolidated asset packs and Gen 1-only required resources to reduce file count and overall mod size.

Overworld populations are limited, distant Pokémon are removed when no longer needed, and ecology behaviors are designed to remain relatively lightweight.

## Summary

RUMBLE UNIFIED is primarily a complete 3D Pokémon presentation system for Gen1Recomp:

**Rumble models + True Scaling + Followers + Visible Overworld Pokémon + Flying/Ecology + Shading + Battle Models + Quest/Stadium compatibility.**

The ecology features are there to complement those systems rather than turn Pokémon Red into a completely different game.
