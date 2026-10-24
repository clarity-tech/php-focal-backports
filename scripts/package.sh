#!/usr/bin/env bash
# Turn dist/<series>-php<branch>-<arch>/ into one release bundle a host can fetch with a single URL:
#   dist/php-backports_<PHP version>_<series>_<arch>.tar      (.debs + SHA256SUMS + BUILDINFO)
#   dist/php-backports_<PHP version>_<series>_<arch>.tar.sha256
# The version is the rebuilt PHP's, without any epoch (lib.sh's bundle_name), so it names the branch.
# Runs anywhere with bash, tar and sha256sum or shasum.
. "$(dirname "$0")/lib.sh"

ls "$DIST_DIR"/*.deb >/dev/null 2>&1 || die "no packages in ${DIST_DIR#"$ROOT"/}: run the build first"
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

name=$(bundle_name)

cd "$DIST_DIR"
sha ./*.deb | sed 's# \./# #' > SHA256SUMS
{
  echo "bundle:        $name"
  echo "built:         $(date -u +%FT%TZ)"
  echo "repo commit:   $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)$(git -C "$ROOT" diff --quiet 2>/dev/null || echo ' (uncommitted changes)')"
  echo "builder image: ${BUILDER_IMAGE:-unknown}"
  echo "target:        Ubuntu $TARGET_VERSION ($TARGET_SERIES) $ARCH"
  echo "php:           $PHP_SOURCE $(target_version_of "$PHP_SOURCE_VERSION"), PHP2Shell fix floor $FIX_FLOOR"
  echo "sources (ppa:$PPA_OWNER/$PPA_NAME, signed by upload key $UPLOAD_KEY_FPR; libraries from ${LIB_SERIES:-none} unless noted, the rest from $SOURCE_SERIES):"
  { each_lib; each_source | sed "s/\$/ $SOURCE_SERIES lib-series-not-applicable/"; } | while read -r n v s x; do
    note=""; [ -n "$x" ] || [ "$s" = "${LIB_SERIES:-}" ] || note=" (the $s upload)"
    echo "  $n $v -> $(target_version_of "$v")$note"
    for f in "$(src_dir_of "$n" "$v")"/*; do echo "    $(sha "$f" | awk '{print $1}')  $(basename "$f")"; done
  done
  echo "packages: $(ls ./*.deb | wc -l | tr -d ' ')"
} > BUILDINFO

cd "$ROOT/dist"
tar -cf "$name.tar" -C "$DIST_DIR" $(cd "$DIST_DIR" && ls ./*.deb | sed 's#^\./##') SHA256SUMS BUILDINFO
sha "$name.tar" | sed 's# .*/# #' > "$name.tar.sha256"
log "dist/$name.tar ($(du -h "$name.tar" | cut -f1), sha256 $(cut -d' ' -f1 "$name.tar.sha256"))"
