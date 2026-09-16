//! Turning a provider's reply into tool calls the engine will run.
//!
//! Ported from `DSHParseCompletionResponseSchema2` in `DSHCompletionV2.mm`.
//! This is the boundary where untrusted model output becomes something
//! executable, so it is the one place where being permissive is expensive: a
//! call that gets through here is a call a person will be asked to approve.
//!
//! The host supplies its model catalogue, a fallback identifier and original
//! JSON storage facts. Eligibility, defaults and byte limits stay in the core.

use serde_json::{json, Map, Value};

use crate::schema::bounded_utf8;

#[path = "completion_response_projection.rs"]
mod projection;
use projection::Projection;

/// The failure codes the parser answers with. They are not `StoreError` codes:
/// a provider reply is not a store operation, and the controller distinguishes
/// these when deciding whether a retry could possibly help.
pub const RESPONSE_JSON: &str = "E_COMPLETION_RESPONSE_JSON";
pub const RESPONSE_ID: &str = "E_COMPLETION_PROVIDER_RESPONSE_ID";
pub const RESPONSE_MODEL: &str = "E_COMPLETION_RESPONSE_MODEL";
pub const MODEL_MISMATCH: &str = "E_COMPLETION_MODEL_MISMATCH";
pub const EMPTY_RESPONSE: &str = "E_COMPLETION_EMPTY_RESPONSE";
pub const LENGTH: &str = "E_COMPLETION_LENGTH";
pub const TOOL_CALL_INVALID: &str = "E_COMPLETION_TOOL_CALL_INVALID";
pub const FINISH_RELATION: &str = "E_COMPLETION_FINISH_RELATION";

pub const MAX_ARGUMENTS_BYTES: usize = 32768;
const MAX_TOOL_NAME: usize = 64;
const MAX_TEXT_BYTES: usize = 256 * 1024;
const MAX_TOOL_CALLS: usize = 16;
const MAX_IDENTIFIER_BYTES: usize = 128;

const NAME_ALPHABET: &str = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";
const IDENTIFIER_ALPHABET: &str =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-";

const FINISH_REASONS: &[&str] = &["stop", "tool_calls", "length", "content_filter"];

fn text_of(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str)
}

fn valid_tool_name(name: Option<&str>) -> bool {
    name.is_some_and(|name| {
        !name.is_empty()
            && name.chars().count() <= MAX_TOOL_NAME
            && name.chars().all(|c| NAME_ALPHABET.contains(c))
    })
}

fn opaque_identifier(value: Option<&Value>) -> bool {
    bounded_utf8(value, MAX_IDENTIFIER_BYTES, false)
        .is_some_and(|text| text.chars().all(|c| IDENTIFIER_ALPHABET.contains(c)))
}

fn exact_keys(map: &Map<String, Value>, keys: &[&str]) -> bool {
    map.len() == keys.len() && map.keys().all(|key| keys.contains(&key.as_str()))
}

/// Only *omission* means create-only. An explicit value — including a
/// placeholder string — has to survive parsing so tool preparation can report
/// it; coercing it to null would turn a malformed update into a create.
fn normalize_create_only_write(name: &str, parameters: &Value) -> Value {
    let Some(map) = parameters.as_object() else {
        return parameters.clone();
    };
    if name != "write_file"
        || !exact_keys(map, &["path", "content"])
        || bounded_utf8(map.get("path"), 512, true).is_none()
        || bounded_utf8(map.get("content"), MAX_ARGUMENTS_BYTES, true).is_none()
    {
        return parameters.clone();
    }
    let mut normalized = map.clone();
    normalized.insert("expected_revision".to_string(), Value::Null);
    Value::Object(normalized)
}

// Foundation historically includes ZERO WIDTH SPACE in this character set.
// Rust's Unicode White_Space property alone would expand empty-answer acceptance.
fn trim_response(text: &str) -> &str {
    text.trim_matches(|ch: char| ch.is_whitespace() || ch == '\u{200b}')
}

/// Every failure a completion round may report. The controller switches on
/// these to decide whether a retry could possibly help, so the set is closed:
/// a code outside it would be a failure nothing knows how to recover from.
pub const FAILURE_CODES: &[&str] = &[
    "E_COMPLETION_BODY_INVALID",
    "E_COMPLETION_BODY_TOO_LARGE",
    "E_COMPLETION_BUSY",
    "E_COMPLETION_CANCELLED",
    "E_COMPLETION_CONTENT_FILTER",
    "E_COMPLETION_CONTEXT_INVALID",
    "E_COMPLETION_CONTEXT_UNSUPPORTED",
    "E_COMPLETION_CREDENTIAL_CHANGED",
    "E_COMPLETION_CREDENTIAL_UNAVAILABLE",
    "E_COMPLETION_EMPTY_RESPONSE",
    "E_COMPLETION_FINISH_RELATION",
    "E_COMPLETION_HISTORY",
    "E_COMPLETION_HTTP_429",
    "E_COMPLETION_HTTP_STATUS",
    "E_COMPLETION_IDENTIFIER",
    "E_COMPLETION_LENGTH",
    "E_COMPLETION_MODEL",
    "E_COMPLETION_MODEL_MISMATCH",
    "E_COMPLETION_NATIVE",
    "E_COMPLETION_PROVIDER_REQUEST_ID",
    "E_COMPLETION_PROVIDER_RESPONSE_ID",
    "E_COMPLETION_REDIRECT",
    "E_COMPLETION_RESPONSE_JSON",
    "E_COMPLETION_RESPONSE_MODEL",
    "E_COMPLETION_RESPONSE_SIZE",
    "E_COMPLETION_ROUND",
    "E_COMPLETION_SCHEMA",
    "E_COMPLETION_THINKING",
    "E_COMPLETION_TIMEOUT",
    "E_COMPLETION_TOOL_CALL_INVALID",
    "E_COMPLETION_TOOLS",
    "E_COMPLETION_TRANSCRIPT",
    "E_COMPLETION_TRANSPORT",
];

/// The subset a parser refusal may name.
const PARSER_FAILURE_CODES: &[&str] = &[
    RESPONSE_JSON,
    RESPONSE_ID,
    RESPONSE_MODEL,
    MODEL_MISMATCH,
    EMPTY_RESPONSE,
    TOOL_CALL_INVALID,
    FINISH_RELATION,
    LENGTH,
];

/// `DSHCompletionTransportParserErrorCode`. Fail-closed on purpose: a verbose
/// diagnostic, a third-party error or a store code must not travel onward as
/// something the controller will switch on.
pub fn parser_failure_code(candidate: Option<&str>) -> &'static str {
    candidate
        .and_then(|text| PARSER_FAILURE_CODES.iter().find(|code| **code == text))
        .copied()
        .unwrap_or(EMPTY_RESPONSE)
}

/// `providerErrorCodeForHTTPStatus`. An unauthenticated or forbidden call
/// means the stored credential is unusable; a rate limit or provider overload
/// gets its own code so the caller can back off rather than retry as a generic
/// status failure.
pub fn http_status_failure_code(status: i64) -> &'static str {
    match status {
        401 | 403 => "E_COMPLETION_CREDENTIAL_UNAVAILABLE",
        429 | 529 => "E_COMPLETION_HTTP_429",
        _ => "E_COMPLETION_HTTP_STATUS",
    }
}

/// What the host must tell the parser, because the core cannot know it.
pub struct Facts<'a> {
    /// Whether `model` is in this build's catalogue.
    pub model_supported: bool,
    /// The model the request asked for.
    pub requested_model: &'a str,
    /// `off`, `high`, ... — a reply claiming tools must show its reasoning
    /// unless thinking was off.
    pub thinking_mode: &'a str,
    /// A fresh lowercase UUID, used only if the compatibility path needs an
    /// identifier the response id cannot supply.
    pub fallback_call_id: &'a str,
}

pub fn parse(decoded: &Value, facts: &Facts) -> Result<Value, &'static str> {
    parse_projected(decoded, facts, &mut Projection::portable())
}

fn parse_projected(
    decoded: &Value,
    facts: &Facts,
    projection: &mut Projection,
) -> Result<Value, &'static str> {
    let Some(decoded) = decoded.as_object() else {
        return Err(RESPONSE_JSON);
    };
    if !opaque_identifier(decoded.get("id")) {
        return Err(RESPONSE_ID);
    }
    let response_id = text_of(decoded.get("id")).unwrap_or_default();
    let Some(model) = text_of(decoded.get("model")) else {
        return Err(RESPONSE_MODEL);
    };
    if !facts.model_supported {
        return Err(RESPONSE_MODEL);
    }
    if model != facts.requested_model {
        return Err(MODEL_MISMATCH);
    }
    // Exactly one choice: a reply with several is not one turn of a
    // conversation and there is no rule for picking between them.
    let choice = decoded
        .get("choices")
        .and_then(Value::as_array)
        .filter(|choices| choices.len() == 1)
        .and_then(|choices| choices[0].as_object());
    let message = choice
        .and_then(|choice| choice.get("message"))
        .and_then(Value::as_object);
    let finish = choice.and_then(|choice| text_of(choice.get("finish_reason")));
    let (Some(choice), Some(message), Some(finish)) = (choice, message, finish) else {
        return Err(EMPTY_RESPONSE);
    };
    let _ = choice;
    if text_of(message.get("role")) != Some("assistant") || !FINISH_REASONS.contains(&finish) {
        return Err(EMPTY_RESPONSE);
    }
    let raw_calls = message.get("tool_calls");
    let call_count = raw_calls.and_then(Value::as_array).map_or(0, Vec::len);
    // A length-limited tool reply is incomplete even when its partial JSON
    // happens to parse. Never expose executable calls from it.
    if finish == "length" && call_count > 0 {
        return Err(LENGTH);
    }

    // DeepSeek's required `content` is nullable for a tool-only reply.
    let nullable_tool_content =
        message.get("content") == Some(&Value::Null) && finish == "tool_calls" && call_count > 0;
    let text: String = if nullable_tool_content {
        String::new()
    } else {
        bounded_utf8(message.get("content"), MAX_TEXT_BYTES, true)
            .ok_or(EMPTY_RESPONSE)?
            .to_string()
    };
    let raw_reasoning = message.get("reasoning_content");
    let reasoning: String = match raw_reasoning {
        None | Some(Value::Null) => String::new(),
        other => bounded_utf8(other, MAX_TEXT_BYTES, true)
            .ok_or(EMPTY_RESPONSE)?
            .to_string(),
    };

    let calls: &[Value] = match raw_calls {
        None | Some(Value::Null) => &[],
        Some(Value::Array(items)) => items.as_slice(),
        Some(_) => return Err(TOOL_CALL_INVALID),
    };
    if calls.len() > MAX_TOOL_CALLS {
        return Err(TOOL_CALL_INVALID);
    }
    if !projection.valid_index_facts(calls.len()) {
        return Err(RESPONSE_JSON);
    }
    let mut tool_calls: Vec<Value> = Vec::with_capacity(calls.len());
    let mut seen: Vec<String> = Vec::with_capacity(calls.len());
    for (index, raw) in calls.iter().enumerate() {
        let Some(call) = raw.as_object() else {
            return Err(TOOL_CALL_INVALID);
        };
        let function = call.get("function").and_then(Value::as_object);
        // Some providers number their calls; the number has to agree with the
        // position, or the reply is describing an order it did not send.
        let base_exact = exact_keys(call, &["id", "type", "function"]);
        let indexed_exact = exact_keys(call, &["id", "type", "function", "index"])
            && projection.integer_storage(index)
            && call.get("index").and_then(Value::as_u64) == Some(index as u64)
            && index < MAX_TOOL_CALLS;
        let Some(function) = function else {
            return Err(TOOL_CALL_INVALID);
        };
        let name = text_of(function.get("name"));
        let identifier = text_of(call.get("id")).unwrap_or_default().to_string();
        if !(base_exact || indexed_exact)
            || !opaque_identifier(call.get("id"))
            || seen.contains(&identifier)
            || text_of(call.get("type")) != Some("function")
            || !exact_keys(function, &["name", "arguments"])
            || !valid_tool_name(name)
        {
            return Err(TOOL_CALL_INVALID);
        }
        let Some(arguments) = bounded_utf8(function.get("arguments"), MAX_ARGUMENTS_BYTES, true)
        else {
            return Err(TOOL_CALL_INVALID);
        };
        let name = name.expect("checked");
        let mut arguments = arguments.to_string();
        if name == "write_file" {
            if let Some(parsed) = projection.decode(&arguments) {
                let normalized = normalize_create_only_write(name, &parsed);
                if normalized != parsed {
                    if let Some(text) =
                        projection.encode(&arguments, "", true, &normalized, MAX_ARGUMENTS_BYTES)
                    {
                        arguments = text;
                    }
                }
            }
        }
        seen.push(identifier.clone());
        tool_calls.push(json!({ "id": identifier, "name": name, "arguments": arguments }));
    }

    // Compatibility: a model that describes a call in prose instead of using
    // the tool channel. Accepted only when it sent no real calls at all, and
    // only in the two exact shapes below — anything looser and ordinary prose
    // that happens to be JSON would become an executable call.
    let mut finish = finish.to_string();
    let mut text = text;
    let mut trimmed = trim_response(&text).to_string();
    let mut compatibility_call = false;
    if tool_calls.is_empty()
        && matches!(finish.as_str(), "stop" | "tool_calls")
        && !trimmed.is_empty()
    {
        if let Some(Value::Object(candidate)) = projection.decode(&trimmed) {
            let long_shape = exact_keys(&candidate, &["type", "function", "parameters"])
                && text_of(candidate.get("type")) == Some("function_call")
                && candidate.get("parameters").is_some_and(Value::is_object);
            let short_shape = exact_keys(&candidate, &["name", "arguments"])
                && candidate.get("arguments").is_some_and(Value::is_object);
            let name = if long_shape {
                text_of(candidate.get("function"))
            } else if short_shape {
                text_of(candidate.get("name"))
            } else {
                None
            };
            let parameters = if long_shape {
                candidate.get("parameters")
            } else if short_shape {
                candidate.get("arguments")
            } else {
                None
            };
            if let (true, Some(name), Some(parameters)) =
                (long_shape || short_shape, name, parameters)
            {
                if valid_tool_name(Some(name)) {
                    let normalized = normalize_create_only_write(name, parameters);
                    let identifier = format!("compat:{response_id}");
                    let identifier = if opaque_identifier(Some(&json!(identifier))) {
                        identifier
                    } else {
                        format!("compat:{}", facts.fallback_call_id)
                    };
                    if let (Some(arguments), true) = (
                        projection.encode(
                            &trimmed,
                            if long_shape {
                                "parameters"
                            } else {
                                "arguments"
                            },
                            normalized != *parameters,
                            &normalized,
                            MAX_ARGUMENTS_BYTES,
                        ),
                        opaque_identifier(Some(&json!(identifier))),
                    ) {
                        tool_calls.push(
                            json!({ "id": identifier, "name": name, "arguments": arguments }),
                        );
                        finish = "tool_calls".to_string();
                        text = String::new();
                        trimmed = String::new();
                        compatibility_call = true;
                    }
                }
            }
        }
    }

    // The finish reason and the calls have to agree: a reply that says
    // "tool_calls" and sends none, or says "stop" and sends some, is not a
    // reply this engine can act on either way.
    let claims_tools = finish == "tool_calls";
    if claims_tools == tool_calls.is_empty() {
        return Err(FINISH_RELATION);
    }
    // Real tool calls come with the reasoning that produced them, unless
    // thinking was off. The compatibility path never had a tool channel and so
    // never had reasoning either.
    if claims_tools
        && !compatibility_call
        && facts.thinking_mode != "off"
        && !matches!(raw_reasoning, Some(Value::String(_)))
    {
        return Err(FINISH_RELATION);
    }
    if matches!(finish.as_str(), "stop" | "length") && trimmed.is_empty() {
        return Err(FINISH_RELATION);
    }
    Ok(json!({
        "provider_response_id": response_id,
        "model": model,
        "text": text,
        "reasoning": reasoning,
        "tool_calls": tool_calls,
        "finish_reason": finish,
    }))
}

/// One envelope in, one reply out; see `rish_agent_completion_response_reduce`.
pub fn reduce_json(input: &str) -> String {
    reduce_json_inner(input)
        .unwrap_or_else(|code| json!({ "ok": false, "failure_code": code }))
        .to_string()
}

fn reduce_json_inner(input: &str) -> Result<Value, &'static str> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| RESPONSE_JSON)?;
    // Dispatched before the parse envelope is read: these two answer from the
    // op alone and need none of the facts a parse does.
    match envelope.get("op").and_then(Value::as_str) {
        Some("http_status_failure") => {
            let status = envelope
                .get("status")
                .and_then(Value::as_i64)
                .ok_or(RESPONSE_JSON)?;
            return Ok(json!({ "ok": true, "failure_code": http_status_failure_code(status) }));
        }
        Some("parser_failure") => {
            return Ok(json!({
                "ok": true,
                "failure_code": parser_failure_code(
                    envelope.get("candidate").and_then(Value::as_str)),
            }));
        }
        Some("parse") => {}
        _ => return Err(RESPONSE_JSON),
    }
    let facts = Facts {
        model_supported: envelope.get("model_supported") == Some(&Value::Bool(true)),
        requested_model: text_of(envelope.get("requested_model")).unwrap_or_default(),
        thinking_mode: text_of(envelope.get("thinking_mode")).unwrap_or_default(),
        fallback_call_id: text_of(envelope.get("fallback_call_id")).unwrap_or_default(),
    };
    let decoded = envelope.get("response").ok_or(RESPONSE_JSON)?;
    let mut projection = Projection::from_envelope(&envelope).ok_or(RESPONSE_JSON)?;
    let parsed = parse_projected(decoded, &facts, &mut projection);
    if !projection.requests.is_empty() {
        return Ok(json!({ "ok": true, "json_requests": projection.requests }));
    }
    parsed.map(|parsed| json!({ "ok": true, "parsed": parsed }))
}

#[cfg(test)]
#[path = "completion_response_tests.rs"]
mod tests;
