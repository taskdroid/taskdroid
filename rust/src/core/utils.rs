use super::error::{Result, TaskError};
use super::models::{TaskAnnotation, TaskComputed, TaskCore, TaskSnapshot, TaskStatus, UdaPair};
use std::str::FromStr;
use taskchampion::{
    Status as TcStatus, Tag,
    chrono::{DateTime, Utc},
};

pub fn task_snapshot_from_task(t: taskchampion::Task) -> TaskSnapshot {
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
        urgency: calculate_urgency(&t, now, &next_tag),
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

fn calculate_urgency(t: &taskchampion::Task, now: DateTime<Utc>, next_tag: &Tag) -> f32 {
    let mut urgency = 0.0;
    const C_NEXT: f32 = 15.0;
    const C_DUE: f32 = 12.0;
    const C_BLOCKING: f32 = 8.0;
    const C_H: f32 = 6.0;
    const C_M: f32 = 3.9;
    const C_L: f32 = 1.8;
    const C_ACTIVE: f32 = 4.0;
    const C_SCHED: f32 = 5.0;
    const C_AGE: f32 = 2.0;
    const C_TAGS: f32 = 1.0;
    const C_ANNOTATIONS: f32 = 1.0;
    const C_PROJECT: f32 = 1.0;
    const C_BLOCKED: f32 = -5.0;
    const C_WAITING: f32 = -3.0;

    if t.has_tag(next_tag) {
        urgency += C_NEXT;
    }
    if t.is_active() {
        urgency += C_ACTIVE;
    }
    if t.is_blocking() {
        urgency += C_BLOCKING;
    }
    if t.is_blocked() {
        urgency += C_BLOCKED;
    }
    if t.is_waiting() {
        urgency += C_WAITING;
    }
    if t.get_value("project").is_some() {
        urgency += C_PROJECT;
    }

    match t.get_priority() {
        "H" => urgency += C_H,
        "M" => urgency += C_M,
        "L" => urgency += C_L,
        _ => {}
    }

    if let Some(due) = t.get_due() {
        if due < now {
            urgency += C_DUE;
        } else {
            let days = (due - now).num_days();
            if days <= 14 {
                urgency += C_DUE * (1.0 - (0.8 * (days as f32 / 14.0)));
            } else {
                urgency += C_DUE * 0.2;
            }
        }
    }

    if let Some(sched) = t
        .get_value("scheduled")
        .or_else(|| t.get_value("sched"))
        .and_then(|s| parse_iso8601(s).ok())
    {
        if sched < now {
            urgency += C_SCHED;
        }
    }

    if let Some(entry) = t.get_entry() {
        let days = (now - entry).num_days().max(0) as f32;
        let factor = (days / 365.0).min(1.0);
        urgency += C_AGE * factor;
    }

    match t.get_tags().count() {
        0 => {}
        1 => urgency += C_TAGS * 0.8,
        2 => urgency += C_TAGS * 0.9,
        _ => urgency += C_TAGS,
    }

    match t.get_annotations().count() {
        0 => {}
        1 => urgency += C_ANNOTATIONS * 0.8,
        2 => urgency += C_ANNOTATIONS * 0.9,
        _ => urgency += C_ANNOTATIONS,
    }

    urgency
}
