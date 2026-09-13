# frozen_string_literal: true

require_relative "configuration"

module NativePackages
  class Scaffold
    include Support
    attr_reader :root

    def initialize(root) = @root = Pathname.new(root).realpath

    def init(interactive: false, name: nil, input: nil, formats: nil)
      raise Error, "configuration exists" if Configuration.discover(root)
      raise Error, "legacy packaging found; use native-packages migrate --dry-run" if (root / "packaging/project.yml").exist?
      raise Error, "interactive init requires a terminal" if interactive && (!$stdin.tty? || ENV["CI"])
      metadata = cargo_metadata
      name ||= metadata.fetch("name", root.basename.to_s.downcase.gsub(/[^a-z0-9-]/, "-"))
      maintainer = git_value("user.name")
      email = git_value("user.email")
      maintainer = "#{maintainer} <#{email}>" unless email.empty?
      values = { "name" => name, "maintainer" => maintainer, "license" => metadata.fetch("license", ""),
        "input" => input || "dist/#{name}-linux-amd64.tar.gz", "formats" => formats || "deb,rpm,archlinux" }
      if interactive
        values.each do |key, value|
          print "#{key} [#{value}]: "
          answer = $stdin.gets&.strip
          raise Error, "input closed; configuration was not written" unless answer
          values[key] = answer unless answer.empty?
        end
      end
      document = { "schema" => 1, "tool" => { "version" => VERSION, "nfpm" => Configuration::NFPM_VERSION },
        "nfpm" => { "name" => values.fetch("name"), "description" => metadata.fetch("description", "TODO: describe this application"),
          "maintainer" => values.fetch("maintainer"), "license" => values.fetch("license"),
          "contents" => [{ "src" => "@PAYLOAD@/#{values.fetch('name')}", "dst" => "/usr/bin/#{values.fetch('name')}", "file_info" => { "mode" => 0o755 } }] },
        "targets" => { "linux-amd64" => { "platform" => "linux", "arch" => "amd64", "libc" => "glibc",
          "formats" => values.fetch("formats").split(","), "input" => { "local" => values.fetch("input") } } } }
      destination = root / Configuration::NAMES.first
      write(destination, "# Review inputs, platform/ABI, dependencies and metadata before building.\n" + YAML.dump(document))
      puts "Created #{destination}. Review the Linux amd64 template, then run native-packages doctor."
      puts "Fill in nfpm.maintainer and nfpm.license." if values.values_at("maintainer", "license").any?(&:empty?)
    end

    def cargo_metadata
      return {} unless (root / "Cargo.toml").file?
      section = (root / "Cargo.toml").read.split(/^\[package\]\s*$/)[1]&.split(/^\[/)&.first.to_s
      section.scan(/^(name|description|license)\s*=\s*"([^"\n]+)"\s*$/).to_h
    end

    def git_value(key)
      capture("git", "config", "--get", key)
    rescue Error, Errno::ENOENT
      ""
    end

    def migrate(dry_run: false)
      raise Error, "configuration exists" if Configuration.discover(root)
      legacy = Project.new(root)
      original = legacy.config
      supported = %w[version name repository release_repository assets templates revisions binary version_file version_section]
      raise Error, "cannot automatically migrate fields: #{(original.keys - supported).join(', ')}" unless (original.keys - supported).empty?
      document = { "schema" => 1, "tool" => { "version" => VERSION, "nfpm" => Configuration::NFPM_VERSION },
        "nfpm" => { "name" => legacy.package_name }, "targets" => {},
        "release" => { "repository" => legacy.repository, "checksums" => "checksums.txt" },
        "assets" => original.fetch("assets"), "templates" => original.fetch("templates", {}),
        "repositories" => legacy.repositories.entries }
      %w[revisions version_file version_section].each { |key| document[key] = original[key] if original.key?(key) }
      if original["binary"]
        binary = original.fetch("binary")
        raise Error, "cannot migrate unknown binary fields" unless (binary.keys - %w[architectures nfpm libraries]).empty?
        document["nfpm"].merge!(legacy.nfpm_definition)
        document["libraries"] = binary.fetch("libraries", {})
        binary.fetch("architectures").each do |architecture, asset_key|
          target = { "amd64" => "x86_64-unknown-linux-gnu", "arm64" => "aarch64-unknown-linux-gnu" }.fetch(architecture)
          asset = original.fetch("assets").fetch(asset_key)
          document["targets"]["linux-#{architecture}"] = { "platform" => "linux", "arch" => architecture, "libc" => "glibc",
            "compiler_target" => target, "formats" => %w[deb rpm],
            "input" => { "local" => "dist/#{asset.fetch('file')}", "release_asset" => asset.fetch("file") } }
          document["targets"]["linux-#{architecture}"]["input"]["url"] = asset.fetch("url") if asset["url"]
        end
      end
      content = YAML.dump(document)
      return puts(content) if dry_run
      path = root / Configuration::NAMES.first
      write(path, content)
      puts "Created #{path}. Existing recipes, wrappers and dependency files were preserved; compare outputs before removing them."
    end
  end
end
