#!/usr/bin/env bash
# Upload the release bundle to S3, and print a pre-signed URL a host can download it with.
#   scripts/upload.sh                     dry run: shows what would be uploaded where
#   scripts/upload.sh --apply             uploads (needs s3:PutObject on S3_BUCKET)
#   scripts/upload.sh --presign [secs]    prints a pre-signed GET URL for the uploaded bundle (default 3600)
# The bucket stays private: hosts never need IAM access to it, only the pre-signed URL.
. "$(dirname "$0")/lib.sh"

[ -n "$S3_BUCKET" ] || die "S3_BUCKET is not set (config.env, or the environment)"
[ -n "$AWS_REGION_NAME" ] || die "AWS_REGION_NAME is not set (config.env, or the environment)"
name=$(bundle_name)
key="$S3_PREFIX/$PHP_SOURCE/$(noepoch "$(target_version_of "$PHP_SOURCE_VERSION")")/$name.tar"
aws_args=(--region "$AWS_REGION_NAME")
[ -n "${AWS_PROFILE_NAME:-}" ] && aws_args+=(--profile "$AWS_PROFILE_NAME")

case "${1:-}" in
  --apply)
    [ -f "$ROOT/dist/$name.tar" ] || die "dist/$name.tar not found: run scripts/package.sh"
    # Never replace a published bundle. Builds are not byte-reproducible, so a second build of the
    # same version has a different sha256, and replacing the object would break every install
    # command, pre-signed URL and record that names the first one (a host may run a local build,
    # not CI's). Bump LOCAL_TAG instead.
    if aws s3api head-object "${aws_args[@]}" --bucket "$S3_BUCKET" --key "$key" >/dev/null 2>&1; then
      die "s3://$S3_BUCKET/$key already exists; refusing to replace it (bump LOCAL_TAG for a new build)"
    fi
    aws s3 cp "${aws_args[@]}" --sse AES256 "$ROOT/dist/$name.tar" "s3://$S3_BUCKET/$key"
    aws s3 cp "${aws_args[@]}" --sse AES256 "$ROOT/dist/$name.tar.sha256" "s3://$S3_BUCKET/$key.sha256"
    log "uploaded s3://$S3_BUCKET/$key (+ .sha256)" ;;
  --presign)
    url=$(aws s3 presign "${aws_args[@]}" "s3://$S3_BUCKET/$key" --expires-in "${2:-3600}")
    echo "sha256: $(cut -d' ' -f1 "$ROOT/dist/$name.tar.sha256" 2>/dev/null || echo 'see the .sha256 object')"
    echo "url:    $url" ;;
  *)
    echo "dry run, nothing uploaded. Would put:"
    echo "  dist/$name.tar        -> s3://$S3_BUCKET/$key"
    echo "  dist/$name.tar.sha256 -> s3://$S3_BUCKET/$key.sha256"
    echo "re-run with --apply to upload, then --presign for a download URL" ;;
esac
