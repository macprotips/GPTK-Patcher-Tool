#!/bin/bash
# Builds MoltenVK with the small changes a game family needs, on top of current upstream.
#
#   scripts/build-moltenvk.sh standard [--ref v1.4.2] [--out DIR]
#
# Profiles:
#   standard      Doom (2016), Wolfenstein II: The New Colossus, Detroit: Become Human
#   doometernal   standard plus geometry shaders, wide lines and vertex-stage subgroups
#
# All three games refuse to create a device without shaderCullDistance and depthBounds, so those
# are not per-engine after all and live in the standard profile. Doom Eternal is the only one
# asking for more.
#
# Every profile also gets moltenvk/unbound-vertex-attributes.patch. Upstream fails to create a
# pipeline when a shader reads a vertex attribute the pipeline never bound; the patch gives that
# attribute a zero-stride dummy instead. Detroit needs it, and so does Doom (2016), which fails
# on "Vertex attribute in_TexCoord1(4) is missing from the vertex descriptor" without it.
#
# Why this exists: these games ask Vulkan for capabilities Metal does not have and refuse to
# create a device without them. Upstream MoltenVK answers honestly and the game quits; the
# community forks answer differently but sit dozens of commits behind, so their shader
# translation is too old to render these games correctly. Both halves are needed at once, so
# the changes are kept here as edits and applied to whatever MoltenVK release is current.
#
# The edits are taken from squidbus's per-game MoltenVK branches (Apache-2.0, same as MoltenVK).
set -euo pipefail

profile="${1:-}"
ref="v1.4.2"
out="$HOME/Library/Application Support/GPTKPatcher/MoltenVK-builds"
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) ref="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$profile" in
    standard|doometernal) ;;
    *) echo "usage: $0 <standard|doometernal> [--ref GIT_REF] [--out DIR]" >&2; exit 2 ;;
esac
patches="$(cd "$(dirname "$0")/../moltenvk" && pwd)"


command -v xcodebuild >/dev/null || { echo "Xcode is required to build MoltenVK." >&2; exit 1; }
work="$(mktemp -d)/MoltenVK"
trap 'rm -rf "$(dirname "$work")"' EXIT

echo "Cloning MoltenVK $ref…"
git clone --quiet --depth 1 --branch "$ref" https://github.com/KhronosGroup/MoltenVK.git "$work"
commit="$(git -C "$work" rev-parse --short HEAD)"

# Shared by every profile: pipelines that read an unbound vertex attribute get a dummy rather
# than failing. Two of the three changes Detroit needed are already merged upstream; this is the
# one that is not.
echo "Applying moltenvk/unbound-vertex-attributes.patch..."
(cd "$work" && git apply "$patches/unbound-vertex-attributes.patch")

python3 - "$work" "$profile" <<'PY'
import sys
root, profile = sys.argv[1], sys.argv[2]
path = f"{root}/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm"
source = open(path).read()

def edit(old, new):
    global source
    if source.count(old) != 1:
        raise SystemExit(f"MoltenVK has changed: could not place the edit for\n  {old.strip()}\n"
                         "Check the profile against upstream before building.")
    source = source.replace(old, new)

# Metal has no cull distance, and these games will not create a device without the feature bit.
# maxCullDistances stays at 0, so nothing is promised beyond the capability itself.
edit("    _features.shaderClipDistance = true;",
     "    _features.shaderClipDistance = true;\n    _features.shaderCullDistance = true;")
# Metal's depth bounds test is behind private API; the games check the feature rather than use it.
edit("    _features.depthBounds = _metalFeatures.depthBoundsTest;",
     "    _features.depthBounds = true;")

if profile == "doometernal":
    edit("\t_features.wideLines = getMVKConfig().useMetalPrivateAPI;",
         "    _features.geometryShader = true;\n\t_features.wideLines = true;")
    edit("\tpVk11Props->subgroupSupportedStages = VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_COMPUTE_BIT;",
         "\tpVk11Props->subgroupSupportedStages = VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_COMPUTE_BIT | VK_SHADER_STAGE_VERTEX_BIT;")

open(path, "w").write(source)
print(f"Applied the {profile} changes.")
PY

echo "Fetching dependencies (this takes a few minutes)…"
(cd "$work" && ./fetchDependencies --macos >/dev/null)
echo "Building…"
(cd "$work" && make macos >/dev/null)

target="$out/MoltenVK-$profile-$ref"
mkdir -p "$target"
cp "$work/Package/Latest/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$target/"
cp "$work/LICENSE" "$target/LICENSE"
cat > "$target/NOTICE.txt" <<NOTE
MoltenVK $ref (commit $commit), modified.

Built from https://github.com/KhronosGroup/MoltenVK with the "$profile" changes described in
scripts/build-moltenvk.sh: capability flags that Doom, Wolfenstein II and Doom Eternal require
before they will create a Vulkan device. Those changes come from squidbus's per-game MoltenVK
branches. Metal does not gain the capabilities; the flags only let the games start.

MoltenVK is licensed under the Apache License 2.0, included as LICENSE. This is not an official
MoltenVK build and is not supported by the Khronos Group.
NOTE
echo "Built $target/libMoltenVK.dylib"
echo "Drop that file on the MoltenVK row in GPTK Patcher Tool, or pass it to --cli --moltenvk."
