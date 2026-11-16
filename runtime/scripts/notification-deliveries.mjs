// Prints the durable APNs delivery records behind main-chat alerts as JSON lines.
// Self-contained (node: imports only) so it can be piped to a coordinator host:
//   node --input-type=module - --database <state_dir>/session.sqlite --text NEEDLE < notification-deliveries.mjs
// It never reads the agent.notifications document, which holds device tokens.
import { DatabaseSync } from "node:sqlite";
import { parseArgs } from "node:util";

const ROOT_CONVERSATION_ID = 1;
const ENTRY_KINDS = { "pi.assistant": "assistant", "agent.user_notice": "notice" };
const DELIVERY_KIND = JSON.stringify("agent.notification-delivery");
const DELIVERY_LIFETIME_MS = 86_400_000;

function usage(message) {
  process.stderr.write(`${message}\nusage: notification-deliveries --database PATH --text NEEDLE [--text NEEDLE ...] [--tasks-since-entry ID]\n`);
  process.exit(2);
}

function parseOptions() {
  let parsed;
  try {
    parsed = parseArgs({ args: process.argv.slice(2), strict: true, allowPositionals: false, options: {
      database: { type: "string" }, text: { type: "string", multiple: true }, "tasks-since-entry": { type: "string" },
    } }).values;
  } catch (error) { usage(error.message); }
  if (parsed.database === undefined) usage("--database is required");
  const needles = parsed.text ?? [];
  if (needles.length === 0 && parsed["tasks-since-entry"] === undefined) usage("give at least one --text or --tasks-since-entry");
  if (needles.some((needle) => needle.length === 0)) usage("--text must not be empty");
  let sinceEntry;
  if (parsed["tasks-since-entry"] !== undefined) {
    sinceEntry = Number(parsed["tasks-since-entry"]);
    if (!Number.isSafeInteger(sinceEntry) || sinceEntry < 1) usage("--tasks-since-entry must be a positive entry id");
  }
  return { database: parsed.database, needles, sinceEntry };
}

function materializeDocument(db, documentId) {
  const base = db.prepare(`SELECT seq, content FROM document_revisions
    WHERE document_id = ? AND kind = 'base' ORDER BY seq DESC LIMIT 1`).get(documentId);
  if (base === undefined) throw new Error(`document ${documentId} has no base revision`);
  if (db.prepare(`SELECT 1 FROM document_revisions WHERE document_id = ? AND seq > ? LIMIT 1`).get(documentId, base.seq) !== undefined) {
    throw new Error(`document ${documentId} has delta revisions; this reader expects agent.notification-delivery to store only bases`);
  }
  return JSON.parse(base.content);
}

function visibleText(record) {
  if (record.kind === "agent.user_notice" && typeof record.data?.text === "string") return record.data.text;
  return (record.model ?? []).filter((message) => message.role === "assistant")
    .flatMap((message) => message.content ?? []).filter((part) => part.type === "text").map((part) => part.text).join("\n");
}

function readEntries(db, needles, sinceEntry) {
  const rows = new Map();
  const byText = db.prepare(`SELECT id, commit_seq, record FROM entries WHERE conversation_id = ? AND instr(record, ?) > 0`);
  for (const needle of needles) {
    for (const row of byText.all(ROOT_CONVERSATION_ID, JSON.stringify(needle).slice(1, -1))) rows.set(row.id, row);
  }
  if (sinceEntry !== undefined) {
    const row = db.prepare(`SELECT id, commit_seq, record FROM entries WHERE conversation_id = ? AND id = ?`).get(ROOT_CONVERSATION_ID, sinceEntry);
    if (row !== undefined) rows.set(row.id, row);
  }
  return [...rows.values()].sort((left, right) => left.id - right.id)
    .map((row) => ({ id: row.id, commitSeq: row.commit_seq, record: JSON.parse(row.record) }))
    .filter((entry) => Object.hasOwn(ENTRY_KINDS, entry.record.kind));
}

function readDeliveries(db) {
  const byEntry = new Map();
  for (const row of db.prepare(`SELECT id, created_at FROM documents WHERE kind = ? AND retired_at IS NULL ORDER BY id`).all(DELIVERY_KIND)) {
    const delivery = materializeDocument(db, row.id).delivery;
    if (delivery === null || delivery === undefined) continue;
    const list = byEntry.get(delivery.entry_id) ?? [];
    list.push({ createdAt: row.created_at, delivery });
    byEntry.set(delivery.entry_id, list);
  }
  return byEntry;
}

const queuedAt = (delivery) => delivery.expires_at - DELIVERY_LIFETIME_MS;

function deliveryRecords(needles, entries, deliveries) {
  const lines = [];
  for (const needle of needles) {
    const matches = entries.filter((entry) => visibleText(entry.record).includes(needle));
    if (matches.length === 0) lines.push({ record: "missing", needle, matched: false, entry_id: null, deliveries: 0 });
    for (const entry of matches) {
      const entryId = String(entry.id), saved = deliveries.get(entryId) ?? [];
      if (saved.length === 0) lines.push({ record: "entry", needle, matched: true, entry_id: entryId, deliveries: 0 });
      for (const { createdAt, delivery } of saved) lines.push({ record: "delivery", needle, matched: true, entry_id: entryId,
        conversation_id: String(entry.record.conversationId), entry_kind: ENTRY_KINDS[entry.record.kind], entry_commit_seq: entry.commitSeq,
        state: delivery.state, status: delivery.status, attempts: delivery.attempts, apns_id: delivery.apns_id,
        installation_id: delivery.installation_id.slice(0, 8), created_at: createdAt, queued_at: queuedAt(delivery) });
    }
  }
  return lines;
}

function taskEvidence(row, ended, entryId, source, bound) {
  const createdAfterEntry = row.id > entryId;
  if (createdAfterEntry) return String(row.conversation_id) === source ? "source_ran_after_entry" : undefined;
  if (row.status !== "terminal") return "live_at_entry_non_terminal_now";
  if (bound !== null && ended !== null && ended > bound) return "live_at_entry_ended_after_delivery_queued";
  return undefined;
}

function taskRecords(db, entryId, entries, deliveries) {
  const entry = entries.find((candidate) => candidate.id === entryId);
  if (entry === undefined) return [{ record: "since_entry", entry_id: String(entryId), found: false }];
  const queued = (deliveries.get(String(entryId)) ?? []).map(({ delivery }) => queuedAt(delivery));
  const bound = queued.length === 0 ? null : Math.min(...queued);
  const source = entry.record.kind === "agent.user_notice" ? entry.record.data?.source_conversation_id ?? null : null;
  const lines = [{ record: "since_entry", entry_id: String(entryId), found: true, entry_kind: ENTRY_KINDS[entry.record.kind],
    entry_commit_seq: entry.commitSeq, job_id: entry.record.data?.task_id ?? null, source_conversation_id: source, earliest_queued_at: bound }];
  const candidates = db.prepare(`SELECT id, conversation_id, kind, status, background, record FROM tasks
    WHERE (id > ?1 AND conversation_id = ?2) OR (id <= ?1 AND (status != 'terminal' OR json_extract(record, '$.endedAt') > ?3))
    ORDER BY id`).all(entryId, source === null ? null : Number(source), bound);
  for (const row of candidates) {
    const record = JSON.parse(row.record), ended = record.endedAt ?? null, fromSource = String(row.conversation_id) === source;
    const evidence = taskEvidence(row, ended, entryId, source, bound);
    if (evidence === undefined) continue;
    const outlived = row.status !== "terminal" ? true : bound === null || ended === null ? null : ended > bound;
    lines.push({ record: "task", since_entry: String(entryId), task_id: String(row.id), kind: JSON.parse(row.kind), status: row.status,
      background: row.background === 1, conversation_id: String(row.conversation_id), started_at: record.startedAt ?? null, ended_at: ended,
      evidence, outlived_delivery_queue: outlived, notice_source: fromSource });
  }
  return lines;
}

const options = parseOptions();
const db = new DatabaseSync(options.database, { readOnly: true });
try {
  db.exec("BEGIN");
  const entries = readEntries(db, options.needles, options.sinceEntry), deliveries = readDeliveries(db);
  const lines = deliveryRecords(options.needles, entries, deliveries);
  if (options.sinceEntry !== undefined) lines.push(...taskRecords(db, options.sinceEntry, entries, deliveries));
  db.exec("COMMIT");
  for (const line of lines) process.stdout.write(JSON.stringify(line) + "\n");
} finally { db.close(); }
