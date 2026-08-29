use anchor_lang::prelude::*;

#[error_code]
pub enum XnftError {
    #[msg("The protocol is paused; no value may move.")]
    ProgramPaused,
    #[msg("Fee rate exceeds the program's hard ceiling of 2000 bps.")]
    FeeTooHigh,
    #[msg("Arithmetic overflow computing a fee or total.")]
    MathOverflow,
    #[msg("Mint cost must be greater than zero.")]
    InvalidMintCost,
    #[msg("The dev wallet may not be the default pubkey.")]
    InvalidDevWallet,
    #[msg("Listing price must be greater than zero.")]
    InvalidPrice,
    #[msg("A rental listing needs a positive per-epoch fee and a positive term.")]
    InvalidRentalTerms,
    #[msg("This listing is for rent, not for sale.")]
    NotForSale,
    #[msg("This listing is for sale, not for rent.")]
    NotForRent,
    #[msg("An xployee must be a zero-decimal, supply-one mint with no live mint authority.")]
    NotAnNft,
    #[msg("The $xNFT mint cannot itself be listed as an xployee.")]
    CannotListPaymentMint,
    #[msg("The seller does not hold the NFT being listed.")]
    SellerDoesNotHoldNft,
    #[msg("Escrow does not hold the listed NFT.")]
    EscrowEmpty,
    #[msg("Not enough $xNFT to cover the price plus the protocol fee.")]
    InsufficientFunds,
    #[msg("Claim exceeds the treasury balance.")]
    InsufficientTreasury,
    #[msg("Amount must be greater than zero.")]
    ZeroAmount,
    #[msg("The payment account is not owned by this listing's seller.")]
    WrongSeller,
    #[msg("Payouts may only be sent to the dev wallet recorded in Config.")]
    WrongPayoutDestination,
    #[msg("The burn leg must be sent to the incinerator recorded in the program.")]
    WrongBurnDestination,
    #[msg("initialize must be signed by the program's upgrade authority.")]
    NotUpgradeAuthority,
    #[msg("No authority transfer has been proposed.")]
    NoPendingAuthority,
    #[msg("The proposed authority may not be the default pubkey.")]
    InvalidAuthority,
    #[msg("This xployee is rented for the rest of its term.")]
    RentalActive,
    #[msg("A rental contract cannot be closed before its term ends.")]
    ContractNotExpired,
    #[msg("Total cost exceeds the maximum the payer signed for.")]
    SlippageExceeded,
}
