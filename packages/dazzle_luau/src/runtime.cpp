#include <lua.h>
#include <lualib.h>
#include <Luau/Compiler.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <vector>

#define DAZZLE_EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))

using Clock = std::chrono::steady_clock;
constexpr size_t source_limit = 64 * 1024;
constexpr size_t text_limit = 16 * 1024;
constexpr size_t heap_limit = 8 * 1024 * 1024;

struct Vm;
using DataCall = void (*)(Vm*, int, const char*, size_t, const char*, size_t,
                         const char*, size_t, int64_t, int);
struct DataRecord {
    std::string key;
    std::string value;
    int64_t revision;
};

struct Vm {
    lua_State* state = nullptr;
    size_t used = 0;
    size_t peak = 0;
    unsigned checkpoints = 0;
    bool stopped = false;
    bool exhausted = false;
    int module = 0;
    int callable = 0;
    const char* action = nullptr;
    const std::string* bytecode = nullptr;
    Clock::time_point deadline;
    char error[512] = {};
    long long load_us = 0;
    long long run_us = 0;
    DataCall data_call = nullptr;
    std::vector<DataRecord> data_records;
    size_t data_bytes = 0;
    unsigned data_calls = 0;
    long long data_wait_us = 0;
    int64_t data_revision = 0;
    bool data_changed = false;
    bool data_answered = false;
    char data_error[512] = {};
};

static void* allocate(void* ud, void* ptr, size_t old_size, size_t size) {
    auto* vm = static_cast<Vm*>(ud);
    if (!ptr) old_size = 0;
    if (!size) {
        vm->used -= old_size;
        std::free(ptr);
        return nullptr;
    }
    if (size > heap_limit || vm->used - old_size > heap_limit - size) {
        vm->exhausted = true;
        return nullptr;
    }
    void* result = std::realloc(ptr, size);
    if (result) {
        vm->used = vm->used - old_size + size;
        if (vm->used > vm->peak) vm->peak = vm->used;
    } else {
        vm->exhausted = true;
    }
    return result;
}

static Vm* owner(lua_State* state) {
    return static_cast<Vm*>(lua_callbacks(state)->userdata);
}

static void interrupt(lua_State* state, int gc) {
    if (gc >= 0) return;
    Vm* vm = owner(state);
    ++vm->checkpoints;
    if (!vm->stopped && vm->checkpoints < 100000 && Clock::now() < vm->deadline) return;
    vm->stopped = true;
    if (lua_isyieldable(state)) lua_break(state);
    else luaL_error(state, "execution budget exceeded");
}

static const char* data_string(lua_State* state, int argument, size_t* size,
                               size_t limit, bool optional = false) {
    if (optional && lua_isnoneornil(state, argument)) {
        *size = 0;
        return "";
    }
    if (lua_type(state, argument) != LUA_TSTRING) luaL_error(state, "dataset argument must be a string");
    const char* text = lua_tolstring(state, argument, size);
    if (*size > limit) luaL_error(state, "dataset argument exceeds its limit");
    return text;
}

static int64_t data_integer(lua_State* state, int argument, int64_t fallback, bool optional) {
    if (optional && lua_isnoneornil(state, argument)) return fallback;
    if (lua_type(state, argument) != LUA_TNUMBER) luaL_error(state, "dataset argument must be an integer");
    const double value = lua_tonumber(state, argument);
    if (!std::isfinite(value) || value < 0 || value > 9007199254740991.0 || std::floor(value) != value)
        luaL_error(state, "invalid dataset integer");
    return static_cast<int64_t>(value);
}

static void push_record(lua_State* state, const DataRecord& record) {
    lua_createtable(state, 0, 3);
    lua_pushlstring(state, record.key.data(), record.key.size());
    lua_setfield(state, -2, "key");
    lua_pushlstring(state, record.value.data(), record.value.size());
    lua_setfield(state, -2, "value");
    lua_pushnumber(state, static_cast<double>(record.revision));
    lua_setfield(state, -2, "revision");
    lua_setreadonly(state, -1, true);
}

static int call_data(lua_State* state, int operation) {
    Vm* vm = owner(state);
    ++vm->data_calls;
    if (!vm->data_call) luaL_error(state, "dataset APIs are unavailable during module loading");
    if (vm->stopped || vm->data_calls > 64 || Clock::now() >= vm->deadline) {
        vm->stopped = true;
        luaL_error(state, "execution or dataset call budget exceeded");
    }
    size_t alias_size = 0, key_size = 0, value_size = 0;
    const char* alias = data_string(state, 1, &alias_size, 64);
    const char* key = data_string(state, 2, &key_size, 256, operation <= 1);
    const char* value = operation == 2 || operation == 4
        ? data_string(state, 3, &value_size, text_limit) : "";
    const int64_t revision = operation >= 2
        ? data_integer(state, operation == 3 ? 3 : 4, 0, false) : 0;
    const int64_t limit = operation == 1 ? data_integer(state, 3, 32, true) : 32;
    if (limit < 1 || limit > 64) luaL_error(state, "dataset page limit must be between 1 and 64");
    vm->data_records.clear();
    vm->data_bytes = 0;
    vm->data_error[0] = 0;
    vm->data_answered = false;
    // Lua allocation must happen after the Dart callback has returned.
    const auto host_start = Clock::now();
    vm->data_call(vm, operation, alias, alias_size, key, key_size, value, value_size,
                  revision, static_cast<int>(limit));
    const auto host_elapsed = Clock::now() - host_start;
    vm->deadline += host_elapsed;
    vm->data_wait_us += std::chrono::duration_cast<std::chrono::microseconds>(host_elapsed).count();
    if (Clock::now() >= vm->deadline) {
        vm->stopped = true;
        luaL_error(state, "execution budget exceeded");
    }
    if (vm->data_error[0]) luaL_error(state, "%s", vm->data_error);
    if (!vm->data_answered) luaL_error(state, "dataset host did not answer");
    if (operation == 0) {
        if (vm->data_records.empty()) lua_pushnil(state);
        else push_record(state, vm->data_records.front());
    } else if (operation == 1) {
        lua_createtable(state, static_cast<int>(vm->data_records.size()), 0);
        for (size_t i = 0; i < vm->data_records.size(); ++i) {
            push_record(state, vm->data_records[i]);
            lua_rawseti(state, -2, static_cast<int>(i + 1));
        }
        lua_setreadonly(state, -1, true);
    } else if (operation == 2) {
        lua_pushnumber(state, static_cast<double>(vm->data_revision));
    } else {
        lua_pushboolean(state, vm->data_changed);
    }
    vm->data_records.clear();
    return 1;
}

static int data_get(lua_State* state) { return call_data(state, 0); }
static int data_query(lua_State* state) { return call_data(state, 1); }
static int data_put(lua_State* state) { return call_data(state, 2); }
static int data_delete(lua_State* state) { return call_data(state, 3); }
static int data_propose(lua_State* state) { return call_data(state, 4); }

static int prepare(lua_State* state) {
    Vm* vm = owner(state);
    luaL_openlibs(state);
    for (const char* name : {"collectgarbage", "getfenv", "setfenv", "loadstring", "require", "print", "coroutine"}) {
        lua_pushnil(state);
        lua_setglobal(state, name);
    }
    lua_createtable(state, 0, 1);
    lua_createtable(state, 0, 5);
    lua_pushcfunction(state, data_get, "data.get");
    lua_setfield(state, -2, "get");
    lua_pushcfunction(state, data_query, "data.query");
    lua_setfield(state, -2, "query");
    lua_pushcfunction(state, data_put, "data.put");
    lua_setfield(state, -2, "put");
    lua_pushcfunction(state, data_delete, "data.delete");
    lua_setfield(state, -2, "delete");
    lua_pushcfunction(state, data_propose, "data.propose");
    lua_setfield(state, -2, "propose");
    lua_setreadonly(state, -1, true);
    lua_setfield(state, -2, "data");
    lua_setreadonly(state, -1, true);
    lua_setglobal(state, "dazzle");
    luaL_sandbox(state);
    luaL_sandboxthread(state);
    if (luau_load(state, "plugin", vm->bytecode->data(), vm->bytecode->size(), 0) != 0) lua_error(state);
    vm->callable = lua_ref(state, -1);
    return 0;
}

static int retain_module(lua_State* state) {
    luaL_checktype(state, 1, LUA_TTABLE);
    owner(state)->module = lua_ref(state, 1);
    return 0;
}

static int prepare_action(lua_State* state) {
    Vm* vm = owner(state);
    lua_getref(state, vm->module);
    lua_pushstring(state, vm->action);
    lua_rawget(state, -2);
    if (!lua_isfunction(state, -1)) luaL_error(state, "declared action is missing");
    vm->callable = lua_ref(state, -1);
    return 0;
}

static bool failed(Vm* vm, int status) {
    const char* message = nullptr;
    if (vm->stopped) message = "execution budget exceeded";
    else if (vm->exhausted) message = "plugin memory limit exceeded";
    else if (status != LUA_OK) {
        message = lua_type(vm->state, -1) == LUA_TSTRING ? lua_tostring(vm->state, -1) : "plugin execution failed";
    }
    if (!message) return false;
    std::strncpy(vm->error, message, sizeof(vm->error) - 1);
    return true;
}

static int run(Vm* vm) {
    lua_getref(vm->state, vm->callable);
    const int status = lua_resume(vm->state, nullptr, 0);
    lua_unref(vm->state, vm->callable);
    vm->callable = 0;
    return status;
}

DAZZLE_EXPORT Vm* dazzle_vm_load(const char* source, size_t size) {
    auto* vm = new (std::nothrow) Vm();
    if (!vm) return nullptr;
    const auto start = Clock::now();
    if (size > source_limit) {
        std::strcpy(vm->error, "plugin source exceeds 64 KiB");
        return vm;
    }
    try {
        Luau::CompileOptions options;
        options.optimizationLevel = 1;
        const std::string bytecode = Luau::compile(std::string(source, size), options);
        vm->state = lua_newstate(allocate, vm);
        if (!vm->state) {
            std::strcpy(vm->error, "cannot allocate plugin VM");
            return vm;
        }
        lua_callbacks(vm->state)->userdata = vm;
        lua_callbacks(vm->state)->interrupt = interrupt;
        vm->bytecode = &bytecode;
        vm->deadline = Clock::now() + std::chrono::milliseconds(50);
        if (failed(vm, lua_cpcall(vm->state, prepare, nullptr))) return vm;
        vm->bytecode = nullptr;
        if (failed(vm, run(vm))) return vm;
        lua_pushcfunction(vm->state, retain_module, "retain_module");
        lua_insert(vm->state, 1);
        if (failed(vm, lua_pcall(vm->state, lua_gettop(vm->state) - 1, 0, 0))) return vm;
        vm->load_us = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - start).count();
    } catch (...) {
        std::strcpy(vm->error, "plugin compiler or runtime failed");
    }
    return vm;
}

DAZZLE_EXPORT int dazzle_vm_invoke(Vm* vm, const char* action) {
    if (!vm || !vm->state || vm->error[0]) return -1;
    const auto start = Clock::now();
    vm->action = action;
    vm->checkpoints = 0;
    vm->data_calls = 0;
    vm->data_wait_us = 0;
    vm->deadline = start + std::chrono::milliseconds(50);
    int status = -1;
    try {
        lua_resetthread(vm->state);
        if (!failed(vm, lua_cpcall(vm->state, prepare_action, nullptr))) {
            status = failed(vm, run(vm)) ? -1 : 0;
        }
    } catch (...) {
        std::strcpy(vm->error, "plugin runtime failed");
    }
    vm->run_us = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - start).count() - vm->data_wait_us;
    return status;
}

DAZZLE_EXPORT const char* dazzle_vm_error(Vm* vm) { return vm->error; }
DAZZLE_EXPORT size_t dazzle_vm_memory(Vm* vm) { return vm->used; }
DAZZLE_EXPORT size_t dazzle_vm_peak(Vm* vm) { return vm->peak; }
DAZZLE_EXPORT long long dazzle_vm_load_us(Vm* vm) { return vm->load_us; }
DAZZLE_EXPORT long long dazzle_vm_run_us(Vm* vm) { return vm->run_us; }
DAZZLE_EXPORT unsigned dazzle_vm_data_calls(Vm* vm) { return vm->data_calls; }
DAZZLE_EXPORT long long dazzle_vm_data_wait_us(Vm* vm) { return vm->data_wait_us; }
DAZZLE_EXPORT void dazzle_vm_data_callback(Vm* vm, DataCall callback) { vm->data_call = callback; }
DAZZLE_EXPORT void dazzle_vm_data_error(Vm* vm, const char* error) {
    std::strncpy(vm->data_error, error, sizeof(vm->data_error) - 1);
    vm->data_error[sizeof(vm->data_error) - 1] = 0;
}
DAZZLE_EXPORT void dazzle_vm_data_record(Vm* vm, const char* key, size_t key_size,
                                        const char* value, size_t value_size, int64_t revision) {
    if (vm->data_error[0]) return;
    if (key_size > 256 || value_size > text_limit || vm->data_records.size() >= 64 ||
        vm->data_bytes + key_size + value_size > 64 * 1024) {
        dazzle_vm_data_error(vm, "dataset response exceeds its limit");
        return;
    }
    try {
        vm->data_records.push_back({std::string(key, key_size), std::string(value, value_size), revision});
        vm->data_bytes += key_size + value_size;
    } catch (...) {
        dazzle_vm_data_error(vm, "cannot allocate dataset response");
    }
}
DAZZLE_EXPORT void dazzle_vm_data_reply(Vm* vm, int64_t revision, bool changed) {
    vm->data_revision = revision;
    vm->data_changed = changed;
    vm->data_answered = true;
}
DAZZLE_EXPORT void dazzle_vm_destroy(Vm* vm) {
    if (!vm) return;
    if (vm->state) lua_close(vm->state);
    delete vm;
}
