# frozen_string_literal: true

module NativePackages
  class Inspection
    include Support
    ELF_ARCHES = { "386" => [3, 1, 1], "amd64" => [62, 2, 1], "arm64" => [183, 2, 1],
      "arm5" => [40, 1, 1], "arm6" => [40, 1, 1], "arm7" => [40, 1, 1],
      "mips" => [8, 1, 2], "mipsle" => [8, 1, 1], "mips64" => [8, 2, 2], "mips64le" => [8, 2, 1],
      "ppc64" => [21, 2, 2], "ppc64le" => [21, 2, 1], "s390x" => [22, 2, 2],
      "riscv64" => [243, 2, 1], "loong64" => [258, 2, 1] }.freeze
    PE_ARCHES = { "386" => 0x14c, "amd64" => 0x8664, "arm64" => 0xaa64 }.freeze
    LIBRARIES = {
      "libgcc_s.so.1" => { "deb" => "libgcc-s1", "rpm" => "libgcc" },
      "libstdc++.so.6" => { "deb" => "libstdc++6", "rpm" => "libstdc++" },
      "libasound.so.2" => { "deb" => "libasound2", "rpm" => "alsa-lib" },
      "libpulse.so.0" => { "deb" => "libpulse0", "rpm" => "pulseaudio-libs" },
      "libpulse-simple.so.0" => { "deb" => "libpulse0", "rpm" => "pulseaudio-libs" },
      "libpipewire-0.3.so.0" => { "deb" => "libpipewire-0.3-0", "rpm" => "pipewire-libs" },
      "libssl.so.3" => { "deb" => "libssl3", "rpm" => "openssl-libs" },
      "libcrypto.so.3" => { "deb" => "libssl3", "rpm" => "openssl-libs" }
    }.freeze
    attr_reader :root

    def initialize(root, libraries = {})
      @root = root
      @libraries = LIBRARIES.merge(libraries)
    end

    RELATIONS = %w[suggests recommends none].freeze
    GLOB = File::FNM_PATHNAME | File::FNM_EXTGLOB

    # Each packaged file with the path nFPM installs it at, or with no
    # format, every file any format of the package installs.
    def selected_files(package, format = nil)
      # nFPM overrides replace the contents list when one is supplied.
      contents = if format
        package.fetch("overrides", {}).fetch(format, {}).fetch("contents", package.fetch("contents"))
      else
        package.fetch("contents") + package.fetch("overrides", {}).values.flat_map { |override| override.fetch("contents", []) }
      end
      contents.flat_map do |item|
        next [] if format && item["packager"] && item["packager"] != format
        next [] if %w[symlink ghost dir].include?(item["type"]) || !item["src"]
        source = File.expand_path(item.fetch("src"), root)
        paths = package["disable_globbing"] ? [Pathname.new(source)].select(&:exist?) : Dir.glob(source).sort.map { |path| Pathname.new(path) }
        raise Error, "missing package content: #{source}" if paths.empty?
        destination = Pathname.new("/") / item.fetch("dst").to_s
        # As nFPM does: a glob source, or a destination ending in a slash,
        # makes the destination a directory that takes each match's name.
        directory = (!package["disable_globbing"] && item.fetch("src").match?(/[*?\[{]/)) || item.fetch("dst").to_s.end_with?("/")
        paths.flat_map do |path|
          if path.directory?
            files(path).map { |file| [file, (destination / file.relative_path_from(path)).cleanpath.to_s] }
          else
            [[path, (directory ? destination / path.basename : destination).cleanpath.to_s]]
          end
        end
      end.uniq
    end

    # The relation for an installed path: the first matching
    # inspection.optional entry's, or nil for a required file.
    def self.relation(target, installed)
      ancestors = Pathname.new(installed).ascend.map(&:to_s)
      entry = target.fetch("inspection", {}).fetch("optional", []).find do |item|
        item.fetch("paths").any? { |pattern| ancestors.any? { |path| File.fnmatch?(pattern, path, GLOB) } }
      end
      entry && entry.fetch("relation", "suggests")
    end

    def check(package, target, format)
      selected = selected_files(package, format)
      paths = selected.map(&:first).uniq
      kind = target.fetch("kind", "binary")
      if kind != "binary"
        binaries = paths.select { |path| ["\x7fELF".b, "MZ".b].any? { |magic| path.binread(magic.bytesize) == magic } }
        raise Error, "#{kind} target contains executable binaries; declare a binary target" unless binaries.empty?
        raise Error, "source target requires an RPM spec" if kind == "source" && paths.none? { |path| path.extname == ".spec" }
        return { "kind" => kind, "files" => paths.length, "installation" => "not-tested" }
      end
      target.fetch("platform") == "windows" ? pe(paths, target) : elf(selected, package, target, format)
    end

    def pe(paths, target)
      expected = PE_ARCHES[target.fetch("arch")]
      raise Error, "PE inspection does not support #{target.fetch('arch')}" unless expected
      binaries = paths.select { |path| path.binread(2) == "MZ" }
      raise Error, "Windows target contains no PE binaries" if binaries.empty?
      binaries.each do |path|
        File.open(path, "rb") do |file|
          file.seek(0x3c)
          offset = file.read(4)&.unpack1("L<")
          raise Error, "invalid PE header: #{path}" unless offset && offset >= 0x40 && offset + 24 <= file.size
          file.seek(offset)
          raise Error, "wrong PE architecture or signature: #{path}" unless file.read(4) == "PE\0\0" && file.read(2).unpack1("S<") == expected
        end
      end
      { "kind" => "pe", "binaries" => binaries.length, "architecture" => target.fetch("arch"), "dependencies" => "explicit", "installation" => "not-tested" }
    end

    def elf(selected, package, target, format)
      expected = ELF_ARCHES[target.fetch("arch")]
      raise Error, "ELF inspection does not support #{target.fetch('arch')}" unless expected
      # A pattern may name a file only some formats install.
      patterns = target.fetch("inspection", {}).fetch("optional", []).flat_map { |item| item.fetch("paths") }
      unless patterns.empty?
        installed = selected_files(package).map(&:last).uniq
        unused = patterns.reject do |pattern|
          installed.any? { |file| Pathname.new(file).ascend.any? { |path| File.fnmatch?(pattern, path.to_s, GLOB) } }
        end
        raise Error, "inspection.optional matches no installed file: #{unused.join(', ')}" unless unused.empty?
      end
      binaries = selected.select { |path, _| path.binread(4) == "\x7fELF" }
      raise Error, "Linux target contains no ELF binaries" if binaries.empty?
      # Libraries and glibc versions by relation: nil for required files.
      linked = Hash.new { |hash, key| hash[key] = [] }
      versions = Hash.new { |hash, key| hash[key] = [] }
      interpreters, optional = [], []
      bundled = binaries.map { |path, _| path.basename.to_s }
      binaries.each do |path, installed|
        header = path.binread(20)
        machine = header.byteslice(18, 2)&.unpack1(header.getbyte(5) == 2 ? "S>" : "S<")
        raise Error, "wrong ELF architecture: #{path}" unless [machine, header.getbyte(4), header.getbyte(5)] == expected
        relation = self.class.relation(target, installed)
        optional << installed if relation
        dynamic = capture("readelf", "-d", path)
        linked[relation].concat(dynamic.scan(/Shared library: \[([^\]]+)\]/).flatten)
        bundled.concat(dynamic.scan(/Library soname: \[([^\]]+)\]/).flatten)
        versions[relation].concat(capture("readelf", "--version-info", path).scan(/GLIBC_(\d+\.\d+)/).flatten)
        interpreters.concat(capture("readelf", "-l", path).scan(/Requesting program interpreter: ([^\]]+)/).flatten)
      end
      # The C library checks cover optional files too: they still install.
      libc = target.fetch("libc")
      if libc == "static" && (linked.values.any? { |values| !values.empty? } || !interpreters.empty?)
        raise Error, "target declares static but contains dynamic ELF binaries"
      end
      if libc == "musl" && (versions.values.any? { |values| !values.empty? } || interpreters.any? { |value| !value.include?("musl") })
        raise Error, "target declares musl but contains a different libc ABI"
      end
      if libc == "glibc" && interpreters.any? { |value| value.include?("musl") }
        raise Error, "target declares glibc but contains a musl loader"
      end
      raise Error, "APK binary targets need musl/static inputs; glibc compatibility is not inferred" if format == "apk" && libc == "glibc"
      system = /\A(?:lib(?:c|m|dl|rt|pthread|resolv)\.so\.|ld-linux)/
      external = linked[nil].uniq - bundled
      # A library a required file links stays a hard dependency, recommends
      # outranks suggests, and libraries of files with relation none are ignored.
      recommends = (linked["recommends"].uniq - bundled - external).grep_v(system)
      weak = { "recommends" => recommends, "suggests" => (linked["suggests"].uniq - bundled - external - recommends).grep_v(system) }
      glibc = versions[nil].max_by { |version| Gem::Version.new(version) }
      if %w[deb rpm].include?(format)
        overrides = package["overrides"] ||= {}
        override = overrides[format] ||= {}
        depends = override.fetch("depends", package.fetch("depends", [])).dup
        external.each do |library|
          next if system.match?(library)
          depends << dependency(library, format)
        end
        if glibc
          previous = depends.grep(format == "deb" ? /\Alibc6(?: |$)/ : /\Aglibc(?: |$)/)
          floor = ([glibc] + previous.flat_map { |value| value.scan(/\d+\.\d+/) }).max_by { |value| Gem::Version.new(value) }
          depends -= previous
          depends << (format == "deb" ? "libc6 (>= #{floor})" : "glibc >= #{floor}")
        end
        override["depends"] = depends.uniq
        taken = override["depends"]
        weak.each do |relation, libraries|
          next if libraries.empty?
          packages = libraries.map { |library| dependency(library, format) }
          override[relation] = (override.fetch(relation, package.fetch(relation, [])) + packages).uniq - taken
          taken += override[relation]
        end
      elsif format == "appimage"
        # Nothing is bundled: the host supplies these, as for deb and rpm.
      elsif !external.empty? && package.fetch("overrides", {}).fetch(format, {}).fetch("depends", package.fetch("depends", [])).empty?
        raise Error, "#{format}: declare dependencies for #{external.join(', ')}"
      end
      result = { "kind" => "elf", "binaries" => binaries.length, "architecture" => target.fetch("arch"), "libc" => libc,
        "required_libraries" => external.sort, "glibc_floor" => glibc, "installation" => "not-tested" }
      unless optional.empty?
        result["optional"] = { "binaries" => optional.sort }.merge(weak.reject { |_, libraries| libraries.empty? }.transform_values(&:sort))
      end
      result
    end

    def dependency(library, format)
      @libraries[library]&.[](format) or raise Error, "add libraries.#{library}.#{format} and declare runtime-loaded dependencies"
    end
  end
end
