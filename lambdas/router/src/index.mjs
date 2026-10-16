// Regional router. Looks up the tenant's assigned region in the registry, assumes the writer role
// of that region's data plane with a tenant_region session tag, and writes the record there.
// Every write emits OpenTelemetry spans carrying tenant_region, data_classification and storage_region.
// Spans are written as JSON lines to stdout (CloudWatch Logs) and read back by GET /traces.

import { context, trace, SpanKind, SpanStatusCode } from '@opentelemetry/api';
import { BasicTracerProvider, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { ExportResultCode, hrTimeToMilliseconds } from '@opentelemetry/core';
import { STSClient, AssumeRoleCommand } from '@aws-sdk/client-sts';
import { DynamoDBClient, PutItemCommand } from '@aws-sdk/client-dynamodb';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { CloudWatchLogsClient, FilterLogEventsCommand } from '@aws-sdk/client-cloudwatch-logs';
import { createHash, randomUUID } from 'node:crypto';

const REGISTRY = JSON.parse(process.env.TENANT_REGISTRY);
const DATA_PLANES = JSON.parse(process.env.DATA_PLANES);
const GIT_COMMIT = process.env.GIT_COMMIT ?? 'unknown';
const LOG_GROUP = process.env.LOG_GROUP;
const REGISTRY_SHA256 = createHash('sha256').update(process.env.TENANT_REGISTRY).digest('hex');
const ZONE_OF_REGION = Object.fromEntries(Object.entries(DATA_PLANES).map(([region, p]) => [region, p.zone]));

// Account IDs never leave the function: they are masked in span messages and responses.
const redact = (text) => String(text).replace(/(?<![0-9a-zA-Z])\d{12}(?![0-9a-zA-Z])/g, '<account-id>');

class StdoutSpanExporter {
  export(spans, done) {
    for (const span of spans) {
      const ctx = span.spanContext();
      const parent = span.parentSpanContext?.spanId ?? span.parentSpanId ?? null;
      process.stdout.write(JSON.stringify({
        type: 'otel-span',
        trace_id: ctx.traceId,
        span_id: ctx.spanId,
        parent_span_id: parent,
        name: span.name,
        start_time: new Date(hrTimeToMilliseconds(span.startTime)).toISOString(),
        duration_ms: Math.round(hrTimeToMilliseconds(span.duration) * 100) / 100,
        status: span.status.code === SpanStatusCode.ERROR ? 'ERROR' : 'OK',
        status_message: span.status.message ?? null,
        attributes: span.attributes,
        resource: span.resource.attributes,
      }) + '\n');
    }
    done({ code: ExportResultCode.SUCCESS });
  }
  shutdown() { return Promise.resolve(); }
  forceFlush() { return Promise.resolve(); }
}

const provider = new BasicTracerProvider({
  resource: resourceFromAttributes({
    'service.name': 'data-residency-router',
    'cloud.provider': 'aws',
    'cloud.region': process.env.AWS_REGION,
    'deployment.git_commit': GIT_COMMIT,
  }),
  spanProcessors: [new SimpleSpanProcessor(new StdoutSpanExporter())],
});
const tracer = provider.getTracer('data-residency-router');

const sts = new STSClient({ region: process.env.AWS_REGION });
const logs = new CloudWatchLogsClient({ region: process.env.AWS_REGION });
const credentialCache = new Map();

async function writerCredentials(roleArn, tenantZone) {
  const key = `${roleArn}|${tenantZone}`;
  const cached = credentialCache.get(key);
  if (cached && cached.expiration.getTime() - Date.now() > 60_000) return cached;
  const out = await sts.send(new AssumeRoleCommand({
    RoleArn: roleArn,
    RoleSessionName: `router-${tenantZone}`,
    Tags: [{ Key: 'tenant_region', Value: tenantZone }],
    DurationSeconds: 900,
  }));
  const creds = {
    accessKeyId: out.Credentials.AccessKeyId,
    secretAccessKey: out.Credentials.SecretAccessKey,
    sessionToken: out.Credentials.SessionToken,
    expiration: out.Credentials.Expiration,
  };
  credentialCache.set(key, creds);
  return creds;
}

async function inSpan(parentCtx, name, attributes, fn) {
  const span = tracer.startSpan(name, { kind: SpanKind.CLIENT, attributes }, parentCtx);
  try {
    return await fn();
  } catch (err) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: redact(err.message) });
    throw err;
  } finally {
    span.end();
  }
}

const reply = (statusCode, body) => ({
  statusCode,
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(body),
});

async function writeRecord(tenantId, payload, simulatedRegion) {
  const tenant = REGISTRY[tenantId];
  if (!tenant) return reply(404, { error: `unknown tenant ${tenantId}` });

  const target = simulatedRegion ?? tenant.storage_region;
  const plane = DATA_PLANES[target];
  if (!plane) return reply(400, { error: `no data plane in ${target}` });

  const tenantZone = ZONE_OF_REGION[tenant.tenant_region];
  const recordId = randomUUID();
  const base = { tenant_id: tenantId, tenant_region: tenant.tenant_region };
  const root = tracer.startSpan('pii.write', {
    kind: SpanKind.SERVER,
    attributes: {
      ...base,
      data_classification: 'pii',
      record_id: recordId,
      'routing.storage_region': tenant.storage_region,
      'routing.registry_sha256': REGISTRY_SHA256,
      'deployment.git_commit': GIT_COMMIT,
      'simulation.misroute': Boolean(simulatedRegion),
    },
  });
  const ctx = trace.setSpan(context.active(), root);
  const traceId = root.spanContext().traceId;

  let storageRegion = target;
  try {
    const credentials = await inSpan(ctx, 'sts.AssumeRole', { ...base, 'target.zone': plane.zone, 'session_tag.tenant_region': tenantZone },
      () => writerCredentials(plane.role_arn, tenantZone));
    const ddb = new DynamoDBClient({ region: target, credentials });
    // storage_region is read from the client that performs the write, not from the registry.
    storageRegion = await ddb.config.region();
    root.setAttribute('storage_region', storageRegion);

    await inSpan(ctx, 'dynamodb.PutItem', { ...base, data_classification: 'pii', storage_region: storageRegion, 'aws.dynamodb.table': plane.table },
      () => ddb.send(new PutItemCommand({
        TableName: plane.table,
        Item: {
          tenant_id: { S: tenantId },
          record_id: { S: recordId },
          payload: { S: JSON.stringify(payload ?? {}) },
          written_at: { S: new Date().toISOString() },
          trace_id: { S: traceId },
        },
      })));

    const s3 = new S3Client({ region: target, credentials });
    await inSpan(ctx, 's3.PutObject', { ...base, data_classification: 'access-log', storage_region: storageRegion },
      () => s3.send(new PutObjectCommand({
        Bucket: plane.bucket,
        Key: `access/${new Date().toISOString().slice(0, 10)}/${recordId}.json`,
        ContentType: 'application/json',
        Body: JSON.stringify({ tenant_id: tenantId, record_id: recordId, trace_id: traceId, storage_region: storageRegion, at: new Date().toISOString() }),
      })));

    const compliant = storageRegion === tenant.tenant_region;
    root.setAttributes({ 'residency.compliant': compliant, outcome: 'stored' });
    return reply(201, { trace_id: traceId, record_id: recordId, tenant_id: tenantId, tenant_region: tenant.tenant_region, storage_region: storageRegion, compliant, outcome: 'stored' });
  } catch (err) {
    const deniedByScp = /service control policy/i.test(err.message);
    const message = redact(err.message);
    root.setAttributes({
      storage_region: storageRegion,
      'residency.compliant': storageRegion === tenant.tenant_region,
      outcome: deniedByScp ? 'denied_by_scp' : 'error',
    });
    root.setStatus({ code: SpanStatusCode.ERROR, message });
    return reply(deniedByScp ? 403 : 500, { trace_id: traceId, tenant_id: tenantId, tenant_region: tenant.tenant_region, storage_region: storageRegion, outcome: deniedByScp ? 'denied_by_scp' : 'error', error: `${err.name}: ${message}` });
  } finally {
    root.end();
  }
}

async function readTraces(tenantId) {
  if (!REGISTRY[tenantId]) return reply(404, { error: `unknown tenant ${tenantId}` });
  const spans = [];
  let nextToken;
  do {
    const out = await logs.send(new FilterLogEventsCommand({
      logGroupName: LOG_GROUP,
      filterPattern: `{ $.type = "otel-span" && $.attributes.tenant_id = "${tenantId}" }`,
      startTime: Date.now() - 7 * 24 * 3600 * 1000,
      nextToken,
    }));
    for (const e of out.events ?? []) spans.push(JSON.parse(e.message));
    nextToken = out.nextToken;
  } while (nextToken && spans.length < 500);

  const byTrace = new Map();
  for (const s of spans) {
    if (!byTrace.has(s.trace_id)) byTrace.set(s.trace_id, []);
    byTrace.get(s.trace_id).push(s);
  }
  const traces = [...byTrace.entries()].map(([traceId, list]) => {
    list.sort((a, b) => a.start_time.localeCompare(b.start_time));
    const root = list.find((s) => s.name === 'pii.write') ?? list[0];
    return { trace_id: traceId, start_time: root.start_time, root: root.attributes, status: root.status, status_message: root.status_message, spans: list };
  }).sort((a, b) => b.start_time.localeCompare(a.start_time));
  return reply(200, { tenant_id: tenantId, traces });
}

function listTenants() {
  const tenants = Object.entries(REGISTRY).map(([id, t]) => ({
    tenant_id: id,
    label: t.label,
    tenant_region: t.tenant_region,
    storage_region: t.storage_region,
    table: DATA_PLANES[t.storage_region]?.table ?? null,
  }));
  return reply(200, { tenants, registry_sha256: REGISTRY_SHA256, git_commit: GIT_COMMIT });
}

export const handler = async (event) => {
  // API Gateway requests carry requestContext.http. Direct (IAM-authenticated) invocations do not,
  // and only they may pass simulate_storage_region to reproduce a misrouted write.
  const viaApi = Boolean(event.requestContext?.http);
  const route = viaApi ? `${event.requestContext.http.method} ${event.rawPath}` : event.route;
  const body = viaApi
    ? JSON.parse(event.body ? (event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body) : '{}')
    : event;
  const query = event.queryStringParameters ?? {};

  try {
    switch (route) {
      case 'GET /tenants': return listTenants();
      case 'GET /traces': return await readTraces(query.tenant_id ?? body.tenant_id);
      case 'POST /records': return await writeRecord(body.tenant_id, body.payload, viaApi ? undefined : body.simulate_storage_region);
      default: return reply(404, { error: `no route ${route}` });
    }
  } catch (err) {
    return reply(500, { error: redact(err.message) });
  }
};
