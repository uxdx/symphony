# Symphony Ops Chain

Decision: disabled by default.

`symphony-ops` may be enabled only when all of these are true:

- the launchd manifest and live LaunchAgents entry both contain `com.sazo.symphony.symphony-ops`
- the workflow requires the Linear label `agt1-ready-for-ops`
- work is in the PR/plan phase unless a separate operator runs an explicit apply step

The chain must not reload launchd jobs, replace live symlinks, mutate secrets, or restart Symphony as part of normal autonomous PR work. Live mutation belongs to a separate apply phase and must pass:

```sh
mix workflow.check --file /path/to/symphony-ops/WORKFLOW.md
mix release.check --pin <expected-commit>
mix launchd.check --manifest-dir deploy/launchd --live-dir ~/Library/LaunchAgents
mix ops.check --decision enabled --phase apply --workflow /path/to/symphony-ops/WORKFLOW.md --apply-ack "I understand this mutates live Symphony ops"
```

Keeping the chain disabled is valid when the live launchd job and workspace are absent.
