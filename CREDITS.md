# Credits

This tool patches other people's software with other people's fixes. Nearly everything it
installs was made by someone else, and the parts that were not are small. This is who did what.

## The software this patches

**CrossOver** is [CodeWeavers'](https://www.codeweavers.com) commercial product, built on
[Wine](https://www.winehq.org). This tool modifies a copy you already own and is not supported by
them. Their build of MoltenVK is also patched to advertise capabilities Metal does not have,
which is the only reason several Vulkan games start at all. Their work, not ours.

**Apple's Game Porting Toolkit** is Apple's, under Apple's terms. Nothing from it is
redistributed here; you supply your own copy and its licence travels with it.

**DXMT** is [3Shain/dxmt](https://github.com/3Shain/dxmt), which translates Direct3D 11 to Metal.
Releases are downloaded by you, not by this tool.

## The MoltenVK builds

[MoltenVK](https://github.com/KhronosGroup/MoltenVK) is the Khronos Group's, Apache-2.0, and it
translates Vulkan to Metal. `scripts/build-moltenvk.sh` builds it with small changes, none of
which are original:

- **The capability flags**, `shaderCullDistance` and `depthBounds`, come from
  [squidbus](https://github.com/squidbus/MoltenVK)'s per-game branches (`doom`, `doometernal`).
  Metal has neither; the games refuse to create a device without them.
- **`moltenvk/unbound-vertex-attributes.patch`** is squidbus's commit `97ac9f8`, which gives a
  vertex attribute the pipeline never bound a zero-stride dummy instead of failing outright. Doom
  and Detroit both need it. Two related fixes of his are already merged upstream (#2748, #2749),
  so they are no longer carried here.

**Detroit: Become Human** is not built here. It needs
[DiAvisoo/MoltenVK-Detroit](https://github.com/DiAvisoo/MoltenVK-Detroit), which builds on
[alexdremov/MoltenVK](https://github.com/alexdremov/MoltenVK) and
[alexdremov/SPIRV-Cross](https://github.com/alexdremov/SPIRV-Cross). The fix needs the shader
compiler patched, not just the driver, and that work is theirs. The research behind it is in
[KhronosGroup/MoltenVK#2054](https://github.com/KhronosGroup/MoltenVK/issues/2054), including
aquadran's blending workaround and imagetasks's reports.

## Finding out what was wrong

[Andrew Tsai's video](https://www.youtube.com/watch?v=ASHlzBnJDOE) is the guide most people start
from, and its links to the Detroit and Doom builds are what made the shape of the problem clear.
Truwa's Doom video supplied the launch options and the observation that an updated MoltenVK is
most of the fix. The r/macgaming thread that started this project pointed at MetalFX and the
frame-rate cap. [italomandara/Procyon](https://github.com/italomandara/Procyon) publishes a
MoltenVK build widely used for Doom.

## What ships inside the app

The app packages one MoltenVK library, built by `scripts/build-moltenvk.sh standard` from Khronos'
source with squidbus's changes described above. Apache-2.0 allows that; the licence and a notice
naming the upstream commit, the modifications and the SDK it was built against ship beside the
library inside the app bundle, in Contents/Resources/MoltenVK. It is not an official MoltenVK
build and the Khronos Group does not support it.

Nothing else is redistributed. Apple's toolkit, DXMT releases and the Detroit build stay with
their own projects and you supply them yourself.

## This project

The Swift app, its tests, the build script and the workflow are MIT; see [LICENSE](LICENSE).
What is genuinely new here is not the fixes but the assembly: taking changes that were stranded on
forks dozens of commits behind upstream, applying them to a current MoltenVK, and making the
result reproducible, licensed and installable without a build toolchain.
