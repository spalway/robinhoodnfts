// Program tests for xnft_market.
//
// The suite is organised around the six safety invariants rather than around the
// instruction list, because the invariants are the thing that has to survive a
// refactor. Every money assertion compares a before/after delta rather than an
// absolute balance, so tests stay order-independent as the file grows.
import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  AuthorityType,
  TOKEN_PROGRAM_ID,
  createAssociatedTokenAccount,
  createMint,
  createTransferCheckedInstruction,
  getAccount,
  getAssociatedTokenAddressSync,
  mintTo,
  setAuthority,
} from "@solana/spl-token";
import {
  Keypair,
  LAMPORTS_PER_SOL,
  PublicKey,
  SystemProgram,
  Transaction,
} from "@solana/web3.js";
import { assert } from "chai";
import { XnftMarket } from "../target/types/xnft_market";

// ---------------------------------------------------------------------------
// Constants mirrored from the program. Duplicated deliberately: a test that
// imports the value it is checking cannot catch a change to that value.
// ---------------------------------------------------------------------------
const DECIMALS = 6;
const UNIT = new BN(10).pow(new BN(DECIMALS));
const MINT_COST = new BN(10_000).mul(UNIT);
const MINT_FEE = new BN(500).mul(UNIT);
const MINT_TOTAL = new BN(10_500).mul(UNIT);
const TRADE_FEE_BPS = 500;
const RENT_FEE_BPS = 1_000;
const MAX_FEE_BPS = 2_000;
const FUNDING = new BN(1_000_000).mul(UNIT);

const INCINERATOR = new PublicKey("1nc1nerator11111111111111111111111111111111");
// Hardcoded rather than imported: web3.js exports the non-upgradeable loader id
// under a confusingly similar name, and picking the wrong one derives a
// ProgramData address the program will reject with no useful message.
const BPF_LOADER_UPGRADEABLE = new PublicKey(
  "BPFLoaderUpgradeab1e11111111111111111111111",
);

const CONFIG_SEED = Buffer.from("config");
const TREASURY_SEED = Buffer.from("treasury");
const LISTING_SEED = Buffer.from("listing");
const ESCROW_SEED = Buffer.from("escrow");
const CONTRACT_SEED = Buffer.from("contract");

type ListingKindArg = { sale: Record<string, never> } | { rent: Record<string, never> };
const SALE: ListingKindArg = { sale: {} };
const RENT: ListingKindArg = { rent: {} };

describe("xnft_market", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  // Anchor renamed the workspace keys from PascalCase to camelCase in 0.31.
  // Accepting both keeps the suite runnable against either CLI rather than
  // failing with an unhelpful "cannot read property methods of undefined".
  const workspace = anchor.workspace as Record<string, Program<XnftMarket>>;
  const program: Program<XnftMarket> = workspace.xnftMarket ?? workspace.XnftMarket;

  const connection = provider.connection;
  const payer = (provider.wallet as anchor.Wallet).payer;
  const authority = payer;

  const devWallet = Keypair.generate();
  const seller = Keypair.generate();
  const buyer = Keypair.generate();
  const renter = Keypair.generate();
  // A second and third renter, because rental exclusivity is a claim about two
  // different wallets and the Contract PDA's renter seed already separates one
  // wallet from itself.
  const renter2 = Keypair.generate();
  const renter3 = Keypair.generate();
  const outsider = Keypair.generate();

  // Definite-assignment markers: every one of these is set in `before`, which
  // TypeScript's flow analysis cannot see from inside the test closures.
  let xnftMint!: PublicKey;
  let configPda!: PublicKey;
  let treasuryPda!: PublicKey;
  let programDataPda!: PublicKey;

  let sellerXnft!: PublicKey;
  let buyerXnft!: PublicKey;
  let renterXnft!: PublicKey;
  let renter2Xnft!: PublicKey;
  let renter3Xnft!: PublicKey;
  let outsiderXnft!: PublicKey;
  let incineratorXnft!: PublicKey;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------
  const big = (v: BN | number): bigint => BigInt(v.toString());

  /**
   * The fee, rounded UP, mirroring `math::fee_on`.
   *
   * Duplicated rather than imported for the same reason as the constants above,
   * and written as explicit ceiling division rather than `divn` so a future
   * change to the rounding direction has to be made here too — deliberately,
   * with this test failing first.
   */
  const feeOf = (amount: BN, bps: number): BN =>
    amount.muln(bps).addn(9_999).divn(10_000);

  /** What the payer is debited, and therefore what they sign as `max_total`. */
  const totalOf = (amount: BN, bps: number): BN => amount.add(feeOf(amount, bps));

  const listingPda = (nftMint: PublicKey) =>
    PublicKey.findProgramAddressSync(
      [LISTING_SEED, nftMint.toBuffer()],
      program.programId,
    )[0];

  const escrowPda = (nftMint: PublicKey) =>
    PublicKey.findProgramAddressSync(
      [ESCROW_SEED, nftMint.toBuffer()],
      program.programId,
    )[0];

  const contractPda = (nftMint: PublicKey, renterKey: PublicKey) =>
    PublicKey.findProgramAddressSync(
      [CONTRACT_SEED, nftMint.toBuffer(), renterKey.toBuffer()],
      program.programId,
    )[0];

  async function balance(tokenAccount: PublicKey): Promise<bigint> {
    return (await getAccount(connection, tokenAccount)).amount;
  }

  async function fund(target: PublicKey, sol = 5): Promise<void> {
    const signature = await connection.requestAirdrop(target, sol * LAMPORTS_PER_SOL);
    const latest = await connection.getLatestBlockhash();
    await connection.confirmTransaction({ signature, ...latest }, "confirmed");
  }

  /**
   * Blocks until the cluster reaches `target`.
   *
   * Rental terms are measured in epochs, so a test of expiry has to actually
   * cross one. `Anchor.toml` pins the validator to 32 slots per epoch — the
   * protocol minimum, roughly thirteen seconds — precisely so this returns
   * rather than sitting in epoch 0 for the life of the suite.
   */
  async function waitForEpoch(target: number, timeoutMs = 120_000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const { epoch } = await connection.getEpochInfo();
      if (epoch >= target) return;
      if (Date.now() > deadline) {
        assert.fail(`still in epoch ${epoch} after waiting for ${target}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }

  const currentEpoch = async (): Promise<number> =>
    (await connection.getEpochInfo()).epoch;

  /**
   * Decode the anchor events emitted by a transaction from its logs — the same
   * `Program data:` lines the Supabase ingest function reads, so a decode failure
   * here is a decode failure there.
   *
   * Polled rather than read once: a local validator will confirm a signature
   * before `getTransaction` can serve it, and a null response is a timing
   * artefact rather than a missing event.
   */
  async function eventsOf(signature: string): Promise<{ name: string; data: any }[]> {
    await connection.confirmTransaction(signature, "confirmed");
    const prefix = "Program data: ";
    for (let attempt = 0; attempt < 20; attempt++) {
      const tx = await connection.getTransaction(signature, {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
      });
      if (tx) {
        const out: { name: string; data: any }[] = [];
        for (const log of tx.meta?.logMessages ?? []) {
          if (!log.startsWith(prefix)) continue;
          const decoded = program.coder.events.decode(log.slice(prefix.length));
          if (decoded) out.push(decoded as { name: string; data: any });
        }
        return out;
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    assert.fail(`could not read logs for ${signature}`);
  }

  /** Event names are camelCased by the 0.30+ IDL; match without caring which. */
  function eventNamed(events: { name: string; data: any }[], name: string): any {
    const found = events.find((e) => e.name.toLowerCase() === name.toLowerCase());
    assert.isDefined(found, `expected a ${name} in the transaction logs`);
    return found!.data;
  }

  /**
   * Asserts a transaction was rejected, and — when `code` is given — that it was
   * rejected for the stated reason. Matching on the error code rather than on
   * "it threw" is what stops a test passing because of an unrelated failure.
   */
  async function rejects(promise: Promise<unknown>, code?: string): Promise<void> {
    try {
      await promise;
    } catch (e: any) {
      if (!code) return;
      const parsed = anchor.AnchorError.parse(e?.logs ?? null);
      if (parsed) {
        assert.strictEqual(
          parsed.error.errorCode.code,
          code,
          `expected ${code}, got ${parsed.error.errorCode.code}`,
        );
        return;
      }
      // Non-anchor failures (the token program's own errors) carry no code.
      assert.include(`${e?.message ?? e} ${JSON.stringify(e?.logs ?? [])}`, code);
      return;
    }
    assert.fail(`expected the transaction to be rejected${code ? ` with ${code}` : ""}`);
  }

  /**
   * A genuine NFT: zero decimals, a supply of exactly one, and no mint authority
   * left alive to make that supply a lie. `list` refuses anything less, because
   * a second unit transferred into the escrow PDA makes both `buy` and
   * `cancel_listing` fail on `close_account` forever.
   */
  async function mintNft(owner: Keypair): Promise<{ mint: PublicKey; ata: PublicKey }> {
    const mint = await createMint(connection, payer, payer.publicKey, null, 0);
    const ata = await createAssociatedTokenAccount(connection, payer, mint, owner.publicKey);
    await mintTo(connection, payer, mint, ata, payer, 1);
    await setAuthority(connection, payer, mint, payer, AuthorityType.MintTokens, null);
    return { mint, ata };
  }

  /** A zero-decimal mint that is *not* an NFT, for the negative cases. */
  async function mintFungible(
    owner: Keypair,
    supply: number,
    revokeAuthority: boolean,
  ): Promise<{ mint: PublicKey; ata: PublicKey }> {
    const mint = await createMint(connection, payer, payer.publicKey, null, 0);
    const ata = await createAssociatedTokenAccount(connection, payer, mint, owner.publicKey);
    await mintTo(connection, payer, mint, ata, payer, supply);
    if (revokeAuthority) {
      await setAuthority(connection, payer, mint, payer, AuthorityType.MintTokens, null);
    }
    return { mint, ata };
  }

  async function listNft(
    kind: ListingKindArg,
    price: BN,
    feePerEpoch: BN,
    termEpochs: number,
  ): Promise<{ mint: PublicKey; ata: PublicKey; listing: PublicKey; escrow: PublicKey }> {
    const { mint, ata } = await mintNft(seller);
    const listing = listingPda(mint);
    const escrow = escrowPda(mint);
    await program.methods
      .list(kind as any, price, feePerEpoch, termEpochs)
      .accountsPartial({
        seller: seller.publicKey,
        config: configPda,
        nftMint: mint,
        sellerNft: ata,
        listing,
        escrow,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([seller])
      .rpc();
    return { mint, ata, listing, escrow };
  }

  function buyAccounts(nftMint: PublicKey, buyerKp: Keypair, buyerPayment: PublicKey) {
    return {
      buyer: buyerKp.publicKey,
      xnftMint,
      config: configPda,
      nftMint,
      seller: seller.publicKey,
      listing: listingPda(nftMint),
      escrow: escrowPda(nftMint),
      buyerNft: getAssociatedTokenAddressSync(nftMint, buyerKp.publicKey),
      buyerToken: buyerPayment,
      sellerToken: sellerXnft,
      treasury: treasuryPda,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    };
  }

  // -------------------------------------------------------------------------
  // Setup
  // -------------------------------------------------------------------------
  before(async () => {
    await Promise.all([
      fund(seller.publicKey),
      fund(buyer.publicKey),
      fund(renter.publicKey),
      fund(renter2.publicKey),
      fund(renter3.publicKey),
      fund(outsider.publicKey),
    ]);

    xnftMint = await createMint(connection, payer, payer.publicKey, null, DECIMALS);

    [configPda] = PublicKey.findProgramAddressSync([CONFIG_SEED], program.programId);
    [treasuryPda] = PublicKey.findProgramAddressSync([TREASURY_SEED], program.programId);
    // The upgradeable loader stores a program's ProgramData at [program_id]
    // under its own program id. `initialize` reads the upgrade authority out of
    // it, which is what stops the fixed ["config"] PDA being front-run.
    [programDataPda] = PublicKey.findProgramAddressSync(
      [program.programId.toBuffer()],
      BPF_LOADER_UPGRADEABLE,
    );

    const holders: [Keypair, (v: PublicKey) => void][] = [
      [seller, (v) => (sellerXnft = v)],
      [buyer, (v) => (buyerXnft = v)],
      [renter, (v) => (renterXnft = v)],
      [renter2, (v) => (renter2Xnft = v)],
      [renter3, (v) => (renter3Xnft = v)],
      [outsider, (v) => (outsiderXnft = v)],
    ];
    for (const [holder, set] of holders) {
      const ata = await createAssociatedTokenAccount(
        connection,
        payer,
        xnftMint,
        holder.publicKey,
      );
      await mintTo(connection, payer, xnftMint, ata, payer, big(FUNDING));
      set(ata);
    }

    // allowOwnerOffCurve: the incinerator is not a valid ed25519 point, so the
    // default ATA derivation refuses it. This is the same flag src/lib/solana.ts
    // passes, and getting it wrong derives an address the program will reject.
    incineratorXnft = getAssociatedTokenAddressSync(xnftMint, INCINERATOR, true);

    await program.methods
      .initialize(TRADE_FEE_BPS, RENT_FEE_BPS, MINT_COST, devWallet.publicKey)
      .accountsPartial(initAccounts(authority.publicKey))
      .rpc();
  });

  function initAccounts(authorityKey: PublicKey) {
    return {
      authority: authorityKey,
      xnftProgram: program.programId,
      programData: programDataPda,
      xnftMint,
      config: configPda,
      treasury: treasuryPda,
      tokenProgram: TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    };
  }

  // -------------------------------------------------------------------------
  describe("initialize", () => {
    it("records the mint, dev wallet, rates and bumps", async () => {
      const config = await program.account.config.fetch(configPda);
      assert.isTrue(config.authority.equals(authority.publicKey));
      assert.isTrue(config.xnftMint.equals(xnftMint));
      assert.isTrue(config.devWallet.equals(devWallet.publicKey));
      assert.strictEqual(config.tradeFeeBps, TRADE_FEE_BPS);
      assert.strictEqual(config.rentFeeBps, RENT_FEE_BPS);
      assert.strictEqual(config.mintCost.toString(), MINT_COST.toString());
      assert.isFalse(config.paused);
      assert.strictEqual(config.totalFees.toString(), "0");
      // Nothing proposed. `accept_authority` refuses the default pubkey, so a
      // fresh Config has no rotation anyone can complete.
      assert.isTrue(config.pendingAuthority.equals(PublicKey.default));
    });

    it("records the deploy's upgrade authority as the protocol authority", async () => {
      // The front-running case this closes: Config lives at a fixed ["config"]
      // PDA, so whoever lands `initialize` first owns the fee rates and the
      // payout destination forever, and there is no second chance. The upgrade
      // authority is the one identity the chain already agrees owns this
      // program — it is set by the deploy itself and cannot be raced.
      //
      // The suite's `before` ran `initialize` signed by the provider wallet,
      // which is that upgrade authority, and it succeeded. That it succeeded
      // *only* for that key is what the next two tests are about.
      const programDataAccount = await connection.getAccountInfo(programDataPda);
      assert.isNotNull(programDataAccount, "program must be deployed upgradeable");
      assert.isTrue(programDataAccount!.owner.equals(BPF_LOADER_UPGRADEABLE));

      const config = await program.account.config.fetch(configPda);
      assert.isTrue(config.authority.equals(authority.publicKey));
    });

    it("refuses a signer who is not the program's upgrade authority", async () => {
      // Asserted without an error code on purpose. Anchor resolves `init` during
      // account deserialization and `constraint =` afterwards, so on an already
      // initialised workspace the singleton's `init` is what surfaces — the
      // authority constraint never gets to speak. What can be asserted here is
      // that the transaction cannot land and that nothing moved, which is the
      // behaviour that matters; the constraint itself is exercised by the
      // ProgramData substitution below, which fails in the deserialization phase
      // and therefore does carry a code.
      await rejects(
        program.methods
          .initialize(TRADE_FEE_BPS, RENT_FEE_BPS, MINT_COST, devWallet.publicKey)
          .accountsPartial(initAccounts(outsider.publicKey))
          .signers([outsider])
          .rpc(),
      );

      const config = await program.account.config.fetch(configPda);
      assert.isTrue(config.authority.equals(authority.publicKey));
      assert.isTrue(config.devWallet.equals(devWallet.publicKey));
    });

    it("refuses anything but a real ProgramData account in that slot", async () => {
      // Substituting an account the caller controls is the obvious way around an
      // upgrade-authority check. `Account<ProgramData>` pins the owner to the
      // upgradeable loader, and that check runs while accounts are being
      // deserialized — before `init` on the singleton — so this one is
      // deterministic.
      await rejects(
        program.methods
          .initialize(TRADE_FEE_BPS, RENT_FEE_BPS, MINT_COST, devWallet.publicKey)
          .accountsPartial({
            ...initAccounts(authority.publicKey),
            programData: configPda,
          })
          .rpc(),
        "AccountOwnedByWrongProgram",
      );
    });

    it("creates a treasury the treasury itself owns", async () => {
      const treasury = await getAccount(connection, treasuryPda);
      assert.isTrue(treasury.mint.equals(xnftMint));
      // Invariant 5's sibling: nobody outside this program holds a key that can
      // sign the treasury, and inside it only claim_fees signs those seeds.
      assert.isTrue(treasury.owner.equals(treasuryPda));
      assert.strictEqual(treasury.amount, 0n);
    });

    it("cannot be run twice", async () => {
      await rejects(
        program.methods
          .initialize(TRADE_FEE_BPS, RENT_FEE_BPS, MINT_COST, devWallet.publicKey)
          .accountsPartial(initAccounts(authority.publicKey))
          .rpc(),
      );
    });
  });

  // -------------------------------------------------------------------------
  describe("set_config — invariant 2, the fee ceiling", () => {
    it("rejects a trade fee above MAX_FEE_BPS", async () => {
      await rejects(
        program.methods
          .setConfig(MAX_FEE_BPS + 1, null, null, null)
          .accountsPartial({ authority: authority.publicKey, config: configPda })
          .rpc(),
        "FeeTooHigh",
      );
    });

    it("rejects a rent fee above MAX_FEE_BPS", async () => {
      await rejects(
        program.methods
          .setConfig(null, MAX_FEE_BPS + 1, null, null)
          .accountsPartial({ authority: authority.publicKey, config: configPda })
          .rpc(),
        "FeeTooHigh",
      );
    });

    it("rejects a 100% fee outright", async () => {
      await rejects(
        program.methods
          .setConfig(10_000, null, null, null)
          .accountsPartial({ authority: authority.publicKey, config: configPda })
          .rpc(),
        "FeeTooHigh",
      );
    });

    it("accepts exactly MAX_FEE_BPS, then restores the real rate", async () => {
      await program.methods
        .setConfig(MAX_FEE_BPS, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
      assert.strictEqual((await program.account.config.fetch(configPda)).tradeFeeBps, MAX_FEE_BPS);

      await program.methods
        .setConfig(TRADE_FEE_BPS, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
      assert.strictEqual(
        (await program.account.config.fetch(configPda)).tradeFeeBps,
        TRADE_FEE_BPS,
      );
    });

    it("rejects a non-authority signer", async () => {
      await rejects(
        program.methods
          .setConfig(null, null, null, true)
          .accountsPartial({ authority: outsider.publicKey, config: configPda })
          .signers([outsider])
          .rpc(),
        "ConstraintHasOne",
      );
    });

    it("refuses the default pubkey as a dev wallet", async () => {
      await rejects(
        program.methods
          .setConfig(null, null, PublicKey.default, null)
          .accountsPartial({ authority: authority.publicKey, config: configPda })
          .rpc(),
        "InvalidDevWallet",
      );
    });

    it("leaves untouched fields alone when only one is passed", async () => {
      const before = await program.account.config.fetch(configPda);
      await program.methods
        .setConfig(null, null, null, false)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
      const after = await program.account.config.fetch(configPda);
      assert.strictEqual(after.tradeFeeBps, before.tradeFeeBps);
      assert.strictEqual(after.rentFeeBps, before.rentFeeBps);
      assert.isTrue(after.devWallet.equals(before.devWallet));
    });
  });

  // -------------------------------------------------------------------------
  describe("mint_xployee", () => {
    function mintAccounts(buyerKp: Keypair, buyerPayment: PublicKey) {
      return {
        buyer: buyerKp.publicKey,
        xnftMint,
        config: configPda,
        buyerToken: buyerPayment,
        incinerator: INCINERATOR,
        incineratorToken: incineratorXnft,
        treasury: treasuryPda,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      };
    }

    it("burns exactly mint_cost and charges 5% on top", async () => {
      const buyerBefore = await balance(buyerXnft);
      const treasuryBefore = await balance(treasuryPda);

      const signature = await program.methods
        .mintXployee(MINT_TOTAL)
        .accountsPartial(mintAccounts(buyer, buyerXnft))
        .signers([buyer])
        .rpc();

      assert.strictEqual(await balance(buyerXnft), buyerBefore - big(MINT_TOTAL));
      assert.strictEqual(await balance(incineratorXnft), big(MINT_COST));
      assert.strictEqual(await balance(treasuryPda), treasuryBefore + big(MINT_FEE));

      const event = eventNamed(await eventsOf(signature), "MintEvent");
      assert.strictEqual(event.burned.toString(), MINT_COST.toString());
      assert.strictEqual(event.fee.toString(), MINT_FEE.toString());
      assert.strictEqual(event.total.toString(), MINT_TOTAL.toString());
      // Assigned by the program from `total_mints`, which was zero. Nothing the
      // caller passed appears here — the id is no longer an argument at all.
      assert.strictEqual(event.xployeeId.toString(), "0");
      assert.strictEqual(event.feeBps, TRADE_FEE_BPS);
      assert.isTrue(event.buyer.equals(buyer.publicKey));
    });

    it("advances the lifetime counters", async () => {
      const config = await program.account.config.fetch(configPda);
      assert.strictEqual(config.totalMints.toString(), "1");
      assert.strictEqual(config.totalBurned.toString(), MINT_COST.toString());
      assert.strictEqual(config.totalFees.toString(), MINT_FEE.toString());
    });

    it("assigns ids from the counter, so two buyers cannot claim the same one", async () => {
      // The defect this closes: `xployee_id` used to be an unvalidated argument
      // echoed into the event, so two buyers could each burn a full mint cost
      // claiming id 7 and the index would have to pick a winner after the money
      // was already destroyed.
      const first = await program.methods
        .mintXployee(MINT_TOTAL)
        .accountsPartial(mintAccounts(buyer, buyerXnft))
        .signers([buyer])
        .rpc();
      const second = await program.methods
        .mintXployee(MINT_TOTAL)
        .accountsPartial(mintAccounts(seller, sellerXnft))
        .signers([seller])
        .rpc();

      const firstId = eventNamed(await eventsOf(first), "MintEvent").xployeeId;
      const secondId = eventNamed(await eventsOf(second), "MintEvent").xployeeId;
      assert.strictEqual(firstId.toString(), "1");
      assert.strictEqual(secondId.toString(), "2");

      const config = await program.account.config.fetch(configPda);
      assert.strictEqual(config.totalMints.toString(), "3");
    });

    it("rejects a total above the buyer's signed maximum", async () => {
      // One raw unit under the real total. A buyer who signed for less than the
      // mint costs does not get charged more; they get nothing.
      await rejects(
        program.methods
          .mintXployee(MINT_TOTAL.subn(1))
          .accountsPartial(mintAccounts(buyer, buyerXnft))
          .signers([buyer])
          .rpc(),
        "SlippageExceeded",
      );
    });

    it("refuses to charge a fee the buyer signed before the authority raised it", async () => {
      // The whole point of `max_total`: the fee is read from Config at execution
      // time, so without this the authority can raise the rate in the gap
      // between the wallet signing and the transaction landing.
      const quotedTotal = MINT_TOTAL;
      await program.methods
        .setConfig(MAX_FEE_BPS, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();

      const buyerBefore = await balance(buyerXnft);
      await rejects(
        program.methods
          .mintXployee(quotedTotal)
          .accountsPartial(mintAccounts(buyer, buyerXnft))
          .signers([buyer])
          .rpc(),
        "SlippageExceeded",
      );
      assert.strictEqual(await balance(buyerXnft), buyerBefore);

      await program.methods
        .setConfig(TRADE_FEE_BPS, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
    });

    it("rejects a destination that is not the incinerator", async () => {
      const fakeBurn = getAssociatedTokenAddressSync(xnftMint, outsider.publicKey);
      await rejects(
        program.methods
          .mintXployee(MINT_TOTAL)
          .accountsPartial({
            ...mintAccounts(buyer, buyerXnft),
            incinerator: outsider.publicKey,
            incineratorToken: fakeBurn,
          })
          .signers([buyer])
          .rpc(),
        "WrongBurnDestination",
      );
    });

    it("rejects a buyer who cannot cover cost plus fee", async () => {
      const pauper = Keypair.generate();
      await fund(pauper.publicKey);
      const ata = await createAssociatedTokenAccount(connection, payer, xnftMint, pauper.publicKey);
      // One raw unit short of the total: enough for the burn, not for the fee.
      await mintTo(connection, payer, xnftMint, ata, payer, big(MINT_TOTAL) - 1n);

      const incineratorBefore = await balance(incineratorXnft);
      await rejects(
        program.methods
          .mintXployee(MINT_TOTAL)
          .accountsPartial(mintAccounts(pauper, ata))
          .signers([pauper])
          .rpc(),
        "InsufficientFunds",
      );
      // Nothing partial: the burn leg did not land on its own.
      assert.strictEqual(await balance(incineratorXnft), incineratorBefore);
      assert.strictEqual(await balance(ata), big(MINT_TOTAL) - 1n);
    });
  });

  // -------------------------------------------------------------------------
  describe("invariant 4 — the pause gate", () => {
    async function setPaused(paused: boolean) {
      await program.methods
        .setConfig(null, null, null, paused)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
    }

    it("blocks every instruction that moves protocol value while paused", async () => {
      const price = new BN(1_000).mul(UNIT);
      const listed = await listNft(SALE, price, new BN(0), 0);
      await setPaused(true);

      await rejects(
        program.methods
          .mintXployee(MINT_TOTAL)
          .accountsPartial({
            buyer: buyer.publicKey,
            xnftMint,
            config: configPda,
            buyerToken: buyerXnft,
            incinerator: INCINERATOR,
            incineratorToken: incineratorXnft,
            treasury: treasuryPda,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([buyer])
          .rpc(),
        "ProgramPaused",
      );

      await rejects(
        program.methods
          .buy(totalOf(price, TRADE_FEE_BPS))
          .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
          .signers([buyer])
          .rpc(),
        "ProgramPaused",
      );

      await rejects(
        program.methods
          .claimFees(new BN(1))
          .accountsPartial({
            authority: authority.publicKey,
            xnftMint,
            config: configPda,
            devWallet: devWallet.publicKey,
            devWalletToken: getAssociatedTokenAddressSync(xnftMint, devWallet.publicKey),
            treasury: treasuryPda,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc(),
        "ProgramPaused",
      );

      await setPaused(false);
    });

    it("still lets a seller withdraw their own xployee while paused", async () => {
      // The carve-out from invariant 4, and the reason it exists: `cancel_listing`
      // hands a seller back an asset that was already theirs and charges nothing.
      // Gating it would give the authority a switch that holds every escrowed
      // xployee hostage, which is a rug with extra steps. A pause must be able to
      // stop the protocol earning without being able to trap user property.
      const listed = await listNft(SALE, new BN(1_000).mul(UNIT), new BN(0), 0);
      await setPaused(true);

      await program.methods
        .cancelListing()
        .accountsPartial({
          seller: seller.publicKey,
          config: configPda,
          nftMint: listed.mint,
          listing: listed.listing,
          escrow: listed.escrow,
          sellerNft: listed.ata,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([seller])
        .rpc();

      assert.strictEqual(await balance(listed.ata), 1n);
      assert.isNull(await connection.getAccountInfo(listed.escrow));
      assert.isNull(await connection.getAccountInfo(listed.listing));
      assert.isTrue((await program.account.config.fetch(configPda)).paused);

      await setPaused(false);
    });
  });

  // -------------------------------------------------------------------------
  describe("list / cancel_listing — invariant 5, escrow has two exits", () => {
    it("moves the xployee into an escrow the Listing PDA owns", async () => {
      const listed = await listNft(SALE, new BN(1_234).mul(UNIT), new BN(0), 0);

      assert.strictEqual(await balance(listed.ata), 0n);
      assert.strictEqual(await balance(listed.escrow), 1n);

      const escrow = await getAccount(connection, listed.escrow);
      assert.isTrue(escrow.owner.equals(listed.listing));

      const listing = await program.account.listing.fetch(listed.listing);
      assert.isTrue(listing.seller.equals(seller.publicKey));
      assert.strictEqual(listing.price.toString(), new BN(1_234).mul(UNIT).toString());
      assert.deepStrictEqual(listing.kind, { sale: {} });
      // A sale listing stores zeroed rental terms rather than whatever was passed.
      assert.strictEqual(listing.feePerEpoch.toString(), "0");
      assert.strictEqual(listing.termEpochs, 0);
    });

    it("cannot be drained by the seller signing the escrow directly", async () => {
      const listed = await listNft(SALE, new BN(500).mul(UNIT), new BN(0), 0);

      // The seller still holds the key that used to own the NFT, but the escrow's
      // owner is now the Listing PDA. This is the exit that must not exist.
      const stealAsSeller = new Transaction().add(
        createTransferCheckedInstruction(
          listed.escrow,
          listed.mint,
          listed.ata,
          seller.publicKey,
          1,
          0,
        ),
      );
      await rejects(provider.sendAndConfirm!(stealAsSeller, [seller]));

      // Nor by anyone else claiming to be the listing.
      const stealAsOutsider = new Transaction().add(
        createTransferCheckedInstruction(
          listed.escrow,
          listed.mint,
          outsiderXnft,
          outsider.publicKey,
          1,
          0,
        ),
      );
      await rejects(provider.sendAndConfirm!(stealAsOutsider, [outsider]));

      assert.strictEqual(await balance(listed.escrow), 1n);
    });

    it("refuses a cancel from anyone but the seller", async () => {
      const listed = await listNft(SALE, new BN(500).mul(UNIT), new BN(0), 0);
      await rejects(
        program.methods
          .cancelListing()
          .accountsPartial({
            seller: outsider.publicKey,
            config: configPda,
            nftMint: listed.mint,
            listing: listed.listing,
            escrow: listed.escrow,
            sellerNft: listed.ata,
            tokenProgram: TOKEN_PROGRAM_ID,
          })
          .signers([outsider])
          .rpc(),
        "WrongSeller",
      );
      assert.strictEqual(await balance(listed.escrow), 1n);
    });

    it("returns the xployee and closes both accounts on cancel", async () => {
      const listed = await listNft(SALE, new BN(500).mul(UNIT), new BN(0), 0);

      await program.methods
        .cancelListing()
        .accountsPartial({
          seller: seller.publicKey,
          config: configPda,
          nftMint: listed.mint,
          listing: listed.listing,
          escrow: listed.escrow,
          sellerNft: listed.ata,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([seller])
        .rpc();

      assert.strictEqual(await balance(listed.ata), 1n);
      assert.isNull(await connection.getAccountInfo(listed.escrow));
      assert.isNull(await connection.getAccountInfo(listed.listing));
    });

    it("rejects a sale listing priced at zero", async () => {
      const { mint, ata } = await mintNft(seller);
      await rejects(
        program.methods
          .list(SALE as any, new BN(0), new BN(0), 0)
          .accountsPartial({
            seller: seller.publicKey,
            config: configPda,
            nftMint: mint,
            sellerNft: ata,
            listing: listingPda(mint),
            escrow: escrowPda(mint),
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([seller])
          .rpc(),
        "InvalidPrice",
      );
    });

    it("rejects a rental listing with a zero term", async () => {
      const { mint, ata } = await mintNft(seller);
      await rejects(
        program.methods
          .list(RENT as any, new BN(0), new BN(10).mul(UNIT), 0)
          .accountsPartial({
            seller: seller.publicKey,
            config: configPda,
            nftMint: mint,
            sellerNft: ata,
            listing: listingPda(mint),
            escrow: escrowPda(mint),
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([seller])
          .rpc(),
        "InvalidRentalTerms",
      );
    });

    it("refuses a zero-decimal mint whose supply is not one", async () => {
      // The brick: the escrow is a bare PDA token account, so anyone can push a
      // second unit into it, after which `buy` and `cancel_listing` both revert
      // on `close_account` and the asset is stuck in a PDA nobody can sign for.
      // `decimals == 0` alone does not rule this out — it only says the token is
      // indivisible, not that there is one of it.
      const { mint, ata } = await mintFungible(seller, 5, true);
      await rejects(
        program.methods
          .list(SALE as any, new BN(100).mul(UNIT), new BN(0), 0)
          .accountsPartial({
            seller: seller.publicKey,
            config: configPda,
            nftMint: mint,
            sellerNft: ata,
            listing: listingPda(mint),
            escrow: escrowPda(mint),
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([seller])
          .rpc(),
        "NotAnNft",
      );
    });

    it("refuses a supply-one mint that still has a live mint authority", async () => {
      // Supply is one *today*. With the mint authority alive that is a snapshot,
      // not a guarantee: the authority can mint a second unit after listing and
      // push it into escrow, which is the same brick by a slower route.
      const { mint, ata } = await mintFungible(seller, 1, false);
      await rejects(
        program.methods
          .list(SALE as any, new BN(100).mul(UNIT), new BN(0), 0)
          .accountsPartial({
            seller: seller.publicKey,
            config: configPda,
            nftMint: mint,
            sellerNft: ata,
            listing: listingPda(mint),
            escrow: escrowPda(mint),
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([seller])
          .rpc(),
        "NotAnNft",
      );
    });

    it("refuses to escrow the settlement mint as if it were an xployee", async () => {
      await rejects(
        program.methods
          .list(SALE as any, new BN(1).mul(UNIT), new BN(0), 0)
          .accountsPartial({
            seller: seller.publicKey,
            config: configPda,
            nftMint: xnftMint,
            sellerNft: sellerXnft,
            listing: listingPda(xnftMint),
            escrow: escrowPda(xnftMint),
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([seller])
          .rpc(),
        // $xNFT has six decimals, so it fails the non-fungibility check first.
        "NotAnNft",
      );
    });
  });

  // -------------------------------------------------------------------------
  describe("buy — invariant 6, the seller receives exactly price", () => {
    it("pays the seller the price and the treasury the fee, then closes up", async () => {
      const price = new BN(2_000).mul(UNIT);
      const fee = feeOf(price, TRADE_FEE_BPS);
      const listed = await listNft(SALE, price, new BN(0), 0);

      const buyerBefore = await balance(buyerXnft);
      const sellerBefore = await balance(sellerXnft);
      const treasuryBefore = await balance(treasuryPda);

      const signature = await program.methods
        .buy(totalOf(price, TRADE_FEE_BPS))
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .signers([buyer])
        .rpc();

      // The seller is made whole at exactly the listed price — the fee is a
      // separate debit on the buyer, never a haircut on the proceeds.
      assert.strictEqual(await balance(sellerXnft), sellerBefore + big(price));
      assert.strictEqual(await balance(treasuryPda), treasuryBefore + big(fee));
      assert.strictEqual(await balance(buyerXnft), buyerBefore - big(price) - big(fee));

      const buyerNft = getAssociatedTokenAddressSync(listed.mint, buyer.publicKey);
      assert.strictEqual(await balance(buyerNft), 1n);
      assert.isNull(await connection.getAccountInfo(listed.escrow));
      assert.isNull(await connection.getAccountInfo(listed.listing));

      const event = eventNamed(await eventsOf(signature), "TradeEvent");
      assert.strictEqual(event.gross.toString(), price.toString());
      assert.strictEqual(event.fee.toString(), fee.toString());
      assert.strictEqual(event.totalPaid.toString(), price.add(fee).toString());
      assert.isTrue(event.nftMint.equals(listed.mint));

      // `net_to_seller` is measured from the seller's balance between the two
      // payment legs, not restated from the same local as `gross`. It agreeing
      // with `gross` is therefore an assertion the index can make rather than a
      // tautology — and the on-chain delta below is what it is measuring.
      assert.strictEqual(event.netToSeller.toString(), price.toString());
      assert.strictEqual(
        big(event.netToSeller),
        (await balance(sellerXnft)) - sellerBefore,
      );
    });

    it("rejects a total above the buyer's signed maximum", async () => {
      const price = new BN(2_000).mul(UNIT);
      const listed = await listNft(SALE, price, new BN(0), 0);
      const treasuryBefore = await balance(treasuryPda);

      await rejects(
        program.methods
          .buy(totalOf(price, TRADE_FEE_BPS).subn(1))
          .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
          .signers([buyer])
          .rpc(),
        "SlippageExceeded",
      );
      assert.strictEqual(await balance(treasuryPda), treasuryBefore);
      assert.strictEqual(await balance(listed.escrow), 1n);

      // The same buy at the honest quote goes through, so the rejection above was
      // about the ceiling and not about anything else being wrong.
      await program.methods
        .buy(totalOf(price, TRADE_FEE_BPS))
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .signers([buyer])
        .rpc();
    });

    it("refuses a fee the buyer never agreed to, raised after they quoted", async () => {
      // The attack `max_total` exists for: the buyer sees 5%, signs, and the
      // authority raises the rate to 20% before the transaction lands. The cap on
      // MAX_FEE_BPS bounds how bad that can get; it does not make it consented to.
      const price = new BN(2_000).mul(UNIT);
      const listed = await listNft(SALE, price, new BN(0), 0);
      const quotedTotal = totalOf(price, TRADE_FEE_BPS);

      await program.methods
        .setConfig(MAX_FEE_BPS, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();

      const buyerBefore = await balance(buyerXnft);
      await rejects(
        program.methods
          .buy(quotedTotal)
          .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
          .signers([buyer])
          .rpc(),
        "SlippageExceeded",
      );
      assert.strictEqual(await balance(buyerXnft), buyerBefore);

      await program.methods
        .setConfig(TRADE_FEE_BPS, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();

      await program.methods
        .buy(quotedTotal)
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .signers([buyer])
        .rpc();
      assert.strictEqual(await balance(buyerXnft), buyerBefore - big(quotedTotal));
    });

    it("rejects a buyer holding the price but not the fee", async () => {
      const price = new BN(2_000).mul(UNIT);
      const listed = await listNft(SALE, price, new BN(0), 0);

      const poor = Keypair.generate();
      await fund(poor.publicKey);
      const poorAta = await createAssociatedTokenAccount(
        connection,
        payer,
        xnftMint,
        poor.publicKey,
      );
      await mintTo(connection, payer, xnftMint, poorAta, payer, big(price));

      const sellerBefore = await balance(sellerXnft);
      const treasuryBefore = await balance(treasuryPda);

      await rejects(
        program.methods
          .buy(totalOf(price, TRADE_FEE_BPS))
          .accountsPartial(buyAccounts(listed.mint, poor, poorAta))
          .signers([poor])
          .rpc(),
        "InsufficientFunds",
      );

      assert.strictEqual(await balance(poorAta), big(price));
      assert.strictEqual(await balance(sellerXnft), sellerBefore);
      assert.strictEqual(await balance(treasuryPda), treasuryBefore);
      assert.strictEqual(await balance(listed.escrow), 1n);
    });

    it("unwinds every leg when a later instruction in the same transaction fails", async () => {
      const price = new BN(3_000).mul(UNIT);
      const listed = await listNft(SALE, price, new BN(0), 0);

      const buyerBefore = await balance(buyerXnft);
      const sellerBefore = await balance(sellerXnft);
      const treasuryBefore = await balance(treasuryPda);

      const buyIx = await program.methods
        .buy(totalOf(price, TRADE_FEE_BPS))
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .instruction();

      // A second instruction that cannot succeed after the buy has debited the
      // buyer. If any leg of `buy` were able to settle independently, this is
      // where a partial state would show up.
      const doomed = createTransferCheckedInstruction(
        buyerXnft,
        xnftMint,
        outsiderXnft,
        buyer.publicKey,
        buyerBefore,
        DECIMALS,
      );

      await rejects(
        provider.sendAndConfirm!(new Transaction().add(buyIx, doomed), [buyer]),
      );

      assert.strictEqual(await balance(buyerXnft), buyerBefore);
      assert.strictEqual(await balance(sellerXnft), sellerBefore);
      assert.strictEqual(await balance(treasuryPda), treasuryBefore);
      assert.strictEqual(await balance(listed.escrow), 1n);
      assert.isNotNull(await connection.getAccountInfo(listed.listing));
    });

    it("refuses to buy a rental listing", async () => {
      const listed = await listNft(RENT, new BN(0), new BN(50).mul(UNIT), 4);
      await rejects(
        program.methods
          .buy(new BN(1_000_000).mul(UNIT))
          .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
          .signers([buyer])
          .rpc(),
        "NotForSale",
      );
    });

    it("refuses a seller substitution", async () => {
      const price = new BN(400).mul(UNIT);
      const listed = await listNft(SALE, price, new BN(0), 0);
      const accounts = buyAccounts(listed.mint, buyer, buyerXnft);
      await rejects(
        program.methods
          .buy(totalOf(price, TRADE_FEE_BPS))
          .accountsPartial({
            ...accounts,
            seller: outsider.publicKey,
            sellerToken: outsiderXnft,
          })
          .signers([buyer])
          .rpc(),
        "WrongSeller",
      );
    });
  });

  // -------------------------------------------------------------------------
  describe("fee arithmetic — boundaries and rounding direction", () => {
    it("rounds a sub-unit fee UP, out of the buyer's side, never the seller's", async () => {
      // 19 * 500 / 10_000 = 0.95 -> 1. The direction is the deliberate half of
      // invariant 6: the two halves of the original wording — treasury never
      // short, buyer never over-charged — cannot both hold, and the payer is the
      // side that absorbs the remainder. Flooring instead would make every trade
      // under 20 raw units pay literally nothing.
      const price = new BN(19);
      const listed = await listNft(SALE, price, new BN(0), 0);

      const buyerBefore = await balance(buyerXnft);
      const sellerBefore = await balance(sellerXnft);
      const treasuryBefore = await balance(treasuryPda);

      await program.methods
        .buy(new BN(20))
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .signers([buyer])
        .rpc();

      // The seller is still made whole at exactly the listed price.
      assert.strictEqual(await balance(sellerXnft), sellerBefore + 19n);
      assert.strictEqual(await balance(treasuryPda), treasuryBefore + 1n);
      assert.strictEqual(await balance(buyerXnft), buyerBefore - 20n);
    });

    it("charges exactly one raw unit where the division comes out even", async () => {
      // 20 * 500 / 10_000 = 1.0 exactly, so there is no rounding to do and the
      // direction cannot hide a bug here.
      const listed = await listNft(SALE, new BN(20), new BN(0), 0);

      const buyerBefore = await balance(buyerXnft);
      const sellerBefore = await balance(sellerXnft);
      const treasuryBefore = await balance(treasuryPda);

      await program.methods
        .buy(new BN(21))
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .signers([buyer])
        .rpc();

      assert.strictEqual(await balance(sellerXnft), sellerBefore + 20n);
      assert.strictEqual(await balance(treasuryPda), treasuryBefore + 1n);
      assert.strictEqual(await balance(buyerXnft), buyerBefore - 21n);
    });

    it("rounds up again just below the next whole unit", async () => {
      // 39 * 500 / 10_000 = 1.95 -> 2, not 1.
      const listed = await listNft(SALE, new BN(39), new BN(0), 0);

      const buyerBefore = await balance(buyerXnft);
      const sellerBefore = await balance(sellerXnft);
      const treasuryBefore = await balance(treasuryPda);

      await program.methods
        .buy(new BN(41))
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .signers([buyer])
        .rpc();

      assert.strictEqual(await balance(sellerXnft), sellerBefore + 39n);
      assert.strictEqual(await balance(treasuryPda), treasuryBefore + 2n);
      assert.strictEqual(await balance(buyerXnft), buyerBefore - 41n);
    });

    it("charges the smallest possible trade something rather than nothing", async () => {
      // 1 * 500 / 10_000 = 0.05 -> 1. Under the old floor this paid zero, which
      // is the fee-free path rounding down leaves behind.
      const listed = await listNft(SALE, new BN(1), new BN(0), 0);
      const treasuryBefore = await balance(treasuryPda);

      await program.methods
        .buy(new BN(2))
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .signers([buyer])
        .rpc();

      assert.strictEqual(await balance(treasuryPda), treasuryBefore + 1n);
    });

    it("charges nothing at a zero fee rate", async () => {
      await program.methods
        .setConfig(0, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();

      const price = new BN(777).mul(UNIT);
      const listed = await listNft(SALE, price, new BN(0), 0);
      const treasuryBefore = await balance(treasuryPda);
      const sellerBefore = await balance(sellerXnft);

      // Ceiling division of an exact zero is still zero: "no fee configured"
      // must not round up to one raw unit per trade.
      await program.methods
        .buy(price)
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .signers([buyer])
        .rpc();

      assert.strictEqual(await balance(treasuryPda), treasuryBefore);
      assert.strictEqual(await balance(sellerXnft), sellerBefore + big(price));

      await program.methods
        .setConfig(TRADE_FEE_BPS, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
    });

    it("charges exactly 20% at the ceiling rate", async () => {
      await program.methods
        .setConfig(MAX_FEE_BPS, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();

      const price = new BN(1_000).mul(UNIT);
      const listed = await listNft(SALE, price, new BN(0), 0);
      const treasuryBefore = await balance(treasuryPda);
      const sellerBefore = await balance(sellerXnft);

      await program.methods
        .buy(totalOf(price, MAX_FEE_BPS))
        .accountsPartial(buyAccounts(listed.mint, buyer, buyerXnft))
        .signers([buyer])
        .rpc();

      assert.strictEqual(await balance(treasuryPda), treasuryBefore + big(price.divn(5)));
      assert.strictEqual(await balance(sellerXnft), sellerBefore + big(price));

      await program.methods
        .setConfig(TRADE_FEE_BPS, null, null, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
    });
  });

  // -------------------------------------------------------------------------
  describe("rent — 10%, and the xployee never moves", () => {
    let rental: { mint: PublicKey; ata: PublicKey; listing: PublicKey; escrow: PublicKey };
    const feePerEpoch = new BN(100).mul(UNIT);
    const term = 6;
    const gross = feePerEpoch.muln(term);
    const fee = feeOf(gross, RENT_FEE_BPS);
    const rentTotal = gross.add(fee);

    before(async () => {
      rental = await listNft(RENT, new BN(0), feePerEpoch, term);
    });

    function rentAccounts(renterKp: Keypair, renterPayment: PublicKey) {
      return {
        renter: renterKp.publicKey,
        xnftMint,
        config: configPda,
        nftMint: rental.mint,
        listing: rental.listing,
        ownerToken: sellerXnft,
        renterToken: renterPayment,
        treasury: treasuryPda,
        contract: contractPda(rental.mint, renterKp.publicKey),
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      };
    }

    it("pays the owner the gross and the treasury 10% on top", async () => {
      const renterBefore = await balance(renterXnft);
      const ownerBefore = await balance(sellerXnft);
      const treasuryBefore = await balance(treasuryPda);

      const signature = await program.methods
        .rent(rentTotal)
        .accountsPartial(rentAccounts(renter, renterXnft))
        .signers([renter])
        .rpc();

      assert.strictEqual(await balance(sellerXnft), ownerBefore + big(gross));
      assert.strictEqual(await balance(treasuryPda), treasuryBefore + big(fee));
      assert.strictEqual(await balance(renterXnft), renterBefore - big(gross) - big(fee));

      // Invariant: renting does not move the asset. It stays in escrow and the
      // listing stays open.
      assert.strictEqual(await balance(rental.escrow), 1n);
      assert.isNotNull(await connection.getAccountInfo(rental.listing));

      const event = eventNamed(await eventsOf(signature), "RentEvent");
      assert.strictEqual(event.gross.toString(), gross.toString());
      assert.strictEqual(event.fee.toString(), fee.toString());
      assert.strictEqual(event.totalPaid.toString(), gross.add(fee).toString());
      assert.strictEqual(event.termEpochs, term);
      assert.strictEqual(event.feeBps, RENT_FEE_BPS);
    });

    it("records the contract with the listing's term, not the caller's", async () => {
      const contract = await program.account.contract.fetch(
        contractPda(rental.mint, renter.publicKey),
      );
      assert.isTrue(contract.owner.equals(seller.publicKey));
      assert.isTrue(contract.renter.equals(renter.publicKey));
      assert.strictEqual(contract.termEpochs, term);
      assert.strictEqual(contract.feePerEpoch.toString(), feePerEpoch.toString());
      assert.strictEqual(contract.totalPaid.toString(), gross.add(fee).toString());
      assert.strictEqual(contract.feePaid.toString(), fee.toString());
      assert.strictEqual(
        contract.endEpoch.sub(contract.startEpoch).toString(),
        term.toString(),
      );
    });

    it("records the term on the listing, which is what makes it exclusive", async () => {
      const listing = await program.account.listing.fetch(rental.listing);
      const contract = await program.account.contract.fetch(
        contractPda(rental.mint, renter.publicKey),
      );
      assert.strictEqual(
        listing.rentedUntilEpoch.toString(),
        contract.endEpoch.toString(),
      );
    });

    it("refuses a second live contract from the same renter", async () => {
      await rejects(
        program.methods
          .rent(rentTotal)
          .accountsPartial(rentAccounts(renter, renterXnft))
          .signers([renter])
          .rpc(),
      );
    });

    it("refuses a SECOND RENTER for a term already sold", async () => {
      // The defect: the Contract PDA is seeded by (nft_mint, renter), so the
      // renter seed only stops a renter colliding with themselves. Nothing
      // stopped fifty different wallets each paying in full for the same six
      // epochs of the same asset, and every one of them would be entitled to it.
      const ownerBefore = await balance(sellerXnft);
      const renter2Before = await balance(renter2Xnft);

      await rejects(
        program.methods
          .rent(rentTotal)
          .accountsPartial(rentAccounts(renter2, renter2Xnft))
          .signers([renter2])
          .rpc(),
        "RentalActive",
      );

      // And not a single unit changed hands on the way to that rejection.
      assert.strictEqual(await balance(sellerXnft), ownerBefore);
      assert.strictEqual(await balance(renter2Xnft), renter2Before);
      assert.isNull(
        await connection.getAccountInfo(contractPda(rental.mint, renter2.publicKey)),
      );
    });

    it("refuses to let the owner withdraw the asset out from under a live rental", async () => {
      // The defect: the seller could take a full term's rent and cancel in the
      // very next transaction, leaving a Contract that no instruction could
      // refund and no instruction could terminate. The renter's money would
      // simply be gone.
      await rejects(
        program.methods
          .cancelListing()
          .accountsPartial({
            seller: seller.publicKey,
            config: configPda,
            nftMint: rental.mint,
            listing: rental.listing,
            escrow: rental.escrow,
            sellerNft: rental.ata,
            tokenProgram: TOKEN_PROGRAM_ID,
          })
          .signers([seller])
          .rpc(),
        "RentalActive",
      );
      assert.strictEqual(await balance(rental.escrow), 1n);
    });

    it("refuses to close a contract before its term ends", async () => {
      await rejects(
        program.methods
          .closeContract()
          .accountsPartial({
            renter: renter.publicKey,
            nftMint: rental.mint,
            contract: contractPda(rental.mint, renter.publicKey),
          })
          .rpc(),
        "ContractNotExpired",
      );
    });

    it("rejects a total above the renter's signed maximum", async () => {
      const fresh = await listNft(RENT, new BN(0), feePerEpoch, term);
      await rejects(
        program.methods
          .rent(rentTotal.subn(1))
          .accountsPartial({
            renter: renter2.publicKey,
            xnftMint,
            config: configPda,
            nftMint: fresh.mint,
            listing: fresh.listing,
            ownerToken: sellerXnft,
            renterToken: renter2Xnft,
            treasury: treasuryPda,
            contract: contractPda(fresh.mint, renter2.publicKey),
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([renter2])
          .rpc(),
        "SlippageExceeded",
      );
      // The listing is left free, not half-rented, so the next renter is not
      // locked out by a payment that never happened.
      assert.strictEqual(
        (await program.account.listing.fetch(fresh.listing)).rentedUntilEpoch.toString(),
        "0",
      );
    });

    it("refuses to pay a substituted owner", async () => {
      await rejects(
        program.methods
          .rent(rentTotal)
          .accountsPartial({
            ...rentAccounts(outsider, outsiderXnft),
            ownerToken: outsiderXnft,
          })
          .signers([outsider])
          .rpc(),
        "WrongSeller",
      );
    });

    it("refuses to rent a sale listing", async () => {
      const forSale = await listNft(SALE, new BN(100).mul(UNIT), new BN(0), 0);
      await rejects(
        program.methods
          .rent(rentTotal)
          .accountsPartial({
            renter: renter.publicKey,
            xnftMint,
            config: configPda,
            nftMint: forSale.mint,
            listing: forSale.listing,
            ownerToken: sellerXnft,
            renterToken: renterXnft,
            treasury: treasuryPda,
            contract: contractPda(forSale.mint, renter.publicKey),
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([renter])
          .rpc(),
        "NotForRent",
      );
    });
  });

  // -------------------------------------------------------------------------
  // The whole rental life cycle, which needs the clock to actually move. The
  // validator is pinned to 32 slots per epoch in Anchor.toml so this is a wait
  // of seconds rather than of days.
  // -------------------------------------------------------------------------
  describe("close_contract — a rental expires, and everything it blocked unblocks", () => {
    const feePerEpoch = new BN(10).mul(UNIT);
    const term = 1;
    const gross = feePerEpoch.muln(term);
    const total = gross.add(feeOf(gross, RENT_FEE_BPS));

    let expiring!: { mint: PublicKey; ata: PublicKey; listing: PublicKey; escrow: PublicKey };
    let contract!: PublicKey;
    let endEpoch!: number;

    function rentAccounts(renterKp: Keypair, renterPayment: PublicKey) {
      return {
        renter: renterKp.publicKey,
        xnftMint,
        config: configPda,
        nftMint: expiring.mint,
        listing: expiring.listing,
        ownerToken: sellerXnft,
        renterToken: renterPayment,
        treasury: treasuryPda,
        contract: contractPda(expiring.mint, renterKp.publicKey),
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      };
    }

    before(async () => {
      expiring = await listNft(RENT, new BN(0), feePerEpoch, term);
      await program.methods
        .rent(total)
        .accountsPartial(rentAccounts(renter3, renter3Xnft))
        .signers([renter3])
        .rpc();
      contract = contractPda(expiring.mint, renter3.publicKey);
      endEpoch = Number(
        (await program.account.contract.fetch(contract)).endEpoch.toString(),
      );
    });

    it("returns the renter's rent-exempt lamports when the term is over", async () => {
      // Without this path the Contract account is permanent: seeded by
      // (nft_mint, renter) and created with `init`, so a wallet could rent a
      // given xployee exactly once for the life of the program, and the lamports
      // it paid to open the account would be locked in it forever.
      await waitForEpoch(endEpoch);

      const renterLamportsBefore = await connection.getBalance(renter3.publicKey);
      const contractLamports = (await connection.getAccountInfo(contract))!.lamports;

      // No signer at all: closing an expired contract only returns the renter's
      // own money to the renter and frees the seed. Requiring the renter to sign
      // would let an abandoned contract block that pair forever, which is the
      // exact failure this removes.
      await program.methods
        .closeContract()
        .accountsPartial({
          renter: renter3.publicKey,
          nftMint: expiring.mint,
          contract,
        })
        .rpc();

      assert.isNull(await connection.getAccountInfo(contract));
      assert.strictEqual(
        await connection.getBalance(renter3.publicKey),
        renterLamportsBefore + contractLamports,
      );
    });

    it("lets the same renter rent the same xployee again afterwards", async () => {
      // The other half of the same defect: the (mint, renter) seed made a repeat
      // rental impossible, not merely awkward.
      await program.methods
        .rent(total)
        .accountsPartial(rentAccounts(renter3, renter3Xnft))
        .signers([renter3])
        .rpc();
      assert.isNotNull(await connection.getAccountInfo(contract));
    });

    it("lets the owner cancel once the term has run out", async () => {
      const later = Number(
        (await program.account.contract.fetch(contract)).endEpoch.toString(),
      );
      await waitForEpoch(later);

      await program.methods
        .cancelListing()
        .accountsPartial({
          seller: seller.publicKey,
          config: configPda,
          nftMint: expiring.mint,
          listing: expiring.listing,
          escrow: expiring.escrow,
          sellerNft: expiring.ata,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([seller])
        .rpc();

      assert.strictEqual(await balance(expiring.ata), 1n);
      assert.isNull(await connection.getAccountInfo(expiring.listing));

      // The expired contract outlives the listing and is still closeable, so the
      // renter's lamports do not depend on the seller leaving the listing up.
      await program.methods
        .closeContract()
        .accountsPartial({
          renter: renter3.publicKey,
          nftMint: expiring.mint,
          contract,
        })
        .rpc();
      assert.isNull(await connection.getAccountInfo(contract));
    });

    it("refuses to close another renter's contract into your own pocket", async () => {
      // `has_one = renter` pins the refund destination to the wallet that paid.
      const fresh = await listNft(RENT, new BN(0), feePerEpoch, term);
      await program.methods
        .rent(total)
        .accountsPartial({
          renter: renter2.publicKey,
          xnftMint,
          config: configPda,
          nftMint: fresh.mint,
          listing: fresh.listing,
          ownerToken: sellerXnft,
          renterToken: renter2Xnft,
          treasury: treasuryPda,
          contract: contractPda(fresh.mint, renter2.publicKey),
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([renter2])
        .rpc();

      await rejects(
        program.methods
          .closeContract()
          .accountsPartial({
            renter: outsider.publicKey,
            nftMint: fresh.mint,
            contract: contractPda(fresh.mint, renter2.publicKey),
          })
          .rpc(),
      );
    });
  });

  // -------------------------------------------------------------------------
  describe("claim_fees — invariant 1, the destination is not a parameter", () => {
    const devAta = () => getAssociatedTokenAddressSync(xnftMint, devWallet.publicKey);

    function claimAccounts() {
      return {
        authority: authority.publicKey,
        xnftMint,
        config: configPda,
        devWallet: devWallet.publicKey,
        devWalletToken: devAta(),
        treasury: treasuryPda,
        tokenProgram: TOKEN_PROGRAM_ID,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      };
    }

    it("rejects a non-authority signer", async () => {
      await rejects(
        program.methods
          .claimFees(new BN(1))
          .accountsPartial({ ...claimAccounts(), authority: outsider.publicKey })
          .signers([outsider])
          .rpc(),
        "ConstraintHasOne",
      );
    });

    it("rejects a destination that is not config.dev_wallet", async () => {
      // The authority is genuine here. The only thing wrong is where the money
      // would land — which is the whole reason the destination is pinned.
      await rejects(
        program.methods
          .claimFees(new BN(1))
          .accountsPartial({
            ...claimAccounts(),
            devWallet: outsider.publicKey,
            devWalletToken: outsiderXnft,
          })
          .rpc(),
        "WrongPayoutDestination",
      );
    });

    it("rejects a token account that is not the dev wallet's ATA", async () => {
      // Right wallet in the dev_wallet slot, wrong token account beside it.
      await rejects(
        program.methods
          .claimFees(new BN(1))
          .accountsPartial({ ...claimAccounts(), devWalletToken: outsiderXnft })
          .rpc(),
      );
    });

    it("rejects a claim of zero", async () => {
      await rejects(
        program.methods.claimFees(new BN(0)).accountsPartial(claimAccounts()).rpc(),
        "ZeroAmount",
      );
    });

    it("rejects a claim larger than the treasury balance", async () => {
      const treasury = await balance(treasuryPda);
      await rejects(
        program.methods
          .claimFees(new BN((treasury + 1n).toString()))
          .accountsPartial(claimAccounts())
          .rpc(),
        "InsufficientTreasury",
      );
    });

    it("pays the dev wallet, opening its token account on the first claim", async () => {
      const treasuryBefore = await balance(treasuryPda);
      assert.isTrue(treasuryBefore > 0n, "expected fees to have accrued by now");
      const amount = new BN((treasuryBefore / 2n).toString());

      assert.isNull(await connection.getAccountInfo(devAta()));

      const signature = await program.methods
        .claimFees(amount)
        .accountsPartial(claimAccounts())
        .rpc();

      assert.strictEqual(await balance(devAta()), big(amount));
      assert.strictEqual(await balance(treasuryPda), treasuryBefore - big(amount));

      const event = eventNamed(await eventsOf(signature), "PayoutEvent");
      assert.isTrue(event.destination.equals(devWallet.publicKey));
      assert.strictEqual(event.amount.toString(), amount.toString());
      assert.strictEqual(
        event.treasuryRemaining.toString(),
        (treasuryBefore - big(amount)).toString(),
      );

      const config = await program.account.config.fetch(configPda);
      assert.strictEqual(config.totalClaimed.toString(), amount.toString());
    });

    it("drains to exactly zero when the whole balance is claimed", async () => {
      const remaining = await balance(treasuryPda);
      await program.methods
        .claimFees(new BN(remaining.toString()))
        .accountsPartial(claimAccounts())
        .rpc();
      assert.strictEqual(await balance(treasuryPda), 0n);
    });

    it("follows the dev wallet after set_config moves it", async () => {
      const newDev = Keypair.generate();
      await program.methods
        .setConfig(null, null, newDev.publicKey, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();

      // The old destination is now the wrong one, with no code change anywhere.
      await rejects(
        program.methods.claimFees(new BN(1)).accountsPartial(claimAccounts()).rpc(),
        "WrongPayoutDestination",
      );

      await program.methods
        .setConfig(null, null, devWallet.publicKey, null)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
    });
  });

  // -------------------------------------------------------------------------
  describe("authority rotation — two steps, so a typo is not terminal", () => {
    const heir = Keypair.generate();

    before(async () => {
      await fund(heir.publicKey);
    });

    it("refuses a proposal from anyone but the current authority", async () => {
      await rejects(
        program.methods
          .proposeAuthority(outsider.publicKey)
          .accountsPartial({ authority: outsider.publicKey, config: configPda })
          .signers([outsider])
          .rpc(),
        "ConstraintHasOne",
      );
    });

    it("refuses an accept when nothing has been proposed", async () => {
      // The default pubkey sits in `pending_authority` when no rotation is in
      // flight, and nobody can sign for it — but the check does not rely on that
      // being true.
      await rejects(
        program.methods
          .acceptAuthority()
          .accountsPartial({ pendingAuthority: outsider.publicKey, config: configPda })
          .signers([outsider])
          .rpc(),
        "NoPendingAuthority",
      );
    });

    it("changes nothing on propose alone", async () => {
      // The whole reason for two steps: a mistyped pubkey in step one is inert.
      // A one-step rotation would hand the treasury, the fee rates and the pause
      // flag to an address nobody holds, irreversibly, in a single transaction.
      const typo = Keypair.generate().publicKey;
      await program.methods
        .proposeAuthority(typo)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();

      const config = await program.account.config.fetch(configPda);
      assert.isTrue(config.authority.equals(authority.publicKey));
      assert.isTrue(config.pendingAuthority.equals(typo));

      // And the current authority still works, so nothing was surrendered.
      await program.methods
        .setConfig(null, null, null, false)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
    });

    it("lets the current authority cancel a proposal", async () => {
      await program.methods
        .proposeAuthority(PublicKey.default)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
      assert.isTrue(
        (await program.account.config.fetch(configPda)).pendingAuthority.equals(
          PublicKey.default,
        ),
      );
    });

    it("refuses an accept from a key that was not the one proposed", async () => {
      await program.methods
        .proposeAuthority(heir.publicKey)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();

      await rejects(
        program.methods
          .acceptAuthority()
          .accountsPartial({ pendingAuthority: outsider.publicKey, config: configPda })
          .signers([outsider])
          .rpc(),
        "NoPendingAuthority",
      );
    });

    it("hands over on accept, and the old key stops working", async () => {
      await program.methods
        .acceptAuthority()
        .accountsPartial({ pendingAuthority: heir.publicKey, config: configPda })
        .signers([heir])
        .rpc();

      const config = await program.account.config.fetch(configPda);
      assert.isTrue(config.authority.equals(heir.publicKey));
      // Cleared, so the same proposal cannot be replayed to seize the authority
      // back after a later, legitimate rotation.
      assert.isTrue(config.pendingAuthority.equals(PublicKey.default));

      await rejects(
        program.methods
          .setConfig(null, null, null, true)
          .accountsPartial({ authority: authority.publicKey, config: configPda })
          .rpc(),
        "ConstraintHasOne",
      );

      // The recovery this exists for: the new key controls the treasury.
      await rejects(
        program.methods
          .claimFees(new BN(1))
          .accountsPartial({
            authority: authority.publicKey,
            xnftMint,
            config: configPda,
            devWallet: devWallet.publicKey,
            devWalletToken: getAssociatedTokenAddressSync(xnftMint, devWallet.publicKey),
            treasury: treasuryPda,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc(),
        "ConstraintHasOne",
      );
    });

    it("rotates back, proving the move is not one-way", async () => {
      await program.methods
        .proposeAuthority(authority.publicKey)
        .accountsPartial({ authority: heir.publicKey, config: configPda })
        .signers([heir])
        .rpc();

      await program.methods
        .acceptAuthority()
        .accountsPartial({ pendingAuthority: authority.publicKey, config: configPda })
        .rpc();

      assert.isTrue(
        (await program.account.config.fetch(configPda)).authority.equals(
          authority.publicKey,
        ),
      );

      await program.methods
        .setConfig(null, null, null, false)
        .accountsPartial({ authority: authority.publicKey, config: configPda })
        .rpc();
    });
  });
});
