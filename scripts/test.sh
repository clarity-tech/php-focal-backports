#!/usr/bin/env bash
# Install the built packages on a CLEAN TARGET_SERIES system and check the result is usable and
# carries the fix. Runs inside a fresh ubuntu:<series> container of the target architecture.
# Exits non-zero on the first failed check.
. "$(dirname "$0")/lib.sh"

. /etc/os-release
[ "$VERSION_CODENAME" = "$TARGET_SERIES" ] || die "running on $VERSION_CODENAME, expected $TARGET_SERIES"
export DEBIAN_FRONTEND=noninteractive
ls "$DIST_DIR"/*.deb >/dev/null 2>&1 || die "no packages in dist/$TARGET_SERIES-$ARCH: run the build first"

# The packages the target's hosts install (targets/$TARGET.env).
WANT=${TEST_PACKAGES:?TEST_PACKAGES is not set in targets/$TARGET.env}
debs=""; for p in $WANT; do f=$(ls "$DIST_DIR/${p}_"*.deb 2>/dev/null | head -1); [ -n "$f" ] || die "$p was not built"; debs="$debs $f"; done

apt-get update -qq
apt-get install -y -qq --no-install-recommends $debs > /tmp/install.log 2>&1 || { tail -20 /tmp/install.log; die "install failed"; }
log "installed: $(echo $WANT | wc -w | tr -d ' ') packages from dist/"

fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "   PASS $1"; else echo "   FAIL $1"; fail=1; fi; }

php_version=$(php8.1 -r 'echo PHP_VERSION;')
pkg_version=$(dpkg-query -W -f='${Version}' php8.1-common)
echo "   php8.1 $php_version, package $pkg_version"
check "package version is the rebuild ($(target_version_of "$(each_source | awk '$1=="php8.1"{print $2}')"))" \
      "[ '$pkg_version' = '$(target_version_of "$(each_source | awk '$1=="php8.1"{print $2}')")' ]"
# grep -c, not -q: -q exits at the first match, zcat then dies of SIGPIPE, and pipefail (lib.sh)
# fails the check depending on timing.
check "changelog records the PHP2Shell fix" \
      "[ \"\$(zcat /usr/share/doc/php8.1-common/changelog.Debian.gz | grep -c 'CVE-2026-109618, CVE-2026-109619')\" -gt 0 ]"
check "fix floor: php8.1-common >= 8.1.34-9" "dpkg --compare-versions '$pkg_version' ge 8.1.34-9"
for m in bcmath curl gd gmp intl mbstring mysqli pdo_mysql sqlite3 xml zip readline sodium exif pcntl posix sockets; do
  check "cli module $m" "php8.1 -m | grep -qix $m"
done
check "opcache loads" "php8.1 -d opcache.enable_cli=1 -r 'exit(function_exists(\"opcache_get_status\") ? 0 : 1);'"
check "php-fpm8.1 config test" "php-fpm8.1 -t"
[ "${SURY_TELEMETRY:-off}" = off ] && check "php-fpm8.1 has no sury DNS telemetry compiled in" "! grep -q telemetry.sury.org /usr/sbin/php-fpm8.1"
check "a PHP script runs: sessions, json, pcre, intl" \
      "php8.1 -r 'session_start(); json_encode([1]); preg_match(\"/a/u\",\"a\"); new NumberFormatter(\"en_IN\", NumberFormatter::DECIMAL); exit(0);'"
check "php -v reports no startup warnings" "! php8.1 -v 2>&1 | grep -qiE 'warning|unable to load'"

# The rebuild must expose exactly what production's PHP does: same functions, classes, methods and
# constants in every extension, and the same compiled-in library versions. targets/<target>.parity
# is scripts/parity_dump.php's output on a production host. A difference means the build
# environment differs from the one the PPA used (it caught libzip, libgd and pcre2 on focal).
baseline=$ROOT/targets/$TARGET.parity
if [ -f "$baseline" ]; then
  php8.1 "$ROOT/scripts/parity_dump.php" > /tmp/parity.txt 2>&1
  if diff -q "$baseline" /tmp/parity.txt >/dev/null; then
    echo "   PASS API surface matches production ($(wc -l < "$baseline" | tr -d ' ') facts, targets/$TARGET.parity)"
  else
    echo "   FAIL API surface differs from production (< production, > this build):"
    diff "$baseline" /tmp/parity.txt | grep '^[<>]' | head -40 | sed 's/^/        /'
    fail=1
  fi
else
  echo "   skip API surface check: no targets/$TARGET.parity"
fi

[ "$fail" = 0 ] || die "tests failed"
log "all checks passed on a clean $PRETTY_NAME $(dpkg --print-architecture)"
