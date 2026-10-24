#!/usr/bin/env bash
# One-time AWS setup for uploads from CI. Run by whoever administers the account.
#   bash aws/setup.sh            dry run: prints every call, changes nothing
#   bash aws/setup.sh --apply    creates the bucket and the CI role
#
# Creates:
#   - S3 bucket $S3_BUCKET (config.env): private, public access blocked, SSE-S3, objects expire
#     after 60 days. It is temporary, for the current PHP2Shell patches.
#   - IAM role gitlab-ci-php-focal-backports. Only this project's `main` branch can assume it,
#     through the account's existing gitlab.com OIDC provider. It may only PutObject under
#     s3://$S3_BUCKET/$S3_PREFIX/.
# Needs GITLAB_PROJECT_PATH (group/project) and, in config.env or the environment, S3_BUCKET and
# AWS_REGION_NAME.
. "$(dirname "$0")/../scripts/lib.sh"

ROLE=gitlab-ci-php-focal-backports
PROJECT=${GITLAB_PROJECT_PATH:?set GITLAB_PROJECT_PATH to the GitLab group/project that may upload}
[ -n "$S3_BUCKET" ] || die "set S3_BUCKET in config.env first"
[ -n "$AWS_REGION_NAME" ] || die "set AWS_REGION_NAME in config.env first"
apply=0; [ "${1:-}" = --apply ] && apply=1
A=(); [ -n "${AWS_PROFILE_NAME:-}" ] && A=(--profile "$AWS_PROFILE_NAME")
run() { if [ "$apply" = 1 ]; then echo "+ ${*:0:6} ..."; "$@"; else echo "would run: $*"; fi; }

acct=$(aws sts get-caller-identity "${A[@]}" --query Account --output text)
provider="arn:aws:iam::$acct:oidc-provider/gitlab.com"
aws iam get-open-id-connect-provider "${A[@]}" --open-id-connect-provider-arn "$provider" >/dev/null \
  || die "no gitlab.com OIDC provider in this account (expected $provider)"
tmp=$(mktemp -d)

cat > "$tmp/trust.json" <<JSON
{"Version": "2012-10-17", "Statement": [{
  "Effect": "Allow",
  "Principal": {"Federated": "$provider"},
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {"gitlab.com:aud": "https://gitlab.com"},
    "StringLike": {"gitlab.com:sub": "project_path:$PROJECT:ref_type:branch:ref:main"}
  }}]}
JSON
cat > "$tmp/upload.json" <<JSON
{"Version": "2012-10-17", "Statement": [{
  "Sid": "UploadReleaseBundles",
  "Effect": "Allow",
  "Action": "s3:PutObject",
  "Resource": "arn:aws:s3:::$S3_BUCKET/$S3_PREFIX/*"}]}
JSON
cat > "$tmp/lifecycle.json" <<JSON
{"Rules": [{"ID": "temporary-bucket", "Status": "Enabled", "Filter": {},
  "Expiration": {"Days": 60}, "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1}}]}
JSON

log "bucket s3://$S3_BUCKET ($AWS_REGION_NAME)"
run aws s3api create-bucket "${A[@]}" --region "$AWS_REGION_NAME" --bucket "$S3_BUCKET" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION_NAME"
run aws s3api put-public-access-block "${A[@]}" --bucket "$S3_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
run aws s3api put-bucket-encryption "${A[@]}" --bucket "$S3_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
run aws s3api put-bucket-lifecycle-configuration "${A[@]}" --bucket "$S3_BUCKET" --lifecycle-configuration "file://$tmp/lifecycle.json"
run aws s3api put-bucket-tagging "${A[@]}" --bucket "$S3_BUCKET" \
  --tagging 'TagSet=[{Key=Purpose,Value=php2shell-focal-patches},{Key=Temporary,Value=true},{Key=Project,Value=php-focal-backports}]'

log "role $ROLE (trusts $PROJECT main via the gitlab.com OIDC provider)"
run aws iam create-role "${A[@]}" --role-name "$ROLE" --assume-role-policy-document "file://$tmp/trust.json" \
  --max-session-duration 3600 --description "GitLab CI upload for $PROJECT (main only)" \
  --tags Key=Project,Value=php-focal-backports Key=Temporary,Value=true
run aws iam put-role-policy "${A[@]}" --role-name "$ROLE" --policy-name upload-release-bundles \
  --policy-document "file://$tmp/upload.json"

[ "$apply" = 1 ] || { echo; echo "--- trust policy ---"; cat "$tmp/trust.json"; echo "--- permissions ---"; cat "$tmp/upload.json"; }
rm -rf "$tmp"
log "role ARN for .gitlab-ci.yml: arn:aws:iam::<this account>:role/$ROLE"
