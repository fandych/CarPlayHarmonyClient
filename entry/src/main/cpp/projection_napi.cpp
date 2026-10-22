#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <napi/native_api.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <native_window/external_window.h>

namespace {

constexpr size_t MAX_PENDING_FRAMES = 48;
constexpr int32_t MAX_ENCODED_BUFFER_BYTES = 4 * 1024 * 1024;
constexpr int32_t MIN_DIMENSION = 320;
constexpr int32_t MAX_DIMENSION = 1920;

struct EncoderEvent {
  std::string type;
  std::string message;
  std::vector<uint8_t> data;
  int64_t timestampUs = 0;
  uint32_t flags = 0;
};

struct EncoderState {
  int64_t id = 0;
  OH_AVCodec* codec = nullptr;
  OHNativeWindow* inputWindow = nullptr;
  napi_threadsafe_function callback = nullptr;
  std::atomic<bool> running{false};
  std::atomic<bool> overflowReported{false};
};

std::mutex gEncoderMutex;
std::unordered_map<int64_t, EncoderState*> gEncoders;
std::atomic<int64_t> gNextEncoderId{1};

bool RequestSyncFrame(EncoderState* state) {
  if (state == nullptr || state->codec == nullptr || !state->running.load()) {
    return false;
  }
  OH_AVFormat* parameter = OH_AVFormat_Create();
  if (parameter == nullptr) {
    return false;
  }
  const bool setOk = OH_AVFormat_SetIntValue(parameter, OH_MD_KEY_REQUEST_I_FRAME, 1);
  const OH_AVErrCode result = setOk ? OH_VideoEncoder_SetParameter(state->codec, parameter) : AV_ERR_INVALID_VAL;
  OH_AVFormat_Destroy(parameter);
  return result == AV_ERR_OK;
}

void SetNamed(napi_env env, napi_value object, const char* name, napi_value value) {
  napi_set_named_property(env, object, name, value);
}

napi_value MakeString(napi_env env, const std::string& value) {
  napi_value result;
  napi_create_string_utf8(env, value.c_str(), value.size(), &result);
  return result;
}

void CallJs(napi_env env, napi_value function, void*, void* data) {
  std::unique_ptr<EncoderEvent> event(static_cast<EncoderEvent*>(data));
  if (env == nullptr || function == nullptr || event == nullptr) {
    return;
  }

  napi_value object;
  napi_create_object(env, &object);
  SetNamed(env, object, "type", MakeString(env, event->type));
  if (!event->message.empty()) {
    SetNamed(env, object, "message", MakeString(env, event->message));
  }
  napi_value timestamp;
  napi_create_int64(env, event->timestampUs, &timestamp);
  SetNamed(env, object, "timestampUs", timestamp);
  napi_value flags;
  napi_create_uint32(env, event->flags, &flags);
  SetNamed(env, object, "flags", flags);

  if (!event->data.empty()) {
    napi_value arrayBuffer;
    void* arrayBufferData = nullptr;
    if (napi_create_arraybuffer(env, event->data.size(), &arrayBufferData, &arrayBuffer) != napi_ok) {
      return;
    }
    std::memcpy(arrayBufferData, event->data.data(), event->data.size());
    napi_value bytes;
    if (napi_create_typedarray(env, napi_uint8_array, event->data.size(), arrayBuffer, 0, &bytes) != napi_ok) {
      return;
    }
    SetNamed(env, object, "data", bytes);
  }

  napi_value global;
  napi_get_global(env, &global);
  napi_value ignored;
  napi_call_function(env, global, function, 1, &object, &ignored);
}

void FinalizeEncoder(napi_env, void* data, void*) {
  delete static_cast<EncoderState*>(data);
}

void EmitEvent(EncoderState* state, EncoderEvent* event) {
  if (state == nullptr || state->callback == nullptr || event == nullptr) {
    delete event;
    return;
  }
  const napi_status status = napi_call_threadsafe_function(state->callback, event, napi_tsfn_nonblocking);
  if (status != napi_ok) {
    delete event;
    if (status == napi_queue_full) {
      RequestSyncFrame(state);
    }
    if (status == napi_queue_full && !state->overflowReported.exchange(true)) {
      auto* overflow = new EncoderEvent();
      overflow->type = "overflow";
      overflow->message = "H.264 output callback queue is full; frames were dropped";
      if (napi_call_threadsafe_function(state->callback, overflow, napi_tsfn_nonblocking) != napi_ok) {
        delete overflow;
      }
    }
  }
}

void OnCodecError(OH_AVCodec*, int32_t errorCode, void* userData) {
  auto* state = static_cast<EncoderState*>(userData);
  if (state == nullptr || !state->running.load()) {
    return;
  }
  auto* event = new EncoderEvent();
  event->type = "error";
  event->message = "Video encoder error " + std::to_string(errorCode);
  EmitEvent(state, event);
}

void OnStreamChanged(OH_AVCodec*, OH_AVFormat*, void* userData) {
  auto* state = static_cast<EncoderState*>(userData);
  if (state == nullptr || !state->running.load()) {
    return;
  }
  auto* event = new EncoderEvent();
  event->type = "streamChanged";
  EmitEvent(state, event);
}

void OnOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
  auto* state = static_cast<EncoderState*>(userData);
  if (state == nullptr || buffer == nullptr) {
    if (codec != nullptr) {
      OH_VideoEncoder_FreeOutputBuffer(codec, index);
    }
    return;
  }

  OH_AVCodecBufferAttr attributes{};
  const OH_AVErrCode attrResult = OH_AVBuffer_GetBufferAttr(buffer, &attributes);
  uint8_t* address = OH_AVBuffer_GetAddr(buffer);
  if (state->running.load() && attrResult == AV_ERR_OK && address != nullptr &&
      attributes.offset >= 0 && attributes.size > 0 && attributes.size <= MAX_ENCODED_BUFFER_BYTES) {
    auto* event = new EncoderEvent();
    event->type = (attributes.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) != 0 ? "codecConfig" : "frame";
    event->timestampUs = attributes.pts;
    event->flags = attributes.flags;
    event->data.assign(address + attributes.offset, address + attributes.offset + attributes.size);
    EmitEvent(state, event);
  } else if (state->running.load()) {
    auto* event = new EncoderEvent();
    event->type = "error";
    event->message = "H.264 encoder returned an invalid or oversized output buffer";
    EmitEvent(state, event);
  }
  OH_VideoEncoder_FreeOutputBuffer(codec, index);
}

bool ReadInt32(napi_env env, napi_value value, int32_t* result) {
  return napi_get_value_int32(env, value, result) == napi_ok;
}

napi_value ThrowError(napi_env env, const std::string& message) {
  napi_throw_error(env, nullptr, message.c_str());
  return nullptr;
}

void DestroyEncoder(EncoderState* state, bool abortCallback) {
  if (state == nullptr) {
    return;
  }
  state->running.store(false);
  if (state->codec != nullptr) {
    OH_VideoEncoder_Stop(state->codec);
    OH_VideoEncoder_Destroy(state->codec);
    state->codec = nullptr;
  }
  if (state->inputWindow != nullptr) {
    OH_NativeWindow_DestroyNativeWindow(state->inputWindow);
    state->inputWindow = nullptr;
  }
  if (state->callback != nullptr) {
    napi_release_threadsafe_function(
        state->callback,
        abortCallback ? napi_tsfn_abort : napi_tsfn_release
    );
    state->callback = nullptr;
  } else {
    delete state;
  }
}

napi_value CreateVideoEncoder(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value args[5];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 5) {
    return ThrowError(env, "createVideoEncoder expects width, height, fps, bitrate, and callback");
  }
  int32_t width = 0;
  int32_t height = 0;
  int32_t fps = 0;
  int32_t bitrate = 0;
  napi_valuetype callbackType;
  if (!ReadInt32(env, args[0], &width) || !ReadInt32(env, args[1], &height) ||
      !ReadInt32(env, args[2], &fps) || !ReadInt32(env, args[3], &bitrate) ||
      napi_typeof(env, args[4], &callbackType) != napi_ok || callbackType != napi_function) {
    return ThrowError(env, "Invalid H.264 encoder arguments");
  }
  if (width < MIN_DIMENSION || width > MAX_DIMENSION || height < MIN_DIMENSION ||
      height > MAX_DIMENSION || (width & 1) != 0 || (height & 1) != 0 ||
      fps < 15 || fps > 60 || bitrate < 500000 || bitrate > 20000000) {
    return ThrowError(env, "H.264 encoder dimensions, frame rate, or bitrate are out of range");
  }
  {
    std::lock_guard<std::mutex> lock(gEncoderMutex);
    if (!gEncoders.empty()) {
      return ThrowError(env, "Only one active CarPlay video encoder is supported");
    }
  }

  auto* state = new EncoderState();
  state->id = gNextEncoderId.fetch_add(1);
  napi_value resourceName = MakeString(env, "CarPlayH264Output");
  if (napi_create_threadsafe_function(
          env,
          args[4],
          nullptr,
          resourceName,
          MAX_PENDING_FRAMES,
          1,
          state,
          FinalizeEncoder,
          nullptr,
          CallJs,
          &state->callback) != napi_ok) {
    delete state;
    return ThrowError(env, "Unable to create H.264 output callback");
  }

  state->codec = OH_VideoEncoder_CreateByMime("video/avc");
  if (state->codec == nullptr) {
    DestroyEncoder(state, true);
    return ThrowError(env, "HarmonyOS has no available H.264 video encoder");
  }

  const OH_AVCodecCallback callbacks = {
      .onError = OnCodecError,
      .onStreamChanged = OnStreamChanged,
      .onNeedInputBuffer = nullptr,
      .onNewOutputBuffer = OnOutputBuffer
  };
  if (OH_VideoEncoder_RegisterCallback(state->codec, callbacks, state) != AV_ERR_OK) {
    DestroyEncoder(state, true);
    return ThrowError(env, "Unable to register H.264 encoder callbacks");
  }

  OH_AVFormat* format = OH_AVFormat_CreateVideoFormat("video/avc", width, height);
  if (format == nullptr) {
    DestroyEncoder(state, true);
    return ThrowError(env, "Unable to allocate H.264 encoder format");
  }
  const bool formatOk =
      OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, bitrate) &&
      OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, fps) &&
      OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, 1);
  const OH_AVErrCode configureResult =
      formatOk ? OH_VideoEncoder_Configure(state->codec, format) : AV_ERR_INVALID_VAL;
  OH_AVFormat_Destroy(format);
  if (configureResult != AV_ERR_OK) {
    DestroyEncoder(state, true);
    return ThrowError(env, "Unable to configure H.264 video encoder");
  }

  if (OH_VideoEncoder_GetSurface(state->codec, &state->inputWindow) != AV_ERR_OK ||
      state->inputWindow == nullptr) {
    DestroyEncoder(state, true);
    return ThrowError(env, "Unable to obtain H.264 encoder input surface");
  }
  uint64_t surfaceId = 0;
  if (OH_NativeWindow_GetSurfaceId(state->inputWindow, &surfaceId) != 0) {
    DestroyEncoder(state, true);
    return ThrowError(env, "Unable to obtain H.264 encoder surface ID");
  }
  if (OH_VideoEncoder_Prepare(state->codec) != AV_ERR_OK) {
    DestroyEncoder(state, true);
    return ThrowError(env, "Unable to prepare H.264 video encoder");
  }
  state->running.store(true);
  {
    std::lock_guard<std::mutex> lock(gEncoderMutex);
    gEncoders.emplace(state->id, state);
  }
  if (OH_VideoEncoder_Start(state->codec) != AV_ERR_OK) {
    {
      std::lock_guard<std::mutex> lock(gEncoderMutex);
      gEncoders.erase(state->id);
    }
    DestroyEncoder(state, true);
    return ThrowError(env, "Unable to start H.264 video encoder");
  }

  napi_value result;
  napi_create_object(env, &result);
  napi_value handle;
  napi_create_int64(env, state->id, &handle);
  SetNamed(env, result, "handle", handle);
  SetNamed(env, result, "surfaceId", MakeString(env, std::to_string(surfaceId)));
  return result;
}

napi_value StopVideoEncoder(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
    return ThrowError(env, "stopVideoEncoder expects an encoder handle");
  }
  int64_t handle = 0;
  if (napi_get_value_int64(env, args[0], &handle) != napi_ok) {
    return ThrowError(env, "Invalid H.264 encoder handle");
  }
  EncoderState* state = nullptr;
  {
    std::lock_guard<std::mutex> lock(gEncoderMutex);
    const auto found = gEncoders.find(handle);
    if (found == gEncoders.end()) {
      napi_value undefined;
      napi_get_undefined(env, &undefined);
      return undefined;
    }
    state = found->second;
    gEncoders.erase(found);
  }
  DestroyEncoder(state, true);
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value RequestKeyFrame(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
    return ThrowError(env, "requestKeyFrame expects an encoder handle");
  }
  int64_t handle = 0;
  if (napi_get_value_int64(env, args[0], &handle) != napi_ok) {
    return ThrowError(env, "Invalid H.264 encoder handle");
  }
  EncoderState* state = nullptr;
  {
    std::lock_guard<std::mutex> lock(gEncoderMutex);
    const auto found = gEncoders.find(handle);
    if (found != gEncoders.end()) {
      state = found->second;
    }
  }
  if (state == nullptr || state->codec == nullptr || !state->running.load()) {
    return ThrowError(env, "H.264 encoder is not running");
  }
  if (!RequestSyncFrame(state)) {
    return ThrowError(env, "Unable to request H.264 key frame");
  }
  napi_value success;
  napi_get_boolean(env, true, &success);
  return success;
}

napi_value Init(napi_env env, napi_value exports) {
  const napi_property_descriptor properties[] = {
      {"createVideoEncoder", nullptr, CreateVideoEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stopVideoEncoder", nullptr, StopVideoEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"requestKeyFrame", nullptr, RequestKeyFrame, nullptr, nullptr, nullptr, napi_default, nullptr}
  };
  napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
  return exports;
}

}  // namespace

NAPI_MODULE(projection, Init)
