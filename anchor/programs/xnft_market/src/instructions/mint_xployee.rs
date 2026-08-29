use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
};

use crate::constants::{CONFIG_SEED, INCINERATOR, TREASURY_SEED};
use crate::errors::XnftError;
use crate::events::MintEvent;
use crate::math::{check_slippage, fee_and_total};
use crate::state::Config;

#[derive(Accounts)]
pub struct MintXployee<'info> {
    #[account(mut)]
    pub buyer: Signer<'info>,

    pub xnft_mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = xnft_mint,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        token::mint = xnft_mint,
        token::authority = buyer,
        token::token_program = token_program,
    )]
    pub buyer_token: InterfaceAccount<'info, TokenAccount>,

    /// CHECK: Not read or written. The address constraint is the entire check,
    /// and it is what makes the larger leg of this instruction a burn rather than
    /// a transfer to a destination the caller picked.
    #[account(address = INCINERATOR @ XnftError::WrongBurnDestination)]
    pub incinerator: UncheckedAccount<'info>,

    /// The incinerator is off the ed25519 curve, so nothing will ever open this
    /// account for it. Whoever mints first pays the one-time rent for everyone
    /// after them — the same bargain the frontend already makes.
    #[account(
        init_if_needed,
        payer = buyer,
        associated_token::mint = xnft_mint,
        associated_token::authority = incinerator,
        associated_token::token_program = token_program,
    )]
    pub incinerator_token: InterfaceAccount<'info, TokenAccount>,

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

pub fn handler(ctx: Context<MintXployee>, max_total: u64) -> Result<()> {
    require!(!ctx.accounts.config.paused, XnftError::ProgramPaused);

    // The id is assigned by the program, not passed in.
    //
    // It used to be an argument that the chain never validated and only echoed
    // into the event, which made it a number that meant nothing: two buyers could
    // each burn a full mint cost claiming id 7, and the index would have to pick
    // a winner after the money was already destroyed. An identifier the program
    // will not defend is worse than no identifier, because downstream readers
    // treat it as a key.
    //
    // `total_mints` is already a monotonic counter maintained under the same
    // account lock that guards the burn, so the mint's ordinal is free and
    // unique by construction. Taken *before* the increment, so the first mint is
    // id 0. The choice is ordinal rather than collection index on purpose: which
    // of the 512 deterministic xployees an ordinal maps to is the generator's
    // business, and the chain has no way to check that claim either.
    let xployee_id = ctx.accounts.config.total_mints;

    let burn_amount = ctx.accounts.config.mint_cost;
    let fee_bps = ctx.accounts.config.trade_fee_bps;
    // The tax rides on top: mint_cost is burned in full and the fee is charged in
    // addition, so the amount destroyed is exactly the advertised mint cost.
    let (fee, total) = fee_and_total(burn_amount, fee_bps)?;

    // Both `mint_cost` and `trade_fee_bps` are read from Config at execution
    // time, so the authority can move either one out from under a signed but
    // unlanded transaction. `max_total` is what the buyer agreed to spend.
    check_slippage(total, max_total)?;

    // Checked here so an underfunded buyer gets a named error rather than a raw
    // token-program failure. Mirrors the balance pre-check in solana.ts, which
    // exists so a shortfall never reaches the wallet as a signature prompt.
    require!(
        ctx.accounts.buyer_token.amount >= total,
        XnftError::InsufficientFunds
    );

    let decimals = ctx.accounts.xnft_mint.decimals;

    // transfer_checked rather than a plain transfer: it carries the mint and the
    // decimals, so a wrong-decimals amount cannot land.
    transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.buyer_token.to_account_info(),
                mint: ctx.accounts.xnft_mint.to_account_info(),
                to: ctx.accounts.incinerator_token.to_account_info(),
                authority: ctx.accounts.buyer.to_account_info(),
            },
        ),
        burn_amount,
        decimals,
    )?;

    transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.buyer_token.to_account_info(),
                mint: ctx.accounts.xnft_mint.to_account_info(),
                to: ctx.accounts.treasury.to_account_info(),
                authority: ctx.accounts.buyer.to_account_info(),
            },
        ),
        fee,
        decimals,
    )?;

    let config = &mut ctx.accounts.config;
    config.total_burned = config
        .total_burned
        .checked_add(burn_amount)
        .ok_or(XnftError::MathOverflow)?;
    config.total_fees = config
        .total_fees
        .checked_add(fee)
        .ok_or(XnftError::MathOverflow)?;
    config.total_mints = config
        .total_mints
        .checked_add(1)
        .ok_or(XnftError::MathOverflow)?;

    emit!(MintEvent {
        buyer: ctx.accounts.buyer.key(),
        xployee_id,
        burned: burn_amount,
        fee,
        total,
        fee_bps,
        timestamp: Clock::get()?.unix_timestamp,
    });

    Ok(())
}
