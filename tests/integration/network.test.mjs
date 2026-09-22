import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import dgram from 'node:dgram';
import { NetworkPeer } from '../../tools/network.mjs';
import { projectRoot } from '../../tools/godot.mjs';

async function availablePort() {
  const socket = dgram.createSocket('udp4');
  await new Promise(resolve => socket.bind(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  return port;
}

const distance = (a, b) => {
  const [aq, ar] = a.split(',').map(Number), [bq, br] = b.split(',').map(Number);
  return Math.max(Math.abs(aq - bq), Math.abs(ar - br), Math.abs(aq + ar - bq - br));
};

// Test navigation selects among authoritative legal destinations; it never applies movement.
function approach(snapshot, player, target, legal) {
  const walkable = Object.keys(snapshot.map.hexes).filter(hex => !['mountain', 'water'].includes(snapshot.map.hexes[hex].terrain));
  const costs = { [target]: 0 }, frontier = [target];
  while (frontier.length) {
    const current = frontier.shift();
    for (const next of walkable) if (!(next in costs) && distance(current, next) === 1) { costs[next] = costs[current] + 1; frontier.push(next); }
  }
  const candidates = Object.keys(legal.move?.targets ?? {}).sort((a, b) => (costs[a] ?? 100) - (costs[b] ?? 100) || distance(a, target) - distance(b, target) || a.localeCompare(b));
  return candidates.length ? { type: 'move', player_id: player, target: candidates[0] } : { type: 'pass', player_id: player };
}

test('native ENet authority, hidden decisions, timeout and token reconnect across three processes', { timeout: 180000 }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'realm-network-'));
  const port = await availablePort();
  const peers = [];
  const report = { transport: 'Godot 4.7.2 ENet', seed: 20260922, port, checks: [], commands: [] };
  const check = label => { report.checks.push(label); console.log(`ENet: ${label}`); };
  async function launch(name, config) {
    const peer = new NetworkPeer({ directory: path.join(directory, name), port, seed: report.seed, auto_drive: false, reaction_timeout_seconds: 120, planning_timeout_seconds: 120, ...config });
    peers.push(peer);
    await peer.start();
    await peer.wait(record => record.kind === 'observation');
    return peer;
  }
  let host, client2, client3;
  async function inspect() { return host.control({ op: 'inspect' }); }
  async function synchronize(version) {
    await Promise.all([host, client2, client3].filter(Boolean).map(peer => peer.wait(record => record.kind === 'observation' && record.data.state_version >= version)));
    const observations = [host, client2, client3].filter(Boolean).map(peer => peer.latest);
    assert.equal(new Set(observations.map(view => view.public_checksum)).size, 1, 'Each seat receives the same public state checksum');
    for (const view of observations) {
      assert.match(view.public_checksum, /^[a-f0-9]{64}$/);
      assert.match(view.view_checksum, /^[a-f0-9]{64}$/);
    }
  }
  async function send(command, expected = true, via) {
    const peer = via ?? ({ p2: client2, p3: client3 }[command.player_id] ?? host);
    let result;
    if (peer === host) result = (await host.control({ op: 'host_submit', command })).result;
    else {
      const from = peer.events.length;
      await peer.control({ op: 'submit', command });
      result = (await peer.wait(record => record.kind === 'result', 10000, from)).data;
    }
    assert.equal(result.is_valid, expected, `${JSON.stringify(command)}: ${JSON.stringify(result)}`);
    report.commands.push({ command, result });
    if (result.is_valid) await synchronize(result.state_version);
    return result;
  }
  try {
    host = await launch('host', { mode: 'host' });
    client2 = await launch('client2', { mode: 'join', address: '127.0.0.1' });
    client3 = await launch('client3', { mode: 'join', address: '127.0.0.1' });
    assert.equal(client2.latest.player_id, 'p2');
    assert.equal(client3.latest.player_id, 'p3');
    await client2.wait(record => record.kind === 'identity');
    await client3.wait(record => record.kind === 'identity');
    assert.notEqual(client2.identity.token, client3.identity.token);
    check('host and two separate native clients join assigned seats with distinct reconnect tokens');
    const start = await host.control({ op: 'start' });
    assert.equal(start.result.is_valid, true, JSON.stringify(start.result));
    let current = await inspect();
    await synchronize(current.snapshot.state_version);
    for (const peer of [client2, client3]) {
      assert.equal(peer.latest.state.rng, undefined, 'Clients must never receive authoritative RNG state');
      assert.equal(peer.latest.state.commands, undefined, 'Raw replay commands may reveal sealed plans');
    }
    check('seeded public checksums agree and authoritative RNG/replay commands stay host-only');

    const originalChecksum = current.checksum;
    const forged = await send({ type: 'ready', player_id: 'p1' }, false, client2);
    assert.match(forged.reason_code, /SEAT|ACTOR|AUTH|PLAYER/);
    assert.equal((await inspect()).checksum, originalChecksum, 'Forged seat command must be pure');
    const staleVersion = await send({ type: 'ready', player_id: 'p2', expected_version: 999999 }, false);
    assert.match(staleVersion.reason_code, /STALE|VERSION/);
    assert.equal((await inspect()).checksum, originalChecksum);
    const beforeRaw = client2.events.length;
    await client2.control({ op: 'raw_rpc', sequence: 1, command: { type: 'ready', player_id: 'p2', expected_version: current.snapshot.state_version } });
    const staleSequence = (await client2.wait(record => record.kind === 'result', 10000, beforeRaw)).data;
    assert.equal(staleSequence.is_valid, false);
    assert.match(staleSequence.reason_code, /SEQUENCE/);
    assert.equal((await inspect()).checksum, originalChecksum);
    check('forged seat, stale state version and replayed sequence reject without state or RNG mutation');

    if (current.snapshot.phase === 'world') await send({ type: 'advance' });
    current = await inspect();
    assert.equal(current.snapshot.phase, 'planning');
    const remotePlan = current.legal.p2.submit_plan.initiative_push ? { initiative_push: true } : {};
    await send({ type: 'submit_plan', player_id: 'p2', plan: remotePlan });
    current = await inspect();
    assert.deepEqual(current.snapshot.plans.p2, remotePlan);
    assert.equal(client3.latest.state.plans?.p2, undefined, 'Other peers cannot receive the submitted plan');
    assert.equal(host.latest.state.plans?.p2, undefined, 'Even host presentation receives only authorized private state');
    for (const peer of [host, client3]) {
      const leaked = (peer.latest.state.events ?? []).filter(event => event.actor_id === 'p2' && event.type === 'PlanSubmitted' && event.data?.plan);
      assert.equal(leaked.length, 0, 'Plan values cannot leak through historical events');
    }
    check('remote simultaneous plan remains absent from other seats and event history');
    for (const player of ['p1', 'p2', 'p4']) await send({ type: 'ready', player_id: player });
    await host.control({ op: 'tick', seconds: 121 });
    current = await inspect();
    assert.equal(current.snapshot.phase, 'initiative');
    assert.deepEqual(current.snapshot.plans.p3, {});
    await synchronize(current.snapshot.state_version);
    check('planning deadline readies the absent submission with no change');

    let attacked = false, remoteMoved = false, timeoutChecked = false, stanceChecked = false, resolved = false;
    for (let attempt = 0; attempt < 120 && !resolved; attempt++) {
      current = await inspect();
      const state = current.snapshot;
      if (state.pending_reaction && Object.keys(state.pending_reaction).length) {
        if (!timeoutChecked && state.pending_reaction.kind === 'bribe_offer') {
          assert.equal(state.pending_reaction.actor_id, 'p3');
          const sequence = state.command_sequence;
          await host.control({ op: 'tick', seconds: 121 });
          current = await inspect();
          assert.ok(current.snapshot.command_sequence > sequence, 'Reaction timeout executes a real command');
          assert.ok(current.snapshot.commands.some(command => command.type === 'resolve_reaction' && command.player_id === 'p3' && command.choice === 'decline'));
          await synchronize(current.snapshot.state_version);
          timeoutChecked = true;
          check('elapsed reaction deadline submits safe Decline through authoritative command pipeline');
          continue;
        }
        await send({ type: 'resolve_reaction', player_id: state.pending_reaction.actor_id, choice: 'decline' });
        continue;
      }
      const pending = state.pending_combat ?? {};
      if (Object.keys(pending).length) {
        const stanceActors = ['p2', 'p3'].filter(player => current.legal[player].choose_stance);
        if (stanceActors.length) {
          const actor = stanceActors.includes('p2') ? 'p2' : stanceActors[0];
          await send({ type: 'choose_stance', player_id: actor, stance: actor === 'p2' ? 'trick' : 'guard' });
          if (!stanceChecked && actor === 'p2') {
            const full = await inspect();
            assert.equal(full.snapshot.pending_combat.stances.p2, 'trick');
            assert.equal(client3.latest.state.pending_combat.stances?.p2, undefined);
            assert.equal(host.latest.state.pending_combat.stances?.p2, undefined);
            for (const peer of [host, client3]) assert.ok(!(peer.latest.state.events ?? []).some(event => event.type === 'StanceSelected' && event.actor_id === 'p2' && event.data?.stance === 'trick'));
            stanceChecked = true;
            check('first remote combat stance remains sealed on other clients until reveal');
          }
          continue;
        }
        let handled = false;
        for (const player of ['p1', 'p2', 'p3', 'p4']) {
          const legal = current.legal[player];
          if (legal.decline_fate) { await send({ type: 'decline_fate', player_id: player }); handled = true; break; }
          if (legal.displace) { await send({ type: 'displace', player_id: player, target: Object.keys(legal.displace.targets).sort()[0] }); handled = true; break; }
        }
        assert.ok(handled, `Unhandled pending combat: ${JSON.stringify(pending)}`);
        continue;
      }
      if (attacked) { resolved = true; break; }
      if (['world', 'initiative', 'bonus', 'resolution'].includes(state.phase)) { await send({ type: 'advance' }); continue; }
      if (state.phase === 'planning') { for (const player of ['p1', 'p2', 'p3', 'p4']) if (current.legal[player].ready) await send({ type: 'ready', player_id: player }); continue; }
      const actor = current.actor, legal = current.legal[actor];
      if (actor === 'p2' && legal.attack?.targets.p3) {
        await send({ type: 'attack', player_id: actor, target_id: 'p3' });
        attacked = true;
      } else if (actor === 'p2') {
        const command = approach(state, actor, state.heroes.p3.hex, legal);
        await send(command);
        remoteMoved ||= command.type === 'move';
      } else if (actor === 'p3' && state.heroes.p3.hex === state.heroes.p3.sanctuary) {
        await send(approach(state, actor, '0,0', legal));
      } else await send({ type: 'pass', player_id: actor });
    }
    assert.ok(remoteMoved && attacked && resolved && timeoutChecked && stanceChecked, JSON.stringify({ remoteMoved, attacked, resolved, timeoutChecked, stanceChecked }));
    current = await inspect();
    assert.ok(current.snapshot.events.some(event => event.type === 'CombatResolved'));
    check('remote legal movement, phases, stance reveal, Fate ordering and combat resolution synchronize');

    const token = client2.identity.token;
    const stableChecksum = current.checksum;
    await client2.stop();
    client2 = undefined;
    await host.wait(record => record.kind === 'lobby' && record.data.seats?.some(seat => seat.player_id === 'p2' && !seat.connected));
    const reconnected = await launch('reconnected', { mode: 'join', address: '127.0.0.1', token });
    client2 = reconnected;
    assert.equal(client2.latest.player_id, 'p2');
    assert.equal((await inspect()).checksum, stableChecksum, 'Reconnect itself must not mutate game state');
    await synchronize(current.snapshot.state_version);
    assert.ok(client2.latest.started);
    assert.ok(client2.latest.state.events.some(event => event.type === 'CombatResolved'));
    assert.equal(client2.latest.state.plans?.p3, undefined);
    check('disconnect reserves seat; opaque token restores filtered snapshot, events and matching public checksum');
    const afterReconnect = await send({ type: 'ready', player_id: 'p2' }, false);
    assert.equal(afterReconnect.reason_code, 'WRONG_PHASE');
    assert.ok(afterReconnect.client_sequence > 1 && afterReconnect.next_sequence === afterReconnect.client_sequence + 1);
    assert.equal((await inspect()).checksum, stableChecksum);
    check('reconnected client resumes its monotonic command sequence');
    for (const peer of peers) {
      for (const record of peer.events.filter(event => event.kind === 'observation')) {
        const view = record.data, state = view.state;
        assert.equal(state.rng, undefined);
        assert.equal(state.commands, undefined);
        assert.equal(state.master_seed, undefined);
        assert.ok(Object.keys(state.plans ?? {}).every(player => player === view.player_id), 'Every received packet limits private plans to its own seat');
        if (state.pending_combat?.stage === 'stances') assert.ok(Object.keys(state.pending_combat.stances ?? {}).every(player => player === view.player_id), 'No intermediate packet leaks another seat\'s stance');
        for (const event of state.events ?? []) if (event.visibility !== 'public') assert.equal(event.actor_id, view.player_id, 'Private events are delivered only to their owner');
      }
    }
    check('all captured wire observations preserve plan, stance, private-event and RNG boundaries');
    const audit = (await readFile(path.join(directory, 'host', 'actions.jsonl'), 'utf8')).trim().split(/\r?\n/).map(line => JSON.parse(line));
    assert.ok(audit.some(entry => entry.source.startsWith('network:timeout:')));
    assert.ok(audit.some(entry => entry.reason_code === forged.reason_code));
    for (const entry of audit.filter(entry => !entry.accepted)) {
      assert.equal(entry.checksum_before, entry.checksum_after);
      assert.deepEqual(entry.rng_before, entry.rng_after);
    }
    report.audit_attempts = audit.length;
    check('host audit records remote and timeout actions plus pure protocol/domain rejections');
    report.final_state_version = current.snapshot.state_version;
    report.final_checksum = stableChecksum;
    report.passed = true;
  } finally {
    await Promise.allSettled(peers.map(peer => peer.stop()));
    const artifactDirectory = path.join(projectRoot, 'artifacts');
    await mkdir(artifactDirectory, { recursive: true });
    await writeFile(path.join(artifactDirectory, 'network_acceptance.json'), JSON.stringify(report, null, 2));
    for (let index = 0; index < peers.length; index++) {
      await writeFile(path.join(artifactDirectory, `network_peer_${index}.jsonl`), peers[index].events.map(record => JSON.stringify(record.kind === 'identity' ? { ...record, data: { player_id: record.data.player_id, token: '[redacted]' } } : record)).join('\n') + '\n');
    }
    await rm(directory, { recursive: true, force: true });
  }
  for (const peer of peers) assert.doesNotMatch(peer.output, /(?:SCRIPT ERROR:|\bERROR:)/);
});
