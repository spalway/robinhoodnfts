//! The only place a fee is computed. Every instruction that charges one calls
//! through here so the rounding direction cannot drift between mint, sale and
//! rent.
use anchor_lang::prelude::*;

use crate::constants::BPS_DENOM;
use crate::errors::XnftError;

/// `amount * fee_bps / 10_000`, rounded **up**.
///
/// The multiply happens in `u128` because `u64::MAX * 2000` overflows `u64` by
/// eleven bits — a raw-unit balance on a 9-decimal mint reaches that range long
/// before the token supply does. Narrowing back is a checked conversion rather
/// than an `as` cast, so a value that somehow exceeded `u64` becomes an error
/// instead of a truncated fee.
///
/// **Rounding up is deliberate.** The two halves of invariant 6 — "never leave
/// the treasury short" and "never over-charge the payer by a rounding unit" —
/// cannot both hold, because `amount * bps` is not always a multiple of 10_000.
/// One side has to absorb the sub-unit, and the choice made here is the payer's,
/// for three reasons:
///
///   1. The treasury is the side that has to reconcile. `config.total_fees` and
///      the treasury's token balance are compared against the Supabase
///      `fee_ledger`; a fee that is short by a sub-unit makes that comparison a
///      tolerance check instead of an equality.
///   2. Flooring makes every trade below `10_000/bps` raw units (20 units at 5%)
///      pay literally nothing. Ceiling keeps the fee positive whenever the
///      amount is.
///   3. The over-charge is bounded at one raw unit — 1e-6 of a token at six
///      decimals — and the payer sees it before signing, because `max_total` is
///      computed from this same function on the client.
///
/// The seller's side is untouched either way: the recipient is always paid
/// exactly `amount`, and the rounding lives entirely in the fee the payer adds
/// on top. `src/lib/fees.ts` must round the same direction or the client's
/// `max_total` will be one unit short of what the program charges.
pub fn fee_on(amount: u64, fee_bps: u16) -> Result<u64> {
    let numerator = (amount as u128)
        .checked_mul(fee_bps as u128)
        .ok_or(XnftError::MathOverflow)?;

    // Ceiling division as `(n + d - 1) / d`. The add cannot overflow u128: the
    // numerator is at most `u64::MAX * u16::MAX`, which is 80 bits.
    let fee = numerator
        .checked_add(BPS_DENOM as u128 - 1)
        .ok_or(XnftError::MathOverflow)?
        / BPS_DENOM as u128;

    u64::try_from(fee).map_err(|_| XnftError::MathOverflow.into())
}

/// `(fee, amount + fee)`. The other half of invariant 6: the recipient is paid
/// exactly `amount` and the payer is debited `amount + fee`, so no rounding unit
/// is ever taken out of the seller's proceeds.
///
/// Every instruction that charges a fee also takes a `max_total` the payer signs
/// over and compares it against the second element of this tuple — see
/// `check_slippage`.
pub fn fee_and_total(amount: u64, fee_bps: u16) -> Result<(u64, u64)> {
    let fee = fee_on(amount, fee_bps)?;
    let total = amount.checked_add(fee).ok_or(XnftError::MathOverflow)?;
    Ok((fee, total))
}

/// The payer signs over a ceiling on what the whole thing costs, and the program
/// refuses to exceed it.
///
/// Without this, every fee is recomputed from `Config` at execution time, so the
/// authority can raise `trade_fee_bps` in the gap between the payer signing and
/// the transaction landing and the payer has no way to have said no. The cap on
/// `MAX_FEE_BPS` bounds how bad that is; it does not make it consented to.
///
/// Deliberately a *total* rather than a fee rate: the rate is an implementation
/// detail of how the number was reached, and the total is the only figure the
/// payer actually saw in the UI.
pub fn check_slippage(total: u64, max_total: u64) -> Result<()> {
    require!(total <= max_total, XnftError::SlippageExceeded);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounds_up_at_one_raw_unit() {
        // 19 * 500 / 10_000 = 0.95 -> 1. The seller still receives all 19; the
        // sub-unit comes out of the buyer's side, never the treasury's.
        assert_eq!(fee_on(19, 500).unwrap(), 1);
        // 20 * 500 / 10_000 = 1.0 exactly — no rounding to do.
        assert_eq!(fee_on(20, 500).unwrap(), 1);
        // 39 * 500 / 10_000 = 1.95 -> 2, not 1.
        assert_eq!(fee_on(39, 500).unwrap(), 2);
        // The smallest non-zero amount still pays something, which flooring did
        // not: 1 * 500 / 10_000 = 0.05 -> 1.
        assert_eq!(fee_on(1, 500).unwrap(), 1);
    }

    #[test]
    fn the_treasury_is_never_short() {
        // The property the rounding direction exists to guarantee: the fee
        // collected is never less than the exact rational fee.
        for amount in [1u64, 2, 19, 20, 39, 100, 999, 12_345, 1_000_000] {
            for bps in [1u16, 500, 1_000, 1_999, 2_000] {
                let fee = fee_on(amount, bps).unwrap() as u128;
                let exact = amount as u128 * bps as u128;
                assert!(fee * 10_000 >= exact, "short at {amount} @ {bps}bps");
                // And never over by a whole unit — the over-charge is bounded.
                assert!((fee - 1) * 10_000 < exact, "over at {amount} @ {bps}bps");
            }
        }
    }

    #[test]
    fn mint_case_is_exact() {
        // The spec's headline number: 10_000 whole tokens at 6 decimals.
        let mint_cost: u64 = 10_000 * 1_000_000;
        let (fee, total) = fee_and_total(mint_cost, 500).unwrap();
        assert_eq!(fee, 500 * 1_000_000);
        assert_eq!(total, 10_500 * 1_000_000);
    }

    #[test]
    fn boundaries() {
        // A zero rate rounds to zero rather than up to one — ceiling division of
        // an exact zero is still zero, so "no fee configured" means no fee.
        assert_eq!(fee_on(u64::MAX, 0).unwrap(), 0);
        assert_eq!(fee_on(0, 2_000).unwrap(), 0);
        // 20% of u64::MAX still fits in u64 once narrowed, which is the whole
        // reason MAX_FEE_BPS exists as a program-level cap.
        assert_eq!(
            fee_on(u64::MAX, 2_000).unwrap(),
            ((u64::MAX as u128 * 2_000 + 9_999) / 10_000) as u64
        );
    }

    #[test]
    fn total_overflow_is_an_error_not_a_wrap() {
        assert!(fee_and_total(u64::MAX, 500).is_err());
    }

    #[test]
    fn slippage_is_inclusive_at_the_ceiling() {
        // Equal to the signed maximum is fine; a single unit over is not. An
        // exclusive bound would reject the quote the client itself computed.
        assert!(check_slippage(10_500, 10_500).is_ok());
        assert!(check_slippage(10_501, 10_500).is_err());
        assert!(check_slippage(0, 0).is_ok());
    }
}
