#!/usr/bin/env bash
# Replace the template's placeholder name with the real service name, in place.
#
#   scripts/rename.sh <service-name>    e.g. scripts/rename.sh repo-jobs-rs
#
# --self-contained-ci is accepted for backwards compatibility and changes nothing: the
# template's only CI, .github/workflows/ci-public.yml, already runs on GitHub-hosted runners
# with no repository secrets.
#
# The placeholder token is `template-rust-service` (crate, binary, image name) and its snake
# form `template_rust_service` (Rust library identifier). The name must be lowercase kebab
# case: [a-z][a-z0-9-]*, so it is valid as a crate, a docker image and a k8s name.
# Run once, right after copying the template, then commit. Idempotent: a second run finds
# nothing to replace.
set -euo pipefail

usage() {
  echo "usage: $0 <service-name> [--self-contained-ci]   (lowercase kebab case, e.g. repo-jobs-rs)" >&2
  exit 2
}
name=""
self_contained=0
for arg in "$@"; do
  case "$arg" in
    --self-contained-ci) self_contained=1 ;;
    -*) usage ;;
    *) [[ -z "$name" ]] || usage; name="$arg" ;;
  esac
done
if [[ ! "$name" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
  usage
fi
snake="${name//-/_}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# CI: nothing to swap. .github/workflows/ci-public.yml is the only workflow and needs no
# secrets. The flag is kept so existing callers do not break.
if [[ "$self_contained" == 1 ]]; then
  echo "ci: GitHub-hosted (.github/workflows/ci-public.yml) — no change"
fi

# Every tracked text file except this script (git ls-files keeps target/ and .git out).
# (while-read, not mapfile: macOS ships bash 3.2.)
files=()
while IFS= read -r f; do files+=("$f"); done < <(git ls-files | grep -v '^scripts/rename.sh$')
changed=0
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  grep -Iq . "$f" 2>/dev/null || continue   # skip binary/empty files
  if sed 's#nonagenticai/template-rust-service##g' "$f" | grep -q -e 'template-rust-service' -e 'template_rust_service'; then
    tmp="$(mktemp)"
    # References to the template repo itself (nonagenticai/template-rust-service) are kept.
    sed -e "s#nonagenticai/template-rust-service#@@TEMPLATE_REPO@@#g" \
        -e "s/template-rust-service/${name}/g" -e "s/template_rust_service/${snake}/g" \
        -e "s#@@TEMPLATE_REPO@@#nonagenticai/template-rust-service#g" "$f" > "$tmp"
    cat "$tmp" > "$f"   # keep the file's mode
    rm -f "$tmp"
    changed=$((changed + 1))
  fi
done

if sed 's#nonagenticai/template-rust-service##g' "${files[@]}" 2>/dev/null \
    | grep -q -e 'template-rust-service' -e 'template_rust_service'; then
  echo "error: placeholder still present after rename" >&2
  exit 1
fi
echo "renamed to ${name} (${snake}) in ${changed} file(s)"

# Cargo.lock: the sed above renamed the root package's [[package]] entry in place, but cargo
# keeps packages sorted by name (then version), so left there the first cargo run rewrites
# the lock and `cargo ... --locked` fails. Move the root entry to its sorted position.
# Deterministic, stdlib only; a no-op when it is already in place (idempotent re-run).
if [[ -f Cargo.lock ]]; then
  python3 - "$name" Cargo.lock <<'PY'
import sys
name, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
lines = text.splitlines(keepends=True)
# Split into: preamble (before the first [[package]]), package blocks, trailer (first
# non-[[package]] table header after them, e.g. [metadata] in old lock versions).
starts = [i for i, l in enumerate(lines) if l.rstrip("\n") == "[[package]]"]
if not starts:
    sys.exit("error: Cargo.lock has no [[package]] entries")
end = len(lines)
for i in range(starts[-1] + 1, len(lines)):
    if lines[i].startswith("[") and lines[i].rstrip("\n") != "[[package]]":
        end = i
        break
pre, trailer = lines[: starts[0]], lines[end:]
bounds = starts + [end]
blocks = [lines[bounds[k] : bounds[k + 1]] for k in range(len(starts))]

def field(block, key):
    for l in block:
        if l.startswith(key + " = "):
            return l.split(" = ", 1)[1].strip().strip('"')
    return None

# Every block ends with its trailing blank separator line except, possibly, the last one.
def norm(block):
    b = [l if l.endswith("\n") else l + "\n" for l in block]
    while b and b[-1].strip() == "":
        b.pop()
    return b

root = [k for k, b in enumerate(blocks) if field(b, "name") == name and field(b, "source") is None]
if len(root) != 1:
    sys.exit(f"error: expected exactly one path package {name!r} in Cargo.lock, found {len(root)}")
if [k for k, b in enumerate(blocks) if field(b, "name") == name and k != root[0]]:
    sys.exit(f"error: {name!r} is also the name of a dependency in Cargo.lock")
mine = blocks.pop(root[0])
pos = next((k for k, b in enumerate(blocks) if field(b, "name") > name), len(blocks))
blocks.insert(pos, mine)
names = [field(b, "name") for b in blocks]
if names != sorted(names):
    sys.exit("error: Cargo.lock packages are not sorted by name after the move")
out = "".join(pre)
out += "\n".join("".join(norm(b)) for b in blocks)
if trailer:
    out += "\n" + "".join(trailer)
if out != text:
    open(path, "w", encoding="utf-8").write(out)
    print(f"Cargo.lock: root package {name} moved to sorted position {pos + 1}/{len(blocks)}")
PY
fi
# Imports of the crate sit in their own group, so formatting is unaffected; format anyway
# when a toolchain is present. A failure here is a warning, not a failed rename: the rename
# above already succeeded, and `cargo fmt --check` in CI catches anything left unformatted.
if command -v cargo >/dev/null 2>&1; then
  cargo fmt || echo "warning: cargo fmt failed; run it before committing" >&2
fi
