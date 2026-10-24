#!/usr/bin/env bash
# Install the built packages on a CLEAN TARGET_SERIES system and check the result is usable and
# carries the fix. Runs inside a fresh ubuntu:<series> container of the target architecture.
# Exits non-zero after the checks if any failed.
. "$(dirname "$0")/lib.sh"

. /etc/os-release
[ "$VERSION_CODENAME" = "$TARGET_SERIES" ] || die "running on $VERSION_CODENAME, expected $TARGET_SERIES"
export DEBIAN_FRONTEND=noninteractive
ls "$DIST_DIR"/*.deb >/dev/null 2>&1 || die "no packages in ${DIST_DIR#"$ROOT"/}: run the build first"
P=$PHP_SOURCE

# The packages the target's hosts install (targets/$TARGET.env), and the branch's extensions.
WANT="${TEST_PACKAGES:?TEST_PACKAGES is not set in targets/$TARGET.env} $(for e in $PHP_EXTENSIONS; do printf '%s-%s ' "$P" "$e"; done)"
debs=""; for p in $WANT; do f=$(ls "$DIST_DIR/${p}_"*.deb 2>/dev/null | head -1); [ -n "$f" ] || die "$p was not built"; debs="$debs $f"; done

apt-get update -qq
# apache2 and curl, for the mod_php test, from the series' own archive. --no-install-recommends
# would leave out apache2 itself (configs, a2enmod, apache2ctl): libapache2-mod-php only recommends it.
apt-get install -y -qq --no-install-recommends $debs apache2 curl > /tmp/install.log 2>&1 || { tail -20 /tmp/install.log; die "install failed"; }
log "installed: $(echo $WANT | wc -w | tr -d ' ') packages from ${DIST_DIR#"$ROOT"/}, and apache2 $(dpkg-query -W -f='${Version}' apache2) from the archive"

fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "   PASS $1"; else echo "   FAIL $1"; fail=1; fi; }

php_version=$($P -r 'echo PHP_VERSION;')
pkg_version=$(dpkg-query -W -f='${Version}' "$P-common")
want_version=$(target_version_of "$PHP_SOURCE_VERSION")
echo "   $P $php_version, package $pkg_version"
check "package version is the rebuild ($want_version)" "[ '$pkg_version' = '$want_version' ]"

# The PHP2Shell fix (CVE-2026-109618, CVE-2026-109619). Every branch's changelog records it: as the
# PPA's backported patch (7.4, 8.0, 8.1: "Avoid state corruption via bailout") or as the upstream
# release that carries it (8.2 and later). Those also have to report that release.
# grep -c, not -q: -q exits at the first match, zcat then dies of SIGPIPE, and pipefail (lib.sh)
# fails the check depending on timing.
check "changelog records the PHP2Shell fix" \
      "[ \"\$(zcat /usr/share/doc/$P-common/changelog.Debian.gz | grep -c 'CVE-2026-109618, CVE-2026-109619')\" -gt 0 ]"
check "fix floor: $P-common $pkg_version >= $FIX_FLOOR" "dpkg --compare-versions '$pkg_version' ge '$FIX_FLOOR'"
if [ -n "$FIX_UPSTREAM" ]; then
  check "fixed upstream: PHP $php_version >= $FIX_UPSTREAM" \
        "$P -r 'exit(version_compare(PHP_VERSION, \"$FIX_UPSTREAM\", \">=\") ? 0 : 1);'"
fi

for m in bcmath curl gd gmp intl json mbstring mysqli pdo_mysql sqlite3 xml zip readline sodium exif pcntl posix sockets; do
  check "cli module $m" "$P -m | grep -qix $m"
done
check "opcache loads" "$P -d opcache.enable_cli=1 -r 'exit(function_exists(\"opcache_get_status\") ? 0 : 1);'"
check "php-fpm$PHP_BRANCH config test" "php-fpm$PHP_BRANCH -t"
[ "${SURY_TELEMETRY:-off}" = off ] && check "php-fpm$PHP_BRANCH has no sury DNS telemetry compiled in" "! grep -q telemetry.sury.org /usr/sbin/php-fpm$PHP_BRANCH"
check "a PHP script runs: sessions, json, pcre, intl" \
      "$P -r 'session_start(); json_encode([1]); preg_match(\"/a/u\",\"a\"); new NumberFormatter(\"en_IN\", NumberFormatter::DECIMAL); exit(0);'"
check "php -v reports no startup warnings" "! $P -v 2>&1 | grep -qiE 'warning|unable to load'"

# mod_php, the SAPI the PHP2Shell advisory rates highest-risk: Apache loads the module and serves a
# PHP page through it. mod_php needs the prefork MPM; switch to it here rather than rely on the
# package's postinst doing so in a container.
a2dismod -q -f mpm_event mpm_worker >/dev/null 2>&1 || true
a2enmod -q mpm_prefork >/dev/null 2>&1 || true
a2enmod -q "$P" >/dev/null 2>&1 || true
modso=$(ls /usr/lib/apache2/modules/libphp*.so 2>/dev/null | head -1)
cat > /var/www/html/php-smoke.php <<'PHP'
<?php
header('Content-Type: text/plain');
session_start();
echo 'mod_php ', PHP_VERSION, ' ', PHP_SAPI, ' ', json_encode(['pcre' => preg_match('/a/u', 'a'), 'session' => session_status() === PHP_SESSION_ACTIVE]);
PHP
want_body="mod_php $php_version apache2handler {\"pcre\":1,\"session\":true}"
check "mod_php: apache2 configtest" "apache2ctl configtest"
check "mod_php: apache2 loads $P (${modso#/usr/lib/apache2/modules/})" "apache2ctl -M 2>/dev/null | grep -qE '^ *php[0-9]*_module '"
# restart, not start: it also covers an apache2 that a postinst managed to start.
apache2ctl restart >/tmp/apache2ctl.log 2>&1 || cat /tmp/apache2ctl.log
for _ in $(seq 20); do curl -fs -o /dev/null http://127.0.0.1/ && break; sleep 0.5; done
body=$(curl -fsS -m 10 http://127.0.0.1/php-smoke.php 2>&1 || true)
echo "   mod_php page: $body"
check "mod_php: serves a PHP page (PHP $php_version, apache2handler, pcre, sessions)" '[ "$body" = "$want_body" ]'
check "mod_php: no crashes in the Apache error log" "! grep -qiE 'segfault|exit signal|child pid [0-9]+ exit' /var/log/apache2/error.log"
[ "${SURY_TELEMETRY:-off}" = off ] && check "mod_php has no sury DNS telemetry compiled in" "[ -n '$modso' ] && ! grep -q telemetry.sury.org '$modso'"
apache2ctl stop >/dev/null 2>&1 || true
echo "   info: ICU $($P -r 'echo INTL_ICU_VERSION;'), IntlListFormatter $($P -r 'echo class_exists("IntlListFormatter") ? "present" : "absent";') (PHP 8.5 compiles it in only with ICU >= 67)"

# The rebuild must expose exactly what production's PHP does: same functions, classes, methods and
# constants in every extension, and the same compiled-in library versions.
# targets/<target>-php<branch>.parity is scripts/parity_dump.php's output on a production host. A
# difference means the build environment differs from the one the PPA used (it caught libzip, libgd
# and pcre2 on focal).
baseline=$ROOT/targets/$TARGET-$P.parity
if [ -f "$baseline" ]; then
  $P "$ROOT/scripts/parity_dump.php" > /tmp/parity.txt 2>&1
  if diff -q "$baseline" /tmp/parity.txt >/dev/null; then
    echo "   PASS API surface matches production ($(wc -l < "$baseline" | tr -d ' ') facts, ${baseline#"$ROOT"/})"
  else
    echo "   FAIL API surface differs from production (< production, > this build):"
    diff "$baseline" /tmp/parity.txt | grep '^[<>]' | head -40 | sed 's/^/        /'
    fail=1
  fi
else
  echo "   skip API surface check: no ${baseline#"$ROOT"/}"
fi

[ "$fail" = 0 ] || die "tests failed"
log "all checks passed for $P on a clean $PRETTY_NAME $(dpkg --print-architecture)"
