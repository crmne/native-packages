# frozen_string_literal: true

require_relative "flatpak"
require_relative "hosted_repository"

module NativePackages
  # A signed, self-hosted Flatpak repository: an OSTree repository that the
  # build's bundles are imported into, served as static files, with a
  # NAME.flatpakrepo and an ID.flatpakref beside it for users to add.
  #
  # This is not Flathub. Flathub does not accept AI-assisted manifests or
  # submissions, so native-packages neither writes nor submits one.
  class FlatpakRepository < HostedRepository
    # Each bundle is a commit without a parent, so a ref has no history to
    # keep: the repository serves the newest commit of each app.
    KEYS = (HostedRepository::KEYS - %w[keep] + %w[title homepage]).freeze

    def self.validate(data)
      settings = data["flatpak"].is_a?(Hash) ? data["flatpak"]["repository"] : nil
      return if settings.nil?
      check(settings, "flatpak.repository", KEYS)
      %w[title homepage].each do |key|
        raise Error, "flatpak.repository.#{key}: expected a string" if settings.key?(key) && !settings[key].is_a?(String)
      end
      if settings.key?("homepage") && !settings["homepage"].start_with?("https://")
        raise Error, "flatpak.repository.homepage: expected an https:// URL"
      end
    end

    def initialize(configuration)
      settings = configuration.data.fetch("flatpak", {})["repository"]
      raise Error, "configure flatpak.repository to publish --to flatpak" unless settings
      super(configuration, settings)
      @flatpak = Flatpak.new(configuration)
    end

    def title = settings.fetch("title", name)

    def publish(bundles, secret: nil, passphrase: nil)
      raise Error, "the build contains no Flatpak bundles to publish --to flatpak" if bundles.empty?
      missing = %w[flatpak ostree].reject { |tool| available?(tool) }
      raise Error, "install #{missing.join(' and ')} to publish --to flatpak" unless missing.empty?
      directory.mkpath
      run "ostree", "init", "--mode=archive-z2", "--repo=#{directory}" unless (directory / "config").file?
      signer(secret: secret, passphrase: passphrase).session do |signing|
        bundles.each { |bundle| run "flatpak", "build-import-bundle", "--no-update-summary", *signing.flatpak_options, directory, bundle }
        # Prune drops the objects only replaced commits used.
        run "flatpak", "build-update-repo", *signing.flatpak_options, "--title=#{title}", "--default-branch=#{@flatpak.branch}",
          "--prune", "--generate-static-deltas", directory
        key = [signing.public_key].pack("m0")
        homepage = settings["homepage"] ? ["Homepage=#{settings['homepage']}"] : []
        write(directory / "#{name}.flatpakrepo", (["[Flatpak Repo]", "Title=#{title}", "Url=#{url}/", *homepage,
          "DefaultBranch=#{@flatpak.branch}", "GPGKey=#{key}"].join("\n") + "\n"))
        runtime = @flatpak.settings["runtime_repo"] ? ["RuntimeRepo=#{@flatpak.settings['runtime_repo']}"] : []
        write(directory / "#{@flatpak.id}.flatpakref", (["[Flatpak Ref]", "Name=#{@flatpak.id}", "Branch=#{@flatpak.branch}", "Title=#{title}",
          "Url=#{url}/", "SuggestRemoteName=#{name}", *homepage, *runtime, "IsRuntime=false", "GPGKey=#{key}"].join("\n") + "\n"))
      end
      puts "Published #{bundles.length} Flatpak bundle#{"s" unless bundles.length == 1} to #{directory}. Install with:", *instructions.map { |line| "  #{line}" }
    end

    def instructions = ["flatpak install --user #{url}/#{@flatpak.id}.flatpakref"]
  end
end
