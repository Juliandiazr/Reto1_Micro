# Diagramas — Reto Unidad 1 "Ruleta de Precisión"

Diagramas del proyecto en formato Mermaid (GitHub los muestra directamente). La explicación completa está en el [README](../README.md).

## Diagrama de bloques del hardware

```mermaid
flowchart LR
    subgraph MCU["STM32F407VET6"]
        RCC["RCC<br/>AHB1ENR.GPIOEEN"]
        PE7_14["GPIOE PE7–PE14<br/>Salidas push-pull"]
        PE3["GPIOE PE3<br/>Entrada pull-down"]
        ST["SysTick<br/>1 ms, polling COUNTFLAG"]
    end
    RCC -.reloj.-> PE7_14
    RCC -.reloj.-> PE3
    PE7_14 -->|"8 ánodos (columnas 1–8)"| LEDS["Fila 5 de la matriz 1088AS<br/>8 LEDs"]
    LEDS -->|"cátodo común (pin 1)"| R["Resistencia limitadora"]
    R --> GND["GND"]
    VCC["3.3 V"] --> BTN["Pulsador N.O. K1"]
    BTN --> PE3
```

## Diagrama de flujo del software

```mermaid
flowchart TD
    A([Reset / _start]) --> B["Habilitar reloj GPIOE<br/>RCC_AHB1ENR |= 1 << 4"]
    B --> C["PE7–PE14 como salida<br/>MODER: BIC 0x3FFFC000, ORR 0x15554000"]
    C --> D["PE3 entrada con pull-down<br/>MODER: BIC 0xC0 · PUPDR: ORR 0x80"]
    D --> E["Apagar_Columnas<br/>ODR: BIC 0x7F80"]
    E --> F["SysTick_Init<br/>RVR = 15999, CVR = 0, CSR = 0x05"]
    F --> G["reiniciar_secuencia<br/>Encender las 8 columnas 1 s y apagar"]
    G --> H["i = 0"]
    H --> I["Apagar_Columnas<br/>Encender LED col_bits i"]
    I --> J["Delay_ms_Poll_K1 (500 ms)"]

    J --> K{"¿PE3 = 1?"}
    K -- No --> L{"¿COUNTFLAG = 1?"}
    L -- No --> K
    L -- Sí --> M["ms = ms − 1"]
    M --> N{"¿ms = 0?"}
    N -- No --> K
    N -- Sí --> O["Sin pulsación: i = i + 1"]
    O --> P{"¿i = 8?"}
    P -- Sí --> H
    P -- No --> I

    K -- Sí --> Q["Leer_K1_Debounced<br/>Esperar 25 ms y releer PE3"]
    Q --> R{"¿Sigue en 1?"}
    R -- "No (rebote)" --> K
    R -- Sí --> S{"¿i = TARGET_INDEX (3)?"}

    S -- Sí --> T["ACIERTO<br/>Apagar todo<br/>Parpadear PE10 3 veces (150/150 ms)"]
    S -- No --> U["FALLO<br/>LED actual congelado 2 s<br/>Apagar_Columnas"]
    T --> V["Esperar_Liberacion_K1<br/>hasta PE3 = 0"]
    U --> V
    V --> G
```
