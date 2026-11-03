# frozen_string_literal: true

require_relative "hosted_repository"

module NativePackages
  # A signed DNF (and Zypper) repository: packages/ holds the .rpm files and
  # repodata/ the metadata createrepo_c writes, with repomd.xml signed
  # beside it as repomd.xml.asc. Beside them go the public key (NAME.asc) and
  # a NAME.repo file for users to install.
  class DnfRepository < HostedRepository
    TAGS = { 1000 => "name", 1001 => "version", 1002 => "release", 1003 => "epoch", 1022 => "arch", 1044 => "sourcerpm" }.freeze
    # Signature header tags for DSA, RSA, PGP, GPG and OpenPGP signatures.
    SIGNATURES = [267, 268, 1002, 1005, 278].freeze

    def self.validate(data)
      settings = data["dnf"]
      check(settings, "dnf", KEYS) unless settings.nil?
    end

    def initialize(configuration)
      super(configuration, configuration.data.fetch("dnf") { raise Error, "configure dnf to publish --to dnf" })
    end

    # The name, version, release, epoch and architecture of the RPM at
    # `path`, and whether it carries a signature.
    def self.header(path)
      File.open(path, "rb") do |file|
        raise Error, "not an RPM package: #{path}" unless file.read(96)&.start_with?("\xED\xAB\xEE\xDB".b)
        signature = read_header(file, path)
        file.seek((8 - (file.pos % 8)) % 8, IO::SEEK_CUR)
        main = read_header(file, path)
        raise Error, "#{File.basename(path)} is a source package" unless main.key?(1044)
        TAGS.to_h { |tag, key| [key, main[tag]] }.merge("epoch" => main[1003]&.first.to_i, "signed" => SIGNATURES.any? { |tag| signature.key?(tag) })
      end
    end

    def self.read_header(file, path)
      raise Error, "invalid RPM header: #{path}" unless file.read(8)&.start_with?("\x8E\xAD\xE8\x01".b)
      count, size = file.read(8).unpack("N2")
      index = file.read(count * 16).unpack("N*").each_slice(4).to_a
      store = file.read(size)
      raise Error, "truncated RPM header: #{path}" unless store&.bytesize == size
      index.to_h do |tag, type, offset, length|
        value = case type
        when 4 then store.byteslice(offset, 4 * length).unpack("N*")
        when 6, 8, 9 then store.byteslice(offset..).unpack1("Z*").force_encoding(Encoding::UTF_8)
        end
        [tag, value]
      end
    end

    # RPM's version order (rpmvercmp): -1, 0 or 1.
    def self.compare(left, right)
      return 0 if left == right
      loop do
        left, right = [left, right].map { |part| part.sub(/\A[^A-Za-z0-9~^]+/, "") }
        # A tilde sorts before everything, even the end.
        if left.start_with?("~") || right.start_with?("~")
          return 1 unless left.start_with?("~")
          return -1 unless right.start_with?("~")
          left, right = left[1..], right[1..]
          next
        end
        if left.start_with?("^") || right.start_with?("^")
          return -1 if left.empty?
          return 1 if right.empty?
          return 1 unless left.start_with?("^")
          return -1 unless right.start_with?("^")
          left, right = left[1..], right[1..]
          next
        end
        break if left.empty? || right.empty?
        numeric = left.match?(/\A\d/)
        pattern = numeric ? /\A\d+/ : /\A[A-Za-z]+/
        mine, theirs = left[pattern], right[pattern]
        # A number is newer than letters.
        return numeric ? 1 : -1 unless theirs
        order = if numeric
          a, b = [mine, theirs].map { |number| number.sub(/\A0+/, "") }
          (a.length <=> b.length).nonzero? || (a <=> b)
        else
          mine <=> theirs
        end
        return order unless order.zero?
        left, right = left[mine.length..], right[theirs.length..]
      end
      return 0 if left.empty? && right.empty?
      left.empty? ? -1 : 1
    end

    def self.compare_packages(left, right)
      (left.fetch("epoch") <=> right.fetch("epoch")).nonzero? || compare(left.fetch("version"), right.fetch("version")).nonzero? ||
        compare(left.fetch("release"), right.fetch("release"))
    end

    def publish(rpms, secret: nil, passphrase: nil)
      raise Error, "the build contains no rpm packages to publish --to dnf" if rpms.empty?
      raise Error, "install createrepo_c to publish --to dnf" unless available?("createrepo_c")
      rpms.each do |path|
        self.class.header(path)
        place(path, directory / "packages" / path.basename)
      end
      entries = Pathname.glob(directory / "packages/*.rpm").sort.to_h do |path|
        header = self.class.header(path)
        [path, [header.values_at("name", "arch"), header]]
      end
      entries = prune(entries) { |left, right| self.class.compare_packages(left, right) }
      signer(secret: secret, passphrase: passphrase).session do |signing|
        # gzip, which every dnf and zypper reads; newer createrepo_c defaults to zstd.
        run "createrepo_c", "--quiet", "--no-database", "--general-compress-type=gz", directory
        signing.detach_sign(directory / "repodata/repomd.xml", directory / "repodata/repomd.xml.asc")
        write(directory / "#{name}.asc", signing.public_key(armor: true))
      end
      signed = entries.values.all? { |_, header| header.fetch("signed") }
      write(directory / "#{name}.repo", <<~REPO)
        [#{name}]
        name=#{name}
        baseurl=#{url}
        enabled=1
        repo_gpgcheck=1
        gpgcheck=#{signed ? 1 : 0}
        gpgkey=#{url}/#{name}.asc
      REPO
      puts "Published #{entries.length} package#{"s" unless entries.length == 1} to #{directory}. Install with:", *instructions.map { |line| "  #{line}" }
    end

    def instructions
      ["sudo curl -fsSLo /etc/yum.repos.d/#{name}.repo #{url}/#{name}.repo", "sudo dnf install #{name}"]
    end
  end
end
