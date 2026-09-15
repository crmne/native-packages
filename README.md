<p align="center">
  <img src="docs/assets/images/logo.svg" alt="native-packages logo" width="128" height="128">
</p>

# native-packages

Turn your built application into packages people can install.

Describe your app's files and supported platforms in one YAML file. Then build
Linux packages, macOS disk images, or Windows installers, upload them to a
GitHub release, and update distribution recipes such as AUR packages and
Homebrew casks.

You bring the compiled app. native-packages handles packaging and release updates.

[Documentation](https://native-packages.dev/)

## Get started

Install with Ruby 3.2 or later:

```sh
gem install native-packages
```

From your application directory, create a configuration:

```sh
native-packages init --interactive
```

The setup creates `native-packages.yaml` with a Linux x86-64 starting point.
Review the app's metadata, the path to your compiled files, and the package
formats you want. The [getting started guide](docs/_guides/getting-started.md)
walks through a complete example and the required packaging tools.

Check your setup and build:

```sh
native-packages doctor
native-packages build --version 1.2.3
```

Your packages are in `dist/packages/1.2.3/`, together with checksums and a build
record. Local builds work without a GitHub release or credentials.

## What can I build?

| Platform | Outputs |
| --- | --- |
| Linux | DEB, RPM, Arch Linux packages, Alpine APK, IPK, and source RPM |
| macOS | DMG, using your packaging script; optional Apple signing and notarization |
| Windows | MSIX, or Inno Setup installers using your packaging script |

Each target needs files built for that platform. DMG and Inno builds run on
macOS and Windows respectively. See [supported platforms](docs/_reference/platforms.md)
for prerequisites and distribution recipes.

## Guides

Start with [getting started](docs/_guides/getting-started.md).

- [Building packages](docs/_guides/building-packages.md) — add files, dependencies, and more targets.
- [Publishing a release](docs/_guides/publishing.md) — build from release assets and upload packages.
- [GitHub Actions](docs/_guides/github-actions.md) — add packaging to your release workflow.
- [macOS and Windows installers](docs/_guides/native-recipes.md) — connect your native packaging scripts.
- [Apple signing and notarization](docs/_guides/apple-notarization.md) — prepare macOS downloads for distribution.
- [AUR, Homebrew, and other repositories](docs/_guides/distribution-recipes.md) — generate and publish recipes.

For a particular option or error, see the [configuration reference](docs/_reference/configuration.md),
[command reference](docs/_reference/commands.md), and [troubleshooting guide](docs/_reference/troubleshooting.md).

## Contributing

See [Contributing](CONTRIBUTING.md) for development, tests, and running the
documentation site locally. Upgrading an older setup? Read
[Migrating from v0.1](docs/_reference/migration.md).

## License

[MIT](LICENSE)
