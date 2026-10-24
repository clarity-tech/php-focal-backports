# Shared by every script. Sourced, not run.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config.env
. "$ROOT/config.env"

ARCH=${ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')}
SRC_DIR=$ROOT/src
BUILD_DIR=$ROOT/build/$TARGET_SERIES-$PHP_SOURCE-$ARCH
DIST_DIR=$ROOT/dist/$TARGET_SERIES-$PHP_SOURCE-$ARCH

log() { printf '== %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

case " $TARGET_BRANCHES " in
  *" $PHP_BRANCH "*) ;;
  *) die "TARGET=$TARGET builds PHP $TARGET_BRANCHES, not $PHP_BRANCH (targets/$TARGET.env)" ;;
esac

# 8.1.34-9+ubuntu22.04.1+deb.sury.org+1 -> 8.1.34-9 (1:7.4.33-31+... -> 1:7.4.33-31)
upstream_of() { echo "${1%%+ubuntu*}"; }
# -> 8.1.34-9+ubuntu20.04.1~backport1 (see LOCAL_TAG in config.env for why `~`). Keeps any epoch,
# so version comparisons stay right.
target_version_of() { echo "$(upstream_of "$1")+ubuntu${TARGET_VERSION}.1~${LOCAL_TAG}"; }
# A version without its epoch, as dpkg spells it in file names: 1:7.4.33-31+... -> 7.4.33-31+...
noepoch() { echo "${1#*:}"; }
# The release bundle: php-backports_<PHP version, without its epoch>_<series>_<arch>. The version
# names the branch (7.4.33-31..., 8.1.34-9...), so bundles of different branches never share a name.
# The epoch goes, as in a .deb's name: `:` is not URL-safe, and GNU tar reads `host:file` as remote.
bundle_name() { echo "php-backports_$(noepoch "$(target_version_of "$PHP_SOURCE_VERSION")")_${TARGET_SERIES}_${ARCH}"; }
# Where scripts/fetch.sh puts one source package's files, and so where build.sh looks for them: one
# directory per version, so two versions of a library (libgd2 -12 and -13) never mix.
src_dir_of() { echo "$SRC_DIR/$1/$(noepoch "$2")"; }

# Iterate SOURCES as "name version" lines.
each_source() { for pair in $SOURCES; do echo "${pair%%=*} ${pair#*=}"; done; }
# Iterate LIB_SOURCES (targets/<target>.env) as "name version series" lines. A pair is published in
# LIB_SERIES unless it ends in @<series>.
each_lib() {
  local pair rest
  for pair in ${LIB_SOURCES:-}; do
    rest=${pair#*=}
    case "$rest" in
      *@*) echo "${pair%%=*} ${rest%@*} ${rest##*@}" ;;
      *)   echo "${pair%%=*} $rest ${LIB_SERIES:-$SOURCE_SERIES}" ;;
    esac
  done
}
