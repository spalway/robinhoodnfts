// Deliberately a no-op.
//
// `initialize` fixes the $xNFT mint, the dev wallet and the fee rates for the
// life of the deployment, and $xNFT does not exist yet. Running it from a
// migration would bind the program to whatever placeholder mint happened to be
// around at deploy time, which is exactly the mistake `XNFT_MINT_ADDRESS = ''`
// in src/lib/solana.ts exists to prevent. Initialize explicitly, once, with the
// real mint in hand.
module.exports = async function () {};
