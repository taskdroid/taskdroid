use super::models::TaskStatus;
use super::utils::map_tc_to_status;
use taskchampion::{
    Status as TcStatus,
    chrono::{DateTime, Datelike, Duration, TimeZone, Utc},
};

#[derive(Debug, Clone)]
enum Expr {
    And(Vec<Expr>),
    Or(Vec<Expr>),
    Not(Box<Expr>),
    Term(Term),
}

#[derive(Debug, Clone)]
enum Term {
    Text(String),
    Tag(String),
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
    Uda {
        key: String,
        value: String,
    },
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
}

const TASKWARRIOR_DEFAULT_DUE_DAYS: i64 = 7;

pub fn matches_query(task: &taskchampion::Task, query: &str) -> bool {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return true;
    }

    let tokens = merge_colon_tokens(tokenize(trimmed));
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
                .any(|existing| existing.to_string().to_lowercase() == lower_tag)
        }
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
        Term::Uda { key, value } => {
            let lower_value = value.to_lowercase();
            task.get_user_defined_attributes().any(|(k, v)| {
                k.eq_ignore_ascii_case(key) && v.to_lowercase().contains(&lower_value)
            })
        }
    }
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
            (Some(value), Some(target)) => value < target,
            _ => false,
        },
        DateOp::BeforeEq => match (task_value, target) {
            (Some(value), Some(target)) => value <= target,
            _ => false,
        },
        DateOp::After => match (task_value, target) {
            (Some(value), Some(target)) => value > target,
            _ => false,
        },
        DateOp::AfterEq => match (task_value, target) {
            (Some(value), Some(target)) => value >= target,
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
    }
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
        let first = self.parse_and()?;
        let mut parts = vec![first];
        while self.peek_is_or() {
            self.index += 1;
            match self.parse_and() {
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

    fn parse_and(&mut self) -> Option<Expr> {
        let mut parts = Vec::new();
        while let Some(token) = self.peek() {
            if token == ")" || self.peek_is_or() {
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

    fn peek_is_not(&self) -> bool {
        matches!(self.peek(), Some("not") | Some("NOT") | Some("!"))
    }
}

fn parse_term(token: &str) -> Term {
    if let Some(term) = parse_comparison(token) {
        return term;
    }

    if let Some((raw_key, raw_value)) = token.split_once(':') {
        let key = canonical_key(raw_key);
        let value = strip_quotes(raw_value);

        match key.as_str() {
            "project" => return Term::Project(value),
            "tag" | "tags" => return Term::Tag(value),
            "status" => {
                if let Some(status) = parse_status(&value) {
                    return Term::Status(status);
                }
            }
            "priority" => return Term::Priority(value),
            "uuid" => return Term::UuidPrefix(value),
            "wait" if value.eq_ignore_ascii_case("someday") => return Term::Flag(Flag::Someday),
            "due" | "wait" | "scheduled" | "entry" | "modified" | "start" | "end" | "until" => {
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

    if let Some(status) = parse_status(token) {
        return Term::Status(status);
    }
    if let Some(flag) = parse_flag(token) {
        return Term::Flag(flag);
    }
    Term::Text(strip_quotes(token))
}

fn parse_comparison(token: &str) -> Option<Term> {
    let (raw_key, op_token, raw_value) = if let Some((left, right)) = token.split_once("<=") {
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
    let field = parse_date_field(&key)?;
    let op = match op_token {
        "<" => DateOp::Before,
        "<=" => DateOp::BeforeEq,
        ">" => DateOp::After,
        ">=" => DateOp::AfterEq,
        "=" => DateOp::On,
        _ => DateOp::On,
    };
    let value = parse_date_expr(raw_value.trim())?;
    Some(Term::Date {
        field,
        op,
        value: Some(value),
    })
}

fn parse_date_term(key: &str, value: &str) -> Option<Term> {
    let (field_name, op_name) = if let Some((field, op)) = key.split_once('.') {
        (field, op)
    } else {
        (key, "on")
    };

    let field = parse_date_field(field_name)?;
    let op = match op_name {
        "before" => DateOp::Before,
        "beforeeq" => DateOp::BeforeEq,
        "after" => DateOp::After,
        "aftereq" => DateOp::AfterEq,
        "on" => DateOp::On,
        "none" => DateOp::None,
        "any" => DateOp::Any,
        _ => DateOp::On,
    };
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
    let unit = value.chars().last()?;
    if !matches!(unit, 'd' | 'w' | 'm' | 'y') {
        return None;
    }
    let number = &value[..value.len() - 1];
    let amount = number.parse::<i64>().ok()?;
    Some((amount, unit))
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
    fn invalid_date_terms_fall_back_to_text() {
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
}
