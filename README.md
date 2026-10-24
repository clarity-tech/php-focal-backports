# php-focal-backports

Security-patched PHP 8.1 packages for **Ubuntu 20.04 (focal)**, which no supplier builds any more,
and for **Ubuntu 26.04 (resolute)**, where the supplier's arm64 build lagged behind amd64. Built
and run on arm64 (AWS Graviton); `ARCH=amd64` works the same way.

## Why it exists

On 2026-10-21 PHP released fixes for **CVE-2026-109618 and CVE-2026-109619** ("PHP2Shell") in
8.5.12, 8.4.27, 8.3.36 and 8.2.35. PHP 8.1 is past its upstream end of life. Ondřej Surý's
`ppa:ondrej/php` shipped a backport for it, **8.1.34-9**, carrying
`0083-Avoid-state-corruption-via-bailout.patch`. That backport only covers some systems:

- **Ubuntu 20.04 got nothing.** The PPA stopped building focal in 2025, and its last focal php8.1,
  8.1.32, was deleted on 2025-06-09. packages.sury.org has no focal suite, and Ubuntu's own archive
  never carried php8.1 for focal. So a 20.04 host running the PPA's php8.1 had nothing to install.
- **Ubuntu 26.04 on arm64 lagged.** On 2026-10-22, packages.sury.org's resolute arm64 index still
  served the pre-fix 8.1.34-8, while amd64 already had 8.1.34-9.

This project rebuilds the PPA's own **signed** source packages, **unchanged**, for each target. The
fix comes from upstream and the PPA's maintainer, not from us. What this adds is a way to rebuild
that source safely for a series nobody builds any more:
- it verifies the signature;
- it rebuilds against the same libraries the PPA used;
- it tests the result for API parity with a running host;
- it installs with guards that refuse a partial or surprising upgrade.

The PPA publishes one Debian source per series with a "No-change backport" changelog entry. We take
the jammy upload, since the PPA has no focal or resolute, and add a "Rebuild of ... for Ubuntu
<version>" entry.

## Targets

`TARGET` selects one of `targets/*.env`, which set the series, its version number and the packages
`scripts/test.sh` installs. It defaults to `focal`.

| `TARGET` | Series | For | Tested package set |
|---|---|---|---|
| `focal` (default) | Ubuntu 20.04 | hosts that ran the PPA's php8.1 before it dropped focal | a typical Laravel web node's php8.1 packages |
| `resolute` | Ubuntu 26.04 | images that install PHP from packages.sury.org | the same set, with their php8.1 dependencies |

## What it builds

`config.env` pins everything. Both targets build the same two sources:

| Source | Version taken from the PPA (jammy) | Built as (focal / resolute) | Why |
|---|---|---|---|
| php8.1 | 8.1.34-9+ubuntu22.04.1+deb.sury.org+1 | 8.1.34-9+ubuntu20.04.1~backport1 / 8.1.34-9+ubuntu26.04.1~backport1 | carries the PHP2Shell fix |
| php-defaults | 101~+ubuntu22.04.1+deb.sury.org+1 | 2:101~+ubuntu20.04.1~backport1 / 2:101~+ubuntu26.04.1~backport1 | provides `php-common`, which php8.1 needs at >= 1:81~ |

php-defaults is needed on both targets:
- Focal's own `php-common` is 1:75, which is too old.
- Resolute's own, 2:99ubuntu1, is new enough but declares `Breaks: php8.1-common`, so the two cannot
  be installed together.

Building ours first also puts sury's `/usr/lib/php/php-common.mk` in place, which php8.1's
`debian/rules` includes, so both targets' binaries are built the same way. That file is also what
switches on the version-check telemetry; see [No phone-home](#no-phone-home).

The version is always `<revision>+ubuntu<version>.1~<LOCAL_TAG>`, with no `~` straight after the
Debian revision, so it compares >= 8.1.34-9 and a fix-floor check passes. Bump `LOCAL_TAG` for
every new build.

- **focal:** it sorts above the PPA's old 8.1.28-2+ubuntu20.04.1+deb.sury.org+1. It sorts **below**
  an official PPA build of the same version, so if the PPA ever publishes one for focal again, apt
  prefers it.
- **resolute:** it sorts above sury's 8.1.34-8+0~20260703.81+ubuntu26.04~1.gbp86d822. packages.sury.org
  uses a different format, so it also sorts **above** sury's own 8.1.34-9
  (8.1.34-9+0~20261021.82+ubuntu26.04~1.gbp4e430a). At equal pin priority, apt keeps ours until sury
  publishes a later revision.

### Focal: the PPA's own libraries

The PPA did not build its focal PHP against plain focal. Its build logs on Launchpad (8.1.28-2 and
8.1.29-1, arm64) show the PPA's own builds of five libraries in the build environment, and some of
them are compiled into PHP. So the focal target rebuilds those five first, from the PPA's focal
uploads. The uploads are deleted from the PPA, but their files are still on Launchpad, and their
`.dsc`s verify against the same upload key. php8.1 then compiles against them (`LIB_SOURCES` in
`targets/focal.env`):

| Library | Version | What building against focal's own would change |
|---|---|---|
| libzip | 1.7.3 | focal ships libzip5 1.5.1 (`libzip.so.5`), while PPA hosts have the PPA's libzip4 1.7.3. `php8.1-zip` would need a library apt will not add, and `ZipArchive` would lose methods |
| libgd2 | 2.3.3-9 | focal's 2.2.5 has no AVIF functions; the PPA's GD exposes them |
| pcre2 | 10.42-3 | PHP sets `PCRE2_EXTRA_ALLOW_LOOKAROUND_BSK` only when compiled against >= 10.38. Without it, a host's pcre2 10.39 or 10.40 rejects `\K` inside a lookaround |
| libxml2 | 2.9.14 | `LIBXML_VERSION` is compiled in |
| argon2 | 0~20190702 | the version `password_hash()` was built with |

We learned this the hard way. A first build against focal's own libraries passed every functional
test. It was refused only by the install dry run on a canary host: `php8.1-zip : Depends: libzip5`.
It had also silently dropped GD's AVIF functions and pcre2's `\K`-in-lookaround option.

The libraries go into the bundle so `scripts/test.sh` can install them on a clean focal. On hosts,
`host/install.sh` upgrades php8.1 packages only. Each host keeps its own libraries, which are the
same versions or newer, and ours sort below the PPA's, so apt never prefers them.

### API parity

A build that passes on a clean focal proves little by itself. `scripts/parity_dump.php` lists every
function, class, method and constant of PHP's own extensions, plus the compiled-in library versions.
`scripts/test.sh` diffs that against `targets/<target>.parity`, and any difference fails the build.

**No baseline ships with this repository:** it has to come from your own hosts. Dump one on a host
running the PHP you are replacing:

```bash
php8.1 scripts/parity_dump.php > targets/focal.parity
```

Without a baseline, the check is skipped. Hosts with different libraries differ in a handful of
constants. For example, libcurl 7.81 adds 7 `CURLOPT_*` constants, and OpenSSL 3 drops
`OPENSSL_SSLV23_PADDING`. So take the baseline from a host on the same series.

### No phone-home

Since sury's packaging patch 0048 (2026-02-11), php-fpm and mod_php send a DNS "version check" at
startup. It is an encrypted UDP/53 query carrying the package name and version, sent to
`telemetry.sury.org`. php8.1's `debian/rules` says it is "not enabled in build by default"; it is
turned on only by `/usr/lib/php/php-common.mk` from the `php-common` package.

With `SURY_TELEMETRY=off`, the default, `build.sh` empties that file in the build container before
building php8.1, which compiles the call out. No source is changed. `test.sh` fails the build if
`php-fpm8.1` still contains the host name.

Hosts that run the PPA's or packages.sury.org's own builds from February 2026 onward send this query.

## Pipeline

| Step | Where | What it guarantees |
|---|---|---|
| `scripts/fetch.sh` | anywhere | downloads the pinned `.dsc` and tarballs from Launchpad |
| `scripts/build.sh` | ubuntu:<series>, target arch | the `.dsc` must verify with `gpgv` against `keys/ondrej-ppa-upload-key.asc` (Ondřej Surý's "Automated PPA Upload Key"), whose fingerprint must equal `UPLOAD_KEY_FPR`. `dpkg-source` checks every file against the signed checksums, then `dpkg-buildpackage` runs |
| `scripts/test.sh` | a fresh ubuntu:<series> | installs the target's package set (`TEST_PACKAGES`) from `dist/`, then checks: the version; that the changelog records the fix; the modules; `php-fpm8.1 -t`; a smoke script; no telemetry; API parity |
| `scripts/package.sh` | anywhere | one bundle per series/arch: the `.debs`, `SHA256SUMS` and `BUILDINFO` (input checksums, commit, builder image), plus the bundle's `.sha256` |
| `scripts/upload.sh` | anywhere with AWS credentials | dry run by default. `--apply` uploads to `s3://$S3_BUCKET/$S3_PREFIX/php8.1/<version>/`, and refuses to replace an existing object. `--presign` prints a time-limited download URL |
| `host/install.sh` | the target host, as root | `simulate` or `apply`; see [Installing on a host](#installing-on-a-host) |

### Building locally

You need Docker. The build tree goes on the host disk (about 2.5 GB), and the build dependencies
take about another 1.3 GB inside Docker's disk.

```bash
make build test package ARCH=arm64                   # focal; about 20-40 minutes on 8 cores
make build test package TARGET=resolute ARCH=arm64   # resolute
make upload [TARGET=resolute]                        # dry run
make upload APPLY=1 && make presign
```

`CONTAINER=<name>` names the build or test container, so a disk watchdog can stop it.

### CI

`.gitlab-ci.yml` runs build, test and package for each target on GitLab's hosted arm64 runners:
- builds on `$BUILD_RUNNER_TAG` (default `saas-linux-medium-arm64`, 4 vCPU / 16 GB);
- the rest on `saas-linux-small-arm64`.

A 2 GB runner runs out of memory on this build.

Each target has its own manual upload job on the default branch. It authenticates with GitLab OIDC
as an IAM role that only that branch can assume, and that may only `PutObject` under the bucket's
prefix, so no AWS keys are stored in CI. `aws/setup.sh` creates the bucket and the role. It is a
dry run by default; `--apply` makes the changes. It needs `GITLAB_PROJECT_PATH`, `S3_BUCKET` and
`AWS_REGION_NAME`. Then set `AWS_ROLE_ARN` as a CI/CD variable.

A GitHub Actions port onto `ubuntu-24.04-arm` runners would be straightforward. It is not included.

## Installing on a host

The bucket stays private. Hosts fetch the bundle through a pre-signed URL, so no instance role
needs S3 access:

```bash
bash install.sh simulate '<pre-signed URL>' <bundle sha256>
bash install.sh apply    '<pre-signed URL>' <bundle sha256>
```

It refuses to install unless all of these hold:

- the bundle's sha256 matches, and every package inside matches `SHA256SUMS`;
- the bundle is for this host's architecture;
- every php8.1 package the host has is in the bundle, so there is no partial upgrade;
- apt's dry run removes nothing and changes nothing but those packages.

Modified config files are kept, so pool and `php.ini` edits survive, including a temporary stopgap.
Separately built extensions (mongodb, redis, igbinary, msgpack, opentelemetry) are not touched: they
depend on the PHP API version, which an 8.1.x update keeps. Afterwards it checks:

- the FPM master runs the new binary;
- the version is at or above the fix floor;
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

Bump the pinned versions in `SOURCES` to the PPA's new jammy uploads and bump `LOCAL_TAG`. Then
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
