//! What a person is told the agent may do.
//!
//! Ported from `AgentPolicyService.mm`. The describe result is a *safe*
//! projection: it is handed to the JavaScript layer and shown in the UI, so
//! the interesting property is not what it contains but what it must never
//! contain — a filesystem path, the native descriptor table, tool arguments,
//! or anything that could be mistaken for an authority handle. Enumerating the
//! output keys explicitly is the rule; an accidental extra key is a leak.
//!
//! The root fingerprint is included on purpose: it lets a UI notice that a
//! grant display has gone stale. It grants no execution authority by itself.

use serde_json::{json, Value};

use crate::schema::{canonical_uuid, exact_keys, is_null, safe_integer, MAX_SAFE_INTEGER};

pub const POLICY_VERSION: &str = "agent-v1";

/// `DSHPolicyValidRequest`.
pub fn request_shape(request: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        request,
        &[
            "schema_version",
            "workspace_id",
            "workspace_binding_revision",
            "project_id",
        ],
    ) else {
        return false;
    };
    safe_integer(map.get("schema_version"), 1, false).is_some()
        && canonical_uuid(map.get("workspace_id"))
        && safe_integer(
            map.get("workspace_binding_revision"),
            MAX_SAFE_INTEGER,
            false,
        )
        .is_some()
        && (is_null(map.get("project_id")) || canonical_uuid(map.get("project_id")))
}

/// `DSHPolicyValidBudget`. The three bounds nest: a single write cannot exceed
/// what a batch may spend, and a batch cannot exceed what an attempt may.
pub fn budget_shape(policy: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        policy,
        &[
            "schema_version",
            "policy_version",
            "max_single_write_bytes",
            "max_batch_write_bytes",
            "max_attempt_write_bytes",
        ],
    ) else {
        return false;
    };
    let bound = |key: &str| safe_integer(map.get(key), MAX_SAFE_INTEGER, false);
    let (Some(single), Some(batch), Some(attempt)) = (
        bound("max_single_write_bytes"),
        bound("max_batch_write_bytes"),
        bound("max_attempt_write_bytes"),
    ) else {
        return false;
    };
    safe_integer(map.get("schema_version"), 1, false).is_some()
        && map.get("policy_version") == Some(&json!(POLICY_VERSION))
        && single <= batch
        && batch <= attempt
}

/// The resolved root has to be the one that was asked about. A resolver that
/// answered for a different workspace, revision or project has answered a
/// different question, and the caller's display would be about something else.
pub fn root_matches_request(root: Option<&Value>, request: Option<&Value>) -> bool {
    ["workspace_id", "workspace_binding_revision", "project_id"]
        .iter()
        .all(|key| root.and_then(|v| v.get(key)) == request.and_then(|v| v.get(key)))
}

/// The safe projection, with its keys enumerated rather than copied from the
/// inputs. Every tool contributes exactly its name and its access.
pub fn projection(request: &Value, root: &Value, registry: &Value, policy: &Value) -> Value {
    let tools: Vec<Value> = registry
        .get("tools")
        .and_then(Value::as_array)
        .map(|tools| {
            tools
                .iter()
                .map(|tool| json!({ "name": tool.get("name"), "access": tool.get("access") }))
                .collect()
        })
        .unwrap_or_default();
    json!({
        "schema_version": 1,
        "workspace_id": request.get("workspace_id"),
        "workspace_binding_revision": request.get("workspace_binding_revision"),
        "project_id": request.get("project_id"),
        "registry_version": registry.get("registry_version"),
        "root_fingerprint_sha256": root.get("root_fingerprint_sha256"),
        "policy_version": policy.get("policy_version"),
        "capabilities": root.get("capabilities"),
        "tools": tools,
        "budget": {
            "max_single_write_bytes": policy.get("max_single_write_bytes"),
            "max_batch_write_bytes": policy.get("max_batch_write_bytes"),
            "max_attempt_write_bytes": policy.get("max_attempt_write_bytes"),
        },
    })
}

/// One envelope in, one reply out; see `rish_agent_policy_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let envelope: Value = serde_json::from_str(input).ok()?;
    let request = envelope.get("request");
    match envelope.get("op")?.as_str()? {
        "request_shape" => Some(json!({ "ok": true, "valid": request_shape(request) })),
        "budget_shape" => Some(json!({
            "ok": true, "valid": budget_shape(envelope.get("policy"))
        })),
        "root_matches_request" => Some(json!({
            "ok": true, "matches": root_matches_request(envelope.get("root"), request)
        })),
        "projection" => Some(json!({
            "ok": true,
            "result": projection(
                request?,
                envelope.get("root")?,
                envelope.get("registry")?,
                envelope.get("policy")?,
            ),
        })),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> Value {
        json!({
            "schema_version": 1,
            "workspace_id": "a1b2c3d4-1111-4111-8111-1111abcd1111",
            "workspace_binding_revision": 7,
            "project_id": null,
        })
    }

    fn policy() -> Value {
        json!({
            "schema_version": 1, "policy_version": POLICY_VERSION,
            "max_single_write_bytes": 32768,
            "max_batch_write_bytes": 524288,
            "max_attempt_write_bytes": 4194304,
        })
    }

    #[test]
    fn a_well_formed_request_is_accepted_and_its_neighbours_are_not() {
        assert!(request_shape(Some(&request())));
        let mut project = request();
        project["project_id"] = json!("b2c3d4e5-2222-4222-8222-2222abcd2222");
        assert!(request_shape(Some(&project)));
        for key in [
            "schema_version",
            "workspace_id",
            "workspace_binding_revision",
            "project_id",
        ] {
            let mut missing = request();
            missing.as_object_mut().expect("object").remove(key);
            assert!(!request_shape(Some(&missing)), "missing {key}");
        }
        let mut extra = request();
        extra["path"] = json!("/tmp");
        assert!(!request_shape(Some(&extra)), "an extra key");
        let mut zero = request();
        zero["workspace_binding_revision"] = json!(0);
        assert!(!request_shape(Some(&zero)), "revision zero");
        let mut upper = request();
        upper["workspace_id"] = json!("A1B2C3D4-1111-4111-8111-1111ABCD1111");
        assert!(!request_shape(Some(&upper)), "an uppercase workspace id");
    }

    /// The three bounds nest. A batch that could not hold one write, or an
    /// attempt that could not hold one batch, would be a budget no caller
    /// could act on.
    #[test]
    fn the_write_budgets_nest() {
        assert!(budget_shape(Some(&policy())));
        let mut inverted = policy();
        inverted["max_single_write_bytes"] = json!(524289);
        assert!(
            !budget_shape(Some(&inverted)),
            "a write bigger than a batch"
        );
        let mut wide = policy();
        wide["max_batch_write_bytes"] = json!(4194305);
        assert!(!budget_shape(Some(&wide)), "a batch bigger than an attempt");
        let mut equal = policy();
        equal["max_single_write_bytes"] = json!(4194304);
        equal["max_batch_write_bytes"] = json!(4194304);
        assert!(budget_shape(Some(&equal)), "equal bounds nest");
        let mut version = policy();
        version["policy_version"] = json!("agent-v2");
        assert!(!budget_shape(Some(&version)), "another policy version");
        let mut zero = policy();
        zero["max_single_write_bytes"] = json!(0);
        assert!(!budget_shape(Some(&zero)), "a bound of zero");
    }

    #[test]
    fn a_root_for_a_different_question_is_not_an_answer() {
        let root = json!({
            "workspace_id": "a1b2c3d4-1111-4111-8111-1111abcd1111",
            "workspace_binding_revision": 7, "project_id": null,
        });
        assert!(root_matches_request(Some(&root), Some(&request())));
        for (key, value) in [
            (
                "workspace_id",
                json!("b2c3d4e5-2222-4222-8222-2222abcd2222"),
            ),
            ("workspace_binding_revision", json!(8)),
            ("project_id", json!("b2c3d4e5-2222-4222-8222-2222abcd2222")),
        ] {
            let mut other = root.clone();
            other[key] = value;
            assert!(
                !root_matches_request(Some(&other), Some(&request())),
                "{key}"
            );
        }
    }

    /// The projection is what the UI is handed. Its keys are enumerated, so a
    /// path, a native descriptor table or an argument that appears in an input
    /// must not appear in the output.
    #[test]
    fn the_projection_carries_nothing_it_was_not_asked_to() {
        let root = json!({
            "schema_version": 1, "kind": "workspace",
            "workspace_id": "a1b2c3d4-1111-4111-8111-1111abcd1111",
            "workspace_binding_revision": 7, "project_id": null,
            "root_fingerprint_sha256": "c".repeat(64),
            "capabilities": ["file_read", "file_write"],
        });
        let registry = json!({
            "schema_version": 2, "registry_version": 2,
            "toolset_sha256": "d".repeat(64),
            "tools": [
                { "name": "read_file", "access": "auto",
                  "parameters": { "path": { "type": "string" } },
                  "absolute_path": "/private/var/x" },
                { "name": "write_file", "access": "conversation_confirm",
                  "arguments": "{\"path\":\"a\"}" },
            ],
        });
        let result = projection(&request(), &root, &registry, &policy());
        let keys: Vec<&str> = result
            .as_object()
            .expect("object")
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(
            keys,
            vec![
                "budget",
                "capabilities",
                "policy_version",
                "project_id",
                "registry_version",
                "root_fingerprint_sha256",
                "schema_version",
                "tools",
                "workspace_binding_revision",
                "workspace_id",
            ]
        );
        // The toolset digest is an authority binding, not a display fact.
        assert!(result.get("toolset_sha256").is_none());
        for tool in result["tools"].as_array().expect("tools") {
            let keys: Vec<&str> = tool
                .as_object()
                .expect("object")
                .keys()
                .map(String::as_str)
                .collect();
            assert_eq!(keys, vec!["access", "name"]);
        }
        let rendered = result.to_string();
        for leaked in [
            "/private/var/x",
            "parameters",
            "arguments",
            "toolset_sha256",
        ] {
            assert!(
                !rendered.contains(leaked),
                "{leaked} reached the projection"
            );
        }
    }
}
