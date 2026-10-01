fn main() {
    println!("cargo:rerun-if-env-changed=GHOSTTY_VT_LIB_DIR");
    let Some(dir) = std::env::var_os("GHOSTTY_VT_LIB_DIR") else {
        panic!("GHOSTTY_VT_LIB_DIR must name the directory holding libghostty-vt.a; the dev shell sets it");
    };
    println!("cargo:rustc-link-search=native={}", dir.to_string_lossy());
    println!("cargo:rustc-link-lib=static=ghostty-vt");
}
