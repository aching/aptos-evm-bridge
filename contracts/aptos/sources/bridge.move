/// Bridge — Maroo -> Aptos mint attestation and Aptos -> Maroo burn rail.
///
/// Demo trust model: a single trusted relayer signer attests Maroo deposits
/// (nonce + amount + recipient) and calls `mint_attested`. The return path
/// burns OKRW on Aptos and emits `WithdrawInitiated` for the relayer to
/// release funds from the Maroo vault.
///
/// Replay protection: (maroo_nonce) seen-set on the mint path, monotonic
/// withdraw nonce on the burn path. Daily mint cap bounds blast radius.
module okrw_bridge::bridge {
    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;
    use aptos_framework::timestamp;
    use aptos_std::table::{Self, Table};
    use okrw_bridge::okrw;
    use std::option;
    use std::signer;

    const EWRONG_RELAYER: u64 = 1;
    const EALREADY_ATTESTED: u64 = 2;
    const EZERO_AMOUNT: u64 = 3;
    const EDAILY_CAP_EXCEEDED: u64 = 4;
    const EPAUSED: u64 = 5;
    const EBAD_RECIPIENT: u64 = 6;
    const EWRONG_METADATA: u64 = 7;
    const ENOT_PENDING_RELAYER: u64 = 8;

    struct Config has key {
        relayer: address,
        /// The one OKRW metadata object this bridge may mint. Pinned at init
        /// so a compromised/mistaken relayer cannot mint a lookalike coin.
        metadata: Object<Metadata>,
        /// Two-step relayer rotation: current relayer proposes, the pending
        /// address claims (proving key ownership by signing the claim).
        pending_relayer: option::Option<address>,
        paused: bool,
        daily_mint_cap: u64,
        minted_today: u64,
        current_day: u64,
        next_withdraw_nonce: u64,
    }

    struct Seen has key {
        /// Maroo deposit nonces already attested. Table (not vector): O(1)
        /// lookup, no unbounded per-mint scan cost as volume grows.
        attested: Table<u64, bool>,
    }

    // ---------------------------------------------------------------- events
    #[event]
    struct MintAttested has drop, store {
        maroo_nonce: u64,
        recipient: address,
        amount: u64,
    }

    #[event]
    struct WithdrawInitiated has drop, store {
        withdraw_nonce: u64,
        from: address,
        maroo_recipient: vector<u8>,
        amount: u64,
    }

    #[event]
    struct BridgePaused has drop, store { by: address }

    #[event]
    struct BridgeUnpaused has drop, store { by: address }

    #[event]
    struct RelayerRotated has drop, store { old_relayer: address, new_relayer: address, by: address }

    #[event]
    struct DailyMintCapUpdated has drop, store { old_cap: u64, new_cap: u64, by: address }

    /// Initialize bridge config. Caller owns the Config/Seen resources and
    /// must BE the relayer (Config is looked up via the relayer signer, so
    /// init-by-`admin` only works if admin == relayer).
    public entry fun init(relayer: &signer, metadata: Object<Metadata>, daily_mint_cap: u64) {
        move_to(relayer, Config {
            relayer: signer::address_of(relayer),
            metadata,
            pending_relayer: option::none(),
            paused: false,
            daily_mint_cap,
            minted_today: 0,
            current_day: timestamp::now_seconds() / 86400,
            next_withdraw_nonce: 0,
        });
        move_to(relayer, Seen { attested: table::new() });
    }

    /// Mint OKRW against a Maroo deposit attestation. Only the relayer.
    public entry fun mint_attested(
        relayer: &signer,
        metadata: Object<Metadata>,
        recipient: address,
        amount: u64,
        maroo_nonce: u64,
    ) acquires Config, Seen {
        let bridge_addr = signer::address_of(relayer);
        let cfg = borrow_global_mut<Config>(bridge_addr);
        assert!(signer::address_of(relayer) == cfg.relayer, EWRONG_RELAYER);
        assert!(metadata == cfg.metadata, EWRONG_METADATA);
        assert!(!cfg.paused, EPAUSED);
        assert!(amount > 0, EZERO_AMOUNT);

        let seen = borrow_global_mut<Seen>(bridge_addr);
        assert!(!table::contains(&seen.attested, maroo_nonce), EALREADY_ATTESTED);
        table::add(&mut seen.attested, maroo_nonce, true);

        // Daily cap (UTC day windows).
        let day = timestamp::now_seconds() / 86400;
        if (day > cfg.current_day) {
            cfg.current_day = day;
            cfg.minted_today = 0;
        };
        assert!(cfg.minted_today + amount <= cfg.daily_mint_cap, EDAILY_CAP_EXCEEDED);
        cfg.minted_today = cfg.minted_today + amount;

        okrw::mint(relayer, metadata, recipient, amount);
        event::emit(MintAttested { maroo_nonce, recipient, amount });
    }

    /// Burn OKRW to initiate a withdraw to Maroo. Two-step demo flow:
    ///   1. user transfers OKRW to the bridge (relayer) account via a normal
    ///      FA transfer (subject to pause/denylist hooks);
    ///   2. the relayer calls this, burning the pre-deposited funds from its
    ///      own store and emitting `WithdrawInitiated`, then releases the
    ///      matching amount from the Maroo vault.
    /// `from` records the original depositor for the event trail.
    /// The Config address is derived from the relayer signer (canonical);
    /// no caller-supplied account address is trusted.
    public entry fun burn_withdraw(
        relayer: &signer,
        metadata: Object<Metadata>,
        from: address,
        amount: u64,
        maroo_recipient: vector<u8>,
    ) acquires Config {
        let bridge_addr = signer::address_of(relayer);
        assert!(bridge_addr == borrow_global<Config>(bridge_addr).relayer, EWRONG_RELAYER);
        assert!(metadata == borrow_global<Config>(bridge_addr).metadata, EWRONG_METADATA);
        assert!(amount > 0, EZERO_AMOUNT);
        assert!(maroo_recipient.length() == 20, EBAD_RECIPIENT); // Maroo EVM address
        let cfg = borrow_global_mut<Config>(bridge_addr);
        assert!(!cfg.paused, EPAUSED);
        let nonce = cfg.next_withdraw_nonce;
        cfg.next_withdraw_nonce = nonce + 1;

        okrw::bridge_burn(relayer, metadata, amount);
        event::emit(WithdrawInitiated { withdraw_nonce: nonce, from, maroo_recipient, amount });
    }

    public entry fun pause(relayer: &signer) acquires Config {
        let bridge_addr = signer::address_of(relayer);
        let cfg = borrow_global_mut<Config>(bridge_addr);
        assert!(signer::address_of(relayer) == cfg.relayer, EWRONG_RELAYER);
        cfg.paused = true;
        event::emit(BridgePaused { by: bridge_addr });
    }

    public entry fun unpause(relayer: &signer) acquires Config {
        let bridge_addr = signer::address_of(relayer);
        let cfg = borrow_global_mut<Config>(bridge_addr);
        assert!(signer::address_of(relayer) == cfg.relayer, EWRONG_RELAYER);
        cfg.paused = false;
        event::emit(BridgeUnpaused { by: bridge_addr });
    }

    /// Combined emergency pause in ONE tx: freezes the bridge (mint + burn
    /// attestation) AND the coin (transfers + direct mint/burn). Requires the
    /// relayer to also hold the coin pauser role (deploy-aptos.sh sets
    /// pauser=relayer for the demo; rotate with okrw::set_pauser if split).
    /// Recovery is deliberately two steps (bridge::unpause + okrw::unpause)
    /// so resuming is an explicit, reviewed action.
    public entry fun emergency_pause(relayer: &signer, metadata: Object<Metadata>) acquires Config {
        let bridge_addr = signer::address_of(relayer);
        let cfg = borrow_global_mut<Config>(bridge_addr);
        assert!(signer::address_of(relayer) == cfg.relayer, EWRONG_RELAYER);
        cfg.paused = true;
        event::emit(BridgePaused { by: bridge_addr });
        okrw::pause(relayer, metadata);
    }

    public entry fun set_daily_mint_cap(relayer: &signer, cap: u64) acquires Config {
        let bridge_addr = signer::address_of(relayer);
        let cfg = borrow_global_mut<Config>(bridge_addr);
        assert!(signer::address_of(relayer) == cfg.relayer, EWRONG_RELAYER);
        let old = cfg.daily_mint_cap;
        cfg.daily_mint_cap = cap;
        event::emit(DailyMintCapUpdated { old_cap: old, new_cap: cap, by: bridge_addr });
    }

    /// Rotate the relayer key (two-step, preserves replay history):
    ///   1. current relayer calls `propose_relayer(new)` — sets pending;
    ///   2. the NEW relayer key calls `claim_relayer(old_home)` — proves key
    ///      ownership by signing, moves Config+Seen (incl. attested nonces)
    ///      under its own account so no Maroo nonce can ever be re-minted.
    /// Either side can cancel by proposing the zero address (current) — the
    /// claim asserts pending == claimant, so a stale proposal is harmless.
    public entry fun propose_relayer(current: &signer, new_relayer: address) acquires Config {
        let home = signer::address_of(current);
        let cfg = borrow_global_mut<Config>(home);
        assert!(signer::address_of(current) == cfg.relayer, EWRONG_RELAYER);
        cfg.pending_relayer = option::some(new_relayer);
        event::emit(RelayerRotated { old_relayer: home, new_relayer, by: home });
    }

    public entry fun claim_relayer(new_relayer: &signer, old_home: address) acquires Config, Seen {
        let new_addr = signer::address_of(new_relayer);
        let pending = borrow_global<Config>(old_home).pending_relayer;
        assert!(option::is_some(&pending) && *option::borrow(&pending) == new_addr, ENOT_PENDING_RELAYER);
        let Config {
            relayer: _,
            metadata,
            pending_relayer: _,
            paused,
            daily_mint_cap,
            minted_today,
            current_day,
            next_withdraw_nonce,
        } = move_from<Config>(old_home);
        let Seen { attested } = move_from<Seen>(old_home);
        move_to(new_relayer, Config {
            relayer: new_addr,
            metadata,
            pending_relayer: option::none(),
            paused,
            daily_mint_cap,
            minted_today,
            current_day,
            next_withdraw_nonce,
        });
        move_to(new_relayer, Seen { attested });
        event::emit(RelayerRotated { old_relayer: old_home, new_relayer: new_addr, by: new_addr });
    }
}
