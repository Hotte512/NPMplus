# hotte-ci

Nightly build of NPMplus with own features on top of upstream.

- `claude/hotte-features`: upstream `develop` at commit `FEATURES_BASE` plus own feature commits
- `.github/workflows/hotte-sync.yml` (`BASE=pinned` in `hotte-sync.env`): every night (01:17 UTC) builds
  `claude/hotte-features` exactly as it is and pushes `ghcr.io/hotte512/npmplus:hotte-main`. Unchanged sources are
  not rebuilt, except on Sundays to pick up updated base packages. Upstream `develop` is rewritten often, so it is
  rebased into `claude/hotte-features` on purpose (then update `FEATURES_BASE`), not automatically.
- `BASE=release`: replays the feature commits onto the latest upstream release instead (for when releases are cut
  from the new `develop`). If they do not apply an issue is opened and the last image stays.
- This branch must be the default branch of the fork, scheduled workflows only run there.

## LXC

`/opt/compose.yaml`:

```yaml
image: ghcr.io/hotte512/npmplus:hotte-main
pull_policy: always
```

Nightly update (`/etc/crontabs/root`, Alpine):

```
30 4 * * * docker compose -f /opt/compose.yaml pull -q npmplus && docker compose -f /opt/compose.yaml up -d && docker image prune -f > /dev/null
```
