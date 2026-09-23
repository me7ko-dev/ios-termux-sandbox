#!/bin/bash
# Extracts the iOS builds of QEMU (and every framework they link) from
# UTM's official release IPAs into Vendor/QEMU/Frameworks, ready to be
# embedded by App/project.yml's "Embed QEMU frameworks" build phase.
#
#   UTM.ipa     -> qemu-aarch64-softmmu.framework       (TCG JIT build)
#   UTM-SE.ipa  -> qemu-aarch64-softmmu-tcti.framework  (TCTI interpreter,
#                  renamed so both can live in one app's Frameworks/)
#
# Building QEMU + glib + pixman + ... for iOS from source is UTM's
# scripts/build_dependencies.sh — a 1-2 hour job; reusing their signed-off
# release binaries gets the identical code in a minute. QEMU is GPLv2: the
# app you build with these must be distributed under GPL-compatible terms
# (see Docs/STATUS.md).
#
# macOS only (otool, install_name_tool, PlistBuddy). Needs `gh` with a
# token (GH_TOKEN) to download release assets. Pin a release with
# UTM_TAG=v4.x.y; defaults to the latest.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/QEMU"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UTM_TAG="${UTM_TAG:-$(gh release view --repo utmapp/UTM --json tagName -q .tagName)}"
echo "UTM release: $UTM_TAG"
gh release view "$UTM_TAG" --repo utmapp/UTM --json assets -q '.assets[].name'
gh release download "$UTM_TAG" --repo utmapp/UTM -p 'UTM.ipa' -p 'UTM-SE.ipa' -D "$WORK"

unzip -q "$WORK/UTM.ipa" -d "$WORK/jit"
unzip -q "$WORK/UTM-SE.ipa" -d "$WORK/se"
JIT_FW="$(echo "$WORK"/jit/Payload/*.app)/Frameworks"
SE_FW="$(echo "$WORK"/se/Payload/*.app)/Frameworks"
echo "Frameworks in UTM.ipa:"; ls "$JIT_FW"

# Prints the framework names (without .framework) that $1 links via @rpath,
# recursively, including $1's own framework.
closure() {
    local fwdir="$1" start="$2"
    local -a queue=("$start") seen=()
    while ((${#queue[@]})); do
        local name="${queue[0]}"; queue=("${queue[@]:1}")
        [[ " ${seen[*]-} " == *" $name "* ]] && continue
        seen+=("$name")
        local bin="$fwdir/$name.framework/$name"
        [[ -f "$bin" ]] || { echo "missing dependency: $bin" >&2; exit 1; }
        while read -r dep; do
            queue+=("$dep")
        done < <(otool -L "$bin" | sed -n 's|^[[:space:]]*@rpath/\([^/]*\)\.framework/.*|\1|p')
    done
    printf '%s\n' "${seen[@]}"
}

rm -rf "$OUT"
mkdir -p "$OUT/Frameworks"

echo "== JIT closure"
for name in $(closure "$JIT_FW" qemu-aarch64-softmmu); do
    echo "  $name"
    cp -R "$JIT_FW/$name.framework" "$OUT/Frameworks/"
done

echo "== TCTI closure"
for name in $(closure "$SE_FW" qemu-aarch64-softmmu); do
    if [[ "$name" == qemu-aarch64-softmmu ]]; then
        continue
    fi
    if [[ ! -d "$OUT/Frameworks/$name.framework" ]]; then
        echo "  $name (only needed by TCTI)"
        cp -R "$SE_FW/$name.framework" "$OUT/Frameworks/"
    fi
done

# Rename UTM SE's QEMU so it can sit next to the JIT one.
TCTI="$OUT/Frameworks/qemu-aarch64-softmmu-tcti.framework"
cp -R "$SE_FW/qemu-aarch64-softmmu.framework" "$TCTI"
mv "$TCTI/qemu-aarch64-softmmu" "$TCTI/qemu-aarch64-softmmu-tcti"
install_name_tool -id @rpath/qemu-aarch64-softmmu-tcti.framework/qemu-aarch64-softmmu-tcti "$TCTI/qemu-aarch64-softmmu-tcti" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable qemu-aarch64-softmmu-tcti" "$TCTI/Info.plist"
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TCTI/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID-tcti" "$TCTI/Info.plist"

# Old signatures are UTM's and invalid after the edits above; the app
# build (or the sideloading tool) signs everything again.
find "$OUT/Frameworks" -name _CodeSignature -type d -prune -exec rm -rf {} +
for fw in "$OUT"/Frameworks/*.framework; do
    bin="$fw/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$fw/Info.plist")"
    codesign --remove-signature "$bin" 2>/dev/null || true
done

# The entry points LinuxVM's CQEMUBootstrap dlsym()s — fail here, not on
# the phone, if a future UTM release renames them.
for bin in "$OUT/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" \
           "$TCTI/qemu-aarch64-softmmu-tcti"; do
    for sym in _qemu_init _qemu_main_loop _qemu_cleanup; do
        nm -gU "$bin" | grep -q " T $sym\$" || { echo "$bin does not export $sym" >&2; exit 1; }
    done
done

echo "$UTM_TAG" > "$OUT/UTM_RELEASE"
du -sh "$OUT/Frameworks"
