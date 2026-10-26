# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

# Stands in for SignTool, PowerShell and the Azure CLI while a test runs. A
# signature is a marker appended to the file, which keeps PE and MSI headers.
module FixtureWindowsTools
  MARKER = "\0fixture-authenticode".b

  class << self
    attr_accessor :active, :commands, :publisher, :timestamped, :signed_in, :status
  end

  def self.reset
    self.commands = []
    self.publisher = "Fixture Publisher"
    self.timestamped = true
    self.signed_in = true
    self.status = nil
  end

  def tool(name, directory)
    return super unless FixtureWindowsTools.active
    path = directory / name / NativePackages::WindowsSigning::TOOLS.fetch(name).fetch("file")
    write(path, name)
    path
  end

  def execute(*arguments, env: {})
    return super unless FixtureWindowsTools.active
    FixtureWindowsTools.commands << arguments.map(&:to_s)
    raise NativePackages::Error, "az failed: Please run 'az login'" if arguments.first == "az" && !FixtureWindowsTools.signed_in
    ""
  end

  def available?(name)
    FixtureWindowsTools.active ? true : super
  end

  def signtool(*arguments)
    return super unless FixtureWindowsTools.active
    FixtureWindowsTools.commands << arguments.map(&:to_s)
    files = arguments.drop(arguments.index("/d") + 2)
    files = files.drop(2) if files.first == "/du"
    files.each { |file| File.open(file, "ab") { |handle| handle.write(MARKER) } }
    "Successfully signed: #{files.length}"
  end

  def signatures(paths)
    return super unless FixtureWindowsTools.active
    paths.map do |path|
      signed = File.binread(path).end_with?(MARKER)
      { "path" => path.to_s, "status" => FixtureWindowsTools.status || (signed ? "Valid" : "NotSigned"), "message" => "",
        "publisher" => signed ? FixtureWindowsTools.publisher : nil,
        "subject" => signed ? "CN=#{FixtureWindowsTools.publisher}" : nil, "timestamped" => signed && FixtureWindowsTools.timestamped }
    end
  end
end
NativePackages::WindowsSigning.prepend(FixtureWindowsTools)

class WindowsSigningTest < Minitest::Test
  ENVIRONMENT = {
    "AZURE_SIGNING_ENDPOINT" => "https://weu.codesigning.azure.net/",
    "AZURE_SIGNING_ACCOUNT" => "fixture-account",
    "AZURE_SIGNING_PROFILE" => "fixture-profile"
  }.freeze

  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-windows-signing-"))
    (@root / "payload").mkpath
    (@root / "payload/app.exe").binwrite(pe)
    (@root / "payload/vendor.dll").binwrite(pe + FixtureWindowsTools::MARKER)
    (@root / "payload/README.txt").write("not code")
    msi = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b + ("\0".b * 504)
    (@root / "fixture.msi").binwrite(msi)
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "fixture", "maintainer" => "Tests <test@example.org>", "description" => "Fixture",
        "license" => "MIT", "homepage" => "https://example.org/fixture" },
      "windows" => { "signing" => { "provider" => "azure-artifact-signing", "description" => "Fixture App",
        "publisher" => "Fixture Publisher" } },
      "targets" => { "windows-amd64" => { "platform" => "windows", "arch" => "amd64", "formats" => ["msi"],
        "input" => { "kind" => "directory", "local" => "payload" },
        "native" => { "command" => [RbConfig.ruby, "-e", "File.binwrite(ARGV[1], File.binread(ARGV[0]))", (@root / "fixture.msi").to_s, "@PACKAGE@"],
          "output" => "@NAME@-@TAG@-windows-amd64.msi" } } } }
    FixtureWindowsTools.reset
    FixtureWindowsTools.active = true
  end

  def teardown
    FixtureWindowsTools.active = false
    FileUtils.remove_entry(@root)
  end

  def pe
    data = "\0".b * 128
    data[0, 2] = "MZ"
    data[0x3c, 4] = [64].pack("L<")
    data[64, 6] = "PE\0\0" + [0x8664].pack("S<")
    data
  end

  def configuration
    (@root / "native-packages.yaml").write(YAML.dump(@data))
    NativePackages::Configuration.new(@root / "native-packages.yaml")
  end

  def signer(environment = ENVIRONMENT) = NativePackages::WindowsSigning.new(configuration, environment)

  def windows_host
    original = NativePackages::NativeRecipe.method(:host)
    NativePackages::NativeRecipe.define_singleton_method(:host) { "windows" }
    yield
  ensure
    NativePackages::NativeRecipe.define_singleton_method(:host, original)
  end

  def with_environment(values)
    previous = values.keys.to_h { |name| [name, ENV[name]] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous.each { |name, value| ENV[name] = value }
  end

  def signed_files = FixtureWindowsTools.commands.select { |command| command.include?("sign") }

  def test_configuration_is_checked
    assert configuration.validate
    [{ "signing" => { "provider" => "osslsigncode" } },
     { "signing" => { "provider" => "azure-artifact-signing", "endpoint" => "https://weu.codesigning.azure.net" } },
     { "signing" => { "provider" => "azure-artifact-signing", "description_url" => "http://example.org" } },
     { "signing" => { "provider" => "azure-artifact-signing", "publisher" => " " } },
     { "signing" => "azure" }, { "signer" => {} }, []].each do |windows|
      @data["windows"] = windows
      assert_raises(NativePackages::Error, windows.inspect) { configuration.validate }
    end
    @data.delete("windows")
    assert configuration.validate
    refute signer.configured?
    refute signer.enabled?, "account settings alone never opt a project in"
  end

  def test_absent_settings_leave_builds_unsigned_and_partial_settings_fail
    unsigned = signer({})
    refute unsigned.enabled?
    assert_equal "off: AZURE_SIGNING_ENDPOINT, AZURE_SIGNING_ACCOUNT, AZURE_SIGNING_PROFILE not set", unsigned.state
    assert_nil unsigned.doctor
    unsigned.with_identity { |active| assert_nil active }
    assert_empty FixtureWindowsTools.commands
    error = assert_raises(NativePackages::Error) { signer(ENVIRONMENT.reject { |name, _| name == "AZURE_SIGNING_PROFILE" }).doctor }
    assert_includes error.message, "AZURE_SIGNING_PROFILE"
    error = assert_raises(NativePackages::Error) { signer(ENVIRONMENT.merge("AZURE_SIGNING_ENDPOINT" => "https://example.org/")).doctor }
    assert_includes error.message, "codesigning.azure.net"
    error = assert_raises(NativePackages::Error) { signer(ENVIRONMENT.merge("AZURE_SIGNING_PROFILE" => "../profile")).doctor }
    assert_includes error.message, "AZURE_SIGNING_PROFILE"
  end

  def test_doctor_requires_windows_and_an_azure_cli_sign_in
    unless NativePackages::NativeRecipe.host == "windows"
      assert_includes assert_raises(NativePackages::Error) { signer.doctor }.message, "must run on Windows"
    end
    windows_host do
      assert_nil signer.doctor
      assert_includes FixtureWindowsTools.commands, %w[az account show --output none]
      FixtureWindowsTools.signed_in = false
      assert_includes assert_raises(NativePackages::Error) { signer.doctor }.message, "az login"
      error = assert_raises(NativePackages::Error) { signer(ENVIRONMENT.merge("NATIVE_PACKAGES_SIGNTOOL" => (@root / "missing.exe").to_s)).doctor }
      assert_includes error.message, "NATIVE_PACKAGES_SIGNTOOL"
    end
  end

  def test_sign_windows_signs_timestamps_and_verifies_every_file
    windows_host do
      setup = (@root / "fixture-setup.exe")
      setup.binwrite(pe)
      out, = capture_io { signer.sign_files([setup, @root / "payload/app.exe"]) }
      assert_includes out, "fixture-setup.exe: signed by CN=Fixture Publisher, timestamped"
      command = signed_files.last
      assert_equal %w[sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib], command[1, 9]
      assert_equal ["/d", "Fixture App", "/du", "https://example.org/fixture", setup.to_s, (@root / "payload/app.exe").to_s], command.last(6)
      metadata = JSON.parse(File.read(command[command.index("/dmdf") + 1])) rescue nil
      assert_nil metadata, "the session's metadata file is removed afterwards"
    end
  end

  def test_metadata_names_the_account_and_allows_only_the_azure_cli_credential
    windows_host do
      signer.with_identity do |active|
        metadata = JSON.parse(File.read(active.instance_variable_get(:@metadata)))
        assert_equal ENVIRONMENT.values, metadata.values_at("Endpoint", "CodeSigningAccountName", "CertificateProfileName")
        refute_includes metadata.fetch("ExcludeCredentials"), "AzureCliCredential"
        assert_includes metadata.fetch("ExcludeCredentials"), "EnvironmentCredential"
        assert_includes metadata.fetch("ExcludeCredentials"), "WorkloadIdentityCredential"
      end
    end
  end

  def test_verification_rejects_invalid_untimestamped_or_foreign_signatures
    windows_host do
      file = @root / "payload/app.exe"
      FixtureWindowsTools.timestamped = false
      assert_includes assert_raises(NativePackages::Error) { capture_io { signer.sign_files([file]) } }.message, "timestamped"
      FixtureWindowsTools.reset
      FixtureWindowsTools.publisher = "Somebody Else"
      error = assert_raises(NativePackages::Error) { capture_io { signer.sign_files([file]) } }
      assert_includes error.message, "windows.signing.publisher"
      FixtureWindowsTools.reset
      FixtureWindowsTools.status = "HashMismatch"
      assert_includes assert_raises(NativePackages::Error) { capture_io { signer.sign_files([file]) } }.message, "HashMismatch"
    end
  end

  def test_sign_windows_requires_configuration_settings_and_files
    windows_host do
      assert_includes assert_raises(NativePackages::Error) { signer({}).sign_files([@root / "payload/app.exe"]) }.message, "AZURE_SIGNING_ENDPOINT"
      assert_includes assert_raises(NativePackages::Error) { capture_io { signer.sign_files([@root / "missing.exe"]) } }.message, "not a regular file"
      @data.delete("windows")
      assert_includes assert_raises(NativePackages::Error) { signer.sign_files([@root / "payload/app.exe"]) }.message, "windows.signing"
    end
    assert_empty signed_files
  end

  def test_long_file_lists_are_split_across_signtool_calls
    windows_host do
      directory = @root / ("d" * 200)
      directory.mkpath
      files = 100.times.map { |index| (directory / "binary-#{index}.exe").tap { |path| path.binwrite(pe) } }
      capture_io { signer.sign_files(files) }
      assert_operator signed_files.length, :>, 1
      assert_equal files.map(&:to_s), signed_files.flat_map { |command| command.last(command.length - command.index("https://example.org/fixture") - 1) }
    end
  end

  def test_build_signs_unsigned_input_code_and_the_installer_before_hashing
    windows_host do
      with_environment(ENVIRONMENT) do
        build = NativePackages::Build.new(configuration)
        plan, = capture_io { build.run_build(value: "1.2.3", dry_run: true) }
        assert_equal({ "provider" => "azure-artifact-signing", "state" => "enabled" }, JSON.parse(plan).fetch("windows_signing"))
        original = (@root / "payload/app.exe").binread
        output = @root / "result"
        out, = capture_io { build.run_build(value: "1.2.3", output: output) }
        assert_includes out, "Signed 1 of 2 Windows binaries in the package input."
        payload_signing, package_signing = signed_files
        assert_equal ["app.exe"], [File.basename(payload_signing.last)], "the vendor's signed DLL and text files stay as they are"
        assert_equal "fixture-v1.2.3-windows-amd64.msi", File.basename(package_signing.last)
        assert_equal original, (@root / "payload/app.exe").binread, "only the staged copy is signed"
        manifest = build.verify(output)
        record = manifest.fetch("packages").first
        assert (output / record.fetch("path")).binread.end_with?(FixtureWindowsTools::MARKER), "the hash covers the signed installer"
        assert_equal({ "signature" => "authenticode", "provider" => "azure-artifact-signing", "publisher" => "Fixture Publisher",
          "timestamped" => true }, record.fetch("validation").fetch("windows_signature"))
      end
    end
  end

  def test_build_without_account_settings_stays_unsigned
    windows_host do
      with_environment(ENVIRONMENT.transform_values { nil }) do
        build = NativePackages::Build.new(configuration)
        plan, = capture_io { build.run_build(value: "1.2.3", dry_run: true) }
        assert_match(/\Aoff: /, JSON.parse(plan).fetch("windows_signing").fetch("state"))
        output = @root / "result"
        capture_io { build.run_build(value: "1.2.3", output: output) }
        refute build.verify(output).fetch("packages").first.fetch("validation").key?("windows_signature")
        assert_empty signed_files
      end
    end
  end

  def test_tools_are_pinned_and_overridable
    FixtureWindowsTools.active = false
    Dir.mktmpdir do |directory|
      directory = Pathname.new(directory)
      override = directory / "signtool.exe"
      override.write("tool")
      windows = NativePackages::WindowsSigning.new(configuration, ENVIRONMENT.merge("NATIVE_PACKAGES_SIGNTOOL" => override.to_s, "LOCALAPPDATA" => directory.to_s))
      assert_equal override, windows.tool("signtool", directory)
      archive = directory / "native-packages/windows-signing/microsoft.artifactsigning.client.1.0.128.nupkg"
      archive.dirname.mkpath
      archive.write("tampered")
      error = assert_raises(NativePackages::Error) { windows.tool("dlib", directory) }
      assert_includes error.message, "pinned SHA-256"
      refute_path_exists archive
    end
    NativePackages::WindowsSigning::TOOLS.each_value do |tool|
      assert_match(/\A[0-9a-f]{64}\z/, tool.fetch("sha256"))
    end
  end

  def test_cli_signs_with_the_project_configuration
    windows_host do
      with_environment(ENVIRONMENT) do
        configuration
        capture_io { NativePackages::CLI.run(@root, ["sign-windows", "payload/app.exe"]) }
        assert_equal [(@root / "payload/app.exe").to_s], [signed_files.last.last]
      end
    end
  end
end
