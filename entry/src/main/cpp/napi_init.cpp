#include <atomic>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include <napi/native_api.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avscreen_capture.h>

namespace {

struct CaptureState;

struct CaptureEvent {
    ~CaptureEvent()
    {
        std::fill(data.begin(), data.end(), 0);
    }

    std::string kind;
    std::vector<uint8_t> data;
    int32_t state = 0;
    int32_t error = 0;
    uint32_t dropped = 0;
    uint32_t flags = 0;
    int64_t timestamp = 0;
    CaptureState *owner = nullptr;
};

struct CaptureState {
    OH_AVScreenCapture *capture = nullptr;
    napi_threadsafe_function callback = nullptr;
    std::atomic<bool> stopping{false};
    std::atomic<bool> started{false};
    std::atomic<uint32_t> outstandingBuffers{0};
    std::atomic<uint32_t> droppedBuffers{0};
    int32_t width = 0;
    int32_t height = 0;
};

std::mutex g_stateMutex;
CaptureState *g_state = nullptr;
constexpr int32_t MAX_ENCODED_BUFFER_BYTES = 4 * 1024 * 1024;
constexpr uint32_t MAX_QUEUED_VIDEO_BUFFERS = 8;

void EmitEvent(CaptureState *state, CaptureEvent *event);

void EmitCaptureError(CaptureState *state, int32_t code)
{
    auto *event = new (std::nothrow) CaptureEvent();
    if (event == nullptr) {
        return;
    }
    event->kind = "error";
    event->error = code;
    EmitEvent(state, event);
}

void CallJavaScript(napi_env env, napi_value callback, void *, void *data)
{
    std::unique_ptr<CaptureEvent> event(static_cast<CaptureEvent *>(data));
    if (event != nullptr && event->kind == "buffer" && event->owner != nullptr) {
        event->owner->outstandingBuffers.fetch_sub(1);
    }
    if (env == nullptr || callback == nullptr || event == nullptr) {
        return;
    }

    napi_value value = nullptr;
    napi_value field = nullptr;
    if (napi_create_object(env, &value) != napi_ok ||
        napi_create_string_utf8(env, event->kind.c_str(), NAPI_AUTO_LENGTH, &field) != napi_ok ||
        napi_set_named_property(env, value, "kind", field) != napi_ok) {
        return;
    }

    if (event->kind == "buffer") {
        void *bufferData = nullptr;
        napi_value arrayBuffer = nullptr;
        if (napi_create_arraybuffer(env, event->data.size(), &bufferData, &arrayBuffer) != napi_ok) {
            return;
        }
        if (!event->data.empty()) {
            std::memcpy(bufferData, event->data.data(), event->data.size());
        }
        if (napi_set_named_property(env, value, "data", arrayBuffer) != napi_ok ||
            napi_create_uint32(env, event->flags, &field) != napi_ok ||
            napi_set_named_property(env, value, "flags", field) != napi_ok ||
            napi_create_double(env, static_cast<double>(event->timestamp), &field) != napi_ok ||
            napi_set_named_property(env, value, "timestamp", field) != napi_ok) {
            return;
        }
    } else if (event->kind == "state") {
        if (napi_create_int32(env, event->state, &field) != napi_ok ||
            napi_set_named_property(env, value, "state", field) != napi_ok) {
            return;
        }
    } else if (event->kind == "overflow") {
        if (napi_create_uint32(env, event->dropped, &field) != napi_ok ||
            napi_set_named_property(env, value, "dropped", field) != napi_ok) {
            return;
        }
    } else {
        if (napi_create_int32(env, event->error, &field) != napi_ok ||
            napi_set_named_property(env, value, "code", field) != napi_ok) {
            return;
        }
    }

    napi_value global = nullptr;
    if (napi_get_global(env, &global) == napi_ok) {
        napi_call_function(env, global, callback, 1, &value, nullptr);
    }
}

void FinalizeCaptureState(napi_env, void *data, void *)
{
    auto *state = static_cast<CaptureState *>(data);
    if (state == nullptr) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        if (g_state == state) {
            g_state = nullptr;
        }
    }
    delete state;
}

void EmitEvent(CaptureState *state, CaptureEvent *event)
{
    if (state == nullptr || event == nullptr || state->stopping.load() || state->callback == nullptr) {
        delete event;
        return;
    }
    napi_threadsafe_function callback = state->callback;
    if (napi_acquire_threadsafe_function(callback) != napi_ok) {
        if (event->kind == "buffer") {
            state->droppedBuffers.fetch_add(1);
        }
        delete event;
        return;
    }
    if (event->kind == "buffer") {
        const uint32_t queued = state->outstandingBuffers.fetch_add(1);
        if (queued >= MAX_QUEUED_VIDEO_BUFFERS) {
            state->outstandingBuffers.fetch_sub(1);
            state->droppedBuffers.fetch_add(1);
            delete event;
            const uint32_t dropped = state->droppedBuffers.exchange(0);
            auto *overflow = new (std::nothrow) CaptureEvent();
            if (overflow != nullptr) {
                overflow->kind = "overflow";
                overflow->dropped = dropped;
                if (napi_call_threadsafe_function(callback, overflow, napi_tsfn_nonblocking) != napi_ok) {
                    state->droppedBuffers.fetch_add(dropped);
                    delete overflow;
                }
            } else {
                state->droppedBuffers.fetch_add(dropped);
            }
            napi_release_threadsafe_function(callback, napi_tsfn_release);
            return;
        }
        event->owner = state;
    }
    const uint32_t dropped = state->droppedBuffers.exchange(0);
    if (dropped > 0) {
        auto *overflow = new (std::nothrow) CaptureEvent();
        if (overflow == nullptr) {
            state->droppedBuffers.fetch_add(dropped);
            if (event->kind == "buffer") {
                state->outstandingBuffers.fetch_sub(1);
                state->droppedBuffers.fetch_add(1);
            }
            delete event;
            napi_release_threadsafe_function(callback, napi_tsfn_release);
            return;
        }
        overflow->kind = "overflow";
        overflow->dropped = dropped;
        if (napi_call_threadsafe_function(callback, overflow, napi_tsfn_nonblocking) != napi_ok) {
            state->droppedBuffers.fetch_add(dropped);
            delete overflow;
            if (event->kind == "buffer") {
                state->outstandingBuffers.fetch_sub(1);
                state->droppedBuffers.fetch_add(1);
            }
            delete event;
            napi_release_threadsafe_function(callback, napi_tsfn_release);
            return;
        }
    }
    const napi_status status = napi_call_threadsafe_function(
        callback,
        event,
        napi_tsfn_nonblocking
    );
    if (status != napi_ok) {
        if (event->kind != "overflow") {
            state->droppedBuffers.fetch_add(1);
        }
        if (event->kind == "buffer") {
            state->outstandingBuffers.fetch_sub(1);
        }
        delete event;
    }
    napi_release_threadsafe_function(callback, napi_tsfn_release);
}

void OnStateChange(OH_AVScreenCapture *, OH_AVScreenCaptureStateCode stateCode, void *userData)
{
    auto *state = static_cast<CaptureState *>(userData);
    if (state == nullptr) {
        return;
    }
    if (stateCode == OH_SCREEN_CAPTURE_STATE_STARTED) {
        state->started.store(true);
    } else if (stateCode != OH_SCREEN_CAPTURE_STATE_PAUSED_BY_USER &&
        stateCode != OH_SCREEN_CAPTURE_STATE_PAUSED_BY_APP) {
        state->started.store(false);
    }
    auto *event = new CaptureEvent();
    event->kind = "state";
    event->state = static_cast<int32_t>(stateCode);
    EmitEvent(state, event);
}

void OnCaptureError(OH_AVScreenCapture *, int32_t errorCode, void *userData)
{
    auto *state = static_cast<CaptureState *>(userData);
    if (state == nullptr) {
        return;
    }
    state->started.store(false);
    auto *event = new CaptureEvent();
    event->kind = "error";
    event->error = errorCode;
    EmitEvent(state, event);
}

void OnBufferAvailable(OH_AVScreenCapture *, OH_AVBuffer *buffer, OH_AVScreenCaptureBufferType bufferType,
    int64_t timestamp, void *userData)
{
    auto *state = static_cast<CaptureState *>(userData);
    if (state == nullptr || bufferType != OH_SCREEN_CAPTURE_BUFFERTYPE_VIDEO || buffer == nullptr) {
        return;
    }
    OH_AVCodecBufferAttr attr{};
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK || attr.size <= 0 || attr.offset < 0 ||
        attr.size > MAX_ENCODED_BUFFER_BYTES) {
        EmitCaptureError(state, AV_SCREEN_CAPTURE_ERR_INVALID_VAL);
        return;
    }
    const int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
    uint8_t *address = OH_AVBuffer_GetAddr(buffer);
    if (address == nullptr || capacity < 0 || attr.offset > capacity || attr.size > capacity - attr.offset) {
        EmitCaptureError(state, AV_SCREEN_CAPTURE_ERR_INVALID_VAL);
        return;
    }

    auto *event = new (std::nothrow) CaptureEvent();
    if (event == nullptr) {
        EmitCaptureError(state, AV_SCREEN_CAPTURE_ERR_NO_MEMORY);
        return;
    }
    event->kind = "buffer";
    event->flags = attr.flags;
    event->timestamp = timestamp > 0 ? timestamp : attr.pts * 1000;
    try {
        event->data.assign(address + attr.offset, address + attr.offset + attr.size);
    } catch (const std::exception &) {
        delete event;
        EmitCaptureError(state, AV_SCREEN_CAPTURE_ERR_NO_MEMORY);
        return;
    }
    EmitEvent(state, event);
}

napi_value ThrowError(napi_env env, const char *message)
{
    napi_throw_error(env, nullptr, message);
    return nullptr;
}

int32_t ReleaseCapture(CaptureState *state)
{
    if (state == nullptr) {
        return AV_SCREEN_CAPTURE_ERR_OK;
    }
    state->stopping.store(true);
    int32_t result = AV_SCREEN_CAPTURE_ERR_OK;
    if (state->capture != nullptr) {
        if (state->started.exchange(false)) {
            result = OH_AVScreenCapture_StopScreenCapture(state->capture);
        }
        const int32_t releaseResult = OH_AVScreenCapture_Release(state->capture);
        state->capture = nullptr;
        if (result == AV_SCREEN_CAPTURE_ERR_OK) {
            result = releaseResult;
        }
    }
    return result;
}

void AbortState(CaptureState *state)
{
    if (state == nullptr) {
        return;
    }
    ReleaseCapture(state);
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        if (g_state == state) {
            g_state = nullptr;
        }
    }
    napi_threadsafe_function callback = state->callback;
    state->callback = nullptr;
    if (callback != nullptr) {
        napi_release_threadsafe_function(callback, napi_tsfn_abort);
    }
}

napi_value StartCapture(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 4) {
        return ThrowError(env, "startCapture requires width, height, display ID, and a callback.");
    }
    napi_valuetype widthType;
    napi_valuetype heightType;
    napi_valuetype displayIdType;
    napi_valuetype callbackType;
    int32_t width = 0;
    int32_t height = 0;
    uint32_t displayId = 0;
    if (napi_typeof(env, args[0], &widthType) != napi_ok || widthType != napi_number ||
        napi_typeof(env, args[1], &heightType) != napi_ok || heightType != napi_number ||
        napi_typeof(env, args[2], &displayIdType) != napi_ok || displayIdType != napi_number ||
        napi_typeof(env, args[3], &callbackType) != napi_ok || callbackType != napi_function ||
        napi_get_value_int32(env, args[0], &width) != napi_ok ||
        napi_get_value_int32(env, args[1], &height) != napi_ok ||
        napi_get_value_uint32(env, args[2], &displayId) != napi_ok ||
        width < 2 || height < 2 || (width & 1) != 0 || (height & 1) != 0 || width > 4096 || height > 4096) {
        return ThrowError(env, "Capture dimensions must be even integers between 2 and 4096.");
    }

    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        if (g_state != nullptr) {
            return ThrowError(env, "A screen capture session is already active.");
        }
    }

    auto *state = new CaptureState();
    state->width = width;
    state->height = height;
    napi_value resourceName = nullptr;
    if (napi_create_string_utf8(env, "CarPlayScreenCapture", NAPI_AUTO_LENGTH, &resourceName) != napi_ok ||
        napi_create_threadsafe_function(env, args[3], nullptr, resourceName, 0, 1, state,
            FinalizeCaptureState, nullptr, CallJavaScript, &state->callback) != napi_ok) {
        delete state;
        return ThrowError(env, "Unable to create the screen capture callback.");
    }
    bool alreadyActive = false;
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        alreadyActive = g_state != nullptr;
        if (!alreadyActive) {
            g_state = state;
        }
    }
    if (alreadyActive) {
        napi_threadsafe_function callback = state->callback;
        state->callback = nullptr;
        napi_release_threadsafe_function(callback, napi_tsfn_abort);
        return ThrowError(env, "A screen capture session is already active.");
    }

    state->capture = OH_AVScreenCapture_Create();
    if (state->capture == nullptr) {
        AbortState(state);
        return ThrowError(env, "Unable to create the HarmonyOS screen capture instance.");
    }

    OH_AVScreenCaptureConfig config{};
    config.captureMode = OH_CAPTURE_SPECIFIED_SCREEN;
    config.dataType = OH_ENCODED_STREAM;
    config.videoInfo.videoCapInfo.displayId = displayId;
    config.videoInfo.videoCapInfo.videoFrameWidth = width;
    config.videoInfo.videoCapInfo.videoFrameHeight = height;
    config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_ES;
    config.videoInfo.videoEncInfo.videoCodec = OH_H264;
    config.videoInfo.videoEncInfo.videoBitrate = 4000000;
    config.videoInfo.videoEncInfo.videoFrameRate = 30;

    if (OH_AVScreenCapture_Init(state->capture, config) != AV_SCREEN_CAPTURE_ERR_OK ||
        OH_AVScreenCapture_SetStateCallback(state->capture, OnStateChange, state) != AV_SCREEN_CAPTURE_ERR_OK ||
        OH_AVScreenCapture_SetErrorCallback(state->capture, OnCaptureError, state) != AV_SCREEN_CAPTURE_ERR_OK ||
        OH_AVScreenCapture_SetDataCallback(state->capture, OnBufferAvailable, state) != AV_SCREEN_CAPTURE_ERR_OK) {
        AbortState(state);
        return ThrowError(env, "Unable to initialize HarmonyOS screen capture and encoded-video callbacks.");
    }

    if (OH_AVScreenCapture_StartScreenCapture(state->capture) != AV_SCREEN_CAPTURE_ERR_OK) {
        AbortState(state);
        return ThrowError(env, "HarmonyOS screen capture could not be started or was not authorized.");
    }

    napi_value undefinedValue = nullptr;
    napi_get_undefined(env, &undefinedValue);
    return undefinedValue;
}

napi_value StopCapture(napi_env env, napi_callback_info)
{
    CaptureState *state = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        state = g_state;
        if (state == nullptr) {
            napi_value undefinedValue = nullptr;
            napi_get_undefined(env, &undefinedValue);
            return undefinedValue;
        }
        state->stopping.store(true);
        g_state = nullptr;
    }

    const int32_t result = ReleaseCapture(state);
    napi_threadsafe_function callback = state->callback;
    state->callback = nullptr;
    if (callback != nullptr) {
        napi_release_threadsafe_function(callback, napi_tsfn_abort);
    }
    if (result != AV_SCREEN_CAPTURE_ERR_OK) {
        return ThrowError(env, "HarmonyOS screen capture cleanup failed.");
    }
    napi_value undefinedValue = nullptr;
    napi_get_undefined(env, &undefinedValue);
    return undefinedValue;
}

napi_value Initialize(napi_env env, napi_value exports)
{
    napi_value start = nullptr;
    napi_value stop = nullptr;
    if (napi_create_function(env, "startCapture", NAPI_AUTO_LENGTH, StartCapture, nullptr, &start) != napi_ok ||
        napi_create_function(env, "stopCapture", NAPI_AUTO_LENGTH, StopCapture, nullptr, &stop) != napi_ok ||
        napi_set_named_property(env, exports, "startCapture", start) != napi_ok ||
        napi_set_named_property(env, exports, "stopCapture", stop) != napi_ok) {
        return ThrowError(env, "Unable to initialize the CarPlay screen capture module.");
    }
    return exports;
}

napi_module g_module = {
    1,
    0,
    nullptr,
    Initialize,
    "entry",
    nullptr,
    {0}
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterCarPlayScreenCaptureModule()
{
    napi_module_register(&g_module);
}
