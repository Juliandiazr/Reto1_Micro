// ============================================================
// matrix_row5_scan.s
// STM32F407VET6 - Fila 5 de la matriz 1088AS: barrido de un
// LED (columna) a la vez, usando SysTick en modo POLLING.
// Juego de reaccion: el usuario presiona K1 (PE3, pull-down)
// intentando acertar cuando el LED objetivo (columna 4, PE10,
// pin fisico 10 del display) esta encendido.
// Segger Embedded Studio - Sintaxis ARM Thumb (unified syntax)
// ============================================================
//
// CABLEADO REAL CONFIRMADO:
//   - Fila 5 (pin 1 del display) esta cableada de forma FIJA:
//     pin1 -> resistencia -> GND del micro (catodo fijo comun).
//   - Las 8 columnas estan en PE7..PE14, activas en ALTO
//     (poner el pin en 1 enciende ese LED):
//       Columna 1 -> pin 13 -> PE12
//       Columna 2 -> pin 3  -> PE7
//       Columna 3 -> pin 4  -> PE8
//       Columna 4 -> pin 10 -> PE10   <-- LED OBJETIVO (indice 3)
//       Columna 5 -> pin 6  -> PE9
//       Columna 6 -> pin 11 -> PE11
//       Columna 7 -> pin 15 -> PE13
//       Columna 8 -> pin 16 -> PE14
//
//   - Pulsador K1 -> PE3, configuracion pull-down interno,
//     presionado = 1 (activo en ALTO).
//
// Como el orden fisico de columna (1..8) NO coincide con el
// orden de los bits PE7..PE14, se arma una tabla "col_bits" que
// traduce indice de columna -> numero de bit en el puerto E.
// ============================================================
    .syntax unified
    .thumb
    .cpu cortex-m4

// ---------------- Direcciones de perifericos ----------------
.equ RCC_BASE,      0x40023800
.equ RCC_AHB1ENR,   RCC_BASE + 0x30
.equ GPIOE_BASE,    0x40021000
.equ GPIOE_MODER,   GPIOE_BASE + 0x00
.equ GPIOE_PUPDR,   GPIOE_BASE + 0x0C
.equ GPIOE_IDR,     GPIOE_BASE + 0x10
.equ GPIOE_ODR,     GPIOE_BASE + 0x14

.equ SYST_CSR,      0xE000E010
.equ SYST_RVR,      0xE000E014
.equ SYST_CVR,      0xE000E018

// Valor de recarga de SysTick para ~1 ms de tick, asumiendo
// SYSCLK = 16 MHz (HSI por defecto, sin PLL). Formula:
// RVR = (SYSCLK_Hz / 1000) - 1
// Si tu SystemInit sube el reloj (p.ej. 168 MHz), cambia esto
// a 167999 para que 1 tick siga siendo 1 ms real.
.equ SYSTICK_LOAD,  15999

// ---------------- Mascaras precalculadas -----------------------
// Columnas usadas: PE7, PE8, PE9, PE10, PE11, PE12, PE13, PE14
.equ MODER_CLEAR_MASK, 0x3FFFC000   // 2 bits por pin, pines 7..14
.equ MODER_SET_MASK,   0x15554000   // 01 (salida) en cada uno de esos pines
.equ COLS_MASK,        0x7F80       // bits 7..14 -> las 8 columnas

// ---- Configuracion de K1 (PE3) ----
.equ K1_MODER_CLEAR,   0x000000C0   // limpia bits [7:6] = modo de PE3
.equ K1_PUPDR_CLEAR,   0x000000C0   // limpia bits [7:6] = pull de PE3
.equ K1_PUPDR_DOWN,    0x00000080   // 10 = pull-down en PE3
.equ K1_BIT,           3            // PE3

// ---- Indice de la columna objetivo (0..7) ----
// pin fisico 10 del display -> columna 4 -> col_bits[3] = 10 (PE10)
.equ TARGET_INDEX,     3

// ---- Tiempo de debounce / bloqueo tras deteccion (ms) ----
.equ DEBOUNCE_MS,      200

// ---- Antirrebote por software del pulsador K1 ----
// Tiempo de confirmacion: tras detectar el primer flanco alto,
// se espera este tiempo y se vuelve a leer el pin. Si sigue en
// alto, se confirma como pulsacion real; si no, fue rebote/ruido.
.equ K1_DEBOUNCE_CONFIRM_MS, 25

// ---- Tiempo de congelamiento al fallar (ms) ----
.equ FALLO_FREEZE_MS,  2000

.equ COLUMN_WINDOW_MS, 500

    .section .text
    .global _start
    .thumb_func
_start:
    // ---- 1) Habilitar reloj para GPIOE ----
    LDR   R0, =RCC_AHB1ENR
    LDR   R1, [R0]
    ORR   R1, R1, #(1 << 4)     // bit4 = GPIOEEN
    STR   R1, [R0]

    // ---- 2) Configurar PE7..PE14 como salida (las 8 columnas) ----
    LDR   R0, =GPIOE_MODER
    LDR   R1, [R0]
    LDR   R2, =MODER_CLEAR_MASK
    BIC   R1, R1, R2
    LDR   R2, =MODER_SET_MASK
    ORR   R1, R1, R2
    STR   R1, [R0]

    // ---- 2b) Configurar PE3 (K1) como entrada con pull-down ----
    LDR   R0, =GPIOE_MODER
    LDR   R1, [R0]
    LDR   R2, =K1_MODER_CLEAR
    BIC   R1, R1, R2            // 00 = entrada (ya de por si es el reset, pero se deja explicito)
    STR   R1, [R0]

    LDR   R0, =GPIOE_PUPDR
    LDR   R1, [R0]
    LDR   R2, =K1_PUPDR_CLEAR
    BIC   R1, R1, R2
    LDR   R2, =K1_PUPDR_DOWN
    ORR   R1, R1, R2
    STR   R1, [R0]

    // ---- 3) Apagar todas las columnas antes de arrancar ----
    BL    Apagar_Columnas

    // ---- 4) Configurar SysTick (modo sondeo, sin interrupcion) ----
    BL    SysTick_Init

    B     reiniciar_secuencia

    // ============================================================
    // FASE 1: encender TODA la fila 5 (las 8 columnas juntas)
    // Esta secuencia tambien se usa para reiniciar el juego tras
    // un acierto o un fallo (requisito 5).
    // ============================================================
    .thumb_func
reiniciar_secuencia:
    LDR   R0, =GPIOE_ODR
    LDR   R1, [R0]
    LDR   R2, =COLS_MASK
    ORR   R1, R1, R2
    STR   R1, [R0]

    LDR   R0, =1000             // 1000 ms = 1 s (ajustable)
    BL    Delay_ms

    BL    Apagar_Columnas

    // ============================================================
    // FASE 2: barrido + juego de reaccion con K1
    // ============================================================
barrido_loop:
    MOV   R5, #0                // indice de columna: 0..7
scan_col:
    BL    Apagar_Columnas
    LDR   R4, =col_bits
    LDRB  R0, [R4, R5]          // numero de bit real (7..14) para esta columna
    MOV   R1, #1
    LSL   R1, R1, R0            // mascara de esa columna
    LDR   R2, =GPIOE_ODR
    LDR   R3, [R2]
    ORR   R3, R3, R1            // activo en ALTO = enciende
    STR   R3, [R2]

    // ---- Ventana de esta columna: COLUMN_WINDOW_MS, sondeando K1 ----
    LDR   R0, =COLUMN_WINDOW_MS
    BL    Delay_ms_Poll_K1       // espera COLUMN_WINDOW_MS, pero si K1
                                  // se presiona durante la ventana,
                                  // retorna antes con R0 = 1

    CMP   R0, #1
    BNE   sin_pulsacion

    // ---- Se detecto pulsacion: evaluar acierto/fallo ----
    CMP   R5, #TARGET_INDEX
    BEQ   acierto
    B     fallo

sin_pulsacion:
    ADD   R5, R5, #1
    CMP   R5, #8
    BLT   scan_col
    B     barrido_loop

    // ---------------------------------------------------------
    // ACIERTO: el desplazamiento se detiene (ya no se vuelve a
    // scan_col) y SOLO el LED objetivo parpadea 3 veces como
    // confirmacion visual. Luego se reinicia la secuencia.
    // Antes de reiniciar, se espera a que el usuario SUELTE K1
    // para no arrastrar la misma pulsacion al siguiente ciclo.
    // ---------------------------------------------------------
    .thumb_func
acierto:
    BL    Apagar_Columnas        // se detiene el desplazamiento: todo apagado primero

    LDR   R4, =col_bits
    LDRB  R0, [R4, #TARGET_INDEX]  // bit real del LED objetivo (PE10 = 10)
    MOV   R7, #1
    LSL   R7, R7, R0              // R7 = mascara del LED objetivo

    MOV   R6, #3
acierto_blink:
    LDR   R0, =GPIOE_ODR
    LDR   R1, [R0]
    ORR   R1, R1, R7            // enciende SOLO el LED objetivo
    STR   R1, [R0]
    LDR   R0, =150
    BL    Delay_ms

    BL    Apagar_Columnas
    LDR   R0, =150
    BL    Delay_ms

    SUBS  R6, R6, #1
    BNE   acierto_blink

    BL    Esperar_Liberacion_K1  // no reiniciar hasta soltar el boton
    B     reiniciar_secuencia

    // ---------------------------------------------------------
    // FALLO: se congela el estado mostrando el LED erroneo
    // (la columna R5 que estaba encendida en el momento de la
    // pulsacion se deja tal cual, sin apagar) durante 2 s, y
    // luego el sistema reinicia la secuencia automaticamente.
    // Antes de reiniciar, se espera a que el usuario SUELTE K1.
    // ---------------------------------------------------------
    .thumb_func
fallo:
    // No se apaga nada: el LED erroneo de la columna R5 sigue
    // encendido tal como quedo en scan_col -> se "congela".
    LDR   R0, =FALLO_FREEZE_MS
    BL    Delay_ms

    BL    Apagar_Columnas
    BL    Esperar_Liberacion_K1  // no reiniciar hasta soltar el boton
    B     reiniciar_secuencia

    // ---------------------------------------------------------
    // SysTick_Init: ENABLE + CLKSOURCE (reloj de nucleo),
    // sin TICKINT -> se usa por sondeo (polling), no interrupcion
    // ---------------------------------------------------------
    .thumb_func
SysTick_Init:
    PUSH  {R0, R1}
    LDR   R0, =SYST_RVR
    LDR   R1, =SYSTICK_LOAD
    STR   R1, [R0]

    LDR   R0, =SYST_CVR
    MOV   R1, #0
    STR   R1, [R0]              // limpia el contador actual

    LDR   R0, =SYST_CSR
    MOV   R1, #0x05             // bit0 ENABLE, bit2 CLKSOURCE, TICKINT=0
    STR   R1, [R0]
    POP   {R0, R1}
    BX    LR

    // ---------------------------------------------------------
    // Delay_ms: espera R0 milisegundos por sondeo puro del bit
    // COUNTFLAG (bit16) de SYST_CSR. Leer SYST_CSR limpia
    // COUNTFLAG automaticamente (comportamiento del hardware).
    // ---------------------------------------------------------
    .thumb_func
Delay_ms:
    PUSH  {R1, R2, LR}
    LDR   R1, =SYST_CSR
dly_wait:
    LDR   R2, [R1]
    TST   R2, #0x00010000
    BEQ   dly_wait
    SUBS  R0, R0, #1
    BNE   dly_wait
    POP   {R1, R2, LR}
    BX    LR

    // ---------------------------------------------------------
    // Delay_ms_Poll_K1: espera R0 milisegundos (por SysTick,
    // mismo mecanismo de COUNTFLAG que Delay_ms), pero en cada
    // milisegundo revisa el estado de K1 (PE3). Si detecta un
    // primer flanco alto, llama a Leer_K1_Debounced para
    // confirmar por software que es una pulsacion real (no
    // rebote). Si se confirma, corta la espera y retorna con
    // R0 = 1. Si se agota el tiempo sin una pulsacion
    // confirmada, retorna con R0 = 0.
    //
    // Esto mantiene el requisito de no usar retardos por
    // decremento de registros tipo NOP: todos los tiempos
    // (ventana de columna, confirmacion de antirrebote) se
    // miden estrictamente por SysTick.
    // ---------------------------------------------------------
    .thumb_func
Delay_ms_Poll_K1:
    PUSH  {R1, R2, R3, LR}
    LDR   R1, =SYST_CSR
poll_wait:
    // -- Revisar K1 primero (PE3, pull-down, presionado = 1) --
    LDR   R2, =GPIOE_IDR
    LDR   R3, [R2]
    LSR   R3, R3, #K1_BIT
    AND   R3, R3, #1
    CMP   R3, #1
    BNE   poll_no_press

    // -- Primer flanco alto detectado: confirmar con antirrebote --
    PUSH  {R0}
    BL    Leer_K1_Debounced      // retorna R0 = 1 si es pulsacion real, 0 si fue rebote
    MOV   R3, R0
    POP   {R0}
    CMP   R3, #1
    BEQ   poll_hit

    // -- Fue rebote/ruido: seguir esperando el resto de la ventana --
    B     poll_wait

poll_no_press:
    // -- No esta presionado, esperar a que cumpla 1 ms --
    LDR   R2, [R1]
    TST   R2, #0x00010000
    BEQ   poll_wait
    SUBS  R0, R0, #1
    BNE   poll_wait

    // -- Se agoto el tiempo sin deteccion confirmada --
    MOV   R0, #0
    POP   {R1, R2, R3, LR}
    BX    LR

poll_hit:
    MOV   R0, #1
    POP   {R1, R2, R3, LR}
    BX    LR

    // ---------------------------------------------------------
    // Leer_K1_Debounced: antirrebote por software. Se llama justo
    // despues de ver el primer flanco alto en K1. Espera
    // K1_DEBOUNCE_CONFIRM_MS (medidos por SysTick, mismo
    // mecanismo de COUNTFLAG) y vuelve a leer el pin PE3:
    //   - Si sigue en alto -> pulsacion real confirmada, R0 = 1.
    //   - Si ya no esta en alto -> fue rebote/ruido, R0 = 0.
    // ---------------------------------------------------------
    .thumb_func
Leer_K1_Debounced:
    PUSH  {R0, R1, LR}
    LDR   R0, =K1_DEBOUNCE_CONFIRM_MS
    BL    Delay_ms               // espera fija de confirmacion, por SysTick

    LDR   R1, =GPIOE_IDR
    LDR   R1, [R1]
    LSR   R1, R1, #K1_BIT
    AND   R1, R1, #1
    CMP   R1, #1
    BEQ   debounce_confirmado

    // -- No confirmado (rebote): restaurar registros y devolver 0 --
    // OJO: el POP restaura el R0 viejo (el ms usado por Delay_ms),
    // por eso R0 se fija DESPUES del POP, nunca antes.
    POP   {R0, R1, LR}
    MOV   R0, #0
    BX    LR

debounce_confirmado:
    // -- Confirmado: restaurar registros y devolver 1 --
    POP   {R0, R1, LR}
    MOV   R0, #1
    BX    LR

    // ---------------------------------------------------------
    // Esperar_Liberacion_K1: bloquea hasta que K1 (PE3) vuelva a
    // LOW (boton soltado). Se usa despues de resolver un acierto
    // o un fallo, para evitar que la misma pulsacion que gano o
    // perdio la partida se "arrastre" y dispare una deteccion
    // fantasma apenas arranca el siguiente ciclo de barrido.
    // No usa SysTick: es un sondeo directo del pin, sin limite
    // de tiempo, ya que solo depende de que el usuario suelte
    // el pulsador.
    // ---------------------------------------------------------
    .thumb_func
Esperar_Liberacion_K1:
    PUSH  {R0, R1}
espera_liberacion_loop:
    LDR   R0, =GPIOE_IDR
    LDR   R0, [R0]
    LSR   R0, R0, #K1_BIT
    AND   R0, R0, #1
    CMP   R0, #0
    BNE   espera_liberacion_loop   // sigue presionado (1): esperar
    POP   {R0, R1}
    BX    LR

    // ---------------------------------------------------------
    // Apagar_Columnas: pone en BAJO las 8 columnas (PE7-14)
    // ---------------------------------------------------------
    .thumb_func
Apagar_Columnas:
    PUSH  {R0, R1, R2}
    LDR   R0, =GPIOE_ODR
    LDR   R1, [R0]
    LDR   R2, =COLS_MASK
    BIC   R1, R1, R2
    STR   R1, [R0]
    POP   {R0, R1, R2}
    BX    LR

    // ---------------------------------------------------------
    // Tabla de traduccion: indice de columna (0..7, columnas
    // 1 a 8) -> numero de bit real en el puerto E
    // col 1->PE12, 2->PE7, 3->PE8, 4->PE10,
    // col 5->PE9,  6->PE11, 7->PE13, 8->PE14
    // ---------------------------------------------------------
    .section .rodata
col_bits:
    .byte 12, 7, 8, 10, 9, 11, 13, 14

    .end