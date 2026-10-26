# frozen_string_literal: true

# Runs on a Windows runner without an Azure account: downloads the pinned
# SignTool and Artifact Signing client, checks their hashes, extracts them,
# and reads real Authenticode signatures through PowerShell.
require "native_packages"

Dir.mktmpdir("native-packages-windows-signing-tools-") do |directory|
  directory = Pathname.new(directory)
  (directory / "native-packages.yaml").write(YAML.dump("schema" => 1, "tool" => { "version" => NativePackages::VERSION, "nfpm" => "2.47.0" },
    "nfpm" => { "name" => "fixture" }, "targets" => {}, "windows" => { "signing" => { "provider" => "azure-artifact-signing" } }))
  configuration = NativePackages::Configuration.new(directory / "native-packages.yaml")
  signer = NativePackages::WindowsSigning.new(configuration, ENV.to_h.reject { |name, _| name.start_with?("NATIVE_PACKAGES_") })
  tools = directory / "tools"
  signtool = signer.tool("signtool", tools)
  dlib = signer.tool("dlib", tools)
  unsigned = directory / "unsigned.exe"
  unsigned.binwrite("MZ" + ("\0" * 126))
  records = signer.signatures([signtool, dlib, unsigned])
  records.each { |record| puts JSON.generate(record) }
  signtool_record, dlib_record, unsigned_record = records
  [signtool_record, dlib_record].each do |record|
    unless record.fetch("status") == "Valid" && record.fetch("timestamped") && record.fetch("publisher") == "Microsoft Corporation"
      abort "expected a valid, timestamped Microsoft signature: #{record.fetch('path')}"
    end
  end
  abort "expected an unsigned fixture" unless unsigned_record.fetch("status") == "NotSigned"
  help = IO.popen([signtool.to_s, "sign", "/?"], err: %i[child out], &:read)
  abort "SignTool does not offer /dlib" unless help.include?("/dlib")
  puts "Pinned Windows signing tools are ready."
end
