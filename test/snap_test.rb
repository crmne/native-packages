# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class SnapTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-snap-test-"))
    @payload = @root / "payload"
    @payload.mkpath
    (@payload / "sample-app.desktop").write("[Desktop Entry]\nType=Application\nName=Sample\nExec=sample-app %U\nIcon=sample-app\n")
    (@payload / "sample-app.svg").write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><circle cx="4" cy="4" r="4"/></svg>')
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "sample-app", "maintainer" => "Test <test@example.org>", "description" => "Sample app\nIt does sample things.\n",
        "license" => "MIT",
        "contents" => [
          { "src" => "@PAYLOAD@/sample-app", "dst" => "/usr/bin/sample-app", "file_info" => { "mode" => 0o755 } },
          { "src" => "@PAYLOAD@/sample-app.desktop", "dst" => "/usr/share/applications/sample-app.desktop" },
          { "src" => "@PAYLOAD@/sample-app.svg", "dst" => "/usr/share/icons/hicolor/scalable/apps/sample-app.svg" }
        ] },
      "targets" => { "linux-amd64" => { "platform" => "linux", "arch" => "amd64", "libc" => "static", "formats" => ["snap"],
        "input" => { "local" => "payload", "kind" => "directory" } } },
      "snap" => { "base" => "core24", "grade" => "stable", "icon" => "/usr/share/icons/hicolor/scalable/apps/sample-app.svg",
        "apps" => { "sample-app" => { "command" => "usr/bin/sample-app", "desktop" => "usr/share/applications/sample-app.desktop",
          "plugs" => %w[wayland x11 network] } },
        "store" => { "channels" => %w[stable latest/beta] } } }
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
    missing = %w[cc readelf mksquashfs unsquashfs].reject { |tool| build.available?(tool) }
    skip "requires #{missing.join(', ')}" unless missing.empty?
    (@root / "main.c").write("#include <stdio.h>\nint main(void) { puts(\"snap-ok\"); return 0; }\n")
    build.capture("cc", "-static", @root / "main.c", "-o", @payload / "sample-app")
    build
  end

  def snap(output) = output / "packages/linux-amd64/snap/sample-app_1.2.3_amd64.snap"

  def test_builds_a_reproducible_snap_without_snapcraft
    build = compile
    outputs = %w[first second].map do |name|
      capture_io { build.run_build(value: "1.2.3", output: @root / "dist" / name) }
      @root / "dist" / name
    end
    path = snap(outputs.first)
    assert_equal "hsqs".b, path.binread(4)
    assert_equal build.sha256(path), build.sha256(snap(outputs.last))
    listing = build.capture("unsquashfs", "-lls", path)
    %w[meta/snap.yaml meta/gui/sample-app.desktop meta/gui/icon.svg usr/bin/sample-app].each do |file|
      assert_match %r{ root/root .* squashfs-root/#{Regexp.escape(file)}$}, listing
    end
    extracted = @root / "extracted"
    build.capture("unsquashfs", "-d", extracted, path)
    metadata = YAML.safe_load_file(extracted / "meta/snap.yaml")
    assert_equal({ "name" => "sample-app", "version" => "1.2.3", "summary" => "Sample app",
      "description" => "Sample app\nIt does sample things.\n", "license" => "MIT", "base" => "core24", "grade" => "stable",
      "confinement" => "strict", "architectures" => ["amd64"],
      "apps" => { "sample-app" => { "command" => "usr/bin/sample-app", "plugs" => %w[wayland x11 network] } } }, metadata)
    desktop = (extracted / "meta/gui/sample-app.desktop").read
    assert_includes desktop, "Exec=sample-app %U\n"
    assert_includes desktop, "Icon=${SNAP}/meta/gui/icon.svg\n"
    details = JSON.parse((outputs.first / "build.json").read).fetch("packages").first.dig("validation", "snap")
    assert_equal({ "name" => "sample-app", "base" => "core24", "confinement" => "strict", "apps" => ["sample-app"], "libraries" => "base" }, details)
    assert build.verify(outputs.first)
  end

  def test_a_second_app_launches_as_snap_dot_app
    build = compile
    @data["snap"]["apps"]["tool"] = { "command" => "usr/bin/sample-app --tool", "desktop" => "usr/share/applications/sample-app.desktop" }
    build = configure
    capture_io { build.run_build(value: "1.2.3", output: @root / "dist") }
    extracted = @root / "extracted"
    build.capture("unsquashfs", "-d", extracted, snap(@root / "dist"))
    assert_includes (extracted / "meta/gui/tool.desktop").read, "Exec=sample-app.tool %U\n"
  end

  def test_rejects_missing_commands_and_files
    compile
    @data["snap"]["apps"]["sample-app"]["command"] = "usr/bin/missing"
    error = assert_raises(NativePackages::Error) { capture_io { configure.run_build(value: "1.2.3") } }
    assert_includes error.message, "installs no executable usr/bin/missing"
    @data["snap"]["apps"]["sample-app"]["command"] = "usr/bin/sample-app"
    @data["snap"]["icon"] = "/usr/share/missing.png"
    error = assert_raises(NativePackages::Error) { capture_io { configure.run_build(value: "1.2.3") } }
    assert_includes error.message, "installs no /usr/share/missing.png"
  end

  def test_validation
    assert configure.configuration.validate
    [
      [-> { @data["snap"]["name"] = "Sample_App" }, "snap.name"],
      [-> { @data["snap"].delete("base") }, "snap.base"],
      [-> { @data["snap"]["confinement"] = "loose" }, "snap.confinement"],
      [-> { @data["snap"]["summary"] = "x" * 79 }, "snap.summary"],
      [-> { @data["snap"]["apps"] = {} }, "snap.apps"],
      [-> { @data["snap"]["apps"]["sample-app"].delete("command") }, "snap.apps.sample-app.command"],
      [-> { @data["snap"]["apps"]["sample-app"]["extensions"] = ["gnome"] }, "unknown fields extensions"],
      [-> { @data["snap"]["apps"]["sample-app"]["plugs"] = "network" }, "snap.apps.sample-app.plugs"],
      [-> { @data["snap"]["store"] = { "channels" => ["nightly"] } }, "snap.store.channels"],
      [-> { @data["snap"]["parts"] = {} }, "unknown fields parts"],
      [-> { @data.delete("snap") }, "need a top-level snap section"],
      [-> { @data["targets"]["linux-amd64"]["formats"] = ["deb"] }, "no target builds the snap format"],
      [-> { @data["targets"]["linux-amd64"]["arch"] = "386" }, "snap does not support 386"],
      [-> { @data["targets"]["linux-amd64"]["kind"] = "data" }, "Snap requires a Linux binary target"],
      [-> { @data["repositories"] = { "snapcraft" => { "publish" => "manual", "url" => "https://example.org" } } }, "repositories.snapcraft"]
    ].each do |change, message|
      saved = Marshal.load(Marshal.dump(@data))
      change.call
      error = assert_raises(NativePackages::Error) { configure.configuration.validate }
      assert_includes error.message, message
      @data = saved
    end
  end

  def test_publishes_to_the_store_with_snapcraft_and_the_environments_credentials
    build = configure
    bin = @root / "bin"
    bin.mkpath
    log = @root / "snapcraft.log"
    (bin / "snapcraft").write("#!/bin/sh\nprintf '%s|%s\\n' \"$*\" \"${#SNAPCRAFT_STORE_CREDENTIALS}\" >> #{log}\n")
    (bin / "snapcraft").chmod(0o755)
    package = @root / "sample-app_1.2.3_amd64.snap"
    package.write("hsqs")
    snap = NativePackages::Snap.new(build.configuration)
    old_path, old_credentials = ENV["PATH"], ENV["SNAPCRAFT_STORE_CREDENTIALS"]
    ENV["PATH"] = "#{bin}#{File::PATH_SEPARATOR}#{old_path}"
    ENV.delete("SNAPCRAFT_STORE_CREDENTIALS")
    assert_includes assert_raises(NativePackages::Error) { snap.publish([package]) }.message, "set SNAPCRAFT_STORE_CREDENTIALS"
    ENV["SNAPCRAFT_STORE_CREDENTIALS"] = "secret"
    capture_io { snap.publish([package]) }
    assert_equal "upload --release=stable,latest/beta #{package}|6\n", log.read
    @data["snap"].delete("store")
    assert_includes assert_raises(NativePackages::Error) { NativePackages::Snap.new(configure.configuration).publish([package]) }.message,
      "configure snap.store.channels"
  ensure
    ENV["PATH"] = old_path
    old_credentials ? ENV["SNAPCRAFT_STORE_CREDENTIALS"] = old_credentials : ENV.delete("SNAPCRAFT_STORE_CREDENTIALS")
  end
end
