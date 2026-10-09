cmake_minimum_required(VERSION 3.5.0)
project(tailscale_napi)

set(TAILSCALE_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}")

add_library(tailscale_ohos SHARED IMPORTED)
set_target_properties(tailscale_ohos PROPERTIES
  IMPORTED_LOCATION "${TAILSCALE_LIB_DIR}/libtailscale_ohos.so"
)

add_library(tailscale_napi SHARED napi_init.cpp)
target_include_directories(tailscale_napi PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(tailscale_napi PUBLIC
  tailscale_ohos
  libace_napi.z.so
  libhilog_ndk.z.so
)
