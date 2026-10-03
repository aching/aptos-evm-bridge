/// OKRW — Maroo Won stablecoin on Aptos (managed fungible asset).
///
/// Mirrors USDC-style regulated-FA controls:
/// - separate admin / minter / pauser / denylister roles (multisig-friendly)
/// - pause halts transfers AND bridge minting
/// - per-address denylist (freeze) enforced on transfer, mint, burn
/// - events for mint / burn / pause / denylist changes
///
/// Transfer enforcement uses the dispatchable-FA pattern: `withdraw` /
/// `deposit` hooks (exact dispatcher signatures) check pause + denylist,
/// then perform the transfer via the stored TransferRef.
///
/// Decimals: 18, matching Maroo native OKRW 1:1 (no conversion).
module okrw_bridge::okrw {
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::event;
    use aptos_framework::function_info;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, MintRef, BurnRef, TransferRef, Metadata};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use std::option;
    use std::signer;
    use std::string;

    const DECIMALS: u8 = 18;

    // ---------------------------------------------------------------- errors
    const EPAUSED: u64 = 1;
    const EDENYLISTED: u64 = 2;
    const ENOT_ADMIN: u64 = 3;
    const ENOT_MINTER: u64 = 4;
    const ENOT_PAUSER: u64 = 5;
    const ENOT_DENYLISTER: u64 = 6;
    const EZERO_AMOUNT: u64 = 7;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Roles has key {
        admin: address,
        minter: address,
        pauser: address,
        denylister: address,
        /// Two-step admin transfer target (none = no transfer in flight).
        pending_admin: option::Option<address>,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct State has key {
        paused: bool,
        mint_ref: MintRef,
        burn_ref: BurnRef,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Denylist has key {
        frozen: vector<address>,
    }

    // ---------------------------------------------------------------- events
    #[event]
    struct Mint has drop, store { to: address, amount: u64 }

    #[event]
    struct Burn has drop, store { from: address, amount: u64 }

    #[event]
    struct Paused has drop, store { by: address }

    #[event]
    struct Unpaused has drop, store { by: address }

    #[event]
    struct Denylisted has drop, store { account: address, by: address }

    #[event]
    struct Undenylisted has drop, store { account: address, by: address }

    /// Initialize the OKRW FA. MUST be called by the publisher account
    /// (demo admin), because dispatch FunctionInfo references the publisher.
    /// Roles assigned to args (use the relayer address as minter).
    public entry fun init(
        admin: &signer,
        minter: address,
        pauser: address,
        denylister: address,
    ) {
        let admin_addr = signer::address_of(admin);
        let ctor_ref = object::create_named_object(admin, b"OKRW");
        let metadata_signer = &object::generate_signer(&ctor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &ctor_ref,
            option::none(),
            string::utf8(b"Maroo Bridged OKRW"),
            string::utf8(b"OKRW"),
            DECIMALS,
            string::utf8(b"https://maroo.io"),
            string::utf8(b"https://maroo.io/okrw.png"),
        );

        // Dispatch hooks: exact dispatcher signatures required.
        let withdraw = function_info::new_function_info(
            admin,
            string::utf8(b"okrw"),
            string::utf8(b"withdraw"),
        );
        let deposit = function_info::new_function_info(
            admin,
            string::utf8(b"okrw"),
            string::utf8(b"deposit"),
        );
        dispatchable_fungible_asset::register_dispatch_functions(
            &ctor_ref, option::some(withdraw), option::some(deposit), option::none(),
        );

        move_to(metadata_signer, Roles {
            admin: admin_addr, minter, pauser, denylister,
            pending_admin: option::none(),
        });
        move_to(metadata_signer, State {
            paused: false,
            mint_ref: fungible_asset::generate_mint_ref(&ctor_ref),
            burn_ref: fungible_asset::generate_burn_ref(&ctor_ref),
        });
        move_to(metadata_signer, Denylist { frozen: vector[] });
    }

    // ------------------------------------------------------------ role gates
    fun assert_admin(caller: address, metadata: Object<Metadata>) acquires Roles {
        let r = borrow_global<Roles>(object::object_address(&metadata));
        assert!(caller == r.admin, ENOT_ADMIN);
    }

    fun assert_minter(caller: address, metadata: Object<Metadata>) acquires Roles {
        let r = borrow_global<Roles>(object::object_address(&metadata));
        assert!(caller == r.minter, ENOT_MINTER);
    }

    fun assert_pauser(caller: address, metadata: Object<Metadata>) acquires Roles {
        let r = borrow_global<Roles>(object::object_address(&metadata));
        assert!(caller == r.pauser, ENOT_PAUSER);
    }

    fun assert_denylister(caller: address, metadata: Object<Metadata>) acquires Roles {
        let r = borrow_global<Roles>(object::object_address(&metadata));
        assert!(caller == r.denylister, ENOT_DENYLISTER);
    }

    // ----------------------------------------------------------------- views
    #[view]
    public fun metadata_address(admin: address): address {
        object::create_object_address(&admin, b"OKRW")
    }

    #[view]
    public fun is_denylisted(metadata: Object<Metadata>, account: address): bool acquires Denylist {
        let d = borrow_global<Denylist>(object::object_address(&metadata));
        d.frozen.contains(&account)
    }

    #[view]
    public fun is_paused(metadata: Object<Metadata>): bool acquires State {
        borrow_global<State>(object::object_address(&metadata)).paused
    }

    // Total OKRW supply across all holders. Used by the off-chain
    // conservation monitor (vault escrow must equal supply). Exposed as a
    // view so monitoring never relies on summing known balances (which
    // silently misses any unexpected third holder).
    #[view]
    public fun supply(metadata: Object<Metadata>): option::Option<u128> {
        fungible_asset::supply(metadata)
    }

    fun metadata_of_store<T: key>(store: Object<T>): Object<Metadata> {
        fungible_asset::store_metadata(store)
    }

    fun store_owner<T: key>(store: Object<T>): address {
        object::owner(store)
    }

    // ------------------------------------------------------------------ mint
    /// Mint OKRW. Only the minter role (relayer signer in the demo).
    /// Uses `mint_to` directly (bypasses the deposit dispatch hook, which
    /// would trip the reentrancy guard when called from this module).
    /// Recipient denylist + pause are checked explicitly below.
    public fun mint(minter: &signer, metadata: Object<Metadata>, to: address, amount: u64) acquires Roles, State, Denylist {
        let caller = signer::address_of(minter);
        assert_minter(caller, metadata);
        assert!(amount > 0, EZERO_AMOUNT);
        assert!(!is_paused(metadata), EPAUSED);
        assert!(!is_denylisted(metadata, to), EDENYLISTED);
        let s = borrow_global<State>(object::object_address(&metadata));
        let store = primary_fungible_store::ensure_primary_store_exists(to, metadata);
        fungible_asset::mint_to(&s.mint_ref, store, amount);
        event::emit(Mint { to, amount });
    }

    /// Burn OKRW from the minter's own store. Only the minter role (relayer
    /// signer in the demo). Uses `burn_from` directly (bypasses the withdraw
    /// dispatch hook — same reentrancy reason as mint). Fail-closed on pause:
    /// incident response halts both bridge directions. The bridge calls this
    /// on the return path after the user transferred funds to the bridge.
    public fun bridge_burn(minter: &signer, metadata: Object<Metadata>, amount: u64) acquires Roles, State, Denylist {
        let caller = signer::address_of(minter);
        assert_minter(caller, metadata);
        assert!(!is_paused(metadata), EPAUSED);
        assert!(!is_denylisted(metadata, caller), EDENYLISTED);
        let s = borrow_global<State>(object::object_address(&metadata));
        let store = primary_fungible_store::ensure_primary_store_exists(caller, metadata);
        fungible_asset::burn_from(&s.burn_ref, store, amount);
        event::emit(Burn { from: caller, amount });
    }
    // ----------------------------------------------------------------- pause
    public entry fun pause(pauser: &signer, metadata: Object<Metadata>) acquires Roles, State {
        let caller = signer::address_of(pauser);
        assert_pauser(caller, metadata);
        borrow_global_mut<State>(object::object_address(&metadata)).paused = true;
        event::emit(Paused { by: caller });
    }

    public entry fun unpause(pauser: &signer, metadata: Object<Metadata>) acquires Roles, State {
        let caller = signer::address_of(pauser);
        assert_pauser(caller, metadata);
        borrow_global_mut<State>(object::object_address(&metadata)).paused = false;
        event::emit(Unpaused { by: caller });
    }

    // --------------------------------------------------------------- denylist
    public entry fun denylist(denylister: &signer, metadata: Object<Metadata>, account: address) acquires Roles, Denylist {
        let caller = signer::address_of(denylister);
        assert_denylister(caller, metadata);
        let d = borrow_global_mut<Denylist>(object::object_address(&metadata));
        if (!d.frozen.contains(&account)) d.frozen.push_back(account);
        event::emit(Denylisted { account, by: caller });
    }

    public entry fun undenylist(denylister: &signer, metadata: Object<Metadata>, account: address) acquires Roles, Denylist {
        let caller = signer::address_of(denylister);
        assert_denylister(caller, metadata);
        let d = borrow_global_mut<Denylist>(object::object_address(&metadata));
        let (found, i) = d.frozen.index_of(&account);
        if (found) { d.frozen.remove(i); };
        event::emit(Undenylisted { account, by: caller });
    }

    // ----------------------------------------------------------------- admin
    #[event]
    struct RoleUpdated has drop, store { role: vector<u8>, old: address, new: address, by: address }

    public entry fun set_minter(admin: &signer, metadata: Object<Metadata>, new_minter: address) acquires Roles {
        let caller = signer::address_of(admin);
        assert_admin(caller, metadata);
        let r = borrow_global_mut<Roles>(object::object_address(&metadata));
        let old = r.minter;
        r.minter = new_minter;
        event::emit(RoleUpdated { role: b"minter", old, new: new_minter, by: caller });
    }

    public entry fun set_pauser(admin: &signer, metadata: Object<Metadata>, new_pauser: address) acquires Roles {
        let caller = signer::address_of(admin);
        assert_admin(caller, metadata);
        let r = borrow_global_mut<Roles>(object::object_address(&metadata));
        let old = r.pauser;
        r.pauser = new_pauser;
        event::emit(RoleUpdated { role: b"pauser", old, new: new_pauser, by: caller });
    }

    public entry fun set_denylister(admin: &signer, metadata: Object<Metadata>, new_denylister: address) acquires Roles {
        let caller = signer::address_of(admin);
        assert_admin(caller, metadata);
        let r = borrow_global_mut<Roles>(object::object_address(&metadata));
        let old = r.denylister;
        r.denylister = new_denylister;
        event::emit(RoleUpdated { role: b"denylister", old, new: new_denylister, by: caller });
    }

    /// Two-step admin transfer: propose then accept. Accept must be signed by
    /// the pending address (proves the new admin holds the key) and can only
    /// complete a transfer the current admin proposed. Prevents bricking all
    /// controls by typo-ing the admin address.
    public entry fun propose_admin(admin: &signer, metadata: Object<Metadata>, new_admin: address) acquires Roles {
        let caller = signer::address_of(admin);
        assert_admin(caller, metadata);
        let r = borrow_global_mut<Roles>(object::object_address(&metadata));
        r.pending_admin = option::some(new_admin);
        event::emit(RoleUpdated { role: b"admin-proposed", old: caller, new: new_admin, by: caller });
    }

    public entry fun accept_admin(new_admin: &signer, metadata: Object<Metadata>) acquires Roles {
        let caller = signer::address_of(new_admin);
        let r = borrow_global_mut<Roles>(object::object_address(&metadata));
        assert!(option::is_some(&r.pending_admin) && *option::borrow(&r.pending_admin) == caller, ENOT_ADMIN);
        let old = r.admin;
        r.admin = caller;
        r.pending_admin = option::none();
        event::emit(RoleUpdated { role: b"admin-accepted", old, new: caller, by: caller });
    }

    // ------------------------------------------------------- dispatch hooks
    /// Withdraw hook (dispatcher signature): enforce pause + denylist on the
    /// store owner, then perform via the TransferRef.
    public fun withdraw<T: key>(
        store: Object<T>,
        amount: u64,
        transfer_ref: &TransferRef,
    ): FungibleAsset acquires State, Denylist {
        let metadata = metadata_of_store(store);
        assert!(!is_paused(metadata), EPAUSED);
        assert!(!is_denylisted(metadata, store_owner(store)), EDENYLISTED);
        fungible_asset::withdraw_with_ref(transfer_ref, store, amount)
    }

    /// Deposit hook (dispatcher signature): enforce pause + denylist, then
    /// perform via the TransferRef.
    public fun deposit<T: key>(
        store: Object<T>,
        fa: FungibleAsset,
        transfer_ref: &TransferRef,
    ) acquires State, Denylist {
        let metadata = metadata_of_store(store);
        assert!(!is_paused(metadata), EPAUSED);
        assert!(!is_denylisted(metadata, store_owner(store)), EDENYLISTED);
        fungible_asset::deposit_with_ref(transfer_ref, store, fa)
    }
}
