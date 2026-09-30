# frozen_string_literal: true

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
    attr_reader :root

    def initialize(root)
      @root = root
    end

    def self.architecture(target)
      RUNTIMES.fetch(target.fetch("arch")) { raise Error, "appimage does not support #{target.fetch('arch')}; use #{RUNTIMES.keys.join(', ')}" }.first
    end

    def self.filename(name, version, target) = "#{name}-#{version}-#{architecture(target)}.AppImage"

    def doctor(target)
      self.class.architecture(target)
      missing = %w[mksquashfs curl].reject { |tool| available?(tool) }
      raise Error, "install required AppImage tools: #{missing.join(', ')} (mksquashfs is in squashfs-tools)" unless missing.empty?
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

    # Returns the AppImage's path and what was put at the AppDir's root.
    def build(package, target, destination, name:, version:, epoch:)
      doctor(target)
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
        File.open(output, "wb") do |file|
          file.write(runtime(target).binread)
          IO.copy_stream(image.to_s, file)
        end
        output.chmod(0o755)
        check(output)
        [output, entry.merge("runtime" => RUNTIME, "libraries" => "host")]
      end
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
