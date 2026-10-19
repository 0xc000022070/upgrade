use std::path::Path;
use tree_sitter::Language;
use tree_sitter_language::LanguageFn;

pub struct Grammar {
    pub name: &'static str,
    pub language: Language,
    pub highlights: &'static [&'static str],
}

pub fn grammar_for(path: &str, first_line: Option<&str>) -> Option<Grammar> {
    let name = name_for_path(path).or_else(|| first_line.and_then(name_for_shebang))?;
    let (language, highlights) = parts(name);
    Some(Grammar {
        name,
        language,
        highlights,
    })
}

fn name_for_path(path: &str) -> Option<&'static str> {
    let path = Path::new(path);
    let file_name = path.file_name()?.to_str()?;
    if let Some(name) = name_for_file_name(file_name) {
        return Some(name);
    }
    name_for_extension(&path.extension()?.to_str()?.to_ascii_lowercase())
}

fn name_for_file_name(file_name: &str) -> Option<&'static str> {
    let name = match file_name {
        "flake.lock" => "json",
        "Cargo.lock" => "toml",
        ".bashrc" | ".bash_profile" | ".profile" | ".envrc" | ".zshrc" | ".zprofile" => "bash",
        "Dockerfile" | "Containerfile" | "dockerfile" | "containerfile" => "dockerfile",
        "Makefile" | "makefile" | "GNUmakefile" => "make",
        _ if file_name.starts_with("Dockerfile.") || file_name.starts_with("Containerfile.") => {
            "dockerfile"
        }
        _ => return None,
    };
    Some(name)
}

fn name_for_extension(extension: &str) -> Option<&'static str> {
    let name = match extension {
        "dart" => "dart",
        "rs" => "rust",
        "ts" | "mts" | "cts" => "typescript",
        "tsx" => "tsx",
        "js" | "mjs" | "cjs" | "jsx" => "javascript",
        "py" | "pyi" => "python",
        "go" => "go",
        "nix" => "nix",
        "sh" | "bash" | "zsh" => "bash",
        "json" | "jsonc" => "json",
        "yaml" | "yml" => "yaml",
        "toml" => "toml",
        "c" | "h" => "c",
        "cc" | "cpp" | "cxx" | "c++" | "hh" | "hpp" | "hxx" | "h++" => "cpp",
        "java" => "java",
        "kt" | "kts" => "kotlin",
        "lua" => "lua",
        "css" => "css",
        "scss" => "scss",
        "html" | "htm" => "html",
        "md" | "markdown" => "markdown",
        "dockerfile" | "containerfile" => "dockerfile",
        "mk" | "make" => "make",
        "sql" => "sql",
        "xml" | "xsd" | "xsl" | "xslt" | "svg" | "plist" | "csproj" | "fsproj" | "xaml" => "xml",
        "proto" => "proto",
        "graphql" | "graphqls" | "gql" => "graphql",
        _ => return None,
    };
    Some(name)
}

fn name_for_shebang(line: &str) -> Option<&'static str> {
    let mut words = line.strip_prefix("#!")?.split_whitespace();
    let mut program = base_name(words.next()?);
    if program == "env" {
        program = base_name(words.find(|word| !word.starts_with('-') && !word.contains('='))?);
    }
    let name = match program.trim_end_matches(|c: char| c.is_ascii_digit() || c == '.') {
        "python" | "pypy" => "python",
        "sh" | "bash" | "zsh" | "dash" | "ksh" | "ash" | "mksh" => "bash",
        "node" | "nodejs" | "deno" | "bun" => "javascript",
        "ts-node" | "tsx" => "typescript",
        "lua" | "luajit" => "lua",
        "make" | "gmake" => "make",
        _ => return None,
    };
    Some(name)
}

fn base_name(program: &str) -> &str {
    program.rsplit('/').next().unwrap_or(program)
}

type Parts = (LanguageFn, &'static [&'static str]);

fn parts(name: &'static str) -> (Language, &'static [&'static str]) {
    if name == "scss" {
        return (
            tree_sitter_scss::language(),
            &[tree_sitter_scss::HIGHLIGHTS_QUERY],
        );
    }
    let (language, highlights) = code_parts(name)
        .or_else(|| data_parts(name))
        .expect("named grammar");
    (Language::new(language), highlights)
}

fn code_parts(name: &str) -> Option<Parts> {
    use tree_sitter_javascript::{HIGHLIGHT_QUERY as JS, JSX_HIGHLIGHT_QUERY as JSX};
    let parts: Parts = match name {
        "dart" => (
            tree_sitter_dart::LANGUAGE,
            &[tree_sitter_dart::HIGHLIGHTS_QUERY],
        ),
        "rust" => (
            tree_sitter_rust::LANGUAGE,
            &[tree_sitter_rust::HIGHLIGHTS_QUERY],
        ),
        "typescript" => (
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT,
            &[JS, tree_sitter_typescript::HIGHLIGHTS_QUERY],
        ),
        "tsx" => (
            tree_sitter_typescript::LANGUAGE_TSX,
            &[JS, JSX, tree_sitter_typescript::HIGHLIGHTS_QUERY],
        ),
        "javascript" => (tree_sitter_javascript::LANGUAGE, &[JS, JSX]),
        "python" => (
            tree_sitter_python::LANGUAGE,
            &[tree_sitter_python::HIGHLIGHTS_QUERY],
        ),
        "go" => (
            tree_sitter_go::LANGUAGE,
            &[tree_sitter_go::HIGHLIGHTS_QUERY],
        ),
        "nix" => (
            tree_sitter_nix::LANGUAGE,
            &[tree_sitter_nix::HIGHLIGHTS_QUERY],
        ),
        "bash" => (
            tree_sitter_bash::LANGUAGE,
            &[tree_sitter_bash::HIGHLIGHT_QUERY],
        ),
        "c" => (tree_sitter_c::LANGUAGE, &[tree_sitter_c::HIGHLIGHT_QUERY]),
        "cpp" => (
            tree_sitter_cpp::LANGUAGE,
            &[
                tree_sitter_c::HIGHLIGHT_QUERY,
                tree_sitter_cpp::HIGHLIGHT_QUERY,
            ],
        ),
        "java" => (
            tree_sitter_java::LANGUAGE,
            &[tree_sitter_java::HIGHLIGHTS_QUERY],
        ),
        "kotlin" => (tree_sitter_kotlin_ng::LANGUAGE, &[]),
        "lua" => (
            tree_sitter_lua::LANGUAGE,
            &[tree_sitter_lua::HIGHLIGHTS_QUERY],
        ),
        "proto" => (tree_sitter_proto::LANGUAGE, &[]),
        "graphql" => (tree_sitter_graphql::LANGUAGE, &[]),
        "sql" => (
            tree_sitter_sequel::LANGUAGE,
            &[tree_sitter_sequel::HIGHLIGHTS_QUERY],
        ),
        _ => return None,
    };
    Some(parts)
}

fn data_parts(name: &str) -> Option<Parts> {
    let parts: Parts = match name {
        "json" => (
            tree_sitter_json::LANGUAGE,
            &[tree_sitter_json::HIGHLIGHTS_QUERY],
        ),
        "yaml" => (
            tree_sitter_yaml::LANGUAGE,
            &[tree_sitter_yaml::HIGHLIGHTS_QUERY],
        ),
        "toml" => (
            tree_sitter_toml_ng::LANGUAGE,
            &[tree_sitter_toml_ng::HIGHLIGHTS_QUERY],
        ),
        "css" => (
            tree_sitter_css::LANGUAGE,
            &[tree_sitter_css::HIGHLIGHTS_QUERY],
        ),
        "html" => (
            tree_sitter_html::LANGUAGE,
            &[tree_sitter_html::HIGHLIGHTS_QUERY],
        ),
        "markdown" => (
            tree_sitter_md::LANGUAGE,
            &[tree_sitter_md::HIGHLIGHT_QUERY_BLOCK],
        ),
        "dockerfile" => (
            tree_sitter_containerfile::LANGUAGE,
            &[tree_sitter_containerfile::HIGHLIGHTS_QUERY],
        ),
        "make" => (
            tree_sitter_make::LANGUAGE,
            &[tree_sitter_make::HIGHLIGHTS_QUERY],
        ),
        "xml" => (
            tree_sitter_xml::LANGUAGE_XML,
            &[tree_sitter_xml::XML_HIGHLIGHT_QUERY],
        ),
        _ => return None,
    };
    Some(parts)
}
