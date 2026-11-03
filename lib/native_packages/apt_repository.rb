# frozen_string_literal: true

require "digest"
require "zlib"
require "rubygems/package"
require "stringio"
require_relative "hosted_repository"

module NativePackages
  # A signed APT repository: pool/ holds the .deb files and dists/ the
  # indexes apt reads (Packages, Release, InRelease and Release.gpg), written
  # by this class without Debian's own tools. Beside them go the public key
  # (NAME.gpg) and a deb822 NAME.sources file for users to install.
  class AptRepository < HostedRepository
    KEYS = (HostedRepository::KEYS + %w[suite component]).freeze
    WORD = /\A[a-z0-9][a-z0-9._-]*\z/
    # The order apt-ftparchive writes; other fields follow in their own order.
    FIELDS = %w[Package Version Architecture].freeze

    def self.validate(data)
      settings = data["apt"]
      return if settings.nil?
      check(settings, "apt", KEYS)
      %w[suite component].each do |key|
        raise Error, "apt.#{key}: use lowercase letters, digits, dots, underscores or hyphens" if settings.key?(key) && !WORD.match?(settings[key].to_s)
      end
    end

    def initialize(configuration)
      super(configuration, configuration.data.fetch("apt") { raise Error, "configure apt to publish --to apt" })
    end

    def suite = settings.fetch("suite", "stable")
    def component = settings.fetch("component", "main")

    # The control paragraph of the .deb at `path`, as text.
    def self.control(path)
      File.open(path, "rb") do |file|
        raise Error, "not a Debian package: #{path}" unless file.read(8) == "!<arch>\n".b
        until file.eof?
          header = file.read(60)
          raise Error, "truncated Debian package: #{path}" unless header&.bytesize == 60
          member = header.byteslice(0, 16).strip.delete_suffix("/")
          size = Integer(header.byteslice(48, 10).strip, 10)
          if member.start_with?("control.tar")
            raise Error, "#{File.basename(path)}: #{member} is not gzip-compressed; build the package with nFPM" unless member == "control.tar.gz"
            Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(file.read(size)))).each do |entry|
              return entry.read.force_encoding(Encoding::UTF_8) if entry.full_name.delete_prefix("./") == "control"
            end
            raise Error, "#{File.basename(path)} has no control file"
          end
          file.seek(size + (size % 2), IO::SEEK_CUR)
        end
      end
      raise Error, "#{File.basename(path)} has no control.tar member"
    end

    # The fields of a control paragraph; continuation lines stay with theirs.
    def self.fields(control)
      control.lines.each_with_object({}) do |line, result|
        next if line.strip.empty?
        if line.start_with?(" ", "\t")
          result[result.keys.last] += "\n#{line.chomp}"
        else
          key, value = line.split(":", 2)
          result[key] = value.to_s.strip
        end
      end
    end

    # Debian's version order (dpkg --compare-versions): -1, 0 or 1.
    def self.compare(left, right)
      left, right = [left, right].map do |version|
        epoch, rest = version.include?(":") ? version.split(":", 2) : ["0", version]
        upstream, _, revision = rest.include?("-") ? rest.rpartition("-") : [rest, nil, "0"]
        [Integer(epoch, 10), upstream, revision]
      end
      (left[0] <=> right[0]).nonzero? || compare_part(left[1], right[1]).nonzero? || compare_part(left[2], right[2])
    end

    def self.compare_part(left, right)
      until left.empty? && right.empty?
        words = [left, right].map { |part| part[/\A\D*/] }
        length = words.map(&:length).max
        length.times do |index|
          order = words.map { |word| rank(word[index]) }
          return order[0] <=> order[1] unless order[0] == order[1]
        end
        left, right = [left, right].zip(words).map { |part, word| part[word.length..] }
        numbers = [left, right].map { |part| part[/\A\d*/] }
        order = numbers[0].to_i <=> numbers[1].to_i
        return order unless order.zero?
        left, right = [left, right].zip(numbers).map { |part, number| part[number.length..] }
      end
      0
    end

    # Tilde sorts before everything, even the end; letters before the rest.
    def self.rank(character)
      return 0 if character.nil?
      return -1 if character == "~"
      character.match?(/[A-Za-z]/) ? character.ord : character.ord + 256
    end

    def publish(debs, secret: nil, passphrase: nil)
      raise Error, "the build contains no deb packages to publish --to apt" if debs.empty?
      debs.each do |path|
        package = self.class.fields(self.class.control(path)).fetch("Package")
        prefix = package.start_with?("lib") ? package[0, 4] : package[0]
        place(path, directory / "pool" / component / prefix / package / path.basename)
      end
      entries = Pathname.glob(directory / "pool/**/*.deb").sort.to_h do |path|
        control = self.class.control(path)
        fields = self.class.fields(control)
        [path, [fields.values_at("Package", "Architecture"), fields.fetch("Version"), control]]
      end
      entries = prune(entries) { |left, right| self.class.compare(left, right) }
      signer(secret: secret, passphrase: passphrase).session { |signing| write_indexes(entries, signing) }
      puts "Published #{entries.length} package#{"s" unless entries.length == 1} to #{directory}. Install with:", *instructions.map { |line| "  #{line}" }
    end

    def instructions
      ["sudo install -d -m 0755 /etc/apt/keyrings",
        "sudo curl -fsSLo /etc/apt/keyrings/#{name}.gpg #{url}/#{name}.gpg",
        "sudo curl -fsSLo /etc/apt/sources.list.d/#{name}.sources #{url}/#{name}.sources",
        "sudo apt update && sudo apt install #{name}"]
    end

    private

    def write_indexes(entries, signing)
      architectures = entries.values.map { |(_, architecture), _, _| architecture }.uniq.sort
      architectures = (architectures - ["all"]).then { |specific| specific.empty? ? ["all"] : specific }
      dists = directory / "dists" / suite
      FileUtils.rm_rf(dists)
      indexes = architectures.flat_map do |architecture|
        stanzas = entries.select { |_, ((_, own), _, _)| [architecture, "all"].include?(own) }
          .sort_by { |path, ((package, _), version, _)| [package, version, path.to_s] }
          .map { |path, (_, _, control)| stanza(path, control) }
        relative = "#{component}/binary-#{architecture}/Packages"
        text = stanzas.join("\n")
        write(dists / relative, text)
        write(dists / "#{relative}.gz", gzip(text))
        [relative, "#{relative}.gz"]
      end
      write(dists / "Release", release(dists, architectures, indexes))
      signing.clearsign(dists / "Release", dists / "InRelease")
      signing.detach_sign(dists / "Release", dists / "Release.gpg")
      write(directory / "#{name}.gpg", signing.public_key)
      write(directory / "#{name}.sources", <<~SOURCES)
        Types: deb
        URIs: #{url}
        Suites: #{suite}
        Components: #{component}
        Signed-By: /etc/apt/keyrings/#{name}.gpg
      SOURCES
    end

    def stanza(path, control)
      fields = self.class.fields(control)
      ordered = FIELDS + (fields.keys - FIELDS)
      body = ordered.map { |key| fields.fetch(key).start_with?("\n") ? "#{key}:#{fields.fetch(key)}" : "#{key}: #{fields.fetch(key)}" }.join("\n")
      bytes = path.binread
      "#{body}\nFilename: #{path.relative_path_from(directory)}\nSize: #{bytes.bytesize}\n" \
        "MD5sum: #{Digest::MD5.hexdigest(bytes)}\nSHA1: #{Digest::SHA1.hexdigest(bytes)}\nSHA256: #{Digest::SHA256.hexdigest(bytes)}\n"
    end

    def release(dists, architectures, indexes)
      epoch = ENV["SOURCE_DATE_EPOCH"] ? Integer(ENV.fetch("SOURCE_DATE_EPOCH")) : Time.now.to_i
      lines = ["Origin: #{name}", "Label: #{name}", "Suite: #{suite}", "Codename: #{suite}",
        "Date: #{Time.at(epoch).utc.strftime('%a, %d %b %Y %H:%M:%S UTC')}", "Architectures: #{architectures.join(' ')}",
        "Components: #{component}", "Description: #{name} packages"]
      { "MD5Sum" => Digest::MD5, "SHA1" => Digest::SHA1, "SHA256" => Digest::SHA256 }.each do |label, digest|
        lines << "#{label}:"
        indexes.each { |relative| lines << " #{digest.file(dists / relative).hexdigest} #{(dists / relative).size} #{relative}" }
      end
      lines.join("\n") + "\n"
    end

    # The same bytes for the same index: no name or time in the header.
    def gzip(text)
      io = StringIO.new("".b)
      writer = Zlib::GzipWriter.new(io, Zlib::BEST_COMPRESSION)
      writer.mtime = 0
      writer.write(text)
      writer.finish
      io.string
    end
  end
end
