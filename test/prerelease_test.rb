# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class PrereleasePackagingTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-preview-"))
    (@root / "payload").mkpath
    (@root / "payload/notice.txt").write("test data\n")
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "preview-fixture", "maintainer" => "Tests <test@example.org>", "description" => "Fixture", "license" => "MIT",
        "contents" => [{ "src" => "@PAYLOAD@/notice.txt", "dst" => "/usr/share/preview-fixture/notice.txt" }] },
      "targets" => { "linux" => { "platform" => "linux", "arch" => "amd64", "kind" => "data", "formats" => %w[deb rpm],
        "input" => { "kind" => "directory", "local" => "payload" } } },
      "release" => { "repository" => "example/preview-fixture" } }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def builder
    (@root / "native-packages.yaml").write(YAML.dump(@data))
    NativePackages::Build.new(NativePackages::Configuration.new(@root / "native-packages.yaml"))
  end

  def test_prereleases_require_explicit_opt_in_and_preserve_strict_legacy_versions
    assert_raises(NativePackages::Error) { builder.version("1.2.3-alpha.1", nil) }
    @data["release"]["prereleases"] = true
    build = builder
    %w[alpha beta rc].each { |channel| assert_equal "1.2.3-#{channel}.2", build.version("v1.2.3-#{channel}.2", nil) }
    %w[1.2.3-alpha.0 1.2.3-alpha.01 1.2.3-preview.1 1.2.3-alpha.1+private 01.2.3-alpha.1].each do |version|
      assert_raises(NativePackages::Error) { build.version(version, nil) }
    end
    assert_raises(NativePackages::Error) { build.project.version_arg("1.2.3-alpha.1") }
    assert_raises(NativePackages::Error) { build.version("1.2.3-alpha.1", "v1.2.3-alpha.2") }
    @data["release"]["prereleases"] = "true"
    assert_raises(NativePackages::Error) { builder.configuration.validate }
  end

  def test_unreviewed_formats_and_downstream_recipes_are_rejected_before_build
    @data["release"]["prereleases"] = true
    @data["targets"]["linux"]["formats"] = %w[deb archlinux]
    assert_includes assert_raises(NativePackages::Error) { builder.run_build(value: "1.2.3-alpha.1", dry_run: true) }.message, "deb, rpm, dmg and inno"
    @data["targets"]["linux"]["formats"] = ["deb"]
    (@root / "recipe.txt").write("@VERSION@\n")
    @data["templates"] = { "recipe.txt" => "recipe.txt" }
    assert_raises(NativePackages::Error) { builder.run_build(value: "1.2.3-alpha.1", dry_run: true) }
    refute_path_exists @root / "dist"
  end

  def test_real_deb_rpm_keep_preview_version_and_verify_before_upload
    @data["release"]["prereleases"] = true
    build = builder
    skip "requires nfpm and bsdtar" unless %w[nfpm bsdtar].all? { |tool| build.available?(tool) }
    output = @root / "preview"
    capture_io { build.run_build(value: "1.2.3-alpha.1", output: output) }
    manifest = build.verify(output)
    assert_equal "1.2.3-alpha.1", manifest.fetch("version")
    packages = manifest.fetch("packages").to_h { |entry| [entry.fetch("format"), output / entry.fetch("path")] }
    assert_includes packages.fetch("rpm").basename.to_s, "1.2.3~alpha.1"
    control = @root / "control"
    control.mkpath
    build.capture("bsdtar", "-xf", packages.fetch("deb"), "-C", control)
    archive = Pathname.glob(control / "control.tar*").fetch(0)
    assert_includes build.capture("bsdtar", "-xOf", archive, "./control"), "Version: 1.2.3~alpha.1"
    calls = []
    marked = "false"
    build.define_singleton_method(:capture) { |*args, **| calls << args; marked }
    build.define_singleton_method(:run) { |*args, **| calls << args }
    assert_includes assert_raises(NativePackages::Error) { build.publish(output, ["github"]) }.message, "marked prerelease"
    refute calls.any? { |args| args.include?("upload") }
    marked = "true"
    build.publish(output, ["github"])
    upload = calls.find { |args| args.include?("upload") }
    assert_equal "v1.2.3-alpha.1", upload[3]
    packages.fetch("deb").write("tampered")
    calls.clear
    assert_raises(NativePackages::Error) { build.publish(output, ["github"]) }
    assert_empty calls
  end
end
