import { useCallback, useEffect, useState } from 'react';

const PLACES = {
  'eu-west-1': { name: 'Ireland', area: 'European Union', account: 'EU account' },
  'us-east-1': { name: 'N. Virginia', area: 'United States', account: 'US account' },
};
const place = (region) => `${PLACES[region]?.name ?? region} (${region})`;

async function api(path, options) {
  const res = await fetch(`/api${path}`, options);
  const data = await res.json();
  if (!res.ok) throw new Error(data.error ?? `HTTP ${res.status}`);
  return data;
}
const post = (path, body) => api(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body ?? {}) });

function Badge({ tone, children }) {
  const tones = {
    ok: 'bg-green-700 text-white',
    bad: 'bg-red-700 text-white',
    warn: 'bg-amber-500 text-black',
    info: 'bg-slate-700 text-white',
  };
  return <span className={`inline-block rounded-md px-3 py-1 text-base font-bold ${tones[tone]}`}>{children}</span>;
}

function Panel({ title, subtitle, children }) {
  return (
    <section className="rounded-xl border-2 border-slate-300 bg-white p-6 shadow-sm">
      <h2 className="text-2xl font-bold text-slate-900">{title}</h2>
      {subtitle && <p className="mt-1 text-lg text-slate-700">{subtitle}</p>}
      <div className="mt-5">{children}</div>
    </section>
  );
}

function Button({ onClick, busy, tone = 'primary', children }) {
  const tones = {
    primary: 'bg-blue-800 hover:bg-blue-900 text-white',
    danger: 'bg-red-700 hover:bg-red-800 text-white',
    plain: 'bg-white hover:bg-slate-100 text-slate-900 border-2 border-slate-400',
  };
  return (
    <button onClick={onClick} disabled={busy} className={`rounded-lg px-5 py-3 text-lg font-semibold disabled:opacity-50 ${tones[tone]}`}>
      {busy ? 'Working...' : children}
    </button>
  );
}

function Raw({ children }) {
  return <pre className="mt-3 overflow-x-auto whitespace-pre-wrap break-words rounded-lg bg-slate-900 p-4 font-mono text-base text-green-200">{children}</pre>;
}

function outcomeOf(root) {
  if (root.outcome === 'stored' && root['residency.compliant']) return { tone: 'ok', label: 'Stored in the right region' };
  if (root.outcome === 'stored') return { tone: 'bad', label: 'Stored in the WRONG region' };
  if (root.outcome === 'denied_by_scp') return { tone: 'warn', label: 'Blocked by the account guardrail' };
  return { tone: 'info', label: 'Failed (not stored)' };
}

function sentenceFor(t) {
  const r = t.root;
  if (r.outcome === 'stored') {
    return r['residency.compliant']
      ? `Written in ${place(r.storage_region)}, which matches the tenant's contract region.`
      : `Written in ${place(r.storage_region)}, but the contract region is ${place(r.tenant_region)}.`;
  }
  if (r.outcome === 'denied_by_scp') {
    return `A write was attempted in ${place(r.storage_region)}. The ${PLACES[r.storage_region]?.account} refused it, so nothing was stored.`;
  }
  return `The write did not complete, so nothing was stored. ${t.status_message ?? ''}`;
}

function TenantView({ tenants, tenantId, setTenantId }) {
  const [traces, setTraces] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [open, setOpen] = useState(null);
  const tenant = tenants.find((t) => t.tenant_id === tenantId);

  const load = useCallback(async () => {
    setError(null);
    try {
      const list = (await api(`/traces?tenant_id=${tenantId}`)).traces;
      setTraces(list);
      return list;
    } catch (e) { setError(e.message); return []; }
  }, [tenantId]);
  useEffect(() => { setTraces(null); load(); }, [load]);

  const write = async () => {
    setBusy(true);
    try {
      const written = await post('/records', { tenant_id: tenantId });
      // Spans reach CloudWatch Logs a few seconds after the write: poll until this trace is visible.
      for (let i = 0; i < 12; i += 1) {
        await new Promise((r) => setTimeout(r, 2500));
        if ((await load()).some((t) => t.trace_id === written.trace_id)) break;
      }
    } catch (e) { setError(e.message); }
    setBusy(false);
  };

  const stored = (traces ?? []).filter((t) => t.root.outcome === 'stored');
  const allInPlace = stored.length > 0 && stored.every((t) => t.root.storage_region === tenant.tenant_region);

  return (
    <Panel title="Where is this tenant's data?" subtitle="Pick a tenant. The answer comes from the runtime traces of real writes, not from configuration.">
      <div className="flex flex-wrap gap-3">
        {tenants.map((t) => (
          <button key={t.tenant_id} onClick={() => setTenantId(t.tenant_id)}
            className={`rounded-lg border-2 px-5 py-3 text-lg font-semibold ${t.tenant_id === tenantId ? 'border-blue-800 bg-blue-800 text-white' : 'border-slate-400 bg-white text-slate-900'}`}>
            {t.label}
          </button>
        ))}
      </div>

      {tenant && (
        <div className="mt-6 rounded-lg border-2 border-slate-300 bg-slate-50 p-5">
          <p className="text-2xl leading-snug text-slate-900">
            <strong>{tenant.label}</strong> has a contract that keeps its personal data in <strong>{PLACES[tenant.tenant_region].area}</strong>.
            Its records are routed to <strong>{place(tenant.storage_region)}</strong>, table <code className="font-mono">{tenant.table}</code> in the {PLACES[tenant.storage_region].account}.
          </p>
          <div className="mt-4 flex flex-wrap items-center gap-3">
            {traces && (stored.length === 0
              ? <Badge tone="info">No stored records traced yet</Badge>
              : allInPlace
                ? <Badge tone="ok">All {stored.length} stored records traced to {place(tenant.tenant_region)}</Badge>
                : <Badge tone="bad">Some stored records are outside {place(tenant.tenant_region)}</Badge>)}
            <Button onClick={write} busy={busy}>Write a test record now</Button>
            <Button onClick={load} tone="plain">Refresh</Button>
          </div>
        </div>
      )}

      {error && <Raw>{error}</Raw>}

      <h3 className="mt-6 text-xl font-bold text-slate-900">Trace evidence (newest first)</h3>
      {!traces && !error && <p className="mt-2 text-lg text-slate-700">Loading traces...</p>}
      {traces?.length === 0 && <p className="mt-2 text-lg text-slate-700">No traces in the last 7 days.</p>}
      <ul className="mt-3 space-y-3">
        {traces?.slice(0, 8).map((t) => {
          const o = outcomeOf(t.root);
          return (
            <li key={t.trace_id} className="rounded-lg border-2 border-slate-200 p-4">
              <div className="flex flex-wrap items-center gap-3">
                <Badge tone={o.tone}>{o.label}</Badge>
                <span className="text-lg text-slate-800">{new Date(t.start_time).toUTCString()}</span>
                {t.root['simulation.misroute'] && <Badge tone="info">Simulated misroute</Badge>}
              </div>
              <p className="mt-2 text-lg text-slate-900">{sentenceFor(t)}</p>
              <p className="mt-1 text-base text-slate-700">
                tenant_region <b>{t.root.tenant_region}</b> - storage_region <b>{t.root.storage_region}</b> - data_classification <b>{t.root.data_classification}</b> - trace <code className="font-mono">{t.trace_id}</code> - commit <code className="font-mono">{String(t.root['deployment.git_commit']).slice(0, 7)}</code>
              </p>
              <button className="mt-2 text-base font-semibold text-blue-800 underline" onClick={() => setOpen(open === t.trace_id ? null : t.trace_id)}>
                {open === t.trace_id ? 'Hide spans' : `Show the ${t.spans.length} spans`}
              </button>
              {open === t.trace_id && (
                <table className="mt-2 w-full text-left text-base">
                  <thead><tr className="border-b-2 border-slate-300"><th className="py-1">Span</th><th>storage_region</th><th>Status</th><th>Duration</th></tr></thead>
                  <tbody>
                    {[...t.spans].sort((a, b) => (a.parent_span_id ? 1 : 0) - (b.parent_span_id ? 1 : 0)).map((s) => (
                      <tr key={s.span_id} className="border-b border-slate-200">
                        <td className="py-1 font-mono">{s.name}</td><td>{s.attributes.storage_region ?? '-'}</td>
                        <td className={s.status === 'ERROR' ? 'font-bold text-red-700' : 'text-green-800'}>{s.status}</td><td>{s.duration_ms} ms</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </li>
          );
        })}
      </ul>
    </Panel>
  );
}

function Simulator({ tenants, tenantId }) {
  const tenant = tenants.find((t) => t.tenant_id === tenantId);
  const [scp, setScp] = useState(null);
  const [scpBusy, setScpBusy] = useState(false);
  const [pr, setPr] = useState(null);
  const [prBusy, setPrBusy] = useState(false);
  const [error, setError] = useState(null);
  const other = tenant?.tenant_region === 'eu-west-1' ? 'us-east-1' : 'eu-west-1';

  useEffect(() => { setScp(null); }, [tenantId]);

  useEffect(() => {
    if (!pr || pr.state !== 'OPEN' || pr.check?.status === 'COMPLETED') return undefined;
    const id = setInterval(async () => { try { setPr(await api(`/pr/${pr.number}`)); } catch (e) { setError(e.message); } }, 5000);
    return () => clearInterval(id);
  }, [pr]);

  const runScp = async () => {
    setScpBusy(true); setError(null);
    try { setScp(await post('/simulate/scp', { tenant_id: tenantId })); } catch (e) { setError(e.message); }
    setScpBusy(false);
  };
  const openPr = async () => {
    setPrBusy(true); setError(null);
    try { const opened = await post('/simulate/pr', { tenant_id: tenantId }); setPr(await api(`/pr/${opened.number}`)); } catch (e) { setError(e.message); }
    setPrBusy(false);
  };
  const closePr = async () => {
    setPrBusy(true);
    try { setPr(await post(`/pr/${pr.number}/close`)); } catch (e) { setError(e.message); }
    setPrBusy(false);
  };

  if (!tenant) return null;
  const blocked = pr?.check?.conclusion === 'FAILURE';
  return (
    <Panel title="Violation simulator" subtitle={`Try to move ${tenant.label}'s data to ${place(other)} and watch each layer stop it.`}>
      <div className="grid gap-6 lg:grid-cols-2">
        <div className="rounded-lg border-2 border-slate-300 p-5">
          <h3 className="text-xl font-bold text-slate-900">1. A developer changes the routing</h3>
          <p className="mt-1 text-lg text-slate-800">Opens a real pull request that sets this tenant's storage region to {other}. The policy check runs on the Terraform plan before anything is deployed.</p>
          <div className="mt-4 flex flex-wrap gap-3">
            <Button onClick={openPr} busy={prBusy && !pr} tone="danger">Open the violating pull request</Button>
            {pr?.state === 'OPEN' && <Button onClick={closePr} busy={prBusy} tone="plain">Close it without merging</Button>}
          </div>
          {pr && (
            <div className="mt-4 space-y-2 text-lg">
              <p><a className="font-semibold text-blue-800 underline" href={pr.url} target="_blank" rel="noreferrer">Pull request #{pr.number}</a>: {pr.title}</p>
              <p>Policy check: {!pr.check || pr.check.status !== 'COMPLETED'
                ? <Badge tone="info">Running...</Badge>
                : blocked ? <Badge tone="bad">FAILED - merge blocked</Badge> : <Badge tone="ok">{pr.check.conclusion}</Badge>}
                {' '}Pull request: <Badge tone="info">{pr.state}</Badge></p>
              {blocked && <p className="text-slate-900">The change never reaches AWS: the pipeline only deploys from main, and main only accepts pull requests whose policy check passed.</p>}
              {pr.output?.length > 0 && <Raw>{pr.output.join('\n')}</Raw>}
            </div>
          )}
        </div>

        <div className="rounded-lg border-2 border-slate-300 p-5">
          <h3 className="text-xl font-bold text-slate-900">2. Someone bypasses CI entirely</h3>
          <p className="mt-1 text-lg text-slate-800">Calls the router directly and forces this tenant's write into the {PLACES[other].account} in {other}, as a bug or a compromised pipeline would.</p>
          <div className="mt-4"><Button onClick={runScp} busy={scpBusy} tone="danger">Force the write into the wrong account</Button></div>
          {scp && (
            <div className="mt-4 space-y-2 text-lg">
              <p>Result: {scp.body.outcome === 'denied_by_scp'
                ? <Badge tone="warn">REFUSED by the {PLACES[scp.forced_region].account} guardrail (SCP)</Badge>
                : <Badge tone="bad">{scp.body.outcome}</Badge>}</p>
              <p className="text-slate-900">Nothing was stored in {place(scp.forced_region)}. The attempt is recorded as trace <code className="font-mono">{scp.body.trace_id}</code>.</p>
              <Raw>{scp.body.error}</Raw>
            </div>
          )}
        </div>
      </div>
      {error && <Raw>{error}</Raw>}
    </Panel>
  );
}

function History() {
  const [entries, setEntries] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => { api('/history').then((d) => setEntries(d.entries)).catch((e) => setError(e.message)); }, []);
  return (
    <Panel title="Compliance history" subtitle="Every change to infrastructure, routing or policy, from the Git history and pull requests of the repository.">
      {error && <Raw>{error}</Raw>}
      {!entries && !error && <p className="text-lg text-slate-700">Loading history...</p>}
      <ol className="space-y-3 border-l-4 border-slate-300 pl-5">
        {entries?.map((e) => (
          <li key={`${e.kind}-${e.sha ?? e.number}`} className="text-lg">
            <span className="text-slate-700">{new Date(e.date).toUTCString()}</span>
            <div className="mt-1 flex flex-wrap items-center gap-2">
              {e.kind === 'pr' ? (
                <>
                  <Badge tone={e.state === 'MERGED' ? 'ok' : e.check === 'FAILURE' ? 'bad' : 'info'}>
                    {e.state === 'MERGED' ? 'PR merged' : e.check === 'FAILURE' ? 'PR blocked by policy' : `PR ${e.state.toLowerCase()}`}
                  </Badge>
                  <a className="font-semibold text-blue-800 underline" href={e.url} target="_blank" rel="noreferrer">#{e.number}</a>
                  <span className="text-slate-900">{e.title}</span>
                </>
              ) : (
                <>
                  <Badge tone="info">Commit</Badge>
                  {e.routing && <Badge tone="warn">Routing change</Badge>}
                  {e.policy && <Badge tone="warn">Policy change</Badge>}
                  {e.guardrail && <Badge tone="warn">Guardrail change</Badge>}
                  <code className="font-mono text-slate-800">{e.sha}</code>
                  <span className="text-slate-900">{e.subject}</span>
                </>
              )}
            </div>
          </li>
        ))}
      </ol>
    </Panel>
  );
}

export default function App() {
  const [tenants, setTenants] = useState(null);
  const [tenantId, setTenantId] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => {
    api('/tenants').then((d) => { setTenants(d.tenants); setTenantId(d.tenants[0]?.tenant_id); }).catch((e) => setError(e.message));
  }, []);

  return (
    <main className="mx-auto max-w-6xl space-y-6 p-6 text-slate-900">
      <header>
        <h1 className="text-4xl font-extrabold">Data Residency Audit Console</h1>
        <p className="mt-2 text-xl text-slate-800">Proof, per tenant, that personal data stays in its contract region: Git review, account guardrails and runtime traces. All tenants are synthetic.</p>
      </header>
      {error && <Raw>{error}</Raw>}
      {tenants && <TenantView tenants={tenants} tenantId={tenantId} setTenantId={setTenantId} />}
      {tenants && <Simulator tenants={tenants} tenantId={tenantId} />}
      <History />
    </main>
  );
}
