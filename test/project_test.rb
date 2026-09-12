# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class NativePackagesTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-test-"))
    (@root / "packaging").mkpath
    @config = { "version" => 1, "name" => "sample-app", "repository" => "example/sample-app", "assets" => {},
      "version_file" => "Cargo.toml", "templates" => { "recipe" => "packaging/recipe.in" } }
    (@root / "Cargo.toml").write("[package]\nname = \"sample-app\"\nversion = \"1.2.3\"\n\n[dependencies]\n")
    (@root / "packaging/recipe.in").write("version=@VERSION@\n")
    (@root / "packaging/repositories.yml").write(YAML.dump("version" => 1, "repositories" => {}))
    configure
    @metadata = { "NAME" => "sample-app", "VERSION" => "1.2.3", "DATE" => "2026-01-01T00:00:00Z", "SOURCE_DATE_EPOCH" => 1_767_225_600 }
  end

  def teardown = FileUtils.remove_entry(@root)

  def configure
    (@root / "packaging/project.yml").write(YAML.dump(@config))
    @project = NativePackages::Project.new(@root)
  end

  def test_tag_must_match_the_application_version
    capture_io { assert_nil @project.check_version("v1.2.3") }
    assert_raises(NativePackages::Error) { @project.check_version("v1.2.4") }
    assert_raises(NativePackages::Error) { @project.check_version("v1.2.3-beta") }
  end

  def test_configuration_validation_requires_no_release
    capture_io { @project.validate }
    @config["templates"] = { "recipe" => "packaging/missing.in" }
    configure
    assert_raises(Errno::ENOENT) { @project.validate }
  end

  def test_stale_recipes_and_wrong_project_outputs_are_rejected
    output = @root / "generated"
    @project.generate(output, @metadata)
    capture_io { @project.check(output) }
    (output / "recipe").write("version=0.0.1\n")
    assert_raises(NativePackages::Error) { @project.check(output) }
    @project.generate(output, @metadata)
    (output / "private-notes").write("not a recipe")
    assert_raises(NativePackages::Error) { @project.check(output) }
    @project.generate(output, @metadata.merge("NAME" => "another-app"))
    assert_raises(NativePackages::Error) { @project.check(output) }
  end

  def test_template_paths_cannot_escape_the_output
    @config["templates"] = { "../outside" => "packaging/recipe.in" }
    configure
    assert_raises(NativePackages::Error) { @project.generate(@root / "generated", @metadata) }
    refute_path_exists @root / "outside"
  end

  def test_repository_client_uses_the_configured_project_name
    entry = { "publish" => "github-pr", "repository" => "example/packages" }
    arguments = nil
    @project.define_singleton_method(:capture) { |*args| arguments = args; "[]" }
    assert_empty @project.repositories.requests(entry)
    assert_includes arguments, "sample-app in:title"
    refute_includes arguments, "hyprmoncfg in:title"
  end

  def test_release_upload_uses_explicit_repository_and_keeps_original_checksums
    output = @root / "assets"
    output.mkpath
    (output / "sample-app_1.2.3_amd64.deb").write("package")
    (output / "packaging-checksums.txt").write("#{@project.sha256(output / 'sample-app_1.2.3_amd64.deb')}  sample-app_1.2.3_amd64.deb\n")
    calls = []
    @project.define_singleton_method(:run) { |*args| calls << args.map(&:to_s) }
    @project.publish_release("v1.2.3", output)
    assert_includes calls.first, "example/sample-app"
    assert_includes calls.first, (output / "packaging-checksums.txt").to_s
    refute_includes calls.first, (output / "checksums.txt").to_s
    assert_raises(NativePackages::Error) { @project.publish_release("v1.2.4", output) }
    (output / "sample-app_1.2.3_amd64.deb").write("changed")
    assert_raises(NativePackages::Error) { @project.publish_release("v1.2.3", output) }
    assert_equal 1, calls.length
  end

  def test_native_binary_architecture_and_glibc_requirements_are_checked
    skip "needs a C compiler and readelf" unless @project.available?("cc") && @project.available?("readelf")
    @config["binary"] = {}
    configure
    payload = @root / "payload"
    payload.mkpath
    (@root / "main.c").write("#include <stdio.h>\nint main(void) { puts(\"test\"); return 0; }\n")
    @project.capture("cc", @root / "main.c", "-o", payload / "app")
    package = {}
    machine = (payload / "app").binread(20).byteslice(18, 2).unpack1("S<")
    arch = machine == 62 ? "amd64" : "arm64"
    @project.runtime_dependencies(payload, arch, package)
    assert package.fetch("overrides").fetch("deb").fetch("depends").any? { |value| value.start_with?("libc6 (>= ") }
    assert_raises(NativePackages::Error) { @project.runtime_dependencies(payload, arch == "amd64" ? "arm64" : "amd64", {}) }
  end

  def test_release_checksums_are_required_for_binary_archives
    @config["assets"] = { "AMD64" => { "file" => "app.tar.gz" } }
    configure
    @project.define_singleton_method(:capture) do |*args, **|
      args.include?("--format=%cI") ? "2026-01-01T00:00:00Z" : "123"
    end
    cache = @project.cache("1.2.3")
    cache.mkpath
    (cache / "app.tar.gz").write("contents")
    (cache / "checksums.txt").write("#{'0' * 64}  app.tar.gz\n")
    assert_raises(NativePackages::Error) { @project.release_metadata("1.2.3") }
    (cache / "checksums.txt").write("#{@project.sha256(cache / 'app.tar.gz')}  app.tar.gz\n")
    assert_equal @project.sha256(cache / "app.tar.gz"), @project.release_metadata("1.2.3").fetch("AMD64_SHA256")
  end

  def test_release_metadata_reads_the_commit_behind_an_annotated_tag
    env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1", "GIT_AUTHOR_NAME" => "Test",
      "GIT_COMMITTER_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.org", "GIT_COMMITTER_EMAIL" => "test@example.org",
      "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z" }
    @project.capture("git", "init", "-b", "main", env: env)
    @project.capture("git", "add", "Cargo.toml", env: env)
    @project.capture("git", "commit", "-m", "Release", env: env)
    @project.capture("git", "tag", "-a", "v1.2.3", "-m", "Release annotation", env: env)
    cache = @project.cache("1.2.3")
    cache.mkpath
    (cache / "checksums.txt").write("")
    metadata = @project.release_metadata("1.2.3")
    assert_equal 1_767_225_600, metadata.fetch("SOURCE_DATE_EPOCH")
    assert_equal "r1.#{@project.capture('git', 'rev-parse', '--short', 'HEAD')}", metadata.fetch("GIT_VERSION")
  end

  def test_release_bundle_contains_only_prepared_recipes
    (@root / "private-source.txt").write("not a release artifact")
    output = @root / "generated"
    @project.generate(output, @metadata)
    assets = @root / "assets"
    capture_io { @project.artifacts(output, output: assets) }
    archive = assets / "sample-app-1.2.3-packaging.tar.xz"
    listing = @project.capture("tar", "-tf", archive)
    assert_includes listing, "recipe"
    assert_includes listing, "release.json"
    refute_includes listing, "private-source"
    assert_includes (assets / "packaging-checksums.txt").read, @project.sha256(archive)
  end

  def test_real_nfpm_packages_from_an_external_configuration
    skip "needs nfpm, cc, bsdtar and readelf" unless %w[nfpm cc bsdtar readelf].all? { |tool| @project.available?(tool) }
    payload = @root / "payload"
    payload.mkpath
    (@root / "app.c").write("int main(void) { return 0; }\n")
    @project.capture("cc", @root / "app.c", "-o", payload / "sample-app")
    machine = (payload / "sample-app").binread(20).byteslice(18, 2).unpack1("S<")
    arch = { 62 => "amd64", 183 => "arm64" }.fetch(machine)
    @config["binary"] = { "architectures" => { arch => "BINARY" }, "nfpm" => "packaging/nfpm.yml" }
    (@root / "packaging/nfpm.yml").write(YAML.dump({
      "maintainer" => "Test <test@example.org>", "description" => "Test application", "license" => "MIT",
      "contents" => [{ "src" => "@PAYLOAD@/sample-app", "dst" => "/usr/bin/sample-app", "file_info" => { "mode" => 0o755 } }]
    }))
    configure
    cache = @project.cache("1.2.3")
    cache.mkpath
    archive = cache / "sample-app.tar.gz"
    @project.capture("tar", "-czf", archive, "-C", payload, "sample-app")
    metadata = @metadata.merge("BINARY_FILE" => archive.basename.to_s, "BINARY_SHA256" => @project.sha256(archive))
    output = @root / "packages"
    output.mkpath
    capture_io { @project.binary_packages(metadata, output) }
    %w[deb rpm].each do |format|
      artifact = output / "sample-app_1.2.3_#{arch}.#{format}"
      assert_path_exists artifact
      destination = @root / "inspect-#{format}"
      destination.mkpath
      @project.capture("bsdtar", "-xf", artifact, "-C", destination)
      if format == "deb"
        data = Pathname.glob(destination / "data.tar*").fetch(0)
        control = Pathname.glob(destination / "control.tar*").fetch(0)
        @project.capture("bsdtar", "-xf", data, "-C", destination)
        assert_includes @project.capture("bsdtar", "-xOf", control, "./control"), "libc6 (>= "
      end
      installed = destination / "usr/bin/sample-app"
      assert_equal @project.sha256(payload / "sample-app"), @project.sha256(installed)
      assert_equal 0o755, installed.stat.mode & 0o777
    end
  end
end
