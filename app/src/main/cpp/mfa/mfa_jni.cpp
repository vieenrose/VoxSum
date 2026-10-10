// mfa_jni.cpp - JNI surface of the mobile reader engine (studio.voxsum.core.llm.MfaEngine) and of
// its SentencePiece tokenizer. One engine handle per loaded model; every call on a handle comes
// from the reader's single LLM thread, except nativeCancel.
#include <jni.h>
#include <android/log.h>

#include <memory>
#include <string>
#include <vector>

#include "mfa_engine.h"
#include "sentencepiece_processor.h"

#define LOG_TAG "voxsum-mfa"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

std::string str(JNIEnv* env, jstring s) {
    if (!s) return {};
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string out(c);
    env->ReleaseStringUTFChars(s, c);
    return out;
}

void throwJava(JNIEnv* env, const std::string& msg) {
    jclass c = env->FindClass("java/lang/IllegalStateException");
    if (c) env->ThrowNew(c, msg.c_str());
}

mfa::Engine* engine(jlong h) { return reinterpret_cast<mfa::Engine*>(h); }
sentencepiece::SentencePieceProcessor* tok(jlong h) { return reinterpret_cast<sentencepiece::SentencePieceProcessor*>(h); }

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_studio_voxsum_core_llm_MfaEngine_nativeLoad(JNIEnv* env, jclass, jstring dir, jstring main, jint ctx,
                                                jint threads, jstring cache, jint backend) {
    try {
        auto* e = new mfa::Engine(str(env, dir), str(env, main), ctx, threads, str(env, cache), backend);
        LOGI("loaded %s, context %d", str(env, main).c_str(), e->context());
        return reinterpret_cast<jlong>(e);
    } catch (const std::exception& ex) {
        LOGE("load failed: %s", ex.what());
        throwJava(env, std::string("mobile reader load failed: ") + ex.what());
        return 0;
    }
}

// Returns the generated ids; streams each one to callback.onToken(int): Boolean (false stops).
JNIEXPORT jintArray JNICALL
Java_studio_voxsum_core_llm_MfaEngine_nativeGenerate(JNIEnv* env, jclass, jlong h, jintArray jids, jint maxNew,
                                                    jfloat temp, jint topK, jfloat topP, jint seed, jobject cb,
                                                    jdoubleArray jstats) {
    if (!h) { throwJava(env, "engine not loaded"); return nullptr; }
    const jsize n = env->GetArrayLength(jids);
    std::vector<int> ids(n);
    env->GetIntArrayRegion(jids, 0, n, reinterpret_cast<jint*>(ids.data()));
    jmethodID onToken = nullptr;
    if (cb) onToken = env->GetMethodID(env->GetObjectClass(cb), "onToken", "(I)Z");
    mfa::Stats st;
    std::vector<int> out;
    try {
        out = engine(h)->generate(ids, maxNew, temp, topK, topP, (unsigned)seed,
            [&](int t) -> bool {
                if (!onToken) return true;
                const jboolean go = env->CallBooleanMethod(cb, onToken, (jint)t);
                if (env->ExceptionCheck()) return false;
                return go == JNI_TRUE;
            }, &st);
    } catch (const std::exception& ex) {
        throwJava(env, ex.what());
        return nullptr;
    }
    if (env->ExceptionCheck()) return nullptr;
    if (jstats && env->GetArrayLength(jstats) >= 5) {
        const double s[5] = {(double)st.prefilled, (double)st.reused, (double)st.generated, st.prefill_s, st.decode_s};
        env->SetDoubleArrayRegion(jstats, 0, 5, s);
    }
    jintArray arr = env->NewIntArray((jsize)out.size());
    env->SetIntArrayRegion(arr, 0, (jsize)out.size(), reinterpret_cast<const jint*>(out.data()));
    return arr;
}

JNIEXPORT jint JNICALL
Java_studio_voxsum_core_llm_MfaEngine_nativeAgree(JNIEnv* env, jclass, jlong h, jintArray jids, jintArray jforced) {
    if (!h) { throwJava(env, "engine not loaded"); return 0; }
    auto vec = [&](jintArray a) {
        std::vector<int> v(env->GetArrayLength(a));
        env->GetIntArrayRegion(a, 0, (jsize)v.size(), reinterpret_cast<jint*>(v.data()));
        return v;
    };
    try { return engine(h)->agree(vec(jids), vec(jforced)); }
    catch (const std::exception& ex) { throwJava(env, ex.what()); return 0; }
}

JNIEXPORT void JNICALL
Java_studio_voxsum_core_llm_MfaEngine_nativeCancel(JNIEnv*, jclass, jlong h) { if (h) engine(h)->cancel(); }

JNIEXPORT void JNICALL
Java_studio_voxsum_core_llm_MfaEngine_nativeFree(JNIEnv*, jclass, jlong h) { delete engine(h); }

JNIEXPORT jint JNICALL
Java_studio_voxsum_core_llm_MfaEngine_nativeContext(JNIEnv*, jclass, jlong h) { return h ? engine(h)->context() : 0; }

// ---- tokenizer -------------------------------------------------------------------------------

JNIEXPORT jlong JNICALL
Java_studio_voxsum_core_llm_SpTokenizer_nativeLoad(JNIEnv* env, jclass, jstring path) {
    auto* sp = new sentencepiece::SentencePieceProcessor();
    const auto st = sp->Load(str(env, path));
    if (!st.ok()) { delete sp; throwJava(env, "tokenizer: " + st.ToString()); return 0; }
    return reinterpret_cast<jlong>(sp);
}

JNIEXPORT jintArray JNICALL
Java_studio_voxsum_core_llm_SpTokenizer_nativeEncode(JNIEnv* env, jclass, jlong h, jstring text) {
    std::vector<int> ids;
    tok(h)->Encode(str(env, text), &ids);
    jintArray arr = env->NewIntArray((jsize)ids.size());
    env->SetIntArrayRegion(arr, 0, (jsize)ids.size(), reinterpret_cast<const jint*>(ids.data()));
    return arr;
}

// UTF-8 bytes, not a jstring: a partial reply can end inside a character, and NewStringUTF
// (modified UTF-8) aborts on that and on 4-byte sequences. Kotlin decodes them.
JNIEXPORT jbyteArray JNICALL
Java_studio_voxsum_core_llm_SpTokenizer_nativeDecode(JNIEnv* env, jclass, jlong h, jintArray jids) {
    const jsize n = env->GetArrayLength(jids);
    std::vector<int> ids(n);
    env->GetIntArrayRegion(jids, 0, n, reinterpret_cast<jint*>(ids.data()));
    std::string out;
    tok(h)->Decode(ids, &out);
    jbyteArray arr = env->NewByteArray((jsize)out.size());
    env->SetByteArrayRegion(arr, 0, (jsize)out.size(), reinterpret_cast<const jbyte*>(out.data()));
    return arr;
}

JNIEXPORT void JNICALL
Java_studio_voxsum_core_llm_SpTokenizer_nativeFree(JNIEnv*, jclass, jlong h) { delete tok(h); }

}  // extern "C"
