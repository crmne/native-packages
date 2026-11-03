# frozen_string_literal: true

require "open3"

# A disposable OpenPGP signing key for repository tests, made once per run.
module OpenPGPTestKey
  module_function

  def available? = system("gpg", "--version", out: File::NULL, err: File::NULL)

  # [fingerprint, armored secret key]
  def key
    @key ||= Dir.mktmpdir("native-packages-gpg-test-") do |home|
      gpg = ["gpg", "--homedir", home, "--batch", "--quiet", "--no-tty"]
      _, error, status = Open3.capture3(*gpg, "--passphrase", "", "--quick-gen-key", "Repository Test <repository@example.org>", "ed25519", "sign", "never")
      raise "could not make a test key: #{error}" unless status.success?
      fingerprint = Open3.capture3(*gpg, "--list-keys", "--with-colons").first[/^fpr:+(\h+):/, 1]
      secret = Open3.capture3(*gpg, "--armor", "--export-secret-keys", fingerprint).first
      Open3.capture3("gpgconf", "--homedir", home, "--kill", "all")
      [fingerprint, secret]
    end
  end
end
