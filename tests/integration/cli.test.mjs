import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { projectRoot, findGodot } from '../../tools/godot.mjs';

function invoke(state, args, expected = 0) {
  const run = spawnSync(process.execPath, ['tools/realm.mjs', ...args, '--state', state, '--json'], { cwd: projectRoot, encoding: 'utf8', windowsHide: true, timeout: 120000, maxBuffer: 16 * 1024 * 1024 });
  assert.equal(run.status, expected, `${args.join(' ')}\n${run.stdout}\n${run.stderr}\n${run.error ?? ''}`);
  return JSON.parse(run.stdout);
}

test('CLI persists shared rules, records rejected attempts, simulates and verifies replay', { timeout: 180000 }, () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'realm-cli-test-'));
  const state = path.join(directory, 'match.json');
  try {
    const created = invoke(state, ['new', '--seed', '20260922']);
    assert.equal(Object.keys(created.snapshot.map.hexes).length, 61);
    const original = readFileSync(state, 'utf8');
    const rejected = invoke(state, ['move', 'p1', '0,0'], 2);
    assert.equal(rejected.result.reason_code, 'WRONG_PHASE');
    assert.equal(readFileSync(state, 'utf8'), original, 'Rejected actions must not rewrite the persisted snapshot');
    invoke(state, ['advance', '--expected-version', '99999'], 2);
    const advanced = invoke(state, ['advance']);
    assert.equal(advanced.snapshot.phase, 'planning');
    const commandFile = path.join(directory, 'plan.json');
    writeFileSync(commandFile, JSON.stringify({ type: 'submit_plan', player_id: 'p1', plan: {} }));
    invoke(state, ['command', '--file', commandFile]);
    const simulated = invoke(state, ['simulate', '--rounds', '3']);
    assert.equal(simulated.snapshot.round_number, 4);
    assert.equal(simulated.snapshot.phase, 'world');
    assert.ok(simulated.action_counts.move > 0);
    assert.ok(simulated.action_counts.capture > 0);
    const beforeReplay = readFileSync(state, 'utf8');
    const replay = invoke(state, ['replay']);
    assert.equal(replay.matches, true);
    assert.equal(replay.replay_checksum, simulated.checksum);
    assert.equal(readFileSync(state, 'utf8'), beforeReplay, 'Replay is read-only');
    const entries = invoke(state, ['logs', '--limit', '1000']);
    assert.equal(entries.filter(entry => !entry.accepted).length, 2);
    assert.ok(entries.some(entry => entry.events.some(event => event.type === 'IncomeGranted')));
    const rejectedOnly = invoke(state, ['logs', '--rejected', '--limit', '1000']);
    assert.equal(rejectedOnly.length, 2);
    assert.ok(rejectedOnly.every(entry => !entry.accepted));
    const incomeOnly = invoke(state, ['logs', '--event', 'IncomeGranted', '--limit', '1000']);
    assert.equal(incomeOnly.length, 3);
    assert.ok(incomeOnly.every(entry => entry.events.some(event => event.type === 'IncomeGranted')));
    for (const entry of entries) {
      assert.match(entry.checksum_before, /^[a-f0-9]{64}$/);
      assert.match(entry.checksum_after, /^[a-f0-9]{64}$/);
      assert.ok(entry.rng_before && entry.rng_after);
      if (!entry.accepted) assert.equal(entry.checksum_before, entry.checksum_after);
    }
    assert.ok(JSON.parse(readFileSync(`${state}.bak`, 'utf8')).state_version < simulated.snapshot.state_version);
  } finally {
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(tmpdir()));
    assert.ok(path.basename(directory).startsWith('realm-cli-test-'));
    rmSync(directory, { recursive: true, force: true });
  }
});

test('headless runner deliberately returns exit 1 when an assertion fails', { timeout: 180000 }, () => {
  const run = spawnSync(findGodot(), ['--headless', '--path', projectRoot, '--script', 'res://tests/run_tests.gd', '--', '--self-test-failure'], { cwd: projectRoot, encoding: 'utf8', windowsHide: true, timeout: 170000 });
  assert.equal(run.status, 1, `${run.stdout}\n${run.stderr}`);
  assert.match(run.stderr, /Intentional runner failure/);
  assert.doesNotMatch(run.stderr, /SCRIPT ERROR|Parse Error/);
});
