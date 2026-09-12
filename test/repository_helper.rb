# frozen_string_literal: true

require "minitest/autorun"
require "native_packages"

# A small fixture project keeps repository integration tests independent of any app.
module Packages
  extend NativePackages::Support
  Error = NativePackages::Error

  def self.root = Pathname.pwd
  def self.package_name = "sample-app"
  def self.upstream = "https://example.org/sample-app"

  def self.generate(output, metadata)
    version = metadata.fetch("VERSION")
    write(output / "void/template", "version=#{version}\n")
    write(output / "gentoo/gui-apps/sample-app/sample-app-#{version}.ebuild", "EAPI=8\n")
    write(output / "gentoo/gui-apps/sample-app/Manifest", "DIST sample-app-#{version}-deps.tar.xz 123 SHA512 hash\n")
    write(output / "release.json", JSON.generate(metadata))
  end

  def self.check(output)
    metadata = JSON.parse((output / "release.json").read)
    version_arg(metadata.fetch("VERSION"))
  end

  class Repositories < NativePackages::Repositories
    def initialize(**options)
      super(project: Packages, **options)
    end
  end
end

module PackageTestHelpers
  def metadata = { "VERSION" => "9.8.7" }
end
