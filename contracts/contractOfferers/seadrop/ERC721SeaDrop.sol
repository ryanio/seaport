// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {
    ContractOffererInterface
} from "../../interfaces/ContractOffererInterface.sol";

import {
    ERC721ContractMetadata,
    ISeaDropTokenContractMetadata
} from "./lib/ERC721ContractMetadata.sol";

import {
    AllowListData,
    CreatorPayout,
    MintParams,
    PublicDrop,
    SignedMintValidationMinMintPrice,
    SignedMintValidationParams,
    TokenGatedDropStage,
    TokenGatedMintParams
} from "./lib/SeaDropStructs.sol";

import { SeaDropErrorsAndEvents } from "./lib/SeaDropErrorsAndEvents.sol";

import {
    ERC721SeaDropStructsErrorsAndEvents
} from "./lib/ERC721SeaDropStructsErrorsAndEvents.sol";

import { ItemType } from "../../lib/ConsiderationEnums.sol";

import {
    ReceivedItem,
    Schema,
    SpentItem
} from "../../lib/ConsiderationStructs.sol";

import { IDelegationRegistry } from "./interfaces/IDelegationRegistry.sol";

import { ERC721A } from "ERC721A/ERC721A.sol";

import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {
    IERC165
} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {
    DefaultOperatorFilterer
} from "operator-filter-registry/DefaultOperatorFilterer.sol";

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {
    MerkleProof
} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

// TODO: add a IERC721SeaDrop.sol interface to replace INonFungibleSeaDropToken

import "forge-std/console.sol";

/**
 * @title  ERC721SeaDrop
 * @author James Wenzel (emo.eth)
 * @author Ryan Ghods (ralxz.eth)
 * @author Stephan Min (stephanm.eth)
 * @author Michael Cohen (notmichael.eth)
 * @notice An ERC-721 token contract that can mint as a Seaport contract
 *         offerer.
 */
contract ERC721SeaDrop is
    ERC721ContractMetadata,
    ERC721SeaDropStructsErrorsAndEvents,
    ContractOffererInterface,
    SeaDropErrorsAndEvents,
    DefaultOperatorFilterer,
    ReentrancyGuard
{
    using ECDSA for bytes32;

    /// @notice The allowed Seaport addresses.
    mapping(address => bool) internal _allowedSeaports;

    /// @notice The enumerated allowed Seaport addresses.
    address[] internal _enumeratedAllowedSeaport;

    /// @notice The conduit address that can call this contract.
    address private immutable _CONDUIT;

    /// @notice The delegation registry.
    IDelegationRegistry public constant delegationRegistry =
        IDelegationRegistry(0x00000000000076A84feF008CDAbe6409d2FE638B);

    /// @notice The public drop data.
    PublicDrop private _publicDrop;

    /// @notice The creator payout addresses and basis points.
    CreatorPayout[] private _creatorPayouts;

    /// @notice The allow list merkle root.
    bytes32 private _allowListMerkleRoot;

    /// @notice The allowed fee recipients.
    mapping(address => bool) private _allowedFeeRecipients;

    /// @notice The enumerated allowed fee recipients.
    address[] private _enumeratedFeeRecipients;

    /// @notice The parameters for allowed signers for server-side drops.
    mapping(address => SignedMintValidationParams)
        private _signedMintValidationParams;

    /// @notice The signers for each server-side drop.
    address[] private _enumeratedSigners;

    /// @notice The used signature digests.
    mapping(bytes32 => bool) private _usedDigests;

    /// @notice The allowed payers.
    mapping(address => bool) private _allowedPayers;

    /// @notice The enumerated allowed payers.
    address[] private _enumeratedPayers;

    /// @notice The token gated drop stages.
    mapping(address => TokenGatedDropStage) private _tokenGatedDrops;

    /// @notice The tokens for token gated drops.
    address[] private _enumeratedTokenGatedTokens;

    /// @notice The token IDs and redeemed counts for token gated drop stages.
    mapping(address => mapping(uint256 => uint256)) private _tokenGatedRedeemed;

    /// @notice Internal constants for EIP-712: Typed structured
    ///         data hashing and signing
    bytes32 internal constant _SIGNED_MINT_TYPEHASH =
        // prettier-ignore
        keccak256(
            "SignedMint("
                "address minter,"
                "address feeRecipient,"
                "MintParams mintParams,"
                "uint256 salt"
            ")"
            "MintParams("
                "uint256 mintPrice,"
                "address paymentToken,"
                "uint256 maxTotalMintableByWallet,"
                "uint256 startTime,"
                "uint256 endTime,"
                "uint256 dropStageIndex,"
                "uint256 maxTokenSupplyForStage,"
                "uint256 feeBps,"
                "bool restrictFeeRecipients"
            ")"
        );
    bytes32 internal constant _MINT_PARAMS_TYPEHASH =
        // prettier-ignore
        keccak256(
            "MintParams("
                "uint256 mintPrice,"
                "address paymentToken,"
                "uint256 maxTotalMintableByWallet,"
                "uint256 startTime,"
                "uint256 endTime,"
                "uint256 dropStageIndex,"
                "uint256 maxTokenSupplyForStage,"
                "uint256 feeBps,"
                "bool restrictFeeRecipients"
            ")"
        );
    bytes32 internal constant _EIP_712_DOMAIN_TYPEHASH =
        // prettier-ignore
        keccak256(
            "EIP712Domain("
                "string name,"
                "string version,"
                "uint256 chainId,"
                "address verifyingContract"
            ")"
        );
    bytes32 internal constant _NAME_HASH = keccak256("ERC721SeaDrop");
    bytes32 internal constant _VERSION_HASH = keccak256("2.0");
    uint256 internal immutable _CHAIN_ID = block.chainid;
    bytes32 internal immutable _DOMAIN_SEPARATOR;

    /**
     * @notice Constant for an unlimited `maxTokenSupplyForStage`.
     *        Used in `mintPublic` where no `maxTokenSupplyForStage`
     *        is stored in the `PublicDrop` struct.
     */
    uint256 internal constant _UNLIMITED_MAX_TOKEN_SUPPLY_FOR_STAGE =
        type(uint256).max;

    /**
     * @notice Constant for a public mint's `dropStageIndex`.
     *         Used in `mintPublic` where no `dropStageIndex`
     *         is stored in the `PublicDrop` struct.
     */
    uint256 internal constant _PUBLIC_DROP_STAGE_INDEX = 0;

    error InvalidCaller(address caller);

    /**
     * @dev Revert with an error if the order does not have the ERC1155 magic
     *      consideration item to signify a consecutive mint.
     */
    error MustSpecifyERC1155ConsiderationItemForSeaDropConsecutiveMint();

    error UnsupportedExtraDataVersion(uint8 version);
    error InvalidExtraDataEncoding(uint8 version);
    error InvalidSubstandard(uint8 substandard);
    error NotImplemented();

    /**
     * @notice Deploy the token contract.
     *
     * @param name           The name of the token.
     * @param symbol         The symbol of the token.
     * @param allowedSeaport The address of the Seaport contract allowed to interact.
     * @param allowedConduit The address of the conduit contract allowed to interact.
     */
    constructor(
        string memory name,
        string memory symbol,
        address[] memory allowedSeaport,
        address allowedConduit
    ) ERC721ContractMetadata(name, symbol) {
        // Put the length on the stack for more efficient access.
        uint256 allowedSeaportLength = allowedSeaport.length;

        // Set the mapping for allowed SeaDrop contracts.
        for (uint256 i = 0; i < allowedSeaportLength; ) {
            _allowedSeaports[allowedSeaport[i]] = true;
            unchecked {
                ++i;
            }
        }

        // Set the allowed Seaport enumeration.
        _enumeratedAllowedSeaport = allowedSeaport;

        // Set the conduit allowed to interact with this contract.
        _CONDUIT = allowedConduit;

        // Set the domain separator.
        _DOMAIN_SEPARATOR = _deriveDomainSeparator();

        // Emit an event noting the contract deployment.
        emit SeaDropTokenDeployed(SEADROP_TOKEN_TYPE.ERC721_STANDARD);
    }

    /**
     * @dev Generates a mint order with the required consideration items.
     *
     * @param fulfiller              The address of the fulfiller.
     * @param minimumReceived        The minimum items that the caller must
     *                               receive. To specify a range of ERC-721
     *                               tokens, use a null address ERC-1155 with
     *                               the amount as the quantity.
     * @param maximumSpent           Maximum items the caller is willing to
     *                               spend. Must meet or exceed the requirement.
     * @param context                Context of the order containing the mint
     *                               parameters. Can contain the contract deploy
     *                               details for contracts.
     *
     * @return offer         An array containing the offer items.
     * @return consideration An array containing the consideration items.
     */
    function generateOrder(
        address fulfiller,
        SpentItem[] calldata minimumReceived,
        SpentItem[] calldata maximumSpent,
        bytes calldata context // encoded based on the schemaID
    )
        external
        override
        returns (SpentItem[] memory offer, ReceivedItem[] memory consideration)
    {
        // Derive the offer and consideration.
        (offer, consideration) = _createOrder(
            fulfiller,
            minimumReceived,
            maximumSpent,
            context
        );
    }

    /**
     * @dev Ratifies an order, nothing additional needs to happen here.
     *
     * @param offer                The offer items.
     * @param consideration        The consideration items.
     * @param context              Additional context of the order.
     * @custom:param orderHashes   The hashes to ratify.
     * @custom:param contractNonce The nonce of the contract.
     *
     * @return The magic value required by Seaport.
     */
    function ratifyOrder(
        SpentItem[] calldata offer,
        ReceivedItem[] calldata consideration,
        bytes calldata context, // encoded based on the schemaID
        bytes32[] calldata /* orderHashes */,
        uint256 /* contractNonce */
    ) external pure override returns (bytes4) {
        // Utilize assembly to efficiently return the ratifyOrder magic value.
        assembly {
            mstore(0, 0xf4dd92ce)
            return(0x1c, 0x04)
        }
    }

    /**
     * @dev View function to preview an order generated in response to a minimum
     *      set of received items, maximum set of spent items, and context
     *      (supplied as extraData).
     *
     * @custom:param caller       The address of the caller (e.g. Seaport).
     * @param fulfiller           The address of the fulfiller.
     * @param minimumReceived     The minimum items that the caller must
     *                            receive. If empty, the fulfiller receives the
     *                            ability to transfer the NFT in question for a
     *                            secondary fee; if a single item is provided
     *                            and that item is an unminted NFT, the
     *                            fulfiller receives the ability to transfer
     *                            the NFT in question for a primary fee.
     * @param maximumSpent        Maximum items the caller is willing to spend.
     *                            Must meet or exceed the requirement.
     * @param context             Context of the order, comprised of the
     *                            the mint parameters and 0x00 version byte.
     *
     * @return offer         An array containing the offer items.
     * @return consideration An array containing the consideration items.
     */
    function previewOrder(
        address /* caller */,
        address fulfiller,
        SpentItem[] calldata minimumReceived,
        SpentItem[] calldata maximumSpent,
        bytes calldata context
    )
        external
        view
        override
        returns (SpentItem[] memory offer, ReceivedItem[] memory consideration)
    {
        // Derive the offer and consideration.
        (offer, consideration) = _validateOrder(
            fulfiller,
            minimumReceived,
            maximumSpent,
            context
        );
    }

    /**
     * @dev Gets the metadata for this contract offerer.
     *
     * @return name    The name of the contract offerer.
     * @return schemas The schemas supported by the contract offerer.
     */
    function getSeaportMetadata()
        external
        pure
        override
        returns (
            string memory name,
            Schema[] memory schemas // map to Seaport Improvement Proposal IDs
        )
    {
        schemas = new Schema[](1);

        schemas[0].id = 12;

        // Encode the SIP-12 information.
        uint256[] memory substandards = new uint256[](2);
        substandards[0] = 0;
        substandards[1] = 1;
        schemas[0].metadata = abi.encode(substandards, "No documentation");

        return ("ERC721SeaDrop", schemas);
    }

    /**
     * @dev Decodes an order and returns the offer and substandard version.
     */
    function _decodeOrder(
        address fulfiller,
        SpentItem[] calldata minimumReceived,
        SpentItem[] calldata maximumSpent,
        bytes calldata context
    ) internal view returns (SpentItem[] memory offer, uint8 substandard) {
        // Declare an error buffer; first check that the minimumReceived has the
        // this address and a non-zero "amount" as the quantity for the mint.
        uint256 errorBuffer = (
            _castAndInvert(
                minimumReceived.length == 1 &&
                    minimumReceived[0].itemType == ItemType.ERC1155 &&
                    minimumReceived[0].token == address(this) &&
                    minimumReceived[0].amount > 0
            )
        );

        // The offer is the minimumReceived.
        offer = minimumReceived;

        // Get the length of the context array from calldata (masked).
        uint256 contextLength;
        assembly {
            contextLength := and(calldataload(context.offset), 0xfffffff)
        }

        // Put the substandard version on the stack.
        substandard = uint8(context[1]);

        // Next, check for SIP-6 version byte.
        errorBuffer |= _castAndInvert(context[0] == bytes1(0x00)) << 1;

        // Next, check for supported substandard.
        errorBuffer |= _castAndInvert(substandard < 4) << 2;

        // Next, check for correct context length.
        unchecked {
            errorBuffer |= _castAndInvert(contextLength > 42) << 3;
        }

        // Handle decoding errors.
        if (errorBuffer != 0) {
            uint8 version = uint8(context[0]);

            if (errorBuffer << 255 != 0) {
                revert MustSpecifyERC1155ConsiderationItemForSeaDropConsecutiveMint();
            } else if (errorBuffer << 254 != 0) {
                revert UnsupportedExtraDataVersion(version);
            } else if (errorBuffer << 253 != 0) {
                revert InvalidSubstandard(substandard);
            } else if (errorBuffer << 252 != 0) {
                revert InvalidExtraDataEncoding(version);
            } else if (errorBuffer << 251 != 0) {}
        }
    }

    /**
     * @dev Validates an order with the required mint payment.
     *
     * @param fulfiller              The fulfiller of the order.
     * @param minimumReceived        The minimum items that the caller must
     *                               receive.
     * @param maximumSpent           The maximum items that the caller is
     *                               willing to spend.
     * @param context                Additional context of the order, comprised
     *                               of the NFT tokenID with transfer activation
     *                               (32 bytes) including the 0x00 version byte.
     *                               Unminted tokens do not need to supply any
     *                               context as the minimumReceived item holds
     *                               all necessary information.
     *
     * @return offer An array containing the offer items.
     * @return consideration An array containing the consideration items.
     */
    function _validateOrder(
        address fulfiller,
        SpentItem[] calldata minimumReceived,
        SpentItem[] calldata maximumSpent,
        bytes calldata context
    )
        internal
        view
        returns (SpentItem[] memory offer, ReceivedItem[] memory consideration)
    {
        // Define a variable for the substandard version.
        uint8 substandard;

        (offer, substandard) = _decodeOrder(
            fulfiller,
            minimumReceived,
            maximumSpent,
            context
        );

        // Quantity is the amount of the ERC-1155 min received item.
        uint256 quantity = minimumReceived[0].amount;

        // All substandards have feeRecipient and minter as first two params.
        address feeRecipient = address(bytes20(context[2:22]));
        address minter = address(bytes20(context[22:42]));

        // Put the fulfiller back on the stack to avoid stack too deep.
        address fulfiller = fulfiller;

        if (substandard == 0) {
            // 0: Public mint
            consideration = _validateMintPublic(
                feeRecipient,
                fulfiller,
                minter,
                quantity
            );
        } else if (substandard == 1) {
            // 1: Allow list mint
            MintParams memory mintParams = abi.decode(
                context[42:330],
                (MintParams)
            );
            bytes32[] memory proof = bytesToBytes32Array(context[330:]);
            consideration = _validateMintAllowList(
                feeRecipient,
                fulfiller,
                minter,
                quantity,
                mintParams,
                proof
            );
        } /* else if (substandard == 2) {
                // 2: Token gated mint
                TokenGatedMintParams memory mintParams = abi.decode(
                    context[42:100],
                    (TokenGatedMintParams)
                );
                consideration = _mintAllowedTokenHolder(
                    feeRecipient,
                    fulfiller,
                    minter,
                    mintParams
                );
            } else if (substandard == 3) {
                // 3: Signed mint
                MintParams memory mintParams = abi.decode(
                    context[42:100],
                    (MintParams)
                );
                uint256 salt = uint256(bytes32(context[100:132]));
                bytes memory signature = context[132:];
                consideration = _mintSigned(
                    feeRecipient,
                    fulfiller,
                    minter,
                    quantity,
                    mintParams,
                    salt,
                    signature
                );
            }*/
    }

    /**
     * @dev Creates an order with the required mint payment.
     *
     * @param fulfiller              The fulfiller of the order.
     * @param minimumReceived        The minimum items that the caller must
     *                               receive.
     * @param maximumSpent           The maximum items that the caller is
     *                               willing to spend.
     * @param context                Additional context of the order, comprised
     *                               of the NFT tokenID with transfer activation
     *                               (32 bytes) including the 0x00 version byte.
     *                               Unminted tokens do not need to supply any
     *                               context as the minimumReceived item holds
     *                               all necessary information.
     *
     * @return offer An array containing the offer items.
     * @return consideration An array containing the consideration items.
     */
    function _createOrder(
        address fulfiller,
        SpentItem[] calldata minimumReceived,
        SpentItem[] calldata maximumSpent,
        bytes calldata context
    )
        internal
        returns (SpentItem[] memory offer, ReceivedItem[] memory consideration)
    {
        // Define a variable for the substandard version.
        uint8 substandard;

        (offer, substandard) = _decodeOrder(
            fulfiller,
            minimumReceived,
            maximumSpent,
            context
        );

        // Quantity is the amount of the ERC-1155 min received item.
        uint256 quantity = minimumReceived[0].amount;

        // All substandards have feeRecipient and minter as first two params.
        address feeRecipient = address(bytes20(context[2:22]));
        address minter = address(bytes20(context[22:42]));

        // Put the fulfiller back on the stack to avoid stack too deep.
        address fulfiller = fulfiller;

        if (substandard == 0) {
            // 0: Public mint
            // Checks
            consideration = _validateMintPublic(
                feeRecipient,
                fulfiller,
                minter,
                quantity
            );
            // Effects
            _mintPublic(feeRecipient, fulfiller, minter, quantity);
        } else if (substandard == 1) {
            // 1: Allow list mint
            MintParams memory mintParams = abi.decode(
                context[42:330],
                (MintParams)
            );
            bytes32[] memory proof = bytesToBytes32Array(context[330:]);
            // Checks
            consideration = _validateMintAllowList(
                feeRecipient,
                fulfiller,
                minter,
                quantity,
                mintParams,
                proof
            );
            // Effects
            _mintAllowList(
                feeRecipient,
                fulfiller,
                minter,
                quantity,
                mintParams,
                proof
            );
        } /* else if (substandard == 2) {
                // 2: Token gated mint
                TokenGatedMintParams memory mintParams = abi.decode(
                    context[42:100],
                    (TokenGatedMintParams)
                );
                consideration = _mintAllowedTokenHolder(
                    feeRecipient,
                    fulfiller,
                    minter,
                    mintParams
                );
            } else if (substandard == 3) {
                // 3: Signed mint
                MintParams memory mintParams = abi.decode(
                    context[42:100],
                    (MintParams)
                );
                uint256 salt = uint256(bytes32(context[100:132]));
                bytes memory signature = context[132:];
                consideration = _mintSigned(
                    feeRecipient,
                    fulfiller,
                    minter,
                    quantity,
                    mintParams,
                    salt,
                    signature
                );
            }*/
    }

    /**
     * @notice Validate a public drop mint.
     *
     * @param feeRecipient The fee recipient.
     * @param payer        The payer of the mint.
     * @param minter       The mint recipient.
     * @param quantity     The number of tokens to mint.
     */
    function _validateMintPublic(
        address feeRecipient,
        address payer,
        address minter,
        uint256 quantity
    ) internal view returns (ReceivedItem[] memory consideration) {
        // Put the public drop data on the stack.
        PublicDrop memory publicDrop = _publicDrop;

        // Ensure that the drop has started.
        _checkActive(publicDrop.startTime, publicDrop.endTime);

        // Put the mint price on the stack.
        uint256 mintPrice = publicDrop.mintPrice;

        // Ensure the payer is allowed if not the minter.
        if (payer != minter) {
            if (
                !_allowedPayers[payer] &&
                !delegationRegistry.checkDelegateForAll(payer, minter)
            ) {
                revert PayerNotAllowed();
            }
        }

        // Check the number of mints are available.
        _checkMintQuantity(
            minter,
            quantity,
            publicDrop.maxTotalMintableByWallet,
            _UNLIMITED_MAX_TOKEN_SUPPLY_FOR_STAGE
        );

        // Check that the fee recipient is allowed if restricted.
        _checkFeeRecipientIsAllowed(
            feeRecipient,
            publicDrop.restrictFeeRecipients
        );

        // Set the required consideration items.
        consideration = _requiredItems(
            quantity,
            publicDrop.mintPrice,
            publicDrop.paymentToken,
            feeRecipient,
            publicDrop.feeBps
        );
    }

    /**
     * @notice Effects for minting a public drop.
     *
     * @param feeRecipient The fee recipient.
     * @param payer        The payer of the mint.
     * @param minter       The mint recipient.
     * @param quantity     The number of tokens to mint.
     */
    function _mintPublic(
        address feeRecipient,
        address payer,
        address minter,
        uint256 quantity
    ) internal {
        // Put the public drop data on the stack.
        PublicDrop memory publicDrop = _publicDrop;

        // Emit an event for the mint, for analytics.
        _emitSeaDropMint(
            minter,
            feeRecipient,
            payer,
            quantity,
            publicDrop.mintPrice,
            publicDrop.paymentToken,
            publicDrop.feeBps,
            _PUBLIC_DROP_STAGE_INDEX
        );
    }

    /**
     * @notice Validate mint from an allow list.
     *
     * @param feeRecipient The fee recipient.
     * @param payer        The payer of the mint.
     * @param minter       The mint recipient.
     * @param quantity     The number of tokens to mint.
     * @param mintParams   The mint parameters.
     * @param proof        The proof for the leaf of the allow list.
     */
    function _validateMintAllowList(
        address feeRecipient,
        address payer,
        address minter,
        uint256 quantity,
        MintParams memory mintParams,
        bytes32[] memory proof
    ) internal view returns (ReceivedItem[] memory consideration) {
        // Check that the drop stage is active.
        _checkActive(mintParams.startTime, mintParams.endTime);

        // Put the mint price on the stack.
        uint256 mintPrice = mintParams.mintPrice;

        // Ensure the payer is allowed if not the minter.
        if (payer != minter) {
            if (
                !_allowedPayers[payer] &&
                !delegationRegistry.checkDelegateForAll(payer, minter)
            ) {
                revert PayerNotAllowed();
            }
        }

        // Check that the minter is allowed to mint the desired quantity.
        _checkMintQuantity(
            minter,
            quantity,
            mintParams.maxTotalMintableByWallet,
            mintParams.maxTokenSupplyForStage
        );

        // Check that the fee recipient is allowed if restricted.
        _checkFeeRecipientIsAllowed(
            feeRecipient,
            mintParams.restrictFeeRecipients
        );

        // Verify the proof.
        if (
            !MerkleProof.verify(
                proof,
                _allowListMerkleRoot,
                keccak256(abi.encode(minter, mintParams))
            )
        ) {
            revert InvalidProof();
        }

        // Set the required consideration items.
        consideration = _requiredItems(
            quantity,
            mintParams.mintPrice,
            mintParams.paymentToken,
            feeRecipient,
            mintParams.feeBps
        );
    }

    /**
     * @notice Effects for minting from an allow list.
     *
     * @param feeRecipient The fee recipient.
     * @param payer        The payer of the mint.
     * @param minter       The mint recipient.
     * @param quantity     The number of tokens to mint.
     * @param mintParams   The mint parameters.
     * @param proof        The proof for the leaf of the allow list.
     */
    function _mintAllowList(
        address feeRecipient,
        address payer,
        address minter,
        uint256 quantity,
        MintParams memory mintParams,
        bytes32[] memory proof
    ) internal {
        // Emit an event for the mint, for analytics.
        _emitSeaDropMint(
            minter,
            feeRecipient,
            payer,
            quantity,
            mintParams.mintPrice,
            mintParams.paymentToken,
            mintParams.feeBps,
            mintParams.dropStageIndex
        );
    }

    /**
     * @notice Mint with a server-side signature.
     *         Note that a signature can only be used once.
     *
     * @param feeRecipient The fee recipient.
     * @param payer        The payer of the mint.
     * @param minter       The mint recipient.
     * @param quantity     The number of tokens to mint.
     * @param mintParams   The mint parameters.
     * @param salt         The salt for the signed mint.
     * @param signature    The server-side signature, must be an allowed
     *                     signer.
     */
    function _mintSigned(
        address feeRecipient,
        address payer,
        address minter,
        uint256 quantity,
        MintParams memory mintParams,
        uint256 salt,
        bytes memory signature
    ) internal returns (ReceivedItem[] memory consideration) {
        // Check that the drop stage is active.
        _checkActive(mintParams.startTime, mintParams.endTime);

        // Ensure the payer is allowed if not the minter.
        if (minter != payer) {
            if (
                !_allowedPayers[payer] &&
                !delegationRegistry.checkDelegateForAll(payer, minter)
            ) {
                revert PayerNotAllowed();
            }
        }

        // Check that the minter is allowed to mint the desired quantity.
        _checkMintQuantity(
            minter,
            quantity,
            mintParams.maxTotalMintableByWallet,
            mintParams.maxTokenSupplyForStage
        );

        // Check that the fee recipient is allowed if restricted.
        _checkFeeRecipientIsAllowed(
            feeRecipient,
            mintParams.restrictFeeRecipients
        );

        // Validate the signature in a block scope to avoid "stack too deep".
        {
            // Get the digest to verify the EIP-712 signature.
            bytes32 digest = _getDigest(minter, feeRecipient, mintParams, salt);

            // Ensure the digest has not already been used.
            if (_usedDigests[digest]) {
                revert SignatureAlreadyUsed();
            }

            // Mark the digest as used.
            _usedDigests[digest] = true;

            // Use the recover method to see what address was used to create
            // the signature on this data.
            // Note that if the digest doesn't exactly match what was signed we'll
            // get a random recovered address.
            address recoveredAddress = digest.recover(signature);
            _validateSignerAndParams(mintParams, recoveredAddress);
        }

        // Set the required consideration items.
        consideration = _requiredItems(
            quantity,
            mintParams.mintPrice,
            mintParams.paymentToken,
            feeRecipient,
            mintParams.feeBps
        );

        // Emit an event for the mint, for analytics.
        _emitSeaDropMint(
            minter,
            feeRecipient,
            payer,
            quantity,
            mintParams.mintPrice,
            mintParams.paymentToken,
            mintParams.feeBps,
            mintParams.dropStageIndex
        );
    }

    /**
     * @notice Enforce stored parameters for signed mints to mitigate
     *         the effects of a malicious signer.
     */
    function _validateSignerAndParams(
        MintParams memory mintParams,
        address signer
    ) internal view {
        SignedMintValidationParams
            memory signedMintValidationParams = _signedMintValidationParams[
                signer
            ];

        // Check that SignedMintValidationParams have been initialized; if not,
        // this is an invalid signer.
        if (signedMintValidationParams.maxMaxTotalMintableByWallet == 0) {
            revert InvalidSignature(signer);
        }

        // Validate individual params.
        uint256 minMintPrice;
        uint256 validationMintPriceLength = signedMintValidationParams
            .minMintPrices
            .length;
        for (uint256 i = 0; i < validationMintPriceLength; ) {
            if (
                mintParams.paymentToken ==
                signedMintValidationParams.minMintPrices[i].paymentToken
            ) {
                minMintPrice = signedMintValidationParams
                    .minMintPrices[i]
                    .minMintPrice;
                break;
            }
            // Revert if we've iterated through the whole array without finding
            // a match.
            if (i == validationMintPriceLength - 1) {
                revert SignedMintValidationParamsMinMintPriceNotSetForToken(
                    mintParams.paymentToken
                );
            }
            unchecked {
                ++i;
            }
        }
        if (mintParams.mintPrice < minMintPrice) {
            revert InvalidSignedMintPrice(
                mintParams.paymentToken,
                mintParams.mintPrice,
                minMintPrice
            );
        }
        if (
            mintParams.maxTotalMintableByWallet >
            signedMintValidationParams.maxMaxTotalMintableByWallet
        ) {
            revert InvalidSignedMaxTotalMintableByWallet(
                mintParams.maxTotalMintableByWallet,
                signedMintValidationParams.maxMaxTotalMintableByWallet
            );
        }
        if (mintParams.startTime < signedMintValidationParams.minStartTime) {
            revert InvalidSignedStartTime(
                mintParams.startTime,
                signedMintValidationParams.minStartTime
            );
        }
        if (mintParams.endTime > signedMintValidationParams.maxEndTime) {
            revert InvalidSignedEndTime(
                mintParams.endTime,
                signedMintValidationParams.maxEndTime
            );
        }
        if (
            mintParams.maxTokenSupplyForStage >
            signedMintValidationParams.maxMaxTokenSupplyForStage
        ) {
            revert InvalidSignedMaxTokenSupplyForStage(
                mintParams.maxTokenSupplyForStage,
                signedMintValidationParams.maxMaxTokenSupplyForStage
            );
        }
        if (mintParams.feeBps > signedMintValidationParams.maxFeeBps) {
            revert InvalidSignedFeeBps(
                mintParams.feeBps,
                signedMintValidationParams.maxFeeBps
            );
        }
        if (mintParams.feeBps < signedMintValidationParams.minFeeBps) {
            revert InvalidSignedFeeBps(
                mintParams.feeBps,
                signedMintValidationParams.minFeeBps
            );
        }
        if (!mintParams.restrictFeeRecipients) {
            revert SignedMintsMustRestrictFeeRecipients();
        }
    }

    /**
     * @notice Mint as an allowed token holder.
     *         This will mark the token ids as redeemed and will revert if the
     *         same token id is attempted to be redeemed twice.
     *
     * @param feeRecipient The fee recipient.
     * @param payer        The payer of the mint.
     * @param minter       The mint recipient.
     * @param mintParams   The token gated mint params.
     */
    function _mintAllowedTokenHolder(
        address feeRecipient,
        address payer,
        address minter,
        TokenGatedMintParams memory mintParams
    ) internal returns (ReceivedItem[] memory consideration) {
        // Ensure the payer is allowed if not the minter.
        if (payer != minter) {
            if (
                !_allowedPayers[payer] &&
                !delegationRegistry.checkDelegateForAll(payer, minter)
            ) {
                revert PayerNotAllowed();
            }
        }

        // Put the allowedNftToken on the stack for more efficient access.
        address allowedNftToken = mintParams.allowedNftToken;

        // Set the dropStage to a variable.
        TokenGatedDropStage memory dropStage = _tokenGatedDrops[
            allowedNftToken
        ];

        // Validate that the dropStage is active.
        _checkActive(dropStage.startTime, dropStage.endTime);

        // Check that the fee recipient is allowed if restricted.
        _checkFeeRecipientIsAllowed(
            feeRecipient,
            dropStage.restrictFeeRecipients
        );

        // Put the length on the stack for more efficient access.
        uint256 allowedNftTokenIdsLength = mintParams.allowedNftTokenIds.length;

        // Revert if the token IDs and amounts are not the same length.
        if (allowedNftTokenIdsLength != mintParams.amounts.length) {
            revert TokenGatedTokenIdsAndAmountsLengthMismatch();
        }

        // Track the total number of mints requested.
        uint256 totalMintQuantity;

        // Iterate through each allowedNftTokenId
        // to ensure it is not already fully redeemed.
        for (uint256 i = 0; i < allowedNftTokenIdsLength; ) {
            // Put the tokenId on the stack.
            uint256 tokenId = mintParams.allowedNftTokenIds[i];

            // Put the amount on the stack.
            uint256 amount = mintParams.amounts[i];

            // Check that the minter is the owner of the allowedNftTokenId.
            if (IERC721(allowedNftToken).ownerOf(tokenId) != minter) {
                revert TokenGatedNotTokenOwner(allowedNftToken, tokenId);
            }

            // Cache the storage pointer for cheaper access.
            mapping(uint256 => uint256)
                storage redeemedTokenIds = _tokenGatedRedeemed[allowedNftToken];

            // Check that the token id has not already been redeemed to its limit.
            if (
                redeemedTokenIds[tokenId] + amount >
                dropStage.maxMintablePerRedeemedToken
            ) {
                revert TokenGatedTokenIdMintExceedsQuantityRemaining(
                    allowedNftToken,
                    tokenId,
                    dropStage.maxMintablePerRedeemedToken,
                    redeemedTokenIds[tokenId],
                    amount
                );
            }

            // Increase mint count on redeemed token id.
            redeemedTokenIds[tokenId] += amount;

            // Add to the total mint quantity.
            totalMintQuantity += amount;

            unchecked {
                ++i;
            }
        }

        // Check that the minter is allowed to mint the desired quantity.
        _checkMintQuantity(
            minter,
            totalMintQuantity,
            dropStage.maxTotalMintableByWallet,
            dropStage.maxTokenSupplyForStage
        );

        // Set the required consideration items.
        consideration = _requiredItems(
            totalMintQuantity,
            dropStage.mintPrice,
            dropStage.paymentToken,
            feeRecipient,
            dropStage.feeBps
        );

        // Emit an event for the mint, for analytics.
        _emitSeaDropMint(
            minter,
            feeRecipient,
            payer,
            totalMintQuantity,
            dropStage.mintPrice,
            dropStage.paymentToken,
            dropStage.feeBps,
            dropStage.dropStageIndex
        );
    }

    /**
     * @notice Check that the drop stage is active.
     *
     * @param startTime The drop stage start time.
     * @param endTime   The drop stage end time.
     */
    function _checkActive(uint256 startTime, uint256 endTime) internal view {
        if (
            _cast(block.timestamp < startTime) |
                _cast(block.timestamp > endTime) ==
            1
        ) {
            // Revert if the drop stage is not active.
            revert NotActive(block.timestamp, startTime, endTime);
        }
    }

    /**
     * @notice Check that the fee recipient is allowed.
     *
     * @param feeRecipient          The fee recipient.
     * @param restrictFeeRecipients If the fee recipients are restricted.
     */
    function _checkFeeRecipientIsAllowed(
        address feeRecipient,
        bool restrictFeeRecipients
    ) internal view {
        // Ensure the fee recipient is not the zero address.
        if (feeRecipient == address(0)) {
            revert FeeRecipientCannotBeZeroAddress();
        }

        // Revert if the fee recipient is restricted and not allowed.
        if (restrictFeeRecipients)
            if (!_allowedFeeRecipients[feeRecipient]) {
                revert FeeRecipientNotAllowed();
            }
    }

    /**
     * @notice Check that the wallet is allowed to mint the desired quantity.
     *
     * @param minter                   The mint recipient.
     * @param quantity                 The number of tokens to mint.
     * @param maxTotalMintableByWallet The max allowed mints per wallet.
     * @param maxTokenSupplyForStage   The max token supply for the drop stage.
     */
    function _checkMintQuantity(
        address minter,
        uint256 quantity,
        uint256 maxTotalMintableByWallet,
        uint256 maxTokenSupplyForStage
    ) internal view {
        // Mint quantity of zero is not valid.
        if (quantity == 0) {
            revert MintQuantityCannotBeZero();
        }

        // Get the mint stats.
        (
            uint256 minterNumMinted,
            uint256 currentTotalSupply,
            uint256 maxSupply
        ) = this.getMintStats(minter);

        // Ensure mint quantity doesn't exceed maxTotalMintableByWallet.
        if (quantity + minterNumMinted > maxTotalMintableByWallet) {
            revert MintQuantityExceedsMaxMintedPerWallet(
                quantity + minterNumMinted,
                maxTotalMintableByWallet
            );
        }

        // Ensure mint quantity doesn't exceed maxSupply.
        if (quantity + currentTotalSupply > maxSupply) {
            revert MintQuantityExceedsMaxSupply(
                quantity + currentTotalSupply,
                maxSupply
            );
        }

        // Ensure mint quantity doesn't exceed maxTokenSupplyForStage.
        if (quantity + currentTotalSupply > maxTokenSupplyForStage) {
            revert MintQuantityExceedsMaxTokenSupplyForStage(
                quantity + currentTotalSupply,
                maxTokenSupplyForStage
            );
        }
    }

    /**
     * @notice Derive the required consideration items for the mint,
     *         includes the fee recipient and creator payouts.
     *
     * @param quantity     The number of tokens to mint.
     * @param mintPrice    The mint price per token.
     * @param paymentToken The payment token.
     * @param feeRecipient The fee recipient.
     * @param feeBps       The fee basis points.
     */
    function _requiredItems(
        uint256 quantity,
        uint256 mintPrice,
        address paymentToken,
        address feeRecipient,
        uint256 feeBps
    ) internal view returns (ReceivedItem[] memory receivedItems) {
        // If the mint price is zero, return early as there
        // are no required consideration items.
        if (mintPrice == 0) return new ReceivedItem[](0);

        // Revert if the fee basis points are greater than 10_000.
        if (feeBps > 10_000) {
            revert InvalidFeeBps(feeBps);
        }

        // Set the itemType.
        ItemType itemType = paymentToken == address(0)
            ? ItemType.NATIVE
            : ItemType.ERC20;

        // Put the total mint price on the stack.
        uint256 totalMintPrice = quantity * mintPrice;

        // Get the fee amount.
        // Note that the fee amount is rounded down in favor of the creator.
        uint256 feeAmount = (totalMintPrice * feeBps) / 10_000;

        // Get the creator payout amount.
        // Fee amount is <= totalMintPrice per above.
        uint256 payoutAmount;
        unchecked {
            payoutAmount = totalMintPrice - feeAmount;
        }

        // Put the creator payouts on the stack.
        CreatorPayout[] storage creatorPayouts = _creatorPayouts;

        // Put the length of total creator payouts on the stack.
        uint256 creatorPayoutsLength = creatorPayouts.length;

        // Put the start index including the fee on the stack.
        uint256 startIndexWithFee = feeAmount > 0 ? 1 : 0;

        // Initialize the returned array with the correct length.
        receivedItems = new ReceivedItem[](
            startIndexWithFee + creatorPayoutsLength
        );

        // Add a consideration item for the fee recipient.
        if (feeAmount > 0) {
            receivedItems[0] = ReceivedItem({
                itemType: itemType,
                token: paymentToken,
                identifier: uint256(0),
                amount: feeAmount,
                recipient: payable(feeRecipient)
            });
        }

        // Add a consideration item for each creator payout.
        for (uint256 i = 0; i < creatorPayoutsLength; ) {
            // Put the creator payout on the stack.
            CreatorPayout memory creatorPayout = creatorPayouts[i];

            // Ensure the creator payout address is not the zero address.
            if (creatorPayout.payoutAddress == address(0)) {
                revert CreatorPayoutAddressCannotBeZeroAddress();
            }

            // Get the creator payout amount.
            // Note that the payout amount is rounded down.
            uint256 creatorPayoutAmount = (payoutAmount *
                creatorPayout.basisPoints) / 10_000;

            receivedItems[startIndexWithFee + i] = ReceivedItem({
                itemType: itemType,
                token: paymentToken,
                identifier: uint256(0),
                amount: creatorPayoutAmount,
                recipient: payable(creatorPayout.payoutAddress)
            });

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Emits an event for the mint, for analytics.
     *
     * @param minter         The mint recipient.
     * @param payer          The address that payed for the mint.
     * @param quantity       The number of tokens to mint.
     * @param mintPrice      The mint price per token.
     * @param paymentToken   The payment token. Null for native token.
     * @param dropStageIndex The drop stage index.
     * @param feeBps         The fee basis points.
     * @param feeRecipient   The fee recipient.
     */
    function _emitSeaDropMint(
        address minter,
        address feeRecipient,
        address payer,
        uint256 quantity,
        uint256 mintPrice,
        address paymentToken,
        uint256 feeBps,
        uint256 dropStageIndex
    ) internal {
        // Emit an event for the mint.
        emit SeaDropMint(
            minter,
            feeRecipient,
            payer,
            quantity,
            mintPrice,
            paymentToken,
            feeBps,
            dropStageIndex
        );
    }

    /**
     * @dev Internal view function to get the EIP-712 domain separator. If the
     *      chainId matches the chainId set on deployment, the cached domain
     *      separator will be returned; otherwise, it will be derived from
     *      scratch.
     *
     * @return The domain separator.
     */
    function _domainSeparator() internal view returns (bytes32) {
        // prettier-ignore
        return block.chainid == _CHAIN_ID
            ? _DOMAIN_SEPARATOR
            : _deriveDomainSeparator();
    }

    /**
     * @dev Internal view function to derive the EIP-712 domain separator.
     *
     * @return The derived domain separator.
     */
    function _deriveDomainSeparator() internal view returns (bytes32) {
        // prettier-ignore
        return keccak256(
            abi.encode(
                _EIP_712_DOMAIN_TYPEHASH,
                _NAME_HASH,
                _VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Returns the mint public drop data.
     */
    function getPublicDrop() external view returns (PublicDrop memory) {
        return _publicDrop;
    }

    /**
     * @notice Returns the creator payouts for the nft contract.
     */
    function getCreatorPayouts()
        external
        view
        returns (CreatorPayout[] memory)
    {
        return _creatorPayouts;
    }

    /**
     * @notice Returns the allow list merkle root for the nft contract.
     */
    function getAllowListMerkleRoot() external view returns (bytes32) {
        return _allowListMerkleRoot;
    }

    /**
     * @notice Returns if the specified fee recipient is allowed
     *         for the nft contract.
     */
    function getFeeRecipientIsAllowed(
        address feeRecipient
    ) external view returns (bool) {
        return _allowedFeeRecipients[feeRecipient];
    }

    /**
     * @notice Returns an enumeration of allowed fee recipients
     *         when fee recipients are enforced.
     */
    function getAllowedFeeRecipients()
        external
        view
        returns (address[] memory)
    {
        return _enumeratedFeeRecipients;
    }

    /**
     * @notice Returns the server-side signers.
     */
    function getSigners() external view returns (address[] memory) {
        return _enumeratedSigners;
    }

    /**
     * @notice Returns the struct of SignedMintValidationParams for a signer.
     *
     * @param signer      The signer.
     */
    function getSignedMintValidationParams(
        address signer
    ) external view returns (SignedMintValidationParams memory) {
        return _signedMintValidationParams[signer];
    }

    /**
     * @notice Returns the allowed payers.
     */
    function getPayers() external view returns (address[] memory) {
        return _enumeratedPayers;
    }

    /**
     * @notice Returns if the specified payer is allowed.
     *
     * @param payer The payer.
     */
    function getPayerIsAllowed(address payer) external view returns (bool) {
        return _allowedPayers[payer];
    }

    /**
     * @notice Returns the allowed token gated drop tokens.
     */
    function getTokenGatedAllowedTokens()
        external
        view
        returns (address[] memory)
    {
        return _enumeratedTokenGatedTokens;
    }

    /**
     * @notice Returns the token gated drop data for the token gated nft.
     */
    function getTokenGatedDrop(
        address allowedNftToken
    ) external view returns (TokenGatedDropStage memory) {
        return _tokenGatedDrops[allowedNftToken];
    }

    /**
     * @notice Returns the redeemed count for a token id for a
     *         token gated drop.
     *
     * @param allowedNftToken   The token gated nft token.
     * @param allowedNftTokenId The token gated nft token id to check.
     */
    function getAllowedNftTokenIdRedeemedCount(
        address allowedNftToken,
        uint256 allowedNftTokenId
    ) external view returns (uint256) {
        return _tokenGatedRedeemed[allowedNftToken][allowedNftTokenId];
    }

    /**
     * @notice Emits an event to notify update of the drop URI.
     *
     *         Only the owner can use this function.
     *
     * @param dropURI The new drop URI.
     */
    function updateDropURI(string calldata dropURI) external {
        // Ensure the sender is only the owner or contract itself.
        _onlyOwnerOrSelf();

        // Emit an event with the update.
        emit DropURIUpdated(dropURI);
    }

    /**
     * @notice Updates the public drop data and emits an event.
     *
     *         Only the owner can use this function.
     *
     * @param publicDrop The public drop data.
     */
    function updatePublicDrop(PublicDrop calldata publicDrop) external {
        // Ensure the sender is only the owner or contract itself.
        _onlyOwnerOrSelf();

        // Revert if the fee basis points is greater than 10_000.
        if (publicDrop.feeBps > 10_000) {
            revert InvalidFeeBps(publicDrop.feeBps);
        }

        // Set the public drop data.
        _publicDrop = publicDrop;

        // Emit an event with the update.
        emit PublicDropUpdated(publicDrop);
    }

    /**
     * @notice Updates the allow list merkle root for the nft contract
     *         and emits an event.
     *
     *         Only the owner can use this function.
     *
     * @param allowListData The allow list data.
     */
    function updateAllowList(AllowListData calldata allowListData) external {
        // Ensure the sender is only the owner or contract itself.
        _onlyOwnerOrSelf();

        // Track the previous root.
        bytes32 prevRoot = _allowListMerkleRoot;

        // Update the merkle root.
        _allowListMerkleRoot = allowListData.merkleRoot;

        // Emit an event with the update.
        emit AllowListUpdated(
            prevRoot,
            allowListData.merkleRoot,
            allowListData.publicKeyURIs,
            allowListData.allowListURI
        );
    }

    /**
     * @notice Updates the token gated drop stage for the nft contract
     *         and emits an event.
     *
     *         Only the owner can use this function.
     *
     *         Note: If two INonFungibleSeaDropToken tokens are doing
     *         simultaneous token gated drop promotions for each other,
     *         they can be minted by the same actor until
     *         `maxTokenSupplyForStage` is reached. Please ensure the
     *         `allowedNftToken` is not running an active drop during
     *         the `dropStage` time period.
     *
     * @param allowedNftToken The token gated nft token.
     * @param dropStage       The token gated drop stage data.
     */
    function updateTokenGatedDrop(
        address allowedNftToken,
        TokenGatedDropStage calldata dropStage
    ) external {
        // Ensure the sender is only the owner or contract itself.
        _onlyOwnerOrSelf();

        // Ensure the allowedNftToken is not the zero address.
        if (allowedNftToken == address(0)) {
            revert TokenGatedDropAllowedNftTokenCannotBeZeroAddress();
        }

        // Ensure the allowedNftToken is not the drop token itself.
        if (allowedNftToken == address(this)) {
            revert TokenGatedDropAllowedNftTokenCannotBeDropToken();
        }

        // Revert if the fee basis points are greater than 10_000.
        if (dropStage.feeBps > 10_000) {
            revert InvalidFeeBps(dropStage.feeBps);
        }

        // Use maxTotalMintableByWallet != 0 as a signal that this update should
        // add or update the drop stage, otherwise we will be removing.
        bool addOrUpdateDropStage = dropStage.maxTotalMintableByWallet != 0;

        // Get pointers to the token gated drop data and enumerated addresses.
        TokenGatedDropStage storage existingDropStageData = _tokenGatedDrops[
            allowedNftToken
        ];
        address[] storage enumeratedTokens = _enumeratedTokenGatedTokens;

        // Stage struct packs to a single slot, so load it
        // as a uint256; if it is 0, it is empty.
        bool dropStageDoesNotExist;
        assembly {
            dropStageDoesNotExist := iszero(sload(existingDropStageData.slot))
        }

        if (addOrUpdateDropStage) {
            _tokenGatedDrops[allowedNftToken] = dropStage;
            // Add to enumeration if it does not exist already.
            if (dropStageDoesNotExist) {
                enumeratedTokens.push(allowedNftToken);
            }
        } else {
            // Check we are not deleting a drop stage that does not exist.
            if (dropStageDoesNotExist) {
                revert TokenGatedDropStageNotPresent();
            }
            // Clear storage slot and remove from enumeration.
            delete _tokenGatedDrops[allowedNftToken];
            _removeFromEnumeration(allowedNftToken, enumeratedTokens);
        }

        // Emit an event with the update.
        emit TokenGatedDropStageUpdated(allowedNftToken, dropStage);
    }

    /**
     * @notice Updates the creator payouts and emits an event.
     *         The basis points must add up to 10_000 exactly.
     *
     *         Only the owner can use this function.
     *
     * @param creatorPayouts The creator payout address and basis points.
     */
    function updateCreatorPayouts(
        CreatorPayout[] calldata creatorPayouts
    ) external {
        // Ensure the sender is only the owner or contract itself.
        _onlyOwnerOrSelf();

        // Reset the creator payout array.
        delete _creatorPayouts;

        // Track the total bais points.
        uint256 totalBasisPoints;

        // Put the total creator payouts length on the stack.
        uint256 creatorPayoutsLength = creatorPayouts.length;

        for (uint256 i; i < creatorPayoutsLength; i++) {
            // Get the creator payout.
            CreatorPayout memory creatorPayout = creatorPayouts[i];

            // Ensure the creator payout address is not the zero address.
            if (creatorPayout.payoutAddress == address(0)) {
                revert CreatorPayoutAddressCannotBeZeroAddress();
            }

            // Ensure the basis points are not zero.
            if (creatorPayout.basisPoints == 0) {
                revert CreatorPayoutBasisPointsCannotBeZero();
            }

            // Add to the total basis points.
            totalBasisPoints += creatorPayout.basisPoints;

            // Push to storage.
            _creatorPayouts.push(creatorPayout);
        }

        // Ensure the total basis points equals 10_000 exactly.
        if (totalBasisPoints != 10_000) {
            revert InvalidCreatorPayoutTotalBasisPoints(totalBasisPoints);
        }

        // Emit an event with the update.
        emit CreatorPayoutsUpdated(creatorPayouts);
    }

    /**
     * @notice Updates the allowed fee recipient and emits an event.
     *
     *         Only the owner can use this function.
     *
     * @param feeRecipient The fee recipient.
     * @param allowed      If the fee recipient is allowed.
     */
    function updateAllowedFeeRecipient(
        address feeRecipient,
        bool allowed
    ) external {
        // Ensure the sender is only the owner or contract itself.
        _onlyOwnerOrSelf();

        if (feeRecipient == address(0)) {
            revert FeeRecipientCannotBeZeroAddress();
        }

        // Track the enumerated storage.
        address[] storage enumeratedStorage = _enumeratedFeeRecipients;
        mapping(address => bool)
            storage feeRecipientsMap = _allowedFeeRecipients;

        if (allowed) {
            if (feeRecipientsMap[feeRecipient]) {
                revert DuplicateFeeRecipient();
            }
            feeRecipientsMap[feeRecipient] = true;
            enumeratedStorage.push(feeRecipient);
        } else {
            if (!feeRecipientsMap[feeRecipient]) {
                revert FeeRecipientNotPresent();
            }
            delete _allowedFeeRecipients[feeRecipient];
            _removeFromEnumeration(feeRecipient, enumeratedStorage);
        }

        // Emit an event with the update.
        emit AllowedFeeRecipientUpdated(feeRecipient, allowed);
    }

    /**
     * @notice Updates the allowed server-side signers and emits an event.
     *
     *         Only the owner can use this function.
     *
     * @param signer                     The signer to update.
     * @param signedMintValidationParams Minimum and maximum parameters
     *                                   to enforce for signed mints.
     */
    function updateSignedMintValidationParams(
        address signer,
        SignedMintValidationParams calldata signedMintValidationParams
    ) external {
        // Ensure the sender is only the owner or contract itself.
        _onlyOwnerOrSelf();

        if (signer == address(0)) {
            revert SignerCannotBeZeroAddress();
        }

        // Revert if the min or max fee bps is greater than 10_000.
        if (signedMintValidationParams.minFeeBps > 10_000) {
            revert InvalidFeeBps(signedMintValidationParams.minFeeBps);
        }
        if (signedMintValidationParams.maxFeeBps > 10_000) {
            revert InvalidFeeBps(signedMintValidationParams.maxFeeBps);
        }

        // Revert if at least one payment token min mint price is not set.
        if (signedMintValidationParams.minMintPrices.length == 0) {
            revert SignedMintValidationParamsMinMintPriceNotSet();
        }

        // Track the enumerated storage.
        address[] storage enumeratedStorage = _enumeratedSigners;
        mapping(address => SignedMintValidationParams)
            storage signedMintValidationParamsMap = _signedMintValidationParams;
        SignedMintValidationParams
            storage existingSignedMintValidationParams = signedMintValidationParamsMap[
                signer
            ];

        bool signedMintValidationParamsDoNotExist;
        assembly {
            signedMintValidationParamsDoNotExist := iszero(
                sload(existingSignedMintValidationParams.slot)
            )
        }
        // Use maxMaxTotalMintableByWallet as sentry for add/update or delete.
        bool addOrUpdate = signedMintValidationParams
            .maxMaxTotalMintableByWallet > 0;

        if (addOrUpdate) {
            signedMintValidationParamsMap[signer] = signedMintValidationParams;
            if (signedMintValidationParamsDoNotExist) {
                enumeratedStorage.push(signer);
            }
        } else {
            if (
                existingSignedMintValidationParams
                    .maxMaxTotalMintableByWallet == 0
            ) {
                revert SignerNotPresent();
            }
            delete _signedMintValidationParams[signer];
            _removeFromEnumeration(signer, enumeratedStorage);
        }

        // Emit an event with the update.
        emit SignedMintValidationParamsUpdated(
            signer,
            signedMintValidationParams
        );
    }

    /**
     * @notice Updates the allowed payer and emits an event.
     *
     *         Only the owner can use this function.
     *
     * @param payer   The payer to add or remove.
     * @param allowed Whether to add or remove the payer.
     */
    function updatePayer(address payer, bool allowed) external {
        // Ensure the sender is only the owner or contract itself.
        _onlyOwnerOrSelf();

        if (payer == address(0)) {
            revert PayerCannotBeZeroAddress();
        }

        // Track the enumerated storage.
        address[] storage enumeratedStorage = _enumeratedPayers;
        mapping(address => bool) storage payersMap = _allowedPayers;

        if (allowed) {
            if (payersMap[payer]) {
                revert DuplicatePayer();
            }
            payersMap[payer] = true;
            enumeratedStorage.push(payer);
        } else {
            if (!payersMap[payer]) {
                revert PayerNotPresent();
            }
            delete _allowedPayers[payer];
            _removeFromEnumeration(payer, enumeratedStorage);
        }

        // Emit an event with the update.
        emit PayerUpdated(payer, allowed);
    }

    /**
     * @notice Remove an address from a supplied enumeration.
     *
     * @param toRemove    The address to remove.
     * @param enumeration The enumerated addresses to parse.
     */
    function _removeFromEnumeration(
        address toRemove,
        address[] storage enumeration
    ) internal {
        // Cache the length.
        uint256 enumerationLength = enumeration.length;
        for (uint256 i = 0; i < enumerationLength; ) {
            // Check if the enumerated element is the one we are deleting.
            if (enumeration[i] == toRemove) {
                // Swap with the last element.
                enumeration[i] = enumeration[enumerationLength - 1];
                // Delete the (now duplicated) last element.
                enumeration.pop();
                // Exit the loop.
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Verify an EIP-712 signature by recreating the data structure
     *         that we signed on the client side, and then using that to recover
     *         the address that signed the signature for this data.
     *
     * @param minter       The mint recipient.
     * @param feeRecipient The fee recipient.
     * @param mintParams   The mint params.
     * @param salt         The salt for the signed mint.
     */
    function _getDigest(
        address minter,
        address feeRecipient,
        MintParams memory mintParams,
        uint256 salt
    ) internal view returns (bytes32 digest) {
        bytes32 mintParamsHashStruct = keccak256(
            abi.encode(
                _MINT_PARAMS_TYPEHASH,
                mintParams.mintPrice,
                mintParams.paymentToken,
                mintParams.maxTotalMintableByWallet,
                mintParams.startTime,
                mintParams.endTime,
                mintParams.dropStageIndex,
                mintParams.maxTokenSupplyForStage,
                mintParams.feeBps,
                mintParams.restrictFeeRecipients
            )
        );
        digest = keccak256(
            bytes.concat(
                bytes2(0x1901),
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        _SIGNED_MINT_TYPEHASH,
                        minter,
                        feeRecipient,
                        mintParamsHashStruct,
                        salt
                    )
                )
            )
        );
    }

    /**
     * @notice Burns `tokenId`. The caller must own `tokenId` or be an
     *         approved operator.
     *
     * @param tokenId The token id to burn.
     */
    function burn(uint256 tokenId) external {
        _burn(tokenId, true);
    }

    /**
     * @dev Overrides the `_startTokenId` function from ERC721A
     *      to start at token id `1`.
     *
     *      This is to avoid future possible problems since `0` is usually
     *      used to signal values that have not been set or have been removed.
     */
    function _startTokenId() internal view virtual override returns (uint256) {
        return 1;
    }

    /**
     * @notice Returns a set of mint stats for the address.
     *         This assists SeaDrop in enforcing maxSupply,
     *         maxTotalMintableByWallet, and maxTokenSupplyForStage checks.
     *
     * @dev    NOTE: Implementing contracts should always update these numbers
     *         before transferring any tokens with _safeMint() to mitigate
     *         consequences of malicious onERC721Received() hooks.
     *
     * @param minter The minter address.
     */
    function getMintStats(
        address minter
    )
        external
        view
        returns (
            uint256 minterNumMinted,
            uint256 currentTotalSupply,
            uint256 maxSupply
        )
    {
        minterNumMinted = _numberMinted(minter);
        currentTotalSupply = _totalMinted();
        maxSupply = _maxSupply;
    }

    /**
     * @notice Returns whether the interface is supported.
     *
     * @param interfaceId The interface id to check against.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721ContractMetadata) returns (bool) {
        return
            // interfaceId == type(IERC721SeaDrop).interfaceId ||
            // ERC721ContractMetadata returns supportsInterface true for
            //     EIP-2981
            // ERC721A returns supportsInterface true for
            //     ERC165, ERC721, ERC721Metadata
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom}
     * for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the caller.
     * - The `operator` must be allowed.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(
        address operator,
        bool approved
    ) public override onlyAllowedOperatorApproval(operator) {
        super.setApprovalForAll(operator, approved);
    }

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the
     * zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     * - The `operator` mut be allowed.
     *
     * Emits an {Approval} event.
     */
    function approve(
        address operator,
        uint256 tokenId
    ) public override onlyAllowedOperatorApproval(operator) {
        super.approve(operator, tokenId);
    }

    /**
     * @dev Transfers `tokenId` from `from` to `to`.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token
     * by either {approve} or {setApprovalForAll}.
     * - The operator must be allowed.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override onlyAllowedOperator(from) {
        // If "from" is this contract, it represents a mint.
        if (from == address(this)) {
            // Mint the tokens with tokenId representing the quantity.
            _mint(to, tokenId);
            return;
        }

        super.transferFrom(from, to, tokenId);
    }

    /**
     * @dev Handle ERC-1155 safeTransferFrom. When "from" is this contract,
     *      mint a quantity of tokens.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external nonReentrant {
        // Revert if caller or from is invalid.
        if (
            from != address(this) ||
            (msg.sender != _CONDUIT && !_allowedSeaports[msg.sender])
        ) {
            revert InvalidCaller(msg.sender);
        }

        // Mint tokens with "value" representing the quantity.
        _mint(to, value);
    }

    /**
     * @dev Equivalent to `safeTransferFrom(from, to, tokenId, '')`.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, tokenId);
    }

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token
     * by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement
     * {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     * - The operator must be allowed.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public override onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    /**
     * @notice Configure multiple properties at a time.
     *
     *         Note: The individual configure methods should be used
     *         to unset or reset any properties to zero, as this method
     *         will ignore zero-value properties in the config struct.
     *
     * @param config The configuration struct.
     */
    function multiConfigure(
        MultiConfigureStruct calldata config
    ) external onlyOwner {
        if (config.maxSupply > 0) {
            this.setMaxSupply(config.maxSupply);
        }
        if (bytes(config.baseURI).length != 0) {
            this.setBaseURI(config.baseURI);
        }
        if (bytes(config.contractURI).length != 0) {
            this.setContractURI(config.contractURI);
        }
        if (
            _cast(config.publicDrop.startTime != 0) |
                _cast(config.publicDrop.endTime != 0) ==
            1
        ) {
            this.updatePublicDrop(config.publicDrop);
        }
        if (bytes(config.dropURI).length != 0) {
            this.updateDropURI(config.dropURI);
        }
        if (config.allowListData.merkleRoot != bytes32(0)) {
            this.updateAllowList(config.allowListData);
        }
        if (config.creatorPayouts.length != 0) {
            this.updateCreatorPayouts(config.creatorPayouts);
        }
        if (config.provenanceHash != bytes32(0)) {
            this.setProvenanceHash(config.provenanceHash);
        }
        if (config.allowedFeeRecipients.length > 0) {
            for (uint256 i = 0; i < config.allowedFeeRecipients.length; ) {
                this.updateAllowedFeeRecipient(
                    config.allowedFeeRecipients[i],
                    true
                );
                unchecked {
                    ++i;
                }
            }
        }
        if (config.disallowedFeeRecipients.length > 0) {
            for (uint256 i = 0; i < config.disallowedFeeRecipients.length; ) {
                this.updateAllowedFeeRecipient(
                    config.disallowedFeeRecipients[i],
                    false
                );
                unchecked {
                    ++i;
                }
            }
        }
        if (config.allowedPayers.length > 0) {
            for (uint256 i = 0; i < config.allowedPayers.length; ) {
                this.updatePayer(config.allowedPayers[i], true);
                unchecked {
                    ++i;
                }
            }
        }
        if (config.disallowedPayers.length > 0) {
            for (uint256 i = 0; i < config.disallowedPayers.length; ) {
                this.updatePayer(config.disallowedPayers[i], false);
                unchecked {
                    ++i;
                }
            }
        }
        if (config.tokenGatedDropStages.length > 0) {
            if (
                config.tokenGatedDropStages.length !=
                config.tokenGatedAllowedNftTokens.length
            ) {
                revert TokenGatedMismatch();
            }
            for (uint256 i = 0; i < config.tokenGatedDropStages.length; ) {
                this.updateTokenGatedDrop(
                    config.tokenGatedAllowedNftTokens[i],
                    config.tokenGatedDropStages[i]
                );
                unchecked {
                    ++i;
                }
            }
        }
        if (config.disallowedTokenGatedAllowedNftTokens.length > 0) {
            for (
                uint256 i = 0;
                i < config.disallowedTokenGatedAllowedNftTokens.length;

            ) {
                TokenGatedDropStage memory emptyStage;
                this.updateTokenGatedDrop(
                    config.disallowedTokenGatedAllowedNftTokens[i],
                    emptyStage
                );
                unchecked {
                    ++i;
                }
            }
        }
        if (config.signedMintValidationParams.length > 0) {
            if (
                config.signedMintValidationParams.length !=
                config.signers.length
            ) {
                revert SignersMismatch();
            }
            for (
                uint256 i = 0;
                i < config.signedMintValidationParams.length;

            ) {
                this.updateSignedMintValidationParams(
                    config.signers[i],
                    config.signedMintValidationParams[i]
                );
                unchecked {
                    ++i;
                }
            }
        }
        if (config.disallowedSigners.length > 0) {
            for (uint256 i = 0; i < config.disallowedSigners.length; ) {
                SignedMintValidationParams memory emptyParams;
                this.updateSignedMintValidationParams(
                    config.disallowedSigners[i],
                    emptyParams
                );
                unchecked {
                    ++i;
                }
            }
        }
    }

    /**
     * @dev Internal utility function to convert bytes to bytes32[].
     */
    function bytesToBytes32Array(
        bytes memory data
    ) public pure returns (bytes32[] memory) {
        // Find 32 bytes segments nb
        uint256 dataNb = data.length / 32;
        // Create an array of dataNb elements
        bytes32[] memory dataList = new bytes32[](dataNb);
        // Start array index at 0
        uint256 index = 0;
        // Loop all 32 bytes segments
        for (uint256 i = 32; i <= data.length; i = i + 32) {
            bytes32 temp;
            // Get 32 bytes from data
            assembly {
                temp := mload(add(data, i))
            }
            // Add extracted 32 bytes to list
            dataList[index] = temp;
            index++;
        }
        // Return data list
        return (dataList);
    }

    /**
     * @dev Internal pure function to cast a `bool` value to a `uint256` value,
     *      then invert to match Unix style where 0 signifies success.
     *
     * @param b The `bool` value to cast.
     *
     * @return u The `uint256` value.
     */
    function _castAndInvert(bool b) internal pure returns (uint256 u) {
        assembly {
            u := iszero(b)
        }
    }
}
