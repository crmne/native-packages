# frozen_string_literal: true

require_relative "build"

module NativePackages
  # Writes a first Omarchy recipe (omacom/omarchy-pkgs) from the app's AUR -bin
  # templates. Omarchy's bot then opens every later version bump itself, from
  # the upstream declaration in .omarchy/package.json, so this runs once.
  class Omarchy
    include Support
    ARCHITECTURES = %w[x86_64 aarch64].freeze
    # The policy RawMakase and superwhisper-bin use: hourly, self-merging updates that wait a day
    # after each GitHub release and go to every channel at once.
    POLICY = { "source" => "local", "auto_merge" => true, "release_ring" => "fast", "min_release_age" => "24h" }.freeze
    PROBE = "999.0.0"
    # Releases are tagged vMAJOR.MINOR.PATCH; the watch must match the whole tag.
    TAG_PATTERN = "v(?P<version>[0-9]+(?:\\.[0-9]+)*)"

    attr_reader :configuration, :root

    def initialize(configuration)
      @configuration = configuration
      @root = configuration.root
    end

    def recipe(checkout, release:, package: nil)
      configuration.validate
      version = version_arg(release)
      name = package || bin_package
      templates = configuration.data.fetch("templates").select { |path, _| path.start_with?("arch/#{name}/") }
      raise Error, "no template for arch/#{name}/PKGBUILD" unless templates.key?("arch/#{name}/PKGBUILD")
      checkout = Pathname.new(checkout).expand_path
      raise Error, "#{checkout} is not an omarchy-pkgs checkout (no pkgbuilds/)" unless (checkout / "pkgbuilds").directory?
      destination = checkout / "pkgbuilds" / name
      raise Error, "#{destination} exists; after the first PR Omarchy's bot updates it" if destination.exist? || destination.symlink?

      build = Build.new(configuration)
      metadata = build.metadata(version, release: true).merge("PKGREL" => 1)
      checksums = build.release_checksums(metadata)
      configuration.data.fetch("assets").each_key do |key|
        digest = checksums[metadata.fetch("#{key}_FILE")]
        metadata["#{key}_SHA256"] = digest if digest
      end

      Dir.mktmpdir(".#{name}-", checkout / "pkgbuilds") do |temporary|
        staging = Pathname.new(temporary) / name
        templates.each do |path, source|
          template = root / relative_path(source)
          content = render(template.binread, metadata)
          content = follow_pkgver(content, version) if File.basename(path) == "PKGBUILD"
          write(staging / relative_path(path).relative_path_from(Pathname.new("arch/#{name}")), content, executable: template.executable?)
        end
        upstream = declaration(staging, name, version, checksums)
        write(staging / ".omarchy/package.json", JSON.pretty_generate(POLICY.merge("upstream" => upstream)) + "\n")
        staging.rename(destination)
      end
      puts "Wrote #{destination}"
    end

    # The one AUR binary recipe, unless the caller names it.
    def bin_package
      names = configuration.data.fetch("templates").keys.filter_map { |path| path[%r{\Aarch/([^/]+-bin)/PKGBUILD\z}, 1] }
      raise Error, "no arch/NAME-bin/PKGBUILD template; add one or pass --package" if names.empty?
      raise Error, "several -bin templates (#{names.join(', ')}); pass --package" if names.length > 1
      names.first
    end

    # Omarchy's bot rewrites only pkgver, pkgrel and the checksums, so every
    # source URL has to be written in terms of pkgver.
    def follow_pkgver(content, version)
      literal = /(?<![0-9.])#{Regexp.escape(version)}(?![0-9])/
      content.gsub(/^source(?:_[A-Za-z0-9_]+)?=\(.*?\)/m) { |array| array.gsub(literal, "${pkgver}") }
    end

    def declaration(staging, name, version, checksums)
      pkgbuild = staging / "PKGBUILD"
      run "bash", "-n", pkgbuild
      upstream = configuration.project.upstream
      sources = {}
      architectures = nil
      ARCHITECTURES.each do |arch|
        recipe = inspect_recipe(pkgbuild, arch)
        architectures ||= recipe.fetch("arch")
        raise Error, "PKGBUILD pkgname must be #{name}" unless recipe.fetch("pkgname") == [name]
        raise Error, "PKGBUILD pkgver must be #{version}" unless recipe.fetch("pkgver") == [version]
        unless !architectures.empty? && (architectures - ARCHITECTURES).empty?
          raise Error, "PKGBUILD arch must list x86_64 and/or aarch64"
        end
        if recipe.fetch("source").any? { |entry| entry.split("::", 2).last.match?(%r{\A[a-z+]+://}) }
          raise Error, "move downloads into source_<arch>: each architecture downloads its own release assets"
        end
        next unless architectures.include?(arch)

        urls = recipe.fetch("source_#{arch}").map { |entry| entry.split("::", 2).last }
        sums = recipe.fetch("sha256sums_#{arch}")
        raise Error, "source_#{arch} must download the release assets" if urls.empty?
        raise Error, "sha256sums_#{arch} must match source_#{arch}" unless sums.length == urls.length
        prefix = "#{upstream}/releases/download/v#{version}/"
        urls.each_with_index do |url, index|
          raise Error, "source_#{arch} leaves a variable unexpanded; use double quotes: #{url}" if url.include?("$")
          raise Error, "source_#{arch} must come from #{prefix}: #{url}" unless url.start_with?(prefix)
          file = url.delete_prefix(prefix)
          raise Error, "#{file} is not listed in the release checksums" unless checksums.key?(file)
          raise Error, "sha256sums_#{arch} disagrees with the release checksums for #{file}" unless sums[index] == checksums.fetch(file)
        end
        sources[arch] = urls
      end
      # Prove the URLs move with pkgver, as they will when the bot bumps it.
      probe = staging / "PKGBUILD.probe"
      probe.write(pkgbuild.read.sub(/^pkgver=.*$/, "pkgver=#{PROBE}"))
      begin
        sources.each do |arch, urls|
          moved = inspect_recipe(probe, arch).fetch("source_#{arch}").map { |entry| entry.split("::", 2).last }
          raise Error, "source_#{arch} does not follow pkgver" unless moved == urls.map { |url| url.gsub(version, PROBE) }
        end
      ensure
        probe.delete
      end
      # The watch takes each new tag's SHA-256 from the digest GitHub reports
      # for the asset at that exact URL, which is why every source above must
      # be a release download and match the release's own checksums.
      { "watch" => { "github" => configuration.data.fetch("release").fetch("repository"), "pattern" => TAG_PATTERN } }
    end

    # Source the recipe the way omarchy-pkgs' tooling does: CARCH set and
    # nothing else from the environment.
    def inspect_recipe(path, arch)
      script = <<~'BASH'
        source "$1" >/dev/null
        emit() { printf '%s' "$1"; shift; printf '\t%s' "$@"; printf '\n'; }
        emit pkgname "${pkgname[@]}"; emit pkgver "$pkgver"; emit arch "${arch[@]}"; emit source "${source[@]}"
        for name in source_x86_64 source_aarch64 sha256sums_x86_64 sha256sums_aarch64; do
          declare -n values="$name"; emit "$name" "${values[@]}"; unset -n values
        done
      BASH
      output = capture("env", "-i", "PATH=/usr/bin:/bin", "CARCH=#{arch}", "bash", "-c", script, "bash", path.basename, chdir: path.dirname)
      output.lines.to_h { |line| key, *values = line.chomp.split("\t", -1); [key, values.reject(&:empty?)] }
    end
  end
end
