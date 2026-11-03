# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"
require_relative "openpgp_helper"

class DnfRepositoryTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-dnf-test-"))
    (@root / "payload").mkpath
    (@root / "payload/sample.txt").write("hello\n")
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "sample-app", "maintainer" => "Test <test@example.org>", "description" => "Sample app", "license" => "MIT",
        "contents" => [{ "src" => "@PAYLOAD@/sample.txt", "dst" => "/usr/share/sample-app/sample.txt" }] },
      "targets" => { "linux-amd64" => { "kind" => "data", "platform" => "linux", "arch" => "amd64", "formats" => %w[rpm],
        "input" => { "local" => "payload", "kind" => "directory" } } },
      "dnf" => { "directory" => "site/rpm", "url" => "https://example.org/rpm", "keep" => 2 } }
    @old_epoch = ENV["SOURCE_DATE_EPOCH"]
    @old_path = ENV["PATH"]
    ENV["SOURCE_DATE_EPOCH"] = "1767225600"
  end

  def teardown
    ENV["SOURCE_DATE_EPOCH"] = @old_epoch
    ENV["PATH"] = @old_path
    ENV.delete(NativePackages::OpenPGP::KEY)
    FileUtils.remove_entry(@root)
  end

  def configure
    (@root / "native-packages.yaml").write(YAML.dump(@data))
    NativePackages::Build.new(NativePackages::Configuration.new(@root / "native-packages.yaml"))
  end

  def build(version)
    skip "requires gpg" unless OpenPGPTestKey.available?
    @data["dnf"]["signing_key"] = OpenPGPTestKey.key.first
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

  # Without createrepo_c installed, a stand-in writes repomd.xml so the rest
  # of the publication can be checked.
  def createrepo
    return if configure.available?("createrepo_c") && ENV["NATIVE_PACKAGES_FAKE_CREATEREPO"].nil?
    bin = @root / "bin"
    bin.mkpath
    (bin / "createrepo_c").write(<<~SH)
      #!/bin/sh
      for last; do :; done
      mkdir -p "$last/repodata"
      ls "$last/packages" > "$last/repodata/repomd.xml"
    SH
    (bin / "createrepo_c").chmod(0o755)
    ENV["PATH"] = "#{bin}#{File::PATH_SEPARATOR}#{@old_path}"
  end

  def test_writes_a_signed_repository_that_keeps_the_newest_versions
    createrepo
    stdout = nil
    %w[1.2.3 1.10.0 1.9.0].each do |version|
      build, output = build(version)
      ENV[NativePackages::OpenPGP::KEY] = OpenPGPTestKey.key.last
      stdout = capture_io { build.publish(output, ["dnf"]) }.first
    end
    repository = @root / "site/rpm"
    assert_equal %w[sample-app-1.10.0-1.x86_64.rpm sample-app-1.9.0-1.x86_64.rpm],
      (repository / "packages").children.map { |path| path.basename.to_s }.sort
    assert_includes stdout, "Removed packages/sample-app-1.2.3-1.x86_64.rpm"
    assert_path_exists repository / "repodata/repomd.xml"
    assert_includes (repository / "repodata/repomd.xml.asc").read, "-----BEGIN PGP SIGNATURE-----"
    assert_includes (repository / "sample-app.asc").read, "-----BEGIN PGP PUBLIC KEY BLOCK-----"
    # nFPM signs no RPM here, so dnf checks the metadata's signature only.
    assert_equal <<~REPO, (repository / "sample-app.repo").read
      [sample-app]
      name=sample-app
      baseurl=https://example.org/rpm
      enabled=1
      repo_gpgcheck=1
      gpgcheck=0
      gpgkey=https://example.org/rpm/sample-app.asc
    REPO
    assert_includes stdout, "sudo curl -fsSLo /etc/yum.repos.d/sample-app.repo https://example.org/rpm/sample-app.repo"
    Dir.mktmpdir("native-packages-dnf-verify-") do |home|
      gpg = ["gpg", "--homedir", home, "--batch", "--status-fd", "1"]
      Open3.capture3(*gpg, "--import", (repository / "sample-app.asc").to_s)
      status = Open3.capture3(*gpg, "--verify", (repository / "repodata/repomd.xml.asc").to_s, (repository / "repodata/repomd.xml").to_s).first
      assert_includes status, "VALIDSIG #{OpenPGPTestKey.key.first}"
      Open3.capture3("gpgconf", "--homedir", home, "--kill", "all")
    end
  end

  def test_reads_the_rpm_header
    _, output = build("1.2.3")
    header = NativePackages::DnfRepository.header(output / "packages/linux-amd64/rpm/sample-app-1.2.3-1.x86_64.rpm")
    assert_equal({ "name" => "sample-app", "version" => "1.2.3", "release" => "1", "epoch" => 0, "arch" => "x86_64",
      "signed" => false }, header.except("sourcerpm"))
    error = assert_raises(NativePackages::Error) { NativePackages::DnfRepository.header(@root / "native-packages.yaml") }
    assert_includes error.message, "not an RPM package"
  end

  def test_validation
    @data["dnf"]["signing_key"] = "a" * 64
    assert configure.configuration.validate
    @data["dnf"]["keep"] = "3"
    assert_includes assert_raises(NativePackages::Error) { configure.configuration.validate }.message, "dnf.keep"
  end

  def test_rpm_version_order
    [%w[1.2.3 1.10.0], %w[1.0~rc1 1.0], %w[1.0 1.0^git1], %w[1.0^git1 1.0.1], %w[1.0a 1.0.1], %w[1.0 1.0.0], %w[2 10], %w[a 1]].each do |older, newer|
      assert_equal(-1, NativePackages::DnfRepository.compare(older, newer), "#{older} < #{newer}")
      assert_equal 1, NativePackages::DnfRepository.compare(newer, older), "#{newer} > #{older}"
    end
    assert_equal 0, NativePackages::DnfRepository.compare("1.01", "1.1")
  end
end
