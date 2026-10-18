//! Generation metrics from Grok's internal per-chunk event log. `events.jsonl`
//! is undocumented and may change shape between Grok versions, so every miss
//! degrades to a hidden metric, never a fabricated number.
//!
//! Speed follows cc-Switch's window: output tokens over the time actually spent
//! streaming, first token to last chunk, excluding tool execution and the wait
//! before the first token. Turns under 100 output tokens are skipped as noise.
use crate::*;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    fs::File,
    io::{BufRead, BufReader, Read, Seek, SeekFrom},
    path::Path,
};

const MAX_TAIL: u64 = 16 * 1024 * 1024;
const MIN_TURN_OUTPUT_TOKENS: f64 = 100.0;
const MIN_GEN_SECONDS: f64 = 0.5;
const MAX_TPS: f64 = 5000.0;
/// Ledger settlement and the matching `turn_ended` event are the same instant.
const TURN_MATCH_SECONDS: f64 = 5.0;
/// Beyond this the open call is stale debris, not a live wait.
const MAX_TTFT_SECONDS: f64 = 600.0;

#[derive(Debug, Default)]
pub struct Flow {
    /// Session prompt-cache hit rate, 0.0–1.0.
    pub cache_rate: Option<f64>,
    /// Seconds from call start to the first streamed token; while the newest
    /// call still waits, the elapsed time so far.
    pub ttft: Option<f64>,
    /// Newest settled turn's output tokens per measured generation second.
    pub speed: Option<f64>,
    /// Billed reasoning tokens streamed outside the measured window.
    pub speed_approx: bool,
}

struct Call {
    start: f64,
    first_token: Option<f64>,
    last_chunk: Option<f64>,
    reasoning: bool,
}

struct Turn {
    start: Option<f64>,
    end: f64,
}

/// The only event fields the metrics need; unknown keys are skipped, and a
/// line that does not fit degrades the same way the full Value path did.
#[derive(Deserialize)]
struct Event {
    ts: String,
    #[serde(default)]
    r#type: String,
    #[serde(default)]
    phase: String,
}

fn parse_events(dir: &Path) -> Option<(Vec<Call>, Vec<Turn>)> {
    let Ok(mut file) = File::open(dir.join("events.jsonl")) else {
        return None;
    };
    let Ok(metadata) = file.metadata() else {
        return None;
    };
    let offset = metadata.len().saturating_sub(MAX_TAIL);
    if file.seek(SeekFrom::Start(offset)).is_err() {
        return None;
    }
    let mut reader = BufReader::new(file.take(metadata.len() - offset));
    let mut line = String::new();
    if offset > 0 && reader.read_line(&mut line).is_err() {
        return None;
    }
    let mut calls = Vec::new();
    let mut turns = Vec::new();
    let mut turn_start = None;
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        // An in-progress write is ignored; the next status run reads it whole.
        if !line.ends_with('\n') {
            break;
        }
        let Ok(event) = serde_json::from_str::<Event>(&line) else {
            continue;
        };
        let Ok(at) = timestamp(&json!(event.ts)) else {
            continue;
        };
        match event.r#type.as_str() {
            "loop_started" => calls.push(Call {
                start: at,
                first_token: None,
                last_chunk: None,
                reasoning: false,
            }),
            "first_token" => {
                if let Some(call) = calls.last_mut()
                    && call.first_token.is_none()
                {
                    call.first_token = Some(at);
                }
            }
            "phase_changed" => {
                if (event.phase == "streaming_reasoning" || event.phase == "streaming_text")
                    && let Some(call) = calls.last_mut()
                {
                    call.last_chunk = Some(at);
                    call.reasoning |= event.phase == "streaming_reasoning";
                }
            }
            "turn_started" => turn_start = Some(at),
            "turn_ended" => turns.push(Turn {
                start: turn_start.take(),
                end: at,
            }),
            _ => {}
        }
    }
    Some((calls, turns))
}

fn settled_speed(calls: &[Call], turns: &[Turn], ledger: Option<&Value>) -> Option<(f64, bool)> {
    // Billed output of the newest settled turn over the streaming time of its
    // calls. The window is bounded by turn_started, or the previous turn_ended
    // when the tail begins mid-turn; without either bound the sum is wrong.
    let ledger = ledger?;
    let (ended_at, turn) = ledger["turns"]
        .as_array()?
        .iter()
        .filter_map(|t| timestamp(&t["endedAt"]).ok().map(|at| (at, t)))
        .max_by(|a, b| a.0.total_cmp(&b.0))?;
    let output = number(&turn["outputTokens"])?;
    if output < MIN_TURN_OUTPUT_TOKENS {
        return None;
    }
    let window = turns
        .iter()
        .rev()
        .find(|t| (t.end - ended_at).abs() <= TURN_MATCH_SECONDS)?;
    let start = window.start.or_else(|| {
        turns
            .iter()
            .filter(|t| t.end < window.end)
            .map(|t| t.end)
            .max_by(|a, b| a.total_cmp(b))
    })?;
    let mut seconds = 0.0;
    let mut streamed_reasoning = false;
    for call in calls {
        // `>=`: a loop can share the window start's exact timestamp.
        if call.start >= start && call.start < window.end {
            if let (Some(first), Some(last)) = (call.first_token, call.last_chunk)
                && last > first
            {
                seconds += last - first;
            }
            streamed_reasoning |= call.reasoning;
        }
    }
    if seconds < MIN_GEN_SECONDS {
        return None;
    }
    let speed = output / seconds;
    if !(0.0..=MAX_TPS).contains(&speed) {
        return None;
    }
    let hidden_reasoning =
        number(&turn["reasoningTokens"]).unwrap_or(0.0) > 0.0 && !streamed_reasoning;
    Some((speed, hidden_reasoning))
}

fn time_to_first_token(calls: &[Call], now: f64) -> Option<f64> {
    let call = calls.last()?;
    let waited = match call.first_token {
        Some(first) => first - call.start,
        None => now - call.start,
    };
    (0.0..MAX_TTFT_SECONDS).contains(&waited).then_some(waited)
}

pub fn measure(home: &Path, payload: &Value) -> Flow {
    let mut flow = Flow::default();
    let dir = session_dir(home, s(&payload["session_id"]));
    let ledger = dir
        .as_deref()
        .and_then(|d| read_json(&d.join("usage.json")).ok())
        .filter(|l| l["sessionId"] == payload["session_id"]);
    // Ledger inputTokens already includes cachedReadTokens. The payload's three
    // buckets are disjoint and input_tokens is the uncached share, so the rates
    // agree once both sources exist.
    flow.cache_rate = ledger
        .as_ref()
        .map(|l| &l["session"])
        .and_then(|session| {
            number(&session["cachedReadTokens"]).zip(number(&session["inputTokens"]))
        })
        .and_then(|(cached, input)| (input > 0.0).then_some((cached / input).clamp(0.0, 1.0)))
        .or_else(|| {
            let usage = &payload["context_window"]["session_usage"];
            let total = n(&usage["cache_read_input_tokens"])
                + n(&usage["cache_creation_input_tokens"])
                + n(&usage["input_tokens"]);
            (total > 0.0).then(|| (n(&usage["cache_read_input_tokens"]) / total).clamp(0.0, 1.0))
        });
    let Some(dir) = dir else {
        return flow;
    };
    let Some((calls, turns)) = parse_events(&dir) else {
        return flow;
    };
    if let Some((speed, approx)) = settled_speed(&calls, &turns, ledger.as_ref()) {
        flow.speed = Some(speed);
        flow.speed_approx = approx;
    }
    flow.ttft = time_to_first_token(&calls, now());
    flow
}
