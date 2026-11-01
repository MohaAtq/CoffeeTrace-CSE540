// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICoffeeTrace
 * @notice Interface for the CoffeeTrace supply chain provenance contract.
 *         It lists every data type, event and function the system exposes,
 *         so the web UI and other contracts know how to talk to it.
 *
 * Product journey (one coffee batch):
 *   Farmer --> Exporter --> Roaster --> Retailer (store) --> Customer
 *   Status:  Harvested -> Exported -> Roasted -> Sold
 */
interface ICoffeeTrace {
    // ---------------------------------------------------------------------
    // Data types
    // ---------------------------------------------------------------------

    /// @notice Stage of a coffee batch in the supply chain.
    enum Status {
        Harvested, // registered by the farmer
        Exported,  // shipped by the exporter
        Roasted,   // roasted by the roaster
        Sold       // sold by the retailer to a customer
    }

    /// @notice Main record stored on-chain for each coffee batch.
    struct Batch {
        uint256 id;             // unique batch ID (also the ERC-721 token ID)
        string origin;          // farm name / region, e.g. "Finca El Paraiso, Huila, Colombia"
        string geolocation;     // GPS coordinates of the plot "lat,long" (EU Deforestation Regulation)
        string variety;         // coffee variety, e.g. "Arabica"
        uint256 weightKg;       // batch weight in kilograms
        uint256 harvestDate;    // unix timestamp of the harvest
        Status status;          // current stage
        bool certified;         // true after a certifier approves it
        string certificateCID;  // IPFS hash (CID) of the fair-trade / organic certificate
        uint256 createdAt;      // block timestamp when the batch was registered
    }

    /// @notice One reading from the (simulated) IoT sensor during shipping.
    struct ConditionReading {
        int256 temperatureX10;  // temperature in Celsius x 10 (e.g. 215 = 21.5 C)
        uint256 humidityX10;    // relative humidity in % x 10 (e.g. 605 = 60.5 %)
        uint256 timestamp;      // when the reading was recorded
    }

    // ---------------------------------------------------------------------
    // Events (the permanent, auditable history of every batch)
    // ---------------------------------------------------------------------

    event BatchRegistered(uint256 indexed batchId, address indexed farmer, string origin, uint256 weightKg);
    event BatchTransferred(uint256 indexed batchId, address indexed from, address indexed to);
    event StatusUpdated(uint256 indexed batchId, Status newStatus, address indexed updatedBy);
    event BatchCertified(uint256 indexed batchId, address indexed certifier, string certificateCID);
    event ConditionRecorded(uint256 indexed batchId, int256 temperatureX10, uint256 humidityX10, uint256 timestamp);

    // ---------------------------------------------------------------------
    // Write functions (each one is restricted to a specific role)
    // ---------------------------------------------------------------------

    /// @notice Farmer creates a new batch. Mints an ERC-721 token to the farmer.
    /// @return batchId The new batch ID.
    function registerBatch(
        string calldata origin,
        string calldata geolocation,
        string calldata variety,
        uint256 weightKg,
        uint256 harvestDate
    ) external returns (uint256 batchId);

    /// @notice Current owner hands the batch to the next stakeholder in the chain.
    function transferBatch(uint256 batchId, address to) external;

    /// @notice Current owner moves the batch to the next stage (one step at a time).
    function updateStatus(uint256 batchId, Status newStatus) external;

    /// @notice Certifier approves the batch and attaches the IPFS CID of the certificate.
    function certifyBatch(uint256 batchId, string calldata certificateCID) external;

    /// @notice Oracle (simulated IoT sensor) records shipping conditions.
    function recordCondition(uint256 batchId, int256 temperatureX10, uint256 humidityX10) external;

    // ---------------------------------------------------------------------
    // Read functions (anyone can call these, e.g. a customer scanning a QR code)
    // ---------------------------------------------------------------------

    /// @notice Returns the full on-chain record of a batch.
    function getBatch(uint256 batchId) external view returns (Batch memory);

    /// @notice Returns every address that has held the batch, in order.
    function getCustodyHistory(uint256 batchId) external view returns (address[] memory);

    /// @notice Returns all IoT readings recorded for the batch.
    function getConditionReadings(uint256 batchId) external view returns (ConditionReading[] memory);

    /// @notice Returns the total number of registered batches.
    function totalBatches() external view returns (uint256);
}
