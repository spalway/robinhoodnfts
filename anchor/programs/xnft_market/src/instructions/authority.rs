//! Two-step authority rotation.
//!
//! Without a rotation path the authority set at `initialize` owns the treasury,
//! the fee rates and the pause flag for the life of the program. A lost key
//! bricks `claim_fees` and leaves the protocol permanently paused-or-not
//! whichever way it happened to be; a compromised key can never be revoked.
//!
//! Two steps rather than one because the one-step version has the same failure
//! mode as no rotation at all: a mistyped destination hands everything to an
//! address nobody controls, irreversibly, in a single transaction. Requiring the
//! incoming key to sign `accept_authority` proves it exists and is held before
//! anything moves.
//!
//! Neither instruction is pause-gated. Nothing here moves value, and a rotation
//! is exactly what you need to be able to do while the protocol is paused —
//! pausing is the first thing a responder does after a key compromise.
use anchor_lang::prelude::*;

use crate::constants::CONFIG_SEED;
use crate::errors::XnftError;
use crate::state::Config;

#[derive(Accounts)]
pub struct ProposeAuthority<'info> {
    pub authority: Signer<'info>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = authority,
    )]
    pub config: Account<'info, Config>,
}

/// Records a candidate. Nothing changes hands until it signs.
///
/// Passing `Pubkey::default()` cancels a proposal in flight, which is the escape
/// hatch for having proposed the wrong key — the proposal is inert until
/// accepted, so cancelling costs nothing.
pub fn propose_handler(ctx: Context<ProposeAuthority>, new_authority: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.pending_authority = new_authority;
    Ok(())
}

#[derive(Accounts)]
pub struct AcceptAuthority<'info> {
    /// The proposed key, proving control of itself. This signature is the whole
    /// point of the second step.
    pub pending_authority: Signer<'info>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = pending_authority @ XnftError::NoPendingAuthority,
    )]
    pub config: Account<'info, Config>,
}

pub fn accept_handler(ctx: Context<AcceptAuthority>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    // `has_one` already proved the signer matches `pending_authority`. This
    // guards the one case where that is not enough: with no proposal in flight
    // the field holds the default pubkey, and matching it would mean anyone who
    // could produce that signature takes the protocol. Nobody can — but the check
    // costs nothing and does not rely on that being true.
    require_keys_neq!(
        config.pending_authority,
        Pubkey::default(),
        XnftError::NoPendingAuthority
    );

    config.authority = config.pending_authority;
    // Cleared so the same proposal cannot be replayed to seize the authority back
    // after a later, legitimate rotation.
    config.pending_authority = Pubkey::default();

    Ok(())
}
