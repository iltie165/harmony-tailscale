#include <napi/native_api.h>
#include <hilog/log.h>

#include <algorithm>
#include <cstdint>
#include <sstream>
#include <string>

#include "libtailscale_ohos.h"

namespace {

constexpr unsigned int TS_LOG_DOMAIN = 0x5453;
constexpr const char *TS_LOG_TAG = "TailscaleNAPI";

enum class AsyncOperation {
    Start,
    Status,
    Login,
    Logout,
    OnlinePeers,
    Diagnostics,
    Close,
};

struct AsyncContext {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    AsyncOperation operation = AsyncOperation::Start;
    std::string dataDir;
    std::string hostname;
    std::string filter;
    std::string result;
    std::string error;
};

std::string TakeGoString(char *value)
{
    if (value == nullptr) {
        return {};
    }
    std::string result(value);
    tailscale_ohos_string_free(value);
    return result;
}

std::string EscapeJSON(const std::string &value)
{
    std::ostringstream output;
    for (const unsigned char character : value) {
        switch (character) {
            case '\\': output << "\\\\"; break;
            case '"': output << "\\\""; break;
            case '\n': output << "\\n"; break;
            case '\r': output << "\\r"; break;
            case '\t': output << "\\t"; break;
            default:
                if (character < 0x20) {
                    output << "?";
                } else {
                    output << character;
                }
        }
    }
    return output.str();
}

napi_value MakeString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

bool ReadString(napi_env env, napi_value value, std::string &result)
{
    size_t size = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok) {
        return false;
    }
    result.resize(size + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, &result[0], result.size(), &copied) != napi_ok) {
        return false;
    }
    result.resize(copied);
    return true;
}

void LogLine(const std::string &line)
{
    constexpr size_t MAX_HILOG_BYTES = 3000;
    if (line.empty()) {
        return;
    }
    for (size_t offset = 0; offset < line.size(); offset += MAX_HILOG_BYTES) {
        const std::string chunk = line.substr(offset, MAX_HILOG_BYTES);
        OH_LOG_Print(LOG_APP, LOG_INFO, TS_LOG_DOMAIN, TS_LOG_TAG, "%{public}s", chunk.c_str());
    }
}

void ForwardGoLogs()
{
    const std::string text = TakeGoString(tailscale_ohos_logs());
    size_t begin = 0;
    while (begin < text.size()) {
        const size_t end = text.find('\n', begin);
        LogLine(text.substr(begin, end == std::string::npos ? std::string::npos : end - begin));
        if (end == std::string::npos) {
            break;
        }
        begin = end + 1;
    }
}

const char *OperationName(AsyncOperation operation)
{
    switch (operation) {
        case AsyncOperation::Start: return "start";
        case AsyncOperation::Status: return "status";
        case AsyncOperation::Login: return "login";
        case AsyncOperation::Logout: return "logout";
        case AsyncOperation::OnlinePeers: return "onlinePeers";
        case AsyncOperation::Diagnostics: return "diagnostics";
        case AsyncOperation::Close: return "close";
    }
    return "unknown";
}

napi_value GetVersion(napi_env env, napi_callback_info)
{
    const std::string tailscaleVersion = TakeGoString(tailscale_ohos_version());
    const std::string goVersion = TakeGoString(tailscale_ohos_go_version());
    std::ostringstream output;
    output << "{\"ok\":true,\"abiVersion\":" << tailscale_ohos_abi_version()
           << ",\"tailscaleVersion\":\"" << EscapeJSON(tailscaleVersion)
           << "\",\"goVersion\":\"" << EscapeJSON(goVersion)
           << "\",\"coreProbe\":" << (tailscale_ohos_core_probe() == 1 ? "true" : "false") << "}";
    LogLine("Native version query succeeded: " + output.str());
    return MakeString(env, output.str());
}

napi_value GetLogs(napi_env env, napi_callback_info)
{
    const std::string output = TakeGoString(tailscale_ohos_logs());
    ForwardGoLogs();
    return MakeString(env, output);
}

void ExecuteAsync(napi_env, void *data)
{
    auto *context = static_cast<AsyncContext *>(data);
    switch (context->operation) {
        case AsyncOperation::Start:
            context->result = TakeGoString(tailscale_ohos_start(
                const_cast<char *>(context->dataDir.c_str()),
                const_cast<char *>(context->hostname.c_str())));
            break;
        case AsyncOperation::Status:
            context->result = TakeGoString(tailscale_ohos_status());
            break;
        case AsyncOperation::Login:
            context->result = TakeGoString(tailscale_ohos_login());
            break;
        case AsyncOperation::Logout:
            context->result = TakeGoString(tailscale_ohos_logout());
            break;
        case AsyncOperation::OnlinePeers:
            context->result = TakeGoString(
                tailscale_ohos_online_peers(const_cast<char *>(context->filter.c_str())));
            break;
        case AsyncOperation::Diagnostics:
            context->result = TakeGoString(
                tailscale_ohos_diagnostics(const_cast<char *>(context->dataDir.c_str())));
            break;
        case AsyncOperation::Close:
            context->result = TakeGoString(tailscale_ohos_close());
            break;
    }
    if (context->result.empty()) {
        context->error = "Go C ABI returned an empty result";
    }
    ForwardGoLogs();
}

void CompleteAsync(napi_env env, napi_status status, void *data)
{
    auto *context = static_cast<AsyncContext *>(data);
    if (status == napi_ok && context->error.empty()) {
        const std::string operationName = OperationName(context->operation);
        if (context->operation == AsyncOperation::Start ||
            context->operation == AsyncOperation::Diagnostics ||
            context->operation == AsyncOperation::Close) {
            LogLine("Async " + operationName + " result: " + context->result);
        } else {
            LogLine("Async " + operationName + " completed; structured result kept out of HiLog");
        }
        napi_resolve_deferred(env, context->deferred, MakeString(env, context->result));
    } else {
        const std::string message = context->error.empty() ? "NAPI async work failed" : context->error;
        napi_value errorMessage = MakeString(env, message);
        napi_value error = nullptr;
        napi_create_error(env, nullptr, errorMessage, &error);
        napi_reject_deferred(env, context->deferred, error);
        LogLine(message);
    }
    napi_delete_async_work(env, context->work);
    delete context;
}

napi_value QueueAsync(napi_env env, AsyncContext *context, const char *resourceName)
{
    context->env = env;
    napi_value promise = nullptr;
    if (napi_create_promise(env, &context->deferred, &promise) != napi_ok) {
        delete context;
        napi_throw_error(env, nullptr, "napi_create_promise failed");
        return nullptr;
    }
    napi_value name = MakeString(env, resourceName);
    if (napi_create_async_work(env, nullptr, name, ExecuteAsync, CompleteAsync, context, &context->work) != napi_ok) {
        delete context;
        napi_throw_error(env, nullptr, "napi_create_async_work failed");
        return nullptr;
    }
    if (napi_queue_async_work(env, context->work) != napi_ok) {
        napi_delete_async_work(env, context->work);
        delete context;
        napi_throw_error(env, nullptr, "napi_queue_async_work failed");
        return nullptr;
    }
    return promise;
}

napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 2) {
        napi_throw_type_error(env, nullptr, "start(dataDir, hostname) requires two strings");
        return nullptr;
    }
    auto *context = new AsyncContext();
    context->operation = AsyncOperation::Start;
    if (!ReadString(env, argv[0], context->dataDir) || !ReadString(env, argv[1], context->hostname)) {
        delete context;
        napi_throw_type_error(env, nullptr, "dataDir and hostname must be strings");
        return nullptr;
    }
    return QueueAsync(env, context, "tailscaleStart");
}

napi_value GetStatus(napi_env env, napi_callback_info)
{
    auto *context = new AsyncContext();
    context->operation = AsyncOperation::Status;
    return QueueAsync(env, context, "tailscaleStatus");
}

napi_value Login(napi_env env, napi_callback_info)
{
    auto *context = new AsyncContext();
    context->operation = AsyncOperation::Login;
    return QueueAsync(env, context, "tailscaleLogin");
}

napi_value Logout(napi_env env, napi_callback_info)
{
    auto *context = new AsyncContext();
    context->operation = AsyncOperation::Logout;
    return QueueAsync(env, context, "tailscaleLogout");
}

napi_value OnlinePeers(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 1) {
        napi_throw_type_error(env, nullptr, "onlinePeers(filter) requires one string");
        return nullptr;
    }
    auto *context = new AsyncContext();
    context->operation = AsyncOperation::OnlinePeers;
    if (!ReadString(env, argv[0], context->filter)) {
        delete context;
        napi_throw_type_error(env, nullptr, "filter must be a string");
        return nullptr;
    }
    return QueueAsync(env, context, "tailscaleOnlinePeers");
}

napi_value Diagnostics(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 1) {
        napi_throw_type_error(env, nullptr, "diagnostics(dataDir) requires one string");
        return nullptr;
    }
    auto *context = new AsyncContext();
    context->operation = AsyncOperation::Diagnostics;
    if (!ReadString(env, argv[0], context->dataDir)) {
        delete context;
        napi_throw_type_error(env, nullptr, "dataDir must be a string");
        return nullptr;
    }
    return QueueAsync(env, context, "tailscaleDiagnostics");
}

napi_value Close(napi_env env, napi_callback_info)
{
    auto *context = new AsyncContext();
    context->operation = AsyncOperation::Close;
    return QueueAsync(env, context, "tailscaleClose");
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"getVersion", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStatus", nullptr, GetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLogs", nullptr, GetLogs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"login", nullptr, Login, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"logout", nullptr, Logout, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onlinePeers", nullptr, OnlinePeers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"diagnostics", nullptr, Diagnostics, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

} // namespace

static napi_module tailscaleModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tailscale_napi",
    .nm_priv = nullptr,
    .reserved = {nullptr, nullptr, nullptr, nullptr},
};

extern "C" __attribute__((constructor)) void RegisterTailscaleModule()
{
    napi_module_register(&tailscaleModule);
}
