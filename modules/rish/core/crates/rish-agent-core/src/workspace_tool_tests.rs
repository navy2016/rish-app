use super::*;
use std::fmt::Write as _;

#[test]
fn the_root_is_the_empty_path_and_a_bare_dot_only_for_a_listing() {
    assert_eq!(path_components("", true), Some(vec![]));
    assert_eq!(path_components(".", true), Some(vec![]));
    assert_eq!(path_components("", false), None);
    assert_eq!(path_components(".", false), None);
}

#[test]
fn native_metadata_is_never_addressable_by_a_tool() {
    for path in [
        ".git",
        ".git/config",
        "a/.git",
        ".trash",
        "a/.trash/b",
        "..",
        "a/../b",
        "/abs",
        "a\\b",
        "a//b",
        "a/\u{1}/b",
    ] {
        assert_eq!(path_components(path, true), None, "{path}");
    }
    // Ordinary dotfiles stay addressable.
    assert_eq!(
        path_components("src/.gitignore", false),
        Some(vec!["src".into(), ".gitignore".into()])
    );
}

#[test]
fn a_decomposed_path_is_not_the_same_path() {
    assert!(path_components("café.md", false).is_some());
    // The same name with a combining accent is refused rather than
    // silently normalised into a different file.
    assert_eq!(path_components("cafe\u{301}.md", false), None);
}

#[test]
fn a_listing_is_ordered_by_bytes_so_every_device_fingerprints_it_alike() {
    let entry = |name: &str| json!({ "name": name, "kind": "file", "revision": "1:2:3:4:5" });
    let listed =
        directory_listing(&[entry("b"), entry("A"), entry("a"), entry("ab")]).expect("listing");
    let names: Vec<&str> = listed["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .map(|entry| entry["name"].as_str().expect("name"))
        .collect();
    assert_eq!(names, vec!["A", "a", "ab", "b"]);
}

#[test]
fn reserved_entries_are_hidden_and_do_not_count_against_the_bound() {
    let mut entries: Vec<Value> = vec![
        json!({ "name": ".git", "kind": "directory", "revision": "1:2:3:4:5" }),
        json!({ "name": ".Trash", "kind": "directory", "revision": "1:2:3:4:5" }),
        json!({ "name": ".staging-1", "kind": "file", "revision": "1:2:3:4:5" }),
        json!({ "name": ".rish-write-1", "kind": "file", "revision": "1:2:3:4:5" }),
    ];
    for index in 0..MAX_ENTRIES {
        entries.push(json!({
            "name": format!("f{index:05}"), "kind": "file", "revision": "1:2:3:4:5",
        }));
    }
    let listed = directory_listing(&entries).expect("listing");
    assert_eq!(
        listed["entries"].as_array().expect("entries").len(),
        MAX_ENTRIES
    );
    entries.push(json!({ "name": "one-too-many", "kind": "file", "revision": "1:2:3:4:5" }));
    assert_eq!(directory_listing(&entries), Err(StoreError::Capacity));
}

/// The capacity bound is reached before an entry the host will not expose
/// is judged, because in the original the two checks were interleaved with
/// the directory walk in that order.
#[test]
fn a_full_directory_is_at_capacity_even_if_a_later_entry_is_unusable() {
    let mut entries: Vec<Value> = (0..MAX_ENTRIES)
        .map(|index| {
            json!({
                "name": format!("f{index:05}"), "kind": "file", "revision": "1:2:3:4:5",
            })
        })
        .collect();
    entries.push(json!({ "name": "link", "kind": "invalid", "revision": "1:2:3:4:5" }));
    assert_eq!(directory_listing(&entries), Err(StoreError::Capacity));
    // With room to spare, the same entry is a conflict.
    assert_eq!(
        directory_listing(&entries[MAX_ENTRIES..]),
        Err(StoreError::Conflict)
    );
}

/// A name that cannot be decoded refuses straight away, ahead of the
/// capacity bound — the one refusal that does not wait its turn.
#[test]
fn a_name_that_is_not_utf8_refuses_before_anything_else() {
    let mut entries: Vec<Value> = (0..MAX_ENTRIES + 5)
        .map(|index| {
            json!({
                "name": format!("f{index:05}"), "kind": "file", "revision": "1:2:3:4:5",
            })
        })
        .collect();
    entries.insert(
        MAX_ENTRIES + 3,
        json!({ "name": "", "kind": "unnamed", "revision": "" }),
    );
    // Capacity is reached first, because the undecodable entry is later.
    assert_eq!(directory_listing(&entries), Err(StoreError::Capacity));
    entries.insert(0, json!({ "name": "", "kind": "unnamed", "revision": "" }));
    assert_eq!(
        directory_listing(&entries),
        Err(StoreError::InvalidArgument)
    );
}

#[test]
fn binary_content_has_no_preview() {
    assert!(diff_preview(Some("a\0b"), "c", false).diff.is_none());
    assert!(diff_preview(Some("a"), "c\0d", false).diff.is_none());
    // A prior the host could not decode arrives as None.
    assert!(diff_preview(None, "c", false).diff.is_none());
}

#[test]
fn an_unchanged_file_previews_as_empty() {
    let preview = diff_preview(Some("a\nb\n"), "a\nb\n", false);
    assert_eq!(preview.diff.as_deref(), Some(""));
    assert!(!preview.truncated);
}

/// The bug this replaced: the helper cleared the flag on entry and
/// assigned it again on exit, so each bound erased the one before it.
#[test]
fn every_bound_that_hides_something_raises_the_flag_and_none_clears_it() {
    // A prior read the host already cut short stays marked.
    let preview = diff_preview(Some("a\n"), "b\n", true);
    assert!(preview.truncated);
    // Past the line bound, with a one-line hunk inside it.
    let mut prior = String::new();
    for i in 0..2500 {
        writeln!(prior, "line {i:04}").expect("string");
    }
    let next = prior.replace("line 0005\n", "LINE 0005\n");
    let preview = diff_preview(Some(&prior), &next, false);
    assert!(preview.truncated);
    assert!(preview.diff.expect("diff").contains("-line 0005"));
    // Past the hunk bound.
    let preview = diff_preview(Some("x\n"), &"y\n".repeat(30), false);
    assert!(preview.truncated);
}

/// 1,500 Chinese characters are 4,500 UTF-8 bytes but 1,500 UTF-16 units,
/// so a clip taken at a UTF-16 index ran past the end of the string.
#[test]
fn a_wide_character_preview_is_clipped_by_bytes_on_a_character_boundary() {
    let tail = "一直写下去".repeat(5);
    let mut prior = String::new();
    let mut next = String::new();
    for i in 0..60 {
        writeln!(prior, "旧的内容第{i}行{tail}").expect("string");
        writeln!(next, "新的内容第{i}行{tail}").expect("string");
    }
    let preview = diff_preview(Some(&prior), &next, false);
    let diff = preview.diff.expect("diff");
    assert!(preview.truncated);
    // The gap the old clip fell through: over the byte budget, under the
    // UTF-16 index it used to clip at.
    let unclipped: usize = diff.chars().map(char::len_utf16).sum();
    assert!(unclipped < MAX_PREVIEW_BYTES / 2, "{unclipped}");
    assert!(diff.len() <= MAX_PREVIEW_BYTES / 2 + 4, "{}", diff.len());
    assert!(diff.ends_with("\n…"));
}

#[test]
fn a_write_without_an_expectation_asserts_the_file_is_absent() {
    let arguments = |value: Value| value.as_object().expect("object").clone();
    assert_eq!(
        write_expected_prior(&arguments(json!({ "path": "a", "content": "b" }))).expect("prior"),
        json!({ "schema_version": 1, "kind": "absent" })
    );
    assert_eq!(
        write_expected_prior(&arguments(
            json!({ "path": "a", "content": "b", "expected_revision": null })
        ))
        .expect("prior"),
        json!({ "schema_version": 1, "kind": "absent" })
    );
    assert_eq!(
        write_expected_prior(&arguments(
            json!({ "path": "a", "content": "b", "expected_revision": "1:2:3:4:5" })
        ))
        .expect("prior"),
        json!({ "schema_version": 1, "kind": "known", "revision": "1:2:3:4:5" })
    );
    // Both forms at once, or an extra key, is not a call this tool takes.
    assert!(write_expected_prior(&arguments(json!({
        "path": "a", "content": "b", "expected_revision": null, "expected_prior": null
    })))
    .is_err());
}

#[test]
fn a_failure_result_is_feedback_the_ledger_would_accept() {
    let result = failure_result("write_file", "E_AGENT_BAD_PATH", false).expect("result");
    assert_eq!(result["status"], json!("failed"));
    assert_eq!(result["effect_may_have_occurred"], json!(false));
    let ambiguous = failure_result("write_file", "E_AGENT_BAD_PATH", true).expect("result");
    assert_eq!(ambiguous["status"], json!("ambiguous"));
    assert_eq!(ambiguous["effect_may_have_occurred"], json!(true));
    // A code outside the closed union cannot be reported at all.
    assert!(failure_result("write_file", "E_MADE_UP", false).is_err());
}

#[test]
fn a_workspace_tool_report_is_capped_tighter_than_a_transcript() {
    let report = |content: &str| {
        json!({
            "schema_version": 1, "name": "read_file", "outcome": "ok",
            "payload": {
                "schema_version": 1, "content": content,
                "revision": "1:2:3:4:5", "truncated": true,
            },
        })
    };
    assert!(feedback(&report("hi")).is_ok());
    assert_eq!(
        feedback(&report(&"x".repeat(64 * 1024))),
        Err(StoreError::Capacity)
    );
}

#[test]
fn the_host_reads_its_byte_caps_from_here() {
    let reply: Value =
        serde_json::from_str(&reduce_json(&json!({ "op": "bounds" }).to_string())).expect("reply");
    assert_eq!(reply["max_path_bytes"], json!(512));
    assert_eq!(reply["max_read_bytes"], json!(60 * 1024));
    assert_eq!(reply["max_prior_read_bytes"], json!(64 * 1024));
    assert_eq!(reply["max_entries"], json!(1000));
}

#[test]
fn a_revision_is_the_file_state_the_host_read() {
    assert_eq!(revision(1, 2, 255, 16, 4095), "1:2:ff:10:fff");
}

#[test]
fn incremental_entry_decisions_preserve_the_directory_walk_refusal_order() {
    let decision = |name: &str, kind: &str, count| {
        let reply: Value = serde_json::from_str(&reduce_json(
            &json!({
                "op": "directory_entry_decision", "visible_count": count,
                "entry": {"name": name, "kind": kind, "revision": "1:2:3:4:5"},
            })
            .to_string(),
        ))
        .expect("reply");
        reply
    };
    assert_eq!(decision("a", "uninspected", 0)["decision"], "inspect");
    assert_eq!(decision("a", "file", 0)["decision"], "include");
    for name in [".", "..", ".GIT", ".Trash", ".Staging-x", ".RISH-WRITE-x"] {
        assert_eq!(
            decision(name, "uninspected", MAX_ENTRIES)["decision"],
            "skip"
        );
        assert_eq!(decision(name, "invalid", MAX_ENTRIES)["decision"], "skip");
    }
    assert_eq!(
        decision("a", "uninspected", MAX_ENTRIES)["error"],
        StoreError::Capacity.code()
    );
    assert_eq!(
        decision("a", "invalid", MAX_ENTRIES)["error"],
        StoreError::Capacity.code()
    );
    assert_eq!(
        decision("a", "invalid", 0)["error"],
        StoreError::Conflict.code()
    );
    assert_eq!(
        decision("", "unnamed", MAX_ENTRIES)["error"],
        StoreError::InvalidArgument.code()
    );
    // Metadata failure precedes name canonicality, but only after capacity.
    assert_eq!(
        decision("cafe\u{301}", "invalid", 0)["error"],
        StoreError::Conflict.code()
    );
    assert_eq!(
        decision("cafe\u{301}", "file", 0)["error"],
        StoreError::InvalidArgument.code()
    );
    assert_eq!(
        directory_listing(&[json!({"name": "a", "kind": "uninspected"})]),
        Err(StoreError::InvalidArgument)
    );
}

#[test]
fn control_and_format_paths_are_refused_without_rejecting_adjacent_unicode() {
    // All 170 Cf scalars in Unicode 16.0, independently enumerated as inclusive
    // code-point ranges so every boundary, including supplementary planes, is
    // exercised through the public path reducer. Cc remains Rust's category.
    let ranges: &[(u32, u32)] = &[
        (0x00ad, 0x00ad),
        (0x0600, 0x0605),
        (0x061c, 0x061c),
        (0x06dd, 0x06dd),
        (0x070f, 0x070f),
        (0x0890, 0x0891),
        (0x08e2, 0x08e2),
        (0x180e, 0x180e),
        (0x200b, 0x200f),
        (0x202a, 0x202e),
        (0x2060, 0x2064),
        (0x2066, 0x206f),
        (0xfeff, 0xfeff),
        (0xfff9, 0xfffb),
        (0x110bd, 0x110bd),
        (0x110cd, 0x110cd),
        (0x13430, 0x1343f),
        (0x1bca0, 0x1bca3),
        (0x1d173, 0x1d17a),
        (0xe0001, 0xe0001),
        (0xe0020, 0xe007f),
    ];
    let mut checked = 0;
    for &(start, end) in ranges {
        for scalar in start..=end {
            let c = char::from_u32(scalar).expect("scalar");
            assert!(
                path_components(&format!("a{c}b"), false).is_none(),
                "U+{scalar:04X}"
            );
            checked += 1;
        }
        for scalar in [start - 1, end + 1] {
            let c = char::from_u32(scalar).expect("scalar");
            if c.is_control() || ranges.iter().any(|&(lo, hi)| (lo..=hi).contains(&scalar)) {
                continue;
            }
            assert!(
                path_components(&format!("a{c}b"), false).is_some(),
                "U+{scalar:04X}"
            );
        }
    }
    assert_eq!(checked, 170);
    for scalar in (0..=0x1f).chain(0x7f..=0x9f) {
        let c = char::from_u32(scalar).expect("scalar");
        assert!(path_components(&format!("a{c}b"), false).is_none());
    }
    for c in [
        'é',
        '中',
        '😀',
        '\u{200a}',
        '\u{2065}',
        '\u{e0100}',
        '\u{e0101}',
        '\u{e0102}',
    ] {
        assert!(path_components(&format!("a{c}b"), false).is_some());
    }
}

// The approval preview's shape and bounds, pinned against
// `DSHAgentApprovalUnifiedDiff` as it stood at 8e33d06 — the last commit
// before it moved here. A person approves a write by reading this, so what
// the bounds *hide* is as much the rule as what they show.

/// Splitting on "\n" leaves a trailing empty line for a file that ends with a
/// newline, and that empty line takes part in the anchoring like any other:
/// it anchors the suffix, so one line changes rather than two, and it is then
/// emitted as trailing context — a context line whose content is empty, which
/// renders as a lone space. Odd-looking, and exactly what the original did.
#[test]
fn a_trailing_newline_is_a_line() {
    let preview = diff_preview(Some("a\n"), "b\n", false).diff.expect("diff");
    assert_eq!(preview, "@@ -1,1 +1,1 @@\n-a\n+b\n ");
    // Without the trailing newline there is no such line and no such context.
    let preview = diff_preview(Some("a"), "b", false).diff.expect("diff");
    assert_eq!(preview, "@@ -1,1 +1,1 @@\n-a\n+b");
}

/// The header counts the removed and added lines and names the line the hunk
/// starts at, one-based.
#[test]
fn the_hunk_header_names_where_the_change_starts_and_how_big_it_is() {
    let prior = "keep1\nkeep2\nold1\nold2\ntail1\ntail2";
    let next = "keep1\nkeep2\nnew1\ntail1\ntail2";
    let preview = diff_preview(Some(prior), next, false).diff.expect("diff");
    assert!(preview.starts_with("@@ -3,2 +3,1 @@"), "{preview}");
}

/// Up to three unchanged lines either side, taken from the prior in both
/// cases, so the reader can see where the change sits.
#[test]
fn three_lines_of_context_surround_the_change() {
    let prior: String = (0..12).map(|i| format!("line{i}\n")).collect();
    let next = prior.replace("line6\n", "CHANGED\n");
    let preview = diff_preview(Some(&prior), &next, false).diff.expect("diff");
    assert_eq!(
        preview,
        "@@ -7,1 +7,1 @@\n line3\n line4\n line5\n-line6\n+CHANGED\n line7\n line8\n line9"
    );
    // Fewer than three available before the change is not an error.
    let prior = "a\nb\nc";
    let preview = diff_preview(Some(prior), "a\nB\nc", false)
        .diff
        .expect("diff");
    assert_eq!(preview, "@@ -2,1 +2,1 @@\n a\n-b\n+B\n c");
}

/// At most 24 lines each way are shown, and the ellipsis says the rest was
/// left out. It sits between the added lines and the trailing context.
#[test]
fn a_hunk_shows_at_most_twenty_four_lines_each_way() {
    let prior: String = (0..30).map(|i| format!("old{i}\n")).collect();
    let next: String = (0..30).map(|i| format!("new{i}\n")).collect();
    let preview = diff_preview(Some(&prior), &next, false);
    let diff = preview.diff.expect("diff");
    assert!(preview.truncated, "a clipped hunk is a truncated preview");
    assert_eq!(diff.matches("\n-").count(), 24);
    assert_eq!(diff.matches("\n+").count(), 24);
    assert!(diff.contains("\n…"), "{diff}");
    assert!(diff.contains("-old23") && !diff.contains("-old24"));
    // The header still counts the whole change, not the part shown.
    assert!(diff.starts_with("@@ -1,30 +1,30 @@"), "{diff}");
    // Exactly 24 is not truncation.
    let prior: String = (0..24).map(|i| format!("old{i}\n")).collect();
    let next: String = (0..24).map(|i| format!("new{i}\n")).collect();
    let preview = diff_preview(Some(&prior), &next, false);
    assert!(!preview.truncated);
    assert!(!preview.diff.expect("diff").contains('…'));
}

/// Past 2,000 lines both sides are cut to the first 2,000 before anything is
/// compared — so a change below that line is not merely elided from the hunk,
/// it is never seen. The flag is the only thing that says so, which is why it
/// may not be cleared.
#[test]
fn a_change_past_the_line_bound_is_invisible_not_elided() {
    let prior: String = (0..2500).map(|i| format!("line{i}\n")).collect();
    // The only difference is past the bound.
    let next = prior.replace("line2400\n", "CHANGED\n");
    let preview = diff_preview(Some(&prior), &next, false);
    assert!(preview.truncated, "the reader has to be told");
    // Within the first 2,000 lines the two are identical, so the diff is empty
    // even though the files differ.
    assert_eq!(preview.diff.as_deref(), Some(""));
}

/// Over the byte budget the preview is cut to half of it and marked. The cut
/// lands on a character boundary and the ellipsis is appended after it.
#[test]
fn an_oversized_preview_is_cut_to_half_the_budget() {
    let prior: String = (0..40)
        .map(|i| format!("old{i} {}\n", "x".repeat(200)))
        .collect();
    let next: String = (0..40)
        .map(|i| format!("new{i} {}\n", "x".repeat(200)))
        .collect();
    let preview = diff_preview(Some(&prior), &next, false);
    let diff = preview.diff.expect("diff");
    assert!(preview.truncated);
    assert!(diff.ends_with("\n…"), "{}", &diff[diff.len() - 16..]);
    // Half the budget, plus the four bytes of "\n…".
    assert!(diff.len() <= 4096 / 2 + 4, "{}", diff.len());
    assert!(
        diff.len() > 4096 / 2 - 8,
        "cut, not merely short: {}",
        diff.len()
    );
}

/// A file that gains or loses lines at one end still anchors on the unchanged
/// part rather than reporting the whole file as changed.
#[test]
fn an_insertion_anchors_on_what_did_not_move() {
    let preview = diff_preview(Some("a\nb\nc"), "a\nNEW\nb\nc", false)
        .diff
        .expect("diff");
    assert_eq!(preview, "@@ -2,0 +2,1 @@\n a\n+NEW\n b\n c");
    let preview = diff_preview(Some("a\nb\nc"), "a\nc", false)
        .diff
        .expect("diff");
    assert_eq!(preview, "@@ -2,1 +2,0 @@\n a\n-b\n c");
}
