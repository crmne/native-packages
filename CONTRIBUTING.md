# Contributing

## Run the tests

Install Ruby 3.2 or later and the development dependencies:

```sh
bundle install
bundle exec ruby -Ilib -e 'Dir["test/*_test.rb"].sort.each { |path| require_relative path }'
```

Package integration checks use nFPM 2.47.0, a C compiler, `readelf`, and `bsdtar`.
Tests use temporary directories and local Git repositories. CI also runs
disposable Linux, macOS, and Windows installation checks. Fixture coverage
does not replace testing packages for each application.

To check the packaged gem and standalone command:

```sh
gem build native-packages.gemspec
ruby test/gem_install.rb native-packages-0.6.0.gem
```

See [Releasing the gem](docs/releasing.md) for publication and
[CLI design](docs/cli-design.md) for the original design notes. Historical
acceptance records are under [docs/acceptance](docs/acceptance).

## Work on the documentation

The site uses [Jekyll VitePress](https://jekyll-vitepress.dev). Its dependencies
are separate from the CLI's development bundle:

```sh
cd docs
bundle install
bundle exec jekyll serve --livereload
```

Open <http://localhost:4000/>. To build and check internal links:

```sh
bundle exec jekyll build --strict_front_matter --trace
python3 scripts/check_links.py _site
```

The generated site is in `docs/_site/` and is ignored by Git and excluded from
the gem. The source uses the published theme gem; there is no machine-specific
path dependency. To test changes from a local theme checkout, use Bundler's
temporary path configuration or a separate Gemfile, and keep that local setup
out of the committed lockfile.

### Writing a guide

Put tutorials in `docs/_guides/` and reference pages in `docs/_reference/`.
Add `title`, `description`, and `nav_order` to the YAML front matter. The sidebar
and previous/next links follow that order. New pages appear in the sidebar
automatically.

Start with what the reader will accomplish and what they need. Use a complete
example, explain unfamiliar terms when they first appear, and show the expected
result after commands. Keep release history and internal implementation notes
in the changelog or contributor documentation.

Use relative Markdown links such as `[Building packages](building-packages.md)`.
The [relative-links plugin](https://github.com/benbalter/jekyll-relative-links)
converts them for the site, while the source remains readable on GitHub.
Liquid rendering is disabled for page content so GitHub Actions expressions
such as `${{ github.ref_name }}` remain literal in examples.

### Deployment

The documentation workflow builds the site and checks links on relevant pull
requests and pushes. Pushes to `main` also deploy the checked artifact through
GitHub Pages. To enable the first deployment, select **GitHub Actions** under
the repository's **Settings → Pages → Build and deployment → Source**.
See [GitHub's custom workflow setup](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

The site is published at `https://native-packages.dev/`. GitHub Pages uses
`native-packages.dev` as the custom domain, with HTTPS enforced. The Jekyll
configuration uses that URL and an empty `baseurl` so pages and assets are
served from the domain root.

If hosting at a different location, update the Pages custom domain and `url`
in `docs/_config.yml`. For hosting under a path, also update `baseurl` and the
link-check command in the workflow. You can preview another base path with
`bundle exec jekyll build --baseurl /your-path`.
