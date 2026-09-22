#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { readFile, writeFile, open, rename, copyFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { findGodot, projectRoot } from './godot.mjs';

const help = `Shattered Realm — the same Godot rules from your terminal

  npm run cli -- new --seed 20260922
  npm run cli -- state [--json]
  npm run cli -- legal [p1]
  npm run cli -- advance
  npm run cli -- plan p1 '{}'
  npm run cli -- ready p1
  npm run cli -- move p1 0,1
  npm run cli -- capture p1
  npm run cli -- pass p1
  npm run cli -- command '{"type":"move","player_id":"p1","target":"0,1"}'
  npm run cli -- command --file command.json
  npm run cli -- simulate --rounds 3
  npm run cli -- replay
  npm run cli -- validate-map --seed 1 --count 100
  npm run cli -- logs [--json] [--limit 20]

Options: --state FILE (default .realm/state.json), --json, --expected-version N,
         --expected-phase PHASE, --command-id ID. GODOT_BIN pins the executable.
Saves rotate state.json.bak and replace atomically. Rejections exit 2; tool errors exit 1.
Every action attempt is recorded alongside the save in state.actions.jsonl.
Read-only commands do not change state or gameplay RNG.`;

function parseArgs(args) {
  const positional = [];
  const options = {};
  const valueFlags = new Set(['state', 'seed', 'rounds', 'count', 'file', 'limit', 'expected-version', 'expected-phase', 'command-id']);
  for (let index = 0; index < args.length; index++) {
    const value = args[index];
    if (!value.startsWith('--')) { positional.push(value); continue; }
    const key = value.slice(2);
    if (key === 'json' || key === 'help') { options[key] = true; continue; }
    if (!valueFlags.has(key)) throw new Error(`Unknown option ${value}.`);
    if (index + 1 === args.length) throw new Error(`Missing value for ${value}.`);
    options[key] = args[++index];
  }
  return { positional, options };
}

function integer(value, fallback, name, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) {
  const number = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) throw new Error(`${name} must be an integer from ${minimum} to ${maximum}.`);
  return number;
}

async function readJson(filename) {
  try { return JSON.parse(await readFile(filename, 'utf8')); }
  catch (error) {
    if (error.code === 'ENOENT') throw new Error(`No saved game at ${filename}. Run new first.`);
    throw new Error(`Cannot read JSON ${filename}: ${error.message}`);
  }
}

async function atomicSave(filename, snapshot) {
  const temporary = `${filename}.${process.pid}.tmp`;
  try {
    try { await copyFile(filename, `${filename}.bak`); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const handle = await open(temporary, 'wx');
    try { await handle.writeFile(JSON.stringify(snapshot, null, 2) + '\n', 'utf8'); await handle.sync(); }
    finally { await handle.close(); }
    await rename(temporary, filename);
  } finally { await rm(temporary, { force: true }); }
}

function summary(response) {
  const state = response.snapshot;
  const lines = [];
  if (state) {
    lines.push(`Seed ${state.master_seed} | Round ${state.round_number} | ${state.phase} | Actor ${response.current_actor || '—'} | v${state.state_version}`);
    lines.push(`Checksum ${response.checksum}`);
    for (const hero of Object.values(state.heroes)) lines.push(`  ${hero.id} ${hero.class_id.padEnd(8)} at ${hero.hex.padEnd(6)} HP ${hero.hp}/${hero.max_hp}  Gold ${hero.gold}  Power ${hero.power}  Fate ${hero.fate}`);
  }
  if (response.result) {
    const result = response.result;
    lines.push(`${result.is_valid ? 'ACCEPT' : 'REJECT'} ${result.reason_code}: ${result.message}`);
    for (const event of result.events ?? []) lines.push(`  #${event.sequence} ${event.type} ${JSON.stringify(event.data)}`);
  }
  for (const [key, value] of Object.entries(response)) {
    if (['snapshot', 'checksum', 'current_actor', 'result', 'log_entries', 'mutated', 'ok'].includes(key)) continue;
    lines.push(`${key}: ${JSON.stringify(value, null, 2)}`);
  }
  return lines.join('\n');
}

function formatLog(entry) {
  const command = entry.command ?? {};
  const lines = [`${entry.timestamp_utc} ${entry.accepted ? 'ACCEPT' : 'REJECT'} r${entry.round_before} ${entry.phase_before} v${entry.version_before}→${entry.version_after} ${command.type} ${command.player_id ?? ''} ${command.target ?? ''} [${entry.reason_code}]`, `  hash ${entry.checksum_before} → ${entry.checksum_after}`];
  if (!entry.accepted) lines.push(`  ${entry.message}`);
  for (const event of entry.events ?? []) lines.push(`  #${event.sequence} ${event.type} ${JSON.stringify(event.data)}`);
  return lines.join('\n');
}

async function main() {
  const { positional, options } = parseArgs(process.argv.slice(2));
  let [operation, player, value] = positional;
  if (!operation || operation === 'help' || options.help) { console.log(help); return; }
  const stateFile = path.resolve(options.state ?? path.join(projectRoot, '.realm', 'state.json'));
  const logFile = path.join(path.dirname(stateFile), `${path.basename(stateFile, '.json')}.actions.jsonl`);
  if (operation === 'logs') {
    const limit = integer(options.limit, 20, 'limit', 1, 100000);
    let text;
    try { text = await readFile(logFile, 'utf8'); } catch (error) { if (error.code !== 'ENOENT') throw error; text = ''; }
    const entries = text.trim().split('\n').filter(Boolean).slice(-limit).map(line => JSON.parse(line));
    console.log(options.json ? JSON.stringify(entries, null, 2) : entries.map(formatLog).join('\n') || 'No recorded actions.');
    return;
  }
  const request = { operation, log_path: logFile };
  const aliases = new Set(['advance', 'ready', 'move', 'capture', 'pass', 'plan', 'submit_plan']);
  if (aliases.has(operation) || operation === 'command') {
    let command;
    if (operation === 'command') command = options.file ? await readJson(path.resolve(options.file)) : JSON.parse(player ?? '{}');
    else {
      command = { type: operation === 'plan' ? 'submit_plan' : operation };
      if (player) command.player_id = player;
      if (operation === 'move') command.target = value ?? '';
      if (operation === 'plan' || operation === 'submit_plan') command.plan = JSON.parse(value ?? '{}');
    }
    if (!command || typeof command !== 'object' || Array.isArray(command)) throw new Error('Command must be a JSON object.');
    if (options['expected-version'] !== undefined) command.expected_version = integer(options['expected-version'], 0, 'expected-version');
    if (options['expected-phase']) command.expected_phase = options['expected-phase'];
    if (options['command-id']) command.command_id = options['command-id'];
    request.operation = 'command';
    request.command = command;
  } else if (!['new', 'state', 'legal', 'simulate', 'replay', 'validate-map'].includes(operation)) throw new Error(`Unknown command ${operation}. Use help.`);
  if (operation === 'legal') request.player_id = player ?? '';
  if (operation === 'new' || operation === 'validate-map') request.seed = integer(options.seed, 20260922, 'seed', -2147483648, 2147483647);
  if (operation === 'validate-map') request.count = integer(options.count, 1, 'count', 1, 10000);
  if (operation === 'simulate') request.rounds = integer(options.rounds, 3, 'rounds', 1, 1000);
  const mutations = ['new', 'command', 'simulate'].includes(request.operation);
  await mkdir(path.dirname(stateFile), { recursive: true });
  let lock;
  let temporary;
  try {
    if (mutations) {
      try { lock = await open(`${stateFile}.lock`, 'wx'); await lock.writeFile(String(process.pid)); }
      catch (error) { if (error.code === 'EEXIST') throw new Error(`Save is locked: ${stateFile}.lock. Another CLI writer is running; remove a stale lock only after it exits.`); throw error; }
    }
    if (!['new', 'validate-map'].includes(request.operation)) request.snapshot = await readJson(stateFile);
    temporary = await mkdtemp(path.join(tmpdir(), 'shattered-realm-'));
    const requestPath = path.join(temporary, 'request.json');
    const responsePath = path.join(temporary, 'response.json');
    await writeFile(requestPath, JSON.stringify(request), 'utf8');
    const result = spawnSync(findGodot(), ['--headless', '--path', projectRoot, '--script', 'res://tools/game_cli.gd', '--', requestPath, responsePath], { cwd: projectRoot, windowsHide: true, encoding: 'utf8', timeout: 120000, maxBuffer: 8 * 1024 * 1024 });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`Godot CLI exited ${result.status}:\n${result.stderr}\n${result.stdout}`);
    if (/(?:SCRIPT ERROR:|\bERROR:)/.test(`${result.stdout}\n${result.stderr}`)) throw new Error(`Godot reported an engine or script error:\n${result.stderr}\n${result.stdout}`);
    let response;
    try { response = JSON.parse(await readFile(responsePath, 'utf8')); }
    catch (error) { throw new Error(`Godot did not write a valid response: ${error.message}\n${result.stderr}\n${result.stdout}`); }
    if (response.snapshot && (request.operation === 'new' || response.mutated)) await atomicSave(stateFile, response.snapshot);
    console.log(options.json ? JSON.stringify(response, null, 2) : summary(response));
    if (!response.ok) process.exitCode = response.result ? 2 : 1;
    if (response.logging_error) { console.error(response.logging_error); process.exitCode = 1; }
  } finally {
    if (temporary) {
      if (path.dirname(path.resolve(temporary)) !== path.resolve(tmpdir()) || !path.basename(temporary).startsWith('shattered-realm-')) throw new Error('Refusing to remove a temporary directory outside the CLI workspace.');
      await rm(temporary, { recursive: true, force: true });
    }
    if (lock) { await lock.close(); await rm(`${stateFile}.lock`, { force: true }); }
  }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
