use anchor_lang::prelude::*;
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};

use crate::constants::{CONFIG_SEED, MAX_FEE_BPS, TREASURY_SEED};
use crate::errors::XnftError;
use crate::program::XnftMarket;
use crate::state::Config;

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,

    /// This program, carried only so its ProgramData address can be derived and
    /// matched against the account below. Anchor checks the address against
    /// `declare_id!`, so it cannot be substituted.
    #[account(
        constraint = xnft_program.programdata_address()? == Some(program_data.key())
            @ XnftError::NotUpgradeAuthority,
    )]
    pub xnft_program: Program<'info, XnftMarket>,

    /// The deployment's upgrade authority, and the entire authorisation story for
    /// this instruction.
    ///
    /// `Config` lives at a fixed `["config"]` PDA, so an unpermissioned
    /// `initialize` is a race the deployer does not necessarily win: anyone
    /// watching the deploy transaction land can send their own `initialize` in
    /// the same slot and own the authority key, the fee rates and the payout
    /// destination permanently. There is no second chance, because `init` on the
    /// singleton fails ever after.
    ///
    /// The upgrade authority is the right key to check because it is the one
    /// identity the chain already agrees owns this program — it is set by the
    /// deploy itself and cannot be front-run.
    #[account(
        constraint = program_data.upgrade_authority_address == Some(authority.key())
            @ XnftError::NotUpgradeAuthority,
    )]
    pub program_data: Account<'info, ProgramData>,

    /// The $xNFT mint. Recorded in Config and thereafter the only mint this
    /// program will move — every payment account is checked against it, so a
    /// later instruction cannot be tricked into settling in a different token.
    pub xnft_mint: InterfaceAccount<'info, Mint>,

    #[account(
        init,
        payer = authority,
        space = 8 + Config::INIT_SPACE,
        seeds = [CONFIG_SEED],
        bump,
    )]
    pub config: Account<'info, Config>,

    /// The treasury is its own authority. Nothing outside this program holds a
    /// key that can sign it, and inside the program the only instruction that
    /// signs with `["treasury", bump]` is `claim_fees` — so fees are reachable
    /// exactly one way.
    #[account(
        init,
        payer = authority,
        seeds = [TREASURY_SEED],
        bump,
        token::mint = xnft_mint,
        token::authority = treasury,
        token::token_program = token_program,
    )]
    pub treasury: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn handler(
    ctx: Context<Initialize>,
    trade_fee_bps: u16,
    rent_fee_bps: u16,
    mint_cost: u64,
    dev_wallet: Pubkey,
) -> Result<()> {
    // The ceiling is checked here as well as in set_config. A program that only
    // guards the update path can be deployed with a 100% fee on day one.
    require!(trade_fee_bps <= MAX_FEE_BPS, XnftError::FeeTooHigh);
    require!(rent_fee_bps <= MAX_FEE_BPS, XnftError::FeeTooHigh);
    require!(mint_cost > 0, XnftError::InvalidMintCost);
    // The default pubkey has no signer and no ATA anyone can create meaningfully;
    // accepting it would strand every fee the protocol ever collects.
    require_keys_neq!(dev_wallet, Pubkey::default(), XnftError::InvalidDevWallet);

    let config = &mut ctx.accounts.config;
    config.authority = ctx.accounts.authority.key();
    config.xnft_mint = ctx.accounts.xnft_mint.key();
    config.dev_wallet = dev_wallet;
    config.trade_fee_bps = trade_fee_bps;
    config.rent_fee_bps = rent_fee_bps;
    config.mint_cost = mint_cost;
    config.paused = false;
    config.total_burned = 0;
    config.total_fees = 0;
    config.total_claimed = 0;
    config.total_mints = 0;
    config.total_trades = 0;
    config.bump = ctx.bumps.config;
    config.treasury_bump = ctx.bumps.treasury;
    // No rotation in flight. `accept_authority` refuses the default pubkey, so a
    // fresh Config cannot be taken over by anyone who can produce a signature for
    // an address nobody holds.
    config.pending_authority = Pubkey::default();

    Ok(())
}
