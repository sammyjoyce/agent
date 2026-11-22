import assert from "node:assert/strict";
import { test } from "node:test";
import { openBridgeHarness } from "./bridge-harness.js";

test("bridge observe_main with task_graph:true and watch_task_graph emit snapshots and detach cleanly", { timeout: 25_000 }, async (t) => {
  const bridge = await openBridgeHarness(t, {});
  try {
    bridge.send(3, { type: "observe_main", input_ids: [], task_graph: true });
    await bridge.waitFor("observe_main ready and task_graph", () =>
      bridge.frames.some((frame) => frame.id === 3 && frame.event.type === "main_ready")
      && bridge.frames.some((frame) => frame.id === 3 && frame.event.type === "task_graph"));
    bridge.send(3, { type: "detach_main" });
    const observeEvents = await bridge.collect(3);
    assert.ok(observeEvents.some((event) => event.type === "main_ready" && event.active_work === true));
    assert.ok(observeEvents.some((event) => event.type === "task_graph"));

    bridge.send(4, { type: "watch_task_graph" });
    await bridge.waitFor("watch_task_graph snapshot", () => bridge.frames.some((frame) => frame.id === 4 && frame.event.type === "task_graph"));
    bridge.send(4, { type: "detach_task_graph" });
    const watchEvents = await bridge.collect(4);
    assert.ok(watchEvents.some((event) => event.type === "task_graph"));
    assert.equal(watchEvents.at(-1)?.type, "done");
  } finally {
    await bridge.close();
  }
});
