use super::config::Taskrc;
use super::error::{Result, TaskError};
use super::models::{TaskAnnotation, TaskComputed, TaskCore, TaskSnapshot, TaskStatus, UdaPair};
use std::str::FromStr;
use taskchampion::{
    Status as TcStatus, Tag,
    chrono::{DateTime, Utc},
};

pub fn task_snapshot_from_task(t: taskchampion::Task, config: &Taskrc) -> TaskSnapshot {
    let now = Utc::now();
    let next_tag = Tag::from_str("next").unwrap_or_else(|_| Tag::from_str("error").unwrap());

    let status = t.get_status();
    let is_recurring_template = status == TcStatus::Recurring;
    let parent_uuid = t.get_value("parent").map(|s| s.to_string());
    let recurrence_index = t.get_value("imask").and_then(|v| v.parse::<usize>().ok());
    let is_recurring_instance = parent_uuid.is_some();

    let series_root_uuid = if is_recurring_template {
        Some(t.get_uuid().to_string())
    } else if is_recurring_instance {
        parent_uuid.clone()
    } else {
        None
    };

    let computed = TaskComputed {
        urgency: calculate_urgency(&t, now, &next_tag, config),
        is_active: t.is_active(),
        is_blocked: t.is_blocked(),
        is_blocking: t.is_blocking(),
        is_waiting: t.is_waiting(),
        is_recurring_template,
        is_recurring_instance,
        series_root_uuid,
    };

    let udas = t
        .get_user_defined_attributes()
        .filter(|(k, _)| {
            ![
                "project",
                "recur",
                "sched",
                "scheduled",
                "until",
                "start",
                "end",
                "parent",
                "imask",
            ]
            .contains(k)
        })
        .map(|(k, v)| UdaPair {
            key: k.to_string(),
            value: v.to_string(),
        })
        .collect();

    let annotations = t
        .get_annotations()
        .map(|ann| TaskAnnotation {
            entry: format_iso8601(ann.entry),
            description: ann.description.to_string(),
        })
        .collect();

    let priority_str = t.get_priority();
    let priority = if priority_str.is_empty() {
        None
    } else {
        Some(priority_str.to_string())
    };

    let core = TaskCore {
        uuid: t.get_uuid().to_string(),
        description: t.get_description().to_string(),
        status: map_tc_to_status(status),
        project: t.get_value("project").map(|s| s.to_string()),
        priority,
        tags: t.get_tags().map(|t| t.to_string()).collect(),
        entry: t.get_entry().map(format_iso8601).unwrap_or_default(),
        modified: t.get_modified().map(format_iso8601).unwrap_or_default(),
        due: t.get_due().map(format_iso8601),
        wait: t.get_wait().map(format_iso8601),
        start: t.get_value("start").and_then(parse_date_opt_str),
        end: t.get_value("end").and_then(parse_date_opt_str),
        scheduled: t
            .get_value("scheduled")
            .or_else(|| t.get_value("sched"))
            .and_then(parse_date_opt_str),
        until: t.get_value("until").and_then(parse_date_opt_str),
        depends: t.get_dependencies().map(|u| u.to_string()).collect(),
        recurrence: t.get_value("recur").map(|s| s.to_string()),
        annotations,
        udas,
        parent_uuid,
        recurrence_index,
    };

    TaskSnapshot { core, computed }
}

pub fn map_tc_to_status(s: TcStatus) -> TaskStatus {
    match s {
        TcStatus::Pending => TaskStatus::Pending,
        TcStatus::Completed => TaskStatus::Completed,
        TcStatus::Deleted => TaskStatus::Deleted,
        TcStatus::Recurring => TaskStatus::Recurring,
        _ => TaskStatus::Pending,
    }
}

pub fn parse_iso8601(date_str: &str) -> Result<DateTime<Utc>> {
    if let Ok(raw_epoch) = date_str.parse::<i64>() {
        let (secs, nanos) = if raw_epoch.abs() >= 1_000_000_000_000 {
            let secs = raw_epoch.div_euclid(1000);
            let millis = raw_epoch.rem_euclid(1000) as u32;
            (secs, millis * 1_000_000)
        } else {
            (raw_epoch, 0)
        };

        if let Some(dt) = DateTime::from_timestamp(secs, nanos) {
            return Ok(dt);
        }
    }
    if let Ok(dt) = DateTime::parse_from_rfc3339(date_str) {
        return Ok(dt.with_timezone(&Utc));
    }
    if let Ok(dt) = DateTime::parse_from_str(date_str, "%Y%m%dT%H%M%SZ") {
        return Ok(dt.with_timezone(&Utc));
    }
    if let Ok(dt) = taskchampion::chrono::NaiveDateTime::parse_from_str(date_str, "%Y%m%dT%H%M%S") {
        return Ok(DateTime::from_naive_utc_and_offset(dt, Utc));
    }
    if let Ok(dt) = taskchampion::chrono::NaiveDate::parse_from_str(date_str, "%Y-%m-%d") {
        let midnight = dt.and_hms_opt(0, 0, 0).ok_or_else(|| {
            TaskError::invalid_input(format!("Invalid date-only value: {date_str}"))
        })?;
        return Ok(DateTime::from_naive_utc_and_offset(midnight, Utc));
    }
    Err(TaskError::invalid_input(format!(
        "Invalid date: {date_str}"
    )))
}

pub fn parse_date_opt(s: &str) -> Option<DateTime<Utc>> {
    parse_iso8601(s).ok()
}

pub fn parse_date_opt_str(s: &str) -> Option<String> {
    parse_iso8601(s).ok().map(|d| d.to_rfc3339())
}

pub fn parse_date_opt_strict(s: &str) -> Result<Option<DateTime<Utc>>> {
    if s.is_empty() {
        Ok(None)
    } else {
        Ok(Some(parse_iso8601(s)?))
    }
}

pub fn parse_date_opt_str_strict(s: &str) -> Result<Option<String>> {
    if s.is_empty() {
        Ok(None)
    } else {
        Ok(Some(parse_iso8601(s)?.to_rfc3339()))
    }
}

pub fn format_iso8601(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339()
}

pub(crate) fn calculate_urgency(
    t: &taskchampion::Task,
    now: DateTime<Utc>,
    next_tag: &Tag,
    config: &Taskrc,
) -> f32 {
    let c_next = config.get_float("urgency.user.tag.next.coefficient", 15.0);
    let c_due = config.get_float("urgency.due.coefficient", 12.0);
    let c_blocking = config.get_float("urgency.blocking.coefficient", 8.0);
    let c_h = config.get_float("urgency.uda.priority.H.coefficient", 6.0);
    let c_m = config.get_float("urgency.uda.priority.M.coefficient", 3.9);
    let c_l = config.get_float("urgency.uda.priority.L.coefficient", 1.8);
    let c_active = config.get_float("urgency.active.coefficient", 4.0);
    let c_sched = config.get_float("urgency.scheduled.coefficient", 5.0);
    let c_age = config.get_float("urgency.age.coefficient", 2.0);
    let c_tags = config.get_float("urgency.tags.coefficient", 1.0);
    let c_annotations = config.get_float("urgency.annotations.coefficient", 1.0);
    let c_project = config.get_float("urgency.project.coefficient", 1.0);
    let c_blocked = config.get_float("urgency.blocked.coefficient", -5.0);
    let c_waiting = config.get_float("urgency.waiting.coefficient", -3.0);

    let mut urgency = 0.0;

    if t.has_tag(next_tag) {
        urgency += c_next;
    }
    if t.is_active() {
        urgency += c_active;
    }
    if t.is_blocking() {
        urgency += c_blocking;
    }
    if t.is_blocked() {
        urgency += c_blocked;
    }
    if t.is_waiting() {
        urgency += c_waiting;
    }
    if t.get_value("project").is_some() {
        urgency += c_project;
    }

    match t.get_priority() {
        "H" => urgency += c_h,
        "M" => urgency += c_m,
        "L" => urgency += c_l,
        _ => {}
    }

    if let Some(due) = t.get_due() {
        if due < now {
            urgency += c_due;
        } else {
            let days = (due - now).num_days();
            if days <= 14 {
                urgency += c_due * (1.0 - (0.8 * (days as f32 / 14.0)));
            } else {
                urgency += c_due * 0.2;
            }
        }
    }

    if let Some(sched) = t
        .get_value("scheduled")
        .or_else(|| t.get_value("sched"))
        .and_then(|s| parse_iso8601(s).ok())
    {
        if sched < now {
            urgency += c_sched;
        }
    }

    if let Some(entry) = t.get_entry() {
        let days = (now - entry).num_days().max(0) as f32;
        let factor = (days / 365.0).min(1.0);
        urgency += c_age * factor;
    }

    match t.get_tags().count() {
        0 => {}
        1 => urgency += c_tags * 0.8,
        2 => urgency += c_tags * 0.9,
        _ => urgency += c_tags,
    }

    match t.get_annotations().count() {
        0 => {}
        1 => urgency += c_annotations * 0.8,
        2 => urgency += c_annotations * 0.9,
        _ => urgency += c_annotations,
    }

    urgency
}
