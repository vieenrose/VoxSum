// JNI bridge for the nemo-x-asr-diarizer streaming engine (studio.voxsum.core.asr.NemoNative).
//
// Segments cross the boundary as one string: records separated by RS (0x1e), fields by US (0x1f):
//   speaker US start_s US end_s US text
// Cheaper and simpler than building Java objects per segment, and the text never contains either byte.
#include <jni.h>
#include <android/log.h>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "engine.h"

namespace {

struct Handle {
    std::unique_ptr<nemo::Engine> engine;
    std::mutex mu;
};

std::string encode_segment(const nemo::Segment& s) {
    char head[96];
    std::snprintf(head, sizeof head, "%d\x1f%.3f\x1f%.3f\x1f", s.speaker, s.start_s, s.end_s);
    return std::string(head) + s.text + "\x1e";
}

jstring to_jstring(JNIEnv* env, const std::string& s) {
    // NewStringUTF wants MODIFIED UTF-8; build from UTF-8 bytes via String(byte[], "UTF-8") instead so
    // 4-byte code points (emoji, CJK extension B) survive.
    jbyteArray bytes = env->NewByteArray((jsize)s.size());
    env->SetByteArrayRegion(bytes, 0, (jsize)s.size(), reinterpret_cast<const jbyte*>(s.data()));
    jclass str = env->FindClass("java/lang/String");
    jmethodID ctor = env->GetMethodID(str, "<init>", "([BLjava/lang/String;)V");
    jstring enc = env->NewStringUTF("UTF-8");
    auto out = (jstring)env->NewObject(str, ctor, bytes, enc);
    env->DeleteLocalRef(bytes);
    env->DeleteLocalRef(enc);
    env->DeleteLocalRef(str);
    return out;
}

std::string from_jstring(JNIEnv* env, jstring s) {
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string out(c);
    env->ReleaseStringUTFChars(s, c);
    return out;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_studio_voxsum_core_asr_NemoNative_nativeCreate(JNIEnv* env, jclass, jstring xasr, jstring diar, jint threads,
                                                      jdouble settle_s) {
    nemo::Config cfg;
    cfg.xasr_model = from_jstring(env, xasr);
    cfg.diar_model = from_jstring(env, diar);
    cfg.threads = threads;
    cfg.max_segment_s = 10.0;   // one transcript line per ~10 s sentence group
    cfg.live_settle_s = settle_s;
    auto h = std::make_unique<Handle>();
    h->engine = std::make_unique<nemo::Engine>(cfg);
    std::string err;
    if (!h->engine->init(err)) {
        __android_log_print(ANDROID_LOG_ERROR, "voxsum-nemo", "init failed: %s", err.c_str());
        return 0;
    }
    h->engine->begin();
    return reinterpret_cast<jlong>(h.release());
}

JNIEXPORT jboolean JNICALL
Java_studio_voxsum_core_asr_NemoNative_nativePush(JNIEnv* env, jclass, jlong ptr, jfloatArray pcm, jint n) {
    auto* h = reinterpret_cast<Handle*>(ptr);
    jfloat* p = env->GetFloatArrayElements(pcm, nullptr);
    std::string err;
    bool ok;
    {
        std::lock_guard<std::mutex> lk(h->mu);
        ok = h->engine->push(p, (size_t)n, err);
    }
    env->ReleaseFloatArrayElements(pcm, p, JNI_ABORT);
    if (!ok) __android_log_print(ANDROID_LOG_ERROR, "voxsum-nemo", "push failed: %s", err.c_str());
    return ok;
}

// Live view: newly frozen segments, GS (0x1d), then the provisional tail.
JNIEXPORT jstring JNICALL
Java_studio_voxsum_core_asr_NemoNative_nativeLive(JNIEnv* env, jclass, jlong ptr) {
    auto* h = reinterpret_cast<Handle*>(ptr);
    std::vector<nemo::Segment> frozen, tail;
    {
        std::lock_guard<std::mutex> lk(h->mu);
        h->engine->live(frozen, tail);
    }
    std::string out;
    for (const auto& s : frozen) out += encode_segment(s);
    out += "\x1d";
    for (const auto& s : tail) out += encode_segment(s);
    return to_jstring(env, out);
}

JNIEXPORT jstring JNICALL
Java_studio_voxsum_core_asr_NemoNative_nativeFinish(JNIEnv* env, jclass, jlong ptr) {
    auto* h = reinterpret_cast<Handle*>(ptr);
    std::string out, err;
    std::lock_guard<std::mutex> lk(h->mu);
    if (!h->engine->finish([&](const nemo::Segment& s) { out += encode_segment(s); }, err)) {
        __android_log_print(ANDROID_LOG_ERROR, "voxsum-nemo", "finish failed: %s", err.c_str());
        return nullptr;
    }
    const auto& st = h->engine->stats();
    __android_log_print(ANDROID_LOG_INFO, "voxsum-nemo",
                        "audio %.1fs wall %.1fs rtf %.3f speakers %zu turns %zu rss %.0fMB",
                        st.audio_s, st.wall_s, st.audio_s > 0 ? st.wall_s / st.audio_s : 0.0,
                        st.speakers, st.turns, st.peak_rss_mb);
    return to_jstring(env, out);
}

JNIEXPORT jdouble JNICALL
Java_studio_voxsum_core_asr_NemoNative_nativeFedSec(JNIEnv*, jclass, jlong ptr) {
    auto* h = reinterpret_cast<Handle*>(ptr);
    std::lock_guard<std::mutex> lk(h->mu);
    return h->engine->fed_s();
}

JNIEXPORT void JNICALL
Java_studio_voxsum_core_asr_NemoNative_nativeFree(JNIEnv*, jclass, jlong ptr) {
    delete reinterpret_cast<Handle*>(ptr);
}

}  // extern "C"
