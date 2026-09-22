# Presentation profile

Run the native renderer profile on Windows from the project folder:

```powershell
.\tools\profile_render.ps1
# Optional engine location:
.\tools\profile_render.ps1 -Godot 'C:\Godot\Godot_v4.7.2-stable_win64_console.exe'
```

The helper opens the actual Main scene in a hidden, offscreen native window at 1920×1080. It disables vsync, warms up for two seconds, then measures ten seconds using a monotonic wall clock. A bot submits an ordinary legal command every 0.20 seconds; each accepted command refreshes the actual interface and board. Rendering uses the GPU and Compatibility renderer, not `--headless`.

Generated output is ignored by Git: `artifacts/presentation_profile.json`, `.png`, `.stdout.log`, and `.stderr.log`. The command fails on engine errors, rejected bot commands, a timeout, or missing rendered frames.

## Recorded run — 2026-09-22

Godot 4.7.2 stable, Windows, NVIDIA GeForce RTX 4070, OpenGL 3.3 / driver 591.86. The run accepted 59 commands and reached round three.

| Measurement | Result |
| --- | ---: |
| Sample duration | 10.001 s |
| Average frame rate | 1,102 FPS |
| Median / 95th percentile frame time | 0.815 / 0.931 ms |
| Median / maximum draw calls per frame | 811 / 851 |
| Median / 95th percentile command plus UI refresh | 5.543 / 13.881 ms |
| Last board reconciliation | 0.876 ms |
| Live nodes at end | 782 |
| Shared cached materials / meshes | 82 / 41 |

These are uncapped native, offscreen results on the named GPU. They demonstrate substantial room above the 60 FPS target on this machine. They are not a measurement of every mid-range desktop, a visible window's compositor latency, or Chromium's software SwiftShader renderer. Browser layout and interaction checks are separate.

The board reuses meshes and materials, uses one mesh per hex outline, and rebuilds static landmarks, routes, and world overlays only when their state changes. Hero movement follows approved paths; interrupted animations snap to the authoritative destination. The renderer consumes no gameplay RNG. `board.debug_metrics()` exposes cache counts, view counts, and the last reconciliation time for inspection.
