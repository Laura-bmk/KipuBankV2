/* Aplico observaciones realizadas a KipuBankV2 para mejorar el código y prepararlo para el TP4*/


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
 * @notice Banco descentralizado que permite depositar y retirar ETH y USDC con conversión a dólares
 * @dev Evolución de KipuBank aplicando conceptos del Módulo 3:
 * - Soporte multitoken (ETH + USDC)
 * - Integración con Chainlink para precios ETH/USD en tiempo real
 * - Conversión automática de decimales a USDC (6 decimales)
 * - Contabilidad interna usando address(0) para representar ETH
 * - Validaciones mediante modifiers reutilizables
 * - Protección contra reentrancia optimizada con uint8
 * - Patrón Checks-Effects-Interactions aplicado consistentemente
 */
contract KipuBankV2 is Ownable {

    /*//////////////////////////////////////////////////////////////
                            CONSTANTES
    //////////////////////////////////////////////////////////////*/

    /// @notice Dirección usada para representar ETH nativo en los mappings
    /// @dev Se usa address(0) para diferenciar ETH de tokens ERC20
    address private constant ETH_ADDRESS = address(0);

    /// @notice Cantidad de decimales del token USDC
    /// @dev USDC en la mayoría de redes tiene 6 decimales
    uint8 private constant USDC_DECIMALS = 6;
    
    /// @notice Cantidad de decimales de ETH
    /// @dev ETH siempre tiene 18 decimales (1 ETH = 10^18 wei)
    uint8 private constant ETH_DECIMALS = 18;
    
    /// @notice Cantidad de decimales que devuelve el oráculo de Chainlink
    /// @dev Todos los price feeds de Chainlink usan 8 decimales
    uint8 private constant ORACLE_DECIMALS = 8;
    
    /// @notice Cantidad de decimales objetivo para la contabilidad interna
    /// @dev Se usa 6 decimales para coincidir con USDC y simplificar cálculos
    uint8 private constant TARGET_DECIMALS = 6;

    /// @notice Estado desbloqueado del lock de reentrancia
    /// @dev Valor inicial y final del flag (1 = desbloqueado)
    uint8 private constant UNLOCKED = 1;
    
    /// @notice Estado bloqueado del lock de reentrancia
    /// @dev Valor temporal mientras se ejecuta una función protegida (2 = bloqueado)
    uint8 private constant LOCKED = 2;

    /*//////////////////////////////////////////////////////////////
                            VARIABLES DE ESTADO
    //////////////////////////////////////////////////////////////*/

    /// @notice Límite máximo por transacción en USD con 6 decimales
    /// @dev Ejemplo: 1000 USD = 1000000000 (1000 * 10^6)
    /// @dev Se usa para prevenir transacciones excesivamente grandes
    uint256 public immutable limitPerTx;

    /// @notice Capacidad máxima total del banco en USD con 6 decimales
    /// @dev Ejemplo: 10000 USD = 10000000000 (10000 * 10^6)
    /// @dev Limita la exposición total del banco
    uint256 public immutable bankCap;

    /// @notice Balance de cada usuario por token en USD (6 decimales)
    /// @dev Estructura: usuario => token => balance en USD
    /// @dev Para ETH se usa address(0), para USDC su dirección de contrato
    /// @dev Los balances se almacenan en valor USD para simplificar la contabilidad
    mapping(address => mapping(address => uint256)) public balance;

    /// @notice Contador total de depósitos realizados
    /// @dev Se incrementa en cada depósito exitoso (ETH o USDC)
    uint256 public totalDeposits;
    
    /// @notice Contador total de retiros realizados
    /// @dev Se incrementa en cada retiro exitoso (ETH o USDC)
    uint256 public totalWithdrawals;

    /// @notice Lock de reentrancia optimizado usando uint8
    /// @dev Usa valores 1→2→1 en vez de bool false→true→false
    /// @dev Ahorra ~15,000 gas por transacción al evitar escribir 0 en storage
    /// @dev Alterna entre UNLOCKED (1) y LOCKED (2)
    uint8 private flag = UNLOCKED;

    /// @notice Oráculo de Chainlink que proporciona el precio ETH/USD
    /// @dev Interfaz AggregatorV3Interface para obtener precios en tiempo real
    AggregatorV3Interface public dataFeed;

    /// @notice Referencia al contrato del token USDC
    /// @dev Se usa para hacer transferencias de USDC mediante transferFrom y transfer
    IERC20 public immutable USDC;

    /*//////////////////////////////////////////////////////////////
                                EVENTOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Se emite cuando un usuario realiza un depósito
    /// @param user Dirección del usuario que depositó
    /// @param token Dirección del token depositado (address(0) para ETH, dirección del contrato para USDC)
    /// @param amount Cantidad depositada en unidades del token original (wei para ETH, unidades USDC para USDC)
    /// @param amountInUSDC Valor equivalente del depósito en USD con 6 decimales
    event DepositPerformed(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 amountInUSDC
    );

    /// @notice Se emite cuando un usuario realiza un retiro
    /// @param user Dirección del usuario que retiró
    /// @param token Dirección del token retirado (address(0) para ETH, dirección del contrato para USDC)
    /// @param amount Cantidad retirada en unidades del token original (wei para ETH, unidades USDC para USDC)
    event WithdrawalPerformed(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /// @notice Se emite cuando el owner actualiza la dirección del oráculo
    /// @param addr Nueva dirección del oráculo de Chainlink
    /// @param time Timestamp del bloque cuando se realizó el cambio
    event FeedSet(address indexed addr, uint256 time);

    /*//////////////////////////////////////////////////////////////
                                ERRORES
    //////////////////////////////////////////////////////////////*/

    /// @notice Se lanza cuando el monto de una operación es cero
    /// @dev Se usa tanto para depósitos como retiros
    error InvalidAmount();
    
    /// @notice Se lanza cuando una transacción excede el límite permitido
    /// @param requested Monto solicitado en USD con 6 decimales
    /// @param limit Límite máximo permitido en USD con 6 decimales
    error ExceedsPerTxLimit(uint256 requested, uint256 limit);
    
    /// @notice Se lanza cuando el usuario no tiene suficiente saldo
    /// @param balance Saldo actual del usuario en USD con 6 decimales
    /// @param requested Monto solicitado en USD con 6 decimales
    error InsufficientBalance(uint256 balance, uint256 requested);
    
    /// @notice Se lanza cuando falla una transferencia de ETH
    /// @param reason Datos devueltos por la llamada fallida
    error TransactionFailed(bytes reason);
    
    /// @notice Se lanza cuando se detecta un intento de ataque de reentrancia
    /// @dev Ocurre cuando se intenta llamar a una función protegida mientras ya está en ejecución
    error ReentrancyAttempt();
    
    /// @notice Se lanza cuando un depósito excedería la capacidad total del banco
    /// @param requested Valor total que tendría el banco después del depósito (en USD con 6 decimales)
    /// @param available Capacidad máxima permitida del banco (en USD con 6 decimales)
    error BankCapExceeded(uint256 requested, uint256 available);
    
    /// @notice Se lanza cuando se proporciona una dirección de contrato inválida (address(0))
    /// @dev Se usa para validar direcciones de oráculos y tokens
    error InvalidContract();

    /*//////////////////////////////////////////////////////////////
                            MODIFICADORES
    //////////////////////////////////////////////////////////////*/

    /// @notice Protege contra ataques de reentrancia
    /// @dev Usa el patrón de lock optimizado con uint8 (1→2→1) en vez de bool
    /// @dev Cambiar entre valores non-zero cuesta ~5k gas vs ~20k gas al escribir desde 0
    /// @dev Ahorra aproximadamente 15,000 gas por transacción comparado con bool
    modifier reentrancyGuard() {
        if (flag == LOCKED) revert ReentrancyAttempt();
        flag = LOCKED;
        _;
        flag = UNLOCKED;
    }

    /// @notice Valida que el ETH enviado (msg.value) no sea cero
    /// @dev Solo se usa en funciones payable que reciben ETH
    modifier validAmount() {
        if (msg.value == 0) revert InvalidAmount();
        _;
    }

    /// @notice Valida que un monto específico no sea cero
    /// @param amount Monto a validar
    /// @dev Se usa para validar parámetros de funciones
    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    /// @notice Valida que un monto en USD no supere el límite por transacción
    /// @param amountInUSD Monto en USD con 6 decimales
    /// @dev Revierte con ExceedsPerTxLimit si amountInUSD > limitPerTx
    modifier withinTxLimit(uint256 amountInUSD) {
        if (amountInUSD > limitPerTx) {
            revert ExceedsPerTxLimit(amountInUSD, limitPerTx);
        }
        _;
    }

    /// @notice Valida que el usuario tenga saldo suficiente
    /// @param user Dirección del usuario a validar
    /// @param token Dirección del token (address(0) para ETH)
    /// @param requiredAmount Monto requerido en USD con 6 decimales
    /// @dev Revierte con InsufficientBalance si el saldo es insuficiente
    modifier hasSufficientBalance(address user, address token, uint256 requiredAmount) {
        uint256 userBalance = balance[user][token];
        if (requiredAmount > userBalance) {
            revert InsufficientBalance(userBalance, requiredAmount);
        }
        _;
    }

    /// @notice Valida que un depósito no exceda la capacidad máxima del banco
    /// @param depositAmountUSD Monto a depositar en USD con 6 decimales
    /// @dev Calcula el total del banco después del depósito y verifica contra bankCap
    modifier withinBankCap(uint256 depositAmountUSD) {
        uint256 _totalBankUSD = _getTotalBankValueUSD() + depositAmountUSD;
        if (_totalBankUSD > bankCap) {
            revert BankCapExceeded(_totalBankUSD, bankCap);
        }
        _;
    }

    /// @notice Valida que una dirección no sea address(0)
    /// @param addr Dirección a validar
    /// @dev Se usa para validar direcciones de contratos externos
    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidContract();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inicializa el banco con los límites y contratos externos
     * @param _limitPerTx Límite máximo por transacción en USD con 6 decimales
     * @param _bankCap Capacidad máxima total del banco en USD con 6 decimales
     * @param _oracle Dirección del Chainlink Price Feed para ETH/USD
     * @param _usdc Dirección del contrato del token USDC
     * @dev Valida que las direcciones de contratos no sean address(0)
     * @dev El owner inicial es msg.sender (quien despliega el contrato)
     * @dev Emite el evento FeedSet al configurar el oráculo inicial
     */
    constructor(
        uint256 _limitPerTx,
        uint256 _bankCap,
        address _oracle,
        address _usdc
    ) 
        Ownable(msg.sender)
        validAddress(_oracle)
        validAddress(_usdc)
    {
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
     * @notice Deposita ETH en el banco
     * @dev Aplica el patrón Checks-Effects-Interactions
     * @dev Obtiene el precio ETH/USD desde Chainlink
     * @dev Convierte el ETH a USD usando la tasa actual
     * @dev Valida que el depósito no exceda el bankCap
     * @dev Actualiza el balance del usuario en USD (6 decimales)
     * @dev Emite el evento DepositPerformed
     * @dev Requiere que msg.value > 0 (validado por el modifier validAmount)
     */
    function deposit() public payable validAmount {
        // CHECKS: Obtener precio y calcular valor en USD
        int256 _latestAnswer = _getETHPrice();
        
        uint256 _depositedInUSDC = _convertToUSD(
            msg.value,
            ETH_DECIMALS,
            uint256(_latestAnswer)
        );

        // Validar el cap del banco
        _validateBankCap(_depositedInUSDC);

        // EFFECTS: Actualizar el estado del contrato
        unchecked {
            balance[msg.sender][ETH_ADDRESS] += _depositedInUSDC;  // Segura: limitada por bankCap
        }
        totalDeposits++;  // Fuera de unchecked: puede desbordar teóricamente

        // INTERACTIONS: Emitir evento
        emit DepositPerformed(msg.sender, ETH_ADDRESS, msg.value, _depositedInUSDC);
    }

    /**
     * @notice Deposita USDC en el banco
     * @param _usdcAmount Cantidad de USDC a depositar (con 6 decimales)
     * @dev El usuario debe haber hecho approve() al contrato antes de llamar esta función
     * @dev USDC ya está en 6 decimales, por lo que no requiere conversión
     * @dev Usa transferFrom para mover los tokens desde el usuario al contrato
     * @dev Valida que el monto no sea cero mediante el modifier nonZeroAmount
     * @dev Valida que no se exceda el bankCap mediante el modifier withinBankCap
     * @dev Emite el evento DepositPerformed
     */
    function depositUSDC(uint256 _usdcAmount) 
        external 
        nonZeroAmount(_usdcAmount)
        withinBankCap(_usdcAmount)
    {
        // EFFECTS
        unchecked {
            balance[msg.sender][address(USDC)] += _usdcAmount;  // Segura: limitada por bankCap
        }
        totalDeposits++;  // Fuera de unchecked: puede desbordar teóricamente

        // INTERACTIONS
        USDC.transferFrom(msg.sender, address(this), _usdcAmount);

        emit DepositPerformed(msg.sender, address(USDC), _usdcAmount, _usdcAmount);
    }

    /**
     * @notice Recibe ETH cuando se envía directamente al contrato sin datos
     * @dev Redirige automáticamente al depósito mediante deposit()
     * @dev Se activa cuando alguien hace una transferencia simple de ETH al contrato
     */
    receive() external payable {
        deposit();
    }

    /**
     * @notice Se ejecuta cuando se llama una función inexistente con ETH
     * @dev Redirige automáticamente al depósito mediante deposit()
     * @dev Se activa cuando alguien llama al contrato con datos incorrectos pero envía ETH
     */
    fallback() external payable {
        deposit();
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES DE RETIRO
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retira ETH del banco
     * @param amount Cantidad de ETH a retirar en wei
     * @return data Datos devueltos por la llamada de transferencia
     * @dev Protegido contra reentrancia mediante el modifier reentrancyGuard
     * @dev Obtiene el precio ETH/USD actual desde Chainlink
     * @dev Convierte el ETH solicitado a USD para validar límites
     * @dev Valida que el monto no sea cero mediante nonZeroAmount
     * @dev Valida que no supere el límite por transacción
     * @dev Valida que el usuario tenga saldo suficiente
     * @dev Actualiza el balance ANTES de enviar ETH (anti-reentrancy)
     * @dev Usa call{value} para enviar ETH (más seguro que transfer)
     * @dev Emite el evento WithdrawalPerformed
     */
    function withdraw(uint256 amount)
        external
        reentrancyGuard
        nonZeroAmount(amount)
        returns (bytes memory data)
    {
        // CHECKS: Obtener precio y calcular valor en USD
        int256 _latestAnswer = _getETHPrice();
        uint256 _withdrawInUSDC = _convertToUSD(
            amount,
            ETH_DECIMALS,
            uint256(_latestAnswer)
        );

        // Validar límite por transacción
        _validateTxLimit(_withdrawInUSDC);

        // Validar saldo suficiente
        _validateSufficientBalance(msg.sender, ETH_ADDRESS, _withdrawInUSDC);

        // EFFECTS: Actualizar el estado ANTES de enviar ETH
        unchecked {
            balance[msg.sender][ETH_ADDRESS] -= _withdrawInUSDC;  // Segura: validada por hasSufficientBalance
        }
        totalWithdrawals++;  // Fuera de unchecked: puede desbordar teóricamente

        // INTERACTIONS: Enviar ETH al usuario
        data = _transferEth(msg.sender, amount);

        emit WithdrawalPerformed(msg.sender, ETH_ADDRESS, amount);
        return data;
    }

    /**
     * @notice Retira USDC del banco
     * @param amount Cantidad de USDC a retirar (con 6 decimales)
     * @dev Protegido contra reentrancia mediante el modifier reentrancyGuard
     * @dev Valida que el monto no sea cero mediante nonZeroAmount
     * @dev Valida que no supere el límite por transacción mediante withinTxLimit
     * @dev Valida que el usuario tenga saldo suficiente mediante hasSufficientBalance
     * @dev USDC ya está en 6 decimales, por lo que no requiere conversión
     * @dev Actualiza el balance ANTES de transferir tokens (anti-reentrancy)
     * @dev Usa transfer del ERC20 para enviar los tokens
     * @dev Emite el evento WithdrawalPerformed
     */
    function withdrawUSDC(uint256 amount) 
        external 
        reentrancyGuard
        nonZeroAmount(amount)
        withinTxLimit(amount)
        hasSufficientBalance(msg.sender, address(USDC), amount)
    {
        // EFFECTS: Actualizar el estado ANTES de transferir tokens
        unchecked {
            balance[msg.sender][address(USDC)] -= amount;  // Segura: validada por hasSufficientBalance
        }
        totalWithdrawals++;  // Fuera de unchecked: puede desbordar teóricamente

        // INTERACTIONS: Transferir USDC al usuario
        USDC.transfer(msg.sender, amount);

        emit WithdrawalPerformed(msg.sender, address(USDC), amount);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES PRIVADAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Envía ETH a una dirección usando low-level call
     * @param to Dirección que recibirá el ETH
     * @param amount Cantidad de ETH a enviar en wei
     * @return Datos devueltos por la llamada
     * @dev Usa call{value} en lugar de transfer para mayor compatibilidad
     * @dev transfer y send están limitados a 2300 gas, lo cual puede causar problemas
     * @dev call es más flexible y seguro cuando se combina con reentrancyGuard
     * @dev Revierte con TransactionFailed si la transferencia falla
     */
    function _transferEth(address to, uint256 amount)
        private
        returns (bytes memory)
    {
        (bool success, bytes memory data) = to.call{value: amount}("");
        if (!success) revert TransactionFailed(data);
        return data;
    }

    /**
     * @notice Obtiene el precio actual de ETH en USD desde el oráculo de Chainlink
     * @return _latestAnswer Precio de ETH en USD con 8 decimales
     * @dev Llama a latestRoundData() del Chainlink Price Feed
     * @dev Solo retorna el precio (answer), ignora los demás datos
     * @dev El precio siempre tiene 8 decimales según el estándar de Chainlink
     * @dev Ejemplo: 4117.88 USD = 411788000000 (4117.88 * 10^8)
     */
    function _getETHPrice() private view returns(int256 _latestAnswer) {
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
     * @notice Convierte cualquier monto de token a su valor equivalente en USD
     * @param _amount Monto original en unidades del token
     * @param _decimals Cantidad de decimales que tiene el token
     * @param _priceUSD Precio del token en USD con 8 decimales (de Chainlink)
     * @return _valueUSD Valor equivalente en USD con 6 decimales
     * @dev Fórmula: (monto * precio) / 10^(decimales_token + 8 - 6)
     * @dev El resultado siempre tiene 6 decimales para coincidir con USDC
     * @dev Ejemplo con 1 ETH (10^18 wei) a $4000:
     *      - numerator = 10^18 * (4000 * 10^8) = 10^18 * 4 * 10^11
     *      - denominator = 10^(18 + 8 - 6) = 10^20
     *      - resultado = (10^18 * 4 * 10^11) / 10^20 = 4000 * 10^6 = 4000 USDC
     */
    function _convertToUSD(
        uint256 _amount,
        uint8 _decimals,
        uint256 _priceUSD
    ) private pure returns (uint256 _valueUSD) {
        uint256 numerator = _amount * _priceUSD;
        uint256 denominator = 10 ** (_decimals + ORACLE_DECIMALS - TARGET_DECIMALS);
        
        return numerator / denominator;
    }

    /**
     * @notice Calcula el valor total que tiene el banco en USD
     * @return _totalUSD Valor total del banco en USD con 6 decimales
     * @dev Suma el valor de todo el ETH del contrato más todo el USDC
     * @dev Obtiene el precio actual de ETH para calcular su valor en USD
     * @dev El USDC ya está en 6 decimales, por lo que se suma directamente
     * @dev Se usa para validar que los depósitos no excedan el bankCap
     */
    function _getTotalBankValueUSD() private view returns (uint256 _totalUSD) {
        // Obtener precio actual de ETH
        int256 _latestAnswer = _getETHPrice();
        
        // Calcular valor de todo el ETH del contrato
        uint256 totalETH = address(this).balance;
        uint256 ethValueUSD = _convertToUSD(
            totalETH,
            ETH_DECIMALS,
            uint256(_latestAnswer)
        );

        // Obtener todo el USDC del contrato
        uint256 totalUSDC = USDC.balanceOf(address(this));

        // Sumar ambos valores
        _totalUSD = ethValueUSD + totalUSDC;
    }

    /**
     * @notice Valida que un depósito no exceda la capacidad máxima del banco
     * @param depositAmountUSD Monto a depositar en USD con 6 decimales
     * @dev Calcula el total del banco después del depósito
     * @dev Revierte con BankCapExceeded si se supera el límite
     */
    function _validateBankCap(uint256 depositAmountUSD) private view {
        uint256 _totalBankUSD = _getTotalBankValueUSD() + depositAmountUSD;
        if (_totalBankUSD > bankCap) {
            revert BankCapExceeded(_totalBankUSD, bankCap);
        }
    }

    /**
     * @notice Valida que un retiro no exceda el límite por transacción
     * @param amountInUSD Monto en USD con 6 decimales
     * @dev Revierte con ExceedsPerTxLimit si se supera el límite
     */
    function _validateTxLimit(uint256 amountInUSD) private view {
        if (amountInUSD > limitPerTx) {
            revert ExceedsPerTxLimit(amountInUSD, limitPerTx);
        }
    }

    /**
     * @notice Valida que el usuario tenga saldo suficiente
     * @param user Dirección del usuario a validar
     * @param token Dirección del token (address(0) para ETH)
     * @param requiredAmount Monto requerido en USD con 6 decimales
     * @dev Revierte con InsufficientBalance si el saldo es insuficiente
     */
    function _validateSufficientBalance(
        address user,
        address token,
        uint256 requiredAmount
    ) private view {
        uint256 userBalance = balance[user][token];
        if (requiredAmount > userBalance) {
            revert InsufficientBalance(userBalance, requiredAmount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    FUNCIONES DE CONSULTA (VIEW)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Obtiene el balance total de ETH que posee el contrato
     * @return Balance de ETH en wei
     * @dev Retorna address(this).balance que es el ETH nativo del contrato
     */
    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Obtiene el balance de un usuario para un token específico
     * @param account Dirección del usuario a consultar
     * @param token Dirección del token a consultar (address(0) para ETH)
     * @return Balance del usuario en USD con 6 decimales
     * @dev Los balances están almacenados en USD, no en unidades del token original
     */
    function balanceOf(address account, address token) external view returns (uint256) {
        return balance[account][token];
    }

    /**
     * @notice Obtiene el balance total de un usuario sumando ETH y USDC
     * @param account Dirección del usuario a consultar
     * @return Balance total del usuario en USD con 6 decimales
     * @dev Suma directamente los balances de ETH y USDC del usuario
     * @dev Ambos están en USD con 6 decimales, por lo que se pueden sumar directamente
     */
    function totalBalance(address account) external view returns (uint256) {
        return balance[account][ETH_ADDRESS] + balance[account][address(USDC)];
    }

    /**
     * @notice Obtiene el valor total que tiene el banco en USD
     * @return Valor total del banco en USD con 6 decimales
     * @dev Llama a la función privada _getTotalBankValueUSD()
     * @dev Incluye tanto ETH como USDC convertidos a USD
     */
    function totalBankValueUSD() external view returns (uint256) {
        return _getTotalBankValueUSD();
    }

    /*//////////////////////////////////////////////////////////////
                    FUNCIONES DE ADMINISTRACIÓN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Actualiza la dirección del oráculo de Chainlink
     * @param _feed Nueva dirección del Chainlink Price Feed
     * @dev Solo puede ser llamada por el owner del contrato
     * @dev Valida que la dirección no sea address(0) mediante validAddress
     * @dev Emite el evento FeedSet con la nueva dirección y timestamp
     * @dev Útil si el oráculo de Chainlink cambia o se detecta un problema
     */
    function setFeeds(address _feed) 
        external 
        onlyOwner 
        validAddress(_feed)
    {
        dataFeed = AggregatorV3Interface(_feed);
        emit FeedSet(_feed, block.timestamp);
    }
}