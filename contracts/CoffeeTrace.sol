// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/ICoffeeTrace.sol";

/**
 * @title CoffeeTrace
 * @notice Blockchain-based coffee supply chain provenance system (CSE 540, Project 1).
 *
 * How it works:
 *  - Each coffee batch is an ERC-721 token (unique ID + owner).
 *  - Stakeholders have roles (Farmer, Exporter, Roaster, Retailer, Certifier, Oracle).
 *  - A batch moves:  Farmer -> Exporter -> Roaster -> Retailer -> (Customer)
 *    with status:    Harvested -> Exported -> Roasted -> Sold
 *  - Certificates (fair-trade / organic) live on IPFS; only their CID is stored here.
 *  - A simulated IoT sensor (Oracle role) records temperature and humidity while shipping.
 *  - Each batch stores the farm's GPS coordinates (needed for EU Deforestation Regulation).
 *  - Every action emits an event, giving a permanent and public history.
 *
 * DRAFT (Smart Contract Design milestone): structure, interfaces and core logic are in
 * place. Planned next steps are marked with "TODO".
 */
contract CoffeeTrace is ERC721, AccessControl, ICoffeeTrace {
    // ---------------------------------------------------------------------
    // Roles (role-based access control)
    // ---------------------------------------------------------------------

    bytes32 public constant FARMER_ROLE    = keccak256("FARMER_ROLE");
    bytes32 public constant EXPORTER_ROLE  = keccak256("EXPORTER_ROLE");
    bytes32 public constant ROASTER_ROLE   = keccak256("ROASTER_ROLE");
    bytes32 public constant RETAILER_ROLE  = keccak256("RETAILER_ROLE");
    bytes32 public constant CERTIFIER_ROLE = keccak256("CERTIFIER_ROLE");
    bytes32 public constant ORACLE_ROLE    = keccak256("ORACLE_ROLE"); // simulated IoT sensor

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    uint256 private _nextBatchId = 1;                                  // batch IDs start at 1
    mapping(uint256 => Batch) private _batches;                        // batchId => batch record
    mapping(uint256 => address[]) private _custodyHistory;             // batchId => list of holders
    mapping(uint256 => ConditionReading[]) private _conditionReadings; // batchId => IoT readings

    // ---------------------------------------------------------------------
    // Custom errors (cheaper than revert strings and easier to read in the UI)
    // ---------------------------------------------------------------------

    error BatchDoesNotExist(uint256 batchId);
    error NotBatchOwner(uint256 batchId, address caller);
    error InvalidStatusTransition(Status current, Status requested);
    error MissingRoleForStatus(Status requested, address caller);
    error InvalidRecipient(address to);
    error InvalidInput(string reason);
    error AlreadyCertified(uint256 batchId);
    error BatchAlreadySold(uint256 batchId);
    error DirectTransferDisabled();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    /// @dev Reverts if the batch was never registered.
    modifier batchExists(uint256 batchId) {
        if (batchId == 0 || batchId >= _nextBatchId) revert BatchDoesNotExist(batchId);
        _;
    }

    /// @dev Reverts unless the caller currently holds (owns) the batch.
    modifier onlyBatchOwner(uint256 batchId) {
        if (ownerOf(batchId) != msg.sender) revert NotBatchOwner(batchId, msg.sender);
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @notice The deployer becomes the admin who can grant roles to stakeholders.
    constructor() ERC721("CoffeeTrace Batch", "COFFEE") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Farmer: register a new batch
    // ---------------------------------------------------------------------

    /// @inheritdoc ICoffeeTrace
    function registerBatch(
        string calldata origin,
        string calldata geolocation,
        string calldata variety,
        uint256 weightKg,
        uint256 harvestDate
    ) external override onlyRole(FARMER_ROLE) returns (uint256 batchId) {
        if (bytes(origin).length == 0) revert InvalidInput("origin is empty");
        if (bytes(geolocation).length == 0) revert InvalidInput("geolocation is empty");
        if (weightKg == 0) revert InvalidInput("weight must be > 0");
        if (harvestDate > block.timestamp) revert InvalidInput("harvest date is in the future");

        batchId = _nextBatchId++;

        _batches[batchId] = Batch({
            id: batchId,
            origin: origin,
            geolocation: geolocation,
            variety: variety,
            weightKg: weightKg,
            harvestDate: harvestDate,
            status: Status.Harvested,
            certified: false,
            certificateCID: "",
            createdAt: block.timestamp
        });

        _safeMint(msg.sender, batchId);            // ERC-721 token goes to the farmer
        _custodyHistory[batchId].push(msg.sender); // farmer is the first holder

        emit BatchRegistered(batchId, msg.sender, origin, weightKg);
    }

    // ---------------------------------------------------------------------
    // Custody transfer between stakeholders
    // ---------------------------------------------------------------------

    /**
     * @inheritdoc ICoffeeTrace
     * @dev The recipient must hold the role for the next step in the chain:
     *      Harvested -> Exporter, Exported -> Roaster, Roasted -> Retailer,
     *      Sold -> any address (the final customer).
     */
    function transferBatch(uint256 batchId, address to)
        external
        override
        batchExists(batchId)
        onlyBatchOwner(batchId)
    {
        if (to == address(0) || to == msg.sender) revert InvalidRecipient(to);

        Status current = _batches[batchId].status;
        if (current != Status.Sold && !hasRole(_requiredRecipientRole(current), to)) {
            revert InvalidRecipient(to);
        }

        _transfer(msg.sender, to, batchId); // internal ERC-721 transfer (public ones are disabled)
        _custodyHistory[batchId].push(to);

        emit BatchTransferred(batchId, msg.sender, to);
    }

    // ---------------------------------------------------------------------
    // Status updates
    // ---------------------------------------------------------------------

    /**
     * @inheritdoc ICoffeeTrace
     * @dev Status can only move forward one step, and only by the owner who has
     *      the matching role (Exporter -> Exported, Roaster -> Roasted, Retailer -> Sold).
     */
    function updateStatus(uint256 batchId, Status newStatus)
        external
        override
        batchExists(batchId)
        onlyBatchOwner(batchId)
    {
        Status current = _batches[batchId].status;
        if (uint8(newStatus) != uint8(current) + 1) revert InvalidStatusTransition(current, newStatus);
        if (!hasRole(_requiredRoleForStatus(newStatus), msg.sender)) {
            revert MissingRoleForStatus(newStatus, msg.sender);
        }

        _batches[batchId].status = newStatus;
        emit StatusUpdated(batchId, newStatus, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Certifier: approve a batch (certificate stored on IPFS)
    // ---------------------------------------------------------------------

    /// @inheritdoc ICoffeeTrace
    function certifyBatch(uint256 batchId, string calldata certificateCID)
        external
        override
        onlyRole(CERTIFIER_ROLE)
        batchExists(batchId)
    {
        if (bytes(certificateCID).length == 0) revert InvalidInput("CID is empty");
        if (_batches[batchId].certified) revert AlreadyCertified(batchId);

        _batches[batchId].certified = true;
        _batches[batchId].certificateCID = certificateCID;

        emit BatchCertified(batchId, msg.sender, certificateCID);
        // TODO (stretch): allow a certifier to revoke a certificate.
    }

    // ---------------------------------------------------------------------
    // Oracle: record IoT sensor data during shipping
    // ---------------------------------------------------------------------

    /// @inheritdoc ICoffeeTrace
    function recordCondition(uint256 batchId, int256 temperatureX10, uint256 humidityX10)
        external
        override
        onlyRole(ORACLE_ROLE)
        batchExists(batchId)
    {
        if (_batches[batchId].status == Status.Sold) revert BatchAlreadySold(batchId);
        if (humidityX10 > 1000) revert InvalidInput("humidity must be 0-100%");

        _conditionReadings[batchId].push(
            ConditionReading({temperatureX10: temperatureX10, humidityX10: humidityX10, timestamp: block.timestamp})
        );

        emit ConditionRecorded(batchId, temperatureX10, humidityX10, block.timestamp);
        // TODO (stretch): flag readings outside a safe range (e.g. humidity > 70%).
    }

    // ---------------------------------------------------------------------
    // Read functions (public: a customer can verify a batch by its ID / QR code)
    // ---------------------------------------------------------------------

    /// @inheritdoc ICoffeeTrace
    function getBatch(uint256 batchId) external view override batchExists(batchId) returns (Batch memory) {
        return _batches[batchId];
    }

    /// @inheritdoc ICoffeeTrace
    function getCustodyHistory(uint256 batchId)
        external
        view
        override
        batchExists(batchId)
        returns (address[] memory)
    {
        return _custodyHistory[batchId];
    }

    /// @inheritdoc ICoffeeTrace
    function getConditionReadings(uint256 batchId)
        external
        view
        override
        batchExists(batchId)
        returns (ConditionReading[] memory)
    {
        return _conditionReadings[batchId];
    }

    /// @inheritdoc ICoffeeTrace
    function totalBatches() external view override returns (uint256) {
        return _nextBatchId - 1;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Role the recipient must have, based on the batch's current status.
    function _requiredRecipientRole(Status current) internal pure returns (bytes32) {
        if (current == Status.Harvested) return EXPORTER_ROLE;
        if (current == Status.Exported) return ROASTER_ROLE;
        return RETAILER_ROLE; // Status.Roasted
    }

    /// @dev Role the caller must have to move a batch into `newStatus`.
    function _requiredRoleForStatus(Status newStatus) internal pure returns (bytes32) {
        if (newStatus == Status.Exported) return EXPORTER_ROLE;
        if (newStatus == Status.Roasted) return ROASTER_ROLE;
        return RETAILER_ROLE; // Status.Sold
    }

    // ---------------------------------------------------------------------
    // ERC-721 overrides
    // ---------------------------------------------------------------------

    /**
     * @dev Standard ERC-721 transfers are disabled so nobody can skip the role
     *      checks. All custody changes must go through transferBatch().
     *      (safeTransferFrom also calls this, so it is blocked too.)
     */
    function transferFrom(address, address, uint256) public pure override {
        revert DirectTransferDisabled();
    }

    /// @dev Required because both ERC721 and AccessControl implement supportsInterface.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
