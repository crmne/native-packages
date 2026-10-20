# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class NativePackagesGlibcCeilingTest < Minitest::Test
  attr_reader :root

  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-glibc-ceiling-test-"))
    (root / "payload").mkpath
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def tool = NativePackages::Inspection.new(root)

  # Two programs that need glibc 2.38 for strlcpy, and one that does not.
  def fixtures
    missing = %w[cc readelf].reject { |name| tool.available?(name) }
    skip "requires #{missing.join(', ')}" unless missing.empty?
    (root / "new.c").write(<<~C)
      #include <string.h>
      int main(int argc, char **argv) { char out[8]; return (int)strlcpy(out, argv[0], sizeof out) + argc; }
    C
    (root / "old.c").write("int main(void) { return 0; }\n")
    tool.capture("cc", root / "new.c", "-o", root / "payload/new")
    tool.capture("cc", root / "new.c", "-o", root / "payload/newer")
    tool.capture("cc", root / "old.c", "-o", root / "payload/old")
    skip "the host glibc has no strlcpy@GLIBC_2.38" unless tool.capture("readelf", "-W", "--dyn-syms", root / "payload/new").include?("strlcpy@GLIBC_2.38")
  end

  def check(ceiling, files = %w[new newer old])
    package = { "contents" => files.map { |name| { "src" => "payload/#{name}", "dst" => "/usr/bin/#{name}" } } }
    arch = { 62 => "amd64", 183 => "arm64" }.fetch((root / "payload/old").binread(20).byteslice(18, 2).unpack1("S<"))
    target = { "platform" => "linux", "arch" => arch, "libc" => "glibc", "formats" => ["deb"], "inspection" => { "glibc_ceiling" => ceiling } }
    tool.check(package, target, "deb")
  end

  def test_binaries_needing_a_newer_glibc_fail_with_their_symbols
    fixtures
    error = assert_raises(NativePackages::Error) { check("2.37") }
    lines = error.message.lines.map(&:strip)
    assert_equal "glibc ceiling 2.37 exceeded:", lines.first
    assert_equal ["#{root / 'payload/new'} needs strlcpy@GLIBC_2.38", "#{root / 'payload/newer'} needs strlcpy@GLIBC_2.38"], lines.drop(1)
  end

  def test_binaries_within_the_ceiling_pass_and_record_it
    fixtures
    result = check("2.38")
    assert_equal "2.38", result.fetch("glibc_ceiling")
    assert_equal "2.38", result.fetch("glibc_floor")
    floor = tool.capture("readelf", "--version-info", root / "payload/old").scan(/GLIBC_(\d+\.\d+)/).flatten.max_by { |version| Gem::Version.new(version) }
    assert_equal floor, check(floor, ["old"]).fetch("glibc_floor")
  end

  def test_configuration_validates_the_ceiling
    data = { "schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "nfpm" => { "name" => "app", "maintainer" => "Test <test@example.org>", "description" => "App", "license" => "MIT",
        "contents" => [{ "src" => "@PAYLOAD@/app", "dst" => "/usr/bin/app" }] },
      "targets" => { "linux-amd64" => { "platform" => "linux", "arch" => "amd64", "libc" => "glibc", "formats" => ["deb"],
        "input" => { "local" => "payload", "kind" => "directory" } } } }
    validate = lambda do |inspection, changes = {}|
      data["targets"]["linux-amd64"].merge!(changes)
      data["targets"]["linux-amd64"]["inspection"] = inspection
      (root / "native-packages.yaml").write(YAML.dump(data))
      NativePackages::Configuration.new(root / "native-packages.yaml").validate
    end
    assert validate.call({ "glibc_ceiling" => "2.39" })
    {
      { "glibc_ceiling" => 2.39 } => "use a quoted glibc version such as '2.39'",
      { "glibc_ceiling" => "2.39.1" } => "use a quoted glibc version",
      { "glibc" => "2.39" } => "inspection: unknown fields glibc",
      "2.39" => "inspection: expected a mapping"
    }.each do |inspection, message|
      assert_includes assert_raises(NativePackages::Error) { validate.call(inspection) }.message, message
    end
    assert_includes assert_raises(NativePackages::Error) { validate.call({ "glibc_ceiling" => "2.39" }, "libc" => "musl") }.message,
      "glibc_ceiling: only for glibc Linux binary targets"
  end
end
