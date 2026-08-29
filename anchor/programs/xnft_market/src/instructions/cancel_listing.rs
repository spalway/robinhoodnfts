use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    close_account, transfer_checked, CloseAccount, Mint, TokenAccount, TokenInterface,
    TransferChecked,
};

use crate::constants::{CONFIG_SEED, ESCROW_SEED, LISTING_SEED};
use crate::errors::XnftError;
use crate::state::{Config, Listing};

#[derive(Accounts)]
pub struct CancelListing<'info> {
    #[account(mut)]
    pub seller: Signer<'info>,

    /// Read for nothing but its bump. This instruction is not paused-gated (see
    /// the handler), and it charges no fee, so nothing else in Config applies —
    /// the account stays in the list only so the seeds keep proving this is the
    /// protocol's own config rather than a look-alike.
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,

    pub nft_mint: InterfaceAccount<'info, Mint>,

    /// `has_one = seller` is the whole authorisation story: only the address
    /// recorded at list time can pull the NFT back out.
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

    #[account(
        mut,
        token::mint = nft_mint,
        token::authority = seller,
        token::token_program = token_program,
    )]
    pub seller_nft: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
}

pub fn handler(ctx: Context<CancelListing>) -> Result<()> {
    // Deliberately *not* paused-gated, and the one carve-out from invariant 4.
    //
    // Invariant 4 exists to stop value flowing while something is wrong. This
    // instruction does not move protocol value: it hands a seller back an asset
    // that was already theirs, charges nothing, and touches no fee. Gating it
    // would mean the authority could pause and hold every escrowed xployee
    // hostage — a pause switch that traps user property is a rug with extra
    // steps, and no incident it protects against is improved by the assets being
    // stuck. Withdrawal is the one door that stays open.
    //
    // What *is* gated is the rental term below, which is a promise to somebody
    // else and survives a pause exactly as it survives everything else.
    require!(ctx.accounts.escrow.amount >= 1, XnftError::EscrowEmpty);

    // A live rental is a term the renter has already paid for in full. Without
    // this the seller can take a whole term's rent and withdraw the asset in the
    // very next transaction, leaving a Contract that no instruction can refund
    // and no instruction can terminate — the renter's money is simply gone.
    //
    // The listing becomes cancellable again the moment the term runs out, with
    // nobody needing to come back and release it.
    require!(
        Clock::get()?.epoch >= ctx.accounts.listing.rented_until_epoch,
        XnftError::RentalActive
    );

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
                to: ctx.accounts.seller_nft.to_account_info(),
                authority: ctx.accounts.listing.to_account_info(),
            },
            signer_seeds,
        ),
        1,
        0,
    )?;

    // Escrow is emptied, so its rent-exempt reserve goes back to whoever paid it.
    // Leaving it open would strand that lamport balance forever: nothing outside
    // this instruction can ever close a token account owned by a Listing PDA.
    close_account(CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        CloseAccount {
            account: ctx.accounts.escrow.to_account_info(),
            destination: ctx.accounts.seller.to_account_info(),
            authority: ctx.accounts.listing.to_account_info(),
        },
        signer_seeds,
    ))?;

    // The Listing account itself is closed by the `close = seller` constraint
    // after this handler returns.
    Ok(())
}
