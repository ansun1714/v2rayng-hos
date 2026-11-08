cmake_minimum_required(VERSION 3.5.0)
project(ngnapi)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(ngnapi SHARED napi_init.cpp)

# libngcore.so 是 Go 交叉编译出来的内核库，运行时用 dlopen 加载，
# 因此这里只链接 NAPI 与日志运行时。
target_link_libraries(ngnapi PUBLIC libace_napi.z.so hilog_ndk.z)
