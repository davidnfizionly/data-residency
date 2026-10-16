// Dev-only API proxy for the audit console (Vite middleware, never shipped to the browser).
// - Signs calls to the router's IAM-authorized HTTP API with the local AWS credentials (SigV4).
// - Invokes the router directly for the account-guardrail (SCP) simulation.
// - Opens, inspects and closes a real violating pull request with git and gh.
// - Builds the compliance history from Git and pull request history.
// The API URL, credentials and account IDs stay on this machine.

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SignatureV4 } from '@smithy/signature-v4';
import { Sha256 } from '@aws-crypto/sha256-js';
import { fromNodeProviderChain } from '@aws-sdk/credential-providers';
import { LambdaClient, InvokeCommand } from '@aws-sdk/client-lambda';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const REPO = 'davidnfizionly/data-residency';
const REGION = 'eu-west-1';
const OTHER_REGION = { 'eu-west-1': 'us-east-1', 'us-east-1': 'eu-west-1' };

const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...opts }).trim();
// Masks account IDs and organization, root and policy IDs in anything shown in the browser.
const redact = (text) => String(text)
  .replace(/(?<![0-9a-zA-Z])\d{12}(?![0-9a-zA-Z])/g, '<account-id>')
  .replace(/\b(o|r|p)-[a-z0-9]{4,32}\b/g, '$1-<id>');

let apiBase;
const apiEndpoint = () => (apiBase ??= run('terraform', ['-chdir=infra/stack', 'output', '-raw', 'api_endpoint']));
const credentials = fromNodeProviderChain();
const signer = new SignatureV4({ service: 'execute-api', region: REGION, credentials, sha256: Sha256 });
const lambda = new LambdaClient({ region: REGION, credentials });

async function callApi(method, route, query, body) {
  const url = new URL(route, apiEndpoint());
  for (const [k, v] of Object.entries(query ?? {})) url.searchParams.set(k, v);
  const payload = body ? JSON.stringify(body) : undefined;
  const signed = await signer.sign({
    method,
    protocol: url.protocol,
    hostname: url.hostname,
    path: url.pathname,
    query: Object.fromEntries(url.searchParams),
    headers: { host: url.hostname, ...(payload ? { 'content-type': 'application/json' } : {}) },
    body: payload,
  });
  const started = performance.now();
  const res = await fetch(url, { method, headers: signed.headers, body: payload });
  const text = redact(await res.text());
  return { status: res.status, ms: Math.round(performance.now() - started), body: JSON.parse(text) };
}

async function simulateScp(tenantId, tenants) {
  const tenant = tenants.find((t) => t.tenant_id === tenantId);
  const target = OTHER_REGION[tenant.tenant_region];
  const out = await lambda.send(new InvokeCommand({
    FunctionName: 'data-residency-router',
    Payload: JSON.stringify({ route: 'POST /records', tenant_id: tenantId, payload: { note: 'console guardrail test' }, simulate_storage_region: target }),
  }));
  const result = JSON.parse(redact(Buffer.from(out.Payload).toString()));
  return { forced_region: target, statusCode: result.statusCode, body: JSON.parse(result.body) };
}

function openViolationPr(tenantId, tenants) {
  const tenant = tenants.find((t) => t.tenant_id === tenantId);
  const target = OTHER_REGION[tenant.tenant_region];
  const stamp = new Date().toISOString().replace(/[-:]/g, '').slice(0, 13);
  const branch = `demo/route-${tenantId}-to-${target}-${stamp}`;
  const worktree = path.join(os.tmpdir(), `dr-violation-${stamp}`);
  run('git', ['fetch', '-q', 'origin', 'main']);
  run('git', ['worktree', 'add', '-q', '-b', branch, worktree, 'origin/main']);
  try {
    const file = path.join(worktree, 'infra/stack/tenants.json');
    const registry = JSON.parse(readFileSync(file, 'utf8'));
    registry[tenantId].storage_region = target;
    writeFileSync(file, JSON.stringify(registry, null, 2) + '\n');
    const title = `Route ${tenantId} storage to ${target}`;
    run('git', ['-C', worktree, 'commit', '-q', '-am', title]);
    run('git', ['-C', worktree, 'push', '-q', '-u', 'origin', branch]);
    const url = run('gh', ['pr', 'create', '-R', REPO, '--base', 'main', '--head', branch, '--title', title,
      '--body', `Changes the storage region of ${tenantId} from ${tenant.tenant_region} to ${target}. Opened from the audit console to demonstrate the residency policy check.`]);
    return { url, number: Number(url.split('/').pop()), branch, title };
  } finally {
    run('git', ['worktree', 'remove', '--force', worktree]);
    run('git', ['branch', '-q', '-D', branch]);
  }
}

function prStatus(number) {
  const pr = JSON.parse(run('gh', ['pr', 'view', String(number), '-R', REPO, '--json', 'number,title,url,state,mergeStateStatus,statusCheckRollup']));
  const check = (pr.statusCheckRollup ?? []).find((c) => c.name === 'plan-and-policy');
  let output = [];
  if (check?.conclusion === 'FAILURE') {
    const runId = check.detailsUrl.match(/runs\/(\d+)/)[1];
    output = run('gh', ['run', 'view', runId, '-R', REPO, '--log-failed'])
      .split('\n').map((l) => l.split('\t').pop().replace(/^\S+Z /, '').replace(/\x1b\[[0-9;]*m/g, ''))
      .filter((l) => /OPA residency check|RESIDENCY VIOLATION|Process completed with exit code/.test(l));
  }
  return { number: pr.number, title: pr.title, url: pr.url, state: pr.state, merge_state: pr.mergeStateStatus,
    check: check ? { status: check.status, conclusion: check.conclusion, url: check.detailsUrl } : null, output: output.map(redact) };
}

function history() {
  run('git', ['fetch', '-q', 'origin', 'main']);
  const commits = run('git', ['log', 'origin/main', '--format=%H%x1f%h%x1f%aI%x1f%an%x1f%s', '--', 'infra', 'policy', 'lambdas', '.github'])
    .split('\n').filter(Boolean).map((line) => {
      const [sha, short, date, author, subject] = line.split('\x1f');
      const files = run('git', ['show', '--format=', '--name-only', sha]).split('\n');
      return { kind: 'commit', sha: short, date, author, subject,
        routing: files.includes('infra/stack/tenants.json'), policy: files.some((f) => f.startsWith('policy/')),
        guardrail: files.some((f) => f.startsWith('infra/org/')) };
    });
  const prs = JSON.parse(run('gh', ['pr', 'list', '-R', REPO, '--state', 'all', '--limit', '50',
    '--json', 'number,title,state,createdAt,mergedAt,closedAt,url,statusCheckRollup']))
    .map((p) => {
      const check = (p.statusCheckRollup ?? []).find((c) => c.name === 'plan-and-policy');
      return { kind: 'pr', number: p.number, title: p.title, state: p.state, url: p.url,
        date: p.mergedAt ?? p.closedAt ?? p.createdAt, check: check?.conclusion ?? check?.status ?? null };
    });
  return [...commits, ...prs].sort((a, b) => new Date(b.date) - new Date(a.date));
}

async function readJson(req) {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  return raw ? JSON.parse(raw) : {};
}

export function auditApi() {
  return {
    name: 'audit-api',
    configureServer(server) {
      server.middlewares.use('/api', async (req, res) => {
        const url = new URL(req.url, 'http://localhost');
        const send = (status, data) => { res.statusCode = status; res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(data)); };
        try {
          const tenants = () => callApi('GET', 'tenants').then((r) => r.body.tenants);
          const key = `${req.method} ${url.pathname}`;
          if (key === 'GET /tenants') return send(200, (await callApi('GET', 'tenants')).body);
          if (key === 'GET /traces') return send(200, (await callApi('GET', 'traces', { tenant_id: url.searchParams.get('tenant_id') })).body);
          if (key === 'POST /records') {
            const { tenant_id } = await readJson(req);
            const r = await callApi('POST', 'records', null, { tenant_id, payload: { note: 'synthetic record from the audit console' } });
            return send(200, { http_status: r.status, ms: r.ms, ...r.body });
          }
          if (key === 'POST /simulate/scp') return send(200, await simulateScp((await readJson(req)).tenant_id, await tenants()));
          if (key === 'POST /simulate/pr') return send(200, openViolationPr((await readJson(req)).tenant_id, await tenants()));
          const pr = url.pathname.match(/^\/pr\/(\d+)(\/close)?$/);
          if (pr && req.method === 'GET') return send(200, prStatus(pr[1]));
          if (pr?.[2] && req.method === 'POST') {
            run('gh', ['pr', 'close', pr[1], '-R', REPO, '--delete-branch', '--comment', 'Blocked by the residency policy check. Closed from the audit console without merging.']);
            return send(200, prStatus(pr[1]));
          }
          if (key === 'GET /history') return send(200, { entries: history() });
          return send(404, { error: `no route ${key}` });
        } catch (err) {
          return send(500, { error: redact(err.stderr?.toString() || err.message) });
        }
      });
    },
  };
}
