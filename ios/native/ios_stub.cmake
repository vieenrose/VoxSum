# sentencepiece's own CMake calls set_xcode_property() under CMAKE_SYSTEM_NAME=iOS but only defines it
# in its bundled ios.toolchain.cmake, which we do not use (we use CMake's native iOS support).
macro(set_xcode_property)
endmacro()
