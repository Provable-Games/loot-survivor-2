use lootsurvivor::models::adventurer::bag::Bag;
use lootsurvivor::models::adventurer::item::Item;
use lootsurvivor::models::adventurer::adventurer::Adventurer;
use lootsurvivor::constants::discovery::DiscoveryEnums::DiscoveryType;

#[starknet::interface]
pub trait IAdventurerSystems<T> {
    fn pack_adventurer(self: @T, adventurer: Adventurer) -> felt252;
    fn unpack_adventurer(self: @T, packed_adventurer: felt252) -> Adventurer;
    fn get_discovery(self: @T, adventurer_level: u8, discovery_type_rnd: u8, amount_rnd1: u8, amount_rnd2: u8) -> DiscoveryType;
    fn pack_bag(self: @T, bag: Bag) -> felt252;
    fn unpack_bag(self: @T, packed_bag: felt252) -> Bag;
    fn get_bag_item(self: @T, bag: Bag, item_id: u8) -> Item;
    fn add_item_to_bag(self: @T, bag: Bag, item: Item) -> Bag;
    fn remove_item_from_bag(self: @T, bag: Bag, item_id: u8) -> (Bag, Item);
    fn add_new_item_to_bag(self: @T, bag: Bag, item_id: u8) -> Bag;
    fn is_bag_full(self: @T, bag: Bag) -> bool;
    fn bag_contains(self: @T, bag: Bag, item_id: u8) -> (bool, Item);
    fn get_bag_jewelry(self: @T, bag: Bag) -> Array<Item>;
    fn get_bag_jewelry_greatness(self: @T, bag: Bag) -> u8;
    fn bag_has_specials(self: @T, bag: Bag) -> bool;
}

#[dojo::contract]
mod adventurer_systems {
    use super::IAdventurerSystems;
    use lootsurvivor::models::adventurer::bag::{Bag, ImplBag};
    use lootsurvivor::models::adventurer::adventurer::{Adventurer, ImplAdventurer};
    use lootsurvivor::models::adventurer::item::Item;
    use lootsurvivor::constants::discovery::DiscoveryEnums::{DiscoveryType};

    #[abi(embed_v0)]
    impl AdventurerSystemsImpl of IAdventurerSystems<ContractState> {
        fn pack_adventurer(self: @ContractState, adventurer: Adventurer) -> felt252 {
            ImplAdventurer::pack(adventurer)
        }

        fn unpack_adventurer(self: @ContractState, packed_adventurer: felt252) -> Adventurer {
            ImplAdventurer::unpack(packed_adventurer)
        }

        fn get_discovery(self: @ContractState, adventurer_level: u8, discovery_type_rnd: u8, amount_rnd1: u8, amount_rnd2: u8) -> DiscoveryType {
            ImplAdventurer::get_discovery(adventurer_level, discovery_type_rnd, amount_rnd1, amount_rnd2)
        }

        fn pack_bag(self: @ContractState, bag: Bag) -> felt252 {
            ImplBag::pack(bag)
        }

        fn unpack_bag(self: @ContractState, packed_bag: felt252) -> Bag {
            ImplBag::unpack(packed_bag)
        }

        fn get_bag_item(self: @ContractState, bag: Bag, item_id: u8) -> Item {
            ImplBag::get_item(bag, item_id)
        }

        fn add_item_to_bag(self: @ContractState, mut bag: Bag, item: Item) -> Bag {
            ImplBag::add_item(ref bag, item);
            bag
        }

        fn remove_item_from_bag(self: @ContractState, mut bag: Bag, item_id: u8) -> (Bag, Item) {
            let item = ImplBag::remove_item(ref bag, item_id);
            (bag, item)
        }

        fn add_new_item_to_bag(self: @ContractState, mut bag: Bag, item_id: u8) -> Bag {
            ImplBag::add_new_item(ref bag, item_id);
            bag
        }

        fn is_bag_full(self: @ContractState, bag: Bag) -> bool {
            ImplBag::is_full(bag)
        }

        fn bag_contains(self: @ContractState, bag: Bag, item_id: u8) -> (bool, Item) {
            ImplBag::contains(bag, item_id)
        }

        fn get_bag_jewelry(self: @ContractState, bag: Bag) -> Array<Item> {
            ImplBag::get_jewelry(bag)
        }

        fn get_bag_jewelry_greatness(self: @ContractState, bag: Bag) -> u8 {
            ImplBag::get_jewelry_greatness(bag)
        }

        fn bag_has_specials(self: @ContractState, bag: Bag) -> bool {
            ImplBag::has_specials(bag)
        }
    }
}