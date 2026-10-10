#include <node_api.h>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
// Simulate only SDK acquisition failures; normal behavior uses real Node N-API.
static bool Fail(const char *stage) {
    const char *fault = std::getenv("HARMONY_TEST_NAPI_FAULT");
    return fault && std::strcmp(fault, stage) == 0;
}
extern "C" napi_status test_create_promise(napi_env env, napi_deferred *deferred, napi_value *promise) {
    return Fail("promise") ? napi_generic_failure : napi_create_promise(env, deferred, promise);
}
extern "C" napi_status test_create_async_work(napi_env env, napi_value resource, napi_value name,
    napi_async_execute_callback execute, napi_async_complete_callback complete, void *data, napi_async_work *work) {
    return Fail("work") ? napi_generic_failure : napi_create_async_work(env, resource, name, execute, complete, data, work);
}
extern "C" napi_status test_queue_async_work(napi_env env, napi_async_work work) {
    return Fail("queue") ? napi_generic_failure : napi_queue_async_work(env, work);
}
extern "C" int OH_LOG_Print(int, int, unsigned int, const char *, const char *format, ...) {
    const char *path = std::getenv("HARMONY_TEST_HILOG_PATH");
    if (!path) return 0;
    va_list args;
    va_start(args, format);
    const char *message = va_arg(args, const char *);
    va_end(args);
    if (FILE *file = std::fopen(path, "a")) {
        std::fprintf(file, "%s\n", message);
        std::fclose(file);
    }
    return 0;
}
