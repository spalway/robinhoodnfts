use anchor_lang::prelude::*;

/// Basis-point denominator. 500 bps = 5%.
pub const BPS_DENOM: u64 = 10_000;

/// 5% — mints and secondary sales.
pub const DEFAULT_TRADE_FEE_BPS: u16 = 500;

/// 10% — rental contracts.
pub const DEFAULT_RENT_FEE_BPS: u16 = 1_000;

/// Hard ceiling on any configurable fee, enforced inside the program rather than
/// by convention. 2000 (20%) rather than 1000 so the 10% rental fee is not sitting
/// exactly at the ceiling, while a compromised authority still cannot set a
/// confiscatory rate.
pub const MAX_FEE_BPS: u16 = 2_000;

/// Solana's canonical incinerator. Nobody holds this key, so tokens parked in its
/// token account are gone for good.
///
/// A `const` and never an instruction account the caller gets to choose: the
/// address constraint on `mint_xployee` is what makes the burn a burn rather than
/// a transfer to whoever asked. Same reasoning that keeps `BURN_ADDRESS` a module
/// constant in `src/lib/solana.ts`.
///
/// Note this key is off the ed25519 curve, so its associated token account has to
/// be derived with owner-off-curve allowed on the client side.
pub const INCINERATOR: Pubkey =
    anchor_lang::solana_program::pubkey!("1nc1nerator11111111111111111111111111111111");

pub const CONFIG_SEED: &[u8] = b"config";
pub const TREASURY_SEED: &[u8] = b"treasury";
pub const LISTING_SEED: &[u8] = b"listing";
pub const ESCROW_SEED: &[u8] = b"escrow";
pub const CONTRACT_SEED: &[u8] = b"contract";
