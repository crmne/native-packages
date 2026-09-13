# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class NativeRecipeTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-recipe-"))
    (@root / "payload").mkpath
    # Header fixture exercises packaging boundaries, not installation or execution.
    pe = "\0".b * 128
    pe[0, 2] = "MZ"
    pe[0x3c, 4] = [64].pack("L<")
    pe[64, 6] = "PE\0\0" + [0x8664].pack("S<")
    (@root / "payload/app.exe").binwrite(pe)
    @command = [RbConfig.ruby, "-rfileutils", "-e", "FileUtils.cp(ARGV[0], ARGV[1])", "@PAYLOAD@/app.exe", "@PACKAGE@"]
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "native-fixture", "maintainer" => "Tests <test@example.org>", "description" => "Fixture", "license" => "MIT" },
      "targets" => { "windows" => { "platform" => "windows", "arch" => "amd64", "formats" => ["inno"],
        "input" => { "kind" => "directory", "local" => "payload" },
        "native" => { "command" => @command, "output" => "@NAME@-@TAG@-windows.exe" } } } }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def builder
    (@root / "native-packages.yaml").write(YAML.dump(@data))
    NativePackages::Build.new(NativePackages::Configuration.new(@root / "native-packages.yaml"))
  end

  def fixture_host
    original = NativePackages::NativeRecipe.method(:host)
    NativePackages::NativeRecipe.define_singleton_method(:host) { "windows" }
    yield
  ensure
    NativePackages::NativeRecipe.define_singleton_method(:host, original)
  end

  def test_native_plan_is_offline_and_validates_platform_and_output
    assert builder.configuration.validate
    assert_includes capture_io { builder.run_build(value: "1.2.3", dry_run: true) }.first, "@PACKAGE@"
    refute_path_exists @root / "dist"
    unless NativePackages::NativeRecipe.host == "windows"
      assert_includes assert_raises(NativePackages::Error) { builder.doctor }.message, "native host"
    end
    @data["targets"]["windows"]["native"]["output"] = "../outside.exe"
    assert_raises(NativePackages::Error) { builder.configuration.validate }
    @data["targets"]["windows"]["native"]["output"] = "fixture.exe"
    @data["targets"]["windows"]["platform"] = "linux"
    assert_raises(NativePackages::Error) { builder.configuration.validate }
  end

  def test_command_output_does_not_depend_on_the_ssh_locale
    source = File.expand_path("../lib", __dir__)
    code = "require 'native_packages'; runner=NativePackages::NativeRecipe.new(Dir.pwd); STDOUT.binmode; print runner.capture(RbConfig.ruby, '-e', 'STDOUT.binmode; STDOUT.write([226,128,166,10].pack(\"C*\"))')"
    output, error, status = Open3.capture3(RbConfig.ruby, "-E", "US-ASCII", "-I", source, "-e", code, binmode: true)
    assert status.success?, error
    assert_equal [226, 128, 166], output.bytes
  end

  def test_native_outputs_share_manifest_verification_and_preserve_payload
    fixture_host do
      build = builder
      original = (@root / "payload/app.exe").binread
      output = @root / "result"
      capture_io { build.run_build(value: "1.2.3", output: output) }
      manifest = build.verify(output)
      assert_equal "pe", manifest.fetch("packages").first.fetch("validation").fetch("kind")
      assert_equal "not-tested", manifest.fetch("packages").first.fetch("validation").fetch("installation")
      assert_equal original, (@root / "payload/app.exe").binread
      assert_raises(NativePackages::Error) { build.run_build(value: "1.2.3", output: output) }
      (output / manifest.fetch("packages").first.fetch("path")).write("changed")
      assert_raises(NativePackages::Error) { build.verify(output) }
    end
  end

  def test_windows_after_package_hook_remains_independent_of_apple_signing
    @data["targets"]["windows"]["after_package"] = [RbConfig.ruby, "-e", "File.open(ARGV[0], 'ab') { |file| file.write('hook') }", "@PACKAGE@"]
    previous = NativePackages::MacosSigning::VARIABLES.to_h { |name| [name, ENV[name]] }
    [false, true].each do |credentials|
      NativePackages::MacosSigning::VARIABLES.each { |name| ENV[name] = credentials ? "not used by Windows" : nil }
      fixture_host do
        build = builder
        output = @root / "hooked-#{credentials}"
        capture_io { build.run_build(value: "1.2.3", output: output) }
        manifest = build.verify(output)
        record = manifest.fetch("packages").first
        assert (output / record.fetch("path")).binread.end_with?("hook")
        refute record.fetch("validation").key?("apple")
      end
    end
  ensure
    previous&.each { |name, value| ENV[name] = value }
  end

  def test_failed_extra_or_modified_outputs_never_publish_a_build
    fixture_host do
      commands = [
        [RbConfig.ruby, "-e", "abort 'failed'", "@PACKAGE@"],
        [RbConfig.ruby, "-e", "File.write(ARGV[0], 'not an installer')", "@PACKAGE@"],
        @command.dup.tap { |cmd| cmd[3] += "; File.write(File.join(File.dirname(ARGV[1]), 'extra'), 'bad')" },
        @command.dup.tap { |cmd| cmd[3] += "; File.write(ARGV[0], 'changed source')" }
      ]
      commands.each_with_index do |command, index|
        @data["targets"]["windows"]["native"]["command"] = command
        output = @root / "rejected-#{index}"
        assert_raises(NativePackages::Error) { capture_io { builder.run_build(value: "1.2.3", output: output) } }
        refute_path_exists output
      end
      assert_equal "MZ", (@root / "payload/app.exe").binread(2)
    end
  end

  def test_native_trees_hash_internal_links_and_reject_escape_or_dangling_links
    skip "symlink fixture requires Unix" if Gem.win_platform?
    recipe = NativePackages::NativeRecipe.new(@root)
    original = recipe.digest(@root / "payload")
    File.symlink("app.exe", @root / "payload/current")
    refute_equal original, recipe.digest(@root / "payload")
    (@root / "outside").write("outside")
    File.symlink("../outside", @root / "payload/escape")
    assert_raises(NativePackages::Error) { recipe.digest(@root / "payload") }
    (@root / "payload/escape").delete
    File.symlink("missing", @root / "payload/dangling")
    assert_raises(NativePackages::Error) { recipe.digest(@root / "payload") }
  end
end
