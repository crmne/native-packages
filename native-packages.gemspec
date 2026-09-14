# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "native-packages"
  spec.version = "0.6.0"
  spec.summary = "Shared release packaging and downstream recipe updates with nFPM"
  spec.authors = ["Carmine Paolino"]
  spec.email = ["carmine@paolino.me"]
  spec.homepage = "https://github.com/crmne/native-packages"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "docs/**/*.md", "examples/**/*"]
  spec.bindir = "exe"
  spec.executables = ["native-packages"]
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
end
