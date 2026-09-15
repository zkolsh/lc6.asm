# Assembly de `rtm32.asm`.

Assembly es una familia de lenguajes de programación de bajo nivel, donde la mayoría de líneas de código corresponden uno a uno contra las instrucciones de máquina que se van a ejectuar.  Aquí se detallan las especificaciones de la sintaxis aceptada por el assembler `rtm32.asm` para el procesador STX4.

Conceptualmente, `rtm32.asm` funciona realizando un gran pattern matching sobre las *sentencias* un archivo de texto entero, codificando cada una como código de RTM32.  Las sentencias tienen un formato predefinido dependiendo de su operación.  En general cada línea corresponde a una sentencia distinta.  De ser necesario, se pueden ingresar dos sentencias en la misma línea insertando un punto y coma (`;`) entre ellas, y se puede separar una sentencia en múltiples líneas estableciendo un `\` al final.

Las sentencias se clasifican en dos grandes grupos:  Directivas, e instrucciones.

Adicionalmente, se soporta un conjunto de herramientas de preprocesador, detalladas más adelante, aunque vale remarcar que estos *no son* sentencias, sino que herramientas para armarlas.

## Tipos de palabras.

`rtm32.asm` no opera caracter por caracter, sino que las agrupa en "*tokens*" de distinto tipo.  Las instrucciones y directivas como una secuencia de tokens.  Se reconocen los siguientes tipos de tokens:

* Los siguientes caracteres sueltos, cada uno siendo su propio tipo:  `.`, `,`, `;`, `(`, `)`, `$`, `-`, `+`, `~`.
* Un *número*, que se puede escribir de cuatro formas:
    - Directamente en base 10, como `1206`.
    - En base 2, como `0b10010110110`.
    - En base 8, como `0o2266`.
    - En base 16, como `0x4B6` o `0x4b6`.
* Un *identificador* es una secuencia de caracteres.  El primero de estos caracteres está entre `a` y `z` o `A` y `Z`.  Cada uno de los demás caracteres está entre `a`--`z`, `A`--`Z`, `0`--`9`, o es un `.`, `_`, o `'`.
* Un *caracter* se escribe entre comillas simples (`'`) y se puede escapar.  Representan siempre un byte.
* Una *string* es una secuencia de caracteres.  En lugar de encerrar cada caracter entre `'`s, únicamente se encierra a la string entera entre `"`s.  Cero o más caracteres dentro de la string pueden estar escapados, detallado más adelante.
* Un *byte* puede ser un caracter o un número literal entre 0 y 255.
* Un *registro* se escribe con un `$` seguido de su número, o, su nombre.  Por ejemplo `$0` y `$zero` representan el mismo registro, y lo mismo con `$1` y `$ra`.
* Un *registro especial* se escribe con un `$` seguido de su número, o, su nombre.  Por ejemplo `$0` y `$psw` representan el mismo registro especial.
* Una *etiqueta* es un identificador seguido de un `:`.  Se usa para ponerle un nombre a una sentencia y poder referirse a ella en otro lugar.
* Un *inmediato* puede ser un número, un byte, o un puntero a una etiqueta con un desplazamiento.
	- Según dónde se solicite el inmediato, puede tomar un tamaño distinto (`ELIMM`, `VLIMM`, `LLIMM`, `LIMM`, ...)
* Hay dos formas de escribir *comentarios*:  Los comentarios de línea comienzan con `//` y terminan en el primer salto de línea que encuentren (no inclusive,) y los bloques de comentario comienzan en un `/*` y continuan hasta encontrar su terminador, `*/`.

Los registros generales y los registros especiales utilizan la misma sintaxis.  Cuando un número o nombre puede corresponder a ambos, el tipo de registro esperado depende de la instrucción que está siendo analizada.

Se reserva el nombre de la etiqueta "`heap_base`."  No se puede declarar una etiqueta con ese nombre pero si se puede utilizar.  Su valor está alineado a 4 bytes y apunta al final de las secciones de código y datos.  Es decir, al comienzo del *heap*.

"*Escapar*" un caracter significa reemplazarlo por otro byte que no se puede fácilmente escribir en el teclado, o que generaría un error léxico al insertarlo.  Un escape arranca con el caracter `\`, y se reconocen los siguientes escapes:

* `\0` inserta el byte `0x00` (NUL).
* `\n` inserta el byte `0x0A` (LF).
* `\r` inserta el byte `0x0D` (CR).
* `\t` inserta el byte `0x09` (Tab).
* `\'` inserta el byte `0x27` (').
* `\"` inserta el byte `0x22` (").
* `\xXY` requiere de dos caracteres adicionales, e insertará el byte literal `0xXY`.

## Directivas.

Las **directivas** se utilizan para escribir datos literales, o cambiar el estado del assembler.  Cada directiva válida comienza con un `.` seguida por un identificador.

Entre el nombre, entre cada uno de los términos, al principio, o al final de cada directiva puede haber espacio horizontal (espacios o tabulaciones.)  De necesitarse espacio vertical (un salto de línea) se debe finalizar la línea con `\`.

Se reconocen las siguientes directivas.  Referirse al apartado anterior para conocer cada tipo de palabra:

* `.section <identificador | string>` toma el nombre de una sección y le indica al assembler que a partir de ahora escriba los datos ahí.  No se codifica en el programa.
    - Por ejemplo, podés escribir `.section ".text"` para comenzar a escribir tu código.
    - De mismo modo, podés escribir `.section ".data"` para comenzar a escribir datos de lectura y escritura.
* `.asciiz <string...>` codifica una string como una secuencia de bytes, terminada por un byte NUL (`0x00`.)  Se codifica alineado a 1 byte.
	- `.asciiz "HOLA"` se codifica como `48 4f 4c 41 00`.
* `.nascii <string...>` codifica una string como una palabra representando su longitud seguida por una secuencia de bytes representando sus datos.  Se codifica alineado a 4 bytes.
	- `.nascii "HOLA"` se codifica como `00 00 00 04 48 4f 4c 41`.
* `.byte <bytes...>` inserta una secuencia de bytes literales.  Se codifica alineado a 1 byte.
	- `.byte 1 2 'A' 3` se codifica como `01 02 48 03`.
* `.short <números...>` inserta una secuencia de números de 16 bits literales, rellenados con ceros de ser necesario.  Se codifica alineado a 2 bytes.
* `.word <números...>` inserta una secuencia de números de 32 bits literales, rellenados con ceros de ser necesario.  Se codifica alineado a 4 bytes.
	- `.word 1 2 3` se codifica como `00 00 00 01 00 00 00 02 00 00 00 03`.
	- `.word 1 'A' 3` no es sintaxis válida.
* `.pad <números...>[(<alineación>)]` recibe una secuencia de números, computa la suma, y luego inserta esa misma cantidad de ceros.  Pegado al último número puede ir otro valor encerrado en paréntesis, indicando que el cursor final debe estar alineado a un múltiplo de esa cantidad de bytes.  En este caso, rellena con más ceros hasta llegar al próximo múltiplo.  De no escribir un valor para la alineación se toma `1` como valor implícito.
	- `.pad 10` inserta 10 ceros en esta sección.
	- `.pad 1 2 3` inserta 6 ceros en esta sección, porque $1 + 2 + 3 = 6$.
	- Al principio de la sección, `.pad 1 2 3(4)` termina insertando 8 ceros en lugar de 6, porque debe rellenar hasta el próximo múltiplo de 4.
	- Al principio de la sección, `.pad 2 2(4)` inserta 4 bytes, al ya estar alineado a un múltiplo de 4, no necesita agregar nada más.
	- `.pad 1 2(4) 3` no es sintaxis válida.
* `.ptr <identificador>` escribe una palabra con la dirección de memoria de la sentencia que tiene esta etiqueta.  Se codifica alineado a 4 bytes.
* `.lo16 <identificador>` escribe los 16 bits más bajos de la dirección de memoria a la sentencia que tiene esta etiqueta.  Se codifica alineado **al final** de 4 bytes
* `.hi16 <identificador>` escribe los 16 bits más altos de la dirección de memoria a la sentencia que tiene esta etiqueta.  Se codifica alineado **al final** de 4 bytes
    - Esta codificación extraña permite escribir instrucciones como `orh $a0, $a0, .hi16 msg` y `ori $a0, $a0, .lo16 msg`, que de otro modo no serían posibles.

## Instrucciones.

Todas las **instrucciones** son de la forma `<nombre> <argumentos...>` y la aridad de cada instrucción está entre 0 y 4.  Los argumentos se separan con comas.  En particular, los formatos de sintaxis **son distintos** a la especificación de operandos en el manual de RTM32.  El funcionamiento de cada instrucción es idéntico al que se describe en el manual, porque el assembler jamás puede modificarlo.

La mayor diferencia sintáctica es que todas las instrucciones tienen su registro de destino como *primer agumento*, mientras que en el manual y la codificación suele ser el último.

Entre el nombre, entre cada uno de los argumentos, al principio, o al final de cada instrucción puede haber espacio horizontal (espacios o tabulaciones.)  De necesitarse espacio vertical (un salto de línea) se debe finalizar la línea con `\`.

Todo campo `imm` representa un inmediato.  Puede ser escrito como un número en cualquier base, o como el nombre de una etiqueta.  Al escribir el nombre de una etiqueta es posible establecer un desplazamiento.  Por ejemplo, `lw $t0, arr+4($zero)` cargará la palabra 4 bytes después de `arr`.

En las siguientes tablas se describen los formatos de cada instrucción.

### Tipo R.

| Instr | Sintaxis |
| ----- | --- |
| sll   | `sll $rd, $rt, aux` |
| rlc   | `rlc $rd, $rt, aux` |
| srl   | `srl $rd, $rt, aux` |
| sra   | `sra $rd, $rt, aux` |
| sllr  | `sllr $rd, $rt, $rs` |
| rlcr  | `rlcr $rd, $rt, $rs` |
| srlr  | `srlr $rd, $rt, $rs` |
| srar  | `srar $rd, $rt, $rs` |
| and   | `and $rd, $rs, $rt` |
| or    | `or $rd, $rs, $rt` |
| nor   | `nor $rd, $rs, $rt` |
| xor   | `xor $rd, $rs, $rt` |
| add   | `add $rd, $rs, $rt` |
| sub   | `sub $rd, $rs, $rt` |
| slt   | `slt $rd, $rs, $rt` |
| sltu  | `sltu $rd, $rs, $rt` |
| lhx   | `lhx $rd, $rs, $rt` |
| lhux  | `lhux $rd, $rs, $rt` |
| lbx   | `lbx $rd, $rs, $rt` |
| lbux  | `lbux $rd, $rs, $rt` |
| lwx   | `lwx $rd, $rs, $rt` |
| swx   | `swx $rd, $rs, $rt` |
| shx   | `shx $rd, $rs, $rt` |
| sbx   | `sbx $rd, $rs, $rt` |
| mul   | `mul $rd, $rs, $rt` |
| mulh  | `mulh $rd, $rs, $rt` |
| mulhu | `mulhu $rd, $rs, $rt` |
| mulhsu    | `mulhsu $rd, $rs, $rt` |
| div   | `div $rd, $rs, $rt` |
| divu  | `divu $rd, $rs, $rt` |
| rest  | `rest $rd, $rs, $rt` |
| restu | `restu $rd, $rs, $rt` |
| cfs   | `cfs $rs, aux` |
| cts   | `cts $rs, aux` |
| trap  | `trap aux` |
| rft   | `rft` |

### Tipo I.

| Instr | Sintaxis |
| ----- | --- |
| jr    | `jr $rs, llimm` |
| jalr  | `jalr $rs, llimm` |
| jalrx | `jalrx $rs, $lrX, llimm` |
| addi  | `addi $rt, $rs, simm` |
| andi  | `andi $rt, $rs, simm` |
| lci   | `lci $rt, $rs, simm` |
| ani   | `ani $rt, $rs, simm` |
| anh   | `anh $rt, $rs, simm` |
| ori   | `ori $rt, $rs, simm` |
| orh   | `orh $rt, $rs, simm` |
| xori  | `xori $rt, $rs, simm` |
| xorh  | `xorh $rt, $rs, simm` |
| lw    | `lw $rt, imm($rs)` |
| sw    | `sw $rt, imm($rs)` |
| sh    | `sh $rt, imm($rs)` |
| sb    | `sb $rt, imm($rs)` |
| lh    | `lh $rt, imm($rs)` |
| lhu   | `lhu $rt, imm($rs)` |
| lb    | `lb $rt, imm($rs)` |
| lbu   | `lbu $rt, imm($rs)` |
| beq   | `beq $rt, $rs, imm` |
| bne   | `bne $rt, $rs, imm` |
| blt   | `blt $rt, $rs, imm` |
| bge   | `bge $rt, $rs, imm` |
| bltu  | `bltu $rt, $rs, imm` |
| bgeu  | `bgeu $rt, $rs, imm` |
| slti  | `slti $rt, $rs, imm` |
| sltiu | `sltiu $rt, $rs, imm` |

### Tipo J.

| Instr | Sintaxis |
| ----- | --- |
| j     | `j elimm` |
| jal   | `jal elimm` |
| jalx  | `jalx $lrX, vlimm` |

## Preprocesador.

El *preprocesador* de `rtm32.asm` es un procesador de macros utilizado automáticamente por el ensamblador para transformar tu código fuente antes de ensamblarlo.  Se llama "preprocesador de macros" porque te permite definir *macros*, que son abreviaciones breves para construcciones más grandes.  Ninguna palabra del preprocesador es una instrucción de código, y El preprocesador de `rtm32.asm` funciona en base a directivas de preprocesador y expansiones de macros.

Todas las directivas de preprocesador comienzan con un `%`.  Se reconocen las siguientes directivas de preprocesador:
* `%filename` inserta una string conteniendo el nombre del archivo donde se encontró esta directiva.
* `%line` inserta una string conteniendo el número de línea dentro del archivo donde se encontró esta directiva.
* `%ifdef <nombre>` e `%ifndef <nombre>` deben estar finalizadas por un `%endif` cada una, y pueden contener un `%else` dentro de ellas.  Condicionalmente, dependiendo de si está definido un macro llamado `<nombre>`, dejarán el cuerpo correspondiente y eliminarán el otro.
* `%include <archivo>` copia y pega el contenido de `<archivo>` sobre esta directiva sin tokenizar.
* `%embed <archivo>` copia y pega el contenido de `<archivo>` sobre esta directiva como bytes.
* `%define <nombre> <valor>` crea un nuevo macro de aridad 0 cuyo cuerpo es `<valor>`, hasta el salto de línea (sin incluir.)
* `%macro <nombre>(<argumentos...>)` comienza a crear un nuevo macro llamado `<nombre>`.  `<argumentos...>` es una lista separada por comas de nombres de macros temporales que podrás usar como argumentos, y se puede dejar vacío para tener un macro de aridad 0.  Todo lo que escribas luego de esta línea hasta `%endmacro` (no inclusive) formará parte del cuerpo del macro.

Además, se proveen dos macros propios del assembler, que no podés redefinir:
* `@sizeOf(<data type>)` toma una directiva de datos y devuelve un número con su tamaño en bytes.
* `@alignOf(<data type>)` toma una directiva de datos y devuelve un número con su alineación en bytes.
* `@stringify(...)` toma tokens en crudo y devuelve una string que las representa.

Para consultar cómo termina el archivo únicamente tras haber ejecutado el preprocesador, ejecutá `rtm32.asm -E <entrada.rtm> <entrada preprocesada.rtm>`
