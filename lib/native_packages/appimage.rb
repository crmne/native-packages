# frozen_string_literal: true

require "digest"

module NativePackages
  # Builds a type 2 AppImage from the same contents nFPM packages: the files
  # are laid out in an AppDir, packed with mksquashfs and appended to a pinned
  # AppImage runtime. Libraries are not bundled; the AppImage uses the host's,
  # as the deb and rpm packages do.
  class AppImage
    include Support
    RUNTIME = "20251108"
    RUNTIME_URL = "https://github.com/AppImage/type2-runtime/releases/download/#{RUNTIME}"
    # nFPM architecture => [AppImage architecture, runtime SHA-256].
    RUNTIMES = {
      "amd64" => ["x86_64", "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"],
      "arm64" => ["aarch64", "00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444"],
      "386" => ["i686", "e72ea0b140a0a16e680713238a6f30aad278b62c4ca17919c554864124515498"],
      "arm7" => ["armhf", "e9060d37577b8a29914ec12d8740add24e19ff29012fb1fa0f60daf62db0688d"]
    }.freeze
    ICON_DIRECTORIES = %w[usr/share/icons usr/share/pixmaps].freeze
    # The runtime's ELF section that AppImageUpdate and the other updaters
    # read: a NUL-terminated string in a fixed 1024 bytes.
    UPDATE_SECTION = ".upd_info"
    # AppImage's update information formats, without the `bintray-zsync`
    # and `pling-v1-zsync` services that no longer exist.
    GITHUB_UPDATE = /\Agh-releases-zsync\|([A-Za-z0-9_.-]+)\|([A-Za-z0-9_.-]+)\|([^|\s]+)\|([^|\s]+\.zsync)\z/
    URL_UPDATE = %r{\Azsync\|https://[^|\s]+\.zsync\z}
    attr_reader :root

    def initialize(root)
      @root = root
    end

    def self.architecture(target)
      RUNTIMES.fetch(target.fetch("arch")) { raise Error, "appimage does not support #{target.fetch('arch')}; use #{RUNTIMES.keys.join(', ')}" }.first
    end

    def self.filename(name, version, target) = "#{name}-#{version}-#{architecture(target)}.AppImage"

    # The target's update information, checked against the AppImage it
    # describes: a GitHub string must name the release repository, and its
    # file pattern must match this target's `.zsync` file, so a release
    # never ships an AppImage whose updaters look for a file that is not
    # there. Returns nil when the target has none.
    def self.update_information(target, name:, version:, repository:)
      settings = target["appimage"]
      return nil if settings.nil?
      raise Error, "appimage: expected a mapping" unless settings.is_a?(Hash)
      unknown = settings.keys - %w[update_information]
      raise Error, "appimage: unknown fields #{unknown.join(', ')}" unless unknown.empty?
      value = settings["update_information"]
      raise Error, "appimage.update_information: expected a string" unless value.is_a?(String) && !value.empty?
      raise Error, "appimage.update_information: at most 1023 bytes" if value.bytesize > 1023
      if (match = GITHUB_UPDATE.match(value))
        owner, project, _tag, pattern = match.captures
        unless "#{owner}/#{project}".casecmp?(repository.to_s)
          raise Error, "appimage.update_information names #{owner}/#{project}, but release.repository is #{repository.inspect}"
        end
        zsync = "#{filename(name, version, target)}.zsync"
        unless File.fnmatch?(pattern, zsync, File::FNM_PATHNAME)
          raise Error, "appimage.update_information: #{pattern} does not match #{zsync}"
        end
      elsif !URL_UPDATE.match?(value)
        raise Error, "appimage.update_information: use gh-releases-zsync|OWNER|REPOSITORY|TAG|FILE.zsync or zsync|https://URL.zsync"
      end
      value
    end

    # The file offset and size of the ELF section `name` in `bytes`, or nil.
    # Every AppImage runtime is a little-endian ELF file, 32 or 64 bits.
    def self.section(bytes, name)
      raise Error, "AppImage runtime is not a little-endian ELF file" unless bytes.start_with?("\x7fELF".b) && bytes.getbyte(5) == 1
      wide = { 1 => false, 2 => true }.fetch(bytes.getbyte(4)) { raise Error, "AppImage runtime has an unknown ELF class" }
      offset = wide ? bytes.byteslice(0x28, 8).unpack1("Q<") : bytes.byteslice(0x20, 4).unpack1("V")
      size, count, names = bytes.byteslice(wide ? 0x3A : 0x2E, 6).unpack("v3")
      header = lambda do |index|
        entry = bytes.byteslice(offset + (index * size), size)
        raise Error, "AppImage runtime has a truncated section table" unless entry && entry.bytesize == size
        wide ? [entry.unpack1("V"), *entry.byteslice(0x18, 16).unpack("Q<2")] : [entry.unpack1("V"), *entry.byteslice(0x10, 8).unpack("V2")]
      end
      _, strings, = header.call(names)
      count.times do |index|
        label, start, length = header.call(index)
        found = bytes.byteslice(strings + label, name.bytesize + 1)
        return [start, length] if found == "#{name}\0".b
      end
      nil
    end

    # `runtime` with `information` in its update section.
    def self.embed(runtime, information)
      start, length = section(runtime, UPDATE_SECTION) || raise(Error, "AppImage runtime has no #{UPDATE_SECTION} section")
      raise Error, "update information exceeds the runtime's #{length}-byte #{UPDATE_SECTION} section" if information.bytesize >= length
      raise Error, "AppImage runtime's #{UPDATE_SECTION} section is outside the file" if start + length > runtime.bytesize
      runtime = runtime.b
      runtime[start, length] = information.b + ("\0".b * (length - information.bytesize))
      runtime
    end

    # The update information an AppImage carries, or nil when it has none.
    def self.read_update_information(path)
      bytes = File.binread(path)
      start, length = section(bytes, UPDATE_SECTION)
      return nil unless start
      value = bytes.byteslice(start, length)[/\A[^\0]*/n]
      value.empty? ? nil : value
    end

    def doctor(target, update: false)
      self.class.architecture(target)
      tools = %w[mksquashfs curl]
      tools << "zsyncmake" if update
      missing = tools.reject { |tool| available?(tool) }
      raise Error, "install required AppImage tools: #{missing.join(', ')} (mksquashfs is in squashfs-tools, zsyncmake in zsync)" unless missing.empty?
    end

    def runtime(target)
      architecture, digest = RUNTIMES.fetch(target.fetch("arch"))
      path = root / ".cache/native-packages/appimage-runtime" / RUNTIME / "runtime-#{architecture}"
      download("#{RUNTIME_URL}/runtime-#{architecture}", path)
      unless sha256(path) == digest
        path.delete
        raise Error, "AppImage runtime checksum mismatch: runtime-#{architecture}"
      end
      path
    end

    # Returns the AppImage's path, what was put at the AppDir's root, and
    # the `.zsync` file beside it when the AppImage carries update
    # information (nil otherwise).
    def build(package, target, destination, name:, version:, epoch:, update: nil)
      doctor(target, update: !update.nil?)
      output = destination / self.class.filename(name, version, target)
      Dir.mktmpdir("native-packages-appimage-") do |directory|
        appdir = Pathname.new(directory) / "AppDir"
        appdir.mkpath
        stage(package, appdir)
        entry = integrate(appdir)
        normalize(appdir, epoch)
        image = Pathname.new(directory) / "filesystem.squashfs"
        run "mksquashfs", appdir, image, "-root-owned", "-noappend", "-no-xattrs", "-no-progress", "-quiet", "-comp", "zstd",
          env: { "SOURCE_DATE_EPOCH" => epoch.to_s }
        bytes = runtime(target).binread
        bytes = self.class.embed(bytes, update) if update
        File.open(output, "wb") do |file|
          file.write(bytes)
          IO.copy_stream(image.to_s, file)
        end
        output.chmod(0o755)
        check(output)
        details = entry.merge("runtime" => RUNTIME, "libraries" => "host")
        return [output, details, nil] unless update
        raise Error, "AppImage lost its update information: #{output}" unless self.class.read_update_information(output) == update
        [output, details.merge("update_information" => update), zsync(output, epoch)]
      end
    end

    # Writes `<AppImage>.zsync` beside the AppImage, for updaters that fetch
    # only the blocks that changed. Its URL is the AppImage's file name,
    # relative to the `.zsync` file, so it works from wherever both are
    # published. The AppImage's time is the build's, which zsyncmake records.
    def zsync(path, epoch)
      File.utime(epoch, epoch, path)
      output = Pathname.new("#{path}.zsync")
      run "zsyncmake", "-u", path.basename.to_s, "-o", output, path, chdir: path.dirname
      check_zsync(output, path)
      output
    end

    # Fails unless `zsync` describes the AppImage at `path` as it is now.
    def check_zsync(zsync, path)
      header = zsync.binread.split("\n\n".b, 2).first.to_s.force_encoding(Encoding::UTF_8).lines.to_h do |line|
        key, value = line.chomp.split(": ", 2)
        [key, value]
      end
      expected = { "Filename" => path.basename.to_s, "URL" => path.basename.to_s, "Length" => path.size.to_s,
        "SHA-1" => Digest::SHA1.file(path).hexdigest }
      wrong = expected.reject { |key, value| header[key] == value }.keys
      raise Error, "#{zsync.basename} does not describe #{path.basename}: #{wrong.join(', ')}" unless wrong.empty?
    end

    def check(path)
      header = path.binread(11)
      raise Error, "not a type 2 AppImage: #{path}" unless header&.start_with?("\x7fELF".b) && header.byteslice(8, 3) == "AI\x02".b
    end

    # nFPM overrides replace the contents list when one is supplied.
    def contents(package)
      package.fetch("overrides", {}).fetch("appimage", {}).fetch("contents", package.fetch("contents"))
        .reject { |item| item["packager"] && item["packager"] != "appimage" }
    end

    def inside(appdir, destination)
      raise Error, "appimage: content destinations must be absolute: #{destination}" unless destination.to_s.start_with?("/")
      appdir / relative_path(destination.to_s.delete_prefix("/"))
    end

    def stage(package, appdir)
      contents(package).each do |item|
        type = item.fetch("type", "file")
        next if type == "ghost"
        target = inside(appdir, item.fetch("dst"))
        mode = item.dig("file_info", "mode")
        case type
        when "dir"
          target.mkpath
        when "symlink"
          target.dirname.mkpath
          File.symlink(item.fetch("src"), target)
        when "file", "tree", "config", "config|noreplace", "config|missingok"
          source = File.expand_path(item.fetch("src"), root)
          paths = package["disable_globbing"] ? [source].select { |path| File.exist?(path) } : Dir.glob(source).sort
          raise Error, "missing package content: #{source}" if paths.empty?
          # As nFPM does: a glob source, or a destination ending in a slash,
          # makes the destination a directory that takes each match's name.
          pattern = !package["disable_globbing"] && item.fetch("src").match?(/[*?\[{]/)
          single = paths.length == 1 && File.file?(paths.first) && type != "tree" && !pattern && !item.fetch("dst").end_with?("/")
          paths.each do |path|
            if File.directory?(path)
              target.mkpath
              FileUtils.cp_r(Dir.children(path).map { |child| File.join(path, child) }, target)
            else
              file = single ? target : target / File.basename(path)
              file.dirname.mkpath
              FileUtils.cp(path, file)
              file.chmod(mode) if mode
            end
          end
        else
          raise Error, "appimage: unsupported content type #{type}"
        end
      end
    end

    # AppImage's root needs the desktop entry, its icon and AppRun.
    def integrate(appdir)
      entries = Pathname.glob(appdir / "usr/share/applications/*.desktop")
      raise Error, "appimage needs exactly one desktop entry in /usr/share/applications; found #{entries.length}" unless entries.length == 1
      desktop = entries.first
      fields = desktop.read.lines.each_with_object({}) do |line, result|
        key, value = line.strip.split("=", 2)
        result[key] ||= value if value && %w[Exec Icon].include?(key)
      end
      command = Shellwords.split(fields.fetch("Exec") { raise Error, "appimage: #{desktop.basename} has no Exec" }).first
      executable = command.start_with?("/") ? inside(appdir, command) : appdir / "usr/bin" / relative_path(command)
      raise Error, "appimage: #{desktop.basename} runs #{command}, which the package does not install" unless executable.file? && executable.executable?
      name = fields.fetch("Icon") { raise Error, "appimage: #{desktop.basename} has no Icon" }
      raise Error, "appimage: Icon must be a name, not a path" if name.include?("/")
      icons = ICON_DIRECTORIES.flat_map { |path| Pathname.glob(appdir / path / "**" / "#{name}.{svg,png}") }
      # A scalable icon first, else the largest bitmap.
      icon = icons.find { |path| path.extname == ".svg" } || icons.max_by(&:size)
      raise Error, "appimage: the package installs no #{name}.svg or #{name}.png icon" unless icon
      FileUtils.cp(desktop, appdir / desktop.basename)
      FileUtils.cp(icon, appdir / icon.basename)
      File.symlink(icon.basename.to_s, appdir / ".DirIcon")
      File.symlink(executable.relative_path_from(appdir).to_s, appdir / "AppRun")
      { "desktop" => desktop.basename.to_s, "icon" => icon.basename.to_s, "executable" => executable.relative_path_from(appdir).to_s }
    end

    # The same bytes for the same inputs: fixed modes and times.
    def normalize(appdir, epoch)
      time = Time.at(epoch)
      Pathname.glob(appdir / "**/*", File::FNM_DOTMATCH).each do |path|
        next if path.basename.to_s == "."
        if path.symlink?
          File.lutime(time, time, path)
        else
          path.chmod(path.directory? || path.executable? ? 0o755 : 0o644)
          File.utime(time, time, path)
        end
      end
      appdir.chmod(0o755)
      File.utime(time, time, appdir)
    end
  end
end
