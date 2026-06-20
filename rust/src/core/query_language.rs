use super::models::TaskStatus;
use super::utils::map_tc_to_status;
use taskchampion::{
    Status as TcStatus,
    chrono::{DateTime, Datelike, Duration, NaiveDate, TimeZone, Timelike, Utc},
};

#[derive(Debug, Clone)]
enum Expr {
    And(Vec<Expr>),
    Or(Vec<Expr>),
    Xor(Vec<Expr>),
    Not(Box<Expr>),
    Term(Term),
}

#[derive(Debug, Clone)]
enum Term {
    Text(String),
    Tag(String),
    TagNone,
    TagAny,
    Project(String),
    Status(TaskStatus),
    Priority(String),
    UuidPrefix(String),
    Date {
        field: DateField,
        op: DateOp,
        value: Option<DateTime<Utc>>,
    },
    Flag(Flag),
    Equals {
        key: String,
        value: String,
    },
    NotEquals {
        key: String,
        value: String,
    },
    StrictNotEquals {
        key: String,
        value: String,
    },
    Pattern(String),
    Uuid(String),
    Uda {
        key: String,
        value: String,
    },
    StrMatch {
        key: String,
        op: StrOp,
        value: String,
    },
    Compare {
        key: String,
        op: CompareOp,
        value: String,
    },
    Negated(Box<Term>),
}

#[derive(Debug, Clone, Copy)]
enum StrOp {
    Has,
    Hasnt,
    StartsWith,
    EndsWith,
    Contains,
    Isnt,
}

#[derive(Debug, Clone, Copy)]
enum CompareOp {
    Lt,
    LtEq,
    Gt,
    GtEq,
}

#[derive(Debug, Clone, Copy)]
enum DateField {
    Due,
    Wait,
    Scheduled,
    Entry,
    Modified,
    Start,
    End,
    Until,
}

#[derive(Debug, Clone, Copy)]
enum DateOp {
    Before,
    BeforeEq,
    After,
    AfterEq,
    On,
    None,
    Any,
}

#[derive(Debug, Clone, Copy)]
enum Flag {
    Ready,
    Active,
    Due,
    DueToday,
    Overdue,
    Someday,
    Project,
    Template,
    Blocked,
    Blocking,
    Waiting,
    Priority,
    Until,
    Instance,
    Latest,
    Tagged,
    Unblocked,
    Annotated,
    Scheduled,
    Tomorrow,
    Yesterday,
    Week,
    Month,
    Quarter,
    Year,
    Uda,
    Orphan,
}

const TASKWARRIOR_DEFAULT_DUE_DAYS: i64 = 7;

pub fn matches_query(task: &taskchampion::Task, query: &str) -> bool {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return true;
    }

    let tokens = merge_comparison_tokens(merge_colon_tokens(tokenize(trimmed)));
    let mut parser = Parser::new(tokens);
    match parser.parse() {
        Some(expr) => evaluate_expr(&expr, task, Utc::now()),
        None => plain_text_match(task, trimmed),
    }
}

fn evaluate_expr(expr: &Expr, task: &taskchampion::Task, now: DateTime<Utc>) -> bool {
    match expr {
        Expr::And(children) => children.iter().all(|child| evaluate_expr(child, task, now)),
        Expr::Or(children) => children.iter().any(|child| evaluate_expr(child, task, now)),
        Expr::Xor(children) => {
            children.iter().fold(0usize, |count, child| {
                if evaluate_expr(child, task, now) {
                    count + 1
                } else {
                    count
                }
            }) == 1
        }
        Expr::Not(child) => !evaluate_expr(child, task, now),
        Expr::Term(term) => evaluate_term(term, task, now),
    }
}

fn evaluate_term(term: &Term, task: &taskchampion::Task, now: DateTime<Utc>) -> bool {
    match term {
        Term::Text(query) => plain_text_match(task, query),
        Term::Tag(tag) => {
            let lower_tag = tag.to_lowercase();
            task.get_tags()
                .any(|existing| existing.to_string().to_lowercase().contains(&lower_tag))
        }
        Term::TagNone => !task
            .get_tags()
            .any(|t| !is_virtual_tag_name(&t.to_string())),
        Term::TagAny => task
            .get_tags()
            .any(|t| !is_virtual_tag_name(&t.to_string())),
        Term::Project(project) => {
            let task_project = task.get_value("project");
            if project.eq_ignore_ascii_case("none") {
                return task_project.map_or(true, |v| v.trim().is_empty());
            }
            let Some(value) = task_project else {
                return false;
            };
            let value = value.to_lowercase();
            let project = project.to_lowercase();
            value == project || value.starts_with(&format!("{project}."))
        }
        Term::Status(status) => map_tc_to_status(task.get_status()) == *status,
        Term::Priority(priority) => {
            let value = task.get_priority();
            if priority.eq_ignore_ascii_case("none") {
                return value.trim().is_empty();
            }
            value.eq_ignore_ascii_case(priority)
        }
        Term::UuidPrefix(prefix) => task
            .get_uuid()
            .to_string()
            .to_lowercase()
            .starts_with(&prefix.to_lowercase()),
        Term::Date { field, op, value } => evaluate_date_term(task, *field, *op, *value),
        Term::Flag(flag) => evaluate_flag(task, *flag, now),
        Term::Equals { key, value } => {
            let task_val = read_attribute(task, key);
            task_val.eq_ignore_ascii_case(value)
        }
        Term::NotEquals { key, value } => {
            let task_val = read_attribute(task, key);
            !task_val.eq_ignore_ascii_case(value)
        }
        Term::StrictNotEquals { key, value } => {
            let task_val = read_attribute(task, key);
            task_val != *value
        }
        Term::Pattern(pattern) => {
            let desc = task.get_description().to_lowercase();
            let pat = pattern.to_lowercase();
            desc.contains(&pat)
        }
        Term::Uuid(prefix) => {
            task.get_uuid().to_string().eq_ignore_ascii_case(prefix)
                || task
                    .get_uuid()
                    .to_string()
                    .to_lowercase()
                    .starts_with(&prefix.to_lowercase())
        }
        Term::Uda { key, value } => {
            let lower_value = value.to_lowercase();
            task.get_user_defined_attributes().any(|(k, v)| {
                k.eq_ignore_ascii_case(key) && v.to_lowercase().contains(&lower_value)
            })
        }
        Term::StrMatch { key, op, value } => {
            let attr = read_attribute(task, key).to_lowercase();
            let val = value.to_lowercase();
            match op {
                StrOp::Has | StrOp::Contains => attr.contains(&val),
                StrOp::Hasnt => !attr.contains(&val),
                StrOp::StartsWith => attr.starts_with(&val),
                StrOp::EndsWith => attr.ends_with(&val),
                StrOp::Isnt => {
                    let words: Vec<&str> = attr
                        .split(|c: char| !c.is_alphanumeric())
                        .filter(|w| !w.is_empty())
                        .collect();
                    !words.iter().any(|&w| w == val.as_str())
                }
            }
        }
        Term::Compare { key, op, value } => {
            let attr = read_attribute(task, key);
            match key.as_str() {
                "priority" => {
                    let rank = |p: &str| -> u8 {
                        match p.to_ascii_uppercase().as_str() {
                            "H" => 3,
                            "M" => 2,
                            "L" => 1,
                            _ => 0,
                        }
                    };
                    let a = rank(&attr);
                    let b = rank(value);
                    match op {
                        CompareOp::Gt => a > b,
                        CompareOp::GtEq => a >= b,
                        CompareOp::Lt => a < b,
                        CompareOp::LtEq => a <= b,
                    }
                }
                _ => {
                    // Lexicographic comparison for strings, f32 parse for numeric fields
                    if let (Ok(a), Ok(b)) = (attr.parse::<f32>(), value.parse::<f32>()) {
                        match op {
                            CompareOp::Gt => a > b,
                            CompareOp::GtEq => a >= b,
                            CompareOp::Lt => a < b,
                            CompareOp::LtEq => a <= b,
                        }
                    } else {
                        let val = value.to_lowercase();
                        let a = attr.to_lowercase();
                        match op {
                            CompareOp::Gt => a > val,
                            CompareOp::GtEq => a >= val,
                            CompareOp::Lt => a < val,
                            CompareOp::LtEq => a <= val,
                        }
                    }
                }
            }
        }
        Term::Negated(inner) => !evaluate_term(inner, task, now),
    }
}

fn read_attribute(task: &taskchampion::Task, key: &str) -> String {
    match key {
        "description" | "desc" => task.get_description().to_string(),
        "project" => task.get_value("project").unwrap_or_default().to_string(),
        "status" => {
            let s = map_tc_to_status(task.get_status());
            match s {
                TaskStatus::Pending => "pending".to_string(),
                TaskStatus::Completed => "completed".to_string(),
                TaskStatus::Deleted => "deleted".to_string(),
                TaskStatus::Recurring => "recurring".to_string(),
            }
        }
        "priority" => task.get_priority().to_string(),
        "uuid" => task.get_uuid().to_string(),
        "due" => task.get_due().map(|d| d.to_rfc3339()).unwrap_or_default(),
        "wait" => task.get_wait().map(|d| d.to_rfc3339()).unwrap_or_default(),
        "entry" => task.get_entry().map(|d| d.to_rfc3339()).unwrap_or_default(),
        "modified" => task
            .get_modified()
            .map(|d| d.to_rfc3339())
            .unwrap_or_default(),
        "start" => task.get_value("start").unwrap_or_default().to_string(),
        "end" => task.get_value("end").unwrap_or_default().to_string(),
        "scheduled" => task.get_value("scheduled").unwrap_or_default().to_string(),
        "until" => task.get_value("until").unwrap_or_default().to_string(),
        other => task.get_value(other).unwrap_or_default().to_string(),
    }
}

fn is_midnight(dt: &DateTime<Utc>) -> bool {
    dt.hour() == 0 && dt.minute() == 0 && dt.second() == 0 && dt.nanosecond() == 0
}

fn evaluate_date_term(
    task: &taskchampion::Task,
    field: DateField,
    op: DateOp,
    target: Option<DateTime<Utc>>,
) -> bool {
    let task_value = read_date_field(task, field);
    match op {
        DateOp::None => task_value.is_none(),
        DateOp::Any => task_value.is_some(),
        DateOp::Before => match (task_value, target) {
            (Some(value), Some(target)) => {
                if is_midnight(&target) {
                    value.date_naive() < target.date_naive()
                } else {
                    value < target
                }
            }
            _ => false,
        },
        DateOp::BeforeEq => match (task_value, target) {
            (Some(value), Some(target)) => {
                if is_midnight(&target) {
                    value.date_naive() <= target.date_naive()
                } else {
                    value <= target
                }
            }
            _ => false,
        },
        DateOp::After => match (task_value, target) {
            (Some(value), Some(target)) => {
                if is_midnight(&target) {
                    value.date_naive() > target.date_naive()
                } else {
                    value > target
                }
            }
            _ => false,
        },
        DateOp::AfterEq => match (task_value, target) {
            (Some(value), Some(target)) => {
                if is_midnight(&target) {
                    value.date_naive() >= target.date_naive()
                } else {
                    value >= target
                }
            }
            _ => false,
        },
        DateOp::On => match (task_value, target) {
            (Some(value), Some(target)) => value.date_naive() == target.date_naive(),
            _ => false,
        },
    }
}

fn evaluate_flag(task: &taskchampion::Task, flag: Flag, now: DateTime<Utc>) -> bool {
    match flag {
        Flag::Ready => {
            map_tc_to_status(task.get_status()) == TaskStatus::Pending
                && !task.is_blocked()
                && !is_waiting_at(task, now)
                && !is_scheduled_future(task, now)
        }
        Flag::Active => task.is_active(),
        Flag::Due => read_date_field(task, DateField::Due)
            .is_some_and(|date| date <= now + Duration::days(TASKWARRIOR_DEFAULT_DUE_DAYS)),
        Flag::DueToday => read_date_field(task, DateField::Due)
            .is_some_and(|date| date.date_naive() == now.date_naive()),
        Flag::Overdue => read_date_field(task, DateField::Due).is_some_and(|date| date < now),
        Flag::Someday => read_date_field(task, DateField::Wait)
            .is_some_and(|date| date > now + Duration::days(30)),
        Flag::Project => task
            .get_value("project")
            .is_some_and(|project| !project.trim().is_empty()),
        Flag::Template => task.get_status() == TcStatus::Recurring,
        Flag::Blocked => task.is_blocked(),
        Flag::Blocking => task.is_blocking(),
        Flag::Waiting => is_waiting_at(task, now),
        Flag::Priority => !task.get_priority().trim().is_empty(),
        Flag::Until => task.get_value("until").is_some_and(|v| !v.is_empty()),
        Flag::Instance => {
            task.get_value("template").is_some_and(|v| !v.is_empty())
                || task.get_value("parent").is_some_and(|v| !v.is_empty())
        }
        Flag::Latest => true,
        Flag::Tagged => task
            .get_tags()
            .any(|t| !is_virtual_tag_name(&t.to_string())),
        Flag::Unblocked => !task.is_blocked(),
        Flag::Annotated => task.get_annotations().count() > 0,
        Flag::Scheduled => task.get_value("scheduled").is_some_and(|v| !v.is_empty()),
        Flag::Tomorrow => read_date_field(task, DateField::Due).is_some_and(|date| {
            let tomorrow = today_midnight(now) + Duration::days(1);
            date.date_naive() == tomorrow.date_naive()
        }),
        Flag::Yesterday => read_date_field(task, DateField::Due).is_some_and(|date| {
            let yesterday = today_midnight(now) - Duration::days(1);
            date.date_naive() == yesterday.date_naive()
        }),
        Flag::Week => read_date_field(task, DateField::Due).is_some_and(|date| {
            let t = today_midnight(now);
            let shift = now.weekday().num_days_from_monday() as i64;
            let sow = t - Duration::days(shift);
            let eow = sow + Duration::days(6);
            date.date_naive() >= sow.date_naive() && date.date_naive() <= eow.date_naive()
        }),
        Flag::Month => read_date_field(task, DateField::Due).is_some_and(|date| {
            let t = today_midnight(now);
            let som = Utc
                .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
                .single()
                .unwrap_or(t);
            let (y, m) = if now.month() == 12 {
                (now.year() + 1, 1)
            } else {
                (now.year(), now.month() + 1)
            };
            let eom =
                Utc.with_ymd_and_hms(y, m, 1, 0, 0, 0).single().unwrap_or(t) - Duration::seconds(1);
            date.date_naive() >= som.date_naive() && date.date_naive() <= eom.date_naive()
        }),
        Flag::Quarter => read_date_field(task, DateField::Due).is_some_and(|date| {
            let t = today_midnight(now);
            let q = (now.month() - 1) / 3;
            let start_month = q * 3 + 1;
            let soq = Utc
                .with_ymd_and_hms(now.year(), start_month, 1, 0, 0, 0)
                .single()
                .unwrap_or(t);
            let (eq_year, eq_month) = if start_month + 3 > 12 {
                (now.year() + 1, 1)
            } else {
                (now.year(), start_month + 3)
            };
            let eoq = Utc
                .with_ymd_and_hms(eq_year, eq_month, 1, 0, 0, 0)
                .single()
                .unwrap_or(t)
                - Duration::seconds(1);
            date.date_naive() >= soq.date_naive() && date.date_naive() <= eoq.date_naive()
        }),
        Flag::Year => read_date_field(task, DateField::Due).is_some_and(|date| {
            let t = today_midnight(now);
            let soy = Utc
                .with_ymd_and_hms(now.year(), 1, 1, 0, 0, 0)
                .single()
                .unwrap_or(t);
            let eoy = Utc
                .with_ymd_and_hms(now.year(), 12, 31, 23, 59, 59)
                .single()
                .unwrap_or(t);
            date.date_naive() >= soy.date_naive() && date.date_naive() <= eoy.date_naive()
        }),
        Flag::Uda => task.get_user_defined_attributes().count() > 0,
        Flag::Orphan => task.get_user_defined_attributes().any(|(k, _)| {
            !k.starts_with("annotation_") && !k.starts_with("tag_") && !k.starts_with("dep_")
        }),
    }
}

fn today_midnight(now: DateTime<Utc>) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(now.year(), now.month(), now.day(), 0, 0, 0)
        .single()
        .unwrap_or(now)
}

fn read_date_field(task: &taskchampion::Task, field: DateField) -> Option<DateTime<Utc>> {
    match field {
        DateField::Due => task.get_due(),
        DateField::Wait => task.get_wait(),
        DateField::Entry => task.get_entry(),
        DateField::Modified => task.get_modified(),
        DateField::Scheduled => parse_iso_value(
            task.get_value("scheduled")
                .or_else(|| task.get_value("sched")),
        ),
        DateField::Start => parse_iso_value(task.get_value("start")),
        DateField::End => parse_iso_value(task.get_value("end")),
        DateField::Until => parse_iso_value(task.get_value("until")),
    }
}

fn parse_iso_value(value: Option<&str>) -> Option<DateTime<Utc>> {
    let raw = value?;
    DateTime::parse_from_rfc3339(raw)
        .ok()
        .map(|parsed| parsed.with_timezone(&Utc))
}

fn is_waiting_at(task: &taskchampion::Task, now: DateTime<Utc>) -> bool {
    if task.is_waiting() {
        return true;
    }
    read_date_field(task, DateField::Wait).is_some_and(|wait| wait > now)
}

fn is_scheduled_future(task: &taskchampion::Task, now: DateTime<Utc>) -> bool {
    read_date_field(task, DateField::Scheduled).is_some_and(|scheduled| scheduled > now)
}

fn plain_text_match(task: &taskchampion::Task, term: &str) -> bool {
    let term = term.to_lowercase();
    let description = task.get_description().to_lowercase();
    if description.contains(&term) {
        return true;
    }
    let project = task.get_value("project").unwrap_or("").to_lowercase();
    if project.contains(&term) {
        return true;
    }
    if task
        .get_tags()
        .any(|tag| tag.to_string().to_lowercase().contains(&term))
    {
        return true;
    }
    if task
        .get_annotations()
        .any(|ann| ann.description.to_lowercase().contains(&term))
    {
        return true;
    }
    if task
        .get_user_defined_attributes()
        .any(|(k, v)| k.to_lowercase().contains(&term) || v.to_lowercase().contains(&term))
    {
        return true;
    }
    false
}

struct Parser {
    tokens: Vec<String>,
    index: usize,
}

impl Parser {
    fn new(tokens: Vec<String>) -> Self {
        Self { tokens, index: 0 }
    }

    fn parse(&mut self) -> Option<Expr> {
        self.parse_or()
    }

    fn parse_or(&mut self) -> Option<Expr> {
        let first = self.parse_xor()?;
        let mut parts = vec![first];
        while self.peek_is_or() {
            self.index += 1;
            match self.parse_xor() {
                Some(rhs) => parts.push(rhs),
                None => break,
            }
        }
        if parts.len() == 1 {
            parts.into_iter().next()
        } else {
            Some(Expr::Or(parts))
        }
    }

    fn parse_xor(&mut self) -> Option<Expr> {
        let first = self.parse_and()?;
        let mut parts = vec![first];
        while self.peek_is_xor() {
            self.index += 1;
            match self.parse_and() {
                Some(rhs) => parts.push(rhs),
                None => break,
            }
        }
        if parts.len() == 1 {
            parts.into_iter().next()
        } else {
            Some(Expr::Xor(parts))
        }
    }

    fn parse_and(&mut self) -> Option<Expr> {
        let mut parts = Vec::new();
        while let Some(token) = self.peek() {
            if token == ")" || self.peek_is_or() || self.peek_is_xor() {
                break;
            }
            if self.peek_is_and() {
                self.index += 1;
                continue;
            }
            let part = self.parse_unary()?;
            parts.push(part);
        }
        if parts.is_empty() {
            None
        } else if parts.len() == 1 {
            parts.into_iter().next()
        } else {
            Some(Expr::And(parts))
        }
    }

    fn parse_unary(&mut self) -> Option<Expr> {
        let token = self.peek()?.to_string();
        if token == "(" {
            self.index += 1;
            let inner = self.parse_or();
            if self.peek().is_some_and(|t| t == ")") {
                self.index += 1;
            }
            return inner;
        }

        if self.peek_is_not() {
            self.index += 1;
            let child = self.parse_unary()?;
            return Some(Expr::Not(Box::new(child)));
        }

        if token.starts_with('-') && token.len() > 1 {
            self.index += 1;
            return Some(Expr::Not(Box::new(Expr::Term(parse_term(&token[1..])))));
        }

        if token.starts_with('!') && token.len() > 1 {
            self.index += 1;
            return Some(Expr::Not(Box::new(Expr::Term(parse_term(&token[1..])))));
        }

        if token.starts_with('+') && token.len() > 1 {
            self.index += 1;
            let payload = &token[1..];
            if let Some(status) = parse_status(payload) {
                return Some(Expr::Term(Term::Status(status)));
            }
            if let Some(flag) = parse_flag(payload) {
                return Some(Expr::Term(Term::Flag(flag)));
            }
            return Some(Expr::Term(Term::Tag(payload.to_string())));
        }

        self.index += 1;
        Some(Expr::Term(parse_term(&token)))
    }

    fn peek(&self) -> Option<&str> {
        self.tokens.get(self.index).map(|t| t.as_str())
    }

    fn peek_is_or(&self) -> bool {
        matches!(self.peek(), Some("or") | Some("OR") | Some("||"))
    }

    fn peek_is_and(&self) -> bool {
        matches!(self.peek(), Some("and") | Some("AND") | Some("&&"))
    }

    fn peek_is_xor(&self) -> bool {
        matches!(self.peek(), Some("xor") | Some("XOR"))
    }

    fn peek_is_not(&self) -> bool {
        matches!(self.peek(), Some("not") | Some("NOT") | Some("!"))
    }
}

fn parse_term(token: &str) -> Term {
    if let Some(term) = parse_comparison(token) {
        return term;
    }

    if let Some(pattern) = token.strip_prefix("__pattern__") {
        return Term::Pattern(pattern.to_string());
    }

    if let Some((raw_key, raw_value)) = token.split_once(':') {
        let key = canonical_key(raw_key);
        let value = strip_quotes(raw_value);

        // Handle key.not:value → Negated(Term)
        if let Some(not_key) = key.strip_suffix(".not") {
            let inner = parse_term(&format!("{not_key}:{value}"));
            return Term::Negated(Box::new(inner));
        }

        // Handle key.has:value / key.hasnt:value / key.startswith:value / key.endswith:value / key.contains:value / key.isnt:value
        if let Some((base_key, modifier)) = key.rsplit_once('.') {
            let op = match modifier {
                "has" => Some(StrOp::Has),
                "hasnt" => Some(StrOp::Hasnt),
                "startswith" => Some(StrOp::StartsWith),
                "endswith" => Some(StrOp::EndsWith),
                "contains" => Some(StrOp::Contains),
                "isnt" => Some(StrOp::Isnt),
                _ => None,
            };
            if let Some(op) = op {
                return Term::StrMatch {
                    key: base_key.to_string(),
                    op,
                    value,
                };
            }
        }

        // Handle tags.none: / project.none: / priority.above: / priority.below:
        if let Some((base_key, modifier)) = key.rsplit_once('.') {
            let canonical_base = canonical_key(base_key);
            match modifier {
                "none" => match canonical_base.as_str() {
                    "tag" | "tags" => return Term::TagNone,
                    "project" => return Term::Project("none".to_string()),
                    _ => {}
                },
                "any" => match canonical_base.as_str() {
                    "tag" | "tags" => return Term::TagAny,
                    _ => {}
                },
                "above" | "over" => {
                    if canonical_base == "priority" {
                        return Term::Compare {
                            key: "priority".to_string(),
                            op: CompareOp::Gt,
                            value: value.to_string(),
                        };
                    }
                    if parse_date_field(&canonical_base).is_some() {
                        if let Some(term) = parse_date_term(&key, &value) {
                            return term;
                        }
                    }
                }
                "below" | "under" => {
                    if canonical_base == "priority" {
                        return Term::Compare {
                            key: "priority".to_string(),
                            op: CompareOp::Lt,
                            value: value.to_string(),
                        };
                    }
                    if parse_date_field(&canonical_base).is_some() {
                        if let Some(term) = parse_date_term(&key, &value) {
                            return term;
                        }
                    }
                }
                _ => {}
            }
        }

        match key.as_str() {
            "project" => return Term::Project(value),
            "tag" | "tags" => {
                return match value.to_ascii_lowercase().as_str() {
                    "none" => Term::TagNone,
                    "any" => Term::TagAny,
                    _ => Term::Tag(value),
                };
            }
            "status" => {
                if let Some(status) = parse_status(&value) {
                    return Term::Status(status);
                }
            }
            "priority" => return Term::Priority(value),
            "uuid" => return Term::UuidPrefix(value),
            "wait" if value.eq_ignore_ascii_case("someday") => return Term::Flag(Flag::Someday),
            _ if parse_date_field(key.split('.').next().unwrap_or(&key)).is_some() => {
                if let Some(term) = parse_date_term(&key, &value) {
                    return term;
                }
            }
            _ => {}
        }

        if key == "description" || key == "desc" {
            return Term::Text(value);
        }
        if key.starts_with("uda.") && key.len() > 4 {
            return Term::Uda {
                key: key[4..].to_string(),
                value,
            };
        }
    }

    // Handle field.none / field.any / tags.none / project.none without colon (e.g. due.none, tags.none)
    if let Some(dot_pos) = token.find('.') {
        let field_part = &token[..dot_pos];
        let op_part = &token[dot_pos + 1..];
        match op_part {
            "none" => {
                if let Some(field) = parse_date_field(field_part) {
                    return Term::Date {
                        field,
                        op: DateOp::None,
                        value: None,
                    };
                }
                let canonical = canonical_key(field_part);
                match canonical.as_str() {
                    "tag" | "tags" => return Term::TagNone,
                    "project" => return Term::Project("none".to_string()),
                    _ => {}
                }
            }
            "any" => {
                if let Some(field) = parse_date_field(field_part) {
                    return Term::Date {
                        field,
                        op: DateOp::Any,
                        value: None,
                    };
                }
                let canonical = canonical_key(field_part);
                match canonical.as_str() {
                    "tag" | "tags" => return Term::TagAny,
                    _ => {}
                }
            }
            _ => {}
        }
    }

    if let Some(status) = parse_status(token) {
        return Term::Status(status);
    }
    if let Some(flag) = parse_flag(token) {
        return Term::Flag(flag);
    }
    if looks_like_uuid(token) {
        return Term::Uuid(token.to_string());
    }
    Term::Text(strip_quotes(token))
}

fn parse_comparison(token: &str) -> Option<Term> {
    let (raw_key, op_token, raw_value) = if let Some((left, right)) = token.split_once("!==") {
        (left, "!==", right)
    } else if let Some((left, right)) = token.split_once("!=") {
        (left, "!=", right)
    } else if let Some((left, right)) = token.split_once("==") {
        (left, "==", right)
    } else if let Some((left, right)) = token.split_once("<=") {
        (left, "<=", right)
    } else if let Some((left, right)) = token.split_once(">=") {
        (left, ">=", right)
    } else if let Some((left, right)) = token.split_once('<') {
        (left, "<", right)
    } else if let Some((left, right)) = token.split_once('>') {
        (left, ">", right)
    } else if let Some((left, right)) = token.split_once('=') {
        (left, "=", right)
    } else {
        return None;
    };

    let key = canonical_key(raw_key);

    if let Some(field) = parse_date_field(&key) {
        let op = match op_token {
            "<" => DateOp::Before,
            "<=" => DateOp::BeforeEq,
            ">" => DateOp::After,
            ">=" => DateOp::AfterEq,
            "=" | "==" => DateOp::On,
            _ => DateOp::On,
        };
        let value = parse_date_expr(raw_value.trim())?;
        return Some(Term::Date {
            field,
            op,
            value: Some(value),
        });
    }

    match op_token {
        "==" => Some(Term::Equals {
            key,
            value: raw_value.trim().to_string(),
        }),
        "!=" => Some(Term::NotEquals {
            key,
            value: raw_value.trim().to_string(),
        }),
        "!==" => Some(Term::StrictNotEquals {
            key,
            value: raw_value.trim().to_string(),
        }),
        "=" => Some(Term::Equals {
            key: key.clone(),
            value: raw_value.trim().to_string(),
        }),
        ">" | "<" | ">=" | "<=" => {
            let value = raw_value.trim().to_string();
            let op = match op_token {
                ">" => CompareOp::Gt,
                "<" => CompareOp::Lt,
                ">=" => CompareOp::GtEq,
                "<=" => CompareOp::LtEq,
                _ => unreachable!(),
            };
            Some(Term::Compare { key, op, value })
        }
        _ => None,
    }
}

fn parse_date_term(key: &str, value: &str) -> Option<Term> {
    let (field_name, op_name) = if let Some((field, op)) = key.split_once('.') {
        (field, op)
    } else {
        (key, "on")
    };

    let field = parse_date_field(field_name)?;
    let op = match op_name {
        "before" | "under" | "below" => DateOp::Before,
        "beforeeq" | "by" => DateOp::BeforeEq,
        "after" | "over" | "above" => DateOp::After,
        "aftereq" => DateOp::AfterEq,
        "on" => match value.to_ascii_lowercase().as_str() {
            "none" => DateOp::None,
            "any" => DateOp::Any,
            _ => DateOp::On,
        },
        "none" => DateOp::None,
        "any" => DateOp::Any,
        _ => DateOp::On,
    };
    // Handle due.not:date as DateOp::On (same equality), negate at Term level
    let field_name_str = field_name.to_string();
    if op_name == "not" {
        let inner = parse_date_term(&field_name_str, value)?;
        return Some(Term::Negated(Box::new(inner)));
    }
    let parsed_value = match op {
        DateOp::None | DateOp::Any => None,
        _ => Some(parse_date_expr(value)?),
    };
    Some(Term::Date {
        field,
        op,
        value: parsed_value,
    })
}

fn parse_date_field(key: &str) -> Option<DateField> {
    match key {
        "due" => Some(DateField::Due),
        "wait" => Some(DateField::Wait),
        "scheduled" => Some(DateField::Scheduled),
        "entry" => Some(DateField::Entry),
        "modified" => Some(DateField::Modified),
        "start" => Some(DateField::Start),
        "end" => Some(DateField::End),
        "until" => Some(DateField::Until),
        _ => None,
    }
}

fn parse_date_expr(raw: &str) -> Option<DateTime<Utc>> {
    let value = raw.trim().to_ascii_lowercase();
    let now = Utc::now();
    let today = Utc
        .with_ymd_and_hms(now.year(), now.month(), now.day(), 0, 0, 0)
        .single()?;

    match value.as_str() {
        "today" => return Some(today),
        "tomorrow" => return Some(today + Duration::days(1)),
        "yesterday" => return Some(today - Duration::days(1)),
        "now" => return Some(now),
        "sow" => {
            let shift = now.weekday().num_days_from_monday() as i64;
            return Some(today - Duration::days(shift));
        }
        "eow" => {
            let shift = 6 - now.weekday().num_days_from_monday() as i64;
            return Some(
                today
                    + Duration::days(shift)
                    + Duration::hours(23)
                    + Duration::minutes(59)
                    + Duration::seconds(59),
            );
        }
        "som" => {
            return Utc
                .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
                .single();
        }
        "eom" => {
            let (y, m) = if now.month() == 12 {
                (now.year() + 1, 1)
            } else {
                (now.year(), now.month() + 1)
            };
            let next_month = Utc.with_ymd_and_hms(y, m, 1, 0, 0, 0).single()?;
            return Some(next_month - Duration::seconds(1));
        }
        "soy" => return Utc.with_ymd_and_hms(now.year(), 1, 1, 0, 0, 0).single(),
        "eoy" => {
            return Utc
                .with_ymd_and_hms(now.year(), 12, 31, 23, 59, 59)
                .single();
        }
        _ => {}
    }

    if let Some(caps) = parse_relative(&value) {
        let (amount, unit) = caps;
        let relative = match unit {
            'd' => today + Duration::days(amount),
            'w' => today + Duration::weeks(amount),
            'h' => now + Duration::hours(amount),
            'n' => now + Duration::minutes(amount),
            's' => now + Duration::seconds(amount),
            'q' => {
                let mut year = now.year();
                let mut month = now.month() as i32 + amount as i32 * 3;
                while month > 12 {
                    month -= 12;
                    year += 1;
                }
                while month < 1 {
                    month += 12;
                    year -= 1;
                }
                let max_day = days_in_month(year, month as u32);
                let day = now.day().min(max_day);
                Utc.with_ymd_and_hms(year, month as u32, day, 0, 0, 0)
                    .single()
                    .unwrap_or(today)
            }
            'm' => {
                let mut year = now.year();
                let mut month = now.month() as i32 + amount as i32;
                while month > 12 {
                    month -= 12;
                    year += 1;
                }
                while month < 1 {
                    month += 12;
                    year -= 1;
                }
                let max_day = days_in_month(year, month as u32);
                let day = now.day().min(max_day);
                Utc.with_ymd_and_hms(year, month as u32, day, 0, 0, 0)
                    .single()
                    .unwrap_or(today)
            }
            'y' => {
                let target_year = now.year() + amount as i32;
                let max_day = days_in_month(target_year, now.month());
                let day = now.day().min(max_day);
                Utc.with_ymd_and_hms(target_year, now.month(), day, 0, 0, 0)
                    .single()
                    .unwrap_or(today)
            }
            _ => today,
        };
        return Some(relative);
    }

    if let Ok(naive) = NaiveDate::parse_from_str(raw, "%Y-%m-%d") {
        return Utc
            .with_ymd_and_hms(naive.year(), naive.month(), naive.day(), 0, 0, 0)
            .single();
    }

    DateTime::parse_from_rfc3339(raw)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
                29
            } else {
                28
            }
        }
        _ => 30,
    }
}

fn parse_relative(value: &str) -> Option<(i64, char)> {
    if value.len() < 2 {
        return None;
    }

    let lower = value.to_ascii_lowercase();

    for (suffix, unit) in [
        ("hours", 'h'),
        ("hrs", 'h'),
        ("minutes", 'n'),
        ("mins", 'n'),
        ("min", 'n'),
        ("mn", 'n'),
        ("seconds", 's'),
        ("secs", 's'),
        ("weeks", 'w'),
        ("ws", 'w'),
        ("months", 'm'),
        ("mths", 'm'),
        ("quarters", 'q'),
        ("qtrs", 'q'),
        ("years", 'y'),
        ("yrs", 'y'),
    ] {
        if lower.ends_with(suffix) {
            let num_part = &value[..value.len() - suffix.len()];
            if let Ok(amount) = num_part.parse::<i64>() {
                return Some((amount, unit));
            }
        }
    }

    let unit = value.chars().last()?;
    if !matches!(unit, 'd' | 'w' | 'm' | 'y' | 'h' | 'n' | 's' | 'q') {
        return None;
    }
    let number = &value[..value.len() - 1];
    let amount = number.parse::<i64>().ok()?;
    Some((amount, unit))
}

fn is_virtual_tag_name(tag: &str) -> bool {
    matches!(
        tag,
        "BLOCKED"
            | "UNBLOCKED"
            | "BLOCKING"
            | "DUE"
            | "DUETODAY"
            | "TODAY"
            | "OVERDUE"
            | "WEEK"
            | "MONTH"
            | "QUARTER"
            | "YEAR"
            | "ACTIVE"
            | "SCHEDULED"
            | "PARENT"
            | "CHILD"
            | "UNTIL"
            | "WAITING"
            | "ANNOTATED"
            | "READY"
            | "YESTERDAY"
            | "TOMORROW"
            | "TAGGED"
            | "PENDING"
            | "COMPLETED"
            | "DELETED"
            | "UDA"
            | "ORPHAN"
            | "PRIORITY"
            | "PROJECT"
            | "LATEST"
            | "INSTANCE"
    )
}

fn looks_like_uuid(token: &str) -> bool {
    let t = token.replace('-', "");
    let len = t.len();
    if !(8..=32).contains(&len) {
        return false;
    }
    t.chars().all(|c| c.is_ascii_hexdigit())
}

fn parse_status(value: &str) -> Option<TaskStatus> {
    match value.to_ascii_lowercase().as_str() {
        "pending" => Some(TaskStatus::Pending),
        "completed" | "done" | "complete" => Some(TaskStatus::Completed),
        "deleted" => Some(TaskStatus::Deleted),
        "recurring" => Some(TaskStatus::Recurring),
        _ => None,
    }
}

fn parse_flag(value: &str) -> Option<Flag> {
    match value.to_ascii_lowercase().as_str() {
        "ready" => Some(Flag::Ready),
        "active" => Some(Flag::Active),
        "due" => Some(Flag::Due),
        "duetoday" | "due.today" | "today" => Some(Flag::DueToday),
        "overdue" => Some(Flag::Overdue),
        "someday" => Some(Flag::Someday),
        "project" => Some(Flag::Project),
        "template" => Some(Flag::Template),
        "blocked" => Some(Flag::Blocked),
        "blocking" => Some(Flag::Blocking),
        "waiting" | "wait" => Some(Flag::Waiting),
        "priority" => Some(Flag::Priority),
        "until" => Some(Flag::Until),
        "instance" => Some(Flag::Instance),
        "latest" => Some(Flag::Latest),
        "tagged" => Some(Flag::Tagged),
        "unblocked" => Some(Flag::Unblocked),
        "annotated" => Some(Flag::Annotated),
        "scheduled" => Some(Flag::Scheduled),
        "tomorrow" => Some(Flag::Tomorrow),
        "yesterday" => Some(Flag::Yesterday),
        "week" => Some(Flag::Week),
        "month" => Some(Flag::Month),
        "quarter" => Some(Flag::Quarter),
        "year" => Some(Flag::Year),
        "uda" => Some(Flag::Uda),
        "orphan" => Some(Flag::Orphan),
        _ => None,
    }
}

fn canonical_key(raw: &str) -> String {
    match raw.to_ascii_lowercase().as_str() {
        "pro" | "proj" => "project".to_string(),
        "pri" => "priority".to_string(),
        "stat" => "status".to_string(),
        "id" => "uuid".to_string(),
        other => other.to_string(),
    }
}

fn strip_quotes(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.len() < 2 {
        return trimmed.to_string();
    }
    let bytes = trimmed.as_bytes();
    if (bytes.first() == Some(&b'"') && bytes.last() == Some(&b'"'))
        || (bytes.first() == Some(&b'\'') && bytes.last() == Some(&b'\''))
    {
        return trimmed[1..trimmed.len() - 1].to_string();
    }
    trimmed.to_string()
}

fn tokenize(input: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut buffer = String::new();
    let mut quote: Option<char> = None;
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;

    let flush = |tokens: &mut Vec<String>, buffer: &mut String| {
        if !buffer.is_empty() {
            tokens.push(std::mem::take(buffer));
        }
    };

    while i < chars.len() {
        let ch = chars[i];
        if let Some(q) = quote {
            if ch == q {
                quote = None;
            } else {
                buffer.push(ch);
            }
            i += 1;
            continue;
        }

        if ch == '"' || ch == '\'' {
            quote = Some(ch);
            i += 1;
            continue;
        }
        if ch == '/' && buffer.is_empty() {
            let start = i + 1;
            if let Some(end) = chars[start..].iter().position(|&c| c == '/') {
                let pattern = chars[start..start + end].iter().collect::<String>();
                if !pattern.is_empty() {
                    flush(&mut tokens, &mut buffer);
                    tokens.push(format!("__pattern__{pattern}"));
                    i = start + end + 1;
                    continue;
                }
            }
        }
        if ch == '(' || ch == ')' {
            flush(&mut tokens, &mut buffer);
            tokens.push(ch.to_string());
            i += 1;
            continue;
        }
        if ch == '&' && i + 1 < chars.len() && chars[i + 1] == '&' {
            flush(&mut tokens, &mut buffer);
            tokens.push("&&".to_string());
            i += 2;
            continue;
        }
        if ch == '|' && i + 1 < chars.len() && chars[i + 1] == '|' {
            flush(&mut tokens, &mut buffer);
            tokens.push("||".to_string());
            i += 2;
            continue;
        }
        if ch.is_whitespace() {
            flush(&mut tokens, &mut buffer);
            i += 1;
            continue;
        }
        buffer.push(ch);
        i += 1;
    }

    if !buffer.is_empty() {
        tokens.push(buffer);
    }
    tokens
}

fn merge_comparison_tokens(tokens: Vec<String>) -> Vec<String> {
    let ops = ["==", "!=", "<=", ">=", "<", ">", "="];
    let mut result = Vec::with_capacity(tokens.len());
    let mut i = 0;
    while i < tokens.len() {
        if i + 2 < tokens.len() {
            let left = &tokens[i];
            let mid = &tokens[i + 1];
            let right = &tokens[i + 2];
            if ops.contains(&mid.as_str())
                && !left.starts_with('+')
                && !left.starts_with('-')
                && left != "("
                && left != ")"
                && !matches!(left.as_str(), "and" | "AND" | "or" | "OR" | "not" | "NOT")
                && !right.starts_with('(')
                && !matches!(right.as_str(), "and" | "AND" | "or" | "OR" | "not" | "NOT")
            {
                result.push(format!("{left}{mid}{right}"));
                i += 3;
                continue;
            }
        }
        result.push(tokens[i].clone());
        i += 1;
    }
    result
}

fn merge_colon_tokens(tokens: Vec<String>) -> Vec<String> {
    let mut result = Vec::with_capacity(tokens.len());
    let mut i = 0;
    while i < tokens.len() {
        if tokens[i].ends_with(':') && i + 1 < tokens.len() {
            let next = &tokens[i + 1];
            if !matches!(
                next.as_str(),
                "(" | ")" | "&&" | "||" | "and" | "AND" | "or" | "OR" | "not" | "NOT" | "!"
            ) {
                result.push(format!("{}{}", tokens[i], next));
                i += 2;
                continue;
            }
        }
        result.push(tokens[i].clone());
        i += 1;
    }
    result
}

pub(crate) fn task_with(fields: &[(&str, &str)]) -> taskchampion::Task {
    use std::str::FromStr;
    use taskchampion::Tag;

    let mut replica = taskchampion::Replica::new(
        taskchampion::StorageConfig::InMemory
            .into_storage()
            .unwrap(),
    );
    let mut ops = taskchampion::Operations::new();
    let uuid = taskchampion::Uuid::new_v4();
    let mut task = replica.create_task(uuid, &mut ops).unwrap();
    task.set_description("test task".into(), &mut ops).unwrap();
    task.set_status(taskchampion::Status::Pending, &mut ops)
        .unwrap();
    task.set_entry(Some(Utc::now()), &mut ops).unwrap();

    for (key, value) in fields {
        match *key {
            "due" => {
                let dt = DateTime::parse_from_rfc3339(value)
                    .unwrap()
                    .with_timezone(&Utc);
                task.set_due(Some(dt), &mut ops).unwrap();
            }
            "wait" => {
                let dt = DateTime::parse_from_rfc3339(value)
                    .unwrap()
                    .with_timezone(&Utc);
                task.set_wait(Some(dt), &mut ops).unwrap();
            }
            "scheduled" => {
                let dt = DateTime::parse_from_rfc3339(value)
                    .unwrap()
                    .with_timezone(&Utc);
                task.set_value("scheduled", Some(dt.to_rfc3339()), &mut ops)
                    .unwrap();
            }
            "project" => {
                task.set_value("project", Some(value.to_string()), &mut ops)
                    .unwrap();
            }
            "priority" => task.set_priority(value.to_string(), &mut ops).unwrap(),
            "tag" => {
                let tag: Tag = FromStr::from_str(value).unwrap();
                task.add_tag(&tag, &mut ops).unwrap();
            }
            "status" => {
                let status = match *value {
                    "pending" => taskchampion::Status::Pending,
                    "completed" => taskchampion::Status::Completed,
                    "deleted" => taskchampion::Status::Deleted,
                    _ => panic!("unknown status: {value}"),
                };
                task.set_status(status, &mut ops).unwrap();
            }
            "description" => task.set_description(value.to_string(), &mut ops).unwrap(),
            _ => {}
        }
    }

    replica.commit_operations(ops).unwrap();
    replica.get_task(uuid).unwrap().unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_expr(query: &str) -> Option<Expr> {
        let tokens = merge_colon_tokens(tokenize(query));
        let mut parser = Parser::new(tokens);
        parser.parse()
    }

    #[test]
    fn plus_completed_maps_to_status_term() {
        let expr = parse_expr("+COMPLETED").expect("expression should parse");
        match expr {
            Expr::Term(Term::Status(TaskStatus::Completed)) => {}
            other => panic!("expected completed status term, got {other:?}"),
        }
    }

    #[test]
    fn wait_someday_maps_to_someday_flag() {
        let expr = parse_expr("wait:someday").expect("expression should parse");
        match expr {
            Expr::Term(Term::Flag(Flag::Someday)) => {}
            other => panic!("expected someday flag term, got {other:?}"),
        }
    }

    #[test]
    fn taskwarrior_style_queries_parse() {
        let examples = [
            "(+ACTIVE or +DUE or +OVERDUE) +READY",
            "(+READY +PROJECT) -DUE -DUETODAY -OVERDUE -ACTIVE",
            "(-COMPLETED -DELETED wait:someday)",
            "-COMPLETED -DELETED -TEMPLATE",
            "(+COMPLETED)",
            "-COMPLETED -DELETED -PROJECT",
        ];
        for example in examples {
            assert!(
                parse_expr(example).is_some(),
                "query example should parse: {example}"
            );
        }
    }

    #[test]
    fn status_query_forms_parse_to_status_terms() {
        for query in [
            "status:completed",
            "stat:deleted",
            "completed",
            "+COMPLETED",
        ] {
            let expr = parse_expr(query).expect("expression should parse");
            match expr {
                Expr::Term(Term::Status(TaskStatus::Completed | TaskStatus::Deleted)) => {}
                other => panic!("expected non-pending status term for {query}, got {other:?}"),
            }
        }
    }

    #[test]
    fn plus_due_matches_within_seven_day_window() {
        let now = taskchampion::chrono::Utc::now();
        let due_soon = task_with(&[
            (
                "due",
                &format!("{}", (now + chrono::Duration::days(6)).format("%+")),
            ),
            ("status", "pending"),
        ]);
        let due_later = task_with(&[
            (
                "due",
                &format!("{}", (now + chrono::Duration::days(8)).format("%+")),
            ),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&due_soon, "+DUE"),
            "task due within 7 days should match +DUE"
        );
        assert!(
            !matches_query(&due_later, "+DUE"),
            "task due after 7 days should not match +DUE"
        );
    }

    #[test]
    fn plus_ready_excludes_future_scheduled() {
        let now = taskchampion::chrono::Utc::now();
        let ready = task_with(&[("status", "pending")]);
        let future = task_with(&[
            (
                "scheduled",
                &format!("{}", (now + chrono::Duration::days(1)).format("%+")),
            ),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&ready, "+READY"),
            "pending task without schedule should be ready"
        );
        assert!(
            !matches_query(&future, "+READY"),
            "future scheduled task should not be ready"
        );
    }

    #[test]
    fn project_prefix_matching() {
        let task = task_with(&[("project", "area.personal.sub"), ("status", "pending")]);

        assert!(
            matches_query(&task, "project:area.personal"),
            "project prefix should match"
        );
        assert!(
            matches_query(&task, "project:area.personal.sub"),
            "exact project should match"
        );
        assert!(
            !matches_query(&task, "project:other"),
            "non-matching project should not match"
        );
    }

    #[test]
    fn invalid_query_falls_back_to_text_search() {
        let task = task_with(&[("description", "due:not-a-date"), ("status", "pending")]);

        assert!(
            matches_query(&task, "due:not-a-date"),
            "invalid date expression should fall back to text search"
        );
    }

    #[test]
    fn bare_iso_date_parses_as_date_term() {
        let expr = parse_expr("due:2026-06-20").expect("bare ISO date should parse");
        match expr {
            Expr::Term(Term::Date {
                field: DateField::Due,
                op: DateOp::On,
                value: Some(_),
            }) => {}
            other => panic!("expected Date term for due:2026-06-20, got {other:?}"),
        }
    }

    #[test]
    fn bare_iso_date_does_not_match_different_day() {
        let now = taskchampion::chrono::Utc::now();
        let yesterday = (now - chrono::Duration::days(1))
            .format("%Y-%m-%d")
            .to_string();
        let due_today = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            !matches_query(&due_today, &format!("due:{yesterday}")),
            "bare ISO date should not match task due on different day"
        );
    }

    #[test]
    fn date_field_modifier_before_parses() {
        let expr = parse_expr("due.before:tomorrow").expect("due.before should parse");
        match expr {
            Expr::Term(Term::Date {
                field: DateField::Due,
                op: DateOp::Before,
                value: Some(_),
            }) => {}
            other => panic!("expected Date Before term, got {other:?}"),
        }
    }

    #[test]
    fn date_field_modifier_after_parses() {
        let expr = parse_expr("due.after:yesterday").expect("due.after should parse");
        match expr {
            Expr::Term(Term::Date {
                field: DateField::Due,
                op: DateOp::After,
                value: Some(_),
            }) => {}
            other => panic!("expected Date After term, got {other:?}"),
        }
    }

    #[test]
    fn date_field_modifier_beforeeq_parses() {
        let expr = parse_expr("due.beforeeq:tomorrow").expect("due.beforeeq should parse");
        match expr {
            Expr::Term(Term::Date {
                field: DateField::Due,
                op: DateOp::BeforeEq,
                value: Some(_),
            }) => {}
            other => panic!("expected Date BeforeEq term, got {other:?}"),
        }
    }

    #[test]
    fn date_field_modifier_aftereq_parses() {
        let expr = parse_expr("due.aftereq:yesterday").expect("due.aftereq should parse");
        match expr {
            Expr::Term(Term::Date {
                field: DateField::Due,
                op: DateOp::AfterEq,
                value: Some(_),
            }) => {}
            other => panic!("expected Date AfterEq term, got {other:?}"),
        }
    }

    #[test]
    fn date_none_without_colon_matches_tasks_without_due() {
        let task_no_due = task_with(&[("status", "pending")]);
        let now = taskchampion::chrono::Utc::now();
        let task_with_due = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&task_no_due, "due.none"),
            "task without due should match due.none"
        );
        assert!(
            !matches_query(&task_with_due, "due.none"),
            "task with due should NOT match due.none"
        );
    }

    #[test]
    fn date_any_without_colon_matches_tasks_with_due() {
        let task_no_due = task_with(&[("status", "pending")]);
        let now = taskchampion::chrono::Utc::now();
        let task_with_due = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            !matches_query(&task_no_due, "due.any"),
            "task without due should NOT match due.any"
        );
        assert!(
            matches_query(&task_with_due, "due.any"),
            "task with due should match due.any"
        );
    }

    #[test]
    fn date_none_with_colon_matches_tasks_without_due() {
        let task_no_due = task_with(&[("status", "pending")]);
        let now = taskchampion::chrono::Utc::now();
        let task_with_due = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&task_no_due, "due:none"),
            "task without due should match due:none"
        );
        assert!(
            !matches_query(&task_with_due, "due:none"),
            "task with due should NOT match due:none"
        );
    }

    #[test]
    fn date_any_with_colon_matches_tasks_with_due() {
        let task_no_due = task_with(&[("status", "pending")]);
        let now = taskchampion::chrono::Utc::now();
        let task_with_due = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            !matches_query(&task_no_due, "due:any"),
            "task without due should NOT match due:any"
        );
        assert!(
            matches_query(&task_with_due, "due:any"),
            "task with due should match due:any"
        );
    }

    #[test]
    fn tags_any_matches_tasks_with_tags() {
        let task_no_tags = task_with(&[("status", "pending")]);
        let task_with_tags = task_with(&[("tag", "home"), ("status", "pending")]);

        assert!(
            !matches_query(&task_no_tags, "tags:any"),
            "task without tags should NOT match tags:any"
        );
        assert!(
            matches_query(&task_with_tags, "tags:any"),
            "task with tags should match tags:any"
        );
    }

    #[test]
    fn invalid_date_terms_still_fall_back_to_text() {
        match parse_term("due:not-a-date") {
            Term::Text(value) => assert_eq!(value, "due:not-a-date"),
            other => panic!("expected invalid date term to fall back to text, got {other:?}"),
        }

        match parse_term("due<=not-a-date") {
            Term::Text(value) => assert_eq!(value, "due<=not-a-date"),
            other => panic!("expected invalid comparison to fall back to text, got {other:?}"),
        }
    }

    #[test]
    fn not_equals_operator() {
        let task = task_with(&[("project", "Work"), ("status", "pending")]);

        assert!(
            matches_query(&task, "project!=Other"),
            "not-equals should match different"
        );
        assert!(
            !matches_query(&task, "project!=Work"),
            "not-equals should not match same"
        );
    }

    #[test]
    fn strict_not_equals_operator() {
        let task = task_with(&[("project", "Work"), ("status", "pending")]);

        assert!(
            matches_query(&task, "project!==other"),
            "strict not-equals should match different"
        );
        assert!(
            !matches_query(&task, "project!==Work"),
            "strict not-equals should not match same"
        );
    }

    #[test]
    fn due_by_modifier() {
        let now = taskchampion::chrono::Utc::now();
        let due_today = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&due_today, "due.by:tomorrow"),
            "due today should match due.by:tomorrow"
        );
        assert!(
            !matches_query(&due_today, "due.by:yesterday"),
            "due today should NOT match due.by:yesterday"
        );
    }

    #[test]
    fn due_under_below_aliases() {
        let now = taskchampion::chrono::Utc::now();
        let due_today = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&due_today, "due.under:tomorrow"),
            "due.under should work like before"
        );
        assert!(
            matches_query(&due_today, "due.below:tomorrow"),
            "due.below should work like before"
        );
    }

    #[test]
    fn due_over_above_aliases() {
        let now = taskchampion::chrono::Utc::now();
        let due_today = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&due_today, "due.over:yesterday"),
            "due.over should work like after"
        );
        assert!(
            matches_query(&due_today, "due.above:yesterday"),
            "due.above should work like after"
        );
    }

    #[test]
    fn flag_priority() {
        let task_pri = task_with(&[("priority", "H"), ("status", "pending")]);
        let task_no_pri = task_with(&[("status", "pending")]);

        assert!(
            matches_query(&task_pri, "+PRIORITY"),
            "task with priority should match +PRIORITY"
        );
        assert!(
            !matches_query(&task_no_pri, "+PRIORITY"),
            "task without priority should not match +PRIORITY"
        );
    }

    #[test]
    fn flag_tagged() {
        let task_no_tags = task_with(&[("status", "pending")]);
        let task_with_tags = task_with(&[("tag", "home"), ("status", "pending")]);

        assert!(
            matches_query(&task_with_tags, "+TAGGED"),
            "tagged task should match +TAGGED"
        );
        assert!(
            !matches_query(&task_no_tags, "+TAGGED"),
            "untagged task should not match +TAGGED"
        );
    }

    #[test]
    fn flag_annotated() {
        use taskchampion::Annotation;
        let mut replica = taskchampion::Replica::new(
            taskchampion::StorageConfig::InMemory
                .into_storage()
                .unwrap(),
        );
        let mut ops = taskchampion::Operations::new();
        let uuid = taskchampion::Uuid::new_v4();
        let mut task = replica.create_task(uuid, &mut ops).unwrap();
        task.set_description("test".into(), &mut ops).unwrap();
        task.set_status(TcStatus::Pending, &mut ops).unwrap();
        task.add_annotation(
            Annotation {
                entry: Utc::now(),
                description: "note".into(),
            },
            &mut ops,
        )
        .unwrap();
        replica.commit_operations(ops).unwrap();
        let task = replica.get_task(uuid).unwrap().unwrap();

        assert!(
            matches_query(&task, "+ANNOTATED"),
            "annotated task should match +ANNOTATED"
        );
    }

    #[test]
    fn flag_unblocked() {
        let task = task_with(&[("status", "pending")]);
        assert!(
            matches_query(&task, "+UNBLOCKED"),
            "non-blocked task should match +UNBLOCKED"
        );
    }

    #[test]
    fn extended_duration_units() {
        let now = taskchampion::chrono::Utc::now();
        let due_in_2h = task_with(&[
            (
                "due",
                &format!("{}", (now + chrono::Duration::hours(2)).format("%+")),
            ),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&due_in_2h, "due.before:3h"),
            "3h should be recognized as 3 hours"
        );
        assert!(
            !matches_query(&due_in_2h, "due.before:1h"),
            "1h should be recognized as 1 hour"
        );
    }

    #[test]
    fn flag_tomorrow() {
        let now = taskchampion::chrono::Utc::now();
        let tomorrow = now + chrono::Duration::days(1);
        let due_tomorrow = task_with(&[
            ("due", &format!("{}", tomorrow.format("%+"))),
            ("status", "pending"),
        ]);
        let due_today = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&due_tomorrow, "+TOMORROW"),
            "task due tomorrow should match +TOMORROW"
        );
        assert!(
            !matches_query(&due_today, "+TOMORROW"),
            "task due today should not match +TOMORROW"
        );
    }

    #[test]
    fn flag_yesterday() {
        let now = taskchampion::chrono::Utc::now();
        let yesterday = now - chrono::Duration::days(1);
        let due_yesterday = task_with(&[
            ("due", &format!("{}", yesterday.format("%+"))),
            ("status", "pending"),
        ]);
        let due_today = task_with(&[
            ("due", &format!("{}", now.format("%+"))),
            ("status", "pending"),
        ]);

        assert!(
            matches_query(&due_yesterday, "+YESTERDAY"),
            "task due yesterday should match +YESTERDAY"
        );
        assert!(
            !matches_query(&due_today, "+YESTERDAY"),
            "task due today should not match +YESTERDAY"
        );
    }
}
