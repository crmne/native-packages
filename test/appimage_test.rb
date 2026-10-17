# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class AppImageTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-appimage-test-"))
    @payload = @root / "payload"
    @payload.mkpath
    (@payload / "sample-app.desktop").write("[Desktop Entry]\nType=Application\nName=Sample\nExec=sample-app %U\nIcon=sample-app\nCategories=Utility;\n")
    (@payload / "sample-app.svg").write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><circle cx="4" cy="4" r="4"/></svg>')
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "sample-app", "maintainer" => "Test <test@example.org>", "description" => "Sample app", "license" => "MIT",
        "contents" => [
          # A glob source names a directory, as it does for nFPM.
          { "src" => "@PAYLOAD@/sample-ap[p]", "dst" => "/usr/bin", "file_info" => { "mode" => 0o755 } },
          { "src" => "@PAYLOAD@/sample-app.desktop", "dst" => "/usr/share/applications/" },
          { "src" => "@PAYLOAD@/sample-app.svg", "dst" => "/usr/share/icons/hicolor/scalable/apps/sample-app.svg" },
          { "src" => "@PAYLOAD@/sample-app.svg", "dst" => "/usr/share/doc/deb-only.svg", "packager" => "deb" }
        ] },
      "targets" => { "linux-amd64" => { "platform" => "linux", "arch" => "amd64", "libc" => "static", "formats" => ["appimage"],
        "input" => { "local" => "payload", "kind" => "directory" } } } }
    @old_epoch = ENV["SOURCE_DATE_EPOCH"]
    ENV["SOURCE_DATE_EPOCH"] = "1767225600"
  end

  def teardown
    ENV["SOURCE_DATE_EPOCH"] = @old_epoch
    FileUtils.remove_entry(@root)
  end

  def configure
    (@root / "native-packages.yaml").write(YAML.dump(@data))
    NativePackages::Build.new(NativePackages::Configuration.new(@root / "native-packages.yaml"))
  end

  def compile
    build = configure
    missing = %w[cc readelf mksquashfs curl].reject { |tool| build.available?(tool) }
    skip "requires #{missing.join(', ')}" unless missing.empty?
    (@root / "main.c").write("#include <stdio.h>\nint main(void) { puts(\"appimage-ok\"); return 0; }\n")
    build.capture("cc", "-static", @root / "main.c", "-o", @payload / "sample-app")
    build
  end

  def test_builds_a_reproducible_type_2_appimage_without_nfpm
    build = compile
    old_path = ENV["PATH"]
    # The AppImage format must not need nFPM.
    ENV["PATH"] = old_path.split(File::PATH_SEPARATOR).reject { |path| File.executable?(File.join(path, "nfpm")) }.join(File::PATH_SEPARATOR)
    skip "mksquashfs shares a directory with nfpm" unless build.available?("mksquashfs")
    outputs = %w[first second].map do |name|
      capture_io { build.run_build(value: "1.2.3", output: @root / "dist" / name) }
      @root / "dist" / name
    end
    image = outputs.first / "packages/linux-amd64/appimage/sample-app-1.2.3-x86_64.AppImage"
    assert_path_exists image
    assert image.executable?
    assert_equal "AI\x02".b, image.binread(11).byteslice(8, 3)
    assert_equal build.sha256(image),
      build.sha256(outputs.last / "packages/linux-amd64/appimage/sample-app-1.2.3-x86_64.AppImage")
    manifest = JSON.parse((outputs.first / "build.json").read)
    details = manifest.fetch("packages").first.fetch("validation").fetch("appimage")
    assert_equal({ "desktop" => "sample-app.desktop", "icon" => "sample-app.svg", "executable" => "usr/bin/sample-app",
      "runtime" => NativePackages::AppImage::RUNTIME, "libraries" => "host" }, details)
    assert build.verify(outputs.first)
    if build.available?("unsquashfs")
      offset = NativePackages::AppImage.new(@root).runtime(@data["targets"]["linux-amd64"]).size
      listing = build.capture("unsquashfs", "-o", offset, "-l", image)
      %w[AppRun .DirIcon sample-app.desktop sample-app.svg usr/bin/sample-app].each { |path| assert_includes listing, "squashfs-root/#{path}\n" }
      refute_includes listing, "deb-only"
    end
  ensure
    ENV["PATH"] = old_path if old_path
  end

  def test_requires_one_desktop_entry_whose_command_and_icon_are_installed
    build = compile
    @data["nfpm"]["contents"].delete_at(1)
    message = assert_raises(NativePackages::Error) { capture_io { configure.run_build(value: "1.2.3") } }.message
    assert_includes message, "exactly one desktop entry"
    setup_contents = lambda do |desktop|
      (@payload / "sample-app.desktop").write(desktop)
      @data["nfpm"]["contents"].insert(1, { "src" => "@PAYLOAD@/sample-app.desktop", "dst" => "/usr/share/applications/" }) if @data["nfpm"]["contents"].length == 3
      FileUtils.rm_rf(@root / "dist")
      assert_raises(NativePackages::Error) { capture_io { configure.run_build(value: "1.2.3") } }.message
    end
    assert_includes setup_contents.call("[Desktop Entry]\nExec=other\nIcon=sample-app\n"), "which the package does not install"
    assert_includes setup_contents.call("[Desktop Entry]\nExec=sample-app\nIcon=missing\n"), "installs no missing.svg"
    assert build
  end

  def test_validation_limits_appimage_to_supported_linux_binaries
    @data["targets"]["linux-amd64"]["arch"] = "riscv64"
    assert_includes assert_raises(NativePackages::Error) { configure.configuration.validate }.message, "appimage does not support riscv64"
    @data["targets"]["linux-amd64"].merge!("arch" => "amd64", "kind" => "data")
    assert_includes assert_raises(NativePackages::Error) { configure.configuration.validate }.message, "AppImage requires a Linux binary target"
    assert_equal "sample-app-1.2.3-aarch64.AppImage", NativePackages::AppImage.filename("sample-app", "1.2.3", { "arch" => "arm64" })
  end

  UPDATE = "gh-releases-zsync|crmne|sample-app|latest|sample-app-*-x86_64.AppImage.zsync"

  def updating
    @data["release"] = { "repository" => "crmne/sample-app" }
    @data["targets"]["linux-amd64"]["appimage"] = { "update_information" => UPDATE }
  end

  def test_embeds_update_information_and_publishes_a_zsync_file_beside_it
    updating
    build = compile
    skip "requires zsyncmake" unless build.available?("zsyncmake")
    outputs = %w[first second].map do |name|
      capture_io { build.run_build(value: "1.2.3", output: @root / "dist" / name) }
      @root / "dist" / name / "packages/linux-amd64/appimage"
    end
    image = outputs.first / "sample-app-1.2.3-x86_64.AppImage"
    zsync = outputs.first / "sample-app-1.2.3-x86_64.AppImage.zsync"
    assert_equal UPDATE, NativePackages::AppImage.read_update_information(image)
    header = zsync.binread.split("\n\n".b, 2).first.force_encoding(Encoding::UTF_8) + "\n"
    assert_includes header, "Filename: sample-app-1.2.3-x86_64.AppImage\n"
    assert_includes header, "URL: sample-app-1.2.3-x86_64.AppImage\n"
    assert_includes header, "Length: #{image.size}\n"
    assert_includes header, "SHA-1: #{Digest::SHA1.file(image).hexdigest}\n"
    # The same bytes for the same inputs, the .zsync file included.
    assert_equal build.sha256(image), build.sha256(outputs.last / image.basename)
    assert_equal build.sha256(zsync), build.sha256(outputs.last / zsync.basename)
    manifest = JSON.parse((@root / "dist/first/build.json").read)
    record = manifest.fetch("packages").first
    assert_equal "packages/linux-amd64/appimage/sample-app-1.2.3-x86_64.AppImage.zsync", record.fetch("zsync")
    assert_equal UPDATE, record.fetch("validation").fetch("appimage").fetch("update_information")
    assert_includes manifest.fetch("files").keys, record.fetch("zsync")
    assert build.verify(@root / "dist/first")
    # A changed AppImage no longer matches its .zsync file.
    File.open(image, "ab") { |file| file.write("x") }
    error = assert_raises(NativePackages::Error) { NativePackages::AppImage.new(@root).check_zsync(zsync, image) }
    assert_includes error.message, "Length, SHA-1"
  end

  def test_an_appimage_without_update_information_has_none
    build = compile
    capture_io { build.run_build(value: "1.2.3", output: @root / "dist") }
    image = @root / "dist/packages/linux-amd64/appimage/sample-app-1.2.3-x86_64.AppImage"
    assert_nil NativePackages::AppImage.read_update_information(image)
    refute_path_exists Pathname.new("#{image}.zsync")
    refute JSON.parse((@root / "dist/build.json").read).fetch("packages").first.key?("zsync")
  end

  def test_update_information_must_find_this_targets_zsync_file
    updating
    assert configure.configuration.validate
    [
      ["gh-releases-zsync|crmne|other-app|latest|sample-app-*-x86_64.AppImage.zsync", "release.repository is \"crmne/sample-app\""],
      ["gh-releases-zsync|crmne|sample-app|latest|sample-app-*-aarch64.AppImage.zsync", "does not match sample-app-9.8.7-x86_64.AppImage.zsync"],
      ["gh-releases-zsync|crmne|sample-app|latest|sample-app-*-x86_64.AppImage", "use gh-releases-zsync"],
      ["gh-releases-zsync|crmne|sample-app|sample-app-*-x86_64.AppImage.zsync", "use gh-releases-zsync"],
      ["zsync|http://example.org/sample-app.AppImage.zsync", "use gh-releases-zsync"],
      ["zsync|https://example.org/#{'a' * 1024}.zsync", "at most 1023 bytes"],
      ["", "expected a string"]
    ].each do |value, message|
      @data["targets"]["linux-amd64"]["appimage"] = { "update_information" => value }
      error = assert_raises(NativePackages::Error) { configure.configuration.validate }
      assert_includes error.message, message, value
      assert error.message.start_with?("linux-amd64.appimage"), error.message
    end
    @data["targets"]["linux-amd64"]["appimage"] = { "update_information" => "zsync|https://example.org/sample-app.AppImage.zsync" }
    assert configure.configuration.validate
    @data["targets"]["linux-amd64"]["appimage"] = { "update_information" => UPDATE, "sign" => true }
    assert_includes assert_raises(NativePackages::Error) { configure.configuration.validate }.message, "unknown fields sign"
    @data["targets"]["linux-amd64"]["appimage"] = { "update_information" => UPDATE }
    @data["targets"]["linux-amd64"]["formats"] = ["deb"]
    assert_includes assert_raises(NativePackages::Error) { configure.configuration.validate }.message, "only for targets that build an AppImage"
  end

  def test_update_information_goes_into_the_runtimes_update_section
    build = configure
    skip "requires curl" unless build.available?("curl")
    %w[amd64 arm64 386 arm7].each do |arch|
      runtime = NativePackages::AppImage.new(@root).runtime({ "arch" => arch }).binread
      start, length = NativePackages::AppImage.section(runtime, ".upd_info")
      assert_equal 1024, length, arch
      embedded = NativePackages::AppImage.embed(runtime, UPDATE)
      assert_equal runtime.bytesize, embedded.bytesize
      assert_equal UPDATE.b + ("\0".b * (1024 - UPDATE.bytesize)), embedded.byteslice(start, length)
      assert_equal runtime.byteslice(0, start), embedded.byteslice(0, start)
      assert_equal runtime.byteslice(start + length..), embedded.byteslice(start + length..)
      error = assert_raises(NativePackages::Error) { NativePackages::AppImage.embed(runtime, "a" * 1024) }
      assert_includes error.message, "exceeds"
    end
    assert_raises(NativePackages::Error) { NativePackages::AppImage.section("not an ELF file".b, ".upd_info") }
  end
end
