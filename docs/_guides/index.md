---
title: Guides
description: Step-by-step guides to building native packages, adding platforms, and publishing your application.
permalink: /guides/
nav_order: 0
---

# Guides

## Learn by building

These guides take you from a compiled application to a published package.
They use one small example throughout, explain each configuration as it is
introduced, and show what to expect after running a command.

### Start here

1. [Getting started](getting-started.md) — install the tools and build your first DEB and RPM.
2. [Building packages](building-packages.md) — choose files, declare dependencies, and add targets.
3. [Publishing a release](publishing.md) — use release assets and upload the finished packages.
4. [GitHub Actions](github-actions.md) — automate packaging after your application builds.

### Add platforms and distribution channels

- [macOS and Windows installers](native-recipes.md) — use your app's packaging scripts.
- [Apple signing and notarization](apple-notarization.md) — sign and notarize DMGs and portable downloads.
- [Distribution recipes](distribution-recipes.md) — update AUR, Homebrew, and other repositories.
- [Building across platforms](multi-platform.md) — combine builds from several machines.
- [Prereleases](prereleases.md) — package alpha, beta, and release candidate versions.

### Look something up

- [Configuration](../_reference/configuration.md) — fields, file paths, hooks, and replacement values.
- [Commands](../_reference/commands.md) — CLI options and examples.
- [Supported platforms](../_reference/platforms.md) — formats and what you need for each one.
- [Troubleshooting](../_reference/troubleshooting.md) — common errors and how to fix them.
- [Migrating from v0.1](../_reference/migration.md) — move an existing project to one configuration file.

These guides describe native-packages **0.6.0**.
