// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

// Normal OZ imports for ease of use
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "./R_NFT.sol";
import "./R_SBT.sol";


contract ReturnDataLayer is AccessControl {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    struct NFTOffsetInfo {
        // Initial Values
        uint loadedAmount;
        uint offsetPercentage;
        uint afterOffset; // what to do after offset tokens have been purchased
        address offsetChoice; // Probably internal decision tree logic here, (i.e. if we cant get all preferred offset move on to "next closest")
        uint timestamp;
        uint correctionIndex;
        int offsetCorrection; // Correction for the amount of offset tokens purchased on behalf of an account, needs to be int as could be negative if user withdraws part of stake

        // To Potentially be used later for individual offset percentages
        uint offsetAmount;
    }

    // Roles Info
    bytes32 public constant EDITOR_ROLE = keccak256("EDITOR_ROLE");

    // Data Mappings
    // User --> SBT
    // Contains length, allows iteration over all indexs, get key,value by index, get value by key
    EnumerableMap.AddressToUintMap private userSBT; // map for iterating over all SBT holders
    mapping(uint => address) public sbtToUser; // will allow for user lookup via sbt tokenID

    // SBT --> NFT(s)
    mapping(uint => uint[]) public sbtToNFT;
    mapping(uint => uint) public nftToSBT; // Do we want this lookup for any reason?

    // NFT(s) --> Staking Pools
    mapping(uint => NFTOffsetInfo) public nftOffsetInfo;

    // General Staking Info
    //address[] public poolAddresses; // probably dont need
    mapping(address => bool) isPool;
    uint public totalStakedAmount;

    mapping(address => uint) public poolAmounts;

    uint[] public yieldPerShare;
    uint[] public adjustedYieldPerShare;

    uint public YPS_MULTIPLIER = 10**18;
    uint public BASIS_POINTS = 10000;

    // TESTNET
    // Rinkeby Testnet
    // address public PAYMENT_TOKEN = 0xb18d016cDD2d9439A19f15633005A6b2cd6Aa774;

    // Mainnet 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address public PAYMENT_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    // Global Offset Stuff
    mapping(address => uint) public stakedPerOffset; // Total USDC Staked Per offset token
    mapping(address => uint) public offsetSharePerToken; // How much of each offset owed per usdc staked

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EDITOR_ROLE, msg.sender);
    }

    // Offset Functions
    function updateStakedPerOffset(address offset, uint amount, bool add) external onlyRole(EDITOR_ROLE) {
        if (add) {
            stakedPerOffset[offset] += amount;
        }
        else {
            stakedPerOffset[offset] -= amount;
        }
    }

    function updateOffsetSharePerToken(address offset, uint amount, bool add) external onlyRole(EDITOR_ROLE) {
        if (add) {
            offsetSharePerToken[offset] += amount;
        }
        else {
            offsetSharePerToken[offset] -= amount;
        }
    }

    // Gets the amount offset for an nft
    // TODO: MULTIPLIERS ARE NEEDED
    function getCurrentNFTOffset(uint nftID) external view returns(int total) {
        NFTOffsetInfo memory info = nftOffsetInfo[nftID];
        total = int((info.loadedAmount * offsetSharePerToken[info.offsetChoice])) - info.offsetCorrection;
        return total;
    }

    // NFT Stake Calculation Functions
    // Calculate Current Stake For an NFT (Initial + Yield)
    function getTotals(uint nftID) public view returns (uint total, uint yield) {
        NFTOffsetInfo memory info = nftOffsetInfo[nftID];

        uint correctionIndex = info.correctionIndex;
        if (correctionIndex == yieldPerShare.length) {
            total = info.loadedAmount;
        }
        else if (correctionIndex > 0) {
            // TODO: This 10000 for basis points is definately causing some rounding issues
            total = (info.loadedAmount * ((adjustedYieldPerShare[adjustedYieldPerShare.length - 1] * BASIS_POINTS) / adjustedYieldPerShare[correctionIndex - 1]) / BASIS_POINTS);
        }
        else {
            total = (info.loadedAmount * adjustedYieldPerShare[adjustedYieldPerShare.length - 1]) / YPS_MULTIPLIER;
        }
        yield = total - info.loadedAmount;
        return (total, yield);
    }

    // Get pending yield for an nft stake
    function getAvailableYield(uint nftID) external returns (uint yield){
        ( ,yield) = getTotals(nftID);
    }

    // Staking Getters / Setters
    function updateYieldPerShare(uint amount) external onlyRole(EDITOR_ROLE) {
        yieldPerShare.push(amount);
    }

    function getYieldPerShareLength() external view returns(uint) {
        return yieldPerShare.length;
    }

    function getYieldPerShare() external view returns(uint[] memory) {
        return yieldPerShare;
    }

    function updateAdjustedYieldPerShare(uint amount) external onlyRole(EDITOR_ROLE) {
        adjustedYieldPerShare.push(amount);
    }

    function getAdjustedYieldPerShareLength() external view returns(uint) {
        return adjustedYieldPerShare.length;
    }

    function getAdjustedYieldPerShare() external view returns(uint[] memory) {
        return adjustedYieldPerShare;
    }

    function setTotalStakedAmount(uint amount, bool add) external onlyRole(EDITOR_ROLE) {
        if (add) {
            totalStakedAmount += amount;
        }
        else {
            totalStakedAmount -= amount;
        }
    }

    function updatePoolAmounts(uint amount, address pool, bool add) external onlyRole(EDITOR_ROLE) {
        if (add) {
            poolAmounts[pool] += amount;
        }
        else {
            poolAmounts[pool] -= amount;
        }
    }

    function updateIsPool(address pool, bool valid) external onlyRole(EDITOR_ROLE) {
        isPool[pool] = valid;
    }

    // Struct Getters and Setters
    function setNFTOffsetInfo(uint nftID, uint _amount, uint _percentage, address _choice, uint _afterOffset) external onlyRole(EDITOR_ROLE) {
        require(nftOffsetInfo[nftID].loadedAmount == 0, "NFT already has offset info");
        nftOffsetInfo[nftID].loadedAmount = _amount;
        nftOffsetInfo[nftID].offsetPercentage = _percentage;
        nftOffsetInfo[nftID].offsetChoice = _choice;
        nftOffsetInfo[nftID].afterOffset = _afterOffset;
        nftOffsetInfo[nftID].timestamp = block.timestamp;
    }

    function setCorrectionIndex(uint nftID, uint _correctionIndex) external onlyRole(EDITOR_ROLE) {
        nftOffsetInfo[nftID].correctionIndex = _correctionIndex;
    }

    function updateOffsetCorrection(uint nftID, int correction, bool add) external onlyRole(EDITOR_ROLE) {
        if (add) {
            nftOffsetInfo[nftID].offsetCorrection += correction;
        }
        else {
            nftOffsetInfo[nftID].offsetCorrection -= correction;
        }
    }

    function updateNFTOffsetLoadedAmount(uint nftID, uint _amount, bool add) external onlyRole(EDITOR_ROLE) {
        if (add) {
            nftOffsetInfo[nftID].loadedAmount += _amount;
        }
        else {
            nftOffsetInfo[nftID].loadedAmount -= _amount;
        }
    }

    function updateNFTOffsetPercentage(uint nftID, uint _percentage) external onlyRole(EDITOR_ROLE) {
        nftOffsetInfo[nftID].offsetPercentage = _percentage;
    }

    function updateNFTOffsetChoice(uint nftID, address _choice) external onlyRole(EDITOR_ROLE) {
        nftOffsetInfo[nftID].offsetChoice = _choice;
    }

    function updateNFTAfterOffset(uint nftID, uint _afterOffset) external onlyRole(EDITOR_ROLE) {
        nftOffsetInfo[nftID].afterOffset = _afterOffset;
    }

    function updateNFTOffsetTimestamp(uint nftID) external onlyRole(EDITOR_ROLE) {
        nftOffsetInfo[nftID].timestamp = block.timestamp;
    }

    // Enumerable Map Getters/Setters
    // Set key, value pair
    function setUserSBT(address user, uint tokenId) external onlyRole(EDITOR_ROLE) {
        userSBT.set(user, tokenId);
    }

    // Remove key, value pair
    function removeUserSBT(address user) external onlyRole(EDITOR_ROLE) {
        userSBT.remove(user);
    }

    // Check key existance
    function containsUserSBT(address user) external view returns(bool) {
        return userSBT.contains(user);
    }

    // Number of sbt holders
    function lengthUserSBT() external view returns(uint) {
        return userSBT.length();
    }

    // key, value pair at index
    function getUserSBTAtIndex(uint index) external view returns(address, uint) {
        return userSBT.at(index);
    }

    // Get value at key, Does not revert is user does not exist
    function tryGetUserSBT(address user) external view returns(bool, uint) {
        return userSBT.tryGet(user);
    }

    // Get value at key, reverts of key does not exist
    function getUserSBT(address user) external view returns(uint) {
        return userSBT.get(user);
    }

    // Set reverse mapping (sbtID to user address)
    function setSBTToUser(uint tokenId, address user) external onlyRole(EDITOR_ROLE) {
        sbtToUser[tokenId] = user;
    }

    // SBT --> NFT Getters/Setters
    // Associate NFT with certain sbt
    function addNFTtoSBT(uint sbtID, uint nftID) external onlyRole(EDITOR_ROLE) {
        sbtToNFT[sbtID].push(nftID);
    }

    // Disassociate NFT from SBT
    function removeSBTFromNFT(uint sbtID, uint nftID) external onlyRole(EDITOR_ROLE) {
        for (uint i = 0; i < sbtToNFT[sbtID].length; i++) {
            if (sbtToNFT[sbtID][i] == nftID) {
                sbtToNFT[sbtID][i] = sbtToNFT[sbtID][sbtToNFT[sbtID].length - 1];
                sbtToNFT[sbtID].pop();
            }
        }
    }

    // Set sbt to be associated with nft
    function setNFTToSBT(uint sbtID, uint nftID) external onlyRole(EDITOR_ROLE) {
        nftToSBT[nftID] = sbtID;
    }

    function setPaymentToken(address _token) external onlyRole(EDITOR_ROLE) {
        PAYMENT_TOKEN = _token;
    }

}
