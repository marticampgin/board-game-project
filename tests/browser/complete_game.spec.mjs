import { test, expect } from '@playwright/test';

async function boot(page) {
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('console', e => { if (e.type() === 'error' || /SCRIPT ERROR|Parse Error/.test(e.text())) errors.push(e.text()); });
  await page.goto('/');
  await page.waitForFunction(() => window.realm?.ui?.controls?.start, null, { timeout: 60_000 });
  return errors;
}
async function state(page) {
  return page.evaluate(() => { window.realm.inspect(); return { state: window.realm.state, ui: window.realm.ui }; });
}
async function click(page, id) {
  await page.waitForFunction(id => { window.realm.inspect(); return window.realm.ui.controls[id] && !window.realm.ui.controls[id].disabled; }, id);
  const p = await page.evaluate(id => {
    const r = window.realm.ui.controls[id], s = window.realm.ui.size;
    const c = document.querySelector('canvas').getBoundingClientRect();
    return { x: c.x + (r.x + r.width / 2) * c.width / s.width, y: c.y + (r.y + r.height / 2) * c.height / s.height };
  }, id);
  await page.mouse.click(p.x, p.y);
  await page.waitForTimeout(80);
}
async function select(page, id, index) {
  await click(page, id);
  await page.keyboard.press('Home');
  // Godot PopupMenu initially has no focused row; the first Down focuses row 0.
  for (let n = 0; n <= index; n++) await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(80);
}

test('manual save, restore, settings and hotseat planning handoffs', async ({ page }, info) => {
  const errors = await boot(page);
  await select(page, 'mode_select', 2);
  await click(page, 'start');
  expect((await state(page)).ui.mode).toBe('hotseat');
  expect((await state(page)).ui.handoff_visible).toBe(true);
  await click(page, 'handoff');
  await click(page, 'plan');
  await click(page, 'plan_confirm');
  await click(page, 'ready_p1');
  expect((await state(page)).ui.handoff_text).toContain('P2');
  await click(page, 'handoff');
  await click(page, 'save_game');
  const saved = (await state(page)).state;
  await click(page, 'ready_p2');
  await click(page, 'handoff');
  await click(page, 'load_game');
  await click(page, 'load_manual');
  expect((await state(page)).state).toEqual(saved);
  await click(page, 'handoff');
  await click(page, 'settings');
  await click(page, 'reduced_motion');
  await click(page, 'settings_close');
  expect((await state(page)).ui.settings.reduced_motion).toBe(true);
  const view = (await state(page)).ui;
  for (const id of ['move', 'plan', 'ready_p2', 'save_game', 'load_game']) {
    if (!view.controls[id]) continue;
    expect(view.controls[id].y + view.controls[id].height, id).toBeLessThanOrEqual(view.size.height);
  }
  await page.screenshot({ path: info.outputPath('hotseat-settings-save.png') });
  expect(errors).toEqual([]);
});

test('solo mode lets three bots plan while preserving the human seat', async ({ page }, info) => {
  const errors = await boot(page);
  await select(page, 'mode_select', 1);
  await select(page, 'seat_select', 3);
  await click(page, 'start');
  await page.waitForFunction(() => window.realm.state.ready.length === 3, null, { timeout: 15_000 });
  const before = await state(page);
  expect(before.ui.mode).toBe('solo');
  expect(before.ui.human_seat).toBe('p4');
  expect(before.state.ready).not.toContain('p4');
  expect(before.state.commands.filter(c => c.player_id === 'p4')).toHaveLength(0);
  await click(page, 'ready_p4');
  await page.waitForFunction(() => window.realm.state.phase.startsWith('cycle'), null, { timeout: 15_000 });
  await page.screenshot({ path: info.outputPath('solo-three-bots.png') });
  expect(errors).toEqual([]);
});

for (const route of ['conquest', 'dominion', 'ascension']) {
  test(`fresh local match reaches the ${route} victory screen`, async ({ page }, info) => {
    const errors = await boot(page);
    await click(page, 'start');
    const result = await page.evaluate(async route => {
      const preferences = { p1: route, p2: 'passive', p3: 'passive', p4: 'passive' };
      const types = new Set();
      let commands = 0;
      while (window.realm.state.phase !== 'victory' && commands < 800) {
        const command = window.realm.propose(preferences);
        if (!command?.type) throw new Error('No legal continuation: ' + JSON.stringify(window.realm.state.phase));
        const result = window.realm.command(command);
        if (!result.is_valid) throw new Error(JSON.stringify({ command, result }));
        types.add(command.type);
        commands++;
        // Let real rendering, deferred layout and animation run between commands.
        await new Promise(requestAnimationFrame);
      }
      window.realm.inspect();
      return { victory: window.realm.state.victory, ui: window.realm.ui, commands, types: [...types] };
    }, route);
    expect(result.victory.route).toBe(route);
    expect(result.victory.winners).toEqual(['p1']);
    expect(result.ui.victory_visible).toBe(true);
    expect(result.ui.victory_text.toLowerCase()).toContain(route);
    await page.screenshot({ path: info.outputPath(`${route}-victory.png`) });
    await click(page, 'victory_continue');
    const finished = await state(page);
    expect(finished.ui.victory_visible).toBe(false);
    expect(finished.ui.instruction.toLowerCase()).toContain('wins');
    console.log(`${route}: round ${result.victory.round}, ${result.commands} commands, ${JSON.stringify(result.ui.performance)}`);
    expect(errors).toEqual([]);
  });
}
