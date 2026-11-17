# GitHub source ownership

GitHub sources optionally partition notifications using the API's
`repository.full_name`. The owner comparison is exact and ASCII
case-insensitive. Repository names and notification titles do not affect the
partition, so new repositories inherit their organization's route.

```toml
[[sources]]
provider = "github"
enabled = true
namespaces = ["github.fixture"]
[sources.owner_filter]
mode = "include"
owners = ["Example-Collective"]
```

The other coordinator uses the same owner list and `mode = "exclude"`.
Omitting `owner_filter` retains unfiltered behavior. Both coordinators must have
read access to the intended account feed: routing cannot manufacture access to
notifications missing from that feed. This is notification intake, not an
organization repository archive or webhook subscription.

For managed installations, preferences can change just the owner partition:

```toml
[github_owner_filter]
mode = "exclude"
owners = ["Example-Collective"]
```

`config apply` preserves existing GitHub namespace selection and enablement,
and leaves non-GitHub sources unchanged. It fails atomically if no GitHub source
exists or the filter is invalid. It does not enable a disabled source. Configure
and verify account access separately; do not substitute whole `sources` arrays
merely to manage routing.

## Checkpoints and retained work

Filtered-out notifications never enter the source journal. A successful scan
containing only excluded notifications still advances the checkpoint and honors
the provider's poll interval. Invalid/missing repository ownership is not assigned
to either partition: coverage remains partial and the checkpoint is retained.

Checkpoints remain bound to their account. A changed owner policy (including a
legacy unfiltered checkpoint) replays the normal seven-day initial intake horizon,
ignoring the old policy's throttle. Equivalent case/order/duplicate owner changes
do not reset it. Existing journal event identities deduplicate replayed versions.
Older notifications outside that horizon are not backfilled.

Applying a policy does **not** revoke or migrate previously admitted events,
pending triage, historical notices, tasks, or running work. Review any old
misrouted backlog separately before activation; never silently cancel it as part
of source filtering.

## Offline acceptance

This exercises production Rust discovery and notification collection against an
invented provider boundary, then durable SQLite admission, fresh-session reread,
and real triage dispatch. The model response is a local fixture; no model request,
publication to a live coordinator, or inbox mutation occurs.

```sh
nix develop --command cargo build --example source_poll_fixture
nix develop --command npm --prefix runtime ci --ignore-scripts
nix develop --command npm --prefix runtime run build
nix develop --command env \
  AGENT_SOURCE_POLL_FIXTURE="$PWD/target/debug/examples/source_poll_fixture" \
  node --test --test-name-pattern='GitHub owner partitions' \
  runtime/dist/test/sources.test.js
nix develop --command cargo test --lib sources::github
nix develop --command cargo test --lib managed_github_partition
```

The adapter test is explicitly skipped without the built fixture environment
variable. Do not count that skip as acceptance.

## Activation gate

Ship the compatible agent parser/adapter before applying the new managed field.
A deployment package pinned to an older agent cannot activate this policy merely
by changing preferences. Build and review the matching package/input update,
verify each actual coordinator's identity and private account configuration,
and apply complementary policies there. Do not guess coordinator identity from
a stale hostname, UI label, or an untrusted peer, and do not weaken trust to gain
access. Confirm resulting config from a fresh read and exercise read-only intake
before claiming live ownership. Running services require an owner-controlled idle
restart; a repair task must not restart its own coordinator.
