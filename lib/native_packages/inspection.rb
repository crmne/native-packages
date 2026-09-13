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

    def selected_files(package, format)
      # nFPM overrides replace the contents list when one is supplied.
      contents = package.fetch("overrides", {}).fetch(format, {}).fetch("contents", package.fetch("contents"))
      contents.flat_map do |item|
        next [] if item["packager"] && item["packager"] != format
        next [] if %w[symlink ghost dir].include?(item["type"]) || !item["src"]
        source = File.expand_path(item.fetch("src"), root)
        paths = package["disable_globbing"] ? [Pathname.new(source)].select(&:exist?) : Dir.glob(source).map { |path| Pathname.new(path) }
        raise Error, "missing package content: #{source}" if paths.empty?
        paths.flat_map { |path| path.directory? ? files(path) : path }
      end.uniq
    end

    def check(package, target, format)
      paths = selected_files(package, format)
      kind = target.fetch("kind", "binary")
      if kind != "binary"
        binaries = paths.select { |path| ["\x7fELF".b, "MZ".b].any? { |magic| path.binread(magic.bytesize) == magic } }
        raise Error, "#{kind} target contains executable binaries; declare a binary target" unless binaries.empty?
        raise Error, "source target requires an RPM spec" if kind == "source" && paths.none? { |path| path.extname == ".spec" }
        return { "kind" => kind, "files" => paths.length, "installation" => "not-tested" }
      end
      target.fetch("platform") == "windows" ? pe(paths, target) : elf(paths, package, target, format)
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

    def elf(paths, package, target, format)
      expected = ELF_ARCHES[target.fetch("arch")]
      raise Error, "ELF inspection does not support #{target.fetch('arch')}" unless expected
      binaries = paths.select { |path| path.binread(4) == "\x7fELF" }
      raise Error, "Linux target contains no ELF binaries" if binaries.empty?
      required, versions, interpreters = [], [], []
      bundled = binaries.map { |path| path.basename.to_s }
      binaries.each do |path|
        header = path.binread(20)
        machine = header.byteslice(18, 2)&.unpack1(header.getbyte(5) == 2 ? "S>" : "S<")
        raise Error, "wrong ELF architecture: #{path}" unless [machine, header.getbyte(4), header.getbyte(5)] == expected
        dynamic = capture("readelf", "-d", path)
        required.concat(dynamic.scan(/Shared library: \[([^\]]+)\]/).flatten)
        bundled.concat(dynamic.scan(/Library soname: \[([^\]]+)\]/).flatten)
        versions.concat(capture("readelf", "--version-info", path).scan(/GLIBC_(\d+\.\d+)/).flatten)
        interpreters.concat(capture("readelf", "-l", path).scan(/Requesting program interpreter: ([^\]]+)/).flatten)
      end
      libc = target.fetch("libc")
      if libc == "static" && (!required.empty? || !interpreters.empty?)
        raise Error, "target declares static but contains dynamic ELF binaries"
      end
      if libc == "musl" && (!versions.empty? || interpreters.any? { |value| !value.include?("musl") })
        raise Error, "target declares musl but contains a different libc ABI"
      end
      if libc == "glibc" && interpreters.any? { |value| value.include?("musl") }
        raise Error, "target declares glibc but contains a musl loader"
      end
      raise Error, "APK binary targets need musl/static inputs; glibc compatibility is not inferred" if format == "apk" && libc == "glibc"
      external = required.uniq - bundled
      glibc = versions.max_by { |version| Gem::Version.new(version) }
      if %w[deb rpm].include?(format)
        overrides = package["overrides"] ||= {}
        override = overrides[format] ||= {}
        depends = override.fetch("depends", package.fetch("depends", [])).dup
        external.each do |library|
          next if /\A(?:lib(?:c|m|dl|rt|pthread|resolv)\.so\.|ld-linux)/.match?(library)
          dependency = @libraries[library]&.[](format)
          raise Error, "add libraries.#{library}.#{format} and declare runtime-loaded dependencies" unless dependency
          depends << dependency
        end
        if glibc
          previous = depends.grep(format == "deb" ? /\Alibc6(?: |$)/ : /\Aglibc(?: |$)/)
          floor = ([glibc] + previous.flat_map { |value| value.scan(/\d+\.\d+/) }).max_by { |value| Gem::Version.new(value) }
          depends -= previous
          depends << (format == "deb" ? "libc6 (>= #{floor})" : "glibc >= #{floor}")
        end
        override["depends"] = depends.uniq
      elsif !external.empty? && package.fetch("overrides", {}).fetch(format, {}).fetch("depends", package.fetch("depends", [])).empty?
        raise Error, "#{format}: declare dependencies for #{external.join(', ')}"
      end
      { "kind" => "elf", "binaries" => binaries.length, "architecture" => target.fetch("arch"), "libc" => libc,
        "required_libraries" => external.sort, "glibc_floor" => glibc, "installation" => "not-tested" }
    end
  end
end
