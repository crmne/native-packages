# frozen_string_literal: true

require_relative "support"
require_relative "repositories"

module NativePackages
  class Project
    include Support
    attr_reader :root, :config

    def initialize(root)
      @root = Pathname.new(root).realpath
      @config = YAML.safe_load_file(@root / "packaging/project.yml", permitted_classes: [], aliases: false)
      raise Error, "unsupported packaging configuration" unless config.fetch("version") == 1
      raise Error, "invalid package name" unless /\A[a-z0-9][a-z0-9-]*\z/.match?(package_name)
      config.fetch("assets").each_key do |key|
        raise Error, "invalid asset key: #{key}" unless /\A[A-Z][A-Z0-9_]*\z/.match?(key)
      end
    end

    def package_name = config.fetch("name")
    def repository = config.fetch("release_repository", config.fetch("repository"))
    def upstream = "https://github.com/#{repository}"
    def cache(version) = root / ".cache/packaging" / version
    def repositories = Repositories.new(project: self)

    def validate
      metadata = { "NAME" => package_name, "VERSION" => "9.8.7", "TAG" => "v9.8.7", "UPSTREAM" => upstream,
        "DATE" => "2026-01-01T00:00:00Z", "SOURCE_DATE_EPOCH" => 1_767_225_600, "GIT_VERSION" => "r123.abcdef0" }
      render_tree(config.fetch("assets"), metadata).each do |key, asset|
        metadata["#{key}_FILE"] = asset.fetch("file")
        metadata["#{key}_URL"] = asset.fetch("url", "#{upstream}/releases/download/v9.8.7/#{asset.fetch('file')}")
        metadata["#{key}_SHA256"] = "0" * 64
      end
      if config["binary"]
        render_tree(nfpm_definition, metadata.merge("ROOT" => root.to_s, "PAYLOAD" => "/payload",
          "ARCH" => "amd64", "TARGET" => "x86_64-unknown-linux-gnu"))
      end
      repositories
      Dir.mktmpdir("native-packages-validate-") do |temporary|
        output = Pathname.new(temporary)
        generate(output, metadata)
        check(output)
      end
    end

    def release_metadata(version)
      version = version_arg(version)
      tag = "v#{version}"
      commit = "#{tag}^{commit}"
      date = capture("git", "show", "-s", "--format=%cI", commit)
      metadata = { "NAME" => package_name, "VERSION" => version, "TAG" => tag, "UPSTREAM" => upstream,
        "DATE" => date, "SOURCE_DATE_EPOCH" => Time.iso8601(date).to_i,
        "GIT_VERSION" => "r#{capture('git', 'rev-list', '--count', commit)}.#{capture('git', 'rev-parse', '--short', commit)}" }
      assets = render_tree(config.fetch("assets"), metadata)
      checksums = cache(version) / "checksums.txt"
      download("#{upstream}/releases/download/#{tag}/checksums.txt", checksums)
      expected = checksums.readlines.to_h do |line|
        match = /\A([a-fA-F0-9]{64})\s+\*?(.+?)\s*\z/.match(line) or raise Error, "invalid release checksum entry"
        [match[2], match[1].downcase]
      end
      assets.each do |key, asset|
        file = asset.fetch("file")
        raise Error, "asset must be a filename" unless File.basename(file) == file
        path = cache(version) / file
        url = asset.fetch("url", "#{upstream}/releases/download/#{tag}/#{file}")
        download(url, path)
        digest = sha256(path)
        if asset.fetch("checksummed", true)
          raise Error, "missing checksum for #{file}" unless expected.key?(file)
          raise Error, "checksum mismatch for #{file}" unless expected.fetch(file) == digest
        end
        metadata["#{key}_FILE"] = file
        metadata["#{key}_URL"] = url
        metadata["#{key}_SHA256"] = digest
      end
      metadata
    end

    def srcinfo(directory)
      if available?("makepkg")
        capture("makepkg", "--printsrcinfo", chdir: directory) + "\n"
      elsif available?("docker")
        capture("docker", "run", "--rm", "-v", "#{directory}:/recipe:ro", "archlinux:base-devel", "bash", "-ec",
          'useradd -m builder; cp -r /recipe /tmp/package; chown -R builder:builder /tmp/package; runuser -u builder -- bash -ec "cd /tmp/package; makepkg --printsrcinfo"') + "\n"
      else
        raise Error, "AUR metadata generation needs makepkg or Docker"
      end
    end

    def generate(output, metadata)
      config.fetch("templates", {}).each do |destination, source|
        local = metadata.merge("PKGREL" => config.fetch("revisions", {}).fetch(metadata.fetch("VERSION"), {}).fetch(destination, 1))
        target = output / relative_path(render(destination, local))
        template = root / relative_path(source)
        write(target, render(template.binread, local), executable: template.executable?)
      end
      Pathname.glob(output / "arch/*/PKGBUILD").each do |recipe|
        write(recipe.dirname / ".SRCINFO", srcinfo(recipe.dirname))
      end
      write(output / "release.json", JSON.pretty_generate(metadata.sort.to_h) + "\n")
    end

    def check(output)
      output = Pathname.new(output).expand_path
      metadata = JSON.parse((output / "release.json").read)
      raise Error, "prepared recipes belong to another project" unless metadata.fetch("NAME") == package_name
      version_arg(metadata.fetch("VERSION"))
      Dir.mktmpdir("native-packages-check-") do |temporary|
        expected = Pathname.new(temporary)
        generate(expected, metadata)
        extra = files(output).map { |file| file.relative_path_from(output) } - files(expected).map { |file| file.relative_path_from(expected) }
        raise Error, "unexpected files in prepared recipes: #{extra.join(', ')}" unless extra.empty?
        files(expected).each do |reference|
          actual = output / reference.relative_path_from(expected)
          raise Error, "generated file is stale: #{actual}" unless actual.file? && actual.binread == reference.binread
        end
      end
      files(output).each do |file|
        raise Error, "unexpanded packaging token: #{file}" if Support::TOKEN.match?(file.read)
        run "bash", "-n", file if %w[PKGBUILD APKBUILD template].include?(file.basename.to_s) || %w[.install .ebuild .SlackBuild].include?(file.extname)
        run "ruby", "-c", file if file.extname == ".rb"
      end
      puts "Checked #{package_name} #{metadata.fetch('VERSION')}"
    end

    def prepare(version, output: nil)
      version = version_arg(version)
      output = Pathname.new(output || root / "dist/packaging" / version).expand_path
      raise Error, "output exists: #{output}; choose --output with a fresh path" if output.exist?
      metadata = release_metadata(version)
      output.dirname.mkpath
      Dir.mktmpdir(".packaging-", output.dirname) do |temporary|
        staging = Pathname.new(temporary) / "recipes"
        generate(staging, metadata)
        check(staging)
        staging.rename(output)
      end
      puts "Prepared #{output}"
    end

    def extract(archive, destination)
      capture("bsdtar", "-tf", archive).each_line { |path| relative_path(path.strip) }
      destination.mkpath
      run "bsdtar", "-xf", archive, "-C", destination
      Pathname.glob(destination / "**/*", File::FNM_DOTMATCH).each do |path|
        raise Error, "unexpected archive symlink: #{path}" if path.symlink?
      end
    end

    def nfpm_definition
      definition = config.fetch("binary").fetch("nfpm")
      definition = YAML.safe_load_file(root / relative_path(definition), permitted_classes: [], aliases: false) if definition.is_a?(String)
      raise Error, "nFPM configuration must contain a contents array" unless definition.is_a?(Hash) && definition["contents"].is_a?(Array)
      definition
    end

    def binary_packages(metadata, output)
      return unless config["binary"]
      raise Error, "install nfpm 2.47.0 to build binary packages" unless available?("nfpm")
      config.fetch("binary").fetch("architectures").each do |architecture, asset_key|
        archive = cache(metadata.fetch("VERSION")) / metadata.fetch("#{asset_key}_FILE")
        raise Error, "release archive checksum changed: #{archive}" unless sha256(archive) == metadata.fetch("#{asset_key}_SHA256")
        Dir.mktmpdir("native-package-payload-") do |temporary|
          payload = Pathname.new(temporary) / "payload"
          extract(archive, payload)
          local = metadata.merge("ARCH" => architecture, "PAYLOAD" => payload.to_s, "ROOT" => root.to_s,
            "TARGET" => { "amd64" => "x86_64-unknown-linux-gnu", "arm64" => "aarch64-unknown-linux-gnu" }.fetch(architecture))
          package = render_tree(nfpm_definition, local)
          package.merge!("name" => package_name, "version" => metadata.fetch("VERSION"), "arch" => architecture,
            "platform" => "linux", "mtime" => metadata.fetch("DATE"))
          runtime_dependencies(payload, architecture, package)
          package.fetch("contents").each do |item|
            next unless item["src"]
            raise Error, "missing package content: #{item.fetch('src')}" if Dir.glob(item.fetch("src")).empty?
          end
          %w[deb rpm].each do |format|
            path = Pathname.new(temporary) / "nfpm.yml"
            write(path, YAML.dump(package))
            run "nfpm", "package", "--config", path, "--packager", format,
              "--target", output / "#{package_name}_#{metadata.fetch('VERSION')}_#{architecture}.#{format}",
              env: { "SOURCE_DATE_EPOCH" => metadata.fetch("SOURCE_DATE_EPOCH").to_s }
          end
        end
      end
    end

    # Inspect release binaries without running them, including when packaging ARM on x86.
    def runtime_dependencies(payload, architecture, package)
      libraries = {
        "libgcc_s.so.1" => { "deb" => "libgcc-s1", "rpm" => "libgcc" },
        "libstdc++.so.6" => { "deb" => "libstdc++6", "rpm" => "libstdc++" },
        "libasound.so.2" => { "deb" => "libasound2", "rpm" => "alsa-lib" },
        "libpulse.so.0" => { "deb" => "libpulse0", "rpm" => "pulseaudio-libs" },
        "libpulse-simple.so.0" => { "deb" => "libpulse0", "rpm" => "pulseaudio-libs" },
        "libpipewire-0.3.so.0" => { "deb" => "libpipewire-0.3-0", "rpm" => "pipewire-libs" },
        "libssl.so.3" => { "deb" => "libssl3", "rpm" => "openssl-libs" },
        "libcrypto.so.3" => { "deb" => "libssl3", "rpm" => "openssl-libs" }
      }.merge(config.fetch("binary").fetch("libraries", {}))
      elfs = files(payload).select { |file| file.binread(4) == "\x7fELF" }
      raise Error, "release archive contains no ELF binaries" if elfs.empty?
      bundled = elfs.map { |file| file.basename.to_s }
      required = []
      versions = []
      elfs.each do |file|
        header = file.binread(20)
        machine = header.byteslice(18, 2).unpack1("S<")
        raise Error, "wrong binary architecture in #{file}" unless machine == { "amd64" => 62, "arm64" => 183 }.fetch(architecture)
        required.concat(capture("readelf", "-d", file).scan(/Shared library: \[([^\]]+)\]/).flatten)
        versions.concat(capture("readelf", "--version-info", file).scan(/GLIBC_(\d+\.\d+)/).flatten)
      end
      glibc = versions.max_by { |version| version.split(".").map(&:to_i) }
      required.uniq!
      external = required - bundled
      unknown = external.reject { |name| libraries.key?(name) || /\A(?:lib(?:c|m|dl|rt|pthread|resolv)\.so\.|ld-linux)/.match?(name) }
      raise Error, "add binary.libraries mappings for: #{unknown.join(', ')}" unless unknown.empty?
      %w[deb rpm].each do |format|
        package["overrides"] ||= {}
        package["overrides"][format] ||= {}
        depends = package["overrides"][format]["depends"] ||= []
        depends.concat(external.filter_map { |name| libraries[name]&.fetch(format) })
        if glibc
          previous = depends.grep(format == "deb" ? /\Alibc6(?: |$)/ : /\Aglibc(?: |$)/)
          floor = ([glibc] + previous.flat_map { |dependency| dependency.scan(/\d+\.\d+/) }).max_by { |version| version.split(".").map(&:to_i) }
          depends -= previous
          depends << (format == "deb" ? "libc6 (>= #{floor})" : "glibc >= #{floor}")
        end
        package["overrides"][format]["depends"] = depends.uniq
      end
    end

    def artifacts(recipes, output: root / "dist/package-assets")
      recipes = Pathname.new(recipes).expand_path
      output = Pathname.new(output).expand_path
      raise Error, "artifact output exists: #{output}" if output.exist?
      check(recipes)
      metadata = JSON.parse((recipes / "release.json").read)
      output.dirname.mkpath
      Dir.mktmpdir(".package-assets-", output.dirname) do |temporary|
        staging = Pathname.new(temporary) / "assets"
        staging.mkpath
        binary_packages(metadata, staging)
        recipe_archive(recipes, staging, name: package_name, version: metadata.fetch("VERSION"), epoch: metadata.fetch("SOURCE_DATE_EPOCH"))
        staging.rename(output)
      end
      puts "Built release assets in #{output}"
    end

    def publish_release(version, output)
      upload_assets(repository, version, output)
    end

    def check_version(tag)
      version = version_arg(tag)
      if config["version_file"]
        source = (root / relative_path(config.fetch("version_file"))).read
        section = config.fetch("version_section", "package")
        body = source.split(/^\[#{Regexp.escape(section)}\]\s*$/)[1]&.split(/^\[/)&.first
        actual = body&.match(/^version\s*=\s*"([^"]+)"/)&.captures&.first
        raise Error, "#{config.fetch('version_file')} reports #{actual.inspect}, tag reports #{version}" unless actual == version
      end
      puts version
    end
  end
end
