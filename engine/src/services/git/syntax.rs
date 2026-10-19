use super::declared;
use super::grammar::Grammar;
use super::highlight::Highlighter;
use imara_diff::{Algorithm, Diff, InternedInput};
use serde_json::{json, Value};
use std::collections::HashMap;
use tree_sitter::{Node, Parser, Point, Tree, TreeCursor};

pub struct Analysis {
    pub changed: Value,
    pub scopes: Value,
    pub highlight: Value,
}

pub fn analyze(
    grammar: &Grammar,
    highlighter: &Highlighter,
    old: &str,
    new: &str,
) -> Option<Analysis> {
    let mut parser = Parser::new();
    parser.set_language(&grammar.language).ok()?;
    let old_tree = parser.parse(old, None)?;
    let new_tree = parser.parse(new, None)?;

    let old_atoms = atoms(&old_tree, old);
    let new_atoms = atoms(&new_tree, new);
    let mut input = InternedInput::default();
    input.update_before(old_atoms.iter().map(Atom::key));
    input.update_after(new_atoms.iter().map(Atom::key));
    let diff = Diff::compute(Algorithm::Histogram, &input);

    let (old_words, new_words) = paired_words(&diff, &old_atoms, &new_atoms);
    let old_changed = unmatched(&old_atoms, &old_words, |index| diff.is_removed(index));
    let new_changed = unmatched(&new_atoms, &new_words, |index| diff.is_added(index));
    Some(Analysis {
        changed: json!({
            "old": utf16_ranges(old, &old_changed),
            "new": utf16_ranges(new, &new_changed),
        }),
        scopes: json!({
            "old": scopes(grammar.name, &old_tree, old),
            "new": scopes(grammar.name, &new_tree, new),
        }),
        highlight: json!({
            "old": highlighter.runs(&old_tree, old),
            "new": highlighter.runs(&new_tree, new),
        }),
    })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Class {
    Code,
    String,
    Comment,
}

struct Atom<'a> {
    class: Class,
    text: &'a str,
    start: usize,
    end: usize,
}

impl<'a> Atom<'a> {
    fn key(&self) -> (bool, &'a str) {
        (self.class != Class::Code, self.text)
    }
}

fn atomic_class(node: Node) -> Option<Class> {
    if !(node.is_named() || node.is_extra()) {
        return None;
    }
    let kind = node.kind();
    if kind.contains("string")
        || kind.contains("heredoc")
        || kind.ends_with("quote_scalar")
        || kind == "block_scalar"
        || kind == "text_block"
    {
        Some(Class::String)
    } else if kind.contains("comment") {
        Some(Class::Comment)
    } else {
        None
    }
}

fn atoms<'a>(tree: &Tree, text: &'a str) -> Vec<Atom<'a>> {
    let mut found = Vec::new();
    let mut covered = 0;
    let mut cursor = tree.walk();
    loop {
        let node = cursor.node();
        let class = atomic_class(node);
        if class.is_none() && cursor.goto_first_child() {
            continue;
        }
        let (start, end) = (node.start_byte(), node.end_byte().min(text.len()));
        push_gap(&mut found, text, covered, start);
        covered = covered.max(end);
        if let Some(slice) = text.get(start..end) {
            push_leaf(&mut found, slice, start, class);
        }
        if !next_node(&mut cursor) {
            push_gap(&mut found, text, covered, text.len());
            return found;
        }
    }
}

fn push_gap<'a>(found: &mut Vec<Atom<'a>>, text: &'a str, from: usize, to: usize) {
    if let Some(gap) = text.get(from..to) {
        push_code(found, gap, from);
    }
}

fn push_code<'a>(found: &mut Vec<Atom<'a>>, slice: &'a str, base: usize) {
    let before = found.len();
    push_words(found, slice, base);
    let mut index = before;
    while index < found.len() {
        let atom = &found[index];
        let rest = &slice[atom.end - base..];
        if atom.text == "\\" && (rest.starts_with('\n') || rest.starts_with("\r\n")) {
            found.remove(index);
        } else {
            index += 1;
        }
    }
}

fn push_leaf<'a>(found: &mut Vec<Atom<'a>>, slice: &'a str, start: usize, class: Option<Class>) {
    let Some(class) = class else {
        push_code(found, slice, start);
        return;
    };
    let trimmed = slice.trim();
    if trimmed.is_empty() {
        return;
    }
    let offset = start + (slice.len() - slice.trim_start().len());
    found.push(Atom {
        class,
        text: trimmed,
        start: offset,
        end: offset + trimmed.len(),
    });
}

pub(super) fn next_node(cursor: &mut TreeCursor) -> bool {
    loop {
        if cursor.goto_next_sibling() {
            return true;
        }
        if !cursor.goto_parent() {
            return false;
        }
    }
}

fn push_words<'a>(found: &mut Vec<Atom<'a>>, slice: &'a str, base: usize) {
    let mut word_start: Option<usize> = None;
    for (index, character) in slice.char_indices() {
        match (character.is_whitespace(), word_start) {
            (true, Some(start)) => {
                found.push(Atom {
                    class: Class::Code,
                    text: &slice[start..index],
                    start: base + start,
                    end: base + index,
                });
                word_start = None;
            }
            (false, None) => word_start = Some(index),
            _ => {}
        }
    }
    if let Some(start) = word_start {
        found.push(Atom {
            class: Class::Code,
            text: &slice[start..],
            start: base + start,
            end: base + slice.len(),
        });
    }
}

type Spans = Vec<(usize, usize)>;
type Words = HashMap<usize, Spans>;

fn paired_words(diff: &Diff, old: &[Atom], new: &[Atom]) -> (Words, Words) {
    let mut old_words = Words::new();
    let mut new_words = Words::new();
    for hunk in diff.hunks() {
        let removed = pairable(old, hunk.before.start..hunk.before.end);
        let added = pairable(new, hunk.after.start..hunk.after.end);
        for (old_index, new_index) in removed.into_iter().zip(added) {
            let (before, after) = (&old[old_index], &new[new_index]);
            if before.class != after.class {
                continue;
            }
            if let Some((removed, added)) = changed_words(before, after) {
                old_words.insert(old_index, removed);
                new_words.insert(new_index, added);
            }
        }
    }
    (old_words, new_words)
}

fn pairable(atoms: &[Atom], range: std::ops::Range<u32>) -> Vec<usize> {
    (range.start as usize..range.end as usize)
        .filter(|index| atoms[*index].class != Class::Code)
        .collect()
}

type Token<'a> = (&'a str, usize, usize);

fn changed_words(before: &Atom, after: &Atom) -> Option<(Spans, Spans)> {
    let old_tokens = tokens(before.text, before.start);
    let new_tokens = tokens(after.text, after.start);
    let mut input = InternedInput::default();
    input.update_before(old_tokens.iter().map(|token| token.0));
    input.update_after(new_tokens.iter().map(|token| token.0));
    let diff = Diff::compute(Algorithm::Myers, &input);
    let shared = old_tokens.len() - diff.count_removals() as usize;
    if shared * 2 < old_tokens.len().max(new_tokens.len()) {
        return None;
    }
    let spans = |tokens: &[Token], changed: &dyn Fn(u32) -> bool| {
        let mut spans = Spans::new();
        for (index, token) in tokens.iter().enumerate() {
            if changed(index as u32) {
                extend(&mut spans, token.1, token.2);
            }
        }
        spans
    };
    Some((
        spans(&old_tokens, &|index| diff.is_removed(index)),
        spans(&new_tokens, &|index| diff.is_added(index)),
    ))
}

fn tokens(text: &str, base: usize) -> Vec<Token<'_>> {
    let mut found = Vec::new();
    let mut word: Option<usize> = None;
    for (index, character) in text.char_indices() {
        let wordy = character.is_alphanumeric() || character == '_';
        if let (Some(start), false) = (word, wordy) {
            found.push((&text[start..index], base + start, base + index));
            word = None;
        }
        if wordy {
            word.get_or_insert(index);
        } else if !character.is_whitespace() {
            let end = index + character.len_utf8();
            found.push((&text[index..end], base + index, base + end));
        }
    }
    if let Some(start) = word {
        found.push((&text[start..], base + start, base + text.len()));
    }
    found
}

fn extend(ranges: &mut Vec<(usize, usize)>, start: usize, end: usize) {
    match ranges.last_mut() {
        Some(last) if last.1 >= start => last.1 = last.1.max(end),
        _ => ranges.push((start, end)),
    }
}

fn unmatched(
    atoms: &[Atom],
    words: &Words,
    is_changed: impl Fn(u32) -> bool,
) -> Vec<(usize, usize)> {
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    for (index, atom) in atoms.iter().enumerate() {
        if !is_changed(index as u32) {
            continue;
        }
        match words.get(&index) {
            Some(spans) => spans
                .iter()
                .for_each(|&(start, end)| extend(&mut ranges, start, end)),
            None => extend(&mut ranges, atom.start, atom.end),
        }
    }
    ranges
}

pub(super) fn utf16_offsets(text: &str, offsets: &[usize]) -> Vec<usize> {
    let mut byte = 0usize;
    let mut unit = 0usize;
    offsets
        .iter()
        .map(|&target| {
            for character in text[byte..].chars() {
                if byte >= target {
                    break;
                }
                byte += character.len_utf8();
                unit += character.len_utf16();
            }
            unit
        })
        .collect()
}

fn utf16_ranges(text: &str, ranges: &[(usize, usize)]) -> Vec<[usize; 2]> {
    let bounds: Vec<usize> = ranges
        .iter()
        .flat_map(|&(start, end)| [start, end])
        .collect();
    utf16_offsets(text, &bounds)
        .chunks(2)
        .map(|pair| [pair[0], pair[1]])
        .collect()
}

fn scope_kind(language: &str, node: Node) -> Option<&'static str> {
    let kind = match node.kind() {
        "function_item"
        | "function_signature_item"
        | "function_declaration"
        | "generator_function_declaration"
        | "function_definition" => "function",
        "method_declaration" | "method_definition" | "method_signature" => "method",
        "class_declaration" if has_child(node, "interface") => "interface",
        "class_declaration"
        | "class_definition"
        | "class_specifier"
        | "abstract_class_declaration" => "class",
        "struct_item" | "struct_specifier" => "struct",
        "union_item" | "union_specifier" => "union",
        "enum_item" | "enum_declaration" | "enum_specifier" => "enum",
        "trait_item" => "trait",
        "interface_declaration" => "interface",
        "impl_item" => "impl",
        "mod_item" | "internal_module" => "module",
        "module" if matches!(language, "typescript" | "tsx") => "module",
        "namespace_definition" => "namespace",
        "object_declaration" => "object",
        "record_declaration" => "record",
        "constructor_declaration" | "secondary_constructor" => "constructor",
        "type_spec" => match node.child_by_field_name("type")?.kind() {
            "struct_type" => "struct",
            "interface_type" => "interface",
            _ => return None,
        },
        "variable_declarator" => match node.child_by_field_name("value")?.kind() {
            "arrow_function" | "function_expression" | "function" => "function",
            _ => return None,
        },
        "binding" if language == "nix" => match node.child_by_field_name("expression")?.kind() {
            "function_expression" => "function",
            _ => return None,
        },
        _ => return None,
    };
    Some(kind)
}

fn has_child(node: Node, kind: &str) -> bool {
    let mut cursor = node.walk();
    let found = node.children(&mut cursor).any(|child| child.kind() == kind);
    found
}

fn is_container(kind: &str) -> bool {
    matches!(
        kind,
        "class"
            | "struct"
            | "enum"
            | "trait"
            | "interface"
            | "impl"
            | "mixin"
            | "extension"
            | "object"
            | "record"
            | "union"
    )
}

pub(super) fn slice<'a>(node: Node, text: &'a str) -> Option<&'a str> {
    text.get(node.start_byte()..node.end_byte())
}

fn scope_name<'a>(node: Node, text: &'a str) -> Option<&'a str> {
    let named = match node.kind() {
        "impl_item" => node.child_by_field_name("type"),
        "binding" => node.child_by_field_name("attrpath"),
        _ => node.child_by_field_name("name"),
    };
    let named = named.or_else(|| innermost_declarator(node)).or_else(|| {
        let mut cursor = node.walk();
        let found = node.named_children(&mut cursor).find(|child| {
            let kind = child.kind();
            kind.ends_with("identifier") || kind == "name"
        });
        found
    })?;
    slice(named, text)
}

fn innermost_declarator(node: Node) -> Option<Node> {
    let mut current = node.child_by_field_name("declarator")?;
    while let Some(inner) = current.child_by_field_name("declarator") {
        current = inner;
    }
    Some(current)
}

fn dart_scope(node: Node, text: &str) -> Option<(&'static str, String)> {
    let kind = match node.kind() {
        "class_declaration" => "class",
        "mixin_declaration" => "mixin",
        "extension_declaration" | "extension_type_declaration" => "extension",
        "enum_declaration" => "enum",
        "method_declaration"
        | "function_declaration"
        | "getter_declaration"
        | "setter_declaration"
        | "local_function_declaration"
        | "declaration" => {
            let mut signature = node
                .child_by_field_name("signature")
                .or_else(|| node.named_child(0))?;
            if signature.kind() == "method_signature" {
                signature = signature.named_child(0)?;
            }
            let kind = match signature.kind() {
                "function_signature" | "getter_signature" | "setter_signature"
                | "operator_signature" => "function",
                "constructor_signature"
                | "factory_constructor_signature"
                | "constant_constructor_signature"
                | "redirecting_factory_constructor_signature" => "constructor",
                _ => return None,
            };
            let mut cursor = signature.walk();
            let mut parts = signature.children_by_field_name("name", &mut cursor);
            let first = parts.next().or_else(|| signature.named_child(0))?;
            let last = parts.last().unwrap_or(first);
            let name = text.get(first.start_byte()..last.end_byte())?;
            return Some((kind, name.to_owned()));
        }
        _ => return None,
    };
    Some((
        kind,
        slice(node.child_by_field_name("name")?, text)?.to_owned(),
    ))
}

fn scope_of(language: &str, node: Node, text: &str) -> Option<(&'static str, String)> {
    match language {
        "dart" => return dart_scope(node, text),
        "markdown" | "sql" | "proto" | "graphql" | "make" | "scss" => {
            return declared::scope(node, text)
        }
        _ => {}
    }
    let kind = scope_kind(language, node)?;
    match scope_name(node, text) {
        Some(name) => Some((kind, name.to_owned())),
        None if kind == "constructor" => Some((kind, String::new())),
        None => None,
    }
}

type Open = Vec<(usize, &'static str, String)>;

fn scopes(language: &str, tree: &Tree, text: &str) -> Vec<Value> {
    if language == "dockerfile" {
        return declared::stages(tree, text);
    }
    let mut found = Vec::new();
    let mut open: Open = Vec::new();
    let mut cursor = tree.walk();
    loop {
        let node = cursor.node();
        while open
            .last()
            .is_some_and(|(end, _, _)| *end <= node.start_byte())
        {
            open.pop();
        }
        if let Some((kind, name)) = scope_of(language, node, text) {
            let (kind, name) = placed(node, kind, name, &open);
            found.push(scope_json(
                node.start_position(),
                trimmed_end(node, text),
                kind,
                &name,
            ));
            open.push((node.end_byte(), kind, name));
        }
        if !cursor.goto_first_child() && !next_node(&mut cursor) {
            return found;
        }
    }
}

fn placed(
    node: Node,
    mut kind: &'static str,
    mut name: String,
    open: &Open,
) -> (&'static str, String) {
    let outer = open.last().filter(|(_, outer, _)| is_container(outer));
    if kind == "function" && outer.is_some() {
        kind = "method";
    }
    if kind == "method" && node.kind() == "method_definition" && name == "constructor" {
        kind = "constructor";
    }
    if name.is_empty() {
        name = outer.map(|(_, _, outer)| outer.clone()).unwrap_or_default();
    }
    (kind, name.split_whitespace().collect::<Vec<_>>().join(" "))
}

pub(super) fn trimmed_end(node: Node, text: &str) -> Point {
    let Some(body) = slice(node, text) else {
        return node.end_position();
    };
    let kept = &body[..body.trim_end().len()];
    let start = node.start_position();
    match kept.rfind('\n') {
        Some(newline) => Point {
            row: start.row + kept.matches('\n').count(),
            column: kept.len() - newline - 1,
        },
        None => Point {
            row: start.row,
            column: start.column + kept.len(),
        },
    }
}

pub(super) fn scope_json(start: Point, end: Point, kind: &str, name: &str) -> Value {
    let end_line = if end.column == 0 && end.row > start.row {
        end.row
    } else {
        end.row + 1
    };
    json!({
        "line": start.row + 1,
        "end": end_line,
        "name": name,
        "kind": kind,
    })
}

#[cfg(test)]
mod tests {
    use super::super::grammar::grammar_for;
    use super::*;

    fn analyzed(path: &str, old: &str, new: &str) -> Analysis {
        let grammar = grammar_for(path, None).unwrap_or_else(|| panic!("no grammar for {path}"));
        let highlighter = Highlighter::new(&grammar);
        analyze(&grammar, &highlighter, old, new)
            .unwrap_or_else(|| panic!("{} did not load", grammar.name))
    }

    fn spans<'a>(text: &'a str, ranges: &Value) -> Vec<&'a str> {
        let units: Vec<u16> = text.encode_utf16().collect();
        let byte = |unit: u64| String::from_utf16(&units[..unit as usize]).unwrap().len();
        ranges
            .as_array()
            .unwrap()
            .iter()
            .map(|range| &text[byte(range[0].as_u64().unwrap())..byte(range[1].as_u64().unwrap())])
            .collect()
    }

    #[test]
    fn utf16_offsets_count_a_surrogate_pair_as_two() {
        assert_eq!(utf16_ranges("😀 ab", &[(5, 7)]), vec![[3, 5]]);
        assert_eq!(utf16_ranges("é x", &[(0, 2), (3, 4)]), vec![[0, 1], [2, 3]]);
    }

    #[test]
    fn every_grammar_loads_and_ignores_layout() {
        for (path, old, new) in [
            ("a.dart", "f(a, b);", "f(\n  a,\n  b);"),
            ("a.rs", "f(a, b);", "f(\n    a, b);"),
            ("a.ts", "f(a, b);", "f(a,\n  b);"),
            ("a.tsx", "<A b={c} />;", "<A\n  b={c}\n/>;"),
            ("a.js", "f(a, b);", "f(a,\n b);"),
            ("a.py", "f(a, b)\n", "f(a,\n  b)\n"),
            ("a.go", "package a\n", "package  a\n"),
            ("a.nix", "{ a = 1; }", "{\n  a = 1;\n}"),
            ("a.sh", "echo a b\n", "echo a \\\n  b\n"),
            (
                "a.json",
                "{\"a\": [1, 2]}",
                "{\n  \"a\": [\n    1,\n    2\n  ]\n}",
            ),
            ("a.yaml", "a: [1, 2]\n", "a: [1,\n  2]\n"),
            ("a.toml", "a = [1, 2]\n", "a = [\n  1,\n  2\n]\n"),
            ("a.c", "int f(int a, int b);", "int f(int a,\n      int b);"),
            (
                "a.cpp",
                "int f(int a, int b);",
                "int f(int a,\n      int b);",
            ),
            (
                "A.java",
                "class A { void f() {} }",
                "class A {\n  void f() {}\n}",
            ),
            ("a.kt", "fun f(a: Int) = a\n", "fun f(\n  a: Int\n) = a\n"),
            ("a.lua", "f(a, b)\n", "f(a,\n  b)\n"),
            ("a.css", "a { color: red; }", "a {\n  color: red;\n}"),
            ("a.html", "<p>some words</p>", "<p>\n  some\n  words\n</p>"),
            (
                "a.scss",
                "a { b { color: red; } }",
                "a {\n  b { color: red; }\n}",
            ),
            (
                "a.md",
                "# Title\n\nsome words\n",
                "# Title\n\nsome\nwords\n",
            ),
            ("Dockerfile", "FROM a\nRUN b c\n", "FROM a\nRUN b \\\n  c\n"),
            ("Makefile", "all: a b\n", "all: a  b\n"),
            ("a.sql", "SELECT a, b FROM t;", "SELECT a,\n  b\nFROM t;"),
            ("a.xml", "<a><b/></a>", "<a>\n  <b/>\n</a>"),
            (
                "a.proto",
                "message A { int32 x = 1; }",
                "message A {\n  int32 x = 1;\n}",
            ),
            ("a.graphql", "type A { b: C }", "type A {\n  b: C\n}"),
        ] {
            let analysis = analyzed(path, old, new);
            assert_eq!(
                analysis.changed,
                json!({ "old": [], "new": [] }),
                "{path} saw a change in layout alone",
            );
        }
    }

    #[test]
    fn every_highlights_query_compiles_and_runs_never_overlap() {
        for (path, text) in [
            (
                "a.rs",
                "#[derive(Debug)]\nstruct A;\n// note\nfn f() -> u8 { g(\"s\", 1) }\n",
            ),
            ("a.dart", "@override\nint f() => g('s', 1); // note\n"),
            ("a.ts", "const a: number = f(\"s\", 1); // note\n"),
            ("a.tsx", "const a = <A b=\"s\" />; // note\n"),
            ("a.js", "const a = f(`s${b}`, 1); // note\n"),
            ("a.py", "@d\ndef f():\n    return 'a' # note\n"),
            ("a.go", "package a\nfunc f() int { return 1 } // note\n"),
            ("a.nix", "{ a = \"s\"; b = 1; } # note\n"),
            ("a.sh", "f() { echo \"s\" 1; } # note\n"),
            ("a.json", "{\"a\": 1}"),
            ("a.yaml", "a: 's' # note\n"),
            ("a.toml", "a = 1 # note\n"),
            ("a.c", "int f(void) { return 1; } // note\n"),
            ("a.cpp", "class A { int f() { return 1; } }; // note\n"),
            ("A.java", "@A class B { int f() { return 1; } } // note\n"),
            ("a.kt", "fun f(): Int = 1 // note\n"),
            ("a.lua", "local function f() return 'a' end -- note\n"),
            ("a.css", "a { color: red; } /* note */"),
            ("a.scss", "@mixin a { color: red; } // note\n"),
            ("a.html", "<p class=\"a\">b</p><!-- note -->"),
            ("a.md", "# Title\n\n- item\n\n```sh\nls\n```\n"),
            ("Dockerfile", "# note\nFROM a AS b\nRUN c\n"),
            ("Makefile", "# note\nall: a\n\tcc a\n"),
            ("a.sql", "-- note\nSELECT 1 FROM t WHERE a = 'b';\n"),
            (
                "a.xml",
                "<?xml version=\"1.0\"?><a b=\"c\"><!-- note --></a>",
            ),
            ("a.proto", "// note\nmessage A { string b = 1; }\n"),
            ("a.graphql", "# note\ntype A { b(c: Int = 1): String }\n"),
        ] {
            let grammar = grammar_for(path, None).unwrap();
            let highlighter = Highlighter::new(&grammar);
            assert_eq!(
                highlighter.has_query(),
                !grammar.highlights.is_empty(),
                "{path}: the shipped highlights query did not compile"
            );
            let highlight = analyzed(path, "", text).highlight;
            let runs = highlight["new"].as_array().unwrap();
            assert!(!runs.is_empty(), "{path} highlighted nothing");
            let mut last = 0;
            for run in runs {
                let (start, end) = (run[0].as_u64().unwrap(), run[1].as_u64().unwrap());
                assert!(
                    start >= last && end > start,
                    "{path}: {run} overlaps or is empty"
                );
                assert!(
                    KINDS_FOR_TEST.contains(&run[2].as_str().unwrap()),
                    "{path}: {run}"
                );
                last = end;
            }
            let kinds: Vec<&str> = runs.iter().map(|run| run[2].as_str().unwrap()).collect();
            if !matches!(path, "a.json" | "a.md") {
                assert!(
                    kinds.contains(&"comment"),
                    "{path} has no comment in {kinds:?}"
                );
            }
        }
    }

    const KINDS_FOR_TEST: [&str; 8] = [
        "keyword",
        "type",
        "string",
        "number",
        "comment",
        "annotation",
        "punctuation",
        "function",
    ];

    fn kinds_of<'a>(text: &'a str, runs: &Value) -> Vec<(&'a str, String)> {
        let units: Vec<u16> = text.encode_utf16().collect();
        let byte = |unit: u64| String::from_utf16(&units[..unit as usize]).unwrap().len();
        runs.as_array()
            .unwrap()
            .iter()
            .map(|run| {
                let (start, end) = (
                    byte(run[0].as_u64().unwrap()),
                    byte(run[1].as_u64().unwrap()),
                );
                (&text[start..end], run[2].as_str().unwrap().to_owned())
            })
            .collect()
    }

    #[test]
    fn rust_highlights_name_each_kind_in_utf16() {
        let text = "#[inline]\nfn grow(n: u32) -> u32 {\n    // 😀 note\n    n + 1\n}\nconst S: &str = \"é\";\n";
        let found = kinds_of(text, &analyzed("a.rs", "", text).highlight["new"]);
        for expected in [
            ("fn", "keyword"),
            ("grow", "function"),
            ("u32", "type"),
            ("// 😀 note", "comment"),
            ("1", "number"),
            ("\"é\"", "string"),
            ("{", "punctuation"),
        ] {
            assert!(
                found.contains(&(expected.0, expected.1.to_owned())),
                "{expected:?} not in {found:?}"
            );
        }
        assert!(found
            .iter()
            .any(|(text, kind)| kind == "annotation" && text.contains("inline")));
    }

    #[test]
    fn grammars_without_a_query_fall_back_to_node_kinds() {
        let text =
            "// note\nservice S {\n  rpc Get(A) returns (B);\n}\nmessage A { string b = 1; }\n";
        let found = kinds_of(text, &analyzed("a.proto", "", text).highlight["new"]);
        for expected in [
            ("// note", "comment"),
            ("service", "keyword"),
            ("message", "keyword"),
            ("1", "number"),
            ("{", "punctuation"),
        ] {
            assert!(
                found.contains(&(expected.0, expected.1.to_owned())),
                "{expected:?} not in {found:?}"
            );
        }
    }

    #[test]
    fn a_shebang_names_the_grammar_when_the_path_does_not() {
        for (line, name) in [
            ("#!/usr/bin/env python3", Some("python")),
            ("#!/usr/bin/python3.11 -u", Some("python")),
            ("#!/bin/bash", Some("bash")),
            ("#!/bin/sh -e", Some("bash")),
            ("#!/usr/bin/env zsh", Some("bash")),
            ("#!/usr/bin/env -S node --flag", Some("javascript")),
            ("#!/usr/bin/env FOO=1 lua", Some("lua")),
            ("#!/usr/bin/make -f", Some("make")),
            ("#!/usr/bin/perl", None),
            ("echo hi", None),
        ] {
            assert_eq!(
                grammar_for("bin/tool", Some(line)).map(|grammar| grammar.name),
                name,
                "{line}"
            );
        }
        assert_eq!(
            grammar_for("tool.rs", Some("#!/bin/bash")).map(|grammar| grammar.name),
            Some("rust")
        );
    }

    #[test]
    fn a_paired_string_or_comment_changes_by_word() {
        let old = "fn f() {\n    // keep the old wording here\n    g(\"hello brave world\");\n}\n";
        let new = "fn f() {\n    // keep the new wording here\n    g(\"hello bold world\");\n}\n";
        let changed = analyzed("a.rs", old, new).changed;
        assert_eq!(spans(old, &changed["old"]), vec!["old", "brave"]);
        assert_eq!(spans(new, &changed["new"]), vec!["new", "bold"]);
    }

    #[test]
    fn a_rewritten_string_changes_as_a_whole() {
        let old = "g(\"one two three four\");\n";
        let new = "g(\"five six seven\");\n";
        let changed = analyzed("a.rs", old, new).changed;
        assert_eq!(spans(old, &changed["old"]), vec!["\"one two three four\""]);
        assert_eq!(spans(new, &changed["new"]), vec!["\"five six seven\""]);
    }

    #[test]
    fn a_string_paired_with_a_comment_changes_as_a_whole() {
        let old = "a(\"note here\");\n";
        let new = "a(); // note here\n";
        let changed = analyzed("a.rs", old, new).changed;
        assert_eq!(spans(old, &changed["old"]), vec!["\"note here\""]);
        assert_eq!(spans(new, &changed["new"]), vec!["// note here"]);
    }

    fn scope_names(path: &str, text: &str) -> Vec<(String, String, u64, u64)> {
        analyzed(path, "", text).scopes["new"]
            .as_array()
            .unwrap()
            .iter()
            .map(|scope| {
                (
                    scope["kind"].as_str().unwrap().to_owned(),
                    scope["name"].as_str().unwrap().to_owned(),
                    scope["line"].as_u64().unwrap(),
                    scope["end"].as_u64().unwrap(),
                )
            })
            .collect()
    }

    fn scope(kind: &str, name: &str, line: u64, end: u64) -> (String, String, u64, u64) {
        (kind.to_owned(), name.to_owned(), line, end)
    }

    #[test]
    fn new_grammars_declare_their_scopes() {
        assert_eq!(
            scope_names(
                "a.md",
                "# Title\n\nintro\n\n## Sub one\n\ntext\n\n## Sub two\n\nmore\n"
            ),
            vec![
                scope("heading", "Title", 1, 11),
                scope("heading", "Sub one", 5, 7),
                scope("heading", "Sub two", 9, 11),
            ]
        );
        assert_eq!(
            scope_names(
                "a.sql",
                "CREATE TABLE users (id INT);\nCREATE VIEW v AS SELECT id FROM users;\nCREATE INDEX idx ON users (id);\n"
            ),
            vec![
                scope("table", "users", 1, 1),
                scope("view", "v", 2, 2),
                scope("index", "idx", 3, 3),
            ]
        );
        assert_eq!(
            scope_names(
                "a.proto",
                "message User {\n  message Inner { int32 x = 1; }\n}\nenum Kind { A = 0; }\nservice Users {\n  rpc Get(User) returns (User);\n}\n"
            ),
            vec![
                scope("message", "User", 1, 3),
                scope("message", "Inner", 2, 2),
                scope("enum", "Kind", 4, 4),
                scope("service", "Users", 5, 7),
                scope("method", "Get", 6, 6),
            ]
        );
        assert_eq!(
            scope_names(
                "a.graphql",
                "type Query {\n  a: Int\n}\ninterface Node { id: ID! }\nmutation Add { a }\nfragment F on Query { a }\n"
            ),
            vec![
                scope("type", "Query", 1, 3),
                scope("interface", "Node", 4, 4),
                scope("mutation", "Add", 5, 5),
                scope("fragment", "F", 6, 6),
            ]
        );
        assert_eq!(
            scope_names(
                "Makefile",
                "all: build\n\nbuild: main.c\n\tcc main.c\n\n.PHONY: all\n"
            ),
            vec![scope("target", "all", 1, 1), scope("target", "build", 3, 4)]
        );
        assert_eq!(
            scope_names(
                "Dockerfile",
                "FROM rust:1 AS build\nRUN cargo build\n\n# runtime\nFROM debian\nCOPY --from=build /a /b\n"
            ),
            vec![scope("stage", "build", 1, 2), scope("stage", "debian", 5, 6)]
        );
        assert_eq!(
            scope_names("a.scss", "@mixin pad($x) {\n  padding: $x;\n}\n@function twice($n) {\n  @return $n * 2;\n}\n"),
            vec![scope("mixin", "pad", 1, 3), scope("function", "twice", 4, 6)]
        );
    }
}
