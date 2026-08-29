use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
};

use crate::constants::{CONFIG_SEED, TREASURY_SEED};
use crate::errors::XnftError;
use crate::events::PayoutEvent;
use crate::state::Config;

/// Invariant 1, structurally.
///
/// There is no destination parameter on this instruction and there is no
/// destination account the caller gets to choose. `dev_wallet` is pinned by an
/// address constraint against `config.dev_wallet`, and the token account is
/// pinned to that wallet's ATA, so the only way to redirect a payout is to change
/// `Config` through the authority-gated `set_config` — which leaves an on-chain
/// record. A caller-supplied destination would make this a drain-anything
/// primitive over the treasury.
#[derive(Accounts)]
pub struct ClaimFees<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,

    pub xnft_mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = authority,
        has_one = xnft_mint,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: not read or written; the address constraint against
    /// `config.dev_wallet` is the entire check, and it is what pins the ATA below.
    #[account(address = config.dev_wallet @ XnftError::WrongPayoutDestination)]
    pub dev_wallet: UncheckedAccount<'info>,

    /// Created on the first claim so a fresh dev wallet does not need a manual
    /// setup step before it can be paid.
    #[account(
        init_if_needed,
        payer = authority,
        associated_token::mint = xnft_mint,
        associated_token::authority = dev_wallet,
        associated_token::token_program = token_program,
    )]
    pub dev_wallet_token: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [TREASURY_SEED],
        bump = config.treasury_bump,
    )]
    pub treasury: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<ClaimFees>, amount: u64) -> Result<()> {
    require!(!ctx.accounts.config.paused, XnftError::ProgramPaused);
    require!(amount > 0, XnftError::ZeroAmount);
    // Checked against the live token balance rather than against the lifetime
    // counters. The counters are informational; the treasury's actual balance is
    // the only number that can be spent.
    require!(
        amount <= ctx.accounts.treasury.amount,
        XnftError::InsufficientTreasury
    );

    let decimals = ctx.accounts.xnft_mint.decimals;
    let treasury_bump = ctx.accounts.config.treasury_bump;
    let treasury_seeds: &[&[u8]] = &[TREASURY_SEED, &[treasury_bump]];
    let signer_seeds: &[&[&[u8]]] = &[treasury_seeds];

    transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.treasury.to_account_info(),
                mint: ctx.accounts.xnft_mint.to_account_info(),
                to: ctx.accounts.dev_wallet_token.to_account_info(),
                authority: ctx.accounts.treasury.to_account_info(),
            },
            signer_seeds,
        ),
        amount,
        decimals,
    )?;

    // `treasury.amount` is the pre-transfer figure the deserializer captured, so
    // the remainder is computed rather than re-read. Reloading would cost an
    // extra account read to learn something arithmetic already knows.
    let treasury_remaining = ctx
        .accounts
        .treasury
        .amount
        .checked_sub(amount)
        .ok_or(XnftError::MathOverflow)?;

    let config = &mut ctx.accounts.config;
    config.total_claimed = config
        .total_claimed
        .checked_add(amount)
        .ok_or(XnftError::MathOverflow)?;
    let total_claimed = config.total_claimed;
    let destination = config.dev_wallet;

    emit!(PayoutEvent {
        destination,
        amount,
        treasury_remaining,
        total_claimed,
        timestamp: Clock::get()?.unix_timestamp,
    });

    Ok(())
}
