use anchor_lang::prelude::*;

use crate::constants::{CONFIG_SEED, MAX_FEE_BPS};
use crate::errors::XnftError;
use crate::state::Config;

#[derive(Accounts)]
pub struct SetConfig<'info> {
    pub authority: Signer<'info>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = authority,
    )]
    pub config: Account<'info, Config>,
}

/// Every field is optional so a pause does not force the caller to restate the
/// fee rates — restating them is how a fat-fingered pause turns into a fee change.
///
/// Deliberately not paused-gated: this is the only instruction that can unpause,
/// so guarding it on `!paused` would make the pause permanent.
///
/// `authority` is deliberately *not* one of the fields. Rotating it is a
/// different kind of change — irreversible if it lands wrong — so it lives in
/// `propose_authority` / `accept_authority`, where the incoming key has to sign
/// for itself. Folding it in here as another `Option` would make handing the
/// protocol to a mistyped address a one-transaction mistake.
pub fn handler(
    ctx: Context<SetConfig>,
    trade_fee_bps: Option<u16>,
    rent_fee_bps: Option<u16>,
    dev_wallet: Option<Pubkey>,
    paused: Option<bool>,
) -> Result<()> {
    let config = &mut ctx.accounts.config;

    if let Some(bps) = trade_fee_bps {
        // The whole point of the cap: even with the authority key in hand, a 100%
        // tax is not expressible.
        require!(bps <= MAX_FEE_BPS, XnftError::FeeTooHigh);
        config.trade_fee_bps = bps;
    }

    if let Some(bps) = rent_fee_bps {
        require!(bps <= MAX_FEE_BPS, XnftError::FeeTooHigh);
        config.rent_fee_bps = bps;
    }

    if let Some(wallet) = dev_wallet {
        require_keys_neq!(wallet, Pubkey::default(), XnftError::InvalidDevWallet);
        config.dev_wallet = wallet;
    }

    if let Some(flag) = paused {
        config.paused = flag;
    }

    Ok(())
}
