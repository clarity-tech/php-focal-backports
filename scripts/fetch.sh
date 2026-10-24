#!/usr/bin/env bash
# Download each pinned source package (.dsc + tarballs) from the PPA into src/<name>/.
# Signature and checksums are verified at build time by `dpkg-source --require-valid-signature`,
# against the committed key in keys/, so a tampered or substituted file fails the build.
# Needs: curl, python3. Runs on the operator's machine or in CI.
. "$(dirname "$0")/lib.sh"

api="https://api.launchpad.net/devel/~$PPA_OWNER/+archive/ubuntu/$PPA_NAME"

# fetch_one <series>: reads "name version" lines on stdin.
fetch_one() {
series="https://api.launchpad.net/devel/ubuntu/$1"
while read -r name version; do
  dest=$SRC_DIR/$name; mkdir -p "$dest"
  # The exact publication of this name+version in that series, whatever its status (Published,
  # Superseded or Deleted), so a pin still resolves after the PPA moves on. A deleted upload's files
  # stay downloadable from Launchpad, and build.sh checks its signature like any other.
  # URL-encode: Debian versions contain `+` and `~`, and a bare `+` in a query string means a space.
  query=$(python3 -I -c 'import sys, urllib.parse as u; print(u.urlencode({"ws.op": "getPublishedSources", "source_name": sys.argv[1], "version": sys.argv[2], "exact_match": "true", "distro_series": sys.argv[3]}))' "$name" "$version" "$series")
  pub=$(curl -fsS -m 60 "$api?$query" \
        | python3 -I -c 'import json,sys; e=json.load(sys.stdin)["entries"]; print(e[0]["self_link"] if e else "")')
  [ -n "$pub" ] || die "$name $version was never published in ppa:$PPA_OWNER/$PPA_NAME for $1"
  urls=$(curl -fsS -m 60 "$pub?ws.op=sourceFileUrls" | python3 -I -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')
  [ -n "$urls" ] || die "no source files listed for $name $version (removed from the PPA?)"
  log "$name $version"
  for u in $urls; do
    f=$(basename "$u" | sed 's/%2B/+/g; s/%7E/~/g')
    if [ -s "$dest/$f" ]; then echo "   have $f"; continue; fi
    curl -fsSL -m 600 -o "$dest/$f.part" "$u" && mv "$dest/$f.part" "$dest/$f"
    echo "   got  $f ($(wc -c < "$dest/$f" | tr -d ' ') bytes)"
  done
done
}

each_lib | fetch_one "${LIB_SERIES:-$SOURCE_SERIES}"
each_source | fetch_one "$SOURCE_SERIES"
