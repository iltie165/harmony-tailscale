#pragma once
// Host-only SDK shim: Node implements the same N-API calls used by this bridge.
#include <node_api.h>
extern "C" napi_status test_create_promise(napi_env, napi_deferred *, napi_value *);
extern "C" napi_status test_create_async_work(napi_env, napi_value, napi_value, napi_async_execute_callback, napi_async_complete_callback, void *, napi_async_work *);
extern "C" napi_status test_queue_async_work(napi_env, napi_async_work);
#define napi_create_promise test_create_promise
#define napi_create_async_work test_create_async_work
#define napi_queue_async_work test_queue_async_work
