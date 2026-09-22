import { test, expect } from '@playwright/test';

async function inspect(page) {
  return page.evaluate(() => { window.realm.inspect(); return { state: window.realm.state, ui: window.realm.ui, legal: window.realm.legal }; });
}

async function clickControl(page, id) {
  await page.waitForFunction(id => { window.realm.inspect(); return window.realm.ui.controls[id] && !window.realm.ui.controls[id].disabled; }, id);
  const point = await page.evaluate(id => {
    const { ui } = window.realm;
    const rect = ui.controls[id];
    const canvas = document.querySelector('canvas').getBoundingClientRect();
    return { x: canvas.x + (rect.x + rect.width / 2) * canvas.width / ui.size.width, y: canvas.y + (rect.y + rect.height / 2) * canvas.height / ui.size.height };
  }, id);
  await page.mouse.click(point.x, point.y);
  await page.waitForTimeout(90);
}

async function clickHex(page, hex) {
  const point = await page.evaluate(hex => {
    window.realm.inspect();
    const { ui } = window.realm;
    const h = ui.hexes[hex];
    const canvas = document.querySelector('canvas').getBoundingClientRect();
    return { x: canvas.x + (ui.viewport.x + h.x) * canvas.width / ui.size.width, y: canvas.y + (ui.viewport.y + h.y) * canvas.height / ui.size.height };
  }, hex);
  await page.mouse.move(point.x, point.y);
  await page.mouse.click(point.x, point.y);
  await page.waitForTimeout(120);
}

async function boot(page) {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error' || /SCRIPT ERROR|Parse Error/.test(message.text())) errors.push(message.text()); });
  await page.goto('/');
  await page.waitForFunction(() => window.realm?.state && window.realm?.ui?.controls?.start, null, { timeout: 60_000 });
  await expect(page).toHaveTitle(/Shattered Realm/);
  await expect(page.locator('canvas')).toBeVisible();
  return errors;
}

test('native Godot UI: planning, camera, movement, capture, income and three rounds', async ({ page }, testInfo) => {
  const errors = await boot(page);
  const initial = await inspect(page);
  expect(Object.keys(initial.state.map.hexes)).toHaveLength(61);
  expect(Object.keys(initial.state.map.locations)).toHaveLength(16);
  expect(Object.keys(initial.state.heroes)).toHaveLength(4);
  await page.screenshot({ path: testInfo.outputPath('welcome-1280.png') });
  await clickControl(page, 'start');
  expect((await inspect(page)).state.phase).toBe('planning');
  await clickControl(page, 'rotate_left');
  expect((await inspect(page)).ui.camera.yaw).toBeLessThan(0);
  await clickControl(page, 'rotate_right');
  await clickControl(page, 'zoom_in');
  expect((await inspect(page)).ui.camera.zoom).toBeLessThan(15.2);
  await clickControl(page, 'zoom_out');
  await clickControl(page, 'debug');
  expect((await inspect(page)).ui.debug_visible).toBe(true);
  await clickControl(page, 'debug_close');
  const moved = new Set();
  let captured = false;
  let commandCount = 0;
  for (let steps = 0; steps < 80; steps++) {
    const { state, legal } = await inspect(page);
    if (state.round_number >= 4) break;
    if (state.phase === 'planning') {
      for (const id of Object.keys(state.heroes)) await clickControl(page, `ready_${id}`);
    } else if (['world', 'initiative', 'bonus', 'resolution'].includes(state.phase)) {
      await clickControl(page, 'advance');
    } else {
      const actor = state.initiative_order[state.current_actor_index];
      if (legal.capture && moved.has(actor)) {
        await clickControl(page, 'capture'); captured = true;
      } else if (legal.move && !moved.has(actor)) {
        const targets = Object.keys(legal.move.targets);
        const tower = targets.find(hex => Object.values(state.map.locations).some(location => location.hex === hex && location.kind === 'minor_tower' && !location.owner_id));
        const destination = tower || targets[0];
        await clickControl(page, 'move');
        expect((await inspect(page)).ui.move_mode).toBe(true);
        await clickHex(page, destination);
        const after = await inspect(page);
        expect(after.state.heroes[actor].hex).toBe(destination);
        expect(after.state.command_sequence).toBeGreaterThan(state.command_sequence);
        moved.add(actor);
      } else {
        const result = await page.evaluate(actor => window.realm.command({ type: 'pass', player_id: actor }), actor);
        expect(result.is_valid).toBe(true);
      }
      commandCount++;
    }
  }
  const final = await inspect(page);
  expect(final.state.round_number).toBe(4);
  expect(moved.size).toBe(4);
  expect(captured).toBe(true);
  expect(commandCount).toBe(24);
  expect(final.state.events.some(event => event.type === 'IncomeGranted')).toBe(true);
  expect(final.ui.journal.length).toBeGreaterThan(100);
  const imagePath = testInfo.outputPath('board-1280.png');
  await page.screenshot({ path: imagePath });
  await testInfo.attach('Godot native UI 1280×720', { path: imagePath, contentType: 'image/png' });
  await page.evaluate(seed => window.realm.reset(seed), initial.state.master_seed);
  const regenerated = await inspect(page);
  expect(regenerated.state.map).toEqual(initial.state.map);
  const before = JSON.stringify(regenerated.state);
  const rejected = await page.evaluate(() => window.realm.command({ type: 'move', player_id: 'p1', target: '99,99' }));
  expect(rejected.is_valid).toBe(false);
  expect(JSON.stringify((await inspect(page)).state)).toBe(before);
  expect(errors).toEqual([]);
});

test('1920×1080 retains board, readable controls and seed regeneration', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  const errors = await boot(page);
  await clickControl(page, 'start');
  await clickControl(page, 'regenerate');
  const { state, ui } = await inspect(page);
  expect(state.phase).toBe('world');
  expect(ui.viewport.width).toBeGreaterThan(380);
  for (const rect of Object.values(ui.controls)) {
    expect(rect.x).toBeGreaterThanOrEqual(0);
    expect(rect.y).toBeGreaterThanOrEqual(0);
    expect(rect.x + rect.width).toBeLessThanOrEqual(ui.size.width + 1);
    expect(rect.y + rect.height).toBeLessThanOrEqual(ui.size.height + 1);
  }
  await page.screenshot({ path: testInfo.outputPath('board-1920.png') });
  expect(errors).toEqual([]);
});
