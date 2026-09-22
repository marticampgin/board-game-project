#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { findGodot, projectRoot } from './godot.mjs';

/** Separate native Godot process with a file inbox, suitable for terminal use and tests. */
export class NetworkPeer extends EventEmitter {
  constructor(config) {
    super();
    this.config = { ...config, directory: path.resolve(config.directory) };
    this.events = [];
    this.output = '';
    this.latest = undefined;
    this.exitCode = undefined;
  }

  async start() {
    await mkdir(path.join(this.config.directory, 'inbox'), { recursive: true });
    const filename = path.join(this.config.directory, 'peer.json');
    await writeFile(filename, JSON.stringify(this.config));
    this.child = spawn(findGodot(), ['--headless', '--path', projectRoot, '--script', 'res://tools/network_peer.gd', '--', filename], {
      cwd: projectRoot, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let pending = '';
    this.child.stdout.on('data', chunk => {
      this.output += chunk;
      pending += chunk;
      const lines = pending.split(/\r?\n/);
      pending = lines.pop();
      for (const line of lines) {
        if (!line.startsWith('@realm-net ')) { this.emit('diagnostic', line); continue; }
        const record = JSON.parse(line.slice(11));
        this.events.push(record);
        if (record.kind === 'observation') this.latest = record.data;
        if (record.kind === 'identity') this.identity = record.data;
        this.emit('record', record);
      }
    });
    this.child.stderr.on('data', chunk => { this.output += chunk; this.emit('diagnostic', chunk.toString()); });
    this.child.on('error', error => { this.output += error.message; this.emit('diagnostic', error.message); });
    this.child.on('close', code => { this.exitCode = code; this.emit('closed', code); });
    await this.wait(record => record.kind === 'boot', 15000);
    return this;
  }

  async write(request) {
    const id = request.id ?? randomUUID();
    const basename = `${Date.now()}-${id}`;
    const temporary = path.join(this.config.directory, 'inbox', `${basename}.tmp`);
    await writeFile(temporary, JSON.stringify({ ...request, id }));
    await rename(temporary, temporary.slice(0, -4) + '.json');
    return id;
  }

  async control(request, timeout = 10000) {
    const id = await this.write(request);
    return (await this.wait(record => record.kind === 'control' && record.data.id === id, timeout)).data;
  }

  wait(predicate, timeout = 10000, after = 0) {
    const found = this.events.slice(after).find(predicate);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const onRecord = record => { if (predicate(record)) { cleanup(); resolve(record); } };
      const onClose = code => { cleanup(); reject(new Error(`Network peer exited ${code}: ${this.output.slice(-4000)}`)); };
      const timer = setTimeout(() => { cleanup(); reject(new Error(`Network peer timed out: ${this.output.slice(-2500)}`)); }, timeout);
      const cleanup = () => { clearTimeout(timer); this.off('record', onRecord); this.off('closed', onClose); };
      this.on('record', onRecord);
      this.on('closed', onClose);
      if (this.exitCode !== undefined) onClose(this.exitCode);
    });
  }

  async stop() {
    if (!this.child || this.exitCode !== undefined) return;
    try { await this.control({ op: 'quit' }, 2000); } catch { /* Process may close before the acknowledgment. */ }
    if (this.exitCode === undefined) {
      await Promise.race([new Promise(resolve => this.once('closed', resolve)), new Promise(resolve => setTimeout(resolve, 1000))]);
    }
    if (this.exitCode === undefined) this.child.kill();
  }
}

const help = `Native ENet development sessions (Godot 4.7.2)
  npm run net -- host --port 24567 --seed 20260922 --session .realm/host
  npm run net -- join --address 127.0.0.1 --port 24567 --session .realm/client
  npm run net -- join --token TOKEN --session .realm/reconnected
  npm run net -- send --session .realm/host --op start
  npm run net -- send --session .realm/client --command '{"type":"ready","player_id":"p2"}'
  npm run net -- inspect --session .realm/client
  npm run net -- logs --session .realm/host [--limit 20] [--json]

Host/join also accept --manual (disable automatic phase/bot drive), --json and --reaction-timeout N.
While connected, enter one JSON command per line; {"op":"start"} starts the host match.
Each session records received wire observations/results in network.jsonl and the latest view in
observation.json. Host actions.jsonl records detailed accepted/rejected commands with RNG and
before/after hashes. Local credentials.json contains that seat's reconnect token. Raw commands use
the same mechanics documented by npm run cli -- --help. Ctrl+C closes the peer.`;

function parse(args) {
  const values = { mode: (args[0] ?? 'help').replace(/^--(?=host$|join$)/, '') };
  for (let index = 1; index < args.length; index++) {
    const flag = args[index];
    if (['--manual', '--json', '--help'].includes(flag)) { values[flag.slice(2)] = true; continue; }
    if (!['--port', '--seed', '--session', '--address', '--token', '--command', '--op', '--file', '--reaction-timeout', '--limit'].includes(flag)) throw new Error(`Unknown option ${flag}`);
    if (++index >= args.length) throw new Error(`Missing value for ${flag}`);
    values[flag.slice(2)] = args[index];
  }
  return values;
}

async function main() {
  const options = parse(process.argv.slice(2));
  if (options.mode === 'help' || options.mode === '--help' || options.help) { console.log(help); return; }
  const directory = path.resolve(options.session ?? `.realm/${options.mode === 'host' ? 'host' : 'client'}`);
  if (options.mode === 'inspect') { console.log(JSON.stringify(JSON.parse(await readFile(path.join(directory, 'observation.json'), 'utf8')), null, 2)); return; }
  if (options.mode === 'logs') {
    const entries = (await readFile(path.join(directory, 'network.jsonl'), 'utf8')).trim().split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line)).slice(-Number(options.limit ?? 20));
    if (options.json) console.log(JSON.stringify(entries, null, 2));
    else for (const entry of entries) {
      const data = entry.data;
      if (entry.kind === 'observation') console.log(`#${entry.index} [${data.player_id}] v${data.state_version} round ${data.state.round_number} ${data.state.phase} ${data.public_checksum.slice(0, 12)}`);
      else if (entry.kind === 'result') console.log(`#${entry.index} ${data.is_valid ? 'ACCEPT' : 'REJECT'} ${data.reason_code} v${data.state_version} ${data.message}`);
      else console.log(`#${entry.index} ${entry.kind}: ${JSON.stringify(data)}`);
    }
    return;
  }
  const peer = new NetworkPeer({ directory, mode: options.mode, port: Number(options.port ?? 24567), seed: Number(options.seed ?? 20260922), address: options.address ?? '127.0.0.1', token: options.token ?? '', auto_drive: !options.manual, reaction_timeout_seconds: Number(options['reaction-timeout'] ?? 20) });
  if (!Number.isInteger(peer.config.port) || peer.config.port < 1024 || peer.config.port > 65535) throw new Error('Port must be an integer from 1024 to 65535.');
  if (options.mode === 'send') {
    const request = options.file ? JSON.parse(await readFile(options.file, 'utf8')) : options.command ? { op: 'submit', command: JSON.parse(options.command) } : { op: options.op ?? 'inspect' };
    const id = await peer.write(request);
    console.log(`Queued ${id}; inspect ${path.join(directory, 'network.jsonl')} for the result.`);
    return;
  }
  if (!['host', 'join'].includes(options.mode)) throw new Error(`Unknown mode ${options.mode}`);
  peer.on('diagnostic', line => { if (line.trim()) console.error(line); });
  peer.on('record', record => {
    if (options.json) console.log(JSON.stringify(record));
    else if (record.kind === 'observation') console.log(`[${record.data.player_id}] v${record.data.state_version} ${record.data.state?.phase ?? 'lobby'} ${record.data.public_checksum?.slice(0, 12) ?? ''}`);
    else console.log(`${record.kind}: ${JSON.stringify(record.data)}`);
  });
  await peer.start();
  const input = createInterface({ input: process.stdin });
  input.on('line', async line => {
    if (!line.trim()) return;
    try { const value = JSON.parse(line); await peer.write(value.op ? value : { op: 'submit', command: value }); }
    catch (error) { console.error(error.message); }
  });
  process.on('SIGINT', async () => { input.close(); await peer.stop(); });
  const status = await new Promise(resolve => peer.once('closed', resolve));
  input.close();
  process.exitCode = /(?:SCRIPT ERROR:|\bERROR:)/.test(peer.output) ? 1 : (status ?? 1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
