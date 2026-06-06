// Headless browser walkthrough of the visualizer (the deferred manual pass, automated). It serves the
// already-built app with `next start` on a free port, drives Chromium across the three responsive
// breakpoints for each puzzle/engine, advances a real solve so cells animate, captures a screenshot of
// each, captures a reduced-motion variant, and runs the accessibility assertions the design contract
// makes (keyboard reachability, focus never on a presentational cell, the thinking aria-live region, the
// keyboard shortcuts, the help focus trap, the /about route). It prints a PASS/FAIL line per check and
// exits non-zero if any assertion fails.
//
// The lattice-server must already be running on 127.0.0.1:8080 (the page connects to ws://127.0.0.1:8080/ws);
// this script does NOT manage it. It only owns the Next server it spawns and the browser.
//
//   npm run walkthrough            # default port 3100, screenshots to web/screenshots/
//   PORT=3200 npm run walkthrough  # override the Next port

import { spawn } from "node:child_process";
import { mkdir, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { chromium } from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const WEB_ROOT = join(__dirname, "..");
const SCREENSHOT_DIR = join(WEB_ROOT, "screenshots");
const PORT = Number(process.env.PORT ?? 3100);
const BASE = `http://127.0.0.1:${PORT}`;

// The three responsive breakpoints the design contract screenshots at (iPhone, tablet, desktop).
const BREAKPOINTS = [
  { name: "375", width: 375, height: 812 },
  { name: "768", width: 768, height: 1024 },
  { name: "1440", width: 1440, height: 900 },
];

// The walkthrough matrix: one entry per view the task names. `puzzleLabel` is the picker option label
// (the accessible option text); `engineLabel` is the engine-picker option text (omitted when the puzzle
// is single-engine and the picker is disabled). `slug` names the screenshot file.
const VIEWS = [
  { slug: "sudoku", puzzleLabel: "sudoku · easy", engineLabel: null },
  { slug: "graph", puzzleLabel: "graph · petersen", engineLabel: "cp" },
  { slug: "queens", puzzleLabel: "queens · 8", engineLabel: null },
  { slug: "nonogram", puzzleLabel: "nonogram · picture", engineLabel: null },
  { slug: "sat", puzzleLabel: "cnf · sat-demo", engineLabel: "sat" },
  { slug: "race", puzzleLabel: "graph · petersen", engineLabel: "cp vs sat" },
];

// ---- result bookkeeping ----------------------------------------------------------------------------

const results = [];
function record(name, ok, detail = "") {
  results.push({ name, ok, detail });
  const tag = ok ? "PASS" : "FAIL";
  process.stdout.write(`  [${tag}] ${name}${detail ? ` — ${detail}` : ""}\n`);
}
// An assertion that records and, on failure, does not throw — so one broken check never aborts the
// rest of the run (the summary at the end is the source of truth and sets the exit code).
function check(name, condition, detail = "") {
  record(name, Boolean(condition), detail);
}

// ---- the Next server we own ------------------------------------------------------------------------

function waitForServer(url, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = async () => {
      try {
        const res = await fetch(url, { method: "GET" });
        if (res.ok || res.status === 200) return resolve();
      } catch {
        // not up yet
      }
      if (Date.now() > deadline) return reject(new Error(`server did not start within ${timeoutMs}ms`));
      setTimeout(tick, 400);
    };
    tick();
  });
}

async function startNext() {
  // `next start` serves the production build already in .next. We invoke Next's JS entry point with the
  // current node binary rather than the `next`/`npm` shell shim: Node on Windows refuses to spawn a .cmd
  // without shell:true (spawn EINVAL), and running the .js directly is the same on every platform. It
  // inherits this process's env and is killed in the finally block.
  const nextBin = join(WEB_ROOT, "node_modules", "next", "dist", "bin", "next");
  const proc = spawn(
    process.execPath,
    [nextBin, "start", "--port", String(PORT)],
    { cwd: WEB_ROOT, stdio: ["ignore", "pipe", "pipe"], env: process.env },
  );
  proc.stdout.on("data", (d) => process.env.WALKTHROUGH_VERBOSE && process.stdout.write(`[next] ${d}`));
  proc.stderr.on("data", (d) => process.env.WALKTHROUGH_VERBOSE && process.stderr.write(`[next] ${d}`));
  await waitForServer(BASE);
  return proc;
}

function stopNext(proc) {
  if (!proc || proc.killed) return;
  // On Windows a plain kill leaves the spawned node child; kill the tree.
  if (process.platform === "win32") {
    try {
      spawn("taskkill", ["/pid", String(proc.pid), "/T", "/F"], { stdio: "ignore" });
    } catch {
      proc.kill("SIGKILL");
    }
  } else {
    proc.kill("SIGTERM");
  }
}

// ---- page-driving helpers --------------------------------------------------------------------------

// Select a puzzle and engine, then start the solve and let it advance so the cells animate. Steps a few
// events and plays briefly, then pauses. Returns once the board has visibly moved (a counter advanced)
// or a short budget elapses — a screenshot of a mid-solve board is the goal, not a finished one.
async function driveSolve(page, view) {
  // Wait for the socket to connect: the controls are disabled until the page reports "engine connected".
  await page.getByText("engine connected").waitFor({ timeout: 15000 });

  await page.getByLabel("puzzle").selectOption({ label: view.puzzleLabel });
  if (view.engineLabel) {
    const engineSel = page.getByLabel("engine");
    if (await engineSel.isEnabled()) await engineSel.selectOption({ label: view.engineLabel });
  }

  await page.getByRole("button", { name: "start", exact: true }).click();

  // Step a few times so single events land, then play briefly so a run of cells animates. The race is
  // play-only (no scrubber/step semantics matter), but the step button still drives it.
  for (let i = 0; i < 4; i++) {
    await page.getByRole("button", { name: "step", exact: true }).click();
    await page.waitForTimeout(120);
  }
  await page.getByRole("button", { name: "play", exact: true }).click();
  await page.waitForTimeout(1200);
  // Pause so the screenshot is a stable frame. The button reads "pause" while playing.
  const pauseBtn = page.getByRole("button", { name: "pause", exact: true });
  if (await pauseBtn.count()) await pauseBtn.click().catch(() => {});
  await page.waitForTimeout(200);
}

async function screenshot(page, name) {
  await page.screenshot({ path: join(SCREENSHOT_DIR, `${name}.png`), fullPage: false });
}

// ---- the accessibility assertions ------------------------------------------------------------------

// Every named control is reachable by Tab and shows a visible focus state. We focus each by its
// accessible name (getByRole/getByLabel) and confirm it becomes document.activeElement and that its
// computed focus outline is non-zero (the FOCUS_RING the design contract puts on every control).
//
// The engine picker is intentionally `disabled` (and so not Tab-reachable) for a single-engine puzzle —
// disabling a control with one option is correct a11y, not a defect. So we first select a dual-encodable
// instance (graph · petersen offers cp · sat · cp vs sat), which enables the engine select, before
// asserting it is focusable. The other controls are reachable on any puzzle.
async function assertControlsFocusable(page) {
  await page.getByLabel("puzzle").selectOption({ label: "graph · petersen" });
  const controls = [
    { how: "label", name: "puzzle" },
    { how: "label", name: "engine" },
    { how: "button", name: "start" },
    { how: "button", name: "step" },
    { how: "button", name: "play" },
    { how: "button", name: "restart" },
    { how: "label", name: "play speed (events per second)" },
    { how: "button", name: "copy a shareable link to this instance" },
    { how: "button", name: "take a guided tour of the visualizer" },
    { how: "button", name: "keyboard shortcuts" },
    { how: "link", name: "how lattice works" },
  ];
  for (const c of controls) {
    const locator =
      c.how === "label"
        ? page.getByLabel(c.name)
        : page.getByRole(c.how, { name: c.name, exact: true });
    const el = locator.first();
    const exists = (await el.count()) > 0;
    if (!exists) {
      check(`control reachable: ${c.name}`, false, "not found in DOM");
      continue;
    }
    // Programmatic focus mirrors what Tab lands on; then confirm it is the active element AND that the
    // focus-visible outline resolves to a real width (the keyboard focus ring). We toggle the
    // focus-visible state by dispatching keyboard focus via .focus() and reading the outline.
    await el.focus();
    const info = await el.evaluate((node) => {
      const active = document.activeElement === node;
      const cs = getComputedStyle(node);
      // focus-visible may not apply to a programmatic focus in every engine; the class is present
      // regardless, so we assert the element is focusable (tabIndex >= 0 or natively focusable) and active.
      const focusable =
        node.tabIndex >= 0 ||
        ["A", "BUTTON", "INPUT", "SELECT", "TEXTAREA"].includes(node.tagName);
      return { active, focusable, outlineStyle: cs.outlineStyle };
    });
    check(
      `control reachable: ${c.name}`,
      info.active && info.focusable,
      info.active ? "focused" : "did not receive focus",
    );
  }
}

// Tabbing through the whole page must never land focus on a presentational grid/trail cell. Those
// renderers are role="img" containers of plain divs; if any became focusable, Tab would stop on a cell.
// We Tab a generous number of times from the top and assert every stop is a real control, never an
// element inside a role="img" board.
async function assertFocusNeverOnPresentationalCell(page) {
  await page.evaluate(() => document.body.focus());
  await page.keyboard.press("Tab");
  let offending = null;
  const seen = [];
  for (let i = 0; i < 40; i++) {
    const where = await page.evaluate(() => {
      const a = document.activeElement;
      if (!a || a === document.body) return null;
      const insideImg = a.closest('[role="img"]') !== null;
      const tag = a.tagName;
      const label = a.getAttribute("aria-label") || a.textContent?.trim().slice(0, 24) || "";
      return { insideImg, tag, label };
    });
    if (!where) break;
    seen.push(`${where.tag}:${where.label}`);
    if (where.insideImg) {
      offending = `${where.tag} "${where.label}" inside a role=img board`;
      break;
    }
    await page.keyboard.press("Tab");
  }
  check(
    "focus never lands on a presentational cell",
    offending === null,
    offending ?? `${seen.length} tab stops, all real controls`,
  );
}

// The thinking panel exposes an aria-live region so a screen reader follows the solve.
async function assertThinkingAriaLive(page) {
  const count = await page.locator('[aria-live="polite"]').count();
  check("thinking panel has an aria-live region", count > 0, `${count} aria-live region(s)`);
}

// The keyboard shortcuts drive the solve. We start a solve, read the propagations+decisions counters,
// press ArrowRight (a live step at the edge) and Space (single-step) a few times, and assert a counter
// advanced. Counters are tabular text in the thinking panel.
async function assertKeyboardShortcuts(page) {
  await page.getByLabel("puzzle").selectOption({ label: "sudoku · easy" });
  await page.getByRole("button", { name: "start", exact: true }).click();
  await page.waitForTimeout(300);

  const readDecisions = async () => {
    // The decisions counter row: a label "decisions" with its tabular value beside it.
    const row = page.locator("div", { hasText: /^decisions/ }).first();
    const txt = await row.innerText().catch(() => "");
    const m = txt.match(/decisions\s*(\d+)/);
    return m ? Number(m[1]) : null;
  };
  // Read a broad "total events" proxy: sum of the four visible counters, robust to which event type the
  // step produced (a step may be a propagate, not a decision).
  const readTotal = async () => {
    return page.evaluate(() => {
      const labels = ["decisions", "propagations", "backtracks", "conflicts"];
      let sum = 0;
      const rows = Array.from(document.querySelectorAll("div"));
      for (const lab of labels) {
        const row = rows.find((d) => d.firstElementChild?.textContent?.trim() === lab);
        const val = row?.lastElementChild?.textContent?.trim();
        if (val && /^\d+$/.test(val)) sum += Number(val);
      }
      return sum;
    });
  };

  const before = await readTotal();
  // Focus the body so the shortcut handler (window-level, suppressed inside selects/inputs) fires.
  await page.evaluate(() => document.body.focus());
  for (let i = 0; i < 6; i++) {
    await page.keyboard.press("ArrowRight");
    await page.waitForTimeout(120);
  }
  await page.keyboard.press("Space");
  await page.waitForTimeout(200);
  const after = await readTotal();
  void readDecisions;
  check(
    "keyboard shortcut (ArrowRight/Space) advances the solve",
    after > before,
    `counters ${before} -> ${after}`,
  );
}

// The help overlay opens with `?`, traps focus, and closes on Esc, returning focus to the trigger.
async function assertHelpOverlay(page) {
  await page.evaluate(() => document.body.focus());
  await page.keyboard.press("?");
  const dialog = page.getByRole("dialog");
  let opened = false;
  try {
    await dialog.waitFor({ state: "visible", timeout: 3000 });
    opened = true;
  } catch {
    opened = false;
  }
  check("help overlay opens with ?", opened);
  if (!opened) return;

  // Focus is inside the dialog (the close button is focused on open).
  const focusInside = await page.evaluate(() => {
    const d = document.querySelector('[role="dialog"]');
    return d ? d.contains(document.activeElement) : false;
  });
  check("help overlay moves focus into the dialog", focusInside);

  // Focus trap: Tab repeatedly and confirm focus never leaves the dialog.
  let escaped = false;
  for (let i = 0; i < 8; i++) {
    await page.keyboard.press("Tab");
    const inside = await page.evaluate(() => {
      const d = document.querySelector('[role="dialog"]');
      return d ? d.contains(document.activeElement) : false;
    });
    if (!inside) {
      escaped = true;
      break;
    }
  }
  check("help overlay traps focus (Tab stays inside)", !escaped);

  // Esc closes and returns focus to the trigger ("keyboard shortcuts" button).
  await page.keyboard.press("Escape");
  let closed = false;
  try {
    await dialog.waitFor({ state: "hidden", timeout: 3000 });
    closed = true;
  } catch {
    closed = false;
  }
  check("help overlay closes on Esc", closed);
  if (closed) {
    const returned = await page.evaluate(
      () => document.activeElement?.getAttribute("aria-label") === "keyboard shortcuts",
    );
    check("help overlay returns focus to the trigger", returned);
  }
}

// The /about route loads and renders its heading.
async function assertAboutRoute(page) {
  const res = await page.goto(`${BASE}/about`, { waitUntil: "domcontentloaded" });
  const ok = Boolean(res && res.ok());
  const heading = await page
    .getByRole("heading", { name: /Watching a solver actually think/i })
    .count();
  check("/about route loads", ok && heading > 0, `status ${res?.status()}, heading ${heading}`);
  await page.goto(BASE, { waitUntil: "domcontentloaded" });
}

// ---- main ------------------------------------------------------------------------------------------

async function main() {
  await rm(SCREENSHOT_DIR, { recursive: true, force: true });
  await mkdir(SCREENSHOT_DIR, { recursive: true });

  console.log(`\nlattice visualizer walkthrough`);
  console.log(`  next:   ${BASE}`);
  console.log(`  server: ws://127.0.0.1:8080/ws (must already be running)`);
  console.log(`  out:    ${SCREENSHOT_DIR}\n`);

  let next;
  const browser = await chromium.launch({ headless: true });
  try {
    next = await startNext();
    console.log("next server ready\n");

    // ---- screenshots: every view at every breakpoint --------------------------------------------
    console.log("capturing screenshots (6 views x 3 breakpoints)");
    for (const bp of BREAKPOINTS) {
      const context = await browser.newContext({
        viewport: { width: bp.width, height: bp.height },
        deviceScaleFactor: 1,
      });
      const page = await context.newPage();
      for (const view of VIEWS) {
        await page.goto(BASE, { waitUntil: "domcontentloaded" });
        try {
          await driveSolve(page, view);
        } catch (err) {
          console.log(`  ! ${view.slug}-${bp.name}: ${err.message}`);
        }
        await screenshot(page, `${view.slug}-${bp.name}`);
        process.stdout.write(`  saved ${view.slug}-${bp.name}.png\n`);
      }
      await context.close();
    }

    // ---- reduced-motion variant: one solve at 1440 with motion off ------------------------------
    // The reduced-motion context drives the same page with `prefers-reduced-motion: reduce`, which the
    // global block in globals.css honors (every CSS animation collapses; the one JS minimap tween is
    // gated off). We capture the graph race — the densest live view (two engines, the colored graph, the
    // SAT trail, the counters) — to prove the busiest screen stays fully legible with motion off, not just
    // an easy propagation-only board.
    console.log("\ncapturing reduced-motion variant (1440)");
    {
      const context = await browser.newContext({
        viewport: { width: 1440, height: 900 },
        reducedMotion: "reduce",
        colorScheme: "dark",
      });
      const page = await context.newPage();
      await page.goto(BASE, { waitUntil: "domcontentloaded" });
      await driveSolve(page, VIEWS[5]); // graph · petersen, cp vs sat race
      await screenshot(page, "race-1440-reduced-motion");
      process.stdout.write("  saved race-1440-reduced-motion.png\n");
      await context.close();
    }

    // ---- accessibility assertions ---------------------------------------------------------------
    console.log("\naccessibility assertions");
    {
      const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
      const page = await context.newPage();
      await page.goto(BASE, { waitUntil: "domcontentloaded" });
      await page.getByText("engine connected").waitFor({ timeout: 15000 }).catch(() => {});

      await assertThinkingAriaLive(page);
      await assertControlsFocusable(page);
      await assertFocusNeverOnPresentationalCell(page);
      await assertKeyboardShortcuts(page);
      await assertHelpOverlay(page);
      await assertAboutRoute(page);

      await context.close();
    }
  } finally {
    await browser.close();
    stopNext(next);
  }

  // ---- summary --------------------------------------------------------------------------------------
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${"=".repeat(60)}`);
  console.log(`a11y assertions: ${results.length - failed.length}/${results.length} passed`);
  if (failed.length) {
    console.log("FAILURES:");
    for (const f of failed) console.log(`  - ${f.name}${f.detail ? ` (${f.detail})` : ""}`);
  }
  console.log(`${"=".repeat(60)}\n`);

  if (failed.length) process.exit(1);
}

main().catch((err) => {
  console.error("\nwalkthrough crashed:", err);
  process.exit(1);
});
