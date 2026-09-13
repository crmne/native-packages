# Releasing the native-packages gem

The gem has no runtime gem dependencies. RubyGems publication is separate from the application-package publishing commands.

## One-time account setup

Under the owner's RubyGems account, create a [pending trusted publisher](https://rubygems.org/profile/oidc/pending_trusted_publishers) with:

| Field | Value |
| --- | --- |
| Gem name | `native-packages` |
| Repository owner | `crmne` |
| Repository | `native-packages` |
| Workflow filename | `release.yml` |
| Environment | `rubygems` |

No application repository or API token is needed. The first successful publication establishes gem ownership. See [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/).

## Release procedure

Update the gemspec, `NativePackages::VERSION`, example/version references and changelog, then update the development lockfile. Run the tests and isolated gem-install check. Commit and push, then create and push an annotated `vMAJOR.MINOR.PATCH` tag.

The release workflow runs the test workflow, including native package acceptance. It downloads the tested gem from the Ruby 4.0 job, checks its version against the tag, exchanges GitHub's OIDC identity for RubyGems publishing credentials, and publishes that artifact. It then attaches the gem to a GitHub release.

Do not move existing tags or republish an existing gem version. If the one-time trusted publisher has not been configured, leave publication pending and retain the tested gem artifact. After configuring it, the workflow can be dispatched on the existing release tag:

```sh
gh workflow run release.yml --ref v0.2.0
```

If RubyGems publication succeeded but a later GitHub step failed, attach the already-published gem to the existing tag manually; do not run `gem push` again for that version.
