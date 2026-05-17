//! Build script:
//!   1. Compile the Slint UI (.slint → generated Rust types).
//!   2. Embed the Windows resource file (manifest, future icon) into the
//!      .exe via `embed-resource`. Driven by TARGET env var, not by
//!      `cfg(windows)`, since build scripts evaluate cfg against the
//!      host, not the target.

fn main() {
    // Always compile the Slint UI — the generated module is referenced
    // through `slint::include_modules!()` on every target (the binary
    // runs only on Windows, but headless `cargo check --target` on Mac
    // still wants the module to exist).
    slint_build::compile("ui/main.slint").expect("compile Slint UI");

    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("windows") {
        embed_resource::compile("app.rc", embed_resource::NONE);
    }
}
