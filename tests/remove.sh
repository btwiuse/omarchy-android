#!/usr/bin/env bash

# Exercises the remove action end-to-end against a fake container and
# fake host runtime. The goal is to prove that:
#   - the action is wired into the option parser and dispatch
#   - the option parser refuses to combine remove with --bundle/--host-bundle
#   - the plan lists every artefact the remove will touch
#   - perform_remove drops the container and the prefix
#   - perform_remove leaves other proot-distro containers alone
#   - perform_remove refuses to do anything if no install is present
#
# The fake proot-distro is a stub script so the test does not touch a
# real container or require root.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

tmp="$(mktemp -d)"
fake_prefix="$(mktemp -d "$tmp/prefix.XXXXXX")"
fake_termux="$tmp/fake-termux"
mkdir -p "$fake_termux/bin" "$fake_termux/var/lib/proot-distro/containers"
# A second container we must NOT touch
mkdir -p "$fake_termux/var/lib/proot-distro/containers/keepme/rootfs"
echo "untouched" > "$fake_termux/var/lib/proot-distro/containers/keepme/rootfs/marker"

current_oci_ref="$(awk -F '=' '$1=="oci_reference" {print $2; exit}' "$ROOT/manifest/release.lock")"
[[ -n "$current_oci_ref" ]] \
  || { echo "release.lock missing oci_reference" >&2; exit 1; }

# Fake container rootfs + a host runtime tree
target_container="$fake_termux/var/lib/proot-distro/containers/omarchy-android"
mkdir -p "$target_container/rootfs/etc"
echo "guest" > "$target_container/rootfs/etc/issue"
install -d -m 0755 "$fake_prefix/bin"
cat > "$fake_prefix/bin/omarchy-android-stop" <<'STOP'
#!/usr/bin/env bash
echo "stop called: $*"
STOP
chmod 0755 "$fake_prefix/bin/omarchy-android-stop"
cat > "$fake_prefix/INSTALL-MANIFEST" <<EOF
version=0.0.13
EOF

# Fake proot-distro: records calls, mimics `remove` by deleting the
# rootfs directory. Lets us assert the install script invoked it
# correctly without requiring the real tool.
fake_pd_log="$tmp/proot-distro.log"
cat > "$fake_termux/bin/proot-distro" <<EOF
#!/usr/bin/env bash
echo "PD \$*" >> "$fake_pd_log"
case "\$1" in
  remove)
    name="\$2"
    if [[ -d "$fake_termux/var/lib/proot-distro/containers/\$name" ]]; then
      rm -rf "$fake_termux/var/lib/proot-distro/containers/\$name"
      exit 0
    fi
    echo "container '\$name' is not installed." >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod 0755 "$fake_termux/bin/proot-distro"

# 1. --help mentions remove
"$ROOT/install.sh" --help 2>&1 | grep -F '  remove' >/dev/null \
  || { echo "help text missing remove action" >&2; exit 1; }

# 2. parser rejects --bundle combined with remove
if "$ROOT/install.sh" remove --bundle /tmp/whatever --dry-run >/dev/null 2>&1; then
  echo "remove --bundle was accepted" >&2; exit 1
fi

# 3. parser rejects --host-bundle combined with remove
if "$ROOT/install.sh" remove --host-bundle /tmp/whatever --dry-run >/dev/null 2>&1; then
  echo "remove --host-bundle was accepted" >&2; exit 1
fi

# 4. dry-run lists every removal step
dry_out="$(
  PREFIX="$fake_termux" \
  HOME="$tmp" \
  PATH="$fake_termux/bin:$PATH" \
  "$ROOT/install.sh" remove --dry-run --yes --prefix "$fake_prefix" 2>&1
)"
grep -F "Remove the proot-distro container omarchy-android" <<<"$dry_out" >/dev/null \
  || { echo "dry-run missing container step" >&2; echo "$dry_out" >&2; exit 1; }
grep -F "Delete the host runtime tree at $fake_prefix" <<<"$dry_out" >/dev/null \
  || { echo "dry-run missing prefix step" >&2; echo "$dry_out" >&2; exit 1; }
grep -F "Offer to uninstall shared Termux packages" <<<"$dry_out" >/dev/null \
  || { echo "dry-run missing termux-package step" >&2; echo "$dry_out" >&2; exit 1; }

# 5. dry-run leaves everything in place
[[ -d "$target_container/rootfs" ]] || { echo "dry-run wiped container" >&2; exit 1; }
[[ -d "$fake_prefix/bin" ]] || { echo "dry-run wiped prefix" >&2; exit 1; }

# 6. dry-run with --keep-termux-packages does not list the uninstall step
keep_out="$(
  PREFIX="$fake_termux" \
  HOME="$tmp" \
  PATH="$fake_termux/bin:$PATH" \
  "$ROOT/install.sh" remove --dry-run --yes --prefix "$fake_prefix" --keep-termux-packages 2>&1
)"
grep -F "Leave shared Termux packages installed" <<<"$keep_out" >/dev/null \
  || { echo "keep-termux-packages plan missing" >&2; exit 1; }
grep -F "Offer to uninstall shared Termux packages" <<<"$keep_out" >/dev/null \
  && { echo "keep-termux-packages still listed uninstall step" >&2; exit 1; }

# 7. real remove cleans container + prefix, leaves the keepme container
#    alone, and refuses if no install exists.
rm -f "$fake_pd_log"
PREFIX="$fake_termux" \
HOME="$tmp" \
PATH="$fake_termux/bin:$PATH" \
"$ROOT/install.sh" remove --yes --keep-termux-packages --prefix "$fake_prefix" 2>&1 | tail -5

[[ ! -d "$target_container" ]] \
  || { echo "container rootfs survived removal" >&2; ls "$target_container" >&2; exit 1; }
[[ ! -e "$fake_prefix" ]] \
  || { echo "prefix survived removal" >&2; ls "$fake_prefix" >&2; exit 1; }
[[ -d "$fake_termux/var/lib/proot-distro/containers/keepme/rootfs" ]] \
  || { echo "other container was wiped" >&2; exit 1; }
grep -F "untouched" "$fake_termux/var/lib/proot-distro/containers/keepme/rootfs/marker" >/dev/null \
  || { echo "other container content was modified" >&2; exit 1; }
grep -F "PD remove omarchy-android" "$fake_pd_log" >/dev/null \
  || { echo "proot-distro remove was not invoked" >&2; cat "$fake_pd_log" >&2; exit 1; }

# 8. second remove with no install present is a hard error
if PREFIX="$fake_termux" HOME="$tmp" PATH="$fake_termux/bin:$PATH" \
     "$ROOT/install.sh" remove --yes --keep-termux-packages --prefix "$fake_prefix" >/dev/null 2>&1; then
  echo "remove on missing install succeeded unexpectedly" >&2; exit 1
fi

rm -rf "$tmp"
echo "remove action tests passed"
