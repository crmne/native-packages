---
title: Getting started
description: Install native-packages and build a DEB and RPM from a compiled Linux application.
nav_order: 1
---

# Getting started

By the end of this guide, you will have a DEB and an RPM containing your app,
ready to test on Linux.

We will package an application called `hello`. You can follow along with your
own compiled executable, or build the tiny example below.

## 1. Install the tools

You need Ruby 3.2 or later. Install the version used by these guides:

```sh
gem install native-packages --version 0.6.0
```

For Linux packages, install **nFPM 2.47.0**, the helper native-packages uses to
write package files. Download the matching build from the
[nFPM release](https://github.com/goreleaser/nfpm/releases/tag/v2.47.0)
and put `nfpm` on your `PATH`. If you already use Go, you can install it with:

```sh
go install github.com/goreleaser/nfpm/v2/cmd/nfpm@v2.47.0
export PATH="$(go env GOPATH)/bin:$PATH"
```

You also need `readelf` to inspect Linux binaries and `bsdtar` to unpack
archives. On Debian or Ubuntu:

```sh
sudo apt-get install binutils libarchive-tools
```

Other distributions provide these through their binutils and libarchive
packages. The [reusable GitHub Actions workflow](github-actions.md) installs
the packaging tools for you.

## 2. Prepare your application

Start in your application's root directory. This example expects a Linux
x86-64 executable at `dist/hello`, built against glibc.

If you have a C compiler on an x86-64 Linux system using glibc, you can create
a sample in a new directory:

```sh
mkdir hello-packaging
cd hello-packaging
mkdir dist
cat > hello.c <<'C'
#include <stdio.h>
int main(void) {
  puts("Hello from a native package!");
  return 0;
}
C
cc -o dist/hello hello.c
```

For your own app, run its usual build command instead and note where it puts
the executable. Packaging starts from those built files.

## 3. Create a configuration

Generate a starting point:

```sh
native-packages init --name hello --formats deb,rpm
```

Open the generated `native-packages.yaml` and replace its contents with:

```yaml
schema: 1
tool:
  version: '0.6.0'
  nfpm: '2.47.0'

nfpm:
  name: hello
  description: A small greeting application
  maintainer: Your Name <you@example.com>
  license: MIT
  contents:
    - src: '@PAYLOAD@/hello'
      dst: /usr/bin/hello
      file_info:
        mode: 0755

targets:
  linux-amd64:
    platform: linux
    arch: amd64
    libc: glibc
    formats: [deb, rpm]
    input:
      kind: file
      local: dist/hello
```

Use your own maintainer details and your app's actual license. There are three
parts to understand:

- **`tool`** selects the tool versions, so everyone builds with the same setup.
- **`nfpm`** describes the package: its name, metadata, and installed files.
  `src` is the file to include; `dst` is where it will be installed.
- **`targets`** describes the build inputs and output formats. `amd64` means
  x86-64, and `glibc` is the C library used by this example's executable.

`@PAYLOAD@` is a temporary copy of your input. Here, it contains `hello`.
The destination `/usr/bin/hello` is inside the package; building does not
install it on your machine.

The default generated configuration expects an archive. We set `kind: file`
because this example supplies one executable. For ARM64, use `arch: arm64`
and an ARM64 build of your app. See [input types and targets](building-packages.md).

## 4. Check and build

Check the configuration and tools:

```sh
native-packages doctor
```

If anything is missing, the command reports what to fix. Once it succeeds,
build version 1.2.3:

```sh
native-packages build --version 1.2.3
```

The command checks your executable's architecture and linked libraries, then
creates both packages. You should see:

```text
dist/packages/1.2.3/
  packages/
    linux-amd64/
      deb/                 # your .deb file
      rpm/                 # your .rpm file
  recipes/
    release.json
  build.json
  packaging-checksums.txt
```

`build.json` records the inputs, outputs, and checks performed.
`packaging-checksums.txt` lists file hashes so changes can be detected.
Keep the whole directory if you plan to publish the build later.

To try again after changing your app or configuration, choose a new output
directory:

```sh
native-packages build --version 1.2.3 --output dist/second-build
```

## 5. Test the package

On a disposable Debian or Ubuntu machine, copy the DEB there and install it:

```sh
sudo apt install ./hello_1.2.3_amd64.deb
hello
sudo apt remove hello
```

Use the filename produced by your build. For the sample, `hello` prints
`Hello from a native package!`. For your own app, also test startup, upgrades,
and removal on each distribution you support. A successful package build
checks the files; installation testing checks how the app behaves.

## Where to go next

Continue with [Building packages](building-packages.md) to add icons,
configuration files, dependencies, and more architectures. When your package
is ready, follow [Publishing a release](publishing.md).
