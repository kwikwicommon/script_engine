#include <quickjs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

typedef struct {
  char *output;
  size_t output_len;
  size_t output_cap;
  int64_t deadline_ms;
} ForceSniffQuickJsState;

static int64_t forcesniff_now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return ((int64_t)tv.tv_sec * 1000) + ((int64_t)tv.tv_usec / 1000);
}

static char *forcesniff_strdup(const char *value) {
  if (value == NULL) {
    value = "";
  }
  size_t length = strlen(value);
  char *copy = (char *)malloc(length + 1);
  if (copy == NULL) {
    return NULL;
  }
  memcpy(copy, value, length);
  copy[length] = '\0';
  return copy;
}

static int forcesniff_reserve(ForceSniffQuickJsState *state, size_t length) {
  if (length + 1 <= state->output_cap) {
    return 0;
  }
  size_t next_cap = state->output_cap == 0 ? 256 : state->output_cap;
  while (next_cap < length + 1) {
    next_cap *= 2;
  }
  char *next = (char *)realloc(state->output, next_cap);
  if (next == NULL) {
    return -1;
  }
  state->output = next;
  state->output_cap = next_cap;
  return 0;
}

static int forcesniff_set_output(ForceSniffQuickJsState *state,
                                 const char *value) {
  size_t length = strlen(value);
  if (forcesniff_reserve(state, length) != 0) {
    return -1;
  }
  memcpy(state->output, value, length);
  state->output[length] = '\0';
  state->output_len = length;
  return 0;
}

static int forcesniff_append_output(ForceSniffQuickJsState *state,
                                    const char *value) {
  size_t value_len = strlen(value);
  size_t next_len = state->output_len + value_len;
  if (forcesniff_reserve(state, next_len) != 0) {
    return -1;
  }
  memcpy(state->output + state->output_len, value, value_len);
  state->output[next_len] = '\0';
  state->output_len = next_len;
  return 0;
}

static int forcesniff_interrupt_handler(JSRuntime *runtime, void *opaque) {
  (void)runtime;
  ForceSniffQuickJsState *state = (ForceSniffQuickJsState *)opaque;
  if (state == NULL || state->deadline_ms <= 0) {
    return 0;
  }
  return forcesniff_now_ms() > state->deadline_ms;
}

static JSValue forcesniff_print(JSContext *ctx, JSValueConst this_val, int argc,
                                JSValueConst *argv) {
  (void)this_val;
  ForceSniffQuickJsState *state =
      (ForceSniffQuickJsState *)JS_GetContextOpaque(ctx);
  if (state == NULL) {
    return JS_UNDEFINED;
  }
  state->output_len = 0;
  if (state->output != NULL) {
    state->output[0] = '\0';
  }
  for (int index = 0; index < argc; index++) {
    const char *item = JS_ToCString(ctx, argv[index]);
    if (item == NULL) {
      item = "";
    }
    if (index > 0) {
      forcesniff_append_output(state, " ");
    }
    forcesniff_append_output(state, item);
    JS_FreeCString(ctx, item);
  }
  return JS_UNDEFINED;
}

static char *forcesniff_json_error(const char *message) {
  const char *prefix = "{\"errors\":[\"";
  const char *suffix = "\"]}";
  size_t message_len = strlen(message == NULL ? "" : message);
  size_t cap = strlen(prefix) + (message_len * 2) + strlen(suffix) + 1;
  char *json = (char *)malloc(cap);
  if (json == NULL) {
    return NULL;
  }
  size_t offset = 0;
  offset += snprintf(json + offset, cap - offset, "%s", prefix);
  for (size_t index = 0; index < message_len && offset + 3 < cap; index++) {
    char ch = message[index];
    if (ch == '"' || ch == '\\') {
      json[offset++] = '\\';
      json[offset++] = ch;
    } else if (ch == '\n' || ch == '\r' || ch == '\t') {
      json[offset++] = ' ';
    } else {
      json[offset++] = ch;
    }
  }
  snprintf(json + offset, cap - offset, "%s", suffix);
  return json;
}

/* Track genuinely unhandled rejections after the host drains promise jobs. */
static void forcesniff_track_rejection(JSContext *ctx, JSValueConst promise,
                                       JSValueConst reason, JS_BOOL handled,
                                       void *opaque) {
  (void)opaque;
  JSValue global = JS_GetGlobalObject(ctx);
  JSValue tracker = JS_GetPropertyStr(ctx, global, "__forceTrackRejection");
  if (JS_IsFunction(ctx, tracker)) {
    JSValue args[3] = {promise, reason, JS_NewBool(ctx, handled)};
    JSValue result = JS_Call(ctx, tracker, JS_UNDEFINED, 3, args);
    if (JS_IsException(result)) {
      JSValue exception = JS_GetException(ctx);
      JS_FreeValue(ctx, exception);
    }
    JS_FreeValue(ctx, result);
  }
  JS_FreeValue(ctx, tracker);
  JS_FreeValue(ctx, global);
}

char *ForceSniffQuickJsExecute(const char *source, int timeout_ms,
                               int64_t memory_limit_bytes) {
  if (source == NULL) {
    return forcesniff_json_error("QuickJS source is empty.");
  }

  ForceSniffQuickJsState state;
  memset(&state, 0, sizeof(state));
  if (timeout_ms > 0) {
    state.deadline_ms = forcesniff_now_ms() + timeout_ms;
  }

  JSRuntime *runtime = JS_NewRuntime();
  if (runtime == NULL) {
    return forcesniff_json_error("QuickJS runtime allocation failed.");
  }
  if (memory_limit_bytes > 0) {
    JS_SetMemoryLimit(runtime, (size_t)memory_limit_bytes);
  }
  JS_SetInterruptHandler(runtime, forcesniff_interrupt_handler, &state);
  JS_SetHostPromiseRejectionTracker(runtime, forcesniff_track_rejection, NULL);

  JSContext *ctx = JS_NewContext(runtime);
  if (ctx == NULL) {
    JS_FreeRuntime(runtime);
    return forcesniff_json_error("QuickJS context allocation failed.");
  }
  JS_SetContextOpaque(ctx, &state);

  JSValue global = JS_GetGlobalObject(ctx);
  JS_SetPropertyStr(
      ctx, global, "print",
      JS_NewCFunction(ctx, forcesniff_print, "print", 1));
  JS_FreeValue(ctx, global);

  JSValue result =
      JS_Eval(ctx, source, strlen(source), "<forcesniff-script>",
              JS_EVAL_TYPE_GLOBAL);
  char *output = NULL;
  if (JS_IsException(result)) {
    JSValue exception = JS_GetException(ctx);
    const char *message = JS_ToCString(ctx, exception);
    output = forcesniff_json_error(message == NULL ? "QuickJS exception."
                                                   : message);
    JS_FreeCString(ctx, message);
    JS_FreeValue(ctx, exception);
  } else if (state.output != NULL && state.output_len > 0) {
    output = forcesniff_strdup(state.output);
  } else {
    output = forcesniff_strdup("{}");
  }

  JS_FreeValue(ctx, result);
  JS_FreeContext(ctx);
  JS_FreeRuntime(runtime);
  free(state.output);
  return output;
}

void ForceSniffQuickJsFree(char *ptr) {
  free(ptr);
}

const char *ForceSniffQuickJsRuntimeManifestJSON(void) {
  return "{\"name\":\"ForceSniff QuickJS Runtime\",\"abi\":1,"
         "\"features\":[\"memory_limit\",\"interrupt_timeout\"]}";
}

/* A session owns one context until the host has delivered all asynchronous work. */
typedef struct {
  JSRuntime *runtime;
  JSContext *ctx;
  ForceSniffQuickJsState state;
} ForceSniffQuickJsSession;

void *ForceSniffQuickJsSessionCreate(int64_t memory_limit_bytes) {
  ForceSniffQuickJsSession *session = calloc(1, sizeof(*session));
  if (!session) return NULL;
  session->runtime = JS_NewRuntime();
  if (!session->runtime) { free(session); return NULL; }
  JS_SetMemoryLimit(session->runtime, (size_t)memory_limit_bytes);
  JS_SetInterruptHandler(session->runtime, forcesniff_interrupt_handler, &session->state);
  JS_SetHostPromiseRejectionTracker(session->runtime, forcesniff_track_rejection, NULL);
  session->ctx = JS_NewContext(session->runtime);
  if (!session->ctx) { JS_FreeRuntime(session->runtime); free(session); return NULL; }
  JS_SetContextOpaque(session->ctx, &session->state);
  JSValue global = JS_GetGlobalObject(session->ctx);
  JS_SetPropertyStr(session->ctx, global, "print", JS_NewCFunction(session->ctx, forcesniff_print, "print", 1));
  JS_FreeValue(session->ctx, global);
  return session;
}

char *ForceSniffQuickJsSessionEval(void *opaque, const char *source, int timeout_ms) {
  ForceSniffQuickJsSession *session = opaque;
  session->state.deadline_ms = forcesniff_now_ms() + timeout_ms;
  session->state.output_len = 0;
  if (session->state.output) session->state.output[0] = 0;
  JSContext *ctx = session->ctx;
  JSValue result = JS_Eval(ctx, source, strlen(source), "<forceapi-session>", JS_EVAL_TYPE_GLOBAL);
  int failed = JS_IsException(result);
  JS_FreeValue(ctx, result);
  while (!failed && JS_IsJobPending(session->runtime)) {
    if (forcesniff_now_ms() > session->state.deadline_ms) {
      return forcesniff_json_error("JavaScript execution timed out.");
    }
    failed = JS_ExecutePendingJob(session->runtime, &ctx) < 0;
  }
  if (forcesniff_now_ms() > session->state.deadline_ms) {
    return forcesniff_json_error("JavaScript execution timed out.");
  }
  if (failed) {
    JSValue exception = JS_GetException(ctx);
    const char *message = JS_ToCString(ctx, exception);
    char *output = forcesniff_json_error(message ? message : "QuickJS exception.");
    JS_FreeCString(ctx, message);
    JS_FreeValue(ctx, exception);
    return output;
  }
  return forcesniff_strdup(session->state.output_len ? session->state.output : "{}");
}

void ForceSniffQuickJsSessionDestroy(void *opaque) {
  ForceSniffQuickJsSession *session = opaque;
  if (!session) return;
  JS_FreeContext(session->ctx);
  JS_FreeRuntime(session->runtime);
  free(session->state.output);
  free(session);
}
