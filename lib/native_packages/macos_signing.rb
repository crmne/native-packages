# frozen_string_literal: true

module NativePackages
  # Apple credentials opt native DMG builds into Developer ID distribution.
  # Only the owned staging copy is signed; caller inputs and keychains survive.
  class MacosSigning
    include Support
    VARIABLES = %w[APPLE_CERTIFICATE_P12 APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD].freeze
    BUNDLES = %w[.app .framework .xpc .appex .bundle .plugin].freeze
    attr_reader :root

    def initialize(root, environment = ENV)
      @root = root
      @credentials = VARIABLES.to_h { |name| [name, environment[name].to_s] }
      @redactions = @credentials.values.reject(&:empty?)
    end

    def enabled? = @credentials.values.any? { |value| !value.empty? }

    def doctor
      return unless enabled?
      missing = @credentials.select { |_, value| value.strip.empty? }.keys
      raise Error, "incomplete Apple notarization credentials: configure #{missing.join(', ')}" unless missing.empty?
      identity = @credentials.fetch("APPLE_SIGNING_IDENTITY")
      team = @credentials.fetch("APPLE_TEAM_ID")
      unless identity.start_with?("Developer ID Application: ") && identity.end_with?("(#{team})")
        raise Error, "APPLE_SIGNING_IDENTITY must be a Developer ID Application identity for APPLE_TEAM_ID"
      end
      begin
        @certificate = @credentials.fetch("APPLE_CERTIFICATE_P12").delete("\r\n").unpack1("m0")
        raise ArgumentError if @certificate.empty?
      rescue ArgumentError
        raise Error, "APPLE_CERTIFICATE_P12 must contain a base64-encoded PKCS#12 certificate and private key"
      end
      missing_tools = %w[security codesign xcrun hdiutil ditto].reject { |tool| available?(tool) }
      raise Error, "install required Apple tools: #{missing_tools.join(', ')}" unless missing_tools.empty?
      execute "xcrun", "--find", "notarytool"
      execute "xcrun", "--find", "stapler"
    end

    def with_identity
      doctor
      return yield(nil) unless enabled?
      # The search list belongs to the OS user, not this project. Coordinate
      # our signing calls across checkouts, including parallel packaging hooks.
      lock_path = signing_lock_path
      FileUtils.mkdir_p(lock_path.dirname, mode: 0o700)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        with_temporary_identity { yield self }
      end
    end

    private def signing_lock_path
      Pathname.new(Dir.home) / "Library/Caches/native-packages/macos-signing.lock"
    end

    private def with_temporary_identity
      Dir.mktmpdir("native-packages-signing-") do |directory|
        @keychain = Pathname.new(directory) / "signing.keychain-db"
        certificate = Pathname.new(directory) / "certificate.p12"
        File.write(certificate, @certificate, mode: "wb", perm: 0o600)
        password = OpenSSL::Random.random_bytes(32).unpack1("H*")
        @redactions << password
        begin
          execute "security", "create-keychain", "-p", password, @keychain
          # Clean runners may not add new keychains to the user search list.
          # codesign needs that entry even when given an explicit --keychain.
          search_list = Shellwords.shellsplit(execute("security", "list-keychains", "-d", "user"))
          unless search_list.any? { |path| File.identical?(path, @keychain) }
            execute "security", "list-keychains", "-d", "user", "-s", *search_list, @keychain
          end
          execute "security", "set-keychain-settings", "-lut", "21600", @keychain
          execute "security", "unlock-keychain", "-p", password, @keychain
          execute "security", "import", certificate, "-k", @keychain,
            "-P", @credentials.fetch("APPLE_CERTIFICATE_PASSWORD"), "-T", "/usr/bin/codesign"
          execute "security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-k", password, @keychain
          identities = execute "security", "find-identity", "-v", "-p", "codesigning", @keychain
          unless identities.include?(%Q{"#{@credentials.fetch("APPLE_SIGNING_IDENTITY")}"})
            raise Error, "imported P12 has no valid private signing identity matching APPLE_SIGNING_IDENTITY (#{identity_diagnosis})"
          end
          execute "xcrun", "notarytool", "store-credentials", "native-packages", "--keychain", @keychain,
            "--apple-id", @credentials.fetch("APPLE_ID"), "--team-id", @credentials.fetch("APPLE_TEAM_ID"),
            "--password", @credentials.fetch("APPLE_APP_PASSWORD")
          yield self
        ensure
          # delete-keychain removes only this keychain and its search-list entry.
          # Never restore an old list over keychains added by another process.
          execute "security", "delete-keychain", @keychain if @keychain.exist?
          @keychain = nil
        end
      end
    end

    # Explain why find-identity -v rejected the identity. CI logs are often
    # public, so report only facts, never names, hashes or tool output.
    private def identity_diagnosis
      identity = @credentials.fetch("APPLE_SIGNING_IDENTITY")
      pem = execute("security", "find-certificate", "-a", "-p", @keychain)
      certificates = pem.scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m).map { |block| OpenSSL::X509::Certificate.new(block) }
      named = certificates.select { |certificate| certificate.subject.to_a.any? { |key, value, _| key == "CN" && value == identity } }
      return "no imported certificate is named APPLE_SIGNING_IDENTITY; #{certificates.length} imported" if named.empty?
      # Without -v, find-identity also lists identities macOS does not trust.
      # The code-signing policy can skip a certificate it does not match, so
      # the basic policy decides whether the private key is present.
      signing = identity_line("codesigning", identity)
      line = identity_line("basic", identity) || signing
      # A P12 can hold an expired and a renewed certificate of the same name;
      # judge the one the identity uses, by the SHA-1 find-identity reports,
      # preferring the code-signing result so validity and trust agree.
      hash = (signing || line).to_s[/\b\h{40}\b/]&.upcase
      own = named.find { |certificate| OpenSSL::Digest::SHA1.hexdigest(certificate.to_der).upcase == hash }
      now = Time.now
      current = (own ? [own] : named).any? { |certificate| certificate.not_before <= now && now <= certificate.not_after }
      facts = ["certificate named APPLE_SIGNING_IDENTITY: present", "within its validity dates: #{current ? 'yes' : 'no'}",
        "matching private key: #{line ? 'present' : 'absent'}"]
      if signing
        # Scan only the trust result after the name, which may contain anything.
        codes = signing.split(%Q{"#{identity}"}, 2).last.scan(/CSSMERR_[A-Z0-9_]+/).uniq
        facts << "trust errors: #{codes.empty? ? 'none reported' : codes.join(', ')}"
      elsif line
        facts << "matches the code-signing policy: no"
      end
      facts.join("; ")
    rescue Error, OpenSSL::X509::CertificateError
      "certificate details could not be read"
    end

    private def identity_line(policy, identity)
      execute("security", "find-identity", "-p", policy, @keychain).lines.find { |entry| entry.include?(%Q{"#{identity}"}) }
    end

    def sign_payload(payload)
      tree = NativeRecipe.new(root).tree(payload)
      paths = tree.filter_map do |relative, kind, *|
        path = payload / relative
        if kind == "file" && NativeRecipe::MACHO.include?(path.binread(4).unpack1("H*"))
          path
        elsif kind == "directory" && (BUNDLES.include?(path.extname) || (path / "Contents/Info.plist").file?)
          path
        end
      end
      raise Error, "Apple signing needs a payload containing Mach-O code" if paths.empty?
      # Files first, then their containing code bundles, including frameworks.
      paths.sort_by { |path| [-path.each_filename.count, path.to_s] }.each do |path|
        metadata = path.directory? ? "entitlements,requirements" : "identifier,entitlements,requirements"
        execute "codesign", "--force", "--timestamp", "--options", "runtime",
          "--preserve-metadata=#{metadata}", "--keychain", @keychain,
          "--sign", @credentials.fetch("APPLE_SIGNING_IDENTITY"), path
        execute "codesign", "--verify", "--strict", path
      end
    end

    def notarize(package)
      execute "hdiutil", "verify", package
      execute "codesign", "--force", "--timestamp", "--keychain", @keychain,
        "--sign", @credentials.fetch("APPLE_SIGNING_IDENTITY"), package
      execute "codesign", "--verify", "--strict", package
      response = submit(package)
      execute "xcrun", "stapler", "staple", package
      execute "xcrun", "stapler", "validate", package
      execute "hdiutil", "verify", package
      puts "Apple accepted #{package.basename}; its notarization ticket is stapled and validated."
      { "signature" => "developer-id", "notarization" => "accepted", "submission_id" => response.fetch("id"), "stapled" => true }
    end

    def submit(package)
      puts "Submitting #{package.basename} to Apple's notary service..."
      response = JSON.parse(execute("xcrun", "notarytool", "submit", package,
        "--keychain-profile", "native-packages", "--keychain", @keychain,
        "--wait", "--timeout", "30m", "--output-format", "json"))
      unless response["status"] == "Accepted"
        raise Error, "Apple notarization was not accepted (submission #{response.fetch('id', 'unknown')}); inspect the notarytool log before distributing"
      end
      response.fetch("id")
      response
    rescue JSON::ParserError, KeyError
      raise Error, "Apple notary service returned an invalid result; no package was published"
    end

    # A portable tarball cannot itself be submitted or stapled. Apple accepts
    # the exact signed code through a temporary ZIP; the app owns the final tar.
    def prepare_directory(source, output:)
      source = Pathname.new(source).expand_path(root)
      output = Pathname.new(output).expand_path(root)
      raise Error, "output exists: #{output}; choose a fresh --output" if output.exist?
      if output.to_s.start_with?(source.to_s + File::SEPARATOR)
        raise Error, "signed output must be outside the input directory"
      end
      native = NativeRecipe.new(root)
      original = native.digest(source)
      raise Error, "macOS signing must run on macOS" if enabled? && NativeRecipe.host != "macos"
      output.dirname.mkpath
      Dir.mktmpdir(".native-packages-macos-", output.dirname) do |directory|
        copied = Pathname.new(directory) / source.basename
        FileUtils.cp_r(source, copied, preserve: true)
        raise Error, "native input changed while staging" unless native.digest(copied) == original
        with_identity do |signing|
          if signing
            sign_payload(copied)
            archive = Pathname.new(directory) / "notarization.zip"
            execute "ditto", "-c", "-k", "--keepParent", copied, archive
            response = submit(archive)
            native.tree(copied).each do |relative, kind, *|
              bundle = copied / relative
              next unless kind == "directory" && bundle.extname == ".app"
              execute "xcrun", "stapler", "staple", bundle
              execute "xcrun", "stapler", "validate", bundle
            end
            puts "Apple accepted portable code (submission #{response.fetch('id')}). Standalone executables use online ticket lookup."
          else
            puts "Apple credentials are absent; copying portable code without signing or notarization."
          end
        end
        copied.rename(output)
      end
      output
    end

    def execute(*arguments)
      capture(*arguments)
    rescue Error => error
      message = error.message.b
      @redactions.sort_by { |value| -value.bytesize }.each { |value| message.gsub!(value.b, "[REDACTED]") }
      raise Error, message
    end
  end
end
