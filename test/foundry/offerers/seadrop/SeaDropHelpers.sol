// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BaseOrderTest } from "../../utils/BaseOrderTest.sol";

import { DelegationRegistry } from "./lib/DelegationRegistry.sol";

import {
    CriteriaResolver,
    ItemType
} from "../../../../contracts/lib/ConsiderationStructs.sol";

import { OrderType } from "../../../../contracts/lib/ConsiderationEnums.sol";

import {
    ERC721SeaDrop
} from "../../../../contracts/contractOfferers/seadrop/ERC721SeaDrop.sol";

import {
    SeaDropErrorsAndEvents
} from "../../../../contracts/contractOfferers/seadrop/lib/SeaDropErrorsAndEvents.sol";

import {
    AllowListData,
    CreatorPayout,
    PublicDrop,
    MintParams
} from "../../../../contracts/contractOfferers/seadrop/lib/SeaDropStructs.sol";

import {
    ZoneInteractionErrors
} from "../../../../contracts/interfaces/ZoneInteractionErrors.sol";

import { Merkle } from "murky/Merkle.sol";

contract SeaDropHelpers is
    BaseOrderTest,
    ZoneInteractionErrors,
    SeaDropErrorsAndEvents
{
    /// @dev The contract offerer.
    ERC721SeaDrop offerer;

    /// @dev The allowed Seaport address to interact with the contract offerer.
    address[] internal allowedSeaport;

    /// @dev SeaDrop doesn't use criteria resolvers.
    CriteriaResolver[] internal criteriaResolvers;

    /// @dev The magic ConsiderationItem address to specify a consecutive mint.
    address
        internal constant _CONSECUTIVE_MINT_ERC1155_CONSIDERATION_ITEM_MAGIC_ADDRESS =
        address(uint160(0xffff << 144));

    /// @dev Token contract addresses to ignore for fuzzing.
    address[9] ignoredTokenContracts = [
        address(token1),
        address(token2),
        address(token3),
        address(test721_1),
        address(test721_2),
        address(test721_3),
        address(test1155_1),
        address(test1155_2),
        address(test1155_3)
    ];

    function setUp() public virtual override {
        super.setUp();

        // Set allowedSeaport
        allowedSeaport = new address[](1);
        allowedSeaport[0] = address(consideration);

        // Deploy DelegationRegistry to the expected address.
        address registryAddress = 0x00000000000076A84feF008CDAbe6409d2FE638B;
        address deployedRegistry = address(new DelegationRegistry());
        vm.etch(registryAddress, deployedRegistry.code);
    }

    /**
     * Drop configuration
     */
    function setSingleCreatorPayout(address creator) internal {
        CreatorPayout[] memory creatorPayouts = new CreatorPayout[](1);
        creatorPayouts[0] = CreatorPayout({
            payoutAddress: creator,
            basisPoints: 10_000
        });
        offerer.updateCreatorPayouts(creatorPayouts);
    }

    function setPublicDrop(
        uint256 mintPrice,
        uint256 maxTotalMintableByWallet,
        uint256 feeBps
    ) internal {
        PublicDrop memory publicDrop = PublicDrop({
            mintPrice: uint80(mintPrice),
            paymentToken: address(0),
            startTime: uint48(block.timestamp),
            endTime: uint48(block.timestamp + 100),
            maxTotalMintableByWallet: uint16(maxTotalMintableByWallet),
            feeBps: uint16(feeBps),
            restrictFeeRecipients: true
        });
        offerer.updatePublicDrop(publicDrop);
    }

    function setAllowListMerkleRootAndReturnProof(
        address[] memory allowList,
        uint256 proofIndex,
        MintParams memory mintParams
    ) internal returns (bytes32[] memory) {
        (bytes32 root, bytes32[] memory proof) = _createMerkleRootAndProof(
            allowList,
            proofIndex,
            mintParams
        );
        AllowListData memory allowListData = AllowListData({
            merkleRoot: root,
            publicKeyURIs: new string[](0),
            allowListURI: ""
        });
        offerer.updateAllowList(allowListData);
        return proof;
    }

    function _createMerkleRootAndProof(
        address[] memory allowList,
        uint256 proofIndex,
        MintParams memory mintParams
    ) internal returns (bytes32 root, bytes32[] memory proof) {
        require(proofIndex < allowList.length);

        // Declare a bytes32 array for the allowlist tuples.
        bytes32[] memory allowListTuples = new bytes32[](allowList.length);

        // Create allowList tuples using allowList addresses and mintParams.
        for (uint256 i = 0; i < allowList.length; i++) {
            allowListTuples[i] = keccak256(
                abi.encode(allowList[i], mintParams)
            );
        }

        // Initialize Merkle.
        Merkle m = new Merkle();

        // Get the merkle root of the allowlist tuples.
        root = m.getRoot(allowListTuples);

        // Get the merkle proof of the tuple at proofIndex.
        proof = m.getProof(allowListTuples, proofIndex);

        // Verify that the merkle root can be obtained from the proof.
        bool verified = m.verifyProof(root, proof, allowListTuples[proofIndex]);
        assertTrue(verified);
    }

    /**
     * Order helpers
     */
    function addSeaDropOfferItem(uint256 quantity) internal {
        addOfferItem(ItemType.ERC1155, address(offerer), 0, quantity, quantity);
    }

    function addSeaDropConsiderationItems(
        address feeRecipient,
        uint256 feeBps,
        uint256 totalValue
    ) internal {
        // Add consideration item for fee recipient.
        uint256 feeAmount = (totalValue * feeBps) / 10_000;
        uint256 creatorAmount = totalValue - feeAmount;
        addConsiderationItem(
            payable(feeRecipient),
            ItemType.NATIVE,
            address(0),
            0,
            feeAmount,
            feeAmount
        );

        // Add consideration items for creator payouts.
        CreatorPayout[] memory creatorPayouts = offerer.getCreatorPayouts();
        for (uint256 i = 0; i < creatorPayouts.length; i++) {
            uint256 amount = (creatorAmount * creatorPayouts[i].basisPoints) /
                10_000;
            addConsiderationItem(
                payable(creatorPayouts[i].payoutAddress),
                ItemType.NATIVE,
                address(0),
                0,
                amount,
                amount
            );
        }
    }

    function configureSeaDropOrderParameters() internal {
        _configureOrderParameters({
            offerer: address(offerer),
            zone: address(0),
            zoneHash: bytes32(0),
            salt: 0,
            useConduit: false
        });
        baseOrderParameters.orderType = OrderType.CONTRACT;
        configureOrderComponents(0);
    }
}
