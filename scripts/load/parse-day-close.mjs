// Procesa marcadores de DayCloseJob real; un error capturado por el trabajo impide declararlo exitoso.
import assert from 'node:assert/strict';
import { readFileSync,writeFileSync } from 'node:fs';
const text=readFileSync(process.env.LOAD_CLOSE_LOG,'utf8');
const match=text.match(/^(.*?)(?:\s+)INFO.*Actualización diaria: fin; duración_ms=(\d+); errores=(\d+)/m);
assert(match,'Sin marcador de duración completo');
const started=text.includes('Actualización diaria: inicio.');assert(started,'Sin marcador de inicio');
const r={volumen:Number(process.env.LOAD_PATIENTS),timestamp_registro:match[1].trim(),duracion_ms:Number(match[2]),errores:Number(match[3]),etapas:{observacion:/Cierre de jornadas:/.test(text),estimacion:/Estimaciones de agenda recalculadas:/.test(text),vencimiento:/Sugerencias vencidas sin decisión:/.test(text),sugerencias:/Sugerencias de agenda regeneradas:/.test(text)}};
r.observaciones=Number(text.match(/Cierre de jornadas: (\d+) observaciones/)?.[1] ?? -1);
r.estimaciones=Number(text.match(/Estimaciones de agenda recalculadas: (\d+) filas/)?.[1] ?? -1);
r.sugerencias=Number(text.match(/Sugerencias de agenda regeneradas: (\d+) cambios/)?.[1] ?? -1);
r.veredicto=r.errores===0&&Object.values(r.etapas).every(Boolean)&&r.observaciones>0&&r.estimaciones>0&&r.sugerencias>0&&r.duracion_ms<60000?'CUMPLE':'NO_CUMPLE';
writeFileSync(process.env.LOAD_CLOSE_RESULT,JSON.stringify(r,null,2)+'\n');console.log(JSON.stringify(r));
