import { readFile } from "node:fs/promises";
import { backup, DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";
import { CURRENT_SQLITE_SCHEMA_VERSION } from "@earendil-works/pi-durable/storage/sqlite";
import type { DatabaseReport } from "./generated/DatabaseReport.js";
import type { DatabaseRequest } from "./generated/DatabaseRequest.js";

/** Pi Durable's schema table, created by chord's migration runner as (singleton, version). */
const SCHEMA_TABLE = "durable_schema";

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export async function answerDatabaseRequest(request: DatabaseRequest): Promise<DatabaseReport> {
  switch (request.type) {
    case "snapshot": {
      // Read-only, so closing never checkpoints into the source store.
      const source = new DatabaseSync(request.source, { readOnly: true });
      try { await backup(source, request.snapshot); } finally { source.close(); }
      const snapshot = new DatabaseSync(request.snapshot);
      try {
        // The copied header still says WAL, and a carried file must stand alone.
        snapshot.exec("PRAGMA journal_mode = DELETE");
        return await inspect(snapshot);
      } finally { snapshot.close(); }
    }
    case "inspect": {
      const database = new DatabaseSync(request.database, { readOnly: true });
      try { return await inspect(database); } finally { database.close(); }
    }
    default: {
      const unknown: never = request;
      throw new Error(`Unknown database request ${JSON.stringify(unknown)}`);
    }
  }
}

async function inspect(database: DatabaseSync): Promise<DatabaseReport> {
  const integrity = database.prepare("PRAGMA integrity_check").all().map((row) => String(row.integrity_check));
  const journal = database.prepare("PRAGMA journal_mode").get();
  const durable = database.prepare("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?").get(SCHEMA_TABLE) !== undefined;
  const version = durable ? database.prepare(`SELECT version FROM ${SCHEMA_TABLE} WHERE singleton = 1`).get()?.version : undefined;
  return { integrity, journal_mode: String(journal?.journal_mode), schema_version: typeof version === "number" ? version : null,
    supported_schema_version: CURRENT_SQLITE_SCHEMA_VERSION, pi_durable_version: await piDurableVersion() };
}

async function piDurableVersion(): Promise<string> {
  const manifest: unknown = JSON.parse(await readFile(new URL(import.meta.resolve("@earendil-works/pi-durable/package.json")), "utf8"));
  if (!object(manifest) || typeof manifest.version !== "string") throw new Error("The installed Pi Durable has no version");
  return manifest.version;
}

function parseRequest(text: string | undefined): DatabaseRequest {
  const value: unknown = text === undefined ? undefined : JSON.parse(text);
  if (object(value)) {
    const fields = Object.keys(value).length;
    if (value.type === "snapshot" && typeof value.source === "string" && typeof value.snapshot === "string" && fields === 3) {
      return { type: "snapshot", source: value.source, snapshot: value.snapshot };
    }
    if (value.type === "inspect" && typeof value.database === "string" && fields === 2) return { type: "inspect", database: value.database };
  }
  throw new Error("Invalid database request");
}

async function main(): Promise<void> {
  process.stdout.write(JSON.stringify(await answerDatabaseRequest(parseRequest(process.argv[2]))) + "\n");
}

if (process.argv[1] !== undefined && pathToFileURL(process.argv[1]).href === import.meta.url) {
  void main().catch((error: unknown) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
