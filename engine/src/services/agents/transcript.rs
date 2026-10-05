use crate::protocol::{arg_str, arg_u64_opt, EngineError, EngineResult};
use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader};

use super::{cut, summarize, typed};

const DEFAULT_LIMIT: u64 = 200;
const MAX_LIMIT: u64 = 500;
const TEXT_CHARS: usize = 4000;
const RESULT_CHARS: usize = 1200;

fn item(index: usize, kind: &str, text: &str, limit: usize) -> Value {
    json!({ "index": index, "kind": kind, "text": cut(text, limit) })
}

fn joined(content: &Value, kinds: &[&str]) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter(|block| {
                block
                    .get("type")
                    .and_then(Value::as_str)
                    .is_none_or(|kind| kinds.contains(&kind))
            })
            .filter_map(|block| block.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn push_text(index: usize, kind: &str, text: &str, out: &mut Vec<Value>) {
    if !text.trim().is_empty() {
        out.push(item(index, kind, text, TEXT_CHARS));
    }
}

fn block_text(block: &Value) -> &str {
    block.get("text").and_then(Value::as_str).unwrap_or("")
}

fn claude_said(index: usize, text: &str, out: &mut Vec<Value>) {
    if let Some(text) = typed("claude", text) {
        push_text(index, "user", &text, out);
    }
}

fn claude_user_block(index: usize, block: &Value, out: &mut Vec<Value>) {
    match block.get("type").and_then(Value::as_str) {
        Some("tool_result") => {
            let text = joined(block.get("content").unwrap_or(&Value::Null), &["text"]);
            let mut result = item(index, "result", &text, RESULT_CHARS);
            result["tool_id"] = block.get("tool_use_id").cloned().unwrap_or(Value::Null);
            result["error"] = json!(block.get("is_error").and_then(Value::as_bool) == Some(true));
            out.push(result);
        }
        Some("text") => claude_said(index, block_text(block), out),
        _ => {}
    }
}

fn claude_assistant_block(index: usize, block: &Value, out: &mut Vec<Value>) {
    match block.get("type").and_then(Value::as_str) {
        Some("text") => push_text(index, "assistant", block_text(block), out),
        Some("tool_use") => {
            let summary = summarize(block.get("input").unwrap_or(&Value::Null));
            let mut tool = item(index, "tool", &summary, TEXT_CHARS);
            tool["tool"] = block.get("name").cloned().unwrap_or(Value::Null);
            tool["tool_id"] = block.get("id").cloned().unwrap_or(Value::Null);
            out.push(tool);
        }
        _ => {}
    }
}

fn flag(record: &Value, key: &str) -> bool {
    record.get(key).and_then(Value::as_bool) == Some(true)
}

fn claude(index: usize, record: &Value, out: &mut Vec<Value>) {
    if flag(record, "isSidechain") || flag(record, "isMeta") || flag(record, "isCompactSummary") {
        return;
    }
    let kind = record.get("type").and_then(Value::as_str).unwrap_or("");
    let Some(content) = record.pointer("/message/content") else {
        return;
    };
    match (kind, content) {
        ("user", Value::String(text)) => claude_said(index, text, out),
        ("user", Value::Array(blocks)) => {
            for block in blocks {
                claude_user_block(index, block, out);
            }
        }
        ("assistant", Value::Array(blocks)) => {
            for block in blocks {
                claude_assistant_block(index, block, out);
            }
        }
        _ => {}
    }
}

fn codex_output(value: &Value) -> String {
    match value {
        Value::String(text) => serde_json::from_str::<Value>(text)
            .ok()
            .and_then(|parsed| parsed.get("output").and_then(Value::as_str).map(str::to_owned))
            .unwrap_or_else(|| text.clone()),
        Value::Object(_) => value
            .get("content")
            .or_else(|| value.get("output"))
            .map(|inner| joined(inner, &["text", "input_text", "output_text"]))
            .unwrap_or_default(),
        other => joined(other, &["text", "input_text", "output_text"]),
    }
}

fn codex(index: usize, record: &Value, out: &mut Vec<Value>) {
    if record.get("type").and_then(Value::as_str) != Some("response_item") {
        return;
    }
    let Some(payload) = record.get("payload") else {
        return;
    };
    let call_id = payload.get("call_id").cloned().unwrap_or(Value::Null);
    match payload.get("type").and_then(Value::as_str) {
        Some("message") => {
            let content = payload.get("content").unwrap_or(&Value::Null);
            match payload.get("role").and_then(Value::as_str) {
                Some("user") => {
                    let text = joined(content, &["input_text"]);
                    if let Some(text) = typed("codex", &text) {
                        out.push(item(index, "user", &text, TEXT_CHARS));
                    }
                }
                Some("assistant") => {
                    let text = joined(content, &["output_text"]);
                    if !text.trim().is_empty() {
                        out.push(item(index, "assistant", &text, TEXT_CHARS));
                    }
                }
                _ => {}
            }
        }
        Some("function_call") => {
            let arguments = payload.get("arguments").and_then(Value::as_str).unwrap_or("");
            let input = serde_json::from_str::<Value>(arguments).unwrap_or(json!(arguments));
            let mut tool = item(index, "tool", &summarize(&input), TEXT_CHARS);
            tool["tool"] = payload.get("name").cloned().unwrap_or(Value::Null);
            tool["tool_id"] = call_id;
            out.push(tool);
        }
        Some("custom_tool_call") => {
            let input = payload.get("input").unwrap_or(&Value::Null);
            let mut tool = item(index, "tool", &summarize(input), TEXT_CHARS);
            tool["tool"] = payload.get("name").cloned().unwrap_or(Value::Null);
            tool["tool_id"] = call_id;
            out.push(tool);
        }
        Some("function_call_output" | "custom_tool_call_output") => {
            let text = codex_output(payload.get("output").unwrap_or(&Value::Null));
            let mut result = item(index, "result", &text, RESULT_CHARS);
            result["tool_id"] = call_id;
            result["error"] = json!(false);
            out.push(result);
        }
        _ => {}
    }
}

pub fn read(args: &Value, sessions: &[(String, String, Option<String>)]) -> EngineResult<Value> {
    let key = arg_str(args, "session")?;
    let after = arg_u64_opt(args, "after")?;
    let limit = arg_u64_opt(args, "limit")?
        .unwrap_or(DEFAULT_LIMIT)
        .clamp(1, MAX_LIMIT) as usize;
    let Some((_, agent, path)) = sessions.iter().find(|(candidate, _, _)| candidate == key) else {
        return Err(EngineError::not_found("no such agent session"));
    };
    let parse: fn(usize, &Value, &mut Vec<Value>) = match agent.as_str() {
        "claude" => claude,
        "codex" => codex,
        other => return Err(EngineError::unsupported(format!("{other} keeps no transcript the engine reads"))),
    };
    let Some(path) = path else {
        return Err(EngineError::not_found("the agent has not named its transcript yet"));
    };
    let file = fs::File::open(path)?;

    let mut reader = BufReader::new(file);
    let mut line = Vec::new();
    let mut items = Vec::new();
    let mut last = after;
    for index in 0.. {
        line.clear();
        if !matches!(reader.read_until(b'\n', &mut line), Ok(read) if read > 0) {
            break;
        }
        if after.is_some_and(|after| index as u64 <= after) {
            continue;
        }
        let complete = line.last() == Some(&b'\n');
        match serde_json::from_str::<Value>(&String::from_utf8_lossy(&line)) {
            Ok(record) => parse(index, &record, &mut items),
            // A record the agent is still writing has no newline yet; it is read whole
            // on the next call rather than half now.
            Err(_) if !complete => break,
            Err(_) => {}
        }
        last = Some(index as u64);
        if items.len() >= limit {
            break;
        }
    }
    Ok(json!({ "session": key, "items": items, "last": last }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn said(text: &str) -> String {
        json!({ "type": "user", "message": { "content": text } }).to_string()
    }

    fn read_file(name: &str, body: &[u8], after: Option<u64>) -> Value {
        let file = format!("upgrade-transcript-unit-{}-{name}.jsonl", std::process::id());
        let path = std::env::temp_dir().join(file);
        fs::write(&path, body).unwrap();
        let sessions = [("claude:s".to_owned(), "claude".to_owned(), Some(path.display().to_string()))];
        let args = match after {
            Some(after) => json!({ "session": "claude:s", "after": after }),
            None => json!({ "session": "claude:s" }),
        };
        let answer = read(&args, &sessions).unwrap();
        fs::remove_file(&path).unwrap();
        answer
    }

    fn texts(answer: &Value) -> Vec<&str> {
        answer["items"].as_array().unwrap().iter().map(|item| item["text"].as_str().unwrap()).collect()
    }

    #[test]
    fn a_bad_complete_line_is_skipped_and_the_rest_is_read() {
        let mut body = format!("{}\n{{\"type\": \"user\", \"mess\n\n", said("one")).into_bytes();
        body.extend_from_slice(b"{\"type\": \"user\", \"message\": {\"content\": \"\xff\xfe\"}}\n");
        body.extend_from_slice(b"\xc3\x28 not json\n");
        body.extend_from_slice(format!("{}\n", said("two")).as_bytes());
        let answer = read_file("bad-lines", &body, None);
        assert_eq!(texts(&answer), vec!["one", "\u{fffd}\u{fffd}", "two"]);
        assert_eq!(answer["last"], json!(5));
    }

    #[test]
    fn a_partial_last_line_waits_for_the_next_call() {
        let whole = said("three");
        let body = format!("{}\n{}", said("one"), &whole[..whole.len() - 4]);
        let answer = read_file("partial", body.as_bytes(), None);
        assert_eq!(texts(&answer), vec!["one"]);
        assert_eq!(answer["last"], json!(0));

        let body = format!("{}\n{whole}", said("one"));
        let answer = read_file("unterminated", body.as_bytes(), Some(0));
        assert_eq!(texts(&answer), vec!["three"]);
        assert_eq!(answer["last"], json!(1));
    }

    #[test]
    fn a_harness_turn_is_not_read_as_the_user() {
        let body = format!(
            "{}\n{}\n",
            said("<task-notification>\n<task-id>x</task-id>"),
            said("<command-name>/commit</command-name>\n<command-args>now</command-args>")
        );
        assert_eq!(texts(&read_file("injected", body.as_bytes(), None)), vec!["/commit now"]);
    }
}
