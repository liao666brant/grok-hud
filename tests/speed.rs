use grok_hud::{display::*, speed, *};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
};
use tempfile::TempDir;

struct Fixture {
    home: TempDir,
    dir: PathBuf,
    payload: Value,
}
impl Fixture {
    fn new() -> Self {
        let home = TempDir::new().unwrap();
        let dir = home.path().join("sessions/workspace/active");
        fs::create_dir_all(&dir).unwrap();
        let payload = json!({"session_id":"active","model":{"id":"model"}});
        Self { home, dir, payload }
    }
    fn ledger(&self, session: Value, turns: Vec<Value>) {
        fs::write(
            self.dir.join("usage.json"),
            json!({"sessionId":"active","session":session,"turns":turns}).to_string(),
        )
        .unwrap();
    }
    fn events(&self, events: &[Value]) {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join("events.jsonl"))
            .unwrap();
        for event in events {
            writeln!(file, "{event}").unwrap();
        }
    }
    fn at(&self, offset: f64) -> String {
        iso(now() + offset)
    }
    /// A streaming chunk at an absolute unix-seconds timestamp.
    fn chunk(&self, at: f64, phase: &str) -> Value {
        json!({"ts":iso(at),"type":"phase_changed","phase":phase})
    }
}

#[test]
fn settled_turn_speed_ttft_and_cache_rate_from_the_ledger() {
    let f = Fixture::new();
    let t0 = now() - 3600.0;
    let turn = json!({"endedAt":iso(t0 + 30.0),"outputTokens":300,"inputTokens":10000,
        "cachedReadTokens":9000,"reasoningTokens":0,"totalTokens":10300});
    f.ledger(
        json!({"inputTokens":10000,"cachedReadTokens":9000,"outputTokens":300,"totalTokens":10300}),
        vec![turn],
    );
    f.events(&[
        json!({"ts":iso(t0),"type":"turn_started","session_id":"active"}),
        json!({"ts":iso(t0 + 10.0),"type":"loop_started","loop_index":0}),
        json!({"ts":iso(t0 + 11.0),"type":"first_token"}),
        f.chunk(t0 + 11.5, "streaming_reasoning"),
        f.chunk(t0 + 12.0, "streaming_text"),
        json!({"ts":iso(t0 + 20.0),"type":"loop_started","loop_index":1}),
        json!({"ts":iso(t0 + 21.0),"type":"first_token"}),
        f.chunk(t0 + 23.0, "streaming_text"),
        json!({"ts":iso(t0 + 30.0),"type":"turn_ended","outcome":"completed"}),
    ]);
    let flow = speed::measure(f.home.path(), &f.payload);
    assert_eq!(flow.cache_rate, Some(0.9));
    assert_eq!(flow.speed, Some(100.0)); // 300 tokens over 1s + 2s of streaming
    assert!(!flow.speed_approx);
    assert_eq!(flow.ttft, Some(1.0)); // newest call: first token 1s after loop start
}

#[test]
fn hidden_reasoning_marks_the_speed_approximate() {
    let f = Fixture::new();
    let t0 = now() - 3600.0;
    let turn = json!({"endedAt":iso(t0 + 30.0),"outputTokens":300,
        "inputTokens":100,"reasoningTokens":80,"totalTokens":400});
    f.ledger(
        json!({"inputTokens":100,"outputTokens":300,"totalTokens":400}),
        vec![turn],
    );
    f.events(&[
        json!({"ts":iso(t0),"type":"turn_started"}),
        json!({"ts":iso(t0 + 10.0),"type":"loop_started"}),
        json!({"ts":iso(t0 + 11.0),"type":"first_token"}),
        f.chunk(t0 + 14.0, "streaming_text"), // 3s window, reasoning never streamed
        json!({"ts":iso(t0 + 30.0),"type":"turn_ended"}),
    ]);
    let flow = speed::measure(f.home.path(), &f.payload);
    assert_eq!(flow.speed, Some(100.0));
    assert!(flow.speed_approx);
}

#[test]
fn small_turns_missing_files_and_stale_waits_hide_metrics() {
    let f = Fixture::new();
    let t0 = now() - 3600.0;
    // Output below the 100-token threshold is noise, like cc-Switch's router cut.
    f.ledger(
        json!({"inputTokens":100,"cachedReadTokens":50}),
        vec![
            json!({"endedAt":iso(t0 + 30.0),"outputTokens":50,"inputTokens":100,
            "cachedReadTokens":50,"reasoningTokens":0}),
        ],
    );
    f.events(&[
        json!({"ts":iso(t0),"type":"turn_started"}),
        json!({"ts":iso(t0 + 10.0),"type":"loop_started"}),
        json!({"ts":iso(t0 + 11.0),"type":"first_token"}),
        f.chunk(t0 + 12.0, "streaming_text"),
        json!({"ts":iso(t0 + 30.0),"type":"turn_ended"}),
    ]);
    let flow = speed::measure(f.home.path(), &f.payload);
    assert_eq!(flow.speed, None);
    assert_eq!(flow.cache_rate, Some(0.5));
    assert_eq!(flow.ttft, Some(1.0));

    // No session directory: everything except a payload cache rate stays hidden.
    let payload = json!({"session_id":"missing","context_window":{"session_usage":{
        "input_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":850}}});
    let flow = speed::measure(f.home.path(), &payload);
    assert_eq!(flow.cache_rate, Some(0.85));
    assert_eq!(flow.speed, None);
    assert_eq!(flow.ttft, None);

    // A call that never produced a token is a live wait, but only while fresh.
    let f = Fixture::new();
    f.ledger(json!({"inputTokens":0}), vec![]);
    f.events(&[
        json!({"ts":f.at(-5.0),"type":"turn_started"}),
        json!({"ts":f.at(-4.0),"type":"loop_started"}),
    ]);
    let flow = speed::measure(f.home.path(), &f.payload);
    let waited = flow.ttft.expect("live wait");
    assert!((3.5..5.0).contains(&waited), "waited {waited}");
    let f = Fixture::new();
    f.ledger(json!({"inputTokens":0}), vec![]);
    f.events(&[
        json!({"ts":f.at(-4000.0),"type":"turn_started"}),
        json!({"ts":f.at(-4000.0),"type":"loop_started"}),
    ]);
    assert_eq!(speed::measure(f.home.path(), &f.payload).ttft, None);
}

#[test]
fn previous_turn_end_bounds_a_window_without_turn_started() {
    // A tail cut can drop turn_started; the previous turn_ended still bounds
    // the window, so the settled speed stays measurable.
    let f = Fixture::new();
    let t0 = now() - 3600.0;
    f.ledger(
        json!({"inputTokens":0}),
        vec![
            json!({"endedAt":iso(t0 + 30.0),"outputTokens":50,"inputTokens":10,"reasoningTokens":0}),
            json!({"endedAt":iso(t0 + 60.0),"outputTokens":300,"inputTokens":10,"reasoningTokens":0}),
        ],
    );
    f.events(&[
        json!({"ts":iso(t0),"type":"turn_started"}),
        json!({"ts":iso(t0 + 10.0),"type":"loop_started"}),
        json!({"ts":iso(t0 + 11.0),"type":"first_token"}),
        f.chunk(t0 + 12.0, "streaming_text"),
        json!({"ts":iso(t0 + 30.0),"type":"turn_ended"}),
        // Second turn without turn_started: only its loops and turn_ended exist.
        json!({"ts":iso(t0 + 40.0),"type":"loop_started"}),
        json!({"ts":iso(t0 + 41.0),"type":"first_token"}),
        f.chunk(t0 + 44.0, "streaming_text"),
        json!({"ts":iso(t0 + 60.0),"type":"turn_ended"}),
    ]);
    let flow = speed::measure(f.home.path(), &f.payload);
    assert_eq!(flow.speed, Some(100.0));
    assert_eq!(flow.ttft, Some(1.0));
}

#[test]
fn performance_elements_render_stack_and_color() {
    let flow = speed::Flow {
        cache_rate: Some(0.97),
        ttft: Some(1.4),
        speed: Some(240.0),
        speed_approx: false,
    };
    let session = Session {
        cost: Some(0.85),
        tokens: Some(1200.0),
        ..Session::default()
    };
    let mut r = json!({"quota":{"used_percent":25,"period_end":"2026-10-05T16:08:48+00:00"},
        "local":{"cost_usd":1.5,"totalTokens":12000}});
    r["estimate"] = json!({"available":true,"usd":30.0});
    let line = status_text(
        Some(&r),
        &session,
        &flow,
        &environment::Environment::default(),
        200,
        true,
    );
    assert!(line.contains("\x1b[96m缓存率 \x1b[0m97.0%"), "{line:?}");
    assert!(
        line.contains("\x1b[92m输出: \x1b[0m240.0 tok/s"),
        "{line:?}"
    );
    assert!(line.contains("\x1b[93m首字 \x1b[0m1.4s"), "{line:?}");
    assert!(line.contains("\x1b[94m25%"), "{line:?}");
    let plain = strip_ansi(&line);
    // The session line and the usage line are fixed groups and never merge.
    assert_eq!(plain.lines().count(), 2, "{plain}");
    let (row1, row2) = (plain.lines().next().unwrap(), plain.lines().nth(1).unwrap());
    assert!(
        row1.contains("词元 1.2K │ 缓存率 97.0% │ 输出: 240.0 tok/s │ 首字 1.4s │ 费用 $0.85"),
        "{row1}"
    );
    assert!(row2.contains("用量 25%"), "{row2}");
    assert!(row2.contains("本机 $1.50 · 12K 词元"), "{row2}");
    assert!(row2.contains("周限 ≈$30.00 · 240K 词元"), "{row2}");

    let approx = speed::Flow {
        speed: Some(240.0),
        speed_approx: true,
        ..speed::Flow::default()
    };
    let text = status_text(
        Some(&r),
        &session,
        &approx,
        &environment::Environment::default(),
        80,
        false,
    );
    assert!(text.contains("输出: ≈240.0 tok/s"), "{text}");

    // Narrow terminals stack elements one per row and clip the overflow.
    let text = status_text(
        Some(&r),
        &session,
        &flow,
        &environment::Environment::default(),
        30,
        false,
    );
    for row in text.lines() {
        assert!(width(row) <= 30, "{row}");
    }
    assert!(text.lines().count() <= 5);
    assert_eq!(
        strip_ansi(&status_text(
            Some(&r),
            &session,
            &flow,
            &environment::Environment::default(),
            44,
            true
        )),
        status_text(
            Some(&r),
            &session,
            &flow,
            &environment::Environment::default(),
            44,
            false
        )
    );
}

#[test]
fn same_timestamp_window_start_still_counts_the_call() {
    // A loop that shares turn_started's exact timestamp belongs to the
    // window; a strict `>` would drop its streaming time and hide or
    // inflate the speed.
    let f = Fixture::new();
    let t0 = now() - 3600.0;
    f.ledger(
        json!({"inputTokens":100,"cachedReadTokens":50}),
        vec![
            json!({"endedAt":iso(t0 + 10.0),"outputTokens":300,"inputTokens":100,
        "reasoningTokens":0}),
        ],
    );
    f.events(&[
        json!({"ts":iso(t0),"type":"turn_started"}),
        json!({"ts":iso(t0),"type":"loop_started"}),
        json!({"ts":iso(t0 + 1.0),"type":"first_token"}),
        f.chunk(t0 + 3.0, "streaming_text"),
        json!({"ts":iso(t0 + 10.0),"type":"turn_ended"}),
    ]);
    let flow = speed::measure(f.home.path(), &f.payload);
    assert_eq!(flow.speed, Some(150.0)); // 300 tokens over the 2s window
}

#[test]
fn overflow_fold_keeps_group_separators_and_colors() {
    // Narrow terminals fold the overflow into one row; the folded row keeps
    // each group's own separator, and spans inside the clipped prefix keep
    // their colors.
    let flow = speed::Flow {
        cache_rate: Some(0.97),
        ttft: Some(1.4),
        speed: Some(240.0),
        speed_approx: false,
    };
    let session = Session {
        cost: Some(0.85),
        tokens: Some(1200.0),
        generating: true,
        ..Session::default()
    };
    let env = environment::Environment { skills: 34, mcp: 2 };
    let mut r = json!({"quota":{"used_percent":25,"period_end":"2026-10-05T16:08:48+00:00"},
        "local":{"cost_usd":1.5,"totalTokens":12000}});
    r["estimate"] = json!({"available":true,"usd":30.0});
    let colored = status_text(Some(&r), &session, &flow, &env, 15, true);
    let plain = strip_ansi(&colored);
    assert_eq!(plain.lines().count(), 5, "{plain}");
    for row in plain.lines() {
        assert!(width(row) <= 15, "{row}");
    }
    // The folded row joins session elements with the session line's ` │ `.
    assert!(plain.contains("生成中 │ 费用"), "{plain}");
    assert!(
        colored.contains("\x1b[2m生成中\x1b[0m │ \x1b[95m费用 \x1b[0m"),
        "{colored:?}"
    );
    assert_eq!(
        plain,
        status_text(Some(&r), &session, &flow, &env, 15, false)
    );
}

#[test]
fn statusline_pipeline_shows_metrics_from_real_session_files() {
    let f = Fixture::new();
    let t0 = now() - 3600.0;
    f.ledger(
        json!({"inputTokens":10000,"cachedReadTokens":9000,"outputTokens":300,"totalTokens":10300}),
        vec![
            json!({"endedAt":iso(t0 + 30.0),"outputTokens":300,"inputTokens":10000,
            "cachedReadTokens":9000,"reasoningTokens":0,"totalTokens":10300}),
        ],
    );
    f.events(&[
        json!({"ts":iso(t0),"type":"turn_started","session_id":"active"}),
        json!({"ts":iso(t0 + 10.0),"type":"loop_started","loop_index":0}),
        json!({"ts":iso(t0 + 11.0),"type":"first_token"}),
        json!({"ts":iso(t0 + 13.0),"type":"phase_changed","phase":"streaming_text"}),
        json!({"ts":iso(t0 + 30.0),"type":"turn_ended","outcome":"completed"}),
    ]);
    let mut child = Command::new(env!("CARGO_BIN_EXE_grok-hud"))
        .args(["--statusline", "--offline", "--no-color", "--grok-home"])
        .arg(f.home.path())
        .env("COLUMNS", "200")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(f.payload.to_string().as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(text.contains("缓存率 90.0%"), "{text}");
    assert!(text.contains("输出: 150.0 tok/s"), "{text}");
    assert!(text.contains("首字 1.0s"), "{text}");
}

fn strip_ansi(s: &str) -> String {
    let mut plain = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            for c2 in chars.by_ref() {
                if c2 == 'm' {
                    break;
                }
            }
        } else {
            plain.push(c);
        }
    }
    plain
}
