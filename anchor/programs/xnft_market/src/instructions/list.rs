use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    transfer_checked, Mint, TokenAccount, TokenInterface, TransferChecked,
};

use crate::constants::{CONFIG_SEED, ESCROW_SEED, LISTING_SEED};
use crate::errors::XnftError;
use crate::state::{Config, Listing, ListingKind};

#[derive(Accounts)]
pub struct List<'info> {
    #[account(mut)]
    pub seller: Signer<'info>,

    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,

    pub nft_mint: InterfaceAccount<'info, Mint>,

    #[account(
        mut,
        token::mint = nft_mint,
        token::authority = seller,
        token::token_program = token_program,
    )]
    pub seller_nft: InterfaceAccount<'info, TokenAccount>,

    /// Seeded by mint alone: one live listing per xployee, and the address is
    /// derivable by anyone who knows the mint.
    #[account(
        init,
        payer = seller,
        space = 8 + Listing::INIT_SPACE,
        seeds = [LISTING_SEED, nft_mint.key().as_ref()],
        bump,
    )]
    pub listing: Account<'info, Listing>,

    /// Invariant 5. The escrow's authority is the Listing PDA, which no key can
    /// sign for and which only `buy` and `cancel_listing` sign for inside this
    /// program. That is what makes the sale fee non-bypassable: there is no third
    /// exit from escrow.
    #[account(
        init,
        payer = seller,
        seeds = [ESCROW_SEED, nft_mint.key().as_ref()],
        bump,
        token::mint = nft_mint,
        token::authority = listing,
        token::token_program = token_program,
    )]
    pub escrow: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn handler(
    ctx: Context<List>,
    kind: ListingKind,
    price: u64,
    fee_per_epoch: u64,
    term_epochs: u32,
) -> Result<()> {
    require!(!ctx.accounts.config.paused, XnftError::ProgramPaused);

    // Non-fungibility, checked properly rather than by decimals alone.
    //
    // `decimals == 0` on its own is not an NFT — it is an integer-denominated
    // token, and a zero-decimal mint with a supply of fifty is perfectly legal.
    // That matters because the escrow is a bare PDA token account: anyone may
    // transfer additional units into it at any time, and both `buy` and
    // `cancel_listing` move exactly one unit out and then `close_account`, which
    // the token program rejects on a non-empty account. A single extra unit
    // pushed into escrow therefore makes both exits revert forever and bricks the
    // asset in a PDA nobody can sign for.
    //
    //   - `decimals == 0`  — the unit is indivisible, so "the NFT" is not some
    //                        fraction of a balance.
    //   - `supply == 1`    — there is exactly one unit in existence to escrow.
    //   - no mint authority — without this, `supply == 1` is only true until the
    //                        mint authority decides otherwise, and the check
    //                        above would be a snapshot rather than a guarantee.
    //
    // A live *freeze* authority can also brick an escrow, and is deliberately not
    // checked: freezing harms only the listing it targets, it is reversible by
    // the same key, and legitimate NFT standards use it. Supply is different
    // because the damage is permanent and any passer-by can inflict it.
    require!(
        ctx.accounts.nft_mint.decimals == 0
            && ctx.accounts.nft_mint.supply == 1
            && ctx.accounts.nft_mint.mint_authority.is_none(),
        XnftError::NotAnNft
    );
    // $xNFT is the settlement asset. Escrowing it as if it were an xployee would
    // let someone list money against money and confuse every downstream reader.
    require_keys_neq!(
        ctx.accounts.nft_mint.key(),
        ctx.accounts.config.xnft_mint,
        XnftError::CannotListPaymentMint
    );
    require!(
        ctx.accounts.seller_nft.amount >= 1,
        XnftError::SellerDoesNotHoldNft
    );

    // Each kind validates only its own fields, and `buy`/`rent` each refuse the
    // other kind — so a sale listing can never be rented at a zero fee, and a
    // rental listing can never be bought for a price of zero.
    match kind {
        ListingKind::Sale => {
            require!(price > 0, XnftError::InvalidPrice);
        }
        ListingKind::Rent => {
            require!(
                fee_per_epoch > 0 && term_epochs > 0,
                XnftError::InvalidRentalTerms
            );
        }
    }

    transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.seller_nft.to_account_info(),
                mint: ctx.accounts.nft_mint.to_account_info(),
                to: ctx.accounts.escrow.to_account_info(),
                authority: ctx.accounts.seller.to_account_info(),
            },
        ),
        1,
        0,
    )?;

    let listing = &mut ctx.accounts.listing;
    listing.seller = ctx.accounts.seller.key();
    listing.nft_mint = ctx.accounts.nft_mint.key();
    // The unused half is stored as zero rather than left at whatever the caller
    // passed, so a reader never has to know which fields this kind honours.
    listing.price = match kind {
        ListingKind::Sale => price,
        ListingKind::Rent => 0,
    };
    listing.fee_per_epoch = match kind {
        ListingKind::Sale => 0,
        ListingKind::Rent => fee_per_epoch,
    };
    listing.term_epochs = match kind {
        ListingKind::Sale => 0,
        ListingKind::Rent => term_epochs,
    };
    listing.kind = kind;
    listing.created_at = Clock::get()?.unix_timestamp;
    listing.bump = ctx.bumps.listing;
    listing.escrow_bump = ctx.bumps.escrow;
    // Nothing is rented yet, and epoch 0 is unreachable on a live chain, so this
    // reads as "free" against every comparison in `rent` and `cancel_listing`.
    listing.rented_until_epoch = 0;

    Ok(())
}
