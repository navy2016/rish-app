//! `rish-agent-core` is the platform-independent half of the Rish agent
//! engine. The iOS app currently implements the engine in Objective-C++
//! (`modules/rish/ios/Sources/Agent*.mm`); this crate takes it over one
//! component at a time behind the existing native interfaces, with the ObjC
//! test suites as the oracle. See the plan in the document centre
//! (`rish-app/plans/2026-09-14-shared-agent-core-astra.md`).
//!
//! Phase 0: canonical JSON, domain-separated hashing, and the strict argument
//! parser, pinned byte for byte to the ObjC engine by
//! `fixtures/canonical-golden.json`.
//!
//! Phase 1: the schema-3 round journal as a pure reducer
//! ([`round_journal`]), driven by the ObjC facade that still owns the WAL
//! transaction, and the bounded primitive validators it needs ([`schema`]).

pub mod canonical;
pub mod completion_response;
pub mod execution_ledger;
pub mod git_tool;
pub mod ledger_batch;
pub mod ledger_ops;
pub mod prepared_attempt;
pub mod provider_round;
pub mod root_projection;
pub mod round_journal;
pub mod runtime_coordinator;
pub mod runtime_tools;
pub mod schema;
pub mod session_schema;
pub mod store;
pub mod strict_json;
pub mod tool_batch;
pub mod tool_execution;
pub mod tool_registry;
pub mod transcript_store;
pub mod wal_operations;
pub mod wal_resident;
pub mod wal_state;
pub mod workspace_tool;
mod write_parent_plan;

/// Protocol version reported over the C ABI. Bumped when the JSON contract
/// of any exported operation changes incompatibly.
pub const PROTOCOL_VERSION: u32 = 1;
