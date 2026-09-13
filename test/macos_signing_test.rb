# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class MacosSigningTest < Minitest::Test
  class FixtureSigner < NativePackages::MacosSigning
    attr_reader :commands
    attr_accessor :notary_status, :fail_at

    def initialize(root, credentials)
      super
      @commands = []
      @notary_status = "Accepted"
    end

    def available?(_name) = true

    def execute(*arguments)
      @commands << arguments.map(&:to_s)
      raise NativePackages::Error, "fixture failure" if @fail_at && arguments.take(@fail_at.length) == @fail_at
      File.write(arguments.last, "keychain") if arguments.take(2) == %w[security create-keychain]
      File.delete(arguments.last) if arguments.take(2) == %w[security delete-keychain]
      return %Q{1) hash "#{@credentials.fetch('APPLE_SIGNING_IDENTITY')}"} if arguments.take(2) == %w[security find-identity]
      return JSON.generate("status" => @notary_status, "id" => "fixture-submission") if arguments.take(3) == %w[xcrun notarytool submit]
      ""
    end
  end

  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-apple-test-"))
    @credentials = {
      "APPLE_CERTIFICATE_P12" => ["certificate"].pack("m0"),
      "APPLE_CERTIFICATE_PASSWORD" => "private-export-password",
      "APPLE_SIGNING_IDENTITY" => "Developer ID Application: Fixture (TEAM123456)",
      "APPLE_ID" => "fixture@example.org", "APPLE_TEAM_ID" => "TEAM123456",
      "APPLE_APP_PASSWORD" => "private-apple-password"
    }
    @signer = FixtureSigner.new(@root, @credentials)
  end

  def teardown = FileUtils.remove_entry(@root)

  def macos_host
    original = NativePackages::NativeRecipe.method(:host)
    NativePackages::NativeRecipe.define_singleton_method(:host) { "macos" }
    yield
  ensure
    NativePackages::NativeRecipe.define_singleton_method(:host, original)
  end

  def test_missing_credentials_are_inert_but_partial_credentials_fail_before_import
    signer = FixtureSigner.new(@root, {})
    refute signer.enabled?
    assert_nil signer.doctor
    signer.with_identity { |active| assert_nil active }
    assert_empty signer.commands
    signer = FixtureSigner.new(@root, @credentials.reject { |key, _| key == "APPLE_APP_PASSWORD" })
    error = assert_raises(NativePackages::Error) { signer.with_identity { flunk } }
    assert_includes error.message, "APPLE_APP_PASSWORD"
    refute_includes error.message, @credentials["APPLE_CERTIFICATE_PASSWORD"]
    assert_empty signer.commands
  end

  def test_bad_identity_and_base64_fail_before_import
    [@credentials.merge("APPLE_SIGNING_IDENTITY" => "Apple Development: Fixture"),
     @credentials.merge("APPLE_CERTIFICATE_P12" => "not base64!")].each do |credentials|
      signer = FixtureSigner.new(@root, credentials)
      assert_raises(NativePackages::Error) { signer.with_identity { flunk } }
      assert_empty signer.commands
    end
  end

  def payload
    app = @root / "Fixture.app"
    (app / "Contents/MacOS").mkpath
    (app / "Contents/Frameworks/Nested.framework/Versions/A").mkpath
    (app / "Contents/Info.plist").write("fixture")
    (app / "Contents/MacOS/fixture").binwrite(["feedfacf"].pack("H*") + "binary")
    (app / "Contents/Frameworks/Nested.framework/Versions/A/Nested").binwrite(["feedfacf"].pack("H*") + "library")
    (app / "Contents/Resources").mkpath
    (app / "Contents/Resources/model.bin").write("model, not executable code")
    app
  end

  def test_signs_nested_code_inside_out_preserves_entitlements_and_cleans_keychain
    app = payload
    original = NativePackages::NativeRecipe.new(@root).digest(app)
    @signer.with_identity { |signer| signer.sign_payload(app) }
    signed = @signer.commands.select { |cmd| cmd.take(2) == %w[codesign --force] }
    assert_equal [app / "Contents/Frameworks/Nested.framework/Versions/A/Nested",
      app / "Contents/Frameworks/Nested.framework", app / "Contents/MacOS/fixture", app], signed.map { |cmd| Pathname.new(cmd.last).cleanpath }
    assert signed.all? { |cmd| cmd.any? { |arg| arg.start_with?("--preserve-metadata=") && arg.include?("entitlements") } }
    refute signed.any? { |cmd| cmd.include?("--deep") }
    refute @signer.commands.any? { |cmd| cmd.take(2) == %w[security list-keychains] }
    keychain = @signer.commands.find { |cmd| cmd.take(2) == %w[security create-keychain] }.last
    refute_path_exists keychain
    assert_equal original, NativePackages::NativeRecipe.new(@root).digest(app)
  end

  def test_acceptance_requires_staple_and_validation_and_never_leaves_keychain
    package = @root / "fixture.dmg"
    package.write("fixture")
    result = nil
    capture_io { @signer.with_identity { |signer| result = signer.notarize(package) } }
    assert_equal "accepted", result.fetch("notarization")
    assert_equal true, result.fetch("stapled")
    assert_equal "fixture-submission", result.fetch("submission_id")
    phases = @signer.commands.map { |cmd| cmd.take(3) }
    assert_operator phases.index(%w[xcrun notarytool submit]), :<, phases.index(%w[xcrun stapler staple])
    assert_operator phases.index(%w[xcrun stapler staple]), :<, phases.index(%w[xcrun stapler validate])
    assert_equal %w[security delete-keychain], @signer.commands.last.take(2)
  end

  def test_rejection_and_stapling_failure_do_not_report_success_and_clean_credentials
    ["Invalid", "Accepted"].each do |status|
      signer = FixtureSigner.new(@root, @credentials)
      signer.notary_status = status
      signer.fail_at = %w[xcrun stapler validate] if status == "Accepted"
      output = capture_io do
        assert_raises(NativePackages::Error) { signer.with_identity { |active| active.notarize(@root / "fixture.dmg") } }
      end.first
      refute_includes output, "ticket is stapled and validated"
      assert_equal %w[security delete-keychain], signer.commands.last.take(2)
    end
  end

  def test_private_values_in_tool_errors_are_redacted
    signer = NativePackages::MacosSigning.new(@root, @credentials)
    value = @credentials.fetch("APPLE_APP_PASSWORD")
    error = assert_raises(NativePackages::Error) do
      signer.execute(RbConfig.ruby, "-e", "warn ARGV.fetch(0); exit 1", value)
    end
    refute_includes error.message, value
    assert_includes error.message, "[REDACTED]"
  end

  def test_build_signs_before_recipe_runs_hooks_before_notarization_and_hashes_final_bytes
    [false, true].each do |enabled|
      source = payload
      original = NativePackages::NativeRecipe.new(@root).digest(source)
      signer = FixtureSigner.new(@root, enabled ? @credentials : {})
      signer.define_singleton_method(:sign_payload) { |path| (path / "signed-marker").write("signed") }
      signer.define_singleton_method(:notarize) do |path|
        raise "hook has not run" unless path.binread.start_with?("hook")
        path.binwrite("stapled" + path.binread)
        { "notarization" => "accepted", "stapled" => true }
      end
      data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
        "nfpm" => { "name" => "fixture", "maintainer" => "Test <test@example.org>", "description" => "Fixture", "license" => "MIT" },
        "targets" => { "mac" => { "platform" => "macos", "arch" => "arm64", "formats" => ["dmg"],
          "input" => { "kind" => "directory", "local" => "Fixture.app" },
          "native" => { "command" => [RbConfig.ruby, "-e", "abort 'payload signature missing' unless File.exist?(File.join(ARGV[0], 'signed-marker')) == #{enabled}; File.binwrite(ARGV[1], 'koly' + 0.chr * 508)", "@PAYLOAD@", "@PACKAGE@"], "output" => "fixture.dmg" },
          "after_package" => [RbConfig.ruby, "-e", "File.binwrite(ARGV[0], 'hook' + File.binread(ARGV[0]))", "@PACKAGE@"] } } }
      (@root / "native-packages.yaml").write(YAML.dump(data))
      output = @root / "build-#{enabled}"
      macos_host do
        original_new = NativePackages::MacosSigning.method(:new)
        original_doctor = NativePackages::NativeRecipe.instance_method(:doctor)
        original_inspect = NativePackages::NativeRecipe.instance_method(:inspect)
        begin
          NativePackages::MacosSigning.define_singleton_method(:new) { |*_arguments| signer }
          NativePackages::NativeRecipe.define_method(:doctor) { |*_arguments| nil }
          NativePackages::NativeRecipe.define_method(:inspect) { |*_arguments| { "kind" => "macho" } }
          build = NativePackages::Build.new(NativePackages::Configuration.new(@root / "native-packages.yaml"))
          capture_io { build.run_build(value: "1.2.3", output: output) }
          record = build.verify(output).fetch("packages").first
          assert_equal enabled, record.fetch("validation").key?("apple")
          assert (output / record.fetch("path")).binread.start_with?(enabled ? "stapledhook" : "hook")
          assert_equal original, NativePackages::NativeRecipe.new(@root).digest(source)
        ensure
          NativePackages::MacosSigning.define_singleton_method(:new, original_new)
          NativePackages::NativeRecipe.define_method(:doctor, original_doctor)
          NativePackages::NativeRecipe.define_method(:inspect, original_inspect)
        end
      end
    end
  end

  def test_portable_copy_is_private_atomic_and_never_changes_source
    app = payload
    original = NativePackages::NativeRecipe.new(@root).digest(app)
    output = @root / "signed/Fixture.app"
    macos_host do
      capture_io { @signer.prepare_directory(app, output: output) }
    end
    assert_path_exists output / "Contents/MacOS/fixture"
    assert_equal original, NativePackages::NativeRecipe.new(@root).digest(app)
    assert @signer.commands.any? { |cmd| cmd.take(3) == %w[xcrun notarytool submit] }
    assert @signer.commands.any? { |cmd| cmd.take(3) == %w[xcrun stapler validate] }
    assert_raises(NativePackages::Error) { @signer.prepare_directory(app, output: output) }
    @signer.notary_status = "Invalid"
    rejected = @root / "rejected"
    macos_host do
      capture_io { assert_raises(NativePackages::Error) { @signer.prepare_directory(app, output: rejected) } }
    end
    refute_path_exists rejected
    assert_equal original, NativePackages::NativeRecipe.new(@root).digest(app)
  end
end
