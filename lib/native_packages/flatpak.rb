# frozen_string_literal: true

require_relative "staging"

module NativePackages
  # Builds a single-file Flatpak bundle from the same contents nFPM packages.
  # The app is already built, so this uses flatpak's own build commands
  # (build-finish, build-export, build-bundle) on the staged files, without
  # flatpak-builder, an SDK or the network. Files installed under /usr go to
  # /app; the runtime supplies the libraries.
  #
  # This never writes or submits a Flathub manifest: Flathub does not accept
  # AI-assisted manifests or submissions.
  class Flatpak
    include Support
    include Staging
    # nFPM architecture => Flatpak architecture.
    ARCHES = { "amd64" => "x86_64", "arm64" => "aarch64" }.freeze
    KEYS = %w[id runtime runtime_version sdk command finish_args metainfo branch runtime_repo repository].freeze
    # Reverse-DNS: three or more elements, no hyphen in the last one.
    ID = /\A(?=.{1,255}\z)(?:[A-Za-z_][A-Za-z0-9_-]*\.){2,}[A-Za-z_][A-Za-z0-9_]*\z/
    RUNTIME = /\A(?:[A-Za-z_][A-Za-z0-9_-]*\.)+[A-Za-z_][A-Za-z0-9_]*\z/
    BRANCH = /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/
    ICON_DIRECTORIES = %w[share/icons share/pixmaps].freeze
    attr_reader :root, :settings

    def initialize(configuration)
      @root = configuration.root
      @settings = configuration.data.fetch("flatpak", {})
    end

    def self.architecture(target)
      ARCHES.fetch(target.fetch("arch")) { raise Error, "flatpak does not support #{target.fetch('arch')}; use #{ARCHES.keys.join(', ')}" }
    end

    def self.filename(name, version, target) = "#{name}-#{version}-#{architecture(target)}.flatpak"

    def self.validate(data)
      building = data.fetch("targets").values.any? { |target| target.fetch("formats", []).include?("flatpak") }
      settings = data["flatpak"]
      raise Error, "flatpak targets need a top-level flatpak section" if building && settings.nil?
      return if settings.nil?
      raise Error, "flatpak: expected a mapping" unless settings.is_a?(Hash)
      raise Error, "flatpak: no target builds the flatpak format" unless building
      unknown = settings.keys - KEYS
      raise Error, "flatpak: unknown fields #{unknown.join(', ')}" unless unknown.empty?
      raise Error, "flatpak.id: use a reverse-DNS application ID such as org.example.App" unless settings["id"].is_a?(String) && ID.match?(settings["id"])
      %w[runtime sdk].each do |key|
        next if key == "sdk" && !settings.key?(key)
        raise Error, "flatpak.#{key}: expected a runtime ID such as org.freedesktop.Platform" unless settings[key].is_a?(String) && RUNTIME.match?(settings[key])
      end
      %w[runtime_version branch].each do |key|
        next if key == "branch" && !settings.key?(key)
        raise Error, "flatpak.#{key}: expected a branch such as 24.08 or stable" unless settings[key].is_a?(String) && BRANCH.match?(settings[key])
      end
      command = settings["command"]
      unless command.is_a?(String) && (/\A[A-Za-z0-9_][A-Za-z0-9_.+-]*\z/.match?(command) || command.start_with?("/app/"))
        raise Error, "flatpak.command: name a program in /app/bin, or an absolute /app path"
      end
      arguments = settings.fetch("finish_args", [])
      unless arguments.is_a?(Array) && arguments.all? { |argument| argument.is_a?(String) && argument.start_with?("--") && !argument.start_with?("--command") }
        raise Error, "flatpak.finish_args: use a list of flatpak build-finish options such as --socket=wayland"
      end
      if settings.key?("metainfo") && !(settings["metainfo"].is_a?(String) && Pathname.new(settings["metainfo"]).relative?)
        raise Error, "flatpak.metainfo: expected a path relative to the configuration"
      end
      if settings.key?("runtime_repo") && !(settings["runtime_repo"].is_a?(String) && settings["runtime_repo"].start_with?("https://"))
        raise Error, "flatpak.runtime_repo: expected an https:// .flatpakrepo URL"
      end
    end

    def id = settings.fetch("id")
    def branch = settings.fetch("branch", "stable")

    def doctor(target)
      self.class.architecture(target)
      raise Error, "install flatpak to build Flatpak bundles" unless available?("flatpak")
    end

    # Returns the bundle's path and what went into it.
    def build(package, target, destination, name:, version:, epoch:)
      doctor(target)
      arch = self.class.architecture(target)
      output = destination / self.class.filename(name, version, target)
      Dir.mktmpdir("native-packages-flatpak-") do |directory|
        directory = Pathname.new(directory)
        tree = directory / "tree"
        tree.mkpath
        stage(package, tree, "flatpak")
        outside = tree.children.map { |path| "/#{path.basename}" } - ["/usr"]
        raise Error, "flatpak: Flatpak apps install only under /usr, which becomes /app; move #{outside.join(', ')}" unless outside.empty?
        build = directory / "build"
        build.mkpath
        files = build / "files"
        (tree / "usr").exist? ? (tree / "usr").rename(files) : files.mkpath
        details = integrate(files)
        metadata = ["[Application]", "name=#{id}", "runtime=#{settings.fetch('runtime')}/#{arch}/#{settings.fetch('runtime_version')}"]
        metadata << "sdk=#{settings.fetch('sdk')}/#{arch}/#{settings.fetch('runtime_version')}" if settings["sdk"]
        write(build / "metadata", metadata.join("\n") + "\n")
        # Installed runtimes would add their own permissions to the metadata;
        # hide them so every host writes the same app.
        installations = directory / "installations"
        environment = { "FLATPAK_SYSTEM_DIR" => (installations / "system").to_s, "FLATPAK_USER_DIR" => (installations / "user").to_s }
        command = settings.fetch("command")
        run "flatpak", "build-finish", "--command=#{command}", *settings.fetch("finish_args", []), build, env: environment
        normalize(build, epoch)
        repository = directory / "repository"
        run "flatpak", "build-export", "--arch=#{arch}", "--timestamp=#{Time.at(epoch).utc.iso8601}", "--no-update-summary",
          "--disable-fsync", repository, build, branch, env: environment
        bundle = ["flatpak", "build-bundle", "--arch=#{arch}"]
        bundle << "--runtime-repo=#{settings['runtime_repo']}" if settings["runtime_repo"]
        run(*bundle, repository, output, id, branch, env: environment)
        check(output, arch)
        # The same inputs give the same commit. The bundle file around it
        # also records when it was written, which SOURCE_DATE_EPOCH does not
        # change, so its hash differs between builds.
        commit = (repository / "refs/heads/app/#{id}/#{arch}/#{branch}").read.strip
        [output, details.merge("id" => id, "branch" => branch, "commit" => commit,
          "runtime" => "#{settings.fetch('runtime')}//#{settings.fetch('runtime_version')}", "command" => command, "libraries" => "runtime")]
      end
    end

    # Fails unless `path` is a Flatpak bundle of this app for `arch`.
    def check(path, arch)
      bytes = path.binread(4096) || ""
      raise Error, "not a Flatpak bundle: #{path}" unless bytes.start_with?("flatpak\0".b)
      raise Error, "#{path.basename} does not hold app/#{id}/#{arch}/#{branch}" unless bytes.include?("app/#{id}/#{arch}/#{branch}".b)
    end

    # Flatpak exports only desktop entries, icons and metainfo named after
    # the app ID, so rename the package's own to match.
    def integrate(files)
      command = settings.fetch("command")
      executable = command.start_with?("/") ? files / relative_path(command.delete_prefix("/app/")) : files / "bin" / command
      raise Error, "flatpak: command #{command} is not an executable the package installs" unless executable.file? && executable.executable?
      details = { "desktop" => nil, "icon" => nil, "metainfo" => nil }
      entries = Pathname.glob(files / "share/applications/*.desktop")
      raise Error, "flatpak: at most one desktop entry in /usr/share/applications; found #{entries.length}" if entries.length > 1
      if (desktop = entries.first)
        lines = desktop.read.lines
        icon = lines.find { |line| line.start_with?("Icon=") }&.delete_prefix("Icon=")&.strip
        if icon && icon != id
          raise Error, "flatpak: Icon must be a name, not a path" if icon.include?("/")
          icons = ICON_DIRECTORIES.flat_map { |path| Pathname.glob(files / path / "**" / "#{icon}.{svg,png}") }
          raise Error, "flatpak: the package installs no #{icon}.svg or #{icon}.png icon" if icons.empty?
          icons.each { |path| path.rename(path.dirname / "#{id}#{path.extname}") }
          lines = lines.map { |line| line.start_with?("Icon=") && line.delete_prefix("Icon=").strip == icon ? "Icon=#{id}\n" : line }
        end
        desktop.delete
        write(files / "share/applications/#{id}.desktop", lines.join)
        details["desktop"] = "#{id}.desktop"
        details["icon"] = id if icon
      end
      if settings["metainfo"]
        source = root / relative_path(settings["metainfo"])
        raise Error, "flatpak.metainfo: #{settings['metainfo']} does not exist" unless source.file?
        write(files / "share/metainfo/#{id}.metainfo.xml", source.binread)
      end
      metainfo = Pathname.glob(files / "share/{metainfo,appdata}/*.xml")
      unless metainfo.empty?
        named = metainfo.find { |path| path.basename.to_s.start_with?("#{id}.") }
        raise Error, "flatpak: name the metainfo file #{id}.metainfo.xml" unless named
        unless named.read.match?(%r{<id>\s*#{Regexp.escape(id)}(?:\.desktop)?\s*</id>})
          raise Error, "flatpak: #{named.basename} does not declare <id>#{id}</id>"
        end
        details["metainfo"] = named.basename.to_s
      end
      details
    end
  end
end
