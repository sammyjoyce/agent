# CLI performance

The separate **CLI performance** CI job compares a change with its pull request
base or previous main commit on the same runner. It builds both in release
mode, alternates baseline and candidate samples, and saves every timing in
JSON.

Every sample drives the real CLI through the existing PTY fixture. A `vt100`
screen parser applies cursor movement, clearing and wrapping, and every check
reads only visible cells. A menu, an ANSI-stripped byte match, or text already
scrolled offscreen does not satisfy a check. Each version runs its own Rust
coordinator and TypeScript runtime on the same synthetic state: the chief's
40-message history, a saved 5,000-message conversation, and 3,000 unrelated
saved discussions, all in real Pi/SQLite storage.

## Scenarios and gates

`examples/cli_performance/scenario.rs` defines every scenario: its coordinator
lifetime, its scripted model turns, its gates, and the steps that drive it. A
gate runs from one benchmark mark to a later one.

| Scenario | Coordinator | Gate | From | To |
| --- | --- | --- | --- | --- |
| `chief_cold` | Fresh per sample | `conversation_visible` | CLI spawn | The chief's last stored sentence is visible. |
| `chief` | Shared per version | `conversation_visible` | CLI spawn | The chief's last stored sentence is visible. |
| `long_history` | Shared per version | `conversation_visible` | Spawn of `chat /resume <id>` | The long conversation's last sentence is visible. |
| `submit` | Fresh per sample | `admission` | Enter | The composer is empty and the prompt is a placed `›` line with no pending `sending…` state. |
| `submit` | Fresh per sample | `first_activity` | Enter | The turn's reasoning summary is visible. |
| `steer` | Fresh per sample | `steer_admission` | Enter on a second prompt while the first turn streams | `Steering messages, waiting` is visible. |
| `steer` | Fresh per sample | `steer_reply` | The same Enter | The steering turn's answer is visible and the turn is idle. |
| `stop_stream` | Fresh per sample | `stop` | Esc while the reasoning stream is open | `• Interrupted` is visible and the turn is idle. |
| `stop_tool` | Fresh per sample | `stop` | Esc while an `exec` tool runs | `• Interrupted` is visible and the turn is idle. |

The launch scenarios measure what they measured before: process spawn until
stored text is visible, with no model request. An interactive sample starts a
fresh coordinator from the snapshot and prepares outside timing. It launches
the CLI, waits for the chief, and settles one short turn. Each prompt is typed
first, and Enter is pressed only once the composer shows the prompt, so Enter
is a keystroke of its own. `/exit` ends every sample.

## Application delay

The gated number is application delay. It is the gate's wall time minus the
scripted provider holds that the gate subtracts:

| Gate | Provider time subtracted |
| --- | --- |
| `conversation_visible`, `admission`, `steer_admission`, `stop` | None. Launch, admission and stopping never wait for the model. |
| `first_activity` | The request's first-chunk hold, from the request body read until the reasoning write. The tail hold that keeps the stream open is not subtracted. |
| `steer_reply` | Every hold after `Steering messages, waiting` became visible. These are the rest of the first turn's stream and the steering turn's own holds. |

The provider records each hold on the benchmark's clock, so a slow reader in
the runtime counts as application delay. Overlapping holds count once. A
missing or reversed mark fails the sample, and a negative result is an error
rather than zero.

Fifteen measured pairs run per scenario. For every scenario and gate, each
candidate gets the greater of a 25% or 20-millisecond allowance over its
paired baseline. CI fails when the median fraction of that budget exceeds 1.
Pairing prevents uneven runner stalls from turning separate medians into a
false regression. The first pair warms the services and is recorded but
excluded from the gate. There are no automatic retries or discarded slow
samples.

Visible marks move in steps of about 41 ms, so one pair can exceed its budget
with no change. How often varies between runs on the same host. Resampling
three same-build Linux runs put the chance that a whole run fails with no
change at 8 to 13% with seven pairs and 2 to 5% with fifteen. Three later runs
on the same host put it under 1% with either count. Keep the count odd,
because with an even count the gate reads the upper of the two middle
fractions.

## Loopback model provider

`runtime/test/fixtures/performance-runtime.ts` starts each version's real
runtime with an invented `OPENAI_API_KEY`. It imports only Node built-ins, so
each version loads only its own runtime's packages. It rewrites only
`https://api.openai.com/v1/responses` to the benchmark's loopback server,
through the original `fetch` with Pi's method, headers, body and abort signal.
Every other URL throws. The server in `examples/cli_performance/provider.rs`
accepts only `POST /v1/responses` and answers with OpenAI Responses
server-sent events. Each request must match the next scripted turn by the
prompt in its latest user input.

| Turn | First-chunk hold | Tail hold | Ends with |
| --- | ---: | ---: | --- |
| `prime` | 20 ms | 150 ms | An answer |
| `submit` | 150 ms | 1,500 ms | An answer |
| `steer_base` | 150 ms | 2,500 ms | An answer |
| `steer` | 150 ms | 100 ms | An answer |
| `stop_stream` | 150 ms | Until the client closes | Nothing |
| `stop_tool` | 150 ms | 300 ms | An `exec` call of a Node process that writes its pid and idles |

The long tails keep a turn busy long enough for Pi to commit the reasoning
partial and for the steering prompt to arrive while the first turn streams.
They stay long enough under the slow candidate below.

Every coordinator also has a `/bin/sh` Rex stand-in on its private `PATH`. It
answers `whoami` and `hosts`, so the coordinator has a local node to run
`exec`, and the CLI's identity check on each input starts no Node process.

## Correctness

A sample fails, and the run with it, when any of these happen:

- The provider sees requests other than the scenario's turns in order, or a
  turn ends differently than scripted. The stopped stream must end with the
  client closing its connection.
- The steering request reaches the provider before the first turn's response
  completed.
- A provider request arrives after Esc. The benchmark checks one second after
  `Interrupted` is visible, and again from the full log at coordinator
  shutdown.
- The `exec` tool process is not running before Esc, or still exists when
  `Interrupted` becomes visible.
- Pi's token ledger for the chief changes by a total other than the sum of the
  responses that completed inside the measured window.
- A launch scenario contacts the provider.

The error includes the visible screen, the marks and the provider log.

## CPU, memory and tokens

Each sample reports CPU time and memory for the CLI, the coordinator and the
runtime, and Pi's token use. These are never gated. The benchmark reads each
process only when the window opens and closes. The interactive window covers
the measured steps. The launch window runs from before the spawn until the
text is visible, so the CLI's CPU time covers its whole life.

| Platform | CPU time | Resident | Peak |
| --- | --- | --- | --- |
| macOS | `proc_pid_rusage` user and system time | `ri_resident_size` | `ri_lifetime_max_phys_footprint`, the lifetime physical footprint |
| Linux | `clock_getcpuclockid` | `VmRSS` | `VmHWM` |

On macOS the footprint leaves out shared and file-backed pages that the
resident size counts, so the peak can be lower than the resident size.

A runtime that respawns inside the window fails the sample. Token use is the
change in Pi's `conversation_usage` ledger for the chief across the window.
The provider reports synthetic usage, so the token counts are synthetic too:
`input_tokens` is the request body bytes divided by 4, rounded up.
`reasoning_tokens` is the reasoning bytes divided by 4, rounded up.
`output_tokens` adds the answer or `exec` argument bytes divided by 4, rounded
up. Cached tokens are 0, and the total is input plus output. Pi records no
usage for the stopped stream, so `stop_stream` reports a change of zero.

## Results

`performance/results.json` uses schema 3. Its header names the terminal size,
the corpus sizes, the allowances, each scenario's turns and gates, the usage
formula, the kind of peak memory, and `synthetic: true`. Each sample keeps its gate spans and a
timeline in milliseconds from the sample's start. The timeline holds the
marks, the provider's request, first chunk, completion and client close, and
coordinator diagnostics receipts at their 1 ms resolution. Receipts only
explain a sample. Each sample also keeps every provider request with its
scripted and observed holds, the process readings, and the token change. The
report ends with each comparison and the medians of CPU time, memory and
tokens. A JSONL file keeps completed samples if a later sample fails, and a
failure JSON records the error.

## Run the benchmark

Build both revisions' runtime and CLI, then compare:

```sh
nix develop --command cargo build --release --bin beep-boop \
  --example terminal-fixture --example cli-performance
nix develop --command npm --prefix runtime run build
nix develop --command target/release/examples/cli-performance \
  --baseline /path/to/base/target/release/beep-boop \
  --baseline-runtime /path/to/base/runtime/dist/src/bridge.js \
  --candidate target/release/beep-boop \
  --candidate-runtime runtime/dist/src/bridge.js \
  --terminal target/release/examples/terminal-fixture \
  --seed runtime/dist/test/fixtures/performance.js \
  --runtime-shim runtime/dist/test/fixtures/performance-runtime.js \
  --output performance/results.json
```

Add `--scenario submit`, repeated as needed, to run a subset. `--samples`
sets the measured pairs per scenario.

## Prove that every gate can fail

Two runs on one build show the gates' range:

1. Run the same build and `runtime/dist/src/bridge.js` on both sides. The
   spread between the sides is the noise floor. A gate usually passes, but
   one near a visible step can fail, as the limits below describe.
2. Run the same build on both sides with
   `--candidate-runtime runtime/dist/test/fixtures/slow-runtime.js`. That
   runtime delays every write to the coordinator by 500 ms, so every gate
   reports `REGRESSION` and the benchmark exits with status 1.

## Limits

- The benchmark makes no claim about native iOS frame pacing.
- The TUI draws a runtime update after waiting up to 40 ms for input, and Pi
  commits a streamed partial on a trailing 100 ms timer. Both count as
  application delay. Visible marks land on steps of about 41 ms, so a sample
  near a step boundary can move by a whole step, and a gate can fail with no
  change. Which gates sit near a boundary depends on the platform. CI gates on
  Linux only. On macOS, resampling three local runs put the chance that a
  whole run fails with no change at about 3 to 5% with fifteen pairs.
- Rex is a shell stand-in, and the model provider is a local script.
- Token counts are synthetic.
- Scrolling to older text in a long history, and foreground work during search
  and import, are not measured yet.

## Add a scenario

Add a variant to `Scenario` in `examples/cli_performance/scenario.rs`, its
definition, and its arm in `drive`. Seed any retained data it needs in
`runtime/test/fixtures/performance.ts`. The paired sampling and regression
gate apply to every gate of every variant. Keep text synthetic and test the
real path the scenario is measuring.

## Native search and cached indexing

The same job measures native search and cached indexing against 65,536
file-backed chunks with 1,024-dimensional synthetic vectors. Dense retrieval,
full-text retrieval with hydration, and vector-cache reuse have separate paired
measurements. Seeding, candidate preparation and inference stay outside the
clock; each sample checks the returned rankings, hydrated text and provenance
against the other revision. Query samples contain eight lookups; cached-index
samples contain four updates. The same
paired-budget gate applies. The native report uses schema 2 and retains the
raw medians alongside the paired budget score. Native results are in
`performance/search.json` and JSONL.

Run that comparison after building both runtimes:

```sh
nix develop .#ci --command node runtime/dist/test/fixtures/search-performance.js \
  --baseline /path/to/base/runtime/dist/src/search.js \
  --candidate runtime/dist/src/search.js \
  --output performance/search.json
```

Add native scenarios to `runtime/test/fixtures/search-performance.ts`. Keep
setup outside timing and verify the actual result as well as its latency.
These synthetic measurements complement live corpus latency and retrieval
recall checks.

Live qualification against 1.35 million published chunks measured 112 ms for
keyword-only retrieval and 12.8 seconds for an exact dense scan. Two concurrent
CLI searches took 11–18 seconds end to end; their query embeddings took
617–653 ms. A retained-history page loaded in 0.8 seconds. These are observations
under ongoing background work, not CI thresholds.

Explicit keyword mode still runs dense retrieval for tie-breaking and fallback.
Automatic chat context uses keyword-only retrieval on its separate reader, so
it does not wait for that scan.

Large projections now scan compact binary vectors for 4,096 candidates and
rerank their original float vectors. The compact table is derived in bounded
publisher transactions from retained embeddings; absent or incomplete tables
retain exact retrieval. Smaller projections keep the contiguous exact scan,
which outperformed scattered candidate hydration in the paired fixture.
Candidate preparation starts at 32,768 chunks; retrieval switches at 4 GiB of
published float vectors.

Private qualification compared the complete reader against the exact reader on
20 retained retrieval cases and representative queries at 1.35 million chunks.
All returned rankings, hydrated matches, provenance and coverage were identical,
including both hardware routing queries. The 20-case run measured median
reader time of 8.0 seconds for exact scans and 2.9 seconds with candidates.
A later hardware pair under heavier I/O measured 9.1–14.7 seconds exact versus
4.8–5.8 seconds with candidates. Native process counters in a separate hardware
pair measured 6.4–6.9 GB read for exact retrieval versus 1.1–1.7 GB with
candidates. Query inference is outside these reader timings.

Binary retrieval remains approximate; these cases establish measured recall,
not a guarantee for every future query.
The paired CI corpus exercises candidate preparation and publication while
retaining exact retrieval at its smaller size. A bounded native regression
also runs the production binary ranking and float reranking function against
retained SQLite vectors, comparing separated semantic matches with exact
search and checking original text, provenance and deletion.

## Durable task and source state

Task-history traversal yields to transport and timers before each bounded page.
Exhaustive searches and history reads retain their full results while unrelated
requests can proceed. The bridge regression checks response ordering against
real retained Pi history, without replacing storage or the runtime.

Tasks and source events use keyed Pi documents. Small control records retain
source cursors and triage ownership; indexed references locate task owners and
related event versions without decoding unrelated retained bodies. Pi still
owns the SQLite schema and atomic commit boundary.

Startup migrates legacy documents in batches of at most 32 records or 4 MiB,
retaining the exact old records. Each batch is independently durable and resumes
after interruption. A record larger than the budget owns its own batch.
The native insertion result distinguishes new records from existing ones, so
fresh records skip redundant index scans. Already handled originals do not
create pending-work indexes.
Migrated startup checks only the completion markers. The runtime regressions
close Pi during both migrations, reopen the file, and verify ownership,
versions, decisions and relinking. Cold point reads and hot admission also have
byte budgets against actual native SQLite reads and writes in CI.

The reusable growth fixture measures first migration, warm reopen, cold point
reads and repeated task/source admission at increasing retained sizes:

```sh
nix develop .#ci --command node runtime/dist/test/fixtures/state-growth.js
```

Set `AGENT_STATE_COUNTS`, `AGENT_STATE_SOURCE_BYTES`, `AGENT_STATE_TASK_BYTES`,
`AGENT_STATE_RUNS` and `AGENT_STATE_REPORT` to qualify a larger synthetic corpus
and retain JSON. Setup stays outside admission timing. The fixture records the
actual SQL emitted by Pi and runs `EXPLAIN QUERY PLAN` with its real parameters.
Point lookups use `documents_by_address`; document materialization and writes
use the existing document-revision indexes and primary keys. No SQLite schema
changes or extra indexes are required.

Local qualification with 4,096 tasks, 366 MiB of source text and 8 MiB of task
summaries measured:

| Operation | Legacy documents | Keyed documents |
| --- | ---: | ---: |
| Cold task and source-status read | 385 ms | 0.49 ms |
| Task admission, median | 86.7 ms | 5.1 ms |
| Task admission, p95 | 124.8 ms | 11.1 ms |
| Source admission, median | 12.4 ms | 4.9 ms |
| First readiness, including migration | 394 ms | 5,717 ms |

The one-time migration trades startup work for bounded normal reads and writes.
Subsequent Harness reopen took 0.93 ms, followed by the 0.49 ms point read.
These local observations are not CI latency thresholds. The CI regressions
verify bounded materialization and persistence, not machine-specific timings.
Migration cost depends on record count as well as retained bytes. Qualify a
consistent snapshot before activation and allow a maintenance window for the
first open. Later starts read only the completion markers.

## Tool discovery

Before tool discovery, every role offered every tool directly. The first main
request declared 30 tools in about 14,900 characters of names, descriptions
and schemas. Pi offers two ways to declare less. `tool_search` loads deferred
tools when the model asks for them, and `codemode` lets the model call tools
from a script. Either one helps only if it removes more tokens than its extra
requests add.

Production now uses both, one per role. `TOOL_SURFACES` in
`runtime/src/toolsets.ts` maps each role to its deferred tools and, for code
mode roles, to the tools that stay direct beside `codemode`:

| Role | Surface |
| --- | --- |
| main | Direct tools and `tool_search`. The browser tools other than `browser_screenshot`, and the context repository, worktree and source tools, are deferred. |
| triage, worker, agent | `codemode`, with `read_file`, `read_attachment`, `browser_screenshot` and, outside agent, `record_task` direct. Scripts reach every other tool. The browser, context repository, worktree and, outside triage, source tools stay out of the script section until a script searches for them. |

The [results](#hillclimb-results) below explain the choice.
`runtime/test/fixtures/tool-discovery.ts` holds the alternatives in one table,
`DISCOVERY_ARMS`. `direct` offers every tool directly, as before, and
`production` is `TOOL_SURFACES`.

Every surface keeps `finish_without_reply`, `read_attachment`, `read_file` and
`browser_screenshot` directly offered. `finish_without_reply` must be the main
turn's own final call. A script receives only the text of a nested result from
a tool without a structured output schema, and `read_attachment`, `read_file`
and `browser_screenshot` can return images. Scripts cannot call
`browser_screenshot` at all, because its image and attachment would be lost.
Triage and worker also keep `record_task` direct. A recovery turn reconciles its input
through the turn's own `record_task` call, and a call from a script fails that
check.

Code mode changes what a person sees in the history of a triage, worker or
agent conversation. A command or file edit that a script makes does not get its
own Command or File changes item. The `codemode` item lists each call the
script made, with its status, above the script's output. The line shows the
command for `exec`, the path for `write_file` and `edit_file`, and the tool
name for other calls. If Pi cut the call's arguments at 200 characters, the
line shows only the tool name. Tool details for the item show the script.
`beep-boop tasks graph` shows a running script's calls as tool nodes under its
`codemode` call. Main's history does not change. Rendering a script's `exec`
and file calls as Command and File changes items is follow-up work.

`runtime/test/tool-discovery.test.ts` runs every arm on the real Harness with
the faux provider. It checks these behaviors:

- The tools each role offers, and each arm's declaration size against `direct`.
- A tool loaded by `tool_search` stays offered after reopen and compaction.
- A worker script cannot call the main-only `delegate_task` or record another
  task, and a main script cannot finish the turn without a reply.
- A main script gets the same task and job results as direct calls.
- A worker script's history item lists the command it ran, the path it
  edited and the script's output.
- `record_task`, `report_result`, `notify` and `notify_user` called from a
  script save the same caller identity as a direct call. The saved outcome
  names the caller's conversation and the assistant entry that issued the
  `codemode` call.
- Reopening does not repeat a settled call or an interrupted call that is
  unsafe to replay. An interrupted replay-safe call runs again.

### Live eval

`runtime/test/tool-discovery-eval.test.ts` runs nine invented scenarios against
a real provider:

| Scenario | Role | Passes when |
| --- | --- | --- |
| `direct-answer` | main | The answer contains 210, the minutes in 3.5 hours. |
| `task-status` | main | The answer names the credit note a saved task waits for. |
| `delegation` | main | A new release-notes task exists and a worker spawn was requested. |
| `file-edit` | worker | One setting changed, the rest of the file is intact, and the task is resolved. |
| `child-agent` | worker and agent | A child agent finished and the parent resolved the task. The child's summary and the parent's evidence each contain at least one `root cause:`, `root cause is:` or `root cause was:` label, in any case and anywhere in the text. For every label, the rest of its sentence starts with the expired certificate, and the whole sentence has no negation word, such as no, not, never, without or a word ending in n't. |
| `browser-read` | main | The answer names the degraded component and its start time. |
| `job-inspection` | main | The answer mentions Lumen Parts, purchase orders, and a weekly or Monday schedule. |
| `source-triage` | triage | A credit-note mail links to its task and a newsletter is dismissed. |
| `long-history` | main | The answer recalls a deposit reference from the second of 24 earlier turns. |

The `child-agent` check does not read meaning. It rejects a denial that uses a
negation word or that names another cause first, and it rejects an answer with
no root cause label. It accepts a label followed by the expired certificate and
a contradiction without a negation word, such as "but we disproved that". A
label with words between `root cause` and the colon, such as
`Root cause (per the doc):`, does not count. The scenario asks for a line that
begins `Root cause:`. Each unit's `detail` keeps the child's summary and the
parent's evidence in full.

Each unit opens a private SQLite file and a temporary workspace. The eval host
returns invented guidance, reads, writes and edits files in that workspace,
runs only `ls`, `cat`, `head`, `tail`, `wc`, `grep` and `pwd`, and serves one
fixed status page to the browser tools. It returns a binding for a worker spawn
without starting a worker and refuses every other host operation.
Provider-hosted web search stays on, as in production. Main runs without the
related-conversation context that the coordinator adds to live chats.

To compare arms, set the provider and the arms, then run the eval:

```sh
AGENT_TOOL_DISCOVERY_EVAL=1 OPENAI_API_KEY=... OPENAI_BASE_URL=... \
AGENT_TOOL_DISCOVERY_ARMS=direct,production AGENT_TOOL_DISCOVERY_TRIALS=3 \
AGENT_TOOL_DISCOVERY_REASONING=low AGENT_TOOL_DISCOVERY_OUT=/tmp/tool-discovery.jsonl \
	nix develop .#ci --command node --test runtime/dist/test/tool-discovery-eval.test.js
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGENT_TOOL_DISCOVERY_ARMS` | `direct` | Arms from `DISCOVERY_ARMS`, comma-separated. |
| `AGENT_TOOL_DISCOVERY_TRIALS` | 3 | Trials per arm. The arm order reverses every other trial. |
| `AGENT_TOOL_DISCOVERY_REASONING` | the product default | Reasoning level for `gpt-6.1-sol`. |
| `AGENT_TOOL_DISCOVERY_SCENARIOS` | all | Scenario names, comma-separated. |
| `AGENT_TOOL_DISCOVERY_CONCURRENCY` | 4 | Units that run at once. |
| `AGENT_TOOL_DISCOVERY_TIMEOUT_SECONDS` | 600 | Limit for one unit. |
| `AGENT_TOOL_DISCOVERY_OUT` | a file in the temp directory | JSONL output path. Keep it outside the repository. |
| `AGENT_TOOL_DISCOVERY_KEEP_FAILURES` | off | Keep a failed unit's state directory and record its path. |

A wrapper around the OpenAI provider records every logical request, including
the requests of delegated child agents. Each JSONL row holds one scenario, arm
and trial: success, requests, uncached input, cache reads, output, total
tokens, the API-estimated cost, wall time, the tools the model called, and the
estimated declaration size of the first request, the recovered retries and the
tool results marked as errors. A recovered retry is a request that ended in a
provider error and was sent again. Each unit is its own subtest, so a failed
scenario fails the run and the TAP output names it. For each arm, the eval
prints the median suite total, the work count, the recovered retries, the tool
errors, and an error count. The error count is the number of units that threw
or had a request end in a provider error that was not retried.

### Baseline

The `direct` surfaces, `gpt-6.1-sol` at `low` reasoning, 6 trials of all nine
scenarios on 2026-11-15:

| Measure per suite | Median | Range |
| --- | ---: | ---: |
| Total tokens | 312,738 | 289,770 to 326,359 |
| Provider requests | 37.5 | 35 to 39 |
| Cache reads | 243,008 | 231,808 to 252,288 |
| API-estimated cost | $0.193 | $0.156 to $0.200 |

All 54 units passed their checks, with no errors and no retries. Each
`file-edit` unit saw one tool error. A request without tool calls costs about
7,700 tokens. About 4,400 of those are the hosted web search tool, and about
3,700 are main's estimated tool declarations. Most of the suite total is the
request count times that prefix, plus the conversation each request carries.
The spread comes from the scenarios whose request counts vary: `child-agent`
used 8 to 10 requests and `task-status` 3 to 4. One trial varies by about
4% of the median, so an arm needs about 7% to show a difference in 3 trials.

### Hillclimb results

Eight surfaces, one mechanism each, ran at `low` reasoning with 3 trials. The
table gives median suite tokens and the change from the baseline. Every trial
of every surface passed all nine scenarios.

| Surface | Tokens | Change | Requests |
| --- | ---: | ---: | ---: |
| Defer the browser tools | 278,139 | -11.1% | 38 |
| Also defer context repository and worktree tools | 279,516 | -10.6% | 39 |
| Also defer source tools outside triage | 263,109 | -15.9% | 38 |
| Code mode for every tool but the always-direct ones | 256,823 | -17.9% | 28 |
| Code mode, deferred tools out of its section | 235,808 | -24.6% | 30 |
| Also defer main's `record_task` and triage's file and job tools | 268,056 | -14.3% | 39 |
| Code mode, deferred tools out of its section, `record_task` direct | 232,928 | -25.5% | 29 |
| Main with tool search, other roles as above (`production`) | 223,414 | -28.6% | 30 |

The two mechanisms save in different places. Deferral shrinks every request.
Main's request without tool calls fell from 7,742 to 6,205 tokens. Code mode
removes requests. A script reads, edits and checks a file in one round, so
`file-edit` fell from 8 requests to 5 and `source-triage` from 7 to 3. Its
section costs about as much as the schemas it replaces, so code mode does not
pay on main, whose scenarios are one or two lookups.

The last surface became `TOOL_SURFACES`. A best-of-eight pick from 3 trials
can look better than it is, so a fresh run compared the shipped table with
`direct`, alternating, at both reasoning levels:

| Measure per suite | `direct`, `low` | `production`, `low` | `direct`, `xhigh` | `production`, `xhigh` |
| --- | ---: | ---: | ---: | ---: |
| Trials | 4 | 4 | 3 | 3 |
| Total tokens | 308,114 | 216,639 | 355,846 | 236,520 |
| Token range | 290,400 to 334,370 | 214,560 to 217,273 | 337,202 to 364,132 | 236,242 to 238,544 |
| Provider requests | 37 | 29 | 42 | 31 |
| Cached share | 0.78 | 0.71 | 0.78 | 0.68 |
| API-estimated cost | $0.175 | $0.159 | $0.220 | $0.197 |

`production` uses 29.7% fewer tokens at `low` and 33.5% fewer at `xhigh`. Every
`production` trial used fewer tokens than every `direct` trial, and every trial
of both passed all nine scenarios. The `xhigh` run measured `production` at its
eval-arm form before it moved into `runtime/src/toolsets.ts`, with the same
lists. The cost falls less than the tokens, because a smaller share of each
request hits the cache. The hosted web search declaration now makes up most of
a request without tool calls, and neither mechanism reaches it.

The runs above graded `child-agent` with an earlier check. It accepted any
answer that named an expired certificate, unless the answer matched a short list
of contradictions, so it passed "There was no expired certificate". Those runs
did not keep the answers, so they cannot be graded again. Two fresh runs of only
`child-agent`, at `low` with 3 alternating trials per arm, checked equal success:

| Check | `direct` | `production` |
| --- | --- | --- |
| Label at the start of a line | 2 of 3 passed | 1 of 3 passed |
| Label anywhere, the current check | 3 of 3 passed, 73,377 tokens (62,857 to 81,164) | 3 of 3 passed, 59,739 tokens (59,526 to 59,863) |

Every answer in both runs stated the seeded cause word for word. The three
failures in the first run put the label after a lead-in, such as
"It states: Root cause:", so the label-anywhere check replaced the line-start
check before the second run. Only the second run counts.

Keeping `exec`, `edit_file` and `write_file` direct in worker and agent did not
keep those calls out of scripts. The model still made its edits in a script in
two of three `file-edit` trials, so that variant did not ship.
