// Token balances will be kept in the join, for flexibility in their management
contract TokenJoin {
    function join(address usr, uint wad)
    function exit(address usr, uint wad)

}

contract FYTokenJoin {
    function join(address usr, uint wad)
    function exit(address usr, uint wad)

}


contract Vat {
  
    // ---- Administration ----
    function addCollateral(bytes6 id, address collateral)
    function addUnderlying(address underlying)                       
    function addSeries(bytes32 series, IERC20 underlying, IFYToken fyToken)
    function addOracle(IERC20 underlying, IERC20 collateral, IOracle oracle)

    mapping (bytes6 => address)                     chiOracles         // Chi accruals oracle for the underlying
    mapping (bytes6 => address)                     rateOracles        // Rate accruals oracle for the underlying
    mapping (bytes6 => mapping(bytes6 => address))  spotOracles        // [underlying][collateral] Spot oracles
    mapping (address => mapping(bytes6 => uint128)) safe               // safe[user][collateral] The `safe` of each user contains assets (including fyDai) that are not assigned to any vault, and therefore unencumbered.

    struct Series {
        address fyToken;
        uint32  maturity;
        // bytes8 free;
    }

    mapping (bytes12 => Series)                     series             // Series available in Vat. We can possibly use a bytes6 (3e14 possible series).
    mapping (bytes6 => bool)                        collaterals        // Collaterals available in Vat. A whole word to pack in.

    // ---- Vault ordering ----
    struct Vault {
        address owner;
        bytes12 next;
        bytes12 series;                                                // address to pack next to it. Each vault is related to only one series, which also determines the underlying.
    }

    mapping (address => bytes12)                    first              // Pointer to the first vault in the user's list. We have 20 bytes here that we can still use.
    mapping (bytes12 => Vault)                      vaults             // With a vault identifier we can get both the owner and the next in the list. When giving a vault both are changed with 1 SSTORE.

    // ---- Vault composition ----
    struct Collaterals {
        bytes6[5] ids;
        bytes2 length;
    }

    struct Balances {
        uint128 debt;
        uint128[5] assets;
    }

    // An user can own one or more Vaults, each one with a bytes12 identifier so that we can pack a singly linked list and a reverse search in a bytes32
    mapping (bytes12 => Collaterals)                vaultCollaterals   // Collaterals are identified by just 6 bytes, then in 32 bytes (one SSTORE) we can have an array of 5 collateral types to allow multi-collateral vaults. 
    mapping (bytes12 => Balances)                   vaultBalances      // Both debt and assets. The debt and the amount held for the first collateral share a word.

    // ---- Vault management ----
    // Create a new vault, linked to a series (and therefore underlying) and up to 6 collateral types
    // 2 SSTORE for series and up to 6 collateral types, plus 2 SSTORE for vault ownership.
    function build(bytes12 series, bytes32 collaterals)
        public
        returns (bytes12 id)
    {
        require (validSeries(series), "Invalid series");               // 1 SLOAD.
        bytes12 _first = first[msg.sender];                            // 1 SLOAD. Use the id of the latest vault created by the user as salt.
        bytes12 id = keccak256(msg.sender + _first)-slice(0, 12);      // Check (vaults[id].owner == address(0)), and increase the salt until a free vault id is found. 1 SLOAD per check.
        Vault memory vault = ({
            owner: msg.sender;
            next: _first;
            series: series;
        });
        first[msg.sender] = id;                                        // 1 SSTORE. We insert the new vaults in the list head.
        vaults[id] = vault;                                            // 2 SSTORE. We can still store one more address for free.

        require (validCollaterals(collaterals), "Invalid collaterals");// C SLOAD.
        Collaterals memory _collaterals = ({
            ids: collaterals.slice(0, 30);
            length: collaterals.slice(30, 32);
        });
        collaterals[id] = _collaterals;                                // 1 SSTORE
    }

    // Change a vault series and/or collateral types. 2 SSTORE.
    // We can change the series if there is no debt, or collaterals types if there is no collateral
    function tweak(bytes12 vault, bytes12 series, bytes32 collaterals)

    // Add collateral to vault. 2.5 or 3.5 SSTORE per collateral type, rounding up.
    // Remove collateral from vault. 2.5 or 3.5 SSTORE per collateral type, rounding up.
    function slip(bytes12 vault, bytes32 collaterals, int128[] memory inks)
        public returns (bytes32)
    {         // Remember that bytes32 collaterals is an array of up to 6 collateral types.
        require (validVault(vault), "Invalid vault");                                 // 1 SLOAD
        // The next 5 lines can be packed into an internal function
        require (validCollaterals(vault, collaterals), "Invalid collaterals");        // C+1 SLOAD.
        Collaterals memory _collaterals = ({
            ids: collaterals.slice(0, 30);
            length: collaterals.slice(30, 32);
        });

        Balances memory _balances = balances[vault];                                  // 1 SLOAD
        bool check;
        for each collateral {
            if (inks[collateral] > 0) {
                token.transferFrom(msg.sender, joins[collateral], inks[collateral]);  // C * 2/3 SSTORE. Should we let the Join update the balances instead?
            } else {
                if (!check) check = true;
                token.transferFrom(joins[collateral], msg.sender, -inks[collateral]); // C * 2/3 SSTORE. Should we let the Join update the balances instead?
            }
            _balances.assets[collateral] += inks[collateral];
        }
        if (check) require(level(vault) >= 0, "Undercollateralized");                 // Cost of `level`
        balances[id] = _balances;                                                     // 1 SSTORE

        return bytes32(_balances);
    }

    // Move collateral from one vault to another (like when rolling a series). 1 SSTORE for each 2 collateral types.
    function flux(bytes12 from, bytes12 to, bytes32 collaterals, uint128[] memory inks)

    // Move debt from one vault to another (like when rolling a series). 2 SSTORE.
    // Note, it won't be possible if the Vat doesn't know about pools
    function move(bytes12 from, bytes12 to, uint128 art)

    // Move collateral and debt. Combine costs of `flux` and `move`, minus 1 SSTORE.
    // Note, it won't be possible if the Vat doesn't know about pools
    function roll(bytes12 from, bytes12 to, bytes32 collaterals, uint128[] memory inks, uint128 art)

    // Transfer vault to another user. 2 or 3 SSTORE.
    function give(bytes12 vault, address user)

    // Borrow from vault and push borrowed asset to user 
    // Repay to vault and pull borrowed asset from user 
    function draw(bytes12 vault, int128 art). // 3 SSTORE.

    // Add collateral and borrow from vault, pull collaterals from and push borrowed asset to user
    // Repay to vault and remove collateral, pull borrowed asset from and push collaterals to user
    // Same cost as `slip` but with an extra cheap collateral. As low as 5 SSTORE for posting WETH and borrowing fyDai
    function frob(bytes12 vault, bytes32 collaterals,  int128[] memory inks, int128 art)
    
    // Repay vault debt using underlying token, pulled from user. Collaterals are pushed to user. 
    function close(bytes12 vault, bytes32 collaterals, uint128[] memory inks, uint128 art) // Same cost as `frob`

    // ---- Accounting ----

    // Return the vault debt in underlying terms
    function dues(bytes12 vault) view returns (uint128 uart) {
        uint32 maturity = series[vault].maturity;                         // 1 SLOAD
        IFYToken fyToken = _series.fyToken;
        if (block.timestamp >= maturity) {
            IOracle oracle = rateOracles[underlying];                     // 1 SLOAD
            uart = balances[vault].debt * oracle.accrual(maturity);       // 1 SLOAD + 1 Oracle Call
        } else {
            uart = balances[vault].debt;                                  // 1 SLOAD
        }
    }

    // Return the capacity of the vault to borrow underlying based on the collaterals held
    function value(bytes12 vault) view returns (uint128 uart) {
        Collaterals memory _collaterals = collaterals[vault];             // 1 SLOAD
        Balances memory _balances = balances[vault];                      // 1 SLOAD
        for each collateral {                                             // * C
            IOracle oracle = spotOracles[underlying][collateral];         // 1 SLOAD
            uart += _balances[collateral] * oracle.spot();                // 1 Oracle Call | Divided by collateralization ratio
        }
    }

    // Return the collateralization level of a vault. It will be negative if undercollateralized.
    function level(bytes12 vault) view returns (int128) {                 // Cost of `value` + `dues`
        return value(vault) - dues(vault);
    }

    // ---- Liquidations ----
    // Each liquidation engine can:
    // - Mark vaults as not a target for liquidation
    // - Donate assets to the Vat
    // - Cancel debt in liquidation vaults at no cost
    // - Retrieve collateral from liquidation vaults
    // - Give vaults to non-privileged users
    // Giving a user vault to a liquidation engine means it will be auctioned and liquidated.
    // The vault will be returned to the user once it's healthy.
}