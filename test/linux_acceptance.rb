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
  "ipk" => ["openwrt/rootfs", "opkg install", "opkg remove"]
}
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
      mkdir -p /var/lock /var/run /tmp
      #{install} /packages/1.2.3/packages/linux-amd64/#{format}/*
      test "$(native-packages-smoke)" = native-packages-ok
      #{install} /packages/1.2.4/packages/linux-amd64/#{format}/*
      test "$(native-packages-smoke)" = native-packages-ok
      #{remove} native-packages-smoke
      test ! -e /usr/bin/native-packages-smoke
    SH
  end
  output, status = Open3.capture2e("docker", "run", "--rm", "-v", "#{root}/dist/packages:/packages:ro", image, "sh", "-ec", script)
  abort "#{format} acceptance failed:\n#{output}" unless status.success?
  puts "#{format}: native install/upgrade/remove#{format == 'srpm' ? ' and source rebuild' : ''} passed"
end
