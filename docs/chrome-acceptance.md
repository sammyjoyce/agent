# Chrome lifecycle acceptance

`runtime/test/acceptance/chrome-lifecycle.ts` checks that browser work survives
the ways Chrome and the service stop on a real Mac. It drives the packaged
`beep-boop` and its browser tools against a Chrome profile that the test owns,
with Chrome's saved-password autofill on. It never opens the user's Chrome,
profile, Keychain or 1Password.

## What each leg proves

A leg runs two invented cases through delegated tasks on the browser host.

1. Case A opens the invented login page, waits for Chrome to autofill the saved
   password, signs in, fills a note and submits it. The site records the
   submission and holds its response.
2. The driver injects the leg's fault while A waits for that response.
3. After the host recovers, the driver sends A's task one message. That turn
   reuses A's old tab handle, then calls `browser_status` and `browser_release`.
4. Case B starts in a new task, repeats the sign-in and submission, and
   releases its tab.
5. The driver lists Chrome's tabs over a loopback DevTools port and counts
   extension approval tabs.

A leg passes only when all of these hold:

- The site saw exactly one submission from each case, and no request from A
  after the fault.
- A's old tab handle did not run. A's reconcile turn finished with answers
  from `browser_status` and `browser_release`, after one `tasks send`.
- B signed in with the autofilled saved password, submitted once and released
  its tab.
- In `relaunch`, Chrome ended with an ordinary Quit. On the guest, AppKit
  logged that Chrome approved the Quit and no crash report appeared. Locally,
  Chrome for Testing exited with code 0. Chrome's own `exit_type` is not
  used, because it stays `Crashed` after a clean Quit until someone answers
  Chrome's restore prompt from an earlier crash.
- No extension approval tab is open. The driver never clicks one.
- Every tab that a case opened is closed. Otherwise, the case's status or
  release reply said that tab cleanup was not verified.
- No model request or tool output contained the site password or the
  extension token.

| Leg | Fault | Expected change |
| --- | --- | --- |
| `relaunch` | Chrome quits normally (`NSRunningApplication.terminate` on its pid) and opens again | Chrome pid |
| `kill_helper` | `SIGKILL` of the `browser-host.js` helper serving case A | none |
| `kill_service` | `SIGKILL` of the process that hosts the browser tools, which its service manager or the driver restarts | service pid |
| `os_reboot` | `sudo shutdown -r now` in the guest, then automatic login | boot time, Chrome pid and service pid |

## Targets

`guest` is a disposable macOS virtual machine made with Tart. It has installed
Google Chrome with the Playwright extension, a saved login, the user's own Rex
with session restore on, and the worker LaunchAgent that `nix/module.nix`
declares. The coordinator, the scripted model and the invented site run outside
the guest. An SSH tunnel carries the worker connection. This target runs all
four legs.

`local` runs Chrome for Testing on a fresh data root with
`--use-mock-keychain --password-store=basic`, driven over native DevTools by a
private coordinator on the machine that runs the driver. It runs `relaunch`,
`kill_helper` and `kill_service`. It does not reboot.

The lab replaces only the model. A scripted server answers the Azure Responses
API through the Azure provider's base URL. Every other part is the packaged
product: CLI, runtime, broker, worker, browser helper, extension and Chrome.
Each model request must match a known case and phase. Any other request fails
the leg.

## Differences from a deployment

- The guest's Chrome uses a data root other than Chrome's default, so a
  DevTools port can observe tabs. A login agent opens it. loginwindow's list of
  apps to reopen is locked empty, so macOS does not reopen Chrome without those
  arguments. A deployment on the default data root relies on macOS reopening
  Chrome instead.
- `local` uses Chrome for Testing and native DevTools, not installed Chrome and
  the extension.
- The coordinator is a private lab coordinator, not the deployment's.

## Run it

Provision the guest once:

```sh
CHROME_GUEST_LAB=~/.chrome-guest-lab BEEP_BOOP=/nix/store/...-beep-boop-0.1.0 \
	REX=/nix/store/...-rex-app-0.1.0 runtime/test/acceptance/provision-chrome-guest.sh
```

Provisioning creates the VM, installs Chrome and Nix, copies the packages and
loads the login agents. Install the Playwright extension once by hand in the
guest's Chrome. Open its Chrome Web Store page over the guest's Screen Sharing
and confirm Chrome's dialog. The lab first installed the extension with an
`ExtensionInstallForcelist` policy that it wrote by hand. That policy did not
survive a guest reboot, and Chrome then removed the extension. So the lab uses
a one-time Chrome Web Store install instead.

Build the runtime and install Chrome for Testing:

```sh
npm --prefix runtime run build
node runtime/node_modules/playwright-core/cli.js install --no-shell chromium
```

Save the invented login, and the guest's pairing token, for each target:

```sh
node runtime/dist/test/acceptance/chrome-lifecycle.js prepare --target guest
node runtime/dist/test/acceptance/chrome-lifecycle.js prepare --target local
```

Run the legs:

```sh
BEEP_BOOP=... REX=... node runtime/dist/test/acceptance/chrome-lifecycle.js run \
	--target guest --legs relaunch,kill_helper,kill_service,os_reboot --evidence /tmp/chrome-guest
BEEP_BOOP=... REX=... node runtime/dist/test/acceptance/chrome-lifecycle.js run \
	--target local --legs relaunch,kill_helper,kill_service --evidence /tmp/chrome-local
```

The command exits 0 only when every requested leg passes.

`guest-reboot-trials.sh N` reboots the guest N times and records whether the
worker LaunchAgent is running after each login.

## Evidence

`--evidence` receives:

- `ledger.jsonl`, one `LegRecord` per leg. Each record has the boot time,
  Chrome pid and data root, and service pid before and after the fault. It also
  has the Quit evidence for `relaunch`, the autofill facts, both cases' results, the open approval tabs, the
  state of each owned tab, the secret check, the verdict and each failed check.
- `summary.md`, a table of the ledger.
- `cases.jsonl`, `model.jsonl`, `site.jsonl`, `cli.jsonl`, `coordinator.log`
  and `host-diagnostics.txt`, with secrets redacted.

## What the legs found

The runs used Rex 0.1.0-1973, Google Chrome 157.0.8103.79 on macOS 26.6.2 for
`guest`, and Chrome for Testing for `local`. Pull request #63 lists the runs
that accepted this version.

- `guest-reboot-trials.sh` found the worker LaunchAgent stopped after 4 of 6
  reboots before the `nix/module.nix` change, and running after 8 of 8 reboots
  with it. In 5 of those 8 boots, launchd started the agent before the Nix
  store mounted.
- The earlier package failed `os_reboot`. Rex restored the interrupted task's
  pane with a login shell, the host treated that shell as the worker, and the
  task never ran again. A binding now records the Rex server instance, so the
  host gives such a pane a replacement terminal in the same session, as
  [the architecture](architecture.md) describes.
- The earlier package failed `kill_helper` and `kill_service`. Chrome kept the
  interrupted case's tab, and the host told the conversation only that its
  handles were stale.

A reboot of an existing deployment host has not run.
