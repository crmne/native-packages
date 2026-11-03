# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class FlatpakTest < Minitest::Test
  ID = "org.example.SampleApp"

  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-flatpak-test-"))
    @payload = @root / "payload"
    @payload.mkpath
    (@payload / "sample-app.desktop").write("[Desktop Entry]\nType=Application\nName=Sample\nExec=sample-app %U\nIcon=sample-app\nCategories=Utility;\n")
    (@payload / "sample-app.svg").write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><circle cx="4" cy="4" r="4"/></svg>')
    (@root / "packaging").mkpath
    (@root / "packaging/sample.metainfo.xml").write(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <component type="desktop-application">
        <id>#{ID}</id>
        <name>Sample</name>
        <summary>Sample app</summary>
        <metadata_license>CC0-1.0</metadata_license>
        <launchable type="desktop-id">#{ID}.desktop</launchable>
      </component>
    XML
    @data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "sample-app", "maintainer" => "Test <test@example.org>", "description" => "Sample app", "license" => "MIT",
        "contents" => [
          { "src" => "@PAYLOAD@/sample-app", "dst" => "/usr/bin/sample-app", "file_info" => { "mode" => 0o755 } },
          { "src" => "@PAYLOAD@/sample-app.desktop", "dst" => "/usr/share/applications/" },
          { "src" => "@PAYLOAD@/sample-app.svg", "dst" => "/usr/share/icons/hicolor/scalable/apps/sample-app.svg" },
          { "src" => "@PAYLOAD@/sample-app.svg", "dst" => "/etc/deb-only.svg", "packager" => "deb" }
        ] },
      "targets" => { "linux-amd64" => { "platform" => "linux", "arch" => "amd64", "libc" => "static", "formats" => ["flatpak"],
        "input" => { "local" => "payload", "kind" => "directory" } } },
      "flatpak" => { "id" => ID, "runtime" => "org.freedesktop.Platform", "runtime_version" => "24.08", "sdk" => "org.freedesktop.Sdk",
        "command" => "sample-app", "metainfo" => "packaging/sample.metainfo.xml",
        "finish_args" => ["--socket=wayland", "--share=network", "--talk-name=org.freedesktop.Notifications"] } }
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
    missing = %w[cc readelf flatpak].reject { |tool| build.available?(tool) }
    skip "requires #{missing.join(', ')}" unless missing.empty?
    (@root / "main.c").write("#include <stdio.h>\nint main(void) { puts(\"flatpak-ok\"); return 0; }\n")
    build.capture("cc", "-static", @root / "main.c", "-o", @payload / "sample-app")
    build
  end

  def bundle(output) = output / "packages/linux-amd64/flatpak/sample-app-1.2.3-x86_64.flatpak"

  def test_builds_a_reproducible_commit_without_nfpm_or_flatpak_builder
    build = compile
    old_path = ENV["PATH"]
    ENV["PATH"] = old_path.split(File::PATH_SEPARATOR).reject { |path| File.executable?(File.join(path, "nfpm")) }.join(File::PATH_SEPARATOR)
    skip "flatpak shares a directory with nfpm" unless build.available?("flatpak")
    outputs = %w[first second].map do |name|
      capture_io { build.run_build(value: "1.2.3", output: @root / "dist" / name) }
      @root / "dist" / name
    end
    path = bundle(outputs.first)
    assert path.binread(8).start_with?("flatpak\0".b)
    # The bundle records when it was written; the commit inside does not.
    commits = outputs.map { |output| JSON.parse((output / "build.json").read).fetch("packages").first.dig("validation", "flatpak", "commit") }
    assert_match(/\A\h{64}\z/, commits.first)
    assert_equal commits.first, commits.last
    assert_includes path.binread, [commits.first].pack("H*")
    bytes = path.binread
    assert_includes bytes, "app/#{ID}/x86_64/stable".b
    # build-finish wrote the command and permissions, and nothing from a
    # runtime installed on this host.
    metadata = bytes[/\[Application\].*?(?=\0)/m]
    assert_includes metadata, "runtime=org.freedesktop.Platform/x86_64/24.08\n"
    assert_includes metadata, "sdk=org.freedesktop.Sdk/x86_64/24.08\n"
    assert_includes metadata, "command=sample-app\n"
    assert_includes metadata, "sockets=wayland;\n"
    assert_includes metadata, "shared=network;\n"
    assert_includes metadata, "org.freedesktop.Notifications=talk\n"
    refute_includes metadata, "kdeglobals"
    manifest = JSON.parse((outputs.first / "build.json").read)
    details = manifest.fetch("packages").first.fetch("validation").fetch("flatpak")
    assert_equal({ "desktop" => "#{ID}.desktop", "icon" => ID, "metainfo" => "#{ID}.metainfo.xml", "id" => ID, "branch" => "stable",
      "commit" => commits.first, "runtime" => "org.freedesktop.Platform//24.08", "command" => "sample-app", "libraries" => "runtime" }, details)
    assert build.verify(outputs.first)
  ensure
    ENV["PATH"] = old_path if old_path
  end

  def test_exports_the_desktop_entry_icon_and_metainfo_under_the_app_id
    build = compile
    skip "requires ostree" unless build.available?("ostree")
    capture_io { build.run_build(value: "1.2.3", output: @root / "dist") }
    Dir.mktmpdir("native-packages-flatpak-import-") do |directory|
      repository = Pathname.new(directory) / "repository"
      build.capture("ostree", "init", "--mode=archive-z2", "--repo=#{repository}")
      build.capture("flatpak", "build-import-bundle", "--no-update-summary", repository, bundle(@root / "dist"))
      checkout = Pathname.new(directory) / "checkout"
      build.capture("ostree", "checkout", "--repo=#{repository}", "--user-mode", "app/#{ID}/x86_64/stable", checkout)
      desktop = checkout / "files/share/applications/#{ID}.desktop"
      assert_includes desktop.read, "Icon=#{ID}\n"
      assert_includes desktop.read, "Exec=sample-app %U\n"
      assert_path_exists checkout / "files/share/icons/hicolor/scalable/apps/#{ID}.svg"
      assert_path_exists checkout / "files/share/metainfo/#{ID}.metainfo.xml"
      assert_path_exists checkout / "export/share/applications/#{ID}.desktop"
      assert_path_exists checkout / "export/share/icons/hicolor/scalable/apps/#{ID}.svg"
      assert (checkout / "files/bin/sample-app").executable?
      refute_path_exists checkout / "files/share/applications/sample-app.desktop"
      refute_path_exists checkout / "files/etc"
    end
  end

  # Installs the bundle into a throwaway user installation and runs it, with
  # a system runtime this host already has, so no download is needed. (The
  # throwaway installation hides the user's own.)
  def test_the_bundle_installs_and_runs
    build = compile
    runtime = build.capture("flatpak", "list", "--system", "--runtime", "--columns=ref").lines.map(&:strip)
      .find { |ref| ref.match?(%r{\A(?:org\.freedesktop|org\.gnome|org\.kde)\.Platform/x86_64/}) }
    skip "requires an installed Platform runtime" unless runtime && RUBY_PLATFORM.start_with?("x86_64")
    name, _, version = runtime.split("/")
    @data["flatpak"].merge!("runtime" => name, "runtime_version" => version)
    @data["flatpak"].delete("sdk")
    build = configure
    capture_io { build.run_build(value: "1.2.3", output: @root / "dist") }
    environment = { "FLATPAK_USER_DIR" => (@root / "installation").to_s }
    build.capture("flatpak", "install", "--user", "--noninteractive", "--bundle", bundle(@root / "dist"), env: environment)
    assert_equal "flatpak-ok", build.capture("flatpak", "run", "--user", ID, env: environment)
  end

  def test_validation
    build = configure
    assert build.configuration.validate
    [
      [-> { @data["flatpak"]["id"] = "sample-app" }, "flatpak.id"],
      [-> { @data["flatpak"]["id"] = "org.example.sample-app" }, "flatpak.id"],
      [-> { @data["flatpak"].delete("runtime_version") }, "flatpak.runtime_version"],
      [-> { @data["flatpak"]["command"] = "../sample-app" }, "flatpak.command"],
      [-> { @data["flatpak"]["finish_args"] = ["--command=other"] }, "flatpak.finish_args"],
      [-> { @data["flatpak"]["finish_args"] = "--share=network" }, "flatpak.finish_args"],
      [-> { @data["flatpak"]["runtime_repo"] = "http://example.org/flathub.flatpakrepo" }, "flatpak.runtime_repo"],
      [-> { @data["flatpak"]["manifest"] = "flathub.yml" }, "unknown fields manifest"],
      [-> { @data.delete("flatpak") }, "need a top-level flatpak section"],
      [-> { @data["targets"]["linux-amd64"]["formats"] = ["deb"] }, "no target builds the flatpak format"],
      [-> { @data["targets"]["linux-amd64"]["arch"] = "riscv64" }, "flatpak does not support riscv64"],
      [-> { @data["targets"]["linux-amd64"]["kind"] = "data" }, "Flatpak requires a Linux binary target"]
    ].each do |change, message|
      saved = Marshal.load(Marshal.dump(@data))
      change.call
      error = assert_raises(NativePackages::Error) { configure.configuration.validate }
      assert_includes error.message, message
      @data = saved
    end
  end

  def test_rejects_files_outside_usr_and_mismatched_metainfo
    build = compile
    @data["nfpm"]["contents"] << { "src" => "@PAYLOAD@/sample-app.svg", "dst" => "/etc/sample-app.svg" }
    error = assert_raises(NativePackages::Error) { capture_io { configure.run_build(value: "1.2.3") } }
    assert_includes error.message, "move /etc"
    @data["nfpm"]["contents"].pop
    (@root / "packaging/sample.metainfo.xml").write("<component><id>org.example.Other</id></component>\n")
    error = assert_raises(NativePackages::Error) { capture_io { configure.run_build(value: "1.2.3") } }
    assert_includes error.message, "does not declare <id>#{ID}</id>"
    (@root / "packaging/sample.metainfo.xml").delete
    @data["flatpak"]["command"] = "missing"
    error = assert_raises(NativePackages::Error) { capture_io { configure.run_build(value: "1.2.3") } }
    assert_includes error.message, "command missing is not an executable"
    assert build
  end
end
