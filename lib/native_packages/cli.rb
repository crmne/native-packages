# frozen_string_literal: true

require_relative "build"
require_relative "scaffold"

module NativePackages
  module CLI
    HELP = <<~TEXT
      Usage: native-packages [--config FILE] COMMAND [options]
        init [--interactive]                       Create native-packages.yaml
        doctor                                     Check configuration and packaging tools
        validate                                   Validate configuration and templates
        build [--version VERSION | --release TAG]  Build all configured packages
          [--target ID] [--format FORMAT]          Select targets/formats (repeatable)
          [--output DIRECTORY] [--dry-run]         Choose output or inspect the plan
          [--defer-recipes]                        Build targets without recipe assets/tools
        aggregate DIR... --output DIRECTORY        Combine target builds before publishing
          [--finalize-recipes]                    Generate recipes from deferred builds
        publish --from DIRECTORY --to github,aur   Publish a complete, verified build
        migrate [--dry-run]                        Convert packaging/project.yml
        repositories                               List downstream destinations
        stage TARGET DIRECTORY                     Stage prepared recipes
        diff TARGET                                Review pending changes
        publish TARGET [--body-file FILE]          Publish a staged downstream update
        status [TARGET] [--json] [--offline]        Check downstream versions and requests
        check-version TAG                          Check the application's version
      Legacy commands remain available:
        prepare VERSION [--output DIRECTORY]
        check DIRECTORY
        artifacts DIRECTORY [--output DIRECTORY]
        publish-release VERSION DIRECTORY
        publish-aur DIRECTORY
    TEXT

    def self.run(root, arguments)
      arguments = arguments.dup
      config_path = nil
      if arguments.first == "--config"
        arguments.shift
        config_path = arguments.shift or raise Error, "--config needs a path"
      end
      command = arguments.shift
      return puts(HELP) if command.nil? || %w[--help -h].include?(command)
      return puts(VERSION) if command == "--version"
      options = { ids: [], formats: [], destinations: [] }
      parser = OptionParser.new do |flags|
        flags.on("--config FILE") { |value| config_path = value }
        flags.on("--help", "-h") { puts HELP; return }
        flags.on("--output DIRECTORY") { |value| options[:output] = Pathname.new(value).expand_path(root) } if %w[build aggregate artifacts prepare].include?(command)
        flags.on("--body-file FILE") { |value| options[:body_file] = Pathname.new(value).expand_path(root) } if command == "publish"
        if %w[build doctor].include?(command)
          flags.on("--target ID") { |value| options[:ids] << value }
          flags.on("--format FORMAT") { |value| options[:formats] << value }
          flags.on("--release TAG") { |value| options[:release] = value }
          flags.on("--defer-recipes") { options[:defer_recipes] = true }
        end
        if command == "build"
          flags.on("--version VERSION") { |value| options[:value] = value }
          flags.on("--dry-run") { options[:dry_run] = true }
        end
        flags.on("--finalize-recipes") { options[:finalize_recipes] = true } if command == "aggregate"
        if command == "init"
          flags.on("--interactive") { options[:interactive] = true }
          flags.on("--name NAME") { |value| options[:name] = value }
          flags.on("--input PATH") { |value| options[:input] = value }
          flags.on("--formats FORMATS") { |value| options[:init_formats] = value }
        end
        flags.on("--dry-run") { options[:dry_run] = true } if command == "migrate"
        if command == "publish"
          flags.on("--from DIRECTORY") { |value| options[:from] = value }
          flags.on("--to DESTINATIONS") { |value| options[:destinations] += value.split(",") }
        end
        if command == "status"
          flags.on("--offline") { options[:offline] = true }
          flags.on("--json") { options[:json] = true }
        end
      end
      parser.parse!(arguments)
      arity = { "init" => 0..0, "migrate" => 0..0, "build" => 0..0, "doctor" => 0..0, "aggregate" => 1..,
        "prepare" => 1..1, "check" => 1..1, "artifacts" => 1..1, "publish-release" => 2..2,
        "repositories" => 0..0, "stage" => 2..2, "diff" => 1..1, "publish" => options[:from] ? 0..0 : 1..1,
        "publish-aur" => 1..1, "status" => 0..1, "check-version" => 1..1, "validate" => 0..0 }[command]
      raise Error, HELP unless arity&.cover?(arguments.length)
      if command == "init"
        raise Error, "init writes native-packages.yaml in the current directory" if config_path
        return Scaffold.new(root).init(**options.slice(:interactive, :name, :input).merge(formats: options[:init_formats]))
      end
      return Scaffold.new(root).migrate(dry_run: options[:dry_run]) if command == "migrate"
      path = Configuration.discover(root, config_path)
      configuration = path && Configuration.new(path)
      if %w[build doctor aggregate].include?(command) || options[:from]
        raise Error, "create native-packages.yaml with init, or convert existing packaging with migrate" unless configuration
        builder = Build.new(configuration)
        case command
        when "build" then return builder.run_build(**options.slice(:value, :release, :ids, :formats, :output, :dry_run, :defer_recipes))
        when "doctor"
          builder.doctor(**options.slice(:ids, :formats, :release, :defer_recipes))
          return puts "Configuration and packaging tools are ready. Build checks input files and package contents."
        when "aggregate"
          raise Error, "aggregate requires --output" unless options[:output]
          return builder.aggregate(arguments, output: options.fetch(:output), finalize_recipes: options.fetch(:finalize_recipes, false))
        when "publish" then return builder.publish(options.fetch(:from), options.fetch(:destinations), body_file: options[:body_file])
        end
      end
      if configuration
        configuration.validate
        return puts "Configuration and templates are valid." if command == "validate"
      end
      project = configuration ? configuration.project : Project.new(root)
      case command
      when "validate" then project.validate
      when "prepare" then project.prepare(arguments.first, **options.slice(:output))
      when "check" then project.check(arguments.first)
      when "artifacts" then project.artifacts(arguments.first, **options.slice(:output))
      when "publish-release" then project.publish_release(*arguments)
      when "repositories" then project.repositories.list
      when "stage" then project.repositories.stage(*arguments)
      when "diff" then project.repositories.diff(arguments.first)
      when "publish" then project.repositories.publish(arguments.first, body_file: options[:body_file])
      when "publish-aur"
        project.repositories.stage("aur", arguments.first)
        project.repositories.publish("aur")
      when "status"
        exit 1 unless project.repositories.status(arguments.first || "all", offline: options[:offline], json: options[:json])
      when "check-version" then project.check_version(arguments.first)
      end
    rescue Error, SystemCallError, KeyError, ArgumentError, OptionParser::ParseError, JSON::ParserError,
           OpenSSL::OpenSSLError, Psych::Exception, IOError, Timeout::Error => error
      abort "native-packages: #{error.message}"
    end
  end
end
