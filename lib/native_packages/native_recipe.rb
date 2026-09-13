# frozen_string_literal: true

require "find"

module NativePackages
  # Coordinate application-owned native recipes. The gem owns the input copy,
  # output boundary and manifest; applications retain installer/signing policy.
  class NativeRecipe
    include Support
    MACHO = ["feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"].freeze
    attr_reader :root

    def initialize(root)
      @root = root
    end

    def self.host
      return "windows" if Gem.win_platform?
      RUBY_PLATFORM.include?("darwin") ? "macos" : "linux"
    end

    def doctor(target, command)
      raise Error, "#{target.fetch('platform')} packaging must run on that native host" unless self.class.host == target.fetch("platform")
      required = [command.first]
      required << "lipo" if target["platform"] == "macos"
      missing = required.reject { |tool| available?(tool) || (Pathname.new(tool).absolute? && File.file?(tool) && File.executable?(tool)) }
      raise Error, "install required native tools: #{missing.join(', ')}" unless missing.empty?
    end

    def tree(path)
      path = Pathname.new(path)
      raise Error, "native input must be a real directory" unless path.directory? && !path.symlink?
      boundary = path.realpath.to_s + File::SEPARATOR
      Find.find(path.to_s).sort.map do |name|
        item = Pathname.new(name)
        stat = item.lstat
        relative = item.relative_path_from(path).to_s
        if stat.symlink?
          link = item.readlink
          unless !link.absolute? && item.realpath.to_s.start_with?(boundary)
            raise Error, "native input symlink leaves the payload: #{relative}"
          end
          [relative, "symlink", link.to_s]
        elsif stat.directory?
          [relative, "directory", stat.mode & 0o777]
        elsif stat.file?
          [relative, "file", stat.mode & 0o777, sha256(item)]
        else
          raise Error, "unsupported native input entry: #{relative}"
        end
      end
    rescue Errno::ENOENT, Errno::ELOOP => error
      raise Error, "invalid native input link or missing entry: #{error.message}"
    end

    def digest(path) = OpenSSL::Digest::SHA256.hexdigest(JSON.generate(tree(path)))

    def inspect(payload, target)
      paths = tree(payload).filter_map { |relative, kind, *| payload / relative if kind == "file" }
      return Inspection.new(root).pe(paths, target) if target["platform"] == "windows"
      expected = { "amd64" => "x86_64", "arm64" => "arm64", "universal" => "arm64 x86_64" }[target.fetch("arch")]
      raise Error, "Mach-O inspection supports amd64, arm64 and universal" unless expected
      binaries = paths.select { |path| MACHO.include?(path.binread(4).unpack1("H*")) }
      raise Error, "macOS target contains no Mach-O binaries" if binaries.empty?
      binaries.each do |path|
        arches = capture("lipo", "-archs", path).split.sort
        raise Error, "wrong Mach-O architecture: #{path}" unless (expected.split - arches).empty?
      end
      { "kind" => "macho", "binaries" => binaries.length, "architecture" => target.fetch("arch"), "dependencies" => "explicit", "installation" => "not-tested" }
    end

    def check_output(path, format)
      raise Error, "native recipe must create a regular package file" unless path.file? && !path.symlink?
      valid = File.open(path, "rb") do |file|
        if format == "dmg"
          next false if file.size < 512
          file.seek(-512, IO::SEEK_END)
          file.read(4) == "koly"
        else
          next false unless file.size >= 64 && file.read(2) == "MZ"
          file.seek(0x3c)
          offset = file.read(4).unpack1("L<")
          next false unless offset >= 64 && offset + 24 <= file.size
          file.seek(offset)
          file.read(4) == "PE\0\0"
        end
      end
      raise Error, "native recipe output is not a #{format} container" unless valid
    end
  end
end
