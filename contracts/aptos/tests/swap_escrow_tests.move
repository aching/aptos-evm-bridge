#[test_only]
module okrw_bridge::swap_escrow_tests {
    use aptos_framework::account;
    use aptos_framework::aptos_coin;
    use aptos_framework::coin;
    use aptos_framework::fungible_asset;
    use aptos_framework::genesis;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use okrw_bridge::swap_escrow;
    use std::signer;
    use std::vector;

    const EVM_RECIPIENT: vector<u8> = x"000000000000000000000000000000000000dEaD";

    fun setup(admin: &signer, solver: &signer): (address, address) {
        // Full test genesis: coin init + per-account APT funding in one call.
        genesis::setup();
        // APT FA metadata (required by aptos_account::transfer in this
        // framework rev) + fund the three test accounts via FA.
        let fa = aptos_coin::mint_apt_fa_for_test(30_000_000_000);
        primary_fungible_store::deposit(signer::address_of(admin), fungible_asset::extract(&mut fa, 10_000_000_000));
        primary_fungible_store::deposit(signer::address_of(solver), fungible_asset::extract(&mut fa, 10_000_000_000));
        primary_fungible_store::deposit(@0xC, fungible_asset::extract(&mut fa, 10_000_000_000));
        fungible_asset::destroy_zero(fa);
        timestamp::set_time_has_started_for_testing(&account::create_account_for_test(@aptos_framework));
        let admin_addr = signer::address_of(admin);
        let solver_addr = signer::address_of(solver);
        swap_escrow::init(admin, solver_addr, 86400);
        (admin_addr, solver_addr)
    }

    fun lock_one(user: &signer, admin: address, amount: u64, min_out: u64): u64 {
        let id = swap_escrow::next_swap_id(admin);
        let deadline = timestamp::now_seconds() + 100000;
        swap_escrow::lock(user, admin, EVM_RECIPIENT, amount, min_out, deadline);
        id
    }

    #[test(admin = @okrw_bridge, solver = @0xB, user = @0xC)]
    fun test_lock_claim_settle_happy_path(admin: signer, solver: signer, user: signer) {
        let (admin_addr, _) = setup(&admin, &solver);
        let user_addr = signer::address_of(&user);
        let id = lock_one(&user, admin_addr, 1_000_000, 100_000);
        let vault = swap_escrow::vault_address(admin_addr);
        assert!(coin::balance<aptos_coin::AptosCoin>(vault) == 1_000_000, 0);
        // Claim after solver fills ETH off-chain.
        swap_escrow::claim(&solver, admin_addr, id, x"ab000000000000000000000000000000000000000000000000000000000000cd", 150_000);
        assert!(coin::balance<aptos_coin::AptosCoin>(vault) == 1_000_000, 1); // not yet released
        // Early settle must fail.
        // (checked in test_early_settle_rejected below)
        timestamp::fast_forward_seconds(86400);
        swap_escrow::settle(admin_addr, id);
        let solver_addr = signer::address_of(&solver);
        // Solver got the locked APT back on top of its 10 APT funding.
        assert!(coin::balance<aptos_coin::AptosCoin>(solver_addr) == 10_000_000_000 + 1_000_000, 2);
        let (_, _, _, _, _, claimed, refunded, _, _, _) = swap_escrow::get_swap(admin_addr, id);
        assert!(claimed && refunded, 3); // refunded flag doubles as terminal marker
    }

    #[test(admin = @okrw_bridge, solver = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 11, location = okrw_bridge::swap_escrow)]
    fun test_early_settle_rejected(admin: signer, solver: signer, user: signer) {
        let (admin_addr, _) = setup(&admin, &solver);
        account::create_account_for_test(signer::address_of(&user));
        let id = lock_one(&user, admin_addr, 1_000_000, 100_000);
        swap_escrow::claim(&solver, admin_addr, id, x"ab000000000000000000000000000000000000000000000000000000000000cd", 150_000);
        swap_escrow::settle(admin_addr, id); // ENOT_CLAIMABLE_YET
    }

    #[test(admin = @okrw_bridge, solver = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 8, location = okrw_bridge::swap_escrow)]
    fun test_double_claim_rejected(admin: signer, solver: signer, user: signer) {
        let (admin_addr, _) = setup(&admin, &solver);
        let id = lock_one(&user, admin_addr, 1_000_000, 100_000);
        let h = x"ab000000000000000000000000000000000000000000000000000000000000cd";
        swap_escrow::claim(&solver, admin_addr, id, h, 150_000);
        swap_escrow::claim(&solver, admin_addr, id, h, 150_000); // EALREADY_CLAIMED
    }

    #[test(admin = @okrw_bridge, solver = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 12, location = okrw_bridge::swap_escrow)]
    fun test_claim_below_min_out_rejected(admin: signer, solver: signer, user: signer) {
        let (admin_addr, _) = setup(&admin, &solver);
        let id = lock_one(&user, admin_addr, 1_000_000, 100_000);
        swap_escrow::claim(&solver, admin_addr, id, x"ab000000000000000000000000000000000000000000000000000000000000cd", 99_999);
    }

    #[test(admin = @okrw_bridge, solver = @0xB, user = @0xC)]
    fun test_refund_after_deadline(admin: signer, solver: signer, user: signer) {
        let (admin_addr, _) = setup(&admin, &solver);
        let user_addr = signer::address_of(&user);
        let before = coin::balance<aptos_coin::AptosCoin>(user_addr);
        let id = lock_one(&user, admin_addr, 1_000_000, 100_000);
        timestamp::fast_forward_seconds(100001);
        swap_escrow::refund(&user, admin_addr, id);
        assert!(coin::balance<aptos_coin::AptosCoin>(user_addr) == before, 0);
    }

    #[test(admin = @okrw_bridge, solver = @0xB, user = @0xC)]
    fun test_challenge_returns_funds_immediately(admin: signer, solver: signer, user: signer) {
        let (admin_addr, _) = setup(&admin, &solver);
        let user_addr = signer::address_of(&user);
        let before = coin::balance<aptos_coin::AptosCoin>(user_addr);
        let id = lock_one(&user, admin_addr, 1_000_000, 100_000);
        swap_escrow::claim(&solver, admin_addr, id, x"ab000000000000000000000000000000000000000000000000000000000000cd", 150_000);
        swap_escrow::challenge(&user, admin_addr, id);
        assert!(coin::balance<aptos_coin::AptosCoin>(user_addr) == before, 0);
    }

    #[test(admin = @okrw_bridge, solver = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 2, location = okrw_bridge::swap_escrow)]
    fun test_claim_by_non_solver_rejected(admin: signer, solver: signer, user: signer) {
        let (admin_addr, _) = setup(&admin, &solver);
        let id = lock_one(&user, admin_addr, 1_000_000, 100_000);
        // user (not solver) tries to claim: ENOT_SOLVER
        swap_escrow::claim(&user, admin_addr, id, x"ab000000000000000000000000000000000000000000000000000000000000cd", 150_000);
    }

    #[test(admin = @okrw_bridge, solver = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 3, location = okrw_bridge::swap_escrow)]
    fun test_pause_blocks_lock(admin: signer, solver: signer, user: signer) {
        let (admin_addr, _) = setup(&admin, &solver);
        swap_escrow::pause(&admin, admin_addr);
        lock_one(&user, admin_addr, 1_000_000, 100_000); // EPAUSED
    }

    #[test(admin = @okrw_bridge, solver = @0xB, user = @0xC)]
    fun test_get_swap_view_roundtrip(admin: signer, solver: signer, user: signer) {
        let (admin_addr, _) = setup(&admin, &solver);
        let user_addr = signer::address_of(&user);
        let id = lock_one(&user, admin_addr, 1_000_000, 100_000);
        let (u, r, amt, mo, dl, claimed, refunded, fh, ca, cs) = swap_escrow::get_swap(admin_addr, id);
        assert!(u == user_addr, 0);
        assert!(r == EVM_RECIPIENT, 1);
        assert!(amt == 1_000_000, 2);
        assert!(mo == 100_000, 3);
        assert!(dl == timestamp::now_seconds() + 100000, 4);
        assert!(!claimed && !refunded, 5);
        assert!(vector::is_empty(&fh), 6);
        assert!(ca == 0 && cs == @0x0, 7);
    }
}
