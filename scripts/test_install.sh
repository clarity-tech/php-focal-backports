#!/usr/bin/env bash
# Run host/install.sh against the packaged bundle, in simulate mode, on a fresh TARGET_SERIES system
# that has this branch's test packages installed: as close to a host as a container gets. It checks
# that install.sh finds the bundle's branch, fix floor and packages, and that its guards pass when
# the host already has this build, and refuse a wrong checksum. (It cannot try a real upgrade: no
# older build of the branch exists for the series any more.) Runs inside a fresh ubuntu:<series>
# container of the target architecture, after scripts/package.sh.
. "$(dirname "$0")/lib.sh"

. /etc/os-release
[ "$VERSION_CODENAME" = "$TARGET_SERIES" ] || die "running on $VERSION_CODENAME, expected $TARGET_SERIES"
export DEBIAN_FRONTEND=noninteractive
name=$(bundle_name); tar=$ROOT/dist/$name.tar
[ -f "$tar" ] && [ -f "$tar.sha256" ] || die "no dist/$name.tar(.sha256): run scripts/package.sh first"
sha=$(cut -d' ' -f1 "$tar.sha256")

apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl >/dev/null
# The host: the target's test package set, from the bundle itself (nothing else carries it now).
tmp=$(mktemp -d); tar -xf "$tar" -C "$tmp"
debs=""; for p in $TEST_PACKAGES $(for e in $PHP_EXTENSIONS; do printf '%s-%s ' "$PHP_SOURCE" "$e"; done); do
  f=$(ls "$tmp/${p}_"*.deb 2>/dev/null | head -1); [ -n "$f" ] || die "$p is not in the bundle"; debs="$debs $f"
done
apt-get install -y -qq --no-install-recommends $debs > /tmp/install.log 2>&1 || { tail -20 /tmp/install.log; die "install failed"; }
log "host: $(echo $debs | wc -w | tr -d ' ') packages from the bundle installed"

fail=0
if bash "$ROOT/host/install.sh" simulate "file://$tar" "0000$sha" > /tmp/wrong-sha.log 2>&1; then
  echo "   FAIL install.sh accepted a wrong sha256"; fail=1
else
  grep -q 'does not match' /tmp/wrong-sha.log && echo "   PASS install.sh refuses a wrong sha256" || { echo "   FAIL install.sh failed for another reason:"; cat /tmp/wrong-sha.log; fail=1; }
fi
log "install.sh simulate $name.tar"
if bash "$ROOT/host/install.sh" simulate "file://$tar" "$sha" 2>&1 | tee /tmp/simulate.log; then
  grep -q '^== simulate only, nothing installed' /tmp/simulate.log && grep -qF "== $PHP_SOURCE-common " /tmp/simulate.log \
    && echo "   PASS install.sh simulate found $PHP_SOURCE and passed its guards" \
    || { echo "   FAIL install.sh simulate did not report $PHP_SOURCE"; fail=1; }
else
  echo "   FAIL install.sh simulate refused the bundle"; fail=1
fi
[ "$fail" = 0 ] || die "install.sh checks failed"
log "install.sh works with $name.tar on a clean $PRETTY_NAME $(dpkg --print-architecture)"
