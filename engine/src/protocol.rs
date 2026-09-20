use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;

pub const PROTOCOL_VERSION: u32 = 1;
pub const ENGINE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Deserialize)]
pub struct Request {
    pub service: String,
    pub op: String,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub args: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    BadRequest,
    Denied,
    NotFound,
    Unsupported,
    Failed,
}

#[derive(Debug)]
pub struct EngineError {
    pub kind: ErrorKind,
    pub message: String,
}

impl EngineError {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::BadRequest, message)
    }

    pub fn denied(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Denied, message)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::NotFound, message)
    }

    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unsupported, message)
    }

    pub fn failed(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Failed, message)
    }
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<std::io::Error> for EngineError {
    fn from(err: std::io::Error) -> Self {
        let kind = match err.kind() {
            std::io::ErrorKind::NotFound => ErrorKind::NotFound,
            std::io::ErrorKind::PermissionDenied => ErrorKind::Denied,
            _ => ErrorKind::Failed,
        };
        Self::new(kind, err.to_string())
    }
}

impl From<serde_json::Error> for EngineError {
    fn from(err: serde_json::Error) -> Self {
        Self::bad_request(err.to_string())
    }
}

pub type EngineResult<T> = Result<T, EngineError>;

#[derive(Debug, Serialize)]
struct ErrorBody {
    kind: ErrorKind,
    message: String,
}

#[derive(Debug, Serialize)]
pub struct Response {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorBody>,
}

impl Response {
    pub fn ok(result: Value) -> Self {
        Self {
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(error: EngineError) -> Self {
        Self {
            ok: false,
            result: None,
            error: Some(ErrorBody {
                kind: error.kind,
                message: error.message,
            }),
        }
    }

    pub fn from_result(result: EngineResult<Value>) -> Self {
        match result {
            Ok(value) => Self::ok(value),
            Err(error) => Self::err(error),
        }
    }
}

pub fn arg_str<'a>(args: &'a Value, key: &str) -> EngineResult<&'a str> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| EngineError::bad_request(format!("{key} is required and must be a string")))
}

pub fn arg_str_opt<'a>(args: &'a Value, key: &str) -> EngineResult<Option<&'a str>> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(EngineError::bad_request(format!("{key} must be a string"))),
    }
}

pub fn arg_u64_opt(args: &Value, key: &str) -> EngineResult<Option<u64>> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value.as_u64().map(Some).ok_or_else(|| {
            EngineError::bad_request(format!("{key} must be a non-negative integer"))
        }),
    }
}

pub fn arg_bool(args: &Value, key: &str, fallback: bool) -> EngineResult<bool> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(fallback),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(EngineError::bad_request(format!("{key} must be a boolean"))),
    }
}

pub fn arg_str_list(args: &Value, key: &str) -> EngineResult<Vec<String>> {
    let Some(value) = args.get(key) else {
        return Ok(Vec::new());
    };
    match value {
        Value::Null => Ok(Vec::new()),
        Value::Array(items) => items
            .iter()
            .map(|item| {
                item.as_str().map(str::to_owned).ok_or_else(|| {
                    EngineError::bad_request(format!("{key} must be an array of strings"))
                })
            })
            .collect(),
        _ => Err(EngineError::bad_request(format!(
            "{key} must be an array of strings"
        ))),
    }
}
