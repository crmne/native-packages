---
title: Migrating from v0.1
description: Convert legacy packaging files into native-packages.yaml while preserving your existing recipes.
nav_order: 5
---

# Migrating from v0.1

Older projects keep separate `packaging/project.yml`, package metadata, and
repository registry files. The current CLI can combine those settings into
one `native-packages.yaml`.

## Preview the conversion

From your application root, with the new gem installed:

```sh
native-packages migrate --dry-run
```

Review the generated YAML. The migrator combines the legacy project settings,
its package definition, and downstream repositories. Existing Linux binary
targets keep their DEB/RPM formats, and templates remain in place.

## Write the configuration

```sh
native-packages migrate
native-packages validate
native-packages doctor
```

Migration creates a new configuration and preserves the existing files. It
refuses to overwrite an existing `native-packages.yaml` or `.yml`.

Review local input paths: the migrator derives them from the legacy release
assets, and your local build may use a different layout. Check maintainer
metadata, dependencies, and each target's C library declaration.

## Compare a build

Build a known app version into a new directory, using its local inputs or
published release assets:

```sh
native-packages build --release v1.2.3 --output dist/migration-check
```

Compare package contents and generated recipes with the previous workflow.
Update your CI to call the matching released workflow and the new `build` /
`publish --from` commands.

Only remove packaging-only Gemfiles or wrappers after the replacement has
been tested. You may keep using Bundler if that suits your project.

## Custom generators

The migrator reports unsupported fields instead of guessing how to convert
them. App-specific Ruby generators, such as custom Nix hashes or source-package
logic, need a manual adapter. Keep that logic in your application and connect
its output through the current asset, template, or build-hook settings.

Legacy configurations and commands remain available. Read the
[original v0.1 guide](https://github.com/crmne/native-packages/blob/main/docs/legacy.md)
when maintaining a project pinned to that release.
