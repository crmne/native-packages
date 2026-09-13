# frozen_string_literal: true

require "native_packages"
require "zlib"

root = Pathname.new(ARGV.fetch(0)).expand_path
root.mkpath
payload = root / "payload"
payload.mkpath
windows = ARGV.include?("--windows")
runner = Object.new.extend(NativePackages::Support)
runner.define_singleton_method(:root) { root }
name = "native-packages-smoke"
data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
  "nfpm" => { "name" => name, "maintainer" => "Native Packages Tests <test@example.org>", "description" => "Native packaging acceptance fixture", "license" => "MIT" }, "targets" => {} }
if windows
  (root / "main.go").write("package main\nfunc main() {}\n")
  runner.capture("go", "build", "-o", payload / "app.exe", root / "main.go", env: { "GOOS" => "windows", "GOARCH" => "amd64", "CGO_ENABLED" => "0" })
  { "logo.png" => 150, "small.png" => 44 }.each do |filename, size|
    chunk = ->(type, value) { [value.bytesize].pack("N") + type + value + [Zlib.crc32(type + value)].pack("N") }
    raw = ("\0".b + "\x20\x60\x90\xff".b * size) * size
    (payload / filename).binwrite("\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [size, size, 8, 6, 0, 0, 0].pack("NNCCCCC")) + chunk.call("IDAT", Zlib.deflate(raw)) + chunk.call("IEND", ""))
  end
  data["nfpm"]["contents"] = %w[app.exe logo.png small.png].map { |file| { "src" => "@PAYLOAD@/#{file}", "dst" => "/#{file}" } }
  data["nfpm"]["msix"] = { "publisher" => "CN=NativePackagesTest", "properties" => { "logo" => "logo.png" },
    "applications" => [{ "id" => "App", "executable" => "app.exe", "visual_elements" => { "display_name" => "Packaging Smoke Test",
      "description" => "Packaging Smoke Test", "square150x150_logo" => "logo.png", "square44x44_logo" => "small.png" } }] }
  data["targets"]["windows-amd64"] = { "platform" => "windows", "arch" => "amd64", "formats" => ["msix"], "input" => { "local" => "payload", "kind" => "directory" } }
  if ENV["MSIX_SIGN_SCRIPT"]
    data["targets"]["windows-amd64"]["after_package"] = ["pwsh", "-NoProfile", "-File", ENV.fetch("MSIX_SIGN_SCRIPT"), "@PACKAGE@"]
  end
else
  (payload / "main.c").write("#include <stdio.h>\nint main(void) { puts(\"native-packages-ok\"); return 0; }\n")
  runner.capture("cc", "-static", payload / "main.c", "-o", payload / name)
  data["nfpm"]["contents"] = [{ "src" => "@PAYLOAD@/#{name}", "dst" => "/usr/bin/#{name}" }]
  data["targets"]["linux-amd64"] = { "platform" => "linux", "arch" => "amd64", "libc" => "static", "abi" => "OpenWrt x86_64 static acceptance fixture",
    "formats" => %w[deb rpm archlinux apk ipk], "input" => { "local" => "payload", "kind" => "directory" } }
  (payload / "#{name}.spec").write(<<~SPEC)
    Name: #{name}
    Version: 1.2.3
    Release: 1
    Summary: Native package test
    License: MIT
    Source0: main.c
    BuildRequires: gcc
    %description
    Native package test.
    %prep
    %build
    gcc %{SOURCE0} -o #{name}
    %install
    mkdir -p %{buildroot}/usr/bin
    cp #{name} %{buildroot}/usr/bin/#{name}
    %files
    /usr/bin/#{name}
  SPEC
  data["targets"]["source"] = { "kind" => "source", "platform" => "linux", "arch" => "all", "formats" => ["srpm"],
    "input" => { "local" => "payload", "kind" => "directory" }, "nfpm" => {
      "contents" => ["main.c", "#{name}.spec"].map { |file| { "src" => "@PAYLOAD@/#{file}", "dst" => "/#{file}" } } } }
end
path = root / "native-packages.yaml"
path.write(YAML.dump(data))
configuration = NativePackages::Configuration.new(path)
%w[1.2.3 1.2.4].each { |version| NativePackages::Build.new(configuration).run_build(value: version) }
