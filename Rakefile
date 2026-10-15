# frozen_string_literal: true

require "English"
require "json"
require "net/http"
require "time"
require "tmpdir"

# Run external commands
class CommandRunner
  include Rake::DSL

  # Print command to console and run; options such as `chdir:` go to spawn
  def execute(*, **)
    sh(*, **)
  end

  # Run command, capture stdout and return `nil` on failure
  def capture(*arguments, **)
    output = IO.popen(arguments, err: File::NULL, **, &:read)
    $CHILD_STATUS.success? ? output : nil
  end

  # Run command, capture stdout and stderr, and return `nil` on failure
  def capture_merged(*arguments)
    output = IO.popen(arguments, err: %i[child out], &:read)
    $CHILD_STATUS.success? ? output : nil
  end
end

# Docker image handling
class Image
  # Platform information
  Platform = Data.define(:operating_system, :architecture) do
    def self.parse(text)
      operating_system, architecture = text.to_s.split("/", 2)
      if operating_system.to_s.empty? || architecture.to_s.empty?
        raise ArgumentError, "expected an os/arch platform, got #{text.inspect}"
      end

      new(operating_system: operating_system, architecture: architecture)
    end

    def to_s
      "#{operating_system}/#{architecture}"
    end
  end

  # Package information
  Package = Data.define(:name, :version) do
    def apk_argument
      "#{name}=#{version}"
    end

    # Alpine's `-rN` is not part of the upstream version, so the pin says
    # "7.5-r0" and the tool prints "7.5". Checking one against the other is what
    # proves the pin took effect rather than that something is merely installed.
    def reported_version
      version.sub(%r{-r\d+\z}, "")
    end
  end

  # Label for Docker builds
  Label = Data.define(:name, :value)

  # Argument for Docker builds
  BuildArgument = Data.define(:name, :value) do
    def to_argument
      "#{name}=#{value}"
    end
  end

  # Assertion about the built image
  #
  # `expected` is a substring rather than a regexp because these assert
  # versions, and a failing literal prints a diff worth reading.
  #
  # `via_entrypoint` runs the image's own ENTRYPOINT.
  Check = Data.define(:description, :command, :expected, :via_entrypoint, :mount, :user, :read_only) do
    def docker_arguments(reference:, platform:)
      # Privileged, because that is how the image is deployed and because it is
      # now required rather than merely expected: the tools carry file
      # capabilities with the effective bit set, and execve refuses them unless
      # the container's bounding set holds every one. A default container
      # cannot even run `smartctl --version`.
      arguments = ["run", "--rm", "--privileged", "--platform", platform.to_s]
      # The image runs as the telegraf user, so a check that has to set up
      # root-owned state says so rather than reaching for su.
      arguments += ["--user", user] if user
      arguments << "--read-only" if read_only
      arguments += ["--volume", "#{File.expand_path(mount)}:/#{File.basename(mount)}:ro"] if mount
      # Through the entrypoint the command is the container's arguments; around
      # it, a shell is substituted so a check can use a pipeline or a `su`.
      return [*arguments, reference, *command.split] if via_entrypoint

      [*arguments, "--entrypoint", "/bin/sh", reference, "-c", command]
    end

    def result_for(output)
      raise Error, "#{description}: command failed: #{command}" if output.nil?
      unless output.include?(expected)
        raise Error, "#{description}: expected #{expected.inspect} in output of " \
                     "#{command.inspect}, got:\n#{output}"
      end

      # The matching line, not the first: several of these print JSON or a
      # banner whose first line carries nothing.
      matching_line = output.lines.find { |line| line.include?(expected) } || output.lines.first
      matching_line.to_s.strip
    end
  end

  class Error < StandardError; end

  DOCKERFILE = "Dockerfile"

  attr_reader :repository, :telegraf_version, :base_digest, :revision, :platforms, :packages

  def initialize(repository:, telegraf_version:, base_digest:, revision:, platforms:, packages:,
                 commands: CommandRunner.new, registry: Registry.new)
    raise ArgumentError, "an image needs at least one platform" if platforms.empty?
    raise ArgumentError, "an image needs at least one package" if packages.empty?
    raise ArgumentError, "revision must not be negative, got #{revision}" if revision.negative?
    raise ArgumentError, "base_digest must be sha256:<64 hex>, got #{base_digest.inspect}" \
      unless base_digest.match?(%r{\Asha256:\h{64}\z})

    @repository = repository
    @telegraf_version = telegraf_version
    @base_digest = base_digest
    @revision = revision
    @platforms = platforms.freeze
    @packages = packages.freeze
    @commands = commands
    @registry = registry
    freeze
  end

  def with_platforms(platforms)
    unknown = platforms - @platforms
    raise Error, "#{unknown.join(", ")} is not a platform this image is configured for" unless unknown.empty?

    self.class.new(repository: @repository, telegraf_version: @telegraf_version,
                   base_digest: @base_digest, revision: @revision, platforms: platforms,
                   packages: @packages, commands: @commands, registry: @registry)
  end

  # The semantic version, and the canonical form of everything below. Variant
  # and revision together are the prerelease, so rebuilds of one Telegraf
  # release order correctly (alpine.0 < alpine.1 < alpine.2).
  #
  # It uses only characters Docker accepts in a tag, which is why the image tag,
  # the git tag and the version label are all this one string rather than
  # transliterations of it.
  def version
    "#{@telegraf_version}-alpine.#{@revision}"
  end

  def reference
    "#{@repository}:#{version}"
  end

  def base_image
    "telegraf:#{@telegraf_version}-alpine"
  end

  def release_reference
    "v#{version}"
  end

  def package(name)
    found = @packages.find { |package| package.name == name }
    raise Error, "this image has no #{name} package" if found.nil?

    found
  end

  def build
    ensure_multi_platform_loadable
    @commands.execute("docker", "buildx", "build",
                      "--platform", @platforms.join(","),
                      "--file", DOCKERFILE,
                      *build_arguments.flat_map { |argument| ["--build-arg", argument.to_argument] },
                      "--tag", reference,
                      "--load", ".")
  end

  def verify
    image_checks = checks
    @platforms.each do |platform|
      ensure_contains(platform, action: "run `rake image:build` first")
      puts "#{platform} (#{reference})"
      image_checks.each { |check| puts "  #{check.description}: #{run_check(check, platform: platform)}" }
      verify_labels(platform: platform)
    end
    puts "#{image_checks.size + labels.size} checks passed on #{@platforms.size} platform(s)"
  end

  # Never over an existing tag: `docker push` would replace it silently, and
  # whoever runs that tag would get different bytes on their next pull. A new
  # build gets a new revision instead.
  def publish
    @platforms.each do |platform|
      ensure_contains(platform, action: "run `rake image:build` and `rake image:verify` first")
    end
    unless @registry.digest(@repository, version).nil?
      raise Error, "#{reference} is already published; bump the revision rather than replace it"
    end

    @commands.execute("docker", "push", reference)
  end

  # The tag's current digest first: a moved digest means upstream rebuilt the
  # base, which is a reason for a new revision even when no pin changed.
  def report_available_versions
    digest = @commands.capture("docker", "buildx", "imagetools", "inspect", base_image,
                               "--format", "{{.Manifest.Digest}}")
    raise Error, "cannot read the current digest of #{base_image}" if digest.nil?

    puts "=== #{base_image} ==="
    puts "current digest: #{digest.strip}"
    puts "pinned digest:  #{@base_digest}"
    names = @packages.map(&:name).join(" ")
    @platforms.each do |platform|
      puts "=== #{platform} ==="
      @commands.execute("docker", "run", "--rm", "--platform", platform.to_s,
                        "--entrypoint", "/bin/sh", base_image,
                        "-c", "apk update > /dev/null && apk policy #{names}")
    end
  end

  def describe
    puts "base image:  #{base_image}@#{@base_digest}"
    puts "version:     #{version}"
    puts "publishes:   #{reference}"
    puts "release tag: #{release_reference}"
    puts "platforms:   #{@platforms.join(", ")}"
    puts "packages:"
    @packages.each { |package| puts "  #{package.apk_argument}" }
  end

  def build_arguments
    [
      BuildArgument.new(name: "TELEGRAF_VERSION", value: @telegraf_version),
      BuildArgument.new(name: "BASE_DIGEST", value: @base_digest),
      BuildArgument.new(name: "SMARTMONTOOLS_VERSION", value: package("smartmontools").version),
      BuildArgument.new(name: "ZLIB_VERSION", value: package("zlib").version),
      BuildArgument.new(name: "IMAGE_VERSION", value: version),
      BuildArgument.new(name: "SOURCE_COMMIT", value: source_commit),
    ]
  end

  def labels
    [
      Label.new(name: "org.opencontainers.image.base.name", value: "docker.io/library/#{base_image}"),
      Label.new(name: "org.opencontainers.image.base.digest", value: @base_digest),
      Label.new(name: "org.opencontainers.image.version", value: version),
    ]
  end

  # Image checks, grouped by what they prove
  def checks
    content_checks + privilege_checks + behaviour_checks
  end

  private

  # What is installed, and at which version
  def content_checks
    [
      check("Telegraf version",
            command: "telegraf --version", expected: "Telegraf #{@telegraf_version}"),
      check("smartctl present",
            command: "smartctl --version", expected: smartctl_version),
      check("smartctl supports JSON output",
            command: "smartctl --json --version", expected: '"json_format_version"'),
      # A security override of a package the base already ships, so what has to
      # be proven is that the pin won over the base's own version.
      check("zlib is the pinned version",
            command: "apk list -I zlib", expected: "zlib-#{package("zlib").version} "),
      # nvme-cli is deliberately absent — smartctl reads NVMe SMART itself, and
      # nvme needed cap_sys_admin of its own. Asserted because it could return
      # as a transitive dependency, uncapability'd and therefore silently
      # half-working for inputs.smart.
      check("nvme-cli absent",
            command: "command -v nvme || echo absent", expected: "absent"),
    ]
  end

  # Who holds which privilege, and that nothing else does
  def privilege_checks
    [
      # Asserted on the real paths: `getcap` does not follow symlinks, so the
      # /usr/bin alias reports nothing even though it confers the same
      # privileges.
      check("smartctl carries its capabilities",
            command: "getcap /usr/sbin/smartctl",
            expected: "cap_dac_override,cap_sys_rawio,cap_sys_admin=ep"),
      check("telegraf carries its capability",
            command: "getcap /usr/bin/telegraf",
            expected: "cap_dac_read_search,cap_net_bind_service,cap_net_raw=ep"),
      check("ping carries a capability instead of setuid",
            command: "getcap /bin/ping", expected: "cap_net_raw=ep"),
      # Upstream ships ping setuid root, and in a privileged pod uid 0 is root on
      # the node, so no path from uid 100 to uid 0 may exist. Root runs the
      # search because uid 100 cannot descend into /root.
      check("no setuid or setgid files",
            command: "test -z \"$(find / -xdev -type f -perm /6000)\" && echo none",
            expected: "none", user: "0:0"),
      # Upstream gives /etc/telegraf to the telegraf user, which would let the
      # running process rewrite its own configuration.
      check("uid 100 cannot write the configuration",
            command: "(touch /etc/telegraf/telegraf.conf || touch /etc/telegraf/telegraf.d/probe) " \
                     "2>/dev/null && echo writable || echo denied",
            expected: "denied"),
      # Proves a capability is live rather than merely recorded — a
      # recorded-but-inert xattr looks identical from `getcap`. Needs root to
      # lay out the probe.
      check("a capability actually takes effect for uid 100",
            command: "cp /bin/busybox /tmp/busybox && setcap cap_dac_override+ep /tmp/busybox && " \
                     "printf live > /root/probe && chmod 600 /root/probe && " \
                     "su telegraf -s /bin/sh -c '/tmp/busybox cat /root/probe'",
            expected: "live", user: "0:0"),
      check("image runs as the telegraf user",
            command: "id", expected: "uid=100(telegraf)"),
    ]
  end

  # That it all works for uid 100. No `su` here: the image runs as the telegraf
  # user, so these already are that user.
  def behaviour_checks
    [
      check("inputs.smartctl path runs",
            command: "/usr/sbin/smartctl --version", expected: smartctl_version),
      check("inputs.smart path runs",
            command: "/usr/bin/smartctl --version", expected: smartctl_version),
      check("ping runs for uid 100",
            command: "ping -c 1 -W 1 127.0.0.1", expected: "1 received"),
      # The privilege model is declarative rather than something the entrypoint
      # performs, so it is worth asserting that the entrypoint reaches the
      # binary at all.
      check("entrypoint runs telegraf",
            command: "--version", expected: "Telegraf #{@telegraf_version}", via_entrypoint: true),
      check("examples/smartctl.conf loads",
            command: "telegraf --config /examples/smartctl.conf --test",
            expected: "Loaded inputs: smartctl\n", mount: "examples"),
      check("examples/smart.conf loads",
            command: "telegraf --config /examples/smart.conf --test",
            expected: "Loaded inputs: smart\n", mount: "examples"),
      # README.md promises readOnlyRootFilesystem works; this is what keeps that
      # true rather than true once.
      check("telegraf runs on a read-only root filesystem",
            command: "telegraf --config /examples/smartctl.conf --test",
            expected: "Loaded inputs: smartctl\n", mount: "examples", read_only: true),
    ]
  end

  def smartctl_version
    "smartctl #{package("smartmontools").reported_version}"
  end

  def check(description, command:, expected:, via_entrypoint: false, mount: nil, user: nil, read_only: false)
    Check.new(description: description, command: command, expected: expected,
              via_entrypoint: via_entrypoint, mount: mount, user: user, read_only: read_only)
  end

  def run_check(check, platform:)
    output = @commands.capture_merged("docker", *check.docker_arguments(reference: reference, platform: platform))
    check.result_for(output)
  end

  def verify_labels(platform:)
    output = inspect_image("{{json .Config.Labels}}", platform: platform)
    raise Error, "cannot read #{platform} labels from #{reference}" if output.nil?

    actual = JSON.parse(output.strip)
    labels.each do |label|
      found = actual[label.name]
      raise Error, "label #{label.name}: expected #{label.value.inspect}, got #{found.inspect}" unless found == label.value

      puts "  #{label.name}: #{found}"
    end
  end

  def ensure_contains(platform, action:)
    return if contains?(platform)

    raise Error, "#{reference} has no #{platform} image; #{action}"
  end

  # Whether the tag holds an image for this platform — answered by starting
  # one, not by inspecting it.
  #
  # `docker image inspect --platform` exists only from Docker 29, and without
  # it the daemon reports the tag's *host* platform even when the tag is a
  # manifest list. Docker 28 with the containerd image store is exactly that
  # combination, and exactly what the release job builds, so inspection would
  # declare every non-host platform missing. Running the image is the one
  # question every version and image store answers alike; `--pull never` keeps
  # a missing platform a local answer rather than a registry round trip.
  def contains?(platform)
    !@commands.capture("docker", "run", "--rm", "--pull", "never", "--platform", platform.to_s,
                       "--entrypoint", "/bin/true", reference).nil?
  end

  # Labels, per platform where the daemon can do it. Docker 28 cannot: it
  # reports the host platform's config for a manifest list, so there the check
  # reads one platform's labels for every platform. They are built from the
  # same arguments and are expected to agree, so it degrades from "each
  # platform's labels" to "the labels" — weaker, never wrong.
  def inspect_image(format, platform:)
    @commands.capture("docker", "image", "inspect", "--platform", platform.to_s,
                      "--format", format, reference) ||
      @commands.capture("docker", "image", "inspect", "--format", format, reference)
  end

  def ensure_multi_platform_loadable
    return if @platforms.size < 2 || containerd_image_store?

    raise Error, "loading a #{@platforms.size}-platform image into the local daemon requires Docker's " \
                 "containerd image store, which this daemon does not use. Enable it in Docker Desktop " \
                 "(Settings > General > \"Use containerd for pulling and storing images\"), or build one " \
                 "platform at a time with IMAGE_PLATFORMS=#{@platforms.first}"
  end

  def containerd_image_store?
    @commands.capture("docker", "info", "--format", "{{json .DriverStatus}}")
      .to_s.include?("io.containerd.snapshotter")
  end

  # "unknown" rather than an abort, so the image still builds outside a checkout.
  def source_commit
    @commands.capture("git", "rev-parse", "HEAD")&.strip || "unknown"
  end
end

# GitHub Actions workflow linting
class WorkflowLinter
  def initialize(directory: ".github/workflows", tool: "actionlint", commands: CommandRunner.new)
    @directory = directory
    @tool = tool
    @commands = commands
  end

  def lint
    files = workflow_files
    if files.empty?
      puts "no workflows under #{@directory}; nothing to lint"
      return
    end

    # Passed explicitly rather than left to the linter's own discovery, so this
    # cannot pass vacuously when the directory is not where it expects.
    @commands.execute(executable, *files)
  end

  private

  def workflow_files
    Dir.glob(File.join(@directory, "*.{yml,yaml}"))
  end

  def executable
    found = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
      .map { |directory| File.join(directory, @tool) }
      .find { |candidate| File.executable?(candidate) }
    return found if found

    abort "#{@tool} is not installed, so #{@directory} cannot be linted; " \
          "install it with `brew install #{@tool}`"
  end
end

# Docker registry HTTP API, with anonymous pull access
class Registry
  # A digest has to name what `docker pull` resolves: the manifest list for a
  # multi-platform image, else the single manifest.
  MANIFEST_TYPES = [
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
  ].join(", ")

  class Error < StandardError; end

  def initialize(host: "registry-1.docker.io", token_url: "https://auth.docker.io/token",
                 service: "registry.docker.io")
    @host = host
    @token_url = token_url
    @service = service
  end

  # Every tag of a repository, following the API's pagination
  def tags(repository)
    path = "/v2/#{repository}/tags/list?n=1000"
    found = []
    while path
      response = request(Net::HTTP::Get, repository, path)
      raise Error, "listing #{repository} tags: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      found.concat(JSON.parse(response.body).fetch("tags") || [])
      path = response["link"]&.[](%r{<([^>]+)>;\s*rel="next"}, 1)
    end
    found
  end

  # The digest a tag resolves to, or nil when the tag does not exist
  def digest(repository, tag)
    response = request(Net::HTTP::Head, repository, "/v2/#{repository}/manifests/#{tag}", accept: MANIFEST_TYPES)
    return nil if response.is_a?(Net::HTTPNotFound)
    raise Error, "resolving #{repository}:#{tag}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response["docker-content-digest"]
  end

  private

  def request(type, repository, path, accept: nil)
    Net::HTTP.start(@host, 443, use_ssl: true) do |http|
      request = type.new(path)
      request["Authorization"] = "Bearer #{token(repository)}"
      request["Accept"] = accept if accept
      http.request(request)
    end
  end

  def token(repository)
    uri = URI(@token_url)
    uri.query = URI.encode_www_form(service: @service, scope: "repository:#{repository}:pull")
    response = Net::HTTP.get_response(uri)
    raise Error, "token for #{repository}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).fetch("token")
  end
end

# The version-bearing lines of one release line's files: the IMAGE literal, the
# Dockerfile's ARG defaults and the README's published tag
#
# Edits are line-anchored and must each match exactly once, so a file whose
# shape has drifted fails the edit instead of being half rewritten. It only
# ever changes values; a new package or platform is a human's change.
class SourceTree
  Release = Data.define(:telegraf_version, :base_digest, :revision, :packages) do
    def version
      "#{telegraf_version}-alpine.#{revision}"
    end
  end

  class Error < StandardError; end

  PACKAGE = %r{^    Image::Package\.new\(name: "([^"]+)", version: "([^"]+)"\),$}

  def initialize(directory)
    @directory = directory
  end

  def read
    rakefile = file("Rakefile")
    Release.new(telegraf_version: value(rakefile, %r{^  telegraf_version: "([^"]+)",$}),
                base_digest: value(rakefile, %r{^  base_digest: "([^"]+)",$}),
                revision: Integer(value(rakefile, %r{^  revision: (\d+),$})),
                packages: rakefile.scan(PACKAGE).to_h)
  end

  def repository
    value(file("Rakefile"), %r{^  repository: "([^"]+)",$})
  end

  def write(release)
    published = "#{repository}:#{release.version}"
    edit("Rakefile") do |text|
      text = replace(text, %r{^  telegraf_version: "[^"]+",$}, %(  telegraf_version: "#{release.telegraf_version}",))
      text = replace(text, %r{^  base_digest: "[^"]+",$}, %(  base_digest: "#{release.base_digest}",))
      text = replace(text, %r{^  revision: \d+,$}, "  revision: #{release.revision},")
      release.packages.reduce(text) do |result, (name, version)|
        replace(result, %r{^    Image::Package\.new\(name: "#{Regexp.escape(name)}", version: "[^"]+"\),$},
                %(    Image::Package.new(name: "#{name}", version: "#{version}"),))
      end
    end
    edit("Dockerfile") do |text|
      text = replace(text, %r{^ARG TELEGRAF_VERSION=.*$}, "ARG TELEGRAF_VERSION=#{release.telegraf_version}")
      text = replace(text, %r{^ARG BASE_DIGEST=.*$}, "ARG BASE_DIGEST=#{release.base_digest}")
      text = replace(text, %r{^ARG IMAGE_VERSION=.*$}, "ARG IMAGE_VERSION=#{release.version}")
      release.packages.reduce(text) do |result, (name, version)|
        argument = "#{name.upcase.tr("-", "_")}_VERSION"
        replace(result, %r{^ARG #{argument}=.*$}, "ARG #{argument}=#{version}")
      end
    end
    edit("README.md") do |text|
      replace(text, %r{^Published as \*\*`[^`]+`\*\*\.$}, "Published as **`#{published}`**.")
    end
  end

  private

  def file(name)
    File.read(File.join(@directory, name))
  end

  def edit(name)
    path = File.join(@directory, name)
    File.write(path, yield(File.read(path)))
  end

  def value(text, pattern)
    matches = text.scan(pattern)
    raise Error, "expected one match of #{pattern.source} in #{@directory}, found #{matches.size}" unless matches.size == 1

    matches.first.first
  end

  def replace(text, pattern, line)
    count = text.scan(pattern).size
    raise Error, "expected one match of #{pattern.source} in #{@directory}, found #{count}" unless count == 1

    text.sub(pattern) { line }
  end
end

# Tracks every upstream telegraf:<version>-alpine at or above a floor, each on
# a release line of its own: branch `<version>-alpine.x`, released as tags
# `v<version>-alpine.<revision>`
#
# Versions are handled oldest first, one at a time, and the first failure stops
# the run, so a release never overtakes an older one that is still broken.
class Mirror
  class Error < StandardError; end

  def initialize(upstream:, repository:, floor:, platforms:, release_workflow:,
                 registry: Registry.new, commands: CommandRunner.new)
    @upstream = upstream
    @repository = repository
    @floor = Gem::Version.new(floor)
    @platforms = platforms
    @release_workflow = release_workflow
    @registry = registry
    @commands = commands
  end

  # Upstream releases at or above the floor, oldest first. Only exact
  # `X.Y.Z-alpine` tags: the moving `X.Y-alpine` and `alpine` tags alias these,
  # and release candidates are not releases.
  def versions
    @registry.tags(@upstream)
      .filter_map { |tag| tag[%r{\A(\d+\.\d+\.\d+)-alpine\z}, 1] }
      .map { |text| Gem::Version.new(text) }
      .select { |version| version >= @floor }
      .sort
  end

  def plan
    versions.each do |version|
      released = released_revisions(version)
      latest = released.empty? ? "nothing released" : "latest #{tag_for(version, released.max)}"
      puts "#{version}: branch #{branch_for(version)}, #{latest}"
    end
  end

  def sync_all(dry_run:)
    versions.each { |version| sync(version, dry_run: dry_run) }
  end

  def sync(version, dry_run:)
    digest = @registry.digest(@upstream, "#{version}-alpine")
    raise Error, "#{@upstream}:#{version}-alpine has no digest" if digest.nil?

    released = released_revisions(version)
    with_worktree(start_point(version)) do |directory|
      tree = SourceTree.new(directory)
      current = tree.read
      desired = current.with(telegraf_version: version.to_s, base_digest: digest,
                             packages: newest_packages("docker.io/#{@upstream}:#{version}-alpine@#{digest}",
                                                       current.packages.keys))
      if desired == current && released.include?(current.revision)
        up_to_date(version, current, directory, dry_run: dry_run)
      else
        release = desired.with(revision: released.empty? ? 0 : released.max + 1)
        tree.write(release)
        cut_release(version, release, current, directory, dry_run: dry_run)
      end
    end
  end

  private

  def up_to_date(version, current, directory, dry_run:)
    tag = tag_for(version, current.revision)
    puts "#{version}: up to date at #{tag}"
    push_branch(version, directory, dry_run: dry_run) unless remote_branch?(version)
    if @registry.digest(@repository, current.version).nil?
      puts "#{version}: #{@repository}:#{current.version} is not published"
      publish(tag, dry_run: dry_run)
    end
  end

  # Verified before anything is committed, so an upstream release this image
  # cannot handle leaves no tag behind — only a failed run to look at.
  def cut_release(version, release, previous, directory, dry_run:)
    tag = tag_for(version, release.revision)
    puts "#{version}: #{tag} — #{changes(previous, release).join("; ")}"
    @commands.execute("rake", "test", chdir: directory)
    if dry_run
      puts "#{version}: dry run, so #{tag} is verified but not committed, tagged or published"
      return
    end

    # Nothing to commit when the line already holds this release but it was
    # never tagged — main's own literal, for one. The tag then goes on as is.
    unless @commands.capture("git", "status", "--porcelain", chdir: directory).to_s.empty?
      git(directory, "commit", "--all", "--quiet", "--message", commit_message(release, previous))
    end
    git(directory, "tag", "--annotate", tag, "--message", "Telegraf #{version} on Alpine with smartmontools")
    push_branch(version, directory, dry_run: dry_run)
    @commands.execute("git", "push", "origin", "refs/tags/#{tag}", chdir: directory)
    publish(tag, dry_run: dry_run)
  end

  def changes(previous, release)
    found = []
    found << "Telegraf #{previous.telegraf_version} -> #{release.telegraf_version}" \
      if previous.telegraf_version != release.telegraf_version
    found << "base #{previous.base_digest} -> #{release.base_digest}" if previous.base_digest != release.base_digest
    release.packages.each do |name, version|
      found << "#{name} #{previous.packages[name]} -> #{version}" if previous.packages[name] != version
    end
    found.empty? ? ["unreleased commit"] : found
  end

  def commit_message(release, previous)
    "chore: release #{release.version}\n\n" + changes(previous, release).map { |change| "- #{change}\n" }.join
  end

  # Tags pushed with the workflow token start no workflows, so the release is
  # dispatched explicitly — on the tag, which the release environment admits —
  # and waited for, so releases land in order.
  def publish(tag, dry_run:)
    if dry_run
      puts "dry run, so #{tag} is not released"
      return
    end

    dispatched = Time.now.utc
    @commands.execute("gh", "workflow", "run", @release_workflow, "--ref", tag)
    @commands.execute("gh", "run", "watch", dispatched_run(tag, dispatched).to_s, "--exit-status", "--interval", "30")
  end

  def dispatched_run(tag, dispatched)
    60.times do
      output = @commands.capture("gh", "run", "list", "--workflow", @release_workflow, "--event", "workflow_dispatch",
                                 "--branch", tag, "--json", "databaseId,createdAt", "--limit", "10")
      run = JSON.parse(output || "[]").find { |candidate| Time.parse(candidate["createdAt"]) >= dispatched - 10 }
      return run["databaseId"] if run

      sleep 5
    end
    raise Error, "the #{@release_workflow} run for #{tag} never appeared"
  end

  # The newest version of each package Alpine offers for this base, which is
  # what an unpinned `apk add` would install. `apk policy` lists candidates
  # oldest first. Every platform has to agree, as the pins are shared.
  def newest_packages(base, names)
    answers = @platforms.map do |platform|
      output = @commands.capture("docker", "run", "--rm", "--platform", platform.to_s, "--entrypoint", "/bin/sh",
                                 base, "-c", "apk update > /dev/null && apk policy #{names.join(" ")}")
      raise Error, "cannot ask #{base} for #{platform} package versions" if output.nil?

      newest_in(output, names, platform)
    end
    raise Error, "platforms disagree on package versions for #{base}: #{answers.uniq}" unless answers.uniq.size == 1

    answers.first
  end

  def newest_in(policy, names, platform)
    newest = {}
    package = nil
    policy.each_line do |line|
      if (header = line[%r{\A(\S+) policy:\s*\z}, 1])
        package = header
      elsif package && (version = line[%r{\A  (\S+):\s*\z}, 1])
        newest[package] = version
      end
    end
    missing = names - newest.keys
    raise Error, "Alpine offers no #{missing.join(", ")} for #{platform}" unless missing.empty?

    names.to_h { |name| [name, newest[name]] }
  end

  # The existing branch, else this checkout's HEAD — never an older tag, even
  # for a version released before its branch existed. A release is published by
  # dispatching the release workflow on its tag, which needs that tag's copy of
  # the workflow to accept dispatch; only current tooling is sure to. The tags
  # still set the next revision, so nothing is renumbered.
  def start_point(version)
    remote_branch?(version) ? "origin/#{branch_for(version)}" : "HEAD"
  end

  # A detached worktree, so no local branch is created or left behind; a
  # release pushes HEAD to the branch by name.
  def with_worktree(start)
    Dir.mktmpdir("mirror-") do |parent|
      directory = File.join(parent, "tree")
      @commands.execute("git", "worktree", "add", "--quiet", "--detach", directory, start)
      begin
        yield directory
      ensure
        @commands.execute("git", "worktree", "remove", "--force", directory)
      end
    end
  end

  def push_branch(version, directory, dry_run:)
    if dry_run
      puts "dry run, so branch #{branch_for(version)} is not pushed"
      return
    end

    @commands.execute("git", "push", "origin", "HEAD:refs/heads/#{branch_for(version)}", chdir: directory)
  end

  # Revisions taken, by git tag or by published image. Docker Hub counts too:
  # git tags can be deleted, and a revision reused after that would overwrite
  # an image someone may be running.
  def released_revisions(version)
    tagged = (@commands.capture("git", "tag", "--list", "v#{version}-alpine.*") || "")
      .lines.map { |tag| tag.strip.delete_prefix("v") }
    pattern = %r{\A#{Regexp.escape(version.to_s)}-alpine\.(\d+)\z}
    (tagged + published_tags).filter_map { |tag| tag[pattern, 1]&.to_i }.uniq
  end

  def published_tags
    @published_tags ||= @registry.tags(@repository)
  end

  def remote_branch?(version)
    !@commands.capture("git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{branch_for(version)}").nil?
  end

  def git(directory, *)
    @commands.execute("git", *, chdir: directory)
  end

  def branch_for(version)
    "#{version}-alpine.x"
  end

  def tag_for(version, revision)
    "v#{version}-alpine.#{revision}"
  end
end

IMAGE = Image.new(
  repository: "jochen/telegraf",
  telegraf_version: "1.40.2",
  # The manifest list behind telegraf:<version>-alpine. `rake image:versions`
  # prints the tag's current one.
  base_digest: "sha256:d3b22c2bd211fd613e4a87b0ca0f74f20b9a7f2b1be3c6e867e98a6d4a51545e",
  # Bumped when the image changes but Telegraf does not; reset on a version bump.
  revision: 0,
  platforms: ["linux/amd64", "linux/arm64"].map { |text| Image::Platform.parse(text) },
  packages: [
    Image::Package.new(name: "smartmontools", version: "7.5-r0"),
    # Overrides the base's 1.3.2-r0 for CVE-2026-85091.
    Image::Package.new(name: "zlib", version: "1.3.2-r1"),
  ]
).freeze

MIRROR = Mirror.new(
  upstream: "library/telegraf",
  repository: IMAGE.repository,
  # The oldest upstream release tracked, inclusive. Older bases predate what the
  # Dockerfile relies on; lowering this backfills them, oldest first.
  floor: "1.40.0",
  platforms: IMAGE.platforms,
  release_workflow: "release.yml"
)

def selected_image
  requested = ENV.fetch("IMAGE_PLATFORMS", "").split(",").map(&:strip).reject(&:empty?)
  return IMAGE if requested.empty?

  IMAGE.with_platforms(requested.map { |text| Image::Platform.parse(text) })
end

namespace "image" do
  desc "Print the configuration: base image, published tag and pinned package versions"
  task "config" do
    selected_image.describe
  end

  desc "Print the fully qualified image reference"
  task "reference" do
    puts selected_image.reference
  end

  desc "Print the git tag this revision expects to be released under"
  task "release_ref" do
    puts selected_image.release_reference
  end

  desc "Build one multi-platform image and load it into the local daemon"
  task "build" do
    selected_image.build
  end

  desc "Run the verification checks against the locally built image"
  task "verify" do
    selected_image.verify
  end

  desc "Push the already-built local image, without building or verifying"
  task "publish" do
    selected_image.publish
  end

  desc "Build, verify, then push"
  task "push" => %w[build verify publish]

  desc "Report the package versions Alpine currently serves, for bumping the pins"
  task "versions" do
    selected_image.report_available_versions
  end
end

namespace "mirror" do
  desc "List the tracked upstream releases, oldest first, with their release lines"
  task "plan" do
    MIRROR.plan
  end

  desc "Release every tracked upstream version whose base or packages moved (DRY_RUN=true stops before committing)"
  task "sync" do
    MIRROR.sync_all(dry_run: ENV.fetch("DRY_RUN", "false") == "true")
  end
end

desc "Build and verify the image"
task "test" => ["image:build", "image:verify"]

namespace "lint" do
  desc "Lint the GitHub Actions workflows with actionlint"
  task "github" do
    WorkflowLinter.new.lint
  end
end

desc "Run every linter"
task "lint" => "lint:github"
