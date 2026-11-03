# frozen_string_literal: true

require_relative "staging"

module NativePackages
  # Builds a .snap from the same contents nFPM packages: the files become the
  # snap's root, beside a generated meta/snap.yaml, packed with mksquashfs
  # as `snap pack` packs a prime directory. No snapcraft, LXD or network is
  # involved, and no extension (such as gnome) is applied, so the snap uses
  # its base snap's libraries and whatever the package installs.
  class Snap
    include Support
    include Staging
    # nFPM architecture => Snap architecture.
    ARCHES = { "amd64" => "amd64", "arm64" => "arm64", "arm7" => "armhf", "ppc64le" => "ppc64el", "s390x" => "s390x",
      "riscv64" => "riscv64" }.freeze
    KEYS = %w[name summary description title license base confinement grade icon apps plugs slots layout environment store].freeze
    APP_KEYS = %w[command desktop plugs slots environment daemon command-chain common-id restart-condition stop-command
      install-mode autostart].freeze
    NAME = /\A(?=.{2,40}\z)(?=[a-z0-9-]*[a-z])[a-z0-9]+(?:-[a-z0-9]+)*\z/
    APP = /\A[a-zA-Z0-9](?:-?[a-zA-Z0-9])*\z/
    CHANNEL = %r{\A(?:[a-z0-9][a-z0-9._-]*/)?(?:stable|candidate|beta|edge)(?:/[a-z0-9][a-z0-9._-]*)?\z}
    CREDENTIALS = "SNAPCRAFT_STORE_CREDENTIALS"
    attr_reader :root, :settings, :name

    def initialize(configuration)
      @root = configuration.root
      @settings = configuration.data.fetch("snap", {})
      @name = settings.fetch("name", configuration.name)
    end

    def self.architecture(target)
      ARCHES.fetch(target.fetch("arch")) { raise Error, "snap does not support #{target.fetch('arch')}; use #{ARCHES.keys.join(', ')}" }
    end

    def self.validate(data)
      building = data.fetch("targets").values.any? { |target| target.fetch("formats", []).include?("snap") }
      settings = data["snap"]
      raise Error, "snap targets need a top-level snap section" if building && settings.nil?
      return if settings.nil?
      raise Error, "snap: expected a mapping" unless settings.is_a?(Hash)
      raise Error, "snap: no target builds the snap format" unless building
      unknown = settings.keys - KEYS
      raise Error, "snap: unknown fields #{unknown.join(', ')}" unless unknown.empty?
      name = settings.fetch("name", data.fetch("nfpm").fetch("name"))
      raise Error, "snap.name: use 2 to 40 lowercase letters, digits and single hyphens, as #{name.inspect} is not" unless name.is_a?(String) && NAME.match?(name)
      raise Error, "snap.base: expected a base such as core24" unless settings["base"].is_a?(String) && /\A(?:core\d{2}|bare)\z/.match?(settings["base"])
      raise Error, "snap.confinement: use strict, classic or devmode" unless %w[strict classic devmode].include?(settings.fetch("confinement", "strict"))
      raise Error, "snap.grade: use stable or devel" unless %w[stable devel].include?(settings.fetch("grade", "stable"))
      summary = settings.fetch("summary", data.fetch("nfpm")["description"].to_s.lines.first.to_s.strip)
      raise Error, "snap.summary: write a summary of at most 78 characters" unless summary.is_a?(String) && !summary.empty? && summary.length <= 78
      %w[description title license].each do |key|
        raise Error, "snap.#{key}: expected a string" if settings.key?(key) && !settings[key].is_a?(String)
      end
      %w[plugs slots layout environment].each do |key|
        raise Error, "snap.#{key}: expected a mapping" if settings.key?(key) && !settings[key].is_a?(Hash)
      end
      if settings.key?("icon") && !(settings["icon"].is_a?(String) && settings["icon"].match?(/\.(?:png|svg)\z/))
        raise Error, "snap.icon: name a .png or .svg file the package installs, such as /usr/share/icons/hicolor/scalable/apps/app.svg"
      end
      apps = settings["apps"]
      raise Error, "snap.apps: declare at least one app with a command" unless apps.is_a?(Hash) && !apps.empty?
      apps.each do |app, definition|
        raise Error, "snap.apps: invalid app name #{app.inspect}" unless app.is_a?(String) && APP.match?(app)
        raise Error, "snap.apps.#{app}: expected a mapping" unless definition.is_a?(Hash)
        unknown = definition.keys - APP_KEYS
        raise Error, "snap.apps.#{app}: unknown fields #{unknown.join(', ')}" unless unknown.empty?
        unless definition["command"].is_a?(String) && !definition["command"].strip.empty?
          raise Error, "snap.apps.#{app}.command: name a program the package installs, such as usr/bin/#{name}"
        end
        %w[plugs slots].each do |key|
          next unless definition.key?(key)
          raise Error, "snap.apps.#{app}.#{key}: expected a list of names" unless definition[key].is_a?(Array) && definition[key].all?(String)
        end
        raise Error, "snap.apps.#{app}.desktop: name a .desktop file the package installs" if definition.key?("desktop") && !definition["desktop"].to_s.end_with?(".desktop")
      end
      store = settings["store"]
      return if store.nil?
      raise Error, "snap.store: expected a mapping with channels" unless store.is_a?(Hash) && store.keys == ["channels"]
      channels = store["channels"]
      unless channels.is_a?(Array) && !channels.empty? && channels.all? { |channel| channel.is_a?(String) && CHANNEL.match?(channel) }
        raise Error, "snap.store.channels: list channels such as stable or latest/edge"
      end
    end

    def filename(version, target) = "#{name}_#{version}_#{self.class.architecture(target)}.snap"

    def doctor(target)
      self.class.architecture(target)
      raise Error, "install mksquashfs (squashfs-tools) to build snaps" unless available?("mksquashfs")
    end

    # Returns the snap's path and what went into it.
    def build(package, target, destination, version:, epoch:)
      doctor(target)
      raise Error, "snap versions are at most 32 characters" if version.length > 32
      output = destination / filename(version, target)
      Dir.mktmpdir("native-packages-snap-") do |directory|
        prime = Pathname.new(directory) / "prime"
        prime.mkpath
        stage(package, prime, "snap")
        raise Error, "snap: the package must not install /meta or /snap, which the snap's own metadata uses" if (prime / "meta").exist? || (prime / "snap").exist?
        apps = settings.fetch("apps").to_h { |app, definition| [app, integrate(prime, app, definition)] }
        if settings["icon"]
          icon = inside(prime, settings["icon"], "snap")
          raise Error, "snap.icon: the package installs no #{settings['icon']}" unless icon.file?
          write(prime / "meta/gui/icon#{icon.extname}", icon.binread)
          apps.each_key do |app|
            desktop = prime / "meta/gui/#{app}.desktop"
            write(desktop, desktop.read.gsub(/^Icon=.*$/, "Icon=${SNAP}/meta/gui/icon#{icon.extname}")) if desktop.file?
          end
        end
        write(prime / "meta/snap.yaml", YAML.dump(metadata(package, version, target, apps)).delete_prefix("---\n"))
        normalize(prime, epoch)
        run "mksquashfs", prime, output, "-noappend", "-comp", "xz", "-no-fragments", "-no-progress", "-quiet", "-all-root", "-no-xattrs",
          env: { "SOURCE_DATE_EPOCH" => epoch.to_s }
        check(output)
        [output, { "name" => name, "base" => settings.fetch("base"), "confinement" => settings.fetch("confinement", "strict"),
          "apps" => apps.keys, "libraries" => "base" }]
      end
    end

    # meta/snap.yaml. The summary, description and license default to the
    # package's.
    def metadata(package, version, target, apps)
      result = { "name" => name, "version" => version, "summary" => settings.fetch("summary", package.fetch("description").lines.first.strip),
        "description" => settings.fetch("description", package.fetch("description")) }
      result["title"] = settings["title"] if settings["title"]
      license = settings.fetch("license", package["license"])
      result["license"] = license if license
      result.merge!("base" => settings.fetch("base"), "grade" => settings.fetch("grade", "stable"),
        "confinement" => settings.fetch("confinement", "strict"), "architectures" => [self.class.architecture(target)], "apps" => apps)
      %w[plugs slots layout environment].each { |key| result[key] = settings[key] if settings[key] }
      result
    end

    # Checks the app's command and puts its desktop entry in meta/gui, where
    # snapd looks for it, launching the snap's app.
    def integrate(prime, app, definition)
      command = Shellwords.split(definition.fetch("command")).first.delete_prefix("$SNAP/")
      executable = prime / relative_path(command)
      raise Error, "snap.apps.#{app}.command: the package installs no executable #{command}" unless executable.file? && executable.executable?
      if (desktop = definition["desktop"])
        source = inside(prime, desktop.start_with?("/") ? desktop : "/#{desktop}", "snap")
        raise Error, "snap.apps.#{app}.desktop: the package installs no #{desktop}" unless source.file?
        launcher = app == name ? name : "#{name}.#{app}"
        entry = source.read.gsub(/^Exec=(\S+)/) { "Exec=#{launcher}" }
        write(prime / "meta/gui/#{app}.desktop", entry)
      end
      definition.except("desktop")
    end

    # Fails unless `path` is a squashfs image, the format of every snap.
    def check(path)
      raise Error, "not a snap (squashfs) file: #{path}" unless path.binread(4) == "hsqs".b
    end

    def publish(paths)
      channels = settings.dig("store", "channels") or raise Error, "configure snap.store.channels to publish --to snapcraft"
      raise Error, "set #{CREDENTIALS} to a Snap Store login from snapcraft export-login" if ENV.fetch(CREDENTIALS, "").empty?
      raise Error, "install snapcraft to publish to the Snap Store" unless available?("snapcraft")
      raise Error, "the build contains no snaps" if paths.empty?
      paths.each { |path| run "snapcraft", "upload", "--release=#{channels.join(',')}", path }
    end
  end
end
