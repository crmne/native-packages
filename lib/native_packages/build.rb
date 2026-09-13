# frozen_string_literal: true

require_relative "configuration"
require_relative "inspection"
require_relative "native_recipe"
require_relative "macos_signing"

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
      raise Error, "install nFPM #{Configuration::NFPM_VERSION}; https://nfpm.goreleaser.com/docs/install/" unless available?("nfpm")
      version = capture("nfpm", "--version")[/(?:GitVersion|Version):\s*v?(\d+\.\d+\.\d+)/, 1]
      if !version && available?("go")
        executable = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |path| File.join(path, Gem.win_platform? ? "nfpm.exe" : "nfpm") }.find { |path| File.file?(path) }
        version = capture("go", "version", "-m", executable)[/\bmod\s+github\.com\/goreleaser\/nfpm\/v2\s+v(\d+\.\d+\.\d+)/, 1] if executable
      end
      wanted = configuration.data.fetch("tool").fetch("nfpm")
      raise Error, "nFPM version is #{version || 'unknown'}; install #{wanted}" unless version == wanted
      version
    end

    def doctor(ids: [], formats: [], release: false, defer_recipes: false)
      configuration.validate
      selected = configuration.select(ids: ids, formats: formats)
      nfpm_version if selected.values.any? { |target| (target.fetch("formats") & Configuration::NATIVE_FORMATS).empty? }
      selected.each do |id, target|
        next unless target["native"]
        metadata = configuration.target_tokens(configuration.tokens("9.8.7"), id, target, "/payload").merge("PACKAGE" => "/output/package", "FORMAT" => target.fetch("formats").first)
        NativeRecipe.new(root).doctor(target, render_tree(target.fetch("native").fetch("command"), metadata))
        MacosSigning.new(root).doctor if target["platform"] == "macos"
      end
      required = []
      required << "readelf" if selected.values.any? { |target| target["platform"] == "linux" && target.fetch("kind", "binary") == "binary" }
      required << "bsdtar" if selected.values.any? { |target| target.fetch("input").fetch("kind", "archive") == "archive" }
      required << "curl" if release
      missing = required.uniq.reject { |tool| available?(tool) }
      raise Error, "install required tools: #{missing.join(', ')}" unless missing.empty?
      recipe_tools unless defer_recipes
      selected
    end

    def recipe_tools
      return if configuration.data.fetch("templates").empty?
      missing = %w[tar xz].reject { |tool| available?(tool) }
      raise Error, "install required recipe tools: #{missing.join(', ')}" unless missing.empty?
      if configuration.data.fetch("templates").keys.any? { |path| path.match?(%r{\Aarch/[^/]+/PKGBUILD\z}) }
        raise Error, "AUR metadata needs makepkg or accessible Docker" unless available?("makepkg") || available?("docker")
      end
    end

    def version(value, release)
      if release && value && configuration.package_version(value) != configuration.package_version(release)
        raise Error, "--release and --version disagree"
      end
      value ||= release
      value ||= capture("git", "describe", "--exact-match", "--tags", "HEAD")
      configuration.package_version(value)
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

    def run_build(value: nil, release: nil, ids: [], formats: [], output: nil, dry_run: false, defer_recipes: false)
      configuration.validate
      selected = configuration.select(ids: ids, formats: formats)
      number = version(value, release)
      configuration.check_prerelease(number, selected)
      if release && selected.values.any? { |target| target["native"] }
        raise Error, "native recipes consume local prepared directories; use --version with native build artifacts"
      end
      output = Pathname.new(output || root / "dist/packages" / number).expand_path(root)
      if dry_run
        puts JSON.pretty_generate("version" => number, "mode" => release ? "release" : "local", "output" => output.to_s,
          "recipes" => defer_recipes ? "deferred" : "included", "targets" => selected.transform_values { |target| target.slice("formats", "platform", "arch", "input", "before_build", "after_package", "native") })
        return
      end
      raise Error, "output exists: #{output}; choose a fresh --output" if output.exist?
      doctor(ids: ids, formats: formats, release: !!release, defer_recipes: defer_recipes)
      info = metadata(number, release: !!release)
      sources = []
      expected = release ? release_checksums(info) : nil
      if defer_recipes
        # Asset hashes are unknown until finalization. Do not silently pass the
        # validation placeholders into a target's input, hooks or package data.
        configuration.data.fetch("assets").each_key { |key| info.delete("#{key}_SHA256") }
        selected.each do |id, target|
          tokens = configuration.target_tokens(info, id, target, "/payload").merge("PACKAGE" => "/output/package", "FORMAT" => target.fetch("formats").first)
          render_tree(target, tokens)
          render_tree(configuration.package(target), tokens)
        end
      else
        acquire_assets(info, expected, sources)
      end
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
          native = target["native"] && NativeRecipe.new(root)
          digest = native ? native.digest(source) : input_digest(source)
          sources << { "target" => id, "path" => source.to_s, "sha256" => digest }
          Dir.mktmpdir("native-packages-input-") do |directory|
            payload = Pathname.new(directory) / (native && source.extname == ".app" ? source.basename : "payload")
            if native
              FileUtils.cp_r(source, payload, preserve: true)
              raise Error, "native input changed while staging" unless native.digest(payload) == digest
            else
              copy_input(source, payload, input.fetch("kind", "archive"))
            end
            signer = target["platform"] == "macos" ? MacosSigning.new(root) : nil
            with_signing(signer) do |signing|
              signing.sign_payload(payload) if signing
              payload_digest = native && native.digest(payload)
              target.fetch("formats").each do |format|
                destination = staging / "packages" / id / format
                destination.mkpath
                if native
                  inspection = native.inspect(payload, target)
                  recipe = target.fetch("native")
                  tokens = configuration.target_tokens(info, id, target, payload)
                  package_path = destination / render(recipe.fetch("output"), tokens)
                  run(*render_tree(recipe.fetch("command"), tokens.merge("PACKAGE" => package_path.to_s, "FORMAT" => format)),
                    env: { "SOURCE_DATE_EPOCH" => info.fetch("SOURCE_DATE_EPOCH").to_s, "NATIVE_PACKAGES_TARGET" => id, "NATIVE_PACKAGES_VERSION" => number })
                  packages = files(destination)
                  raise Error, "native recipe must create only its declared output" unless packages == [package_path]
                  native.check_output(package_path, format)
                else
                  package = render_tree(configuration.package(target), configuration.target_tokens(info, id, target, payload))
                  if number.include?("-") && (package.fetch("version_schema", "semver") != "semver" || %w[prerelease version_metadata].any? { |key| package.key?(key) && !package[key].to_s.empty? })
                    raise Error, "prerelease package versions must use unmodified nFPM semver conversion"
                  end
                  package.merge!("name" => configuration.name, "version" => number, "arch" => target.fetch("arch"),
                    "platform" => target.fetch("platform"), "mtime" => info.fetch("DATE"))
                  inspection = Inspection.new(root, configuration.data.fetch("libraries")).check(package, target, format)
                  config_path = Pathname.new(directory) / "nfpm.yaml"
                  write(config_path, YAML.dump(package))
                  run "nfpm", "package", "--config", config_path, "--packager", format, "--target", destination,
                    env: { "SOURCE_DATE_EPOCH" => info.fetch("SOURCE_DATE_EPOCH").to_s }
                  packages = files(destination)
                  raise Error, "nFPM did not create exactly one #{format} package" unless packages.length == 1
                end
                if target["after_package"]
                  hook_tokens = configuration.target_tokens(info, id, target, payload).merge("PACKAGE" => packages.first.to_s, "FORMAT" => format)
                  run(*render_tree(target.fetch("after_package"), hook_tokens), env: { "NATIVE_PACKAGES_TARGET" => id, "NATIVE_PACKAGES_VERSION" => number })
                  raise Error, "after_package must preserve the package path and output set" unless files(destination) == packages
                end
                if native
                  native.check_output(packages.first, format)
                  raise Error, "native recipes/signing must not change their input payload" unless native.digest(payload) == payload_digest
                end
                inspection["apple"] = signing.notarize(packages.first) if signing
                records << { "target" => id, "format" => format, "path" => packages.first.relative_path_from(staging).to_s,
                  "sha256" => sha256(packages.first), "validation" => inspection }
              end
            end
          end
        end
        write_recipes(staging, info) unless defer_recipes
        manifest = { "schema" => 1, "name" => configuration.name, "version" => number, "configuration" => configuration.digest,
          "tool" => configuration.data.fetch("tool"), "epoch" => info.fetch("SOURCE_DATE_EPOCH"), "inputs" => sources,
          "targets" => selected.transform_values { |target| target.fetch("formats") }, "packages" => records,
          "files" => files(staging).to_h { |file| [file.relative_path_from(staging).to_s, sha256(file)] } }
        if defer_recipes
          manifest["recipes"] = { "state" => "deferred", "metadata" => info.reject { |key, _| key == "ROOT" } }
        end
        write(staging / "build.json", JSON.pretty_generate(manifest) + "\n")
        write(staging / "packaging-checksums.txt", files(staging).map { |file| "#{sha256(file)}  #{file.relative_path_from(staging)}\n" }.join)
        staging.rename(output)
      end
      puts "Built #{selected.values.sum { |target| target.fetch('formats').length }} packages in #{output}"
      output
    end

    def with_signing(signer)
      if signer&.enabled?
        signer.with_identity { |active| yield active }
      else
        yield nil
      end
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

    def acquire_assets(info, expected, sources, packages: {})
      configuration.data.fetch("assets").each do |key, definition|
        asset = render_tree(definition, info)
        path = if packages.key?(asset.fetch("file"))
          packages.fetch(asset.fetch("file"))
        elsif expected
          release_input(asset.merge("release_asset" => asset.fetch("file")), info, expected, checksummed: asset.fetch("checksummed", true))
        else
          root / asset.fetch("local") { raise Error, "assets.#{key}: declare local input or use --release" }
        end
        digest = sha256(path)
        info["#{key}_SHA256"] = digest
        info["#{key}_FILE"] = asset.fetch("file")
        info["#{key}_URL"] = asset.fetch("url", "#{info.fetch('UPSTREAM')}/releases/download/#{info.fetch('TAG')}/#{asset.fetch('file')}")
        source = { "asset" => key, "sha256" => digest }
        # An aggregated package survives under its release filename; the
        # finalizer's temporary staging path does not survive the rename.
        if packages.key?(asset.fetch("file"))
          source["package"] = asset.fetch("file")
        else
          source["path"] = path.to_s
        end
        sources << source
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

    def write_recipes(output, info)
      recipes = output / "recipes"
      project.generate(recipes, info)
      project.check(recipes, prerelease: info.fetch("VERSION").include?("-"))
      unless configuration.data.fetch("templates").empty?
        project.recipe_archive(recipes, output, name: configuration.name, version: info.fetch("VERSION"), epoch: info.fetch("SOURCE_DATE_EPOCH"))
        (output / "packaging-checksums.txt").delete
      end
    end

    def verify_recipes(output, manifest, complete:)
      if manifest.key?("recipes")
        phase = manifest.fetch("recipes")
        unless phase.is_a?(Hash) && phase["state"] == "deferred" && phase["metadata"].is_a?(Hash)
          raise Error, "invalid recipe phase"
        end
        info = phase.fetch("metadata")
        unless info.values_at("NAME", "VERSION", "SOURCE_DATE_EPOCH") == manifest.values_at("name", "version", "epoch")
          raise Error, "deferred recipe metadata disagrees with build"
        end
        package_paths = manifest.fetch("packages").map { |entry| entry.fetch("path") }
        raise Error, "deferred build contains recipe files" unless (manifest.fetch("files").keys - package_paths).empty?
        raise Error, "recipes are deferred; aggregate with --finalize-recipes before publishing" if complete
        return
      end
      # Require the recipe files as well as hashes, so dropping the deferred
      # marker cannot make an unfinished build appear publishable.
      required = ["recipes/release.json"]
      raise Error, "missing recipe metadata" unless manifest.fetch("files").key?(required.first)
      info = JSON.parse((output / required.first).read)
      configuration.data.fetch("templates").each_key do |path|
        relative = render(path, info.merge("ROOT" => root.to_s))
        required << "recipes/#{relative_path(relative)}"
        required << "recipes/#{File.dirname(relative)}/.SRCINFO" if relative.match?(%r{\Aarch/[^/]+/PKGBUILD\z})
      end
      unless configuration.data.fetch("templates").empty?
        required << "#{configuration.name}-#{manifest.fetch('version')}-packaging.tar.xz"
      end
      missing = required - manifest.fetch("files").keys
      raise Error, "missing recipe outputs: #{missing.join(', ')}" unless missing.empty?
    end

    def verify(output, complete: true)
      output = Pathname.new(output).expand_path(root)
      manifest = JSON.parse((output / "build.json").read)
      raise Error, "unsupported build manifest" unless manifest.fetch("schema") == 1
      raise Error, "build belongs to another project/configuration" unless manifest.fetch("name") == configuration.name && manifest.fetch("configuration") == configuration.digest
      number = configuration.package_version(manifest.fetch("version"))
      selected = configuration.select(ids: manifest.fetch("targets").keys)
      configuration.check_prerelease(number, selected)
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
      verify_recipes(output, manifest, complete: complete)
      manifest
    end

    def publish(output, destinations, body_file: nil)
      configuration.validate
      output = Pathname.new(output).expand_path(root)
      manifest = verify(output)
      raise Error, "supply at least one --to destination" if destinations.empty?
      destinations.each { |name| project.repositories.select(name) unless name == "github" }
      if manifest.fetch("version").include?("-")
        raise Error, "prereleases can only attach to an existing GitHub prerelease" unless destinations == ["github"]
        marked = capture("gh", "release", "view", "v#{manifest.fetch('version')}", "--repo", project.repository, "--json", "isPrerelease", "--jq", ".isPrerelease")
        raise Error, "destination release must already be marked prerelease" unless marked == "true"
      end
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

    def aggregate(inputs, output:, finalize_recipes: false)
      configuration.validate
      output = Pathname.new(output).expand_path(root)
      raise Error, "output exists: #{output}" if output.exist?
      roots = inputs.map { |path| Pathname.new(path).expand_path(root) }
      manifests = roots.map { |path| verify(path, complete: false) }
      raise Error, "supply builds to aggregate" if manifests.empty?
      %w[version epoch tool].each do |key|
        raise Error, "builds disagree on #{key}" unless manifests.map { |entry| entry.fetch(key) }.uniq.length == 1
      end
      phases = manifests.map { |entry| entry["recipes"] }
      if phases.any?
        raise Error, "do not mix deferred and completed recipe builds" if phases.any?(&:nil?)
        raise Error, "deferred recipe metadata differs between builds" unless phases.uniq.length == 1
        raise Error, "deferred builds require --finalize-recipes" unless finalize_recipes
      elsif finalize_recipes
        raise Error, "--finalize-recipes requires builds made with --defer-recipes"
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
        if finalize_recipes
          expected = configuration.targets.transform_values { |target| target.fetch("formats") }
          raise Error, "incomplete target set; aggregate all configured targets before finalizing recipes" unless result.fetch("targets") == expected
          recipe_tools
          info = result.fetch("recipes").fetch("metadata").merge("ROOT" => root.to_s)
          packages = result.fetch("packages").each_with_object({}) do |entry, paths|
            name = File.basename(entry.fetch("path"))
            raise Error, "ambiguous recipe asset filename: #{name}" if paths.key?(name)
            paths[name] = staging / entry.fetch("path")
          end
          acquire_assets(info, nil, result.fetch("inputs"), packages: packages)
          write_recipes(staging, info)
          result.delete("recipes")
          result["files"] = files(staging).to_h { |file| [file.relative_path_from(staging).to_s, sha256(file)] }
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
