#!/usr/bin/env bash
# Upgrade a host's php8.1 packages from a release bundle. Runs ON the host, as root.
#   bash install.sh simulate|apply <bundle URL> <bundle sha256>
# The URL is normally a pre-signed S3 URL from scripts/upload.sh --presign.
#
# Guarded: nothing is installed unless the bundle's checksum matches, every file inside matches
# SHA256SUMS, and apt's dry run shows that only the host's existing php8.1 packages change, with
# nothing removed. Modified config files are kept (the PHP2Shell stopgap lines in pool.d, php.ini
# edits such as post_max_size). Separately built extensions (mongodb, redis, igbinary, msgpack,
# opentelemetry) are not touched: they depend on the PHP API version, which an 8.1.x update keeps.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1
MODE=${1:-}; URL=${2:-}; WANT_SHA=${3:-}
case "$MODE" in simulate|apply) ;; *) echo "usage: $0 simulate|apply <bundle URL> <bundle sha256>"; exit 1;; esac
[ -n "$URL" ] && [ -n "$WANT_SHA" ] || { echo "usage: $0 simulate|apply <bundle URL> <bundle sha256>"; exit 1; }
FLOOR=8.1.34-9
OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
W=/root/php-backports; mkdir -p "$W"; cd "$W" || exit 1

http_codes() {
  for n in $(grep -rhoE '^[[:space:]]*server_name[[:space:]]+[^;]+' /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
             | awk '{for (i=2;i<=NF;i++) print $i}' | grep -vE '^(_|example\.com|www\..*)$' | sort -u | head -3); do
    printf '%s=%s ' "$n" "$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $n" http://127.0.0.1/)"
  done
}
t0=$(date -u +'%Y/%m/%d %H:%M:%S')
echo "== $(hostname) $(date -u +%FT%TZ) mode=$MODE | $(. /etc/os-release; echo "$PRETTY_NAME") $(dpkg --print-architecture) | http before: $(http_codes)"

# 1. Fetch and verify the bundle.
curl -fsSL -m 600 -o bundle.tar "$URL" || { echo "!! download failed"; exit 2; }
got=$(sha256sum bundle.tar | cut -d' ' -f1)
[ "$got" = "$WANT_SHA" ] || { echo "!! bundle sha256 $got does not match the expected $WANT_SHA"; exit 2; }
# --warning: bundles packed on macOS carry Apple xattr headers that GNU tar warns about, harmlessly.
rm -rf debs && mkdir debs && tar --warning=no-unknown-keyword -xf bundle.tar -C debs
(cd debs && sha256sum --quiet -c SHA256SUMS) || { echo "!! a package inside the bundle fails SHA256SUMS"; exit 2; }
grep -E '^(bundle|target|built):' debs/BUILDINFO | sed 's/^/   /'
[ "$(dpkg --print-architecture)" = "$(awk '/^target:/{print $NF}' debs/BUILDINFO)" ] || { echo "!! bundle is for another architecture"; exit 2; }

# 2. Work out exactly which packages to upgrade: the host's installed php8.1-source packages.
broken=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'php*' | awk '$1!="ii" && $1!="un" && $1!="rc" {print $2"("$1")"}' | tr '\n' ' ')
[ -z "$broken" ] || echo "   note: dpkg has unfinished php packages: $broken(this upgrade configures them)"
pk=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${source:Package}\n' 'php*' | awk '$1 ~ /^i/ && $3=="php8.1" {print $2}')
[ -n "$pk" ] || { echo "!! no php8.1 packages installed here"; exit 2; }
echo "   apt-get check before: $(apt-get check >/dev/null 2>&1 && echo OK || echo BROKEN)"
# php8.1-dev is REMOVED, not upgraded. A host may carry one force-installed from another
# distribution (Debian 11's, say, to compile a PECL extension) whose dependencies apt cannot meet,
# which leaves apt refusing every transaction. It has no runtime role. Reinstall it from this
# bundle (with libpcre2-dev) if a PECL build is needed again.
rmdev=""
if echo "$pk" | grep -qx php8.1-dev; then
  pk=$(echo "$pk" | grep -vx php8.1-dev); rmdev="php8.1-dev-"
  echo "   php8.1-dev $(dpkg-query -W -f='${Version}' php8.1-dev) will be removed (build headers only)"
fi
files=""; missing=""
for p in $pk; do f=$(ls debs/"${p}"_*.deb 2>/dev/null | head -1); [ -n "$f" ] && files="$files ./$f" || missing="$missing $p"; done
[ -z "$missing" ] || { echo "!! the bundle has no package for:$missing (partial upgrade refused)"; exit 2; }
# php-common only if the host's is too old for the new packages (a PPA host's 2:93 is fine).
if ! dpkg --compare-versions "$(dpkg-query -W -f='${Version}' php-common 2>/dev/null || echo 0)" ge 1:81~; then
  files="$files ./$(ls debs/php-common_*.deb)"; echo "   php-common is older than 1:81~, including it"
fi
have=$(dpkg-query -W -f='${Version}' php8.1-common)
echo "== php8.1-common $have -> $(dpkg-deb -f debs/php8.1-common_*.deb Version) | upgrading $(echo $files | wc -w | tr -d ' ') packages"

# 3. Dry run, and refuse anything beyond those packages.
fail=0
sim=$(apt-get -s install --no-install-recommends "${OPTS[@]}" $files $rmdev 2>&1)
echo "== $(echo "$sim" | grep -E 'upgraded,')"
unexpected_rm=$(echo "$sim" | awk '/^Remv/{print $2}' | grep -vx php8.1-dev | tr '\n' ' ')
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

# 4. Install, then make sure FPM runs the new binary.
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
mp=$(systemctl show -p MainPID --value php8.1-fpm); exe=$(readlink /proc/$mp/exe 2>/dev/null)
case "$exe" in *deleted*) echo "== php8.1-fpm still on the old binary, restarting"; systemctl restart php8.1-fpm; sleep 2;; esac
mp=$(systemctl show -p MainPID --value php8.1-fpm); exe=$(readlink /proc/$mp/exe 2>/dev/null)
now=$(dpkg-query -W -f='${Version}' php8.1-common)
dpkg --compare-versions "$now" ge "$FLOOR" && s=PATCHED || { s="STILL OLD"; rc=1; }
[ "$(systemctl is-active php8.1-fpm)" = active ] || rc=1
echo "== php8.1-fpm $now $s | $(systemctl is-active php8.1-fpm) | binary ${exe:-?} | stopgap lines in pool.d: $(cat /etc/php/8.1/fpm/pool.d/*.conf | grep -c 'upload_progress.enabled\] = off')"
echo "== CLI loads: $(php8.1 -m 2>&1 | grep -ciE 'warning|unable to load') startup warnings | mongodb $(php8.1 -r 'echo phpversion("mongodb") ?: "not loaded";')"
stale=$(for p in $(pgrep php); do readlink /proc/$p/exe 2>/dev/null | grep -q deleted && ps -o args= -p "$p" | cut -c1-70; done | sort | uniq -c)
[ -z "$stale" ] || { echo "   long-running PHP processes still on the old binary (restart Horizon/supervisor programs):"; echo "$stale" | sed 's/^/     /'; }
sleep 5
echo "== http after: $(http_codes)"
n=$(awk -v t="$t0" '($1" "$2) >= t' /var/log/nginx/error.log 2>/dev/null | grep -cE 'connect\(\) to unix|upstream prematurely|no live upstreams')
echo "== nginx error.log since start: $n upstream errors"
exit $rc
