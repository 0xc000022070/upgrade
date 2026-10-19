use imara_diff::{Algorithm, Diff, InternedInput};
use serde_json::{json, Value};
use std::path::Path;
use tree_sitter::{Language, Node, Parser, Tree, TreeCursor};

pub struct Grammar {
    pub name: &'static str,
    language: Language,
}

pub fn grammar_for(path: &str) -> Option<Grammar> {
    let path = Path::new(path);
    let file_name = path.file_name()?.to_str()?;
    let by_name = match file_name {
        "flake.lock" => Some("json"),
        "Cargo.lock" => Some("toml"),
        ".bashrc" | ".bash_profile" | ".profile" | ".envrc" => Some("bash"),
        _ => None,
    };
    let name = match by_name {
        Some(name) => name,
        None => match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
            "dart" => "dart",
            "rs" => "rust",
            "ts" | "mts" | "cts" => "typescript",
            "tsx" => "tsx",
            "js" | "mjs" | "cjs" | "jsx" => "javascript",
            "py" | "pyi" => "python",
            "go" => "go",
            "nix" => "nix",
            "sh" | "bash" => "bash",
            "json" | "jsonc" => "json",
            "yaml" | "yml" => "yaml",
            "toml" => "toml",
            "c" | "h" => "c",
            "cc" | "cpp" | "cxx" | "c++" | "hh" | "hpp" | "hxx" | "h++" => "cpp",
            "java" => "java",
            "kt" | "kts" => "kotlin",
            "lua" => "lua",
            "css" => "css",
            "html" | "htm" => "html",
            _ => return None,
        },
    };
    let language = match name {
        "dart" => tree_sitter_dart::LANGUAGE,
        "rust" => tree_sitter_rust::LANGUAGE,
        "typescript" => tree_sitter_typescript::LANGUAGE_TYPESCRIPT,
        "tsx" => tree_sitter_typescript::LANGUAGE_TSX,
        "javascript" => tree_sitter_javascript::LANGUAGE,
        "python" => tree_sitter_python::LANGUAGE,
        "go" => tree_sitter_go::LANGUAGE,
        "nix" => tree_sitter_nix::LANGUAGE,
        "bash" => tree_sitter_bash::LANGUAGE,
        "json" => tree_sitter_json::LANGUAGE,
        "yaml" => tree_sitter_yaml::LANGUAGE,
        "toml" => tree_sitter_toml_ng::LANGUAGE,
        "c" => tree_sitter_c::LANGUAGE,
        "cpp" => tree_sitter_cpp::LANGUAGE,
        "java" => tree_sitter_java::LANGUAGE,
        "kotlin" => tree_sitter_kotlin_ng::LANGUAGE,
        "lua" => tree_sitter_lua::LANGUAGE,
        "css" => tree_sitter_css::LANGUAGE,
        "html" => tree_sitter_html::LANGUAGE,
        _ => return None,
    };
    Some(Grammar {
        name,
        language: Language::new(language),
    })
}

pub struct Analysis {
    pub changed: Value,
    pub scopes: Value,
}

pub fn analyze(grammar: &Grammar, old: &str, new: &str) -> Option<Analysis> {
    let mut parser = Parser::new();
    parser.set_language(&grammar.language).ok()?;
    let old_tree = parser.parse(old, None)?;
    let new_tree = parser.parse(new, None)?;

    let old_atoms = atoms(&old_tree, old);
    let new_atoms = atoms(&new_tree, new);
    let mut input = InternedInput::default();
    input.update_before(old_atoms.iter().map(|atom| (atom.atomic, atom.text)));
    input.update_after(new_atoms.iter().map(|atom| (atom.atomic, atom.text)));
    let diff = Diff::compute(Algorithm::Histogram, &input);

    let old_changed = unmatched(&old_atoms, |index| diff.is_removed(index));
    let new_changed = unmatched(&new_atoms, |index| diff.is_added(index));
    Some(Analysis {
        changed: json!({
            "old": utf16_ranges(old, &old_changed),
            "new": utf16_ranges(new, &new_changed),
        }),
        scopes: json!({
            "old": scopes(grammar.name, &old_tree, old),
            "new": scopes(grammar.name, &new_tree, new),
        }),
    })
}

struct Atom<'a> {
    atomic: bool,
    text: &'a str,
    start: usize,
    end: usize,
}

fn is_atomic(node: Node) -> bool {
    let kind = node.kind();
    (node.is_named() || node.is_extra())
        && (kind.contains("string")
            || kind.contains("comment")
            || kind.contains("heredoc")
            || kind.ends_with("quote_scalar")
            || kind == "block_scalar"
            || kind == "text_block")
}

fn atoms<'a>(tree: &Tree, text: &'a str) -> Vec<Atom<'a>> {
    let mut found = Vec::new();
    let mut covered = 0;
    let mut cursor = tree.walk();
    loop {
        let node = cursor.node();
        let atomic = is_atomic(node);
        if !atomic && cursor.goto_first_child() {
            continue;
        }
        let (start, end) = (node.start_byte(), node.end_byte().min(text.len()));
        push_gap(&mut found, text, covered, start);
        covered = covered.max(end);
        if let Some(slice) = text.get(start..end) {
            push_leaf(&mut found, slice, start, atomic);
        }
        if !next_node(&mut cursor) {
            push_gap(&mut found, text, covered, text.len());
            return found;
        }
    }
}

fn push_gap<'a>(found: &mut Vec<Atom<'a>>, text: &'a str, from: usize, to: usize) {
    let Some(gap) = text.get(from..to) else {
        return;
    };
    let before = found.len();
    push_words(found, gap, from);
    let mut index = before;
    while index < found.len() {
        let atom = &found[index];
        let rest = &text[atom.end..];
        if atom.text == "\\" && (rest.starts_with('\n') || rest.starts_with("\r\n")) {
            found.remove(index);
        } else {
            index += 1;
        }
    }
}

fn push_leaf<'a>(found: &mut Vec<Atom<'a>>, slice: &'a str, start: usize, atomic: bool) {
    if !atomic {
        push_words(found, slice, start);
        return;
    }
    let trimmed = slice.trim();
    if trimmed.is_empty() {
        return;
    }
    let offset = start + (slice.len() - slice.trim_start().len());
    found.push(Atom {
        atomic: true,
        text: trimmed,
        start: offset,
        end: offset + trimmed.len(),
    });
}

fn next_node(cursor: &mut TreeCursor) -> bool {
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
                    atomic: false,
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
            atomic: false,
            text: &slice[start..],
            start: base + start,
            end: base + slice.len(),
        });
    }
}

fn unmatched(atoms: &[Atom], is_changed: impl Fn(u32) -> bool) -> Vec<(usize, usize)> {
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    for (index, atom) in atoms.iter().enumerate() {
        if !is_changed(index as u32) {
            continue;
        }
        match ranges.last_mut() {
            Some(last) if last.1 >= atom.start => last.1 = last.1.max(atom.end),
            _ => ranges.push((atom.start, atom.end)),
        }
    }
    ranges
}

fn utf16_ranges(text: &str, ranges: &[(usize, usize)]) -> Vec<[usize; 2]> {
    let mut byte = 0usize;
    let mut unit = 0usize;
    let mut advance = |target: usize| {
        for character in text[byte..].chars() {
            if byte >= target {
                break;
            }
            byte += character.len_utf8();
            unit += character.len_utf16();
        }
        unit
    };
    ranges
        .iter()
        .map(|&(start, end)| [advance(start), advance(end)])
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

fn slice<'a>(node: Node, text: &'a str) -> Option<&'a str> {
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
    if language == "dart" {
        return dart_scope(node, text);
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
            found.push(scope_json(node, kind, &name));
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

fn scope_json(node: Node, kind: &str, name: &str) -> Value {
    let start = node.start_position();
    let end = node.end_position();
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
    use super::*;

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
        ] {
            let grammar = grammar_for(path).unwrap_or_else(|| panic!("no grammar for {path}"));
            let analysis = analyze(&grammar, old, new)
                .unwrap_or_else(|| panic!("{} did not load", grammar.name));
            assert_eq!(
                analysis.changed,
                json!({ "old": [], "new": [] }),
                "{} saw a change in layout alone",
                grammar.name
            );
        }
    }
}
