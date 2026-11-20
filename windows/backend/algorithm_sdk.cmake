# PROJECT_DIR is set inside Flutter/backend subdirectories, not their parent.
# Resolve SDK sources from this file so installation works in either scope.
get_filename_component(ATRADER_ALGORITHM_SDK_SOURCE_DIR
  "${CMAKE_CURRENT_LIST_DIR}/../../lib" ABSOLUTE)

install(FILES
  "${ATRADER_ALGORITHM_SDK_SOURCE_DIR}/strategy_api.dart"
  "${ATRADER_ALGORITHM_SDK_SOURCE_DIR}/simulator.dart"
  "${ATRADER_ALGORITHM_SDK_SOURCE_DIR}/exchange_calendar.dart"
  "${ATRADER_ALGORITHM_SDK_SOURCE_DIR}/training.dart"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/algorithm_sdk/lib" COMPONENT Runtime)
install(DIRECTORY "${ATRADER_ALGORITHM_SDK_SOURCE_DIR}/algorithms/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/algorithm_sdk/lib/algorithms"
  COMPONENT Runtime FILES_MATCHING PATTERN "*.dart")
