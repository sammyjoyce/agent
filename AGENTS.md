# Working on Beep Boop

Keep the application small and use upstream Pi for model and conversation
machinery. Rust owns application types; generate TypeScript protocol bindings.
Use explicit state and ownership transitions, with errors instead of panics.

Use Nix for development. Run formatting, Clippy and relevant behavioral tests.
Test real producers, consumers and lifecycle boundaries. Use the iOS 27.3
Simulator for iOS builds, tests and checks. Keep real accounts, credentials,
transcripts, hostnames and private configuration out of source, fixtures and
documentation. Examples must use invented data.

The product loads user instructions from the configured Codex AGENTS.md at
runtime. Never copy those instructions into this repository.

## Code structure

-  Run [`deslop-please`](https://github.com/deterministic-machines/deslop-please) to check for sloppy code structure.
   It lints the Rust workspace (not `runtime/` or `ios/`): `nix develop --command deslop-please`
   from the repository root. The dev shell pins the rust-analyzer it reads.
-  Errors flagged by `deslop-please` must be fixed from first principles, don't do mechanical moves to hide them.
    - `module-cycle` & `tangle`: what is the intended layer of abstraction? Which module should be at which layer?
    - `field-leak` & `shallow-module`: Why we have these fields/functions at all? What are the patterns of use? Can they be hidden behind a narrow interface? Don't fix each leak one at a time, fix them holistically.
    - Draw a diagram to help user understand the before and proposed after structure.
