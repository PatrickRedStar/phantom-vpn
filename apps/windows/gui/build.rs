//! Embed the Windows resource file (manifest, future icon) into the .exe.
//! `embed-resource` invokes rc.exe under MSVC and `windres` on
//! MinGW / cross-compile from a Mac. We only invoke it when the target
//! is Windows — Mac host builds skip resource embedding entirely.

fn main() {
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("windows") {
        embed_resource::compile("app.rc", embed_resource::NONE);
    }
}
