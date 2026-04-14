// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  Blockchain Lab #7 — ERC-20 & Staking Contract
//  Kookmin University | Prof. Hyoung Joong Kim
//  2026.04.14
// ============================================================

// ──────────────────────────────────────────────────────────
//  PART 1: IERC20 Interface
// ──────────────────────────────────────────────────────────
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// ──────────────────────────────────────────────────────────
//  PART 2: KMU Token (ERC-20)
//  - 배포 시 msg.sender 에게 1,000,000 KMU 발행
//  - Staking Contract 에 deposit 할 토큰으로 사용
// ──────────────────────────────────────────────────────────
contract KMUToken is IERC20 {
    string  public name     = "Kookmin Token";
    string  public symbol   = "KMU";
    uint8   public decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor() {
        uint256 initialSupply = 1_000_000 * 10 ** decimals;
        _totalSupply = initialSupply;
        _balances[msg.sender] = initialSupply;
        emit Transfer(address(0), msg.sender, initialSupply);
    }

    // ── ERC-20 필수 함수 ──────────────────────────────────

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /// @notice msg.sender → to 로 amount 만큼 토큰 전송
    function transfer(address to, uint256 amount) external override returns (bool) {
        require(to != address(0), "ERC20: transfer to zero address");
        require(_balances[msg.sender] >= amount, "ERC20: insufficient balance");

        _balances[msg.sender] -= amount;
        _balances[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice msg.sender 가 spender 에게 amount 만큼 사용 허가
    function approve(address spender, uint256 amount) external override returns (bool) {
        require(spender != address(0), "ERC20: approve to zero address");
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice msg.sender(= 스테이킹 컨트랙트) 가 from → to 로 amount 전송
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(to != address(0), "ERC20: transfer to zero address");
        require(_balances[from] >= amount, "ERC20: insufficient balance");
        require(_allowances[from][msg.sender] >= amount, "ERC20: insufficient allowance");

        _allowances[from][msg.sender] -= amount;
        _balances[from]               -= amount;
        _balances[to]                 += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // ── 추가: faucet (테스트용) ───────────────────────────
    /// @notice 테스트넷용 - 누구나 1000 KMU 를 받을 수 있음
    function faucet() external {
        uint256 amount = 1_000 * 10 ** decimals;
        _totalSupply           += amount;
        _balances[msg.sender]  += amount;
        emit Transfer(address(0), msg.sender, amount);
    }
}

// ──────────────────────────────────────────────────────────
//  PART 3: Staking Contract
//
//  기능:
//   - stake(amount)       : 토큰을 컨트랙트에 예치
//   - unstake(amount)     : 예치한 토큰 출금
//   - claimReward()       : 누적 보상(KMU) 수령
//   - emergencyWithdraw() : 보상 포기 후 원금 즉시 출금
//   - getStakeInfo()      : 내 스테이킹 현황 조회
//
//  보상 계산:
//   - 1초당 스테이킹 금액의 rewardRatePerSecond (기본 1e12 = 0.0001%) 비율
//   - 즉 100 KMU 를 1시간 스테이킹하면 약 0.036 KMU 보상
// ──────────────────────────────────────────────────────────
contract StakingContract {

    // ── 상태 변수 ─────────────────────────────────────────
    IERC20  public immutable stakingToken;   // 스테이킹 & 보상 토큰 (동일 토큰)
    address public           owner;

    uint256 public constant REWARD_RATE_PER_SECOND = 1e12; // per 1e18 token per second
    uint256 public totalStaked;

    struct StakeInfo {
        uint256 amount;          // 현재 스테이킹 중인 양
        uint256 stakedAt;        // 최근 스테이크 타임스탬프
        uint256 rewardDebt;      // 이미 수령한 보상 누계
        uint256 pendingReward;   // 아직 미수령 보상 (스냅샷)
    }

    mapping(address => StakeInfo) public stakes;

    // ── 이벤트 ────────────────────────────────────────────
    event Staked(address indexed user, uint256 amount, uint256 timestamp);
    event Unstaked(address indexed user, uint256 amount, uint256 timestamp);
    event RewardClaimed(address indexed user, uint256 reward, uint256 timestamp);
    event EmergencyWithdraw(address indexed user, uint256 amount, uint256 timestamp);

    // ── 생성자 ────────────────────────────────────────────
    constructor(address _stakingToken) {
        stakingToken = IERC20(_stakingToken);
        owner        = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ── 내부 함수: 미수령 보상 계산 ───────────────────────
    function _calcPending(address user) internal view returns (uint256) {
        StakeInfo memory s = stakes[user];
        if (s.amount == 0) return s.pendingReward;

        uint256 elapsed = block.timestamp - s.stakedAt;
        uint256 earned  = (s.amount * elapsed * REWARD_RATE_PER_SECOND) / 1e18;
        return s.pendingReward + earned;
    }

    // ── stake(): 토큰 예치 ────────────────────────────────
    /// @notice 사전에 approve(stakingContract, amount) 를 호출해야 함
    function stake(uint256 amount) external {
        require(amount > 0, "Cannot stake 0");

        StakeInfo storage s = stakes[msg.sender];

        // 기존 보상 스냅샷 저장
        if (s.amount > 0) {
            s.pendingReward = _calcPending(msg.sender);
        }

        // transferFrom 으로 토큰 가져옴 (approve 필요)
        bool ok = stakingToken.transferFrom(msg.sender, address(this), amount);
        require(ok, "Transfer failed");

        s.amount    += amount;
        s.stakedAt   = block.timestamp;
        totalStaked += amount;

        emit Staked(msg.sender, amount, block.timestamp);
    }

    // ── unstake(): 토큰 출금 ──────────────────────────────
    function unstake(uint256 amount) external {
        StakeInfo storage s = stakes[msg.sender];
        require(s.amount >= amount, "Insufficient staked amount");
        require(amount > 0, "Cannot unstake 0");

        // 보상 스냅샷 저장
        s.pendingReward = _calcPending(msg.sender);

        s.amount    -= amount;
        s.stakedAt   = block.timestamp;
        totalStaked -= amount;

        bool ok = stakingToken.transfer(msg.sender, amount);
        require(ok, "Transfer failed");

        emit Unstaked(msg.sender, amount, block.timestamp);
    }

    // ── claimReward(): 보상 수령 ──────────────────────────
    function claimReward() external {
        StakeInfo storage s = stakes[msg.sender];
        uint256 reward = _calcPending(msg.sender);
        require(reward > 0, "No reward to claim");

        s.pendingReward = 0;
        s.stakedAt      = block.timestamp;  // 타이머 리셋
        s.rewardDebt   += reward;

        // 컨트랙트가 보상 토큰을 충분히 보유해야 함
        bool ok = stakingToken.transfer(msg.sender, reward);
        require(ok, "Reward transfer failed");

        emit RewardClaimed(msg.sender, reward, block.timestamp);
    }

    // ── emergencyWithdraw(): 보상 포기 + 원금 즉시 출금 ──
    function emergencyWithdraw() external {
        StakeInfo storage s = stakes[msg.sender];
        uint256 amount = s.amount;
        require(amount > 0, "Nothing staked");

        totalStaked    -= amount;
        s.amount        = 0;
        s.pendingReward = 0;
        s.stakedAt      = 0;

        bool ok = stakingToken.transfer(msg.sender, amount);
        require(ok, "Transfer failed");

        emit EmergencyWithdraw(msg.sender, amount, block.timestamp);
    }

    // ── View 함수 ─────────────────────────────────────────

    /// @notice 내 스테이킹 정보 한눈에 조회
    function getStakeInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 pendingReward,
        uint256 stakedSince,
        uint256 totalRewardEarned
    ) {
        StakeInfo memory s = stakes[user];
        return (
            s.amount,
            _calcPending(user),
            s.stakedAt,
            s.rewardDebt
        );
    }

    /// @notice 컨트랙트가 보유한 토큰 (보상 재원)
    function contractBalance() external view returns (uint256) {
        return stakingToken.balanceOf(address(this));
    }

    // ── 오너 전용: 보상 재원 추가 ─────────────────────────
    /// @notice 컨트랙트에 보상용 토큰을 추가 deposit
    function fundRewards(uint256 amount) external onlyOwner {
        bool ok = stakingToken.transferFrom(msg.sender, address(this), amount);
        require(ok, "Fund transfer failed");
    }
}
