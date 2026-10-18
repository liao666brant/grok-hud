//! Local environment counts for the statusline: installed skills and
//! configured MCP servers. Grok's statusline payload carries neither, so both
//! are counted from the Grok home and the session's project root. Grok's own
//! built-in MCP servers have no on-disk definition and are not counted.

use crate::*;
use serde_json::Value;
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Default)]
pub struct Environment {
    /// Skill directories (a `SKILL.md` inside), deduplicated by name.
    pub skills: usize,
    /// Configured MCP servers, deduplicated by name.
    pub mcp: usize,
}

/// Skill roots count directories that hold a `SKILL.md`.
fn count_skills(dir: &Path, names: &mut HashSet<String>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.path().join("SKILL.md").is_file()
            && let Some(name) = entry.file_name().to_str()
            && !name.is_empty()
        {
            names.insert(name.to_owned());
        }
    }
}

/// `[mcp_servers.<name>]` table headers, skipping nested tables such as
/// `[mcp_servers.x.headers]`.
fn toml_mcp_servers(text: &str, names: &mut HashSet<String>) {
    for line in text.lines() {
        let Some(rest) = line.trim().strip_prefix("[mcp_servers.") else {
            continue;
        };
        let Some(end) = rest.find(']') else {
            continue;
        };
        let inner = rest[..end].trim();
        let name = if inner.len() > 1 && inner.starts_with('"') && inner.ends_with('"') {
            &inner[1..inner.len() - 1]
        } else if inner.contains('.') {
            continue;
        } else {
            inner
        };
        if !name.is_empty() {
            names.insert(name.to_owned());
        }
    }
}

/// Cut at the first `#` that sits outside a quoted string; quotes left inside
/// a comment would otherwise pair with real names and skip them.
fn strip_toml_comment(line: &str) -> &str {
    let mut in_quote = false;
    for (index, c) in line.char_indices() {
        match c {
            '"' => in_quote = !in_quote,
            '#' if !in_quote => return &line[..index],
            _ => {}
        }
    }
    line
}

/// The `enabled` list of the `[plugins]` table, including arrays that span
/// lines; TOML string arrays allow trailing commas that JSON rejects, so the
/// quoted names are pulled instead of parsing the array.
fn toml_enabled_plugins(text: &str) -> HashSet<String> {
    let mut enabled = HashSet::new();
    let mut in_plugins = false;
    let mut buffer = String::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_plugins = line.starts_with("[plugins]");
            continue;
        }
        if !in_plugins {
            continue;
        }
        let line = strip_toml_comment(line);
        if buffer.is_empty() {
            if !line.starts_with("enabled") {
                continue;
            }
            buffer.push_str(line);
        } else {
            buffer.push(' ');
            buffer.push_str(line);
        }
        let Some(start) = buffer.find('[') else {
            buffer.clear();
            continue;
        };
        if buffer.matches('[').count() != buffer.matches(']').count() {
            continue;
        }
        if let Some(end) = buffer.rfind(']').filter(|end| *end > start) {
            let mut quotes = buffer[start..=end]
                .match_indices('"')
                .map(|(index, _)| index + start);
            while let (Some(open), Some(close)) = (quotes.next(), quotes.next()) {
                enabled.insert(buffer[open + 1..close].to_owned());
            }
        }
        buffer.clear();
    }
    enabled
}

/// `.mcp.json` carries Claude-style `{"mcpServers": {...}}`.
fn json_mcp_servers(path: &Path, names: &mut HashSet<String>) {
    let Ok(value) = read_json(path) else {
        return;
    };
    if let Some(servers) = value["mcpServers"].as_object() {
        for name in servers.keys() {
            names.insert(name.clone());
        }
    }
}

/// The plugin's manifest name from plugin.json (root, then `.grok-plugin/`,
/// then `.claude-plugin/`).
fn plugin_name(dir: &Path) -> Option<String> {
    for manifest in [
        "plugin.json",
        ".grok-plugin/plugin.json",
        ".claude-plugin/plugin.json",
    ] {
        if let Ok(value) = read_json(&dir.join(manifest))
            && let Some(name) = value["name"].as_str()
        {
            return Some(name.to_owned());
        }
    }
    None
}

/// The session's project root, preferring the repository over the working
/// directory.
fn project_root(payload: &Value) -> Option<PathBuf> {
    let workspace = &payload["workspace"];
    for value in [
        &workspace["repo_root"],
        &workspace["current_dir"],
        &payload["cwd"],
    ] {
        let path = s(value);
        if !path.is_empty() {
            return Some(PathBuf::from(path));
        }
    }
    None
}

/// Count local skills and MCP servers for the statusline. Missing files and
/// unparseable values simply contribute nothing; this never fails.
pub fn count(home: &Path, payload: &Value) -> Environment {
    let mut skills: HashSet<String> = HashSet::new();
    let mut mcp: HashSet<String> = HashSet::new();

    let config = fs::read_to_string(home.join("config.toml")).unwrap_or_default();
    toml_mcp_servers(&config, &mut mcp);
    let enabled = toml_enabled_plugins(&config);

    count_skills(&home.join("skills"), &mut skills);
    count_skills(&home.join("bundled").join("skills"), &mut skills);

    if let Ok(plugins) = fs::read_dir(home.join("installed-plugins")) {
        for entry in plugins.flatten() {
            let dir = entry.path();
            if dir.is_dir()
                && let Some(name) = plugin_name(&dir)
                && enabled.contains(&name)
            {
                count_skills(&dir.join("skills"), &mut skills);
                json_mcp_servers(&dir.join(".mcp.json"), &mut mcp);
            }
        }
    }

    if let Some(root) = project_root(payload) {
        count_skills(&root.join(".grok").join("skills"), &mut skills);
        let project_config =
            fs::read_to_string(root.join(".grok").join("config.toml")).unwrap_or_default();
        toml_mcp_servers(&project_config, &mut mcp);
        json_mcp_servers(&root.join(".mcp.json"), &mut mcp);
    }

    Environment {
        skills: skills.len(),
        mcp: mcp.len(),
    }
}
