// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract WindfallFeeShare is ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ===== Errors =====
    error NotLotto();
    error NotHost();
    error ZeroAddress();
    error ZeroAmount();
    error TooManyShareholders();
    error MinTooLow();
    error LottoAlreadySet();

    IERC20 public immutable TOKEN;
    address public lotto;
    address public immutable hostTreasury;

    uint256 public minQualifyingDonation;
    uint256 public minQualifyingDonationToSave;
    uint256 public constant THE_MIN = 1000e18; // 1000 TOKEN (18 decimals)
    uint64 public constant SHARE_DURATION = 365 days;
    uint256 public constant MAX_SHAREHOLDERS = 200;

    struct Shareholder {
        uint64 expiry;
        bool exists;
        bool active;
        uint256 amount;
        uint64 lastStateChange;
    }

    mapping(address => Shareholder) public shareholders;
    mapping(address => uint256) public claimable;

    address[] public shareholderList; // donor shareholders only, host excluded

    event QualifyingDonation(address indexed donor, uint256 amount, uint64 newExpiry);
    event FeeDistributed(uint256 amount, uint256 activeShares, uint256 sharePerMember, uint256 remainderToHost);
    event Claimed(address indexed account, uint256 amount);
    event MinQualifyingDonationUpdated(uint256 oldAmount, uint256 newAmount);

    modifier onlyLotto() {
        if (msg.sender != lotto) revert NotLotto();
        _;
    }

    modifier onlyHost() {
        if (msg.sender != hostTreasury) revert NotHost();
        _;
    }

    constructor(
        address _token,
        address _hostTreasury
    ) {
        if (_token == address(0) || _hostTreasury == address(0)) revert ZeroAddress();

        TOKEN = IERC20(_token);
        hostTreasury = _hostTreasury;
        minQualifyingDonation = THE_MIN;
        minQualifyingDonationToSave = THE_MIN/10;
    }

    function setLotto(address _lotto) external onlyHost {
        // no require for test
        if (lotto != address(0)) revert LottoAlreadySet();
        if (_lotto == address(0)) revert ZeroAddress();
        lotto = _lotto;
    }

    // -------- HOST SETTINGS --------
    function _setMinQualifyingDonation() internal {
        uint256 old = minQualifyingDonation;
        uint256 active = _countActiveDonors();
        if (active>=0) minQualifyingDonation = THE_MIN;
        if (active>35) minQualifyingDonation = THE_MIN*10;
        if (active>70) minQualifyingDonation = THE_MIN*100;
        if (active>105) minQualifyingDonation = THE_MIN*1000;
        if (active>140) minQualifyingDonation = THE_MIN*10000;
        if (active>175) minQualifyingDonation = THE_MIN*100000;
        if (old != minQualifyingDonation){
            minQualifyingDonationToSave = minQualifyingDonation/10;
            emit MinQualifyingDonationUpdated(old, minQualifyingDonation);
        }
    }

    // -------- Prune expired after 30 days from lastStateChange  --------
    function pruneExpired(uint256 maxIterations) external {
        _pruneExpiredInternal(maxIterations);
    }

    function _pruneExpiredInternal(uint256 maxIterations) internal {
        uint256 i = 0;
        while (i < shareholderList.length && maxIterations > 0) {
            address a = shareholderList[i];
            if (!_isActive(a) && uint64(block.timestamp) > shareholders[a].lastStateChange + 30 days) {
                delete shareholders[a];
                shareholderList[i] = shareholderList[shareholderList.length - 1];
                shareholderList.pop();
            } else {
                i++;
            }
            maxIterations--;
        }
    }

    // -------- After expiration change the state --------
    function disableExpired(address donor) internal {
        Shareholder storage s = shareholders[donor];
        if (!_isActive(donor) && s.active == true) {
            s.active = false;
            s.amount = 0;
            s.lastStateChange = uint64(block.timestamp);
        }
    }

    // -------- LOTTO HOOK: qualifying donations --------
    function registerDonation(address donor, uint256 amount) external onlyLotto {
        if (donor == hostTreasury) return;
        if (amount < minQualifyingDonationToSave) return;

        Shareholder storage s = shareholders[donor];

        if (!s.exists) {
            if (shareholderList.length >= MAX_SHAREHOLDERS) _pruneExpiredInternal(MAX_SHAREHOLDERS);
            if (shareholderList.length >= MAX_SHAREHOLDERS) revert TooManyShareholders();
            s.exists = true;
            s.amount = 0;
            s.active = false;
            shareholderList.push(donor);
        } else {
            disableExpired(donor);

            // reset inactive accumulation if 30-day continuity was broken
            if (!s.active && s.amount > 0 && uint64(block.timestamp) > s.lastStateChange + 30 days) {
                s.amount = 0;
            }
        }

        s.lastStateChange = uint64(block.timestamp);

        if (s.active){
            //add days proportionnel to min minQualifyingDonation
             uint64 durationToAdd = uint64((uint256(SHARE_DURATION) * amount) / minQualifyingDonation);
             s.expiry = s.expiry + durationToAdd;
        } else {
            s.amount = s.amount + amount;

            if (s.amount >= minQualifyingDonation) {
                uint64 base = uint64(block.timestamp);
                uint256 remainingAmount = s.amount - minQualifyingDonation;
                uint64 durationToAdd = uint64((uint256(SHARE_DURATION) * remainingAmount) / minQualifyingDonation);
                s.expiry = base + SHARE_DURATION + durationToAdd;
                s.active = true;
                s.amount = 0;
            }
        }

        
        _setMinQualifyingDonation();
        emit QualifyingDonation(donor, amount, s.expiry);
    }

    // -------- LOTTO HOOK: distribute ticket-buy host fee --------
    // Lotto should transfer fee tokens to this contract first, then call this.
    function distributeFee(uint256 amount) external onlyLotto {
        if (amount == 0) revert ZeroAmount();

        uint256 activeDonors = _countActiveDonors();
        uint256 hostshares = (activeDonors + 19) / 20; // ceil(activeDonors / 20)
        if (hostshares < 1) hostshares = 1;
        uint256 activeShares = activeDonors + hostshares; // + host

        uint256 sharePerMember = amount / activeShares;
        uint256 distributed = sharePerMember * activeShares;
        uint256 remainder = amount - distributed;

        // host share
        claimable[hostTreasury] += sharePerMember*hostshares + remainder;

        // donor shares
        uint256 len = shareholderList.length;
        for (uint256 i = 0; i < len; i++) {
            address a = shareholderList[i];
            if (_isActive(a)) {
                claimable[a] += sharePerMember;
            }
        }

        emit FeeDistributed(amount, activeShares, sharePerMember, remainder);
    }

    // -------- CLAIM --------
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert ZeroAmount();

        claimable[msg.sender] = 0;
        TOKEN.safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    // -------- VIEWS --------
    function isActive(address account) external view returns (bool) {
        if (account == hostTreasury) return true;
        return _isActive(account);
    }

    function activeParticipantCount() external view returns (uint256) {
        return _countActiveDonors();
    }

    function getShareholderCount() external view returns (uint256) {
        return shareholderList.length;
    }
    function currentTotalShares() external view returns (uint256) {
        uint256 activeDonors = _countActiveDonors();
        uint256 hostshares = (activeDonors + 19) / 20; // ceil(activeDonors / 20)
        if (hostshares < 1) hostshares = 1;
        return (activeDonors + hostshares);
    }
    function currentHostShares() external view returns (uint256) {
        uint256 activeDonors = _countActiveDonors();
        uint256 hostshares = (activeDonors + 19) / 20; // ceil(activeDonors / 20)
        if (hostshares < 1) hostshares = 1;
        return hostshares; // + host
    }

    function getShareholders()
        external
        view
        returns (
            address[] memory addrs,
            uint64[] memory expiries,
            bool[] memory activeFlags
        )
    {
        uint256 len = shareholderList.length;
        addrs = new address[](len);
        expiries = new uint64[](len);
        activeFlags = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            address a = shareholderList[i];
            addrs[i] = a;
            expiries[i] = shareholders[a].expiry;
            activeFlags[i] = _isActive(a);
        }
    }

    function _isActive(address account) internal view returns (bool) {
        Shareholder storage s = shareholders[account];
        return s.exists && s.active && s.expiry >= block.timestamp;
    }

    function _countActiveDonors() internal view returns (uint256 count) {
        uint256 len = shareholderList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_isActive(shareholderList[i])) {
                count++;
            }
        }
    }
}