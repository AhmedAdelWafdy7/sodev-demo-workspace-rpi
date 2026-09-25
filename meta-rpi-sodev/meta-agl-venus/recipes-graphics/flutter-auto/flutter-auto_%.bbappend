# One MSAA policy for the whole cluster in the Vulkan lane: 1x. (This layer is only
# in the AGL build for --gpu=vulkan, so --gpu=gl keeps meta-flutter's 4x.)
#
# The Vulkan/Impeller lane's 4x was turned off in the engine (flutter-engine
# bbappend, 0002-impeller-do-not-request-4x-MSAA patch — see the measured
# rationale there). meta-flutter's flutter-auto enables the egl-multisample
# PACKAGECONFIG, which is EGL_SAMPLES=4 for the OpenGL embedder this lane
# installs alongside the Vulkan one; leaving it on would mean the two embedders
# disagree about anti-aliasing on the same panel. Removing it gives that OpenGL
# embedder the adopted 1x policy too.
#
# egl-multisample maps to -DBUILD_EGL_ENABLE_MULTISAMPLE (flutter-auto_2.0.bb), an EGL
# config knob only used inside the BUILD_BACKEND_WAYLAND_EGL branch. flutter-auto-vulkan
# never had it (its own recipe documents why).
PACKAGECONFIG:remove = "egl-multisample"
