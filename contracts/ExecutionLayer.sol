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
import "./DataLayer.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IUniswapV2Router02.sol";


contract ReturnExecutionLayer is AccessControl {

    // Roles
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // Payment Token
    address public paymentToken;

    // Sushiswap
    IUniswapV2Router02 public sushiRouter = IUniswapV2Router02(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);

    // TESTNET
    // Rinkeby Uniswap
    // IUniswapV2Router02 public sushiRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    // AAVE USDC Pool
    IPool public aaveUSDCPool; // Testnet 0xE039BdF1d874d27338e09B55CB09879Dedca52D8; Mainnet 0x794a61358D6845594F94dc1DB02A252b5b4814aD

    // Polygon Mainnet
    address public aUSDC = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;

    // TESTNET
    // Rinkeby Testnet aUSDC
    // address public aUSDC = 0x50b283C17b0Fc2a36c550A57B1a133459F4391B3;

    ReturnNFT public RETURN_NFT;
    ClimatePassport public RETURN_SBT;
    ReturnDataLayer public DATA_LAYER;


    event FundNFT(uint amount, uint nftID, address offsetToken);
    event WithdrawNFTFunds(uint amount, uint nftID, address offsetToken);
    event MintNFT(uint nftID, uint sbtID, uint amount, uint offsetPercentage, uint afterOffset, address offsetToken, address user);
    event MintSBT(uint sbtID, address user);
    event Stake(address pool, uint amount);
    event Unstake(address pool, uint amount);
    event Swap(address tokenIn, address tokenOut, uint amountIn, uint amountOut);

    constructor(address _NFT, address _SBT, address _dataLayer) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);

        RETURN_NFT = ReturnNFT(_NFT);
        RETURN_SBT = ClimatePassport(_SBT);
        DATA_LAYER = ReturnDataLayer(_dataLayer);
        paymentToken = DATA_LAYER.PAYMENT_TOKEN();
    }

    // User purchases NFT
    // TODO: Users can buy one NFT with multiple offsets
    // TODO: Return NFT/SBT IDs
    function buyNFT(uint amount, uint offsetPercentage, uint afterOffset, address offsetToken) external {
        // TODO: Approve Here? Dont think you can
        require(IERC20(paymentToken).transferFrom(msg.sender, address(this), amount), "Failed to transfer payment"); // Transfer Funds

        // TODO: Do we need this check? Alternative is to force users to create an account/mint SBT before purchasing NFT
        (bool exists, ) = DATA_LAYER.tryGetUserSBT(msg.sender);
        if (!exists) { // User has no SBT
            _mintSBT(msg.sender); // mint sbt
        }

        uint tokenId = _mintNFT(msg.sender, amount, offsetPercentage, offsetToken, afterOffset); // Mint NFT

        _stake(tokenId, amount); // Stake Amount
    }

    // Add Additional funds to NFT
    function _fundNFT(uint nftID, uint amount) external {
        require(RETURN_NFT.ownerOf(nftID) == msg.sender, "NFT not owned by user");
        require(IERC20(paymentToken).transferFrom(msg.sender, address(this), amount), "Failed to transfer payment"); // Transfer Funds

        _updateStake(nftID, amount, true); // Stake Amount, stake info should be updated in this function

        emit FundNFT(amount, nftID, msg.sender);

    }

    function _withdrawFunds(uint nftID, uint amount) external {
        require(RETURN_NFT.ownerOf(nftID) == msg.sender, "NFT not owned by user");

        _updateStake(nftID, amount, false);
    }

    function _mintSBT(address user) internal returns(uint) {
        // mint sbt to user
        uint newID = RETURN_SBT.testMint(user);
        // Update user -> SBT in data layer
        DATA_LAYER.setUserSBT(msg.sender, newID);

        emit MintSBT(newID, user);

        return newID;
    }

    function _mintNFT(address user, uint _amount, uint _percentage, address _offsetToken, uint _afterOffset) internal returns(uint) {
        uint sbtID = DATA_LAYER.getUserSBT(user); // Normal get, should revert if user doesn't have an sbt
        // mint nft to user
        uint nftID = RETURN_NFT.testMint(user);

        // TODO: These mappings may cause trouble in the case when users transfer/trade nft's
        //       Potential Solutions:
        //       1. Require people to re-register an nft when they purchased one on the secondary market
        //       2. Remove nft to sbt mapping, instead query nft --> owner --> sbt. Update sbt --> nft to be sbt --> registered nft?
        //       3. Build sbt minting functionality and update the data layer within the nft transfer function (my favorite?)
        //       4. Remove both nft -> sbt and sbt -> nft[] mappings, rely on only dealing with nft's and querying ownerOf
        // Update NFT -> SBT in data layer
        DATA_LAYER.setNFTToSBT(sbtID, nftID);
        // Update SBT -> NFT[] in data layer
        DATA_LAYER.addNFTtoSBT(sbtID, nftID);

        // Write Offset Info
        DATA_LAYER.setNFTOffsetInfo(nftID, _amount, _percentage, _offsetToken, _afterOffset);

        // uint nftID, uint sbtID, uint amount, uint offsetPercentage, uint afterOffset, address offsetToken, address user
        emit MintNFT(nftID, sbtID, _amount, _percentage, _afterOffset, _offsetToken, user);

        return nftID;

    }

    function _updateOffsetCorrection(uint nftID, uint amount, bool add) internal {
        address offsetToken;
        (,,,offsetToken,,,,) = DATA_LAYER.nftOffsetInfo(nftID);
        // set correction
        // add == true, we are setting a positive correction (subtracted from user owed)
        // add == false, user is removing some or all and we need to add to calculated user total
        // TODO: MULTIPLIERS REQUIRED HERE
        DATA_LAYER.updateOffsetCorrection(nftID, int(amount * DATA_LAYER.offsetSharePerToken(offsetToken)), add);

        // update staked per offset token
        DATA_LAYER.updateStakedPerOffset(offsetToken, amount, add);
    }

    // User Purchasing new nft creates new stake
    function _stake(uint nftID, uint amount) internal {
        // Update yield and calculate correction
        updateYield();

        // set correction index (no longer + 1 since we push beforehand)
        if (nftID == 0) {
            DATA_LAYER.setCorrectionIndex(nftID, 0);
        }
        else {
            DATA_LAYER.setCorrectionIndex(nftID, DATA_LAYER.getYieldPerShareLength());
        }


        // set correction, add offset correction
        _updateOffsetCorrection(nftID, amount, true);

        // deposit
        aaveSupplyUSDC(amount);

    }

    // Update stake corresponding to an existing NFT
    function _updateStake(uint nftID, uint amount, bool add) internal {
        // Update yield and calculate YPS & AYPS
        updateYield();

        // Get nft earnings up to this point
        (uint total, ) = DATA_LAYER.getTotals(nftID);

        if (!add) { // User removing from stake
            require(total >= amount, "You cant unstake more than your balance");
            total = total - amount;
            DATA_LAYER.updateNFTOffsetLoadedAmount(nftID, amount, false);

            //removing stake, correction should be negative
            _updateOffsetCorrection(nftID, amount, false);

            aaveWithdrawUSDC(amount);
        }
        else {
            total = total + amount;
            DATA_LAYER.updateNFTOffsetLoadedAmount(nftID, amount, true);

            //removing stake, correction should be positive
            _updateOffsetCorrection(nftID, amount, true);

            aaveSupplyUSDC(amount);
        }

        DATA_LAYER.setCorrectionIndex(nftID, DATA_LAYER.getYieldPerShareLength());
        DATA_LAYER.updateNFTOffsetTimestamp(nftID);
    }


    // Rebalance part 1
    function updateYield() internal {
        // 1. Claim All Pending Rewards
        uint balanceBefore = DATA_LAYER.poolAmounts(aUSDC);
        uint yield = IERC20(aUSDC).balanceOf(address(this)) - balanceBefore;

        // 2. Update yieldPerShare // TODO: if yield > 0
        //uint yps = (_simulatedYield * YPS_MULTIPLIER) / totalStakedAmount;

        uint yieldPerShare;
        if (DATA_LAYER.totalStakedAmount() == 0) {
            yieldPerShare = 0;
        }
        else {
            yieldPerShare = yield * DATA_LAYER.YPS_MULTIPLIER() / DATA_LAYER.totalStakedAmount();
        }

        DATA_LAYER.updateYieldPerShare(yieldPerShare);

        //3. Update adjustedYieldPerShare
        uint ypsLength = DATA_LAYER.getYieldPerShareLength();
        if (ypsLength == 1) {
            DATA_LAYER.updateAdjustedYieldPerShare(yieldPerShare + DATA_LAYER.YPS_MULTIPLIER());
        }
        else {
            uint aYPS = (DATA_LAYER.adjustedYieldPerShare(DATA_LAYER.getAdjustedYieldPerShareLength() - 1) * (yieldPerShare + DATA_LAYER.YPS_MULTIPLIER())) / DATA_LAYER.YPS_MULTIPLIER();
            DATA_LAYER.updateAdjustedYieldPerShare(aYPS);
        }

        // 4. Update Total Staked and Pool Staked to Reflect Yield
        DATA_LAYER.setTotalStakedAmount(yield, true);
        DATA_LAYER.updatePoolAmounts(yield, aUSDC, true);
    }

    function setPaymentToken(address _paymentToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        paymentToken = _paymentToken;
        DATA_LAYER.setPaymentToken(_paymentToken);
    }

    function _setUSDCPool(address _poolAddress) internal {
        if (address(aaveUSDCPool) != address(0)) {
            DATA_LAYER.updateIsPool(address(aaveUSDCPool), false);
        }
        aaveUSDCPool = IPool(_poolAddress);
        DATA_LAYER.updateIsPool(_poolAddress, true);
    }

    function setUSDCPool(address _poolAddress) external onlyRole(EXECUTOR_ROLE) {
        _setUSDCPool(_poolAddress);
    }

    function setaUSDCAddress(address _aUSDC) external onlyRole(EXECUTOR_ROLE) {
        aUSDC = _aUSDC;
    }

    function aaveSupplyUSDC(uint amount) internal {
        // 1. Deposit into aave usdc pool
        IERC20(paymentToken).approve(address(aaveUSDCPool), amount);
        aaveUSDCPool.supply(paymentToken, amount, address(this), 0);

        // 2. Update Values
        DATA_LAYER.setTotalStakedAmount(amount, true);
        DATA_LAYER.updatePoolAmounts(amount, aUSDC, true);
        emit Stake(address(aaveUSDCPool), amount);
    }

    function aaveWithdrawUSDC(uint amount) internal {
        aaveUSDCPool.withdraw(paymentToken, amount, address(this)); // TODO: Probably more efficient to just pass withdrawal address

        DATA_LAYER.setTotalStakedAmount(amount, false);
        DATA_LAYER.updatePoolAmounts(amount, aUSDC, false);
        emit Unstake(address(aaveUSDCPool), amount);
    }


    // TODO: How does this affect our yield calculations??? We are spending yield to offset
    function swapUSDCForOffset(uint amountUSDCExpected, uint amountOffset, address offsetToken) internal returns(uint) {
        // TODO: maybe just one approval in constructor, then dont have to worry about it
        IERC20(paymentToken).approve(address(sushiRouter), amountUSDCExpected);

        uint amount = IERC20(offsetToken).balanceOf(address(this));

        // TODO: Actual swap on sushi

        amount = IERC20(offsetToken).balanceOf(address(this)) - amount;

        emit Swap(address(paymentToken), offsetToken, amountUSDCExpected, amount);

        return amount;
    }

    function processGlobalOffsets(address offsetToken, uint amountToSpend, uint amountTokenExpected) external onlyRole(EXECUTOR_ROLE) {
        uint received = swapUSDCForOffset(amountTokenExpected, amountTokenExpected, offsetToken);

        // TODO: Definately need some multipliers for this to work
        uint offsetPerShare = received / DATA_LAYER.stakedPerOffset(offsetToken);
        DATA_LAYER.updateOffsetSharePerToken(offsetToken, offsetPerShare, true);
    }

    function processBatchOffsets(uint[] calldata nftIDs, uint[] calldata offsetAmount, address offsetToken, uint amountOffset, uint amountToSpend) external onlyRole(EXECUTOR_ROLE) {

    }


    // TODO: Rebalancing logic, do we want this on chain or called from the backend?
    // pools: array of pool addresses to stake
    // ratios: percentage of total TVL to be staked in each pool (in basis points)
    function rebalanceStakes(address[] calldata pools, uint[] calldata ratios) external onlyRole(EXECUTOR_ROLE) {
        updateYield();

        // 3. Restake following rebalancing logic
        // TODO: Option 1: Unstake all and restake according to params, much simpler but will most likely result in extra unnecessary work being done
        // TODO: Option 2: More complex param structure to only rebalance what needs to be rebalanced

    }

    // TEST FUNCTIONS
    function getAUSDCBalance() external view returns(uint) {
        return IERC20(aUSDC).balanceOf(address(this));
    }

}
