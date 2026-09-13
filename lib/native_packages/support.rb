# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "openssl"
require "optparse"
require "pathname"
require "shellwords"
require "time"
require "tmpdir"
require "yaml"

module NativePackages
  VERSION = "0.3.1"
  class Error < StandardError; end

  module Support
    TOKEN = /@([A-Z][A-Z0-9_]*)@/

    def run(*arguments, env: {}, chdir: root)
      output = capture(*arguments, env: env, chdir: chdir)
      puts output unless output.empty?
    end

    def capture(*arguments, env: {}, chdir: root)
      # Native tools can emit UTF-8 progress even when an SSH session declares
      # US-ASCII. Preserve those bytes; locale-dependent strip would raise.
      output, error, status = Open3.capture3(env, *arguments.map(&:to_s), chdir: chdir.to_s, binmode: true)
      raise Error, "#{arguments.first} failed: #{error.strip}" unless status.success?
      output.strip
    end

    def available?(name)
      extensions = Gem.win_platform? ? [""] + ENV.fetch("PATHEXT", ".EXE;.BAT;.CMD").split(";").map(&:downcase) : [""]
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |path|
        extensions.any? { |extension| File.executable?(File.join(path, name + extension)) && File.file?(File.join(path, name + extension)) }
      end
    end

    def version_arg(value, prerelease: false)
      version = value.delete_prefix("v")
      stable = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.match?(version)
      preview = prerelease && /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-(alpha|beta|rc)\.[1-9]\d*\z/.match?(version)
      unless stable || preview
        raise Error, prerelease ? "expected 1.2.3 or 1.2.3-alpha.N, -beta.N or -rc.N" : "expected a stable version such as 1.2.3"
      end
      version
    end

    def render(value, metadata)
      value.gsub(TOKEN) { metadata.fetch(Regexp.last_match(1)).to_s }
    end

    def render_tree(value, metadata)
      case value
      when Hash then value.to_h { |key, item| [key, render_tree(item, metadata)] }
      when Array then value.map { |item| render_tree(item, metadata) }
      when String then render(value, metadata)
      else value
      end
    end

    def relative_path(value)
      path = Pathname.new(value)
      raise Error, "unsafe relative path: #{value}" if path.absolute? || path.each_filename.any? { |part| %w[.. .git].include?(part) }
      path
    end

    def files(path)
      Pathname.glob(path / "**/*", File::FNM_DOTMATCH).select(&:file?).sort
    end

    def write(path, content, executable: false)
      path = Pathname.new(path)
      path.dirname.mkpath
      raise Error, "refusing to overwrite symlink: #{path}" if path.symlink?
      path.binwrite(content)
      path.chmod(executable ? 0o755 : 0o644)
    end

    def sha256(path) = OpenSSL::Digest::SHA256.file(path).hexdigest

    def recipe_archive(recipes, output, name:, version:, epoch:)
      archive = output / "#{name}-#{version}-packaging.tar.xz"
      run "tar", "--sort=name", "--mtime=@#{epoch}", "--owner=0", "--group=0", "--numeric-owner",
        "-cJf", archive, "-C", recipes, "."
      write(output / "packaging-checksums.txt", files(output).reject { |file| file.basename.to_s == "packaging-checksums.txt" }.map { |file| "#{sha256(file)}  #{file.basename}\n" }.join)
    end

    def upload_assets(repository, version, output)
      version = version_arg(version)
      output = Pathname.new(output).expand_path
      expected = (output / "packaging-checksums.txt").readlines.to_h { |line| digest, name = line.split; [name, digest] }
      raise Error, "no package assets to upload" if expected.empty?
      paths = expected.map do |name, digest|
        raise Error, "invalid package asset filename" unless File.basename(name) == name && name != "checksums.txt"
        pattern = /\A#{Regexp.escape(package_name)}(?:_#{Regexp.escape(version)}_(?:amd64|arm64)\.(?:deb|rpm)|-#{Regexp.escape(version)}-packaging\.tar\.xz)\z/
        raise Error, "package asset does not belong to #{package_name} #{version}: #{name}" unless pattern.match?(name)
        path = output / name
        raise Error, "package asset checksum changed: #{name}" unless path.file? && sha256(path) == digest
        path
      end
      paths << output / "packaging-checksums.txt"
      run "gh", "release", "upload", "v#{version}", *paths, "--repo", repository, "--clobber"
    end

    def download(url, path)
      return if path.file?
      raise Error, "downloads must use HTTPS" unless url.start_with?("https://")
      path.dirname.mkpath
      temporary = Pathname.new("#{path}.partial")
      begin
        run "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
            "--connect-timeout", "20", "--max-time", "600", "--output", temporary, url
        temporary.rename(path)
      ensure
        temporary.delete if temporary.exist?
      end
    end
  end
end
