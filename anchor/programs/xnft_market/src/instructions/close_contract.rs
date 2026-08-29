//! Reclaims an expired rental contract.
//!
//! `Contract` is seeded by `(nft_mint, renter)` and created with `init`, so
//! without this instruction the account is permanent: a wallet could rent a given
//! xployee exactly once for the life of the program, and the rent-exempt
//! lamports it paid to open the account would be locked in it forever.
use anchor_lang::prelude::*;

use crate::constants::CONTRACT_SEED;
use crate::errors::XnftError;
use crate::state::Contract;

#[derive(Accounts)]
pub struct CloseContract<'info> {
    /// CHECK: the rent destination, pinned by the `has_one` below. Never read or
    /// written as data — only credited with the lamports it originally paid.
    #[account(mut)]
    pub renter: UncheckedAccount<'info>,

    /// CHECK: carried only to re-derive the contract PDA, and pinned by the
    /// `has_one` below so it cannot be a different mint's.
    pub nft_mint: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [CONTRACT_SEED, nft_mint.key().as_ref(), renter.key().as_ref()],
        bump = contract.bump,
        has_one = nft_mint,
        has_one = renter,
        close = renter,
    )]
    pub contract: Account<'info, Contract>,
}

/// Deliberately permissionless — there is no signer on this instruction at all.
///
/// The only two effects are returning the renter's own rent to the renter and
/// freeing the `(mint, renter)` seed for a future rental, and both are things the
/// renter wants. Requiring the renter to sign would mean an abandoned contract
/// blocks that pair forever, which is the exact failure this instruction exists
/// to remove. Requiring the owner to sign would hand the owner a veto over the
/// renter's lamports.
///
/// Not pause-gated, for the same reason `cancel_listing` is not: the lamports
/// belong to the renter, and a pause must not be able to hold user property.
pub fn handler(ctx: Context<CloseContract>) -> Result<()> {
    // Epochs, matching how the term was measured at `rent` time. `end_epoch` is
    // exclusive: the term covers `start_epoch..end_epoch`, so the contract is
    // spent the moment the clock reaches it.
    let epoch = Clock::get()?.epoch;
    require!(
        epoch >= ctx.accounts.contract.end_epoch,
        XnftError::ContractNotExpired
    );

    // The account itself is closed by the `close = renter` constraint on exit.
    Ok(())
}
