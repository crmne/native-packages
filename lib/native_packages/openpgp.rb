# frozen_string_literal: true

module NativePackages
  # OpenPGP signatures for hosted package repositories, made with GnuPG.
  #
  # The key is an armored secret key in NATIVE_PACKAGES_GPG_KEY, imported
  # into a temporary keyring that is deleted afterwards, or else a key the
  # user's own GnuPG (and its agent) already holds. Either way it must be the
  # configured fingerprint, and every signature is checked against that
  # key's public half alone before it is published.
  class OpenPGP
    include Support
    KEY ="NATIVE_PACKAGES_GPG_KEY"
    PASSPHRASE = "NATIVE_PACKAGES_GPG_PASSPHRASE"
    FINGERPRINT = /\A(?:\h{40}|\h{64})\z/

    # The signing key and passphrase from the environment, removed from it
    # so that no later subprocess inherits them.
    def self.environment = { secret: ENV.delete(KEY), passphrase: ENV.delete(PASSPHRASE) }

    def self.fingerprint(value, label)
      fingerprint = value.is_a?(String) ? value.delete(" ").upcase : ""
      raise Error, "#{label}: expected the signing key's full fingerprint (40 or 64 hexadecimal digits)" unless FINGERPRINT.match?(fingerprint)
      fingerprint
    end

    attr_reader :fingerprint, :home

    def initialize(fingerprint, secret: nil, passphrase: nil)
      @fingerprint = fingerprint
      @secret = secret
      @passphrase = passphrase
    end

    # Yields self, ready to sign, then deletes any temporary keyring.
    def session
      raise Error, "install gpg (GnuPG) to sign repositories" unless available?("gpg")
      Dir.mktmpdir("native-packages-gpg-") do |directory|
        directory = Pathname.new(directory)
        homes = []
        begin
          if @secret && !@secret.empty?
            @home = keyring(directory / "signing", homes)
            gpg("--import", input: @secret)
          end
          # gpg fails outright when it has no such key.
          listed = begin
            gpg("--list-secret-keys", "--with-colons", fingerprint).lines.grep(/\Afpr:/).map { |line| line.split(":")[9] }
          rescue Error
            []
          end
          unless listed.include?(fingerprint)
            raise Error, "GnuPG has no secret key #{fingerprint}; set #{KEY} to its armored secret key, or import it"
          end
          @public = gpg("--export", fingerprint)
          @verifier = keyring(directory / "verifying", homes)
          gpg("--import", input: @public, home: @verifier)
          yield self
        ensure
          # Stop the agents the temporary keyrings started.
          homes.each { |home| Open3.capture3("gpgconf", "--homedir", home.to_s, "--kill", "all") } if available?("gpgconf")
          @home = nil
        end
      end
    end

    # The public key, binary or ASCII-armored.
    def public_key(armor: false) = armor ? gpg("--armor", "--export", fingerprint, home: @verifier) : @public

    # Options that make flatpak sign with this key.
    def flatpak_options = ["--gpg-sign=#{fingerprint}", *(home ? ["--gpg-homedir=#{home}"] : [])]

    def clearsign(input, output)
      sign("--clearsign", input, output)
      verify(output)
    end

    def detach_sign(input, output)
      sign("--detach-sign", input, output, "--armor")
      verify(output, input)
    end

    # Fails unless `signature` (over `data`, when detached) was made by the
    # configured key.
    def verify(signature, data = nil)
      status = gpg("--status-fd", "1", "--verify", signature.to_s, *(data ? [data.to_s] : []), home: @verifier)
      signers = status.lines.grep(/\A\[GNUPG:\] VALIDSIG /).map { |line| line.split.last }
      raise Error, "#{Pathname.new(signature).basename} is not signed by #{fingerprint}" unless signers == [fingerprint]
    end

    private

    def keyring(path, homes)
      path.mkpath
      path.chmod(0o700)
      homes << path
      path
    end

    def sign(mode, input, output, *options)
      unlock = @passphrase ? ["--pinentry-mode", "loopback", "--passphrase-fd", "0"] : []
      gpg(*unlock, "--local-user", fingerprint, "--digest-algo", "SHA512", *options, mode, "--output", output.to_s, input.to_s,
        input: @passphrase && "#{@passphrase}\n")
    end

    # Runs gpg and returns its output bytes, unchanged.
    def gpg(*arguments, input: nil, home: @home)
      command = ["gpg", "--batch", "--yes", "--no-tty", "--quiet", *(home ? ["--homedir", home.to_s] : []), *arguments]
      output, error, status = Open3.capture3(*command, stdin_data: input.to_s, binmode: true)
      raise Error, "gpg failed: #{error.strip}" unless status.success?
      output
    end
  end
end
