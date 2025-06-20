import { Adventurer, Beast, Equipment, Item } from "@/types/game";
import { getArmorType, getAttackType } from "./beast";
import { ItemType, ItemUtils } from "./loot";

export const calculateLevel = (xp: number) => {
    if (xp === 0) return 1;
    return Math.floor(Math.sqrt(xp));
};

export const calculateNextLevelXP = (currentLevel: number) => {
    return Math.min(400, Math.pow(currentLevel + 1, 2));
};

export const calculateProgress = (xp: number) => {
    const currentLevel = calculateLevel(xp);
    const nextLevelXP = calculateNextLevelXP(currentLevel);
    const currentLevelXP = Math.pow(currentLevel, 2);
    return ((xp - currentLevelXP) / (nextLevelXP - currentLevelXP)) * 100;
};

export const getNewItemsEquipped = (newEquipment: Equipment, oldEquipment: Equipment) => {
    const newItems: Item[] = [];

    // Check each equipment slot in the current adventurer
    Object.entries(newEquipment).forEach(([slot, currentItem]) => {
        const initialItem = oldEquipment[slot as keyof Equipment];

        // Only add if there's a current item and it's different from the initial item
        if (currentItem.id !== 0 && currentItem.id !== initialItem.id) {
            newItems.push(currentItem);
        }
    });

    return newItems;
};

// Calculate critical hit bonus based on luck and ring
const critical_hit_bonus = (base_damage: number, luck: number, ring: Item | null, entropy: number): number => {
    let total = 0;
    const scaledChance = (luck * 255) / 100;

    if (entropy <= scaledChance) {
        total = base_damage;

        // Titanium Ring gives 3% bonus per level on critical hits
        if (ring && ItemUtils.getItemName(ring.id) === "TitaniumRing" && total > 0) {
            const ringLevel = calculateLevel(ring.xp);
            total += Math.floor((total * 3 * ringLevel) / 100);
        }
    }

    return total;
};

// Calculate weapon special bonus based on matching specials
const calculateWeaponSpecialBonus = (weaponId: number, weaponLevel: number, itemSpecialsSeed: number, beastPrefix: string | null, beastSuffix: string | null, baseDamage: number, ring: Item) => {
    if (!beastPrefix && !beastSuffix) return 0;

    const weaponSpecials = ItemUtils.getSpecials(weaponId, weaponLevel, itemSpecialsSeed);

    let bonus = 0;
    // Special2 (prefix) match gives 8x damage
    if (weaponSpecials.prefix && weaponSpecials.prefix === beastPrefix) {
        bonus += baseDamage * 8;
    }
    // Special3 (suffix) match gives 2x damage
    if (weaponSpecials.suffix && weaponSpecials.suffix === beastSuffix) {
        bonus += baseDamage * 2;
    }

    // Platinum Ring gives 3% bonus per level on special matches
    if (ItemUtils.getItemName(ring.id) === "PlatinumRing" && bonus > 0) {
        const ringLevel = calculateLevel(ring.xp);
        bonus += Math.floor((bonus * 3 * ringLevel) / 100);
    }

    return bonus;
};

export const calculateAttackDamage = (adventurer: Adventurer, beast: Beast, criticalHitEntropy: number) => {
    const weapon = adventurer.equipment.weapon;
    if (!weapon) return 4; // Minimum damage

    const weaponLevel = calculateLevel(weapon.xp);
    const weaponTier = ItemUtils.getItemTier(weapon.id);
    const baseAttack = weaponLevel * (6 - Number(weaponTier));

    let baseArmor = 0;
    let elementalDamage = 0;

    const beastLevel = beast.level;
    const weaponType = ItemUtils.getItemType(weapon.id);
    const beastArmor = getArmorType(beast.id);

    baseArmor = beastLevel * (6 - Number(beast.tier));
    elementalDamage = elementalAdjustedDamage(baseAttack, weaponType, beastArmor);

    // Calculate special name bonus damage with ring bonus
    const ring = adventurer.equipment.ring;
    const specialBonus = calculateWeaponSpecialBonus(weapon.id, weaponLevel, adventurer.item_specials_seed, beast.specialPrefix, beast.specialSuffix, elementalDamage, ring);
    elementalDamage += specialBonus;

    // Calculate critical hit bonus with ring bonus using adventurer's luck stat
    const critBonus = criticalHitEntropy ? critical_hit_bonus(elementalDamage, adventurer.stats.luck, ring, criticalHitEntropy) : 0;
    elementalDamage += critBonus;

    const strengthBonus = strength_dmg(elementalDamage, adventurer.stats.strength);
    const totalAttack = elementalDamage + strengthBonus;
    const totalDamage = Math.floor(totalAttack - baseArmor);

    return Math.max(4, totalDamage);
};

export const ability_based_percentage = (adventurer_xp: number, relevant_stat: number) => {
    let adventurer_level = calculateLevel(adventurer_xp);

    if (relevant_stat >= adventurer_level) {
        return 100;
    } else {
        return Math.floor((relevant_stat / adventurer_level) * 100);
    }
}

export const ability_based_avoid_threat = (adventurer_level: number, relevant_stat: number, rnd: number) => {
    if (relevant_stat >= adventurer_level) {
        return true;
    } else {
        let scaled_chance = (adventurer_level * rnd) / 255;
        return relevant_stat > scaled_chance;
    }
}

const calculateBeastDamage = (beast: Beast, adventurer: Adventurer, attackLocation: string, entropy: number) => {
    const baseAttack = beast.level * (6 - Number(beast.tier));
    const armor: Item = adventurer.equipment[attackLocation.toLowerCase() as keyof typeof adventurer.equipment];
    let damage = baseAttack;

    if (armor) {
        const armorLevel = calculateLevel(armor.xp);
        const armorValue = armorLevel * (6 - ItemUtils.getItemTier(armor.id));
        damage = Math.max(2, baseAttack - armorValue);

        // Apply elemental adjustment
        const beastAttackType = getAttackType(beast.id);
        const armorType = ItemUtils.getItemType(armor.id);
        damage = elementalAdjustedDamage(damage, beastAttackType, armorType);

        // Calculate critical hit bonus - beasts use adventurer's level * 3 for luck
        const critBonus = critical_hit_bonus(damage, calculateLevel(adventurer.xp) * 3, null, entropy);
        damage += critBonus;

        // Check for neck armor reduction
        const neck = adventurer.equipment.neck;
        if (neck_reduction(armor, neck)) {
            const neckLevel = calculateLevel(neck.xp);
            damage -= Math.floor((armorLevel * (6 - ItemUtils.getItemTier(armor.id)) * neckLevel * 3) / 100);
        }
    }

    return Math.max(2, damage);
};

// Check if neck item provides bonus armor reduction
const neck_reduction = (armor: Item, neck: Item): boolean => {
    if (!armor.id || !neck.id) return false;

    if (ItemUtils.getItemType(armor.id) === ItemType.Cloth && ItemUtils.getItemName(neck.id) === "Amulet") return true;
    if (ItemUtils.getItemType(armor.id) === ItemType.Hide && ItemUtils.getItemName(neck.id) === "Pendant") return true;
    if (ItemUtils.getItemType(armor.id) === ItemType.Metal && ItemUtils.getItemName(neck.id) === "Necklace") return true;

    return false;
};

export function elementalAdjustedDamage(base_attack: number, weapon_type: string, armor_type: string): number {
    let elemental_effect = Math.floor(base_attack / 2);

    if (
        (weapon_type === ItemType.Magic && armor_type === "Metal") ||
        (weapon_type === ItemType.Blade && armor_type === "Cloth") ||
        (weapon_type === ItemType.Bludgeon && armor_type === "Hide")
    ) {
        return base_attack + elemental_effect;
    }

    if (
        (weapon_type === ItemType.Magic && armor_type === "Hide") ||
        (weapon_type === ItemType.Blade && armor_type === "Metal") ||
        (weapon_type === ItemType.Bludgeon && armor_type === "Cloth")
    ) {
        return base_attack - elemental_effect;
    }

    return base_attack;
}

export function strength_dmg(damage: number, strength: number): number {
    if (strength == 0) return 0;
    return (damage * strength * 10) / 100;
}