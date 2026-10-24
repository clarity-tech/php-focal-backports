#!/usr/bin/env bash
# Upgrade a host's packages of one PHP branch (php7.4 ... php8.5) from a release bundle. Runs ON the
# host, as root.
#   bash install.sh simulate|apply <bundle URL> <bundle sha256>
# The URL is normally a GitHub Release asset, or a pre-signed S3 URL from scripts/upload.sh --presign.
# The bundle names its branch (it carries one php<X.Y>-common); only that branch's packages change,
# so a host with several branches installed is upgraded one bundle at a time.
#
# Guarded: nothing is installed unless the bundle's checksum matches, every file inside matches
# SHA256SUMS, the bundle is at or above that branch's PHP2Shell fix floor, and apt's dry run shows
# that only the host's existing packages of that branch change, with nothing removed. Modified
# config files are kept (the PHP2Shell stopgap lines in pool.d, php.ini edits such as
# post_max_size). Separately built extensions (mongodb, redis, igbinary, msgpack, opentelemetry)
# are not touched: they depend on the PHP API version, which a patch update within a branch keeps.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1
MODE=${1:-}; URL=${2:-}; WANT_SHA=${3:-}
case "$MODE" in simulate|apply) ;; *) echo "usage: $0 simulate|apply <bundle URL> <bundle sha256>"; exit 1;; esac
[ -n "$URL" ] && [ -n "$WANT_SHA" ] || { echo "usage: $0 simulate|apply <bundle URL> <bundle sha256>"; exit 1; }
OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
W=/root/php-backports; mkdir -p "$W"; cd "$W" || exit 1

http_codes() {
  for n in $({ grep -rhoE '^[[:space:]]*server_name[[:space:]]+[^;]+' /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
                 | awk '{for (i=2;i<=NF;i++) print $i}'
               grep -rhoiE '^[[:space:]]*ServerName[[:space:]]+[^[:space:]]+' /etc/apache2/sites-enabled 2>/dev/null | awk '{print $2}'; } \
             | grep -vE '^(_|example\.com|www\..*)$' | sort -u | head -3); do
    printf '%s=%s ' "$n" "$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $n" http://127.0.0.1/)"
  done
}
# PIDs of apache2 processes that still map a mod_php that dpkg has replaced.
apache_stale() { for p in $(pgrep -x apache2); do grep -q 'libphp.*\.so (deleted)' "/proc/$p/maps" 2>/dev/null && echo "$p"; done; }
t0=$(date -u +'%Y/%m/%d %H:%M:%S')
echo "== $(hostname) $(date -u +%FT%TZ) mode=$MODE | $(. /etc/os-release; echo "$PRETTY_NAME") $(dpkg --print-architecture) | http before: $(http_codes)"

# 1. Fetch and verify the bundle.
curl -fsSL -m 600 -o bundle.tar "$URL" || { echo "!! download failed"; exit 2; }
got=$(sha256sum bundle.tar | cut -d' ' -f1)
[ "$got" = "$WANT_SHA" ] || { echo "!! bundle sha256 $got does not match the expected $WANT_SHA"; exit 2; }
# --warning: bundles packed on macOS carry Apple xattr headers that GNU tar warns about, harmlessly.
rm -rf debs && mkdir debs && tar --warning=no-unknown-keyword -xf bundle.tar -C debs
(cd debs && sha256sum --quiet -c SHA256SUMS) || { echo "!! a package inside the bundle fails SHA256SUMS"; exit 2; }
grep -E '^(bundle|target|built|php):' debs/BUILDINFO | sed 's/^/   /'
[ "$(dpkg --print-architecture)" = "$(awk '/^target:/{print $NF}' debs/BUILDINFO)" ] || { echo "!! bundle is for another architecture"; exit 2; }

# 2. Which branch: the bundle's one php<X.Y>-common package names it.
common=$(cd debs && for f in php[0-9]*.[0-9]*-common_*.deb; do [ -e "$f" ] && echo "$f"; done)
[ "$(echo "$common" | grep -c .)" = 1 ] || { echo "!! expected one php<X.Y>-common package in the bundle, found: ${common:-none}"; exit 2; }
PHP=${common%%-common_*}; BRANCH=${PHP#php}
# The first version of each branch that carries the PHP2Shell fix (CVE-2026-109618, CVE-2026-109619).
# Kept here, not read from the bundle, so that a bundle cannot vouch for itself. Equal to FIX_FLOOR
# in the repository's branches/<branch>.env; scripts/test.sh checks that they agree.
case "$BRANCH" in
  7.4) FLOOR=1:7.4.33-31 ;;
  8.0) FLOOR=1:8.0.30-25 ;;
  8.1) FLOOR=8.1.34-9 ;;
  8.2) FLOOR=8.2.35-1 ;;
  8.3) FLOOR=8.3.36-1 ;;
  8.4) FLOOR=8.4.27-1 ;;
  8.5) FLOOR=8.5.12-1 ;;
  *) echo "!! no PHP2Shell fix floor known for $PHP"; exit 2 ;;
esac
new=$(dpkg-deb -f "debs/$common" Version)
dpkg --compare-versions "$new" ge "$FLOOR" || { echo "!! the bundle's $PHP-common $new is below the fix floor $FLOOR"; exit 2; }

# 3. Work out exactly which packages to upgrade: the host's installed packages of that branch.
broken=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'php*' 'libapache2-mod-php*' 2>/dev/null | awk '$1!="ii" && $1!="un" && $1!="rc" {print $2"("$1")"}' | tr '\n' ' ')
[ -z "$broken" ] || echo "   note: dpkg has unfinished php packages: $broken(this upgrade configures them)"
pk=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${source:Package}\n' 'php*' 'libapache2-mod-php*' 'libphp*' 2>/dev/null | awk -v src="$PHP" '$1 ~ /^i/ && $3==src {print $2}')
[ -n "$pk" ] || { echo "!! no $PHP packages installed here"; exit 2; }
echo "   apt-get check before: $(apt-get check >/dev/null 2>&1 && echo OK || echo BROKEN)"
# <branch>-dev is REMOVED, not upgraded. A host may carry one force-installed from another
# distribution (Debian 11's, say, to compile a PECL extension) whose dependencies apt cannot meet,
# which leaves apt refusing every transaction. It has no runtime role. Reinstall it from this
# bundle (with libpcre2-dev) if a PECL build is needed again.
rmdev=""
if echo "$pk" | grep -qx "$PHP-dev"; then
  pk=$(echo "$pk" | grep -vx "$PHP-dev"); rmdev="$PHP-dev-"
  echo "   $PHP-dev $(dpkg-query -W -f='${Version}' "$PHP-dev") will be removed (build headers only)"
fi
files=""; missing=""
for p in $pk; do f=$(ls debs/"${p}"_*.deb 2>/dev/null | head -1); [ -n "$f" ] && files="$files ./$f" || missing="$missing $p"; done
[ -z "$missing" ] || { echo "!! the bundle has no package for:$missing (partial upgrade refused)"; exit 2; }
# php-common only if the host's is older than the new packages need (a PPA host's usually is not).
need=$(dpkg-deb -f "debs/$common" Depends | tr ',' '\n' | sed -n 's/^ *php-common (>= *\([^)]*\)) *$/\1/p' | head -1)
[ -n "$need" ] || { echo "!! cannot read the php-common version $common needs"; exit 2; }
if ! dpkg --compare-versions "$(dpkg-query -W -f='${Version}' php-common 2>/dev/null || echo 0)" ge "$need"; then
  files="$files ./$(ls debs/php-common_*.deb)"; echo "   php-common is older than $need, including it"
fi
have=$(dpkg-query -W -f='${Version}' "$PHP-common")
# These bundles replace the PPA's (or packages.sury.org's) builds. A series' own PHP, such as focal's
# php7.4 7.4.3-4ubuntu2.x, is a different supplier's: Ubuntu fixes it (USN-8948-2, through Ubuntu
# Pro), and switching it to 7.4.33 is not a security update.
if echo "$have" | grep -qE -- '-[0-9.]+ubuntu[0-9]'; then
  echo "!! $PHP-common $have is Ubuntu's own build, not the PPA's; refusing to replace it (Ubuntu ships its fix)"; exit 2
fi
echo "== $PHP-common $have -> $new | upgrading $(echo $files | wc -w | tr -d ' ') packages"

# 4. Dry run, and refuse anything beyond those packages.
fail=0
sim=$(apt-get -s install --no-install-recommends "${OPTS[@]}" $files $rmdev 2>&1)
echo "== $(echo "$sim" | grep -E 'upgraded,')"
unexpected_rm=$(echo "$sim" | awk '/^Remv/{print $2}' | grep -vx "$PHP-dev" | tr '\n' ' ')
if [ -n "$unexpected_rm" ]; then echo "!! would REMOVE: $unexpected_rm"; fail=1; fi
if echo "$sim" | grep -qE '^E:'; then
  # apt names the unsatisfied package in the block above the E: line; print it, not just the summary.
  blk=$(echo "$sim" | sed -n '/unmet dependencies/,$p' | grep -vE '^(Inst|Conf|Remv) ' | head -40)
  [ -n "$blk" ] || blk=$(echo "$sim" | grep -vE '^(Inst|Conf|Remv) ' | tail -20)
  echo "$blk" | sed 's/^/!! /'; fail=1
fi
extra=$(echo "$sim" | awk '/^Inst/{print $2}' | grep -vxF "$(echo $pk php-common | tr ' ' '\n')" | tr '\n' ' ')
[ -z "$extra" ] || { echo "!! would also change: $extra"; fail=1; }
[ "$fail" = 0 ] || { echo "!! ABORTED, nothing installed"; exit 2; }
[ "$MODE" = apply ] || { echo "== simulate only, nothing installed"; exit 0; }

# 5. Install, then make sure FPM and Apache run the new code.
apt-get install -y -q --no-install-recommends "${OPTS[@]}" $files $rmdev > "$W/install.log" 2>&1 \
  || { echo "!! install failed:"; tail -15 "$W/install.log"; exit 3; }
grep -E "Configuration file|Keeping old|Replacing config" "$W/install.log" | sed 's/^/   dpkg: /'
rc=0
if apt-get check >/dev/null 2>&1; then
  # apt works again, so unattended-upgrades will resume at its next daily run with whatever has queued up.
  echo "== apt-get check after: OK | upgrades now pending for unattended-upgrades: $(apt-get -s upgrade 2>/dev/null | grep -c '^Inst')"
else
  echo "!! apt-get check after: still BROKEN"; rc=1
fi
now=$(dpkg-query -W -f='${Version}' "$PHP-common")
dpkg --compare-versions "$now" ge "$FLOOR" && s=PATCHED || { s="STILL OLD"; rc=1; }
echo "== $PHP-common $now $s (fix floor $FLOOR)"
if echo "$pk" | grep -qx "$PHP-fpm"; then
  fpm=$PHP-fpm
  mp=$(systemctl show -p MainPID --value "$fpm"); exe=$(readlink "/proc/$mp/exe" 2>/dev/null)
  case "$exe" in *deleted*) echo "== $fpm still on the old binary, restarting"; systemctl restart "$fpm"; sleep 2;; esac
  mp=$(systemctl show -p MainPID --value "$fpm"); exe=$(readlink "/proc/$mp/exe" 2>/dev/null)
  case "$exe" in *deleted*) rc=1;; esac
  [ "$(systemctl is-active "$fpm")" = active ] || rc=1
  echo "== $fpm $(systemctl is-active "$fpm") | binary ${exe:-?} | stopgap lines in pool.d: $(cat /etc/php/"$BRANCH"/fpm/pool.d/*.conf 2>/dev/null | grep -c 'upload_progress.enabled\] = off')"
fi
if echo "$pk" | grep -qx "libapache2-mod-$PHP"; then
  if [ "$(systemctl is-active apache2 2>/dev/null)" = active ]; then
    # A graceful reload makes Apache load the new module; requests in flight finish first.
    [ -z "$(apache_stale)" ] || { echo "== apache2 still maps the old mod_php, reloading"; systemctl reload apache2; sleep 3; }
    if [ -n "$(apache_stale)" ]; then echo "!! apache2 processes $(apache_stale | tr '\n' ' ')still run the old mod_php: restart apache2"; rc=1; fi
    echo "== apache2 $(systemctl is-active apache2) | mod_php: $([ -z "$(apache_stale)" ] && echo new || echo OLD)"
  else
    echo "   apache2 is not running; it loads the new mod_php when it starts"
  fi
fi
echo "== CLI loads: $("$PHP" -m 2>&1 | grep -ciE 'warning|unable to load') startup warnings | mongodb $("$PHP" -r 'echo phpversion("mongodb") ?: "not loaded";' 2>/dev/null)"
stale=$(for p in $(pgrep php); do readlink "/proc/$p/exe" 2>/dev/null | grep -q deleted && ps -o args= -p "$p" | cut -c1-70; done | sort | uniq -c)
[ -z "$stale" ] || { echo "   long-running PHP processes still on the old binary (restart Horizon/supervisor programs):"; echo "$stale" | sed 's/^/     /'; }
sleep 5
echo "== http after: $(http_codes)"
n=$(awk -v t="$t0" '($1" "$2) >= t' /var/log/nginx/error.log 2>/dev/null | grep -cE 'connect\(\) to unix|upstream prematurely|no live upstreams')
echo "== nginx error.log since start: $n upstream errors"
exit $rc
