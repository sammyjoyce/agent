# Rex Protocol & Surface Exploration (`api_revision` 19)

Protocol and surface exploration notes against Rex `0.1.0-preview.22` (control API revision `19`)
covering secondary surfaces, direct control/data framing, and block plugins.

## Secondary Surfaces

1. **Clickable Localhost Dev-Server URLs & `rex forward open`**
   - Completed TUI scrollback rows (`src/tui/scrollback_links.rs`) convert `http://localhost:...`
     and `http://127.0.0.1:...` URLs into `OSC 8` hyperlinks alongside `https://` URLs.
   - `rex forward open [URL | host:port | BLOCK]` forwards local ports, URLs, or attached terminal
     blocks.
   - `com.superlogical.terminal.ports` (with `com.superlogical.terminal.blob_read` pagination)
     inspects listening dev-server ports in worker panes without waking idle terminals.

2. **Floating / Minimized Layers (`session.new_layer`, `session.set_layer_state`)**
   - `session.new_layer` accepts fractional `[x, y, w, h]` bounds inside a window;
     `session.set_layer_state` transitions floating layers between `normal` and `minimized` while
     preserving pane processes, layout bounds, and stack position (tiled layers reject minimization
     with `bad_request`).
   - Task agents remain in named tabs while floating layers can serve as an optional host for
     secondary overlays once a consumer is wired.

3. **Opt-in Size-Capped Kitty Graphics Thumbnails**
   - Kitty APC graphics (`\x1b_Ga=T,f=100,t=d,q=2,...\x1b\\` in 4096-byte base64 chunks) should
     stay strictly size-capped (e.g., 256 KiB raw PNG) and gated on explicit opt-in plus known
     Kitty-graphics terminals (`ghostty`, `kitty`, `wezterm`, `rex`) when scrollback thumbnail
     rendering is implemented.

4. **Headless Servers (`rex server`)**
   - `rex server` exposes `run`, `start`, `status`, `logs`, `tailscale`, `stop`, `install`, and
     `uninstall` subcommands. Default local servers bind a peer-credential Unix socket; remote
     Tailscale access is opt-in.

## Protocol, Block SDK & Desktop Surfaces

1. **Direct `rex.control.v1` WebSocket Client (`GET /api/control`)**
   - `session.bootstrap` returns `server_status` (`api_revision`, `api_min_revision`, `instance_id`,
     `host_id`, `listeners`), `session.view`, and up-front data tickets in one roundtrip, reducing
     iOS attach latency once direct WebSocket transport replaces coordinator-side CLI shelling.
   - `session.own_block` provides explicit client claim ownership per block; future direct control
     adoption should gate methods on `api_revision`.

2. **Direct `GET /api/data` Framing & `rex.data.bytes.v1`**
   - `data.connect` mints single-use channel tickets scoped optionally by `subprotocol`
     (`rex.data.terminal.v1` or `rex.data.bytes.v1`), returning `REJECT 0x01` if already
     redeemed/expired or `0x07` on subprotocol mismatch, and closing unsupported streams with
     WebSocket close `1008`.
   - The handshake and the reject reasons are shared by every data stream. `download_begin`
     and `upload_begin` return their own tickets.

3. **Live iOS Terminal Streaming (`rex.data.terminal.v1`) vs. Snapshot Reads**
   - `com.superlogical.terminal.format` (`max_bytes` + `com.superlogical.terminal.blob_read`)
     delivers bounded UTF-8 HTML or plain text snapshots over standard control RPCs without
     embedding a full Ghostty terminal renderer in iOS upfront. Direct `rex.data.terminal.v1`
     streaming remains best deferred until live interactive remote pane views are needed in iOS.

4. **Out-of-Process Rex Block SDK (`--block-dir` / `--block-plugin-reload`)**
   - Built-in creators are `com.superlogical.onboarding`, `com.superlogical.terminal`, and
     `com.superlogical.tunnel`. External `rex-block-*` plugin creators remain cleanly decoupled
     from core coordinator/worker execution while official Rex clients track the public Block SDK.

5. **Built-in Non-Terminal Blocks (`com.superlogical.tunnel`, `com.superlogical.onboarding`)**
   - `com.superlogical.tunnel.info` exposes `flavor: dial | listen`, `connections`,
     `target`/`address`, and `last_owner`.
   - `com.superlogical.onboarding.{state,set_step}` exposes `generation`, `step`, and
     `step_changed` as the reference pattern for stateful non-terminal blocks.

6. **Extended `com.superlogical.terminal` Methods**
   - Server terminal methods include `blob_read`, `clear`, `clipboard_read`, `download_begin`,
     `format`, `input_mode`, `list_dir`, `modes`, `ports`, `process`, `program_status`, `pwd`,
     `reset`, `resize`, `set_theme`, `size`, `title`, `upload_begin`, and `write`. Add typed
     wrappers in `src/rex/` alongside each consumer.

7. **Focus History (`focus_history.reverse`), CLI `block new`/`stream`, and macOS `Rex.app`**
   - `focus_history.reverse` (API rev 19) accepts `cursor`, `session_id`, `window_id`,
     `not_session_id`, `not_window_id`, and returns `{ reversed, cursor, session_id, window_id,
     block_id }`.
   - `rex block new` and `rex block stream` ship in the `rex` CLI.
   - `Rex.app` AppleScript (`Rex.sdef`) and macOS Shortcuts App Intents were not verified.
