import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { projectRoot } from './godot.mjs';

// Godot should never import JavaScript tooling or Playwright's bundled assets.
const directory = path.join(projectRoot, 'node_modules');
await mkdir(directory, { recursive: true });
await writeFile(path.join(directory, '.gdignore'), '# Development dependencies are not Godot project resources.\n', 'utf8');
