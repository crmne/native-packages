# frozen_string_literal: true

module NativePackages
  # Authenticode signing through Azure Artifact Signing (formerly Trusted
  # Signing). The configuration opts in; the account coordinates come from the
  # environment, and Azure authentication from an existing Azure CLI sign-in
  # (`az login`, or azure/login with OIDC in CI). No secret is read or stored.
  class WindowsSigning
    include Support
    PROVIDER = "azure-artifact-signing"
    KEYS = %w[provider description description_url publisher].freeze
    VARIABLES = %w[AZURE_SIGNING_ENDPOINT AZURE_SIGNING_ACCOUNT AZURE_SIGNING_PROFILE].freeze
    TIMESTAMP = "http://timestamp.acs.microsoft.com"
    # Every DefaultAzureCredential source except the Azure CLI's, so a stray
    # client secret or cached account can never sign in its place.
    EXCLUDED_CREDENTIALS = %w[EnvironmentCredential WorkloadIdentityCredential ManagedIdentityCredential
      SharedTokenCacheCredential VisualStudioCredential VisualStudioCodeCredential AzurePowerShellCredential
      AzureDeveloperCliCredential InteractiveBrowserCredential].freeze
    # The versions azure/artifact-signing-action 2.0.0 installs, pinned by hash.
    TOOLS = {
      "signtool" => { "package" => "microsoft.windows.sdk.buildtools", "version" => "10.0.26100.4188",
        "sha256" => "180deb372659029864c10a0c04787833234d64aacd1d2c0661d2c00295d8e022",
        "directory" => "bin/10.0.26100.0/x64", "file" => "signtool.exe", "override" => "NATIVE_PACKAGES_SIGNTOOL" },
      "dlib" => { "package" => "microsoft.artifactsigning.client", "version" => "1.0.128",
        "sha256" => "74bd7d27e6ce1051409c38d9b46bc8df0400ecd643d51ffbf2ac00869061e40b",
        "directory" => "bin/x64", "file" => "Azure.CodeSigning.Dlib.dll", "override" => "NATIVE_PACKAGES_ARTIFACT_SIGNING_DLIB" }
    }.freeze
    # Command lines on Windows hold 32,767 characters; leave room for options.
    BATCH_CHARACTERS = 16_000
    SIGNATURES = <<~'POWERSHELL'
      $ErrorActionPreference = 'Stop'
      $simple = [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName
      $paths = @(Get-Content -LiteralPath $env:NATIVE_PACKAGES_SIGNATURE_LIST -Encoding UTF8)
      $result = @(foreach ($line in $paths) {
        # Plain strings: lines from Get-Content carry note properties that
        # ConvertTo-Json would otherwise write out as an object.
        $path = [string]$line
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        $certificate = $signature.SignerCertificate
        $publisher = $null
        $subject = $null
        if ($certificate) {
          $publisher = $certificate.GetNameInfo($simple, $false)
          $subject = $certificate.Subject
        }
        [pscustomobject]@{ path = $path; status = [string]$signature.Status; message = [string]$signature.StatusMessage;
          publisher = $publisher; subject = $subject; timestamped = [bool]$signature.TimeStamperCertificate }
      })
      [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $result -Compress -Depth 3)))
    POWERSHELL

    # Only the tool's own directory leaves the NuGet package (a ZIP file).
    EXTRACT = <<~'POWERSHELL'
      $ErrorActionPreference = 'Stop'
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $prefix = $env:NATIVE_PACKAGES_PREFIX + '/'
      $zip = [System.IO.Compression.ZipFile]::OpenRead($env:NATIVE_PACKAGES_ARCHIVE)
      try {
        foreach ($entry in $zip.Entries) {
          if (-not $entry.FullName.StartsWith($prefix) -or -not $entry.Name -or $entry.FullName.Contains('..')) { continue }
          $target = Join-Path $env:NATIVE_PACKAGES_DESTINATION $entry.FullName
          New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
          [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
      } finally {
        $zip.Dispose()
      }
    POWERSHELL

    attr_reader :root, :settings

    def self.validate(data)
      windows = data.fetch("windows", {})
      raise Error, "windows: expected a mapping" unless windows.is_a?(Hash)
      unknown = windows.keys - %w[signing]
      raise Error, "windows: unknown fields #{unknown.join(', ')}" unless unknown.empty?
      return unless windows.key?("signing")
      signing = windows["signing"]
      raise Error, "windows.signing: expected a mapping" unless signing.is_a?(Hash)
      unknown = signing.keys - KEYS
      raise Error, "windows.signing: unknown fields #{unknown.join(', ')}" unless unknown.empty?
      raise Error, "windows.signing.provider: use #{PROVIDER}" unless signing["provider"] == PROVIDER
      %w[description publisher].each do |key|
        next unless signing.key?(key)
        raise Error, "windows.signing.#{key}: expected a nonempty string" unless signing[key].is_a?(String) && !signing[key].strip.empty?
      end
      if signing.key?("description_url") && !(signing["description_url"].is_a?(String) && %r{\Ahttps://\S+\z}.match?(signing["description_url"]))
        raise Error, "windows.signing.description_url: expected an https:// URL"
      end
    end

    def initialize(configuration, environment = ENV)
      @root = configuration.root
      self.class.validate(configuration.data)
      @settings = configuration.data.fetch("windows", {}).fetch("signing", nil)
      @environment = environment
      @values = VARIABLES.to_h { |name| [name, environment[name].to_s.strip] }
      @description = settings && settings.fetch("description", configuration.name)
      @description_url = settings && (settings["description_url"] || configuration.data.fetch("nfpm")["homepage"])
    end

    def configured? = !settings.nil?
    def enabled? = configured? && @values.values.any? { |value| !value.empty? }
    def state = !configured? ? "off" : enabled? ? "enabled" : "off: #{VARIABLES.join(', ')} not set"

    def doctor
      return unless enabled?
      missing = @values.select { |_, value| value.empty? }.keys
      raise Error, "incomplete Azure Artifact Signing settings: set #{missing.join(', ')}" unless missing.empty?
      unless %r{\Ahttps://[a-z0-9-]+\.codesigning\.azure\.net/?\z}.match?(@values.fetch("AZURE_SIGNING_ENDPOINT"))
        raise Error, "AZURE_SIGNING_ENDPOINT must be an Artifact Signing endpoint such as https://weu.codesigning.azure.net/"
      end
      %w[AZURE_SIGNING_ACCOUNT AZURE_SIGNING_PROFILE].each do |name|
        raise Error, "#{name} must be a name, not a path or URL" unless /\A[A-Za-z0-9][A-Za-z0-9-]*\z/.match?(@values.fetch(name))
      end
      raise Error, "Windows signing must run on Windows" unless NativeRecipe.host == "windows"
      tools = %w[powershell az]
      tools << "curl" if TOOLS.values.any? { |tool| @environment[tool.fetch("override")].to_s.empty? }
      missing_tools = tools.reject { |tool| available?(tool) }
      raise Error, "install required Windows signing tools: #{missing_tools.join(', ')}" unless missing_tools.empty?
      TOOLS.each_value do |tool|
        path = @environment[tool.fetch("override")].to_s
        raise Error, "#{tool.fetch('override')} does not name a file: #{path}" unless path.empty? || File.file?(path)
      end
      begin
        execute "az", "account", "show", "--output", "none"
      rescue Error
        raise Error, "sign in to Azure before signing: az login, or azure/login with OIDC in GitHub Actions"
      end
      nil
    end

    def with_identity
      doctor
      return yield(nil) unless enabled?
      Dir.mktmpdir("native-packages-windows-signing-") do |directory|
        directory = Pathname.new(directory)
        @signtool = tool("signtool", directory)
        @dlib = tool("dlib", directory)
        @metadata = directory / "metadata.json"
        write(@metadata, JSON.pretty_generate("Endpoint" => @values.fetch("AZURE_SIGNING_ENDPOINT"),
          "CodeSigningAccountName" => @values.fetch("AZURE_SIGNING_ACCOUNT"),
          "CertificateProfileName" => @values.fetch("AZURE_SIGNING_PROFILE"),
          "ExcludeCredentials" => EXCLUDED_CREDENTIALS) + "\n")
        yield self
      ensure
        @signtool = @dlib = @metadata = nil
      end
    end

    # A package recipe gets a signed copy of its input. Code that already
    # carries a valid signature, ours from sign-windows or a vendor's, stays.
    def sign_payload(payload)
      binaries = NativeRecipe.new(root).tree(payload).filter_map do |relative, kind, *|
        path = payload / relative
        path if kind == "file" && portable_executable?(path)
      end
      unsigned = signatures(binaries).reject { |record| record.fetch("status") == "Valid" }.map { |record| Pathname.new(record.fetch("path")) }
      sign(unsigned) unless unsigned.empty?
      puts "Signed #{unsigned.length} of #{binaries.length} Windows binaries in the package input."
      unsigned.length
    end

    def sign_package(package)
      record = sign([package]).first
      { "signature" => "authenticode", "provider" => PROVIDER, "publisher" => record.fetch("publisher"),
        "timestamped" => true }
    end

    # Signs files in place, in as few SignTool calls as fit a command line,
    # then checks every signature.
    def sign(paths)
      paths = paths.map { |path| Pathname.new(path).expand_path(root) }
      paths.each { |path| raise Error, "not a regular file: #{path}" unless path.file? && !path.symlink? }
      batches = paths.each_with_object([[]]) do |path, groups|
        length = groups.last.sum { |item| item.to_s.length + 3 } + path.to_s.length + 3
        groups << [] if !groups.last.empty? && length > BATCH_CHARACTERS
        groups.last << path
      end
      batches.each do |batch|
        arguments = [@signtool, "sign", "/v", "/fd", "SHA256", "/tr", TIMESTAMP, "/td", "SHA256",
          "/dlib", @dlib, "/dmdf", @metadata, "/d", @description]
        arguments += ["/du", @description_url] if @description_url
        output = signtool(*arguments, *batch)
        puts output unless output.empty?
      end
      verify(paths)
    end

    def verify(paths)
      signatures(paths).map do |record|
        path = record.fetch("path")
        unless record.fetch("status") == "Valid" && record.fetch("timestamped")
          raise Error, "#{path} is not validly signed and timestamped: #{record.fetch('status')} #{record.fetch('message')}".strip
        end
        if settings["publisher"] && record.fetch("publisher") != settings["publisher"]
          raise Error, "#{path} is signed by #{record.fetch('publisher').inspect}, not windows.signing.publisher #{settings['publisher'].inspect}"
        end
        puts "#{File.basename(path)}: signed by #{record.fetch('subject')}, timestamped"
        record
      end
    end

    def signatures(paths)
      return [] if paths.empty?
      records = Dir.mktmpdir("native-packages-signatures-") do |directory|
        list = Pathname.new(directory) / "files.txt"
        write(list, paths.map { |path| Pathname.new(path).expand_path(root).to_s }.join("\n") + "\n")
        JSON.parse(powershell(SIGNATURES, "NATIVE_PACKAGES_SIGNATURE_LIST" => list.to_s).strip.unpack1("m0").force_encoding(Encoding::UTF_8))
      end
      raise Error, "unexpected signature report" unless records.is_a?(Array) && records.length == paths.length
      records
    rescue ArgumentError, JSON::ParserError
      raise Error, "could not read Authenticode signatures"
    end

    # `native-packages sign-windows FILE...`: explicit, so it never skips.
    def sign_files(paths)
      raise Error, "add windows.signing to the configuration to sign Windows files" unless configured?
      raise Error, "set #{VARIABLES.join(', ')} to sign Windows files" unless enabled?
      raise Error, "sign-windows needs at least one file" if paths.empty?
      with_identity { |signing| signing.sign(paths) }
    end

    def portable_executable?(path)
      File.open(path, "rb") do |file|
        next false unless file.size >= 64 && file.read(2) == "MZ"
        file.seek(0x3c)
        offset = file.read(4).unpack1("L<")
        next false unless offset >= 64 && offset + 4 <= file.size
        file.seek(offset)
        file.read(4) == "PE\0\0"
      end
    end

    # SignTool and the Artifact Signing client from nuget.org, hash-checked on
    # every use, or local copies named by the override variables.
    def tool(name, directory)
      tool = TOOLS.fetch(name)
      override = @environment[tool.fetch("override")].to_s
      return Pathname.new(override).expand_path unless override.empty?
      package, version = tool.values_at("package", "version")
      archive = cache_directory / "#{package}.#{version}.nupkg"
      download("https://api.nuget.org/v3-flatcontainer/#{package}/#{version}/#{package}.#{version}.nupkg", archive)
      unless sha256(archive) == tool.fetch("sha256")
        archive.delete
        raise Error, "#{package} #{version} from nuget.org does not match its pinned SHA-256"
      end
      destination = directory / name
      destination.mkpath
      powershell(EXTRACT, "NATIVE_PACKAGES_ARCHIVE" => archive.to_s, "NATIVE_PACKAGES_PREFIX" => tool.fetch("directory"),
        "NATIVE_PACKAGES_DESTINATION" => destination.to_s)
      path = destination / tool.fetch("directory") / tool.fetch("file")
      raise Error, "#{package} #{version} has no #{tool.fetch('file')}" unless path.file?
      path
    end

    def cache_directory
      base = @environment["LOCALAPPDATA"].to_s.empty? ? File.join(Dir.home, ".cache") : @environment["LOCALAPPDATA"]
      Pathname.new(base) / "native-packages/windows-signing"
    end

    # SignTool and the Artifact Signing client report failures on standard
    # output, so a failure shows both streams.
    def signtool(*arguments)
      output, status = Open3.capture2e(*arguments.map(&:to_s), chdir: root.to_s, binmode: true)
      raise Error, "SignTool failed:\n#{output.strip}" unless status.success?
      output.strip
    end

    # Windows PowerShell started from PowerShell 7 inherits a module path
    # where its own Microsoft.PowerShell.Security cannot load; without one, it
    # uses its default.
    def powershell(script, env)
      encoded = [script.encode(Encoding::UTF_16LE)].pack("m0")
      execute("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded,
        env: env.merge("PSModulePath" => nil))
    end

    def execute(*arguments, env: {})
      capture(*arguments, env: env)
    end
  end
end
