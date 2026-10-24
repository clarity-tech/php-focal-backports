#!/usr/bin/env bash
# Download each pinned source package (.dsc + tarballs) from the PPA into src/<name>/<version>/.
# Signature and checksums are verified at build time by `dpkg-source --require-valid-signature`,
# against the committed key in keys/, so a tampered or substituted file fails the build.
# Needs: curl, python3. Runs on the operator's machine or in CI.
. "$(dirname "$0")/lib.sh"

api="https://api.launchpad.net/devel/~$PPA_OWNER/+archive/ubuntu/$PPA_NAME"

# fetch_one: reads "name version series" lines on stdin.
fetch_one() {
while read -r name version series_name; do
  series="https://api.launchpad.net/devel/ubuntu/$series_name"
  dest=$(src_dir_of "$name" "$version"); mkdir -p "$dest"
  # The exact publication of this name+version in that series, whatever its status (Published,
  # Superseded or Deleted), so a pin still resolves after the PPA moves on. A deleted upload's files
  # stay downloadable from Launchpad, and build.sh checks its signature like any other.
  # URL-encode: Debian versions contain `+` and `~`, and a bare `+` in a query string means a space.
  query=$(python3 -I -c 'import sys, urllib.parse as u; print(u.urlencode({"ws.op": "getPublishedSources", "source_name": sys.argv[1], "version": sys.argv[2], "exact_match": "true", "distro_series": sys.argv[3]}))' "$name" "$version" "$series")
  pub=$(curl -fsS -m 60 --retry 3 "$api?$query" \
        | python3 -I -c 'import json,sys; e=json.load(sys.stdin)["entries"]; print(e[0]["self_link"] if e else "")')
  [ -n "$pub" ] || die "$name $version was never published in ppa:$PPA_OWNER/$PPA_NAME for $series_name"
  urls=$(curl -fsS -m 60 --retry 3 "$pub?ws.op=sourceFileUrls" | python3 -I -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')
  [ -n "$urls" ] || die "no source files listed for $name $version (removed from the PPA?)"
  log "$name $version ($series_name)"
  for u in $urls; do
    f=$(basename "$u" | sed 's/%2B/+/g; s/%7E/~/g')
    if [ -s "$dest/$f" ]; then echo "   have $f"; continue; fi
    curl -fsSL -m 600 --retry 3 -o "$dest/$f.part" "$u" && mv "$dest/$f.part" "$dest/$f"
    echo "   got  $f ($(wc -c < "$dest/$f" | tr -d ' ') bytes)"
  done
done
}

each_lib | fetch_one
each_source | sed "s/\$/ $SOURCE_SERIES/" | fetch_one
