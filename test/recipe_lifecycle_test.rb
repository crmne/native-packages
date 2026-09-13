# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class RecipeLifecycleTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-lifecycle-"))
    @old_epoch = ENV["SOURCE_DATE_EPOCH"]
    ENV["SOURCE_DATE_EPOCH"] = "1767225600"
    (@root / "payload").mkpath
    (@root / "payload/notice.txt").write("fixture\n")
    # A PE header fixture tests the adapter/manifest boundary, not installation.
    pe = "\0".b * 128
    pe[0, 2] = "MZ"
    pe[0x3c, 4] = [64].pack("L<")
    pe[64, 6] = "PE\0\0" + [0x8664].pack("S<")
    (@root / "payload/app.exe").binwrite(pe)
    (@root / "recipe.in").write("package=@NATIVE_FILE@\nhash=@NATIVE_SHA256@\nsource=@SOURCE_SHA256@\n")
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "lifecycle-fixture", "maintainer" => "Tests <test@example.org>", "description" => "Fixture", "license" => "MIT",
        "contents" => [{ "src" => "@PAYLOAD@/notice.txt", "dst" => "/usr/share/lifecycle-fixture/notice.txt" }] },
      "targets" => {
        "linux" => { "platform" => "linux", "arch" => "amd64", "kind" => "data", "formats" => ["deb"],
          "input" => { "kind" => "directory", "local" => "payload" } },
        "windows" => { "platform" => "windows", "arch" => "amd64", "formats" => ["inno"],
          "input" => { "kind" => "directory", "local" => "payload" },
          "native" => { "command" => [RbConfig.ruby, "-rfileutils", "-e", "FileUtils.cp(ARGV[0], ARGV[1])", "@PAYLOAD@/app.exe", "@PACKAGE@"],
            "output" => "lifecycle-fixture-@TAG@-windows.exe" },
          "after_package" => [RbConfig.ruby, "-e", "File.open(ARGV[0], 'ab') { |f| f.write('after-package') }", "@PACKAGE@"] } },
      "assets" => { "NATIVE" => { "file" => "lifecycle-fixture-@TAG@-windows.exe", "local" => "not-built-yet.exe" },
        "SOURCE" => { "file" => "source.txt", "local" => "source.txt" } },
      "templates" => { "recipe.txt" => "recipe.in" } }
    configure
    skip "requires nfpm, tar and xz" unless %w[nfpm tar xz].all? { |tool| @build.available?(tool) }
  end

  def teardown
    ENV["SOURCE_DATE_EPOCH"] = @old_epoch
    FileUtils.remove_entry(@root)
  end

  def configure
    (@root / "native-packages.yaml").write(YAML.dump(@data))
    @build = NativePackages::Build.new(NativePackages::Configuration.new(@root / "native-packages.yaml"))
  end

  def fixture_host
    original = NativePackages::NativeRecipe.method(:host)
    NativePackages::NativeRecipe.define_singleton_method(:host) { "windows" }
    yield
  ensure
    NativePackages::NativeRecipe.define_singleton_method(:host, original)
  end

  def deferred(ids: [], output: @root / "deferred")
    fixture_host { capture_io { @build.run_build(value: "1.2.3", ids: ids, output: output, defer_recipes: true) } }
    output
  end

  def test_separate_checkouts_finalize_recipes_from_completed_native_output
    linux = @root / "linux"
    capture_io { NativePackages::CLI.run(@root, %w[build --version 1.2.3 --target linux --defer-recipes --output linux]) }
    refute_path_exists linux / "recipes"
    Dir.mktmpdir("native-packages-lifecycle-other-") do |directory|
      other = Pathname.new(directory)
      %w[native-packages.yaml recipe.in].each { |name| FileUtils.cp(@root / name, other) }
      FileUtils.cp_r(@root / "payload", other / "payload")
      fixture_host do
        capture_io { NativePackages::CLI.run(other, %w[build --version 1.2.3 --target windows --defer-recipes --output windows]) }
      end
      windows = other / "windows"
      assert_includes assert_raises(NativePackages::Error) { @build.aggregate([linux, windows], output: @root / "unfinalized") }.message, "--finalize-recipes"
      assert_includes assert_raises(NativePackages::Error) { @build.aggregate([linux], output: @root / "incomplete", finalize_recipes: true) }.message, "incomplete target set"
      refute_path_exists @root / "incomplete"
      # Only the finalizer needs external recipe assets. A stale file with the
      # configured native path must not override the verified package output.
      (@root / "source.txt").write("recipe source\n")
      (@root / "not-built-yet.exe").write("stale output from another run")
      complete = @root / "complete"
      capture_io { NativePackages::CLI.run(@root, ["aggregate", linux.to_s, windows.to_s, "--finalize-recipes", "--output", complete.to_s]) }
      manifest = @build.verify(complete)
      assert_equal 2, manifest.fetch("packages").length
      refute manifest.key?("recipes")
      native = manifest.fetch("packages").find { |entry| entry.fetch("target") == "windows" }
      assert (complete / native.fetch("path")).binread.end_with?("after-package")
      recipe = (complete / "recipes/recipe.txt").read
      assert_includes recipe, "hash=#{native.fetch('sha256')}"
      asset = manifest.fetch("inputs").find { |entry| entry["asset"] == "NATIVE" }
      assert_equal native.fetch("sha256"), asset.fetch("sha256")
      assert_equal File.basename(native.fetch("path")), asset.fetch("package")
      refute asset.key?("path"), "a temporary aggregate path must not become persisted provenance"
      assert_includes recipe, "source=#{@build.sha256(@root / 'source.txt')}"
      assert_path_exists complete / "lifecycle-fixture-1.2.3-packaging.tar.xz"
      assert_raises(NativePackages::Error) { @build.aggregate([linux, windows], output: complete, finalize_recipes: true) }
      assert_equal recipe, (complete / "recipes/recipe.txt").read
    end
  end

  def test_deferred_build_cannot_publish_or_drop_its_marker_to_bypass_finalization
    output = deferred
    assert_includes assert_raises(NativePackages::Error) { @build.publish(output, ["github"]) }.message, "recipes are deferred"
    manifest = JSON.parse((output / "build.json").read)
    manifest.delete("recipes")
    (output / "build.json").write(JSON.generate(manifest))
    assert_includes assert_raises(NativePackages::Error) { @build.publish(output, ["github"]) }.message, "missing recipe metadata"
  end

  def test_failed_finalization_keeps_deferred_inputs_and_publishes_no_output
    output = deferred
    complete = @root / "complete"
    original = (output / "build.json").binread
    assert_raises(Errno::ENOENT) { @build.aggregate([output], output: complete, finalize_recipes: true) }
    refute_path_exists complete
    assert_equal original, (output / "build.json").binread
    manifest = @build.verify(output, complete: false)
    package = output / manifest.fetch("packages").first.fetch("path")
    package.write("changed")
    assert_includes assert_raises(NativePackages::Error) { @build.aggregate([output], output: complete, finalize_recipes: true) }.message, "package output changed"
    refute_path_exists complete
  end

  def test_target_builds_do_not_require_aur_tools_but_finalization_does
    @data["templates"] = { "arch/lifecycle-fixture/PKGBUILD" => "recipe.in" }
    configure
    @build.define_singleton_method(:available?) do |tool|
      !%w[makepkg docker].include?(tool) && super(tool)
    end
    fixture_host do
      assert_includes assert_raises(NativePackages::Error) { @build.doctor(ids: ["windows"]) }.message, "AUR metadata needs"
      assert_equal ["windows"], @build.doctor(ids: ["windows"], defer_recipes: true).keys
    end
    output = deferred
    assert_includes assert_raises(NativePackages::Error) { @build.aggregate([output], output: @root / "complete", finalize_recipes: true) }.message, "AUR metadata needs"
    refute_path_exists @root / "complete"
  end

  def test_deferred_asset_hashes_cannot_silently_enter_target_commands
    @data["targets"]["linux"]["before_build"] = [RbConfig.ruby, "-e", "File.write('ran-hook', ARGV[0])", "@NATIVE_SHA256@"]
    configure
    assert_raises(KeyError) { deferred(ids: ["linux"]) }
    refute_path_exists @root / "ran-hook"
    refute_path_exists @root / "deferred"
  end

  def test_deferred_release_builds_still_verify_selected_input_checksums
    @data["release"] = { "repository" => "example/lifecycle-fixture" }
    @data["targets"]["linux"]["input"] = { "release_asset" => "notice.txt", "kind" => "file" }
    configure
    cache = @build.release_cache(@build.configuration.tokens("1.2.3"))
    cache.mkpath
    (cache / "notice.txt").write("release input\n")
    (cache / "checksums.txt").write("#{'0' * 64}  notice.txt\n")
    output = @root / "release"
    assert_includes assert_raises(NativePackages::Error) {
      @build.run_build(release: "v1.2.3", ids: ["linux"], output: output, defer_recipes: true)
    }.message, "checksum mismatch"
    refute_path_exists output
    (cache / "checksums.txt").write("#{@build.sha256(cache / 'notice.txt')}  notice.txt\n")
    capture_io { @build.run_build(release: "v1.2.3", ids: ["linux"], output: output, defer_recipes: true) }
    assert_equal ["linux"], @build.verify(output, complete: false).fetch("targets").keys
  end

  def test_default_builds_still_require_recipe_assets_and_do_not_implicitly_defer
    assert_raises(Errno::ENOENT) { @build.run_build(value: "1.2.3", ids: ["linux"], output: @root / "normal") }
    refute_path_exists @root / "normal"
  end

  def test_mixing_completed_and_deferred_recipes_is_rejected
    windows = deferred(ids: ["windows"], output: @root / "windows")
    (@root / "source.txt").write("source\n")
    (@root / "not-built-yet.exe").write("already published output\n")
    linux = @root / "linux"
    capture_io { @build.run_build(value: "1.2.3", ids: ["linux"], output: linux) }
    assert_includes assert_raises(NativePackages::Error) { @build.aggregate([linux, windows], output: @root / "mixed", finalize_recipes: true) }.message, "do not mix"
    assert_raises(NativePackages::Error) { @build.aggregate([linux], output: @root / "wrong-mode", finalize_recipes: true) }
  end
end
