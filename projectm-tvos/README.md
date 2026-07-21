# libprojectM for tvOS — patches & build recipe

SpinViz for Apple TV dynamically links **libprojectM 4.1.0**
(upstream commit `98101f56`, https://github.com/projectM-visualizer/projectm),
licensed under the **GNU LGPL-2.1**. Per LGPL §6, the library ships as a
dynamically linked, replaceable framework inside the app bundle.

This directory provides everything needed to reproduce or modify that library:

- `patches/tvos-gles30.patch` — lowers projectM's OpenGL ES gate from 3.2 to
  3.0 and adds an EAGL context-current probe, so it runs on Apple's native
  GLES 3.0 stack on tvOS.
- `build-projectm-tvos.sh` — builds `libprojectM-4.xcframework`
  (device + simulator slices) as dynamic frameworks
  (`-DBUILD_SHARED_LIBS=ON`) from the upstream source at the commit above,
  with the patch applied.

To substitute your own build of the library, replace
`libprojectM-4.framework` inside `SpinVizTV.app/Frameworks/` with a framework
built by this script (re-signing required for deployment to a device).

The full LGPL-2.1 text ships inside the app (Settings → About → Open-Source
Licenses) and with the upstream source.
