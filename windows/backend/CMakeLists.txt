cmake_minimum_required(VERSION 3.14)

include("${FLUTTER_MANAGED_DIR}/ephemeral/generated_config.cmake")

set(BACKEND_EXECUTABLE
  "${CMAKE_CURRENT_BINARY_DIR}/atrader_backend.exe")
file(GLOB_RECURSE BACKEND_DART_SOURCES CONFIGURE_DEPENDS
  "${PROJECT_DIR}/lib/*.dart")

# Compile a standalone service; users of the Windows bundle need no Dart SDK.
add_custom_command(
  OUTPUT "${BACKEND_EXECUTABLE}"
  COMMAND "${FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart.exe"
    compile exe "${PROJECT_DIR}/bin/server.dart"
    -o "${BACKEND_EXECUTABLE}"
  WORKING_DIRECTORY "${PROJECT_DIR}"
  DEPENDS
    "${PROJECT_DIR}/bin/server.dart"
    "${PROJECT_DIR}/pubspec.yaml"
    "${PROJECT_DIR}/pubspec.lock"
    "${PROJECT_DIR}/.dart_tool/package_config.json"
    ${BACKEND_DART_SOURCES}
  COMMENT "Compiling the A-Trader Dart backend"
  VERBATIM
)
add_custom_target(atrader_backend DEPENDS "${BACKEND_EXECUTABLE}")
add_dependencies(${BINARY_NAME} atrader_backend)
set(BACKEND_EXECUTABLE "${BACKEND_EXECUTABLE}" PARENT_SCOPE)
