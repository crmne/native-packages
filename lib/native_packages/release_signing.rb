# frozen_string_literal: true

require "digest"

module NativePackages
  # Portable release manifests, independent of package format or CI provider.
  # Ed25519 signs the exact file bytes (no prehash, encoding or canonicalization).
  module ReleaseSigning
    LIMIT = 1024 * 1024
    PUBLIC_PREFIX = ["302a300506032b6570032100"].pack("H*").freeze
    FILENAME = /\A[A-Za-z0-9][A-Za-z0-9._+\-]*\z/
    module_function

    def checksums(directory, output:)
      directory = Pathname.new(directory).realpath
      output = Pathname.new(output).expand_path
      raise Error, "invalid checksum filename" unless FILENAME.match?(output.basename.to_s)
      raise Error, "checksum output must be inside the artifact directory" unless output.dirname.realpath == directory
      raise Error, "refusing to overwrite checksum output" if output.exist? || output.symlink?
      entries = directory.children.sort
      raise Error, "no release artifacts" if entries.empty?
      names = entries.map { |path| path.basename.to_s }
      raise Error, "ambiguous artifact filenames" unless names.map(&:downcase).uniq.length == names.length
      manifest = entries.map do |path|
        name = path.basename.to_s
        raise Error, "invalid artifact filename" unless FILENAME.match?(name)
        raise Error, "signature already exists" if name == "#{output.basename}.sig"
        regular_file!(path)
        "#{Digest::SHA256.file(path).hexdigest}  #{name}\n"
      end.join
      raise Error, "release manifest exceeds 1 MiB" if manifest.bytesize > LIMIT
      write_new(output, manifest)
    end

    def sign(manifest, public_key:, key_env: "NATIVE_PACKAGES_SIGNING_KEY")
      raise Error, "invalid signing key variable name" unless /\A[A-Z][A-Z0-9_]*\z/.match?(key_env)
      pem = ENV.delete(key_env)
      raise Error, "missing signing key environment variable" if pem.nil? || pem.empty?
      # No subprocess receives the private key, and no private file is created.
      key = OpenSSL::PKey.read(pem, "")
      trusted = read_public_key(public_key)
      raise Error, "signing key does not match trusted Ed25519 public key" unless key.oid == "ED25519" && key.public_to_der == trusted.public_to_der
      manifest = Pathname.new(manifest)
      bytes = bounded_read(manifest, LIMIT)
      verify_files(manifest, bytes)
      signature = key.sign(nil, bytes)
      raise Error, "could not verify generated signature" unless signature.bytesize == 64 && trusted.verify(nil, signature, bytes)
      write_new(Pathname.new("#{manifest}.sig"), signature)
    rescue OpenSSL::OpenSSLError
      # Do not expose parser diagnostics from secret input.
      raise Error, "could not use Ed25519 signing key"
    end

    def verify(manifest, public_key:)
      manifest = Pathname.new(manifest)
      bytes = bounded_read(manifest, LIMIT)
      signature = bounded_read(Pathname.new("#{manifest}.sig"), 64)
      trusted = read_public_key(public_key)
      raise Error, "invalid release signature" unless signature.bytesize == 64 && trusted.verify(nil, signature, bytes)
      verify_files(manifest, bytes)
      true
    rescue OpenSSL::OpenSSLError
      raise Error, "invalid Ed25519 public key or release signature"
    end

    def read_public_key(path)
      hex = bounded_read(Pathname.new(path), 128).strip
      raise Error, "public key must be 32 bytes encoded as hex" unless /\A[0-9a-fA-F]{64}\z/.match?(hex)
      OpenSSL::PKey.read(PUBLIC_PREFIX + [hex].pack("H*"))
    end

    def verify_files(manifest, bytes)
      raise Error, "empty release manifest" if bytes.empty?
      seen = {}
      bytes.each_line do |line|
        match = /\A([0-9a-fA-F]{64})  ([A-Za-z0-9][A-Za-z0-9._+\-]*)\n\z/.match(line)
        raise Error, "invalid release checksum entry" unless match
        digest, name = match.captures
        raise Error, "duplicate or self-referencing checksum entry" if seen[name.downcase] || [manifest.basename.to_s.downcase, "#{manifest.basename}.sig".downcase].include?(name.downcase)
        seen[name.downcase] = true
        path = manifest.dirname / name
        regular_file!(path)
        raise Error, "release artifact checksum mismatch: #{name}" unless Digest::SHA256.file(path).hexdigest == digest.downcase
      end
    end

    def regular_file!(path)
      raise Error, "release input must be a regular file: #{path.basename}" unless path.lstat.file?
    end

    def bounded_read(path, limit)
      regular_file!(path)
      bytes = File.binread(path, limit + 1) || "".b
      raise Error, "release metadata exceeds size limit" if bytes.bytesize > limit
      bytes
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
        file.binmode
        file.write(bytes)
      end
      path
    end
  end
end
