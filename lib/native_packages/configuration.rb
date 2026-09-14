# frozen_string_literal: true

require_relative "project"

module NativePackages
  class Configuration
    include Support
    NATIVE_FORMATS = %w[dmg inno].freeze
    FORMATS = (%w[deb rpm archlinux apk ipk msix srpm] + NATIVE_FORMATS).freeze
    NFPM_VERSION = "2.47.0"
    NAMES = %w[native-packages.yaml native-packages.yml].freeze
    KEYS = %w[schema tool nfpm targets release assets templates repositories revisions libraries version_file version_section].freeze
    attr_reader :root, :path, :data

    def self.discover(root, explicit = nil)
      return Pathname.new(explicit).expand_path(root) if explicit
      paths = NAMES.map { |name| Pathname.new(root) / name }.select(&:exist?)
      raise Error, "both #{NAMES.join(' and ')} exist; use --config" if paths.length > 1
      paths.first
    end

    def initialize(path)
      @path = Pathname.new(path).expand_path
      @root = @path.dirname.realpath
      @data = YAML.safe_load_file(@path, permitted_classes: [], aliases: false)
      raise Error, "#{path}: expected a configuration mapping" unless data.is_a?(Hash)
      raise Error, "unsupported schema; expected schema: 1" unless data["schema"] == 1
      unknown = data.keys - KEYS
      raise Error, "unknown configuration fields: #{unknown.join(', ')}" unless unknown.empty?
      %w[tool targets].each { |key| mapping(data.fetch(key), key) }
      data["nfpm"] = definition(data.fetch("nfpm", {}))
      %w[assets templates repositories revisions libraries release].each { |key| data[key] = mapping(data.fetch(key, {}), key) }
      data["targets"].each do |name, target|
        mapping(target, "targets.#{name}")
        target["nfpm"] = definition(target.fetch("nfpm", {}))
      end
    end

    def mapping(value, label)
      raise Error, "#{label}: expected a mapping" unless value.is_a?(Hash)
      value
    end

    def definition(value)
      value = YAML.safe_load_file(root / relative_path(value), permitted_classes: [], aliases: false) if value.is_a?(String)
      mapping(value, "nfpm")
    end

    def merge(base, override)
      base.merge(override) { |_, left, right| left.is_a?(Hash) && right.is_a?(Hash) ? merge(left, right) : right }
    end

    def name = data.fetch("nfpm").fetch("name")
    def targets = data.fetch("targets")
    def digest = OpenSSL::Digest::SHA256.hexdigest(JSON.generate(data))
    def package(target) = merge(data.fetch("nfpm"), target.fetch("nfpm", {}))
    def package_version(value) = version_arg(value, prerelease: data.fetch("release").fetch("prereleases", false))

    def check_prerelease(version, selected, defer_recipes: false)
      return unless version.include?("-")
      raise Error, "prerelease builds require release.prereleases: true" unless data.fetch("release")["prereleases"] == true
      unless selected.values.all? { |target| (target.fetch("formats") - %w[deb rpm dmg inno]).empty? } && (defer_recipes || data.fetch("templates").empty?)
        raise Error, "prereleases support deb, rpm, dmg and inno only, without downstream recipes"
      end
    end

    def project
      config = { "version" => 1, "name" => name, "repository" => data.fetch("release").fetch("repository", ""),
        "assets" => data.fetch("assets"), "templates" => data.fetch("templates"), "revisions" => data.fetch("revisions") }
      %w[version_file version_section].each { |key| config[key] = data[key] if data.key?(key) }
      Project.new(root, config: config, registries: data.fetch("repositories"))
    end

    def validate
      raise Error, "nfpm.name: use letters, digits, dots, underscores or hyphens" unless /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/.match?(name)
      %w[version nfpm].each { |key| version_arg(data.fetch("tool").fetch(key)) }
      if data.fetch("tool").fetch("version") != VERSION
        wanted = data.fetch("tool").fetch("version")
        raise Error, "configuration needs native-packages #{wanted}; run gem install native-packages -v #{wanted}, then native-packages _#{wanted}_ COMMAND"
      end
      raise Error, "unsupported nFPM version; use #{NFPM_VERSION}" unless data.fetch("tool").fetch("nfpm") == NFPM_VERSION
      if data.fetch("release").key?("prereleases") && ![true, false].include?(data.fetch("release")["prereleases"])
        raise Error, "release.prereleases must be true or false"
      end
      metadata = tokens("9.8.7", epoch: 1_767_225_600)
      targets.each do |id, target|
        raise Error, "invalid target name: #{id}" unless /\A[a-z0-9][a-z0-9-]*\z/.match?(id)
        unknown = target.keys - %w[platform arch libc abi kind formats input nfpm before_build after_package compiler_target native]
        raise Error, "targets.#{id}: unknown fields #{unknown.join(', ')}" unless unknown.empty?
        formats = target.fetch("formats")
        unless formats.is_a?(Array) && !formats.empty? && formats.uniq == formats && (formats - FORMATS).empty?
          raise Error, "targets.#{id}.formats: choose from #{FORMATS.join(', ')}"
        end
        raise Error, "targets.#{id}.platform: use linux, windows or macos" unless %w[linux windows macos].include?(target.fetch("platform"))
        raise Error, "targets.#{id}.arch: expected an architecture" unless /\A[a-zA-Z0-9_+-]+\z/.match?(target.fetch("arch"))
        kind = target.fetch("kind", "binary")
        raise Error, "targets.#{id}.kind: use binary, data or source" unless %w[binary data source].include?(kind)
        raise Error, "#{id}: MSIX requires a Windows target with only msix format" if formats.include?("msix") && (target["platform"] != "windows" || formats != ["msix"])
        raise Error, "#{id}: Windows targets require msix or inno" if target["platform"] == "windows" && ![["msix"], ["inno"]].include?(formats)
        raise Error, "#{id}: macOS targets require dmg" if target["platform"] == "macos" && formats != ["dmg"]
        native = !(formats & NATIVE_FORMATS).empty?
        if native
          expected = { "dmg" => "macos", "inno" => "windows" }[formats.first]
          raise Error, "#{id}: native formats require a separate binary target on their native platform" unless formats.length == 1 && expected == target["platform"] && kind == "binary"
          recipe = mapping(target.fetch("native"), "#{id}.native")
          raise Error, "#{id}.native: expected command and output" unless recipe.keys.sort == %w[command output]
          command = recipe["command"]
          unless command.is_a?(Array) && !command.empty? && command.all? { |part| part.is_a?(String) } && command.any? { |part| part.include?("@PACKAGE@") }
            raise Error, "#{id}.native.command: use command arguments including @PACKAGE@"
          end
          filename = render(recipe.fetch("output"), target_tokens(metadata, id, target, "/payload"))
          extension = formats == ["dmg"] ? ".dmg" : ".exe"
          unless /\A[a-zA-Z0-9][a-zA-Z0-9._+-]*\z/.match?(filename) && filename.end_with?(extension)
            raise Error, "#{id}.native.output: expected a safe #{extension} filename"
          end
          render_tree(command, target_tokens(metadata, id, target, "/payload").merge("PACKAGE" => "/output/#{filename}", "FORMAT" => formats.first))
        elsif target.key?("native")
          raise Error, "#{id}: native commands require a dmg or inno target"
        end
        raise Error, "#{id}: SRPM requires a separate source target" if (formats.include?("srpm") && (kind != "source" || formats != ["srpm"])) || (kind == "source" && formats != ["srpm"])
        if kind == "binary" && target["platform"] == "linux"
          raise Error, "#{id}.libc: declare glibc, musl or static" unless %w[glibc musl static].include?(target["libc"])
        end
        raise Error, "#{id}: IPK needs an explicit abi (device/distribution baseline)" if formats.include?("ipk") && target.fetch("abi", "").empty?
        input = mapping(target.fetch("input"), "#{id}.input")
        raise Error, "#{id}.input: declare local or release_asset" unless input["local"] || input["release_asset"]
        raise Error, "#{id}.input.kind: use file, directory or archive" unless %w[file directory archive].include?(input.fetch("kind", "archive"))
        raise Error, "#{id}: native packaging requires an input directory" if native && input.fetch("kind", "archive") != "directory"
        raise Error, "#{id}: native packaging requires input.local" if native && !input["local"]
        %w[before_build after_package].each do |key|
          hook = target[key]
          raise Error, "#{id}.#{key}: use a nonempty array of command arguments" if hook && (!hook.is_a?(Array) || hook.empty? || !hook.all? { |part| part.is_a?(String) })
        end
        rendered = render_tree(package(target), target_tokens(metadata, id, target, "/payload"))
        raise Error, "#{id}: nfpm.contents must be an array" unless native || rendered["contents"].is_a?(Array)
        %w[maintainer description license].each do |key|
          raise Error, "#{id}: fill in nfpm.#{key}" unless rendered[key].is_a?(String) && !rendered[key].strip.empty?
        end
        if formats.include?("msix")
          msix = mapping(rendered.fetch("msix"), "#{id}.nfpm.msix")
          raise Error, "#{id}: supply msix.publisher" unless msix["publisher"].is_a?(String) && !msix["publisher"].empty?
          raise Error, "#{id}: supply msix.applications" unless msix["applications"].is_a?(Array) && !msix["applications"].empty?
        end
        %w[name arch platform version].each do |key|
          expected = { "name" => name, "arch" => target["arch"], "platform" => target["platform"], "version" => "9.8.7" }.fetch(key)
          raise Error, "#{id}: conflicting nfpm.#{key}; declare it once" if rendered.key?(key) && rendered[key] != expected
        end
        render_tree(input, target_tokens(metadata, id, target, "/payload"))
        render_tree(target["before_build"], target_tokens(metadata, id, target, "/payload")) if target["before_build"]
        render_tree(target["after_package"], target_tokens(metadata, id, target, "/payload").merge("PACKAGE" => "/output/package", "FORMAT" => formats.first)) if target["after_package"]
      end
      data.fetch("templates").each do |destination, source|
        relative_path(render(destination, metadata))
        render((root / relative_path(source)).binread, metadata)
      end
      project.repositories
      true
    end

    def tokens(version, epoch: nil)
      epoch ||= Integer(ENV.fetch("SOURCE_DATE_EPOCH", Time.now.to_i.to_s))
      result = { "NAME" => name, "VERSION" => version, "TAG" => "v#{version}", "DATE" => Time.at(epoch).utc.iso8601,
        "SOURCE_DATE_EPOCH" => epoch, "ROOT" => root.to_s, "PKGREL" => 1,
        "UPSTREAM" => "https://github.com/#{data.fetch('release').fetch('repository', '')}", "GIT_VERSION" => "r0.unknown" }
      data.fetch("assets").each do |key, asset|
        raise Error, "invalid asset key: #{key}" unless /\A[A-Z][A-Z0-9_]*\z/.match?(key)
        result["#{key}_FILE"] = render(asset.fetch("file"), result)
        result["#{key}_URL"] = render(asset.fetch("url", "#{result['UPSTREAM']}/releases/download/@TAG@/@#{key}_FILE@"), result)
        result["#{key}_SHA256"] = "0" * 64
      end
      result
    end

    def target_tokens(metadata, id, target, payload)
      metadata.merge("ARCH" => target.fetch("arch"), "PLATFORM" => target.fetch("platform"),
        "TARGET" => target.fetch("compiler_target", id), "TARGET_ID" => id, "PAYLOAD" => payload.to_s)
    end

    def select(ids: [], formats: [])
      raise Error, "unknown targets: #{(ids - targets.keys).join(', ')}" unless (ids - targets.keys).empty?
      raise Error, "unknown formats: #{(formats - FORMATS).join(', ')}" unless (formats - FORMATS).empty?
      chosen = targets.select { |id, _| ids.empty? || ids.include?(id) }.filter_map do |id, target|
        selected = formats.empty? ? target.fetch("formats") : target.fetch("formats") & formats
        [id, target.merge("formats" => selected)] unless selected.empty?
      end.to_h
      raise Error, "no configured targets match the selection" if chosen.empty? && (!targets.empty? || !ids.empty? || !formats.empty?)
      chosen
    end
  end
end
