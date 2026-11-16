// The deliberately slow candidate for the CLI benchmark's proof that every
// interactive gate can fail. Each runtime event reaches the coordinator late.
const SLOW_RUNTIME_DELAY_MS = 500;

const write = process.stdout.write.bind(process.stdout);
process.stdout.write = ((chunk: string | Uint8Array, ...rest: unknown[]) => {
  const copy = typeof chunk === "string" ? chunk : Buffer.from(chunk);
  setTimeout(() => (write as (...args: unknown[]) => boolean)(copy, ...rest), SLOW_RUNTIME_DELAY_MS);
  return true;
}) as typeof process.stdout.write;

await import("../../src/bridge.js");
