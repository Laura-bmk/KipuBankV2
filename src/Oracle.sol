// SPDX-License-Identifier: MIT
pragma solidity >0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Mock del oráculo de Chainlink para testing
// Implementa la interfaz completa de Chainlink
contract Oracle is AggregatorV3Interface {
    
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "ETH / USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId)
        external
        pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, 411788170000, 0, 0, 0);
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        // Precio: 411788170000 = $4117.88 USD con 8 decimales
        // Es el mismo precio que usaba el Oracle de Donations.sol
        return (1, 411788170000, 0, block.timestamp, 1);
    }
}