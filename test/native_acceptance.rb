# frozen_string_literal: true

# Native package lifecycle fixtures. Run only with a fresh, disposable directory.
# These test the shared adapter; they do not certify an application's behavior.
require "native_packages"
require "securerandom"

root = Pathname.new(ARGV.fetch(0)).expand_path
raise "Acceptance output already exists" if root.exist? || root.symlink?
host = NativePackages::NativeRecipe.host
raise "This acceptance fixture requires macOS or Windows" unless %w[macos windows].include?(host)
root.mkpath
(root / "QA-OWNERSHIP.txt").write("native-packages disposable native acceptance\n")
runner = Object.new.extend(NativePackages::Support)
runner.define_singleton_method(:root) { root }
windows = host == "windows"
identity = "NativePackagesFixture-#{SecureRandom.hex(8)}"
versions = %w[1.2.3-alpha.1 1.2.3-alpha.2 1.2.3]
payload = root / (windows ? "payload" : "NativeFixture.app")
payload.mkpath
resources = windows ? payload : payload / "Contents/Resources"
(resources / "models").mkpath
(resources / "models/fixture.bin").write("fixture-model-preserved\n")
arch = windows ? "amd64" : ({ "arm64" => "arm64", "x86_64" => "amd64" }.fetch(runner.capture("uname", "-m")))
binary = windows ? payload / "app.exe" : payload / "Contents/MacOS/native-fixture"
binary.dirname.mkpath

if windows
  compiler = ENV.fetch("NATIVE_PACKAGES_ISCC")
  raise "Inno compiler not found" unless File.file?(compiler)
  (root / "fixture.iss").write(<<~ISS)
    [Setup]
    AppId=#{identity}
    AppName=Native Packages Acceptance Fixture
    AppVersion={#Version}
    VersionInfoVersion=1.2.3.{#BuildNumber}
    DefaultDirName={userpf}\\#{identity}
    PrivilegesRequired=lowest
    DisableDirPage=yes
    DisableProgramGroupPage=yes
    UninstallDisplayName=#{identity}
    WizardStyle=modern
    [Files]
    Source: "{#Input}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
  ISS
  (root / "recipe.rb").write(<<~'RUBY')
    require 'pathname'
    input, output, version = ARGV
    output = Pathname.new(output)
    build = version.include?('-') ? version.split('.').last : '3'
    ok = system(ENV.fetch('NATIVE_PACKAGES_ISCC'), '/Qp', "/DInput=#{input}", "/DVersion=#{version}", "/DBuildNumber=#{build}",
      "/O#{output.dirname}", "/F#{output.basename('.exe')}", File.join(__dir__, 'fixture.iss'))
    abort 'Inno Setup fixture compilation failed' unless ok
  RUBY
else
  (root / "recipe.rb").write(<<~'RUBY')
    require 'tmpdir'
    require 'fileutils'
    input, output = ARGV
    Dir.mktmpdir('native-fixture-dmg-') do |stage|
      FileUtils.cp_r(input, File.join(stage, 'NativeFixture.app'), preserve: true)
      File.symlink('/Applications', File.join(stage, 'Applications'))
      abort 'DMG creation failed' unless system('hdiutil', 'create', '-volname', 'NativeFixture', '-srcfolder', stage, '-format', 'UDZO', output)
      abort 'DMG verification failed' unless system('hdiutil', 'verify', output)
    end
  RUBY
end

format = windows ? "inno" : "dmg"
data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
  "nfpm" => { "name" => "native-fixture", "maintainer" => "Tests <test@example.org>", "description" => "Native fixture", "license" => "MIT" },
  "release" => { "prereleases" => true },
  "targets" => { host => { "platform" => host, "arch" => arch, "formats" => [format],
    "input" => { "kind" => "directory", "local" => payload.basename.to_s },
    "native" => { "command" => [RbConfig.ruby, "@ROOT@/recipe.rb", "@PAYLOAD@", "@PACKAGE@", "@VERSION@"],
      "output" => "@NAME@-@TAG@-@PLATFORM@.#{windows ? 'exe' : 'dmg'}" } } } }
(root / "native-packages.yaml").write(YAML.dump(data))
builder = NativePackages::Build.new(NativePackages::Configuration.new(root / "native-packages.yaml"))
packages = {}
versions.each_with_index do |version, index|
  (root / "fixture.c").write("#include <stdio.h>\nint main(void) { puts(\"#{version}\"); return 0; }\n")
  if windows
    runner.run("cl.exe", "/nologo", "/MT", root / "fixture.c", "/Fe:#{binary}", "/Fo:#{root / 'fixture.obj'}")
  else
    runner.run("cc", root / "fixture.c", "-o", binary)
    (payload / "Contents/Info.plist").write(<<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>org.example.native-packages-fixture</string>
      <key>CFBundleExecutable</key><string>native-fixture</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>1.2.3</string>
      <key>CFBundleVersion</key><string>#{index + 1}.0.0</string>
      </dict></plist>
    PLIST
    runner.run("codesign", "--force", "--sign", "-", payload)
    runner.run("codesign", "--verify", "--strict", payload)
  end
  # Cover the existing preview path and the opt-in deferred path with real
  # native packages, then install and remove the exact verified artifacts.
  deferred = version == versions.last
  output = builder.run_build(value: version, defer_recipes: deferred)
  if deferred
    complete = root / "finalized" / version
    builder.aggregate([output], output: complete, finalize_recipes: true)
    output = complete
  end
  manifest = builder.verify(output)
  packages[version] = { "path" => output / manifest.fetch("packages").first.fetch("path"), "binary_sha256" => runner.sha256(binary) }
end

installed = root / "installed"
observations = []
begin
  (versions + [versions.first]).each do |version|
    package = packages.fetch(version)
    if windows
      runner.run(package.fetch("path"), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/DIR=#{installed}")
      executable = installed / "app.exe"
      model = installed / "models/fixture.bin"
    else
      mount = root / "mounted"
      mount.mkpath
      runner.run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, package.fetch("path"))
      begin
        FileUtils.remove_entry(installed) if installed.exist?
        installed.mkpath
        FileUtils.cp_r(mount / "NativeFixture.app", installed / "NativeFixture.app", preserve: true)
      ensure
        runner.run("hdiutil", "detach", mount)
      end
      runner.run("codesign", "--verify", "--strict", installed / "NativeFixture.app")
      executable = installed / "NativeFixture.app/Contents/MacOS/native-fixture"
      model = installed / "NativeFixture.app/Contents/Resources/models/fixture.bin"
    end
    raise "Installed binary differs" unless runner.sha256(executable) == package.fetch("binary_sha256")
    raise "Installed model differs" unless model.read == "fixture-model-preserved\n"
    observed = runner.capture(executable)
    raise "Installed version differs: #{observed}" unless observed == version
    observations << { "expected" => version, "observed" => observed, "binary_sha256" => runner.sha256(executable), "model_preserved" => true }
  end
ensure
  if windows && (installed / "unins000.exe").file?
    runner.run(installed / "unins000.exe", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
  elsif !windows && installed.exist?
    FileUtils.remove_entry(installed)
  end
end
raise "Uninstall left the fixture executable" if windows && (installed / "app.exe").exist?
result = { "schema" => 1, "tool" => NativePackages::VERSION, "host" => host, "arch" => arch,
  "fixture_only" => true, "install_upgrade_rollback" => observations, "removed" => true,
  "packages" => packages.transform_values { |record| { "path" => record.fetch("path").relative_path_from(root).to_s, "sha256" => runner.sha256(record.fetch("path")) } } }
(root / "native-results.json").write(JSON.pretty_generate(result) + "\n")
puts JSON.pretty_generate(result)
