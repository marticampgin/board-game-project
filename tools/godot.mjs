import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/** Resolve without a shell so spaces and untrusted command arguments remain literal. */
export function findGodot() {
  const choices = [process.env.GODOT_BIN, 'Godot_v4.7.2-stable_win64_console.exe', 'godot', 'godot4'].filter(Boolean);
  for (const binary of choices) {
    const probe = spawnSync(binary, ['--version'], { encoding: 'utf8', windowsHide: true });
    if (!probe.error && probe.status === 0) {
      if (!probe.stdout.trim().startsWith('4.7.2.stable')) {
        throw new Error(`Expected Godot 4.7.2 stable; ${binary} reports ${probe.stdout.trim()}. Set GODOT_BIN.`);
      }
      return binary;
    }
  }
  throw new Error('Godot 4.7.2 stable was not found. Set GODOT_BIN to its console executable.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const action = process.argv[2] ?? 'test';
    const modes = {
      play: ['--path', projectRoot],
      check: ['--headless', '--path', projectRoot, '--editor', '--quit'],
      test: ['--headless', '--path', projectRoot, '--script', 'res://tests/run_tests.gd'],
    };
    if (!Object.hasOwn(modes, action)) throw new Error(`Unknown mode ${action}; use play, check, or test.`);
    if (!existsSync(path.join(projectRoot, 'project.godot'))) throw new Error('project.godot is missing.');
    const args = [...modes[action], ...(process.argv.length > 3 ? ['--', ...process.argv.slice(3)] : [])];
    if (action === 'play') {
      const result = spawnSync(findGodot(), args, { cwd: projectRoot, windowsHide: true, stdio: 'inherit' });
      if (result.error) throw result.error;
      process.exitCode = result.status ?? 1;
    } else {
      // Stream long simulation suites so developers can see the seed currently under test.
      const child = spawn(findGodot(), args, { cwd: projectRoot, windowsHide: true, stdio: ['inherit', 'pipe', 'pipe'] });
      let engineError = false;
      let diagnosticTail = '';
      const forward = (chunk, output) => {
        output.write(chunk);
        const text = diagnosticTail + chunk.toString();
        engineError ||= /(?:SCRIPT ERROR:|\bERROR:)/.test(text);
        diagnosticTail = text.slice(-80);
      };
      child.stdout.on('data', chunk => forward(chunk, process.stdout));
      child.stderr.on('data', chunk => forward(chunk, process.stderr));
      const status = await new Promise((resolve, reject) => {
        child.on('error', reject);
        child.on('close', resolve);
      });
      // Godot's editor can exit zero after a script import failure.
      process.exitCode = engineError ? 1 : (status ?? 1);
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
