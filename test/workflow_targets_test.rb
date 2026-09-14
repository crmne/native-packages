# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class WorkflowTargetsTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("native-packages-workflow-"))
    @workflow = YAML.safe_load_file(File.expand_path("../.github/workflows/package.yml", __dir__), aliases: true)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_configuration_normalizes_known_targets_and_rejects_unknown_input
    config = @root / "project config.yaml"
    config.write(YAML.dump("tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
      "targets" => { "linux-amd64" => {}, "linux-arm64" => {}, "macos" => {} }))
    script = @workflow.fetch("jobs").fetch("configuration").fetch("steps").find { |step| step["id"] == "read" }.fetch("run")
    output = @root / "outputs"
    env = { "CONFIG" => config.to_s, "GITHUB_OUTPUT" => output.to_s, "TARGETS" => "linux-arm64, linux-amd64\nlinux-arm64" }
    _stdout, stderr, status = Open3.capture3(env, "bash", "-e", "-c", script, chdir: @root)
    assert status.success?, stderr
    assert_includes output.read, "targets=linux-amd64,linux-arm64\n"
    _stdout, stderr, status = Open3.capture3(env.merge("TARGETS" => "missing"), "bash", "-e", "-c", script, chdir: @root)
    refute status.success?
    assert_includes stderr, "unknown targets: missing"
  end

  def test_build_and_publish_steps_pass_the_same_target_arguments
    bin = @root / "bin"
    bin.mkpath
    (bin / "native-packages").write("#!#{RbConfig.ruby}\nrequire 'json'\nFile.write(ENV.fetch('CAPTURE'), ARGV.to_json)\n")
    File.chmod(0o755, bin / "native-packages")
    steps = @workflow.fetch("jobs").fetch("packages").fetch("steps")
    names = ["Build packages from published release", "Build packages from local artifacts", "Attach packages to GitHub release"]
    ["", "linux-amd64,linux-arm64"].each do |targets|
      names.each do |name|
        script = steps.find { |step| step["name"] == name }.fetch("run")
        capture = @root / "argv.json"
        env = { "PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}", "CAPTURE" => capture.to_s,
          "TARGETS" => targets, "CONFIG" => "project config.yaml", "VERSION" => "v1.2.3" }
        _stdout, stderr, status = Open3.capture3(env, "bash", "-e", "-o", "pipefail", "-c", script, chdir: @root)
        assert status.success?, stderr
        argv = JSON.parse(capture.read)
        assert_equal ["--config", "project config.yaml"], argv.first(2)
        actual = argv.each_index.filter_map { |index| argv[index + 1] if argv[index] == "--target" }
        assert_equal targets.split(","), actual
      end
    end
  end
end
