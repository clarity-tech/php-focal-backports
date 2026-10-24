#!/usr/bin/env bash
# Rebuild every source in SOURCES for TARGET_SERIES, unchanged apart from a new changelog entry,
# and collect the .debs into dist/<series>-<arch>/.
# Runs INSIDE an Ubuntu TARGET_SERIES environment of the target architecture, as root: the
# `make build` docker container, or a CI job whose image is ubuntu:<series>.
. "$(dirname "$0")/lib.sh"

. /etc/os-release
[ "$VERSION_CODENAME" = "$TARGET_SERIES" ] || die "running on $VERSION_CODENAME, expected $TARGET_SERIES"
export DEBIAN_FRONTEND=noninteractive
log "build environment: $PRETTY_NAME $(dpkg --print-architecture), $(nproc) CPUs"

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential ca-certificates devscripts dpkg-dev equivs fakeroot gnupg gpgv libdistro-info-perl >/dev/null

# The PPA upload key, as a plain keyring gpgv can read, after checking it is the key config.env names.
keyfile=$ROOT/keys/ondrej-ppa-upload-key.asc
keyring=$(mktemp); gpg --batch --dearmor < "$keyfile" > "$keyring"
fpr=$(gpg --batch --show-keys --with-colons "$keyfile" | awk -F: '/^fpr/{print $10; exit}')
[ "$fpr" = "$UPLOAD_KEY_FPR" ] || die "$keyfile is $fpr, config.env expects $UPLOAD_KEY_FPR"
# dpkg-source checks .dsc signatures against ~/.gnupg/trustedkeys.gpg; give it the same single key.
mkdir -p ~/.gnupg && chmod 700 ~/.gnupg && cp "$keyring" ~/.gnupg/trustedkeys.gpg

rm -rf "$BUILD_DIR" "$DIST_DIR"; mkdir -p "$BUILD_DIR" "$DIST_DIR"
DEBFULLNAME=${MAINTAINER% <*}; DEBEMAIL=${MAINTAINER##*<}; DEBEMAIL=${DEBEMAIL%>}; export DEBFULLNAME DEBEMAIL

# build_one <name> <version>: verify, unpack, rebuild and collect one source package. Prints the
# .debs it produced, one per line, on fd 3.
build_one() {
  local name=$1 version=$2 dsc new note
  dsc=$(ls "$SRC_DIR/$name"/*.dsc 2>/dev/null | head -1)
  [ -n "$dsc" ] || die "no .dsc for $name in src/$name: run scripts/fetch.sh first"
  new=$(target_version_of "$version")
  log "$name $version -> $new"

  # The .dsc must carry a good signature from the PPA key; dpkg-source then checks every file
  # against the checksums in that signed .dsc.
  gpgv --keyring "$keyring" "$dsc" 2>&1 | grep -E 'Good signature|BAD|Can.t check' | sed 's/^/   /'
  gpgv --keyring "$keyring" "$dsc" >/dev/null 2>&1 || die "$dsc is not validly signed by $UPLOAD_KEY_FPR"
  dpkg-source --require-valid-signature -x "$dsc" "$BUILD_DIR/$name" >/dev/null

  cd "$BUILD_DIR/$name"
  # -b: the new version can sort below the one it is rebuilt from (on focal it does, on purpose).
  note=""; [ "$name" = php8.1 ] && [ "$SURY_TELEMETRY" = off ] && note=" Built without sury's DNS telemetry (patch 0048)."
  dch -b --newversion "$new" --distribution "$TARGET_SERIES" --force-distribution \
    "Rebuild of $version for Ubuntu $TARGET_VERSION ($TARGET_SERIES). No source changes.$note"
  mk-build-deps --install --remove --tool 'apt-get -y -qq --no-install-recommends' debian/control >/dev/null
  # See SURY_TELEMETRY in config.env. This edits the build container only, never the packages.
  if [ -n "$note" ] && [ -s /usr/lib/php/php-common.mk ]; then
    : > /usr/lib/php/php-common.mk
    log "emptied /usr/lib/php/php-common.mk in the build container: telemetry is compiled out"
  fi
  # nocheck: the upstream test suites take hours (PHP's); scripts/test.sh checks the result instead.
  DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us > "$BUILD_DIR/$name.build.log" 2>&1 \
    || { tail -40 "$BUILD_DIR/$name.build.log"; die "$name failed to build (log: build/$TARGET_SERIES-$ARCH/$name.build.log)"; }

  cd "$BUILD_DIR"
  ls ./*.deb | sed 's#^\./##' >&3
  mv ./*.deb ./*.buildinfo ./*.changes "$DIST_DIR/"
}

# 1. Libraries (LIB_SOURCES, focal only), so php8.1 compiles against the same ones the PPA's focal
# builds did. Each library's runtime and -dev packages go into the build container straight away,
# before anything that builds against them; its tools, docs and language bindings do not.
each_lib | while read -r name version; do
  debs=$(build_one "$name" "$version" 3>&1 >&2)
  want=$(echo "$debs" | grep -E '^lib' | grep -vE -- '-(dbg|doc|tools|utils)_|dbgsym' | sed "s#^#$DIST_DIR/#")
  apt-get install -y -qq --no-install-recommends $want >/dev/null
  log "installed $(echo "$want" | xargs -n1 basename | sed 's/_.*//' | tr '\n' ' ')for the builds that follow"
done

# 2. php-defaults, then the rest: php8.1 build-depends on php-common, includes its
# /usr/lib/php/php-common.mk, and its packages need php-common >= 1:81~, which focal's own 1:75 does
# not satisfy and resolute's own 2:99ubuntu1 Breaks (see config.env).
for name in php-defaults $(each_source | awk '$1 != "php-defaults" {print $1}'); do
  version=$(each_source | awk -v n="$name" '$1 == n {print $2}')
  [ -n "$version" ] || continue
  build_one "$name" "$version" 3>/dev/null
  if [ "$name" = php-defaults ]; then
    apt-get install -y -qq --no-install-recommends "$DIST_DIR"/php-common_*.deb >/dev/null
    log "installed php-common $(dpkg-query -W -f='${Version}' php-common) for the builds that follow"
  fi
done
rm -f "$keyring"
log "built $(ls "$DIST_DIR"/*.deb | wc -l | tr -d ' ') packages into dist/$TARGET_SERIES-$ARCH"
