use crate::*;
use serde_json::Value;
use std::{fs, path::Path};
use unicode_width::UnicodeWidthStr;

#[derive(Debug, Default)]
pub struct Session {
    pub cost: Option<f64>,
    pub tokens: Option<f64>,
    pub partial: bool,
    pub tokens_estimated: bool,
    pub cost_estimated: bool,
    pub generating: bool,
}

fn sum_fields(value: &Value, fields: &[&str]) -> Option<f64> {
    fields
        .iter()
        .map(|f| number(&value[*f]))
        .collect::<Option<Vec<_>>>()
        .map(|v| v.iter().sum())
}
pub fn session_usage(home: &Path, payload: &Value) -> Session {
    let context = &payload["context_window"];
    let mut session = Session {
        cost: number(&payload["cost"]["total_cost_usd"]),
        tokens: sum_fields(context, &["session_input_tokens", "session_output_tokens"]).or_else(
            || {
                sum_fields(
                    &context["session_usage"],
                    &[
                        "input_tokens",
                        "output_tokens",
                        "cache_creation_input_tokens",
                        "cache_read_input_tokens",
                    ],
                )
            },
        ),
        partial: false,
        ..Session::default()
    };
    // Match the exact session; never guess from the newest ledger or read chat logs.
    let Some(ledger) = session_dir(home, s(&payload["session_id"]))
        .and_then(|dir| read_json(&dir.join("usage.json")).ok())
        .filter(|ledger| ledger["sessionId"] == payload["session_id"])
    else {
        return session;
    };
    let totals = &ledger["session"];
    let ledger_cost = number(&totals["costUsdTicks"]).map(|v| v / TICKS);
    let ledger_tokens = number(&totals["totalTokens"])
        .or_else(|| sum_fields(totals, &["inputTokens", "outputTokens"]));
    // Timer runs reuse Grok's last payload. Re-read the matching ledger even
    // when that payload is complete, and advance the paired totals together.
    let ledger_newer = ledger_tokens.zip(session.tokens).is_some_and(|(l, p)| {
        l > p || (l == p && ledger_cost.zip(session.cost).is_some_and(|(l, p)| l > p))
    });
    let fallback_cost = session.cost.is_none()
        && !session
            .tokens
            .zip(ledger_tokens)
            .is_some_and(|(p, l)| p > l);
    if fallback_cost || ledger_newer {
        session.cost = ledger_cost;
        session.partial = totals["costIsPartial"] == true || n(&totals["costMissingCalls"]) > 0.0;
    }
    if session.tokens.is_none() || ledger_newer || (fallback_cost && session.cost.is_some()) {
        // On resume Grok can omit cost and send zero process-local tokens.
        // When recovering ledger cost, recover the matching ledger tokens too.
        session.tokens = ledger_tokens.or(session.tokens);
    }
    session
}
pub fn money(value: Option<f64>) -> String {
    match value {
        Some(v) if v > 0.0 && v < 0.01 => format!("${v:.4}"),
        Some(v) => format!("${v:.2}"),
        None => "$--".into(),
    }
}
pub fn tokens(value: Option<f64>) -> String {
    let Some(value) = value else {
        return "--".into();
    };
    for (scale, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] {
        if value >= scale {
            return format!(
                "{}{suffix}",
                format!("{:.2}", value / scale)
                    .trim_end_matches('0')
                    .trim_end_matches('.')
            );
        }
    }
    format!("{value:.0}")
}
fn live_money(value: Option<f64>, estimated: bool) -> String {
    if estimated && let Some(value) = value {
        format!("≈${value:.4}")
    } else {
        money(value)
    }
}
fn live_tokens(value: Option<f64>, estimated: bool) -> String {
    if estimated && let Some(value) = value {
        format!("≈{}", tokens(Some(value)))
    } else {
        tokens(value)
    }
}
pub fn width(text: &str) -> usize {
    UnicodeWidthStr::width(text)
}
fn clip(text: &str, columns: usize) -> String {
    if width(text) <= columns {
        return text.into();
    }
    let mut out = String::new();
    for c in text.chars() {
        if width(&out) + unicode_width::UnicodeWidthChar::width(c).unwrap_or(0)
            > columns.saturating_sub(1)
        {
            break;
        }
        out.push(c);
    }
    out.push('…');
    out
}
/// claude-hud usage colors: red from 90%, bright magenta from 75%, else bright blue.
fn usage_code(percent: f64) -> u8 {
    if percent >= 90.0 {
        31
    } else if percent >= 75.0 {
        95
    } else {
        94
    }
}
/// claude-hud's countdown: `45m`, `2h 30m`, `3d 4h`, `3d`.
fn short_duration(seconds: f64) -> String {
    let minutes = (seconds / 60.0).ceil() as u64;
    if minutes < 60 {
        return format!("{minutes}m");
    }
    let hours = minutes / 60;
    let rest = minutes % 60;
    if hours >= 24 {
        if hours.is_multiple_of(24) {
            format!("{}d", hours / 24)
        } else {
            format!("{}d {}h", hours / 24, hours % 24)
        }
    } else if rest > 0 {
        format!("{hours}h {rest}m")
    } else {
        format!("{hours}h")
    }
}
fn short_seconds(value: f64) -> String {
    if value >= 10.0 {
        format!("{value:.0}")
    } else {
        format!("{value:.1}")
    }
}

/// One status line element: visible text plus color spans as byte ranges.
struct Element {
    text: String,
    ranges: Vec<(usize, usize, u8)>,
}
impl Element {
    fn plain(text: impl Into<String>) -> Self {
        Element {
            text: text.into(),
            ranges: Vec::new(),
        }
    }
    /// State text like 生成中 renders whole-dim.
    fn dimmed(text: impl Into<String>) -> Self {
        let text = text.into();
        let len = text.len();
        Element {
            text,
            ranges: vec![(0, len, DIM)],
        }
    }
}

/// Accumulates one element's text while recording value spans for coloring.
struct Painter(String, Vec<(usize, usize, u8)>);
impl Painter {
    fn new() -> Self {
        Painter(String::new(), Vec::new())
    }
    fn push(&mut self, text: &str) {
        self.0.push_str(text);
    }
    fn value(&mut self, text: &str, code: u8) {
        let start = self.0.len();
        self.0.push_str(text);
        self.1.push((start, self.0.len(), code));
    }
    fn finish(self) -> Element {
        Element {
            text: self.0,
            ranges: self.1,
        }
    }
}

const SEP: &str = " · ";
/// claude-hud's separator between elements sharing a line.
const JOIN: &str = " │ ";
/// claude-hud's separator between parts inside its usage element.
const PART: &str = " | ";
/// Dim, the color for transient state text like 生成中.
const DIM: u8 = 2;
/// Label palette by category: blue quantities (词元, 用量), cyan cache and
/// skills, green output and servers, yellow timing and limits, magenta money.
const BLUE: u8 = 94;
const CYAN: u8 = 96;
const GREEN: u8 = 92;
const YELLOW: u8 = 93;
const MAGENTA: u8 = 95;
/// Grok truncates the statusline past five lines.
const MAX_LINES: usize = 5;

fn session_elements(session: &Session) -> Vec<Element> {
    // Blue label (quantity), plain value.
    let mut p = Painter::new();
    p.value("词元 ", BLUE);
    p.push(&live_tokens(session.tokens, session.tokens_estimated));
    vec![p.finish()]
}

/// Cost: magenta label (money), plain amount.
fn cost_element(session: &Session) -> Element {
    let mut p = Painter::new();
    p.value("费用 ", MAGENTA);
    p.push(&live_money(session.cost, session.cost_estimated));
    if session.partial {
        p.push("*");
    }
    p.finish()
}

/// Environment counts: emoji icon, label, and number share the category color.
/// Icons must measure two cells (guarded by test) so folding matches the terminal.
fn environment_elements(environment: &environment::Environment) -> Vec<Element> {
    let mut out = Vec::new();
    if environment.skills > 0 {
        let mut p = Painter::new();
        p.value("⚡ 技能 ", CYAN);
        p.value(&environment.skills.to_string(), CYAN);
        out.push(p.finish());
    }
    if environment.mcp > 0 {
        let mut p = Painter::new();
        p.value("🔌 MCP ", GREEN);
        p.value(&environment.mcp.to_string(), GREEN);
        out.push(p.finish());
    }
    out
}

fn quota_elements(r: &Value) -> Vec<Element> {
    let usage = display_usage(r);
    let limit = if r["estimate"]["available"] == true {
        number(&r["estimate"]["usd"])
    } else {
        None
    };
    let token_limit = limit
        .zip(number(&r["local"]["totalTokens"]))
        .zip(number(&r["local"]["cost_usd"]))
        .filter(|((l, t), c)| *l > 0.0 && *t > 0.0 && *c > 0.0)
        .map(|((l, t), c)| t * l / c);
    let incomplete = ["unreadable_files", "undated_turns", "partial_cost_turns"]
        .iter()
        .any(|key| n(&usage[*key]) > 0.0);

    // claude-hud with its bar disabled: colored label, banded percent,
    // plain countdown parenthetical.
    let mut spent = Painter::new();
    spent.value("用量 ", BLUE);
    match number(&r["quota"]["used_percent"]) {
        Some(used) => spent.value(&format!("{used}%"), usage_code(used)),
        None => spent.value("--", DIM),
    }
    let mut notes: Vec<String> = Vec::new();
    if let Some(remaining) = timestamp(&r["quota"]["period_end"])
        .ok()
        .map(|end| end - now())
        .filter(|remaining| *remaining > 0.0)
    {
        notes.push(format!("重置剩余 {}", short_duration(remaining)));
    }
    if r["stale"] == true {
        notes.push("旧数据".into());
    }
    if !notes.is_empty() {
        spent.push(&format!(" ({})", notes.join(" · ")));
    }
    let spent = spent.finish();

    let mut local = Painter::new();
    local.value("本机 ", MAGENTA);
    local.push(&live_money(
        number(&usage["cost_usd"]),
        usage["cost_estimated"] == true,
    ));
    if incomplete {
        local.push("*");
    }
    local.push(SEP);
    local.push(&live_tokens(
        number(&usage["totalTokens"]),
        usage["tokens_estimated"] == true,
    ));
    local.push(" 词元");

    let mut weekly = Painter::new();
    weekly.value("周限 ", YELLOW);
    weekly.push(&format!(
        "{}{}",
        if limit.is_some() { "≈" } else { "" },
        money(limit)
    ));
    weekly.push(SEP);
    weekly.push(&format!(
        "{}{}",
        if token_limit.is_some() { "≈" } else { "" },
        tokens(token_limit)
    ));
    weekly.push(" 词元");

    vec![spent, local.finish(), weekly.finish()]
}

fn perf_elements(flow: &speed::Flow) -> Vec<Element> {
    let mut out = Vec::new();
    if let Some(cache) = flow.cache_rate {
        // Cyan label (cache), plain percent.
        let mut p = Painter::new();
        p.value("缓存率 ", CYAN);
        p.push(&format!("{:.1}%", (cache * 100.0).clamp(0.0, 100.0)));
        out.push(p.finish());
    }
    if let Some(value) = flow.speed {
        // Green label (output), plain speed value.
        let mut p = Painter::new();
        p.value("输出: ", GREEN);
        p.push(&format!(
            "{}{value:.1} tok/s",
            if flow.speed_approx { "≈" } else { "" }
        ));
        out.push(p.finish());
    }
    if let Some(value) = flow.ttft {
        // Yellow label (timing), plain seconds.
        let mut p = Painter::new();
        p.value("首字 ", YELLOW);
        p.push(&format!("{}s", short_seconds(value)));
        out.push(p.finish());
    }
    out
}

pub fn status_text(
    report: Option<&Value>,
    session: &Session,
    flow: &speed::Flow,
    environment: &environment::Environment,
    columns: usize,
    color: bool,
) -> String {
    let columns = columns.clamp(1, 500);
    // Layout mirrors claude-hud: a session line whose parts join with " │ "
    // like its project line and a usage line whose parts join with " | "
    // like its usage element. Every label carries its category color, values
    // stay plain, and the environment counts tint label and number alike;
    // the usage percent keeps its blue/magenta/red bands, the reset
    // countdown is a plain parenthetical, and 生成中 stays dim. Parts that
    // do not fit stack one per row, and the overflow folds into Grok's
    // five-line limit. Colors are injected after layout from per-element
    // spans, so merging and clipping only measure visible text.
    let mut elements = Vec::new();
    let mut groups: Vec<(usize, usize, &str)> = Vec::new();
    let start = elements.len();
    elements.extend(session_elements(session));
    elements.extend(perf_elements(flow));
    if session.generating {
        elements.push(Element::dimmed("生成中"));
    }
    elements.push(cost_element(session));
    // Zero counts hide; homes without skills or servers stay quiet.
    elements.extend(environment_elements(environment));
    groups.push((start, elements.len() - start, JOIN));
    let start = elements.len();
    if let Some(r) = report {
        elements.extend(quota_elements(r));
    } else {
        elements.push(Element::plain(
            "额度暂不可用 · 请运行 grok-budget.exe --refresh",
        ));
    }
    groups.push((start, elements.len() - start, PART));

    let mut rows: Vec<(Vec<usize>, &str)> = Vec::new();
    for (start, len, join) in groups {
        let mut row: Vec<usize> = Vec::new();
        let mut row_width = 0;
        for (index, element) in elements.iter().enumerate().skip(start).take(len) {
            let w = width(&element.text);
            if !row.is_empty() && row_width + width(join) + w > columns {
                rows.push((std::mem::take(&mut row), join));
                row_width = 0;
            }
            row_width += usize::from(!row.is_empty()) * width(join) + w;
            row.push(index);
        }
        if !row.is_empty() {
            rows.push((row, join));
        }
    }
    // Grok truncates past five lines; the overflow folds into one last row.
    if rows.len() > MAX_LINES {
        let overflow = rows.split_off(MAX_LINES - 1);
        // Each folded element keeps its own group's separator; a group
        // boundary inside the fold joins with the usage line's part.
        let pairs: Vec<(usize, &str)> = overflow
            .iter()
            .flat_map(|(row, join)| row.iter().map(|&index| (index, *join)))
            .collect();
        let mut text = String::new();
        let mut spans: Vec<(usize, usize, u8)> = Vec::new();
        for (position, &(index, join)) in pairs.iter().enumerate() {
            if position > 0 {
                text.push_str(if pairs[position - 1].1 == join {
                    join
                } else {
                    PART
                });
            }
            let base = text.len();
            let element = &elements[index];
            text.push_str(&element.text);
            spans.extend(
                element
                    .ranges
                    .iter()
                    .map(|(s, e, c)| (base + s, base + e, *c)),
            );
        }
        let join = pairs.last().map_or(PART, |&(_, join)| join);
        elements.push(Element {
            text,
            ranges: spans,
        });
        rows.push((vec![elements.len() - 1], join));
    }
    // A lone element wider than the terminal is clipped; spans fully inside the
    // retained prefix survive truncation, the rest is dropped. Byte offsets past
    // the prefix would cut into the appended ellipsis, so they must go.
    for row in &rows {
        if row.0.len() == 1
            && let Some(element) = elements.get_mut(row.0[0])
            && width(&element.text) > columns
        {
            let clipped = clip(&element.text, columns);
            let cut = clipped.strip_suffix('…').map_or(clipped.len(), str::len);
            element.ranges.retain(|(_, end, _)| *end <= cut);
            element.text = clipped;
        }
    }

    let mut out = String::new();
    for (index, row) in rows.iter().enumerate() {
        if index > 0 {
            out.push('\n');
        }
        let mut text = String::new();
        let mut spans: Vec<(usize, usize, u8)> = Vec::new();
        for (position, &element) in row.0.iter().enumerate() {
            if position > 0 {
                text.push_str(row.1);
            }
            let base = text.len();
            let element = &elements[element];
            text.push_str(&element.text);
            spans.extend(
                element
                    .ranges
                    .iter()
                    .map(|(s, e, c)| (base + s, base + e, *c)),
            );
        }
        if !color {
            out.push_str(&text);
            continue;
        }
        let mut cursor = 0;
        for (start, end, code) in spans {
            out.push_str(&text[cursor..start]);
            out.push_str(&format!("\x1b[{code}m{}\x1b[0m", &text[start..end]));
            cursor = end;
        }
        out.push_str(&text[cursor..]);
    }
    out
}
pub fn report_text(r: &Value) -> String {
    let q = &r["quota"];
    let u = display_usage(r);
    let e = &r["estimate"];
    let mut lines = vec![
        "Grok Build 用量 / 周额度".into(),
        format!("账户已用 {}%（服务端）", n(&q["used_percent"])),
    ];
    for p in q["products"].as_array().into_iter().flatten() {
        lines.push(format!(
            "{} 占比：{}",
            s(&p["product"]),
            number(&p["used_percent"])
                .map(|v| format!("{v}%"))
                .unwrap_or_else(|| "未知".into())
        ));
    }
    lines.push(format!(
        "周期：{} → {}",
        local_date(&q["period_start"], "%Y-%m-%d %H:%M:%S %Z"),
        local_date(&q["period_end"], "%Y-%m-%d %H:%M:%S %Z")
    ));
    lines.push(format!(
        "距离重置：{}",
        data::duration(timestamp(&q["period_end"]).unwrap_or(0.0) - now())
    ));
    lines.push(s(&r["projection"]["summary"]).into());
    lines.push(format!(
        "本机 ${:.4} / 预估周限 {}  {} 轮  {} 会话",
        n(&u["cost_usd"]),
        if e["available"] == true {
            money(number(&e["usd"]))
        } else {
            "未知".into()
        },
        n(&u["turns"]),
        n(&u["sessions"])
    ));
    let input = n(&u["inputTokens"]);
    let cached = n(&u["cachedReadTokens"]);
    let cache_rate = if input > 0.0 {
        format!("{:.1}", cached / input * 100.0)
    } else {
        "未知".into()
    };
    lines.push(format!(
        "输入 {input}（含缓存 {cached} · 缓存率 {cache_rate}%）  输出 {} Token",
        n(&u["outputTokens"])
    ));
    lines.push("官方美元及 Token 周上限：接口未公开".into());
    if e["available"] == true {
        lines.push(format!(
            "反推周限 ${:.4}（{}）；敏感区间 {} ～ {}",
            n(&e["usd"]),
            s(&e["confidence"]),
            money(number(&e["low_usd"])),
            number(&e["high_usd"])
                .map(|v| money(Some(v)))
                .unwrap_or_else(|| "无法约束上界".into())
        ));
    }
    lines.push(s(&e["reason"]).into());
    lines.push("模型成本（账本记录值，不是订阅实际扣款或官方单价）：".into());
    let mut models: Vec<_> = u["models"]
        .as_object()
        .into_iter()
        .flat_map(|v| v.iter())
        .collect();
    models.sort_by(|a, b| {
        n(&b.1["cost_usd"])
            .total_cmp(&n(&a.1["cost_usd"]))
            .then_with(|| a.0.cmp(b.0))
    });
    for (name, m) in models {
        lines.push(format!(
            "  {name}: ${:.4}  {} calls{}",
            n(&m["cost_usd"]),
            n(&m["calls"]),
            if m["partial"] == true {
                " [成本不完整]"
            } else {
                ""
            }
        ));
    }
    lines.push(format!(
        "采样：{}  {} 个样本  缓存 {} 秒",
        local_date(&r["sampled_at_iso"], "%Y-%m-%d %H:%M:%S"),
        n(&r["sample_count"]),
        n(&r["cache_age_seconds"])
    ));
    lines.push(format!(
        "去重 {} 轮  不可读账本 {}  无时间轮次 {}  不完整成本 {}",
        n(&u["duplicates"]),
        n(&u["unreadable_files"]),
        n(&u["undated_turns"]),
        n(&u["partial_cost_turns"])
    ));
    lines.push("仅统计本机已记录轮次；其他设备、未完成调用、Chat 和账户切换可能造成偏差。估算不是官方上限；敏感区间不是统计置信区间。".into());
    if r["stale"] == true {
        lines.push(format!("旧数据：{}", s(&r["error"])));
    }
    lines.join("\n")
}

pub fn display_usage(r: &Value) -> &Value {
    if r["live_local"].is_object() {
        &r["live_local"]
    } else {
        &r["local"]
    }
}
pub fn write_html(r: &Value, path: &Path) -> Result<()> {
    // Embed the template in the native executable; no runtime Python or asset lookup.
    let encoded = r
        .to_string()
        .replace('<', "\\u003c")
        .replace('&', "\\u0026");
    let html = include_str!("../grok-budget/report.html").replace("__REPORT_DATA__", &encoded);
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, html)?;
    Ok(())
}
