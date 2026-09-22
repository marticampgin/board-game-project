import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const binary = process.env.GODOT_BIN || (process.platform === 'win32' ? 'Godot_v4.7.2-stable_win64_console.exe' : 'godot');
await mkdir(path.join(root, 'build/web'), { recursive: true });
await writeFile(path.join(root, 'build/.gdignore'), '');
await writeFile(path.join(root, 'node_modules/.gdignore'), '');
for (const args of [['--headless', '--path', root, '--editor', '--quit'], ['--headless', '--path', root, '--export-debug', 'Web', 'build/web/index.html']]) {
  const result = spawnSync(binary, args, { cwd: root, encoding: 'utf8', timeout: 120_000 });
  process.stdout.write(result.stdout || '');
  process.stderr.write(result.stderr || '');
  if (result.error || result.status !== 0 || /SCRIPT ERROR|Parse Error|Failed to load script/.test(`${result.stdout}${result.stderr}`)) {
    console.error(result.error || 'Godot export failed.');
    process.exit(result.status || 1);
  }
}
