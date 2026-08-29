//! `xnft_market` — the authority on every transfer of value in the xNFTs
//! protocol.
//!
//! The rules this program exists to make structural, rather than to document:
//!
//!   1. The payout destination is read from `Config`, never taken as an argument.
//!      `claim_fees` has no destination parameter and no destination account the
//!      caller chooses. Same reasoning that keeps `BURN_ADDRESS` a module
//!      constant in `src/lib/solana.ts`.
//!   2. Fee rates are capped at `MAX_FEE_BPS` inside the program, so a
//!      compromised authority still cannot set a confiscatory tax. Rates are also
//!      recomputed at execution time, so every payer signs a `max_total` the
//!      program refuses to exceed — the cap bounds the abuse, the slippage
//!      argument is what makes the price consented to.
//!   3. Every fee multiply goes through a `u128` intermediate and a checked
//!      narrowing; every add and subtract is `checked_*`; the release profile
//!      keeps `overflow-checks` on regardless.
//!   4. `!config.paused` gates every instruction that moves *protocol* value.
//!      `cancel_listing` and `close_contract` are the deliberate exceptions: both
//!      only hand a user back their own property, and a pause that traps user
//!      assets is a rug with extra steps.
//!   5. Escrow's authority is the Listing PDA, so a listed xployee has exactly
//!      two exits: `buy`, which charges, and `cancel_listing`, which returns it.
//!   6. Fees round **up** and the recipient is paid exactly the amount they asked
//!      for — the payer covers the fee on top, so the rounding unit comes out of
//!      the payer's side and the treasury is never short. `src/lib/fees.ts` must
//!      round the same way. See `math::fee_on` for why this side was chosen.
//!   7. Ownership is not a race and not a one-way door. `initialize` is gated on
//!      the program's upgrade authority so the fixed `["config"]` PDA cannot be
//!      front-run, and the authority rotates through a two-step
//!      propose/accept so neither a lost key nor a typo is terminal.
//!
//! Money is raw `u64` units throughout. Whole-token amounts and decimals meet
//! only at the client edge.
use anchor_lang::prelude::*;

pub mod constants;
pub mod errors;
pub mod events;
pub mod instructions;
pub mod math;
pub mod state;

use instructions::*;
use state::ListingKind;

declare_id!("7bPUjqHijBsh5XHEXq2FbbVURSFoA5moMGM2MQREXpsW");

#[program]
pub mod xnft_market {
    use super::*;

    /// One-time. Creates `Config` and the treasury token account, and fixes the
    /// $xNFT mint this program will settle in forever after.
    ///
    /// Must be signed by the program's upgrade authority. `Config` sits at a
    /// fixed PDA, so an open `initialize` is a race an observer of the deploy can
    /// win — and the winner owns every fee forever.
    pub fn initialize(
        ctx: Context<Initialize>,
        trade_fee_bps: u16,
        rent_fee_bps: u16,
        mint_cost: u64,
        dev_wallet: Pubkey,
    ) -> Result<()> {
        instructions::initialize::handler(ctx, trade_fee_bps, rent_fee_bps, mint_cost, dev_wallet)
    }

    /// Buyer pays `mint_cost + trade_fee`: `mint_cost` to the incinerator, the
    /// fee to the treasury. The tax rides on top so the burned amount is exactly
    /// the advertised mint cost.
    ///
    /// `max_total` is the buyer's slippage ceiling. The xployee id is assigned by
    /// the program from `config.total_mints` — it is not an argument, because an
    /// id the chain will not defend is one two buyers can each pay for.
    pub fn mint_xployee(ctx: Context<MintXployee>, max_total: u64) -> Result<()> {
        instructions::mint_xployee::handler(ctx, max_total)
    }

    /// Moves the xployee into an escrow owned by the Listing PDA. No fee.
    pub fn list(
        ctx: Context<List>,
        kind: ListingKind,
        price: u64,
        fee_per_epoch: u64,
        term_epochs: u32,
    ) -> Result<()> {
        instructions::list::handler(ctx, kind, price, fee_per_epoch, term_epochs)
    }

    /// Returns the xployee to its seller and closes the listing. No fee.
    ///
    /// Available while paused — see invariant 4 — but refused while a rental term
    /// the renter has already paid for is still running.
    pub fn cancel_listing(ctx: Context<CancelListing>) -> Result<()> {
        instructions::cancel_listing::handler(ctx)
    }

    /// Atomic: buyer pays the seller `price` and the treasury the fee, the escrow
    /// releases the xployee, and both escrow and listing close in the same
    /// transaction. `max_total` is the buyer's slippage ceiling.
    pub fn buy(ctx: Context<Buy>, max_total: u64) -> Result<()> {
        instructions::buy::handler(ctx, max_total)
    }

    /// Renter pays the owner `fee_per_epoch * term_epochs` and the treasury the
    /// rental fee on top. The xployee never leaves escrow. `max_total` is the
    /// renter's slippage ceiling.
    ///
    /// Exclusive for the term: refused while the listing's `rented_until_epoch`
    /// is still ahead of the clock.
    pub fn rent(ctx: Context<RentXployee>, max_total: u64) -> Result<()> {
        instructions::rent::handler(ctx, max_total)
    }

    /// Permissionless once the term has run out. Closes the `Contract` and
    /// returns its rent-exempt lamports to the renter who paid them, which is
    /// also what frees the `(mint, renter)` seed for a future rental.
    pub fn close_contract(ctx: Context<CloseContract>) -> Result<()> {
        instructions::close_contract::handler(ctx)
    }

    /// Authority-gated. Moves `amount` from the treasury to `config.dev_wallet`'s
    /// associated token account and nowhere else.
    pub fn claim_fees(ctx: Context<ClaimFees>, amount: u64) -> Result<()> {
        instructions::claim_fees::handler(ctx, amount)
    }

    /// Authority-gated. Each field is optional so a pause does not require
    /// restating the fee rates.
    pub fn set_config(
        ctx: Context<SetConfig>,
        trade_fee_bps: Option<u16>,
        rent_fee_bps: Option<u16>,
        dev_wallet: Option<Pubkey>,
        paused: Option<bool>,
    ) -> Result<()> {
        instructions::set_config::handler(ctx, trade_fee_bps, rent_fee_bps, dev_wallet, paused)
    }

    /// Authority-gated. Step one of a two-step rotation: names a candidate and
    /// changes nothing else. `Pubkey::default()` cancels a proposal in flight.
    pub fn propose_authority(ctx: Context<ProposeAuthority>, new_authority: Pubkey) -> Result<()> {
        instructions::authority::propose_handler(ctx, new_authority)
    }

    /// Step two, signed by the proposed key itself. The signature is the proof
    /// that the incoming authority exists and is held — which is the whole reason
    /// this is two instructions and not one.
    pub fn accept_authority(ctx: Context<AcceptAuthority>) -> Result<()> {
        instructions::authority::accept_handler(ctx)
    }
}
