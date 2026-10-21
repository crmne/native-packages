# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class OmarchyTest < Minitest::Test
  AMD64 = "a" * 64
  ARM64 = "b" * 64

  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-omarchy-test-"))
    @checkout = @root / "omarchy-pkgs"
    (@checkout / "pkgbuilds").mkpath
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "sample-app" }, "targets" => {},
      "release" => { "repository" => "example/sample-app", "checksums" => "SHA256SUMS" },
      "assets" => { "AMD64" => { "file" => "sample-app_@VERSION@_linux_amd64.tar.gz" },
        "ARM64" => { "file" => "sample-app_@VERSION@_linux_arm64.tar.gz" } },
      "templates" => { "arch/sample-app-bin/PKGBUILD" => "packaging/PKGBUILD.in",
        "arch/sample-app-bin/sample-app-bin.install" => "packaging/sample-app.install" } }
    (@root / "packaging").mkpath
    # The AUR template bakes the release into each URL; Omarchy's bot needs pkgver.
    template(<<~'PKGBUILD')
      pkgname=sample-app-bin
      pkgver=@VERSION@
      pkgrel=@PKGREL@
      arch=('x86_64' 'aarch64')
      install="${pkgname}.install"
      source_x86_64=("@AMD64_URL@")
      source_aarch64=("@ARM64_URL@")
      sha256sums_x86_64=('@AMD64_SHA256@')
      sha256sums_aarch64=('@ARM64_SHA256@')
      package() { install -Dm755 sample-app "$pkgdir/usr/bin/sample-app"; }
    PKGBUILD
    (@root / "packaging/sample-app.install").write("post_install() { echo hello; }\n")
    checksums = @root / ".cache/native-packages/releases/example/sample-app/1.2.3/SHA256SUMS"
    checksums.dirname.mkpath
    checksums.write("#{AMD64}  sample-app_1.2.3_linux_amd64.tar.gz\n#{ARM64}  sample-app_1.2.3_linux_arm64.tar.gz\n")
    @old_epoch = ENV["SOURCE_DATE_EPOCH"]
    ENV["SOURCE_DATE_EPOCH"] = "1767225600"
  end

  def teardown
    ENV["SOURCE_DATE_EPOCH"] = @old_epoch
    FileUtils.remove_entry(@root)
  end

  def template(content) = (@root / "packaging/PKGBUILD.in").write(content)

  def configure = (@root / "native-packages.yaml").write(YAML.dump(@data))

  def generate(*arguments)
    configure
    capture_io { NativePackages::CLI.run(@root, ["omarchy-recipe", @checkout.to_s, "--release", "v1.2.3", *arguments]) }
  end

  def refusal(**options)
    configure
    omarchy = NativePackages::Omarchy.new(NativePackages::Configuration.new(@root / "native-packages.yaml"))
    assert_raises(NativePackages::Error) { capture_io { omarchy.recipe(@checkout, release: "v1.2.3", **options) } }.message
  end

  def test_writes_a_recipe_the_omarchy_bot_can_update
    stdout, = generate
    recipe = @checkout / "pkgbuilds/sample-app-bin"
    assert_includes stdout, "Wrote #{recipe}"
    pkgbuild = (recipe / "PKGBUILD").read
    assert_includes pkgbuild, "pkgver=1.2.3\npkgrel=1\n"
    assert_includes pkgbuild, %(source_x86_64=("https://github.com/example/sample-app/releases/download/v${pkgver}/sample-app_${pkgver}_linux_amd64.tar.gz"))
    assert_includes pkgbuild, "sha256sums_aarch64=('#{ARM64}')"
    assert_equal "post_install() { echo hello; }\n", (recipe / "sample-app-bin.install").read
    assert_equal({ "source" => "local", "auto_merge" => true, "release_ring" => "fast", "min_release_age" => "24h",
      "upstream" => { "watch" => { "github" => "example/sample-app", "pattern" => "v(?P<version>[0-9]+(?:\\.[0-9]+)*)" } } },
      JSON.parse((recipe / ".omarchy/package.json").read))
    assert_equal %w[.omarchy/package.json PKGBUILD sample-app-bin.install],
      Pathname.glob(recipe / "**/*", File::FNM_DOTMATCH).select(&:file?).map { |file| file.relative_path_from(recipe).to_s }.sort
    assert_equal ["sample-app-bin"], (@checkout / "pkgbuilds").children.map { |child| child.basename.to_s }
  end

  def test_leaves_an_existing_recipe_to_the_omarchy_bot
    (@checkout / "pkgbuilds/sample-app-bin").mkpath
    assert_includes refusal, "exists; after the first PR Omarchy's bot updates it"
    assert_empty (@checkout / "pkgbuilds/sample-app-bin").children
  end

  def test_requires_an_omarchy_pkgs_checkout_and_a_release
    (@checkout / "pkgbuilds").rmdir
    assert_includes refusal, "not an omarchy-pkgs checkout"
    (@checkout / "pkgbuilds").mkpath
    _, stderr = capture_io { assert_raises(SystemExit) { NativePackages::CLI.run(@root, ["omarchy-recipe", @checkout.to_s]) } }
    assert_includes stderr, "omarchy-recipe requires --release"
  end

  def test_rejects_sources_the_bot_could_not_move
    aur = (@root / "packaging/PKGBUILD.in").read
    template(aur.sub(%(source_x86_64=("@AMD64_URL@")), %(source_x86_64=('@AMD64_URL@'))))
    assert_match(/\Asource_x86_64 leaves a variable unexpanded; use double quotes/, refusal)
    template(aur.sub("pkgrel=", "_version=@VERSION@\npkgrel=").sub(%(source_x86_64=("@AMD64_URL@")),
      %(source_x86_64=("https://github.com/example/sample-app/releases/download/v${_version}/sample-app_${_version}_linux_amd64.tar.gz"))))
    assert_equal "source_x86_64 does not follow pkgver", refusal
    assert_equal [], (@checkout / "pkgbuilds").children
  end

  def test_rejects_assets_missing_from_the_release_checksums
    @data["assets"]["ARM64"]["file"] = "sample-app_@VERSION@_linux_aarch64.tar.gz"
    assert_equal "sample-app_1.2.3_linux_aarch64.tar.gz is not listed in the release checksums", refusal
  end

  def test_picks_the_named_template_when_there_are_several
    @data["templates"]["arch/other-bin/PKGBUILD"] = "packaging/PKGBUILD.in"
    assert_includes refusal, "several -bin templates (sample-app-bin, other-bin)"
    generate("--package", "sample-app-bin")
    assert_path_exists @checkout / "pkgbuilds/sample-app-bin/PKGBUILD"
  end
end
