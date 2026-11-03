# frozen_string_literal: true

require_relative "openpgp"

module NativePackages
  # A signed package repository that native-packages writes into a directory,
  # such as a GitHub Pages checkout, to be served as static files. Writing is
  # all it does: the release process commits and pushes the directory.
  class HostedRepository
    include Support
    KEYS = %w[directory url keep signing_key].freeze
    KEEP = 3
    attr_reader :root, :name, :settings, :directory

    # Checks the settings shared by every hosted repository, under `label`.
    def self.check(settings, label, keys)
      raise Error, "#{label}: expected a mapping" unless settings.is_a?(Hash)
      unknown = settings.keys - keys
      raise Error, "#{label}: unknown fields #{unknown.join(', ')}" unless unknown.empty?
      raise Error, "#{label}.directory: name the directory to write the repository into" unless settings["directory"].is_a?(String) && !settings["directory"].empty?
      unless settings["url"].is_a?(String) && %r{\Ahttps://[^\s/]+(?:/\S*)?\z}.match?(settings["url"])
        raise Error, "#{label}.url: expected the https:// URL the directory is served at"
      end
      keep = settings.fetch("keep", KEEP)
      raise Error, "#{label}.keep: expected how many versions of each package to keep (1 or more)" unless keep.is_a?(Integer) && keep.positive?
      OpenPGP.fingerprint(settings["signing_key"], "#{label}.signing_key")
    end

    def initialize(configuration, settings)
      @root = configuration.root
      @name = configuration.name
      @settings = settings
      @directory = Pathname.new(settings.fetch("directory")).expand_path(root)
    end

    def url = settings.fetch("url").chomp("/")
    def keep = settings.fetch("keep", KEEP)

    def signer(secret: nil, passphrase: nil)
      OpenPGP.new(OpenPGP.fingerprint(settings.fetch("signing_key"), "signing_key"), secret: secret, passphrase: passphrase)
    end

    # Copies `path` to `destination`, refusing to change a published file.
    def place(path, destination)
      if destination.exist?
        raise Error, "#{destination.relative_path_from(directory)} is already published with different contents" unless sha256(destination) == sha256(path)
        return
      end
      destination.dirname.mkpath
      FileUtils.cp(path, destination)
      destination.chmod(0o644)
    end

    # Deletes all but the newest `keep` versions in each group of `entries`
    # (path => [group, version, ...]), ordered by `compare`, and returns
    # the entries that remain.
    def prune(entries, &compare)
      removed = entries.group_by { |_, details| details.first }.values.flat_map do |versions|
        versions.sort { |left, right| compare.call(right.last[1], left.last[1]) }.drop(keep).map(&:first)
      end
      removed.each do |path|
        path.delete
        puts "Removed #{path.relative_path_from(directory)}"
        parent = path.dirname
        while parent != directory && parent.empty?
          parent.rmdir
          parent = parent.dirname
        end
      end
      entries.except(*removed)
    end
  end
end
