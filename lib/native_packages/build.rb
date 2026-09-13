# frozen_string_literal: true

require_relative "configuration"
require_relative "inspection"

module NativePackages
  class Build
    include Support
    attr_reader :configuration, :root, :project

    def initialize(configuration)
      @configuration = configuration
      @root = configuration.root
      @project = configuration.project
    end

    def nfpm_version
      raise Error, "install nFPM #{Configuration::NFPM_VERSION}; https://nfpm.goreleaser.com/install/" unless available?("nfpm")
      version = capture("nfpm", "--version")[/(?:GitVersion|Version):\s*v?(\d+\.\d+\.\d+)/, 1]
      if !version && available?("go")
        executable = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |path| File.join(path, Gem.win_platform? ? "nfpm.exe" : "nfpm") }.find { |path| File.file?(path) }
        version = capture("go", "version", "-m", executable)[/\bmod\s+github\.com\/goreleaser\/nfpm\/v2\s+v(\d+\.\d+\.\d+)/, 1] if executable
      end
      wanted = configuration.data.fetch("tool").fetch("nfpm")
      raise Error, "nFPM version is #{version || 'unknown'}; install #{wanted}" unless version == wanted
      version
    end

    def doctor(ids: [], formats: [], release: false)
      configuration.validate
      selected = configuration.select(ids: ids, formats: formats)
      nfpm_version unless selected.empty?
      required = []
      required << "readelf" if selected.values.any? { |target| target["platform"] == "linux" && target.fetch("kind", "binary") == "binary" }
      required << "bsdtar" if selected.values.any? { |target| target.fetch("input").fetch("kind", "archive") == "archive" }
      required << "curl" if release
      required += %w[tar xz] unless configuration.data.fetch("templates").empty?
      missing = required.uniq.reject { |tool| available?(tool) }
      raise Error, "install required tools: #{missing.join(', ')}" unless missing.empty?
      if configuration.data.fetch("templates").keys.any? { |path| path.match?(%r{\Aarch/[^/]+/PKGBUILD\z}) }
        raise Error, "AUR metadata needs makepkg or accessible Docker" unless available?("makepkg") || available?("docker")
      end
      selected
    end

    def version(value, release)
      if release && value && version_arg(value) != version_arg(release)
        raise Error, "--release and --version disagree"
      end
      value ||= release
      value ||= capture("git", "describe", "--exact-match", "--tags", "HEAD")
      version_arg(value)
    rescue Error => error
      raise error if value
      raise Error, "no exact release tag at HEAD; supply --version"
    end

    def metadata(version, release: false)
      epoch = ENV["SOURCE_DATE_EPOCH"] && Integer(ENV.fetch("SOURCE_DATE_EPOCH"))
      ref = release ? "v#{version}^{commit}" : "HEAD"
      begin
        epoch ||= Integer(capture("git", "show", "-s", "--format=%ct", ref))
        git_version = "r#{capture('git', 'rev-list', '--count', ref)}.#{capture('git', 'rev-parse', '--short', ref)}"
      rescue Error, Errno::ENOENT
        git_version = "r0.unknown"
      end
      configuration.tokens(version, epoch: epoch).merge("GIT_VERSION" => git_version)
    end

    def run_build(value: nil, release: nil, ids: [], formats: [], output: nil, dry_run: false)
      configuration.validate
      selected = configuration.select(ids: ids, formats: formats)
      number = version(value, release)
      output = Pathname.new(output || root / "dist/packages" / number).expand_path(root)
      if dry_run
        puts JSON.pretty_generate("version" => number, "mode" => release ? "release" : "local", "output" => output.to_s,
          "targets" => selected.transform_values { |target| target.slice("formats", "platform", "arch", "input", "before_build", "after_package") })
        return
      end
      raise Error, "output exists: #{output}; choose a fresh --output" if output.exist?
      doctor(ids: ids, formats: formats, release: !!release)
      info = metadata(number, release: !!release)
      sources = []
      expected = release ? release_checksums(info) : nil
      acquire_assets(info, expected, sources)
      output.dirname.mkpath
      Dir.mktmpdir(".native-packages-", output.dirname) do |temporary|
        staging = Pathname.new(temporary) / "result"
        staging.mkpath
        records = []
        selected.each do |id, target|
          local = configuration.target_tokens(info, id, target, "")
          hook = target["before_build"]
          run(*render_tree(hook, local), env: { "NATIVE_PACKAGES_TARGET" => id, "NATIVE_PACKAGES_VERSION" => number }) if hook && !release
          input = render_tree(target.fetch("input"), local)
          source = release ? release_input(input, info, expected) : root / input.fetch("local")
          raise Error, "input does not exist: #{source}" unless source.exist?
          if source.directory? && (output.to_s == source.expand_path.to_s || output.to_s.start_with?(source.expand_path.to_s + File::SEPARATOR))
            raise Error, "package output must be outside the input directory"
          end
          sources << { "target" => id, "path" => source.to_s, "sha256" => input_digest(source) }
          Dir.mktmpdir("native-packages-input-") do |directory|
            payload = Pathname.new(directory) / "payload"
            copy_input(source, payload, input.fetch("kind", "archive"))
            target.fetch("formats").each do |format|
              package = render_tree(configuration.package(target), configuration.target_tokens(info, id, target, payload))
              package.merge!("name" => configuration.name, "version" => number, "arch" => target.fetch("arch"),
                "platform" => target.fetch("platform"), "mtime" => info.fetch("DATE"))
              inspection = Inspection.new(root, configuration.data.fetch("libraries")).check(package, target, format)
              config_path = Pathname.new(directory) / "nfpm.yaml"
              write(config_path, YAML.dump(package))
              destination = staging / "packages" / id / format
              destination.mkpath
              run "nfpm", "package", "--config", config_path, "--packager", format, "--target", destination,
                env: { "SOURCE_DATE_EPOCH" => info.fetch("SOURCE_DATE_EPOCH").to_s }
              packages = files(destination)
              raise Error, "nFPM did not create exactly one #{format} package" unless packages.length == 1
              if target["after_package"]
                signing = configuration.target_tokens(info, id, target, payload).merge("PACKAGE" => packages.first.to_s, "FORMAT" => format)
                run(*render_tree(target.fetch("after_package"), signing), env: { "NATIVE_PACKAGES_TARGET" => id, "NATIVE_PACKAGES_VERSION" => number })
                raise Error, "after_package must preserve the package path and output set" unless files(destination) == packages
              end
              records << { "target" => id, "format" => format, "path" => packages.first.relative_path_from(staging).to_s,
                "sha256" => sha256(packages.first), "validation" => inspection }
            end
          end
        end
        recipes = staging / "recipes"
        project.generate(recipes, info)
        project.check(recipes)
        if !configuration.data.fetch("templates").empty?
          project.recipe_archive(recipes, staging, name: configuration.name, version: number, epoch: info.fetch("SOURCE_DATE_EPOCH"))
          (staging / "packaging-checksums.txt").delete
        end
        manifest = { "schema" => 1, "name" => configuration.name, "version" => number, "configuration" => configuration.digest,
          "tool" => configuration.data.fetch("tool"), "epoch" => info.fetch("SOURCE_DATE_EPOCH"), "inputs" => sources,
          "targets" => selected.transform_values { |target| target.fetch("formats") }, "packages" => records,
          "files" => files(staging).to_h { |file| [file.relative_path_from(staging).to_s, sha256(file)] } }
        write(staging / "build.json", JSON.pretty_generate(manifest) + "\n")
        write(staging / "packaging-checksums.txt", files(staging).map { |file| "#{sha256(file)}  #{file.relative_path_from(staging)}\n" }.join)
        staging.rename(output)
      end
      puts "Built #{selected.values.sum { |target| target.fetch('formats').length }} packages in #{output}"
      output
    end

    def release_cache(info)
      repository = configuration.data.fetch("release").fetch("repository")
      raise Error, "release.repository must be owner/repository" unless /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/.match?(repository)
      root / ".cache/native-packages/releases" / repository / info.fetch("VERSION")
    end

    def release_checksums(info)
      name = configuration.data.fetch("release").fetch("checksums", "checksums.txt")
      raise Error, "release.checksums must be a filename" unless File.basename(name) == name
      path = release_cache(info) / name
      download("#{info.fetch('UPSTREAM')}/releases/download/#{info.fetch('TAG')}/#{name}", path)
      path.readlines.each_with_object({}) do |line, result|
        match = /\A([a-fA-F0-9]{64})\s+\*?([^\r\n]+)\s*\z/.match(line) or raise Error, "invalid checksum entry"
        filename = match[2].strip
        raise Error, "duplicate checksum: #{filename}" if result.key?(filename)
        result[filename] = match[1].downcase
      end
    end

    def release_input(input, info, checksums, checksummed: true)
      filename = input.fetch("release_asset")
      raise Error, "release_asset must be a filename" unless File.basename(filename) == filename && !%w[. ..].include?(filename)
      path = release_cache(info) / filename
      url = input.fetch("url", "#{info.fetch('UPSTREAM')}/releases/download/#{info.fetch('TAG')}/#{filename}")
      download(url, path)
      if checksummed
        raise Error, "missing release checksum for #{filename}" unless checksums.key?(filename)
        raise Error, "checksum mismatch: #{filename}" unless sha256(path) == checksums.fetch(filename)
      end
      path
    end

    def acquire_assets(info, expected, sources)
      configuration.data.fetch("assets").each do |key, definition|
        asset = render_tree(definition, info)
        path = if expected
          release_input(asset.merge("release_asset" => asset.fetch("file")), info, expected, checksummed: asset.fetch("checksummed", true))
        else
          root / asset.fetch("local") { raise Error, "assets.#{key}: declare local input or use --release" }
        end
        digest = sha256(path)
        info["#{key}_SHA256"] = digest
        info["#{key}_FILE"] = asset.fetch("file")
        info["#{key}_URL"] = asset.fetch("url", "#{info.fetch('UPSTREAM')}/releases/download/#{info.fetch('TAG')}/#{asset.fetch('file')}")
        sources << { "asset" => key, "path" => path.to_s, "sha256" => digest }
      end
    end

    def input_digest(source)
      paths = source.directory? ? files(source) : [source]
      raise Error, "input symlinks must be represented as nFPM symlink contents" if source.symlink? || paths.any?(&:symlink?)
      return sha256(source) if source.file?
      OpenSSL::Digest::SHA256.hexdigest(JSON.generate(paths.map { |path| [path.relative_path_from(source).to_s, path.stat.mode & 0o777, sha256(path)] }))
    end

    def copy_input(source, payload, kind)
      case kind
      when "archive" then project.extract(source, payload)
      when "directory"
        raise Error, "expected input directory: #{source}" unless source.directory?
        FileUtils.cp_r(source, payload)
      when "file"
        raise Error, "expected input file: #{source}" unless source.file?
        payload.mkpath
        FileUtils.cp(source, payload / source.basename)
      end
    end

    def verify(output, complete: true)
      output = Pathname.new(output).expand_path(root)
      manifest = JSON.parse((output / "build.json").read)
      raise Error, "unsupported build manifest" unless manifest.fetch("schema") == 1
      raise Error, "build belongs to another project/configuration" unless manifest.fetch("name") == configuration.name && manifest.fetch("configuration") == configuration.digest
      version_arg(manifest.fetch("version"))
      expected = configuration.targets.transform_values { |target| target.fetch("formats") }
      raise Error, "incomplete target set; aggregate all configured targets before publishing" if complete && manifest.fetch("targets") != expected
      expected_pairs = manifest.fetch("targets").flat_map { |id, formats| formats.map { |format| [id, format] } }.sort
      actual_pairs = manifest.fetch("packages").map { |entry| entry.values_at("target", "format") }.sort
      raise Error, "manifest packages do not match its target set" unless actual_pairs == expected_pairs
      manifest.fetch("files").each do |relative, digest|
        path = output / relative_path(relative)
        inside = path.exist? && path.realpath.to_s.start_with?(output.realpath.to_s + File::SEPARATOR)
        raise Error, "package output changed: #{relative}" unless inside && path.file? && !path.symlink? && sha256(path) == digest
      end
      extras = files(output).map { |path| path.relative_path_from(output).to_s } - manifest.fetch("files").keys - %w[build.json packaging-checksums.txt]
      raise Error, "unexpected build files: #{extras.join(', ')}" unless extras.empty?
      manifest.fetch("packages").each do |entry|
        raise Error, "package hash does not match file manifest" unless entry.fetch("sha256") == manifest.fetch("files").fetch(entry.fetch("path"))
      end
      manifest
    end

    def publish(output, destinations, body_file: nil)
      configuration.validate
      output = Pathname.new(output).expand_path(root)
      manifest = verify(output)
      raise Error, "supply at least one --to destination" if destinations.empty?
      destinations.each { |name| project.repositories.select(name) unless name == "github" }
      destinations.each do |destination|
        if destination == "github"
          paths = manifest.fetch("packages").map { |entry| output / entry.fetch("path") }
          paths += manifest.fetch("files").keys.grep(/-packaging\.tar\.xz\z/).map { |path| output / path }
          names = paths.map { |path| path.basename.to_s }
          raise Error, "duplicate release asset names; give variants distinct nFPM names/releases" unless names.uniq == names
          raise Error, "release.repository is required" if project.repository.empty?
          Dir.mktmpdir("native-packages-upload-") do |directory|
            checksums = Pathname.new(directory) / "packaging-checksums.txt"
            write(checksums, paths.map { |path| "#{sha256(path)}  #{path.basename}\n" }.join)
            run "gh", "release", "upload", "v#{manifest.fetch('version')}", *paths, checksums, "--repo", project.repository, "--clobber"
          end
        else
          project.repositories.stage(destination, output / "recipes")
          project.repositories.publish(destination, body_file: body_file)
        end
      end
    end

    def aggregate(inputs, output:)
      configuration.validate
      output = Pathname.new(output).expand_path(root)
      raise Error, "output exists: #{output}" if output.exist?
      roots = inputs.map { |path| Pathname.new(path).expand_path(root) }
      manifests = roots.map { |path| verify(path, complete: false) }
      raise Error, "supply builds to aggregate" if manifests.empty?
      %w[version epoch tool].each do |key|
        raise Error, "builds disagree on #{key}" unless manifests.map { |entry| entry.fetch(key) }.uniq.length == 1
      end
      result = Marshal.load(Marshal.dump(manifests.first))
      result.merge!("targets" => {}, "packages" => [], "files" => {}, "inputs" => manifests.flat_map { |entry| entry.fetch("inputs") }.uniq)
      output.dirname.mkpath
      Dir.mktmpdir(".native-packages-aggregate-", output.dirname) do |directory|
        staging = Pathname.new(directory) / "result"
        staging.mkpath
        manifests.zip(roots).each do |manifest, source|
          manifest.fetch("targets").each do |id, formats|
            result["targets"][id] ||= []
            raise Error, "duplicate target/format: #{id}" unless (result["targets"][id] & formats).empty?
            result["targets"][id] += formats
          end
          result["packages"] += manifest.fetch("packages")
          manifest.fetch("files").each do |path, digest|
            raise Error, "conflicting build file: #{path}" if result["files"][path] && result["files"][path] != digest
            destination = staging / relative_path(path)
            destination.dirname.mkpath
            FileUtils.cp(source / path, destination)
            result["files"][path] = digest
          end
        end
        configuration.targets.each do |id, target|
          result["targets"][id] = target.fetch("formats").select { |format| result["targets"].fetch(id, []).include?(format) }
        end
        write(staging / "build.json", JSON.pretty_generate(result) + "\n")
        write(staging / "packaging-checksums.txt", files(staging).map { |file| "#{sha256(file)}  #{file.relative_path_from(staging)}\n" }.join)
        verify(staging)
        staging.rename(output)
      end
      puts "Aggregated #{output}"
    end
  end
end
