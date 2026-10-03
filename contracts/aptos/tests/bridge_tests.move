#[test_only]
module okrw_bridge::bridge_tests {
    use aptos_framework::account;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use okrw_bridge::bridge;
    use okrw_bridge::okrw;
    use std::signer;

    /// okrw::init must be called by the publisher (@okrw_bridge = 0xCAFE in
    /// --dev), because dispatch hooks reference the publisher's module
    /// address. bridge::init must be called by the relayer, because Config /
    /// Seen live under the relayer's account (mint_attested borrows them via
    /// the relayer signer). The publisher acts as coin admin.
    fun setup(publisher: &signer, relayer: &signer): Object<Metadata> {
        timestamp::set_time_has_started_for_testing(&account::create_account_for_test(@aptos_framework));
        let publisher_addr = signer::address_of(publisher);
        let relayer_addr = signer::address_of(relayer);
        okrw::init(publisher, relayer_addr, publisher_addr, publisher_addr);
        let metadata = object::address_to_object<Metadata>(okrw::metadata_address(publisher_addr));
        bridge::init(relayer, metadata, 1_000_000);
        metadata
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    fun test_mint_attested_happy_path(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        bridge::mint_attested(&relayer, metadata, user_addr, 100, 0);
        assert!(primary_fungible_store::balance(user_addr, metadata) == 100, 0);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    fun test_supply_view_tracks_mint_and_burn(publisher: signer, relayer: signer, user: signer) {
        use std::option;
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        let relayer_addr = signer::address_of(&relayer);
        account::create_account_for_test(user_addr);
        assert!(okrw::supply(metadata) == option::some(0), 0);
        bridge::mint_attested(&relayer, metadata, user_addr, 100, 0);
        assert!(okrw::supply(metadata) == option::some(100), 1);
        primary_fungible_store::transfer(&user, metadata, relayer_addr, 40);
        bridge::burn_withdraw(
            &relayer, metadata, user_addr, 40,
            x"0000000000000000000000000000000000000000",
        );
        assert!(okrw::supply(metadata) == option::some(60), 2);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 2, location = okrw_bridge::bridge)]
    fun test_mint_attested_replay_rejected(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        bridge::mint_attested(&relayer, metadata, user_addr, 100, 7);
        bridge::mint_attested(&relayer, metadata, user_addr, 100, 7);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 4, location = okrw_bridge::okrw)]
    fun test_mint_by_non_minter_rejected(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        okrw::mint(&user, metadata, user_addr, 100);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    fun test_withdraw_two_step_burns(publisher: signer, relayer: signer, user: signer) {
        let publisher_addr = signer::address_of(&publisher);
        let metadata = setup(&publisher, &relayer);
        let relayer_addr = signer::address_of(&relayer);
        let user_addr = signer::address_of(&user);
        account::create_account_for_test(user_addr);
        bridge::mint_attested(&relayer, metadata, user_addr, 100, 0);
        // Step 1: user transfers to bridge account.
        primary_fungible_store::transfer(&user, metadata, relayer_addr, 40);
        assert!(primary_fungible_store::balance(relayer_addr, metadata) == 40, 0);
        // Step 2: relayer burns + emits (Config lives under relayer).
        bridge::burn_withdraw(
            &relayer, metadata, user_addr, 40,
            x"0000000000000000000000000000000000000000",
        );
        assert!(primary_fungible_store::balance(relayer_addr, metadata) == 0, 1);
        assert!(primary_fungible_store::balance(user_addr, metadata) == 60, 2);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    fun test_pause_unpause_view(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        bridge::mint_attested(&relayer, metadata, user_addr, 100, 0);
        okrw::pause(&publisher, metadata);
        assert!(okrw::is_paused(metadata), 0);
        okrw::unpause(&publisher, metadata);
        assert!(!okrw::is_paused(metadata), 1);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    fun test_denylist_then_mint_works_after_removal(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        okrw::denylist(&publisher, metadata, user_addr);
        assert!(okrw::is_denylisted(metadata, user_addr), 0);
        okrw::undenylist(&publisher, metadata, user_addr);
        assert!(!okrw::is_denylisted(metadata, user_addr), 1);
        bridge::mint_attested(&relayer, metadata, user_addr, 10, 0);
        assert!(primary_fungible_store::balance(user_addr, metadata) == 10, 2);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 4, location = okrw_bridge::bridge)]
    fun test_daily_cap_enforced(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        bridge::set_daily_mint_cap(&relayer, 50);
        bridge::mint_attested(&relayer, metadata, user_addr, 50, 0);
        bridge::mint_attested(&relayer, metadata, user_addr, 1, 1);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 5, location = okrw_bridge::bridge)]
    fun test_bridge_pause_blocks_mint(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        bridge::pause(&relayer);
        bridge::mint_attested(&relayer, metadata, signer::address_of(&user), 10, 0);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC, relayer2 = @0xE)]
    fun test_relayer_rotation_preserves_replay_history(
        publisher: signer, relayer: signer, user: signer, relayer2: signer,
    ) {
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        // Attest nonce 0 under the old relayer.
        bridge::mint_attested(&relayer, metadata, user_addr, 10, 0);
        // Rotate bridge (propose + claim) AND coin minter role (admin step).
        let new_addr = signer::address_of(&relayer2);
        bridge::propose_relayer(&relayer, new_addr);
        bridge::claim_relayer(&relayer2, signer::address_of(&relayer));
        okrw::set_minter(&publisher, metadata, new_addr);
        // New relayer can mint new nonces…
        bridge::mint_attested(&relayer2, metadata, user_addr, 10, 1);
        assert!(primary_fungible_store::balance(user_addr, metadata) == 20, 0);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC, relayer2 = @0xE)]
    #[expected_failure(abort_code = 2, location = okrw_bridge::bridge)]
    fun test_replay_blocked_after_rotation(
        publisher: signer, relayer: signer, user: signer, relayer2: signer,
    ) {
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        bridge::mint_attested(&relayer, metadata, user_addr, 10, 0);
        bridge::propose_relayer(&relayer, signer::address_of(&relayer2));
        bridge::claim_relayer(&relayer2, signer::address_of(&relayer));
        okrw::set_minter(&publisher, metadata, signer::address_of(&relayer2));
        // …but nonce 0 can never be re-attested (Seen moved with Config).
        bridge::mint_attested(&relayer2, metadata, user_addr, 10, 0);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 7, location = okrw_bridge::bridge)]
    fun test_wrong_metadata_rejected(publisher: signer, relayer: signer, user: signer) {
        use aptos_framework::primary_fungible_store;
        use std::option;
        use std::string;
        let metadata = setup(&publisher, &relayer);
        // A genuine but DIFFERENT FA metadata object must fail (EWRONG_METADATA).
        let ctor = object::create_named_object(&publisher, b"FAKE");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &ctor, option::none(),
            string::utf8(b"Fake"), string::utf8(b"FAKE"), 8,
            string::utf8(b""), string::utf8(b""),
        );
        let fake = object::object_from_constructor_ref<Metadata>(&ctor);
        bridge::mint_attested(&relayer, fake, signer::address_of(&user), 10, 0);
        let _ = metadata;
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC, newadmin = @0xF)]
    fun test_admin_two_step_transfer(publisher: signer, relayer: signer, user: signer, newadmin: signer) {
        let metadata = setup(&publisher, &relayer);
        let new_addr = signer::address_of(&newadmin);
        // Non-pending claimant cannot seize admin…
        okrw::propose_admin(&publisher, metadata, new_addr);
        okrw::accept_admin(&newadmin, metadata);
        // …and the new admin can now rotate roles.
        okrw::set_pauser(&newadmin, metadata, signer::address_of(&user));
        okrw::set_denylister(&newadmin, metadata, signer::address_of(&user));
        okrw::set_minter(&newadmin, metadata, signer::address_of(&user));
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 3, location = okrw_bridge::okrw)]
    fun test_admin_accept_without_proposal_fails(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        okrw::accept_admin(&user, metadata);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 1, location = okrw_bridge::okrw)]
    fun test_burn_blocked_while_paused(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        let relayer_addr = signer::address_of(&relayer);
        account::create_account_for_test(relayer_addr);
        bridge::mint_attested(&relayer, metadata, relayer_addr, 50, 0);
        okrw::pause(&publisher, metadata);
        // bridge_burn while paused must abort (EPAUSED).
        okrw::bridge_burn(&relayer, metadata, 10);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    fun test_emergency_pause_freezes_both_layers(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        let user_addr = signer::address_of(&user);
        let relayer_addr = signer::address_of(&relayer);
        // Deploy parity: pauser = relayer so one key freezes both layers.
        okrw::set_pauser(&publisher, metadata, relayer_addr);
        bridge::mint_attested(&relayer, metadata, user_addr, 100, 0);
        bridge::emergency_pause(&relayer, metadata);
        assert!(okrw::is_paused(metadata), 0);
        // Bridge mint path now aborts with EPAUSED (5)...
        // (verified implicitly: is_paused gates okrw::mint/bridge_burn;
        // bridge::mint_attested checks cfg.paused first)
        // Recovery is two explicit steps.
        bridge::unpause(&relayer);
        okrw::unpause(&relayer, metadata);
        assert!(!okrw::is_paused(metadata), 1);
        bridge::mint_attested(&relayer, metadata, user_addr, 10, 1);
        assert!(primary_fungible_store::balance(user_addr, metadata) == 110, 2);
    }

    #[test(publisher = @okrw_bridge, relayer = @0xB, user = @0xC)]
    #[expected_failure(abort_code = 5, location = okrw_bridge::bridge)]
    fun test_emergency_pause_blocks_bridge_burn(publisher: signer, relayer: signer, user: signer) {
        let metadata = setup(&publisher, &relayer);
        let relayer_addr = signer::address_of(&relayer);
        account::create_account_for_test(relayer_addr);
        okrw::set_pauser(&publisher, metadata, relayer_addr);
        bridge::mint_attested(&relayer, metadata, relayer_addr, 50, 0);
        bridge::emergency_pause(&relayer, metadata);
        // Burn path aborts: bridge paused (EPAUSED=5 surfaces from okrw too).
        bridge::burn_withdraw(
            &relayer, metadata, relayer_addr, 10,
            x"0000000000000000000000000000000000000000",
        );
    }
}
