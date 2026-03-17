using System;
using System.Collections.Generic;

namespace Robot {
    /// Unified item layer for ALL Przedmiot entities (including currency).
    ///
    /// Builds dual-index lookup in a single O(n) pass over all entities:
    /// 1. ByNameAndOwner:  key = "{EntityName}|{Owner}" (for item @Transfer)
    /// 2. ByDenomAndOwner: key = "{Denomination}|{Owner}" (for currency @Transfer)
    ///
    /// Also provides single-pass filter+enrichment for Przedmiot entities,
    /// combining is-Przedmiot check, status/owner/location/name filters,
    /// IsCurrency classification, and owner type resolution in one iteration.
    ///
    /// denominationNames parameter: canonical denomination names (e.g., "Korony Elanckie")
    /// pre-resolved by the PS caller from $script:CurrencyDenominations. This avoids
    /// cross-assembly dependency on currency-helpers.
    ///
    /// Consumers: item-helpers.ps1, get-entitystate.ps1 (@Transfer expansion),
    /// currency-helpers.ps1 (delegation), get-itementity.ps1
    public sealed class ItemHelper {

        /// Single-pass over ALL entities: builds TWO lookup indexes simultaneously.
        /// denominationNames: canonical denomination names for identifying currency items
        /// via GenericNames matching (case-insensitive).
        public static ItemLookupResult BuildLookup(
            object[] entities, string[] denominationNames) {

            var byName = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            var byDenom = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            int itemCount = 0;
            int currencyCount = 0;

            var denomSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (denominationNames != null) {
                for (int i = 0; i < denominationNames.Length; i++) {
                    denomSet.Add(denominationNames[i]);
                }
            }

            for (int ei = 0; ei < entities.Length; ei++) {
                dynamic entity = entities[ei];

                string type = entity.Type;
                if (!string.Equals(type, "Przedmiot", StringComparison.OrdinalIgnoreCase)) continue;

                string owner = entity.Owner;
                string entityName = entity.Name;
                itemCount++;

                // ByNameAndOwner index (all Przedmiot entities)
                // Index ALL names (primary + aliases + generic names) for flexible
                // item transfer resolution — allows transfer identifiers to match
                // any name variant of the entity.
                // Names is a HashSet<string> (IEnumerable, not IList).
                if (!string.IsNullOrEmpty(owner)) {
                    object names = entity.Names;
                    if (names != null) {
                        var nameEnum = names as System.Collections.IEnumerable;
                        if (nameEnum != null) {
                            foreach (object nameObj in nameEnum) {
                                string n = nameObj as string;
                                if (!string.IsNullOrEmpty(n)) {
                                    string nameKey = n + "|" + owner;
                                    if (!byName.ContainsKey(nameKey)) {
                                        byName[nameKey] = entity;
                                    }
                                }
                            }
                        }
                    }
                    // Also index by primary Name in case Names collection is empty
                    if (!string.IsNullOrEmpty(entityName)) {
                        string primaryKey = entityName + "|" + owner;
                        if (!byName.ContainsKey(primaryKey)) {
                            byName[primaryKey] = entity;
                        }
                    }
                }

                // ByDenomAndOwner index (currency entities only)
                object genericNames = entity.GenericNames;
                if (genericNames != null) {
                    var gnList = genericNames as System.Collections.IList;
                    if (gnList != null && gnList.Count > 0) {
                        for (int gi = 0; gi < gnList.Count; gi++) {
                            string gn = gnList[gi] as string;
                            if (gn != null && denomSet.Contains(gn)) {
                                currencyCount++;
                                if (!string.IsNullOrEmpty(owner)) {
                                    string denomKey = gn + "|" + owner;
                                    if (!byDenom.ContainsKey(denomKey)) {
                                        byDenom[denomKey] = entity;
                                    }
                                }
                                break;
                            }
                        }
                    }
                }
            }

            return new ItemLookupResult {
                ByNameAndOwner = byName,
                ByDenomAndOwner = byDenom,
                ItemCount = itemCount,
                CurrencyCount = currencyCount
            };
        }

        /// O(1) lookup by entity name + owner (for item @Transfer).
        /// Returns null if not found.
        public static object FindByNameAndOwner(
            ItemLookupResult lookup, string itemName, string ownerName) {

            if (lookup == null || string.IsNullOrEmpty(itemName) || string.IsNullOrEmpty(ownerName))
                return null;

            string key = itemName + "|" + ownerName;
            object found;
            if (lookup.ByNameAndOwner.TryGetValue(key, out found)) return found;
            return null;
        }

        /// O(1) lookup by denomination + owner (for currency @Transfer).
        /// denomination should be canonical (e.g., "Korony Elanckie").
        /// Returns null if not found.
        public static object FindByDenominationAndOwner(
            ItemLookupResult lookup, string denomination, string ownerName) {

            if (lookup == null || string.IsNullOrEmpty(denomination) || string.IsNullOrEmpty(ownerName))
                return null;

            string key = denomination + "|" + ownerName;
            object found;
            if (lookup.ByDenomAndOwner.TryGetValue(key, out found)) return found;
            return null;
        }

        /// Single-pass filter + enrichment for ALL Przedmiot entities.
        /// Combines is-Przedmiot check + status/owner/location/name filters +
        /// IsCurrency classification + owner type resolution in ONE iteration.
        /// Returns ItemFilterResult with parallel arrays for PS layer to assemble PSCustomObjects.
        ///
        /// entityLookup: entity-by-name dictionary for owner type resolution (may be null).
        public static ItemFilterResult FilterItems(
            object[] entities, string[] denominationNames,
            string ownerFilter, string locationFilter, string nameFilter,
            bool includeInactive, bool includeDeleted, bool currencyOnly,
            bool excludeCurrency, object entityLookup) {

            var denomSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (denominationNames != null) {
                for (int i = 0; i < denominationNames.Length; i++) {
                    denomSet.Add(denominationNames[i]);
                }
            }

            // Pre-size to a quarter of entity count as a reasonable capacity estimate
            int capacity = Math.Max(16, entities.Length / 4);
            var indices = new List<int>(capacity);
            var ownerTypes = new List<string>(capacity);
            var quantities = new List<int>(capacity);
            var isCurrencyArr = new List<bool>(capacity);
            var denominations = new List<string>(capacity);

            // Build a simple lookup from entityLookup if provided (dynamic: Dictionary[string, object])
            System.Collections.IDictionary lookup = entityLookup as System.Collections.IDictionary;

            for (int ei = 0; ei < entities.Length; ei++) {
                dynamic entity = entities[ei];

                string type = entity.Type;
                if (!string.Equals(type, "Przedmiot", StringComparison.OrdinalIgnoreCase)) continue;

                // Status filter
                string status = entity.Status;
                if (string.IsNullOrEmpty(status)) status = "Aktywny";
                if (string.Equals(status, "Usunięty", StringComparison.OrdinalIgnoreCase) && !includeDeleted) continue;
                if (string.Equals(status, "Nieaktywny", StringComparison.OrdinalIgnoreCase) && !includeInactive) continue;

                // Currency classification (single GenericNames walk)
                bool isCurrency = false;
                string denomName = null;
                object genericNames = entity.GenericNames;
                if (genericNames != null) {
                    var gnList = genericNames as System.Collections.IList;
                    if (gnList != null && gnList.Count > 0) {
                        for (int gi = 0; gi < gnList.Count; gi++) {
                            string gn = gnList[gi] as string;
                            if (gn != null && denomSet.Contains(gn)) {
                                isCurrency = true;
                                denomName = gn;
                                break;
                            }
                        }
                    }
                }

                if (currencyOnly && !isCurrency) continue;
                if (excludeCurrency && isCurrency) continue;

                // Owner filter
                string owner = entity.Owner;
                if (!string.IsNullOrEmpty(ownerFilter)) {
                    if (string.IsNullOrEmpty(owner) ||
                        !string.Equals(owner, ownerFilter, StringComparison.OrdinalIgnoreCase)) continue;
                }

                // Location filter
                string location = entity.Location;
                if (!string.IsNullOrEmpty(locationFilter)) {
                    if (string.IsNullOrEmpty(location) ||
                        !string.Equals(location, locationFilter, StringComparison.OrdinalIgnoreCase)) continue;
                }

                // Name filter (substring, case-insensitive)
                string entityName = entity.Name;
                if (!string.IsNullOrEmpty(nameFilter)) {
                    if (string.IsNullOrEmpty(entityName) ||
                        entityName.IndexOf(nameFilter, StringComparison.OrdinalIgnoreCase) < 0) continue;
                }

                // Quantity parsing
                string qtyStr = entity.Quantity;
                int qty = 1;
                if (!string.IsNullOrEmpty(qtyStr)) {
                    int parsed;
                    if (int.TryParse(qtyStr, out parsed)) {
                        qty = parsed;
                    }
                }

                // Owner type resolution
                string ownerType = "Unknown";
                if (!string.IsNullOrEmpty(owner) && lookup != null) {
                    object ownerEntity = null;
                    if (lookup.Contains(owner)) {
                        ownerEntity = lookup[owner];
                    }
                    if (ownerEntity != null) {
                        string ownerEntityType = ((dynamic)ownerEntity).Type;
                        if (string.Equals(ownerEntityType, "Postać", StringComparison.OrdinalIgnoreCase)) {
                            ownerType = "Physical";
                        } else if (string.Equals(ownerEntityType, "NPC", StringComparison.OrdinalIgnoreCase) ||
                                   string.Equals(ownerEntityType, "Grupa", StringComparison.OrdinalIgnoreCase) ||
                                   string.Equals(ownerEntityType, "Gracz", StringComparison.OrdinalIgnoreCase)) {
                            ownerType = "Virtual";
                        }
                    }
                }

                indices.Add(ei);
                ownerTypes.Add(ownerType);
                quantities.Add(qty);
                isCurrencyArr.Add(isCurrency);
                denominations.Add(denomName);
            }

            return new ItemFilterResult {
                Count = indices.Count,
                Indices = indices.ToArray(),
                OwnerTypes = ownerTypes.ToArray(),
                Quantities = quantities.ToArray(),
                IsCurrency = isCurrencyArr.ToArray(),
                Denominations = denominations.ToArray()
            };
        }
    }

    /// Dual-index lookup result from BuildLookup.
    public sealed class ItemLookupResult {
        public Dictionary<string, object> ByNameAndOwner { get; set; }
        public Dictionary<string, object> ByDenomAndOwner { get; set; }
        public int ItemCount { get; set; }
        public int CurrencyCount { get; set; }
    }

    /// Filter+enrichment result with parallel arrays for PS object assembly.
    public sealed class ItemFilterResult {
        public int Count { get; set; }
        public int[] Indices { get; set; }
        public string[] OwnerTypes { get; set; }
        public int[] Quantities { get; set; }
        public bool[] IsCurrency { get; set; }
        public string[] Denominations { get; set; }
    }
}
