# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"
require_relative "openpgp_helper"

class FlatpakRepositoryTest < Minitest::Test
  ID = "org.example.SampleApp"

  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-flatpak-repository-test-"))
    @payload = @root / "payload"
    @payload.mkpath
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "sample-app", "maintainer" => "Test <test@example.org>", "description" => "Sample app", "license" => "MIT",
        "contents" => [{ "src" => "@PAYLOAD@/sample-app", "dst" => "/usr/bin/sample-app", "file_info" => { "mode" => 0o755 } }] },
      "targets" => { "linux-amd64" => { "platform" => "linux", "arch" => "amd64", "libc" => "static", "formats" => ["flatpak"],
        "input" => { "local" => "payload", "kind" => "directory" } } },
      "flatpak" => { "id" => ID, "runtime" => "org.freedesktop.Platform", "runtime_version" => "24.08", "command" => "sample-app",
        "runtime_repo" => "https://dl.flathub.org/repo/flathub.flatpakrepo",
        "repository" => { "directory" => "site/flatpak", "url" => "https://example.org/flatpak", "title" => "Sample" } } }
    @old_epoch = ENV["SOURCE_DATE_EPOCH"]
  end

  def teardown
    ENV["SOURCE_DATE_EPOCH"] = @old_epoch
    ENV.delete(NativePackages::OpenPGP::KEY)
    FileUtils.remove_entry(@root)
  end

  def configure
    (@root / "native-packages.yaml").write(YAML.dump(@data))
    NativePackages::Build.new(NativePackages::Configuration.new(@root / "native-packages.yaml"))
  end

  def build(version, epoch)
    ENV["SOURCE_DATE_EPOCH"] = epoch.to_s
    build = configure
    (@root / "main.c").write("#include <stdio.h>\nint main(void) { puts(\"#{version}\"); return 0; }\n")
    build.capture("cc", "-static", @root / "main.c", "-o", @payload / "sample-app")
    output = @root / "dist" / version
    capture_io { build.run_build(value: version, output: output) }
    [build, output]
  end

  def test_imports_bundles_into_a_signed_repository_with_a_flatpakref
    skip "requires gpg" unless OpenPGPTestKey.available?
    fingerprint, secret = OpenPGPTestKey.key
    @data["flatpak"]["repository"]["signing_key"] = fingerprint
    missing = %w[cc readelf flatpak ostree].reject { |tool| configure.available?(tool) }
    skip "requires #{missing.join(', ')}" unless missing.empty?
    stdout = nil
    [["1.0.0", 1_767_225_600], ["1.1.0", 1_767_312_000], ["1.2.0", 1_767_398_400]].each do |version, epoch|
      build, output = build(version, epoch)
      ENV[NativePackages::OpenPGP::KEY] = secret
      stdout = capture_io { build.publish(output, ["flatpak"]) }.first
    end
    repository = @root / "site/flatpak"
    ref = "app/#{ID}/x86_64/stable"
    log = configure.capture("ostree", "log", "--repo=#{repository}", ref)
    # Bundles carry no history: the ref holds the newest commit alone.
    assert_equal 1, log.scan(/^commit /).length, log
    assert_includes log, "Export org.example.SampleApp"
    assert_includes configure.capture("ostree", "show", "--repo=#{repository}", ref), "Found 1 signature"
    flatpakref = (repository / "#{ID}.flatpakref").read
    assert_includes flatpakref, "[Flatpak Ref]\nName=#{ID}\nBranch=stable\nTitle=Sample\nUrl=https://example.org/flatpak/\n"
    assert_includes flatpakref, "RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo\n"
    assert_match(/^GPGKey=[A-Za-z0-9+\/=]{40,}$/, flatpakref)
    assert_includes (repository / "sample-app.flatpakrepo").read, "[Flatpak Repo]\nTitle=Sample\nUrl=https://example.org/flatpak/\n"
    assert_includes stdout, "flatpak install --user https://example.org/flatpak/#{ID}.flatpakref"
  end

  def test_validation
    @data["flatpak"]["repository"]["signing_key"] = "b" * 40
    assert configure.configuration.validate
    @data["flatpak"]["repository"]["homepage"] = "http://example.org"
    assert_includes assert_raises(NativePackages::Error) { configure.configuration.validate }.message, "flatpak.repository.homepage"
    @data["flatpak"]["repository"].merge!("homepage" => "https://example.org", "keep" => 2)
    assert_includes assert_raises(NativePackages::Error) { configure.configuration.validate }.message, "unknown fields keep"
    @data["flatpak"]["repository"] = { "url" => "https://example.org/flatpak", "signing_key" => "b" * 40 }
    assert_includes assert_raises(NativePackages::Error) { configure.configuration.validate }.message, "flatpak.repository.directory"
  end
end
