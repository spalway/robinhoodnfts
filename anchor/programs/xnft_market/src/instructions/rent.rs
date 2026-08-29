use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
};

use crate::constants::{CONFIG_SEED, CONTRACT_SEED, LISTING_SEED, TREASURY_SEED};
use crate::errors::XnftError;
use crate::events::RentEvent;
use crate::math::{check_slippage, fee_and_total};
use crate::state::{Config, Contract, Listing, ListingKind};

/// Named `RentXployee` rather than `Rent` because `anchor_lang::prelude::*`
/// already exports the `Rent` sysvar, and two glob imports of the same name make
/// every use of it ambiguous in `lib.rs`. The instruction is still `rent` — the
/// IDL takes its name from the function, not the accounts struct.
#[derive(Accounts)]
pub struct RentXployee<'info> {
    #[account(mut)]
    pub renter: Signer<'info>,

    pub xnft_mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = xnft_mint,
    )]
    pub config: Account<'info, Config>,

    pub nft_mint: InterfaceAccount<'info, Mint>,

    /// Never closed — renting leaves the listing standing and the NFT in escrow
    /// for the whole term — but mutable, because the term is recorded here.
    /// `rented_until_epoch` is what makes a rental exclusive; a read-only listing
    /// would let the same six epochs of the same asset be sold to as many renters
    /// as care to ask.
    #[account(
        mut,
        seeds = [LISTING_SEED, nft_mint.key().as_ref()],
        bump = listing.bump,
        has_one = nft_mint,
    )]
    pub listing: Account<'info, Listing>,

    /// The owner is identified by whose token account this is rather than by an
    /// extra `AccountInfo`, so there is no owner address for the caller to get
    /// wrong or to substitute.
    #[account(
        mut,
        token::mint = xnft_mint,
        token::token_program = token_program,
        constraint = owner_token.owner == listing.seller @ XnftError::WrongSeller,
    )]
    pub owner_token: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        token::mint = xnft_mint,
        token::authority = renter,
        token::token_program = token_program,
    )]
    pub renter_token: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [TREASURY_SEED],
        bump = config.treasury_bump,
    )]
    pub treasury: InterfaceAccount<'info, TokenAccount>,

    #[account(
        init,
        payer = renter,
        space = 8 + Contract::INIT_SPACE,
        seeds = [CONTRACT_SEED, nft_mint.key().as_ref(), renter.key().as_ref()],
        bump,
    )]
    pub contract: Account<'info, Contract>,

    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<RentXployee>, max_total: u64) -> Result<()> {
    require!(!ctx.accounts.config.paused, XnftError::ProgramPaused);
    require!(
        ctx.accounts.listing.kind == ListingKind::Rent,
        XnftError::NotForRent
    );

    // Solana epochs rather than wall-clock: the frontend's accrual model is
    // already epoch-shaped, and an epoch cannot be nudged by a validator's clock
    // drift the way `unix_timestamp` can.
    let clock = Clock::get()?;
    let start_epoch = clock.epoch;

    // Exclusivity. A rental sells the *use* of an asset for a stretch of time,
    // and time is not divisible among buyers: if this listing's term is already
    // sold, there is nothing left to sell until it runs out. The check is a
    // comparison against a stored end epoch rather than a flag someone has to
    // clear, so the listing re-opens on its own.
    require!(
        start_epoch >= ctx.accounts.listing.rented_until_epoch,
        XnftError::RentalActive
    );

    // The term comes from the listing, never from the caller. A renter-chosen
    // term is a renter-chosen price, and a term of zero would mint a contract for
    // nothing.
    let term_epochs = ctx.accounts.listing.term_epochs;
    let fee_per_epoch = ctx.accounts.listing.fee_per_epoch;
    let owner = ctx.accounts.listing.seller;
    require!(
        fee_per_epoch > 0 && term_epochs > 0,
        XnftError::InvalidRentalTerms
    );

    let gross = fee_per_epoch
        .checked_mul(term_epochs as u64)
        .ok_or(XnftError::MathOverflow)?;
    let fee_bps = ctx.accounts.config.rent_fee_bps;
    let (fee, total) = fee_and_total(gross, fee_bps)?;

    // The rate is read from Config at execution time, so without this the
    // authority can raise `rent_fee_bps` between the renter signing and the
    // transaction landing. `max_total` is the number the renter actually saw.
    check_slippage(total, max_total)?;

    require!(
        ctx.accounts.renter_token.amount >= total,
        XnftError::InsufficientFunds
    );

    let decimals = ctx.accounts.xnft_mint.decimals;

    transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.renter_token.to_account_info(),
                mint: ctx.accounts.xnft_mint.to_account_info(),
                to: ctx.accounts.owner_token.to_account_info(),
                authority: ctx.accounts.renter.to_account_info(),
            },
        ),
        gross,
        decimals,
    )?;

    transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.renter_token.to_account_info(),
                mint: ctx.accounts.xnft_mint.to_account_info(),
                to: ctx.accounts.treasury.to_account_info(),
                authority: ctx.accounts.renter.to_account_info(),
            },
        ),
        fee,
        decimals,
    )?;

    let end_epoch = start_epoch
        .checked_add(term_epochs as u64)
        .ok_or(XnftError::MathOverflow)?;

    // Written after the transfers, so a failed payment leaves the listing free
    // rather than blocked. Also what stops `cancel_listing` pulling the asset out
    // from under a renter who has already paid for the term.
    let listing = &mut ctx.accounts.listing;
    listing.rented_until_epoch = end_epoch;

    let contract = &mut ctx.accounts.contract;
    contract.nft_mint = ctx.accounts.nft_mint.key();
    contract.owner = owner;
    contract.renter = ctx.accounts.renter.key();
    contract.start_epoch = start_epoch;
    contract.end_epoch = end_epoch;
    contract.fee_per_epoch = fee_per_epoch;
    contract.term_epochs = term_epochs;
    contract.total_paid = total;
    contract.fee_paid = fee;
    contract.bump = ctx.bumps.contract;

    let config = &mut ctx.accounts.config;
    config.total_fees = config
        .total_fees
        .checked_add(fee)
        .ok_or(XnftError::MathOverflow)?;

    emit!(RentEvent {
        nft_mint: ctx.accounts.nft_mint.key(),
        owner,
        renter: ctx.accounts.renter.key(),
        gross,
        fee,
        total_paid: total,
        fee_per_epoch,
        term_epochs,
        start_epoch,
        end_epoch,
        fee_bps,
        timestamp: clock.unix_timestamp,
    });

    Ok(())
}
