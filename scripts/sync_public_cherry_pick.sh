#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/sync_public_cherry_pick.sh [options] <commit> [<commit> ...]

Options:
  --public-dir PATH   Public repository checkout.
                      Default: $TIINGO_PUBLIC_REPO_DIR, then ../public/TiingoJulia
  --branch NAME       Public repository branch to update. Default: main
  --push              Push to the public repository after checks pass.
  --no-pull           Skip pull --ff-only before cherry-picking.
  -h, --help          Show this help.

Examples:
  bash scripts/sync_public_cherry_pick.sh abc1234
  bash scripts/sync_public_cherry_pick.sh --push abc1234 def5678
  TIINGO_PUBLIC_REPO_DIR=/path/to/public/TiingoJulia bash scripts/sync_public_cherry_pick.sh --push HEAD
EOF
}

fail() {
    if [[ "${rollback_on_failure:-false}" == "true" && -n "${original_public_head:-}" ]]; then
        printf 'Rolling public repo back to %s\n' "$original_public_head" >&2
        git -C "$public_dir" reset --hard "$original_public_head" >/dev/null 2>&1 || true
    fi
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

private_root="$(git rev-parse --show-toplevel)"
default_public_dir="$(cd "$private_root/.." && pwd)/public/TiingoJulia"
public_dir="${TIINGO_PUBLIC_REPO_DIR:-$default_public_dir}"
branch="main"
push_after=false
pull_before=true
rollback_on_failure=false
original_public_head=""
commits=()

while (($#)); do
    case "$1" in
        --public-dir)
            shift
            (($#)) || fail "--public-dir requires a path"
            public_dir="$1"
            ;;
        --branch)
            shift
            (($#)) || fail "--branch requires a name"
            branch="$1"
            ;;
        --push)
            push_after=true
            ;;
        --no-pull)
            pull_before=false
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while (($#)); do
                commits+=("$1")
                shift
            done
            break
            ;;
        -*)
            fail "Unknown option: $1"
            ;;
        *)
            commits+=("$1")
            ;;
    esac
    shift
done

((${#commits[@]})) || {
    usage
    exit 64
}

[[ -d "$public_dir/.git" ]] || fail "Public repository not found: $public_dir"

private_status="$(git -C "$private_root" status --porcelain --untracked-files=no)"
if [[ -n "$private_status" ]]; then
    fail "Private repository has staged or tracked working-tree changes. Commit or stash first."
fi

public_status="$(git -C "$public_dir" status --porcelain)"
if [[ -n "$public_status" ]]; then
    fail "Public repository is not clean. Commit, stash, or reset it first."
fi

for commit in "${commits[@]}"; do
    git -C "$private_root" rev-parse --verify "$commit^{commit}" >/dev/null ||
        fail "Not a commit in private repository: $commit"
done

info "Using private repo: $private_root"
info "Using public repo:  $public_dir"
info "Target branch:      $branch"

git -C "$public_dir" switch "$branch"

if $pull_before; then
    info "Updating public branch with pull --ff-only"
    git -C "$public_dir" pull --ff-only
fi

original_public_head="$(git -C "$public_dir" rev-parse HEAD)"
rollback_on_failure=true

remote_name="private-local"
if git -C "$public_dir" remote get-url "$remote_name" >/dev/null 2>&1; then
    git -C "$public_dir" remote set-url "$remote_name" "$private_root"
else
    git -C "$public_dir" remote add "$remote_name" "$private_root"
fi

for commit in "${commits[@]}"; do
    resolved="$(git -C "$private_root" rev-parse "$commit^{commit}")"
    info "Fetching private commit $resolved"
    git -C "$public_dir" fetch "$remote_name" "$resolved"

    info "Cherry-picking $resolved into public repo"
    if ! git -C "$public_dir" cherry-pick -x "$resolved"; then
        printf '\nCherry-pick stopped with conflicts.\n' >&2
        printf 'Resolve conflicts in: %s\n' "$public_dir" >&2
        printf 'Then run: git cherry-pick --continue\n' >&2
        printf 'Or abort: git cherry-pick --abort\n' >&2
        exit 1
    fi
done

info "Running public safety scans"
git -C "$public_dir" diff --check

if git -C "$public_dir" ls-files | grep -Eq '(^|/)(\.agents|\.claude|\.codex|AGENTS\.md|CLAUDE\.md)(/|$)'; then
    fail "Public repository contains private agent/Codex/Claude files."
fi

if rg -n --hidden --glob '!/.git/**' \
    'otwn|/Users/|/Volumes/|00_TOKUSENQUANT|10kpw_traefik|QuantScreener|TokusenQuant|private/' \
    "$public_dir"; then
    fail "Public risk scan found private/internal references."
fi

if [[ -f "$public_dir/scripts/ci/validate_release_hygiene.jl" ]]; then
    info "Running release hygiene check"
    git -C "$public_dir" ls-files >/dev/null
    (cd "$public_dir" && julia --project=. scripts/ci/validate_release_hygiene.jl)
fi

info "Public sync checks passed"
rollback_on_failure=false

if $push_after; then
    info "Pushing public branch"
    git -C "$public_dir" push origin "$branch"
else
    printf '\nNot pushed. Review the public repo, then run:\n'
    printf '  git -C %q push origin %q\n' "$public_dir" "$branch"
fi
