# Roadmap

Remaining work. The [architecture](architecture.md) describes ownership and
recovery; [history](history.md) describes import and retrieval.

## Finish the current pass

- [x] Finish Codex catch-up and vector indexing, reconcile available text against
  source checkpoints, and verify real searches. Missing media stays explicit
  coverage gaps; importing and searching open no Rex sessions.
- [x] Import changes to completed Codex conversations from validated change
  watermarks, preserving earlier edits, source lineage and retention upgrades.
- [x] Finish live search latency validation, including time outside the index
  query while background work runs.
- [x] Verify a real incoming supplier version reaches its original imported
  task conversation and completes the existing worker's native submission.
- [x] Verify chat admission, steering, interruption, reopening and scrolling
  against a large live corpus while background work runs. Live checks passed
  with over a million retained entries, including pending-input recovery after
  stop and bounded main-history reopen.
- [x] Recover main-chat admission after coordinator restart, preserving steer
  and queue modes. Independent workers and control requests remain responsive
  while another worker's host effect is held. Ready observers and workers do
  not consume startup capacity; the real bridge regression covers 64 observers,
  bounded initialization, replies at capacity, recovery and detach cleanup.
- [x] Derive request lifecycle and valid controls from the Rust command type;
  share host-effect ownership and the CLI's client context across transports.
  Shutdown drains issued writes before releasing the runtime. Regression tests
  cover worker interruption, read-only observers, effect capacity and receipts.
- [x] Retain attachments before Pi admission without filesystem work on the
  shared commit queue; retention failures admit no input.
- [x] Carry native invocation cancellation through background host effects,
  preserving issued receipts and isolating unrelated execution lanes. Restored
  phases wait for their transport while notification recovery proceeds.
- [x] Preserve typed storage, provider and native failures, plus host-delivery
  certainty. Reconnect reconciles uncertain inputs without resending them.
- [x] Coalesce source-status reads and make retrieval close terminal for queued
  indexing, lazy opens and late embedding replies.
- [x] Partition retained task and source bodies in native Pi documents, with
  resumable migration, bounded read/write regressions and real SQL-plan and
  growth benchmarks. Legacy records remain intact. Initialization has its own
  bounded budget and remains cancellable before listeners bind.
  Retained-history scans yield between pages so concurrent clients stay
  responsive during exhaustive reads.
- [x] Use narrow process results and validate native execution bindings before
  host effects while retaining process limits and cleanup ownership.
- [x] Share Rust/Swift tool-merge traces across live, restored and sparse updates,
  preserving known names, terminal states and retained output.
- [x] Prepare the runtime once in CI and gate signed-cache publication on
  qualified package closures from trusted main runs. Preserve qualified compiler
  caches across publishing failures.
- [x] Share bounded snapshot-to-live observation for main and saved chats,
  preserving event order and suppressing publications throughout view cleanup.
  Overflow reports recovery without retaining an unbounded history buffer.
- [x] Test native outbox recovery against the production coordinator and Pi
  storage across reconnects and server restarts, without fake peers. CI runs
  the wire test on both platforms and the Swift client on macOS.
- [x] Persist acknowledged sends across iOS suspension and app restart.
  Delivery and processing have separate states; completed work is normal,
  blocked work is visible, and explicit continuation can recover a parked
  main generation without duplicating its saved inputs.
- [x] Clear the iOS composer immediately on Send while retaining its backup
  until outbox admission. Preserve newer typing and restore local rejections;
  connection changes cannot resurrect saved text. Native tests keep the
  keyboard active through consecutive sends and use production persistence.
  Cold recovery uses admission identities to preserve newer notes and files
  after failed saves, queue retirement and storage relocation.
  Simulator checks retain production startup and composer/outbox state across
  relaunch.
  The native text view copies and clears its buffer in the Send event, before
  asynchronous admission work. Native checks cover marked text, consecutive
  sends, foreground recovery and active responses. The replacement is available
  in TestFlight. A [phone acceptance](../ios/README.md#phone-acceptance) run on
  an installed build showed the placeholder and the keyboard in the first
  composer capture after every Send. It covered consecutive sends, an active
  response across Home and an app switch, a long multiline draft, identical
  newer typing and a relaunch with a newer draft. A started control that never
  left the phone comes back to the live composer ahead of newer typing, and
  `ChatModel` tests drive a failed dial, a disconnect and an address edit
  before any recipient writes it
  ([#34](https://github.com/sammyjoyce/agent/issues/34)).
- [x] Return a control's text, such as `/status`, to the live iOS composer when
  no recipient of its Send wrote it, as crash recovery already does, and keep
  newer typing. A control that any recipient wrote does not come back. A
  `ChatModel` test drives a dial that fails after the start. See
  [issue #34](https://github.com/sammyjoyce/agent/issues/34).
- [x] Use shared typed cells for live and imported messages, with Codex-style
  terminal formatting and retained command output on reopen.
- [x] Retain the live tail and older reading position through native rotation.
  Expanded tool cards show retained output once without losing truncated text.
- [x] Pin and activate scheduled-chat reuse, recovery and shared worktree
  controls through Global Nix. Background, CLI and main-agent collection have
  passed live checks, preserving active and dirty work.
- [x] Run scheduled tasks and their child agents without Rex terminals, retaining
  conversation identity, host tools, live views, steering and isolated stop.
- [x] Verify failed scheduled occurrences settle after recovery on their
  existing tasks, clearing scheduler errors while preserving unresolved work.
- [x] Verify parked scheduled model generations recover live on the existing
  actor, preserving queued occurrences and native submission identities.
- [x] Verify parked history indexing resumes its retained native work and
  staged batches without re-importing conversations.
- [x] Verify current source events reach triage beside historical backlogs.
  Deployed per-account old/new selection and separate polling/triage lanes
  passed live checks with older mail pending. Interrupted source claims
  settled; restart and retry regression tests pass. Provider-time ordering
  covers later historical backfills and immutable legacy rereads.
- [x] Surface failed source checks in CLI and native clients without adding
  repeated history notices. Retain typed helper failures and accept mail
  without a Subject header.
- [x] Recover missed shipment and spam work after source-storage failure.
  Verify source-bound shipment registration and carrier refresh, plus the spam
  proposal's main-chat publication and accepted phone delivery.
- [x] Verify autonomous handoff under the revised source instructions, including
  existing tasks with stale restrictions, without manual continuation.
  A fresh shipping notice resumed the existing task and its source investigation.
- [x] Verify chat reuse and native worktree inventory display live. Reopening
  retained the task, conversation and allocation; `/worktrees` displayed real
  inventory with ready, held and removed states.
- [x] Release the qualified native copy, selection, clipboard-image and input
  updates. Signed private TestFlight build 106 matches the deployed coordinator's
  production source; native UI, host and simulator CI checks pass.
- [x] Show native input and scheduled-notice provenance and main-conversation
  model settings; retain unsent drafts across reopen. Native consumer and UI
  checks pass, including the matched production-coordinator restart check.
- [x] Provision and ship an iOS Share target backed by the shared-draft queue.
  Signed private TestFlight build 106 includes matching host and extension App
  Groups; native UI checks verify the unsent-draft handoff.
- [x] Verify native rendering against the original visual references.
  Typed action rows and the shared Shell card passed native rendering,
  copy/selection and Light/Dark checks. Unknown shell intent remains explicit.
- [x] Ship private lifecycle logs, `/machines`, local usage-reset times and
  countdowns, and the remaining viewport correction.

## Inputs and automation

- [ ] **Sidechats** (inspired by Meta’s Muse): open a side conversation from a
  message to explore a follow-up without interrupting the main chat. Return to
  that message when done; bring an answer back only if you choose.
- [x] Ship `/goal` for persistent objectives, visible progress, pause/resume and
  completion tied to a verified outcome. A goal completes only when the runtime
  itself finds the required text in a file on the task's host.
- [x] Ship hosted web search and page retrieval with source links for supported
  OpenAI models. The existing ChatGPT login has passed an isolated search,
  open-page and find-in-page check. Other providers need their own integration.
- [x] Ship Chrome control in the selected host's existing profile with normal
  Playwright code and private 1Password CLI reads. Both macOS deployments
  passed fresh password/TOTP sign-in with 1Password enabled, authenticated
  access, independent connections without browser approval clicks, and owned
  tab cleanup after the Beep Boop service restarted.
- [x] Reuse existing signed-in user tabs with exclusive control and preserved
  drafts; return explicit browser-script results without automatic page dumps.
- [ ] Complete unattended Chrome lifecycle acceptance across OS reboots,
  ordinary browser relaunch and interruption recovery with autofill enabled.
  A disposable macOS guest with installed Chrome, the extension and
  saved-password autofill passed OS reboot, relaunch, and helper and service
  interruption. Chrome for Testing on a disposable profile passed relaunch and
  interruption. See `docs/chrome-acceptance.md`. A reboot of an existing
  deployment host remains.
- [x] Deliver browser screenshot attachments.
- [x] A phone client for the main conversation, using the same submission,
  steering and queueing path as the CLI. The native iPhone app fulfills the
  planned WhatsApp/iMessage client use case. System appearance is the default,
  with saved Light/Dark overrides and native keyboard dismissal.
- [x] Enable iPhone alerts for completed main-chat replies and explicit
  `notify_user` notices, including mid-job requests. On a real phone, a
  development-signed build had alerts on and was registered with the
  coordinator. A [phone acceptance](../ios/README.md#phone-acceptance) run
  showed a completed reply as an alert with the app in the background and
  after it was terminated, and a mid-job notice while its job still ran. Each
  alert matched an accepted durable delivery. TestFlight builds need the
  production APNs environment. See [notification setup](notifications.md).
- [x] Direct coordination between task sessions through their durable inboxes:
  sender identity, admission receipts, steering or queueing, and shared history.
- [x] Voice input through a transcription provider interface. The iPhone
  composer transcribes on the device with Parakeet behind `SpeechEngine`. Tap
  the mic to transcribe into the draft, or hold it to send through the same
  Send. Dictation transcribes on the phone and never uploads its audio. A held
  take passed a real-phone recheck.
- [x] File/photo attachments on iOS and dragged files in the terminal, retained
  with the conversation and delivered to Pi on the selected execution host.
- [x] Paste clipboard images into removable, unsent iOS attachments while
  preserving the note. Native UI checks cover import, removal and no automatic
  send.
- [x] Copy complete native messages or select a text range, including activity
  summaries and tool output. Native copy/paste and partial selection are
  verified against the actual composer.
- [x] Retain typed CLI/iOS input origins and scheduled-notice lineage. Missing
  legacy origins remain unknown. Native acknowledgement/history checks keep
  sent inputs before their replies without duplicate echoes or retry badges.
- [x] Scheduled jobs through the existing coordinator background process and
  task follow-through path. Reuse durable timers; persist occurrence identities
  so restarts and retries cannot run a job twice.
- [x] Reuse each scheduled job's task and Pi conversation across timer and
  manual runs, preserving each admitted run's prompt, model and identity.
- [x] Release CLI account diagnostics and scheduled-run timing, outcome and
  exact reply inspection. Keep unavailable historical timing explicit.
- [x] Release native scheduled-job diagnostics, retained-run recovery and
  read-only navigation into live job and sub-agent conversations. Signed build
  106 and the deployed coordinator share these contracts. Live retry preserved
  the parked task, and source readback separates progress from completed scans.
- [x] Shared worktree inventory through the CLI and `/worktrees`, including
  native chat clients.
- [ ] Bring the iPhone app's actions and content to Siri and Shortcuts through
  App Intents. **Open Coordinator**, **Open Job**, **Retry Interrupted Run**,
  **Send Message**, reading jobs, onscreen coordinators and jobs, and
  coordinators and jobs in Spotlight ship, with a build check that the app
  carries its intents metadata and phrases. Send Message asks before it sends,
  sends one confirmed copy through the outbox, and never runs a command. These
  checks on a real iPhone remain: Siri by voice, and Send Message and the
  Spotlight index on a locked phone.
- [ ] A macOS menu bar app that shows Beep Boop's status on the Mac, including
  whether the service is running and its installed and running versions.
- [ ] Typed read and write access to Apple Notes, Reminders, Mail and Messages
  through macctl, a signed Swift daemon whose source moves into `macos/macctl/`.
  `HostCommand::Apple` reaches only the configured Mac that owns the data, and
  that Mac's tiers decide which `apple_read`, `apple_change` and `apple_send`
  methods exist. Each write commits an operation record before dispatch; an
  unknown outcome blocks further writes to that app until it is settled. macctl
  first needs four guarantees it lacks today. Per-send approval, triage writes
  and the design's other open questions are the owner's decisions. See the
  [design](https://github.com/sammyjoyce/agent/issues/31).
- [ ] Computer use for desktop apps on the selected host, based on or using
  [agent-desktop](https://github.com/vercel-labs/agent-desktop). Computer use
  is the final fallback, after supported APIs, configured CLIs and Chrome
  tools, as the [architecture](architecture.md#integrations-and-scheduling)
  orders them. agent-desktop reads an app's accessibility tree as JSON with a
  ref for each element, acts on a ref, then reads the tree again to check the
  result. It needs no screenshots or pixel matching and has no model inside,
  so the loop stays in Pi. It ships under Apache-2.0 as a CLI, an MCP server
  and a C library for macOS, Windows and Linux. Ref actions do not move the
  pointer or take focus unless `--headed` is set, and macOS needs the
  Accessibility grant. Whether to run agent-desktop or build on its design is
  open. Snapshots, screenshots and clipboard reads can hold private desktop
  content.
- [ ] Reply to a specific message in the iPhone app, as Apple Messages does.
  Choose **Reply** on a message, and the composer shows that message above the
  draft until you send or cancel. The sent input names the message it answers,
  so the transcript shows that message quoted with the reply and the model
  knows which message the reply is about. Today a message's menu offers only
  **Copy message**, **Select text** and **Share text**, and an input cannot
  name an earlier message.

## Retrieval, learning and proof

- [ ] ChatGPT conversation import from a verified export, with resumable,
  idempotent ingestion and attachment coverage. `beep-boop import chatgpt`
  checks and imports invented exports end to end, including interruption,
  reruns and later edited exports. Checking and importing a real export, with
  its counts, digests, gaps and unsupported content recorded, remains to
  verify.
  See [ChatGPT exports](history.md#chatgpt-exports).
- [ ] [Grok Bot](https://docs.x.ai/grok-bot/overview) conversation import, with
  resumable, idempotent ingestion and attachment coverage. Grok Bot documents
  no account-wide export, only per-call transcripts and per-message downloads,
  so the import source is still open.
- [x] Representative SQL plans and paired CI benchmarks for history loading,
  dense/FTS retrieval, hydration and cached indexing. See
  [performance checks](performance.md).
- [x] Reduce full-corpus semantic search latency with binary candidates and
  exact float reranking. At 1.35 million chunks, 20 real retrieval cases retained
  identical full results while median reader time fell from 8.0 to 2.9 seconds.
  Preparation reuses retained vectors; exact retrieval remains available until
  preparation completes. See [qualification limits](performance.md).
- [x] Private retrieval evals: paraphrases, exact references, similar threads,
  rich older context versus sparse recent context, and incomplete coverage.
  Track recall, wrong-thread selection and latency.
- [x] End-to-end loop-closing tests and model evals: incoming reply → relevant
  existing task → resumed worker → action → verified outcome. Cover unrelated
  noise, exchanges already handled by the user, malicious source instructions,
  duplicate events and source failures.
  [Loop-closing tests and the live evaluation](architecture.md#validation) use
  a local ledger command as the action. Real mailbox and provider effects stay
  outside both. The latest live run, on `gpt-6.1-sol` from the `openai`
  provider, passed six of seven cases. In the already-handled case the model
  sent the user a needless completion notice.
- [x] CLI startup and retained-history first-render benchmarks, with paired
  baseline comparisons and a separate CI regression gate.
- [x] Benchmarks for input admission, first visible activity, steering/stop,
  long-history scrolling, search and import contention. Separate application
  delay from model latency; track CPU, RAM and token use. See
  [CLI performance](performance.md#scenarios-and-gates).
- [x] Nightly operational log review through scheduled jobs, with coordinator
  collection, retained task summaries and explicit coverage gaps. Repeat a
  review through the [scheduled-job run command](setup.md#scheduled-jobs).
- [x] Dreams and Dreams evals: inspect private logs nightly and propose useful
  improvements as reviewable diffs with before/after evidence. Learned changes
  take effect only after approval of that diff.
  [Dreams](setup.md#dreams) proposes at most one patch to a private guidance
  repository, with checks run before and after, and `beep-boop dreams apply`
  applies it only for the approved outcome digest. An opt-in live eval
  measures proposals, quiet abstentions and injected text.
- [x] Connect Pi's native telemetry to the same diagnostics. Show token use,
  cache hits and estimated cost for every chat, separately from subscription
  quota; keep estimates distinct from billed amounts. Native tests, review and
  live coordinator status readback pass.
- [x] Benchmark deferred tool discovery before adopting it for larger toolsets.
  The [tool discovery eval](performance.md#tool-discovery) measures nine
  scenarios across main, triage, worker and agent roles. Offering every tool
  directly used a median of 308,114 total tokens and 37 requests per suite
  at `gpt-6.1-sol` low reasoning; the adopted surfaces use 216,639 and 29,
  with every scenario passing.

## Recovery

- [x] Reconcile Rex server restarts, terminal exits and reconnects without
  duplicate sessions or lost pending inputs. A binding records the Rex server
  instance read just before its terminal was created, or read by the terminal
  as it attached, so a shell that Rex restores after a restart is never taken
  for the task's terminal. A terminal's own attachment confirms a create or
  resume whose reply was lost. The task keeps its session and gets its terminal
  back the next time it is presented. If Rex answers that the session is gone,
  that same presentation opens one new session for the task.
- [x] Transfer interactive worker execution to a daemon before its terminal
  client exits, retaining ownership of pending host effects. The coordinator
  owns each task actor and the execution host's worker service owns every
  issued effect before the terminal is ready, so closing or killing an updated
  terminal only stops observation. A task terminal from an older build that ran
  host effects itself still stops the turn when you leave its TUI, until that
  host updates.
- [x] Tested coordinator backups and restoration, including retained assets.
  `beep-boop backup create` copies a stopped coordinator's database,
  coordinator ID, attachments, history assets and feedback with a checksummed
  manifest. `backup restore` checks the archive and rebuilds the store in a new
  directory. Background work, task turns and automatic worktree collection stay
  held until `backup release`. See
  [backups and restore](setup.md#backups-and-restore).
- [x] Replicated coordinator state and failover, retaining one active owner so
  additional coordinators do not duplicate work or external effects. A
  coordinator with a `[failover]` section writes every commit and retained file
  to a log on a Cloudflare Durable Object before local disk, a standby replays
  that log, and `beep-boop failover promote` moves ownership to it under an
  epoch that only the authority grants. The authority refuses every append and
  every effect approval from any other epoch, so a coordinator without the
  current epoch commits nothing, accepts no input and gets no new effect
  approved. A coordinator opens a replicated state directory only under that
  epoch. After a wrong statement that the old host is stopped, an effect
  approved before the seal can still be dispatched once; promotion reports it
  and does not repeat it. Promotion is an operator command, and nothing takes
  over by itself. See
  [failover](setup.md#failover), and
  [cross-host recovery](architecture.md#cross-host-recovery) for what the stop
  evidence does not prove.

## Upstream reuse follow-ups

Verifiers found these while qualifying the upstream reuse rows below and judged
none a blocker. See [issue #52](https://github.com/sammyjoyce/agent/issues/52).

- [ ] Show a code mode script's nested `exec`, `write_file` and `edit_file`
  calls as their own Command and File changes items in triage, worker and agent
  history. Today they are lines inside the code mode item, although the
  result's `details.calls` already carries them.
- [ ] Make the tool discovery eval's `child-agent` oracle check meaning instead
  of wording, then requalify it with a fresh run. It still accepts a denial in
  the sentence after the root cause label, and denials worded as "ruled out",
  "excluded", "instead of" or "discarded theory".
- [ ] Rerun the full nine-scenario tool discovery confirmation under the current
  oracle at low and default reasoning, retaining every answer. The published
  full-suite numbers came from the earlier, weaker oracle.
- [ ] Shrink the worker's `codemode` prompt section with tool namespaces or a
  smaller inline budget.
- [ ] End-to-end image read tests for the triage and child-agent routes, across
  two machines, and for cancelling a slow transfer.
- [ ] Prepare attachments with the conversation model's image limits instead of
  the defaults.
- [ ] A bridge-level test that an oversized task graph request fails without
  breaking the bridge.
- [ ] Print JSON errors when a `--json` CLI request fails.
- [ ] A live task graph watch, plus task graph views in the TUI and iOS app.
- [ ] Make waits in `runtime/test/native-main.test.ts` cancellation-aware, so a
  missing event fails at its timeout instead of hanging. Trunk hangs the same
  way.
- [ ] Restore Linux real-browser coverage. The pinned Chromium needs
  `libglib-2.0` on NixOS hosts, and the gate must pass the browser fixture's
  `GITHUB_ENV` on.

## Issues

Real-device iPhone UI issues audited through macOS iPhone Mirroring on a
physical iPhone 16 Pro (`iPhone17,1`, iOS `27.3` build `24C5037i`, Beep Boop iOS
`0.1` build `416`, iPhone Mirroring `2.1` build `128.2` on macOS `27.3` build
`26C5035r`). Private screenshots, walkthrough clips and action logs are retained
outside this repository under their evidence identifiers; all examples below use
invented names and placeholder text. Entries distinguish **OBSERVED** defects
from **USER-REPORTED NOT REPRODUCED** and **UNTESTED / BLOCKED** coverage gaps
after the phone left mirroring (`iPhone in Use`) before repeat and cold-relaunch
trials completed. Deduplicated against existing roadmap items and open GitHub
issues (including `#71` and `#95`).

- [ ] **`UI-001` — Background/foreground reconnect drops reasoning summaries from an expanded activity group and shifts the open tool card**
  - **Status**: `OBSERVED`
  - **Severity**: High
  - **Build**: Beep Boop iOS `0.1` (build `416`), iOS `27.3` (`24C5037i`), iPhone 16 Pro (`iPhone17,1`)
  - **Steps**:
    1. Open a single-coordinator feed (`Work`) containing a completed activity group with multiple tool calls and reasoning summaries (e.g., `5 tool calls · 4 summaries`).
    2. Expand the activity group and expand its first shell tool call so a reasoning summary row sits directly above the expanded `Shell` card.
    3. Background Beep Boop to the Home Screen and leave it backgrounded until it suspends and disconnects (`Disconnected` visible in the App Switcher snapshot).
    4. Foreground Beep Boop from the App Switcher and wait for automatic reconnect (`Connecting` → connected) to settle, then observe without touching the screen for >8 seconds and again after scrolling 15 minutes later.
  - **Expected**: Reconnect restores the complete activity group (`5 tool calls · 4 summaries`), keeps the reasoning summary above the expanded tool call, and keeps the expanded `Shell` card anchored at its prior vertical position.
  - **Actual**: During `Connecting`, the group header drops all summaries (`5 tool calls`) and the first reasoning summary disappears. Once reconnect settles—and persistently 15 minutes later after scrolling—the header remains `5 tool calls · 2 summaries`, two of four summaries never return, and the open `Shell` card shifts upward by ~1 row height (~30–35 pt). *(Control: coordinator scope, group/card expanded state, general scroll neighborhood and tool-row count survived without duplicates.)*
  - **Repro frequency**: 1/1 observed trial on build `416` (repeat trials and cold-relaunch persistence check blocked when phone left mirroring).
  - **Evidence**: `EVID-20261120-A1`
  - **Acceptance check**: With an expanded activity group containing N summaries and an open child tool card, background Beep Boop until it disconnects, foreground it, and verify all N summaries remain in both the group header and expanded body with zero vertical jump of the open tool card after reconnect completes.

- [ ] **`UI-002` — Expanding the active streaming activity group at the live tail stalls follow-tail, clips streaming rows behind the composer and delays `Latest`**
  - **Status**: `OBSERVED`
  - **Severity**: Medium-High
  - **Build**: Beep Boop iOS `0.1` (build `416`), iOS `27.3` (`24C5037i`), iPhone 16 Pro (`iPhone17,1`)
  - **Steps**:
    1. Sit at the live tail of an actively streaming conversation (`Working...` visible above the composer, no `Latest` pill).
    2. Tap the collapsed active activity disclosure (`3 tool calls · 2 summaries >`) to expand it while the run continues.
    3. Do not scroll manually; observe across a 10-second burst (16 frames) as a 4th tool call starts (`1 running · 4 tool calls · 2 summaries`) and completes, and again ~2 minutes later after a 5th call and additional summaries append.
  - **Expected**: Expanding the live activity group either keeps follow-tail engaged so newly appended tool rows and `Working...` stay cleanly above the composer, or immediately transitions to manual-reading mode with `↓ Latest` visible and no row clipped mid-line under the composer edge.
  - **Actual**: Immediately on expansion, `Working...` is pushed downward and half-clipped behind the composer with no `↓ Latest` pill shown. When the 4th tool call streams in and completes across the 10-second burst, follow-tail does not advance: `Working...` moves below the composer and the 4th tool row is half-clipped behind the composer, still with no `↓ Latest` pill. Only after further rows append later (`5 tool calls · 4 summaries`) does `↓ Latest` appear.
  - **Repro frequency**: 1/1 observed live-streaming trial on build `416` (16 consecutive frames over 10 seconds plus follow-up observation).
  - **Evidence**: `EVID-20261120-B1`
  - **Acceptance check**: At the live tail of an actively streaming turn, expand the active activity group and verify that either newly appended tool rows and `Working...` stay fully visible above the composer, or `↓ Latest` appears immediately without clipping active rows mid-line under the composer.

- [ ] **`UI-003` — Floating `↓ Latest` pill overlaps readable text inside expanded `Shell` tool cards and activity rows**
  - **Status**: `OBSERVED`
  - **Severity**: Low-Medium
  - **Build**: Beep Boop iOS `0.1` (build `416`), iOS `27.3` (`24C5037i`), iPhone 16 Pro (`iPhone17,1`)
  - **Steps**:
    1. Scroll above the live tail (or expand an activity group / `Shell` card while newer rows exist below) so the floating `↓ Latest` pill is displayed.
    2. Inspect the bottom-right text of visible activity rows and expanded `Shell` card output lines.
  - **Expected**: The `↓ Latest` jump button does not obscure readable text or disclosure chevrons inside activity rows or expanded `Shell` cards.
  - **Actual**: The opaque `↓ Latest` pill floats directly on top of bottom-right transcript content, covering activity row suffixes/chevrons and the right side of the bottom two visible lines inside an expanded `Shell` card across multiple scroll positions.
  - **Repro frequency**: 2/2 distinct expanded layouts (over collapsed activity rows and over an expanded `Shell` card) across multiple scroll offsets and after reconnect.
  - **Evidence**: `EVID-20261120-B2`
  - **Acceptance check**: Scroll above the live tail with both collapsed activity rows and an expanded `Shell` card in view and verify the `↓ Latest` control remains legible without obscuring code lines or row disclosure controls.

- [ ] **`UI-004` — Consecutive reasoning summaries concatenate inline with literal `****` markdown delimiters**
  - **Status**: `OBSERVED`
  - **Severity**: Low-Medium
  - **Build**: Beep Boop iOS `0.1` (build `416`), iOS `27.3` (`24C5037i`), iPhone 16 Pro (`iPhone17,1`)
  - **Steps**:
    1. Stream a multi-step turn that emits consecutive bolded reasoning summaries into one activity group.
    2. Expand the activity group and inspect the summary entries.
  - **Expected**: Each reasoning summary renders as its own separated line or block with clean formatting and no raw markdown tokens.
  - **Actual**: Two adjacent summaries are concatenated into a single line with literal `****` rendered between them (e.g., `Inspecting report status****Reviewing message text`), persisting across the entire 10-second burst and subsequent captures.
  - **Repro frequency**: 1/1 multi-summary streaming turn observed on build `416`.
  - **Evidence**: `EVID-20261120-O1`
  - **Acceptance check**: Stream two back-to-back bolded reasoning summaries into an activity group and verify they render as distinct lines/blocks with zero literal `*` markdown delimiters visible.

- [ ] **`UI-005` — `Disconnected` / `Connecting` status bar collides with the top visible transcript line during background/foreground transitions**
  - **Status**: `OBSERVED`
  - **Severity**: Low
  - **Build**: Beep Boop iOS `0.1` (build `416`), iOS `27.3` (`24C5037i`), iPhone 16 Pro (`iPhone17,1`)
  - **Steps**:
    1. Scroll mid-conversation so a message line sits immediately below the top header bar.
    2. Background Beep Boop until it disconnects, inspect the App Switcher snapshot, and foreground Beep Boop to observe the `Disconnected` → `Connecting` → connected transition.
  - **Expected**: Connection status banners reserve dedicated vertical layout space above the transcript viewport without overlapping visible message text or spinners.
  - **Actual**: `Disconnected` / `Try again` sits flush against the top visible line in the background snapshot, and during foreground `Connecting` the activity spinner aligns beside/overlaps the right edge of the top transcript line before the feed shifts as the status row clears.
  - **Repro frequency**: 1/1 observed background→foreground reconnect on build `416`.
  - **Evidence**: `EVID-20261120-A2`
  - **Acceptance check**: Trigger disconnect and foreground reconnect while scrolled mid-conversation and verify status banners inset cleanly above transcript text with no text/spinner collision.

- [ ] **`UI-006` — Close/reopen cold relaunch and in-app conversation navigation away/back remain unverified**
  - **Status**: `UNTESTED / BLOCKED` (reported Focus A scope; partial coverage in `UI-001` and `UI-005`)
  - **Severity**: Medium (pending reproduction)
  - **Build**: Beep Boop iOS `0.1` (build `416`), iOS `27.3` (`24C5037i`), iPhone 16 Pro (`iPhone17,1`)
  - **Steps**:
    1. Verify composer is empty and idle, record active coordinator scope, scroll offset, expanded activity/tool state and visible message history.
    2. Test: (a) switching coordinator scope (`Work` ↔ `All coordinators` ↔ second coordinator), (b) opening `Connection → Jobs and work` conversations and navigating back, and (c) closing Beep Boop from the App Switcher and cold-relaunching.
    3. Repeat 2–3 times per transition.
  - **Expected**: Active conversation scope, history completeness (no missing/duplicated rows), and expected scroll/expansion restoration behave consistently across navigation away/back and cold relaunch.
  - **Actual**: Not yet executed on build `416` because iPhone Mirroring ended with `iPhone in Use — Lock your iPhone to connect` when the user took the physical phone before these transitions ran. (The coordinator picker menu itself opened cleanly.)
  - **Repro frequency**: Untested (0 trials; blocked by `iPhone in Use`).
  - **Evidence**: `EVID-20261120-BLOCK`
  - **Acceptance check**: Complete 2–3 trials each of coordinator switching, `Jobs and work` navigation away/back, and cold app relaunch on a real iPhone via iPhone Mirroring; confirm no missing history, duplicate rows, unexpected scope resets or scroll loss.

- [ ] **`UI-007` — Unexpected viewport jump while reading expanded tool-call details during active streaming**
  - **Status**: `USER-REPORTED NOT REPRODUCED / PARTIALLY BLOCKED` (reported Focus B scope; related live-tail defect captured in `UI-002`)
  - **Severity**: High (if reproduced; pending remaining live-tail/keyboard/collapse trials)
  - **Build**: Beep Boop iOS `0.1` (build `416`), iOS `27.3` (`24C5037i`), iPhone 16 Pro (`iPhone17,1`)
  - **Steps**:
    1. Open an actively streaming conversation with tool calls and expand a child tool-call detail card (`Shell` card) to read its output while new tool calls and assistant text stream in.
    2. Test from both (a) off-tail (`↓ Latest` visible) and (b) live-tail (follow-tail active), plus toggling keyboard open/dismiss and collapsing/re-expanding neighboring rows mid-stream.
  - **Expected**: Reading an expanded tool-call detail stays anchored in place while new events append below, and collapsing/expanding or toggling the keyboard does not unexpectedly jump the viewport away from the inspected row.
  - **Actual**: In one off-tail control trial (`↓ Latest` already visible), expanding a `Shell` card and waiting while the turn finished and appended a new reply below produced **no** unexpected jump (0/1). Live-tail child-card expansion during rapid multi-chunk streaming, inner-card vs outer-feed scrolling during streaming, collapse/expand row anchoring, and keyboard open/dismiss interactions were blocked when the phone left mirroring (`iPhone in Use`).
  - **Repro frequency**: 0/1 in off-tail control trial; remaining live-tail, collapse/expand and keyboard scenarios untested (blocked by `iPhone in Use`).
  - **Evidence**: `EVID-20261120-B3`, `EVID-20261120-BLOCK`
  - **Acceptance check**: Against an actively streaming read-only job feed or harmless test coordinator, verify zero unexpected viewport jumps when expanding/reading a tool-call detail card from both live-tail and scrolled-up states while text and tool events stream continuously, and across collapse/expand and keyboard toggle interactions.

## Reuse upstream

Verified against Pi Durable 1.5.2 and Beep Boop's current source. Source
integration and deployment are tracked separately above.

| Upstream capability | Status | Application use and remaining work |
| --- | --- | --- |
| Durable conversations, submissions and task checkpoints | In use | Native Harness, SQLite storage and checkpointed documents own history and execution. |
| Steering, follow-ups, abort and compaction | In use | Native input modes, abort and compaction events drive chat. |
| Durable sleeps and wake notifications | In use | Sources, resources and jobs share Pi's persisted sleeps and scheduler. |
| Typed telemetry and usage totals | In use | Native UsageDoc supplies own-conversation totals and bounded request timings in `/status`; the private native SQLite recorder keeps payload-free diagnostics. Unknown prices remain unavailable; API-equivalent estimates are separate from bills and subscription quota. |
| Image preparation workers | In use | One Photon worker prepares attached images and images read from hosts for native model input. Beep Boop owns transfer and storage. |
| Image-aware file readers | In use | `read_file` recognizes PNG, JPEG, GIF, WebP and BMP files by content on any execution host, pulls them in 1 MiB chunks up to 16 MiB, and returns upstream `read`'s image result within the model's limits. Text reads keep their byte offset and limit. Upstream `read` itself stays unused, because its offsets are lines and it needs a Harness environment. |
| Forks, child tasks and task graphs | Graph in use | `beep-boop tasks graph` shows Pi's live task tree with task and agent identity. Delegate conversations stay ownerless: ownership by the spawning call breaks delegate lifetimes, and a background anchor adds a permanent native task per delegate before any feature needs it. No flow needs a fork. [Architecture](architecture.md#tasks-and-execution) records the evidence and when to revisit. A live watch and the TUI and iOS views remain. |
| Deferred tool search and code mode | In use | Main defers its rarely used tools behind `tool_search`. Triage, worker and agent call most tools from `codemode` scripts. On the [tool discovery eval](performance.md#hillclimb-results) this uses 29.7% fewer tokens at low reasoning and 33.5% fewer at the default, with every scenario passing. The `child-agent` scenario passes when the child's summary and the parent's evidence each name the expired certificate after a root cause label, in a sentence with no negation word; a fresh run of it under that check passed 3 of 3 trials in each arm. In those roles' history, a script's commands and file edits are lines in its code mode item, not their own Command and File changes items; rendering them as those items remains. Tool search is separate from conversation search. |

See [Pi Durable](https://github.com/earendil-works/pi/tree/main/packages/durable)
and [Pi telemetry](https://github.com/earendil-works/pi/tree/main/packages/telemetry).
Upstream interfaces are experimental; verify the pinned API before adopting one.
