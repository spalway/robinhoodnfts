# ABANDONED — this directory is dead code

**Nothing in `anchor/` is part of the xNFTs app. Do not read it as a source of truth.**

`xnft_market` was a Solana program intended to be the authority on every transfer of value in the
protocol. It was written and then abandoned. The app now composes plain SPL Token instructions
instead — see [`src/lib/spl.ts`](../src/lib/spl.ts) and
[`docs/superpowers/specs/2026-08-05-onchain-fees-supabase-design.md`](../docs/superpowers/specs/2026-08-05-onchain-fees-supabase-design.md).

## It was never compiled

Not once. The Rust here has never been type-checked, never linted, never executed, and never
deployed to any cluster. `target/` contains a program keypair and no build artifact, which is the
evidence.

The reason is environmental, and it is worth stating so that nobody burns another day on it:

- The default `x86_64-pc-windows-msvc` target needs the Visual Studio Build Tools C++ workload for
  its linker, and that installer requires **administrator elevation, which is unavailable in this
  environment**.
- The `x86_64-pc-windows-gnu` fallback avoids MSVC but then **failed on a missing `dlltool`** — part
  of GNU binutils, which the available toolchain did not supply and which could not be installed by
  the route already blocked above.

There is no Rust toolchain here. **Never invoke `cargo` or `anchor` in this project.**

## Why it is still on disk

This project is not under version control. Deleting the directory would be unrecoverable, and the
design reasoning in the comments is occasionally worth re-reading. That is the *only* reason it
survives.

## What it must not be used for

Everything in here describes a system that does not exist. Specifically:

- **Do not match its layouts.** There are no PDAs, no `Config` account, no `Listing`, no `Contract`,
  no discriminators, no IDL. Any client code deriving an address or decoding an account is wrong.
- **Do not trust its constants.** `math::fee_on` rounds *up*; `src/lib/fees.ts` **floors**, and
  `fees.ts` is the one that runs. The old "matched pair" contract between them is void.
- **Do not trust its guarantees.** The header comment in `programs/xnft_market/src/lib.rs` promises a
  program-enforced fee cap, a pause flag, escrow that makes the fee unbypassable, a PDA-owned
  treasury, and slippage protection via `max_total`. **None of those exist.** §4.4 of the spec is the
  honest accounting of what was given up when this was dropped.
- **Do not treat `tests/xnft_market.ts` as a specification.** It tests a program that will never run.

Where this directory disagrees with `src/lib/`, `src/lib/` is right by definition — because
`src/lib/` runs.
