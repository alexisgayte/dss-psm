pragma solidity >=0.5.12;

import { DaiJoinAbstract } from "dss-interfaces/dss/DaiJoinAbstract.sol";
import { DaiAbstract } from "dss-interfaces/dss/DaiAbstract.sol";
import { VatAbstract } from "dss-interfaces/dss/VatAbstract.sol";

interface AuthGemJoinAbstract {
    function dec() external view returns (uint256);
    function vat() external view returns (address);
    function ilk() external view returns (bytes32);
    function join(address, uint256, address) external;
    function exit(address, uint256) external;
}

// Peg Stability Module
// Allows anyone to go between Dai and the Gem by pooling the liquidity
// An optional fee is charged for incoming and outgoing transfers

contract DssPsm {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit AuthUser(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit DeauthUser(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    VatAbstract immutable public vat;
    AuthGemJoinAbstract immutable public gemJoin;
    DaiAbstract immutable public dai;
    DaiJoinAbstract immutable public daiJoin;
    bytes32 immutable public ilk;
    address immutable public vow;

    uint256 immutable internal gemWadConversionFactor;

    uint256 public tin;         // toll in [wad]
    uint256 public tout;        // toll out [wad]

    // --- Events ---
    event AuthUser(address indexed user);
    event DeauthUser(address indexed user);
    event File(bytes32 indexed what, uint256 data);
    event GemForDaiSwap(address indexed owner, uint256 value, uint256 fee);
    event DaiForGemSwap(address indexed owner, uint256 value, uint256 fee);

    // --- Init ---
    constructor(address gemJoin_, address daiJoin_, address vow_) public {
        wards[msg.sender] = 1;
        AuthGemJoinAbstract gemJoin__ = gemJoin = AuthGemJoinAbstract(gemJoin_);
        DaiJoinAbstract daiJoin__ = daiJoin = DaiJoinAbstract(daiJoin_);
        VatAbstract vat__ = vat = VatAbstract(address(gemJoin__.vat()));
        DaiAbstract dai__ = dai = DaiAbstract(address(daiJoin__.dai()));
        ilk = gemJoin__.ilk();
        vow = vow_;
        gemWadConversionFactor = 10 ** (18 - gemJoin__.dec());
        dai__.approve(daiJoin_, uint256(-1));
        vat__.hope(daiJoin_);
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external auth {
        if (what == "tin") tin = data;
        else if (what == "tout") tout = data;
        else revert("DssPsm/file-unrecognized-param");

        emit File(what, data);
    }
    function hope(address usr) external auth {
        vat.hope(usr);
    }
    function nope(address usr) external auth {
        vat.nope(usr);
    }

    // --- Primary Functions ---
    function swapGemForDai(address usr, uint256 wad) external {
        uint256 wad18 = mul(wad, gemWadConversionFactor);
        uint256 fee = mul(wad18, tin) / WAD;
        uint256 base = sub(wad18, fee);
        gemJoin.join(address(this), wad, msg.sender);
        vat.frob(ilk, address(this), address(this), address(this), int256(wad18), int256(wad18));
        vat.move(address(this), vow, mul(fee, RAY));
        daiJoin.exit(usr, base);

        emit GemForDaiSwap(usr, wad, fee);
    }

    function swapDaiForGem(address usr, uint256 wad) external {
        require(dai.transferFrom(msg.sender, address(this), wad), "DssPsm/failed-transfer");
        uint256 wadGem = wad / gemWadConversionFactor;
        uint256 fee = add(mul(wad, tout) / WAD, sub(wad, mul(wadGem, gemWadConversionFactor))); // Fee = tout + Division Remainder
        uint256 base = sub(wad, fee);
        daiJoin.join(address(this), wad);
        vat.move(address(this), vow, mul(fee, RAY));
        vat.frob(ilk, address(this), address(this), address(this), -int256(base), -int256(base));
        gemJoin.exit(usr, base / gemWadConversionFactor);

        emit DaiForGemSwap(usr, wad, fee);
    }

}
