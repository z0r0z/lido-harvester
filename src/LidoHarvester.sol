// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @notice Simple Lido stETH harvesting contract to utilize ETH yield.
/// @dev Accepts raw ETH (converts to stETH) or stETH deposits -
/// which increment basis counter to track yield - which can reconvert
/// to ETH - which may then be used in withdraw() - optional condition
/// can be attached which ensures some sort of balance increase in ETH
/// or ERC20 asset occurs as result of spending such ETH on withdraw().
contract LidoHarvester {
    event OwnershipTransferred(address indexed from, address indexed to);

    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    uint256 public staked;
    uint16 public slipBps;
    address public owner;

    address public target;
    address public asset;
    address public holder;

    error ConditionUnmet();
    error Unauthorized();

    modifier onlyOwner() {
        require(msg.sender == owner, Unauthorized());
        _;
    }

    function transferOwnership(address to) public payable onlyOwner {
        emit OwnershipTransferred(msg.sender, owner = to);
    }

    function setSlippage(uint16 _slipBps) public payable onlyOwner {
        require(_slipBps <= 10000);
        slipBps = _slipBps;
    }

    function setTarget(address _target) public payable onlyOwner {
        address old = target;
        if (old != address(0)) IERC20(STETH).approve(old, 0);
        target = _target;
        if (_target != address(0)) IERC20(STETH).approve(_target, type(uint256).max);
    }

    function setCondition(address _asset, address _holder) public payable onlyOwner {
        (asset, holder) = (_asset, _holder);
    }

    constructor() payable {
        emit OwnershipTransferred(address(0), owner = msg.sender);
    }

    receive() external payable {
        assembly { if tload(0) { return(0, 0) } }
        uint256 stethBal = IERC20(STETH).balanceOf(address(this));
        (bool ok,) = STETH.call{value: msg.value}("");
        require(ok);
        unchecked { staked += IERC20(STETH).balanceOf(address(this)) - stethBal; }
    }

    function deposit(uint256 amt) public payable {
        uint256 stethBal = IERC20(STETH).balanceOf(address(this));
        require(IERC20(STETH).transferFrom(msg.sender, address(this), amt));
        unchecked { staked += IERC20(STETH).balanceOf(address(this)) - stethBal; }
    }

    function withdraw(address to, uint256 val, bytes calldata data, uint256 minGain) public payable onlyOwner {
        address _holder = holder;
        address _asset = asset;
        uint256 balBefore;
        bool conditioned = _holder != address(0);
        bool ethCondition = _asset == address(0);

        if (conditioned) balBefore = ethCondition ? _holder.balance : IERC20(_asset).balanceOf(_holder);

        (bool ok,) = to.call{value: val}(data);
        require(ok);

        if (conditioned) {
            uint256 balAfter = ethCondition ? _holder.balance : IERC20(_asset).balanceOf(_holder);
            require(balAfter >= balBefore + minGain, ConditionUnmet());
        }
    }

    function stake(uint256 amt) public payable onlyOwner {
        if (amt == 0) amt = address(this).balance;
        uint256 stethBal = IERC20(STETH).balanceOf(address(this));
        (bool ok,) = STETH.call{value: amt}("");
        require(ok);
        unchecked { staked += IERC20(STETH).balanceOf(address(this)) - stethBal; }
    }

    function withdrawStETH(address to, uint256 amt) public payable onlyOwner {
        staked -= amt;
        require(IERC20(STETH).transfer(to, amt));
    }

    function harvest(bytes calldata data) public payable returns (uint256 yield) {
        address _target = target;
        uint256 _staked = staked;
        uint256 ethBal = address(this).balance;
        uint256 stethBal = IERC20(STETH).balanceOf(address(this));
        if (stethBal <= _staked) return 0;
        unchecked { yield = stethBal - _staked; }
        assembly { tstore(0, 1) }
        (bool ok,) = _target.call(data);
        assembly { tstore(0, 0) }
        require(ok);
        unchecked {
            require(address(this).balance >= ethBal + yield * (10000 - slipBps) / 10000);
            require(IERC20(STETH).balanceOf(address(this)) + 2 >= _staked);
        }
    }
}
