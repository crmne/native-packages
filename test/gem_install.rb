# frozen_string_literal: true

# Run after gem build; this deliberately does not require the checkout's library.
require "tmpdir"
require "open3"
require "pathname"
require "yaml"
require "fileutils"

gem_path = File.expand_path(ARGV.fetch(0))
Dir.mktmpdir("native-packages-installed-") do |directory|
  root = Pathname.new(directory)
  gems = root / "gems"
  app = root / "app"
  app.mkpath
  env = { "GEM_HOME" => gems.to_s, "GEM_PATH" => gems.to_s, "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil }
  invoke = lambda do |*arguments|
    output, status = Open3.capture2e(env, *arguments, chdir: app)
    abort "#{arguments.first} failed:\n#{output}" unless status.success?
    output
  end
  invoke.call("gem", "install", "--local", "--no-document", gem_path)
  command = [RbConfig.ruby, (gems / "bin/native-packages").to_s]
  invoke.call(*command, "init", "--name", "installed-example")
  data = YAML.safe_load_file(app / "native-packages.yaml")
  (app / "payload").mkpath
  (app / "payload/message.txt").write("installed gem works\n")
  data["nfpm"]["maintainer"] = "Test <test@example.org>"
  data["nfpm"]["license"] = "MIT"
  data["nfpm"]["contents"] = [{ "src" => "@PAYLOAD@/message.txt", "dst" => "/usr/share/installed-example/message.txt" }]
  data["targets"]["linux-amd64"].merge!("kind" => "data", "formats" => ["deb"], "input" => { "kind" => "directory", "local" => "payload" })
  (app / "native-packages.yaml").write(YAML.dump(data))
  invoke.call(*command, "validate")
  invoke.call(*command, "build", "--version", "1.2.3")
  abort "no package created" if Dir["#{app}/dist/packages/1.2.3/packages/**/*.deb"].empty?
  abort "unexpected consumer Gemfile" unless Dir["#{app}/**/Gemfile*"].empty?
  puts "Isolated gem install, init, validate and build passed without Bundler or a project Gemfile."
end
