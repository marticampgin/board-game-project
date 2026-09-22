# Assets and tools

The board, terrain, landmarks, hero silhouettes, paths and markers are procedural primitive meshes authored in `scripts/presentation/board_view.gd`. No downloaded art, music, sound effects or third-party Godot addons are included. The interface uses Godot's bundled default font.

Runtime: [Godot Engine](https://godotengine.org/), pinned to 4.7.2 stable Standard and its matching export templates. Engine and bundled dependency notices are available through the [Godot license page](https://godotengine.org/license/).

Browser testing: [Playwright](https://github.com/microsoft/playwright), a development dependency only. JavaScript tooling does not implement game rules and is excluded from the game exports.

The supplied master specification remains the design source of truth. Game title and lore are provisional as stated there.
