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
for argument do
  if [ -n "$method" ]; then payload=$argument; break; fi
  case "$previous:$argument" in
    call:*) method=$argument ;;
    *:whoami | *:hosts) method=$argument; break ;;
  esac
  previous=$argument
done
if [ "${AGENT_TEST_FAKE_REX_FAIL_AT-}" = "$method" ]; then
  printf 'Error: stream response "control-1" failed: connection reset\n' >&2
  exit 4
fi
if [ "${AGENT_TEST_FAKE_REX_DOWN_AT-}" = "$method" ]; then
  : > "$root/dead"
fi
if [ -e "$root/dead" ]; then
  printf 'Error: no Rex server is running at %s, and autostart is disabled\n' \
    "${AGENT_TEST_FAKE_REX_SOCKET:-/run/user/1000/rex/server.sock}" >&2
  exit 4
fi
host=44444444-4444-4444-8444-444444444444
origin_window=window:22222222-2222-4222-8222-222222222222
origin_block=block:33333333-3333-4333-8333-333333333333
created=session:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
created_window=window:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
created_block=block:cccccccc-cccc-4ccc-8ccc-cccccccccccc
added_window=window:dddddddd-dddd-4ddd-8ddd-dddddddddddd
added_block=block:eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
block() {
  printf '{"window_id":"%s","layers":[{"blocks":[{"block_id":"%s","host_id":"%s","flavor":"com.superlogical.terminal.shell"}]}]}' "$1" "$2" "$host"
}
case "$method" in
  whoami)
    printf '{"host_id":"%s","instance_id":"66666666-6666-4666-8666-666666666666","rex_version":"fixture","tailscale":{"dns_name":"fixture-node.example.ts.net","https":{"state":"available","url":"https://fixture-node.example.ts.net"}}}\n' "$host" ;;
  hosts)
    printf '{"hosts":[{"host_id":"%s","label":"fixture-peer","endpoints":["https://peer.example.invalid"]}]}\n' "$host" ;;
  session.create)
    printf '{"session_id":"%s","initial_windows":[{"window_id":"%s","block_ids":["%s"],"revision":1}]}\n' "$created" "$created_window" "$created_block" ;;
  session.new_window)
    printf '{"window_id":"%s","block_ids":["%s"],"revision":2}\n' "$added_window" "$added_block" ;;
  session.view)
    session=$(printf '%s' "$payload" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
    windows="$(block "$created_window" "$created_block"),$(block "$added_window" "$added_block")"
    if [ ! -e "$root/closed" ]; then windows="$(block "$origin_window" "$origin_block"),$windows"; fi
    printf '{"session_id":"%s","revision":2,"windows":[%s]}\n' "$session" "$windows" ;;
  session.list)
    printf '{"sessions":[{"session_id":"session:99999999-9999-4999-8999-999999999999","label":"Unrelated"}]}\n' ;;
  session.move) printf '{}\n' ;;
  com.superlogical.terminal.process)
    printf '{"child":null,"foreground":null,"last_exit":{"exit_code":0}}\n' ;;
  block.close) : > "$root/closed"; printf '{}\n' ;;
  *) printf 'Unexpected fixture method %s\n' "$method" >&2; exit 1 ;;
esac
