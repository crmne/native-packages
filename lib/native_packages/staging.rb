# frozen_string_literal: true

module NativePackages
  # Lays out a package's nFPM contents as a directory tree, for the formats
  # nFPM does not write (AppImage, Flatpak and Snap), and fixes its modes and
  # times so the same inputs give the same bytes.
  module Staging
    include Support

    # nFPM overrides replace the contents list when one is supplied.
    def contents(package, packager)
      package.fetch("overrides", {}).fetch(packager, {}).fetch("contents", package.fetch("contents"))
        .reject { |item| item["packager"] && item["packager"] != packager }
    end

    def inside(tree, destination, packager)
      raise Error, "#{packager}: content destinations must be absolute: #{destination}" unless destination.to_s.start_with?("/")
      tree / relative_path(destination.to_s.delete_prefix("/"))
    end

    def stage(package, tree, packager)
      contents(package, packager).each do |item|
        type = item.fetch("type", "file")
        next if type == "ghost"
        target = inside(tree, item.fetch("dst"), packager)
        mode = item.dig("file_info", "mode")
        case type
        when "dir"
          target.mkpath
        when "symlink"
          target.dirname.mkpath
          File.symlink(item.fetch("src"), target)
        when "file", "tree", "config", "config|noreplace", "config|missingok"
          source = File.expand_path(item.fetch("src"), root)
          paths = package["disable_globbing"] ? [source].select { |path| File.exist?(path) } : Dir.glob(source).sort
          raise Error, "missing package content: #{source}" if paths.empty?
          # As nFPM does: a glob source, or a destination ending in a slash,
          # makes the destination a directory that takes each match's name.
          pattern = !package["disable_globbing"] && item.fetch("src").match?(/[*?\[{]/)
          single = paths.length == 1 && File.file?(paths.first) && type != "tree" && !pattern && !item.fetch("dst").end_with?("/")
          paths.each do |path|
            if File.directory?(path)
              target.mkpath
              FileUtils.cp_r(Dir.children(path).map { |child| File.join(path, child) }, target)
            else
              file = single ? target : target / File.basename(path)
              file.dirname.mkpath
              FileUtils.cp(path, file)
              file.chmod(mode) if mode
            end
          end
        else
          raise Error, "#{packager}: unsupported content type #{type}"
        end
      end
    end

    # The same bytes for the same inputs: fixed modes and times.
    def normalize(tree, epoch)
      time = Time.at(epoch)
      Pathname.glob(tree / "**/*", File::FNM_DOTMATCH).each do |path|
        next if path.basename.to_s == "."
        if path.symlink?
          File.lutime(time, time, path)
        else
          path.chmod(path.directory? || path.executable? ? 0o755 : 0o644)
          File.utime(time, time, path)
        end
      end
      tree.chmod(0o755)
      File.utime(time, time, tree)
    end
  end
end
