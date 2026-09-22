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
    assert.ok(incomeOnly.length > 0 && incomeOnly.length <= 3);
    assert.deepEqual(incomeOnly, entries.filter(entry => entry.events.some(event => event.type === 'IncomeGranted')));
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
  const run = spawnSync(findGodot(), ['--headless', '--path', projectRoot, '--script', 'res://tests/run_tests.gd', '--', '--suite', 'combat', '--self-test-failure'], { cwd: projectRoot, encoding: 'utf8', windowsHide: true, timeout: 170000 });
  assert.equal(run.status, 1, `${run.stdout}\n${run.stderr}`);
  assert.match(run.stderr, /Intentional runner failure/);
  assert.doesNotMatch(run.stderr, /SCRIPT ERROR|Parse Error/);
});

test('conflict action aliases submit their documented command payloads', { timeout: 90000 }, () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'realm-cli-test-'));
  const state = path.join(directory, 'aliases.json');
  try {
    invoke(state, ['new', '--seed', '7']);
    const commands = [
      { args: ['attack', 'p1', 'p2'], command: { type: 'attack', player_id: 'p1', target_id: 'p2' } },
      { args: ['stance', 'p1', 'assault'], command: { type: 'choose_stance', player_id: 'p1', stance: 'assault' } },
      { args: ['fate', 'p1'], command: { type: 'spend_fate', player_id: 'p1' } },
      { args: ['decline-fate', 'p1'], command: { type: 'decline_fate', player_id: 'p1' } },
      { args: ['displace', 'p1', '0,1'], command: { type: 'displace', player_id: 'p1', target: '0,1' } },
      { args: ['reaction', 'p3', 'accept'], command: { type: 'resolve_reaction', player_id: 'p3', choice: 'accept' } },
      { args: ['rest', 'p1'], command: { type: 'special', player_id: 'p1', special_id: 'rest' } },
      { args: ['forced-march', 'p2', '0,1'], command: { type: 'special', player_id: 'p2', special_id: 'forced_march', target: '0,1' } },
      { args: ['special', 'p2', 'forced_march', '0,1'], command: { type: 'special', player_id: 'p2', special_id: 'forced_march', target: '0,1' } },
      { args: ['upgrade', 'p1'], command: { type: 'upgrade', player_id: 'p1' } },
      { args: ['trade', 'p3', 'power_to_gold'], command: { type: 'trade', player_id: 'p3', direction: 'power_to_gold' } },
      { args: ['explore', 'p1', '--use-fate'], command: { type: 'explore', player_id: 'p1', use_fate: true } },
      { args: ['reward', 'p1', 'gold_cache'], command: { type: 'choose_reward', player_id: 'p1', choice: 'gold_cache' } },
      { args: ['purchase', 'p1', 'iron_weapon'], command: { type: 'submit_plan', player_id: 'p1', plan: { purchases: ['iron_weapon'] } } },
      { args: ['dark-bargain', 'p4'], command: { type: 'special', player_id: 'p4', special_id: 'dark_bargain' } },
      { args: ['begin-ritual', 'p1'], command: { type: 'begin_ritual', player_id: 'p1' } },
      { args: ['complete-ritual', 'p1'], command: { type: 'complete_ritual', player_id: 'p1' } },
    ];
    for (const { args } of commands) {
      const response = invoke(state, args, 2);
      assert.notEqual(response.result.reason_code, 'UNKNOWN_COMMAND');
      assert.equal(response.snapshot.state_version, 0, 'A command outside its decision window must not consume a version');
    }
    const entries = invoke(state, ['logs', '--limit', '100']);
    assert.deepEqual(entries.map(entry => entry.command), commands.map(example => example.command));
    assert.ok(entries.every(entry => !entry.accepted && entry.checksum_before === entry.checksum_after));
  } finally {
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(tmpdir()));
    assert.ok(path.basename(directory).startsWith('realm-cli-test-'));
    rmSync(directory, { recursive: true, force: true });
  }
});
