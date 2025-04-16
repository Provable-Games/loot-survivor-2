use lootsurvivor::constants::discovery::DiscoveryEnums::ExploreResult;
use lootsurvivor::models::adventurer::adventurer::{Adventurer, ItemSpecial};
use lootsurvivor::models::adventurer::bag::Bag;
use lootsurvivor::models::adventurer::stats::Stats;
use lootsurvivor::models::beast::Beast;
use lootsurvivor::models::market::ItemPurchase;

const VRF_ENABLED: bool = false;

#[starknet::interface]
trait IGameSystems<T> {
    // ------ Game Actions ------
    fn start_game(ref self: T, adventurer_id: u64, weapon: u8);
    fn explore(ref self: T, adventurer_id: u64, till_beast: bool) -> Array<ExploreResult>;
    fn attack(ref self: T, adventurer_id: u64, to_the_death: bool);
    fn flee(ref self: T, adventurer_id: u64, to_the_death: bool);
    fn equip(ref self: T, adventurer_id: u64, items: Array<u8>);
    fn drop(ref self: T, adventurer_id: u64, items: Array<u8>);
    fn level_up(
        ref self: T, adventurer_id: u64, potions: u8, stat_upgrades: Stats, items: Array<ItemPurchase>,
    );
    fn set_adventurer_obituary(ref self: T, adventurer_id: u64, obituary: ByteArray);

    // ------ View Functions ------

    // adventurer details
    fn get_adventurer(self: @T, adventurer_id: u64) -> Adventurer;
    fn get_adventurer_obituary(self: @T, adventurer_id: u64) -> ByteArray;
    fn get_adventurer_no_boosts(self: @T, adventurer_id: u64) -> Adventurer;
    fn get_adventurer_name(self: @T, adventurer_id: u64) -> felt252;

    // bag and specials
    fn get_bag(self: @T, adventurer_id: u64) -> Bag;

    // market details
    fn get_market(self: @T, adventurer_id: u64) -> Array<u8>;
    fn get_potion_price(self: @T, adventurer_id: u64) -> u16;
    fn get_item_price(self: @T, adventurer_id: u64, item_id: u8) -> u16;

    // beast details
    fn get_attacking_beast(self: @T, adventurer_id: u64) -> Beast;
    fn get_item_specials(self: @T, adventurer_id: u64) -> Array<ItemSpecial>;
    fn obstacle_critical_hit_chance(self: @T, adventurer_id: u64) -> u8;
    fn beast_critical_hit_chance(self: @T, adventurer_id: u64, is_ambush: bool) -> u8;
}


#[dojo::contract]
mod game_systems {
    use super::VRF_ENABLED;
    use core::panic_with_felt252;
    use starknet::{ContractAddress, get_tx_info};
    use lootsurvivor::constants::adventurer::{
        ITEM_MAX_GREATNESS, ITEM_XP_MULTIPLIER_BEASTS, ITEM_XP_MULTIPLIER_OBSTACLES, MAX_GREATNESS_STAT_BONUS,
        POTION_HEALTH_AMOUNT, STARTING_HEALTH, TWO_POW_32, XP_FOR_DISCOVERIES,
    };
    use lootsurvivor::constants::combat::CombatEnums::{Tier};
    use lootsurvivor::constants::discovery::DiscoveryEnums::{DiscoveryType, ExploreResult};
    use lootsurvivor::constants::game::{MAINNET_CHAIN_ID, SEPOLIA_CHAIN_ID, STARTER_BEAST_ATTACK_DAMAGE, messages};
    use lootsurvivor::constants::loot::{SUFFIX_UNLOCK_GREATNESS};
    use lootsurvivor::constants::world::{DEFAULT_NS, SCORE_ATTRIBUTE, SCORE_MODEL, SETTINGS_MODEL};

    use lootsurvivor::models::game::{AdventurerPacked, AdventurerEntropy, BagPacked, AdventurerObituary};
    use lootsurvivor::models::adventurer::adventurer::{
        Adventurer, IAdventurer, ImplAdventurer, ItemLeveledUp, ItemSpecial,
    };
    use lootsurvivor::models::adventurer::bag::{Bag};
    use lootsurvivor::models::adventurer::equipment::{ImplEquipment};
    use lootsurvivor::models::adventurer::item::{ImplItem, Item};
    use lootsurvivor::models::adventurer::stats::{ImplStats, Stats};
    use lootsurvivor::models::beast::{Beast, IBeast, ImplBeast};
    use lootsurvivor::models::combat::{CombatSpec, ImplCombat, SpecialPowers};
    use lootsurvivor::models::market::{ItemPurchase, LootWithPrice};
    use lootsurvivor::models::obstacle::{IObstacle, ImplObstacle};
    use lootsurvivor::models::event::{BattleDetails, ObstacleDetails};

    use lootsurvivor::utils::cartridge::VRFImpl;

    use lootsurvivor::libs::game::{IGameLib, ImplGame, GameLibs};

    use dojo::model::ModelStorage;
    use dojo::world::WorldStorage;
    
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_token::erc721::interface::{IERC721Metadata};
    use openzeppelin_token::erc721::{ERC721Component, ERC721HooksEmptyImpl};

    use tournaments::components::game::game_component;
    use tournaments::components::interfaces::{IGameDetails, ISettings};
    use tournaments::components::libs::lifecycle::{LifecycleAssertionsImpl, LifecycleAssertionsTrait};
    use tournaments::components::models::game::TokenMetadata;

    // Components
    component!(path: game_component, storage: game, event: GameEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: ERC721Component, storage: erc721, event: ERC721Event);

    #[abi(embed_v0)]
    impl GameImpl = game_component::GameImpl<ContractState>;
    impl GameInternalImpl = game_component::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl ERC721Impl = ERC721Component::ERC721Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC721CamelOnlyImpl = ERC721Component::ERC721CamelOnlyImpl<ContractState>;
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        game: game_component::Storage,
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        GameEvent: game_component::Event,
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    /// @title Dojo Init
    /// @notice Initializes the contract
    /// @dev This is the constructor for the contract. It is called once when the contract is
    /// deployed.
    ///
    /// @param creator_address: the address of the creator of the game
    fn dojo_init(ref self: ContractState, creator_address: ContractAddress) {
        self.erc721.initializer("Loot Survivor", "LSVR", "https://lootsurvivor.io/");
        self
            .game
            .initializer(
                creator_address,
                'Loot Survivor',
                "Loot Survivor is a fully on-chain arcade dungeon crawler game on Starknet",
                'Provable Games',
                'Provable Games',
                'Arcade / Dungeon Crawler',
                "https://lootsurvivor.io/favicon-32x32.png",
                DEFAULT_NS(),
                SCORE_MODEL(),
                SCORE_ATTRIBUTE(),
                SETTINGS_MODEL(),
            );
    }

    // ------------------------------------------ //
    // ------------ Game Component ------------------------ //
    // ------------------------------------------ //
    #[abi(embed_v0)]
    impl SettingsImpl of ISettings<ContractState> {
        fn setting_exists(self: @ContractState, settings_id: u32) -> bool {
            return settings_id == 0;
        }
    }

    #[abi(embed_v0)]
    impl GameDetailsImpl of IGameDetails<ContractState> {
        fn score(self: @ContractState, game_id: u64) -> u32 {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let mut adventurer_packed: AdventurerPacked = world.read_model(game_id);
            let adventurer = ImplAdventurer::unpack(adventurer_packed.packed);
            adventurer.xp.into()
        }
    }

    // ------------------------------------------ //
    // ------------ Impl ------------------------ //
    // ------------------------------------------ //
    #[abi(embed_v0)]
    impl GameSystemsImpl of super::IGameSystems<ContractState> {
        /// @title Start Game
        ///
        /// @notice Starts a new game of Loot Survivor
        /// @dev Starts a new game of Loot Survivor with the provided weapon.
        fn start_game(ref self: ContractState, adventurer_id: u64, weapon: u8) {
            let mut world: WorldStorage = self.world(@DEFAULT_NS());

            let token_metadata: TokenMetadata = world.read_model(adventurer_id);
            self.validate_start_conditions(adventurer_id, @token_metadata);

            // get game libaries
            let game_libs = ImplGame::get_libs(world);

            // assert provided weapon
            _assert_valid_starter_weapon(weapon, game_libs);

            // generate a new adventurer using the provided started weapon
            let mut adventurer = ImplAdventurer::new(weapon);

            let _beast_battle_details = _starter_beast_ambush(ref adventurer, adventurer_id, weapon, game_libs);

            _save_adventurer_no_boosts(ref world, adventurer, adventurer_id);
        }

        /// @title Explore Function
        ///
        /// @notice Allows an adventurer to explore
        ///
        /// @param adventurer_id A u256 representing the ID of the adventurer.
        /// @param till_beast A boolean flag indicating if the exploration continues until
        /// encountering a beast.
        fn explore(ref self: ContractState, adventurer_id: u64, till_beast: bool) -> Array<ExploreResult> {
            self.assert_token_ownership(adventurer_id);

            let mut world: WorldStorage = self.world(@DEFAULT_NS());
            
            let token_metadata: TokenMetadata = world.read_model(adventurer_id);
            token_metadata.lifecycle.assert_is_playable(adventurer_id, starknet::get_block_timestamp());
            
            // get game libaries
            let game_libs = ImplGame::get_libs(world);

            // load player assets
            let mut adventurer = _load_adventurer(world, adventurer_id, game_libs);
            let mut bag = _load_bag(world, adventurer_id, game_libs);


            // use an immutable adventurer for assertions
            let immutable_adventurer = adventurer.clone();

            // assert action is valid
            _assert_not_dead(immutable_adventurer);
            _assert_no_stat_upgrades_available(immutable_adventurer);
            _assert_not_in_battle(immutable_adventurer);

            // get random seed
            let (explore_seed, market_seed) = _get_random_seed(world, adventurer_id, adventurer.xp);

            // go explore
            let mut explore_results = ArrayTrait::<ExploreResult>::new();
            _explore(ref world, ref adventurer, ref bag, ref explore_results, adventurer_id, explore_seed, till_beast, game_libs);

            // save state
            if (adventurer.stat_upgrades_available != 0) {
                _save_market_seed(ref world, adventurer_id, market_seed);
            }

            adventurer.increment_action_count();
            _save_adventurer(ref world, ref adventurer, adventurer_id, game_libs);

            if bag.mutated {
                _save_bag(ref world, adventurer_id, bag, game_libs);
            }

            explore_results
        }

        /// @title Attack Function
        ///
        /// @notice Allows an adventurer to attack a beast
        ///
        /// @param adventurer_id A u256 representing the ID of the adventurer.
        /// @param to_the_death A boolean flag indicating if the attack should continue until either
        /// the adventurer or the beast is defeated.
        fn attack(ref self: ContractState, adventurer_id: u64, to_the_death: bool) {
            self.assert_token_ownership(adventurer_id);

            let mut world: WorldStorage = self.world(@DEFAULT_NS());

            let token_metadata: TokenMetadata = world.read_model(adventurer_id);
            token_metadata.lifecycle.assert_is_playable(adventurer_id, starknet::get_block_timestamp());

            // get game libaries
            let game_libs = ImplGame::get_libs(world);

            // load player assets
            let mut adventurer = _load_adventurer(world, adventurer_id, game_libs);

            // use an immutable adventurer for assertions
            let immutable_adventurer = adventurer.clone();

            // assert action is valid
            _assert_not_dead(immutable_adventurer);
            _assert_in_battle(immutable_adventurer);

            // get weapon specials
            let weapon_specials = game_libs.get_specials(
                adventurer.equipment.weapon.id,
                adventurer.equipment.weapon.get_greatness(),
                adventurer.item_specials_seed,
            );

            // get previous entropy to fetch correct beast
            let adventurer_entropy = _load_adventurer_entropy(world, adventurer_id);
            
            // generate xp based randomness seeds
            let (
                beast_seed,
                _,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd,
                _,
                _,
            ) = ImplAdventurer::get_randomness(adventurer.xp, adventurer_entropy.beast_seed);
            
            // get beast based on entropy seeds
            let beast = ImplAdventurer::get_beast(
                adventurer.get_level(),
                game_libs.get_type(adventurer.equipment.weapon.id),
                beast_seed,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd,
            );
            
            // get weapon details
            let weapon = game_libs.get_item(adventurer.equipment.weapon.id);
            let weapon_combat_spec = CombatSpec {
                tier: weapon.tier,
                item_type: weapon.item_type,
                level: adventurer.equipment.weapon.get_greatness().into(),
                specials: weapon_specials,
            };
            
            let (level_seed, market_seed) = _get_random_seed(world, adventurer_id, adventurer.xp);

            _attack(
                ref adventurer,
                weapon_combat_spec,
                level_seed,
                beast,
                beast_seed,
                to_the_death,
                beast_level_rnd,
                game_libs,
            );

            // save state
            if (adventurer.stat_upgrades_available != 0) {
                _save_market_seed(ref world, adventurer_id, market_seed);
            }
            
            adventurer.increment_action_count();
            _save_adventurer(ref world, ref adventurer, adventurer_id, game_libs);
        }

        /// @title Flee Function
        ///
        /// @notice Allows an adventurer to flee from a beast
        ///
        /// @param adventurer_id A u256 representing the unique ID of the adventurer.
        /// @param to_the_death A boolean flag indicating if the flee attempt should continue until
        /// either the adventurer escapes or is defeated.
        fn flee(ref self: ContractState, adventurer_id: u64, to_the_death: bool) {
            self.assert_token_ownership(adventurer_id);

            let mut world: WorldStorage = self.world(@DEFAULT_NS());

            let token_metadata: TokenMetadata = world.read_model(adventurer_id);
            token_metadata.lifecycle.assert_is_playable(adventurer_id, starknet::get_block_timestamp());

            // get game libaries
            let game_libs = ImplGame::get_libs(world);

            // load player assets
            let mut adventurer = _load_adventurer(world, adventurer_id, game_libs);

            // use an immutable adventurer for assertions
            let immutable_adventurer = adventurer.clone();

            // assert action is valid
            _assert_not_dead(immutable_adventurer);
            _assert_in_battle(immutable_adventurer);
            _assert_not_starter_beast(immutable_adventurer, messages::CANT_FLEE_STARTER_BEAST);
            _assert_dexterity_not_zero(immutable_adventurer);

            // get previous entropy to fetch correct beast
            let adventurer_entropy = _load_adventurer_entropy(world, adventurer_id);

            // generate xp based randomness seeds
            let (beast_seed, _, beast_health_rnd, beast_level_rnd, beast_specials1_rnd, beast_specials2_rnd, _, _) =
                ImplAdventurer::get_randomness(
                adventurer.xp, adventurer_entropy.beast_seed,
            );

            // get beast based on entropy seeds
            let beast = ImplAdventurer::get_beast(
                adventurer.get_level(),
                game_libs.get_type(adventurer.equipment.weapon.id),
                beast_seed,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd,
            );

            // get random seed
            let (flee_seed, market_seed) = _get_random_seed(world, adventurer_id, adventurer.xp);

            // attempt to flee
            _flee(ref adventurer, flee_seed, beast_seed, beast, to_the_death, game_libs);

            // save state
            if (adventurer.stat_upgrades_available != 0) {
                _save_market_seed(ref world, adventurer_id, market_seed);
            }
            
            adventurer.increment_action_count();
            _save_adventurer(ref world, ref adventurer, adventurer_id, game_libs);
        }

        /// @title Equip Function
        ///
        /// @notice Allows an adventurer to equip items from their bag
        /// @player Calling this during battle will result in a beast counter-attack
        ///
        /// @param adventurer_id A u256 representing the unique ID of the adventurer.
        /// @param items A u8 array representing the item IDs to equip.
        fn equip(ref self: ContractState, adventurer_id: u64, items: Array<u8>) {
            self.assert_token_ownership(adventurer_id);

            let mut world: WorldStorage = self.world(@DEFAULT_NS());

            let token_metadata: TokenMetadata = world.read_model(adventurer_id);
            token_metadata.lifecycle.assert_is_playable(adventurer_id, starknet::get_block_timestamp());

            // get game libaries
            let game_libs = ImplGame::get_libs(world);

            // load player assets
            let mut adventurer = _load_adventurer(world, adventurer_id, game_libs);
            let mut bag = _load_bag(world, adventurer_id, game_libs);

            // assert action is valid
            _assert_not_dead(adventurer);
            assert(items.len() != 0, messages::NO_ITEMS);
            assert(items.len() <= 8, messages::TOO_MANY_ITEMS);

            // equip items and record the unequipped items for event
            let _unequipped_items = _equip_items(ref adventurer, ref bag, items.clone(), false, game_libs);

            // if the adventurer is equipping an item during battle, the beast will counter attack
            if (adventurer.in_battle()) {
                // get previous entropy to fetch correct beast
                let adventurer_entropy = _load_adventurer_entropy(world, adventurer_id);

                // generate xp based randomness seeds
                let (beast_seed, _, beast_health_rnd, beast_level_rnd, beast_specials1_rnd, beast_specials2_rnd, _, _) =
                    ImplAdventurer::get_randomness(
                    adventurer.xp, adventurer_entropy.beast_seed,
                );

                // get beast based on entropy seeds
                let beast = ImplAdventurer::get_beast(
                    adventurer.get_level(),
                    game_libs.get_type(adventurer.equipment.weapon.id),
                    beast_seed,
                    beast_health_rnd,
                    beast_level_rnd,
                    beast_specials1_rnd,
                    beast_specials2_rnd,
                );

                // get random seed
                let (seed, _) = _get_random_seed(world, adventurer_id, adventurer.xp);

                // get randomness for combat
                let (_, _, beast_crit_hit_rnd, attack_location_rnd) = ImplAdventurer::get_battle_randomness(
                    adventurer.xp, adventurer.action_count, seed,
                );

                // process beast attack
                let _beast_battle_details = _beast_attack(
                    ref adventurer,
                    beast,
                    beast_seed,
                    beast_crit_hit_rnd,
                    attack_location_rnd,
                    false,
                    game_libs,
                );
            }
            
            // save state
            adventurer.increment_action_count();
            _save_adventurer(ref world, ref adventurer, adventurer_id, game_libs);

            // if the bag was mutated, pack and save it
            if bag.mutated {
                _save_bag(ref world, adventurer_id, bag, game_libs);
            }
        }

        /// @title Drop Function
        ///
        /// @notice Allows an adventurer to drop equpped items or items from their bag
        ///
        /// @param adventurer_id A u256 representing the unique ID of the adventurer.
        /// @param items A u8 Array representing the IDs of the items to drop.
        fn drop(ref self: ContractState, adventurer_id: u64, items: Array<u8>) {
            self.assert_token_ownership(adventurer_id);

            let mut world: WorldStorage = self.world(@DEFAULT_NS());

            let token_metadata: TokenMetadata = world.read_model(adventurer_id);
            token_metadata.lifecycle.assert_is_playable(adventurer_id, starknet::get_block_timestamp());

            // get game libaries
            let game_libs = ImplGame::get_libs(world);

            // load player assets
            let mut adventurer = _load_adventurer(world, adventurer_id, game_libs);
            let mut bag = _load_bag(world, adventurer_id, game_libs);

            // assert action is valid (ownership of item is handled in internal function when we
            // iterate over items)
            _assert_not_dead(adventurer);
            assert(items.len() != 0, messages::NO_ITEMS);
            _assert_not_starter_beast(adventurer, messages::CANT_DROP_DURING_STARTER_BEAST);

            // drop items
            _drop(ref adventurer, ref bag, items.clone(), game_libs);

            // save state
            _save_adventurer(ref world, ref adventurer, adventurer_id, game_libs);

            // if the bag was mutated, save it
            if bag.mutated {
                _save_bag(ref world, adventurer_id, bag, game_libs);
            }
        }

        /// @title Upgrade Function
        ///
        /// @notice Allows an adventurer to upgrade their stats, purchase potions, and buy new
        /// items.
        ///
        /// @param adventurer_id A u256 representing the unique ID of the adventurer.
        /// @param potions A u8 representing the number of potions to purchase
        /// @param stat_upgrades A Stats struct detailing the upgrades the adventurer wants to apply
        /// to their stats.
        /// @param items An array of ItemPurchase detailing the items the adventurer wishes to
        /// purchase during the upgrade.
        fn level_up(
            ref self: ContractState, adventurer_id: u64, potions: u8, stat_upgrades: Stats, items: Array<ItemPurchase>,
        ) {
            self.assert_token_ownership(adventurer_id);

            let mut world: WorldStorage = self.world(@DEFAULT_NS());

            let token_metadata: TokenMetadata = world.read_model(adventurer_id);
            token_metadata.lifecycle.assert_is_playable(adventurer_id, starknet::get_block_timestamp());

            // get game libaries
            let game_libs = ImplGame::get_libs(world);

            // load player assets
            let mut adventurer = _load_adventurer(world, adventurer_id, game_libs);
            let mut bag = _load_bag(world, adventurer_id, game_libs);

            let immutable_adventurer = adventurer.clone();

            // assert action is valid
            _assert_not_dead(immutable_adventurer);
            _assert_not_in_battle(immutable_adventurer);
            _assert_valid_stat_selection(immutable_adventurer, stat_upgrades);

            // get number of stat upgrades available before we use them
            let pre_upgrade_stat_points = adventurer.stat_upgrades_available;

            // reset stat upgrades available
            adventurer.stat_upgrades_available = 0;

            // upgrade adventurer's stats
            adventurer.stats.apply_stats(stat_upgrades);

            // if adventurer upgraded vitality
            if stat_upgrades.vitality != 0 {
                // apply health boost
                adventurer.apply_vitality_health_boost(stat_upgrades.vitality);
            }

            // if the player is buying items, process purchases
            if (items.len() != 0) {
                let adventurer_entropy = _load_adventurer_entropy(world, adventurer_id);

                let (_purchases, _equipped_items, _unequipped_items) = _buy_items(
                    adventurer_entropy.market_seed, ref adventurer, ref bag, pre_upgrade_stat_points, items.clone(), game_libs,
                );
            }

            // if the player is buying potions as part of the upgrade, process purchase
            // @dev process potion purchase after items in case item purchases changes item stat
            // boosts
            if potions != 0 {
                _buy_potions(ref adventurer, potions);
            }

            // if the upgrade mutated the adventurer's bag
            if bag.mutated {
                _save_bag(ref world, adventurer_id, bag, game_libs);
            }

            adventurer.increment_action_count();
            _save_adventurer(ref world, ref adventurer, adventurer_id, game_libs);
        }

        /// @title Set Adventurer Obituary
        /// @notice Allows an adventurer to set their obituary.
        /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
        /// @param obituary A ByteArray representing the obituary of the adventurer.
        fn set_adventurer_obituary(ref self: ContractState, adventurer_id: u64, obituary: ByteArray) {
            self.assert_token_ownership(adventurer_id);

            let mut world: WorldStorage = self.world(@DEFAULT_NS());

            // asset adventurer is dead
            let adventurer = _load_adventurer_no_boosts(world, adventurer_id);
            _assert_is_dead(adventurer);

            let mut adventurer_obituary: AdventurerObituary = world.read_model(adventurer_id);

            // assert obituary has not already been set
            assert(adventurer_obituary.obituary.len() != 0, messages::OBITUARY_ALREADY_SET);

            // set adventurer obituary
            adventurer_obituary.obituary = obituary;
            world.write_model(@adventurer_obituary);
        }

        // ------------------------------------------ //
        // ------------ View Functions -------------- //
        // ------------------------------------------ //
        fn get_adventurer(self: @ContractState, adventurer_id: u64) -> Adventurer {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let game_libs = ImplGame::get_libs(world);
            _load_adventurer(world, adventurer_id, game_libs)
        }

        fn get_adventurer_obituary(self: @ContractState, adventurer_id: u64) -> ByteArray {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let adventurer_obituary: AdventurerObituary = world.read_model(adventurer_id);
            adventurer_obituary.obituary
        }

        fn get_adventurer_name(self: @ContractState, adventurer_id: u64) -> felt252 {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let token_metadata: TokenMetadata = world.read_model(adventurer_id);
            token_metadata.player_name
        }

        fn get_item_specials(self: @ContractState, adventurer_id: u64) -> Array<ItemSpecial> {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let game_libs = ImplGame::get_libs(world);
            let adventurer: Adventurer = _load_adventurer(world, adventurer_id, game_libs);
            let specials_seed = adventurer.item_specials_seed;

            // assert specials seed is not 0
            assert(specials_seed != 0, messages::ITEM_SPECIALS_UNAVAILABLE);

            let mut item_specials: Array<ItemSpecial> = ArrayTrait::<ItemSpecial>::new();
            let mut item_id = 1;
            loop {
                if item_id > 101 {
                    break;
                }

                let special_power = SpecialPowers {
                    special1: game_libs.get_suffix(item_id, specials_seed),
                    special2: game_libs.get_prefix1(item_id, specials_seed),
                    special3: game_libs.get_prefix2(item_id, specials_seed),
                };
                item_specials.append(ItemSpecial { item_id, special_power });

                item_id += 1;
            };

            item_specials
        }

        fn get_adventurer_no_boosts(self: @ContractState, adventurer_id: u64) -> Adventurer {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            _load_adventurer_no_boosts(world, adventurer_id)
        }

        fn get_bag(self: @ContractState, adventurer_id: u64) -> Bag {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let game_libs = ImplGame::get_libs(world);
            _load_bag(world, adventurer_id, game_libs)
        }

        fn get_market(self: @ContractState, adventurer_id: u64) -> Array<u8> {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let game_libs = ImplGame::get_libs(world);
            let adventurer = _load_adventurer(world, adventurer_id, game_libs);
            let adventurer_entropy = _load_adventurer_entropy(world, adventurer_id);
            _get_market(adventurer_entropy.market_seed, adventurer.stat_upgrades_available, game_libs)
        }

        fn get_potion_price(self: @ContractState, adventurer_id: u64) -> u16 {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let game_libs = ImplGame::get_libs(world);
            let adventurer = _load_adventurer(world, adventurer_id, game_libs);
            adventurer.charisma_adjusted_potion_price()
        }

        fn get_item_price(self: @ContractState, adventurer_id: u64, item_id: u8) -> u16 {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let game_libs = ImplGame::get_libs(world);
            let adventurer = _load_adventurer(world, adventurer_id, game_libs);
            let base_item_price = game_libs.get_price(game_libs.get_tier(item_id));
            adventurer.stats.charisma_adjusted_item_price(base_item_price)
        }

        fn get_attacking_beast(self: @ContractState, adventurer_id: u64) -> Beast {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            _get_attacking_beast(world, adventurer_id)
        }

        fn obstacle_critical_hit_chance(self: @ContractState, adventurer_id: u64) -> u8 {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let game_libs = ImplGame::get_libs(world);
            let adventurer = _load_adventurer(world, adventurer_id, game_libs);
            ImplAdventurer::get_dynamic_critical_hit_chance(adventurer.get_level())
        }

        fn beast_critical_hit_chance(self: @ContractState, adventurer_id: u64, is_ambush: bool) -> u8 {
            let world: WorldStorage = self.world(@DEFAULT_NS());
            let game_libs = ImplGame::get_libs(world);
            let adventurer = _load_adventurer(world, adventurer_id, game_libs);
            ImplBeast::get_critical_hit_chance(adventurer.get_level(), is_ambush)
        }
    }

    /// @title Reveal Starting Stats
    /// @notice Reveals and applies starting stats to the adventurer.
    /// @param adventurer A reference to the Adventurer object.
    /// @param seed A u64 representing the seed for the adventurer.
    fn reveal_starting_stats(ref adventurer: Adventurer, seed: u64) {
        // reveal and apply starting stats
        adventurer.stats = ImplStats::generate_starting_stats(seed);

        // increase adventurer's health for any vitality they received
        adventurer.health += adventurer.stats.get_max_health() - STARTING_HEALTH.into();
    }

    /// @title Process Beast Death
    /// @notice Processes the death of a beast and emits an event.
    /// @dev This function is called when a beast is slain.
    /// @param adventurer A reference to the adventurer.
    /// @param beast A reference to the Beast object.
    /// @param beast_seed A u128 representing the seed of the beast.
    /// @param damage_dealt A u16 representing the damage dealt to the beast.
    /// @param critical_hit A boolean representing whether the attack was a critical hit.
    fn _process_beast_death(
        ref adventurer: Adventurer,
        beast: Beast,
        beast_seed: u32,
        damage_dealt: u16,
        critical_hit: bool,
        item_specials_rnd: u16,
        level_seed: u64,
        game_libs: GameLibs,
    ) {
        // zero out beast health
        adventurer.beast_health = 0;

        // get gold reward and increase adventurers gold
        let gold_earned = beast.get_gold_reward();
        let ring_bonus = adventurer.equipment.ring.jewelry_gold_bonus(gold_earned);
        adventurer.increase_gold(gold_earned + ring_bonus);

        // get xp reward and increase adventurers xp
        let xp_earned_adventurer = beast.get_xp_reward(adventurer.get_level());
        let (_previous_level, _new_level) = adventurer.increase_adventurer_xp(xp_earned_adventurer);

        // items use adventurer xp with an item multplier so they level faster than Adventurer
        let xp_earned_items = xp_earned_adventurer * ITEM_XP_MULTIPLIER_BEASTS.into();
        // assigning xp to items is more complex so we delegate to an internal function
        let _items_leveled_up = _grant_xp_to_equipped_items(ref adventurer, xp_earned_items, item_specials_rnd, game_libs);

        // Reveal starting stats if adventurer is on level 1
        if (adventurer.get_level() == 1) {
            reveal_starting_stats(ref adventurer, level_seed);
        }

        // // if beast beast level is above collectible threshold
        // if beast.combat_spec.level >= BEAST_SPECIAL_NAME_LEVEL_UNLOCK.into() && _network_supports_vrf() {
        //     // mint beast to owner of the adventurer or controller delegate if set
        //     _mint_beast(@self, beast, get_caller_address());
        // }
    }

    /// @title Mint Beast
    /// @notice Mints a beast and emits an event.
    /// @dev This function is called when a beast is slain.
    /// @param self A reference to the ContractState object.
    /// @param beast A reference to the Beast object.
    /// @param to_address A ContractAddress representing the address to mint the beast to.
    // fn _mint_beast(self: @ContractState, beast: Beast, to_address: ContractAddress) {
    //     let beasts_dispatcher = self._beasts_dispatcher.read();

    //     let is_beast_minted = beasts_dispatcher
    //         .isMinted(beast.id, beast.combat_spec.specials.special2, beast.combat_spec.specials.special3);

    //     let beasts_minter = beasts_dispatcher.getMinter();

    //     if !is_beast_minted && beasts_minter == starknet::get_contract_address() {
    //         beasts_dispatcher
    //             .mint(
    //                 to_address,
    //                 beast.id,
    //                 beast.combat_spec.specials.special2,
    //                 beast.combat_spec.specials.special3,
    //                 beast.combat_spec.level,
    //                 beast.starting_health,
    //             );
    //     }
    // }


    /// @title Starter Beast Ambush
    /// @notice Simulates a beast ambush for the adventurer and returns the battle details.
    /// @dev This function simulates a beast ambush for the adventurer and returns the battle
    /// details.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param starting_weapon A u8 representing the starting weapon for the adventurer.
    /// @return BattleDetails The battle details for the ambush.
    fn _starter_beast_ambush(ref adventurer: Adventurer, adventurer_id: u64, starting_weapon: u8, game_libs: GameLibs) -> BattleDetails {
        // starter beast will always be weak against starter weapon so we don't need to
        // expend a lot of resources to generate strong entropy. Instead just downres
        // the adventurer id to u32 and use that for beast seed
        let beast_seed = (adventurer_id % TWO_POW_32.into()).try_into().unwrap();

        // generate starter beast which will have weak armor against the adventurers starter weapon
        let starter_beast = ImplBeast::get_starter_beast(game_libs.get_type(starting_weapon), beast_seed);

        // spoof a beast ambush by deducting health from the adventurer
        adventurer.decrease_health(STARTER_BEAST_ATTACK_DAMAGE);

        // return battle details
        BattleDetails {
            seed: beast_seed,
            id: starter_beast.id,
            beast_specs: starter_beast.combat_spec,
            damage: STARTER_BEAST_ATTACK_DAMAGE,
            critical_hit: false,
            location: 2,
        }
    }

    /// @title Explore
    /// @notice Allows the adventurer to explore the world and encounter beasts, obstacles, or
    /// discoveries.
    /// @dev This function is called when the adventurer explores the world.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param explore_results A reference to the array of explore results.
    /// @param seed A felt252 representing the entropy for the adventurer.
    /// @param explore_till_beast A bool representing whether to explore until a beast is
    /// encountered.
    fn _explore(
        ref world: WorldStorage,
        ref adventurer: Adventurer,
        ref bag: Bag,
        ref explore_results: Array<ExploreResult>,
        adventurer_id: u64,
        explore_seed: u64,
        explore_till_beast: bool,
        game_libs: GameLibs,
    ) {
        let (rnd1_u32, _, rnd3_u16, rnd4_u16, rnd5_u8, rnd6_u8, rnd7_u8, explore_rnd) = ImplAdventurer::get_randomness(
            adventurer.xp, explore_seed,
        );

        // go exploring
        let explore_result = ImplAdventurer::get_random_explore(explore_rnd);
        explore_results.append(explore_result);
        match explore_result {
            ExploreResult::Beast(()) => {
                _beast_encounter(
                    ref adventurer,
                    seed: rnd1_u32,
                    health_rnd: rnd3_u16,
                    level_rnd: rnd4_u16,
                    dmg_location_rnd: rnd5_u8,
                    crit_hit_rnd: rnd6_u8,
                    ambush_rnd: rnd7_u8,
                    specials1_rnd: rnd5_u8, // use same entropy for crit hit, initial attack location, and beast specials
                    specials2_rnd: rnd6_u8, // to create some fun organic lore for the beast special names
                    game_libs: game_libs,
                );
                // save seed to get correct beast
                _save_beast_seed(ref world, adventurer_id, explore_seed);
            },
            ExploreResult::Obstacle(()) => {
                _obstacle_encounter(
                    ref adventurer,
                    seed: rnd1_u32,
                    level_rnd: rnd4_u16,
                    dmg_location_rnd: rnd5_u8,
                    crit_hit_rnd: rnd6_u8,
                    dodge_rnd: rnd7_u8,
                    item_specials_rnd: rnd3_u16,
                    game_libs: game_libs,
                );
            },
            ExploreResult::Discovery(()) => {
                _process_discovery(
                    ref adventurer, ref bag, discovery_type_rnd: rnd5_u8, amount_rnd1: rnd6_u8, amount_rnd2: rnd7_u8, game_libs: game_libs,
                );
            },
        }

        // if explore_till_beast is true and adventurer can still explore
        if explore_till_beast && adventurer.can_explore() {
            // Keep exploring
            _explore(ref world, ref adventurer, ref bag, ref explore_results, adventurer_id, explore_seed, explore_till_beast, game_libs);
        }
    }

    /// @title Process Discovery
    /// @notice Processes the discovery for the adventurer and emits an event.
    /// @dev This function is called when the adventurer discovers something.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param entropy A u128 representing the entropy for the adventurer.
    fn _process_discovery(
        ref adventurer: Adventurer, ref bag: Bag, discovery_type_rnd: u8, amount_rnd1: u8, amount_rnd2: u8, game_libs: GameLibs,
    ) {
        // get discovery type
        let discovery_type = ImplAdventurer::get_discovery(
            adventurer.get_level(), discovery_type_rnd, amount_rnd1, amount_rnd2,
        );

        // Grant adventurer XP to progress entropy
        let (_previous_level, _new_level) = adventurer.increase_adventurer_xp(XP_FOR_DISCOVERIES.into());

        // handle discovery type
        match discovery_type {
            DiscoveryType::Gold(amount) => { adventurer.increase_gold(amount); },
            DiscoveryType::Health(amount) => { adventurer.increase_health(amount); },
            DiscoveryType::Loot(item_id) => {
                let (item_in_bag, _) = game_libs.bag_contains(bag, item_id);

                let slot = game_libs.get_slot(item_id);
                let slot_free = adventurer.equipment.is_slot_free_item_id(item_id, slot);

                // if the bag is full and the slot is not free
                let inventory_full = game_libs.is_bag_full(bag) && slot_free == false;

                // if item is in adventurers bag, is equipped or inventory is full
                if item_in_bag || adventurer.equipment.is_equipped(item_id) || inventory_full {
                    // we replace item discovery with gold based on market value of the item
                    let mut amount = 0;
                    match game_libs.get_tier(item_id) {
                        Tier::None(()) => panic_with_felt252('found invalid item'),
                        Tier::T1(()) => amount = 20,
                        Tier::T2(()) => amount = 16,
                        Tier::T3(()) => amount = 12,
                        Tier::T4(()) => amount = 8,
                        Tier::T5(()) => amount = 4,
                    }
                    adventurer.increase_gold(amount);
                    // if the item is not already owned or equipped and the adventurer has space for it
                } else {
                    // no items will be dropped as part of discovery
                    let _dropped_items = ArrayTrait::<u8>::new();
                    let mut equipped_items = ArrayTrait::<u8>::new();
                    let mut bagged_items = ArrayTrait::<u8>::new();

                    let item = ImplItem::new(item_id);
                    if slot_free {
                        // equip the item
                        let slot = game_libs.get_slot(item.id);
                        adventurer.equipment.equip(item, slot);
                        equipped_items.append(item.id);
                    } else {
                        // otherwise toss it in bag
                        bag = game_libs.add_item_to_bag(bag, item);
                        bagged_items.append(item.id);
                    }
                }
            },
        }
    }

    /// @title Beast Encounter
    /// @notice Handles the encounter with a beast and returns the battle details.
    /// @dev This function is called when the adventurer encounters a beast.
    /// @param adventurer A reference to the adventurer.
    /// @param seed A u32 representing the seed for the beast.
    /// @param beast_health_rnd A u32 representing the random health for the beast.
    /// @param beast_level_rnd A u32 representing the random level for the beast.
    /// @param beast_specials_rnd A u32 representing the random specials for the beast.
    /// @param ambush_rnd A u32 representing the random ambush for the beast.
    /// @param critical_hit_rnd A u32 representing the random critical hit for the beast.
    fn _beast_encounter(
        ref adventurer: Adventurer,
        seed: u32,
        health_rnd: u16,
        level_rnd: u16,
        dmg_location_rnd: u8,
        crit_hit_rnd: u8,
        ambush_rnd: u8,
        specials1_rnd: u8,
        specials2_rnd: u8,
        game_libs: GameLibs,
    ) {
        let adventurer_level = adventurer.get_level();

        let beast = ImplAdventurer::get_beast(
            adventurer.get_level(),
            game_libs.get_type(adventurer.equipment.weapon.id),
            seed,
            health_rnd,
            level_rnd,
            specials1_rnd,
            specials2_rnd,
        );

        // init beast health on adventurer
        // @dev: this is only info about beast that we store onchain
        adventurer.beast_health = beast.starting_health;

        // check if beast ambushed adventurer
        let is_ambush = ImplAdventurer::is_ambushed(adventurer_level, adventurer.stats.wisdom, ambush_rnd);

        // if adventurer was ambushed
        if (is_ambush) {
            // process beast attack
            let _beast_battle_details = _beast_attack(
                ref adventurer, beast, seed, crit_hit_rnd, dmg_location_rnd, is_ambush, game_libs,
            );
            if (adventurer.health == 0) {
                return;
            }
        }
    }

    /// @title Obstacle Encounter
    /// @notice Handles the encounter with an obstacle and returns the battle details.
    /// @dev This function is called when the adventurer encounters an obstacle.
    /// @param adventurer A reference to the adventurer.
    /// @param seed A u32 representing the entropy for the adventurer.
    fn _obstacle_encounter(
        ref adventurer: Adventurer,
        seed: u32,
        level_rnd: u16,
        dmg_location_rnd: u8,
        crit_hit_rnd: u8,
        dodge_rnd: u8,
        item_specials_rnd: u16,
        game_libs: GameLibs,
    ) {
        // get adventurer's level
        let adventurer_level = adventurer.get_level();

        // get random obstacle
        let obstacle = ImplAdventurer::get_random_obstacle(adventurer_level, seed, level_rnd);

        // get a random attack location for the obstacle
        let damage_slot = ImplAdventurer::get_attack_location(dmg_location_rnd);

        // get armor at the location being attacked
        let armor = adventurer.equipment.get_item_at_slot(damage_slot);
        let armor_details = game_libs.get_item(armor.id);

        // get damage from obstalce
        let (combat_result, _) = adventurer.get_obstacle_damage(obstacle, armor, armor_details, crit_hit_rnd);

        // pull damage taken out of combat result for easy access
        let damage_taken = combat_result.total_damage;

        // get base xp reward for obstacle
        let base_reward = obstacle.get_xp_reward(adventurer_level);

        // get item xp reward for obstacle
        let item_xp_reward = base_reward * ITEM_XP_MULTIPLIER_OBSTACLES.into();

        // create obstacle details for event
        let _obstacle_details = ObstacleDetails {
            id: obstacle.id,
            level: obstacle.combat_spec.level,
            damage_taken,
            damage_location: ImplCombat::slot_to_u8(damage_slot),
            critical_hit: combat_result.critical_hit_bonus > 0,
            adventurer_xp_reward: base_reward,
            item_xp_reward,
        };

        // attempt to dodge obstacle
        let dodged = ImplCombat::ability_based_avoid_threat(adventurer_level, adventurer.stats.intelligence, dodge_rnd);

        // if adventurer did not dodge obstacle
        if (!dodged) {
            // adventurer takes damage
            adventurer.decrease_health(damage_taken);

            // if adventurer died
            if (adventurer.health == 0) {
                return;
            }
        }

        // grant adventurer xp and get previous and new level
        let (_previous_level, _new_level) = adventurer.increase_adventurer_xp(base_reward);

        // grant items xp and get array of items that leveled up
        let _items_leveled_up = _grant_xp_to_equipped_items(ref adventurer, item_xp_reward, item_specials_rnd, game_libs);
    }

    // @notice Grants XP to items currently equipped by an adventurer, and processes any level
    // ups.//
    // @dev This function does three main things:
    //   1. Iterates through each of the equipped items for the given adventurer.
    //   2. Increases the XP for the equipped item. If the item levels up, it processes the level up
    //   and updates the item.
    //   3. If any items have leveled up, emits an `ItemsLeveledUp` event.//
    // @param adventurer Reference to the adventurer's state.
    // @param xp_amount Amount of XP to grant to each equipped item.
    // @return Array of items that leveled up.
    fn _grant_xp_to_equipped_items(
        ref adventurer: Adventurer,
        xp_amount: u16,
        item_specials_rnd: u16,
        game_libs: GameLibs,
    ) -> Array<ItemLeveledUp> {
        let mut items_leveled_up = ArrayTrait::<ItemLeveledUp>::new();
        let equipped_items = adventurer.get_equipped_items();
        let mut item_index: u32 = 0;
        loop {
            if item_index == equipped_items.len() {
                break;
            }
            // get item
            let item = *equipped_items.at(item_index);

            // get item slot
            let item_slot = game_libs.get_slot(item.id);

            // increase item xp and record previous and new level
            let (previous_level, new_level) = adventurer.equipment.increase_item_xp_at_slot(item_slot, xp_amount);

            // if item leveled up
            if new_level > previous_level {
                // process level up
                let updated_item = _process_item_level_up(
                    ref adventurer,
                    adventurer.equipment.get_item_at_slot(item_slot),
                    previous_level,
                    new_level,
                    item_specials_rnd,
                    game_libs,
                );

                // add item to list of items that leveled up to be emitted in event
                items_leveled_up.append(updated_item);
            }

            item_index += 1;
        };

        items_leveled_up
    }

    /// @title Process Item Level Up
    /// @notice Processes the level up for an item and returns the updated item.
    /// @dev This function is called when an item levels up.
    /// @param adventurer A reference to the adventurer.
    /// @param item A reference to the item.
    /// @param previous_level A u8 representing the previous level of the item.
    /// @param new_level A u8 representing the new level of the item.
    /// @return ItemLeveledUp The updated item.
    fn _process_item_level_up(
        ref adventurer: Adventurer, item: Item, previous_level: u8, new_level: u8, item_specials_rnd: u16, game_libs: GameLibs,
    ) -> ItemLeveledUp {
        // if item reached max greatness level
        if (new_level == ITEM_MAX_GREATNESS) {
            // adventurer receives a bonus stat upgrade point
            adventurer.increase_stat_upgrades_available(MAX_GREATNESS_STAT_BONUS);
        }

        // check if item unlocked specials as part of level up
        let (suffix_unlocked, prefixes_unlocked) = ImplAdventurer::unlocked_specials(previous_level, new_level);

        // get item specials seed
        let item_specials_seed = adventurer.item_specials_seed;
        let specials = if item_specials_seed != 0 {
            game_libs.get_specials(item.id, item.get_greatness(), item_specials_seed)
        } else {
            SpecialPowers { special1: 0, special2: 0, special3: 0 }
        };

        // if specials were unlocked
        if (suffix_unlocked || prefixes_unlocked) {
            // check if we already have the vrf seed for the item specials
            if item_specials_seed != 0 {
                // if suffix was unlocked, apply stat boosts for suffix special to adventurer
                if suffix_unlocked {
                    // apply stat boosts for suffix special to adventurer
                    adventurer.stats.apply_suffix_boost(specials.special1);
                    // apply health boost for any vitality gained (one time event)
                    adventurer.apply_health_boost_from_vitality_unlock(specials);
                }
            } else {
                adventurer.item_specials_seed = item_specials_rnd;

                // get specials for the item
                let specials = game_libs.get_specials(item.id, item.get_greatness(), adventurer.item_specials_seed);

                // if suffix was unlocked, apply stat boosts for suffix special to
                // adventurer
                if suffix_unlocked {
                    // apply stat boosts for suffix special to adventurer
                    adventurer.stats.apply_suffix_boost(specials.special1);
                    // apply health boost for any vitality gained (one time event)
                    adventurer.apply_health_boost_from_vitality_unlock(specials);
                }
            }
        }

        ItemLeveledUp { item_id: item.id, previous_level, new_level, suffix_unlocked, prefixes_unlocked, specials }
    }

    fn _network_supports_vrf() -> bool {
        let chain_id = get_tx_info().unbox().chain_id;
        VRF_ENABLED && (chain_id == MAINNET_CHAIN_ID || chain_id == SEPOLIA_CHAIN_ID)
    }

    /// @notice Executes an adventurer's attack on a beast and manages the consequences of the
    /// combat @dev This function covers the entire combat process between an adventurer and a
    /// beast, including generating randomness for combat, handling the aftermath of the attack, and
    /// any subsequent counter-attacks by the beast.
    /// @param adventurer The attacking adventurer
    /// @param weapon_combat_spec The combat specifications of the adventurer's weapon
    /// @param seed A random value tied to the adventurer to aid in determining certain random
    /// aspects of the combat @param beast The defending beast
    /// @param beast_seed The seed associated with the beast
    /// @param fight_to_the_death Flag to indicate whether the adventurer should continue attacking
    /// until either they or the beast is defeated
    fn _attack(
        ref adventurer: Adventurer,
        weapon_combat_spec: CombatSpec,
        level_seed: u64,
        beast: Beast,
        beast_seed: u32,
        fight_to_the_death: bool,
        item_specials_seed: u16,
        game_libs: GameLibs,
    ) {
        // get randomness for combat
        let (_, adventurer_crit_hit_rnd, beast_crit_hit_rnd, attack_location_rnd) =
            ImplAdventurer::get_battle_randomness(
            adventurer.xp, adventurer.action_count, level_seed,
        );

        // increment battle action count (ensures each battle action has unique randomness)
        adventurer.increment_action_count();

        // attack beast and get combat result that provides damage breakdown
        let combat_result = adventurer.attack(weapon_combat_spec, beast, adventurer_crit_hit_rnd);

        // provide critical hit as a boolean for events
        let is_critical_hit = combat_result.critical_hit_bonus > 0;

        // if the damage dealt exceeds the beasts health
        if (combat_result.total_damage >= adventurer.beast_health) {
            // process beast death
            _process_beast_death(
                ref adventurer,
                beast,
                beast_seed,
                combat_result.total_damage,
                is_critical_hit,
                item_specials_seed,
                level_seed,
                game_libs,
            );
        } else {
            // if beast survived the attack, deduct damage dealt
            adventurer.beast_health -= combat_result.total_damage;

            // process beast counter attack
            let _attacked_by_beast_details = _beast_attack(
                ref adventurer,
                beast,
                beast_seed,
                beast_crit_hit_rnd,
                attack_location_rnd,
                false,
                game_libs,
            );

            // if adventurer is dead
            if (adventurer.health == 0) {
                return;
            }

            // if the adventurer is still alive and fighting to the death
            if fight_to_the_death {
                // attack again
                _attack(
                    ref adventurer,
                    weapon_combat_spec,
                    level_seed,
                    beast,
                    beast_seed,
                    true,
                    item_specials_seed,
                    game_libs,
                );
            }
        }
    }

    /// @title Beast Attack (Internal)
    /// @notice Handles attacks by a beast on an adventurer
    /// @dev This function determines a random attack location on the adventurer, retrieves armor
    /// and specials from that location, processes the beast attack, and deducts the damage from the
    /// adventurer's health.
    /// @param adventurer The adventurer being attacked
    /// @param beast The beast that is attacking
    /// @param beast_seed The seed associated with the beast
    /// @param critical_hit_rnd A random value used to determine whether a critical hit was made
    /// @return Returns a BattleDetails object containing details of the beast's attack, including
    /// the seed, beast ID, combat specifications of the beast, total damage dealt, whether a
    /// critical hit was made, and the location of the attack on the adventurer.
    fn _beast_attack(
        ref adventurer: Adventurer,
        beast: Beast,
        beast_seed: u32,
        critical_hit_rnd: u8,
        attack_location_rnd: u8,
        is_ambush: bool,
        game_libs: GameLibs,
    ) -> BattleDetails {
        // beasts attack random location on adventurer
        let attack_location = ImplAdventurer::get_attack_location(attack_location_rnd);

        // get armor at attack location
        let armor = adventurer.equipment.get_item_at_slot(attack_location);

        // get armor specials
        let armor_specials = game_libs.get_specials(armor.id, armor.get_greatness(), adventurer.item_specials_seed);
        let armor_details = game_libs.get_item(armor.id);

        // process beast attack
        let (combat_result, _jewlery_armor_bonus) = adventurer
            .defend(beast, armor, armor_specials, armor_details, critical_hit_rnd, is_ambush);

        // deduct damage taken from adventurer's health
        adventurer.decrease_health(combat_result.total_damage);

        // return beast battle details
        BattleDetails {
            seed: beast_seed,
            id: beast.id,
            beast_specs: beast.combat_spec,
            damage: combat_result.total_damage,
            critical_hit: combat_result.critical_hit_bonus > 0,
            location: ImplCombat::slot_to_u8(attack_location),
        }
    }

    /// @title Flee
    /// @notice Handles an attempt by the adventurer to flee from a battle with a beast.
    /// @dev This function is called when the adventurer attempts to flee from a battle with a
    /// beast.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param level_seed A felt252 representing the entropy for the adventurer.
    /// @param beast_seed A u32 representing the seed for the beast.
    /// @param beast A reference to the beast that the adventurer is attempting to flee from.
    /// @param flee_to_the_death A bool representing whether to flee until death.
    fn _flee(
        ref adventurer: Adventurer,
        flee_seed: u64,
        beast_seed: u32,
        beast: Beast,
        flee_to_the_death: bool,
        game_libs: GameLibs,
    ) {
        // get randomness for flee and ambush
        let (flee_rnd, _, beast_crit_hit_rnd, attack_location_rnd) = ImplAdventurer::get_battle_randomness(
            adventurer.xp, adventurer.action_count, flee_seed,
        );

        // increment action count (ensures each battle action has unique randomness)
        adventurer.increment_action_count();

        // attempt to flee
        let fled = ImplBeast::attempt_flee(adventurer.get_level(), adventurer.stats.dexterity, flee_rnd);

        // if adventurer fled
        if (fled) {
            // set beast health to zero to denote adventurer is no longer in battle
            adventurer.beast_health = 0;

            // increment adventurer xp by one to change adventurer entropy state
            let (_previous_level, _new_level) = adventurer.increase_adventurer_xp(1);
        } else {
            // if the flee attempt failed, beast counter attacks
            let _beast_battle_details = _beast_attack(
                ref adventurer,
                beast,
                beast_seed,
                beast_crit_hit_rnd,
                attack_location_rnd,
                false,
                game_libs,
            );

            // if player is still alive and elected to flee till death
            if (flee_to_the_death && adventurer.health != 0) {
                // reattempt flee
                _flee(ref adventurer, flee_seed, beast_seed, beast, true, game_libs);
            }
        }
    }

    /// @title Equip Item
    /// @notice Equips a specific item to the adventurer, and if there's an item already equipped in
    /// that slot, it's moved to the bag.
    /// @dev This function is called when an item is equipped to the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param item The primitive item to be equipped.
    /// @return The ID of the item that has been unequipped.
    fn _equip_item(
        ref adventurer: Adventurer, ref bag: Bag, item: Item, game_libs: GameLibs,
    ) -> u8 {
        // get the item currently equipped to the slot the item is being equipped to
        let unequipping_item = adventurer.equipment.get_item_at_slot(game_libs.get_slot(item.id));

        // if the item exists
        if unequipping_item.id != 0 {
            // put it into the adventurer's bag
            bag = game_libs.add_item_to_bag(bag, unequipping_item);

            // if the item was providing a stat boosts, remove it
            if unequipping_item.get_greatness() >= SUFFIX_UNLOCK_GREATNESS {
                _remove_item_stat_boost(ref adventurer, unequipping_item, game_libs);
            }
        }

        // equip item
        let slot = game_libs.get_slot(item.id);
        adventurer.equipment.equip(item, slot);

        // if item being equipped has stat boosts unlocked, apply it to adventurer
        if item.get_greatness() >= SUFFIX_UNLOCK_GREATNESS {
            _apply_item_stat_boost(ref adventurer, item, game_libs);
        }

        // return the item being unequipped for events
        unequipping_item.id
    }

    /// @title Equip Items
    /// @notice Equips items to the adventurer and returns the items that were unequipped as a
    /// result.
    /// @dev This function is called when items are equipped to the adventurer.
    /// @param contract_state A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param items_to_equip An array of u8 representing the items to be equipped.
    /// @param is_newly_purchased A bool representing whether the items are newly purchased.
    /// @return An array of u8 representing the items that were unequipped as a result of equipping
    /// the items.
    fn _equip_items(
        ref adventurer: Adventurer,
        ref bag: Bag,
        items_to_equip: Array<u8>,
        is_newly_purchased: bool,
        game_libs: GameLibs,
    ) -> Array<u8> {
        // mutable array from returning items that were unequipped as a result of equipping the
        // items
        let mut unequipped_items = ArrayTrait::<u8>::new();

        // get a clone of our items to equip to keep ownership for event
        let _equipped_items = items_to_equip.clone();

        // for each item we need to equip
        let mut i: u32 = 0;
        loop {
            if i == items_to_equip.len() {
                break ();
            }

            // get the item id
            let item_id = *items_to_equip.at(i);

            // assume we won't need to unequip an item to equip new one
            let mut unequipped_item_id: u8 = 0;

            // if item is newly purchased
            if is_newly_purchased {
                // assert adventurer does not already own the item
                _assert_item_not_owned(adventurer, bag, item_id.clone(), game_libs);

                // create new item, equip it, and record if we need unequipped an item
                let mut new_item = ImplItem::new(item_id);
                unequipped_item_id = _equip_item(ref adventurer, ref bag, new_item, game_libs);
            } else {
                // otherwise item is being equipped from bag
                // so remove it from bag, equip it, and record if we need to unequip an item
                let (new_bag, item) = game_libs.remove_item_from_bag(bag, item_id);
                bag = new_bag;
                unequipped_item_id = _equip_item(ref adventurer, ref bag, item, game_libs);
            }

            // if an item was unequipped
            if unequipped_item_id != 0 {
                // add it to our return array so we can emit these in events
                unequipped_items.append(unequipped_item_id);
            }

            i += 1;
        };

        unequipped_items
    }

    /// @title Drop Items
    /// @notice Drops multiple items from the adventurer's possessions, either from equipment or
    /// bag.
    /// @dev This function is called when items are dropped from the adventurer's possessions.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param items An array of u8 representing the items to be dropped.
    /// @return A tuple containing two boolean values. The first indicates if the adventurer was
    /// mutated, the second indicates if the bag was mutated.
    fn _drop(ref adventurer: Adventurer, ref bag: Bag, items: Array<u8>, game_libs: GameLibs) {
        // for each item
        let mut i: u32 = 0;
        loop {
            if i == items.len() {
                break ();
            }

            // init a blank item to use for dropped item storage
            let mut item = ImplItem::new(0);

            // get item id
            let item_id = *items.at(i);

            // if item is equipped
            if adventurer.equipment.is_equipped(item_id) {
                // get it from adventurer equipment
                item = adventurer.equipment.get_item(item_id);

                // if the item was providing a stat boosts
                if item.get_greatness() >= SUFFIX_UNLOCK_GREATNESS {
                    // remove it
                    _remove_item_stat_boost(ref adventurer, item, game_libs);
                }

                // drop the item
                adventurer.equipment.drop(item_id);
            } else {
                // if item is not equipped, it must be in the bag
                // but we double check and panic just in case
                let (item_in_bag, _) = game_libs.bag_contains(bag, item_id);
                if item_in_bag {
                    // get item from the bag
                    item = game_libs.get_bag_item(bag, item_id);

                    // remove item from the bag (sets mutated to true)
                    let (new_bag, _) = game_libs.remove_item_from_bag(bag, item_id);
                    bag = new_bag;
                } else {
                    panic_with_felt252('Item not owned by adventurer');
                }
            }

            i += 1;
        };
    }

    /// @title Buy Items
    /// @notice Facilitates the purchase of multiple items and returns the items that were
    /// purchased, equipped, and unequipped.
    /// @dev This function is called when the adventurer purchases items.
    /// @param seed A felt252 representing the seed for the market.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param stat_upgrades_available A u8 representing the number of stat points available to the
    /// adventurer.
    /// @param items_to_purchase An array of ItemPurchase representing the items to be purchased.
    /// @return A tuple containing three arrays: the first contains the items purchased, the second
    /// contains the items that were equipped as part of the purchase, and the third contains the
    /// items that were unequipped as a result of equipping the newly purchased items.
    fn _buy_items(
        market_seed: u64,
        ref adventurer: Adventurer,
        ref bag: Bag,
        stat_upgrades_available: u8,
        items_to_purchase: Array<ItemPurchase>,
        game_libs: GameLibs,
    ) -> (Array<LootWithPrice>, Array<u8>, Array<u8>) {
        // get adventurer entropy
        let market_inventory = _get_market(market_seed, stat_upgrades_available, game_libs);

        // mutable array for returning items that need to be equipped as part of this purchase
        let mut unequipped_items = ArrayTrait::<u8>::new();
        let mut items_to_equip = ArrayTrait::<u8>::new();

        // iterate over item ids to purchase and store results in purchases array
        let mut purchases = ArrayTrait::<LootWithPrice>::new();
        let mut item_number: u32 = 0;
        loop {
            if item_number == items_to_purchase.len() {
                break ();
            }

            // get the item
            let item = *items_to_purchase.at(item_number);

            // get a mutable reference to the inventory
            let mut inventory = market_inventory.span();

            // assert item is available on market
            assert(game_libs.is_item_available(inventory, item.item_id), messages::ITEM_DOES_NOT_EXIST);

            // buy it and store result in our purchases array for event
            purchases.append(_buy_item(ref adventurer, ref bag, item.item_id, game_libs));

            // if item is being equipped as part of the purchase
            if item.equip {
                // add it to our array of items to equip
                items_to_equip.append(item.item_id);
            } else {
                // if it's not being equipped, just add it to bag
                bag = game_libs.add_new_item_to_bag(bag, item.item_id);
            }

            // increment counter
            item_number += 1;
        };

        // if we have items to equip as part of the purchase
        if (items_to_equip.len() != 0) {
            // equip them and record the items that were unequipped
            unequipped_items = _equip_items(ref adventurer, ref bag, items_to_equip.clone(), true, game_libs);
        }

        (purchases, items_to_equip, unequipped_items)
    }

    /// @title Buy Potions
    /// @notice Processes the purchase of potions for the adventurer and emits an event.
    /// @dev This function is called when the adventurer purchases potions.
    /// @param adventurer A reference to the adventurer.
    /// @param quantity A u8 representing the number of potions to buy.
    fn _buy_potions(ref adventurer: Adventurer, quantity: u8) {
        let cost = adventurer.charisma_adjusted_potion_price() * quantity.into();
        let health = POTION_HEALTH_AMOUNT.into() * quantity.into();

        // assert adventurer has enough gold to buy the potions
        _assert_has_enough_gold(adventurer, cost);

        // assert adventurer is not buying more health than they can use
        _assert_not_buying_excess_health(adventurer, health);

        // deduct cost of potions from adventurers gold balance
        adventurer.deduct_gold(cost);

        // add health to adventurer
        adventurer.increase_health(health);
    }

    /// @title Buy Item
    /// @notice Buys an item with the item price adjusted for adventurer's charisma.
    /// @dev This function is called when the adventurer buys an item.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param item_id A u8 representing the ID of the item to be purchased.
    /// @return The item that was purchased and its price.
    fn _buy_item(ref adventurer: Adventurer, ref bag: Bag, item_id: u8, game_libs: GameLibs) -> LootWithPrice {
        // create an immutable copy of our adventurer to use for validation
        let immutable_adventurer = adventurer;

        // assert adventurer does not already own the item
        _assert_item_not_owned(immutable_adventurer, bag, item_id, game_libs);

        // assert item is valid
        _assert_valid_item_id(item_id);

        // get item from item id
        let item = game_libs.get_item(item_id);

        // get item price
        let base_item_price = game_libs.get_price(item.tier);

        // get item price with charisma discount
        let charisma_adjusted_price = adventurer.stats.charisma_adjusted_item_price(base_item_price);

        // check adventurer has enough gold to buy the item
        _assert_has_enough_gold(immutable_adventurer, charisma_adjusted_price);

        // deduct charisma adjusted cost of item from adventurer's gold balance
        adventurer.deduct_gold(charisma_adjusted_price);

        // return item with price
        LootWithPrice { item: item, price: charisma_adjusted_price }
    }

    // ------------------------------------------ //
    // ------------ Helper Functions ------------ //
    // ------------------------------------------ //

    /// @title Get Random Seed
    /// @notice Gets a random seed for the adventurer.
    /// @dev This function is called when a random seed is needed.
    /// @param world A reference to the WorldStorage object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param adventurer_xp A u16 representing the adventurer's XP.
    /// @return A felt252 representing the random seed.
    fn _get_random_seed(world: WorldStorage, adventurer_id: u64, adventurer_xp: u16) -> (u64, u64) {
        let mut seed: felt252 = 0;

        if _network_supports_vrf() {
            seed = VRFImpl::seed();
        } else {
            seed = ImplAdventurer::get_simple_entropy(adventurer_xp, adventurer_id);
        }

        ImplAdventurer::felt_to_two_u64(seed)
    }

    /// @title Load Adventurer
    /// @notice Loads the adventurer and returns the adventurer.
    /// @dev This function is called when the adventurer is loaded.
    /// @param world A reference to the WorldStorage object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer.
    fn _load_adventurer(world: WorldStorage, adventurer_id: u64, game_libs: GameLibs) -> Adventurer {
        let mut adventurer_packed: AdventurerPacked = world.read_model(adventurer_id);
        let mut adventurer = ImplAdventurer::unpack(adventurer_packed.packed);
        _apply_equipment_stat_boosts(ref adventurer, adventurer_id, game_libs);
        _apply_luck(world, ref adventurer, adventurer_id, game_libs);
        adventurer
    }

    /// @title Load Adventurer No Boosts
    /// @notice Loads the adventurer and returns the adventurer without boosts.
    /// @dev This function is called when the adventurer is loaded without boosts.
    /// @param world A reference to the WorldStorage object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer.
    fn _load_adventurer_no_boosts(world: WorldStorage, adventurer_id: u64) -> Adventurer {
        let mut adventurer_packed: AdventurerPacked = world.read_model(adventurer_id);
        let adventurer = ImplAdventurer::unpack(adventurer_packed.packed);
        adventurer
    }
    
    fn _load_adventurer_entropy(world: WorldStorage, adventurer_id: u64) -> AdventurerEntropy {
        let adventurer_entropy: AdventurerEntropy = world.read_model(adventurer_id);
        adventurer_entropy
    }

    fn _save_market_seed(ref world: WorldStorage, adventurer_id: u64, market_seed: u64) {
        let mut adventurer_entropy = _load_adventurer_entropy(world, adventurer_id);
        adventurer_entropy.market_seed = market_seed;
        world.write_model(@adventurer_entropy);
    }

    fn _save_beast_seed(ref world: WorldStorage, adventurer_id: u64, beast_seed: u64) {
        let mut adventurer_entropy = _load_adventurer_entropy(world, adventurer_id);
        adventurer_entropy.beast_seed = beast_seed;
        world.write_model(@adventurer_entropy);
    }

    /// @title Save Adventurer
    /// @notice Saves the adventurer and returns the adventurer.
    /// @dev This function is called when the adventurer is saved.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer.
    fn _save_adventurer(ref world: WorldStorage, ref adventurer: Adventurer, adventurer_id: u64, game_libs: GameLibs) {
        _remove_equipment_stat_boosts(ref adventurer, adventurer_id, game_libs);
        let packed = adventurer.pack();
        world.write_model(@AdventurerPacked { adventurer_id, packed });
    }

    /// @title Save Adventurer No Boosts
    /// @notice Saves the adventurer without boosts and returns the adventurer.
    /// @dev This function is called when the adventurer is saved without boosts.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer.
    fn _save_adventurer_no_boosts(ref world: WorldStorage, adventurer: Adventurer, adventurer_id: u64) {
        let packed = adventurer.pack();
        world.write_model(@AdventurerPacked { adventurer_id, packed });
    }

    /// @title Apply Luck
    /// @notice Applies the adventurer's luck to the adventurer.
    /// @dev This function is called when the adventurer's luck is applied.
    /// @param world A reference to the WorldStorage object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    fn _apply_luck(world: WorldStorage, ref adventurer: Adventurer, adventurer_id: u64, game_libs: GameLibs) {
        let bag = _load_bag(world, adventurer_id, game_libs);
        adventurer.set_luck(bag, game_libs.get_bag_jewelry_greatness(bag));
    }

    /// @title Load Bag
    /// @notice Loads the bag and returns the bag.
    /// @dev This function is called when the bag is loaded.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The bag.
    fn _load_bag(world: WorldStorage, adventurer_id: u64, game_libs: GameLibs) -> Bag {
        let bag_packed: BagPacked = world.read_model(adventurer_id);
        game_libs.unpack_bag(bag_packed.packed)
    }

    /// @title Save Bag
    /// @notice Saves the bag and returns the bag.
    /// @dev This function is called when the bag is saved.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param bag A reference to the bag.
    /// @param game_libs A reference to the game libraries.
    fn _save_bag(ref world: WorldStorage, adventurer_id: u64, bag: Bag, game_libs: GameLibs) {
        let packed = game_libs.pack_bag(bag);
        world.write_model(@BagPacked { adventurer_id, packed });
    }

    /// @title Apply Item Stat Boost
    /// @notice Applies the item stat boost to the adventurer.
    /// @dev This function is called when the item stat boost is applied to the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param item A reference to the item.
    fn _apply_item_stat_boost(ref adventurer: Adventurer, item: Item, game_libs: GameLibs) {
        let item_suffix = game_libs.get_suffix(item.id, adventurer.item_specials_seed);
        adventurer.stats.apply_suffix_boost(item_suffix);
    }

    /// @title Remove Item Stat Boost
    /// @notice Removes the item stat boost from the adventurer.
    /// @dev This function is called when the item stat boost is removed from the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param item A reference to the item.
    fn _remove_item_stat_boost(ref adventurer: Adventurer, item: Item, game_libs: GameLibs) {
        let item_suffix = game_libs.get_suffix(item.id, adventurer.item_specials_seed);
        adventurer.stats.remove_suffix_boost(item_suffix);

        // if the adventurer's health is now above the max health due to a change in Vitality
        let max_health = adventurer.stats.get_max_health();
        if adventurer.health > max_health {
            // lower adventurer's health to max health
            adventurer.health = max_health;
        }
    }

    /// @title Apply Equipment Stat Boosts
    /// @notice Applies the equipment stat boosts to the adventurer.
    /// @dev This function is called when the equipment stat boosts are applied to the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    fn _apply_equipment_stat_boosts(ref adventurer: Adventurer, adventurer_id: u64, game_libs: GameLibs) {
        let item_specials_seed = adventurer.item_specials_seed;
        if adventurer.equipment.has_specials() && item_specials_seed != 0 {
            let weapon_suffix = game_libs.get_suffix(adventurer.equipment.weapon.id, item_specials_seed);
            let chest_suffix = game_libs.get_suffix(adventurer.equipment.chest.id, item_specials_seed);
            let head_suffix = game_libs.get_suffix(adventurer.equipment.head.id, item_specials_seed);
            let waist_suffix = game_libs.get_suffix(adventurer.equipment.waist.id, item_specials_seed);
            let foot_suffix = game_libs.get_suffix(adventurer.equipment.foot.id, item_specials_seed);
            let hand_suffix = game_libs.get_suffix(adventurer.equipment.hand.id, item_specials_seed);
            let neck_suffix = game_libs.get_suffix(adventurer.equipment.neck.id, item_specials_seed);
            let ring_suffix = game_libs.get_suffix(adventurer.equipment.ring.id, item_specials_seed);

            let item_stat_boosts = adventurer.equipment.get_stat_boosts(
                item_specials_seed, weapon_suffix, chest_suffix, head_suffix,
                waist_suffix, foot_suffix, hand_suffix, neck_suffix, ring_suffix
            );
            adventurer.stats.apply_stats(item_stat_boosts);
        }
    }

    /// @title Remove Equipment Stat Boosts
    /// @notice Removes the equipment stat boosts from the adventurer.
    /// @dev This function is called when the equipment stat boosts are removed from the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    fn _remove_equipment_stat_boosts(ref adventurer: Adventurer, adventurer_id: u64, game_libs: GameLibs) {
        let item_specials_seed = adventurer.item_specials_seed;
        if adventurer.equipment.has_specials() && item_specials_seed != 0 {
            let weapon_suffix = game_libs.get_suffix(adventurer.equipment.weapon.id, item_specials_seed);
            let chest_suffix = game_libs.get_suffix(adventurer.equipment.chest.id, item_specials_seed);
            let head_suffix = game_libs.get_suffix(adventurer.equipment.head.id, item_specials_seed);
            let waist_suffix = game_libs.get_suffix(adventurer.equipment.waist.id, item_specials_seed);
            let foot_suffix = game_libs.get_suffix(adventurer.equipment.foot.id, item_specials_seed);
            let hand_suffix = game_libs.get_suffix(adventurer.equipment.hand.id, item_specials_seed);
            let neck_suffix = game_libs.get_suffix(adventurer.equipment.neck.id, item_specials_seed);
            let ring_suffix = game_libs.get_suffix(adventurer.equipment.ring.id, item_specials_seed);

            let item_stat_boosts = adventurer.equipment.get_stat_boosts(
                item_specials_seed, weapon_suffix, chest_suffix, head_suffix,
                waist_suffix, foot_suffix, hand_suffix, neck_suffix, ring_suffix
            );
            adventurer.stats.remove_stats(item_stat_boosts);
        }
    }
    fn _assert_in_battle(adventurer: Adventurer) {
        assert(adventurer.beast_health != 0, messages::NOT_IN_BATTLE);
    }
    fn _assert_dexterity_not_zero(adventurer: Adventurer) {
        assert(adventurer.stats.dexterity != 0, messages::ZERO_DEXTERITY);
    }
    fn _assert_not_in_battle(adventurer: Adventurer) {
        assert(adventurer.beast_health == 0, messages::ACTION_NOT_ALLOWED_DURING_BATTLE);
    }
    fn _assert_upgrades_available(stat_upgrades_available: u8) {
        assert(stat_upgrades_available != 0, messages::MARKET_CLOSED);
    }
    fn _assert_item_not_owned(adventurer: Adventurer, bag: Bag, item_id: u8, game_libs: GameLibs) {
        let (item_in_bag, _) = game_libs.bag_contains(bag, item_id);
        assert(
            adventurer.equipment.is_equipped(item_id) == false && item_in_bag == false, messages::ITEM_ALREADY_OWNED,
        );
    }
    fn _assert_valid_item_id(item_id: u8) {
        assert(item_id > 0 && item_id <= 101, messages::INVALID_ITEM_ID);
    }
    fn _assert_not_starter_beast(adventurer: Adventurer, message: felt252) {
        assert(adventurer.get_level() > 1, message);
    }
    fn _assert_no_stat_upgrades_available(adventurer: Adventurer) {
        assert(adventurer.stat_upgrades_available == 0, messages::STAT_UPGRADES_AVAILABLE);
    }
    fn _assert_not_dead(self: Adventurer) {
        assert(self.health != 0, messages::DEAD_ADVENTURER);
    }
    fn _assert_is_dead(self: Adventurer) {
        assert(self.health == 0, messages::ADVENTURER_IS_ALIVE);
    }
    fn _assert_valid_starter_weapon(starting_weapon: u8, game_libs: GameLibs) {
        assert(game_libs.is_starting_weapon(starting_weapon) == true, messages::INVALID_STARTING_WEAPON);
    }
    fn _assert_zero_luck(stats: Stats) {
        assert(stats.luck == 0, messages::NON_ZERO_STARTING_LUCK);
    }
    fn _assert_has_enough_gold(adventurer: Adventurer, cost: u16) {
        assert(adventurer.gold >= cost, messages::NOT_ENOUGH_GOLD);
    }
    fn _assert_not_buying_excess_health(adventurer: Adventurer, purchased_health: u16) {
        let adventurer_health_after_potions = adventurer.health + purchased_health;
        // assert adventurer is not buying more health than needed
        assert(
            adventurer_health_after_potions < adventurer.stats.get_max_health() + POTION_HEALTH_AMOUNT.into(),
            messages::HEALTH_FULL,
        );
    }
    fn _assert_stat_balance(stat_upgrades: Stats, stat_upgrades_available: u8) {
        let stat_upgrade_count = stat_upgrades.strength
            + stat_upgrades.dexterity
            + stat_upgrades.vitality
            + stat_upgrades.intelligence
            + stat_upgrades.wisdom
            + stat_upgrades.charisma;

        if stat_upgrades_available < stat_upgrade_count {
            panic_with_felt252(messages::INSUFFICIENT_STAT_UPGRADES);
        } else if stat_upgrades_available > stat_upgrade_count {
            panic_with_felt252(messages::MUST_USE_ALL_STATS);
        }
    }
    fn _assert_valid_stat_selection(adventurer: Adventurer, stat_upgrades: Stats) {
        _assert_upgrades_available(adventurer.stat_upgrades_available);
        _assert_stat_balance(stat_upgrades, adventurer.stat_upgrades_available);
        _assert_zero_luck(stat_upgrades);
    }

    fn _get_market(seed: u64, stat_upgrades_available: u8, game_libs: GameLibs) -> Array<u8> {
        let market_size = game_libs.get_market_size(stat_upgrades_available);
        game_libs.get_available_items(seed, market_size)
    }
    fn _get_attacking_beast(world: WorldStorage, adventurer_id: u64) -> Beast {
        // get game libaries
        let game_libs = ImplGame::get_libs(world);

        // get adventurer
        let adventurer = _load_adventurer_no_boosts(world, adventurer_id);

        // assert adventurer is in battle
        assert(adventurer.beast_health != 0, messages::NOT_IN_BATTLE);

        let adventurer_weapon_type = game_libs.get_type(adventurer.equipment.weapon.id);
        if adventurer.get_level() > 1 {
            // get adventurer entropy
            let adventurer_entropy = _load_adventurer_entropy(world, adventurer_id);

            // generate xp based randomness seeds
            let (beast_seed, _, beast_health_rnd, beast_level_rnd, beast_specials1_rnd, beast_specials2_rnd, _, _) =
                ImplAdventurer::get_randomness(
                adventurer.xp, adventurer_entropy.beast_seed,
            );

            // get beast based on entropy seeds
            ImplAdventurer::get_beast(
                adventurer.get_level(),
                adventurer_weapon_type,
                beast_seed,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd,
            )
        } else {
            let level_seed_u256: u256 = adventurer_id.try_into().unwrap();
            let beast_seed = (level_seed_u256 % TWO_POW_32.into()).try_into().unwrap();
            // generate starter beast which will have weak armor against the adventurers starter
            // weapon
            ImplBeast::get_starter_beast(adventurer_weapon_type, beast_seed)
        }
    }

    #[abi(embed_v0)]
    impl ERC721Metadata of IERC721Metadata<ContractState> {
        /// Returns the NFT name.
        fn name(self: @ContractState) -> ByteArray {
            "Loot Survivor"
        }

        /// Returns the NFT symbol.
        fn symbol(self: @ContractState) -> ByteArray {
            "LSVR"
        }

        /// Returns the Uniform Resource Identifier (URI) for the `token_id` token.
        /// If the URI is not set, the return value will be an empty ByteArray.
        ///
        /// Requirements:
        ///
        /// - `token_id` exists.
        fn token_uri(self: @ContractState, token_id: u256) -> ByteArray {
            self.erc721._require_owned(token_id);

            let adventurer_id = token_id.try_into().unwrap();
            let adventurer = self.get_adventurer(adventurer_id);
            let adventurer_name = self.get_adventurer_name(adventurer_id);
            let bag = self.get_bag(adventurer_id);

            let game_libs = ImplGame::get_libs(self.world(@DEFAULT_NS()));
            game_libs.create_metadata(adventurer_id, adventurer, adventurer_name, bag)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        
        fn validate_start_conditions(self: @ContractState, token_id: u64, token_metadata: @TokenMetadata) {
            self.assert_token_ownership(token_id);
            self.assert_game_not_started(token_id);
            token_metadata.lifecycle.assert_is_playable(token_id, starknet::get_block_timestamp());
        }

        
        fn assert_token_ownership(self: @ContractState, token_id: u64) {
            let token_owner = ERC721Impl::owner_of(self, token_id.into());
            assert!(
                token_owner == starknet::get_caller_address(),
                "Loot Survivor: Caller is not owner of token {}",
                token_id,
            );
        }

        
        fn assert_game_not_started(self: @ContractState, adventurer_id: u64) {
            let adventurer = _load_adventurer_no_boosts(self.world(@DEFAULT_NS()), adventurer_id);
            assert!(adventurer.xp == 0, "Loot Survivor: Adventurer {} has already started", adventurer_id);
        }
    }
}
