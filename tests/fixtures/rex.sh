#!/bin/sh
set -eu
root=${AGENT_TEST_FAKE_REX:?}
{
  printf '%s\t' "${REX_SERVER-<unset>}"
  printf '%s\037' "$@"
  printf '\n'
} >> "$root/calls"
method=
payload=
previous=
socket=/run/user/1000/rex/server.sock
server=${REX_SERVER:-unix://$socket}
for argument do
  if [ -n "$method" ]; then payload=$argument; break; fi
  case "$previous:$argument" in
    --server:unix://*) socket=${argument#unix://}; server=$argument ;;
    --server:ssh://*) server=$argument ;;
    call:*) method=$argument ;;
    *:whoami | *:hosts) method=$argument; break ;;
  esac
  previous=$argument
done
if [ "${AGENT_TEST_FAKE_REX_FAIL_AT-}" = "$method" ]; then
  printf 'Error: stream response "control-1" failed: connection reset\n' >&2
  exit 4
fi
if [ "${AGENT_TEST_FAKE_REX_FAIL_ONCE_AT-}" = "$method" ] && [ ! -e "$root/failed-once" ]; then
  : > "$root/failed-once"
  printf 'Error: stream response "control-1" failed: connection reset\n' >&2
  exit 4
fi
if [ "${AGENT_TEST_FAKE_REX_DOWN_AT-}" = "$method" ]; then
  : > "$root/dead"
fi
if [ -e "$root/dead" ]; then
  case $server in
    unix://*) printf 'Error: no Rex server is running at %s, and autostart is disabled\n' "$socket" >&2 ;;
    *) printf 'Error: REX_SERVER: connecting to Rex server: probing %s: connecting to API control: failed to WebSocket dial: connection refused\n' "$server" >&2 ;;
  esac
  exit 4
fi
host=44444444-4444-4444-8444-444444444444
if [ "$server" = "${AGENT_TEST_FAKE_REX_ORIGIN_SERVER-}" ]; then
  host=55555555-5555-4555-8555-555555555555
fi
origin_session=session:11111111-1111-4111-8111-111111111111
origin_window=window:22222222-2222-4222-8222-222222222222
origin_block=block:33333333-3333-4333-8333-333333333333
created=session:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
created_window=window:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
created_block=block:cccccccc-cccc-4ccc-8ccc-cccccccccccc
added_window=window:dddddddd-dddd-4ddd-8ddd-dddddddddddd
added_block=block:eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
placeholder_window=window:f0f0f0f0-f0f0-40f0-80f0-f0f0f0f0f0f0
placeholder_block=block:f1f1f1f1-f1f1-41f1-81f1-f1f1f1f1f1f1
closed_blocks=" ${AGENT_TEST_FAKE_REX_GONE-} "
shown() {
  case "$closed_blocks" in *" $1 "*) return 1 ;; esac
}
# A closed block takes its window with it.
block() {
  if shown "$2"; then
    printf '{"window_id":"%s","layers":[{"blocks":[{"block_id":"%s","host_id":"%s","flavor":"com.superlogical.terminal.shell"}]}]}' "$1" "$2" "$host"
  fi
}
listed() {
  if shown "$1"; then printf '{"block_id":"%s","label":"Chat","placement":"%s"}' "$1" "$2"; fi
}
joined() {
  out=
  for item do out="$out${out:+${item:+,}}$item"; done
  printf '%s' "$out"
}
instance=66666666-6666-4666-8666-666666666666
restored=
if [ -e "$root/restarted" ]; then instance=88888888-8888-4888-8888-888888888888; restored=1; fi
if [ "${AGENT_TEST_FAKE_REX_RESTART_AFTER-}" = "$method" ]; then
  : > "$root/restarted"
fi
case "$method" in
  whoami)
    if [ "${AGENT_TEST_FAKE_REX_NO_TAILSCALE-}" = "1" ]; then
      printf '{"host_id":"%s","instance_id":"%s","rex_version":"fixture"}\n' "$host" "$instance"
    else
      printf '{"host_id":"%s","instance_id":"%s","rex_version":"fixture","tailscale":{"dns_name":"fixture-node.example.ts.net","https":{"state":"available","url":"https://fixture-node.example.ts.net"}}}\n' "$host" "$instance"
    fi ;;
  hosts)
    if [ "${AGENT_TEST_FAKE_REX_SSH_PEER-}" = "1" ]; then
      printf '{"hosts":[{"host_id":"%s","label":"fixture-peer","endpoints":["unix:///run/user/1000/rex.sock","ssh://worker.example.invalid:2222"]}]}\n' "$host"
    else
      printf '{"hosts":[{"host_id":"%s","label":"fixture-peer","endpoints":["https://peer.example.invalid"]}]}\n' "$host"
    fi ;;
  session.create)
    printf '{"session_id":"%s","initial_windows":[{"window_id":"%s","block_ids":["%s"],"revision":1}]}\n' "$created" "$created_window" "$created_block" ;;
  session.new_window)
    case "$payload" in
      *'"label":"beep-boop:placeholder"'*) printf '{"window_id":"%s","block_ids":["%s"],"revision":3}\n' "$placeholder_window" "$placeholder_block" ;;
      *) printf '{"window_id":"%s","block_ids":["%s"],"revision":2}\n' "$added_window" "$added_block" ;;
    esac ;;
  session.view)
    session=$(printf '%s' "$payload" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
    if [ "$session" = "${AGENT_TEST_FAKE_REX_MISSING-}" ] ||
      { [ "$session" = "$origin_session" ] && [ "$server" != "${AGENT_TEST_FAKE_REX_ORIGIN_SERVER:-$server}" ]; }; then
      printf 'Error: stream response "control-1" failed: session %s not found (status=404 code=session_not_found)\n' "$session" >&2
      exit 3
    fi
    origin=
    if [ ! -e "$root/closed" ] && [ ! -e "$root/detached" ]; then origin=$(block "$origin_window" "$origin_block"); fi
    windows=$(joined "$origin" "$(block "$created_window" "$created_block")" "$(block "$added_window" "$added_block")")
    printf '{"session_id":"%s","revision":2,"windows":[%s]}\n' "$session" "$windows" ;;
  session.list_blocks)
    placement=placed
    if [ -e "$root/detached" ]; then placement=detached; fi
    origin=
    if [ ! -e "$root/closed" ]; then origin=$(listed "$origin_block" "$placement"); fi
    blocks=$(joined "$origin" "$(listed "$created_block" placed)" "$(listed "$added_block" placed)")
    printf '{"blocks":[%s]}\n' "$blocks" ;;
  session.detach_block)
    case "$payload" in *"$origin_block"*) : > "$root/detached" ;; esac
    printf '{"revision":3}\n' ;;
  session.move_block)
    case "${AGENT_TEST_FAKE_REX_MOVE_MISSING-}:$(ls "$root")" in
      anchor-once:*move-refused*) ;;
      pane:* | anchor:* | anchor-once:*)
        missing=$placeholder_block
        : > "$root/move-refused"
        if [ "$AGENT_TEST_FAKE_REX_MOVE_MISSING" = pane ]; then missing=$origin_block; : > "$root/closed"; fi
        printf 'Error: stream response "control-1" failed: block not found: %s (status=404 code=not_found)\n' "$missing" >&2
        exit 3 ;;
    esac
    case "$payload" in *"$origin_block"*) rm -f "$root/detached" ;; esac
    printf '{"revision":4}\n' ;;
  session.list)
    printf '{"sessions":[{"session_id":"session:99999999-9999-4999-8999-999999999999","label":"Unrelated"}]}\n' ;;
  session.move) printf '{}\n' ;;
  com.superlogical.terminal.process)
    block_id=$(printf '%s' "$payload" | sed -n 's/.*"block_id":"\([^"]*\)".*/\1/p')
    if ! shown "$block_id"; then
      printf 'Error: stream response "control-1" failed: block not found: %s (status=404 code=not_found)\n' "$block_id" >&2
      exit 3
    fi
    # Rex restores every pane with a fresh shell.
    case "$restored:$payload" in
      1:* | *"${AGENT_TEST_FAKE_REX_RUNNING:-<none>}"*) printf '{"child":{"pid":4242},"foreground":null,"last_exit":null}\n' ;;
      *) printf '{"child":null,"foreground":null,"last_exit":{"exit_code":0}}\n' ;;
    esac ;;
  com.superlogical.terminal.format)
    printf '{"content":"<pre>Current task view 🦀</pre>\\n","eof":true}\n' ;;
  block.close)
    case "$payload" in *"$origin_block"*) : > "$root/closed" ;; esac
    printf '{}\n' ;;
  *) printf 'Unexpected fixture method %s\n' "$method" >&2; exit 1 ;;
esac
