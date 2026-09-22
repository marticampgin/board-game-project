import { spawn } from 'node:child_process';
import { createSocket } from 'node:dgram';
import { findGodot, projectRoot } from './godot.mjs';

const probe = createSocket('udp4');
await new Promise(resolve => probe.bind(0, '127.0.0.1', resolve));
const port = probe.address().port;
await new Promise(resolve => probe.close(resolve));
const peers = [];
function launch(mode) {
  const child = spawn(findGodot(), ['--headless', '--path', projectRoot, '--script', 'res://tests/presentation/network_ui_smoke.gd', '--', mode, String(port)], { windowsHide: true });
  const peer = { child, output: '', done: false, boot: false, exit: null };
  peers.push(peer);
  for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => {
    peer.output += chunk;
    if (peer.output.includes('@ui-boot')) peer.boot = true;
    if (peer.output.includes('@ui-done')) peer.done = true;
  });
  child.on('exit', code => { peer.exit = code; });
  return peer;
}
async function waitFor(predicate, timeout) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    const bad = peers.find(peer => /SCRIPT ERROR:|\bERROR:|UI SMOKE FAILED:/.test(peer.output) || peer.exit !== null);
    if (bad) throw new Error(bad.output);
    if (Date.now() > deadline) throw new Error(peers.map(peer => peer.output).join('\n'));
    await new Promise(resolve => setTimeout(resolve, 50));
  }
}
try {
  const host = launch('host');
  await waitFor(() => host.boot, 10000);
  launch('join');
  launch('join');
  await waitFor(() => peers.every(peer => peer.done), 30000);
  for (const peer of peers) console.log(peer.output.split(/\r?\n/).find(line => line.startsWith('@ui-done')));
  console.log('PASS: three native Main scenes use filtered network views and legal per-seat controls.');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  for (const peer of peers) peer.child.kill();
}
