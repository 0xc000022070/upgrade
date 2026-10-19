use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};

const BINARY: &str = env!("CARGO_BIN_EXE_strikedddd");
static COUNTER: AtomicU32 = AtomicU32::new(0);

struct Sandbox {
    root: PathBuf,
    repo: PathBuf,
    owner: String,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!(
            "strikedddd-git-{}-{name}-{unique}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("state")).unwrap();
        fs::create_dir_all(root.join("home")).unwrap();
        let repo = root.join("repo");
        fs::create_dir_all(&repo).unwrap();
        let mut sandbox = Self {
            root,
            repo,
            owner: String::new(),
        };
        sandbox.owner = sandbox.raw(json!({ "service": "lifecycle", "op": "probe" }))["result"]
            ["owner"]
            .as_str()
            .unwrap()
            .to_owned();
        sandbox.git(&["init", "--quiet"]);
        sandbox
    }

    fn raw(&self, request: Value) -> Value {
        let mut child = Command::new(BINARY)
            .env("STRIKEDDDD_STATE", self.root.join("state"))
            .env("HOME", self.root.join("home"))
            .env("XDG_CONFIG_HOME", self.root.join("home/config"))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env_remove("STRIKEDDDD_CONFIG")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(request.to_string().as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }

    fn git(&self, args: &[&str]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(&self.repo)
            .args([
                "-c",
                "user.name=Striked",
                "-c",
                "user.email=striked@example.invalid",
            ])
            .args([
                "-c",
                "commit.gpgsign=false",
                "-c",
                "init.defaultBranch=main",
            ])
            .args(args)
            .env("HOME", self.root.join("home"))
            .env("XDG_CONFIG_HOME", self.root.join("home/config"))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap().trim().to_owned()
    }

    fn write(&self, path: &str, contents: impl AsRef<[u8]>) {
        let target = self.repo.join(path);
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(target, contents).unwrap();
    }

    fn commit(&self, message: &str) -> String {
        self.git(&["add", "--all"]);
        self.git(&["commit", "--quiet", "--allow-empty", "-m", message]);
        self.git(&["rev-parse", "HEAD"])
    }

    fn diff(&self, args: Value) -> Value {
        let answer = self
            .raw(json!({ "service": "git/1", "op": "diff", "owner": self.owner, "args": args }));
        assert_eq!(answer["ok"], json!(true), "{answer}");
        answer["result"].clone()
    }

    fn worktree(&self, files: Value) -> Value {
        self.diff(json!({
            "directory": self.repo.to_str().unwrap(),
            "commit": null,
            "files": files,
        }))
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn utf16_span(text: &str, token: &str) -> Value {
    let byte = text.find(token).unwrap();
    let start = text[..byte].encode_utf16().count();
    json!([start, start + token.encode_utf16().count()])
}

fn texts<'a>(file: &'a Value, side: &str, text: &'a str) -> Vec<&'a str> {
    file["changed"][side]
        .as_array()
        .unwrap()
        .iter()
        .map(|range| {
            let units: Vec<u16> = text.encode_utf16().collect();
            let (start, end) = (range[0].as_u64().unwrap(), range[1].as_u64().unwrap());
            let prefix = String::from_utf16(&units[..start as usize]).unwrap();
            let token = String::from_utf16(&units[start as usize..end as usize]).unwrap();
            &text[prefix.len()..prefix.len() + token.len()]
        })
        .collect()
}

#[test]
fn a_reflowed_line_has_no_changes_on_either_side() {
    let sandbox = Sandbox::new("reflow");
    sandbox.write("lib/pick.dart", "int pick() {\n  return a ? b : c;\n}\n");
    sandbox.commit("one line");
    sandbox.write(
        "lib/pick.dart",
        "int pick() {\n  return a\n      ? b\n      : c;\n}\n",
    );

    let result = sandbox.worktree(json!([{ "path": "lib/pick.dart", "origin": null }]));
    let file = &result["files"][0];
    assert_eq!(file["language"], json!("dart"));
    assert_eq!(file["skipped"], json!(null));
    assert_eq!(file["old"], json!("int pick() {\n  return a ? b : c;\n}\n"));
    assert_eq!(file["changed"], json!({ "old": [], "new": [] }));
    assert_eq!(result["capped"], json!(false));
}

#[test]
fn a_dropped_brace_is_the_only_change_though_the_tree_recovers_around_it() {
    let sandbox = Sandbox::new("dangling");
    let old = "class Foo {\n  void bump() {\n    n++;\n  }\n}\n\nclass Bar {\n  int size = 1;\n}\n";
    sandbox.write("lib/foo.dart", old);
    sandbox.commit("braces");
    let new = old.replacen("    n++;\n  }\n", "    n++;\n", 1);
    sandbox.write("lib/foo.dart", &new);

    let result = sandbox.worktree(json!([{ "path": "lib/foo.dart", "origin": null }]));
    let file = &result["files"][0];
    assert_eq!(texts(file, "old", old), vec!["}"]);
    assert_eq!(texts(file, "new", &new), Vec::<&str>::new());
}

#[test]
fn a_renamed_identifier_is_the_only_change_and_offsets_count_utf16() {
    let sandbox = Sandbox::new("rename");
    let old = "void main() {\n  var face = '😀';\n  var alpha = 1;\n  print(alpha + 2);\n}\n";
    let new = "void main() {\n  var face = '😀';\n  var beta = 1;\n  print(alpha + 2);\n}\n";
    sandbox.write("app/main.dart", old);
    sandbox.commit("alpha");
    sandbox.write("app/main.dart", new);
    let sha = sandbox.commit("beta");

    let result = sandbox.diff(json!({
        "directory": sandbox.repo.join("app").to_str().unwrap(),
        "commit": sha,
        "files": [{ "path": "app/main.dart", "origin": null }],
    }));
    let file = &result["files"][0];
    assert_eq!(file["old"], json!(old));
    assert_eq!(file["new"], json!(new));
    assert_eq!(file["changed"]["old"], json!([utf16_span(old, "alpha")]));
    assert_eq!(file["changed"]["new"], json!([utf16_span(new, "beta")]));
    assert_ne!(utf16_span(new, "beta")[0], json!(new.find("beta").unwrap()));
    assert_eq!(texts(file, "new", new), vec!["beta"]);
}

#[test]
fn scopes_name_dart_classes_and_methods_and_rust_impls() {
    let sandbox = Sandbox::new("scopes");
    sandbox.commit("empty");
    let dart = "class Greeter {\n  String greet() {\n    return 'hi';\n  }\n}\n";
    let rust = "struct Point;\n\nimpl Point {\n    fn origin() -> Self {\n        Point\n    }\n}\n\nfn main() {}\n";
    sandbox.write("greeter.dart", dart);
    sandbox.write("src/point.rs", rust);

    let result = sandbox.worktree(json!([
        { "path": "greeter.dart", "origin": null },
        { "path": "src/point.rs", "origin": null },
    ]));
    let dart_file = &result["files"][0];
    assert_eq!(dart_file["old"], json!(null));
    assert_eq!(dart_file["scopes"]["old"], json!([]));
    assert_eq!(
        dart_file["scopes"]["new"],
        json!([
            { "line": 1, "end": 5, "name": "Greeter", "kind": "class" },
            { "line": 2, "end": 4, "name": "greet", "kind": "method" },
        ])
    );

    let rust_file = &result["files"][1];
    assert_eq!(rust_file["language"], json!("rust"));
    assert_eq!(
        rust_file["scopes"]["new"],
        json!([
            { "line": 1, "end": 1, "name": "Point", "kind": "struct" },
            { "line": 3, "end": 7, "name": "Point", "kind": "impl" },
            { "line": 4, "end": 6, "name": "origin", "kind": "method" },
            { "line": 9, "end": 9, "name": "main", "kind": "function" },
        ])
    );
}

#[test]
fn added_deleted_and_renamed_files_resolve_each_side() {
    let sandbox = Sandbox::new("sides");
    sandbox.write("gone.py", "def gone():\n    pass\n");
    sandbox.write("before.rs", "fn kept() {}\n");
    sandbox.commit("base");
    fs::remove_file(sandbox.repo.join("gone.py")).unwrap();
    fs::rename(
        sandbox.repo.join("before.rs"),
        sandbox.repo.join("after.rs"),
    )
    .unwrap();
    sandbox.write("fresh.go", "package main\n");
    sandbox.write("notes.txt", "plain\n");

    let result = sandbox.worktree(json!([
        { "path": "gone.py", "origin": null },
        { "path": "fresh.go", "origin": null },
        { "path": "after.rs", "origin": "before.rs" },
        { "path": "notes.txt" },
    ]));
    let files = result["files"].as_array().unwrap();

    assert_eq!(files[0]["old"], json!("def gone():\n    pass\n"));
    assert_eq!(files[0]["new"], json!(null));
    assert_eq!(files[0]["changed"]["new"], json!([]));
    assert_eq!(
        files[0]["changed"]["old"],
        json!([[0, 3], [4, 11], [16, 20]])
    );

    assert_eq!(files[1]["old"], json!(null));
    assert_eq!(files[1]["new"], json!("package main\n"));
    assert_eq!(files[1]["changed"]["new"], json!([[0, 7], [8, 12]]));

    assert_eq!(files[2]["origin"], json!("before.rs"));
    assert_eq!(files[2]["old"], json!("fn kept() {}\n"));
    assert_eq!(files[2]["changed"], json!({ "old": [], "new": [] }));

    assert_eq!(files[3]["language"], json!(null));
    assert_eq!(files[3]["new"], json!("plain\n"));
    assert!(files[3].get("changed").is_none());
    assert!(files[3].get("scopes").is_none());
}

#[test]
fn binary_and_large_files_are_skipped_without_their_text() {
    let sandbox = Sandbox::new("skipped");
    sandbox.write("image.dart", b"class A {}\n\0\x01\x02");
    sandbox.write("latin1.txt", [0x63_u8, 0x61, 0x66, 0xe9]);
    sandbox.write("big.json", format!("[{}0]", "0,".repeat(300 * 1024)));
    sandbox.commit("blobs");

    let result = sandbox.worktree(json!([
        { "path": "image.dart", "origin": null },
        { "path": "latin1.txt", "origin": null },
        { "path": "big.json", "origin": null },
    ]));
    let files = result["files"].as_array().unwrap();
    assert_eq!(files[0]["skipped"], json!("binary"));
    assert_eq!(files[1]["skipped"], json!("binary"));
    assert_eq!(files[2]["skipped"], json!("large"));
    for file in files {
        assert!(file.get("old").is_none(), "{file}");
        assert!(file.get("new").is_none(), "{file}");
        assert_eq!(file["language"], json!(null));
    }
    assert_eq!(result["capped"], json!(false));
}

#[test]
fn the_budget_stops_at_the_file_that_would_overrun_it() {
    let sandbox = Sandbox::new("budget");
    sandbox.commit("empty");
    sandbox.write("a.toml", "a = 1\n");
    sandbox.write("b.toml", "b = 22222222222222222222\n");
    sandbox.write("c.toml", "c = 3\n");

    let result = sandbox.diff(json!({
        "directory": sandbox.repo.to_str().unwrap(),
        "commit": null,
        "max_bytes": 16,
        "files": [
            { "path": "a.toml", "origin": null },
            { "path": "b.toml", "origin": null },
            { "path": "c.toml", "origin": null },
        ],
    }));
    let files = result["files"].as_array().unwrap();
    assert_eq!(files[0]["new"], json!("a = 1\n"));
    assert_eq!(files[0]["skipped"], json!(null));
    assert_eq!(files[1]["skipped"], json!("budget"));
    assert_eq!(files[2]["skipped"], json!("budget"));
    assert_eq!(result["capped"], json!(true));
}

#[test]
fn a_commit_with_no_parent_has_no_old_side() {
    let sandbox = Sandbox::new("root");
    sandbox.write("first.nix", "{ x = 1; }\n");
    let sha = sandbox.commit("root");

    let result = sandbox.diff(json!({
        "directory": sandbox.repo.to_str().unwrap(),
        "commit": &sha[..12],
        "files": [{ "path": "first.nix", "origin": null }],
    }));
    let file = &result["files"][0];
    assert_eq!(file["old"], json!(null));
    assert_eq!(file["new"], json!("{ x = 1; }\n"));
    assert_eq!(file["language"], json!("nix"));
}

#[test]
fn diff_refuses_what_it_cannot_resolve_and_writes_nothing() {
    let sandbox = Sandbox::new("refused");
    sandbox.write("kept.rs", "fn kept() {}\n");
    sandbox.commit("base");
    let status_before = sandbox.git(&["status", "--porcelain"]);
    let head_before = sandbox.git(&["rev-parse", "HEAD"]);

    let call = |args: Value| {
        sandbox
            .raw(json!({ "service": "git/1", "op": "diff", "owner": sandbox.owner, "args": args }))
    };
    let repo = sandbox.repo.to_str().unwrap().to_owned();
    let files = json!([{ "path": "kept.rs", "origin": null }]);

    let outside =
        call(json!({ "directory": sandbox.root.join("home").to_str().unwrap(), "files": files }));
    assert_eq!(outside["error"]["kind"], json!("not_found"), "{outside}");

    let option = call(json!({ "directory": repo, "commit": "--output=/tmp/x", "files": files }));
    assert_eq!(option["error"]["kind"], json!("bad_request"), "{option}");

    let unknown = call(json!({ "directory": repo, "commit": "deadbeefdeadbeef", "files": files }));
    assert_eq!(unknown["error"]["kind"], json!("not_found"), "{unknown}");

    let escaping = call(json!({ "directory": repo, "files": [{ "path": "../outside.rs" }] }));
    assert_eq!(
        escaping["error"]["kind"],
        json!("bad_request"),
        "{escaping}"
    );

    let relative = call(json!({ "directory": "repo", "files": files }));
    assert_eq!(
        relative["error"]["kind"],
        json!("bad_request"),
        "{relative}"
    );

    assert_eq!(sandbox.git(&["status", "--porcelain"]), status_before);
    assert_eq!(sandbox.git(&["rev-parse", "HEAD"]), head_before);
}
