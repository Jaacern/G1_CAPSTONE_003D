#!/bin/sh
# Tareas del dia, en bucle.
#
# Son las que hacen que la aplicacion se sienta viva: generar las dosis,
# marcar las vencidas, crear las alertas y calcular el semaforo. Sin
# alguien que las corra, la pantalla de medicamentos sale vacia, la
# adherencia da cero y el semaforo se queda en el ultimo dia calculado.
#
# Cada hora y no una vez al dia, porque marcar una dosis vencida a tiempo
# y avisar de una medicion fuera de rango no pueden esperar hasta manana.
# Las cinco tareas son idempotentes, asi que repetirlas no duplica nada.
#
# Es un bucle y no cron para no meter un demonio mas en la imagen: un
# contenedor que hace una sola cosa es mas facil de mirar en los logs.
INTERVALO="${MANTENIMIENTO_INTERVALO_SEG:-3600}"

echo "[mantenimiento] cada ${INTERVALO}s"
while true; do
    python -m app.maintenance diario || \
        echo "[mantenimiento] la corrida fallo, se reintenta en ${INTERVALO}s"
    sleep "$INTERVALO"
done
