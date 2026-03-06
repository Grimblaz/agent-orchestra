---
name: browser-canvas-testing
description: VS Code native browser tool behavior for canvas-based games (Phaser 3, etc.). Use when interacting with HTML canvas elements, clicking game objects, or verifying canvas state via browser tools. Use when `clickElement` fails on canvas or when you need coordinate-based interaction.
---

# Browser Canvas Testing

Domain knowledge for using VS Code native browser tools against HTML canvas applications verified via VS Code source code review.

## When to Use

- Clicking game objects or UI elements rendered inside an HTML `<canvas>`
- Verifying canvas visual state with `screenshotPage`
- Discovering why `readPage` returns empty on a canvas-only page
- Any Phaser 3 / WebGL / 2D canvas game interaction in browser tools

---

## 1. Why `clickElement` Cannot Target Canvas Objects

`clickElement` is **selector-based only**. The VS Code source (`clickBrowserTool.ts`) defines these parameters:

```
pageId, selector, ref, dblClick, button
```

There is **no coordinate or position parameter**. The implementation does exactly:

```js
page.locator(selector).click()
```

A `<canvas>` element renders its content via GPU/CPU drawing calls — there are no child DOM elements for selectors to target. Even `canvas` as a CSS selector only clicks the canvas border box center, not a specific game object inside it.

**Conclusion**: `clickElement` cannot be used for canvas game interaction. Use `runPlaywrightCode` instead.

**Source**: [clickBrowserTool.ts](https://github.com/microsoft/vscode/blob/3487365a09898056546f68899ee94f286a3ca915/src/vs/workbench/contrib/browserView/electron-browser/tools/clickBrowserTool.ts)

---

## 2. Canvas Coordinate Conversion Formula

Canvas games use an internal game-space coordinate system that does not map directly to CSS page coordinates. Use `getBoundingClientRect` to convert.

```js
// 1. Query canvas bounding rect (accounts for scaling and letterboxing)
const rect = await page.evaluate(() => {
  const c = document.querySelector('canvas');
  if (!c) throw new Error('Canvas element not found');
  const r = c.getBoundingClientRect();
  return { left: r.left, top: r.top, width: r.width, height: r.height };
});

// 2. Convert game-space coords → CSS page coords
const cssX = rect.left + (gameX / GAME_WIDTH) * rect.width;
const cssY = rect.top + (gameY / GAME_HEIGHT) * rect.height;

// 3. Click via Playwright mouse API
await page.mouse.click(cssX, cssY);
```

**If the page has multiple `<canvas>` elements** (e.g., a main scene canvas plus a HUD overlay), `document.querySelector('canvas')` returns the first one, which may not be the target. Use a specific selector instead: `document.querySelector('#game canvas')` or `document.getElementById('game-canvas')`. Inspect with `page.evaluate(() => document.querySelectorAll('canvas').length)` to detect multiple canvases.

**Prerequisite**: The canvas must be rendered before calling `getBoundingClientRect()`. An unrendered canvas returns `{0,0,0,0}`, causing the formula to click `(0,0)` silently. See Section 3 for the render-ready wait pattern.

**Variables**:

- `gameX`, `gameY` — coordinates in the game's internal resolution (e.g., from game design docs or layout)
- `GAME_WIDTH`, `GAME_HEIGHT` — the game's declared resolution (e.g., `1920`, `1080` for a 1920×1080 game)
- `cssX`, `cssY` — CSS page coordinates passed to Playwright

This formula is verified working for Phaser 3 in **FIT scale mode** at 1920×1080.

**Note — scale mode matters**: In FIT mode the canvas CSS box scales to the viewport while `GAME_WIDTH`/`GAME_HEIGHT` stay constant, so this formula is exact. In **RESIZE mode** the game's internal resolution changes to match the viewport; use `canvas.width` and `canvas.height` read via `page.evaluate()` for `GAME_WIDTH`/`GAME_HEIGHT` instead of hardcoded constants. Other modes (NONE, ENVELOP) may require similar adjustments.

---

## 3. `runPlaywrightCode` Usage Pattern

`runPlaywrightCode` executes arbitrary Playwright code against the current browser page — the correct tool for all canvas interaction.

**Full worked example** — click a game object at game-space position (960, 540) in a 1920×1080 game:

```js
// Wait for canvas to be rendered and sized
await page.waitForFunction(() => {
  const c = document.querySelector('canvas');
  return c !== null && c.getBoundingClientRect().width > 0;
});

const rect = await page.evaluate(() => {
  const c = document.querySelector('canvas');
  const r = c.getBoundingClientRect();
  return { left: r.left, top: r.top, width: r.width, height: r.height };
});

const GAME_WIDTH = 1920;
const GAME_HEIGHT = 1080;
const gameX = 960;
const gameY = 540;

const cssX = rect.left + (gameX / GAME_WIDTH) * rect.width;
const cssY = rect.top + (gameY / GAME_HEIGHT) * rect.height;

await page.mouse.click(cssX, cssY);
```

**Also useful via `runPlaywrightCode`**:

- `await page.mouse.move(cssX, cssY)` — hover without clicking
- `await page.keyboard.press('Space')` — send key events to the game
- `await page.evaluate(() => window.gameState)` — read exposed JS globals for state assertions

---

## 4. `screenshotPage` — Works for Canvas Verification

`screenshotPage` **does work** on canvas content. It uses VS Code's internal `browserViewModel.captureScreenshot()` — not Playwright's `.screenshot()` method. This internal capture reads the rendered frame buffer directly, so canvas pixels are captured correctly.

Use `screenshotPage` to:

- Verify game state visually after an interaction
- Confirm UI transitions or animations completed
- Capture evidence of pass/fail for test reports

**Source**: [screenshotBrowserTool.ts](https://github.com/microsoft/vscode/blob/3487365a09898056546f68899ee94f286a3ca915/src/vs/workbench/contrib/browserView/electron-browser/tools/screenshotBrowserTool.ts)

---

## 5. `readPage` — Returns Empty for Canvas-Only Pages

`readPage` calls `playwrightService.getSummary()` which returns a DOM accessibility/semantic snapshot. Canvas elements render no accessible child nodes — the entire visual scene is opaque to the accessibility tree.

**Result**: `readPage` returns an empty or near-empty response for canvas-only applications.

**Do not use** `readPage` to:

- Detect game objects or UI state in a canvas game
- Assert text labels rendered inside the canvas
- Navigate or introspect canvas content

Use `runPlaywrightCode` with `page.evaluate()` to read game state from exposed JS APIs, or use `screenshotPage` for visual verification.

**Source**: [readBrowserTool.ts](https://github.com/microsoft/vscode/blob/3487365a09898056546f68899ee94f286a3ca915/src/vs/workbench/contrib/browserView/electron-browser/tools/readBrowserTool.ts)

---

## VS Code Source Citations

All behaviors above are verified from VS Code 1.110 source code:

| Tool | Source File |
|------|-------------|
| `click_element` / `clickElement` | [clickBrowserTool.ts](https://github.com/microsoft/vscode/blob/3487365a09898056546f68899ee94f286a3ca915/src/vs/workbench/contrib/browserView/electron-browser/tools/clickBrowserTool.ts) |
| `screenshot_page` / `screenshotPage` | [screenshotBrowserTool.ts](https://github.com/microsoft/vscode/blob/3487365a09898056546f68899ee94f286a3ca915/src/vs/workbench/contrib/browserView/electron-browser/tools/screenshotBrowserTool.ts) |
| `read_page` / `readPage` | [readBrowserTool.ts](https://github.com/microsoft/vscode/blob/3487365a09898056546f68899ee94f286a3ca915/src/vs/workbench/contrib/browserView/electron-browser/tools/readBrowserTool.ts) |
| `run_playwright_code` / `runPlaywrightCode` | VS Code native Playwright code execution (no single tool source file — functionality available when `workbench.browser.enableChatTools: true`) |
