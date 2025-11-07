# 🏦 KipuBankV2

## 📄 Descripción del contrato

KipuBankV2 es una versión mejorada del contrato original KipuBank, desarrollada en Solidity 0.8.30, que amplía la funcionalidad básica de depósito y retiro de Ether, incorporando soporte para tokens ERC20 (por ejemplo, Circle/USDC) y la posibilidad de consultar equivalencias en dólares (USD) mediante un oráculo.

---

## 🚀 Mejoras de alto nivel

KipuBankV2 evoluciona la primera versión mediante los siguientes cambios:

### 🔹 Soporte para tokens ERC20
Además del manejo de Ether, ahora permite depositar y retirar tokens compatibles con ERC20, como USDC.

👉 Esto extiende el uso del contrato a escenarios más realistas del ecosistema DeFi.

### 🔹 Integración con oráculo de precios
Incorpora un mock de oráculo (Oracle.sol) que devuelve el valor de 1 ETH en USD, posibilitando:
- Consultar la equivalencia de los fondos de cada usuario en dólares.
- Mostrar balances convertidos según el precio de referencia.

### 🔹 Modularidad y escalabilidad
El contrato está diseñado para interactuar con componentes externos:
- Un contrato ERC20 (Circle.sol).
- Un oráculo (Oracle.sol).

Esta estructura modular facilita futuras extensiones, como aceptar múltiples tokens o consultar precios dinámicos.

### 🔹 Refactorización y eficiencia
Se reorganizó la lógica interna para:
- Evitar duplicación de código.
- Aplicar el patrón checks → effects → interactions.
- Usar errores personalizados para ahorro de gas.
- Mantener el reentrancy guard en funciones críticas.

---

## 💰 Funcionalidades principales

### ➕ Depositar ETH o Tokens

```solidity
function deposit() public payable
function depositUSDC(uint256 _usdcAmount) external
```

- `deposit()` permite depositar Ether directamente al contrato.
- `depositUSDC()` permite enviar tokens ERC20 (como USDC).
- Ambas funciones registran el depósito en el balance del usuario y emiten su respectivo evento.
- En el caso del token, el usuario debe haber aprobado previamente la transferencia (`approve`).

### ➖ Retirar ETH o Tokens

```solidity
function withdraw(uint256 amount) external reentrancyGuard
function withdrawUSDC(uint256 amount) external reentrancyGuard
```

- Permiten retirar fondos desde la bóveda personal del usuario.
- Verifican que el monto solicitado no supere su saldo ni el límite por transacción (`limitPerTx`).
- Ejecutan transferencias seguras hacia el usuario y emiten el evento correspondiente.

### 💵 Consultar balances y conversión a USD

```solidity
function balanceOf(address account, address token) external view returns (uint256)
function totalBalance(address account) external view returns (uint256)
function totalBankValueUSD() external view returns (uint256)
```

- `balanceOf()` devuelve el saldo del usuario en un token específico (ETH o USDC) en USD.
- `totalBalance()` suma el saldo total del usuario (ETH + USDC).
- `totalBankValueUSD()` calcula el valor total del banco mediante el oráculo.

### 📊 Información general del contrato

```solidity
function contractBalance() external view returns (uint256)
uint256 public totalDeposits
uint256 public totalWithdrawals
```

- Consultas globales sobre el estado del banco y sus operaciones.

---

## ⚙️ Instrucciones de despliegue e interacción

### 🧩 En Remix IDE

1. **Abrí Remix** y cargá los archivos:
   - `KipuBankV2.sol`
   - `Circle.sol`
   - `Oracle.sol`

2. **Compilá todos** con versión `0.8.30`.

3. **En la pestaña Deploy & Run Transactions:**
   - Primero desplegá `Oracle.sol`.
   - Luego desplegá `Circle.sol` (token ERC20 de prueba).
   - Finalmente desplegá `KipuBankV2.sol`, pasando como parámetros en el constructor:
     - `_limitPerTx`: `1000000000` (1,000 USD con 6 decimales)
     - `_bankCap`: `10000000000` (10,000 USD con 6 decimales)
     - `_oracle`: dirección del contrato Oracle
     - `_usdc`: dirección del contrato Circle

4. **Interactuá desde la interfaz de Remix:**
   - `deposit()` enviando un valor en Value (wei).
   - `depositUSDC(amount)` tras ejecutar `approve()` en el token.
   - `withdraw(amount)` o `withdrawUSDC(amount)` para retirar.
   - `totalBalance(address)` para ver el saldo total en USD.

---

### 🌐 En testnet Sepolia

1. **Configurá MetaMask** en la red Sepolia.
2. **Obtené ETH de prueba** desde un faucet (https://www.alchemy.com/faucets/ethereum-sepolia).
3. **Desplegá los contratos** en el orden indicado.
4. **Copiá las direcciones** desplegadas y usalas para interactuar entre sí.
5. **Verificá el código del contrato** en Etherscan Sepolia usando el plugin de verificación de Remix.

#### 📍 Contrato desplegado y verificado:

**KipuBankV2 en Sepolia:**
```
https://sepolia.etherscan.io/address/0x9C20C3545ffc3D2b0bb719eDF6f082f71666C52f
```

**Contratos auxiliares:**
- Oracle: `0x4A274D47De0c221415D37a0aA56c09be5947384d`
- Circle (USDC): `0x7c9579d4e117f0d4A21CF43a5ABf7dB7A8AD7194`

---

## 🎯 Decisiones de diseño y trade-offs

### 1️⃣ **Uso de address(0) para representar ETH**

**Decisión:** En lugar de crear una estructura separada para ETH vs tokens, usamos `address(0)` como identificador de ETH en el mapping de balances.

**Trade-off:**
- ✅ **Ventaja:** Simplifica la lógica del contrato y reduce duplicación de código.
- ⚠️ **Desventaja:** Puede ser menos intuitivo para desarrolladores que no conozcan este patrón.

---

### 2️⃣ **Conversión a 6 decimales (formato USDC)**

**Decisión:** Todos los balances internos se almacenan en USD con 6 decimales, independientemente del token original.

**Trade-off:**
- ✅ **Ventaja:** Unifica la contabilidad y simplifica comparaciones entre ETH (18 decimales) y USDC (6 decimales).
- ⚠️ **Desventaja:** Puede haber pequeñas pérdidas de precisión al convertir desde ETH. Se mitiga usando `unchecked` solo donde es seguro.

---

### 3️⃣ **Oracle mock en lugar de Chainlink real**

**Decisión:** Se implementó un mock de oráculo (Oracle.sol) que devuelve un precio fijo de ETH/USD.

**Trade-off:**
- ✅ **Ventaja:** Facilita las pruebas en testnet sin depender de subscripciones de Chainlink.
- ⚠️ **Desventaja:** En producción se debería usar un oráculo real (Chainlink Price Feed) para precios actualizados. El contrato ya está preparado para esto mediante `setFeeds()`.

---

### 4️⃣ **Límites por transacción en USD**

**Decisión:** Los límites (`limitPerTx` y `bankCap`) se definen en USD (6 decimales), no en unidades del token.

**Trade-off:**
- ✅ **Ventaja:** Permite aplicar límites consistentes sin importar si se deposita ETH o USDC.
- ⚠️ **Desventaja:** Requiere consultas al oráculo en cada operación, aumentando el costo de gas ligeramente.

---

### 5️⃣ **Reentrancy guard solo en retiros**

**Decisión:** El modificador `reentrancyGuard` se aplica únicamente en funciones de retiro (`withdraw` y `withdrawUSDC`).

**Trade-off:**
- ✅ **Ventaja:** Ahorra gas en depósitos, que no son vulnerables a reentrancia.
- ✅ **Justificación:** Los depósitos siguen el patrón checks-effects-interactions, por lo que no necesitan protección adicional.

---

### 6️⃣ **Función `receive()` y `fallback()` llaman a `deposit()`**

**Decisión:** Cualquier ETH enviado directamente al contrato (sin llamar a una función) se trata como un depósito.

**Trade-off:**
- ✅ **Ventaja:** Mejora la UX permitiendo depósitos simples tipo "enviar ETH".
- ⚠️ **Desventaja:** Si alguien envía ETH por error, se registra como depósito (aunque puede retirarlo después).

---

### 7️⃣ **Errores personalizados vs require con strings**

**Decisión:** Se usaron custom errors (`error InvalidAmount()`) en lugar de `require` con mensajes de texto.

**Trade-off:**
- ✅ **Ventaja:** Ahorro significativo de gas (los strings son costosos).
- ✅ **Ventaja:** Más eficiente y moderno (patrón recomendado desde Solidity 0.8.4).
- ⚠️ **Desventaja:** Requiere herramientas actualizadas para decodificar los errores (Etherscan y Remix lo soportan).

---

## 🌐 Área personal — versión tokenizada

*Más que aprender a depositar tokens, terminé "minteando" mi salud mental…*

Como no encontré testnets activas para NFT, decidí conservarla en mi propia colección 😅

<p align="center">
  <img src="https://i.ibb.co/xK3CvDXB/rivotril-imagen.jpg" alt="Imagen de Rivotril" width="250"/>
</p>

**Token ID:** #0001  
**Name:** Rivotril a morir  
**Network:** KipuVerse (local testnet)

**Metadata:**
```json
{
  "description": "Tokenized proof of survival from TP3 stress",
  "attributes": [
    { "trait_type": "Coffee Cups", "value": "∞" },
    { "trait_type": "Error Count", "value": "too many" },
    { "trait_type": "Sanity Left", "value": "0.3%" }
  ]
}
```

```
// return 01010111 01001000 01001001 01010100 01000101 00100000 01000110 01001100 01000001 01000111
```

---





**Desarrollado con ☕ y mucho debugging para el TP3 de Blockchain.**
