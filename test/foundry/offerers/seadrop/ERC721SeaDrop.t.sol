// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SeaDropHelpers } from "./SeaDropHelpers.sol";

import {
    ERC721SeaDrop
} from "../../../../contracts/contractOfferers/seadrop/ERC721SeaDrop.sol";

import {
    CreatorPayout,
    PublicDrop,
    MintParams
} from "../../../../contracts/contractOfferers/seadrop/lib/SeaDropStructs.sol";

import {
    ConsiderationInterface
} from "../../../../contracts/interfaces/ConsiderationInterface.sol";

import {
    OfferItem,
    ConsiderationItem,
    AdvancedOrder,
    OrderComponents,
    FulfillmentComponent
} from "../../../../contracts/lib/ConsiderationStructs.sol";

import "forge-std/console.sol";

contract ERC721SeaDropTest is SeaDropHelpers {
    FuzzArgs empty;

    struct FuzzArgs {
        address feeRecipient;
        address creator;
    }

    struct Context {
        FuzzArgs args;
    }

    modifier fuzzConstraints(FuzzArgs memory args) {
        // Assume feeRecipient and creator are not the zero address.
        vm.assume(args.feeRecipient != address(0));
        vm.assume(args.creator != address(0));

        // Assume the feeRecipient is not the creator.
        vm.assume(args.feeRecipient != args.creator);

        // Assume the feeRecipient and creator are not any test token contracts.
        for (uint256 i = 0; i < ignoredTokenContracts.length; i++) {
            vm.assume(args.feeRecipient != ignoredTokenContracts[i]);
            vm.assume(args.creator != ignoredTokenContracts[i]);
        }
        _;
    }

    function testMintPublic(
        Context memory context
    ) public fuzzConstraints(context.args) {
        offerer = new ERC721SeaDrop("", "", allowedSeaport, address(0));

        address feeRecipient = context.args.feeRecipient;
        uint256 feeBps = 500;

        offerer.updateAllowedFeeRecipient(feeRecipient, true);
        offerer.setMaxSupply(10);
        setSingleCreatorPayout(context.args.creator);
        setPublicDrop(1 ether, 5, feeBps);

        addSeaDropOfferItem(3); // 3 mints
        addSeaDropConsiderationItems(feeRecipient, feeBps, 3 ether);
        configureSeaDropOrderParameters();

        address minter = address(this);
        bytes memory extraData = bytes.concat(
            bytes1(0x00), // SIP-6 version byte
            bytes1(0x00), // substandard version: public mint
            bytes20(feeRecipient),
            bytes20(minter)
        );

        AdvancedOrder memory order = AdvancedOrder({
            parameters: baseOrderParameters,
            numerator: 1,
            denominator: 1,
            signature: "",
            extraData: extraData
        });

        vm.deal(address(this), 10 ether);

        vm.expectEmit(true, true, true, true, address(offerer));
        emit SeaDropMint(
            minter,
            feeRecipient,
            address(this),
            3,
            1 ether,
            address(0),
            feeBps,
            0
        );

        consideration.fulfillAdvancedOrder{ value: 3 ether }({
            advancedOrder: order,
            criteriaResolvers: criteriaResolvers,
            fulfillerConduitKey: bytes32(0),
            recipient: address(0)
        });

        assertEq(offerer.ownerOf(1), minter);
        assertEq(offerer.ownerOf(2), minter);
        assertEq(offerer.ownerOf(3), minter);
        assertEq(context.args.creator.balance, 3 ether * 0.95);

        // Minting any more should exceed maxTotalMintableByWallet
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidContractOrder.selector,
                (uint256(uint160(address(offerer))) << 96) +
                    consideration.getContractOffererNonce(address(offerer))
            )
        );
        consideration.fulfillAdvancedOrder({
            advancedOrder: order,
            criteriaResolvers: criteriaResolvers,
            fulfillerConduitKey: bytes32(0),
            recipient: address(0)
        });
    }

    function testMintAllowList(
        Context memory context
    ) public fuzzConstraints(context.args) {
        offerer = new ERC721SeaDrop("", "", allowedSeaport, address(0));

        address feeRecipient = context.args.feeRecipient;
        uint256 feeBps = 500;

        offerer.updateAllowedFeeRecipient(feeRecipient, true);
        offerer.setMaxSupply(10);
        setSingleCreatorPayout(context.args.creator);

        MintParams memory mintParams = MintParams({
            mintPrice: 1 ether,
            paymentToken: address(0),
            maxTotalMintableByWallet: 5,
            startTime: uint48(block.timestamp),
            endTime: uint48(block.timestamp) + 1000,
            dropStageIndex: 1,
            maxTokenSupplyForStage: 1000,
            feeBps: feeBps,
            restrictFeeRecipients: false
        });

        address[] memory allowList = new address[](2);
        allowList[0] = address(this);
        allowList[1] = makeAddr("fred");
        bytes32[] memory proof = setAllowListMerkleRootAndReturnProof(
            allowList,
            0,
            mintParams
        );

        addSeaDropOfferItem(3); // 3 mints
        addSeaDropConsiderationItems(feeRecipient, feeBps, 3 ether);
        configureSeaDropOrderParameters();

        address minter = address(this);
        bytes memory extraData = bytes.concat(
            bytes1(0x00), // SIP-6 version byte
            bytes1(0x01), // substandard version: allow list mint
            bytes20(feeRecipient),
            bytes20(minter),
            abi.encode(mintParams),
            abi.encodePacked(proof)
        );

        AdvancedOrder memory order = AdvancedOrder({
            parameters: baseOrderParameters,
            numerator: 1,
            denominator: 1,
            signature: "",
            extraData: extraData
        });

        vm.deal(address(this), 10 ether);

        vm.expectEmit(true, true, true, true, address(offerer));
        emit SeaDropMint(
            minter,
            feeRecipient,
            address(this),
            3,
            1 ether,
            address(0),
            feeBps,
            1
        );

        consideration.fulfillAdvancedOrder{ value: 3 ether }({
            advancedOrder: order,
            criteriaResolvers: criteriaResolvers,
            fulfillerConduitKey: bytes32(0),
            recipient: address(0)
        });

        assertEq(offerer.ownerOf(1), minter);
        assertEq(offerer.ownerOf(2), minter);
        assertEq(offerer.ownerOf(3), minter);
        assertEq(context.args.creator.balance, 3 ether * 0.95);

        // Minting any more should exceed maxTotalMintableByWallet
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidContractOrder.selector,
                (uint256(uint160(address(offerer))) << 96) +
                    consideration.getContractOffererNonce(address(offerer))
            )
        );
        consideration.fulfillAdvancedOrder({
            advancedOrder: order,
            criteriaResolvers: criteriaResolvers,
            fulfillerConduitKey: bytes32(0),
            recipient: address(0)
        });
    }
}
