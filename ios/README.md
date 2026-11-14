# Beep Boop iPhone client

A SwiftUI client for the coordinator's main conversation. The coordinator owns
Pi, history, models, tools and Rex workers. The app connects through the existing
authenticated NDJSON-over-Tailscale service.

The visible app name is **Beep Boop**. The Xcode project, scheme, targets and
executable remain `Agent`, and the bundle ID remains `dev.jessfraz.Agent`. Keep
that identity and the existing signing configuration for updates to the same app.

## Build and connect

1. Build the matching coordinator and run `make bindings` from the repository
   root. The native protocol is additive but requires this coordinator version.
   Existing coordinator setup is described in [setup](../docs/setup.md).
2. Open `Agent.xcodeproj` in full Xcode with an iOS 18-or-newer SDK. The `Agent`
   scheme uses this directory's local Swift package, and the app target also
   links [ScrawlKit](https://github.com/kitlangton/scrawl). For a
   device build, choose a development team and use a bundle ID registered to it.
   Simulator builds do not require signing.
3. Connect Tailscale on the device. The coordinator must authorize its peer
   through the existing same-user, pinned-user or pinned-node policy. A pinned
   human account admits its authorized, untagged devices automatically.
   Tagged devices require their own pinned node identity. Tailnet network policy
   must also permit the coordinator port. See [trust configuration](../docs/setup.md#trust).
4. Enter the coordinator's full MagicDNS name (`machine.example.ts.net`) and
   port, normally `43187`, in Connection, then **Save**. Numeric Tailscale IPv4
   addresses also work. Save asks the address which coordinator answers and
   remembers that coordinator. If the address does not answer, Save keeps
   nothing. The optional name defaults to the first label of the MagicDNS name. Each connection resolves the name
   again and pins a validated tailnet address, so IP changes do not require
   editing the setting. Ordinary LAN addresses and IPv6 addresses are
   unsupported. Transport binds the active point-to-point interface's Tailscale
   IPv4 source address.
5. To use another coordinator too, choose **Add coordinator** in Connection.
   Names must differ, ignoring case, and an address that answers as a
   coordinator already saved is refused.

## Install on an iPhone

Install Apple's TestFlight app, accept the invitation to the private internal
group, install Beep Boop, and enable **Automatic Updates**. Connect Tailscale before
opening Beep Boop. Internal testing requires no public App Store release; builds
expire after 90 days.

The [Xcode Cloud workflow](ci_scripts/README.md) watches `main`, requires native
tests, archives for internal testing only, and distributes to the private group.
Apple manages signing. The linked setup covers repository access, build numbers
and the first verified upload. `TestFlightExport.plist` supports a manual
internal-only upload when needed.

Main-chat alerts require the one-time [APNs setup](../docs/notifications.md).
They start enabled: allow the notification prompt on first opening, then connect
to register automatically. Disable **Main-chat updates** in Connection anytime.
After an update from a build without saved coordinators, the app withdraws that
build's alert registration once it proves that a saved coordinator answers at
the address that build used, whatever the toggle says. That coordinator then
alerts this device only through the saved coordinator's own registration, and
only while alerts are on. A coordinator saved only at another address is sent
the withdrawal once a probe of that build's address finds it there. Until then
the phone cannot tell whether it is the one that build used. When that build
used more than one address, each coordinator proven at one of them gets its own
withdrawal. Until that coordinator confirms, the app sends it again each time it
becomes active.
**Connection → Appearance** follows the system by default. Choose **Light** or
**Dark** to keep a saved override.

For a direct development install, sign in to the developer account in Xcode
Settings, connect the phone, and select it as the `Agent` scheme's run
destination. Choose the team under Signing & Capabilities. Enable Developer
Mode if requested, then Run.

The app embeds `AgentShare`. For signed installs, register its bundle ID
`$(AGENT_BUNDLE_IDENTIFIER).Share` and enable the same App Group for both IDs.
`Shared.xcconfig` owns the base bundle ID, group, versions and signing team;
the group defaults to `group.$(AGENT_BUNDLE_IDENTIFIER)`. Keep the existing
host bundle ID when updating an installed app. Provisioning both targets is
required for sharing on a phone; an unsigned build does not establish that.

## Send feedback with Scrawl

ScrawlKit records Beep Boop with your narration, touches and drawn ink, and
sends the recording to Scrawl on your Mac. The watcher in `beep-boop maintain`
then sends it to the coordinator as `/feedback`, which starts a background
repair. Recording does nothing until you pair the phone.

1. Open Scrawl on the Mac.
2. Run `/Applications/Scrawl.app/Contents/MacOS/scrawl link --scheme beepboop --url http://<mac>.<tailnet>.ts.net:47777`.
   To get the Mac's Tailscale name, run `tailscale status --json` and copy
   `Self.DNSName` without the trailing dot. Pair by name because iOS refuses
   plain HTTP to IP addresses, so the default link, which carries IP
   addresses, can't upload.
3. Open the printed link on the iPhone, or scan its QR code. Pairing links
   work whatever the feed shows.
4. Show one coordinator's conversation. To start recording, send
   `/feedback` followed by what went wrong, or hold three fingers on the screen
   for half a second. The typed text becomes the recording's description.
5. To stop and send, hold three fingers again, or tap Send on the strip.

To unpair the phone, open `beepboop://scrawl?reset=1` on it.

A recording goes to exactly one coordinator: the one the feed shows when it
starts. That is the only coordinator saved, or the one whose conversation you
chose. It must be paired. Messages held from before the update that may belong
to another coordinator count as a second one. With no coordinator or several in
view, the three-finger hold does nothing.

Typed `/feedback` never goes to a coordinator as a message, so it works while
the coordinator is not connected. It records nothing, keeps the draft and says
why in these cases:

- The feed shows no coordinator, or more than one.
- The draft is addressed to a coordinator other than the one shown.
- Files are attached. A recording can't carry them, so send them as a message.
- Scrawl isn't paired.
- A recording is already running.

Each recording's `timeline.json` names its coordinator in a `beepBoop` object
with the coordinator's ID and address, the typed description and the
composer's diagnostics. If the feed shows anything else when the recording
stops, the phone leaves `beepBoop` out, and the Mac refuses the recording
instead of sending it to another coordinator.

Feedback through Scrawl has these limits:

- Scrawl must be running on the Mac. A recording made while the Mac is off
  waits on the phone until the next cable connection.
- The strip says "Saved on your Mac", because Scrawl doesn't know about the
  watcher. The repair result arrives in the main chat.
- A Mac capture (Option-Shift-S) becomes feedback only on a Mac whose
  `config.toml` sets `scrawl_feedback = true`.

If a recording doesn't upload, Scrawl can collect it the next time you connect
the phone by cable. To allow that, list the app's bundle ID under `usbApps` in
`~/.config/scrawl/config.json`.

## Behavior and data

- Saved history, streamed answer text, provider-shareable summaries, tool status,
  commentary, durable notices and compaction state use native views. Markdown
  uses Foundation's parser, with native headings, quotes, lists, code blocks and
  tables. Changed rows are prepared once per published snapshot, outside SwiftUI
  bodies. Complete messages use at most four parsing workers, joined before
  publication. Rendering and incoming pages
  are bounded; display truncation does not alter coordinator history.
- Startup reads a bounded recent page. Scrolling to the top loads earlier
  conversation while preserving the visible position. Tool-only pages are
  coalesced until dialogue appears, with an eight-page, 500-row, 4 MiB batch
  limit; **Load earlier messages** remains available. At most 500 rows and
  4 MiB of display text remain in memory. The coordinator retains full history.
  **Latest** returns to a fresh recent page, retaining concurrent replies and
  pending messages. It stays available if paging evicted recent history;
  otherwise it disappears at the bottom. Live output stays at the bottom through
  keyboard and composer size changes; scrolling up preserves the reading position.
- Consecutive tool calls and summaries share a compact disclosure. Progress
  messages stay visible. Expand activity to read every supplied summary or
  inspect a command's arguments, output, errors and status.
- Activity rows label the supplied action and use category icons. Unclassified
  shell commands remain **Ran**; the client does not guess Read/Search intent
  from command text. Expanded commands use one **Shell** card with literal,
  scrollable output and a result footer. Input metadata stays behind
  **Input details**; missing results never become Success.
- Long-press a message, summary or tool output for **Copy message**, **Select
  text** or **Share text**. Selection opens native text handles on a stable
  snapshot, so streaming cannot move the selected range.
- Tool details are read on demand from Pi's stored call and result. Each text
  section is limited to 32 KiB; missing content and truncation are shown.
  History pages carry tool identity and status without the full output.
- Slash parsing and execution use the shared Rust command parser and backend
  handlers. The phone menu lists only supported controls. `/resume` remains a
  TUI-only saved-conversation view; it never starts work from this app.
- Messages, including immutable attachment copies, are saved to the
  saved coordinator's own outbox before transmission. On iOS it
  uses complete file protection and is excluded from backup. History stays in
  memory; there is no separate phone conversation database. For its newest 2000
  entries, each coordinator's `Ledger.json` keeps the entry ID, the time this
  phone received it and the send ID. For its newest 2000 Sends, it keeps the
  recipients and the time each was queued. It never holds message text. It has
  the same protection, and it keeps the order you saw across a relaunch.
- The unsent composer saves its note, delivery mode and attachment references
  together. Reopening restores that draft; importing or restoring never sends it.
  The draft keeps its recipient and restored origin across a relaunch too, and
  one naming a coordinator no longer saved blocks Send.
  Choosing a command preserves the note and replaces only a known command prefix.
  The composer uses a plain native `UITextView`. Send copies its text and
  clears the visible buffer synchronously, keeping the keyboard active.
  Admission starts in that same button event; asynchronous persistence and
  delivery remain outside the editor. The submitted copy and newer draft
  checkpoint separately under a stable input identity.
  Recovery checks the original endpoint's retained receipt, so admitted text
  stays retired after a failed save or connection change. Newer typing and files
  survive. Controls retain receipts without becoming replayable inputs.
  A Send to several coordinators keeps its receipt in each recipient's outbox.
  Recovery offers its text again only when none of them still holds it.
  A coordinator removed since the Send no longer counts, so recovery offers the
  text again when no coordinator still saved received it.
  A control that never leaves the phone releases its outbox's receipt, whether
  an address edit, a disconnect or a failed dial stopped it.
  Ownership paths are relative to the composer record, allowing storage to move.
  Local rejection restores the unadmitted copy, preserving newer typing.
  Restoring an outbox input saves the complete replacement draft and keeps the
  original queued until a Send carries the copy. Failed preparation removes
  partial attachment copies.
- Composer diagnostics use Apple's unified log subsystem `dev.jessfraz.Agent`,
  category `Composer`. They record the build, lifecycle, send/clear/admission
  state, character/attachment counts and failure domains/codes, without message
  text or file paths.
  A feedback recording's `beepBoop` object carries up to 15 minutes of
  current-process metadata as `composerLog`, at most 256 KiB with the newest
  lines kept. Collection includes the OS version, stops waiting after two
  seconds and reports empty or unavailable coverage.
- **Connection → Conversation settings** changes the main conversation's model,
  reasoning and Fast setting without submitting the draft. Configured and
  effective selections are shown separately; an unknown active selection stays
  unknown. Controls appear only when supported by the connected coordinator.
- With two or more coordinators, one feed shows them all, ordered by when this
  phone received each entry. Each coordinator's replies start with its name in
  its color. Typing `@` offers the saved names. A chosen name, or `@Name`
  followed by a space, becomes a chip in the composer, and the message goes to
  that coordinator only. Names are read only from text the keyboard has
  committed, so a word it is still composing, such as one awaiting conversion
  or dictation, offers no names and makes no chip until it is committed.
  Without a chip the message goes to every paired
  coordinator. A restored message's text is never read for tags, so removing
  its chip sends it to every coordinator as it is. A tag you type in it stays
  text, and the picker does not open. Send empties the composer, and text you
  enter while it sends is still restored text. Clearing the composer, its text
  and its files, ends it, so text you type or paste afterwards is new, and a
  leading `@Name` in it becomes the chip. Undo never reaches back past a
  Restore or past clearing a restored message. The original is still queued or
  held, so restore it again. The line under the field names the recipients, or
  says why Send is blocked, before you send. After a removal the composer keeps working
  this way with one coordinator left, until the app quits.
  A message to several coordinators is saved
  in each one's outbox under its own input ID before any of them is sent. If
  one refuses it, none keeps it and the draft stays, except a copy that
  **Check / retry** already sent. That copy stays queued, since its
  coordinator may have it. The message's bubble reads "To Work
  and Personal" once every recipient has it. Otherwise it shows each
  coordinator's delivery with its own **Check / retry**, or **Restore** and
  **Discard**. A
  coordinator with no record of it on this phone reads "Status unknown". The
  bubble reads "Not sent to Personal" only after you discard Personal's copy, or
  restore it and send it unchanged, which withdraws the original from Personal's
  queue. If Personal later reports that it kept the original after all, the bubble reads
  "Personal · Sent", then "Personal · Delivered" once it is placed.
  Commands are never queued, so one a coordinator did not get because its
  connection dropped, or because you removed it meanwhile, is named under the
  feed ("Work did not get /status. It was removed."). If no coordinator got it,
  the draft stays. That note stays until your next Send, beside any other
  error, with one coordinator left too.
- Adding, editing, pairing and removing coordinators run one at a time. Remove
  refuses while the draft is addressed to that coordinator or restored from it.
  It saves `profiles.json` without the coordinator, and with a record of its
  alert withdrawal, before it withdraws alerts or deletes anything, so a failed
  save leaves the coordinator as it was. A withdrawal its coordinator has not
  confirmed is sent again each time the app becomes active, at the removed
  coordinator's address or at a saved address that now answers as it. Another
  coordinator's answer confirms nothing. The phone stops trying once every one
  of those addresses answers as another coordinator, as after a reinstall,
  since it then knows no way to reach the removed one. Each launch deletes
  the files of every coordinator `profiles.json` no longer lists. Until the app
  quits, a chip for a removed coordinator, a message restored from one, or a
  leading `@Name` that names no saved coordinator blocks Send, with one
  coordinator left too, so nothing meant for it goes to another coordinator.
- Every connection first asks for the coordinator's ID and writes nothing else
  unless the ID matches the saved one. A coordinator too old to answer, or one
  that answers and then closes without replying to the app's first request,
  shows "Update the coordinator". If the address now answers as a different
  coordinator, the queue stays on the phone. Both cases keep retrying. When
  that coordinator is another saved one, as when two coordinators trade
  addresses, the line names it and asks you to edit the address, which keeps
  the queue. An address edit that reaches a different coordinator saves
  nothing, and the form names the coordinator saved at that address, if there
  is one. With two or more coordinators, each one's error shows on its own
  line above the feed. With one, its error shows under the feed, beside any
  error of the composer's own, and only while it lasts.
- Coordinator acknowledgements are saved with each outbox input. Accepted
  messages stay saved through suspension, reconnect and app restart; they are
  observed by their original IDs until placement and cannot be resubmitted or
  restored.
  **Sending** becomes **Sent** after coordinator acknowledgement, not after a
  local outbox write. **Sent** does not mean the work is finished. Confirmed
  history keeps that receipt; reconnecting cannot turn it into a retry badge.
  Pending inputs can separately show queued, working, completed or paused work
  reported by the coordinator, under each recipient's line for a message to
  several coordinators. Placement retires that badge, without implying
  execution completed; the coordinator reports a paused main conversation.
  Older outboxes without acknowledgement state remain unconfirmed and are
  reconciled without automatic replay.
- Transient network loss reconnects automatically. Suspension releases owned
  connections. Returning reconnects and reconciles
  the original input IDs. Uncertain writes are never automatically replayed.
  **Check / retry** retains the same ID;
  terminal rejection retains the original. **Restore to composer** copies it,
  addressed to its own coordinator. Text you type or files you attach while it
  copies the files stay, after the restored message. If you pick another
  coordinator meanwhile, Restore leaves your draft alone. The app removes the
  original only when you send the restored message unchanged to its coordinator,
  with the same text and every restored file, and only while its coordinator
  still refuses it.
  Once you clear the composer, the original stays even if you type or paste
  the same text again and send it. If
  you send something else instead, the original stays and still needs
  attention, and **Discard** removes it. The refusal is saved with the queued
  message until it is sent again, so after a reconnect, an address edit or a
  relaunch the message still needs attention, with **Restore** and **Discard**
  rather than **Check / retry**, until its coordinator reports it accepted or
  placed. If the phone
  cannot save it, the app still follows the coordinator's latest word until it
  quits. A **Check / retry** of the original that has not left the phone when
  you send the copy is cancelled. Each connection asks the coordinator about
  every queued message and the newest withdrawn originals, 32 in all.
- Failed or partial source checks show one current coverage warning above the
  conversation, one per coordinator led by its name when several are saved. Tap
  it for per-account status, full safe errors and local check
  times, including healthy sources. The same view is in Connection → Sources.
  The view separates the last completed scan from the last check and shows
  available scan progress and its window. **Refreshing** means an earlier scan
  completed; **Catching up** means completion has not yet been recorded.
  Live recovery clears old errors; repeated polls add no history or alerts.
- Connection → **Jobs and work** lists applied schedules and saved work. Open a
  job for last/next execution, errors, its exact reply and the owning chat.
  **Retry interrupted run** resumes an execution parked at the restart limit,
  preserving its identity. Conversation inspection includes sub-agents and live
  updates, uses the shared history renderer and never sends or stops work.
  With two or more coordinators, each coordinator's page under Connection holds
  its own **Jobs and work** and **Conversation settings**.
- The top of the chat holds messages that a build without saved coordinators
  queued for the coordinator at its address. Each launch of that build keeps its
  own queue and the address it was queued for, every queue it left is held, and
  the update saves a coordinator at its last address under a name no saved
  coordinator has. A name an earlier build of this app saved twice, ignoring
  case, keeps its first coordinator, and the later one gets the first free name,
  such as `Coordinator-2`. The build without saved coordinators never recorded
  which coordinator answered at an address, so they may already have been
  delivered. The app never sends them. A queue belongs to the first saved
  coordinator the phone proves answers at its address: by pairing, adding or
  editing a coordinator there, by any probe of that address that finds a saved
  coordinator, or by a coordinator already saved there, the only one, when the
  app starts. Each queue's folder records its
  address, its coordinator and that build's alert registration. The folders are
  in `Agent/HeldQueues`, where no earlier build of this app reads, writes or
  deletes anything, so installing earlier builds over this one in any order, and
  then this one again, loses none of them. Those builds do not show them. The
  build before this one kept its own held queues in `Agent/Held` and deletes each
  folder there that `profiles.json` does not list. The update moves each of them
  into `Agent/HeldQueues` with what that build listed about it, and until it has
  moved, `profiles.json` lists it in that build's format, so a launch that stops
  part way leaves that build nothing to delete. What an earlier build recorded
  about a queue counts only where it proves the queue's address or coordinator,
  and what the build before this one listed describes only the folder it kept.
  The update writes each folder's queue into the folder before moving it, so a
  launch that stops part way resumes with that queue. Until the folder moves,
  what `profiles.json` says about it in an earlier build's format wins over what
  the update wrote, so a coordinator that build proved for the queue after the
  stop keeps it.
  **Restore to composer** makes a new message for you to send, addressed to that
  coordinator. Until one is, Restore asks which paired coordinator gets it. If no
  build recorded the address, Restore always asks. **Discard** deletes a held
  message. A held message leaves the hold only when you send its restored copy
  unchanged to the coordinator it belongs to, or discard it. A held message the
  earlier build saw its coordinator accept offers only **Discard**, since a
  restored copy would send it twice. Removing a
  coordinator deletes the held messages its confirmation counted as that
  coordinator's, and no others: a queue that becomes that coordinator's after
  the confirmation stays. A Remove that stops part way may leave held messages
  that show again, and Discard deletes them. Nothing else deletes a held
  message. If held messages cannot be read, the chat says so for as long as they
  are on this phone and their last read failed.
- Do not restore an uncertain submission as a new message to bypass checking its
  original ID. Coordinator admission may already have succeeded.
- Use the **+** menu for files, photos, commands and delivery mode, or drop files
  onto the chat. Up to
  eight files of 16 MiB each use the shared chunked attachment protocol. Photos
  are resized and encoded as JPEG. History includes file metadata; bytes are
  downloaded and verified only when opening a preview. Pi's existing adapter
  handles model image input; other files remain available to agent tools on the
  execution host. No provider requests originate on iOS.
- **Paste images** imports clipboard images as removable **Unsent attachments**.
  Import preserves the note and existing files, and sending remains explicit.
  A failed or cancelled import removes only its newly staged files.
- The shared protocol retains typed CLI/iOS input origins and scheduled-notice
  lineage. Missing legacy origin stays unknown. Live and restored rows use the
  same durable identities and causal ordering.
- In another app's Share sheet, choose **Beep Boop**, review the note and files,
  then **Save draft**. Selected text, links, images and regular files enter the
  shared-draft inbox. Opening Beep Boop merges them into the existing unsent
  composer once, preserving its note and attachments. Sharing never sends or
  starts agent work. Cancel before saving leaves the composer untouched.
  An uncertain save retries the same frozen selection and transfer ID.
- `/feedback` starts a Scrawl recording, as
  [Send feedback with Scrawl](#send-feedback-with-scrawl) describes. A draft
  saved by an earlier build with its automatic `Feedback.png` screenshot loads
  with that screenshot as an ordinary attached file.

### Siri and Shortcuts

**Open Coordinator** shows a saved coordinator's feed, as tapping one of its
alerts does. Its Coordinator picker lists each saved coordinator by name, in
saved order, and never shows an address. The composer draft is left as it was.
Say "Open Work in Beep Boop", or add the action in the Shortcuts app. Renaming
or removing a coordinator updates the picker and the phrases. Intents, entities
and queries live in `ios/Sources/AgentUI/Siri/`. The shortcuts provider lives
in the app target, because a provider inside the package ships no phrase.

**Retry Interrupted Run** retries a scheduled job whose last run paused after
repeated interrupted restarts, the same rule the job screen's Recovery button
uses. It asks to unlock the phone first. Its Job picker lists the jobs of every
paired coordinator that answers, by title and coordinator, and leaves out the
prompt, the working directory and the run output. The app holds each
coordinator connected only while an intent reads or retries, so it works with
the app in the background. It has no phrase. Add it in the Shortcuts app.

## Validation

```sh
make bindings
swift test --package-path ios
swift test --package-path ios --configuration release \
  --filter pagedHistoryAndStreamingPreparationRemainBoundedAndKeepCanonicalIdentity
xcodebuild -project ios/Agent.xcodeproj -scheme Agent \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath target/ios-app CODE_SIGNING_ALLOWED=NO build
python3 ios/scripts/check-intents-metadata.py target/ios-app/Build/Products/Debug-iphonesimulator/Agent.app
```

Run these from the repository root, with full Xcode selected for Apple checks.
Rust owns the native wire types. The existing bindings exporter generates
`Generated.swift` and schema-covering fixtures, decoded and reserialized by
Rust's actual serde implementation. Swift tests consume those fixtures and
exercise loopback framing, outbox persistence, composer admission and owned
connection cleanup. From the repository root, `make check` also starts the
production coordinator and Pi database. On macOS the same Swift client stays
alive across server restarts, preserving its draft and reconciling its outbox
without duplicate input. Scripted peers remain in separate fault-injection
tests.
On macOS, a process-overlap regression exercises real draft saves and cold
readback while native processes launch. File locks end with their transaction,
including when a child temporarily inherits a descriptor before exec.

Native UI checks use the screen's production startup and scene lifecycle. A
DEBUG-only transport redirects each saved coordinator to an owned loopback peer;
per-test storage identities retain the composer and each coordinator's outbox
across relaunch. Foreground recovery and process relaunch are asserted separately
from suspension, which XCTest can prevent and therefore report as skipped.
Native interaction checks also rotate a static transcript at the live tail and
while reading older messages. Incoming output preserves that older reading
position; following resumes when scrolling back to the live tail.
Expanded tool output must appear once, retaining
richer previews when lazy details are truncated and keeping the truncation
notice visible.

Rendering tests capture the production message rows
in light, dark and large-text appearance using invented content. Markdown
regressions assert code-fence boundaries, escaped pipes, table cells, inline
styles, link destinations, list numbering/nesting and line breaks. The gallery
includes all heading levels, lists/tasks, wide tables, Unicode and unfinished
code fences. PNGs support manual and Claude review; automatic assertions cover
content, successful native rendering and Dynamic Type height growth. Full-chat
captures cover grouped activity, opened reasoning and command details alongside
the real header and composer. Screenshots are review artifacts, not golden-image
comparisons.
CI retains the native failure summary and each failing test's PNG and text
attachments in a separate artifact. Complete bundles retain the recordings and
remaining evidence.
Nested block-container layout, remote image previews, math and diagrams remain
outside this renderer. To retain the review images,
pass `--attachments-path /absolute/existing/directory` to `swift test`.
`bash ios/scripts/check.sh` runs strict Swift lint, macOS tests, the unsigned
app build, package tests on iOS and app-hosted rendering tests. It requires an
installed compatible iOS runtime and cleans up only its own simulator.
Simulator UI checks use ad-hoc signing for real App Group entitlements; no
Apple account or provisioning profile is needed.
CI runs `host`, `simulator-core`, `simulator-performance` and `simulator-ui` in
parallel; every phase must pass. The default local command runs all checks;
`simulator` keeps the three simulator suites together for local use. Each
simulator phase creates and removes its own device.
Failed simulator runs also retain PNG/text attachments and their native manifest
in a separate `ios-failures-*` CI artifact, alongside the complete result bundle.
To run only the live notification-tap test, run
`python3 ios/scripts/test-notification-tap.py SIMULATOR_UDID ARTIFACT_DIRECTORY`.
Set `IOS_SIMULATOR_RUNTIME` to an exact identifier from
`xcrun simctl list runtimes` to qualify a particular installed runtime.
The `Agent` scheme's hosted tests also check that accessibility text sizes
expand the message layout. History preparation benchmarks exercise the real
`Transcript` and rich-text parser with invented content. The timing tests run
alone in Release configuration on macOS and iOS; Debug tests retain the same
ordering, memory and identity checks without timing unoptimized code alongside
unrelated tests. After one warmup, five
iterations produce median CI gates: 20 ms for the first 20-entry page, 250 ms for
26 older pages reaching the 500-row window, and 500 ms for 102 streamed chunks
(about 5 KiB). Test attachments retain every sample and budget. These limits
leave headroom for CI variation and catch substantial regressions; they exclude
network latency, decoding, SwiftUI drawing and device frame pacing. Ordering,
memory bounds and durable identity are also asserted.
Runtime tests exercise the actual Pi/bridge with
synthetic external model responses and host effects, never real accounts.

Native UI checks exercise copy/partial-selection, clipboard-image drafts and
actual appearance. Release acceptance also requires protected CI, a matching
coordinator and signed build/source readback. Current acceptance is tracked in
the [roadmap](../docs/roadmap.md#finish-the-current-pass).
