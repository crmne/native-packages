# frozen_string_literal: true

require "net/http"
require "securerandom"
require "yaml"

module NativePackages
  # Each destination has an independent Git checkout and a small, ignored staging record.
  class Repositories
    attr_reader :entries, :cache, :project

    def initialize(project:, registry: project.root / "packaging/repositories.yml", cache: project.root / ".cache/packaging", entries: nil)
      @project = project
      document = entries ? { "version" => 1, "repositories" => entries } : YAML.safe_load_file(registry, permitted_classes: [], aliases: false)
      raise Error, "unsupported repository registry version" unless document.fetch("version") == 1

      @entries = document.fetch("repositories")
      @cache = Pathname.new(cache).expand_path
      @entries.each do |name, entry|
        raise Error, "invalid repository name: #{name}" unless /\A[a-z0-9-]+\z/.match?(name)
        raise Error, "unknown publish method for #{name}" unless %w[push github-pr gitlab-mr manual].include?(entry.fetch("publish"))
        entry.fetch("url")
        next unless entry.key?("branch")

        safe_relative(entry.fetch("package_path"))
        entry.fetch("files").each { |source, target| safe_relative(source); safe_relative(target) }
        entry.fetch("version_pattern")
        raise Error, "missing version path for #{name}" unless entry["version_file"] || entry["version_files"]
      end
    end

    def select(selector)
      return entries if selector == "all"
      return { selector => entries.fetch(selector) } if entries.key?(selector)

      group = entries.select { |_, entry| entry["group"] == selector }
      raise Error, "unknown target: #{selector}; run repositories to list targets" if group.empty?

      group
    end

    def list
      entries.each do |name, entry|
        puts "#{name.ljust(14)} #{entry.fetch('publish').ljust(10)} #{entry.fetch('url')}"
      end
    end

    def checkout(name) = cache / "repos" / name
    def state_path(name) = cache / "state" / "#{name}.json"
    def body_path(name) = cache / "submissions" / "#{name}.md"
    def state(name) = state_path(name).file? ? JSON.parse(state_path(name).read) : nil
    def fingerprint(entry) = OpenSSL::Digest::SHA256.hexdigest(JSON.generate(entry))

    def git(name, *arguments, allow_failure: false)
      directory = checkout(name)
      directory = cache if !directory.directory?
      env = { "GIT_TERMINAL_PROMPT" => "0", "GIT_SSH_COMMAND" => ENV.fetch("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o ConnectTimeout=20") }
      output, error, status = Open3.capture3(env, "git", *arguments.map(&:to_s), chdir: directory.to_s)
      return [output, status] if allow_failure
      raise Error, "#{name}: git #{arguments.first} failed: #{error.strip}" unless status.success?

      output.strip
    end

    def refresh(name, entry)
      cache.mkpath
      path = checkout(name)
      if path.exist?
        raise Error, "#{path} is not a managed checkout" unless (path / ".git").directory?
        unless git(name, "remote", "get-url", "upstream") == entry.fetch("url") &&
               git(name, "remote", "get-url", "origin") == entry.fetch("fork_url", entry.fetch("url")) &&
               git(name, "remote", "get-url", "--push", "origin") == entry.fetch("push_url", entry.fetch("url"))
          raise Error, "#{name}: checkout remotes differ from the registry; inspect #{path}"
        end
      else
        path.dirname.mkpath
        git(name, "clone", "--filter=blob:none", "--depth=1", "--no-checkout", "--origin", "upstream",
            "--branch", entry.fetch("branch"), entry.fetch("url"), path)
        git(name, "remote", "add", "origin", entry.fetch("fork_url", entry.fetch("url")))
        git(name, "remote", "set-url", "--push", "origin", entry.fetch("push_url", entry.fetch("url")))
        unless entry.fetch("package_path") == "."
          git(name, "sparse-checkout", "set", "--cone", entry.fetch("package_path"), ".github")
        end
        git(name, "checkout", "--detach", "upstream/#{entry.fetch('branch')}")
      end
      [entry.fetch("branch"), entry["status_branch"]].compact.uniq.each do |branch|
        git(name, "fetch", "--depth=1", "upstream", "+refs/heads/#{branch}:refs/remotes/upstream/#{branch}")
      end
      path
    end

    def safe_relative(path)
      parts = path.to_s.split("/")
      if path.to_s.empty? || Pathname.new(path).absolute? || parts.include?("..") || parts.include?(".git")
        raise Error, "unsafe package path: #{path}"
      end
      path
    end

    def contained_path(root, relative)
      safe_relative(relative)
      path = root
      Pathname.new(relative).each_filename do |part|
        path /= part
        raise Error, "refusing to follow a package symlink: #{path}" if path.symlink?
      end
      path
    end

    def payload(output, entry)
      entry.fetch("files").each_with_object({}) do |(source, destination), result|
        from = contained_path(output, source)
        raise Error, "missing generated recipe: #{from}" unless from.exist?

        paths = from.directory? ? project.files(from) : [from]
        paths.each do |file|
          relative = from.directory? ? (Pathname.new(destination) / file.relative_path_from(from)).cleanpath.to_s : destination
          safe_relative(relative)
          raise Error, "duplicate package destination: #{relative}" if result.key?(relative)
          raise Error, "refusing a generated symlink: #{file}" if file.symlink?

          result[relative] = file
        end
      end
    end

    def merge_manifest(previous, current)
      lines = previous.lines.reject { |line| line.strip.empty? }
      current.each_line do |line|
        next if line.strip.empty?
        key = line.split.first(2)
        raise Error, "invalid generated Manifest entry" unless key.first == "DIST" && key.length == 2

        lines.reject! { |old| old.split.first(2) == key }
        lines << line.chomp + "\n"
      end
      lines.sort.join
    end

    def remote_head(name, branch)
      git(name, "ls-remote", "--heads", "origin", "refs/heads/#{branch}").split.first
    end

    def repository_version(name, entry, ref)
      path = entry["version_file"] || entry.fetch("version_files")
      exists = git(name, "ls-tree", ref, "--", path)
      return nil if exists.empty?

      content = if entry["version_files"]
        git(name, "ls-tree", "--name-only", "#{ref}:#{path}")
      else
        git(name, "show", "#{ref}:#{path}")
      end
      content.scan(Regexp.new(entry.fetch("version_pattern"))).flatten.max_by { |version| version.scan(/\d+/).map(&:to_i) }
    end

    def prevent_downgrade(name, previous, version)
      return unless previous && /\A\d+\.\d+\.\d+(?:-\d+|-r\d+)?\z/.match?(previous)
      return unless (previous.scan(/\d+/).first(3).map(&:to_i) <=> version.split(".").map(&:to_i)) == 1

      raise Error, "refusing to downgrade #{name} from #{previous} to #{version}"
    end

    def stage(selector, output)
      output = Pathname.new(output).expand_path
      project.check(output)
      metadata = JSON.parse((output / "release.json").read)
      version = project.version_arg(metadata.fetch("VERSION"))
      select(selector).each do |name, entry|
        if entry.fetch("publish") == "manual"
          puts "#{name}: manual workflow — #{entry.fetch('notes')}"
          next
        end
        stage_one(name, entry, output, metadata, version)
      end
    end

    def stage_one(name, entry, output, metadata, version)
      sources = payload(output, entry)
      digest = OpenSSL::Digest::SHA256.hexdigest(sources.sort.map { |path, file| "#{path}\0#{file.binread}\0#{file.stat.mode & 0o777}" }.join)
      previous = state(name)
      if previous && !previous["published"]
        if previous.fetch("version") == version && previous.fetch("payload_digest") == digest && previous.fetch("registry_digest") == fingerprint(entry)
          puts "#{name}: already prepared in #{checkout(name)}"
          return
        end
        raise Error, "#{name}: an unpublished update exists; inspect it with diff and publish it before staging another"
      end
      if previous && (git(name, "branch", "--show-current") != previous.fetch("branch") || git(name, "rev-parse", "HEAD") != previous.fetch("head_commit", previous["remote_commit"]))
        raise Error, "#{name}: local commits or a branch change exist; inspect #{checkout(name)} before staging"
      end
      path = refresh(name, entry)
      raise Error, "#{name}: checkout has local changes; inspect #{path}" unless git(name, "status", "--porcelain").empty?

      branch = project.render(entry.fetch("proposal_branch", entry.fetch("branch")), metadata)
      existing = nil
      if %w[github-pr gitlab-mr].include?(entry.fetch("publish"))
        proposals = own_requests(entry)
        existing = proposals.find { |request| request.fetch("branch") == branch }
        existing ||= proposals.first if proposals.length == 1
        raise Error, "#{name}: multiple open requests; set proposal_branch to the one to update" if !existing && proposals.length > 1
        if existing
          branch = existing.fetch("branch")
        elsif remote_head(name, branch) && !entry.fetch("proposal_branch").include?("@VERSION@")
          # An old, closed request must not dictate the base of a new submission.
          branch = "#{branch}-#{version}"
        end
      end
      git(name, "check-ref-format", "--branch", branch)
      remote = remote_head(name, branch)
      base = "upstream/#{entry.fetch('branch')}"
      if remote && branch != entry.fetch("branch")
        git(name, "fetch", "--depth=1", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}")
        base = "origin/#{branch}"
      end
      prevent_downgrade(name, repository_version(name, entry, base), version)
      prevent_downgrade(name, repository_version(name, entry, "upstream/#{entry.fetch('branch')}"), version)
      base_commit = git(name, "rev-parse", base)
      local_branch = "packaging/#{name}/#{version}-#{SecureRandom.hex(4)}"
      git(name, "switch", "-c", local_branch, base)
      # Compute every destination before writing; a symlink must never redirect a copy.
      destinations = sources.to_h { |relative, file| [contained_path(path, relative), file] }
      destinations.each do |target, source|
        content = source.binread
        content = merge_manifest(target.read, content) if target.basename.to_s == "Manifest" && target.file?
        project.write(target, content, executable: (source.stat.mode & 0o111).positive?)
      end
      git(name, "add", "--", *sources.keys)
      record = {
        "version" => version, "branch" => local_branch, "destination_branch" => branch,
        "base_commit" => base_commit, "remote_commit" => remote, "paths" => sources.keys.sort,
        "registry_digest" => fingerprint(entry), "payload_digest" => digest, "published" => false,
        "request_url" => existing && existing.fetch("url"),
        "title" => project.render(entry.fetch("title", "#{project.package_name}: update to @VERSION@"), metadata)
      }
      project.write(state_path(name), JSON.pretty_generate(record) + "\n")
      if %w[github-pr gitlab-mr].include?(entry.fetch("publish"))
        description = "Update #{project.package_name} to #{version}.\n\nUpstream release: #{project.upstream}/releases/tag/v#{version}\n\n"
        template = %w[.github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md].map { |file| path / file }.find(&:file?)
        description << (existing && existing["body"] ? existing.fetch("body") : template ? template.read : "Validation:\n\nDescribe the native package checks performed before submitting.\n")
        project.write(body_path(name), description)
        puts "#{name}: edit the submission description at #{body_path(name)}"
      end
      puts "#{name}: staged #{version} in #{path}; run diff #{name} to review"
    end

    def prepared(name, entry)
      record = state(name) or raise Error, "#{name}: no prepared update; run stage first"
      raise Error, "#{name}: registry changed since staging" unless record.fetch("registry_digest") == fingerprint(entry)
      raise Error, "#{name}: checkout is on a different branch" unless git(name, "branch", "--show-current") == record.fetch("branch")
      record
    end

    def diff(selector)
      select(selector).each do |name, entry|
        next if entry.fetch("publish") == "manual"
        record = prepared(name, entry)
        puts "#{name} — #{record.fetch('version')} (#{checkout(name)})"
        puts git(name, "diff", "--no-ext-diff", record.fetch("base_commit"), "--")
      end
    end

    def publish(selector, body_file: nil)
      targets = select(selector)
      if targets.length > 1 && targets.values.any? { |entry| entry.fetch("publish") != "push" }
        raise Error, "publish PR/MR targets individually with their reviewed --body-file"
      end
      targets.each do |name, entry|
        raise Error, "#{name}: #{entry.fetch('notes')}" if entry.fetch("publish") == "manual"
        record = prepared(name, entry)
        if %w[github-pr gitlab-mr].include?(entry.fetch("publish"))
          raise Error, "#{name}: supply a reviewed --body-file (prepared at #{body_path(name)})" unless body_file&.file? && !body_file.read.strip.empty?
          raise Error, "install gh to publish GitHub requests" if entry.fetch("publish") == "github-pr" && !project.available?("gh")
          if entry.fetch("publish") == "gitlab-mr" && ENV.fetch(entry.fetch("token_env"), "").empty?
            raise Error, "set #{entry.fetch('token_env')} to publish GitLab requests"
          end
        end
        raise Error, "#{name}: unstaged edits exist; review and git add them first" unless git(name, "diff", "--name-only").empty?
        raise Error, "#{name}: untracked files exist in the checkout" unless git(name, "ls-files", "--others", "--exclude-standard").empty?
        head = git(name, "rev-parse", "HEAD")
        remote = remote_head(name, record.fetch("destination_branch"))
        unless remote == record["remote_commit"] || remote == head
          _, ancestry = git(name, "merge-base", "--is-ancestor", remote || "", head, allow_failure: true)
          unless remote && ancestry.success?
            raise Error, "#{name}: destination advanced since staging; commit your reviewed changes, fetch and rebase onto origin/#{record.fetch('destination_branch')} in #{checkout(name)}, then retry"
          end
          # The maintainer reconciled the branch manually; exclude those remote changes from our diff.
          record["base_commit"] = remote
          record["remote_commit"] = remote
        end
        changed = git(name, "diff", "--name-only", record.fetch("base_commit"), "--").lines.map(&:strip)
        raise Error, "#{name}: changes outside the prepared package paths" unless (changed - record.fetch("paths")).empty?
        project.write(state_path(name), JSON.pretty_generate(record) + "\n")
      end
      targets.each { |name, entry| publish_one(name, entry, prepared(name, entry), body_file) }
    end

    def publish_one(name, entry, record, body_file)
      unless git(name, "diff", "--cached", "--name-only").empty?
        flags = []
        flags << "-S" if entry["sign_commit"]
        flags << "--signoff" if entry["signoff"]
        git(name, "commit", *flags, "-m", record.fetch("title"))
      end
      if git(name, "rev-parse", "HEAD") == record.fetch("base_commit") && (entry.fetch("publish") == "push" || !record["request_url"])
        puts "#{name}: already up to date"
        record["outcome"] = "unchanged"
      else
        flags = entry["sign_push"] ? ["--signed"] : []
        git(name, "push", *flags, "origin", "HEAD:refs/heads/#{record.fetch('destination_branch')}")
        record["request_url"] = publish_request(name, entry, record, body_file) unless entry.fetch("publish") == "push"
        record["remote_commit"] = git(name, "rev-parse", "HEAD")
        record["outcome"] = "pushed"
        puts "#{name}: published #{record.fetch('version')}#{record['request_url'] && " — #{record['request_url']}"}"
      end
      record["published"] = true
      record["head_commit"] = git(name, "rev-parse", "HEAD")
      project.write(state_path(name), JSON.pretty_generate(record) + "\n")
    end

    def gitlab(entry, path, method: :get, data: nil)
      uri = URI("https://#{entry.fetch('host')}/api/v4/#{path}")
      request = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(method).new(uri)
      token = ENV[entry.fetch("token_env")]
      request["PRIVATE-TOKEN"] = token if token && !token.empty?
      if data
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(data)
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 60) { |http| http.request(request) }
      raise Error, "GitLab API returned HTTP #{response.code} for #{uri.path}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    end

    def project_path(project) = "projects/#{URI.encode_www_form_component(project)}"

    def requests(entry)
      case entry.fetch("publish")
      when "github-pr"
        rows = JSON.parse(project.capture("gh", "pr", "list", "--repo", entry.fetch("repository"), "--state", "open",
          "--search", "#{project.package_name} in:title", "--limit", "100", "--json", "number,url,title,body,headRefName,headRepositoryOwner"))
        rows.map { |row| { "number" => row.fetch("number"), "url" => row.fetch("url"), "title" => row.fetch("title"), "body" => row.fetch("body"), "branch" => row.fetch("headRefName"), "owner" => row.dig("headRepositoryOwner", "login") } }
      when "gitlab-mr"
        rows = gitlab(entry, "#{project_path(entry.fetch('repository'))}/merge_requests?state=opened&scope=all&search=#{URI.encode_www_form_component(project.package_name)}&per_page=100")
        rows.map { |row| { "number" => row.fetch("iid"), "url" => row.fetch("web_url"), "title" => row.fetch("title"), "body" => row["description"], "branch" => row.fetch("source_branch"), "source_project_id" => row.fetch("source_project_id") } }
      else
        []
      end
    end

    def own_requests(entry)
      rows = requests(entry)
      if entry.fetch("publish") == "github-pr"
        rows.select { |row| row["owner"] == entry.fetch("fork_owner") }
      else
        source_id = gitlab(entry, project_path(entry.fetch("fork_repository"))).fetch("id")
        rows.select { |row| row["source_project_id"] == source_id }
      end
    end

    def publish_request(name, entry, record, body_file)
      branch = record.fetch("destination_branch")
      if entry.fetch("publish") == "github-pr"
        existing = requests(entry).find { |request| request.fetch("branch") == branch && request["owner"] == entry.fetch("fork_owner") }
        if existing
          project.capture("gh", "pr", "edit", existing.fetch("url"), "--title", record.fetch("title"), "--body-file", body_file)
          existing.fetch("url")
        else
          project.capture("gh", "pr", "create", "--repo", entry.fetch("repository"), "--base", entry.fetch("branch"),
            "--head", "#{entry.fetch('fork_owner')}:#{branch}", "--title", record.fetch("title"), "--body-file", body_file)
        end
      else
        source_id = gitlab(entry, project_path(entry.fetch("fork_repository"))).fetch("id")
        existing = requests(entry).find { |request| request.fetch("branch") == branch && request["source_project_id"] == source_id }
        data = { "title" => record.fetch("title"), "description" => body_file.read }
        response = if existing
          gitlab(entry, "#{project_path(entry.fetch('repository'))}/merge_requests/#{existing.fetch('number')}", method: :put, data: data)
        else
          target_id = gitlab(entry, project_path(entry.fetch("repository"))).fetch("id")
          gitlab(entry, "#{project_path(entry.fetch('fork_repository'))}/merge_requests", method: :post,
            data: data.merge("source_branch" => branch, "target_branch" => entry.fetch("branch"), "target_project_id" => target_id))
        end
        response.fetch("web_url")
      end
    end

    def status(selector = "all", offline: false, json: false)
      rows = select(selector).map do |name, entry|
        row = { "target" => name, "url" => entry.fetch("url"), "method" => entry.fetch("publish"), "notes" => entry["notes"], "checked_at" => Time.now.utc.iso8601, "source" => offline ? "cached" : "live" }
        record = state(name)
        row["local_version"] = record && record["version"]
        row["local_state"] = record ? (record["published"] ? record.fetch("outcome", "pushed") : "prepared") : "not prepared"
        if entry["branch"]
          begin
            refresh(name, entry) unless offline
            if (checkout(name) / ".git").directory?
              row["upstream_branch"] = entry.fetch("status_branch", entry.fetch("branch"))
              row["upstream_version"] = repository_version(name, entry, "upstream/#{row.fetch('upstream_branch')}")
              row["local_changes"] = !git(name, "status", "--porcelain").empty?
            else
              row["remote_error"] = "not fetched (offline)"
            end
          rescue Error, SystemCallError => error
            row["remote_error"] = error.message
          end
        end
        begin
          row["requests"] = requests(entry).map { |request| request.reject { |key, _| key == "body" } } unless offline
        rescue Error, SystemCallError, IOError, JSON::ParserError, Timeout::Error, SocketError, OpenSSL::OpenSSLError => error
          row["request_error"] = error.message
        end
        row
      end
      if json
        puts JSON.pretty_generate(rows)
      else
        puts "TARGET         UPSTREAM       LOCAL                  OPEN REQUESTS"
        rows.each do |row|
          version = row["remote_error"] ? "unknown" : row["upstream_version"] || (entries.fetch(row.fetch("target"))["branch"] ? "absent" : "manual")
          puts "#{row.fetch('target').ljust(14)} #{version.ljust(14)} #{[row['local_version'], row['local_state']].compact.join(' ').ljust(22)} #{Array(row['requests']).map { |request| request.fetch('url') }.join(' ')}"
          %w[remote_error request_error notes].each { |key| puts "  #{row[key]}" if row[key] }
        end
      end
      !rows.any? { |row| row["remote_error"] || row["request_error"] }
    end
  end
end
