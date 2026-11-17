// A test that scripts the claim's answers through the fixture helper has no
// authority for the Pi child to open. Rust still runs as a replicated owner at
// the scripted epoch, and the Pi child runs as a local one. The import is
// dynamic because the runtime fixture reads the session while it loads.
delete process.env.AGENT_FAILOVER;
await import("./coordinator-runtime.js");

export {};
