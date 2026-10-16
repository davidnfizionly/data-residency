// Headless end-to-end run of the audit console (automated captures).
// Requires the dev server on 127.0.0.1:5173. Usage: node e2e/flow.mjs <screenshot-dir>
// E2E_SKIP_PR=1 skips opening a real violating pull request (the rest of the flow still runs).
// Playwright is resolved from PLAYWRIGHT_MODULE (path to an installed playwright package) or the default resolution.
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? 'playwright');

const out = process.argv[2] ?? '.';
const log = (msg) => console.log(`${new Date().toISOString()} ${msg}`);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
const section = (title) => page.locator('section', { has: page.getByRole('heading', { name: title }) });

await page.goto('http://127.0.0.1:5173/');
await page.getByRole('button', { name: 'Synthetic Tenant EU 01' }).waitFor();
await page.getByText(/stored records traced|No stored records/).waitFor({ timeout: 30000 });
log('tenant view loaded');

await page.getByRole('button', { name: 'Write a test record now' }).click();
await page.getByRole('button', { name: 'Write a test record now' }).waitFor({ timeout: 30000 });
await page.getByText(/All \d+ stored records traced to Ireland/).waitFor({ timeout: 30000 });
await page.getByRole('button', { name: /Show the \d+ spans/ }).first().click();
await section("Where is this tenant's data?").screenshot({ path: `${out}/auto-01-console-tenant-evidence.png` });
log('test record written, trace evidence shown');

await page.getByRole('button', { name: 'Force the write into the wrong account' }).click();
await page.getByText(/REFUSED by the US account guardrail/).waitFor({ timeout: 30000 });
log('SCP simulation refused');

if (process.env.E2E_SKIP_PR) {
  await page.reload();
  await page.getByText('PR blocked by policy').first().waitFor({ timeout: 60000 });
  log('E2E_SKIP_PR set: no new pull request opened; history checked');
  await browser.close();
  process.exit(0);
}

await page.getByRole('button', { name: 'Open the violating pull request' }).click();
await page.getByText(/Pull request #\d+/).waitFor({ timeout: 60000 });
log('violating pull request opened');
await page.getByText('FAILED - merge blocked').waitFor({ timeout: 300000 });
await page.getByText('RESIDENCY VIOLATION', { exact: false }).first().waitFor({ timeout: 30000 });
await section('Violation simulator').screenshot({ path: `${out}/auto-02-console-violation-simulator.png` });
log('policy check failed, output shown');

await page.getByRole('button', { name: 'Close it without merging' }).click();
await page.getByText('CLOSED').waitFor({ timeout: 60000 });
log('pull request closed without merging');

await page.reload();
await page.getByText('PR blocked by policy').first().waitFor({ timeout: 60000 });
await section('Compliance history').screenshot({ path: `${out}/auto-03-console-history.png` });
log('history shows the blocked pull request');
await browser.close();
