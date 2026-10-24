# php-focal-backports

Security-patched PHP packages for **Ubuntu 20.04 (focal)**, which no supplier builds any more:
every PHP branch that Ondřej Surý's PPA fixed for PHP2Shell, which is **7.4, 8.0, 8.1, 8.2, 8.3 and
8.4**. Also PHP 8.1 for **Ubuntu 26.04 (resolute)**. Built and tested on arm64 (AWS Graviton) and
amd64. PHP 8.5 is built for focal as a trial only, and never released.

## Why it exists

On 2026-10-21 PHP released fixes for **CVE-2026-109618 and CVE-2026-109619** ("PHP2Shell") in
8.5.12, 8.4.27, 8.3.36 and 8.2.35. PHP 7.4, 8.0 and 8.1 are past their upstream end of life.
`ppa:ondrej/php` shipped fixed uploads of every branch, each carrying the fix. For 7.4, 8.0 and
8.1 the fix is the maintainer's backported patch, "Avoid state corruption via bailout". That
covers some systems only:

- **Ubuntu 20.04 got nothing from the PPA.**
  - The PPA stopped building focal in 2025, and deleted its last focal build of every branch on
    2025-06-09. Those were 7.4.33-20, 8.0.30-13, 8.1.32-1, 8.2.28-1, 8.3.21-1 and 8.4.7-1.
  - packages.sury.org has no focal suite.
  - So a 20.04 host running the PPA's PHP had nothing to install.
  - Ubuntu's own focal php7.4 (7.4.3) is a different package line. Ubuntu fixed it through Ubuntu
    Pro (USN-8948-2); this project is not for it.
- **Ubuntu 26.04 on arm64 lagged.** On 2026-10-22, packages.sury.org's resolute arm64 index still
  served the pre-fix 8.1.34-8, while amd64 already had 8.1.34-9. By 2026-10-24 both architectures
  served 8.1.34-9, so that gap has closed. The resolute target stays: its build is the same signed
  source, with the DNS telemetry compiled out (see [No phone-home](#no-phone-home)).

This project rebuilds the PPA's own **signed** source packages, **unchanged**, for each target. The
fix comes from upstream and the PPA's maintainer, not from us. What this adds is a way to rebuild
that source safely for a series nobody builds any more:
- it verifies the signature;
- it rebuilds against the same libraries the PPA used;
- it tests the result, including mod_php, and can check API parity with a running host;
- it installs with guards that refuse a partial or surprising upgrade.

The PPA publishes one Debian source per series with a "No-change backport" changelog entry. We take
the jammy upload, since the PPA has no focal or resolute, and add a "Rebuild of ... for Ubuntu
<version>" entry.

## Branches and targets

Two variables select a build:
- `PHP_BRANCH` selects one of `branches/*.env`, which pin the branch's fixed upload and its fix
  floor. It defaults to `8.1`.
- `TARGET` selects one of `targets/*.env`, which set the series, the libraries to rebuild first and
  the packages `scripts/test.sh` installs. It defaults to `focal`.

| `PHP_BRANCH` | Fixed upload (jammy, `+ubuntu22.04.1+deb.sury.org+1`) | The fix | Targets |
|---|---|---|---|
| 7.4 | 1:7.4.33-31 | `0164-Avoid-state-corruption-via-bailout.patch` | focal |
| 8.0 | 1:8.0.30-25 | `0137-Avoid-state-corruption-via-bailout.patch` | focal |
| 8.1 | 8.1.34-9 | `0083-Avoid-state-corruption-via-bailout.patch` | focal, resolute |
| 8.2 | 8.2.35-1 | upstream 8.2.35 | focal |
| 8.3 | 8.3.36-1 | upstream 8.3.36 | focal |
| 8.4 | 8.4.27-1 | upstream 8.4.27 | focal |
| 8.5 | 8.5.12-1 | upstream 8.5.12 | focal, **trial only** |

The fix floor is the fixed upload's Debian version (`1:7.4.33-31`, `8.1.34-9`, `8.2.35-1`, ...).
`scripts/test.sh` fails a build below it, and `host/install.sh` refuses one. Every branch's
changelog records the fix under the CVE ids. For 8.2 and later, the test also checks that
`PHP_VERSION` reaches the upstream release.

| `TARGET` | Series | For | Tested package set |
|---|---|---|---|
| `focal` (default) | Ubuntu 20.04 | hosts that ran the PPA's PHP before it dropped focal | a typical Laravel web node's packages, and mod_php |
| `resolute` | Ubuntu 26.04 | images that install PHP 8.1 from packages.sury.org | the same set, with their dependencies |

The resolute target builds 8.1 only: packages.sury.org builds every branch for resolute itself.

## What it builds

`config.env` and the two files it sources pin everything. Each build rebuilds two sources:

| Source | Version taken from the PPA (jammy) | Built as (focal / resolute) | Why |
|---|---|---|---|
| php&lt;branch&gt; | see the table above | e.g. 8.1.34-9+ubuntu20.04.1~&lt;LOCAL_TAG&gt; / 8.1.34-9+ubuntu26.04.1~&lt;LOCAL_TAG&gt; | carries the PHP2Shell fix |
| php-defaults | 101~+ubuntu22.04.1+deb.sury.org+1 | 2:101~+ubuntu20.04.1~&lt;LOCAL_TAG&gt; / 2:101~+ubuntu26.04.1~&lt;LOCAL_TAG&gt; | provides `php-common`, which every branch needs at a version focal and resolute do not have |

php-defaults is needed on both targets:
- `php7.4-common` to `php8.3-common` need `php-common` >= 1:81~, and 8.4 and 8.5 need >= 2:95~.
  Focal's own is 1:75.
- Resolute's own, 2:99ubuntu1, is new enough but declares `Breaks: php8.1-common`, so the two cannot
  be installed together.

Building ours first also puts sury's `/usr/lib/php/php-common.mk` in place, which every branch's
`debian/rules` includes, so both targets' binaries are built the same way. That file is also what
switches on the version-check telemetry; see [No phone-home](#no-phone-home).

The version is always `<revision>+ubuntu<version>.1~<LOCAL_TAG>`, with no `~` straight after the
Debian revision, so it compares >= the revision it rebuilds and a fix-floor check passes. An epoch
(`1:` for 7.4 and 8.0) is kept. Bump `LOCAL_TAG` for every new build; the release workflow uses
`clarity2`.

- **focal:** it sorts above the PPA's last focal build of each branch, such as
  8.3.21-1+ubuntu20.04.1+deb.sury.org+1. It sorts **below** an official PPA build of the same
  revision, so if the PPA ever publishes one for focal again, apt prefers it.
- **resolute:** it sorts above sury's 8.1.34-8+0~20260703.81+ubuntu26.04~1.gbp86d822. packages.sury.org
  uses a different format, so it also sorts **above** sury's own 8.1.34-9
  (8.1.34-9+0~20261021.82+ubuntu26.04~1.gbp4e430a). At equal pin priority, apt keeps ours until sury
  publishes a later revision.

### Focal: the PPA's own libraries

The PPA did not build its focal PHP against plain focal. The build logs of its last focal uploads
of each branch are on Launchpad (arm64; each `branches/<branch>.env` links its own). They show the
PPA's own builds of eight libraries in the build environment, and some of them are compiled into
PHP. So the focal target rebuilds those libraries first, from the PPA's focal uploads. The uploads
are deleted from the PPA, but their files are still on Launchpad, and their `.dsc`s verify against
the same upload key. PHP then compiles against them (`LIB_SOURCES` in `targets/focal.env`):

| Library | Version | What building against focal's own would change |
|---|---|---|
| libzip | 1.7.3 | focal ships libzip5 1.5.1 (`libzip.so.5`), while PPA hosts have the PPA's libzip4 1.7.3. `php<branch>-zip` would need a library apt will not add, and `ZipArchive` would lose methods |
| libgd2 | 2.3.3-12 or 2.3.3-13, per branch (below) | focal's 2.2.5 has no AVIF functions; the PPA's GD exposes them |
| pcre2 | 10.42-3 | PHP sets `PCRE2_EXTRA_ALLOW_LOOKAROUND_BSK` only when compiled against >= 10.38. Without it, a host's pcre2 10.39 or 10.40 rejects `\K` inside a lookaround |
| libxml2 | 2.9.14 | `LIBXML_VERSION` is compiled in |
| argon2 | 0~20190702 | the version `password_hash()` was built with |
| libzstd | 1.4.8 | not PHP's own dependencies, but the PPA's builds replaced focal's in its build chroot: libzstd1, libidn2-0 and libpcre3 at the chroot's upgrade, and libpcre3-dev with the build dependencies. They are built first, so the libraries after them build against them |
| libidn2 | 2.3.0 | (as above) |
| pcre3 | 8.45 | (as above) |

libgd differs by branch, following each branch's last focal build:

| Branch | Last focal build (Launchpad log) | libgd2 |
|---|---|---|
| 7.4 | 1:7.4.33-20 ([30700598](https://launchpad.net/~ondrej/+archive/ubuntu/php/+build/30700598)) | 2.3.3-13 |
| 8.0 | 1:8.0.30-13 ([30419480](https://launchpad.net/~ondrej/+archive/ubuntu/php/+build/30419480)) | 2.3.3-12 |
| 8.1 | 8.1.32-1 ([30419448](https://launchpad.net/~ondrej/+archive/ubuntu/php/+build/30419448)) | 2.3.3-12 |
| 8.2 | 8.2.28-1 ([30419423](https://launchpad.net/~ondrej/+archive/ubuntu/php/+build/30419423)) | 2.3.3-12 |
| 8.3 | 8.3.21-1 ([30700581](https://launchpad.net/~ondrej/+archive/ubuntu/php/+build/30700581)) | 2.3.3-13 |
| 8.4 | 8.4.7-1 ([30700612](https://launchpad.net/~ondrej/+archive/ubuntu/php/+build/30700612)) | 2.3.3-13 |
| 8.5 (trial) | never built for focal | 2.3.3-13, the newest the PPA built for focal |

The focal 2.3.3-13 upload's files are gone from Launchpad. It was a no-change backport of the same
Debian source as the jammy 2.3.3-13 upload, which is still published and verifies, so the jammy
upload stands in for it (`@jammy` in `FOCAL_LIBGD`). 2.3.3-13 dropped libraqm. Our builds' `libgd3`
links libraqm0 with -12 and not with -13, and neither links libheif or libavif, which matches the
packages in the PPA's build logs.

The libraries are built arch-only, as Launchpad's arm64 builders built them. libidn2's
`Build-Depends-Indep` alone would pull in texlive. The build log prints each runtime library's
`Depends`, for comparison with the PPA's.

Earlier releases (`clarity1`, 8.1 only) were built against five of these libraries, with libgd
2.3.3-9, which matched the 8.1.28 and 8.1.29 logs rather than the final 8.1.32 build. The current
set changes 8.1's binaries, hence the new `LOCAL_TAG`.

We learned why the libraries matter the hard way. A first build against focal's own libraries
passed every functional test. It was refused only by the install dry run on a canary host:
`php8.1-zip : Depends: libzip5`. It had also silently dropped GD's AVIF functions and pcre2's
`\K`-in-lookaround option.

The libraries go into the bundle so `scripts/test.sh` can install them on a clean focal. On hosts,
`host/install.sh` upgrades PHP packages only. Each host keeps its own libraries, which are the same
versions or newer, and ours sort below the PPA's, so apt never prefers them.

### mod_php and Apache

`libapache2-mod-php<branch>` is built against **focal's own apache2-dev 2.4.41**, not the PPA's.
The PPA's focal builds used apache2 2.4.63, apr 1.7.2, apr-util 1.6.3 and brotli 1.1.0 from
`ppa:ondrej/apache2`, whose focal files are all gone, so they cannot be rebuilt. The module is
built for Apache 2.4's module API, `apache2-api-20120211`, which focal's 2.4.41 and the PPA's 2.4.63
both provide. CI tests it with focal's 2.4.41 only: Apache loads the module and serves a PHP page
through it. If your hosts run the PPA's Apache, simulate the install on one first.

### API parity

A build that passes on a clean focal proves little by itself. `scripts/parity_dump.php` lists every
function, class, method and constant of PHP's own extensions, plus the compiled-in library versions.
`scripts/test.sh` diffs that against `targets/<target>-php<branch>.parity`, and any difference
fails the build.

**No baseline ships with this repository:** it has to come from your own hosts. Dump one on a host
running the PHP you are replacing:

```bash
php8.1 scripts/parity_dump.php > targets/focal-php8.1.parity
```

Without a baseline, the check is skipped. Hosts with different libraries differ in a handful of
constants. For example, libcurl 7.81 adds 7 `CURLOPT_*` constants, and OpenSSL 3 drops
`OPENSSL_SSLV23_PADDING`. So take the baseline from a host on the same series.

### No phone-home

Since sury's packaging patch "Add minimal privacy preserving secure DNS telemetry" (0048 in php8.1,
2026-02-11; every branch carries it), php-fpm and mod_php send a DNS "version check" at startup. It
is an encrypted UDP/53 query carrying the package name and version, sent to `telemetry.sury.org`.
`debian/rules` says it is "not enabled in build by default"; it is turned on only by
`/usr/lib/php/php-common.mk` from the `php-common` package.

With `SURY_TELEMETRY=off`, the default, `build.sh` empties that file in the build container before
building PHP, which compiles the call out. No source is changed. `test.sh` fails the build if
`php-fpm<branch>` or the mod_php module still contains the host name.

Hosts that run the PPA's or packages.sury.org's own builds from February 2026 onward send this query.

### PHP 8.5: a trial

The PPA never built php8.5 for focal. Its build dependencies' version floors are all met by focal,
so CI builds and tests it, but it may fail, and it is never released. It builds and passes the
same tests as the other branches, mod_php included. Focal's ICU is 66, so `IntlListFormatter`
exists but supports only `TYPE_AND` and `WIDTH_WIDE`: `TYPE_OR`, `TYPE_UNITS`, `WIDTH_SHORT` and
`WIDTH_NARROW` need ICU >= 67. The test prints which applies.

## Pipeline

| Step | Where | What it guarantees |
|---|---|---|
| `scripts/fetch.sh` | anywhere | downloads the pinned `.dsc` and tarballs from Launchpad into `src/<name>/<version>/` |
| `scripts/build.sh` | ubuntu:<series>, target arch | the `.dsc` must verify with `gpgv` against `keys/ondrej-ppa-upload-key.asc` (Ondřej Surý's "Automated PPA Upload Key"), whose fingerprint must equal `UPLOAD_KEY_FPR`. `dpkg-source` checks every file against the signed checksums, then `dpkg-buildpackage` runs |
| `scripts/test.sh` | a fresh ubuntu:<series> | installs the target's package set (`TEST_PACKAGES` and the branch's `PHP_EXTENSIONS`) from `dist/`, plus apache2 from the archive, then checks: the version and fix floor; that the changelog records the fix; for 8.2 and later, `PHP_VERSION`; the modules; `php-fpm<branch> -t`; a smoke script; mod_php serving a page; no telemetry; API parity |
| `scripts/package.sh` | anywhere | one bundle per branch/series/arch: the `.debs`, `SHA256SUMS` and `BUILDINFO` (input checksums, commit, builder image), plus the bundle's `.sha256` |
| `scripts/test_install.sh` | a fresh ubuntu:<series> | runs `host/install.sh simulate` against the bundle, with the bundle's packages installed, and checks that it refuses a wrong sha256 |
| `scripts/upload.sh` | anywhere with AWS credentials | dry run by default. `--apply` uploads to `s3://$S3_BUCKET/$S3_PREFIX/php<branch>/<version>/`, and refuses to replace an existing object. `--presign` prints a time-limited download URL |
| `host/install.sh` | the target host, as root | `simulate` or `apply`; see [Installing on a host](#installing-on-a-host) |

A bundle is named `php-backports_<version>_<series>_<arch>.tar`, for example
`php-backports_7.4.33-31+ubuntu20.04.1~clarity2_focal_arm64.tar`. The version names the branch, so
bundles of different branches never share a name. Any epoch is dropped, as in a `.deb`'s name.

### Building locally

You need Docker. The build tree goes on the host disk (about 2.5 GB), and the build dependencies
take about another 1.3 GB inside Docker's disk.

```bash
make build test package ARCH=arm64                   # focal, PHP 8.1; about 20-40 minutes on 8 cores
make build test package PHP_BRANCH=8.3 ARCH=amd64    # another branch
make build test package TARGET=resolute ARCH=arm64   # resolute (8.1 only)
make test-install                                    # install.sh simulate against the bundle
make upload [PHP_BRANCH=8.3] [TARGET=resolute]       # dry run
make upload APPLY=1 && make presign
```

`CONTAINER=<name>` names the build or test container, so a disk watchdog can stop it.

### CI

`.github/workflows/release.yml` builds, tests and packages on GitHub's runners, arm64
(`ubuntu-24.04-arm`) and amd64 (`ubuntu-24.04`):
- **build:** focal x 7.4, 8.0, 8.1, 8.2, 8.3 and 8.4, and resolute x 8.1, on both architectures, 14
  jobs. Each also runs `make test-install`.
- **trial:** focal x 8.5 on both architectures. It is allowed to fail, and its bundles are kept as
  run artifacts only.

Pushing a `v*` tag publishes the 14 bundles, their `.sha256` files and `install.sh` as a GitHub
Release, each bundle with a build provenance attestation. It never publishes the trial. It builds
with `LOCAL_TAG=clarity2`, so its versions never collide with a private build of the same revision
or with the `clarity1` release.

`.gitlab-ci.yml` runs build, test and package for each target on GitLab's hosted arm64 runners,
for one branch, `PHP_BRANCH` (8.1):
- builds on `$BUILD_RUNNER_TAG` (default `saas-linux-medium-arm64`, 4 vCPU / 16 GB);
- the rest on `saas-linux-small-arm64`.

A 2 GB runner runs out of memory on this build.

Each target has its own manual upload job on the default branch. It authenticates with GitLab OIDC
as an IAM role that only that branch can assume, and that may only `PutObject` under the bucket's
prefix, so no AWS keys are stored in CI. `aws/setup.sh` creates the bucket and the role. It is a
dry run by default; `--apply` makes the changes. It needs `GITLAB_PROJECT_PATH`, `S3_BUCKET` and
`AWS_REGION_NAME`. Then set `AWS_ROLE_ARN` as a CI/CD variable.

## Installing on a host

### Prebuilt bundles

Each [release](https://github.com/clarity-tech/php-focal-backports/releases) carries a bundle for
each branch and target, on arm64 and amd64, with its sha256, all built by the release workflow.
Pick the bundle for your host's branch, series and architecture. Check where a bundle came from
before you trust it:

```bash
gh attestation verify <bundle>.tar --repo clarity-tech/php-focal-backports
```

Then install with the release's asset URL and sha256, as below. If you would rather not trust
our builds, build your own; that is what the rest of this README is for.

### Your own builds

The bucket stays private. Hosts fetch the bundle through a pre-signed URL, so no instance role
needs S3 access:

```bash
bash install.sh simulate '<bundle URL>' <bundle sha256>
bash install.sh apply    '<bundle URL>' <bundle sha256>
```

The same `install.sh` works for every branch. It reads the branch from the bundle (its one
`php<branch>-common` package) and upgrades the host's packages of that branch, mod_php and the
embed SAPI included. A host with two branches installed takes two bundles, one run each.

It refuses to install unless all of these hold:

- the bundle's sha256 matches, and every package inside matches `SHA256SUMS`;
- the bundle is for this host's architecture;
- the bundle is at or above its branch's fix floor, which `install.sh` keeps in its own table
  rather than trusting the bundle;
- the host runs the PPA's (or packages.sury.org's) build of that branch, not Ubuntu's own, such as
  focal's php7.4 7.4.3, which Ubuntu fixes itself;
- every package of that branch the host has is in the bundle, so there is no partial upgrade;
- apt's dry run removes nothing and changes nothing but those packages, plus `php-common` if the
  host's is older than the new packages need.

Modified config files are kept, so pool and `php.ini` edits survive, including a temporary stopgap.
Separately built extensions (mongodb, redis, igbinary, msgpack, opentelemetry) are not touched: they
depend on the PHP API version, which a patch update within a branch keeps. Afterwards it checks:

- the version is at or above the fix floor;
- if the branch's FPM is installed, the FPM master runs the new binary;
- if mod_php is installed and Apache is running, no Apache process still maps the old module (it
  reloads Apache gracefully if one does);
- local HTTP codes match the run before the upgrade;
- nginx logged no upstream errors.

Long-running PHP processes (queue workers, supervisor programs) keep the old binary until they are
restarted. The script lists any it finds.

**Roll out one host at a time, canary first.** Start with a non-production host on the same series
that runs your real workload, then each production node in turn. **Snapshot each production node
first:** the PPA has deleted its old focal packages, so there is nothing to downgrade to.

## Keeping releases

Treat the upload bucket as temporary: `aws/setup.sh` gives it a 60-day expiry. Keep the durable
copy of each bundle you install, with its `.sha256`, somewhere permanent, such as a package
registry. Builds are not byte-reproducible, so a later rebuild of the same version is different
bytes. Also archive `src/`, every signed `.dsc` and tarball, because the PPA deletes old uploads.
To rebuild without Launchpad, unpack that archive into `src/` and run `make build` without `fetch`.

## Adding the next fix

For each affected branch, bump `PHP_SOURCE_VERSION` in `branches/<branch>.env` to the PPA's new
jammy upload, along with `FIX_FLOOR` (and `FIX_UPSTREAM` for 8.2 and later). Bump the same floor in
`host/install.sh`'s table; `scripts/test.sh` fails if the two disagree. Then bump `LOCAL_TAG` and
build, test, package and upload.

If the uploads start being signed by a different key, the build fails at the signature check.
Replace `keys/ondrej-ppa-upload-key.asc` and `UPLOAD_KEY_FPR` together, and only after confirming
the new fingerprint is registered to the uploader's Launchpad account
(`https://api.launchpad.net/1.0/~ondrej/gpg_keys`).

## Why not ...

- **sury's Debian 11 (bullseye) packages**, which share focal's glibc 2.31? They were still pre-fix
  on arm64. Mixing distributions' dependency trees on a production host is also a worse risk than
  rebuilding the same maintainer's source for the right series.
- **Upgrading the OS?** That is the real fix. This project buys the time to do it properly.

## Licences

This repository holds only build, test and install tooling, released under the MIT License (see
[LICENSE](LICENSE)). The PHP sources and their Debian
packaging are downloaded from Launchpad at build time. They are not included here, and they keep
their own licences: the PHP License, and the packaging's own terms. `keys/` holds the PPA
maintainer's public upload key.
