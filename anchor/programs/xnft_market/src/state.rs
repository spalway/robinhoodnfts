use anchor_lang::prelude::*;

/// Singleton at `["config"]`. The authority on fee rates, the pause flag and the
/// payout destination.
///
/// `dev_wallet` lives here rather than in a `claim_fees` argument on purpose: a
/// caller-supplied destination would turn the claim into a drain-anything
/// primitive. Changing it is authority-gated through `set_config`.
#[account]
#[derive(InitSpace)]
pub struct Config {
    pub authority: Pubkey,
    pub xnft_mint: Pubkey,
    pub dev_wallet: Pubkey,
    pub trade_fee_bps: u16,
    pub rent_fee_bps: u16,
    /// Raw units, i.e. `10_000 * 10^decimals`. Whole tokens never appear on chain.
    pub mint_cost: u64,
    pub paused: bool,
    /// Lifetime counters. Purely informational — the Supabase index rebuilds from
    /// events, and these exist so a single account read can prove the index right.
    pub total_burned: u64,
    pub total_fees: u64,
    pub total_claimed: u64,
    pub total_mints: u64,
    pub total_trades: u64,
    pub bump: u8,
    /// Stored so `claim_fees` can sign as the treasury without paying for a
    /// `find_program_address` scan on every payout.
    pub treasury_bump: u8,
    /// Half of a two-step authority rotation. `propose_authority` writes here and
    /// `accept_authority` — signed by *this* key — promotes it.
    ///
    /// Two steps rather than one because a one-step rotation makes a mistyped
    /// pubkey unrecoverable: the treasury, the fee rates and the pause flag would
    /// all belong forever to an address nobody holds. Requiring the incoming key
    /// to sign proves it exists and is controlled before anything is handed over.
    ///
    /// `Pubkey::default()` means "nothing proposed", which is also how a proposal
    /// is cancelled.
    ///
    /// Appended after `treasury_bump` rather than placed next to `authority` so
    /// every field that existed before rotation kept its byte offset.
    pub pending_authority: Pubkey,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug, InitSpace)]
pub enum ListingKind {
    Sale,
    Rent,
}

/// One per NFT, at `["listing", nft_mint]`. Seeding by mint alone means an NFT
/// can only be listed once at a time.
///
/// The listing owns the escrow token account, which is what makes the fee
/// non-bypassable: once the NFT is in escrow the only two instructions that can
/// sign it out are `buy` (which charges) and `cancel_listing` (which returns it
/// to the seller).
#[account]
#[derive(InitSpace)]
pub struct Listing {
    pub seller: Pubkey,
    pub nft_mint: Pubkey,
    /// Sale price in raw $xNFT units. Zero on a rental listing.
    pub price: u64,
    /// Rental price per epoch in raw $xNFT units. Zero on a sale listing.
    pub fee_per_epoch: u64,
    pub term_epochs: u32,
    pub kind: ListingKind,
    pub created_at: i64,
    pub bump: u8,
    pub escrow_bump: u8,
    /// The epoch at which the live rental term ends, or `0` when nothing is
    /// rented. This single field carries both exclusivity rules:
    ///
    ///   - `rent` refuses while `clock.epoch < rented_until_epoch`, so a term is
    ///     sold to one renter at a time. Without it, the Contract PDA's `renter`
    ///     seed lets fifty renters each buy the same six epochs of the same
    ///     asset, and every one of them is entitled to it.
    ///   - `cancel_listing` refuses on the same condition, so the seller cannot
    ///     take a full term's rent and pull the asset out of escrow in the next
    ///     transaction — which would orphan a Contract that no instruction can
    ///     refund or terminate.
    ///
    /// Stored as an epoch rather than a boolean so it expires on its own. A flag
    /// would need somebody to come back and clear it, and "somebody" is exactly
    /// the party with an incentive not to.
    pub rented_until_epoch: u64,
}

/// An active rental at `["contract", nft_mint, renter]`.
///
/// Seeding by renter as well as mint caps a renter at one live contract per
/// xployee: a second `rent` on the same pair hits an already-initialised account
/// and fails, rather than silently overwriting the first term. Exclusivity
/// *across* renters is a separate rule and lives on `Listing.rented_until_epoch`
/// — the seed alone only stops a renter colliding with themselves.
///
/// `close_contract` closes this account once `end_epoch` has passed and returns
/// the rent-exempt lamports to the renter who paid them. Without that path the
/// renter-in-the-seed is a one-shot: a given wallet could rent a given xployee
/// exactly once for the life of the program, and its rent would be locked in a
/// dead account forever.
#[account]
#[derive(InitSpace)]
pub struct Contract {
    pub nft_mint: Pubkey,
    pub owner: Pubkey,
    pub renter: Pubkey,
    pub start_epoch: u64,
    pub end_epoch: u64,
    pub fee_per_epoch: u64,
    pub term_epochs: u32,
    /// Gross plus fee — what actually left the renter's wallet.
    pub total_paid: u64,
    pub fee_paid: u64,
    pub bump: u8,
}
