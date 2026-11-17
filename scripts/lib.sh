# Shared by the DXVK build and patch scripts. Source it, do not run it.

dxvk_upstream_url="https://github.com/doitsujin/dxvk.git"

# The DXVK commit the dxvk submodule pins: the superproject's record, not what
# dxvk/ happens to have checked out.
pinned_dxvk_commit() { git -C "$1" ls-files -s dxvk | awk '{ print $2 }'; }

# Prints the commit a DXVK commit, tag or branch names, in the clone in the
# current directory. Commits and tags already here are used as they are. A
# branch always comes from upstream, since a local one can be any age.
resolve_dxvk_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]] && git rev-parse -q --verify "$ref^{commit}" 2>/dev/null; then return; fi
  if git rev-parse -q --verify "refs/tags/$ref^{commit}" 2>/dev/null; then return; fi
  if ! git fetch -q --tags "$dxvk_upstream_url" '+refs/heads/*:refs/remotes/upstream/*' 2>/dev/null; then
    echo "Cannot reach $dxvk_upstream_url to look up DXVK '$ref'." >&2
    return 1
  fi
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && git fetch -q "$dxvk_upstream_url" "$ref" 2>/dev/null
  git rev-parse -q --verify "refs/remotes/upstream/$ref^{commit}" 2>/dev/null \
    || git rev-parse -q --verify "refs/tags/$ref^{commit}" 2>/dev/null \
    || git rev-parse -q --verify "$ref^{commit}" 2>/dev/null \
    || { echo "DXVK has no commit, tag or branch '$ref'." >&2; return 1; }
}

# Writes the DXVK patches of a GE-Proton or proton-cachyos release into DIR as 01.patch, 02.patch, ...
# in the order its own build applies them, and the DXVK commit it pins as DIR/commit.
fetch_variant_patches() {  # VARIANT DIR
  local variant="$1" out="$2" url list="" src n=0 path
  case "$variant" in
    GE-Proton*) url="https://github.com/GloriousEggroll/proton-ge-custom.git" ;;
    cachyos-*) url="https://github.com/CachyOS/proton-cachyos.git" ;;
    *) return 1 ;;
  esac
  src="$(mktemp -d)"
  git clone -q --depth 1 --filter=blob:none --sparse --branch "$variant" "$url" "$src" 2>/dev/null \
    && git -C "$src" sparse-checkout set patches/dxvk || { rm -rf "$src"; return 1; }
  if [[ "$variant" == GE-Proton* ]]; then
    # GE lists its patches by hand, between `pushd dxvk` and the next `popd`.
    list="$(sed -n '/^ *pushd dxvk$/,/^ *popd$/p' "$src/patches/protonprep-valve-staging.sh" 2>/dev/null \
      | grep -v '^ *#' | grep -o 'patches/dxvk/[^" ]*\.patch' || true)"
  elif [[ -d "$src/patches/dxvk" ]]; then
    list="$(cd "$src" && find patches/dxvk -name '*.patch' | sort)"
  fi
  rm -rf "$out" && mkdir -p "$out"
  git -C "$src" ls-tree HEAD dxvk | awk '{ print $3 }' > "$out/commit"
  # A release may patch nothing in DXVK, so there may be no list at all.
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    n=$((n + 1))
    cp "$src/$path" "$out/$(printf '%02d' "$n").patch"
  done <<<"$list"
  rm -rf "$src"
}

# Applies the patches fetch_variant_patches wrote to DIR to the checkout in the
# current directory, and commits the result, even when there were none.
apply_variant_patches() {  # DIR VARIANT
  local patch
  for patch in "$1"/*.patch; do
    [[ -e "$patch" ]] || continue
    patch -s -Np1 --no-backup-if-mismatch -i "$patch" >/dev/null || {
      echo "The DXVK patch $(basename "$patch") of $2 does not apply." >&2
      return 1
    }
  done
  git add -A
  git -c user.name="$GIT_COMMITTER_NAME" -c user.email="$GIT_COMMITTER_EMAIL" \
    commit -q --allow-empty --date="${GIT_COMMITTER_DATE:-now}" -m "DXVK patches of $2"
}

# Newest release tag of a variant: latest_variant 'GE-Proton*' or 'cachyos-*-slr'.
latest_variant() {
  local url="https://github.com/GloriousEggroll/proton-ge-custom.git"
  [[ "$1" == cachyos-* ]] && url="https://github.com/CachyOS/proton-cachyos.git"
  git ls-remote --tags --refs --sort=-v:refname "$url" "$1" | head -n1 | sed 's|.*refs/tags/||'
}
