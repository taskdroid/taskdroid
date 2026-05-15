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
use crate::core::utils::{parse_iso8601, task_snapshot_from_task};
use taskchampion::{
    Replica, StorageConfig,
    chrono::{Datelike, Duration, Utc, Weekday},
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
