# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class ReleaseSigningTest < Minitest::Test
  Signing = NativePackages::ReleaseSigning

  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-signing-"))
    @assets = @root / "release assets"
    @assets.mkpath
    (@assets / "app-v1.2.3-rc.1.zip").binwrite("fixture\x00\xff".b)
    @manifest = @assets / "checksums.txt"
    @key = OpenSSL::PKey.generate_key("ED25519")
    @public = @root / "public.hex"
    @public.write(@key.public_to_der.byteslice(-32, 32).unpack1("H*") + "\n")
    @key_env = "NATIVE_PACKAGES_FIXTURE_SIGNING_KEY"
    @previous_key = ENV[@key_env]
  end

  def teardown
    ENV[@key_env] = @previous_key
    FileUtils.remove_entry(@root)
  end

  def generate
    Signing.checksums(@assets, output: @manifest)
  end

  def sign
    ENV[@key_env] = @key.private_to_pem
    Signing.sign(@manifest, public_key: @public, key_env: @key_env)
  ensure
    refute ENV.key?(@key_env), "the signer removes its secret from the process environment"
  end

  def signature = Pathname.new("#{@manifest}.sig")

  def test_cli_works_without_project_configuration_and_preserves_exact_bytes
    (@assets / "other.dmg").write("second artifact\n")
    NativePackages::CLI.run(@root, ["release-checksums", @assets.to_s, "--output", @manifest.to_s])
    bytes = @manifest.binread
    assert_equal %w[app-v1.2.3-rc.1.zip other.dmg], bytes.lines.map { |line| line.split.last }
    ENV[@key_env] = @key.private_to_pem
    NativePackages::CLI.run(@root, ["sign-checksums", @manifest.to_s, "--public-key", @public.to_s, "--key-env", @key_env])
    assert_equal 64, signature.size
    assert @key.verify(nil, signature.binread, bytes)
    assert NativePackages::CLI.run(@root, ["verify-checksums", @manifest.to_s, "--public-key", @public.to_s])
    assert_equal bytes, @manifest.binread
    assert_equal [@assets, @public].sort, @root.children.sort, "no private key file is created"
  end

  def test_signatures_are_compatible_with_openssl_cli
    generate
    sign
    pem = @root / "public.pem"
    pem.write(@key.public_to_pem)
    _out, err, status = Open3.capture3("openssl", "pkeyutl", "-verify", "-rawin", "-pubin",
      "-inkey", pem.to_s, "-in", @manifest.to_s, "-sigfile", signature.to_s)
    assert status.success?, err
  end

  def test_shared_rust_updater_interoperability_vector
    # A public, disposable seed used by ZapFast's Rust verifier test too.
    @key = OpenSSL::PKey.read(["302e020100300506032b657004220420" + "2a" * 32].pack("H*"))
    @public.write("197f6b23e16c8532c6abc838facd5ea789be0c76b2920334039bfa8b3d368d61")
    (@assets / "app-v1.2.3-rc.1.zip").rename(@assets / "app-v1.2.3.zip")
    (@assets / "app-v1.2.3.zip").write("fixture")
    generate
    sign
    assert_equal "f16d05ec6b29248d2c61adb1e9263f78e4f7bace1b955014a2d17872cfe4064d  app-v1.2.3.zip\n", @manifest.binread
    assert_equal "562fce6b4dc6e8d30a907f104a3b1c5fbf777c3b849ee23181de624c1398f6af3d1ee6b4a272f87c7100b6f58d34854c1d2285c854335f23edf1c0fa5a9e2a0f", signature.binread.unpack1("H*")
  end

  def test_missing_wrong_malformed_or_non_ed25519_keys_cannot_sign
    generate
    assert_raises(NativePackages::Error) { Signing.sign(@manifest, public_key: @public, key_env: @key_env) }
    [OpenSSL::PKey.generate_key("ED25519").private_to_pem, "private fixture garbage",
      OpenSSL::PKey::EC.generate("prime256v1").private_to_pem, @key.public_to_pem].each do |pem|
      ENV[@key_env] = pem
      error = assert_raises(NativePackages::Error) { Signing.sign(@manifest, public_key: @public, key_env: @key_env) }
      refute_includes error.message, pem
      refute_path_exists signature
      refute ENV.key?(@key_env)
    end
  end

  def test_unsigned_wrong_key_and_changed_manifest_or_payload_are_rejected
    generate
    assert_raises(Errno::ENOENT) { Signing.verify(@manifest, public_key: @public) }
    sign
    bytes = @manifest.binread
    @manifest.binwrite(bytes.sub("app-v1.2.3", "app-v1.2.4"))
    assert_raises(NativePackages::Error) { Signing.verify(@manifest, public_key: @public) }
    @manifest.binwrite(bytes)
    original_key = @public.read
    @public.write("00" * 32)
    assert_raises(NativePackages::Error) { Signing.verify(@manifest, public_key: @public) }
    @public.write(original_key)
    (@assets / "app-v1.2.3-rc.1.zip").write("modified")
    assert_raises(NativePackages::Error) { Signing.verify(@manifest, public_key: @public) }
    signature.delete
    assert_raises(NativePackages::Error) { sign }
    refute_path_exists signature
  end

  def test_signature_size_is_exact_and_metadata_reads_are_bounded
    generate
    sign
    bytes = signature.binread
    ["", bytes.byteslice(0, 63), bytes + "x"].each do |bad|
      signature.binwrite(bad)
      assert_raises(NativePackages::Error) { Signing.verify(@manifest, public_key: @public) }
    end
    @manifest.binwrite("x" * (Signing::LIMIT + 1))
    assert_raises(NativePackages::Error) { sign }
  end

  def test_existing_outputs_and_symlinks_are_not_overwritten
    generate
    original = @manifest.binread
    assert_raises(NativePackages::Error) { generate }
    assert_equal original, @manifest.binread
    sign
    original_signature = signature.binread
    assert_raises(Errno::EEXIST) { sign }
    assert_equal original_signature, signature.binread
    return if Gem.win_platform? # Windows symlink creation needs an elevated token.
    signature.delete
    signature.make_symlink(@public)
    assert_raises(Errno::EEXIST) { sign }
    assert_equal 65, @public.size
    signature.delete
    artifact = @assets / "app-v1.2.3-rc.1.zip"
    artifact.delete
    artifact.make_symlink(@public)
    assert_raises(NativePackages::Error) { sign }
  end

  def test_generation_rejects_directories_ambiguous_names_and_unsafe_filenames
    (@assets / "nested").mkpath
    assert_raises(NativePackages::Error) { generate }
    (@assets / "nested").rmdir
    ["bad name.zip", "-option.zip", "bad\nname.zip", "checksums.txt.sig"].each do |name|
      next if Gem.win_platform? && name.include?("\n")
      (@assets / name).write("fixture")
      assert_raises(NativePackages::Error) { generate }
      (@assets / name).delete
      refute_path_exists @manifest
    end
    (@assets / "App-v1.2.3-rc.1.zip").write("case collision")
    # Case-insensitive filesystems cannot represent both names in the first place.
    assert_raises(NativePackages::Error) { generate } if @assets.children.length == 2
  end

  def test_authenticated_manifests_still_reject_duplicate_unsafe_and_self_references
    generate
    valid = @manifest.binread
    [valid + valid, valid.sub("app-v1.2.3-rc.1.zip", "../escape"),
      valid.sub("app-v1.2.3-rc.1.zip", "checksums.txt"),
      valid.sub("app-v1.2.3-rc.1.zip", "checksums.txt.sig"), "", valid.chomp].each do |bad|
      @manifest.binwrite(bad)
      signature.binwrite(@key.sign(nil, bad))
      assert_raises(NativePackages::Error) { Signing.verify(@manifest, public_key: @public) }
    end
  end

  def test_signing_action_uses_the_shared_cli_and_step_environment
    action = YAML.safe_load_file(File.expand_path("../.github/actions/sign-release/action.yml", __dir__))
    script = action.fetch("runs").fetch("steps").first.fetch("run")
    env = { "SIGNING_TOOL_ROOT" => File.expand_path("..", __dir__), "ARTIFACT_DIRECTORY" => @assets.to_s,
      "TRUSTED_PUBLIC_KEY" => @public.to_s, "PRIVATE_KEY_VARIABLE" => @key_env, @key_env => @key.private_to_pem }
    out, err, status = Open3.capture3(env, "bash", "-e", "-o", "pipefail", "-c", script, chdir: @root)
    assert status.success?, err
    refute_includes out + err, @key.private_to_pem
    assert Signing.verify(@manifest, public_key: @public)
  end

  def test_attestation_runs_in_calling_build_job_with_no_publisher_secret
    action = YAML.safe_load_file(File.expand_path("../.github/actions/attest/action.yml", __dir__))
    assert_equal "composite", action.fetch("runs").fetch("using")
    step = action.fetch("runs").fetch("steps").fetch(0)
    assert_match(/\Aactions\/attest@[0-9a-f]{40}\z/, step.fetch("uses"))
    assert_equal "${{ inputs.subject-path }}", step.fetch("with").fetch("subject-path")
    assert_equal false, step.fetch("with").fetch("create-storage-record")
    refute action.to_s.include?("secrets.")
  end
end
