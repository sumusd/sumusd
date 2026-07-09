// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockOracle} from "../test/mocks/MockOracle.sol";

/// @notice Local (anvil) bringup: like {SetupSepolia} but also seeds an INTENTIONALLY IMBALANCED
///         pool (flavor A $800 / flavor B $400 / flavor C $200) so the weight-tilted haircut is
///         visible in the dapp immediately. Testnet/local only — all collateral and pricing are
///         mocks (placeholder flavors stand in for whitelisted, GENIUS-Act-compliant stablecoins).
///
/// Usage:
///   anvil &
///   forge script script/SetupLocal.s.sol:SetupLocal \
///     --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract SetupLocal is Script {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint16 internal constant TILT = 500; // convex haircut sensitivity to imbalance (mild near target, steep near depletion)
    // Base redeem rate below 100% leaves headroom for the tilt to REWARD over-represented redemptions
    // (eff rises toward 100%) instead of just penalizing under-represented ones.
    uint16 internal constant BASE_STABLE = 9900; // base for the most liquid flavors (99%)
    uint16 internal constant BASE_C = 9700; // base for a conservatively-rated flavor (97%)

    function run() external {
        vm.startBroadcast();
        address admin = msg.sender;

        SumUSD sumUsd = new SumUSD(admin);
        SumUSDEngine engine = new SumUSDEngine(admin, sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));

        MockOracle oracle = new MockOracle();
        MockERC20 flavorA = new MockERC20("Flavor A", "FLAV-A", 6);
        MockERC20 flavorB = new MockERC20("Flavor B", "FLAV-B", 6);
        MockERC20 flavorC = new MockERC20("Flavor C", "FLAV-C", 18);

        oracle.setPrice(address(flavorA), WAD);
        oracle.setPrice(address(flavorB), WAD);
        oracle.setPrice(address(flavorC), WAD);

        engine.setCollateral(address(flavorA), true, BASE_STABLE, oracle);
        engine.setCollateral(address(flavorB), true, BASE_STABLE, oracle);
        engine.setCollateral(address(flavorC), true, BASE_C, oracle);
        engine.setTiltSlopeBps(TILT);

        // 2 bps redemption fee: 1 bp retained as extra backing, 1 bp routed to the fee recipient
        // (the deployer here, stands in for a treasury). redeemMix (distress exit) is exempt.
        engine.setRedeemFee(2, 1);
        engine.setFeeRecipient(admin);

        // Mint plenty to the deployer, then seed an imbalanced basket via real deposits.
        flavorA.mint(admin, 2_000_000e6);
        flavorB.mint(admin, 2_000_000e6);
        flavorC.mint(admin, 2_000_000e18);

        flavorA.approve(address(engine), type(uint256).max);
        flavorB.approve(address(engine), type(uint256).max);
        flavorC.approve(address(engine), type(uint256).max);

        engine.deposit(address(flavorA), 800e6, 0); // overweight
        engine.deposit(address(flavorB), 400e6, 0);
        engine.deposit(address(flavorC), 200e18, 0); // underweight

        vm.stopBroadcast();

        console2.log("=== SumUSD local deployment ===");
        console2.log("NEXT_PUBLIC_SUMUSD_ADDRESS=%s", address(sumUsd));
        console2.log("NEXT_PUBLIC_ENGINE_ADDRESS=%s", address(engine));
        console2.log("NEXT_PUBLIC_FLAVOR_A=%s", address(flavorA));
        console2.log("NEXT_PUBLIC_FLAVOR_B=%s", address(flavorB));
        console2.log("NEXT_PUBLIC_FLAVOR_C=%s", address(flavorC));
        console2.log("ratioBps=%s", engine.systemCollateralizationRatioBps());
        console2.log(
            "A redeemRateBps=%s  B redeemRateBps=%s  C redeemRateBps=%s",
            engine.currentRedeemRateBps(address(flavorA)),
            engine.currentRedeemRateBps(address(flavorB)),
            engine.currentRedeemRateBps(address(flavorC))
        );
    }
}
