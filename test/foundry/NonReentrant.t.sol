// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import { OrderType, BasicOrderType, ItemType, Side } from "../../contracts/lib/ConsiderationEnums.sol";
import { AdditionalRecipient } from "../../contracts/lib/ConsiderationStructs.sol";
import { Consideration } from "../../contracts/Consideration.sol";
import { OfferItem, ConsiderationItem, OrderComponents, BasicOrderParameters } from "../../contracts/lib/ConsiderationStructs.sol";
import { BaseOrderTest } from "./utils/BaseOrderTest.sol";
import { ReentrantContract } from "./utils/reentrancy/ReentrantContract.sol";
import { EntryPoint, ReentrancyPoint } from "./utils/reentrancy/ReentrantEnums.sol";
import { FulfillBasicOrderParameters, FulfillOrderParameters, FulfillAdvancedOrderParameters, FulfillAvailableOrdersParameters, FulfillAvailableAdvancedOrdersParameters, MatchOrdersParameters, MatchAdvancedOrdersParameters, CancelParameters, ValidateParameters, ReentrantCallParameters, CriteriaResolver } from "./utils/reentrancy/ReentrantStructs.sol";

contract NonReentrantTest is BaseOrderTest {
    ReentrantContract reenterer;

    /**
     * @dev Foundry fuzzes enums as uints, so we need to manually fuzz on uints and use vm.assume
     * to filter out invalid values
     */
    struct NonReentrantIntermediaryInputs {
        uint8 entryPoint;
        uint8 reentrancyPoint;
    }

    /**
     * @dev struct to test combinations of entrypoints and reentrancy points
     */
    struct NonReentrantInputs {
        EntryPoint entryPoint;
        ReentrancyPoint reentrancyPoint;
    }

    struct NonReentrantDifferentialInputs {
        Consideration consideration;
        NonReentrantInputs args;
    }

    function setUp() public virtual override {
        super.setUp();
        // reenterer = new ReentrantContract();
    }

    function testNonReentrant(NonReentrantIntermediaryInputs memory _inputs)
        public
    {
        vm.assume(_inputs.entryPoint < 7 && _inputs.reentrancyPoint < 10);
        NonReentrantInputs memory inputs = NonReentrantInputs(
            EntryPoint(_inputs.entryPoint),
            ReentrancyPoint(_inputs.reentrancyPoint)
        );
        _testNonReentrant(
            NonReentrantDifferentialInputs(consideration, inputs)
        );
        _testNonReentrant(
            NonReentrantDifferentialInputs(referenceConsideration, inputs)
        );
    }

    function constructReentrantContract(
        Consideration _consideration,
        ReentrancyPoint _reentrancyPoint
    ) internal {
        if (_reentrancyPoint == ReentrancyPoint.FulfillBasicOrder) {} else if (
            _reentrancyPoint == ReentrancyPoint.FulfillOrder
        ) {} else if (
            _reentrancyPoint == ReentrancyPoint.FulfillAdvancedOrder
        ) {} else if (
            _reentrancyPoint == ReentrancyPoint.FulfillAvailableOrders
        ) {} else if (
            _reentrancyPoint == ReentrancyPoint.FulfillAvailableAdvancedOrders
        ) {} else if (
            _reentrancyPoint == ReentrancyPoint.MatchOrders
        ) {} else if (
            _reentrancyPoint == ReentrancyPoint.MatchAdvancedOrders
        ) {} else if (_reentrancyPoint == ReentrancyPoint.Cancel) {} else if (
            _reentrancyPoint == ReentrancyPoint.Validate
        ) {}
        reenterer = new ReentrantContract(_consideration, _reentrancyPoint);
    }

    function _testNonReentrant(NonReentrantDifferentialInputs memory inputs)
        internal
        resetTokenBalancesBetweenRuns
    {
        // reenterer = new ReentrantContract(
        //     inputs.consideration,
        //     inputs.args.reentrancyPoint
        // );
    }
}
