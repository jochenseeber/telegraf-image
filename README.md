# Telegraf with smartmontools

A Telegraf container image that adds `smartmontools` and `nvme-cli`, so
Telegraf can collect disk SMART attributes from Kubernetes nodes. Both SMART
plugins work out of the box: [`inputs.smartctl`][smartctl-plugin] and the older
[`inputs.smart`][smart-plugin].

Published as **`jochen/telegraf:1.40.0-r.0-alpine`**.

Versions are semantic: `1.40.0-r.0+alpine` is the upstream Telegraf release,
`r.0` a prerelease identifier counting rebuilds of it, and `+alpine` build
metadata naming the variant. The git tag carries that exactly
(`v1.40.0-r.0+alpine`); the image tag joins the metadata with `-` instead,
because Docker's reference parser rejects `+`. The image's
`org.opencontainers.image.version` label holds the unmodified version.

[smartctl-plugin]: https://github.com/influxdata/telegraf/tree/master/plugins/inputs/smartctl
[smart-plugin]: https://github.com/influxdata/telegraf/tree/master/plugins/inputs/smart

## Why this image exists

The official Telegraf images cannot read SMART data. Both 1.40 Dockerfiles, the
Debian and the Alpine one, install `lm_sensors`, `iputils`, `net-snmp-tools`,
`procps`, `tzdata`, `setpriv`, `libcap` and `tini` — and no `smartmontools`. An
upstream request to add the package was opened in December 2021 and closed
without it landing.

## What it adds over upstream

Built on `telegraf:1.40.0-alpine`, unmodified except for:

- **`smartmontools` `7.5-r0`** — `smartctl`, which both plugins call.
- **`nvme-cli` `2.16-r1`** — `nvme`, which `inputs.smart` calls for NVMe vendor
  attributes.
- **`sudo` `1.9.17_p2-r0`** — lets the unprivileged `telegraf` user reach the
  two tools above.

Plus two things that make the plugins work without further configuration:

- `/etc/sudoers.d/telegraf`, granting the `telegraf` user passwordless root for
  exactly `smartctl` and `nvme`.
- `/usr/bin/smartctl` and `/usr/bin/nvme` symlinks. Alpine installs both tools
  under `/usr/sbin`, which is where `inputs.smartctl` looks; `inputs.smart`
  defaults to `/usr/bin` instead. Without the symlinks it finds neither tool.

`inputs.smartctl` needs `smartctl` 7.0 or newer for JSON output. This image
ships **smartmontools 7.5** (`smartctl 7.5 2025-04-30 r5714`).

The entrypoint, command, exposed ports and the `telegraf` user are inherited
from upstream and deliberately untouched.

## Which plugin

**`inputs.smartctl`** is the newer one and the better default. It parses
`smartctl`'s JSON output, and it reads NVMe devices through `smartctl` itself —
its documentation is explicit that, "contrary to the smart plugin, this plugin
does not use the `nvme-cli` package". Configuration:
[`examples/smartctl.conf`](examples/smartctl.conf).

**`inputs.smart`** is the older one, and the reason to choose it is
`enable_extensions`: it shells out to `nvme` for vendor-specific NVMe log pages
(Intel and friends) that `smartctl` does not surface. It also emits a different
metric and tag shape, so the two are not drop-in replacements for each other in
existing dashboards. Configuration:
[`examples/smart.conf`](examples/smart.conf).

Pick `inputs.smartctl` unless you specifically want NVMe vendor extensions.

## What the consumer has to provide

The image cannot grant itself device access. The pod running it needs:

- **`privileged: true`** in the container's security context.
- **`/dev` mounted** from the host, so `smartctl --scan-open` finds the disks.
- **No `runAsUser` or `runAsNonRoot`.** The container has to start at uid 0 so
  the upstream entrypoint can perform its own drop to `telegraf`. Forcing a
  different uid skips that drop, and `sudo` then denies the call because the
  sudoers policy names the `telegraf` user.
- **`use_sudo = true`** in whichever plugin is configured. Without it the
  plugin calls the tools directly and every device read fails on permissions.

Ready-to-adapt snippets are in [`examples/`](examples): `smartctl.conf` and
`smart.conf`.

## Building

Requires Docker with buildx, and — to build more than one platform locally —
Docker's containerd image store.

```bash
rake image:config    # show what would be built and published
rake image:build     # one multi-platform build, loaded locally
rake image:verify    # run the checks against each platform in it
rake image:push      # build, verify, then push exactly what was verified
```

`rake test` is `image:build` plus `image:verify`.

`image:build` produces a single multi-platform image under the tag it will be
published as, rather than a set of per-architecture tags — so what gets
verified is the artifact itself, not something that resembles it.
`image:verify` then reaches each architecture out of that one manifest list
with `docker run --platform`.

`image:verify` runs checks against each platform: the Telegraf version, that
`smartctl` and `nvme` are the pinned versions, that `smartctl` can emit JSON,
that the `telegraf` user can reach both tools through sudo at both plugins'
default paths, that the entrypoint still drops to uid 100, and that Telegraf
loads each shipped example config.

### Versions are pinned, on purpose

The base image is pinned to the exact patch tag (`1.40.0-alpine`, never
`1.40-alpine` or `latest`) and every apk package to its exact version.

The CI runners are pinned too (`ubuntu-24.04`, not `ubuntu-latest`), so the
toolchain a build runs against does not change underneath it. That image ships
Docker 28, which has no `--platform` on `docker image inspect` — the Rakefile
falls back for exactly that case, and pinning here is what keeps the fallback
exercised on every run rather than quietly rotting.

## Bumping the Telegraf version

Everything version-shaped lives in the `IMAGE` literal at the bottom of the
[`Rakefile`](Rakefile). The Dockerfile's `ARG` defaults mirror it so a bare
`docker build` works, and have to be updated alongside.

1. Check what is current:
   `docker run --rm telegraf:<new>-alpine telegraf --version`.
2. Set `telegraf_version` in that literal and reset `revision` to `0`.
3. Refresh the package pins — a new Telegraf release often moves to a newer
   Alpine base with different package versions:

   ```bash
   rake image:versions
   ```

   It asks the new base image's own `apk` what it would install, for every
   configured platform, and prints the versions to copy into `packages`.
4. Mirror the Telegraf version and the pins into the `Dockerfile`'s `ARG`
   defaults.
5. `rake test`, then commit.
6. Tag with the reference the `Rakefile` now expects and push the tag:

   ```bash
   git tag "$(rake --silent image:release_ref)"
   git push origin main --follow-tags
   ```

   The release workflow refuses any tag that disagrees with the `Rakefile`, so
   the code is always the authority and the tag follows it.

To rebuild without a Telegraf bump — a moved package pin, a sudoers change, a
base image rebuild — leave `telegraf_version` alone and increment `revision`,
giving `-r.1`, `-r.2` and so on. Those sort in order under semver, and all of
them sort below a bare `1.40.0`, which this project never publishes.

### Adding a platform

The `platforms` list in the `Rakefile` and the `build` matrix in
`.github/workflows/ci.yml` are separate lists, on purpose — the workflow says
what it builds instead of computing it. Change both together.

## Releasing

`.github/workflows/release.yml` fires on a `v*` tag. It checks that the tag
matches the `Rakefile`, runs the full CI suite for that commit, and only then
builds, verifies and pushes — the same `rake image:push` a workstation runs.

`image:publish` is a plain `docker push` of the image already in the local
daemon, not a second build to the registry. So the bytes that reach Docker Hub
are the ones `image:verify` just ran its checks against, rather than a rebuild
that ought to be identical. It refuses to push a tag that is absent or missing
a platform, which is why it is only ever the second half of `image:push`.

It needs two secrets on the **`release` environment** — not repository secrets,
so that no branch build can reach them:

- `DOCKERHUB_USERNAME` — the Docker Hub account owning the namespace.
- `DOCKERHUB_TOKEN` — an access token for it, not the account password.

The publish job declares `environment: release`, which is what makes those
secrets visible to it, and the environment restricts itself to `v*` tags. CI
holds no Docker Hub credentials at all; it only pulls the public base image.

## Layout

- `Rakefile` — single source of truth (base version, revision, platforms,
  package pins), the `image:*` tasks and `rake lint`.
- `Dockerfile` — the image, plus its build-time assertions.
- `sudoers.d/telegraf` — the sudo policy copied into the image.
- `examples/smartctl.conf`, `examples/smart.conf` — plugin configuration for
  the consumer to adapt; both are load-tested by `image:verify`.
- `.github/workflows/` — CI (build and verify per platform) and release
  (publish).
