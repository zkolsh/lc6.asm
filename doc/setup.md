# Instalación de `rtm32.asm`.

En esta guía se detalla el proceso de instalación y uso básico del assembler `rtm32.asm` para la máquina RTM32.

El assembler se provee como un archivo estáticamente linkeado, por lo que no requiere instalar dependencias adicionales.

Se proveen ejecutables para las siguientes plataformas:

- `aarch64-linux-musl`
- `aarch64-macos`
- `x86_64-linux-musl`
- `x86_64-macos`
- `x86_64-windows-gnu`

Únicamente debes descargar el ejecutable que corresponda a tu plataforma.  Si no sabés cuál elegir y estás en Linux, usá `x86_64-linux-musl-rtm32.asm`.

Una vez descargado, quitá la plataforma del nombre del archivo, renombrándolo a `rtm32.asm`.  De ser necesario, darle además permisos de ejecución.

```
$ mv x86_64-linux-musl-rtm32.asm rtm32.asm
$ chmod +x rtm32.asm
```

Con esto, ya podés usar el assembler.  Podés verificarlo con el siguiente comando:

```
$ ./rtm32.asm --version
./rtm32.asm version 1.2.1
```

## Recomendado:  Instalarlo en `PATH`.

Para no tener que escribir `./rtm32.asm` o `~/Descargas/rtm32.asm`, se recomienda colocar al assembler en una carpeta que esté en tu `PATH` de usuario.  No es estrictamente necesario pero se recomienda realizar este proceso.

Esto aplica para todas las plataformas soportadas.  Sin embargo, qué carpetas forman parte del PATH y cómo modificarlo depende de tu sistema operativo, distribución y configuración.  Es imposible detallarlo en solo este documento

Podés consultar las carpetas actualmente incluidas en tu PATH con:

```
$ echo $PATH
```

Dónde instalar el ejecutable y cómo modificar el PATH queda a tu criterio o al de quien administre el sistema.

Se describen a continuación algunas rutas donde se puede colocar el archivo.  Ojo que si alguna de estas carpetas *no* existe o *no* está en `PATH`, mover el archivo ahí no va a hacer nada!

### Instalarlo para un solo usuario (ideal)

* `~/.local/bin` en sistemas Unix.
* `%LOCALAPPDATA%\Programs` en Windows.

### Instalarlo para todos los usuarios (aceptable, requiere privilegios de administrador)

* `/usr/local/bin` en sistemas Unix

### Instalarlo en una ruta del sistema

**No se recomienda** hacer esto, pero de ser muy complejo modificar tu `PATH`, estas "van a funcionar":

* `/usr/bin` en sistemas Unix.
* `%WINDIR%\System32` en Windows.

---

Para verificar que sea accesible globalmente, ahora deberías poder correr:

```
$ rtm32.asm --version
rtm32.asm version 1.2.1
```

# Uso de `rtm32.asm`

Habiendo instalado el assembler, ya es posible generar programas.  Para correr el assembler, se le debe indicar por la línea de comandos un archivo de entrada y un archivo de salida.  Esto se hace de la siguiente manera:
```
$ rtm32.asm mi_programa_en_assembly.rtm -o mi_archivo_ejecutable.bin
```

Esto leerá el archivo de texto `mi_programa_en_assembly.rtm` y generará el ejecutable `mi_archivo_ejecutable.bin`:  Podrás correr esto con el emulador de RTM32.  Para que un archivo sea ejecutable, además de ser sintácticamente válido se deben poder resolver todos los símbolos.  Es decir, si escribiste `j tag1234`, entonces en algún otro lugar debe estar definida la etiqueta `tag1234`.

Alternativamente, se puede generar un *archivo de objeto*.  Esto se hace agregando la flag `-c` a la invocación:

```
$ rtm32.asm -c mi_archivo_en_assembly.rtm -o mi_objeto.o
```

`mi_objeto.o` **no** es un ejecutable, sino que es más parecido a una librería.  Las etiquetas definidas en `mi_archivo_en_assembly.rtm` se podrán usar en cualquier archivo que luego esté linkeado con este.  Por ejemplo, si `mi_programa_en_assembly` quiere usar estas etiquetas, lo linkeamos de la siguiente manera:
```

$ rtm32.asm -c mi_archivo_en_assembly.rtm -o mi_objeto.o
$ rtm32.asm mi_programa_en_assembly.rtm -o mi_archivo_ejecutable.bin -l:mi_objeto.o
```

La flag `-l:<archivo>` se puede usar cualquier cantidad de veces e indica que se debe linkear con este objeto adicional.

## Programa de ejemplo:  Hola mundo

Se comparte aquí un programa comentado que imprime "Hola, mundo!" por la consola del emulador.  Vamos a usarlo de ejemplo para ver cómo usar los programas generados por `rtm32.asm` con el emulador RTM32.

```
.section ".data"
	mensaje: .asciiz "Hola, mundo!"

.section ".text"
	// Elegimos un valor para inicializar el stack
	addi $sp, $zero, 0xFFC

	// Para llamar a `imprimir_asciiz` debemos cargar en $a0 un puntero
	// al mensaje.  Un puntero es de 32 bits, por lo cual es imposible hacerlo
	// con tan solo una instrucción.

	// Hay dos formas de cargar un puntero.  La primera es usar las relocaciones
	// .lo16 y .hi16 para cargarlo en dos pasos.  La segunda es bakear el puntero
	// en el segmento de datos con `mensaje_ptr: .ptr mensaje` y cargar el puntero
	// directamente con `lw $rt, mensaje_ptr($zero)`.

	// Usamos la primer forma:
	orh $a0, $zero, .hi16 mensaje
	ori $a0, $a0,   .lo16 mensaje

	jal imprimir_asciiz

	// Debemos detener la ejecución del programa aquí.  De otro modo, el
	// emulador volverá a avanzar hacia imprimir_asciiz.  No tenemos una
	// instrucción HALT, pero si estamos corriendo la máquina con el debugger,
	// podemos obtener el mismo ejemplo con una excepción:
	trap 1
	// ^ Esta excepción no está definida, por lo cual el debugger detendrá la
	//   ejecución por nosotros con "Core Exception 6."

// Hagamos una función "imprimir_asciiz"
// Tomará en $a0 un puntero a la string que quiere imprimir
imprimir_asciiz:
	// Los registros $sX son callee-saved.  Es decir, si los usamos dentro
	// de esta función, debemos restaurarlos a su valor original antes de
	// salir.  Esto se suele hacer empujándolos y quitándolos del stack.
	addi $sp, $sp, -12
	sw $s0, 0($sp)		// guarda puntero al próximo caracter
	sw $s1, 4($sp)		// guarda el caracter actual
	sw $s2, 8($sp)		// guarda la dirección de la consola
	// No hace falta empujar $ra porque no llamamos a ninguna derivada de JAL

	// Al principio no leímos ningún caracter.  Establecemos $s0 al principio
	// de la string, es decir, en $a0
	addi $s0, $a0, 0

	// Truco para guardar la dirección de la consola en una instrucción:
	addi $s2, $zero, -0x100

	// Procesamos los caracteres uno por uno
imprimir_asciiz.bucle:
	lbu $s1, 0($s0)

	// Una string .asciiz termina cuando lleguemos a un byte cuyo valor es 0
	beq $s1, $zero, imprimir_asciiz.salir

	// Si llegamos acá, $s1 != 0, lo imprimimos:
	sb $s1, 0($s2)

	// Avanzamos el puntero, y la próxima vuelta procesamos el siguiente caracter:
	addi $s0, $s0, 1
	j imprimir_asciiz.bucle

imprimir_asciiz.salir:
	// Imprimamos tambien un salto de línea.  Nosotros estamos acostumbrados a
	// escribirlos con '\n'.  Esto se conoce como "LF."  En RTM32, sin embargo,
	// se usa "CRLF."  Es decir, debemos imprimir dos caracteres, '\r' y '\n',
	// donde '\r' mueve el cursor hacia el borde izquierdo de la consola, y '\n'
	// únicamente lo desplaza una celda hacia abajo sin restablecer la posición
	// horizontal.

	addi $s1, $zero, '\r'
	sb $s1, 0($s2)

	addi $s1, $zero, '\n'
	sb $s1, 0($s2)

	// Ahora sí, salimos de la función:
	// Empujamos varias cosas al stack, debemos restaurarlas
	lw $s0, 0($sp)
	lw $s1, 4($sp)
	lw $s2, 8($sp)
	addi $sp, $sp, 12

	// Ahora si, salimos de la función
	jr $ra, 0
```

Lo guardamos en el archivo `hola_mundo.rtm`.  Ensamblamos:

```
$ rtm32.asm hola_mundo.rtm -o hola_mundo.bin
```

Asumiendo que `rtm32 -d telnet` ya está corriendo, nos conectamos por telnet y cargamos el programa:

```
$ telnet -4 localhost 4444
Trying 127.0.0.1...
Connected to localhost.
Escape character is '^]'.
RTM32-0.1.1
RTM32> load hola_mundo.bin
Successfully burst loaded 116 aligned bytes into base address 0x00000000
```

Podemos probar correrlo.  Como se indicó en los comentarios del código, el programa tiene una forma "sucia" de terminar su ejecución, por lo cual deberíamos esperar ver el error "Core Exception 6"

```
RTM32> c
Continuing execution...

[Execution Fault: Core Exception 6 thrown at PC 0x00000014]
Core execution stopped. Current PC: 0x00000014
RTM32> r
=== General Purpose Registers ===
R[ 0]: 0x00000000   R[ 1]: 0x00000010   R[ 2]: 0x00000000   R[ 3]: 0x00000000
R[ 4]: 0x00000000   R[ 5]: 0x00000000   R[ 6]: 0x00000000   R[ 7]: 0x00000000
R[ 8]: 0x00000064   R[ 9]: 0x00000000   R[10]: 0x00000000   R[11]: 0x00000000
R[12]: 0x00000000   R[13]: 0x00000000   R[14]: 0x00000000   R[15]: 0x00000000
R[16]: 0x00000000   R[17]: 0x00000000   R[18]: 0x00000000   R[19]: 0x00000000
R[20]: 0x00000000   R[21]: 0x00000000   R[22]: 0x00000000   R[23]: 0x00000000
R[24]: 0x00000000   R[25]: 0x00000000   R[26]: 0x00000000   R[27]: 0x00000000
R[28]: 0x00000000   R[29]: 0x00000000   R[30]: 0x00000FFC   R[31]: 0x00000000

=== Control & Special Registers ===
PC      : 0x00000014  CAUSE   : 0x00000006  EPC     : 0x00000000
BADVADR : 0x00000000  VBR     : 0x00000002

Execution State:
Mode: KERNEL | Flags: [-ZC--]

Last Memory Operation:
Address: 0x00000010 | Size: 0x00000004 | Type: FETCH
```

Y efectivamente, si revisamos la consola de picocom, vemos la frase:  `Hola, mundo!`
