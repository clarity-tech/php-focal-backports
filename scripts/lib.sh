# Shared by every script. Sourced, not run.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config.env
. "$ROOT/config.env"

ARCH=${ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')}
SRC_DIR=$ROOT/src
BUILD_DIR=$ROOT/build/$TARGET_SERIES-$ARCH
DIST_DIR=$ROOT/dist/$TARGET_SERIES-$ARCH

log() { printf '== %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

# 8.1.34-9+ubuntu22.04.1+deb.sury.org+1 -> 8.1.34-9
upstream_of() { echo "${1%%+ubuntu*}"; }
# -> 8.1.34-9+ubuntu20.04.1~backport1 (see LOCAL_TAG in config.env for why `~`)
target_version_of() { echo "$(upstream_of "$1")+ubuntu${TARGET_VERSION}.1~${LOCAL_TAG}"; }

# Iterate SOURCES as "name version" lines.
each_source() { for pair in $SOURCES; do echo "${pair%%=*} ${pair#*=}"; done; }
# Iterate LIB_SOURCES (targets/<target>.env, published in LIB_SERIES) the same way.
each_lib() { for pair in ${LIB_SOURCES:-}; do echo "${pair%%=*} ${pair#*=}"; done; }
