use super::syntax::{scope_json, slice, trimmed_end};
use serde_json::Value;
use tree_sitter::{Node, Tree};

pub fn scope(node: Node, text: &str) -> Option<(&'static str, String)> {
    let (kind, name) = markup_scope(node)
        .or_else(|| sql_scope(node))
        .or_else(|| proto_scope(node))
        .or_else(|| graphql_scope(node))?;
    let name = slice(name, text)?
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if name.is_empty() || kind == "target" && name.starts_with('.') {
        return None;
    }
    Some((kind, name))
}

fn child<'a>(node: Node<'a>, kinds: &[&str]) -> Option<Node<'a>> {
    let mut cursor = node.walk();
    let found = node
        .named_children(&mut cursor)
        .find(|child| kinds.contains(&child.kind()));
    found
}

fn markup_scope(node: Node) -> Option<(&'static str, Node)> {
    match node.kind() {
        "section" => {
            let heading = child(node, &["atx_heading", "setext_heading"])?;
            Some(("heading", child(heading, &["inline", "paragraph"])?))
        }
        "rule" => Some(("target", child(node, &["targets"])?)),
        "mixin_statement" => Some(("mixin", child(node, &["identifier"])?)),
        "function_statement" => Some(("function", child(node, &["identifier"])?)),
        _ => None,
    }
}

fn sql_scope(node: Node) -> Option<(&'static str, Node)> {
    let kind = match node.kind() {
        "create_table" => "table",
        "create_view" | "create_materialized_view" => "view",
        "create_function" => "function",
        "create_index" => "index",
        "create_type" => "type",
        "create_schema" => "schema",
        "create_sequence" => "sequence",
        "create_trigger" => "trigger",
        "create_database" => "database",
        _ => return None,
    };
    Some((kind, child(node, &["object_reference", "identifier"])?))
}

fn proto_scope(node: Node) -> Option<(&'static str, Node)> {
    let (kind, name) = match node.kind() {
        "message" => ("message", "message_name"),
        "service" => ("service", "service_name"),
        "enum" => ("enum", "enum_name"),
        "rpc" => ("method", "rpc_name"),
        _ => return None,
    };
    Some((kind, child(node, &[name])?))
}

fn graphql_scope(node: Node) -> Option<(&'static str, Node)> {
    let kind = match node.kind() {
        "object_type_definition" | "object_type_extension" => "type",
        "interface_type_definition" => "interface",
        "enum_type_definition" => "enum",
        "input_object_type_definition" => "input",
        "union_type_definition" => "union",
        "scalar_type_definition" => "scalar",
        "directive_definition" => "directive",
        "fragment_definition" => "fragment",
        "operation_definition" => match child(node, &["operation_type"]) {
            Some(operation) if operation.child(0)?.kind() == "mutation" => "mutation",
            Some(operation) if operation.child(0)?.kind() == "subscription" => "subscription",
            _ => "query",
        },
        _ => return None,
    };
    Some((kind, child(node, &["name", "fragment_name"])?))
}

pub fn stages(tree: &Tree, text: &str) -> Vec<Value> {
    let root = tree.root_node();
    let mut cursor = root.walk();
    let instructions: Vec<Node> = root.named_children(&mut cursor).collect();
    let starts: Vec<usize> = instructions
        .iter()
        .enumerate()
        .filter(|(_, node)| node.kind() == "from_instruction")
        .map(|(index, _)| index)
        .collect();
    starts
        .iter()
        .enumerate()
        .filter_map(|(order, &first)| {
            let next = starts.get(order + 1).copied().unwrap_or(instructions.len());
            let from = instructions[first];
            let last = instructions[first..next]
                .iter()
                .rev()
                .find(|node| node.kind() != "comment")
                .unwrap_or(&from);
            let name = child(from, &["image_alias"]).or_else(|| child(from, &["image_spec"]))?;
            Some(scope_json(
                from.start_position(),
                trimmed_end(*last, text),
                "stage",
                slice(name, text)?,
            ))
        })
        .collect()
}
