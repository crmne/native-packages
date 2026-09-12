# frozen_string_literal: true

require_relative "repository_helper"

class PackageRepositoriesTest < Minitest::Test
  include PackageTestHelpers

  def setup
    @root = Pathname.new(Dir.mktmpdir("sample-app-repositories-"))
    @environment = ENV.to_h
    ENV.update("GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_AUTHOR_NAME" => "Packaging Test", "GIT_AUTHOR_EMAIL" => "test@example.org",
      "GIT_COMMITTER_NAME" => "Packaging Test", "GIT_COMMITTER_EMAIL" => "test@example.org")
    @seed = @root / "seed"
    @seed.mkpath
    command("git", "init", "-b", "main", @seed)
    Packages.write(@seed / "pkg/sample-app/recipe", "version=9.8.6\n")
    Packages.write(@seed / "pkg/sample-app/README.local", "downstream notes\n")
    Packages.write(@seed / "unrelated.txt", "other packages\n")
    command("git", "-C", @seed, "add", ".")
    command("git", "-C", @seed, "commit", "-m", "Initial downstream package")
    @upstream = @root / "upstream.git"
    @fork = @root / "fork.git"
    command("git", "clone", "--bare", @seed, @upstream)
    command("git", "clone", "--bare", @seed, @fork)
    @entry = {
      "url" => "file://#{@upstream}", "push_url" => "file://#{@upstream}", "branch" => "main",
      "package_path" => "pkg/sample-app", "files" => { "void/template" => "pkg/sample-app/recipe" },
      "version_file" => "pkg/sample-app/recipe", "version_pattern" => '^version=(\S+)', "publish" => "push"
    }
    @output = @root / "generated"
    Packages.generate(@output, metadata)
    configure
  end

  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@root)
  end

  def command(*args)
    output, error, status = Open3.capture3(*args.map(&:to_s))
    raise "#{args.first} failed: #{error}" unless status.success?
    output.strip
  end

  def configure(entry = @entry, name: "sample")
    @registry = @root / "repositories.yml"
    @registry.write(YAML.dump("version" => 1, "repositories" => { name => entry }))
    @manager = Packages::Repositories.new(registry: @registry, cache: @root / "cache with spaces")
  end

  def stage
    capture_subprocess_io { @manager.stage("sample", @output) }
  end

  def remote_file(path = "pkg/sample-app/recipe")
    command("git", "--git-dir", @upstream, "show", "main:#{path}")
  end

  def test_stage_diff_and_publish_preserve_downstream_history
    before = command("git", "--git-dir", @upstream, "rev-parse", "main")
    stage
    assert_equal "version=9.8.6", remote_file
    assert_equal "downstream notes\n", (@manager.checkout("sample") / "pkg/sample-app/README.local").read
    diff, = capture_io { @manager.diff("sample") }
    assert_includes diff, "+version=9.8.7"
    record = @manager.state("sample")
    stage
    assert_equal record, @manager.state("sample")
    capture_subprocess_io { @manager.publish("sample") }
    assert_includes remote_file, "version=9.8.7"
    assert_equal "other packages", remote_file("unrelated.txt")
    assert_equal before, command("git", "--git-dir", @upstream, "rev-parse", "main^")
    assert @manager.state("sample").fetch("published")
    commits = command("git", "--git-dir", @upstream, "rev-list", "--count", "main")
    capture_subprocess_io { @manager.publish("sample") }
    assert_equal commits, command("git", "--git-dir", @upstream, "rev-list", "--count", "main")
  end

  def test_unstaged_or_unrelated_edits_cannot_be_published
    stage
    path = @manager.checkout("sample")
    (path / "pkg/sample-app/recipe").write("version=9.8.7\n# reviewed adjustment\n")
    error = assert_raises(Packages::Error) { @manager.publish("sample") }
    assert_match "unstaged", error.message
    command("git", "-C", path, "add", "pkg/sample-app/recipe")
    (path / "unrelated.txt").write("must not publish\n")
    command("git", "-C", path, "add", "unrelated.txt")
    error = assert_raises(Packages::Error) { @manager.publish("sample") }
    assert_match "outside the prepared", error.message
    assert_equal "version=9.8.6", remote_file
  end

  def test_remote_race_is_rejected_without_overwriting_staged_work
    stage
    Packages.write(@seed / "unrelated.txt", "another maintainer's change\n")
    command("git", "-C", @seed, "commit", "-am", "Another maintainer")
    command("git", "-C", @seed, "push", @upstream, "main")
    error = assert_raises(Packages::Error) { @manager.publish("sample") }
    assert_match "destination advanced", error.message
    assert_equal "another maintainer's change", remote_file("unrelated.txt")
    assert_includes (@manager.checkout("sample") / "pkg/sample-app/recipe").read, "version=9.8.7"
    path = @manager.checkout("sample")
    command("git", "-C", path, "commit", "-m", "Reviewed update")
    command("git", "-C", path, "fetch", "origin", "main:refs/remotes/origin/main")
    command("git", "-C", path, "rebase", "origin/main")
    capture_subprocess_io { @manager.publish("sample") }
    assert_includes remote_file, "version=9.8.7"
    assert_equal "another maintainer's change", remote_file("unrelated.txt")
  end

  def test_new_staging_does_not_hide_local_commits_after_publication
    stage
    capture_subprocess_io { @manager.publish("sample") }
    path = @manager.checkout("sample")
    Packages.write(path / "unrelated.txt", "local work\n")
    command("git", "-C", path, "commit", "-am", "Keep local work")
    head = command("git", "-C", path, "rev-parse", "HEAD")
    capture_subprocess_io do
      error = assert_raises(Packages::Error) { @manager.stage("sample", @output) }
      assert_match "local commits", error.message
    end
    assert_equal head, command("git", "-C", path, "rev-parse", "HEAD")
  end

  def test_changed_registry_and_pending_payload_are_rejected
    stage
    newer = metadata.merge("VERSION" => "9.8.8")
    Packages.generate(@output, newer)
    capture_subprocess_io do
      error = assert_raises(Packages::Error) { @manager.stage("sample", @output) }
      assert_match "unpublished update", error.message
    end
    configure(@entry.merge("push_url" => "file://#{@fork}"))
    error = assert_raises(Packages::Error) { @manager.publish("sample") }
    assert_match "registry changed", error.message
  end

  def test_downgrades_are_rejected
    Packages.generate(@output, metadata.merge("VERSION" => "9.8.5"))
    capture_subprocess_io do
      error = assert_raises(Packages::Error) { @manager.stage("sample", @output) }
      assert_match "refusing to downgrade", error.message
    end
    assert_equal "version=9.8.6", remote_file
  end

  def test_gentoo_updates_keep_old_ebuilds_and_manifest_entries
    Packages.write(@seed / "pkg/sample-app/sample-app-9.8.6.ebuild", "EAPI=8\n")
    Packages.write(@seed / "pkg/sample-app/Manifest", "DIST old.tar.gz 123 SHA512 old\n")
    command("git", "-C", @seed, "add", ".")
    command("git", "-C", @seed, "commit", "-m", "Gentoo history")
    command("git", "-C", @seed, "push", @upstream, "main")
    configure(@entry.reject { |key, _| key == "version_file" }.merge(
      "files" => { "gentoo/gui-apps/sample-app" => "pkg/sample-app" }, "version_files" => "pkg/sample-app",
      "version_pattern" => 'sample-app-([0-9.]+)\.ebuild'))
    stage
    root = @manager.checkout("sample") / "pkg/sample-app"
    assert_path_exists root / "sample-app-9.8.6.ebuild"
    assert_path_exists root / "sample-app-9.8.7.ebuild"
    assert_includes (root / "Manifest").read, "DIST old.tar.gz 123 SHA512 old"
    assert_includes (root / "Manifest").read, "sample-app-9.8.7-deps.tar.xz"
    assert_path_exists root / "README.local"
  end

  def test_destination_symlinks_and_path_traversal_are_rejected
    error = assert_raises(Packages::Error) { configure(@entry.merge("files" => { "void/template" => "../outside" })) }
    assert_match "unsafe package path", error.message
    configure
    @manager.refresh("sample", @entry)
    recipe = @manager.checkout("sample") / "pkg/sample-app/recipe"
    recipe.delete
    File.symlink(@root / "outside", recipe)
    assert_raises(Packages::Error) { @manager.contained_path(@manager.checkout("sample"), "pkg/sample-app/recipe") }
    refute_path_exists @root / "outside"
  end

  def test_status_refreshes_versions_and_offline_status_does_not_fetch
    output, = capture_io { assert @manager.status("sample", json: true) }
    assert_equal "9.8.6", JSON.parse(output).first.fetch("upstream_version")
    Packages.write(@seed / "pkg/sample-app/recipe", "version=9.8.7\n")
    command("git", "-C", @seed, "commit", "-am", "New downstream version")
    command("git", "-C", @seed, "push", @upstream, "main")
    output, = capture_io { assert @manager.status("sample", offline: true, json: true) }
    assert_equal "9.8.6", JSON.parse(output).first.fetch("upstream_version")
    output, = capture_io { assert @manager.status("sample", json: true) }
    assert_equal "9.8.7", JSON.parse(output).first.fetch("upstream_version")
  end

  def test_status_distinguishes_missing_packages_from_failed_fetches
    configure(@entry.merge("version_file" => "pkg/sample-app/missing"))
    output, = capture_io { assert @manager.status("sample", json: true) }
    row = JSON.parse(output).first
    assert_nil row["upstream_version"]
    refute row.key?("remote_error")
    FileUtils.mv(@upstream, @root / "unavailable.git")
    output, = capture_io { refute @manager.status("sample", json: true) }
    assert JSON.parse(output).first.key?("remote_error")
  end

  def test_manual_destinations_are_listed_without_being_published
    configure({ "url" => "https://example.org/upload", "publish" => "manual", "notes" => "Native upload required" })
    output, = capture_io { assert @manager.status("sample", json: true) }
    assert_equal "manual", JSON.parse(output).first.fetch("method")
    assert_raises(Packages::Error) { @manager.publish("sample") }
  end

  def test_github_submission_uses_fork_branch_and_reviewed_body_without_duplicates
    entry = @entry.merge("publish" => "github-pr", "fork_url" => "file://#{@fork}", "push_url" => "file://#{@fork}",
      "proposal_branch" => "sample-app", "repository" => "example/upstream", "fork_owner" => "maintainer")
    configure(entry)
    bin = @root / "bin"
    bin.mkpath
    log = @root / "gh.log"
    marker = @root / "open-pr"
    script = <<~RUBY
      #!#{RbConfig.ruby}
      require 'json'
      File.open(#{log.to_s.inspect}, 'a') { |file| file.puts ARGV.to_json }
      case ARGV[0, 2]
      when ['pr', 'list']
        puts(File.exist?(#{marker.to_s.inspect}) ? [{number: 7, url: 'https://github.com/example/upstream/pull/7', title: 'sample-app', body: 'Reviewed original description', headRefName: 'sample-app', headRepositoryOwner: {login: 'maintainer'}}].to_json : '[]')
      when ['pr', 'create']
        File.write(#{marker.to_s.inspect}, 'open')
        puts 'https://github.com/example/upstream/pull/7'
      when ['pr', 'edit']
        puts 'https://github.com/example/upstream/pull/7'
      else
        abort 'unexpected gh command'
      end
    RUBY
    Packages.write(bin / "gh", script, executable: true)
    ENV["PATH"] = "#{bin}:#{ENV.fetch('PATH')}"
    stage
    assert_raises(Packages::Error) { @manager.publish("sample") }
    body = @root / "reviewed description.md"
    body.write("Native package build passed.\nLiteral `code` and $(text) remain text.\n")
    capture_subprocess_io { @manager.publish("sample", body_file: body) }
    capture_subprocess_io { @manager.publish("sample", body_file: body) }
    commands = log.readlines.map { |line| JSON.parse(line) }
    assert_equal 1, commands.count { |args| args[0, 2] == %w[pr create] }
    create = commands.find { |args| args[0, 2] == %w[pr create] }
    assert_equal "maintainer:sample-app", create[create.index("--head") + 1]
    assert_equal body.to_s, create[create.index("--body-file") + 1]
    assert_equal "version=9.8.6", remote_file
    assert_includes command("git", "--git-dir", @fork, "show", "sample-app:pkg/sample-app/recipe"), "version=9.8.7"
    assert_equal "https://github.com/example/upstream/pull/7", @manager.state("sample").fetch("request_url")
  end

  def test_gitlab_publication_creates_then_updates_the_same_fork_request
    configure(@entry.merge("publish" => "gitlab-mr", "fork_url" => "file://#{@fork}", "push_url" => "file://#{@fork}",
      "proposal_branch" => "testing/sample-app", "repository" => "distro/packages", "fork_repository" => "maintainer/packages",
      "host" => "gitlab.example.org", "token_env" => "PACKAGE_TEST_GITLAB_TOKEN"))
    client = Class.new(Packages::Repositories) do
      attr_reader :api_calls

      def gitlab(_entry, path, method: :get, data: nil)
        (@api_calls ||= []) << [path, method, data]
        if path == "projects/maintainer%2Fpackages"
          { "id" => 10 }
        elsif path == "projects/distro%2Fpackages"
          { "id" => 20 }
        elsif method == :get
          @opened ? [{ "iid" => 7, "web_url" => "https://gitlab.example.org/distro/packages/-/merge_requests/7", "title" => "sample-app", "source_branch" => "testing/sample-app", "source_project_id" => 10, "description" => "Reviewed" }] : []
        else
          @opened = true
          { "web_url" => "https://gitlab.example.org/distro/packages/-/merge_requests/7" }
        end
      end
    end
    @manager = client.new(registry: @registry, cache: @root / "cache with spaces")
    stage
    body = @root / "reviewed.md"
    body.write("Native Alpine checks passed.\n")
    assert_raises(Packages::Error) { @manager.publish("sample", body_file: body) }
    ENV["PACKAGE_TEST_GITLAB_TOKEN"] = "test-token"
    capture_subprocess_io { @manager.publish("sample", body_file: body) }
    capture_subprocess_io { @manager.publish("sample", body_file: body) }
    creates = @manager.api_calls.select { |_, method, _| method == :post }
    assert_equal 1, creates.length
    assert_equal "projects/maintainer%2Fpackages/merge_requests", creates.first[0]
    assert_equal 20, creates.first[2].fetch("target_project_id")
    assert_equal "testing/sample-app", creates.first[2].fetch("source_branch")
    assert_equal body.read, creates.first[2].fetch("description")
    assert @manager.api_calls.any? { |path, method, _| path == "projects/distro%2Fpackages/merge_requests/7" && method == :put }
    assert_equal "version=9.8.6", remote_file
  end

  def proposal_client(proposals)
    client = Class.new(Packages::Repositories) do
      attr_accessor :proposals

      def requests(_entry) = proposals
    end
    @manager = client.new(registry: @registry, cache: @root / "cache with spaces")
    @manager.proposals = proposals
  end

  def test_staging_reuses_an_open_request_and_preserves_its_history
    command("git", "-C", @seed, "switch", "-c", "historical-request")
    Packages.write(@seed / "pkg/sample-app/README.local", "reviewer's package notes\n")
    command("git", "-C", @seed, "commit", "-am", "Review feedback")
    command("git", "-C", @seed, "push", @fork, "historical-request")
    configure(@entry.merge("publish" => "github-pr", "fork_url" => "file://#{@fork}", "push_url" => "file://#{@fork}",
      "proposal_branch" => "sample-app-@VERSION@", "repository" => "example/upstream", "fork_owner" => "maintainer"))
    proposal_client([{ "branch" => "historical-request", "owner" => "maintainer", "url" => "https://example.org/pull/7", "body" => "Reviewed checks" }])
    stage
    assert_equal "historical-request", @manager.state("sample").fetch("destination_branch")
    assert_equal "https://example.org/pull/7", @manager.state("sample").fetch("request_url")
    assert_equal "reviewer's package notes\n", (@manager.checkout("sample") / "pkg/sample-app/README.local").read
    assert_includes @manager.body_path("sample").read, "Reviewed checks"
    assert_equal command("git", "--git-dir", @fork, "rev-parse", "historical-request"), @manager.state("sample").fetch("base_commit")
  end

  def test_closed_request_branches_do_not_supply_the_next_update_base
    command("git", "-C", @seed, "switch", "-c", "sample-app")
    Packages.write(@seed / "pkg/sample-app/README.local", "abandoned request\n")
    command("git", "-C", @seed, "commit", "-am", "Closed request")
    command("git", "-C", @seed, "push", @fork, "sample-app")
    configure(@entry.merge("publish" => "github-pr", "fork_url" => "file://#{@fork}", "push_url" => "file://#{@fork}",
      "proposal_branch" => "sample-app", "repository" => "example/upstream", "fork_owner" => "maintainer"))
    proposal_client([])
    stage
    assert_equal "sample-app-9.8.7", @manager.state("sample").fetch("destination_branch")
    assert_equal "downstream notes\n", (@manager.checkout("sample") / "pkg/sample-app/README.local").read
    assert_equal command("git", "--git-dir", @upstream, "rev-parse", "main"), @manager.state("sample").fetch("base_commit")
  end

  def test_an_unchanged_recipe_does_not_push_or_create_an_empty_request
    Packages.write(@seed / "pkg/sample-app/recipe", (@output / "void/template").read)
    command("git", "-C", @seed, "commit", "-am", "Package already current")
    command("git", "-C", @seed, "push", @upstream, "main")
    configure(@entry.merge("publish" => "gitlab-mr", "fork_url" => "file://#{@fork}", "push_url" => "file://#{@fork}",
      "proposal_branch" => "sample-app-@VERSION@", "repository" => "distro/packages", "fork_repository" => "maintainer/packages",
      "host" => "gitlab.example.org", "token_env" => "PACKAGE_TEST_GITLAB_TOKEN"))
    client = Class.new(Packages::Repositories) do
      def own_requests(_entry) = []
      def publish_request(*) = raise("an unchanged package must not open a request")
    end
    @manager = client.new(registry: @registry, cache: @root / "cache with spaces")
    ENV["PACKAGE_TEST_GITLAB_TOKEN"] = "test-token"
    body = @root / "reviewed.md"
    body.write("Native package checks passed.\n")
    stage
    capture_subprocess_io { @manager.publish("sample", body_file: body) }
    assert_equal "unchanged", @manager.state("sample").fetch("outcome")
    assert_empty command("git", "--git-dir", @fork, "for-each-ref", "refs/heads/sample-app-9.8.7")
    stage
    capture_subprocess_io { @manager.publish("sample", body_file: body) }
    assert_equal "unchanged", @manager.state("sample").fetch("outcome")
  end

  def test_guru_requests_signed_commits_and_pushes
    configure(@entry.merge("sign_commit" => true, "sign_push" => true, "signoff" => true))
    client = Class.new(Packages::Repositories) do
      attr_reader :git_calls

      def git(name, *arguments, **options)
        (@git_calls ||= []) << arguments
        # Exercise Git normally, but do not require a hardware signing key in the test.
        super(name, *(arguments - ["-S", "--signed"]), **options)
      end
    end
    @manager = client.new(registry: @registry, cache: @root / "cache with spaces")
    stage
    capture_subprocess_io { @manager.publish("sample") }
    assert @manager.git_calls.any? { |args| args.first == "commit" && args.include?("-S") && args.include?("--signoff") }
    assert @manager.git_calls.any? { |args| args.first == "push" && args.include?("--signed") }
    assert_includes command("git", "--git-dir", @upstream, "log", "-1", "--format=%B"), "Signed-off-by: Packaging Test <test@example.org>"
  end
end
