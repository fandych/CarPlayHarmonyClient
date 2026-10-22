cmake_minimum_required(VERSION 3.4.1)
project(carplay_screen_capture)

add_library(entry SHARED napi_init.cpp)
target_compile_features(entry PRIVATE cxx_std_17)
target_link_libraries(entry PUBLIC
  libace_napi.z.so
  libnative_avscreen_capture.so
  libnative_media_core.so
)
