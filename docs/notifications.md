# iPhone notifications

The coordinator sends an alert for a new completed main-chat reply, an
explicitly published user notice, or a standing side chat reply allowed by that
side chat's notification setting. Each side chat defaults to `inherit` (following
the device's **Main-chat updates** toggle) and can be overridden per topic to
`on` or `off`. Tools, progress, receipts, compaction, imported conversations and
history replay do not trigger alerts. Legacy notices stay readable without
becoming push notifications.

Alerts preview the actual reply or published notice, with basic Markdown
formatting removed and long text truncated. Reasoning, tool output and internal
notice references stay out of the preview. Main alerts use the title `Beep Boop`
and open the main chat; side chat alerts use `Beep Boop · <title>` and open
directly to that side chat. An open main chat or open matching side chat
suppresses foreground banners for that conversation; the app has no persistent
background socket. When **Main-chat updates** is turned off while at least one
side chat is explicitly set to `on`, the device remains registered with
`main_enabled: false` so only those opted-in side chats send push alerts.

## One-time setup

1. Enable **Push Notifications** for the app's explicit App ID in the Apple
   developer account. Build with that team's provisioning profile. The app
   already declares the push entitlement; unsigned simulator builds do not
   provision an account or prove real delivery.
2. Create an APNs signing key for the app and environment. Keep the `.p8` key in
   the credential manager, with an owner-only runtime copy on the coordinator
   outside the Nix store. Record its Key ID and the developer Team ID.
3. Add this to the coordinator's private, local `config.toml`. Use the installed
   app's actual bundle identifier as `topic`.

   ```toml
   [apns]
   team_id = "TEAM000001"
   key_id = "KEY0000001"
   topic = "dev.example.Agent"
   key_file = "~/.config/agent/apns/AuthKey.p8"
   environment = "production"
   ```

   The key must be a regular file owned by the service user with owner-only
   permissions, such as `0600`.
   APNs settings are excluded from managed settings and machine announcements.
   Keep both configuration and key outside repositories and the Nix store.
   Restart the coordinator after configuring it.
4. Install and open the signed app on the iPhone. Main-chat updates are enabled
   by default; allow Apple's notification prompt. Connect to the coordinator
   over Tailscale to register the device automatically.

Debug signing uses Apple's development entitlement and requires
`environment = "sandbox"`. TestFlight and Release signing use production.
The coordinator needs outbound HTTPS access to APNs; no public inbound service
is required. Notification delivery uses Apple, while opening the conversation
still uses the trusted Tailscale connection.

## Delivery and recovery

Device tokens are registered again through the trusted connection and are not
saved on the phone. The coordinator retains registrations and delivery state in
private Pi storage. Disabling alerts removes that installation; token changes
supersede its queued deliveries. Enrollment starts at the current conversation
boundary, without alerting for old history.

Turn alerts off in **Connection → Notifications**. That choice and a denied
permission remain off across launches, without repeated permission prompts.
To enable alerts after denying permission, allow Beep Boop notifications in iPhone
Settings and turn **Main-chat updates** back on in Beep Boop.

Each installation/message pair has one durable delivery identity. APNs
acceptance is not proof that the phone displayed an alert. A lost provider
receipt remains uncertain and is not blindly resent, including after restart.
Known temporary rejections retry through Pi's durable scheduler with backoff.
Delivery expires after 24 hours; APNs can retain an accepted alert while the
phone is briefly offline. Internal/control annotations suppress queued alerts;
they cannot retract an alert Apple already accepted.
Apple and the operating system do not provide an exactly-once display guarantee.

See Apple's [registration guide](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
and [provider authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
for the account and signing steps.

## Verify on a phone

APNs acceptance does not show that the phone displayed an alert. The
[phone acceptance runner](../ios/README.md#phone-acceptance) drives the
installed app, puts it in the background or terminates it, and records each
alert that the phone shows. To match those alerts with the coordinator's
delivery records, run `runtime/scripts/notification-deliveries.mjs` on the
coordinator host. It opens the session database read-only and prints the
delivery state, HTTP status and attempts for each entry whose text contains a
given string. It never prints a device token or the entry text. Read-only
mode does not change the database file, but SQLite can still create its
`-wal` and `-shm` files next to it when they are missing.

```sh
node --input-type=module - --database <state directory>/session.sqlite \
  --text <codeword> < runtime/scripts/notification-deliveries.mjs
```

Add `--tasks-since-entry <entry ID>` to list candidate tasks for a notice. The
list is wider than the job that sent the notice. It holds tasks in any
conversation that existed when the notice was committed and were still running
or ended after its delivery was queued. It also holds every task the notice's
source conversation started later. To show that the notice arrived mid-job,
take a task with `notice_source: true` that belongs to the work that called
`notify_user`. Its `started_at` must come before the time the phone showed the
notice and its `ended_at` after it. An unrelated task, or a later end time
alone, does not show this. The comparison assumes that the phone's clock and
the coordinator's clock agree.
