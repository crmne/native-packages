# frozen_string_literal: true

require "open3"
require "pathname"

root = Pathname.new(ARGV.fetch(0)).realpath
formats = ARGV.drop(1)
formats = %w[deb rpm archlinux apk ipk srpm] if formats.empty?
commands = {
  "deb" => ["debian:trixie", "dpkg -i", "dpkg -r"],
  "rpm" => ["fedora:41", "rpm -U", "rpm -e"],
  "archlinux" => ["archlinux:base", "pacman --noconfirm -U", "pacman --noconfirm -R"],
  "apk" => ["alpine:3.24.0", "apk add --allow-untrusted", "apk del"],
  "ipk" => ["openwrt/rootfs:x86-64-24.10.8", "opkg install", "opkg remove"]
}
failures = []
formats.each do |format|
  if format == "srpm"
    image = "fedora:41"
    script = <<~SH
      dnf install -y rpm-build gcc
      rpmbuild --rebuild /packages/1.2.3/packages/source/srpm/*.src.rpm
      rpm -U /root/rpmbuild/RPMS/*/*.rpm
      test "$(native-packages-smoke)" = native-packages-ok
      rpm -e native-packages-smoke
    SH
  else
    image, install, remove = commands.fetch(format)
    script = <<~SH
      mkdir -p /run/lock /tmp
      test -d /var/lock || mkdir -p /var/lock
      test -d /var/run || mkdir -p /var/run
      #{install} /packages/1.2.3/packages/linux-amd64/#{format}/*
      test "$(native-packages-smoke)" = native-packages-ok
      #{install} /packages/1.2.4/packages/linux-amd64/#{format}/*
      test "$(native-packages-smoke)" = native-packages-ok
      #{remove} native-packages-smoke
      test ! -e /usr/bin/native-packages-smoke
    SH
  end
  output, status = Open3.capture2e("docker", "run", "--rm", "-v", "#{root}/dist/packages:/packages:ro", image, "sh", "-ec", script)
  if status.success?
    checks = format == "srpm" ? "source rebuild and native install/remove" : "native install/upgrade/remove"
    puts "#{format}: #{checks} passed"
  else
    warn "#{format} acceptance failed:\n#{output}"
    failures << format
  end
end
abort "Native acceptance failed: #{failures.join(', ')}" unless failures.empty?
