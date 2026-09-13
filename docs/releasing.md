# Releasing the native-packages gem

This repository follows RubyLLM's publishing convention: publishing a GitHub release starts gem publication. Branch and tag pushes run checks without publishing a gem.

## Authentication

Configure the repository secret `RUBYGEMS_AUTH_TOKEN`, using an existing RubyGems token with permission to push `native-packages`. GitHub passes it to RubyGems through `GEM_HOST_API_KEY`. GitHub Packages uses the workflow's built-in GitHub token.

Repository secrets are scoped to their repository. RubyLLM's existing secret does not automatically become available here, and GitHub cannot reveal its value for copying. Use the original token from your credential store or a new appropriately scoped token. A pending trusted publisher is not required for this method.

The secret can be set interactively without putting it in a shell command or chat:

```sh
gh secret set RUBYGEMS_AUTH_TOKEN --repo crmne/native-packages
```

[RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) is an alternative if the project adopts OIDC later; it is not the current release workflow.

## Release procedure

Update the gemspec, `NativePackages::VERSION`, example/version references and changelog, then update the development lockfile. Run tests and the isolated gem-install check. Commit and push the reviewed change to `main` and prepare release notes in a file.

Create a GitHub release for that commit:

```sh
gh release create v0.4.0 --target main --title 'native-packages 0.4.0' --notes-file release-notes.md
```

Adding `--draft` permits review before publication and does not trigger the publisher. The tag must match the exact gem version and point to a commit on `main`. Set `--prerelease` only for a prerelease gem version.

The release workflow verifies the tag, tested commit and prerelease setting, then runs the test workflow, including native package acceptance. It downloads the tested gem from the Ruby 4.0 job, publishes it to RubyGems and GitHub Packages, and attaches it to the GitHub release. It does not rebuild a different artifact after the tests.

If authentication is missing, leave the tested gem and release draft available until the secret is configured. Failed release jobs can be rerun after configuration; already-published gem versions are not overwritten. Never move an existing release tag to retry publication.
