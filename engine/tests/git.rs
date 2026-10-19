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

#[test]
fn against_picks_the_index_or_the_staged_side() {
    let sandbox = Sandbox::new("against");
    sandbox.write("a.py", "x = 1\n");
    sandbox.commit("one");
    sandbox.write("a.py", "x = 2\n");
    sandbox.git(&["add", "a.py"]);
    sandbox.write("a.py", "x = 3\n");
    let files = json!([{ "path": "a.py", "origin": null }]);
    let call = |against: Value| {
        let result = sandbox.diff(json!({
            "directory": sandbox.repo.to_str().unwrap(),
            "commit": null,
            "against": against,
            "files": files,
        }));
        let file = &result["files"][0];
        (file["old"].clone(), file["new"].clone())
    };

    assert_eq!(call(json!(null)), (json!("x = 1\n"), json!("x = 3\n")));
    assert_eq!(call(json!("head")), (json!("x = 1\n"), json!("x = 3\n")));
    assert_eq!(call(json!("index")), (json!("x = 2\n"), json!("x = 3\n")));
    assert_eq!(call(json!("staged")), (json!("x = 1\n"), json!("x = 2\n")));

    let sha = sandbox.commit("two");
    let pinned = sandbox.diff(json!({
        "directory": sandbox.repo.to_str().unwrap(),
        "commit": sha,
        "against": "index",
        "files": files,
    }));
    assert_eq!(pinned["files"][0]["old"], json!("x = 1\n"));
    assert_eq!(pinned["files"][0]["new"], json!("x = 3\n"));

    let refused = sandbox.raw(json!({
        "service": "git/1",
        "op": "diff",
        "owner": sandbox.owner,
        "args": { "directory": sandbox.repo.to_str().unwrap(), "against": "theirs", "files": files },
    }));
    assert_eq!(refused["error"]["kind"], json!("bad_request"), "{refused}");
}

#[test]
fn each_side_carries_its_blob_id() {
    let sandbox = Sandbox::new("oids");
    sandbox.write("kept.rs", "fn a() {}\n");
    sandbox.write("gone.rs", "fn b() {}\n");
    sandbox.write("\"quoted\".txt", "q\n");
    sandbox.commit("base");
    sandbox.write("kept.rs", "fn a() { 1 }\n");
    sandbox.write("\"quoted\".txt", "r\n");
    sandbox.write("big.json", format!("[{}0]", "0,".repeat(300 * 1024)));
    fs::remove_file(sandbox.repo.join("gone.rs")).unwrap();
    std::os::unix::fs::symlink("kept.rs", sandbox.repo.join("link")).unwrap();

    let result = sandbox.worktree(json!([
        { "path": "kept.rs", "origin": null },
        { "path": "gone.rs", "origin": null },
        { "path": "\"quoted\".txt", "origin": null },
        { "path": "big.json", "origin": null },
        { "path": "link", "origin": null },
    ]));
    let files = result["files"].as_array().unwrap();
    let head = |path: &str| json!(sandbox.git(&["rev-parse", &format!("HEAD:{path}")]));
    let hashed = |path: &str| json!(sandbox.git(&["hash-object", "--", path]));

    assert_eq!(files[0]["old_oid"], head("kept.rs"));
    assert_eq!(files[0]["new_oid"], hashed("kept.rs"));
    assert_ne!(files[0]["old_oid"], files[0]["new_oid"]);
    assert_eq!(files[1]["old_oid"], head("gone.rs"));
    assert_eq!(files[1]["new_oid"], json!(null));
    assert_eq!(files[2]["new_oid"], hashed("\"quoted\".txt"));
    assert_eq!(files[3]["skipped"], json!("large"));
    assert_eq!(files[3]["old_oid"], json!(null));
    assert_eq!(files[3]["new_oid"], hashed("big.json"));
    assert_eq!(files[4]["new"], json!("kept.rs"));
    sandbox.git(&["add", "link"]);
    assert_eq!(
        files[4]["new_oid"],
        json!(sandbox.git(&["rev-parse", ":link"]))
    );
}

#[test]
fn an_image_comes_back_as_base64_on_each_side() {
    let sandbox = Sandbox::new("images");
    let png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    sandbox.write("icon.png", &png);
    sandbox.commit("icon");
    let mut grown = png.clone();
    grown.extend_from_slice(&[0, 1, 2, 3]);
    sandbox.write("icon.png", &grown);

    let result = sandbox.worktree(json!([{ "path": "icon.png", "origin": null }]));
    let icon = &result["files"][0];
    assert_eq!(icon["old"], json!(null));
    assert_eq!(icon["new"], json!(null));
    assert_eq!(icon["skipped"], json!(null));
    assert_eq!(icon["language"], json!(null));
    assert!(icon.get("changed").is_none());
    assert_eq!(
        icon["image"],
        json!({
            "old": "iVBORw0KGgoAAAANSUhEUg==",
            "new": "iVBORw0KGgoAAAANSUhEUgABAgM=",
            "mime": "image/png",
        })
    );
}

#[test]
fn images_have_their_own_size_limit_and_svg_stays_text() {
    let sandbox = Sandbox::new("image-limits");
    sandbox.write("huge.jpg", vec![0xffu8; 3 * 1024 * 1024]);
    sandbox.commit("huge");
    sandbox.write("fresh.webp", vec![0x52u8; 600 * 1024]);
    sandbox.write("logo.svg", "<svg><path d=\"M0 0\"/></svg>\n");

    let result = sandbox.diff(json!({
        "directory": sandbox.repo.to_str().unwrap(),
        "commit": null,
        "max_bytes": 8 * 1024 * 1024,
        "files": [
            { "path": "huge.jpg", "origin": null },
            { "path": "fresh.webp", "origin": null },
            { "path": "logo.svg", "origin": null },
        ],
    }));
    let files = result["files"].as_array().unwrap();
    assert_eq!(files[0]["skipped"], json!("large"));
    assert!(files[0].get("image").is_none());

    let fresh = &files[1]["image"];
    assert_eq!(
        (&fresh["old"], &fresh["mime"]),
        (&json!(null), &json!("image/webp"))
    );
    let encoded = fresh["new"].as_str().unwrap().len();
    assert_eq!(encoded, (600 * 1024usize).div_ceil(3) * 4);

    assert_eq!(files[2]["new"], json!("<svg><path d=\"M0 0\"/></svg>\n"));
    assert!(files[2].get("image").is_none());
}

#[test]
fn a_script_without_an_extension_is_read_by_its_shebang_and_highlighted() {
    let sandbox = Sandbox::new("shebang");
    sandbox.commit("empty");
    let script = "#!/usr/bin/env python3\ndef main():\n    return 'ok'  # done\n";
    sandbox.write("bin/tool", script);
    sandbox.write("notes", "just words\n");

    let result = sandbox.worktree(json!([
        { "path": "bin/tool", "origin": null },
        { "path": "notes", "origin": null },
    ]));
    let tool = &result["files"][0];
    assert_eq!(tool["language"], json!("python"));
    assert_eq!(
        tool["scopes"]["new"],
        json!([{ "line": 2, "end": 3, "name": "main", "kind": "function" }])
    );
    assert_eq!(tool["highlight"]["old"], json!([]));
    let runs = tool["highlight"]["new"].as_array().unwrap();
    let kind_of = |token: &str| {
        let span = utf16_span(script, token);
        runs.iter()
            .find(|run| run[0] == span[0] && run[1] == span[1])
            .map(|run| run[2].clone())
    };
    assert_eq!(kind_of("def"), Some(json!("keyword")));
    assert_eq!(kind_of("main"), Some(json!("function")));
    assert_eq!(kind_of("'ok'"), Some(json!("string")));
    assert_eq!(kind_of("# done"), Some(json!("comment")));

    let notes = &result["files"][1];
    assert_eq!(notes["language"], json!(null));
    assert!(notes.get("highlight").is_none());
}
