// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Vault
 * @notice This contract manages deposits, withdrawals, and yield distribution
 *
 * @dev Withdrawal Timeline Visualization:
 *
 * March 2024                       Key Events & Storage
 * ---------------------------      ------------------------------------------
 * Sun Mon Tue Wed Thu Fri Sat
 *                  |
 *  3   4   5   6   7   8   9      [Day 3]
 *  |                              15:00 UTC: User requests withdrawal
 *  |                              withdrawPerDay[Mar 3 00:00 UTC] += amount
 *  |
 * 10  11  12  13  14  15  16     [Day 4 ~ Day 10]
 *  |   |                          7 days waiting period
 *  |   |
 *  |   |                         [Day 10]
 *  |   |                         15:00 UTC: Admin calls undelegate()
 *  |   |                         Processes: withdrawPerDay[Mar 3 00:00 UTC]
 *  |   |
 *  |   |                         [Day 11]
 *  |   |                         00:00 UTC: Withdrawal becomes available
 *  |   |                         User can claim their tokens
 * 17  18  19  20  21  22  23
 *
 * Timeline Details:
 * ----------------
 * 1. Withdrawal Request (Day 3)
 *    - Time: 15:00 UTC on March 3rd
 *    - Storage: withdrawPerDay[Mar 3 00:00 UTC] (that day's midnight)
 *    - ReleaseTime set to: March 11th 00:00 UTC
 *
 * 2. Undelegate (Day 10)
 *    - Time: 15:00 UTC on March 10th
 *    - Reads: withdrawPerDay[Mar 3 00:00 UTC]
 *    - Why Day 3?: current_time(Mar 10) - 7 days = Mar 3
 *
 * 3. Claim Period (Day 11)
 *    - Starts: 00:00 UTC on March 11th
 *    - Note: The 1-day gap between undelegate and claim
 *           (Day 10 undelegate → Day 11 claim) is intentional
 */
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract Vault is Initializable, PausableUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    address public operator;
    address public gateway;

    modifier onlyOperator() {
        require(msg.sender == operator, "Caller is not the operator");
        _;
    }

    modifier onlyGateway() {
        require(msg.sender == gateway, "Caller is not the gateway");
        _;
    }

    uint256 public constant TIME_UNIT = 1 days;
    uint256 public totalSupply;
    uint256 public totalInterest;
    uint256 public totalDelegatedBalance;
    uint256 public totalUndelegatedBalance;
    uint256 public totalXSupply;
    uint256 public withdrawalDelay; // Delay in TIME_UNIT units
    uint256 public yieldMaxRate; // Max yield rate in basis points (e.g., 300 = 3%)
    uint256 public depositCap;

    mapping(address => uint256) public depositBalance;
    mapping(address => uint256) public depositXBalance;

    // Daily withdrawal tracking
    mapping(uint256 => uint256) public withdrawPerDay;
    mapping(uint256 => uint256) public withdrawInterestPerDay;
    mapping(uint256 => bool) public withdrawReleased;

    // Yield history tracking
    struct YieldUpdate {
        uint256 timestamp;
        uint256 amount;
        uint256 totalInterest;
    }

    YieldUpdate[] public yieldHistory;
    mapping(uint256 => bool) public yieldUpdatedForDay; // Track if yield was updated for a day

    struct WithdrawRequest {
        uint256 id;
        address user;
        uint256 timestamp;
        uint256 unitTime;
        uint256 releaseTime;
        uint256 principalAmount;
        uint256 interestAmount;
        bool released;
    }

    // All withdraw requests
    WithdrawRequest[] public withdrawRequests;
    // User's withdraw request indices using EnumerableSet
    mapping(address => EnumerableSet.UintSet) private userWithdrawIndices;

    address public treasury;
    address public token;
    uint8 public tokenDecimals;

    // Events
    event Deposited(address indexed user, uint256 amount, uint256 xAmount);
    event WithdrawRequested(
        address indexed user,
        uint256 id,
        uint256 amount,
        uint256 principalAmount,
        uint256 interestAmount,
        uint256 timestamp,
        uint256 unitTime,
        uint256 releaseTime
    );
    event Claimed(address indexed user, uint256[] requestIds, uint256 principalAmount, uint256 interestAmount);
    event Undelegated(uint256 amount, uint256 principalAmount, uint256 interestAmount, uint256 targetTimestamp);
    event YieldUpdated(uint256 amount, uint256 totalInterest);
    event TreasuryUpdated(address newTreasury);
    event YieldMaxRateUpdated(uint256 newRate);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event DepositCapUpdated(uint256 newCap);
    event GatewayUpdated(address indexed previousGateway, address indexed newGateway);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _token, address _treasury, address _operator, address _owner, address _gateway) public initializer {
        require(_token != address(0), "Invalid token address");
        require(_treasury != address(0), "Invalid treasury address");
        require(_operator != address(0), "Invalid operator address");
        require(_owner != address(0), "Invalid owner address");
        require(_gateway != address(0), "Invalid gateway address");

        __Pausable_init();
        __Ownable_init(_owner);

        token = _token;
        treasury = _treasury;
        operator = _operator;
        gateway = _gateway;
        withdrawalDelay = 7;
        yieldMaxRate = 300;
        depositCap = type(uint256).max; 
        tokenDecimals = IERC20Metadata(_token).decimals();
    }

    // Role management functions
    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "Invalid operator address");
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
    }

    function setGateway(address _gateway) external onlyOwner {
        require(_gateway != address(0), "Invalid gateway address");
        emit GatewayUpdated(gateway, _gateway);
        gateway = _gateway;
    }

    // Owner functions (using OwnableUpgradeable's owner)
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        require(IERC20(token).balanceOf(_treasury) >= totalSupply + totalInterest, "Insufficient treasury balance");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setYieldMaxRate(uint256 _rate) external onlyOwner {
        require(_rate > 0 && _rate <= 10000, "Invalid rate");
        yieldMaxRate = _rate;
        emit YieldMaxRateUpdated(_rate);
    }

    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function deposit(uint256 amount) external whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(totalSupply + amount <= depositCap, "Deposit cap exceeded");

        uint256 xAmount = (totalXSupply == 0) ? amount : amount * totalXSupply / (totalSupply + totalInterest);

        depositBalance[msg.sender] += amount;
        depositXBalance[msg.sender] += xAmount;
        
        totalSupply += amount;
        totalXSupply += xAmount;

        IERC20(token).safeTransferFrom(msg.sender, treasury, amount);
        totalDelegatedBalance += amount;

        emit Deposited(msg.sender, amount, xAmount);
    }

    function undelegate() external onlyOperator whenNotPaused {
        uint256 targetTimestamp = getTargetUndelegateTimestamp(block.timestamp);
        _undelegate(targetTimestamp);
    }

    function undelegate(uint256 timestamp) external onlyOwner whenNotPaused {
        require(timestamp <= block.timestamp, "Invalid timestamp");
        uint256 targetTimestamp = getTargetUndelegateTimestamp(timestamp);
        _undelegate(targetTimestamp);
    }

    function _undelegate(uint256 targetTimestamp) private {
        require(!withdrawReleased[targetTimestamp], "Withdrawals already released for this unit");
        require(withdrawPerDay[targetTimestamp] + withdrawInterestPerDay[targetTimestamp] > 0, "No withdrawals to release for this unit");

        uint256 principalAmount = withdrawPerDay[targetTimestamp];
        uint256 interestAmount = withdrawInterestPerDay[targetTimestamp];
        uint256 totalAmount = principalAmount + interestAmount;

        IERC20(token).safeTransferFrom(treasury, address(this), totalAmount);
        totalUndelegatedBalance += totalAmount;

        // Mark this unit's withdrawals as released
        withdrawReleased[targetTimestamp] = true;

        emit Undelegated(totalAmount, principalAmount, interestAmount, targetTimestamp);
    }

    function withdraw(uint256 amount) external whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");

        uint256 userXBalance = depositXBalance[msg.sender];
        uint256 userDepositBalance = depositBalance[msg.sender];
        
        uint256 maxWithdrawAmount = userXBalance * (totalSupply + totalInterest) / totalXSupply;
        require(amount <= maxWithdrawAmount, "Insufficient balance");
        
        uint256 xAmountToBurn = (amount * totalXSupply + totalSupply + totalInterest - 1) / (totalSupply + totalInterest);
        uint256 principalAmount = (amount * (totalXSupply * userDepositBalance)) / ((totalSupply + totalInterest) * userXBalance);
        uint256 interestAmount = amount - principalAmount;
        
        depositXBalance[msg.sender] -= xAmountToBurn;
        depositBalance[msg.sender] -= principalAmount;
        
        totalXSupply -= xAmountToBurn;
        totalSupply -= principalAmount;
        totalInterest -= interestAmount;

        uint256 currentTime = getTimeUnitStart(block.timestamp);
        uint256 withdrawReleaseTime = releaseTime(block.timestamp);

        withdrawPerDay[currentTime] += principalAmount;
        withdrawInterestPerDay[currentTime] += interestAmount;
        
        uint256 requestId = withdrawRequests.length;
        withdrawRequests.push(
            WithdrawRequest({
                id: requestId,
                user: msg.sender,
                timestamp: block.timestamp,
                unitTime: currentTime,
                releaseTime: withdrawReleaseTime,
                principalAmount: principalAmount,
                interestAmount: interestAmount,
                released: false
            })
        );

        userWithdrawIndices[msg.sender].add(requestId);

        emit WithdrawRequested(msg.sender, requestId, amount, principalAmount, interestAmount, block.timestamp, currentTime, withdrawReleaseTime);
    }

    function claim() external whenNotPaused {
        _claim(msg.sender);
    }

    function claim(uint256[] memory requestIds) external whenNotPaused {
        require(requestIds.length > 0, "No request IDs provided");
        _claim(msg.sender, requestIds);
    }

    function claimBehalf(address user) external whenNotPaused onlyGateway {
        _claim(user);
    }

    function _claim(address user, uint256[] memory requestIds) internal {
        EnumerableSet.UintSet storage userIndices = userWithdrawIndices[user];

        uint256 principalAmount = 0;
        uint256 interestAmount = 0;
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestId = requestIds[i];
            require(requestId < withdrawRequests.length, "Invalid request ID");
            WithdrawRequest storage request = withdrawRequests[requestId];
            require(request.user == user, "Request does not belong to user");
            require(!request.released, "Request already released");
            require(request.releaseTime <= block.timestamp && withdrawReleased[request.unitTime], "Request not yet available for claim");
            request.released = true;
            principalAmount += request.principalAmount;
            interestAmount += request.interestAmount;
            userIndices.remove(requestId);
        }
        
        require(principalAmount > 0 || interestAmount > 0, "No withdrawals to claim");
        uint256 totalAmount = principalAmount + interestAmount;
        require(IERC20(token).balanceOf(address(this)) >= totalAmount, "Insufficient contract balance");
        IERC20(token).safeTransfer(user, totalAmount);

        emit Claimed(user, requestIds, principalAmount, interestAmount);
    }

    function _claim(address user) internal {
        (uint256[] memory requestIds, uint256 principalAmount, uint256 interestAmount) = getClaimableAmount(user);
        require(principalAmount > 0 || interestAmount > 0, "No withdrawals to claim");

        EnumerableSet.UintSet storage userIndices = userWithdrawIndices[user];

        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestId = requestIds[i];
            WithdrawRequest storage request = withdrawRequests[requestId];
            request.released = true;
            userIndices.remove(requestId);
        }

        uint256 totalAmount = principalAmount + interestAmount;
        require(IERC20(token).balanceOf(address(this)) >= totalAmount, "Insufficient contract balance");
        IERC20(token).safeTransfer(user, totalAmount);

        emit Claimed(user, requestIds, principalAmount, interestAmount);
    }

    function getClaimableAmount(address user) public view returns (uint256[] memory requestIds, uint256 principal, uint256 interest) {
        EnumerableSet.UintSet storage userIndices = userWithdrawIndices[user];
        uint256[] memory tempRequestIds = new uint256[](userIndices.length());
        uint256 count = 0;

        for (uint256 i = 0; i < userIndices.length(); i++) {
            WithdrawRequest storage request = withdrawRequests[userIndices.at(i)];
            if (!request.released && request.releaseTime <= block.timestamp && withdrawReleased[request.unitTime]) {
                tempRequestIds[count] = request.id;
                principal += request.principalAmount;
                interest += request.interestAmount;
                count++;
            }
        }

        requestIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            requestIds[i] = tempRequestIds[i];
        }

        return (requestIds, principal, interest);
    }

    function updateYield(uint256 amount) external onlyOperator whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");

        // Check if yield was already updated for current day
        uint256 currentUnitStart = getTimeUnitStart(block.timestamp);
        require(!yieldUpdatedForDay[currentUnitStart], "Yield already updated for today");

        // Check if amount exceeds max yield rate
        uint256 maxYieldAmount = getMaxYieldAmount();
        require(amount <= maxYieldAmount, "Amount exceeds max yield rate");

        // Update total interest
        totalInterest += amount;

        // Record yield update in history
        yieldHistory.push(YieldUpdate({timestamp: block.timestamp, amount: amount, totalInterest: totalInterest}));

        // Mark yield as updated for current day
        yieldUpdatedForDay[currentUnitStart] = true;

        emit YieldUpdated(amount, totalInterest);
    }

    function getPendingWithdrawalsForDay(uint256 timestamp) public view returns (uint256 totalAmount) {
        for (uint256 i = 0; i < withdrawRequests.length; i++) {
            WithdrawRequest storage request = withdrawRequests[i];
            if (!request.released && request.releaseTime == timestamp) {
                totalAmount += request.principalAmount + request.interestAmount;
            }
        }
        return totalAmount;
    }

    function getUserWithdrawRequests(address user) external view returns (WithdrawRequest[] memory) {
        EnumerableSet.UintSet storage userIndices = userWithdrawIndices[user];
        uint256 length = userIndices.length();
        WithdrawRequest[] memory requests = new WithdrawRequest[](length);

        for (uint256 i = 0; i < length; i++) {
            requests[i] = withdrawRequests[userIndices.at(i)];
        }

        return requests;
    }

    function getTimeUnitStart(uint256 timestamp) public pure returns (uint256) {
        return (timestamp / TIME_UNIT) * TIME_UNIT;
    }

    function getCurrentTimeUnitStart() public view returns (uint256) {
        return getTimeUnitStart(block.timestamp);
    }

    function getMaxYieldAmount() public view returns (uint256) {
        return (totalSupply * yieldMaxRate) / 10000;
    }

    function releaseTime(uint256 timestamp) public view virtual returns (uint256) {
        uint256 currentUnit = timestamp / TIME_UNIT;
        return (currentUnit + 1) * TIME_UNIT + (withdrawalDelay * TIME_UNIT);
    }

    function getCurrentReleaseTime() public view virtual returns (uint256) {
        return releaseTime(block.timestamp);
    }

    function getTargetUndelegateTimestamp(uint256 timestamp) public view returns (uint256) {
        uint256 currentUnit = timestamp / TIME_UNIT;
        return currentUnit * TIME_UNIT - (withdrawalDelay * TIME_UNIT);
    }

    function getCurrentTargetUndelegateTimestamp() public view returns (uint256) {
        return getTargetUndelegateTimestamp(block.timestamp);
    }

    function getYieldHistory() external view returns (YieldUpdate[] memory) {
        return yieldHistory;
    }

    function getYieldHistoryLength() external view returns (uint256) {
        return yieldHistory.length;
    }

    function getYieldHistoryAt(uint256 index) external view returns (YieldUpdate memory) {
        require(index < yieldHistory.length, "Index out of bounds");
        return yieldHistory[index];
    }

    function getYieldHistoryByIndexRange(uint256 fromIndex, uint256 toIndex)
        external
        view
        returns (YieldUpdate[] memory)
    {
        require(fromIndex <= toIndex, "Invalid index range");
        require(toIndex < yieldHistory.length, "Index out of bounds");

        uint256 length = toIndex - fromIndex + 1;
        YieldUpdate[] memory result = new YieldUpdate[](length);

        for (uint256 i = 0; i < length; i++) {
            result[i] = yieldHistory[fromIndex + i];
        }

        return result;
    }

    function getUserPrincipal(address user) external view returns (uint256) {
        return depositBalance[user];
    }

    function getUserTotalBalance(address user) external view returns (uint256) {
        if (totalXSupply == 0) return 0;
        return depositXBalance[user] * (totalSupply + totalInterest) / totalXSupply;
    }

    function getUserYield(address user) external view returns (uint256) {
        uint256 totalBalance = this.getUserTotalBalance(user);
        uint256 principal = depositBalance[user];
        return totalBalance > principal ? totalBalance - principal : 0;
    }

    function getUserXBalance(address user) external view returns (uint256) {
        return depositXBalance[user];
    }

    function getExchangeRate() external view returns (uint256) {
        uint256 scaleFactor = 10 ** tokenDecimals;
        if (totalXSupply == 0) return scaleFactor;
        return (totalSupply + totalInterest) * scaleFactor / totalXSupply;
    }

    function getProtocolState() external view returns (
        uint256 _totalSupply,
        uint256 _totalInterest, 
        uint256 _totalXSupply,
        uint256 _exchangeRate
    ) {
        _totalSupply = totalSupply;
        _totalInterest = totalInterest;
        _totalXSupply = totalXSupply;
        _exchangeRate = this.getExchangeRate();
    }

    function getUsersYield(address[] memory users) external view returns (uint256[] memory yieldAmounts) {
        yieldAmounts = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            yieldAmounts[i] = this.getUserYield(users[i]);
        }
        return yieldAmounts;
    }

    function getUserInfo(address user) external view returns (
        uint256 principal,
        uint256 totalBalance,
        uint256 yieldAmount,
        uint256 xBalance
    ) {
        principal = depositBalance[user];
        totalBalance = this.getUserTotalBalance(user);
        yieldAmount = totalBalance > principal ? totalBalance - principal : 0;
        xBalance = depositXBalance[user];
    }

    function getUsersInfo(address[] memory users) external view returns (
        uint256[] memory principals,
        uint256[] memory totalBalances,
        uint256[] memory yieldAmounts,
        uint256[] memory xBalances
    ) {
        principals = new uint256[](users.length);
        totalBalances = new uint256[](users.length);
        yieldAmounts = new uint256[](users.length);
        xBalances = new uint256[](users.length);

        for (uint256 i = 0; i < users.length; i++) {
            principals[i] = depositBalance[users[i]];
            totalBalances[i] = this.getUserTotalBalance(users[i]);
            yieldAmounts[i] = totalBalances[i] > principals[i] ? totalBalances[i] - principals[i] : 0;
            xBalances[i] = depositXBalance[users[i]];
        }

        return (principals, totalBalances, yieldAmounts, xBalances);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
