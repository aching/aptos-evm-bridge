/// Swap escrow — REVERSE direction: user locks APT on Aptos, solver fills
/// ETH on an EVM chain (Anvil demo), then claims the locked APT here.
///
/// Mirrors contracts/maroo/src/SwapEscrow.sol semantics:
/// lock -> claim (solver only, after filling ETH) -> settle (after challenge
/// window) | refund (user, after deadline) | challenge (anyone, cancels a
/// bogus claim and returns funds immediately).
///
/// Escrow custody: a dedicated resource account created at init holds the
/// locked APT. Its SignerCapability lives in Config, so settle/refund/
/// challenge can move funds without any user signature at payout time.
module okrw_bridge::swap_escrow {
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::aptos_account;
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use std::signer;
    use std::vector;

    // ---------------------------------------------------------------- errors
    const ENOT_ADMIN: u64 = 1;
    const ENOT_SOLVER: u64 = 2;
    const EPAUSED: u64 = 3;
    const EZERO_AMOUNT: u64 = 4;
    const EBAD_RECIPIENT: u64 = 5;
    const EBAD_DEADLINE: u64 = 6;
    const ENO_SWAP: u64 = 7;
    const EALREADY_CLAIMED: u64 = 8;
    const EALREADY_REFUNDED: u64 = 9;
    const EDEADLINE_PASSED: u64 = 10;
    const ENOT_CLAIMABLE_YET: u64 = 11;
    const EMIN_OUT_NOT_MET: u64 = 12;
    const ENOT_USER: u64 = 13;
    const EBAD_FILL_HASH: u64 = 14;

    const DEFAULT_CHALLENGE_WINDOW: u64 = 86400; // 24h, mirrors EVM escrow

    struct Swap has store {
        user: address,
        /// 20-byte EVM address the solver must pay on the EVM chain.
        evm_recipient: vector<u8>,
        /// Locked APT (octas).
        amount: u64,
        /// Minimum acceptable ETH payout (wei). u64 caps swaps at ~18 ETH.
        min_out: u64,
        /// Unix seconds after which the user may refund.
        deadline: u64,
        claimed: bool,
        refunded: bool,
        /// 32-byte keccak of (evm fill tx hash || recipient || amount).
        fill_hash: vector<u8>,
        /// Timestamp when the pending claim matures.
        claimable_at: u64,
        claim_solver: address,
    }

    struct Config has key {
        admin: address,
        solver: address,
        paused: bool,
        challenge_window: u64,
        next_swap_id: u64,
        /// Escrow vault: resource-account signer capability + address.
        vault_cap: SignerCapability,
        vault_addr: address,
    }

    // ---------------------------------------------------------------- events
    #[event]
    struct SwapLocked has drop, store {
        swap_id: u64,
        user: address,
        evm_recipient: vector<u8>,
        amount: u64,
        min_out: u64,
        deadline: u64,
    }

    #[event]
    struct SwapClaimed has drop, store {
        swap_id: u64,
        solver: address,
        fill_hash: vector<u8>,
        claimable_at: u64,
    }

    #[event]
    struct SwapSettled has drop, store { swap_id: u64, solver: address, amount: u64 }

    #[event]
    struct SwapRefunded has drop, store { swap_id: u64, user: address, amount: u64 }

    #[event]
    struct ClaimChallenged has drop, store { swap_id: u64, challenger: address }

    #[event]
    struct EscrowPaused has drop, store { by: address }

    #[event]
    struct EscrowUnpaused has drop, store { by: address }

    #[event]
    struct SolverUpdated has drop, store { old_solver: address, new_solver: address, by: address }

    // ----------------------------------------------------------------- views
    #[view]
    public fun get_swap(admin: address, swap_id: u64): (address, vector<u8>, u64, u64, u64, bool, bool, vector<u8>, u64, address) acquires Swaps {
        let s = vector::borrow(&borrow_global<Swaps>(admin).items, swap_id);
        (s.user, s.evm_recipient, s.amount, s.min_out, s.deadline,
         s.claimed, s.refunded, s.fill_hash, s.claimable_at, s.claim_solver)
    }

    #[view]
    public fun next_swap_id(admin: address): u64 acquires Config {
        borrow_global<Config>(admin).next_swap_id
    }

    #[view]
    public fun vault_address(admin: address): address acquires Config {
        borrow_global<Config>(admin).vault_addr
    }

    struct Swaps has key { items: vector<Swap> }

    /// Initialize escrow. Caller becomes admin; creates the vault resource
    /// account that custodies locked APT.
    public entry fun init(admin: &signer, solver: address, challenge_window: u64) {
        let admin_addr = signer::address_of(admin);
        let (vault_signer, vault_cap) =
            account::create_resource_account(admin, b"swap_escrow");
        let vault_addr = signer::address_of(&vault_signer);
        move_to(admin, Config {
            admin: admin_addr,
            solver,
            paused: false,
            challenge_window,
            next_swap_id: 0,
            vault_cap,
            vault_addr,
        });
        move_to(admin, Swaps { items: vector[] });
    }

    fun assert_admin(caller: address, admin: address) acquires Config {
        assert!(caller == borrow_global<Config>(admin).admin, ENOT_ADMIN);
    }

    fun assert_solver(caller: address, admin: address) acquires Config {
        assert!(caller == borrow_global<Config>(admin).solver, ENOT_SOLVER);
    }

    /// Lock APT into escrow, naming the EVM recipient the solver must pay.
    public entry fun lock(
        user: &signer,
        admin: address,
        evm_recipient: vector<u8>,
        amount: u64,
        min_out: u64,
        deadline: u64,
    ) acquires Config, Swaps {
        let cfg = borrow_global<Config>(admin);
        assert!(!cfg.paused, EPAUSED);
        assert!(amount > 0, EZERO_AMOUNT);
        assert!(vector::length(&evm_recipient) == 20, EBAD_RECIPIENT);
        assert!(min_out > 0, EZERO_AMOUNT);
        assert!(deadline > timestamp::now_seconds(), EBAD_DEADLINE);
        let user_addr = signer::address_of(user);
        // Custody: user -> vault resource account (user signs, so direct).
        aptos_account::transfer(user, cfg.vault_addr, amount);
        let swaps = borrow_global_mut<Swaps>(admin);
        let swap_id = vector::length(&swaps.items);
        vector::push_back(&mut swaps.items, Swap {
            user: user_addr,
            evm_recipient,
            amount,
            min_out,
            deadline,
            claimed: false,
            refunded: false,
            fill_hash: vector[],
            claimable_at: 0,
            claim_solver: @0x0,
        });
        borrow_global_mut<Config>(admin).next_swap_id = swap_id + 1;
        event::emit(SwapLocked { swap_id, user: user_addr, evm_recipient, amount, min_out, deadline });
    }

    /// Solver claims after filling ETH on the EVM chain. Funds release at
    /// settle, after the challenge window.
    public entry fun claim(
        solver: &signer,
        admin: address,
        swap_id: u64,
        fill_hash: vector<u8>,
        fill_amount: u64,
    ) acquires Config, Swaps {
        let caller = signer::address_of(solver);
        assert_solver(caller, admin);
        assert!(vector::length(&fill_hash) == 32, EBAD_FILL_HASH);
        let cfg = borrow_global<Config>(admin);
        assert!(!cfg.paused, EPAUSED);
        let swaps = borrow_global_mut<Swaps>(admin);
        assert!(swap_id < vector::length(&swaps.items), ENO_SWAP);
        let s = vector::borrow_mut(&mut swaps.items, swap_id);
        assert!(!s.claimed, EALREADY_CLAIMED);
        assert!(!s.refunded, EALREADY_REFUNDED);
        assert!(timestamp::now_seconds() < s.deadline, EDEADLINE_PASSED);
        assert!(fill_amount >= s.min_out, EMIN_OUT_NOT_MET);
        s.claimed = true;
        s.claim_solver = caller;
        s.fill_hash = fill_hash;
        let mature = timestamp::now_seconds() + cfg.challenge_window;
        s.claimable_at = mature;
        event::emit(SwapClaimed { swap_id, solver: caller, fill_hash, claimable_at: mature });
    }

    /// Release locked APT to the claiming solver after the window matures.
    public entry fun settle(admin: address, swap_id: u64) acquires Config, Swaps {
        let cfg = borrow_global<Config>(admin);
        assert!(!cfg.paused, EPAUSED);
        let swaps = borrow_global_mut<Swaps>(admin);
        assert!(swap_id < vector::length(&swaps.items), ENO_SWAP);
        let s = vector::borrow_mut(&mut swaps.items, swap_id);
        assert!(s.claimed, ENO_SWAP);
        assert!(!s.refunded, EALREADY_REFUNDED);
        assert!(timestamp::now_seconds() >= s.claimable_at, ENOT_CLAIMABLE_YET);
        let (to, amt) = (s.claim_solver, s.amount);
        s.refunded = true; // terminal: neither settle nor refund can re-run
        let vault = account::create_signer_with_capability(&cfg.vault_cap);
        aptos_account::transfer(&vault, to, amt);
        event::emit(SwapSettled { swap_id, solver: to, amount: amt });
    }

    /// User reclaims locked APT after the deadline (unclaimed swaps only).
    public entry fun refund(user: &signer, admin: address, swap_id: u64) acquires Config, Swaps {
        let caller = signer::address_of(user);
        let swaps = borrow_global_mut<Swaps>(admin);
        assert!(swap_id < vector::length(&swaps.items), ENO_SWAP);
        let s = vector::borrow_mut(&mut swaps.items, swap_id);
        assert!(caller == s.user, ENOT_USER);
        assert!(!s.claimed, EALREADY_CLAIMED);
        assert!(!s.refunded, EALREADY_REFUNDED);
        assert!(timestamp::now_seconds() >= s.deadline, EDEADLINE_PASSED);
        s.refunded = true;
        let cfg = borrow_global<Config>(admin);
        let vault = account::create_signer_with_capability(&cfg.vault_cap);
        aptos_account::transfer(&vault, caller, s.amount);
        event::emit(SwapRefunded { swap_id, user: caller, amount: s.amount });
    }

    /// Cancel a bogus claim during the window; funds return to the user
    /// immediately (simpler than the EVM two-step: no second refund needed).
    public entry fun challenge(challenger: &signer, admin: address, swap_id: u64) acquires Config, Swaps {
        let cfg = borrow_global<Config>(admin);
        assert!(!cfg.paused, EPAUSED);
        let swaps = borrow_global_mut<Swaps>(admin);
        assert!(swap_id < vector::length(&swaps.items), ENO_SWAP);
        let s = vector::borrow_mut(&mut swaps.items, swap_id);
        assert!(s.claimed, ENO_SWAP);
        assert!(!s.refunded, EALREADY_REFUNDED);
        assert!(timestamp::now_seconds() < s.claimable_at, EDEADLINE_PASSED);
        let (to, amt) = (s.user, s.amount);
        s.refunded = true;
        let vault = account::create_signer_with_capability(&cfg.vault_cap);
        aptos_account::transfer(&vault, to, amt);
        event::emit(ClaimChallenged { swap_id, challenger: signer::address_of(challenger) });
    }

    // ----------------------------------------------------------------- admin
    public entry fun set_solver(admin: &signer, escrow_admin: address, new_solver: address) acquires Config {
        let caller = signer::address_of(admin);
        assert_admin(caller, escrow_admin);
        let cfg = borrow_global_mut<Config>(escrow_admin);
        let old = cfg.solver;
        cfg.solver = new_solver;
        event::emit(SolverUpdated { old_solver: old, new_solver, by: caller });
    }

    public entry fun set_challenge_window(admin: &signer, escrow_admin: address, window_secs: u64) acquires Config {
        let caller = signer::address_of(admin);
        assert_admin(caller, escrow_admin);
        borrow_global_mut<Config>(escrow_admin).challenge_window = window_secs;
    }

    public entry fun pause(admin: &signer, escrow_admin: address) acquires Config {
        let caller = signer::address_of(admin);
        assert_admin(caller, escrow_admin);
        borrow_global_mut<Config>(escrow_admin).paused = true;
        event::emit(EscrowPaused { by: caller });
    }

    public entry fun unpause(admin: &signer, escrow_admin: address) acquires Config {
        let caller = signer::address_of(admin);
        assert_admin(caller, escrow_admin);
        borrow_global_mut<Config>(escrow_admin).paused = false;
        event::emit(EscrowUnpaused { by: caller });
    }

    #[test_only]
    public fun default_challenge_window(): u64 { DEFAULT_CHALLENGE_WINDOW }
}
