# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class NativePackagesInspectionTest < Minitest::Test
  attr_reader :root

  def capture(...) = NativePackages::Inspection.new(root).capture(...)

  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-inspection-test-"))
    @old_epoch = ENV["SOURCE_DATE_EPOCH"]
    ENV["SOURCE_DATE_EPOCH"] = "1767225600"
  end

  def teardown
    ENV["SOURCE_DATE_EPOCH"] = @old_epoch
    FileUtils.remove_entry(@root)
  end

  def need_tools(*tools)
    missing = tools.reject { |tool| NativePackages::Inspection.new(root).available?(tool) }
    skip "requires #{missing.join(', ')}" unless missing.empty?
  end

  # An app, and a plugin directory whose plugin links a library the package
  # does not ship and that has no built-in mapping. The plugin also uses a
  # newer glibc symbol where the host has one.
  def fixtures(app_links_fixture: false)
    need_tools "cc", "readelf"
    (root / "build").mkpath
    (root / "payload/plugins").mkpath
    (root / "fixture.c").write("int fixture(void) { return 1; }\n")
    capture("cc", "-shared", "-fPIC", "-Wl,-soname,libfixture.so.1", root / "fixture.c", "-o", root / "build/libfixture.so.1")
    (root / "app.c").write("#{app_links_fixture ? 'int fixture(void);' : ''}\nint main(void) { return #{app_links_fixture ? 'fixture()' : '0'}; }\n")
    capture("cc", root / "app.c", "-o", root / "payload/app", *(app_links_fixture ? ["-L#{root / 'build'}", "-l:libfixture.so.1"] : []))
    (root / "plugin.c").write(<<~C)
      #include <string.h>
      int fixture(void);
      int plugin(char *out, const char *in) {
      #if defined(__GLIBC__) && __GLIBC_PREREQ(2, 38)
        strlcpy(out, in, 8);
      #endif
        return fixture() + (int)strlen(in);
      }
    C
    capture("cc", "-shared", "-fPIC", root / "plugin.c", "-o", root / "payload/plugins/libplugin.so", "-L#{root / 'build'}", "-l:libfixture.so.1")
  end

  def package
    { "contents" => [{ "src" => "payload/app", "dst" => "/usr/bin/app" },
      { "src" => "payload/plugins", "dst" => "/usr/lib/app/plugins", "type" => "tree" }] }
  end

  def target(optional = nil)
    result = { "platform" => "linux", "arch" => arch, "libc" => "glibc", "formats" => %w[deb rpm] }
    result["inspection"] = { "optional" => optional } if optional
    result
  end

  def arch = { 62 => "amd64", 183 => "arm64" }.fetch((root / "payload/app").binread(20).byteslice(18, 2).unpack1("S<"))

  def glibc(path) = capture("readelf", "--version-info", path).scan(/GLIBC_(\d+\.\d+)/).flatten.max_by { |version| Gem::Version.new(version) }

  def inspect_package(optional, format, libraries = {})
    value = package
    result = NativePackages::Inspection.new(root, libraries).check(value, target(optional), format)
    [result, value.fetch("overrides").fetch(format)]
  end

  def test_installed_paths_follow_nfpm_destinations
    (root / "payload/share/nested").mkpath
    %w[a.so b.so share/nested/c.txt].each { |name| (root / "payload" / name).write("x") }
    contents = [{ "src" => "payload/*.so", "dst" => "/usr/lib/app" }, { "src" => "payload/a.so", "dst" => "/opt/app/" },
      { "src" => "payload/b.so", "dst" => "/opt/app/renamed.so" }, { "src" => "payload/share", "dst" => "/usr/share/app", "type" => "tree" },
      { "src" => "payload/a.so", "dst" => "/usr/lib/rpm-only.so", "packager" => "rpm" }, { "src" => "/usr/bin/app", "dst" => "/usr/bin/link", "type" => "symlink" }]
    installed = NativePackages::Inspection.new(root).selected_files({ "contents" => contents }, "deb").map(&:last)
    assert_equal %w[/opt/app/a.so /opt/app/renamed.so /usr/lib/app/a.so /usr/lib/app/b.so /usr/share/app/nested/c.txt], installed.sort
  end

  def test_relation_matches_globs_and_directories
    optional = [{ "paths" => ["/usr/lib/app/cuda-*", "/usr/lib/app/**/*.so"], "relation" => "none" }, { "paths" => ["/usr/lib/app/gtk"] }]
    inspection = { "inspection" => { "optional" => optional } }
    assert_equal "none", NativePackages::Inspection.relation(inspection, "/usr/lib/app/cuda-12/deep/libx.so.1")
    assert_equal "none", NativePackages::Inspection.relation(inspection, "/usr/lib/app/plugins/libx.so")
    assert_equal "suggests", NativePackages::Inspection.relation(inspection, "/usr/lib/app/gtk")
    assert_nil NativePackages::Inspection.relation(inspection, "/usr/lib/app/cuda")
    assert_nil NativePackages::Inspection.relation(inspection, "/usr/bin/app")
  end

  def test_unmapped_libraries_of_required_files_still_fail
    fixtures
    error = assert_raises(NativePackages::Error) { inspect_package(nil, "deb") }
    assert_includes error.message, "add libraries.libfixture.so.1.deb"
  end

  def test_optional_files_with_relation_none_add_nothing_and_keep_the_glibc_floor
    fixtures
    %w[deb rpm].each do |format|
      result, override = inspect_package([{ "paths" => ["/usr/lib/app/plugins"], "relation" => "none" }], format)
      floor = glibc(root / "payload/app")
      assert_equal floor, result.fetch("glibc_floor")
      assert_equal [format == "deb" ? "libc6 (>= #{floor})" : "glibc >= #{floor}"], override.fetch("depends")
      refute override.key?("suggests")
      assert_equal({ "binaries" => ["/usr/lib/app/plugins/libplugin.so"] }, result.fetch("optional"))
    end
  end

  def test_optional_files_become_weak_dependencies
    fixtures
    libraries = { "libfixture.so.1" => { "deb" => "libfixture1", "rpm" => "fixture-libs" } }
    { "deb" => "libfixture1", "rpm" => "fixture-libs" }.each do |format, name|
      result, override = inspect_package([{ "paths" => ["/usr/lib/app/plugins/*.so"], "relation" => "suggests" }], format, libraries)
      assert_equal [name], override.fetch("suggests")
      refute_includes override.fetch("depends"), name
      assert_equal ["libfixture.so.1"], result.fetch("optional").fetch("suggests")
      _, override = inspect_package([{ "paths" => ["/usr/lib/app/plugins"], "relation" => "recommends" }], format, libraries)
      assert_equal [name], override.fetch("recommends")
    end
    error = assert_raises(NativePackages::Error) { inspect_package([{ "paths" => ["/usr/lib/app/plugins"] }], "deb") }
    assert_includes error.message, "add libraries.libfixture.so.1.deb"
  end

  def test_a_library_a_required_file_links_stays_required
    fixtures(app_links_fixture: true)
    libraries = { "libfixture.so.1" => { "deb" => "libfixture1", "rpm" => "fixture-libs" } }
    value = package.merge("suggests" => ["helper"])
    NativePackages::Inspection.new(root, libraries).check(value, target([{ "paths" => ["/usr/lib/app/plugins"] }]), "deb")
    override = value.fetch("overrides").fetch("deb")
    assert_includes override.fetch("depends"), "libfixture1"
    refute override.key?("suggests"), "explicit suggests stay where they were declared"
  end

  def test_optional_patterns_must_match_an_installed_file
    fixtures
    error = assert_raises(NativePackages::Error) { inspect_package([{ "paths" => ["/usr/lib/app/plugin"], "relation" => "none" }], "deb") }
    assert_includes error.message, "inspection.optional matches no installed file: /usr/lib/app/plugin"
    value = package
    value["contents"] << { "src" => "payload/plugins/libplugin.so", "dst" => "/usr/lib/app/rpm-only/", "packager" => "rpm" }
    NativePackages::Inspection.new(root).check(value, target([{ "paths" => ["/usr/lib/app/plugins", "/usr/lib/app/rpm-only"], "relation" => "none" }]), "deb")
  end

  def test_optional_files_are_still_checked_for_architecture_and_libc
    fixtures
    optional = target([{ "paths" => ["/usr/lib/app/plugins"], "relation" => "none" }])
    (root / "payload/app").write("#!/bin/sh\n")
    error = assert_raises(NativePackages::Error) { NativePackages::Inspection.new(root).check(package, optional.merge("libc" => "static"), "deb") }
    assert_includes error.message, "dynamic ELF"
    other = optional.fetch("arch") == "amd64" ? "arm64" : "amd64"
    error = assert_raises(NativePackages::Error) { NativePackages::Inspection.new(root).check(package, optional.merge("arch" => other), "deb") }
    assert_includes error.message, "wrong ELF architecture: #{root / 'payload/plugins/libplugin.so'}"
  end

  def test_configuration_validates_inspection
    data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "app", "maintainer" => "Test <test@example.org>", "description" => "App", "license" => "MIT",
        "contents" => [{ "src" => "@PAYLOAD@/app", "dst" => "/usr/bin/app" }] },
      "targets" => { "linux-amd64" => { "platform" => "linux", "arch" => "amd64", "libc" => "glibc", "formats" => ["deb"],
        "input" => { "local" => "payload", "kind" => "directory" } } } }
    validate = lambda do |inspection|
      data["targets"]["linux-amd64"]["inspection"] = inspection
      (root / "native-packages.yaml").write(YAML.dump(data))
      NativePackages::Configuration.new(root / "native-packages.yaml").validate
    end
    assert validate.call({ "optional" => [{ "paths" => ["/usr/lib/app/**"], "relation" => "none" }, { "paths" => ["/usr/lib/app/gtk"] }] })
    {
      { "optional" => [] } => "inspection.optional: expected a nonempty list",
      { "optional" => [{ "paths" => ["lib/app"] }] } => "inspection.optional[0].paths",
      { "optional" => [{ "paths" => [] }] } => "inspection.optional[0].paths",
      { "optional" => [{ "paths" => ["/x"], "relation" => "depends" }] } => "relation: use suggests, recommends, none",
      { "optional" => [{ "paths" => ["/x"], "when" => "gpu" }] } => "unknown fields when",
      { "skip" => true } => "inspection: unknown fields skip",
      [] => "inspection: expected a mapping"
    }.each do |inspection, message|
      assert_includes assert_raises(NativePackages::Error) { validate.call(inspection) }.message, message
    end
    data["targets"]["linux-amd64"]["kind"] = "data"
    assert_includes assert_raises(NativePackages::Error) { validate.call({ "optional" => [{ "paths" => ["/x"] }] }) }.message,
      "only for Linux binary targets"
  end

  def test_deb_package_carries_the_suggestion
    need_tools "nfpm", "bsdtar"
    fixtures
    data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "libraries" => { "libfixture.so.1" => { "deb" => "libfixture1", "rpm" => "fixture-libs" } },
      "nfpm" => { "name" => "sample-app", "maintainer" => "Test <test@example.org>", "description" => "Sample app", "license" => "MIT",
        "contents" => [{ "src" => "@PAYLOAD@/app", "dst" => "/usr/bin/app" },
          { "src" => "@PAYLOAD@/plugins", "dst" => "/usr/lib/sample-app/plugins", "type" => "tree" }] },
      "targets" => { "linux" => { "platform" => "linux", "arch" => arch, "libc" => "glibc", "formats" => ["deb"],
        "inspection" => { "optional" => [{ "paths" => ["/usr/lib/sample-app/plugins"] }] },
        "input" => { "local" => "payload", "kind" => "directory" } } } }
    (root / "native-packages.yaml").write(YAML.dump(data))
    build = NativePackages::Build.new(NativePackages::Configuration.new(root / "native-packages.yaml"))
    capture_io { build.run_build(value: "1.2.3") }
    output = root / "dist/packages/1.2.3"
    record = build.verify(output).fetch("packages").first
    assert_equal ["/usr/lib/sample-app/plugins/libplugin.so"], record.fetch("validation").fetch("optional").fetch("binaries")
    control = root / "control"
    control.mkpath
    capture("bsdtar", "-xf", output / record.fetch("path"), "-C", control)
    fields = capture("bsdtar", "-xOf", Pathname.glob(control / "control.tar*").fetch(0), "./control")
    assert_includes fields, "Suggests: libfixture1"
    assert_includes fields, "Depends: libc6 (>= #{glibc(root / 'payload/app')})"
  end
end
