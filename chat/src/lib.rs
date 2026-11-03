pub mod core;
pub mod node;

use std::ffi::{c_char, CStr, CString};
use std::sync::{Arc, OnceLock};

use serde_json::{json, Value};
use tokio::runtime::Runtime;
use tokio::sync::OnceCell;

use crate::node::Node;

type Callback = extern "C" fn(*mut c_char);

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static NODE: OnceCell<Result<Arc<Node>, String>> = OnceCell::const_new();
static CALLBACK: OnceLock<Callback> = OnceLock::new();

fn emit(value: Value) {
    if let Some(callback) = CALLBACK.get() {
        if let Ok(text) = CString::new(value.to_string()) {
            callback(text.into_raw());
        }
    }
}

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("tokio runtime"))
}

/// # Safety
/// `dir` is a NUL-terminated path that outlives the call.
#[no_mangle]
pub unsafe extern "C" fn upgrade_chat_start(dir: *const c_char, callback: Callback) {
    let _ = CALLBACK.set(callback);
    let dir = CStr::from_ptr(dir).to_string_lossy().into_owned();
    runtime().spawn(async move {
        let node = NODE
            .get_or_init(|| async { Node::start(&dir, Arc::new(emit)).await.map_err(|e| e.0) })
            .await;
        emit(match node {
            Ok(_) => json!({"event": "started"}),
            Err(e) => json!({"event": "failed", "error": e}),
        });
    });
}

/// # Safety
/// `request` is a NUL-terminated JSON string that outlives the call.
#[no_mangle]
pub unsafe extern "C" fn upgrade_chat_call(id: i64, request: *const c_char) {
    let request = CStr::from_ptr(request).to_string_lossy().into_owned();
    runtime().spawn(async move {
        let answer = match (NODE.get(), serde_json::from_str::<Value>(&request)) {
            (Some(Ok(node)), Ok(request)) => node.call(request).await.map_err(|e| e.0),
            (Some(Err(e)), _) => Err(e.clone()),
            (None, _) => Err("not started".to_owned()),
            (_, Err(e)) => Err(e.to_string()),
        };
        emit(match answer {
            Ok(ok) => json!({"reply": id, "ok": ok}),
            Err(error) => json!({"reply": id, "error": error}),
        });
    });
}

/// # Safety
/// `text` came from the callback and is freed once.
#[no_mangle]
pub unsafe extern "C" fn upgrade_chat_free(text: *mut c_char) {
    drop(CString::from_raw(text));
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_dev_luisnquin_upgrade_ChatNative_setup(
    env: jni::EnvUnowned,
    _class: jni::objects::JClass,
    context: jni::objects::JObject,
) {
    veilid_core::veilid_core_setup_android(env, context);
}
