# Agent Instructions

Read [README.md](README.md) first — it covers why this image exists, the
capability-based privilege model, what consumers must provide, and how to bump
the Telegraf version. Everything below is only for agents and is not repeated
there.

## The one rule that matters here

The `IMAGE` literal at the bottom of the `Rakefile` is the single source of
truth for every version. It is the composition root: the only place that names
concrete versions, reads the environment (`IMAGE_PLATFORMS`) and the image
tasks' Telegraf argument, and wires the objects together. `Image` itself is told
everything at construction and is frozen, so do not move configuration into
constants on the class or have it consult `ENV` — that is the design, not an
accident.

When asked to bump anything, change that literal and run `rake test`.
The image tasks' argument (`rake 'test[1.40.3]'`) is not a bump: it builds one
other Telegraf release by hand, as the release workflow would, and leaves the
pinned one unchanged.

Two places deliberately repeat what those constants say, and both must be
changed with them:

- the `Dockerfile`'s `ARG` defaults, so a bare `docker build` still works;
- the `build` matrix in `.github/workflows/ci.yml`, which states its platforms
  rather than computing them.

This duplication is a decision, not an oversight — do not reintroduce a
generated matrix or a separate manifest file to remove it. `rake image:verify`
catches a `Dockerfile` that has drifted (it asserts the installed versions and
the image labels against the constants). Nothing catches a CI matrix missing a
platform the `Rakefile` lists, which would then be published unverified, so
that is the pairing to be careful with.

## Do not "fix" these

They look like oversights and are not:

- **No `# syntax=` directive in the `Dockerfile`.** It would pull a frontend
  image from the registry at a floating `:1` tag, in a project whose point is
  that nothing floats. Nothing in the file needs it.
- **`USER 100` and an `ENTRYPOINT` of its own, with upstream's
  `/entrypoint.sh` unused.** That script starts as root, `setcap`s the Telegraf
  binary and drops to uid 100 with `setpriv`; all of it is done at build time
  here or handled by `USER`. Do not restore it, and do not drop `ENV HOME` or
  `CMD []` — the first replaces an export the script did at runtime, and
  without the second the base image's `CMD ["telegraf"]` arrives as a stray
  argument to the binary now in `ENTRYPOINT`. `USER` is numeric on purpose:
  the kubelet refuses `runAsNonRoot` for an image whose user is a name, as it
  cannot tell that name is not root. `image:verify` asserts it.
- **Two pins, and no package pins.** A version of ours pins `tooling_base` by
  digest; a build pins its Telegraf release and that release's base digest. The
  Rust toolchain and the test host's tools are deliberately unpinned: they take
  what the tooling base's Alpine release serves, which a stable branch only
  patch-rebuilds, and the test host's tools stand in for a node's anyway. Do
  not build `node-tool` on the Telegraf base — different Telegraf releases sit
  on different Alpine releases — and do not install or upgrade anything in the
  image stage: a build carries what its base ships, which is what makes "built
  once, never rebuilt" honest. The tooling base moves with a new version of
  ours, found with `rake image:versions`.
- **A tag _and_ a digest in `FROM`.** The digest is the pin; the tag is
  documentation, which Docker ignores when a digest is present. Do not drop
  either. `BASE_DIGEST` is declared twice in the `Dockerfile` on purpose — an
  `ARG` before `FROM` is out of scope after it, and the label needs it.
- **`ping` with `cap_net_raw` and no setuid bit, and `/etc/telegraf` owned by
  root.** Both undo upstream defaults deliberately: a setuid-root binary is a
  path to root on the node in a privileged pod, and a config directory the
  process owns is one it can rewrite. `image:verify` asserts both, plus that no
  setuid or setgid file exists anywhere.
- **No build-time check that Telegraf actually runs.** `execve` refuses a
  binary whose file-permitted set exceeds the caller's bounding set when the
  effective bit is on, and the build sandbox lacks `cap_dac_read_search` — so
  even root cannot exec Telegraf during a build. That is why the Dockerfile
  asserts only `getcap` output plus a `cap_dac_override` probe, and
  `rake image:verify` runs everything instead.
- **`--privileged` on every container `image:verify` starts.** Not laziness
  about isolation: for the same reason, a default container cannot exec
  Telegraf at all. It also matches how the image is deployed.
- **No smartmontools, LVM or ZFS in the image; `node-tool` runs the node's.**
  It enters the node's mount namespace through `/hostfs/proc/1/ns/mnt` — the
  node's `/proc`, which consumers mount for `procstat` anyway — and runs the
  node's own `smartctl`, `pvs`, `vgs`, `lvs` and `zpool`, so the node's
  versions and configuration apply. Do not add the packages back "to make it
  self-contained": `lvm` is the whole LVM suite, `smartctl` can test and
  reconfigure disks, `zpool` can destroy pools, and the wrapper existing is
  what keeps those out of uid 100's reach. Nothing of the base image is wrapped
  or removed; only tools this project adds go through `node-tool`.
- **`node-tool`'s allowlists are exactly what the plugins pass.** Taken from
  the Telegraf sources: `inputs.smartctl` runs `--json --scan-open` and
  `--json --all <device> --device <type> --nocheck=<mode>`; `inputs.smart` runs
  `--scan`, `--scan --device=nvme` and
  `--info --health --attributes --tolerance=verypermissive -n <mode> --format=brief <device> [-d <type>]`;
  `inputs.lvm` passes `--reportformat`, `--units`, `--nosuffix` and `-o`; and
  `examples/zfs.conf` runs `zpool list -H -p -o <columns>` — `inputs.zfs`
  itself runs no commands on Linux. Do not widen them for convenience, keep the
  matching exact — LVM accepts abbreviated long options — and keep option
  values typed: power modes, device types and column names are plain words, and
  `smartctl` devices are paths under `/dev/` without `..`. A Telegraf upgrade
  that passes something new shows up as a failing example-config or live check,
  which is the moment to add exactly that.
- **The node's `/proc` at `/hostfs/proc`, not `hostPID`, and not a bare `mnt`
  file.** The kernel refuses to bind-mount a mount-namespace file into a newer
  namespace (`mnt_ns_loop`), which every pod's is; tested. Telegraf cannot open
  the namespace link without `cap_sys_ptrace`, which it must never get;
  measured, the refused link resolves to its own directory.
- **Six capabilities on `node-tool`, all `=p`, handed on per tool.**
  `cap_sys_ptrace` and `cap_sys_chroot` (with `cap_sys_admin`) are for entering
  the node, effective only for opening the namespace and `setns`, then dropped
  from every set. Each tool then gets only its own, as ambient capabilities —
  measured: `smartctl` exactly `cap_dac_override,cap_sys_rawio,cap_sys_admin`,
  the LVM tools exactly `cap_dac_override,cap_fowner,cap_sys_admin`, `zpool`
  exactly `cap_dac_override`, to open `/dev/zfs`, which libzfs opens
  read-write even to list and a node can keep `0600`. That was measured on the
  CI runner, whose kernel has the ZFS module: the test host keeps `/dev/zfs`
  root-only `0600` where it exists, so `zpool version` there talks to a real
  module. Docker Desktop has none, so locally the check proves routing only.
  `cap_dac_override`, not
  `cap_dac_read_search`, for LVM: it opens `/dev/mapper/control` read-write
  even to report; the read-only capability passed locally and failed on real
  hosts. Keep the environment replacement: the node's tools have no file
  capabilities, so `AT_SECURE` does not protect them from `LD_PRELOAD`. Keep it
  statically linked and without dependencies — `image:verify` asserts the
  first.
- **`unshare(CLONE_FS)` before `setns`.** The kernel refuses to change the
  mount namespace of a process whose filesystem context another thread
  shares (`EINVAL`). `node-tool` has one thread, but QEMU's user-mode
  emulation, which CI uses for the non-native platform, adds its own. It looks
  redundant natively and on Docker Desktop, which emulates without QEMU; it is
  what lets CI's arm64 job enter the node.
- **The namespace is opened privileged, then checked.** Unprivileged, the link
  falls back to its directory, so a guard that `stat`s it first proves nothing.
  `node-tool` opens it with the entry capabilities effective, then refuses a
  directory and the container's own namespace — the latter would run the
  wrapper in a loop, since there `/usr/sbin/lvs` is the wrapper.
- **The test host.** `image:build` builds the `test-host` stage as
  `local/telegraf-test-host`, a name outside the repository so it cannot be
  pushed as the image. It is the stage before `image` on purpose: a plain
  `docker build` builds the last stage. `image:verify` starts it per platform
  with a throwaway volume group and the device modes a real node has
  (`Image::AS_ON_A_HOST`). Checks marked `on_host` join its process namespace,
  mount a `/proc` of it at `/hostfs/proc` as root on a tmpfs, and then run as
  `telegraf` — like a pod whose node's `/proc` knows its processes. Teardown is
  the test host's own `trap` on `docker stop`. It runs on the tooling base, so
  every build of one version of ours is tested against the same node-side
  tools, as far as its Alpine release keeps them. Its `zpool` talks to a ZFS
  module only where the Docker host's kernel has one, as CI's does; on Docker
  Desktop the ZFS checks prove routing and parsing only. No container can
  create a pool, so `zfs.conf`'s parsing is checked against a stand-in `zpool`
  printing the real output format.
- **No `nvme-cli`, and a check that asserts its absence.** `smartctl` reads
  NVMe SMART itself; `nvme` only ever served `inputs.smart`'s
  `enable_extensions`. Do not add it to `node-tool` to "support" that option.
  The absence check covers smartmontools and LVM as well: any of them returning
  as a dependency would be run in place of the node's.
- **Everything in one `Rakefile`** — `Image`, `CommandRunner`, `WorkflowLinter`
  and the value types. There is no `rakelib/`. `.rubocop.yml` excludes the
  `Rakefile` from `Style/OneClassPerFile` for exactly this reason.
- **No rescue around the task bodies.** Rake already aborts with exit 1 and
  prints the exception message; a wrapper would only hide the backtrace, which
  matters when the failure is a bug rather than a bad pin.
- **`runs-on: ubuntu-24.04`, not `ubuntu-latest`.** Pinned like everything else
  here, and deliberately on the image shipping Docker 28 — the version with no
  `--platform` on `docker image inspect`, which is the path
  `Image#inspect_image` falls back for. Moving to a newer runner leaves that
  fallback untested.
- **No Docker Hub login in CI.** It pulls only the public base image. The push
  token stays out of a workflow that runs on every branch.
- **`environment: release` on the publish job.** The Docker Hub credentials are
  environment secrets, and an environment secret reaches only a job that names
  its environment. Removing that line does not fall back to repository secrets
  — it makes them resolve to empty, and the login fails on "Username and
  password required".
- **`Image#version` and `Image#tag` differ, by one character.** The build's
  name is `<telegraf_version>+image.<own_version>` — ours as semver build
  metadata, labelled `image.`, Telegraf's first because it is what consumers
  choose by — and is what the git tag, the release branch and the version label
  use. Docker rejects `+`, so the image tag swaps it for `_`, which neither
  version can contain. The swap is one way: recover a build's version from its
  `org.opencontainers.image.version` label, never by parsing a tag, and do not
  "simplify" the git tag to match the image tag.

## Building every Telegraf release

`rake builds:publish`, run by `.github/workflows/release.yml` on a version tag
of ours, goes through every Telegraf release from `TELEGRAF_FLOOR` on and
builds, verifies and pushes each build not yet on Docker Hub.
`.github/workflows/mirror.yml` only dispatches that workflow daily on every
`vX.Y.Z` tag. README.md, "Building every Telegraf release", covers what they
do; these are the constraints on changing them.

- **Nothing is written to git.** A build exists only as its image: no build
  branches, commits or tags. The Telegraf release and its base digest reach the
  build as arguments (`Image#with_telegraf`), and the tag's files keep the
  values CI tests with. Do not reintroduce per-build refs.
- **Built from the tag, by its own code.** The release workflow runs on
  `v<own>`, so every build of a version uses that version's Dockerfile,
  `node-tool`, checks and floor. Changes to `main` reach builds only through a
  new version of ours. Running on the tag is also what admits the job to the
  `release` environment and its Docker Hub credentials, whose policy allows
  `v*` refs only — so the mirror dispatches rather than publishing itself.
- **Built once, never rebuilt.** A build already on Docker Hub is skipped;
  upstream rebuilding a base in place does not start a build. `Image#publish`
  refusing an existing tag backs this up: do not add a counter or an overwrite
  to get rebuilds — that would be a different release policy, not a fix.
- **Serial, oldest first, stopping at the first failure.** That is how order is
  guaranteed: no build lands while an older one of the same version is broken,
  and the next run starts over from there. Do not turn it into a matrix. The
  mirror runs versions of ours one after the other but lets a failing one not
  stop the next.
- **No build cache in the release workflow.** CI keeps build layers between
  runs (`IMAGE_BUILD_CACHE`, a week-keyed `actions/cache`); the publish job
  builds from scratch, so what it publishes never rests on a layer cached from
  another run, possibly another branch's. Do not add the cache there to speed
  it up.
- **Every build is verified where it is published.** `builds:publish` runs
  `image:build` and `image:verify` before each `image:publish`, in the same
  job, so what reaches Docker Hub is what was checked. The release workflow
  skips its CI job when the mirror dispatched it
  (`github.actor == 'github-actions[bot]'`) for that reason; the skip fails
  safe, as an actor that does not match just runs CI.
- **The tag filter is release tags only.** `release.yml` fires on
  `v[0-9]+.[0-9]+.[0-9]+` — `+` means "one or more" in GitHub's patterns — so
  neither `-dev` versions nor the retired `-alpine.N` tags start it. Its config
  job rejects any ref that is not the checked-out version's tag.

## Releasing

`rake release` (class `Release`) is the only way a version of ours gets a plain
`X.Y.Z` and a tag; between releases `own_version` is `X.Y.Z-dev`, which is
never built for release, as only `vX.Y.Z` tags start the release workflow. From
`main` at `X.Y.0-dev` it branches `X.Y.x`, commits and tags the release there,
commits `X.Y.1-dev` after it, and moves `main` to `X.(Y+1).0-dev`; on `X.Y.x`
it makes the next patch release.

- **It never pushes.** Pushing the tag starts the release workflow and with it
  public releases, so that stays a person's step; the task prints the command.
  Do not add a push.
- **It validates before it changes anything** — clean tree, branch, `-dev`
  version, no existing branch or tag — so a refusal leaves nothing behind. Keep
  new checks in that order.
- **The version lines are an interface.** `SourceTree` reads and rewrites
  `own_version: "…",` (and the `telegraf_version`/`base_digest` lines beside
  it) in the `IMAGE` literal, the Dockerfile's `ARG IMAGE_VERSION=`, and the
  README's `Published as` line, by line-anchored pattern. Each edit must match
  exactly once, so a reformatted line fails the release rather than corrupting
  it — but it does fail it. Keep those lines' shape.
- **The release branch gets its commits in a worktree**, so the checkout stays
  on `main` throughout and ends on `main`'s next development version.

## Verification

`rake image:verify` is not optional before publishing, and it must keep testing
every platform the image is configured for, not just the host's. Several of its
checks exist because their failure mode is otherwise invisible — a metrics gap
on a node, days later:

- every plugin's default paths running the node's tools, `inputs.lvm` reading
  the test host's volume group as uid 100, and a capability proving live rather
  than merely recorded,
- the image running as uid 100 and its entrypoint reaching the binary, and
- Telegraf actually loading each config under `examples/`.

The example configs are shipped documentation that is also executed: `--test`
rejects an option the installed Telegraf does not have, so those two checks are
what keeps `examples/` from drifting. Adding an option to an example without
running `rake image:verify` defeats the point.

The entrypoint check deliberately runs through the image's real `ENTRYPOINT`,
so it would catch a broken `ENTRYPOINT`/`CMD` pairing that
`--entrypoint /bin/sh` hides. Only three checks ask for `--user 0:0`: the
live-capability probe, because laying out a root-owned file needs root, the
setuid search, because uid 100 cannot descend into `/root`, and the
own-namespace refusal, for its mount — its `lvs` still runs as uid 100.
`on_host` checks mount `/hostfs/proc` as root and then run as `telegraf`, and
the test host does its own setup as root. Everything else runs as the image's
own user, which is the point.

Every hardening check was run against the build before it as a negative
control, and failed there. Do the same for a new one: a check that passes on
the image it is meant to guard against proves nothing.

`image:publish` is a plain `docker push` of the already-loaded image, on
purpose: the published bytes are the verified ones. Do not turn it back into a
`buildx --push`, which would publish a rebuild that only ought to match what
was checked. Its refusal to push a missing or partially built tag is what keeps
that guarantee, so the guard is not redundant with `image:push`'s task order.

Report what `rake image:verify` actually printed. It names the versions it
found, so quoting them is cheap and a claim without them is not verification.
