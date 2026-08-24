//! `parse_typecheck` — feeds arbitrary bytes through Nickel's lexer, parser, and (enforcing)
//! typechecker via the same public `ProgramBuilder`/`Program` API the `nickel` CLI uses
//! (`nickel typecheck --strict`, i.e. `TypecheckMode::Enforce`). No evaluation happens here —
//! this target is about grammar/typing robustness, not the interpreter.
#![no_main]

use libfuzzer_sys::fuzz_target;
use nickel_lang_core::{eval::cache::CacheImpl, program::ProgramBuilder, typecheck::TypecheckMode};

fuzz_target!(|data: &[u8]| {
    // Parsing/typechecking is not free-of-recursion either (nested types, nested records), so
    // cap input size to keep exploration in "new logic" territory rather than "how deep can the
    // parser's own AST recursion go before the native stack gives up" territory.
    if data.len() > 8192 {
        return;
    }
    let Ok(src) = std::str::from_utf8(data) else {
        return;
    };

    let Ok(mut program) = ProgramBuilder::new()
        .add_source_string(src, "fuzz-parse-typecheck")
        .build::<CacheImpl>()
    else {
        return;
    };

    let _ = program.typecheck(TypecheckMode::Enforce);
});
