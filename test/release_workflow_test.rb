# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

class ReleaseWorkflowTest < Minitest::Test
  def setup
    root = File.expand_path("../.github/workflows", __dir__)
    @release = YAML.safe_load_file("#{root}/release.yml")
    @tests = YAML.safe_load_file("#{root}/test.yml")
  end

  def test_release_caller_grants_every_permission_requested_by_reusable_tests
    caller = @release.fetch("jobs").fetch("checks").fetch("permissions")
    @tests.fetch("jobs").each_value do |job|
      job.fetch("permissions", {}).each do |scope, access|
        assert_equal access, caller.fetch(scope), "reusable job cannot elevate #{scope}"
      end
    end
  end

  def test_retry_checks_and_publication_use_the_validated_tag_commit
    jobs = @release.fetch("jobs")
    assert_equal "${{ needs.validate.outputs.sha }}", jobs.fetch("checks").fetch("with").fetch("source-ref")
    checkout = jobs.fetch("publish").fetch("steps").find { |step| step["uses"]&.start_with?("actions/checkout@") }
    assert_equal "${{ needs.validate.outputs.sha }}", checkout.fetch("with").fetch("ref")
    @tests.fetch("jobs").each_value do |job|
      job.fetch("steps").select { |step| step["uses"]&.start_with?("actions/checkout@") }.each do |step|
        assert_equal "${{ inputs.source-ref || github.sha }}", step.fetch("with").fetch("ref")
      end
    end
    validation = jobs.fetch("validate").fetch("steps").find { |step| step["id"] == "release" }.fetch("run")
    assert_includes validation, "git merge-base --is-ancestor HEAD origin/main"
    assert_includes validation, 'refs/tags/$RELEASE_TAG^{commit}'
    assert_includes validation, 'test "$RELEASE_TAG" = "v$version"'
    assert_includes validation, 'error("Release must be published")'
  end
end
