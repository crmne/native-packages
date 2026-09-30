---
layout: home
title: native-packages
description: Turn your built application into Linux packages, macOS disk images, and Windows installers. Publish releases from one configuration.
permalink: /
hero:
  name: native-packages
  text: Turn your app into installable packages
  tagline: One configuration. Linux, macOS, and Windows. Build packages and publish them with every release.
  actions:
    - theme: brand
      text: Get started
      link: /getting-started/
    - theme: alt
      text: GitHub
      link: https://github.com/crmne/native-packages
  image:
    src: /assets/images/logo.svg
    alt: native-packages logo
    width: 320
    height: 320
features:
  - icon: 📦
    title: One configuration
    details: Describe your app's files, package metadata, and build targets in a single YAML file.
  - icon: 🐧
    title: Linux packages
    details: Create DEB, RPM, AppImage, Arch, Alpine, and IPK packages from your compatible Linux builds.
  - icon: 🖥️
    title: Native installers
    details: Connect your macOS DMG and Windows Inno Setup scripts, or package Windows apps as MSIX.
  - icon: 🚀
    title: Release automation
    details: Build from local files or release assets. Add packaging to GitHub Actions and upload the finished packages.
  - icon: 🍺
    title: AUR and Homebrew
    details: Fill in versions, download URLs, and checksums in your recipes, then review and publish the updates.
  - icon: 🔎
    title: Verified builds
    details: Check binary architecture and library requirements. Record file hashes and verify them before publishing.
---

<video class="hero-film" controls muted loop playsinline preload="metadata" poster="{{ '/assets/images/launch-film-poster.jpg' | relative_url }}" aria-label="native-packages in under a minute: seventeen packaging files become one configuration" hidden>
  <source src="{{ '/assets/videos/launch-film.mp4' | relative_url }}" type="video/mp4">
</video>

<style>
  /* The theme sizes its hero for a square logo; the film is 16:9. */
  .VPHero .hero-film {
    display: block;
    width: 100%;
    max-width: 560px;
    height: auto;
    aspect-ratio: 16 / 9;
    margin: 0 auto;
    border-radius: 12px;
    background: #0d0e1a;
  }
  .VPHero .image-container:has(.hero-film) {
    width: 100%;
    height: auto;
    padding: 0 24px;
    transform: none;
  }
  @media (max-width: 959px) {
    .VPHero .image:has(.hero-film) {
      margin: 0 0 32px;
    }
  }
</style>

<script>
  // The theme's hero takes a picture; the film takes its place where
  // scripts run, and the logo stays where they do not.
  (function () {
    var film = document.querySelector(".hero-film");
    var slot = document.querySelector(".VPHero .image-container");
    if (!film || !slot) return;
    slot.replaceChildren(film);
    film.hidden = false;
    if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      film.play().catch(function () {});
    }
  })();
</script>
