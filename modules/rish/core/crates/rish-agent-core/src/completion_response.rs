//! Turning a provider's reply into tool calls the engine will run.
//!
//! Ported from `DSHParseCompletionResponseSchema2` in `DSHCompletionV2.mm`.
//! This is the boundary where untrusted model output becomes something
//! executable, so it is the one place where being permissive is expensive: a
//! call that gets through here is a call a person will be asked to approve.
//!
//! The host supplies the two things only it knows — whether a model is in this
//! build's catalogue, and a fresh identifier for the compatibility path — and
//! nothing else.

use serde_json::{json, Map, Value};

use crate::schema::bounded_utf8;

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
        || bounded_utf8(map.get("path"), 512, false).is_none()
        || bounded_utf8(map.get("content"), MAX_ARGUMENTS_BYTES, true).is_none()
    {
        return parameters.clone();
    }
    let mut normalized = map.clone();
    normalized.insert("expected_revision".to_string(), Value::Null);
    Value::Object(normalized)
}

/// Serializes tool arguments the way the parser stores them: sorted keys, no
/// spaces — the same shape `NSJSONWritingSortedKeys` produced.
fn arguments_json(value: &Value) -> Option<String> {
    let text = crate::canonical::canonical_json(value)
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())?;
    (text.len() <= MAX_ARGUMENTS_BYTES).then_some(text)
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
            if let Ok(parsed) = serde_json::from_str::<Value>(&arguments) {
                let normalized = normalize_create_only_write(name, &parsed);
                if normalized != parsed {
                    if let Some(text) = arguments_json(&normalized) {
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
    let mut trimmed = text.trim().to_string();
    let mut compatibility_call = false;
    if tool_calls.is_empty()
        && matches!(finish.as_str(), "stop" | "tool_calls")
        && !trimmed.is_empty()
    {
        if let Ok(Value::Object(candidate)) = serde_json::from_str::<Value>(&trimmed) {
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
                        arguments_json(&normalized),
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
    let value = match reduce_json_inner(input) {
        Ok(output) => json!({ "ok": true, "parsed": output }),
        Err(code) => json!({ "ok": false, "failure_code": code }),
    };
    value.to_string()
}

fn reduce_json_inner(input: &str) -> Result<Value, &'static str> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| RESPONSE_JSON)?;
    if envelope.get("op").and_then(Value::as_str) != Some("parse") {
        return Err(RESPONSE_JSON);
    }
    let facts = Facts {
        model_supported: envelope.get("model_supported") == Some(&Value::Bool(true)),
        requested_model: text_of(envelope.get("requested_model")).unwrap_or_default(),
        thinking_mode: text_of(envelope.get("thinking_mode")).unwrap_or_default(),
        fallback_call_id: text_of(envelope.get("fallback_call_id")).unwrap_or_default(),
    };
    let decoded = envelope.get("response").ok_or(RESPONSE_JSON)?;
    parse(decoded, &facts)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts<'a>(thinking: &'a str) -> Facts<'a> {
        Facts {
            model_supported: true,
            requested_model: "deepseek-v4-flash",
            thinking_mode: thinking,
            fallback_call_id: "11111111-1111-4111-8111-111111111111",
        }
    }

    fn response(message: Value, finish: &str) -> Value {
        json!({
            "id": "resp-1", "model": "deepseek-v4-flash",
            "choices": [{ "message": message, "finish_reason": finish }],
        })
    }

    fn call(id: &str, name: &str, arguments: &str) -> Value {
        json!({ "id": id, "type": "function",
                "function": { "name": name, "arguments": arguments } })
    }

    #[test]
    fn a_plain_answer_parses() {
        let parsed = parse(
            &response(json!({ "role": "assistant", "content": "hello" }), "stop"),
            &facts("off"),
        )
        .expect("parsed");
        assert_eq!(parsed["text"], json!("hello"));
        assert_eq!(parsed["tool_calls"], json!([]));
        assert_eq!(parsed["finish_reason"], json!("stop"));
    }

    #[test]
    fn a_reply_must_be_for_the_model_that_was_asked() {
        let mut wrong = response(json!({ "role": "assistant", "content": "hi" }), "stop");
        wrong["model"] = json!("some-other-model");
        assert_eq!(parse(&wrong, &facts("off")), Err(MODEL_MISMATCH));
        let mut unknown = facts("off");
        unknown.model_supported = false;
        assert_eq!(
            parse(
                &response(json!({ "role": "assistant", "content": "hi" }), "stop"),
                &unknown
            ),
            Err(RESPONSE_MODEL)
        );
    }

    /// A reply cut off mid-argument can still be syntactically valid JSON.
    /// Running it would run a call the model never finished writing.
    #[test]
    fn a_length_limited_reply_never_yields_an_executable_call() {
        let message = json!({
            "role": "assistant", "content": "", "reasoning_content": "r",
            "tool_calls": [call("c1", "read_file", "{\"path\":\"a\"}")],
        });
        assert_eq!(
            parse(&response(message, "length"), &facts("high")),
            Err(LENGTH)
        );
    }

    #[test]
    fn the_finish_reason_and_the_calls_must_agree() {
        // Content stays a string here: a null content is only allowed for a
        // tool-only reply, so with "stop" it would fail as an empty response
        // before the finish relation is ever reached.
        let with_calls = json!({
            "role": "assistant", "content": "text", "reasoning_content": "r",
            "tool_calls": [call("c1", "read_file", "{\"path\":\"a\"}")],
        });
        assert_eq!(
            parse(&response(with_calls, "stop"), &facts("high")),
            Err(FINISH_RELATION)
        );
        let without = json!({ "role": "assistant", "content": "text" });
        assert_eq!(
            parse(&response(without, "tool_calls"), &facts("high")),
            Err(FINISH_RELATION)
        );
    }

    #[test]
    fn a_tool_call_comes_with_the_reasoning_that_produced_it() {
        let message = json!({
            "role": "assistant", "content": null,
            "tool_calls": [call("c1", "read_file", "{\"path\":\"a\"}")],
        });
        assert_eq!(
            parse(&response(message.clone(), "tool_calls"), &facts("high")),
            Err(FINISH_RELATION)
        );
        // With thinking off there is nothing to show.
        assert!(parse(&response(message, "tool_calls"), &facts("off")).is_ok());
    }

    #[test]
    fn two_calls_may_not_share_an_identifier() {
        let message = json!({
            "role": "assistant", "content": null, "reasoning_content": "r",
            "tool_calls": [
                call("c1", "read_file", "{\"path\":\"a\"}"),
                call("c1", "read_file", "{\"path\":\"b\"}"),
            ],
        });
        assert_eq!(
            parse(&response(message, "tool_calls"), &facts("high")),
            Err(TOOL_CALL_INVALID)
        );
    }

    #[test]
    fn a_numbered_call_must_be_numbered_with_its_own_position() {
        let numbered = |index: u64| {
            json!({ "id": "c1", "type": "function", "index": index,
                    "function": { "name": "read_file", "arguments": "{}" } })
        };
        let good = json!({
            "role": "assistant", "content": null, "reasoning_content": "r",
            "tool_calls": [numbered(0)],
        });
        assert!(parse(&response(good, "tool_calls"), &facts("high")).is_ok());
        let bad = json!({
            "role": "assistant", "content": null, "reasoning_content": "r",
            "tool_calls": [numbered(3)],
        });
        assert_eq!(
            parse(&response(bad, "tool_calls"), &facts("high")),
            Err(TOOL_CALL_INVALID)
        );
    }

    #[test]
    fn an_omitted_revision_means_create_only_and_an_explicit_one_survives() {
        let parse_write = |arguments: &str| {
            let message = json!({
                "role": "assistant", "content": null, "reasoning_content": "r",
                "tool_calls": [call("c1", "write_file", arguments)],
            });
            parse(&response(message, "tool_calls"), &facts("high")).expect("parsed")["tool_calls"]
                [0]["arguments"]
                .as_str()
                .expect("arguments")
                .to_string()
        };
        assert_eq!(
            parse_write("{\"path\":\"a\",\"content\":\"b\"}"),
            "{\"content\":\"b\",\"expected_revision\":null,\"path\":\"a\"}"
        );
        // An explicit value, even a bad one, must reach tool preparation
        // rather than become a create request.
        let explicit = "{\"content\":\"b\",\"expected_revision\":\"oops\",\"path\":\"a\"}";
        assert_eq!(parse_write(explicit), explicit);
    }

    #[test]
    fn a_call_described_in_prose_is_accepted_only_in_the_two_exact_shapes() {
        let prose = |text: &str| {
            parse(
                &response(json!({ "role": "assistant", "content": text }), "stop"),
                &facts("off"),
            )
        };
        let parsed =
            prose("{\"name\":\"read_file\",\"arguments\":{\"path\":\"a\"}}").expect("parsed");
        assert_eq!(parsed["finish_reason"], json!("tool_calls"));
        assert_eq!(parsed["tool_calls"][0]["name"], json!("read_file"));
        assert_eq!(parsed["tool_calls"][0]["id"], json!("compat:resp-1"));
        assert_eq!(parsed["text"], json!(""));
        // Ordinary prose that happens to be JSON stays prose.
        let plain = prose("{\"answer\":42}").expect("parsed");
        assert_eq!(plain["tool_calls"], json!([]));
        assert_eq!(plain["finish_reason"], json!("stop"));
        // A shape that is close but not exact stays prose too.
        let loose = prose("{\"name\":\"read_file\",\"arguments\":{},\"extra\":1}").expect("parsed");
        assert_eq!(loose["tool_calls"], json!([]));
    }

    #[test]
    fn a_compatibility_id_falls_back_when_the_response_id_cannot_spell_one() {
        let mut reply = response(
            json!({ "role": "assistant",
                    "content": "{\"name\":\"read_file\",\"arguments\":{\"path\":\"a\"}}" }),
            "stop",
        );
        // 128 bytes is the identifier bound; "compat:" pushes this past it.
        reply["id"] = json!("x".repeat(126));
        let parsed = parse(&reply, &facts("off")).expect("parsed");
        assert_eq!(
            parsed["tool_calls"][0]["id"],
            json!("compat:11111111-1111-4111-8111-111111111111")
        );
    }

    #[test]
    fn a_reply_that_says_nothing_is_not_an_answer() {
        assert_eq!(
            parse(
                &response(json!({ "role": "assistant", "content": "   " }), "stop"),
                &facts("off")
            ),
            Err(FINISH_RELATION)
        );
    }

    #[test]
    fn exactly_one_choice_is_one_turn() {
        let mut two = response(json!({ "role": "assistant", "content": "hi" }), "stop");
        two["choices"] = json!([
            { "message": { "role": "assistant", "content": "a" }, "finish_reason": "stop" },
            { "message": { "role": "assistant", "content": "b" }, "finish_reason": "stop" },
        ]);
        assert_eq!(parse(&two, &facts("off")), Err(EMPTY_RESPONSE));
    }
}
