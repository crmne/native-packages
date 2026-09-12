# frozen_string_literal: true

require_relative "project"

module NativePackages
  module CLI
    HELP = <<~TEXT
      Usage: native-packages COMMAND (run from the application repository)
        validate                                   Validate configuration and all templates offline
        prepare VERSION [--output DIRECTORY]       Verify assets and generate recipes
        check DIRECTORY                            Check prepared recipes
        artifacts DIRECTORY [--output DIRECTORY]   Build release packages and recipe bundle
        publish-release VERSION DIRECTORY          Upload package assets to an existing release
        repositories                               List configured downstream destinations
        stage TARGET DIRECTORY                     Stage one target, aur, or all
        diff TARGET                                Review pending changes
        publish TARGET [--body-file FILE]          Push and create/update a submission
        publish-aur DIRECTORY                      Stage and publish all AUR recipes
        status [TARGET] [--json] [--offline]        Check downstream versions and requests
        check-version TAG                          Check that a tag matches the application
    TEXT

    def self.run(root, arguments)
      command = arguments.shift
      return puts(HELP) if %w[--help -h].include?(command)
      return puts(VERSION) if command == "--version"
      project = Project.new(root)
      output = nil
      body_file = nil
      offline = json = false
      OptionParser.new do |options|
        options.on("--output DIRECTORY") { |value| output = Pathname.new(value).expand_path } if %w[prepare artifacts].include?(command)
        options.on("--body-file FILE") { |value| body_file = Pathname.new(value).expand_path } if command == "publish"
        if command == "status"
          options.on("--offline") { offline = true }
          options.on("--json") { json = true }
        end
      end.parse!(arguments)
      arity = { "prepare" => 1..1, "check" => 1..1, "artifacts" => 1..1, "publish-release" => 2..2,
        "repositories" => 0..0, "stage" => 2..2, "diff" => 1..1, "publish" => 1..1, "publish-aur" => 1..1,
        "status" => 0..1, "check-version" => 1..1, "validate" => 0..0 }[command]
      raise Error, HELP unless arity&.cover?(arguments.length)
      case command
      when "validate" then project.validate
      when "prepare" then project.prepare(arguments.first, **(output ? { output: output } : {}))
      when "check" then project.check(arguments.first)
      when "artifacts" then project.artifacts(arguments.first, **(output ? { output: output } : {}))
      when "publish-release" then project.publish_release(*arguments)
      when "repositories" then project.repositories.list
      when "stage" then project.repositories.stage(*arguments)
      when "diff" then project.repositories.diff(arguments.first)
      when "publish" then project.repositories.publish(arguments.first, body_file: body_file)
      when "publish-aur"
        project.repositories.stage("aur", arguments.first)
        project.repositories.publish("aur")
      when "status"
        exit 1 unless project.repositories.status(arguments.first || "all", offline: offline, json: json)
      when "check-version" then project.check_version(arguments.first)
      end
    rescue Error, SystemCallError, KeyError, ArgumentError, OptionParser::ParseError, JSON::ParserError,
           OpenSSL::OpenSSLError, Psych::Exception, IOError, Timeout::Error => error
      abort "packages: #{error.message}"
    end
  end
end
