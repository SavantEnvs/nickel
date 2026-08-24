//! `eval` — parses, typechecks (lazily, gradual-typing style, matching the `nickel eval` CLI
//! path), and fully evaluates arbitrary bytes as Nickel source, via the same public
//! `ProgramBuilder`/`Program` API the `nickel` CLI uses (`Program::eval_full`, i.e. `nickel
//! export`'s evaluation path without the serialization step). Exercises the whole pipeline:
//! lexer, parser, typechecker, and the lazy evaluator (thunks, merging, contracts, stdlib).
#![no_main]

use libfuzzer_sys::fuzz_target;
use nickel_lang_core::{eval::cache::CacheImpl, program::ProgramBuilder};

fuzz_target!(|data: &[u8]| {
    // Nickel is Turing-complete (recursive lets/records, contracts implemented as functions,
    // stdlib recursion) — an enormous input mostly just re-explores stack-depth/step-count
    // territory, not new evaluator logic. Keep it cheap so corpus growth stays meaningful; Mayhem's
    // per-exec timeout bounds any hang.
    if data.len() > 4096 {
        return;
    }
    let Ok(src) = std::str::from_utf8(data) else {
        return;
    };

    let Ok(mut program) = ProgramBuilder::new()
        .add_source_string(src, "fuzz-eval")
        .build::<CacheImpl>()
    else {
        return;
    };

    let _ = program.eval_full();
});
