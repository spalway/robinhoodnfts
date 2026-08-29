//! Every value-moving instruction emits one of these.
//!
//! These are not telemetry. The `ingest-signature` Edge Function refuses
//! client-supplied amounts and re-reads the transaction from RPC, so the numbers
//! below are the only thing Supabase is allowed to believe. Anything the index
//! needs to store has to be a field here — a value that is only implicit in the
//! account state is a value the indexer would have to guess at.
use anchor_lang::prelude::*;

#[event]
pub struct MintEvent {
    pub buyer: Pubkey,
    /// The mint's ordinal, assigned by the program as `config.total_mints` before
    /// that counter is advanced — so the first mint is 0 and no two mints ever
    /// share an id. Not an instruction argument: a caller-supplied id is a number
    /// the chain will not defend, and two buyers could each burn a full mint cost
    /// claiming the same one.
    pub xployee_id: u64,
    /// Raw units sent to the incinerator.
    pub burned: u64,
    /// Raw units sent to the treasury.
    pub fee: u64,
    /// `burned + fee` — the buyer's total debit.
    pub total: u64,
    pub fee_bps: u16,
    pub timestamp: i64,
}

#[event]
pub struct TradeEvent {
    pub nft_mint: Pubkey,
    pub buyer: Pubkey,
    pub seller: Pubkey,
    /// The listed price.
    pub gross: u64,
    pub fee: u64,
    /// **Measured**, not restated: the seller's token balance is re-read between
    /// the payment leg and the fee leg and this is the delta. It should always
    /// equal `gross` — the fee rides on top, so the seller is never short a
    /// rounding unit — and the point of measuring rather than echoing `gross` is
    /// that the index can now actually assert that, which it could not when both
    /// fields came from the same local. A divergence means a transfer hook or a
    /// fee-bearing mint took a cut, and the index should see it rather than be
    /// told the number that was intended.
    pub net_to_seller: u64,
    /// `gross + fee` — the buyer's total debit.
    pub total_paid: u64,
    pub fee_bps: u16,
    pub timestamp: i64,
}

#[event]
pub struct RentEvent {
    pub nft_mint: Pubkey,
    pub owner: Pubkey,
    pub renter: Pubkey,
    /// `fee_per_epoch * term_epochs`, paid to the owner in full.
    pub gross: u64,
    pub fee: u64,
    pub total_paid: u64,
    pub fee_per_epoch: u64,
    pub term_epochs: u32,
    pub start_epoch: u64,
    pub end_epoch: u64,
    pub fee_bps: u16,
    pub timestamp: i64,
}

#[event]
pub struct PayoutEvent {
    /// Always `config.dev_wallet`. Emitted so the payout row can be reconciled
    /// against the config the chain actually held at claim time.
    pub destination: Pubkey,
    pub amount: u64,
    pub treasury_remaining: u64,
    pub total_claimed: u64,
    pub timestamp: i64,
}
