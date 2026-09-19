# frozen_string_literal: true

require "English"
require "json"

# Run external commands
class CommandRunner
  include Rake::DSL

  # Print command to console and run
  def execute(*)
    sh(*)
  end

  # Run command, capture stdout and return `nil` on failure
  def capture(*arguments)
    output = IO.popen(arguments, err: File::NULL, &:read)
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
  Check = Data.define(:description, :command, :expected, :via_entrypoint, :mount) do
    def docker_arguments(reference:, platform:)
      arguments = ["run", "--rm", "--platform", platform.to_s]
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

  attr_reader :repository, :telegraf_version, :revision, :platforms, :packages

  def initialize(repository:, telegraf_version:, revision:, platforms:, packages:,
                 commands: CommandRunner.new)
    raise ArgumentError, "an image needs at least one platform" if platforms.empty?
    raise ArgumentError, "an image needs at least one package" if packages.empty?
    raise ArgumentError, "revision must not be negative, got #{revision}" if revision.negative?

    @repository = repository
    @telegraf_version = telegraf_version
    @revision = revision
    @platforms = platforms.freeze
    @packages = packages.freeze
    @commands = commands
    freeze
  end

  def with_platforms(platforms)
    unknown = platforms - @platforms
    raise Error, "#{unknown.join(", ")} is not a platform this image is configured for" unless unknown.empty?

    self.class.new(repository: @repository, telegraf_version: @telegraf_version,
                   revision: @revision, platforms: platforms, packages: @packages,
                   commands: @commands)
  end

  # The semantic version, and the canonical form of everything below. The
  # revision is a prerelease identifier so rebuilds of one Telegraf release
  # order correctly (r.0 < r.1 < r.2); the variant is build metadata, which
  # semver excludes from precedence because it does not change what was built.
  def version
    "#{@telegraf_version}-r.#{@revision}+alpine"
  end

  # Docker's reference parser rejects "+" outright, so build metadata is joined
  # with "-" instead. Git has no such restriction, which is why only the image
  # tag is transliterated and `release_reference` keeps the exact semantic
  # version — read the version off the image's own label rather than trying to
  # recover it from the tag, where that "-" is indistinguishable from the one
  # introducing the prerelease.
  def tag
    version.tr("+", "-")
  end

  def reference
    "#{@repository}:#{tag}"
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

  def publish
    @platforms.each do |platform|
      ensure_contains(platform, action: "run `rake image:build` and `rake image:verify` first")
    end
    @commands.execute("docker", "push", reference)
  end

  def report_available_versions
    names = @packages.map(&:name).join(" ")
    @platforms.each do |platform|
      puts "=== #{platform} ==="
      @commands.execute("docker", "run", "--rm", "--platform", platform.to_s,
                        "--entrypoint", "/bin/sh", base_image,
                        "-c", "apk update > /dev/null && apk policy #{names}")
    end
  end

  def describe
    puts "base image:  #{base_image}"
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
      BuildArgument.new(name: "SMARTMONTOOLS_VERSION", value: package("smartmontools").version),
      BuildArgument.new(name: "NVME_CLI_VERSION", value: package("nvme-cli").version),
      BuildArgument.new(name: "SUDO_VERSION", value: package("sudo").version),
      BuildArgument.new(name: "IMAGE_VERSION", value: version),
      BuildArgument.new(name: "SOURCE_COMMIT", value: source_commit),
    ]
  end

  def labels
    [
      Label.new(name: "org.opencontainers.image.base.name", value: "docker.io/library/#{base_image}"),
      Label.new(name: "org.opencontainers.image.version", value: version),
    ]
  end

  # Image checks
  def checks
    smartctl_version = "smartctl #{package("smartmontools").reported_version}"
    nvme_version = "nvme version #{package("nvme-cli").reported_version}"
    [
      check("Telegraf version",
            command: "telegraf --version", expected: "Telegraf #{@telegraf_version}"),
      check("smartctl present",
            command: "smartctl --version", expected: smartctl_version),
      check("smartctl supports JSON output",
            command: "smartctl --json --version", expected: '"json_format_version"'),
      check("nvme-cli present",
            command: "nvme version", expected: nvme_version),
      check("inputs.smartctl path: sudo smartctl",
            command: "su telegraf -s /bin/sh -c 'sudo -n /usr/sbin/smartctl --version'",
            expected: smartctl_version),
      check("inputs.smartctl path: sudo nvme",
            command: "su telegraf -s /bin/sh -c 'sudo -n /usr/sbin/nvme version'",
            expected: nvme_version),
      check("inputs.smart path: sudo smartctl",
            command: "su telegraf -s /bin/sh -c 'sudo -n /usr/bin/smartctl --version'",
            expected: smartctl_version),
      check("inputs.smart path: sudo nvme",
            command: "su telegraf -s /bin/sh -c 'sudo -n /usr/bin/nvme version'",
            expected: nvme_version),
      check("entrypoint drops to the telegraf user",
            command: "id", expected: "uid=100(telegraf)", via_entrypoint: true),
      check("examples/smartctl.conf loads",
            command: "telegraf --config /examples/smartctl.conf --test",
            expected: "Loaded inputs: smartctl\n", mount: "examples"),
      check("examples/smart.conf loads",
            command: "telegraf --config /examples/smart.conf --test",
            expected: "Loaded inputs: smart\n", mount: "examples"),
    ]
  end

  private

  def check(description, command:, expected:, via_entrypoint: false, mount: nil)
    Check.new(description: description, command: command, expected: expected,
              via_entrypoint: via_entrypoint, mount: mount)
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

IMAGE = Image.new(
  repository: "jochen/telegraf",
  telegraf_version: "1.40.0",
  # Bumped when the image changes but Telegraf does not; reset on a version bump.
  revision: 0,
  platforms: ["linux/amd64", "linux/arm64"].map { |text| Image::Platform.parse(text) },
  packages: [
    Image::Package.new(name: "smartmontools", version: "7.5-r0"),
    Image::Package.new(name: "nvme-cli", version: "2.16-r1"),
    Image::Package.new(name: "sudo", version: "1.9.17_p2-r0"),
  ]
).freeze

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
