# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"
require "zlib"

class NativePackagesCLITest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-cli-test-"))
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "sample-app", "maintainer" => "Test <test@example.org>", "description" => "Sample app", "license" => "MIT",
        "contents" => [{ "src" => "@PAYLOAD@/sample.txt", "dst" => "/usr/share/sample-app/sample.txt" }] },
      "targets" => { "linux-amd64" => { "kind" => "data", "platform" => "linux", "arch" => "amd64",
        "formats" => %w[deb rpm archlinux apk ipk], "abi" => "test-only x86_64 data package",
        "input" => { "local" => "payload", "kind" => "directory" } } } }
    (@root / "payload").mkpath
    (@root / "payload/sample.txt").write("hello\n")
    @old_epoch = ENV["SOURCE_DATE_EPOCH"]
    ENV["SOURCE_DATE_EPOCH"] = "1767225600"
    configure
  end

  def teardown
    ENV["SOURCE_DATE_EPOCH"] = @old_epoch
    FileUtils.remove_entry(@root)
  end

  def configure
    (@root / "native-packages.yaml").write(YAML.dump(@data))
    @config = NativePackages::Configuration.new(@root / "native-packages.yaml")
    @build = NativePackages::Build.new(@config)
  end

  def need_tools(*tools)
    missing = tools.reject { |tool| @build.available?(tool) }
    skip "requires #{missing.join(', ')}" unless missing.empty?
  end

  def build(**options)
    capture_io { @build.run_build(value: "1.2.3", **options) }
    @root / "dist/packages/1.2.3"
  end

  def test_init_and_help_work_without_an_existing_project
    (@root / "native-packages.yaml").delete
    stdout, = capture_io { NativePackages::CLI.run(@root, ["init", "--name", "sample-app", "--input", "dist/app.tar.gz"]) }
    assert_includes stdout, "Created"
    assert_path_exists @root / "native-packages.yaml"
    refute_path_exists @root / "Gemfile"
    refute_path_exists @root / "packaging/Gemfile"
    refute_path_exists @root / "scripts/packages.rb"
    assert_raises(NativePackages::Error) { NativePackages::Scaffold.new(@root).init }
    assert_includes capture_io { NativePackages::CLI.run(@root, ["--help"]) }.first, "build"
  end

  def test_validation_is_offline_and_never_runs_build_commands
    @data["targets"]["linux-amd64"]["before_build"] = ["ruby", "-e", "File.write('unexpected', 'ran')"]
    @data["targets"]["linux-amd64"]["input"]["local"] = "missing-input"
    configure
    assert @config.validate
    refute_path_exists @root / "unexpected"
    assert_includes capture_io { @build.run_build(value: "1.2.3", dry_run: true) }.first, "missing-input"
    refute_path_exists @root / "dist"
  end

  def test_version_selection_and_configuration_discovery
    assert_raises(NativePackages::Error) { @build.version("1.2.3", "v2.0.0") }
    assert_raises(NativePackages::Error) { @build.version(nil, nil) }
    (@root / "native-packages.yml").write("schema: 1\n")
    assert_raises(NativePackages::Error) { NativePackages::Configuration.discover(@root) }
    assert_equal @root / "native-packages.yaml", NativePackages::Configuration.discover(@root, "native-packages.yaml")
    @data["tool"]["version"] = "0.1.0"
    configure
    assert_includes assert_raises(NativePackages::Error) { @config.validate }.message, "gem install"
  end

  def test_formats_require_explicit_suitable_targets
    target = @data["targets"]["linux-amd64"]
    target["formats"] = ["msix"]
    configure
    assert_raises(NativePackages::Error) { @config.validate }
    target["formats"] = ["srpm"]
    configure
    assert_raises(NativePackages::Error) { @config.validate }
    target["formats"] = ["ipk"]
    target.delete("abi")
    configure
    assert_raises(NativePackages::Error) { @config.validate }
    assert_raises(NativePackages::Error) { @config.select(formats: ["banana"]) }
    assert_raises(NativePackages::Error) { @config.select(ids: ["missing"]) }
  end

  def test_real_linux_formats_and_manifest_verified_publishing
    need_tools "nfpm", "bsdtar"
    output = build
    manifest = @build.verify(output)
    assert_equal %w[apk archlinux deb ipk rpm], manifest.fetch("packages").map { |entry| entry.fetch("format") }.sort
    manifest.fetch("packages").each do |entry|
      package = output / entry.fetch("path")
      assert_path_exists package
      format = entry.fetch("format")
      if %w[deb ipk].include?(format)
        directory = @root / "inspect-#{format}"
        directory.mkpath
        @build.capture("bsdtar", "-xf", package, "-C", directory)
        archive = Pathname.glob(directory / "data.tar*").first
        assert archive, "#{format} contains a data archive"
        assert_equal "hello", @build.capture("bsdtar", "-xOf", archive, "./usr/share/sample-app/sample.txt")
      else
        assert_includes @build.capture("bsdtar", "-tf", package), "usr/share/sample-app/sample.txt"
      end
    end
    paths = manifest.fetch("packages").map { |entry| entry.fetch("path") }
    assert paths.any? { |path| path.end_with?(".pkg.tar.zst") }
    refute paths.any? { |path| path.end_with?(".archlinux") }
    @data["release"] = { "repository" => "example/sample-app" }
    configure
    assert_raises(NativePackages::Error) { @build.verify(output) }
    @data.delete("release")
    configure
    package = output / paths.first
    package.write("tampered")
    assert_raises(NativePackages::Error) { @build.publish(output, ["github"]) }
  end

  def test_partial_builds_aggregate_and_cannot_publish_as_complete
    need_tools "nfpm"
    @data["targets"]["linux-amd64"]["formats"] = %w[deb rpm]
    configure
    first, second, combined = %w[first second combined].map { |name| @root / name }
    build(formats: ["deb"], output: first)
    build(formats: ["rpm"], output: second)
    assert_raises(NativePackages::Error) { @build.verify(first) }
    capture_io { @build.aggregate([first, second], output: combined) }
    assert_equal 2, @build.verify(combined).fetch("packages").length
    assert_raises(NativePackages::Error) { @build.aggregate([first, first], output: @root / "duplicate") }
  end

  def test_binary_architecture_and_libc_are_inspected
    need_tools "cc", "readelf", "nfpm"
    (@root / "app.c").write("int main(void) { return 0; }\n")
    @build.capture("cc", @root / "app.c", "-o", @root / "payload/app")
    arch = { 62 => "amd64", 183 => "arm64" }.fetch((@root / "payload/app").binread(20).byteslice(18, 2).unpack1("S<"))
    target = @data["targets"]["linux-amd64"]
    target.merge!("kind" => "binary", "arch" => arch, "libc" => "glibc", "formats" => %w[deb rpm])
    @data["nfpm"]["contents"] = [{ "src" => "@PAYLOAD@/app", "dst" => "/usr/bin/app" }]
    configure
    manifest = @build.verify(build)
    assert manifest.fetch("packages").all? { |entry| entry.fetch("validation").fetch("glibc_floor") }
    target["libc"] = "musl"
    configure
    assert_includes assert_raises(NativePackages::Error) { build(output: @root / "wrong-libc") }.message, "different libc"
    target["libc"] = "static"
    configure
    assert_includes assert_raises(NativePackages::Error) { build(output: @root / "wrong-static") }.message, "dynamic ELF"
    target["libc"] = "glibc"
    target["arch"] = arch == "amd64" ? "arm64" : "amd64"
    configure
    assert_includes assert_raises(NativePackages::Error) { build(output: @root / "wrong-arch") }.message, "wrong ELF architecture"
  end

  def test_hooks_run_once_per_target_and_inputs_do_not_require_a_release
    need_tools "nfpm"
    @data["targets"]["linux-amd64"]["formats"] = %w[deb rpm]
    @data["targets"]["linux-amd64"]["before_build"] = [RbConfig.ruby, "-e", "File.open('hook-count', 'a') { |f| f.puts ENV.fetch('NATIVE_PACKAGES_VERSION') }"]
    configure
    build
    assert_equal "1.2.3\n", (@root / "hook-count").read
  end

  def test_srpm_contains_real_sources_and_spec
    need_tools "nfpm", "bsdtar"
    (@root / "payload/sample-app.spec").write(<<~SPEC)
      Name: sample-app
      Version: 1.2.3
      Release: 1
      Summary: Sample data package
      License: MIT
      BuildArch: noarch
      Source0: sample.txt
      %description
      Sample data package.
      %prep
      %build
      %install
      mkdir -p %{buildroot}/usr/share/sample-app
      cp %{SOURCE0} %{buildroot}/usr/share/sample-app/sample.txt
      %files
      /usr/share/sample-app/sample.txt
    SPEC
    @data["targets"] = { "source" => { "kind" => "source", "platform" => "linux", "arch" => "all", "formats" => ["srpm"],
      "input" => { "local" => "payload", "kind" => "directory" } } }
    @data["nfpm"]["contents"] = %w[sample-app.spec sample.txt].map { |name| { "src" => "@PAYLOAD@/#{name}", "dst" => "/#{name}" } }
    configure
    output = build
    package = output / @build.verify(output).fetch("packages").first.fetch("path")
    assert package.to_s.end_with?(".src.rpm")
    assert_includes @build.capture("bsdtar", "-tf", package), "sample-app.spec"
    assert_includes @build.capture("bsdtar", "-tf", package), "sample.txt"
  end

  def png(path, size)
    chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
    raw = ("\0".b + ("\x20\x60\x90\xff".b * size)) * size
    path.binwrite("\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [size, size, 8, 6, 0, 0, 0].pack("NNCCCCC")) + chunk.call("IDAT", Zlib.deflate(raw)) + chunk.call("IEND", ""))
  end

  def test_msix_packages_a_real_windows_executable
    need_tools "nfpm", "go", "bsdtar"
    (@root / "main.go").write("package main\nfunc main() {}\n")
    @build.capture("go", "build", "-o", @root / "payload/app.exe", @root / "main.go", env: { "GOOS" => "windows", "GOARCH" => "amd64", "CGO_ENABLED" => "0" })
    png(@root / "payload/logo.png", 150)
    png(@root / "payload/small.png", 44)
    @data["targets"] = { "windows-amd64" => { "kind" => "binary", "platform" => "windows", "arch" => "amd64", "formats" => ["msix"],
      "input" => { "local" => "payload", "kind" => "directory" } } }
    @data["nfpm"]["contents"] = %w[app.exe logo.png small.png].map { |name| { "src" => "@PAYLOAD@/#{name}", "dst" => "/#{name}" } }
    @data["nfpm"]["msix"] = { "publisher" => "CN=NativePackagesTest", "properties" => { "logo" => "logo.png" },
      "applications" => [{ "id" => "App", "executable" => "app.exe", "visual_elements" => {
        "display_name" => "Sample App", "description" => "Sample app", "square150x150_logo" => "logo.png", "square44x44_logo" => "small.png" } }] }
    configure
    output = build
    record = @build.verify(output).fetch("packages").first
    assert_equal "pe", record.fetch("validation").fetch("kind")
    package = output / record.fetch("path")
    assert_includes @build.capture("bsdtar", "-tf", package), "AppxManifest.xml"
    assert_includes @build.capture("bsdtar", "-xOf", package, "AppxManifest.xml"), "CN=NativePackagesTest"
    assert_includes @build.capture("bsdtar", "-tf", package), "app.exe"
  end
end
