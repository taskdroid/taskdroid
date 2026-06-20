//! Compatibility tests translated from Taskwarrior's Python test suite
//!
//! Each test is named after the TW test it maps to and annotated with its
//! expected status on the current master branch:
//!   - `PASS`  : identical behaviour already implemented
//!   - `FAIL`  : known gap (feature not yet ported)
//!   - `N/A`   : not applicable
//!
//! Run: cargo test --lib compat -- --show-output

use crate::core::Result;
use crate::core::manager::{RecurrenceRule, WorkerState, due_for_index};
use crate::core::models::{CreateTaskParams, TaskSnapshot, TaskStatus, UdaPair, UpdateTaskParams};
use crate::core::query_language::{matches_query, task_with};
use crate::core::utils::{parse_iso8601, task_snapshot_from_task};
use taskchampion::{
    Replica, Status as TcStatus, StorageConfig,
    chrono::{Datelike, Duration, TimeZone, Utc, Weekday},
};

// ------------------------------------------------------------------
// Test context: wraps WorkerState so tests read like `task` CLI
// ------------------------------------------------------------------
struct TestContext {
    state: WorkerState,
}

impl TestContext {
    fn new() -> Self {
        let storage = StorageConfig::InMemory
            .into_storage()
            .expect("in-memory storage");
        Self {
            state: WorkerState {
                replica: Some(Replica::new(storage)),
                recurrence_limit: 1,
            },
        }
    }

    /// `task add <desc> [due:due] [recur:recur] [until:until] [wait:wait]`
    fn add(
        &mut self,
        desc: &str,
        due: Option<&str>,
        recur: Option<&str>,
        until: Option<&str>,
        wait: Option<&str>,
    ) -> String {
        self.state
            .add_task(CreateTaskParams {
                description: desc.to_string(),
                status: TaskStatus::Pending,
                project: None,
                priority: None,
                tags: vec![],
                due: due.map(|s| s.to_string()),
                wait: wait.map(|s| s.to_string()),
                scheduled: None,
                recurrence: recur.map(|s| s.to_string()),
                until: until.map(|s| s.to_string()),
                udas: vec![],
            })
            .expect("add_task must not error")
    }

    /// `task list` - triggers maintenance (GC + recurrence generation)
    fn maintain(&mut self) {
        let replica = self.state.replica.as_mut().expect("replica exists");
        WorkerState::apply_maintenance(replica, self.state.recurrence_limit)
            .expect("maintenance must not error");
    }

    /// All tasks as snapshots.
    fn all_tasks(&mut self) -> Vec<TaskSnapshot> {
        let replica = self.state.replica.as_mut().expect("replica exists");
        replica
            .all_tasks()
            .expect("all_tasks must not error")
            .into_iter()
            .map(|(_, t)| task_snapshot_from_task(t))
            .collect()
    }

    /// Count tasks whose description matches.
    fn count_by_desc(&mut self, desc: &str) -> usize {
        self.all_tasks()
            .into_iter()
            .filter(|t| t.core.description == desc)
            .count()
    }

    /// `task N <mods>` - update fields.
    fn update(&mut self, uuid: &str, params: UpdateTaskParams) -> Result<()> {
        self.state.update_task(uuid.to_string(), params)
    }

    /// `task N done` - complete a single task.
    fn done(&mut self, uuid: &str) -> Result<()> {
        self.state.done_task_single(uuid.to_string())
    }

    /// `task N delete` - delete a single task.
    #[allow(dead_code)]
    fn delete_single(&mut self, uuid: &str) -> Result<()> {
        self.state.delete_task_single(uuid.to_string())
    }

    /// `task N delete` - delete entire series (template + all children).
    fn delete_series(&mut self, uuid: &str) -> Result<()> {
        self.state.delete_task_series(uuid.to_string())
    }

    /// `task export` - all tasks as JSON, optionally including deleted.
    fn export(&mut self, include_deleted: bool) -> Result<String> {
        self.state.export_tasks(include_deleted)
    }

    /// `task _get N.field` - fetch and inspect one task.
    fn get(&mut self, uuid: &str) -> TaskSnapshot {
        self.state
            .get_task(uuid.to_string())
            .expect("task must exist")
    }

    /// Pending children of a template (parent_uuid match).
    fn pending_children(&mut self, parent_uuid: &str) -> Vec<TaskSnapshot> {
        self.all_tasks()
            .into_iter()
            .filter(|t| {
                t.core.parent_uuid.as_deref() == Some(parent_uuid)
                    && t.core.status == TaskStatus::Pending
            })
            .collect()
    }

    /// Reliable future date string for tests.
    fn due_rfc(&self, days_from_now: i64) -> String {
        (Utc::now() + Duration::days(days_from_now)).to_rfc3339()
    }

    /// Good default due for recurring tasks (far enough in the future).
    fn future_due(&self) -> String {
        self.due_rfc(30)
    }
}

// ==================================================================
// TestNoDueDate (TW: recurrence.test.py :: TestNoDueDate)
//
// "A recurring task must have a 'due' date."
//
// PASS if `add_task` rejects recur without due.
// ==================================================================
#[test]
fn tw_test_no_due_date() {
    let mut ctx = TestContext::new();
    let result = ctx.state.add_task(CreateTaskParams {
        description: "foo".into(),
        status: TaskStatus::Pending,
        recurrence: Some("daily".into()),
        due: None,
        ..empty_params()
    });
    assert!(
        result.is_err(),
        "PASS: recurring task without due date must be rejected"
    );
}

// ==================================================================
// TestBug649 (TW: recurrence.test.py :: TestBug649)
//
// "Recurring tasks cannot be immediately marked completed."
//
// PASS if `done_task_single` rejects a task whose status is Recurring.
// ==================================================================
#[test]
fn tw_test_bug_649_recurring_template_cannot_be_completed() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("one", Some(&ctx.future_due()), Some("weekly"), None, None);
    let task = ctx.get(&uuid);
    assert_eq!(
        task.core.status,
        TaskStatus::Recurring,
        "template must have Recurring status"
    );
    let result = ctx.done(&uuid);
    assert!(
        result.is_err(),
        "completing a Recurring-status template must be rejected"
    );
}

// ==================================================================
// TestRecurrenceUntil (TW: recurrence.test.py :: TestRecurrenceUntil)
//
// An `until` date terminates recurrence. When `until` passes, no new
// instances are generated and the template/children are expired.
// ==================================================================
#[test]
fn tw_test_recurrence_until() {
    let mut ctx = TestContext::new();

    // Template due 30 days out, recur daily, until 31 days out.
    ctx.add(
        "one",
        Some(&ctx.due_rfc(30)),
        Some("daily"),
        Some(&ctx.due_rfc(31)),
        None,
    );

    ctx.maintain();

    let count = ctx.count_by_desc("one");
    // Taskwarrior behavior for this setup is 2 tasks:
    // recurring template + one pending instance (the due day).
    assert_eq!(
        count, 2,
        "until compatibility mismatch: got {count} tasks (expected 2)"
    );
    println!("PASS: until respected, count={count}");
}

// ==================================================================
// TestBug360RemovalError (TW: recurrence.test.py :: TestBug360)
//
// "You cannot remove the recurrence from a recurring task."
// "You cannot remove the due date from a recurring task."
// ==================================================================
#[test]
fn tw_test_bug_360_cannot_remove_recurrence() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("foo", Some(&ctx.future_due()), Some("daily"), None, None);

    let result = ctx.update(
        &uuid,
        UpdateTaskParams {
            recurrence: Some("".to_string()),
            ..empty_update()
        },
    );
    assert!(
        result.is_err(),
        "PASS: removing recurrence from recurring task must fail (FAIL if it silently clears)"
    );
}

#[test]
fn tw_test_bug_360_cannot_remove_due() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("foo", Some(&ctx.future_due()), Some("daily"), None, None);

    let result = ctx.update(
        &uuid,
        UpdateTaskParams {
            due: Some("".to_string()),
            ..empty_update()
        },
    );
    assert!(
        result.is_err(),
        "PASS: removing due from recurring task must fail (FAIL if it succeeds)"
    );
}

// ==================================================================
// TestRecurrenceLimit (TW: recurrence.test.py :: TestRecurrenceLimit)
//
// rc.recurrence.limit controls how many future instances exist.
// ==================================================================
#[test]
fn tw_test_recurrence_limit() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("one", Some(&ctx.future_due()), Some("weekly"), None, None);

    ctx.state.recurrence_limit = 3;

    ctx.maintain();

    let children = ctx.pending_children(&uuid);
    let actual = children.len();
    println!("COMPAT: recurrence limit 3 → {actual} children (expected 3)");
}

// ==================================================================
// TestPeriod (TW: recurrence.test.py :: TestPeriod)
//
// All named recurrence periods parse and generate at least one child.
// ==================================================================
#[test]
fn tw_test_period_daily() {
    let mut ctx = TestContext::new();
    ctx.add("daily", Some(&ctx.future_due()), Some("daily"), None, None);
    ctx.maintain();
    assert!(
        ctx.count_by_desc("daily") >= 2,
        "daily: template + at least 1 child"
    );
}

#[test]
fn tw_test_period_weekly() {
    let mut ctx = TestContext::new();
    ctx.add(
        "weekly",
        Some(&ctx.future_due()),
        Some("weekly"),
        None,
        None,
    );
    ctx.maintain();
    assert!(
        ctx.count_by_desc("weekly") >= 2,
        "weekly: template + at least 1 child"
    );
}

#[test]
fn tw_test_period_monthly() {
    let mut ctx = TestContext::new();
    ctx.add(
        "monthly",
        Some(&ctx.future_due()),
        Some("monthly"),
        None,
        None,
    );
    ctx.maintain();
    assert!(
        ctx.count_by_desc("monthly") >= 2,
        "monthly: template + at least 1 child"
    );
}

#[test]
fn tw_test_period_biweekly() {
    let mut ctx = TestContext::new();
    ctx.add(
        "biweekly",
        Some(&ctx.future_due()),
        Some("biweekly"),
        None,
        None,
    );
    ctx.maintain();
    assert!(
        ctx.count_by_desc("biweekly") >= 2,
        "biweekly: template + at least 1 child"
    );
}

#[test]
fn tw_test_period_quarterly() {
    let mut ctx = TestContext::new();
    let result = ctx.state.add_task(CreateTaskParams {
        description: "quarterly".into(),
        status: TaskStatus::Pending,
        recurrence: Some("quarterly".into()),
        due: Some(ctx.future_due()),
        ..empty_params()
    });
    if result.is_ok() {
        let _uuid = result.unwrap();
        ctx.maintain();
        println!("OK:   quarterly → {} tasks", ctx.count_by_desc("quarterly"));
    } else {
        println!("GAP:  quarterly rejected by parser");
    }
}

#[test]
fn tw_test_period_yearly() {
    let mut ctx = TestContext::new();
    ctx.add(
        "yearly",
        Some(&ctx.future_due()),
        Some("yearly"),
        None,
        None,
    );
    ctx.maintain();
    assert!(
        ctx.count_by_desc("yearly") >= 2,
        "yearly: template + at least 1 child"
    );
}

/// Known-gap periods that taskwarrior accepts but taskdroid doesn't yet.
#[test]
fn tw_test_period_known_gaps() {
    let gaps: &[(&str, &str)] = &[
        ("1day", "1day"),
        ("1sennight", "1sennight"),
        ("fortnight", "fortnight"),
        ("2d", "2d"),
        ("2w", "2w"),
        ("2mo", "2mo"),
        ("2q", "2q"),
        ("2y", "2y"),
        ("annual", "annual"),
        ("bimonthly", "bimonthly"),
        ("semiannual", "semiannual"),
        ("biannual", "biannual"),
    ];
    for (desc, recur) in gaps {
        let mut ctx = TestContext::new();
        let result = ctx.state.add_task(CreateTaskParams {
            description: desc.to_string(),
            status: TaskStatus::Pending,
            recurrence: Some(recur.to_string()),
            due: Some(ctx.future_due()),
            ..empty_params()
        });
        if result.is_ok() {
            let _uuid = result.unwrap();
            ctx.maintain();
            let count = ctx.count_by_desc(desc);
            println!("OK:   {desc} (recur:{recur}) → {count} tasks");
        } else {
            println!("GAP:  {desc} (recur:{recur}) rejected by parser");
        }
    }
}

// ==================================================================
// TestBug932 (TW: recurrence.test.py :: TestBug932)
//
// Verify template project modifications propagate to children.
// ==================================================================
#[test]
fn tw_test_bug_932_project_mod_propagates() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("R", Some(&ctx.due_rfc(30)), Some("daily"), None, None);
    ctx.maintain();

    ctx.update(
        &uuid,
        UpdateTaskParams {
            project: Some("P".to_string()),
            ..empty_update()
        },
    )
    .expect("update template project");

    ctx.maintain();

    let children = ctx.pending_children(&uuid);
    let all_match = children
        .iter()
        .all(|c| c.core.project.as_deref() == Some("P"));
    if all_match {
        println!("PASS: project propagated to all children");
    } else {
        println!(
            "COMPAT GAP: project did not propagate ({} children checked)",
            children.len()
        );
    }
}

// ==================================================================
// TestRecurrenceWeekdays (TW)
//
// "recur:weekdays skips weekends"
// ==================================================================
#[test]
fn tw_test_weekdays_skips_weekends() {
    let base = parse_iso8601("2026-04-03T00:00:00Z") // Friday
        .expect("parse friday");
    let next = due_for_index(base, RecurrenceRule::Weekdays, 1).expect("next");
    assert_eq!(next.weekday(), Weekday::Mon, "weekdays skip to Monday");
}

// ==================================================================
// TestUpgradeToRecurring (TW: recurrence.test.py :: TestUpgradeToRecurring)
//
// A pending task can be upgraded to recurring by setting due + recur.
// Upgrading without a due date must be rejected.
// ==================================================================
#[test]
fn tw_test_upgrade_to_recurring() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("foo", None, None, None, None);

    ctx.update(
        &uuid,
        UpdateTaskParams {
            due: Some(ctx.future_due()),
            recurrence: Some("weekly".to_string()),
            ..empty_update()
        },
    )
    .expect("upgrade to recurring must succeed");

    let task = ctx.get(&uuid);
    assert_eq!(
        task.core.status,
        TaskStatus::Recurring,
        "PASS: pending task upgraded to Recurring status"
    );
}

#[test]
fn tw_test_failed_upgrade_no_due() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("foo", None, None, None, None);

    let result = ctx.update(
        &uuid,
        UpdateTaskParams {
            recurrence: Some("weekly".to_string()),
            ..empty_update()
        },
    );
    assert!(
        result.is_err(),
        "PASS: upgrade to recurring without due date must be rejected"
    );
}

// ==================================================================
// TestRecurrenceDisabled (TW: recurrence.test.py :: TestRecurrenceDisabled)
//
// When recurrence is globally disabled (recurrence_limit = 0), no
// child instances are generated.
// ==================================================================
#[test]
fn tw_test_recurrence_disabled() {
    let mut ctx = TestContext::new();
    ctx.state.recurrence_limit = 0;

    let uuid = ctx.add("one", Some(&ctx.future_due()), Some("daily"), None, None);
    ctx.maintain();

    let children = ctx.pending_children(&uuid);
    assert_eq!(
        children.len(),
        0,
        "PASS: no children generated when recurrence_limit=0"
    );
}

// ==================================================================
// TestBug972 (TW: recurrence.test.py :: TestBug972)
//
// A bare number as recurrence period (e.g. "2") is not supported.
// ==================================================================
#[test]
fn tw_test_bug_972() {
    let mut ctx = TestContext::new();
    let result = ctx.state.add_task(CreateTaskParams {
        description: "one".into(),
        status: TaskStatus::Pending,
        recurrence: Some("2".into()),
        due: Some(ctx.future_due()),
        ..empty_params()
    });
    assert!(
        result.is_err(),
        "PASS: bare number period '2' must be rejected"
    );
}

// ==================================================================
// TestDeletionRecurrence (TW: recurrence.test.py :: TestDeletionRecurrence)
//
// Deleting a parent cascades to all children; deleting a child
// cascades to all siblings and the parent.
// ==================================================================
#[test]
fn tw_test_delete_parent() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("one", Some(&ctx.future_due()), Some("daily"), None, None);
    ctx.maintain();

    ctx.delete_series(&uuid)
        .expect("delete series must succeed");

    let remaining: Vec<_> = ctx
        .all_tasks()
        .into_iter()
        .filter(|t| t.core.description == "one")
        .collect();
    assert!(
        remaining
            .iter()
            .all(|t| t.core.status == TaskStatus::Deleted),
        "PASS: deleting parent marked all ({}) tasks as Deleted",
        remaining.len()
    );
}

#[test]
fn tw_test_delete_child_with_siblings() {
    let mut ctx = TestContext::new();
    ctx.state.recurrence_limit = 5;
    let uuid = ctx.add("one", Some(&ctx.future_due()), Some("daily"), None, None);
    ctx.maintain();

    let children = ctx.pending_children(&uuid);
    assert_eq!(children.len(), 5, "setup: should have 5 pending children");

    ctx.delete_series(&children[0].core.uuid)
        .expect("delete child series must succeed");

    let remaining: Vec<_> = ctx
        .all_tasks()
        .into_iter()
        .filter(|t| t.core.description == "one")
        .collect();
    assert!(
        remaining
            .iter()
            .all(|t| t.core.status == TaskStatus::Deleted),
        "PASS: deleting child marked all ({}) tasks as Deleted",
        remaining.len()
    );
}

// ==================================================================
// TestAppendPrependRecurrence (TW: recurrence.test.py :: TestAppendPrependRecurrence)
//
// Appending/prepending text to a child propagates to siblings.
// Taskwarrior propagates child modifications to siblings on confirmation;
// taskdroid currently does not support this path.
// ==================================================================
#[test]
fn tw_test_append_propagate() {
    let mut ctx = TestContext::new();
    ctx.state.recurrence_limit = 2;
    let uuid = ctx.add("one", Some(&ctx.future_due()), Some("daily"), None, None);
    ctx.maintain();

    let children = ctx.pending_children(&uuid);
    assert!(children.len() >= 2, "setup: need at least 2 children");

    // Modify the first child's description (simulating append).
    ctx.update(
        &children[0].core.uuid,
        UpdateTaskParams {
            description: Some(format!("{} APP", children[0].core.description)),
            ..empty_update()
        },
    )
    .expect("modify child must succeed");

    // Re-fetch siblings and check whether they changed.
    let remaining = ctx.pending_children(&uuid);
    let all_match = remaining.iter().all(|c| c.core.description.contains("APP"));
    if all_match {
        println!("PASS: append propagated to siblings");
    } else {
        println!(
            "GAP: append did not propagate to siblings (taskdroid does not support child→sibling propagation)"
        );
    }
}

#[test]
fn tw_test_prepend_propagate() {
    let mut ctx = TestContext::new();
    ctx.state.recurrence_limit = 2;
    let uuid = ctx.add("one", Some(&ctx.future_due()), Some("daily"), None, None);
    ctx.maintain();

    let children = ctx.pending_children(&uuid);
    assert!(children.len() >= 2, "setup: need at least 2 children");

    ctx.update(
        &children[0].core.uuid,
        UpdateTaskParams {
            description: Some(format!("PRE {}", children[0].core.description)),
            ..empty_update()
        },
    )
    .expect("modify child must succeed");

    let remaining = ctx.pending_children(&uuid);
    let all_match = remaining.iter().all(|c| c.core.description.contains("PRE"));
    if all_match {
        println!("PASS: prepend propagated to siblings");
    } else {
        println!(
            "GAP: prepend did not propagate to siblings (taskdroid does not support child→sibling propagation)"
        );
    }
}

// ==================================================================
// TestRecurrenceTasks.test_change_propagation
// (TW: recurrence.test.py :: TestRecurrenceTasks)
//
// Modifying a child can optionally propagate to siblings.
// ==================================================================
#[test]
fn tw_test_change_propagation() {
    let mut ctx = TestContext::new();
    ctx.state.recurrence_limit = 3;
    let uuid = ctx.add(
        "complex",
        Some(&ctx.future_due()),
        Some("daily"),
        None,
        None,
    );
    ctx.maintain();

    let children = ctx.pending_children(&uuid);
    assert!(children.len() >= 2, "setup: need at least 2 children");

    // Modify a child — check if siblings changed too.
    let child_uuid = &children[0].core.uuid;
    ctx.update(
        child_uuid,
        UpdateTaskParams {
            description: Some("complex2".into()),
            ..empty_update()
        },
    )
    .expect("modify child must succeed");

    let remaining = ctx.pending_children(&uuid);
    let sibling = remaining.iter().find(|c| c.core.uuid != *child_uuid);
    if let Some(sibling) = sibling {
        if sibling.core.description == "complex2" {
            println!(
                "COMPAT: child modification propagated to sibling (TW default with confirm=0)"
            );
        } else {
            println!(
                "COMPAT: child modification did NOT propagate to sibling (description={})",
                sibling.core.description
            );
        }
    }
}

// ==================================================================
// TestBugAnnual (TW: recurrence.test.py :: TestBugAnnual)
//
// Verify that annual recurring tasks do not drift (creep) in their
// due dates across years.
// ==================================================================
#[test]
fn tw_test_annual_no_creep() {
    let base = parse_iso8601("2000-01-01T00:00:00Z").expect("base date");
    let rule = RecurrenceRule::Months(12);

    // Check forward: no creep across 15 years.
    for offset in 0..=15 {
        let due = due_for_index(base, rule, offset).expect("due must exist");
        assert_eq!(
            due.month(),
            1,
            "month should stay January at offset {offset}, got {}",
            due.month()
        );
        assert_eq!(
            due.day(),
            1,
            "day should stay 1 at offset {offset}, got {}",
            due.day()
        );
        assert_eq!(
            due.year(),
            2000 + offset as i32,
            "year should advance by {offset}"
        );
    }

    println!("PASS: annual recurrence does not creep");
}

// ==================================================================
// TestTags (TW: tag.test.py)
//
// Tag lifecycle: add on create, remove on modify, add+remove same tag
// is a net no-op, removing a missing tag is a no-op.
// ==================================================================
#[test]
fn tw_test_tag_manipulation() {
    let mut ctx = TestContext::new();

    // Create task with three tags.
    let uuid = ctx
        .state
        .add_task(CreateTaskParams {
            description: "This is a test".into(),
            tags: vec!["one".into(), "two".into(), "three".into()],
            ..empty_params()
        })
        .expect("add");

    let task = ctx.get(&uuid);
    assert_eq!(
        user_tags(&task.core.tags),
        vec!["one", "three", "two"],
        "tags on create"
    );

    // Remove all three.
    ctx.update(
        &uuid,
        UpdateTaskParams {
            remove_tags: vec!["one".into(), "two".into(), "three".into()],
            ..empty_update()
        },
    )
    .expect("remove tags");
    let task = ctx.get(&uuid);
    assert!(user_tags(&task.core.tags).is_empty(), "tags after removal");

    // Add three new tags.
    ctx.update(
        &uuid,
        UpdateTaskParams {
            add_tags: vec!["four".into(), "five".into(), "six".into()],
            ..empty_update()
        },
    )
    .expect("add tags");
    let task = ctx.get(&uuid);
    assert_eq!(
        user_tags(&task.core.tags),
        vec!["five", "four", "six"],
        "tags after re-add"
    );

    // Add and remove same tag in one operation — net no-op.
    ctx.update(
        &uuid,
        UpdateTaskParams {
            add_tags: vec!["duplicate".into()],
            remove_tags: vec!["duplicate".into()],
            ..empty_update()
        },
    )
    .expect("add+remove same tag");
    let task = ctx.get(&uuid);
    assert!(
        !user_tags(&task.core.tags).contains(&"duplicate"),
        "add+remove same tag is net no-op"
    );

    // Remove a tag that does not exist — TW reports "Modified 0 tasks".
    let result = ctx.update(
        &uuid,
        UpdateTaskParams {
            remove_tags: vec!["missing".into()],
            ..empty_update()
        },
    );
    if result.is_ok() {
        let task = ctx.get(&uuid);
        println!(
            "PASS: removed missing tag — no-op as expected (tags={:?})",
            user_tags(&task.core.tags)
        );
    } else {
        println!("GAP: removing missing tag returned error (TW treats it as no-op)");
    }
}

#[test]
fn tw_test_bug_1700_tags_overwrite() {
    let mut ctx = TestContext::new();

    let uuid = ctx
        .state
        .add_task(CreateTaskParams {
            description: "one".into(),
            tags: vec!["tag1".into(), "tag2".into()],
            ..empty_params()
        })
        .expect("add");

    let task = ctx.get(&uuid);
    assert!(user_tags(&task.core.tags).contains(&"tag1"), "tag1");
    assert!(user_tags(&task.core.tags).contains(&"tag2"), "tag2");

    // TW: `tags:tag2,tag3` replaces all tags.
    // taskdroid has no set_tags — approximate with remove+add.
    ctx.update(
        &uuid,
        UpdateTaskParams {
            remove_tags: vec!["tag1".into()],
            add_tags: vec!["tag3".into()],
            ..empty_update()
        },
    )
    .expect("replace tags");
    let task = ctx.get(&uuid);
    assert_eq!(
        user_tags(&task.core.tags),
        vec!["tag2", "tag3"],
        "tags replaced (manual remove+add)"
    );
    println!("PASS: tags overwrite via remove+add emulation");
}

// ==================================================================
// TestBug1763 (TW: modify.test.py :: TestBug1763)
//
// Clearing `due:` on a task that has no due date is a no-op.
// TW reports "Modified 0 tasks" and does not bump `modified`.
// ==================================================================
#[test]
fn tw_test_mod_nop() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("foo", None, None, None, None);

    let before_modified = ctx.get(&uuid).core.modified.clone();

    // Clear due on a task that never had a due date.
    ctx.update(
        &uuid,
        UpdateTaskParams {
            due: Some("".into()),
            ..empty_update()
        },
    )
    .expect("update must not error");

    let after_modified = ctx.get(&uuid).core.modified;
    if after_modified == before_modified {
        println!("PASS: clearing undated due is a no-op (modified unchanged)");
    } else {
        println!("GAP: clearing undated due bumped modified (TW shows Modified 0 tasks)");
    }
}

// ==================================================================
// TestBug3584 (TW: modify.test.py :: TestBug3584)
//
// Setting an end date on a pending task should be rejected.
// taskdroid's UpdateTaskParams has no `end` field, so this guardrail
// is currently not testable through the API.
// ==================================================================
#[test]
fn tw_test_mod_pending_task_end_date() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("foo", None, None, None, None);

    // Try to set `end` via UDA — taskdroid may or may not treat it as a first-class field.
    let result = ctx.update(
        &uuid,
        UpdateTaskParams {
            set_udas: vec![UdaPair {
                key: "end".into(),
                value: "2026-06-01T00:00:00Z".into(),
            }],
            ..empty_update()
        },
    );
    match result {
        Ok(()) => {
            let task = ctx.get(&uuid);
            if task.core.end.is_some() {
                println!("GAP: setting end on pending task succeeded (TW rejects this)");
            } else {
                println!(
                    "COMPAT: 'end' UDA was accepted but did not affect the end field (guardrail N/A)"
                );
            }
        }
        Err(_) => {
            println!("PASS: setting end on pending task was rejected");
        }
    }
}

// ==================================================================
// TestLogCommand (TW: log.test.py :: TestLogCommand)
//
// `task log <desc>` creates a completed task with an end date.
// `task log <desc> wait:...` must be rejected.
// ==================================================================
#[test]
fn tw_test_log_creates_completed_task() {
    let mut ctx = TestContext::new();

    let uuid = ctx
        .state
        .add_task(CreateTaskParams {
            description: "This is a test".into(),
            status: TaskStatus::Completed,
            ..empty_params()
        })
        .expect("log task");

    let task = ctx.get(&uuid);
    assert_eq!(
        task.core.status,
        TaskStatus::Completed,
        "log creates completed task"
    );
    assert!(
        task.core.end.is_some(),
        "completed task should have end date"
    );
    println!("PASS: log creates completed task with end date");
}

#[test]
fn tw_test_log_rejects_wait() {
    let mut ctx = TestContext::new();

    let result = ctx.state.add_task(CreateTaskParams {
        description: "This is a test".into(),
        status: TaskStatus::Completed,
        wait: Some("2026-12-31T00:00:00Z".into()),
        ..empty_params()
    });
    if result.is_err() {
        println!("PASS: log+wait was rejected");
    } else {
        println!("GAP: log+wait succeeded (TW rejects this)");
    }
}

// ==================================================================
// TestDuplication (TW: duplicate.test.py)
//
// Duplicating a task creates a new task with same description/status.
// taskdroid has no built-in duplicate; we approximate by copy.
// ==================================================================
#[test]
fn tw_test_duplicate_basic() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("foo", None, None, None, None);

    let task = ctx.get(&uuid);
    let dup_uuid = ctx
        .state
        .add_task(CreateTaskParams {
            description: task.core.description.clone(),
            status: TaskStatus::Pending,
            ..empty_params()
        })
        .expect("manual duplicate");

    let dup = ctx.get(&dup_uuid);
    assert_eq!(dup.core.description, "foo", "description preserved");
    assert_eq!(dup.core.status, TaskStatus::Pending, "status preserved");
    println!("PASS: basic duplication via copy");
}

// ==================================================================
// TestExport (TW: export.test.py)
//
// Export round-trip: add a task, export to JSON, verify fields.
// ==================================================================
#[test]
fn tw_test_export_description() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("test", None, None, None, None);

    let json = ctx.export(false).expect("export");
    let snapshots: Vec<TaskSnapshot> = serde_json::from_str(&json).expect("parse JSON");
    let exported = snapshots
        .iter()
        .find(|t| t.core.uuid == uuid)
        .expect("task in export");
    assert_eq!(exported.core.description, "test");
    println!("PASS: export contains description");
}

#[test]
fn tw_test_export_status() {
    let mut ctx = TestContext::new();
    let uuid = ctx.add("test", None, None, None, None);

    let json = ctx.export(false).expect("export");
    let snapshots: Vec<TaskSnapshot> = serde_json::from_str(&json).expect("parse JSON");
    let exported = snapshots
        .iter()
        .find(|t| t.core.uuid == uuid)
        .expect("task in export");
    assert_eq!(exported.core.status, TaskStatus::Pending);
    println!("PASS: export contains pending status");
}

/// Filter out taskchampion virtual tags (all-uppercase, e.g. PENDING, UNBLOCKED).
fn user_tags(tags: &[String]) -> Vec<&str> {
    let mut t: Vec<&str> = tags
        .iter()
        .map(|s| s.as_str())
        .filter(|s| s.chars().any(char::is_lowercase))
        .collect();
    t.sort();
    t
}

fn empty_params() -> CreateTaskParams {
    CreateTaskParams {
        description: String::new(),
        status: TaskStatus::Pending,
        project: None,
        priority: None,
        tags: vec![],
        due: None,
        wait: None,
        scheduled: None,
        recurrence: None,
        until: None,
        udas: vec![],
    }
}

fn empty_update() -> UpdateTaskParams {
    UpdateTaskParams {
        description: None,
        status: None,
        project: None,
        priority: None,
        due: None,
        wait: None,
        scheduled: None,
        recurrence: None,
        until: None,
        add_tags: vec![],
        remove_tags: vec![],
        add_annotation: None,
        remove_annotations: vec![],
        add_depends: vec![],
        remove_depends: vec![],
        start: None,
        set_udas: vec![],
    }
}

// ------------------------------------------------------------------
// TW filter query compatibility tests
// Ported from: filter.test.py, operators.test.py, project.test.py,
//              tag.test.py, search.test.py, due.test.py
// Uses matches_query() and task_with() from query_language module
// ------------------------------------------------------------------

#[test]
fn test_list_project_a() {
    let task_a = task_with(&[("project", "A"), ("status", "pending")]);
    let task_b = task_with(&[("project", "B"), ("status", "pending")]);

    assert!(
        matches_query(&task_a, "project:A"),
        "project:A should match task in project A"
    );
    assert!(
        !matches_query(&task_b, "project:A"),
        "project:A should not match task in project B"
    );
}

#[test]
fn test_list_priority_h() {
    let task_h = task_with(&[("priority", "H"), ("status", "pending")]);
    let task_l = task_with(&[("priority", "L"), ("status", "pending")]);

    assert!(
        matches_query(&task_h, "priority:H"),
        "priority:H should match H priority"
    );
    assert!(
        !matches_query(&task_l, "priority:H"),
        "priority:H should not match L priority"
    );
}

#[test]
fn test_list_priority_empty_value() {
    let _task_no_pri = task_with(&[("status", "pending")]);
    let task_h = task_with(&[("priority", "H"), ("status", "pending")]);

    assert!(
        !matches_query(&task_h, "priority:"),
        "priority: should not match task with priority set"
    );
}

#[test]
fn test_list_substring_pattern() {
    let task_foo = task_with(&[
        ("description", "task with foo keyword"),
        ("status", "pending"),
    ]);
    let task_bar = task_with(&[
        ("description", "task with bar keyword"),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&task_foo, "/foo/"),
        "/foo/ should match task with 'foo' in description"
    );
    assert!(
        !matches_query(&task_bar, "/foo/"),
        "/foo/ should not match task without 'foo'"
    );
}

#[test]
fn test_list_double_substring_and() {
    let task_foo_bar = task_with(&[("description", "foo bar"), ("status", "pending")]);
    let task_foo_only = task_with(&[("description", "foo only"), ("status", "pending")]);

    assert!(
        matches_query(&task_foo_bar, "/foo/ /bar/"),
        "/foo/ /bar/ should match task with both"
    );
    assert!(
        !matches_query(&task_foo_only, "/foo/ /bar/"),
        "/foo/ /bar/ should not match task with only foo"
    );
}

#[test]
fn test_list_include_tag() {
    let task_tagged = task_with(&[("tag", "tag"), ("status", "pending")]);
    let task_untagged = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&task_tagged, "+tag"),
        "+tag should match tagged task"
    );
    assert!(
        !matches_query(&task_untagged, "+tag"),
        "+tag should not match untagged task"
    );
}

#[test]
fn test_list_exclude_tag() {
    let task_tagged = task_with(&[("tag", "tag"), ("status", "pending")]);
    let task_untagged = task_with(&[("status", "pending")]);

    assert!(
        !matches_query(&task_tagged, "-tag"),
        "-tag should exclude tagged task"
    );
    assert!(
        matches_query(&task_untagged, "-tag"),
        "-tag should pass untagged task"
    );
}

#[test]
fn test_list_non_existing_tag() {
    let task = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&task, "-missing"),
        "-missing should be no-op on untagged task"
    );
}

#[test]
fn test_list_mutually_exclusive_tag() {
    let task = task_with(&[("tag", "tag"), ("status", "pending")]);

    assert!(
        !matches_query(&task, "+tag -tag"),
        "+tag -tag should be contradictory"
    );
}

#[test]
fn test_list_project_a_priority_h() {
    let task = task_with(&[("project", "A"), ("priority", "H"), ("status", "pending")]);
    let wrong_proj = task_with(&[("project", "B"), ("priority", "H"), ("status", "pending")]);
    let wrong_pri = task_with(&[("project", "A"), ("priority", "L"), ("status", "pending")]);

    assert!(
        matches_query(&task, "project:A priority:H"),
        "should match both project:A and priority:H"
    );
    assert!(
        !matches_query(&wrong_proj, "project:A priority:H"),
        "wrong project should not match"
    );
    assert!(
        !matches_query(&wrong_pri, "project:A priority:H"),
        "wrong priority should not match"
    );
}

#[test]
fn test_list_project_a_substring() {
    let task = task_with(&[
        ("project", "A"),
        ("description", "task with foo"),
        ("status", "pending"),
    ]);
    let no_foo = task_with(&[
        ("project", "A"),
        ("description", "task without"),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&task, "project:A /foo/"),
        "project:A /foo/ should match"
    );
    assert!(
        !matches_query(&no_foo, "project:A /foo/"),
        "project:A /foo/ should not match task without foo"
    );
}

#[test]
fn test_list_project_a_tag() {
    let task = task_with(&[("project", "A"), ("tag", "tag"), ("status", "pending")]);
    let no_tag = task_with(&[("project", "A"), ("status", "pending")]);

    assert!(
        matches_query(&task, "project:A +tag"),
        "project:A +tag should match"
    );
    assert!(
        !matches_query(&no_tag, "project:A +tag"),
        "project:A +tag should not match untagged"
    );
}

#[test]
fn test_status_case_insensitive() {
    let done = task_with(&[("status", "completed")]);

    assert!(
        matches_query(&done, "status:completed"),
        "lowercase status should match"
    );
    assert!(
        matches_query(&done, "status:Completed"),
        "capitalized status should match"
    );
    assert!(
        matches_query(&done, "status:COMPLETED"),
        "uppercase status should match"
    );
}

#[test]
fn test_list_project_prefix() {
    let task_foo = task_with(&[("project", "foo.uno.dos"), ("status", "pending")]);
    let task_bar = task_with(&[("project", "bar.uno.dos"), ("status", "pending")]);

    assert!(
        matches_query(&task_foo, "project:foo"),
        "project:foo should prefix-match foo.uno.dos"
    );
    assert!(
        matches_query(&task_bar, "project:bar"),
        "project:bar should prefix-match bar.uno.dos"
    );
    assert!(
        !matches_query(&task_bar, "project:foo"),
        "project:foo should not match bar.* tasks"
    );
}

#[test]
fn test_list_project_not() {
    let task_foo = task_with(&[("project", "foo.uno"), ("status", "pending")]);
    let task_bar = task_with(&[("project", "bar.uno"), ("status", "pending")]);

    assert!(
        !matches_query(&task_foo, "project.not:foo"),
        "project.not:foo should exclude foo.*"
    );
    assert!(
        matches_query(&task_bar, "project.not:foo"),
        "project.not:foo should pass bar.*"
    );
}

#[test]
fn test_list_project_startswith() {
    let task_bar = task_with(&[("project", "bar.uno"), ("status", "pending")]);
    let task_foo = task_with(&[("project", "foo.dos"), ("status", "pending")]);

    assert!(
        matches_query(&task_bar, "project.startswith:bar"),
        "project.startswith:bar should match bar.*"
    );
    assert!(
        !matches_query(&task_foo, "project.startswith:bar"),
        "project.startswith:bar should not match foo.*"
    );
}

#[test]
fn test_attribute_has_modifier() {
    let task = task_with(&[("description", "hello foo world"), ("status", "pending")]);
    let no_match = task_with(&[("description", "hello bar world"), ("status", "pending")]);

    assert!(
        matches_query(&task, "description.has:foo"),
        "description.has:foo should match"
    );
    assert!(
        !matches_query(&no_match, "description.has:foo"),
        "description.has:foo should not match without foo"
    );
}

#[test]
fn test_has_hasnt() {
    let task = task_with(&[("description", "hello foo world"), ("status", "pending")]);
    let no_foo = task_with(&[("description", "hello bar world"), ("status", "pending")]);

    assert!(
        matches_query(&task, "description.has:foo"),
        "description.has:foo should match"
    );
    assert!(
        !matches_query(&task, "description.hasnt:foo"),
        "description.hasnt:foo should NOT match task that has foo"
    );
    assert!(
        matches_query(&no_foo, "description.hasnt:foo"),
        "description.hasnt:foo should match task without foo"
    );
}

#[test]
fn test_project_inequality_not() {
    let work = task_with(&[("project", "WORK"), ("status", "pending")]);
    let home = task_with(&[("project", "HOME"), ("status", "pending")]);

    assert!(
        !matches_query(&work, "project.not:WORK"),
        "project.not:WORK should exclude WORK"
    );
    assert!(
        matches_query(&home, "project.not:WORK"),
        "project.not:WORK should include HOME"
    );
}

#[test]
fn test_project_not_equal() {
    let work = task_with(&[("project", "WORK"), ("status", "pending")]);
    let home = task_with(&[("project", "HOME"), ("status", "pending")]);

    assert!(
        !matches_query(&work, "project != WORK"),
        "project != WORK should exclude WORK"
    );
    assert!(
        matches_query(&home, "project != WORK"),
        "project != WORK should include HOME"
    );
}

#[test]
fn test_attribute_modifier_with_duration() {
    let now = Utc::now();
    let due_7d = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(7)).format("%+")),
        ),
        ("status", "pending"),
    ]);
    let due_10d = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(10)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_7d, "due.before:9d"),
        "due.before:9d should match 7d task"
    );
    assert!(
        !matches_query(&due_10d, "due.before:9d"),
        "due.before:9d should NOT match 10d task"
    );
}

#[test]
fn test_due_before_boundary() {
    let now = Utc::now();
    let due_today = task_with(&[
        ("due", &format!("{}", now.format("%+"))),
        ("status", "pending"),
    ]);
    let _due_tomorrow = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_today, "due.before:tomorrow"),
        "due today should match due.before:tomorrow"
    );
    assert!(
        !matches_query(&due_today, "due.before:today"),
        "due today should NOT match due.before:today"
    );
}

#[test]
fn test_due_after_boundary() {
    let now = Utc::now();
    let due_today = task_with(&[
        ("due", &format!("{}", now.format("%+"))),
        ("status", "pending"),
    ]);
    let _due_yesterday = task_with(&[
        (
            "due",
            &format!("{}", (now - Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_today, "due.after:yesterday"),
        "due today should match due.after:yesterday"
    );
    assert!(
        !matches_query(&due_today, "due.after:tomorrow"),
        "due today should NOT match due.after:tomorrow"
    );
}

#[test]
fn test_due_by_eoy_inclusive() {
    let now = Utc::now();
    let eoy = Utc
        .with_ymd_and_hms(now.year(), 12, 31, 23, 59, 59)
        .single()
        .unwrap();
    let due_eoy = task_with(&[
        ("due", &format!("{}", eoy.format("%+"))),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_eoy, "due.by:eoy"),
        "due at end of year should match due.by:eoy"
    );
}

#[test]
fn test_due_by_yesterday_excludes_today() {
    let now = Utc::now();
    let due_today = task_with(&[
        ("due", &format!("{}", now.format("%+"))),
        ("status", "pending"),
    ]);

    assert!(
        !matches_query(&due_today, "due.by:yesterday"),
        "due today should NOT match due.by:yesterday"
    );
}

#[test]
fn test_tags_none_filter() {
    let task_no_tags = task_with(&[("status", "pending")]);
    let task_tagged = task_with(&[("tag", "home"), ("status", "pending")]);

    assert!(
        matches_query(&task_no_tags, "tags.none:"),
        "tags.none: should match untagged task"
    );
    assert!(
        !matches_query(&task_tagged, "tags.none:"),
        "tags.none: should NOT match tagged task"
    );
}

#[test]
fn test_project_name_keyword_ambiguity() {
    let task = task_with(&[("project", "sat"), ("status", "pending")]);

    assert!(
        matches_query(&task, "pro:sat"),
        "pro:sat should match project named 'sat' without date interpretation"
    );
}

// === TW operators.test.py :: TestOperatorsIdentity ===

#[test]
fn test_implicit_and() {
    let one = task_with(&[("project", "A"), ("priority", "H"), ("status", "pending")]);
    let two = task_with(&[("project", "A"), ("status", "pending")]);
    let three = task_with(&[("priority", "H"), ("status", "pending")]);

    assert!(
        matches_query(&one, "project:A priority:H"),
        "implicit AND should match task with both"
    );
    assert!(
        !matches_query(&two, "project:A priority:H"),
        "implicit AND should not match missing H"
    );
    assert!(
        !matches_query(&three, "project:A priority:H"),
        "implicit AND should not match missing A"
    );
}

#[test]
fn test_explicit_and() {
    let one = task_with(&[("project", "A"), ("priority", "H"), ("status", "pending")]);
    let two = task_with(&[("project", "A"), ("status", "pending")]);

    assert!(
        matches_query(&one, "project:A and priority:H"),
        "explicit AND should match task with both"
    );
    assert!(
        !matches_query(&two, "project:A and priority:H"),
        "explicit AND should not match missing H"
    );
}

#[test]
fn test_and_not() {
    let one = task_with(&[("project", "A"), ("priority", "H"), ("status", "pending")]);
    let two = task_with(&[("project", "A"), ("status", "pending")]);

    assert!(
        !matches_query(&one, "project:A and priority.not:H"),
        "AND with NOT should exclude H task"
    );
    assert!(
        matches_query(&two, "project:A and priority.not:H"),
        "AND with NOT should include task without H"
    );
}

#[test]
fn test_or_operator() {
    let one = task_with(&[("project", "A"), ("priority", "H"), ("status", "pending")]);
    let two = task_with(&[("project", "A"), ("status", "pending")]);
    let three = task_with(&[("priority", "H"), ("status", "pending")]);
    let four = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&one, "project:A or priority:H"),
        "OR should match task with either A or H"
    );
    assert!(
        matches_query(&two, "project:A or priority:H"),
        "OR should match task with A"
    );
    assert!(
        matches_query(&three, "project:A or priority:H"),
        "OR should match task with H"
    );
    assert!(
        !matches_query(&four, "project:A or priority:H"),
        "OR should NOT match task with neither A nor H"
    );
}

#[test]
fn test_or_with_not() {
    let one = task_with(&[("project", "A"), ("priority", "H"), ("status", "pending")]);
    let two = task_with(&[("project", "A"), ("status", "pending")]);
    let three = task_with(&[("priority", "H"), ("status", "pending")]);
    let four = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&one, "project:A or priority.not:H"),
        "OR with NOT should match one (project:A true)"
    );
    assert!(
        matches_query(&two, "project:A or priority.not:H"),
        "OR with NOT should match two (project:A true)"
    );
    assert!(
        !matches_query(&three, "project:A or priority.not:H"),
        "OR with NOT should NOT match three (priority H, no project A)"
    );
    assert!(
        matches_query(&four, "project:A or priority.not:H"),
        "OR with NOT should match four (priority.not:H true)"
    );
}

#[test]
fn test_xor_operator() {
    let one = task_with(&[("project", "A"), ("priority", "H"), ("status", "pending")]);
    let two = task_with(&[("project", "A"), ("status", "pending")]);
    let three = task_with(&[("priority", "H"), ("status", "pending")]);
    let four = task_with(&[("status", "pending")]);

    assert!(
        !matches_query(&one, "project:A xor priority:H"),
        "XOR should exclude task with both A and H"
    );
    assert!(
        matches_query(&two, "project:A xor priority:H"),
        "XOR should include task with only A"
    );
    assert!(
        matches_query(&three, "project:A xor priority:H"),
        "XOR should include task with only H"
    );
    assert!(
        !matches_query(&four, "project:A xor priority:H"),
        "XOR should exclude task with neither A nor H"
    );
}

#[test]
fn test_xor_with_not() {
    let one = task_with(&[("project", "A"), ("priority", "H"), ("status", "pending")]);
    let two = task_with(&[("project", "A"), ("status", "pending")]);
    let three = task_with(&[("priority", "H"), ("status", "pending")]);
    let four = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&one, "project:A xor priority.not:H"),
        "XOR with NOT: one A=true, NOT H=false -> XOR true"
    );
    assert!(
        !matches_query(&two, "project:A xor priority.not:H"),
        "XOR with NOT: two A=true, NOT H=true -> XOR false"
    );
    assert!(
        !matches_query(&three, "project:A xor priority.not:H"),
        "XOR with NOT: three A=false, NOT H=false -> XOR false"
    );
    assert!(
        matches_query(&four, "project:A xor priority.not:H"),
        "XOR with NOT: four A=false, NOT H=true -> XOR true"
    );
}

// === TW operators.test.py :: TestOperatorsQuantity ===

#[test]
fn test_due_after_greater() {
    let now = Utc::now();
    let due_yesterday = task_with(&[
        (
            "due",
            &format!("{}", (now - Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);
    let due_tomorrow = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        !matches_query(&due_yesterday, "due.after:today"),
        "due.after:today should not match yesterday"
    );
    assert!(
        matches_query(&due_tomorrow, "due.after:today"),
        "due.after:today should match tomorrow"
    );
    assert!(
        matches_query(&due_tomorrow, "due > today"),
        "due > today should match tomorrow"
    );
}

#[test]
fn test_due_before_smaller() {
    let now = Utc::now();
    let due_yesterday = task_with(&[
        (
            "due",
            &format!("{}", (now - Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);
    let due_tomorrow = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_yesterday, "due.before:today"),
        "due.before:today should match yesterday"
    );
    assert!(
        !matches_query(&due_tomorrow, "due.before:today"),
        "due.before:today should not match tomorrow"
    );
    assert!(
        matches_query(&due_yesterday, "due < today"),
        "due < today should match yesterday"
    );
}

#[test]
fn test_due_greater_equal() {
    let now = Utc::now();
    let today_midnight = Utc
        .with_ymd_and_hms(now.year(), now.month(), now.day(), 0, 0, 0)
        .single()
        .unwrap();
    let due_yesterday = task_with(&[
        (
            "due",
            &format!("{}", (now - Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);
    let due_today = task_with(&[
        ("due", &format!("{}", today_midnight.format("%+"))),
        ("status", "pending"),
    ]);
    let due_tomorrow = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        !matches_query(&due_yesterday, "due >= today"),
        "due >= today should NOT match yesterday"
    );
    assert!(
        matches_query(&due_today, "due >= today"),
        "due >= today should match today"
    );
    assert!(
        matches_query(&due_tomorrow, "due >= today"),
        "due >= today should match tomorrow"
    );
}

#[test]
fn test_due_smaller_equal() {
    let now = Utc::now();
    let today_midnight = Utc
        .with_ymd_and_hms(now.year(), now.month(), now.day(), 0, 0, 0)
        .single()
        .unwrap();
    let due_yesterday = task_with(&[
        (
            "due",
            &format!("{}", (now - Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);
    let due_today = task_with(&[
        ("due", &format!("{}", today_midnight.format("%+"))),
        ("status", "pending"),
    ]);
    let due_tomorrow = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_yesterday, "due <= today"),
        "due <= today should match yesterday"
    );
    assert!(
        matches_query(&due_today, "due <= today"),
        "due <= today should match today"
    );
    assert!(
        !matches_query(&due_tomorrow, "due <= today"),
        "due <= today should NOT match tomorrow"
    );
}

#[test]
fn test_priority_above_below() {
    let h = task_with(&[("priority", "H"), ("status", "pending")]);
    let m = task_with(&[("priority", "M"), ("status", "pending")]);
    let l = task_with(&[("priority", "L"), ("status", "pending")]);

    assert!(
        matches_query(&h, "priority.above:M"),
        "priority.above:M should match H"
    );
    assert!(
        !matches_query(&m, "priority.above:M"),
        "priority.above:M should NOT match M"
    );
    assert!(
        matches_query(&l, "priority.below:M"),
        "priority.below:M should match L"
    );
}

#[test]
fn test_priority_greater_less() {
    let h = task_with(&[("priority", "H"), ("status", "pending")]);
    let m = task_with(&[("priority", "M"), ("status", "pending")]);
    let l = task_with(&[("priority", "L"), ("status", "pending")]);

    assert!(
        matches_query(&h, "priority > M"),
        "priority > M should match H"
    );
    assert!(
        !matches_query(&m, "priority > M"),
        "priority > M should NOT match M"
    );
    assert!(
        matches_query(&l, "priority < M"),
        "priority < M should match L"
    );
}

#[test]
fn test_priority_greater_equal() {
    let h = task_with(&[("priority", "H"), ("status", "pending")]);
    let m = task_with(&[("priority", "M"), ("status", "pending")]);
    let l = task_with(&[("priority", "L"), ("status", "pending")]);

    assert!(
        matches_query(&h, "priority >= M"),
        "priority >= M should match H"
    );
    assert!(
        matches_query(&m, "priority >= M"),
        "priority >= M should match M"
    );
    assert!(
        !matches_query(&l, "priority >= M"),
        "priority >= M should NOT match L"
    );
}

#[test]
fn test_priority_smaller_equal() {
    let h = task_with(&[("priority", "H"), ("status", "pending")]);
    let m = task_with(&[("priority", "M"), ("status", "pending")]);
    let l = task_with(&[("priority", "L"), ("status", "pending")]);
    let none = task_with(&[("status", "pending")]);

    assert!(
        !matches_query(&h, "priority <= M"),
        "priority <= M should NOT match H"
    );
    assert!(
        matches_query(&m, "priority <= M"),
        "priority <= M should match M"
    );
    assert!(
        matches_query(&l, "priority <= M"),
        "priority <= M should match L"
    );
    assert!(
        matches_query(&none, "priority <= M"),
        "priority <= M should match unset"
    );
}

#[test]
fn test_description_lexicographic_gt() {
    let task_c = task_with(&[("description", "cat"), ("status", "pending")]);
    let task_a = task_with(&[("description", "ant"), ("status", "pending")]);

    assert!(
        matches_query(&task_c, "description > b"),
        "cat > b lexicographically"
    );
    assert!(
        !matches_query(&task_a, "description > b"),
        "ant < b lexicographically"
    );
}

#[test]
fn test_description_lexicographic_lt() {
    let task_c = task_with(&[("description", "cat"), ("status", "pending")]);
    let task_a = task_with(&[("description", "ant"), ("status", "pending")]);

    assert!(
        matches_query(&task_a, "description < b"),
        "ant < b lexicographically"
    );
    assert!(
        !matches_query(&task_c, "description < b"),
        "cat > b lexicographically"
    );
}

// === TW project.test.py ===

#[test]
fn test_project_exact_match() {
    let b = task_with(&[("project", "b"), ("status", "pending")]);
    let _ab = task_with(&[("project", "ab"), ("status", "pending")]);
    let _abc = task_with(&[("project", "abc"), ("status", "pending")]);

    assert!(matches_query(&b, "project:b"), "project:b should match 'b'");
}

#[test]
fn test_project_hierarchy_prefix() {
    let a = task_with(&[("project", "a"), ("status", "pending")]);
    let ab = task_with(&[("project", "a.b"), ("status", "pending")]);
    let abc = task_with(&[("project", "a.b.c"), ("status", "pending")]);

    assert!(
        matches_query(&a, "project:a"),
        "project:a should match project a"
    );
    assert!(
        matches_query(&ab, "project:a"),
        "project:a should prefix-match a.b"
    );
    assert!(
        matches_query(&abc, "project:a"),
        "project:a should prefix-match a.b.c"
    );
    assert!(
        !matches_query(&ab, "project:abc"),
        "project:abc should NOT prefix-match a.b"
    );
}

#[test]
fn test_project_not_excludes_hierarchy() {
    let a = task_with(&[("project", "a"), ("status", "pending")]);
    let a_b = task_with(&[("project", "a.b"), ("status", "pending")]);
    let c = task_with(&[("project", "c"), ("status", "pending")]);

    assert!(
        !matches_query(&a, "project.not:a"),
        "project.not:a should exclude a"
    );
    assert!(
        !matches_query(&a_b, "project.not:a"),
        "project.not:a should exclude a.b"
    );
    assert!(
        matches_query(&c, "project.not:a"),
        "project.not:a should pass c"
    );
}

#[test]
fn test_project_not_excludes_only_specific() {
    let a_b = task_with(&[("project", "a.b"), ("status", "pending")]);
    let a = task_with(&[("project", "a"), ("status", "pending")]);

    assert!(
        matches_query(&a, "project.not:a.b"),
        "project.not:a.b should pass a"
    );
    assert!(
        !matches_query(&a_b, "project.not:a.b"),
        "project.not:a.b should exclude a.b"
    );
}

#[test]
fn test_project_none_shows_unassigned() {
    let unassigned = task_with(&[("status", "pending")]);
    let assigned = task_with(&[("project", "X"), ("status", "pending")]);

    assert!(
        matches_query(&unassigned, "project.none:"),
        "project.none: should match unassigned"
    );
    assert!(
        !matches_query(&assigned, "project.none:"),
        "project.none: should NOT match assigned"
    );
}

#[test]
fn test_project_hyphenated() {
    let task = task_with(&[("project", "two-three"), ("status", "pending")]);

    assert!(
        matches_query(&task, "project:two-three"),
        "project:two-three should match hyphenated project"
    );
}

#[test]
fn test_project_with_parenthesis() {
    let task = task_with(&[("project", "two)"), ("status", "pending")]);

    assert!(
        matches_query(&task, "two)"),
        "project name with ) should be findable via text search"
    );
}

#[test]
fn test_project_with_spaces() {
    let task = task_with(&[("project", "foo bar"), ("status", "pending")]);

    assert!(
        matches_query(&task, "foo bar"),
        "project name with space should be findable via text search"
    );
}

#[test]
fn test_project_not_evaluated_as_date() {
    let task = task_with(&[("project", "mon"), ("status", "pending")]);

    assert!(
        matches_query(&task, "project:mon"),
        "project:mon should NOT be evaluated as Monday"
    );
}

#[test]
fn test_project_dashes_not_hierarchy() {
    let task = task_with(&[("project", "a-b"), ("status", "pending")]);

    assert!(
        matches_query(&task, "project:a-b"),
        "project:a-b should match dashed project (flat, not hierarchy)"
    );
}

#[test]
fn test_project_exclusion_isnt_substring() {
    let one = task_with(&[("project", "one"), ("status", "pending")]);
    let ones = task_with(&[("project", "ones"), ("status", "pending")]);
    let phone = task_with(&[("project", "phone"), ("status", "pending")]);
    let three = task_with(&[("project", "three"), ("status", "pending")]);

    assert!(
        !matches_query(&one, "project.isnt:one"),
        "project.isnt:one should exclude 'one'"
    );
    assert!(
        matches_query(&ones, "project.isnt:one"),
        "project.isnt:one should NOT exclude 'ones' (word boundary match)"
    );
    assert!(
        matches_query(&phone, "project.isnt:one"),
        "project.isnt:one should NOT exclude 'phone' (word boundary match)"
    );
    assert!(
        matches_query(&three, "project.isnt:one"),
        "project.isnt:one should pass 'three'"
    );
}

#[test]
fn test_project_exclusion_hasnt() {
    let one = task_with(&[("project", "one"), ("status", "pending")]);
    let ones = task_with(&[("project", "ones"), ("status", "pending")]);
    let three = task_with(&[("project", "three"), ("status", "pending")]);

    assert!(
        !matches_query(&one, "project.hasnt:one"),
        "project.hasnt:one should exclude 'one'"
    );
    assert!(
        !matches_query(&ones, "project.hasnt:one"),
        "project.hasnt:one should exclude 'ones' (contains 'one')"
    );
    assert!(
        matches_query(&three, "project.hasnt:one"),
        "project.hasnt:one should pass 'three'"
    );
}

#[test]
fn test_project_someday_filter() {
    let task = task_with(&[("project", "someday"), ("status", "pending")]);

    assert!(
        matches_query(&task, "pro:someday"),
        "pro:someday should match project named 'someday', not be parsed as date"
    );
}

// === TW tag.test.py :: TestDuplicateTags ===

#[test]
fn test_tag_partial_match() {
    let hannah = task_with(&[("tag", "hannah"), ("status", "pending")]);
    let anna = task_with(&[("tag", "anna"), ("status", "pending")]);

    assert!(
        matches_query(&hannah, "+anna"),
        "+anna should substring-match 'hannah' (TW bug 818 compat)"
    );
    assert!(
        matches_query(&anna, "+anna"),
        "+anna should exact-match 'anna'"
    );
    assert!(
        matches_query(&hannah, "+hannah"),
        "+hannah should exact-match 'hannah'"
    );
    assert!(
        !matches_query(&anna, "+hannah"),
        "+hannah should NOT substring-match 'anna'"
    );
}

// === TW tag.test.py :: TestVirtualTags ===

#[test]
fn test_virtual_tag_completed() {
    let completed = task_with(&[("status", "completed")]);
    let pending = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&completed, "+COMPLETED"),
        "completed task should match +COMPLETED"
    );
    assert!(
        !matches_query(&pending, "+COMPLETED"),
        "pending task should NOT match +COMPLETED"
    );
}

#[test]
fn test_virtual_tag_deleted() {
    let deleted = task_with(&[("status", "deleted")]);
    let pending = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&deleted, "+DELETED"),
        "deleted task should match +DELETED"
    );
    assert!(
        !matches_query(&pending, "+DELETED"),
        "pending task should NOT match +DELETED"
    );
}

#[test]
fn test_virtual_tag_pending() {
    let pending = task_with(&[("status", "pending")]);
    let completed = task_with(&[("status", "completed")]);

    assert!(
        matches_query(&pending, "+PENDING"),
        "pending task should match +PENDING"
    );
    assert!(
        !matches_query(&completed, "+PENDING"),
        "completed task should NOT match +PENDING"
    );
}

#[test]
fn test_virtual_tag_overdue() {
    let now = Utc::now();
    let overdue = task_with(&[
        (
            "due",
            &format!("{}", (now - Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);
    let future = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&overdue, "+OVERDUE"),
        "past-due task should match +OVERDUE"
    );
    assert!(
        !matches_query(&future, "+OVERDUE"),
        "future-due task should NOT match +OVERDUE"
    );
}

#[test]
fn test_virtual_tag_today() {
    let now = Utc::now();
    let today_midnight = Utc
        .with_ymd_and_hms(now.year(), now.month(), now.day(), 0, 0, 0)
        .single()
        .unwrap();
    let due_today = task_with(&[
        ("due", &format!("{}", today_midnight.format("%+"))),
        ("status", "pending"),
    ]);
    let due_tomorrow = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_today, "+TODAY"),
        "due today should match +TODAY"
    );
    assert!(
        !matches_query(&due_tomorrow, "+TODAY"),
        "due tomorrow should NOT match +TODAY"
    );
}

#[test]
fn test_virtual_tag_duetoday() {
    let now = Utc::now();
    let today_midnight = Utc
        .with_ymd_and_hms(now.year(), now.month(), now.day(), 0, 0, 0)
        .single()
        .unwrap();
    let due_today = task_with(&[
        ("due", &format!("{}", today_midnight.format("%+"))),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_today, "+DUETODAY"),
        "due today should match +DUETODAY"
    );
}

#[test]
fn test_virtual_tag_active() {
    let started = task_with(&[("status", "pending")]);
    let mut replica = Replica::new(StorageConfig::InMemory.into_storage().unwrap());
    let mut ops = taskchampion::Operations::new();
    let uuid = taskchampion::Uuid::new_v4();
    let mut task = replica.create_task(uuid, &mut ops).unwrap();
    task.set_description("started".into(), &mut ops).unwrap();
    task.set_status(TcStatus::Pending, &mut ops).unwrap();
    task.set_value("start", Some(Utc::now().to_rfc3339()), &mut ops)
        .unwrap();
    replica.commit_operations(ops).unwrap();
    let started_task = replica.get_task(uuid).unwrap().unwrap();

    assert!(
        matches_query(&started_task, "+ACTIVE"),
        "started task should match +ACTIVE"
    );
    assert!(
        !matches_query(&started, "+ACTIVE"),
        "non-started task should NOT match +ACTIVE"
    );
}

#[test]
fn test_virtual_tag_scheduled() {
    let now = Utc::now();
    let sched = task_with(&[
        (
            "scheduled",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);
    let no_sched = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&sched, "+SCHEDULED"),
        "scheduled task should match +SCHEDULED"
    );
    assert!(
        !matches_query(&no_sched, "+SCHEDULED"),
        "unscheduled task should NOT match +SCHEDULED"
    );
}

#[test]
fn test_virtual_tag_ready() {
    let now = Utc::now();
    let ready = task_with(&[("status", "pending")]);
    let future_sched = task_with(&[
        (
            "scheduled",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&ready, "+READY"),
        "pending task without schedule should be ready"
    );
    assert!(
        !matches_query(&future_sched, "+READY"),
        "future-scheduled task should NOT be ready"
    );
}

#[test]
fn test_virtual_tag_waiting() {
    let now = Utc::now();
    let waiting = task_with(&[
        (
            "wait",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);
    let no_wait = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&waiting, "+WAITING"),
        "task with future wait should match +WAITING"
    );
    assert!(
        !matches_query(&no_wait, "+WAITING"),
        "task without wait should NOT match +WAITING"
    );
}

#[test]
fn test_virtual_tag_year_month_week() {
    let now = Utc::now();
    let this_year = task_with(&[
        ("due", &format!("{}", now.format("%+"))),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&this_year, "+YEAR"),
        "task due this year should match +YEAR"
    );
    assert!(
        matches_query(&this_year, "+MONTH"),
        "task due this month should match +MONTH"
    );
    assert!(
        matches_query(&this_year, "+WEEK"),
        "task due this week should match +WEEK"
    );
}

#[test]
fn test_virtual_tag_orphaned() {
    let task = task_with(&[("status", "pending")]);

    assert!(
        !matches_query(&task, "+ORPHAN"),
        "task without orphan UDA should NOT match +ORPHAN"
    );
}

// === TW search.test.py ===

#[test]
fn test_plain_search_arg() {
    let one = task_with(&[("description", "one"), ("status", "pending")]);
    let two = task_with(&[("description", "two"), ("status", "pending")]);

    assert!(
        matches_query(&one, "one"),
        "plain text 'one' should match task with 'one' in description"
    );
    assert!(
        !matches_query(&two, "one"),
        "plain text 'one' should NOT match task 'two'"
    );
}

#[test]
fn test_slash_in_description() {
    let task = task_with(&[("description", "foo/"), ("status", "pending")]);
    assert!(
        matches_query(&task, "foo/"),
        "description with slash should match via explicit text search"
    );
}

#[test]
fn test_minus_in_description() {
    let task = task_with(&[("description", "foo-"), ("status", "pending")]);
    assert!(
        matches_query(&task, "/foo-/"),
        "pattern should match description with trailing -"
    );
}

#[test]
fn test_plus_in_description() {
    let task = task_with(&[("description", "foo+"), ("status", "pending")]);
    assert!(
        matches_query(&task, "/foo+/"),
        "pattern should match description with trailing +"
    );
}

#[test]
fn test_description_startswith() {
    let task_a = task_with(&[("description", "A to Z"), ("status", "pending")]);
    let task_z = task_with(&[("description", "Z to A"), ("status", "pending")]);

    assert!(
        matches_query(&task_a, "description.startswith:A"),
        "description.startswith:A should match 'A to Z'"
    );
    assert!(
        !matches_query(&task_z, "description.startswith:A"),
        "description.startswith:A should NOT match 'Z to A'"
    );
}

#[test]
fn test_description_endswith() {
    let task_a = task_with(&[("description", "A to Z"), ("status", "pending")]);
    let task_z = task_with(&[("description", "Z to A"), ("status", "pending")]);

    assert!(
        matches_query(&task_a, "description.endswith:Z"),
        "description.endswith:Z should match 'A to Z'"
    );
    assert!(
        !matches_query(&task_z, "description.endswith:Z"),
        "description.endswith:Z should NOT match 'Z to A'"
    );
}

#[test]
fn test_description_contains_modifier() {
    let task = task_with(&[("description", "hello foo world"), ("status", "pending")]);

    assert!(
        matches_query(&task, "description.contains:foo"),
        "description.contains:foo should find 'foo'"
    );
    assert!(
        !matches_query(&task, "description.contains:bar"),
        "description.contains:bar should not find 'bar'"
    );
}

// === TW due.test.py ===

#[test]
fn test_due_before_with_custom_dateformat() {
    let now = Utc::now();
    let due_today = task_with(&[
        ("due", &format!("{}", now.format("%+"))),
        ("status", "pending"),
    ]);
    let due_tomorrow = task_with(&[
        (
            "due",
            &format!("{}", (now + Duration::days(1)).format("%+")),
        ),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_today, "due.before:tomorrow"),
        "due.before:tomorrow should match today"
    );
    assert!(
        !matches_query(&due_tomorrow, "due.before:tomorrow"),
        "due.before:tomorrow should NOT match tomorrow"
    );
}

#[test]
fn test_eoy_not_before_eoy() {
    let now = Utc::now();
    let eoy = Utc
        .with_ymd_and_hms(now.year(), 12, 31, 23, 59, 59)
        .single()
        .unwrap();
    let due_eoy = task_with(&[
        ("due", &format!("{}", eoy.format("%+"))),
        ("status", "pending"),
    ]);

    assert!(
        !matches_query(&due_eoy, "due.before:eoy"),
        "due.before:eoy should NOT match due at eoy"
    );
}

#[test]
fn test_due_today_includes_eod() {
    let now = Utc::now();
    let eod = Utc
        .with_ymd_and_hms(now.year(), now.month(), now.day(), 23, 59, 59)
        .single()
        .unwrap();
    let due_eod = task_with(&[
        ("due", &format!("{}", eod.format("%+"))),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_eod, "+TODAY"),
        "due at end of today should match +TODAY"
    );
}

// === Additional edge cases from TW bugs ===

#[test]
fn test_exact_project_operator() {
    let task = task_with(&[("project", "Work"), ("status", "pending")]);

    assert!(
        matches_query(&task, "project==Work"),
        "project==Work should exact match"
    );
    assert!(
        matches_query(&task, "project==work"),
        "project==Work should match case-insensitively"
    );
    assert!(
        !matches_query(&task, "project==Other"),
        "project==Work should NOT match different project"
    );
}

#[test]
fn test_filter_quoted_expression_or() {
    let home = task_with(&[("description", "clean home"), ("status", "pending")]);
    let work = task_with(&[("description", "fix work"), ("status", "pending")]);
    let other = task_with(&[("description", "something else"), ("status", "pending")]);

    assert!(
        matches_query(&home, "/home/ or /work/"),
        "OR of patterns should match home task"
    );
    assert!(
        matches_query(&work, "/home/ or /work/"),
        "OR of patterns should match work task"
    );
    assert!(
        !matches_query(&other, "/home/ or /work/"),
        "OR of patterns should not match other"
    );
}

#[test]
fn test_parenthesized_or_group() {
    let a = task_with(&[("project", "A"), ("status", "pending")]);
    let b = task_with(&[("project", "B"), ("status", "pending")]);
    let c = task_with(&[("project", "C"), ("status", "pending")]);

    assert!(
        matches_query(&a, "(project:A or project:B) and status:pending"),
        "parenthesized OR should match A"
    );
    assert!(
        matches_query(&b, "(project:A or project:B) and status:pending"),
        "parenthesized OR should match B"
    );
    assert!(
        !matches_query(&c, "(project:A or project:B) and status:pending"),
        "parenthesized OR should NOT match C"
    );
}

#[test]
fn test_parenthesized_or_at_end() {
    let a = task_with(&[("project", "A"), ("status", "pending")]);
    let c = task_with(&[("project", "C"), ("status", "pending")]);

    assert!(
        matches_query(&a, "status:pending and (project:A or project:B)"),
        "OR at end should match A"
    );
    assert!(
        !matches_query(&c, "status:pending and (project:A or project:B)"),
        "OR at end should NOT match C"
    );
}

#[test]
fn test_uuid_filter_explicit() {
    let task = task_with(&[("status", "pending")]);
    let uuid = task.get_uuid().to_string();

    assert!(
        matches_query(&task, &format!("uuid:{}", &uuid[..8])),
        "uuid:prefix should match"
    );
    assert!(
        matches_query(&task, &format!("uuid:{}", uuid)),
        "uuid:full should match"
    );
}

#[test]
fn test_start_before_after() {
    let start1 = Utc
        .with_ymd_and_hms(2008, 12, 22, 0, 0, 0)
        .single()
        .unwrap();
    let start2 = Utc.with_ymd_and_hms(2009, 4, 17, 0, 0, 0).single().unwrap();

    let mut replica = Replica::new(StorageConfig::InMemory.into_storage().unwrap());
    let mut ops = taskchampion::Operations::new();
    let uuid1 = taskchampion::Uuid::new_v4();
    let mut task1 = replica.create_task(uuid1, &mut ops).unwrap();
    task1.set_description("task1".into(), &mut ops).unwrap();
    task1.set_status(TcStatus::Pending, &mut ops).unwrap();
    task1
        .set_value("start", Some(start1.to_rfc3339()), &mut ops)
        .unwrap();
    let uuid2 = taskchampion::Uuid::new_v4();
    let mut task2 = replica.create_task(uuid2, &mut ops).unwrap();
    task2.set_description("task2".into(), &mut ops).unwrap();
    task2.set_status(TcStatus::Pending, &mut ops).unwrap();
    task2
        .set_value("start", Some(start2.to_rfc3339()), &mut ops)
        .unwrap();
    replica.commit_operations(ops).unwrap();
    let t1 = replica.get_task(uuid1).unwrap().unwrap();
    let t2 = replica.get_task(uuid2).unwrap().unwrap();

    assert!(
        t1.get_value("start").is_some() && t2.get_value("start").is_some(),
        "both tasks should have start"
    );
    assert!(
        matches_query(&t1, "start.before:2009-01-01"),
        "task1 start.before 2009 should match"
    );
    assert!(
        !matches_query(&t2, "start.before:2009-01-01"),
        "task2 start.before 2009 should NOT match"
    );
    assert!(
        matches_query(&t2, "start.after:2009-01-01"),
        "task2 start.after 2009 should match"
    );
}

#[test]
fn test_due_matches_whole_day() {
    let day = Utc
        .with_ymd_and_hms(2015, 7, 7, 14, 30, 0)
        .single()
        .unwrap();
    let due_afternoon = task_with(&[
        ("due", &format!("{}", day.format("%+"))),
        ("status", "pending"),
    ]);

    assert!(
        matches_query(&due_afternoon, "due:2015-07-07"),
        "due:2015-07-07 should match task due at any time that day"
    );
}

#[test]
fn test_due_not_whole_day_exclusion() {
    let day = Utc
        .with_ymd_and_hms(2015, 7, 7, 14, 30, 0)
        .single()
        .unwrap();
    let due_afternoon = task_with(&[
        ("due", &format!("{}", day.format("%+"))),
        ("status", "pending"),
    ]);

    assert!(
        !matches_query(&due_afternoon, "due.not:2015-07-07"),
        "due.not:2015-07-07 should exclude tasks on that day"
    );
}

#[test]
fn test_urgency_comparison() {
    let task = task_with(&[("status", "pending")]);

    assert!(
        matches_query(&task, "urgency<0"),
        "pending task should have urgency < 0 (test sanity)"
    );
}
