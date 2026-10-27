# hotte-ci

Nightly build of NPMplus with own features on top of upstream.

- `claude/hotte-features`: upstream commit `FEATURES_BASE` plus own feature commits
- `.github/workflows/hotte-sync.yml`: every night (01:17 UTC) replays the feature commits onto the latest
  release of ZoeyVid/NPMplus, falls back to upstream `develop` if they do not apply, and pushes
  `ghcr.io/hotte512/npmplus:hotte-main`. Unchanged sources are not rebuilt. If both fail an issue is opened
  and the last image stays.
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
