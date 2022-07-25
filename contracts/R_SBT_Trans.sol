// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

// Transparent pattern

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract ClimatePassport_Trans is Initializable, ERC721Upgradeable, ERC721URIStorageUpgradeable, AccessControlUpgradeable {
    using CountersUpgradeable for CountersUpgradeable.Counter;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    CountersUpgradeable.Counter private _tokenIdCounter;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        //_disableInitializers();
    }

    function initialize() initializer public {
        __ERC721_init("Return Climate Passport", "RSBT");
        __ERC721URIStorage_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    function _baseURI() internal pure override returns (string memory) {
        return "https://returnprotocol-buckets-sbtmetadata.s3.amazonaws.com/";
    }

    function safeMint(address to, string memory uri) public onlyRole(MINTER_ROLE) {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function testMint(address to) public returns (uint) {
        uint id = _tokenIdCounter.current();
        string memory uri = string(abi.encodePacked(_baseURI(), Strings.toString(id), ".json"));
        safeMint(to, uri);
        return id;
    }

    // The following functions are overrides required by Solidity.

    function _burn(uint256 tokenId)
    internal
    override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
    {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
    public
    view
    override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
    returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
    public
    view
    override(ERC721Upgradeable, AccessControlUpgradeable)
    returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function noxfr() internal {
        require(false, "ClimatePassports cannot be transfered, try burning this token + minting a new one.");
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        noxfr();
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public override {
        noxfr();
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory _data) public override {
        noxfr();
    }
}