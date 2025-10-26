// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Laura-bmk
 * @notice Banco que permite depositar y retirar ETH y USDC con conversión a dólares
 * @dev Evolución de KipuBank aplicando lo aprendido en Modulo3:
 * - Soporte multitoken (ETH + USDC)
 * - Integración con Chainlink para precios ETH/USD
 * - Conversión de decimales a USDC (6 decimales)
 * - Contabilidad usando address(0) para ETH
 */
contract KipuBankV2 is Ownable {

    /*//////////////////////////////////////////////////////////////
                            CONSTANTES
    //////////////////////////////////////////////////////////////*/

    // Uso address(0) para representar ETH en ls mappings
    // diferenciar entre ETH nativo y tokens ERC20
    address private constant ETH_ADDRESS = address(0);

    // Estos son los decimales de cada token
    uint8 private constant USDC_DECIMALS = 6;   // USDC tiene 6 decimales
    uint8 private constant ETH_DECIMALS = 18;   // ETH tiene 18 decimales
    
    // Chainlink siempre devuelve precios con 8 decimales
    uint8 private constant ORACLE_DECIMALS = 8;
    
    // Todo en 6 decimales para que coincida con USDC
    uint8 private constant TARGET_DECIMALS = 6;

    /*//////////////////////////////////////////////////////////////
                            VARIABLES DE ESTADO
    //////////////////////////////////////////////////////////////*/

    // Límite por transacción en USD (con 6 decimales)
    // Ej: 1000 USD = 1000000000 (1000 * 10^6)
    uint256 public immutable limitPerTx;

    // Límite total que puede tener el banco en USD (con 6 decimales)
    // Ej: 10000 USD = 10000000000 (10000 * 10^6)
    uint256 public immutable bankCap;

    // Acá se guarda el balance de cada usuario por token
    // Primer mapping: usuario => segundo mapping
    // Segundo mapping: token => balance en USD (6 decimales)
    // Para ETH uso address(0), para USDC se usa su dirección
    mapping(address => mapping(address => uint256)) public balance;

    // Contadores para saber cuántas operaciones se hicieron
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;

    // Esta bandera evita ataques de reentrancia
    // Se mantiene igual q en KipuBank TP2
    bool private flag;

    // El oráculo de Chainlink da el precio de ETH en USD
    AggregatorV3Interface public dataFeed;

    // Referencia al contrato de USDC para hacer transferencias
    IERC20 public immutable USDC;

    /*//////////////////////////////////////////////////////////////
                                EVENTOS
    //////////////////////////////////////////////////////////////*/

    // Se dispara cuando alguien hace un depósito
    event DepositPerformed(
        address indexed user,       // Quién depositó
        address indexed token,      // Qué token (address(0) = ETH)
        uint256 amount,             // Cuánto depositó (en unidades del token)
        uint256 amountInUSDC        // Cuánto vale en USD (6 decimales)
    );

    // Se dispara cuando alguien hace un retiro
    event WithdrawalPerformed(
        address indexed user,       // Quién retiro
        address indexed token,      // Qué token retiró
        uint256 amount              // Cuánto retiró (en unidades del token)
    );

    // Se dispara cuando el owner cambia el oráculo
    event FeedSet(address indexed addr, uint256 time);

    /*//////////////////////////////////////////////////////////////
                                ERRORES
    //////////////////////////////////////////////////////////////*/

    // Errores personalizados 
    // Son más eficientes en gas que los require con strings
    error InvalidAmount();                                          // Cuando el monto es cero
    error ExceedsPerTxLimit(uint256 requested, uint256 limit);     // Supera el límite por transacción
    error InsufficientBalance(uint256 balance, uint256 requested);  // No hay suficiente saldo
    error TransactionFailed(bytes reason);                          // Falló la transferencia de ETH
    error ReentrancyAttempt();                                      // Intento de reentrancia detectado
    error BankCapExceeded(uint256 requested, uint256 available);   // Se supera el límite del banco
    error InvalidContract();                                        // Dirección de contrato inválida

    /*//////////////////////////////////////////////////////////////
                            MODIFICADORES
    //////////////////////////////////////////////////////////////*/

    // Evita que una función se llame a sí misma antes de terminar
    // Es el mismo patrón del KipuBank TP2
    modifier reentrancyGuard() {
        if (flag) revert ReentrancyAttempt();
        flag = true;
        _;
        flag = false;
    }

    // Chequea que el ETH enviado no sea cero
    modifier validAmount() {
        if (msg.value == 0) revert InvalidAmount();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inicializa el banco con los límites y contratos externos
     * @param _limitPerTx Límite por transacción en USD con 6 decimales
     * @param _bankCap Límite total del banco en USD con 6 decimales
     * @param _oracle Dirección del Chainlink DataFeed (ETH/USD)
     * @param _usdc Dirección del contrato USDC
     */
    constructor(
        uint256 _limitPerTx,
        uint256 _bankCap,
        address _oracle,
        address _usdc
    ) Ownable(msg.sender) {
        // Verifica que no pasen direcciones vacías
        if (_oracle == address(0) || _usdc == address(0)) {
            revert InvalidContract();
        }

        limitPerTx = _limitPerTx;
        bankCap = _bankCap;
        dataFeed = AggregatorV3Interface(_oracle);
        USDC = IERC20(_usdc);

        emit FeedSet(_oracle, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES DE DEPÓSITO
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Depositar ETH en el banco
     * @dev Aplica el patrón checks-effects-interactions como en KipuBank revisado
     * Usa el oráculo de Chainlink como en Donations.sol
     */
    function deposit() public payable validAmount {
        // CHECKS: Primero verificar todo antes de modificar el estado
        
        // Obtener el precio actual de ETH desde Chainlink
        int256 _latestAnswer = _getETHPrice();
        
        // Convertir el ETH depositado a USD con 6 decimales
        // Esto se hace con la función vista en clase
        uint256 _depositedInUSDC = _convertToUSD(
            msg.value,                  // Cuánto ETH envió (en wei)
            ETH_DECIMALS,               // ETH tiene 18 decimales
            uint256(_latestAnswer)      // Precio de ETH en USD (8 decimales)
        );

        // Calcular cuánto tendría el banco después de este depósito
        uint256 _totalBankUSD = _getTotalBankValueUSD() + _depositedInUSDC;
        
        // Verifica que no supere el límite del banco
        if (_totalBankUSD > bankCap) {
            revert BankCapExceeded(_totalBankUSD, bankCap);
        }

        // EFFECTS: Actualizamos el estado del contrato
        // Uso unchecked porque ya está verificado que no se supera el bankCap
        //corrección del TP2
        unchecked {
            balance[msg.sender][ETH_ADDRESS] += _depositedInUSDC;
            totalDeposits++;
        }

        // INTERACTIONS: Al final se emite el evento
        emit DepositPerformed(msg.sender, ETH_ADDRESS, msg.value, _depositedInUSDC);
    }

    /**
     * @notice Depositar USDC en el banco
     * @param _usdcAmount Cantidad de USDC a depositar (con 6 decimales)
     * @dev Usa transferFrom como vimos en Donations.sol
     * El usuario debe hacer approve() primero
     */
    function depositUSDC(uint256 _usdcAmount) external {
        // CHECKS
        if (_usdcAmount == 0) revert InvalidAmount();

        // USDC ya está en 6 decimales, así que es 1:1 en la contabilidad
        // No hay q convertir nada, solo verificar el límite del banco
        uint256 _totalBankUSD = _getTotalBankValueUSD() + _usdcAmount;
        if (_totalBankUSD > bankCap) {
            revert BankCapExceeded(_totalBankUSD, bankCap);
        }

        // EFFECTS
        unchecked {
            balance[msg.sender][address(USDC)] += _usdcAmount;
            totalDeposits++;
        }

        // INTERACTIONS
        // Transfere los USDC del usuario hacia este contrato
        // Igual que en Donations.sol
        USDC.transferFrom(msg.sender, address(this), _usdcAmount);

        emit DepositPerformed(msg.sender, address(USDC), _usdcAmount, _usdcAmount);
    }

    /**
     * @notice Recibe ETH cuando alguien envía sin llamar ninguna función
     */
    receive() external payable {
        deposit();
    }

    /**
     * @notice Se ejecuta si alguien llama una función que no existe
     */
    fallback() external payable {
        deposit();
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES DE RETIRO
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retirar ETH del banco
     * @param amount Cantidad de ETH a retirar en wei
     * @return data Lo que devuelve la llamada de transferencia
     */
    function withdraw(uint256 amount)
        external
        reentrancyGuard
        returns (bytes memory data)
    {
        // CHECKS
        if (amount == 0) revert InvalidAmount();

        // Averiguo el precio actual para saber cuánto vale el retiro en USD
        int256 _latestAnswer = _getETHPrice();
        uint256 _withdrawInUSDC = _convertToUSD(
            amount,
            ETH_DECIMALS,
            uint256(_latestAnswer)
        );

        // Verifica el límite por transacción
        if (_withdrawInUSDC > limitPerTx) {
            revert ExceedsPerTxLimit(_withdrawInUSDC, limitPerTx);
        }

        // Verifica que tenga suficiente saldo
        uint256 userBalance = balance[msg.sender][ETH_ADDRESS];
        if (_withdrawInUSDC > userBalance) {
            revert InsufficientBalance(userBalance, _withdrawInUSDC);
        }

        // EFFECTS
        // Actualiza el estado ANTES de enviar ETH (anti-reentrancy)
        unchecked {
            balance[msg.sender][ETH_ADDRESS] = userBalance - _withdrawInUSDC;
            totalWithdrawals++;
        }

        // INTERACTIONS
        // Envia el ETH usando la función privada
        data = _transferEth(msg.sender, amount);

        emit WithdrawalPerformed(msg.sender, ETH_ADDRESS, amount);
        return data;
    }

    /**
     * @notice Retirar USDC del banco
     * @param amount Cantidad de USDC a retirar (con 6 decimales)
     */
    function withdrawUSDC(uint256 amount) external reentrancyGuard {
        // CHECKS
        if (amount == 0) revert InvalidAmount();
        
        // Para USDC el límite se aplica directamente porque ya está en 6 decimales
        if (amount > limitPerTx) {
            revert ExceedsPerTxLimit(amount, limitPerTx);
        }

        uint256 userBalance = balance[msg.sender][address(USDC)];
        if (amount > userBalance) {
            revert InsufficientBalance(userBalance, amount);
        }

        // EFFECTS
        unchecked {
            balance[msg.sender][address(USDC)] = userBalance - amount;
            totalWithdrawals++;
        }

        // INTERACTIONS
        USDC.transfer(msg.sender, amount);

        emit WithdrawalPerformed(msg.sender, address(USDC), amount);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES PRIVADAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Envía ETH a una dirección usando call
     * @param to Dirección que recibe el ETH
     * @param amount Cantidad en wei
     * @return Datos que devuelve la llamada
     */
    function _transferEth(address to, uint256 amount)
        private
        returns (bytes memory)
    {
        // Uso call en lugar de transfer porque es más seguro
        // Lo modifiqué para el anterior KipuBank
        (bool success, bytes memory data) = to.call{value: amount}("");
        if (!success) revert TransactionFailed(data);
        return data;
    }

    /**
     * @notice Obtiene el precio de ETH en USD desde Chainlink
     * @return _latestAnswer Precio con 8 decimales
     * @dev Igual que _getETHPrice() de Donations.sol
     */
    function _getETHPrice() private view returns(int256 _latestAnswer) {
        // Llama al oráculo de Chainlink
        // Devuelve varios datos pero solo uso el precio (answer)
        (
            /* uint80 roundId */,
            _latestAnswer,
            /*uint256 startedAt*/,
            /*uint256 updatedAt*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();

        return _latestAnswer;
    }

    /**
     * @notice Convierte cualquier monto a USD con 6 decimales
     * @dev  "función de conversión de decimales y valores" que pide la consigna
     * @param _amount Monto original del token
     * @param _decimals Cuántos decimales tiene ese token
     * @param _priceUSD Precio en USD del token (con 8 decimales de Chainlink)
     * @return _valueUSD Valor equivalente en USD con 6 decimales
     */
    function _convertToUSD(
        uint256 _amount,
        uint8 _decimals,
        uint256 _priceUSD
    ) private pure returns (uint256 _valueUSD) {
        // La fórmula sería: (monto * precio * 10^6) / (10^decimales_token * 10^8)
        // Simplificado: (monto * precio) / 10^(decimales_token + 8 - 6)
        
        // Ejemplo con 1 ETH (1 * 10^18 wei) a $4000:
        // numerator = 10^18 * (4000 * 10^8) = 10^18 * 4 * 10^11
        // denominator = 10^(18 + 8 - 6) = 10^20
        // resultado = (10^18 * 4 * 10^11) / 10^20 = 4000 * 10^6 = 4000 USDC
        
        uint256 numerator = _amount * _priceUSD;
        uint256 denominator = 10 ** (_decimals + ORACLE_DECIMALS - TARGET_DECIMALS);
        
        return numerator / denominator;
    }

    /**
     * @notice Calcula cuánto vale todo el banco en USD
     * @return _totalUSD Valor total con 6 decimales
     */
    function _getTotalBankValueUSD() private view returns (uint256 _totalUSD) {
        // Obtenemos el precio actual de ETH
        int256 _latestAnswer = _getETHPrice();
        
        // Calcula cuánto vale todo el ETH del contrato
        uint256 totalETH = address(this).balance;
        uint256 ethValueUSD = _convertToUSD(
            totalETH,
            ETH_DECIMALS,
            uint256(_latestAnswer)
        );

        // Sumar todo el USDC (que ya está en 6 decimales)
        uint256 totalUSDC = USDC.balanceOf(address(this));

        _totalUSD = ethValueUSD + totalUSDC;
    }

    /*//////////////////////////////////////////////////////////////
                    FUNCIONES DE CONSULTA (VIEW)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Cuánto ETH tiene el contrato en total
     */
    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Cuánto tiene un usuario de un token específico
     * @param account Usuario a consultar
     * @param token Token a consultar (address(0) = ETH)
     * @return Saldo en USD con 6 decimales
     */
    function balanceOf(address account, address token) external view returns (uint256) {
        return balance[account][token];
    }

    /**
     * @notice Cuánto tiene un usuario en total (ETH + USDC sumados)
     * @param account Usuario a consultar
     * @return Saldo total en USD con 6 decimales
     */
    function totalBalance(address account) external view returns (uint256) {
        return balance[account][ETH_ADDRESS] + balance[account][address(USDC)];
    }

    /**
     * @notice Cuánto vale todo el banco en USD
     * @return Valor total con 6 decimales
     */
    function totalBankValueUSD() external view returns (uint256) {
        return _getTotalBankValueUSD();
    }

    /*//////////////////////////////////////////////////////////////
                    FUNCIONES DE ADMINISTRACIÓN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Cambiar el oráculo de Chainlink
     * @param _feed Nueva dirección del DataFeed
     * @dev Solo el owner puede hacer esto
     * Es igual que setFeeds() de DonationsV2.sol
     */
    function setFeeds(address _feed) external onlyOwner {
        if (_feed == address(0)) revert InvalidContract();
        dataFeed = AggregatorV3Interface(_feed);
        emit FeedSet(_feed, block.timestamp);
    }
}