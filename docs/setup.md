# Setup

Install [Rex](https://www.superlogical.com/rex) and Tailscale on each execution
machine. Connect them to the same authorized tailnet. Provider CLIs keep their
own accounts and credentials; agent does not duplicate that setup.

## Coordinator

Choose one machine that stays on. It owns conversations, shared settings,
background intake and the main agent.

```sh
nix profile add github:jessfraz/beep-boop
beep-boop init
beep-boop serve
```

`beep-boop init` creates `~/.config/agent/config.toml` with private permissions
and refuses to overwrite an existing file.

`beep-boop serve` listens on the native Tailscale interface at port 43187 and a
private local Unix socket. Leave it running, then use another terminal:

```sh
beep-boop login
beep-boop status
beep-boop chat
```

Start the service before login. Otherwise the CLI starts a local-only daemon,
which owns the same database and prevents a second coordinator from starting. A
Nix service also satisfies this ordering. `beep-boop login` opens ChatGPT
sign-in; complete any identity check in the browser. Credentials are stored
privately and refreshed by the app. No Codex credential copying is required.

ChatGPT is the default provider. A signed-out chat reports
`Not signed in to ChatGPT. Run beep-boop login.` Other Pi providers can use
their supported environment or ambient credentials. Beep Boop does not provide
an interactive login flow for every provider.

## Worker or CLI client

On another execution machine:

```sh
nix profile add github:jessfraz/beep-boop
beep-boop init --coordinator tailscale://100.64.0.10
beep-boop serve
```

Replace the invented address with the coordinator's native Tailscale IPv4
address. The port is optional. The worker announces its native Rex identity
and local launch paths, and keeps a reverse connection to the coordinator.
Rex host labels and endpoints are reused when present in its shared host
inventory; a machine can also announce its own native Rex metadata. There is
no second host list to maintain in agent settings.

Use `beep-boop chat` from any directory in another terminal. It always reaches
the configured coordinator. Caller project information accompanies the request;
shared context and conversation storage stay on the coordinator.
`beep-boop nodes` shows registered machines and which are online.

In the TUI, `beep-boop` opens that same saved main conversation and attaches to
ongoing work. `/exit` or Ctrl+C detaches main chat while the work continues. If
closing waits on an input receipt, press Ctrl+C again to exit the client.
Accepted work continues. If delivery was unconfirmed, check saved history before
sending the message again. Reopen it to see live progress, steer or queue more
context. Saved messages load automatically in the background while the composer
remains usable.

Task sessions open directly into an interactive `Chat` tab. Reply there or
through the main agent; both use the same task conversation. Named child tabs
return results while remaining available for follow-ups. Live activity shows
tool names and exposed provider thinking text.

TTY sessions use a Markdown TUI with model, reasoning, directory and activity
status. Enter steers active work; Tab queues a separate follow-up turn. Queued
messages run in FIFO order. Esc stops, and Shift+Enter or Alt+Enter inserts a
newline. Press `?` in an empty editor or use `/help` for commands and shortcuts,
generated from the same definitions used to parse them.
Pending messages share compact previews above the composer; each keeps its own
delivery state and appears once in history when placed.
Presentation follows the installed Codex CLI 0.165 conventions: prompt gutters,
neutral Markdown replies, exposed reasoning summaries, bounded tool output,
an unbordered composer and colored model/directory context. Live and restored
messages share the same typed cells. Ctrl+T opens the transcript; Enter on a
saved tool reads its private arguments and output on demand.
Esc returns to chat without stopping its work.

The reference implementations are Codex's [message cells](https://github.com/openai/codex/blob/rust-v0.165.0/codex-rs/tui/src/history_cell/messages.rs),
[tool cells](https://github.com/openai/codex/blob/rust-v0.165.0/codex-rs/tui/src/exec_cell/render.rs)
and [composer](https://github.com/openai/codex/blob/rust-v0.165.0/codex-rs/tui/src/bottom_pane/chat_composer.rs).

In chat, input sent after Esc waits for its stop receipt; editing and other
chats stay responsive. If stopping cannot be confirmed, the input stays unsent
for recovery. Pi's compaction shows as **Compacting context**; current
instructions reload before the next model round. Select transcript text with the
terminal's normal copy/paste controls; the wheel and trackpad use native
terminal scrollback. PgUp/PgDn scroll the loaded conversation or shortcut help.
On a Mac, use Fn+Up/Fn+Down. Up/Down recalls sent prompts when the editor is
empty; slash commands offer completion. Use `beep-boop --no-tui chat` for plain
output or `beep-boop --json chat` for protocol events.

Reopen the CLI after updating it to load presentation changes. Detaching an
older client preserves server-owned work and saved history.

Temporary connection loss shows `Reconnecting` until the same chat reattaches.
Drafts and queued inputs stay in place; saved input IDs reconcile delivery.
The phone persists coordinator acknowledgements, so returning to the app does
not turn a saved message into an uncertain send. Delivery and processing are
separate: work can be queued, running, completed, stopped or blocked. Completed
work is normal; blocked work explains the required recovery. Sending a message
can resume a parked main generation. Reconnecting alone never retries work.
An unconfirmed write is never resent automatically. Exiting during an outage
saves pending input under the local state directory.

Drag files into the terminal composer to attach them. Complete shell-escaped
file paths become attachment chips; ordinary text stays in the prompt. Up to
eight files of 16 MiB each are copied before transfer. Backspace in an empty
editor removes the last attachment. Images use Pi's model image input; other
files are available to agent tools on the execution host.

`/resume` opens a saved-chat picker in this terminal. Filter by title or ID,
press Enter to choose, or Esc to keep the current chat and draft. Browsing
history does not start work. A new message reuses the selected conversation's
worker, reopening its Rex session in the background when needed.

Use `/model`, `/reasoning` or `/fast` to change the current conversation, and
`/status` to inspect its effective settings, connection and available plan usage.
`/model` without an argument lists models; `/fast` alone toggles fast mode.
Changes persist when the conversation reopens and apply to the next model
generation. TOML supplies defaults for new work. `/help` has the accepted
arguments; Pi validates model capabilities.

`/goal <objective>` gives the current conversation one persistent objective.
In main it starts a task on the default host. In a task view it uses that task.
When a turn ends without a verified result, the task continues on its own, up
to five times per activation. A turn that fails, for example on a provider
error, does not continue. Neither does a turn that leaves the task waiting on
someone else, until a new message reaches the task. `/goal` shows the
objective, its state and continuations, the task's latest summary and the last
refused attempt. `/goal pause` stops the goal's current turn and queues no more
goal turns. Other messages already queued in the task still run. Pause also
cancels the host action the turn is running, as Esc does, but it cannot undo
an effect that already happened, such as a file write. `/goal resume` starts a
new activation in the same task. A goal completes only when the runtime itself
finds the required text in the named file on the task's host. The task's
history keeps the result of each check that returns while its turn and
activation are still running. A check, passed or failed, that returns after a
pause, Esc or a new activation is discarded. While a goal is open, the task
cannot mark itself resolved. The phone accepts the
same commands for main.

OpenAI Responses models have hosted web search enabled, including page opening
and find-in-page when the model supports them. The same tools apply to the main
agent, tasks and child agents. Citations remain copyable links in saved history.
Availability depends on the model and account; an unsupported tool is reported
as a capability failure. Other providers keep their native tool configuration.
This does not give the agent access to a signed-in Chrome session.

### Chrome

Chrome tools are an optional fallback when an API or CLI cannot complete the
task. They use the selected host's running Chrome, on macOS or Linux. Browser
effects stay on that host even when the coordinator runs elsewhere.

On each host that should provide Chrome, add this section to its private Beep Boop
configuration:

```toml
[browser]
# Optional: pin a profile instead of the last-used one with Playwright installed.
# profile_dir_name = "Profile 1"
# Optional credential launcher prefix; secrets enter only the browser helper.
# credential_command = ["with-credentials", "browser", "--"]
# Optional: an existing Chrome instance's user-data root, not a copied profile.
# user_data_dir = "/example/chrome-data"
```

Install the official [Playwright
extension](https://chromewebstore.google.com/detail/playwright/mmlmfjhmonkocbjadbfplnigmagldckm)
in that existing Chrome profile. Its status page displays a profile-specific
`PLAYWRIGHT_MCP_EXTENSION_TOKEN` . Provide that token to Beep Boop's service
through its private credential environment, directly or through
`credential_command` , then restart the service. Keep the token in a secret
manager and out of Beep Boop configuration, launcher arguments, repository files,
and the Nix store. Installation and pairing are one-time setup; fresh tasks and
service or browser restarts reuse the token without another connection approval
click. Upstream opens a temporary Chrome connector URL containing the token.
Beep Boop discards its output and closes that connector after pairing.

An existing Chrome with native debugging enabled can instead use a loopback
CDP connection:

```toml
[browser]
debugging_port = 9222
```

This selects the connected browser's current profile. Omit `user_data_dir` and
`profile_dir_name` in this mode; they cannot pin a profile through CDP. Native
connections disconnect without quitting Chrome and require no Playwright
extension token. Beep Boop does not launch Chrome or create a replacement profile
when this endpoint is unavailable.

Chrome's `chrome://inspect` connection mode requires approval for each new
connection. Unattended native CDP requires Chrome's command-line debugging
port with a nondefault user-data root. Moving an existing profile needs a
separate migration and launch setup; pointing at an empty directory loses its
signed-in context. Launch setup must handle macOS restoring stock Chrome before
the wrapper. Startup flags cannot be added to an existing process; any recovery
restart must honor Chrome's normal unsaved-work checks. Chrome's upcoming macOS
encryption changes also make default-root cookies incompatible with custom
roots. See Chrome's
[debugging requirements](https://developer.chrome.com/blog/remote-debugging-port)
and the [cookie-key change](https://github.com/chromium/chromium/commit/c7ee20cc2303adf430ec7c1996afa8d20f2f8641).
Migrating a disposable profile is not proof of personal account continuity.

The extension connects to installed Chrome and the selected existing profile.
Chrome for Testing is a disposable test fixture, never a production fallback.
Disposable macOS tests use `--use-mock-keychain` and `--password-store=basic`
to avoid accessing Keychain. These flags do not belong on the user's Chrome.
Extension mode needs no native debugging port. Its connector can start
installed Chrome with that same profile when it is closed.

`profile_dir_name` selects the final directory component shown by Chrome's
profile path, such as `Default` or `Profile 1`. `user_data_dir` selects the
existing browser's data root, not the profile directory inside it. The token
must belong to that exact profile. Confirm the website's account before an
account-specific action. Browser state remains local. Script scope is not a
process security sandbox; the existing task authorization applies to code.

Scheduled sign-ins use the 1Password CLI from the running agent. Browser
scripts support standard Node imports, so a script can run the configured
machine-authenticated CLI, select the saved login for the task, and pass its
values directly to Playwright. Keep credential output inside that function;
return only the task result. No website-specific Nix entries or browser
credential mappings are needed. Machine authentication stays with the
credential provider and does not depend on unlocking the desktop extension.

Ask Beep Boop to use Chrome on a named machine when necessary. With native
Chrome, `browser_user_tabs` discovers existing user web tabs without navigating
them. `browser_claim_tab` takes the exact returned identity, URL and title to
borrow a signed-in tab; another conversation cannot claim it concurrently.
Workers default to their owning host; workers and the coordinator can explicitly
choose another connected host for browser recovery. Release a live connection
before switching hosts. An offline default never silently selects another
machine's account. `browser_open` creates a disposable tab.
`browser_status` inspects the live connection;
`browser_run_code` runs an `async (page) => { ... }` function with the normal
Playwright Page API. Use whichever locators, waits, frames, evaluation, file
uploads, downloads and other browser operations the task needs. Await the
operations and handle dialogs through normal Page event handlers. Return a
serializable result. Only that explicit result is returned, with secret
redaction; console output and automatic page snapshots are omitted. Request
`browser_action` snapshot explicitly when needed. Pages created through
`page.context().newPage()` and popups from owned pages are tracked for cleanup.
`browser_action` also provides convenience commands for snapshots, navigation,
form input, clicks, keys, dialogs and retaining a result tab. Handles
refer to exact live Page objects; tab reordering cannot retarget an action.
Handles and automatic cleanup cover owned pages and their popups. Other pages
dragged into the task's group remain unowned and are preserved. Moving an owned
page out invalidates its control handle and preserves the page.

Clicks, form input, and key presses bring their owned tab to the front. Reading
snapshots leaves the foreground tab alone.

Claimed user tabs are released without closing them, including after errors;
their drafts and existing page state survive. `close_tab` cannot close them.
Disposable tabs close when the turn finishes. `retain_tab` preserves a needed
draft or result for the user; `browser_release` closes remaining disposable tabs
and disconnects while Chrome keeps running. Retained results survive disconnect
and leave the task's tab group.

After interruption or connection loss, Beep Boop retains uncertain operations and
inspects their outcome before repeating them. A browser or host restart
invalidates old tab handles; it does not prove a submission failed. Reconnect
to continue, preserving tabs whose ownership cannot be verified.

`browser_screenshot` captures one owned tab as a PNG at CSS scale. It captures
the viewport unless the call sets `full_page` to true. A capture over 2 MiB
(2097152 bytes) fails, so capture the viewport or scroll to the part you need.
Like a click, a screenshot brings its tab to the front. The model receives the
image in the tool result, and Beep Boop keeps the same bytes as a retained
attachment on the tool's row in history. The model can pass that attachment ID
to `read_attachment` or to a delegated agent. The CLI shows the attachment's
name and size. The iOS app lists it under the tool's activity and previews it
after checking its SHA-256. Code mode scripts cannot call `browser_screenshot`,
because a script receives only the text of a nested result.

Screenshot pixels are not redacted. Text redaction, including captured
passwords, does not apply to images. Chrome masks password fields, and anything
else visible on the page appears as shown, so capture only what the task needs.

Scripts can also use Playwright screenshots and file APIs on the execution host.
Those files stay on that host and do not reach the model or history. Chrome
settings, desktop applications and general desktop control use other tools.

Chrome may detach an extension debugger when another extension inserts a
protected frame, including some password-manager menus. That loses the live
Page handle even if the native tab stays open. Beep Boop reports the interrupted
operation and unverified cleanup rather than treating the tab as closed or
replaying its actions. Native CDP avoids this extension debugger restriction.
Verify completed sign-in and the intended task on each host with 1Password
enabled before considering deployment complete. A filled field does not prove
the website accepted input or authenticated the account. MFA, rejected requests
and uncertain submissions remain unfinished work until resolved.

See the upstream [extension setup](https://github.com/microsoft/playwright/blob/main/packages/extension/README.md)
for installation, profile selection and token pairing.

`/feedback <description>` saves private diagnostics and starts a background
repair worker on the originating machine. A repair started inside Rex uses a
named terminal in that folder; later reports reuse the repair task. From a raw
CLI, the first report creates its repair session. Results appear in the saved
main chat. `beep-boop feedback latest` and `beep-boop feedback show <id>` read
captures; `beep-boop feedback retry <id>` retries a saved report with its
original identity. Inside Rex, feedback includes an HTML capture of the
originating terminal. On iOS, `/feedback` starts a
[Scrawl recording](../ios/README.md#send-feedback-with-scrawl) instead. Added
files follow the report to the repair worker. Captures stay in
private coordinator storage.

Import existing local Codex conversations after both services are connected:

```sh
beep-boop import codex
beep-boop import status
beep-boop history search "supplier fabrication question"
beep-boop history read CONVERSATION_ID
beep-boop history open CONVERSATION_ID
```

The import creates no Rex sessions. Rerun the same command to resume partial
reads and catch up changed conversations. `--host NAME` limits an import to a
registered host. An unavailable source is reported as partial coverage, not
silently skipped. [History](history.md) describes storage and retrieval.

Use `beep-boop jobs status` to inspect background work and retained errors.
If history indexing is parked after interrupted restarts, use
`beep-boop import retry-index` to resume its checkpoint and staged vectors.

A CLI-only client uses the same `beep-boop init --coordinator ...` command and
skips the service. The [native iPhone client](../ios/README.md) connects to the
same main conversation over Tailscale. Use the coordinator's full MagicDNS name
and port `43187` ; numeric tailnet IPv4 addresses also work. Rex's phone CLI
remains available for terminal access.

If the coordinator is unavailable, chat reports the failure. If a worker goes
offline, its tasks remain assigned to it. The MVP does not transfer live work
or synchronize the database between machines.

## Trust

Both ends verify native Tailscale peer identity. The listener never binds to a
LAN or wildcard address. By default, authorized untagged devices belonging to
the same user are accepted. Set `trusted_user_ids` to pinned numeric Tailscale
user IDs to accept that human's authorized, untagged devices automatically,
including a new phone, without adding each device's stable node ID. The daemon
must verify that the node's user matches its identity profile; names and email
addresses never grant trust. Set `trusted_nodes` to exact stable node IDs for
tagged servers. When either list is nonempty, a peer must match a pinned node
or a pinned user under the untagged-device rule; the default same-user rule no
longer applies. For a tagged coordinator, pin its stable node ID on clients and
pin the human user IDs allowed to connect in the coordinator's private config.

When a machine has both GUI and system Tailscale daemons, set
`tailscale_socket` to the intended daemon's socket. Identity checks and
connections use that selection. Rex's embedded Tailscale identity is distinct
from the native daemon identity used by agent.

## Settings and sources

### Scheduled jobs

Keep jobs in Git and configure `job_directories = ["~/automation/scheduled_jobs"]`
on the coordinator. A job file contains a readable stable `id`, `prompt`,
`model`, `reasoning_effort`, IANA `timezone`, and one or more `[[schedules]]`,
each with its own stable `id` and anchored DTSTART/RRULE `recurrence`. See the
[example job](../examples/scheduled_jobs/daily-review.toml). IDs are unique
across jobs and within each job's schedules; renames retain their IDs. Optional
schedule `focus` and `prompt` narrow a pass while retaining the main rules.

Run check and sync in the coordinator's checkout after editing or pulling the
files. Sync rejects remote clients so their local paths cannot select a
different working directory on the coordinator:

```sh
beep-boop jobs check --next 5
beep-boop jobs sync
beep-boop jobs list
beep-boop jobs get daily-review
beep-boop jobs retry daily-review
beep-boop jobs run daily-review
beep-boop jobs run daily-review --schedule morning
```

`check` and `sync` also accept repeated `--directory PATH` arguments. Check
validates the whole catalog and previews occurrences without applying changes.
Sync replaces the managed job catalog with that complete validated snapshot:
unchanged timers retain their deadlines, changed timers are replaced, and
removed schedules stop admitting work. Missing directories, invalid TOML or
duplicate IDs leave the applied catalog intact. An existing empty directory
can intentionally remove all jobs. Source timers are outside job sync's scope.
`/jobs` and `/jobs ID` use the same read requests and presentation as list/get.
`get` includes the latest execution's start, finish, retry or blocking error,
and exact completed reply. Pi owns these records; inspecting them starts no
work. Older runs without a retained execution reference show unavailable
timing rather than treating admission as completion. `--json` retains the
typed result for scripts.
An active retry shows its current running state. Its previous work failure
remains saved but is not advertised as current while that exact work executes.
Planner failures, backoff and blocked work remain visible.

`retry` resumes an existing execution parked after Pi's restart limit. It keeps
the same task, occurrence and checkpoints, and does not admit another run or
move recurring timers. A parked model generation resumes with current guidance
and tools when its execution host is connected. Unknown jobs and jobs
without a parked execution are rejected. Use `run` for a separate new pass.

On iOS, Connection → Jobs and work lists applied jobs and saved conversations.
A job's detail shows its schedules, execution state, retained timing, errors and
reply. **Retry interrupted run** uses the same recovery path. Open its owning
conversation or a sub-agent to inspect live activity and earlier history.
Inspection is read-only; closing it detaches the viewer and leaves work running.

`run` queues the applied job now with its saved prompt and model. A job with one
schedule selects it automatically; a job with several requires `--schedule ID` .
`/run-job JOB [--schedule ID]` uses the same admission path. The response
identifies the durable task; admission does not mean completion. Manual runs
serialize with the job's scheduled runs without changing its next occurrence or
any source timer. Each explicit request creates a run, including when that job
already has work queued. Inspect it with `beep-boop tasks read ID` .

Timer and manual runs share the job's task and Pi conversation. Job-owned work
and its child agents run in the coordinator's background process through
registered host connections, without opening Rex sessions or terminals. Chat
views attach to that same saved conversation. Audit individual inputs and
outcomes rather than counting tasks or using a task's last-update time as a run
boundary.

Startup applies valid configured directories; validation errors retain the
applied catalog and are reported in the coordinator log. Without configured
directories it retains the last explicitly synced catalog. Jobs start with
future occurrences; restarts coalesce missed ticks and serialize runs per job.
Each admission retains its original prompt/model snapshot. Pi wakes the running
coordinator; offline time is reconciled when it returns. Existing hosted
automations require a separate verified cutover.

The MVP accepts HOURLY, DAILY and WEEKLY rules with INTERVAL, BYDAY, BYHOUR,
BYMINUTE, BYSECOND and WKST. DTSTART must agree with the named timezone and
rule. Nonexistent local occurrences are skipped; repeated local times use the
first instant. Source polling uses elapsed intervals through the same Pi timer.

### Dreams

Dreams is one scheduled job that reads the coordinator's private runtime
receipts and task summaries each night. It proposes at most one diff to a
private Git repository, or it abstains. A proposal changes nothing until you
approve that exact outcome with `beep-boop dreams apply`.

Point Dreams at a repository of guidance that your agents read, such as one of
your `context_repositories`. Add the policy to the coordinator's private
configuration file:

```toml
[dreams]
repository = "/Users/example/context"
editable = ["AGENTS.md", "playbooks/*.md"]
window_hours = 24

[[dreams.checks]]
name = "commands-exist"
argv = ["/bin/sh", "/Users/example/dreams-checks/commands-exist.sh"]
timeout_seconds = 60
```

`repository` is the root of a Git work tree. `editable` lists the only paths a
proposal may change, relative to that root. A `*` matches within one path
component. A path with a component that starts with `.git` is never editable.
`window_hours` is 1 to 48 and defaults to 24. Each check is a program with
literal arguments that exits 0 when a checkout is healthy. Dreams runs every
check on the base commit and again on the candidate, so each proposal records
before and after results. See the
[example check](../examples/dreams/commands-exist.sh).

The `[dreams]` table is validated with the rest of the configuration. An
invalid table, such as one whose repository does not exist, makes `serve`,
`jobs check`, `dreams` and every other `beep-boop` command that reads the
configuration fail until you fix or remove the table.

The policy loader refuses a repository that contains the configuration file, a
job directory or the state directory. It also refuses a check whose arguments
name an editable path. The loader follows each argument as the check would see
it, from the repository root, through symlinks and without regard to case. It
treats the value of a `name=value` argument, such as `--file=AGENTS.md`, the
same way. It refuses a relative argument that contains `..`, and a relative
argument that is not ASCII, because a volume can fold other characters into an
editable name. The coordinator applies the same rule again before each run's
checks, in the clone that they run in, because a later commit can turn a
harmless argument into a symlink to an editable file. A refused check fails
that run with the same message, and no check starts. That rule catches a path
written in the configuration. It does
not see a short option with an attached value, such as `-fAGENTS.md`, a path
inside a `-c` string, or a file that a check program opens by itself, so the
rule about checks below still applies. Keep check programs
outside the repository. Restart the coordinator after you change the policy.

Copy the [example job](../examples/scheduled_jobs/dreams.toml) into a job
directory, then check and sync as for any job. The job id `dreams` is reserved.
A job with that id can call `dreams_review`, `dreams_propose` and
`dreams_abstain`, and it has no shell, file, browser or delegation tool. Its
model requests also carry no hosted provider tool, so the model that reads your
private evidence has no web search. The coordinator records that rule for the
job's conversation and never lifts it. A `dreams` job without a `[dreams]`
policy still runs with only those tools, and each tool answers
`Dreams is not configured`.

If you ran a job with the id `dreams` before you upgraded, its task stops
running. The coordinator withdraws that task's unrun input and records why as
the task's outcome, and its history stays readable with `beep-boop tasks read`.
The next Dreams run starts a new task, so no earlier turn reaches the Dreams
model.

```sh
beep-boop jobs check && beep-boop jobs sync
beep-boop jobs run dreams
beep-boop dreams list
beep-boop dreams show RUN
beep-boop dreams apply RUN --approve sha256:OUTCOME_DIGEST
```

`dreams list` shows each run's window, coverage, outcome and status.
`dreams show RUN` prints the coverage gaps, the before and after check results,
the rationale, the body of each cited piece of evidence, the patch, and the
exact `apply` command. It prints at most 4,000 bytes of each evidence body and
16,000 bytes of evidence in all, and says how many bytes it left out. Evidence
and text that a model wrote are labeled and quoted. Control characters and
Unicode format characters, such as bidirectional overrides and zero-width characters,
are shown as escapes in that text and in the patch, so the patch you read is
the patch that `apply` commits. Add `--json` for the typed record, which keeps
the exact bytes. These commands read the
coordinator's state directory, so run them on the coordinator's machine.

Read the patch before you approve it. The outcome digest, which `dreams show`
prints as `Outcome sha256`, is the SHA-256 of the exact bytes of the sealed
`outcome.json`. Every sealed outcome, a proposal or an abstention, holds one
hash of the sealed review record and all of its evidence. A proposal also holds
the patch hash, the base commit, the changed files with their blob ids, the
cited evidence ids and the check results. `dreams show` reads the review and
the evidence once, checks them against that hash, and prints only the bodies
it checked. So the digest you approve covers the evidence bodies that
`dreams show` printed, not only their ids. `dreams show` refuses a run whose
review or evidence changed, and `dreams list` fails and names that run.
`apply` recomputes the outcome digest, the review hash and the patch hash, and
refuses with one of these messages, without changing the repository:

- `Dreams approval does not match the review`
- `Dreams review changed since it was sealed`
- `Dreams patch changed since it was proposed`
- `Dreams policy changed since this proposal`
- `Dreams base is stale: target HEAD is <commit>, proposal base is <commit>`
- `Dreams target has local changes in touched paths`
- `Dreams target has a held Git index lock: <path>`
- `Dreams run did not propose a change`

A local change is any difference in a touched path or its parent directories:
content, file type, a deletion, or an executable bit. Apply reads the
executable bit from the file itself, so it refuses even when `core.fileMode` is
off. A held index lock means that another Git command is running or that one
crashed. Remove a stale `index.lock` and apply again. Apply inspects the
target once and then writes. A process that writes to a touched path while
apply runs can lose that change, and one that takes the Git index lock can
make apply fail and leave `ORIG_HEAD` behind. Stop other writers to the target
repository while apply runs.

A successful apply adds one commit with `Dreams-Run`, `Dreams-Base` and
`Dreams-Patch-Sha256` trailers and fast-forwards the checked-out branch. The
commit uses your Git identity and is not signed. Apply then records that commit
in the run's directory. A second apply of the same run reports
`already applied` and changes nothing, even after `HEAD` has moved back to the
base, and `dreams show` says when the recorded commit is no longer reachable
from `HEAD`. If an apply was interrupted
after Git wrote the proposed content but before `HEAD` moved, `dreams show`
still reports `pending`, and the next apply finishes the same commit once. A
context repository serves approved guidance on the next turn. Revert the commit
to withdraw it.

A run abstains as `quiet` only when its coverage has no gaps. A gap is any way
the window may be missing evidence: expired or evicted segments, dropped or
unparseable receipts, a read that stopped early, a restart after a crash, or
more than ten minutes with no receipt. The coordinator writes a `heartbeat`
receipt every five minutes, so a stopped coordinator or a failed log writer
appears as an `unwitnessed` gap instead of a quiet night. A machine that sleeps
for more than ten minutes leaves the same gap. A `clock_moved` gap means that
receipt timestamps went back by more than a minute around the window, or that
a receipt is stamped ahead of the present. A receipt near such a move can carry
a time outside the window although it was written inside it, so the night is
not counted whole.
Smaller steps back are normal, because several senders stamp a receipt before
they enqueue it. A gap never blocks a proposal. It blocks only the claim
that the night was quiet. Task summaries are the text retained when the review
was sealed. They are a snapshot, not a history of the window.

The log writer also records when it starts and when it stops cleanly. When
`[dreams]` is configured, the coordinator starts no work until the writer has
written its start record. If the writer cannot write it, the coordinator exits
with an error that names `<state_dir>/diagnostics`. Causes include a read-only
`runtime.jsonl`, a file where the directory should be, a malformed
`retention.json`, and another process that holds
`<state_dir>/diagnostics/writer.lock` for 10 seconds, which the error also
names. Fix that path, or remove `[dreams]` from the config to run chat without
nightly review. While it waits, startup also takes the time the writer needs
to read the retained log.

Without `[dreams]`, startup does not wait for the writer. A writer that cannot
start prints `Runtime diagnostics unavailable; chat continues.` and the
coordinator serves chat, as it did before Dreams. That run leaves no receipts.
So a coordinator without `[dreams]` writes its start time to
`<state_dir>/unrecorded-start` before it serves, unless the file is already
there, and the writer removes the file once the log holds the start record. A
writer that finds the file left by earlier starts records that time first, and
the review shows an `unclean_restart` gap from the first unrecorded start to
the writer's own. A review after you add `[dreams]` back does not call that
time quiet. If the state directory refuses that file, only the ten-minute rule
above catches the run.

A writer holds queued receipts and its count of dropped receipts in memory, so
a crash loses them. When a writer starts and the receipt before its start is
not a clean stop, the review shows an `unclean_restart` gap from that receipt
to the start, even when the restart came within ten minutes. The writer leaves
flushing to the operating system. After an operating-system crash or a power
loss, the receipts written just before it can be gone, a recent start record
included, so a review of that time can miss the restart.

The first start after an upgrade from a version without these records leaves
one `unclean_restart` gap. Every review whose window covers that start shows
it, so with `window_hours = 48` that one upgrade can refuse a quiet abstention
in every run for two days.

A check runs with only `PATH`, `HOME`, `LANG` and `TMPDIR` in its environment,
in a private clone under `<state_dir>/dreams/runs/`. Write checks that read
candidate files as data. A check that executes or sources an editable file
runs proposed content before you have approved it. Dreams keeps every run
under `<state_dir>/dreams/runs/` and does not prune them. A backup leaves
`<state_dir>/dreams` out. A coordinator restored from a backup has no earlier
runs, reviews, evidence, patches, proposals or applied-run records. Its
`dreams list` is empty, and it cannot show or apply an old run ID or approve an
old digest. The target repository is outside the state directory, so the backup
does not copy it either.

To measure a model on Dreams, run the opt-in eval against your provider. It
writes one JSON line per trial, with each patch and check result, to the output
directory:

```sh
AGENT_DREAMS_EVAL=1 AGENT_DREAMS_EVAL_OUTPUT=/tmp/dreams-eval \
  cargo test --locked --test dreams_eval -- --ignored --nocapture
```

Set `OPENAI_API_KEY` and `OPENAI_BASE_URL` first. The eval covers a seeded
defect, a quiet night and injected text, three trials each by default.

### Coordinator settings

The commented [coordinator example](../examples/coordinator.toml) is parsed by
the same strict configuration loader as the CLI and exercised in tests. The
[client example](../examples/client.toml) is sufficient for workers and
terminals. Configuration is TOML, not JSON.

Set `context_repositories = ["~/context"]` on the coordinator to make an
existing private Git repository available to every chat. Beep Boop loads its
`AGENTS.md` and offers bounded read/search tools for relevant files. It does
not change the caller's working directory or require clients to copy the repo.

`[model]` controls defaults for new work. `provider` and `reasoning` are typed;
Pi validates the model ID. Omit reasoning to use the provider's default.
`fast = true` requests OpenAI priority service where supported; unsupported
choices fail explicitly. See the official
[fast-mode guide](https://developers.openai.com/api/docs/guides/fast-mode).
Existing tasks keep their saved selection.

Sources are optional `[[sources]]` entries. Set `enabled = false` to skip a feed
without even discovering its accounts. An empty list disables external intake;
internal task outcomes remain available.

| Source | Existing authenticated tools |
| --- | --- |
| `google` | Switchboard Google namespaces and `gws` |
| `google_calendar` | Switchboard Google namespaces and `gws` |
| `github` | Switchboard GitHub namespaces and `gh` |
| `slack` | Configured read-only CLI command |
| `messages` | Switchboard Messages namespaces, or local macOS `messages` |

Omitting `namespaces` discovers all configured accounts for that provider. An
explicit selection never falls back to another account. Slack additionally needs
its account and command prefix. The source command must be available in the
service's PATH. `beep-boop sources` shows each account's coverage, last check in
local time and safe diagnostic. `--json` also retains opaque checkpoints for
scripts. An access failure is not an empty inbox.

Messages reads run headlessly through the local Rex Server, using its macOS Full
Disk Access grant. Enable access for Rex Server once in System Settings;
beep-boop binaries do not need their own grant. No sessions or terminals are
created for polling. The agent's literal `messages doctor` , `messages chats` ,
and `messages read` commands, including their Switchboard equivalents, use the
same reader. Their working directory, deadline, diagnostics and output limits
are preserved. Commands run directly in an unrelated shell still use that
shell's macOS permission context.

With Messages enabled, the coordinator installs the small Rex action module at
startup, and workers check it when connecting using the coordinator's settings.
Existing Rex configuration is preserved; an unchanged module causes no reload.
Setup can also be run explicitly:

```sh
beep-boop rex install
```

If Rex configuration is managed elsewhere, include `require('agent_messages')`
through that owner. The command reports any setup failure and preserves the
existing configuration; other sources and chat can continue.

`beep-boop usage` and `/status` read quota through the coordinator's installed
Codex app-server, after verifying its signed-in account matches the agent's.
This does not expose a separate quota for agent, and requires Codex
independently. Reset dates use the client's local timezone and include the time
remaining.

`/status` also reads Pi Durable's own-conversation usage ledger: model/tool
tokens, cache reads and writes, reported reasoning tokens, and recent request
durations. Reasoning and one-hour cache writes are subsets, never extra tokens.
Imported history has no measured spend; child/ancestor ledgers are not added to
the selected conversation. Costs are Pi's recorded API-equivalent USD estimates,
not invoices or ChatGPT subscription charges. Unknown prices stay unavailable.
Timing samples cover the last 20 native entries; older or deferred responses may
have no duration.

The coordinator installs Pi's native buffered SQLite telemetry recorder at
`<state_dir>/diagnostics/telemetry.sqlite`, with seven-day retention and at most
2,048 queued spans or metric series. Status reports recorder availability and
dropped counts. Native request/phase timing and identifiers remain private;
prompt/response bodies, tool arguments, response IDs and error messages are
excluded. Metrics include request and first-chunk latency, token categories,
estimated cost and task phases. Nothing is exported to an external service.
Recorder failure does not stop chat or its durable usage ledger.

`/machines` reads the coordinator's host registry and refreshes supported online
workers. It shows OS, CPU count, RAM, Tailscale IP and load averages. Unavailable
probes retain their last sample with its age; unknown measurements stay unknown.

Worker lifecycle notices include UTC timestamps. Each service also writes
rotating structured lifecycle receipts to
`<state_dir>/diagnostics/runtime.jsonl` and its numbered archives (1 MiB per
segment). Retention targets 48 hours, with a 128 MiB total disk cap including
coverage metadata and its atomic replacement. Whole expired segments leave
first; capacity pressure can remove younger segments. These record
input placement, activity, host-call timing and interruption without message
bodies, reasoning, tool arguments or credentials. The files are private to the
user; logging failure does not block chat. With `[dreams]` configured, a
coordinator whose log cannot record its start exits instead; see Dreams above.

Browser host-call records correlate the conversation, session, operation and
local tab handle with duration, outcome and owned-tab count. Cancellation keeps
those same identifiers. Fixed connection stages and control-loss causes explain
failures without recording URLs, page content, scripts, input values or pairing
tokens. Script results and redacted error details remain in private tool history.

A slow runtime write records one `write_backpressure` event with its request,
command kind and byte counts. Event reads continue while that write is pending.
A clean stop records `service_shutdown` with `SIGINT` or `SIGTERM` and its
timestamp before pending requests close, distinguishing a managed restart from
a runtime failure.

Failures before the listener opens are recorded in `diagnostics/startup.jsonl`.
It retains initialization stages, durations and native numeric failure codes
without SQL, paths or error payloads, capped at 64 KiB. A restart loop can be a
storage failure; preserve the database and its WAL before attempting recovery.

`diagnostics/retention.json` records the policy, expiry watermark and cumulative
timestamp bounds of capacity evictions, including uncertain timestamp coverage.
It also flags unknown history when upgrading legacy rotations. Read actual
receipt files to establish the available interval; the watermark is coverage
evidence, not an inventory of retained files. An interrupted prune can report a
conservative possible gap. `dropped_before` counts channel overflow only, so
zero does not establish complete log coverage. Every sender of one writer
shares that count, so the next receipt written carries it, whether that is
another sender's receipt, a heartbeat or the writer's last line at shutdown. No finite cap guarantees a full
audit interval at an unbounded event rate. The writer also records a
`heartbeat` receipt every five minutes, so an interval with no receipt at all
means that nothing was written, not that nothing happened.

### Scrawl feedback

On a Mac worker that runs Scrawl, add this line to the private `config.toml`
and restart the service:

```toml
scrawl_feedback = true
```

`beep-boop maintain` then checks `~/Library/Application Support/scrawl/captures`
every 2 seconds. Each new finished capture becomes `/feedback` on a
coordinator, sent in the same request the phone sends. It starts the same
background repair, and the result appears in the main chat. The setting is off by default. It belongs to this machine, so
`beep-boop config apply` cannot set it. On other platforms the service logs one
line and ignores it.

Scrawl writes `summary.md` last, so a capture counts as finished once
`summary.md` has not changed for 2 seconds and no `.transcript-pending` marker
remains. Captures already in the folder the first time the watcher runs are
never sent.

The bundle decides where its feedback goes:

- A phone recording whose `timeline.json` carries a version 1 `beepBoop`
  target goes to that host and port. The watcher asks the coordinator to
  identify itself first and sends nothing unless its ID matches the one the
  phone pinned. A mismatch is logged and the capture is never sent.
- A phone recording without a valid target is logged and never sent. It never
  falls back to this Mac's coordinator.
- A capture of this Mac's screen goes to the configured coordinator.

The description is the typed `/feedback` text, or the Scrawl note for a Mac
capture, then `Narration:` and the narration transcript. `/feedback` joins its
words with single spaces, so the description is one line, limited to 4096
bytes. The watcher
attaches up to eight files of at most 16 MiB each, in this order:
`summary.md`, the contact sheet, `scrawl.json`, the phone's `Composer.log`,
the keyframes, then the recording if a slot is left. A larger file is skipped.

`<state_dir>/scrawl-feedback.json` records each capture as `backlog`,
`submitted`, `acknowledged` or `refused`. A submitted capture is resent with
its original request ID until the coordinator confirms it, so a restart does
not duplicate feedback. The coordinator deletes uploaded files after 24 hours,
so a capture still unconfirmed a day after it was sent is refused at its next
failed resend. A capture the coordinator rejects is refused and never resent.

To see what the watcher will do without sending or writing anything, run:

```sh
beep-boop scrawl-feedback --dry-run --captures-dir /path/to/captures
```

It prints one JSON line per capture. A capture the ledger holds shows its
state, with the reason for a refused one. A new capture shows `deliver` with
its destination, description and attachments, or `refused` or `incomplete`.
Before the watcher's first start, every capture present shows `backlog`.
Add `--state-dir` when the service uses one.

## Backups and restore

Back up a coordinator while it is stopped. Stop the service first; the command
never stops one. It takes the state directory's writer lock and refuses while a
coordinator or its Pi child still owns the directory.

```sh
beep-boop backup create /Volumes/Backup/beep-boop-2026-11-16
```

Add `--state-dir` when the service uses one. The destination must not exist.
The backup is a directory with `manifest.json` and a `data` folder that mirrors
the state directory. It contains:

- A copy of `session.sqlite` made with SQLite's backup API and checked with
  `PRAGMA integrity_check`.
- `coordinator-id`, so paired phones recognize the restored coordinator.
- Uploaded attachments, imported history assets and private feedback.

The manifest records the backup format, the application and Pi versions, the
database schema version, the coordinator ID, the integrity result and the size
and SHA-256 of each file. The command writes the backup in a hidden
`.<name>.partial-<id>` directory beside the destination and renames it only
after every file is written and synced. An interrupted backup leaves that hidden
directory, never a partial destination. Delete it when no backup is running.

The backup leaves out credentials (`auth.json`), the search index, diagnostics,
logs, sockets, locks and this machine's client state: worker caches, the Scrawl
ledger, the feedback outbox and saved TUI drafts. It also leaves out Dreams
state: `<state_dir>/dreams` with every run, review, patch, proposal and
applied-run record, and `<state_dir>/unrecorded-start`. The receipt lists both
as not included. The restored coordinator starts a new diagnostics log, so a
Dreams review that covers the time between the backup and the restored
coordinator's first start shows it as an `unwitnessed` gap and never seals a
quiet night. Dreams runs wait for `backup release`. The private TOML configuration
is outside the state directory, so keep a separate copy of it. The command
lists any other name in the state directory as not included. A backup contains
private conversations, attachments and feedback; keep it as private as the
state directory.

Restore into a new directory or an empty one:

```sh
beep-boop backup restore /Volumes/Backup/beep-boop-2026-11-16 ~/agent-restored
```

Before anything appears at the target, restore checks every path, size and
SHA-256, the database integrity and schema version, and the coordinator ID. It
refuses a target that is not empty, and it never reads or changes the existing
state directory. To check a backup without using it, restore it into a scratch
directory and then delete that directory.

A restored store starts held. Until the release, the held coordinator does not
run this work:

- Scheduled jobs, source polling, automatic triage and automatic history
  indexing.
- Phone notifications.
- Task turns. The coordinator starts no task actor and refuses the worker that
  a task's terminal starts, so no backed-up task turn resumes.
- Worktree collection, both the collection that each registered worker requests
  on its own and `beep-boop resources collect`.

A held store is not a read-only copy. It serves history and attachments, and it
runs chats and the other commands you send. A chat's tool calls run on hosts
and in the browser, and its own tool can still collect worktrees. A chat can
create tasks, send them input and open their terminals, but no task turn runs
until the release. `/goal` saves, pauses and resumes a goal, and the goal's
task turns and automatic continuations wait for the release. `/feedback` saves its report and opens a repair terminal on
the reporting machine, and the repair turn waits too. `beep-boop import codex`
imports history and indexes what it imports.

The restored coordinator has the same coordinator ID, so do not run it while
the original still runs. Check the hosts first, for example that work a
restored job would start has not already happened elsewhere. Then stop the
coordinator and release the hold:

```sh
beep-boop --state-dir ~/agent-restored backup release
```

Start the service with `--state-dir` set to the restored directory, or move the
directory to the default location while no coordinator runs. Run
`beep-boop login` again, because credentials are not in the backup. After the
release, the coordinator rebuilds the search index in the background.

## nix-darwin service

The flake exports `darwinModules.default`. Import it and reference a private
configuration file that already exists outside the Nix store:

```nix
{
  imports = [ inputs.agent.darwinModules.default ];
  services.agent = {
    enable = true;
    role = "coordinator"; # Use "worker" on the other machines.
    configFile = "/Users/example/.config/agent/config.toml";
    workingDirectory = "/Users/example";
    extraPackages = [ pkgs.gh pkgs.tailscale ];
  };
}
```

Include Rex, Switchboard and enabled provider CLIs in `extraPackages` as well.
The worker's TOML must set `coordinator`; the coordinator's must omit it.
The macOS module installs a user LaunchAgent: it starts at login and launchd
restarts it after exit. It does not run before a user logs in after reboot.
Model settings, source configuration, credentials and context stay in private
runtime files. Restart the service after changing its settings.

For generated preferences, `beep-boop config apply preferences.toml` updates
only the supplied model, context repositories, sources or polling interval in
the existing private configuration. Connection and trust settings remain local.
Invalid preferences leave the file untouched; repeated applications are a no-op.
This allows Nix to manage shared preferences without publishing machine
connection details or credentials.
