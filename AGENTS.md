# Agent Instructions

Read [README.md](README.md) first — it covers why this image exists, the
capability-based privilege model, what consumers must provide, and how to bump
the Telegraf version. Everything below is only for agents and is not repeated
there.

## The one rule that matters here

The `IMAGE` literal at the bottom of the `Rakefile` is the single source of
truth for every version. It is the composition root: the only place that names
concrete versions, reads the environment (`IMAGE_PLATFORMS`) and wires the
objects together. `Image` itself is told everything at construction and is
frozen, so do not move configuration into constants on the class or have it
consult `ENV` — that is the design, not an accident.

When asked to bump anything, change that literal and run `rake test`.

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
- **`USER telegraf` and an `ENTRYPOINT` of its own, with upstream's
  `/entrypoint.sh` unused.** That script starts as root, `setcap`s the Telegraf
  binary and drops to uid 100 with `setpriv`; all of it is done at build time
  here or handled by `USER`. Do not restore it, and do not drop `ENV HOME` or
  `CMD []` — the first replaces an export the script did at runtime, and
  without the second the base image's `CMD ["telegraf"]` arrives as a stray
  argument to the binary now in `ENTRYPOINT`.
- **Exact apk pins that eventually stop resolving.** A failing build is the
  intended signal that Alpine rotated a version out of its index. Fix it with
  `rake image:versions` and a `REVISION` bump, not by unpinning.
- **A tag _and_ a digest in `FROM`.** The digest is the pin; the tag is
  documentation, which Docker ignores when a digest is present. Do not drop
  either. `BASE_DIGEST` is declared twice in the `Dockerfile` on purpose — an
  `ARG` before `FROM` is out of scope after it, and the label needs it.
- **A `zlib` pin for a package the base already ships.** It is a security
  override (CVE-2026-85091), not a dependency. The mirror pins it to the newest
  version Alpine offers, so it stays current by itself; removing it is never
  required.
- **`ping` with `cap_net_raw` and no setuid bit, and `/etc/telegraf` owned by
  root.** Both undo upstream defaults deliberately: a setuid-root binary is a
  path to root on the node in a privileged pod, and a config directory the
  process owns is one it can rewrite. `image:verify` asserts both, plus that no
  setuid or setgid file exists anywhere.
- **No build-time check that the tools actually run.** `execve` refuses a
  binary whose file-permitted set exceeds the caller's bounding set when the
  effective bit is on, and the build sandbox has neither `cap_sys_rawio` nor
  `cap_sys_admin` — so even root cannot exec them during a build. That is why
  the Dockerfile asserts only `getcap` output plus a `cap_dac_override` probe,
  and `rake image:verify` runs the tools instead.
- **`--privileged` on every container `image:verify` starts.** Not laziness
  about isolation: for the same reason, a default container cannot exec these
  tools at all. It also matches how the image is deployed.
- **The `/usr/bin/smartctl` symlink.** `inputs.smartctl` looks in `/usr/sbin`,
  `inputs.smart` in `/usr/bin`. The symlink is what lets both plugins work
  without every consumer overriding `path_smartctl`. It needs no capabilities
  of its own — a file capability is on the inode, verified — though `getcap`
  reports nothing for it, so assert on the real path.
- **No `nvme-cli`, and a check that asserts its absence.** `smartctl` reads
  NVMe SMART itself; `nvme` only ever served `inputs.smart`'s
  `enable_extensions`, and it had to hold `cap_sys_admin` to do it. Do not
  reinstall it to "support" that option. The absence check is there because the
  package could return as a transitive dependency — present but without
  capabilities, which is the silent half-working state.
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
- **`Image#version` with no separate tag method.** The format
  (`1.40.2-alpine.0`) is deliberately restricted to characters Docker accepts
  in a tag, so the image tag, the git tag and the version label are one string
  rather than transliterations of each other. Keep it that way: semver build
  metadata (`+alpine`) would be valid semver and invalid as a Docker tag, which
  is what forced a transliteration here before.

## The mirror

`rake mirror:sync` (run daily by `.github/workflows/mirror.yml`) keeps a
release line per upstream release — branch `<version>-alpine.x`, tags
`v<version>-alpine.<revision>`. README.md, "Mirroring upstream releases",
covers what it does; these are the constraints on changing it.

- **The `IMAGE` literal's line shapes are an interface.** `SourceTree` reads
  and rewrites `telegraf_version: "…",`, `base_digest: "…",`, `revision: N,`
  and `Image::Package.new(name: "…", version: "…"),` by line-anchored pattern,
  along with the Dockerfile's `ARG <NAME>_VERSION=` defaults and the README's
  `Published as` line. Each edit must match exactly once, so a reformatted line
  fails the run rather than corrupting it — but it does fail it. Keep those
  lines' shape, and name a new package's `ARG` after the package
  (`smartmontools` → `SMARTMONTOOLS_VERSION`).
- **Strictly serial, stopping at the first failure.** That is how order is
  guaranteed. Do not turn it into a matrix or let it skip a failing version: a
  later release would then land while an earlier one is broken.
- **Verified before committed.** `rake test` runs in the line's worktree before
  anything is committed or tagged, so a base this image cannot handle leaves no
  tag behind. Do not move the commit before it.
- **Published by dispatch, not by the tag push.** A tag pushed with the
  workflow token starts no workflows; `workflow_dispatch` is the exception. So
  the mirror dispatches `release.yml` on the tag and waits for it. Removing
  `workflow_dispatch` from `release.yml` stops every automated release.
- **New lines fork from `main`, never from an older tag** — even for a version
  released before its line existed. Dispatch needs the workflow at the
  dispatched ref to accept it, which only current tooling is sure to; tags
  still set the next revision, so nothing is renumbered.
- **`main` is the template.** Its `IMAGE` literal is what a new line starts
  from, before the mirror rewrites the version lines. Changes to `main` reach
  an existing line only when merged into its branch by hand.
- **Detached worktrees, no local branches.** The mirror pushes
  `HEAD:refs/heads/<branch>`, so a run leaves no branch behind, and a dry run
  leaves nothing at all.

## Verification

`rake image:verify` is not optional before publishing, and it must keep testing
every platform the image is configured for, not just the host's. Several of its
checks exist because their failure mode is otherwise invisible — a metrics gap
on a node, days later:

- both plugins' default paths running `smartctl`, and a capability proving live
  rather than merely recorded,
- the image running as uid 100 and its entrypoint reaching the binary, and
- Telegraf actually loading each config under `examples/`.

The example configs are shipped documentation that is also executed: `--test`
rejects an option the installed Telegraf does not have, so those two checks are
what keeps `examples/` from drifting. Adding an option to an example without
running `rake image:verify` defeats the point.

The entrypoint check deliberately runs through the image's real `ENTRYPOINT`,
so it would catch a broken `ENTRYPOINT`/`CMD` pairing that
`--entrypoint /bin/sh` hides. Only two checks ask for `--user 0:0`: the
live-capability probe, because laying out a root-owned file needs root, and the
setuid search, because uid 100 cannot descend into `/root`. Everything else
runs as the image's own user, which is the point.

Every hardening check was run against the revision before it as a negative
control, and failed there. Do the same for a new one: a check that passes on
the image it is meant to guard against proves nothing.

`image:publish` is a plain `docker push` of the already-loaded image, on
purpose: the published bytes are the verified ones. Do not turn it back into a
`buildx --push`, which would publish a rebuild that only ought to match what
was checked. Its refusal to push a missing or partially built tag is what keeps
that guarantee, so the guard is not redundant with `image:push`'s task order.

Report what `rake image:verify` actually printed. It names the versions it
found, so quoting them is cheap and a claim without them is not verification.
