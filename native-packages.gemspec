# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "native-packages"
  spec.version = "0.7.0"
  spec.summary = "Build native application packages and publish release updates"
  spec.authors = ["Carmine Paolino"]
  spec.email = ["carmine@paolino.me"]
  spec.homepage = "https://github.com/crmne/native-packages"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "CONTRIBUTING.md", "LICENSE",
    "docs/*.md", "docs/_guides/**/*.md", "docs/_reference/**/*.md", "docs/acceptance/**/*.md",
    "docs/assets/images/logo.svg", "examples/**/*"]
  spec.bindir = "exe"
  spec.executables = ["native-packages"]
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
end
