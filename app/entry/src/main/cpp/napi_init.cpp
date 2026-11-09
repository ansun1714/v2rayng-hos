#include <dlfcn.h>
#include <string>
#include <map>
#include <mutex>
#include <chrono>
#include <condition_variable>
#include <hilog/log.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <errno.h>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>

#include "napi/native_api.h"

static constexpr unsigned int kDomain = 0x0001;
static constexpr const char *kTag = "NG-NAPI";

typedef char *(*FnStart)(char *cfg, char *home);
typedef void (*FnStop)(void);
typedef int (*FnIsRunning)(void);
typedef char *(*FnStats)(void);
typedef char *(*FnProxyDelay)(char *name, char *url, int timeoutMs);
typedef void (*FnProxyDelayAsync)(char *name, char *url, int timeoutMs, char *resPath, int seq);
typedef char *(*FnVersion)(void);
typedef void (*FnFree)(char *p);
typedef void (*FnSetProtectCb)(int (*cb)(int));
typedef void (*FnSetLogCb)(void (*cb)(int, const char *));

static FnStart g_start = nullptr;
static FnStop g_stop = nullptr;
static FnIsRunning g_isRunning = nullptr;
static FnStats g_stats = nullptr;
static FnProxyDelay g_proxyDelay = nullptr;
static FnProxyDelayAsync g_proxyDelayAsync = nullptr;
static FnVersion g_version = nullptr;
static FnFree g_free = nullptr;
static FnSetProtectCb g_setProtectCb = nullptr;
static FnSetLogCb g_setLogCb = nullptr;

// ---- 内核日志桥：Go 侧 log.Subscribe 的回调落到 hilog（NG-CORE）----
// 只放 error/warn：info 级别会逐条记录连接的目的地址（域名/IP），
// 落进系统日志等于把访问记录交出去，所以 info/debug 一律丢弃。
static void GoLog(int level, const char *msg) {
    if (msg == nullptr) {
        return;
    }
    LogLevel lv;
    if (level <= 1) {
        lv = LOG_ERROR;
    } else if (level == 2) {
        lv = LOG_WARN;
    } else {
        return;
    }
    OH_LOG_Print(LOG_APP, lv, kDomain, "NG-CORE", "%{public}s", msg);
}

// ---- socket protect 桥：Go 侧每个出站 socket 都要经过 ArkTS 的 VpnConnection.protect(fd) ----
static napi_threadsafe_function g_tsfn = nullptr;
static std::mutex g_protectMutex;
static std::condition_variable g_protectCv;
static std::map<int, bool> g_protectDone;
static std::map<int, bool> g_protectOk;
static int g_protectSeq = 1;

static bool LoadCore() {
    if (g_start != nullptr) {
        return true;
    }
    // 内核库随 HAP 一起打进 libs/arm64-v8a，运行时同目录加载。
    void *handle = dlopen("libngcore.so", RTLD_NOW | RTLD_GLOBAL);
    if (handle == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kDomain, kTag, "dlopen libngcore failed: %{public}s", dlerror());
        return false;
    }
    g_start = (FnStart)dlsym(handle, "ncore_start");
    g_stop = (FnStop)dlsym(handle, "ncore_stop");
    g_isRunning = (FnIsRunning)dlsym(handle, "ncore_is_running");
    g_stats = (FnStats)dlsym(handle, "ncore_stats");
    g_proxyDelay = (FnProxyDelay)dlsym(handle, "ncore_proxydelay");
    g_proxyDelayAsync = (FnProxyDelayAsync)dlsym(handle, "ncore_proxydelay_async");
    g_version = (FnVersion)dlsym(handle, "ncore_version");
    g_free = (FnFree)dlsym(handle, "ncore_free");
    g_setProtectCb = (FnSetProtectCb)dlsym(handle, "ncore_set_protect_cb");
    g_setLogCb = (FnSetLogCb)dlsym(handle, "ncore_set_log_cb");
    if (g_start == nullptr || g_stop == nullptr || g_stats == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kDomain, kTag, "dlsym ncore_* failed");
        return false;
    }
    // 日志桥随库加载立即生效：内核监听/拨号/保护的失败默认只写内核日志，不开桥就是黑洞
    if (g_setLogCb != nullptr) {
        g_setLogCb(GoLog);
        OH_LOG_Print(LOG_APP, LOG_INFO, kDomain, kTag, "core log bridge installed");
    }
    return true;
}

static std::string GetString(napi_env env, napi_value value) {
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::string out(len, '\0');
    napi_get_value_string_utf8(env, value, &out[0], len + 1, &len);
    return out;
}

static napi_value MakeString(napi_env env, const std::string &s) {
    napi_value result = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &result);
    return result;
}

// 由 Go 内核线程调用：把 fd 交给 JS 线程执行 protect，阻塞等待结果（最多 10s）。
static int ProtectFd(int fd) {
    if (g_tsfn == nullptr) {
        return -1;
    }
    int id = 0;
    {
        std::lock_guard<std::mutex> lock(g_protectMutex);
        id = g_protectSeq++;
        g_protectDone[id] = false;
        g_protectOk[id] = false;
    }
    int *payload = new int[2];
    payload[0] = id;
    payload[1] = fd;
    napi_status status = napi_call_threadsafe_function(g_tsfn, payload, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        delete[] payload;
        std::lock_guard<std::mutex> lock(g_protectMutex);
        g_protectDone.erase(id);
        g_protectOk.erase(id);
        return -1;
    }

    bool finished = false;
    bool ok = false;
    {
        std::unique_lock<std::mutex> lock(g_protectMutex);
        finished = g_protectCv.wait_for(lock, std::chrono::seconds(10), [id]() -> bool {
            auto it = g_protectDone.find(id);
            return it != g_protectDone.end() && it->second;
        });
        if (finished) {
            auto it = g_protectOk.find(id);
            ok = it != g_protectOk.end() && it->second;
        }
        g_protectDone.erase(id);
        g_protectOk.erase(id);
    }
    return ok ? 1 : 0;
}

// JS 线程执行体：callback(id, fd)
static void CallJsProtect(napi_env env, napi_value jsCb, void *context, void *data) {
    int *payload = static_cast<int *>(data);
    if (payload == nullptr) {
        return;
    }
    int id = payload[0];
    int fd = payload[1];
    delete[] payload;
    if (env == nullptr || jsCb == nullptr) {
        return;
    }
    napi_value argv[2] = {nullptr, nullptr};
    napi_create_int32(env, id, &argv[0]);
    napi_create_int32(env, fd, &argv[1]);
    napi_value global = nullptr;
    napi_get_undefined(env, &global);
    napi_value ignored = nullptr;
    napi_call_function(env, global, jsCb, 2, argv, &ignored);
}

// setProtectHandler(cb: (id: number, fd: number) => void)
static napi_value SetProtectHandler(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[0], &type);
    if (type != napi_function) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kDomain, kTag, "setProtectHandler: not a function");
        return nullptr;
    }
    if (!LoadCore() || g_setProtectCb == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kDomain, kTag, "setProtectHandler: core missing");
        return nullptr;
    }
    if (g_tsfn != nullptr) {
        napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
        g_tsfn = nullptr;
    }
    napi_value name = nullptr;
    napi_create_string_utf8(env, "ngnapiProtect", NAPI_AUTO_LENGTH, &name);
    napi_status status = napi_create_threadsafe_function(env, args[0], nullptr, name, 0, 1, nullptr, nullptr,
                                                         nullptr, CallJsProtect, &g_tsfn);
    if (status != napi_ok) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kDomain, kTag, "create_threadsafe_function failed: %{public}d",
                     static_cast<int>(status));
        g_tsfn = nullptr;
        return nullptr;
    }
    g_setProtectCb(ProtectFd);
    OH_LOG_Print(LOG_APP, LOG_INFO, kDomain, kTag, "protect handler installed");
    return nullptr;
}

// protectDone(id: number, ok: boolean)
static napi_value ProtectDone(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return nullptr;
    }
    int32_t id = 0;
    bool ok = false;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_bool(env, args[1], &ok);
    {
        std::lock_guard<std::mutex> lock(g_protectMutex);
        if (g_protectDone.find(id) != g_protectDone.end()) {
            g_protectDone[id] = true;
            g_protectOk[id] = ok;
        }
    }
    g_protectCv.notify_all();
    return nullptr;
}

// start(configYaml: string, homeDir: string): string  —— 返回空串表示启动成功
static napi_value Start(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (!LoadCore()) {
        return MakeString(env, "libngcore.so 加载失败");
    }
    if (argc < 2) {
        return MakeString(env, "参数不足");
    }

    std::string cfg = GetString(env, args[0]);
    std::string home = GetString(env, args[1]);

    char *err = g_start(const_cast<char *>(cfg.c_str()), const_cast<char *>(home.c_str()));
    if (err == nullptr) {
        return MakeString(env, "");
    }
    std::string message(err);
    if (g_free != nullptr) {
        g_free(err);
    }
    OH_LOG_Print(LOG_APP, LOG_ERROR, kDomain, kTag, "ncore_start failed: %{public}s", message.c_str());
    return MakeString(env, message);
}

static napi_value Stop(napi_env env, napi_callback_info info) {
    if (LoadCore()) {
        g_stop();
    }
    return nullptr;
}

static napi_value IsRunning(napi_env env, napi_callback_info info) {
    napi_value result = nullptr;
    bool running = (g_isRunning != nullptr) && g_isRunning() == 1;
    napi_get_boolean(env, running, &result);
    return result;
}

static napi_value Stats(napi_env env, napi_callback_info info) {
    if (!LoadCore()) {
        return MakeString(env, "{}");
    }
    char *json = g_stats();
    if (json == nullptr) {
        return MakeString(env, "{}");
    }
    std::string body(json);
    if (g_free != nullptr) {
        g_free(json);
    }
    return MakeString(env, body);
}

// proxyDelay(name, url, timeoutMs)：进程内做一次真实经节点的延迟测试
static napi_value ProxyDelay(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (!LoadCore() || g_proxyDelay == nullptr) {
        return MakeString(env, "{\"error\":\"core not loaded\"}");
    }
    std::string name = GetString(env, argv[0]);
    std::string url = argc > 1 ? GetString(env, argv[1]) : "";
    int timeout = 5000;
    if (argc > 2) {
        int32_t v = 0;
        napi_get_value_int32(env, argv[2], &v);
        if (v > 0) {
            timeout = v;
        }
    }
    char *json = g_proxyDelay(const_cast<char *>(name.c_str()), const_cast<char *>(url.c_str()), timeout);
    if (json == nullptr) {
        return MakeString(env, "{\"error\":\"no result\"}");
    }
    std::string body(json);
    if (g_free != nullptr) {
        g_free(json);
    }
    return MakeString(env, body);
}

// proxyDelayAsync(name, url, timeoutMs, resPath, seq)：异步测速，结果由 Go 侧写文件
static napi_value ProxyDelayAsync(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (!LoadCore() || g_proxyDelayAsync == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kDomain, kTag, "proxyDelayAsync: core missing");
        return nullptr;
    }
    std::string name = GetString(env, argv[0]);
    std::string url = GetString(env, argv[1]);
    int32_t timeout = 5000;
    if (argc > 2) {
        napi_get_value_int32(env, argv[2], &timeout);
        if (timeout <= 0) {
            timeout = 5000;
        }
    }
    std::string resPath = GetString(env, argv[3]);
    int32_t seq = 0;
    if (argc > 4) {
        napi_get_value_int32(env, argv[4], &seq);
    }
    g_proxyDelayAsync(const_cast<char *>(name.c_str()), const_cast<char *>(url.c_str()), timeout,
                      const_cast<char *>(resPath.c_str()), seq);
    return nullptr;
}

static napi_value Version(napi_env env, napi_callback_info info) {
    if (!LoadCore()) {
        return MakeString(env, "unknown");
    }
    char *v = g_version();
    if (v == nullptr) {
        return MakeString(env, "unknown");
    }
    std::string body(v);
    if (g_free != nullptr) {
        g_free(v);
    }
    return MakeString(env, body);
}

// enableCoreLog(): 把内核日志接进 hilog，域名 NG-CORE
static napi_value EnableCoreLog(napi_env env, napi_callback_info info) {
    if (!LoadCore() || g_setLogCb == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kDomain, kTag, "enableCoreLog: core missing");
        return nullptr;
    }
    g_setLogCb(GoLog);
    OH_LOG_Print(LOG_APP, LOG_INFO, kDomain, kTag, "core log bridge installed");
    return nullptr;
}

// probeFd(fd: number): string —— 诊断用：直接在扩展进程里对 tun fd 做 fstat/fcntl/getifname
static napi_value ProbeFd(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fd = -1;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &fd);
    }
    char buf[640];
    struct stat st;
    memset(&st, 0, sizeof(st));
    errno = 0;
    int rc = fstat(fd, &st);
    int e1 = errno;
    errno = 0;
    int flags = fcntl(fd, F_GETFL);
    int e2 = errno;
    char name[64];
    memset(name, 0, sizeof(name));
    errno = 0;
    int irc = ioctl(fd, 0x80087467 /* TUNGETIFF */, name);
    int e3 = errno;
    errno = 0;
    int dupfd = dup(fd);
    int e4 = errno;
    char pkt[2048];
    errno = 0;
    ssize_t rn = -1;
    if (dupfd >= 0) {
        rn = read(dupfd, pkt, sizeof(pkt));
    }
    int e5 = errno;
    char path[64];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    struct stat st2;
    memset(&st2, 0, sizeof(st2));
    errno = 0;
    int rc2 = stat(path, &st2);
    int e6 = errno;
    errno = 0;
    int ofd = open(path, O_RDWR | O_NONBLOCK);
    int e7 = errno;
    snprintf(buf, sizeof(buf),
             "fd=%d fstat rc=%d errno=%d(%s) mode=0%o | fcntl=%d errno=%d | TUNGETIFF rc=%d errno=%d "
             "| dup=%d errno=%d | read=%zd errno=%d(%s) | stat(proc) rc=%d errno=%d | open(proc)=%d errno=%d",
             fd, rc, e1, strerror(e1), (unsigned)(st.st_mode), flags, e2, irc, e3, dupfd, e4, rn, e5, strerror(e5),
             rc2, e6, ofd, e7);
    OH_LOG_Print(LOG_APP, LOG_INFO, kDomain, kTag, "probe %{public}s", buf);
    if (dupfd >= 0) {
        close(dupfd);
    }
    if (ofd >= 0) {
        close(ofd);
    }
    return MakeString(env, buf);
}

// probeDial(ip: string, port: number, timeoutMs: number): string —— 裸 TCP 探测，绕开内核判断出站是否通
static napi_value ProbeDial(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string host = (argc > 0) ? GetString(env, args[0]) : std::string();
    int32_t port = 443;
    int32_t timeoutMs = 5000;
    if (argc > 1) {
        napi_get_value_int32(env, args[1], &port);
    }
    if (argc > 2) {
        napi_get_value_int32(env, args[2], &timeoutMs);
    }
    char buf[256];
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    errno = 0;
    int rc = inet_pton(AF_INET, host.c_str(), &addr.sin_addr);
    int e0 = errno;
    int s = -1;
    int connRc = -1;
    int e1 = 0;
    if (rc == 1) {
        s = socket(AF_INET, SOCK_STREAM, 0);
        e1 = errno;
        if (s >= 0) {
            fcntl(s, F_SETFL, O_NONBLOCK);
            errno = 0;
            connRc = connect(s, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr));
            e1 = errno;
            if (connRc != 0 && e1 == EINPROGRESS) {
                struct pollfd pfd;
                pfd.fd = s;
                pfd.events = POLLOUT;
                pfd.revents = 0;
                errno = 0;
                int pr = poll(&pfd, 1, timeoutMs);
                if (pr == 1) {
                    int soErr = 0;
                    socklen_t len = sizeof(soErr);
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &len);
                    connRc = (soErr == 0) ? 0 : -1;
                    e1 = soErr;
                } else if (pr == 0) {
                    connRc = -2;
                    e1 = ETIMEDOUT;
                } else {
                    connRc = -3;
                    e1 = errno;
                }
            } else if (connRc == 0) {
                e1 = 0;
            }
        }
    }
    snprintf(buf, sizeof(buf), "dial %s:%d => rc=%d errno=%d(%s) socket=%d", host.c_str(), port, connRc, e1,
             strerror(e1), s);
    OH_LOG_Print(LOG_APP, LOG_INFO, kDomain, kTag, "probe %{public}s", buf);
    if (s >= 0) {
        close(s);
    }
    return MakeString(env, buf);
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stats", nullptr, Stats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"proxyDelay", nullptr, ProxyDelay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"proxyDelayAsync", nullptr, ProxyDelayAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setProtectHandler", nullptr, SetProtectHandler, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"protectDone", nullptr, ProtectDone, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"enableCoreLog", nullptr, EnableCoreLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeFd", nullptr, ProbeFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeDial", nullptr, ProbeDial, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "ngnapi",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterModule() {
    napi_module_register(&g_module);
}
