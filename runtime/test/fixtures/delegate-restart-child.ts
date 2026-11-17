import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { attachMainAndSpawnedWorkers, host, open, scriptActors } from "../delegation.js";
import { fixtureModel } from "../model.js";

const directory = process.argv[2], moment = process.argv[3];
if (directory === undefined || (moment !== "spawning" && moment !== "working")) throw new Error("Fixture arguments missing");
const app = await open(directory);
const report = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
scriptActors(app.faux, {
  "Start the board review": [
    fauxAssistantMessage(fauxToolCall("delegate_task", { input: "Inspect the board repository", title: "Board review", outcome: "Verify the board change" }), { stopReason: "toolUse" }),
    fauxAssistantMessage("Delegated the board review."),
  ],
  "Inspect the board repository": [async () => {
    let task = (await app.tasks.list())[0];
    while (task === undefined || task.pending.length > 0 || task.worker.state !== "bound") {
      await new Promise<void>((resolve) => setTimeout(resolve, 5)); task = (await app.tasks.list())[0];
    }
    report({ task_id: task.id, conversation_id: task.conversation_id, worker: task.worker });
    return new Promise(() => {});
  }],
});
let root;
if (moment === "working") root = (await attachMainAndSpawnedWorkers(app, new AbortController().signal)).root;
else {
  root = await app.session.root(BACKGROUND_CONTEXT);
  app.executions.bind(root.id.toString(), { model: fixtureModel, cwd: host.cwd, hosts: [host], call: async (command) => {
    if (command.type !== "spawn_workspace_worker") throw new Error("Unexpected host effect: " + command.type);
    const task = await app.tasks.get(command.task_id);
    report({ task_id: task.id, conversation_id: task.conversation_id, worker: task.worker });
    return new Promise(() => {});
  } });
  await root.configure({ model: { provider: "openai", modelId: "fixture" }, extensions: [app.tools.main] }, BACKGROUND_CONTEXT);
}
await root.submit({ type: "input", content: "Start the board review" }, BACKGROUND_CONTEXT);
