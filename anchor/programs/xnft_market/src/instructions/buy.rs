use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{
    close_account, transfer_checked, CloseAccount, Mint, TokenAccount, TokenInterface,
    TransferChecked,
};

use crate::constants::{CONFIG_SEED, ESCROW_SEED, LISTING_SEED, TREASURY_SEED};
use crate::errors::XnftError;
use crate::events::TradeEvent;
use crate::math::{check_slippage, fee_and_total};
use crate::state::{Config, Listing, ListingKind};

#[derive(Accounts)]
pub struct Buy<'info> {
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

    pub nft_mint: InterfaceAccount<'info, Mint>,

    /// CHECK: pinned by the listing's `has_one`, receives the rent from both
    /// closed accounts, and is the authority `seller_token` is checked against.
    #[account(mut)]
    pub seller: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [LISTING_SEED, nft_mint.key().as_ref()],
        bump = listing.bump,
        has_one = seller @ XnftError::WrongSeller,
        has_one = nft_mint,
        close = seller,
    )]
    pub listing: Account<'info, Listing>,

    #[account(
        mut,
        seeds = [ESCROW_SEED, nft_mint.key().as_ref()],
        bump = listing.escrow_bump,
        token::mint = nft_mint,
        token::authority = listing,
        token::token_program = token_program,
    )]
    pub escrow: InterfaceAccount<'info, TokenAccount>,

    /// A first-time buyer of this xployee has nowhere for it to land yet.
    #[account(
        init_if_needed,
        payer = buyer,
        associated_token::mint = nft_mint,
        associated_token::authority = buyer,
        associated_token::token_program = token_program,
    )]
    pub buyer_nft: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        token::mint = xnft_mint,
        token::authority = buyer,
        token::token_program = token_program,
    )]
    pub buyer_token: InterfaceAccount<'info, TokenAccount>,

    #[account(
        mut,
        token::mint = xnft_mint,
        token::authority = seller,
        token::token_program = token_program,
    )]
    pub seller_token: InterfaceAccount<'info, TokenAccount>,

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

/// All four legs — payment, fee, NFT release, account close — are one
/// instruction. There is no partial settlement to unwind because a failure at any
/// point reverts the transaction, which is what makes "the buyer cannot get the
/// NFT without paying the fee" a structural claim rather than an ordering
/// convention.
pub fn handler(ctx: Context<Buy>, max_total: u64) -> Result<()> {
    require!(!ctx.accounts.config.paused, XnftError::ProgramPaused);
    require!(
        ctx.accounts.listing.kind == ListingKind::Sale,
        XnftError::NotForSale
    );
    require!(ctx.accounts.escrow.amount >= 1, XnftError::EscrowEmpty);

    let price = ctx.accounts.listing.price;
    let fee_bps = ctx.accounts.config.trade_fee_bps;
    let (fee, total) = fee_and_total(price, fee_bps)?;

    // The fee is recomputed from Config here, at execution time — so between the
    // buyer signing and this landing, `set_config` can raise `trade_fee_bps` and
    // the buyer pays a rate they never agreed to. `max_total` is the figure the
    // UI showed them, and it is checked before a single unit moves.
    check_slippage(total, max_total)?;

    require!(
        ctx.accounts.buyer_token.amount >= total,
        XnftError::InsufficientFunds
    );

    let decimals = ctx.accounts.xnft_mint.decimals;
    // Read before the payment leg so `net_to_seller` in the event below can be a
    // measurement of what the seller's account actually gained.
    let seller_balance_before = ctx.accounts.seller_token.amount;

    // The seller is paid `price` exactly. The fee is a separate debit on the
    // buyer, so the rounded-up fee costs the buyer a sub-unit rather than
    // costing the seller the price they actually listed.
    transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.buyer_token.to_account_info(),
                mint: ctx.accounts.xnft_mint.to_account_info(),
                to: ctx.accounts.seller_token.to_account_info(),
                authority: ctx.accounts.buyer.to_account_info(),
            },
        ),
        price,
        decimals,
    )?;

    // Re-read between the two legs, not after both. If buyer and seller are the
    // same wallet the payment leg is a self-transfer and the delta is genuinely
    // zero; measuring after the fee leg would instead see the fee leave and
    // underflow. Reading here also keeps this a measurement of the payment alone.
    ctx.accounts.seller_token.reload()?;
    let net_to_seller = ctx
        .accounts
        .seller_token
        .amount
        .checked_sub(seller_balance_before)
        .ok_or(XnftError::MathOverflow)?;

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

    let nft_mint_key = ctx.accounts.nft_mint.key();
    let listing_seeds: &[&[u8]] = &[
        LISTING_SEED,
        nft_mint_key.as_ref(),
        &[ctx.accounts.listing.bump],
    ];
    let signer_seeds: &[&[&[u8]]] = &[listing_seeds];

    transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.escrow.to_account_info(),
                mint: ctx.accounts.nft_mint.to_account_info(),
                to: ctx.accounts.buyer_nft.to_account_info(),
                authority: ctx.accounts.listing.to_account_info(),
            },
            signer_seeds,
        ),
        1,
        0,
    )?;

    // Rent from both escrow and the Listing account goes back to the seller, who
    // paid it. The Listing itself is closed by its `close` constraint on exit.
    close_account(CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        CloseAccount {
            account: ctx.accounts.escrow.to_account_info(),
            destination: ctx.accounts.seller.to_account_info(),
            authority: ctx.accounts.listing.to_account_info(),
        },
        signer_seeds,
    ))?;

    let config = &mut ctx.accounts.config;
    config.total_fees = config
        .total_fees
        .checked_add(fee)
        .ok_or(XnftError::MathOverflow)?;
    config.total_trades = config
        .total_trades
        .checked_add(1)
        .ok_or(XnftError::MathOverflow)?;

    emit!(TradeEvent {
        nft_mint: nft_mint_key,
        buyer: ctx.accounts.buyer.key(),
        seller: ctx.accounts.seller.key(),
        gross: price,
        fee,
        net_to_seller,
        total_paid: total,
        fee_bps,
        timestamp: Clock::get()?.unix_timestamp,
    });

    Ok(())
}
