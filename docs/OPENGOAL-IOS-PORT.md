# OpenGOAL iOS port lane

OpenGOAL is cataloged as a research project, not as a supported iOS app. The
official project targets x86-64 desktop systems and explicitly has no mobile
release plan. There is no iOS IPA to index in the AltStore source.

## Why Metal is not enough

The current renderer owns a desktop OpenGL pipeline and a large GLSL shader
surface, so a native Metal backend is required. That work does not solve the
more fundamental execution constraint: OpenGOAL links compiled GOAL objects into
writable-executable memory at runtime. A normal third-party iOS app cannot use
that model.

The shippable direction is ahead-of-time ARM64 GOAL code included in the signed
Mach-O, with a static function and relocation registry replacing runtime code
generation and linking. An interpreter is a possible alternative, but it needs
a separate performance proof. Completing an ARM64 JIT alone would still not
make the runtime acceptable on iOS.

## Acceptance sequence

1. Compile and run one representative GOAL unit as signed, ahead-of-time ARM64
   code on a physical iPad, without private or dynamic-code entitlements.
2. Complete the ARM64 ABI, SIMD, code generation, and relocation work against
   that static execution model.
3. Expose the runtime and disc validator as in-process library APIs. Remove the
   desktop child-process launcher, dialogs, and unrestricted filesystem paths.
4. Add a Metal renderer behind OpenGOAL's graphics-pipeline boundary, with an
   `MTKView` or `CAMetalLayer`, translated shaders, and API-neutral resources.
5. Add controller, touch, audio-interruption, backgrounding, save-data, and
   sandbox support. The user imports a legally obtained supported PS2 disc image
   locally; no original game data enters source control, CI, an IPA, or a feed.
6. Prove a standalone Jak 1 IPA on device: title to gameplay, background and
   foreground, clean shutdown, and a clean relaunch without stale global state.
   Jak II follows Jak 1; Jak 3 remains last because its upstream support is less
   mature.

## Framework decision

Do not create a generic shared Metal framework yet. DuskLight already ships its
own WebGPU-to-Metal path, while OpenGOAL needs a renderer designed around its
existing pipeline and bucket architecture. If multiple completed ports later
share stable code, extract a static `MetalHostKit.xcframework` for layer hosting,
frame pacing, and lifecycle callbacks. Each standalone IPA must link its own
copy; installed apps cannot share a runtime framework.

OpenGOAL code is ISC licensed, but dependency notices still apply and original
Sony or Naughty Dog assets must never be redistributed.
