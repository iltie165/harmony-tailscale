#pragma once
#define LOG_APP 0
#define LOG_INFO 4
extern "C" int OH_LOG_Print(int, int, unsigned int, const char *, const char *, ...);
