use lootsurvivor::models::beast::Beast;
use lootsurvivor::constants::combat::CombatEnums::Type;

#[starknet::interface]
pub trait IBeastSystems<T> {
    fn get_starter_beast(self: @T, starter_weapon_type: Type, seed: u32) -> Beast;
    fn get_beast(
        self: @T,
        adventurer_level: u8,
        weapon_type: Type,
        seed: u32,
        health_rnd: u16,
        level_rnd: u16,
        special2_rnd: u8,
        special3_rnd: u8,
    ) -> Beast;
    fn get_critical_hit_chance(self: @T, adventurer_level: u8, is_ambush: bool) -> u8;
    fn attempt_flee(self: @T, adventurer_level: u8, adventurer_dexterity: u8, rnd: u8) -> bool;
}

#[dojo::contract]
mod Beast_systems {
    use super::IBeastSystems;
    use lootsurvivor::models::beast::{Beast, ImplBeast};
    use lootsurvivor::constants::combat::CombatEnums::Type;

    #[abi(embed_v0)]
    impl BeastSystemsImpl of IBeastSystems<ContractState> {
        fn get_starter_beast(self: @ContractState, starter_weapon_type: Type, seed: u32) -> Beast {
            ImplBeast::get_starter_beast(starter_weapon_type, seed)
        }

        fn get_beast(
            self: @ContractState,
            adventurer_level: u8,
            weapon_type: Type,
            seed: u32,
            health_rnd: u16,
            level_rnd: u16,
            special2_rnd: u8,
            special3_rnd: u8,
        ) -> Beast {
            ImplBeast::get_beast(adventurer_level, weapon_type, seed, health_rnd, level_rnd, special2_rnd, special3_rnd)
        }

        fn get_critical_hit_chance(self: @ContractState, adventurer_level: u8, is_ambush: bool) -> u8 {
            ImplBeast::get_critical_hit_chance(adventurer_level, is_ambush)
        }

        fn attempt_flee(self: @ContractState, adventurer_level: u8, adventurer_dexterity: u8, rnd: u8) -> bool {
            ImplBeast::attempt_flee(adventurer_level, adventurer_dexterity, rnd)
        }
    }
}