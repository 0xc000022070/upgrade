use super::grammar::Grammar;
use super::syntax::{next_node, utf16_offsets};
use serde_json::{json, Value};
use tree_sitter::{Node, Query, QueryCursor, StreamingIterator, Tree};

const KINDS: [&str; 8] = [
    "keyword",
    "type",
    "string",
    "number",
    "comment",
    "annotation",
    "punctuation",
    "function",
];

const RESET: u8 = 0;

pub struct Highlighter {
    query: Option<Query>,
    paints: Vec<Option<u8>>,
}

impl Highlighter {
    pub fn new(grammar: &Grammar) -> Self {
        let source = grammar.highlights.concat();
        let query = (!source.is_empty())
            .then(|| Query::new(&grammar.language, &source).ok())
            .flatten();
        let paints = query.as_ref().map_or_else(Vec::new, |query| {
            query
                .capture_names()
                .iter()
                .map(|name| paint_for_capture(name))
                .collect()
        });
        Self { query, paints }
    }

    #[cfg(test)]
    pub fn has_query(&self) -> bool {
        self.query.is_some()
    }

    pub fn runs(&self, tree: &Tree, text: &str) -> Vec<Value> {
        let mut painted = vec![RESET; text.len()];
        match &self.query {
            Some(query) => self.paint_captures(query, tree, text, &mut painted),
            None => paint_nodes(tree, &mut painted),
        }
        runs_json(text, &painted)
    }

    fn paint_captures(&self, query: &Query, tree: &Tree, text: &str, painted: &mut [u8]) {
        let mut spans: Vec<(usize, usize, usize, u8)> = Vec::new();
        let mut cursor = QueryCursor::new();
        let mut matches = cursor.matches(query, tree.root_node(), text.as_bytes());
        while let Some(found) = matches.next() {
            for capture in found.captures() {
                if let Some(paint) = self.paints[capture.index as usize] {
                    let node = capture.node;
                    let paint = literal_paint(node).unwrap_or(paint);
                    spans.push((
                        node.start_byte(),
                        node.end_byte(),
                        found.pattern_index,
                        paint,
                    ));
                }
            }
        }
        spans.sort_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(&a.1)).then(b.2.cmp(&a.2)));
        for (start, end, _, paint) in spans {
            fill(painted, start, end, paint);
        }
    }
}

fn fill(painted: &mut [u8], start: usize, end: usize, paint: u8) {
    if let Some(range) = painted.get_mut(start..end.min(painted.len())) {
        range.fill(paint);
    }
}

const HEADS: &[(&str, &[&str])] = &[
    (
        "keyword",
        &[
            "keyword",
            "conditional",
            "repeat",
            "include",
            "exception",
            "storageclass",
            "boolean",
            "preproc",
            "import",
            "use",
            "forward",
            "media",
            "mixin",
            "supports",
            "keyframes",
            "charset",
            "at-root",
            "extend",
            "each",
            "for",
            "while",
            "return",
            "debug",
            "warn",
        ],
    ),
    ("type", &["type", "constructor", "tag"]),
    (
        "string",
        &["string", "escape", "character", "markup", "text"],
    ),
    ("number", &["number", "float"]),
    ("comment", &["comment"]),
    ("annotation", &["attribute", "decorator", "annotation"]),
    ("punctuation", &["punctuation", "operator", "delimiter"]),
    ("function", &["function", "method"]),
];

fn paint_for_capture(name: &str) -> Option<u8> {
    match name {
        "constant.builtin" | "variable.builtin" | "text.title" | "markup.heading" => {
            return kind_index("keyword")
        }
        "string.special.key" => return None,
        _ => {}
    }
    let head = name.split('.').next().unwrap_or(name);
    if matches!(head, "none" | "embedded") {
        return Some(RESET);
    }
    let (kind, _) = HEADS.iter().find(|(_, heads)| heads.contains(&head))?;
    kind_index(kind)
}

fn literal_paint(node: Node) -> Option<u8> {
    let kind = node.kind();
    let numeric = node.is_named() && NUMERIC.iter().any(|part| kind.contains(part));
    numeric.then(|| kind_index("number")).flatten()
}

const NUMERIC: [&str; 4] = ["number", "integer", "float", "int_lit"];

fn kind_index(kind: &str) -> Option<u8> {
    KINDS
        .iter()
        .position(|known| *known == kind)
        .map(|index| index as u8 + 1)
}

fn paint_nodes(tree: &Tree, painted: &mut [u8]) {
    let mut cursor = tree.walk();
    loop {
        let node = cursor.node();
        let paint = node_kind(node).and_then(kind_index);
        if let Some(paint) = paint {
            fill(painted, node.start_byte(), node.end_byte(), paint);
        }
        if (paint.is_some() || !cursor.goto_first_child()) && !next_node(&mut cursor) {
            return;
        }
    }
}

fn node_kind(node: Node) -> Option<&'static str> {
    let kind = node.kind();
    if node.is_named() {
        return named_kind(node, kind);
    }
    if kind.chars().all(|c| c.is_ascii_alphabetic() || c == '_') {
        Some("keyword")
    } else if kind.chars().all(|c| c.is_ascii_punctuation()) {
        Some("punctuation")
    } else {
        None
    }
}

fn named_kind(node: Node, kind: &str) -> Option<&'static str> {
    if kind.contains("comment") {
        return Some("comment");
    }
    if kind.contains("string") || kind.ends_with("_literal") && kind.contains("char") {
        return Some("string");
    }
    if NUMERIC.iter().any(|part| kind.contains(part)) {
        return Some("number");
    }
    if kind.contains("annotation") {
        return Some("annotation");
    }
    if kind.contains("type") && node.child_count() == 0 || kind == "user_type" {
        return Some("type");
    }
    let parent = node.parent()?.kind();
    let declares_function = ["function", "method", "rpc"]
        .iter()
        .any(|part| parent.contains(part));
    (declares_function && node.child_count() == 0 && kind.contains("identifier"))
        .then_some("function")
}

fn runs_json(text: &str, painted: &[u8]) -> Vec<Value> {
    let mut runs: Vec<(usize, usize, u8)> = Vec::new();
    for (index, paint) in painted.iter().enumerate() {
        if *paint == RESET {
            continue;
        }
        match runs.last_mut() {
            Some(last) if last.1 == index && last.2 == *paint => last.1 = index + 1,
            _ => runs.push((index, index + 1, *paint)),
        }
    }
    let blank = |index: usize| text.as_bytes()[index].is_ascii_whitespace();
    for run in &mut runs {
        while run.0 < run.1 && blank(run.0) {
            run.0 += 1;
        }
        while run.1 > run.0 && blank(run.1 - 1) {
            run.1 -= 1;
        }
    }
    runs.retain(|run| run.0 < run.1);
    let bounds: Vec<usize> = runs.iter().flat_map(|run| [run.0, run.1]).collect();
    let units = utf16_offsets(text, &bounds);
    runs.iter()
        .zip(units.chunks(2))
        .map(|(run, units)| json!([units[0], units[1], KINDS[run.2 as usize - 1]]))
        .collect()
}
