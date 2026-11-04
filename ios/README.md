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
   scheme uses this directory's local Swift package without dependencies. For a
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
  otherwise it disappears at the bottom.
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
- Messages and feedback, including immutable attachment copies, are saved to the
  saved coordinator's own outbox before transmission. On iOS it
  uses complete file protection and is excluded from backup. History stays in
  memory; there is no separate phone conversation database. For its newest 2000
  entries, each coordinator's `Ledger.json` keeps the entry ID, the time this
  phone received it and the send ID. For its newest 2000 Sends, it keeps the
  recipients and the time each was queued. It never holds message text. It has
  the same protection, and it keeps the order you saw across a relaunch.
- The unsent composer saves its note, delivery mode and attachment references
  together. Reopening restores that draft; importing or restoring never sends it.
- **Connection → Conversation settings** changes the main conversation's model,
  reasoning and Fast setting without submitting the draft. Configured and
  effective selections are shown separately; an unknown active selection stays
  unknown. Controls appear only when supported by the connected coordinator.
- With two or more coordinators, one feed shows them all, ordered by when this
  phone received each entry. Each coordinator's replies start with its name in
  its color. Typing `@` offers the saved names. A chosen name, or `@Name`
  followed by a space, becomes a chip in the composer, and the message goes to
  that coordinator only. Without a chip the message goes to every paired
  coordinator. A restored message's text is never read for tags, so removing
  its chip sends it to every coordinator as it is. A tag you type in it stays
  text, and the picker does not open. If you edit it while it sends, the text
  left in the composer is still restored text. Clearing the composer, its text
  and its files, ends it, so text you type or paste afterwards is new, and a
  leading `@Name` in it becomes the chip. Undo never reaches back past a
  Restore or past clearing a restored message. The original is still queued or
  held, so restore it again. The line under the field names the recipients, or
  says why Send is blocked, before you send. After a removal the composer keeps working
  this way with one coordinator left, until the app quits.
  A message to several coordinators is saved
  in each one's outbox under its own input ID before any of them is sent. If
  one refuses it, none keeps it and the draft stays. Its bubble reads "To Work
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
  confirmed is sent again each time the app becomes active. Each launch deletes
  the files of every coordinator `profiles.json` no longer lists. Until the app
  quits, a chip for a removed coordinator, a message restored from one, or a
  leading `@Name` that names no saved coordinator blocks Send, with one
  coordinator left too, so nothing meant for it goes to another coordinator.
- Every connection first asks for the coordinator's ID and writes nothing else
  unless the ID matches the saved one. A coordinator too old to answer shows
  "Update the coordinator". If the address now answers as a different
  coordinator, the queue stays on the phone. Both cases keep retrying.
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
- The top of the chat holds messages that a build without saved coordinators
  queued. That build never recorded their coordinator, so they may already have
  been delivered. The app never sends them. **Restore to composer** makes a new
  message for you to send, and **Discard** deletes one. A held message leaves
  the hold only when you send its restored copy unchanged to its coordinator,
  or discard it. A held message the earlier build saw its coordinator accept
  offers only **Discard**, since a restored copy would send it twice.
- Do not restore an uncertain submission as a new message to bypass checking its
  original ID. Coordinator admission may already have succeeded.
- Use the **+** menu for files, photos, commands and delivery mode, or drop files
  onto the chat. Up to
  eight files of 16 MiB each use the shared chunked attachment protocol. Photos
  are resized and encoded as JPEG. History includes file metadata; bytes are
  downloaded and verified only when opening a preview.
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
- `/feedback` captures the current app window before sending and includes it
  with the report. Failed admission keeps that exact screenshot for retry.
  With more than one coordinator saved nothing is captured, because the feed
  shows every coordinator's conversation. A kept screenshot, or any restored
  `Feedback.png` whatever its text says, belongs to the coordinator it came from
  and is sent to that coordinator alone; otherwise it must be removed before
  sending.
  Pi's existing adapter handles model image input; other files remain available
  to agent tools on the execution host. No provider requests originate on iOS.

## Validation

```sh
make bindings
swift test --package-path ios
swift test --package-path ios --configuration release \
  --filter pagedHistoryAndStreamingPreparationRemainBoundedAndKeepCanonicalIdentity
xcodebuild -project ios/Agent.xcodeproj -scheme Agent \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath target/ios-app CODE_SIGNING_ALLOWED=NO build
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
