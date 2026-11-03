# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"
require_relative "openpgp_helper"

class AptRepositoryTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-apt-test-"))
    (@root / "payload").mkpath
    (@root / "payload/sample.txt").write("hello\n")
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "sample-app", "maintainer" => "Test <test@example.org>",
        "description" => "Sample app\n A longer description.", "license" => "MIT",
        "contents" => [{ "src" => "@PAYLOAD@/sample.txt", "dst" => "/usr/share/sample-app/sample.txt" }] },
      "targets" => {
        "linux-amd64" => { "kind" => "data", "platform" => "linux", "arch" => "amd64", "formats" => %w[deb rpm],
          "input" => { "local" => "payload", "kind" => "directory" } },
        "linux-arm64" => { "kind" => "data", "platform" => "linux", "arch" => "arm64", "formats" => %w[deb rpm],
          "input" => { "local" => "payload", "kind" => "directory" } }
      },
      "apt" => { "directory" => "site/apt", "url" => "https://example.org/apt/", "keep" => 2 } }
    @old_epoch = ENV["SOURCE_DATE_EPOCH"]
    ENV["SOURCE_DATE_EPOCH"] = "1767225600"
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

  def signed
    skip "requires gpg" unless OpenPGPTestKey.available?
    fingerprint, secret = OpenPGPTestKey.key
    @data["apt"]["signing_key"] = fingerprint
    ENV[NativePackages::OpenPGP::KEY] = secret
    fingerprint
  end

  def build(version)
    build = configure
    missing = %w[nfpm readelf].reject { |tool| build.available?(tool) }
    skip "requires #{missing.join(', ')}" unless missing.empty?
    begin
      build.nfpm_version
    rescue NativePackages::Error => error
      skip "requires a working nFPM #{NativePackages::Configuration::NFPM_VERSION}: #{error.message}"
    end
    output = @root / "dist" / version
    capture_io { build.run_build(value: version, output: output) }
    [build, output]
  end

  def publish(build, output)
    ENV[NativePackages::OpenPGP::KEY] = OpenPGPTestKey.key.last
    capture_io { build.publish(output, ["apt"]) }.first
  end

  def test_writes_a_signed_repository_that_keeps_the_newest_versions
    fingerprint = signed
    stdout = nil
    %w[1.2.3 1.10.0 1.9.0].each do |version|
      build, output = build(version)
      stdout = publish(build, output)
    end
    refute ENV.key?(NativePackages::OpenPGP::KEY), "the key must not reach later subprocesses"
    repository = @root / "site/apt"
    pool = repository / "pool/main/s/sample-app"
    # 1.10.0 is newer than 1.9.0, which is newer than 1.2.3; keep: 2.
    assert_equal %w[sample-app_1.10.0_amd64.deb sample-app_1.10.0_arm64.deb sample-app_1.9.0_amd64.deb sample-app_1.9.0_arm64.deb],
      pool.children.map { |path| path.basename.to_s }.sort
    assert_includes stdout, "Removed pool/main/s/sample-app/sample-app_1.2.3_amd64.deb"
    dists = repository / "dists/stable"
    packages = (dists / "main/binary-amd64/Packages").read
    stanzas = packages.split("\n\n")
    assert_equal 2, stanzas.length
    first = stanzas.first
    assert first.start_with?("Package: sample-app\nVersion: 1.10.0\nArchitecture: amd64\n"), first
    assert_includes first, "Description: Sample app\n A longer description.\n"
    deb = pool / "sample-app_1.10.0_amd64.deb"
    assert_includes first, "Filename: pool/main/s/sample-app/sample-app_1.10.0_amd64.deb\nSize: #{deb.size}\n"
    assert first.end_with?("SHA256: #{Digest::SHA256.file(deb).hexdigest}"), first
    assert packages.end_with?("\n")
    assert_equal packages, Zlib.gunzip((dists / "main/binary-amd64/Packages.gz").binread)
    release = (dists / "Release").read
    assert_includes release, "Suite: stable\nCodename: stable\nDate: Thu, 01 Jan 2026 00:00:00 UTC\nArchitectures: amd64 arm64\nComponents: main\n"
    packages_file = dists / "main/binary-arm64/Packages"
    assert_includes release, " #{Digest::SHA256.file(packages_file).hexdigest} #{packages_file.size} main/binary-arm64/Packages\n"
    assert_includes (dists / "InRelease").read, "-----BEGIN PGP SIGNED MESSAGE-----"
    assert_includes (dists / "Release.gpg").read, "-----BEGIN PGP SIGNATURE-----"
    assert_equal <<~SOURCES, (repository / "sample-app.sources").read
      Types: deb
      URIs: https://example.org/apt
      Suites: stable
      Components: main
      Signed-By: /etc/apt/keyrings/sample-app.gpg
    SOURCES
    assert_includes stdout, "sudo curl -fsSLo /etc/apt/sources.list.d/sample-app.sources https://example.org/apt/sample-app.sources"
    Dir.mktmpdir("native-packages-apt-verify-") do |home|
      gpg = ["gpg", "--homedir", home, "--batch", "--status-fd", "1"]
      _, = Open3.capture3(*gpg, "--import", (repository / "sample-app.gpg").to_s)
      assert_includes Open3.capture3(*gpg, "--verify", (dists / "InRelease").to_s).first, "VALIDSIG"
      assert_includes Open3.capture3(*gpg, "--verify", (dists / "Release.gpg").to_s, (dists / "Release").to_s).first, "VALIDSIG #{fingerprint[-40..]}"
      Open3.capture3("gpgconf", "--homedir", home, "--kill", "all")
    end
  end

  def test_refuses_to_replace_a_published_package_with_different_bytes
    signed
    build, output = build("1.2.3")
    publish(build, output)
    (@root / "payload/sample.txt").write("changed\n")
    output = @root / "dist/again"
    capture_io { build.run_build(value: "1.2.3", output: output) }
    error = assert_raises(NativePackages::Error) { publish(build, output) }
    assert_includes error.message, "sample-app_1.2.3_amd64.deb is already published with different contents"
  end

  def test_signing_needs_the_configured_key
    signed
    build, output = build("1.2.3")
    ENV.delete(NativePackages::OpenPGP::KEY)
    @data["apt"]["signing_key"] = "0" * 40
    build = configure
    error = assert_raises(NativePackages::Error) { capture_io { build.publish(output, ["apt"]) } }
    assert_includes error.message, "build belongs to another project/configuration"
    other = NativePackages::AptRepository.new(build.configuration)
    error = assert_raises(NativePackages::Error) do
      capture_io { other.publish([output / "packages/linux-amd64/deb/sample-app_1.2.3_amd64.deb"], secret: OpenPGPTestKey.key.last) }
    end
    assert_includes error.message, "GnuPG has no secret key #{'0' * 40}"
  end

  def test_validation
    @data["apt"]["signing_key"] = "a" * 40
    assert configure.configuration.validate
    [
      [-> { @data["apt"]["url"] = "http://example.org/apt" }, "apt.url"],
      [-> { @data["apt"].delete("directory") }, "apt.directory"],
      [-> { @data["apt"]["keep"] = 0 }, "apt.keep"],
      [-> { @data["apt"]["signing_key"] = "ABCD1234" }, "apt.signing_key"],
      [-> { @data["apt"]["suite"] = "Stable Release" }, "apt.suite"],
      [-> { @data["apt"]["key_file"] = "key.asc" }, "unknown fields key_file"],
      [-> { @data["repositories"] = { "apt" => { "publish" => "manual", "url" => "https://example.org" } } }, "repositories.apt"]
    ].each do |change, message|
      saved = Marshal.load(Marshal.dump(@data))
      change.call
      error = assert_raises(NativePackages::Error) { configure.configuration.validate }
      assert_includes error.message, message
      @data = saved
    end
  end

  def test_debian_version_order
    [%w[1.2.3 1.10.0], %w[1.0~rc1 1.0], %w[1.0 1.0a], %w[1.0-1 1.0-2], %w[2.0 1:1.0], %w[1.0~~ 1.0~], %w[1.0 1.0+b1]].each do |older, newer|
      assert_equal(-1, NativePackages::AptRepository.compare(older, newer), "#{older} < #{newer}")
      assert_equal 1, NativePackages::AptRepository.compare(newer, older), "#{newer} > #{older}"
    end
    assert_equal 0, NativePackages::AptRepository.compare("1.0-1", "1.0-1")
  end
end
