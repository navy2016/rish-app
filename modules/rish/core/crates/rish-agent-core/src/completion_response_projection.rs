//! Host JSON storage facts for the live Foundation provider boundary.
//!
//! The core asks for decoding or sorted serialization of an original string.
//! Foundation executes that mechanical operation, while eligibility, selected
//! parameter path, create-only defaults and byte limits remain in the parser.
//! Reusing the original source preserves Foundation number and slash spelling.

use serde_json::{json, Value};

pub(super) const CONTRACT: &str = "foundation-json-v1";
const MAX_OPERATIONS: usize = 32; // Two operations for each of sixteen calls.
const MAX_SOURCE_BYTES: usize = 256 * 1024;

pub(super) struct Projection<'a> {
    results: Option<&'a [Value]>,
    index_storage: Option<&'a [Value]>,
    pub requests: Vec<Value>,
}

impl<'a> Projection<'a> {
    pub fn portable() -> Self {
        Self {
            results: None,
            index_storage: None,
            requests: Vec::new(),
        }
    }

    pub fn from_envelope(envelope: &'a Value) -> Option<Self> {
        if envelope.get("projection_contract").is_none() {
            return Some(Self::portable());
        }
        if envelope.get("projection_contract")?.as_str()? != CONTRACT {
            return None;
        }
        let results = envelope.get("json_results")?.as_array()?;
        let storage = envelope.get("call_index_storage")?.as_array()?;
        // The host records one overflow slot so the parser can retain the
        // established too-many-calls error before evaluating per-call facts.
        if results.len() > MAX_OPERATIONS || storage.len() > 17 {
            return None;
        }
        for (index, result) in results.iter().enumerate() {
            let object = result.as_object()?;
            let request = object.get("request")?.as_object()?;
            if object.len() != 2
                || !object.contains_key("value")
                || request.len() != 4
                || request.get("source")?.as_str()?.len() > MAX_SOURCE_BYTES
                || !matches!(request.get("op")?.as_str()?, "decode" | "encode")
                || !matches!(
                    request.get("path")?.as_str()?,
                    "" | "arguments" | "parameters"
                )
                || !request.get("insert_null_revision")?.is_boolean()
                || results[..index]
                    .iter()
                    .any(|old| old["request"] == result["request"])
            {
                return None;
            }
        }
        if !storage.iter().all(|value| {
            matches!(
                value.as_str(),
                Some("missing" | "signed" | "unsigned" | "floating" | "boolean" | "other")
            )
        }) {
            return None;
        }
        Some(Self {
            results: Some(results),
            index_storage: Some(storage),
            requests: Vec::new(),
        })
    }

    pub fn valid_index_facts(&self, count: usize) -> bool {
        self.index_storage
            .is_none_or(|storage| storage.len() == count)
    }

    pub fn integer_storage(&self, index: usize) -> bool {
        self.index_storage.is_none_or(|storage| {
            matches!(
                storage.get(index).and_then(Value::as_str),
                Some("signed" | "unsigned")
            )
        })
    }

    fn request(&mut self, op: &str, source: &str, path: &str, insert: bool) -> Option<Value> {
        let request = json!({
            "op": op, "source": source, "path": path, "insert_null_revision": insert,
        });
        if let Some(found) = self
            .results?
            .iter()
            .find(|result| result["request"] == request)
        {
            return Some(found["value"].clone());
        }
        if !self.requests.contains(&request) {
            self.requests.push(request);
        }
        None
    }

    pub fn decode(&mut self, source: &str) -> Option<Value> {
        if self.results.is_some() {
            self.request("decode", source, "", false)
        } else {
            serde_json::from_str(source).ok()
        }
    }

    pub fn encode(
        &mut self,
        source: &str,
        path: &str,
        insert: bool,
        value: &Value,
        maximum: usize,
    ) -> Option<String> {
        let text = if self.results.is_some() {
            self.request("encode", source, path, insert)?
                .as_str()?
                .to_string()
        } else {
            // Preserve the existing portable contract. Only the iOS live
            // boundary requests its original Foundation writer projection.
            String::from_utf8(crate::canonical::canonical_json(value).ok()?).ok()?
        };
        (text.len() <= maximum).then_some(text)
    }
}
