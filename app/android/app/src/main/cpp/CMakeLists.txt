cmake_minimum_required(VERSION 3.22.1)
project("termopus_secrets")

# Set standards BEFORE add_library
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fvisibility=hidden")

add_library(termopus_secrets SHARED termopus_secrets.cpp)

find_library(log-lib log)
target_link_libraries(termopus_secrets ${log-lib})
