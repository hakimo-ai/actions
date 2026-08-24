#!/usr/bin/env bash
# Verifies every SHA-pinned third-party action reference in this repo's
# action.yml files.
#   1. Comment format - every SHA-pinned `uses:` line must carry a trailing
#      `# ...` comment (this repo's documented pinning convention). A pin
#      with no comment - or one the parser below can't recognize - is a
#      hard fail rather than being silently skipped from the count below.
#   2. Existence/version - for a clean `# vX.Y.Z` comment, the SHA must
#      match what that tag resolves to today (this alone also proves the
#      SHA exists - a nonexistent SHA can never equal a real tag SHA, so a
#      separate existence lookup isn't needed for this case). For any other
#      comment (e.g. dtolnay/rust-toolchain's `# v1 (2025-08-23)`, an
#      intentionally floating major-version reference) we fall back to
#      checking the SHA exists at all - but a comment that merely looks
#      like a malformed version tag (e.g. `V2.1.6`, `v2.1.6.`, `2.1.6`) is
#      treated as an error instead of silently accepted as "intentionally
#      floating".
#
# Requires: gh CLI, authenticated (GH_TOKEN env var - the default
# GITHUB_TOKEN in Actions is sufficient for public-repo commit lookups).
set -uo pipefail

fail=0
checked=0

# --- Comment-format guard: every SHA-pinned `uses:` line must have SOME
# trailing comment. Compare all SHA-pinned lines against the stricter
# per-pin parser below actually understands; any gap is a pin the loop
# would otherwise silently skip without a word.
all_pins=$(grep -rnoE 'uses: [A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[a-f0-9]{40}' --include='action.yml' .)
parseable_pins=$(grep -rnoE 'uses: [A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[a-f0-9]{40}[[:space:]]*#[[:space:]]*[^[:space:]].*' --include='action.yml' . | sed -E 's/[[:space:]]*#.*$//')
missing_comment=$(comm -23 <(echo "$all_pins" | sort) <(echo "$parseable_pins" | sort))
if [ -n "$missing_comment" ]; then
  echo "FAIL  SHA-pinned action reference(s) with no (or a malformed) trailing '# vX.Y.Z' comment:"
  echo "$missing_comment" | sed 's/^/      /'
  fail=1
fi

while IFS=$'\t' read -r file line owner_repo sha comment; do
  checked=$((checked + 1))
  loc="$file:$line"

  tag=$(echo "$comment" | grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)

  if [ -n "$tag" ]; then
    # --- Clean vX.Y.Z comment: the tag-match check alone also proves
    # existence - a nonexistent SHA can never equal a real tag SHA. ---
    tag_sha=$(gh api "repos/$owner_repo/commits/$tag" --jq '.sha' 2>/tmp/verify-pins-err || true)
    if [ -z "$tag_sha" ]; then
      echo "FAIL  $loc  $owner_repo@$sha ($comment)"
      echo "      Comment claims tag '$tag' but it doesn't resolve upstream: $(cat /tmp/verify-pins-err | tr -d '\n')"
      fail=1
      continue
    fi
    if [ "$sha" != "$tag_sha" ]; then
      echo "FAIL  $loc  $owner_repo@$sha ($comment)"
      echo "      Pinned SHA does not exist or does not match tag '$tag' - tag currently points to $tag_sha"
      fail=1
      continue
    fi
    echo "OK    $loc  $owner_repo@$sha ($comment)"
    continue
  fi

  # --- Not a clean vX.Y.Z comment. Reject anything that looks like a
  # malformed attempt at one (wrong case, trailing punctuation, missing
  # 'v') instead of silently treating a typo as an intentionally-floating
  # reference. ---
  if echo "$comment" | grep -qEi '^v?[0-9]+(\.[0-9]+){1,2}\.?$'; then
    echo "FAIL  $loc  $owner_repo@$sha ($comment)"
    echo "      Comment looks like a malformed version tag - expected the exact format 'vX.Y.Z'"
    fail=1
    continue
  fi

  # --- Genuinely non-semver comment (e.g. a floating major like
  # dtolnay/rust-toolchain's 'v1 (2025-08-23)') - existence is still
  # checked, version-match doesn't apply. ---
  if ! gh api "repos/$owner_repo/commits/$sha" --jq '.sha' > /dev/null 2>/tmp/verify-pins-err; then
    echo "FAIL  $loc  $owner_repo@$sha ($comment)"
    echo "      SHA does not exist upstream: $(cat /tmp/verify-pins-err | tr -d '\n')"
    fail=1
    continue
  fi

  echo "OK    $loc  $owner_repo@$sha ($comment) - exists (non-semver comment, version-match skipped)"
done < <(
  grep -rnoE 'uses: [A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[a-f0-9]{40}[[:space:]]*#[[:space:]]*[^[:space:]].*' \
    --include='action.yml' . \
  | sed -E 's/^([^:]+):([0-9]+):uses: ([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)@([a-f0-9]{40})[[:space:]]*#[[:space:]]*(.*)$/\1\t\2\t\3\t\4\t\5/'
)

echo ""
echo "Checked $checked pinned action reference(s)."

if [ "$fail" -ne 0 ]; then
  echo "One or more pins failed verification - see FAIL lines above."
  exit 1
fi

echo "All pins verified."
