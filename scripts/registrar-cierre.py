#!/usr/bin/env python3
"""C-02: convertir una ejecución Maven real en el registro A.6, sin propiedades sensibles de JUnit."""
import argparse
import csv
from datetime import datetime
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
FRONT = ROOT.parent / "salud-u"
DOCUMENTO = ROOT.parents[1] / "MSD-Documento proyecto de grado Ver.1.10 u.docx"

CASOS = {
    "PV-7.1": ["NotificacionIntegrationTest#asignacionCreaUnSoloAvisoInclusoConReintentosConcurrentesYRespetaRls", "NotificacionIntegrationTest#cancelacionYAusenciaGeneranAvisosSinFiltrarMotivosYLaLlegadaNoDuplica", "NotificacionIntegrationTest#falloPosteriorAlInsertDeCitaRevierteAvisoCitaSolicitudYCupo"],
    "PV-7.2": ["RecordatorioCitaIntegrationTest#tomorrowUsesBoliviaMidnightAndAHalfOpenRangeRegardlessOfSessionTimezone", "RecordatorioCitaIntegrationTest#preferencesDefaultToEnabledAndReinforcedOptOutDoesNotDisableOrdinaryReminders", "RecordatorioCitaIntegrationTest#concurrentWorkersDoNotCreateDuplicates", "RecordatorioCitaIntegrationTest#batchFailureRollsBackAllRemindersAndTheNextAttemptCanRecover"],
    "PV-7.3": ["ObservacionJornadaIntegrationTest#closingADayCountsEachDoctorAndSpecialtyWithItsPeriodAndIsIdempotent", "EstimacionAgendaIntegrationTest#recomputeStoresVersionedEstimatesInSpanishFromObservationsAndInitialValues"],
    "PV-7.4": ["SugerenciasAgendaIntegrationTest#pv74LowAttendanceSuggestsOverbookingOnTheLatestSlotAndRegeneratesIdempotently"],
    "PV-7.5": ["DecisionSugerenciaIntegrationTest#pa21UndecidedSuggestionsExpireAndCanNoLongerBeDecided"],
    "PV-7.6": ["ReprogramacionBloqueoIntegrationTest#pv76BlockingADayWithThreeAppointmentsReschedulesEachOneAndThenBlocks"],
    "PA-20": ["NotificationApiIntegrationTest#ownListAndForeignReadAreIsolatedEvenForAdministrationAndWithoutIdentityFilters", "NotificationApiIntegrationTest#reprogrammingReusesItsReadNoticeAndMakesItUnreadAndNewestAgain", "NotificacionIntegrationTest#reprogramacionesSinCambiarEstadoActualizanElMismoAvisoYReabrenSuLectura", "NotificacionIntegrationTest#cancelacionYAusenciaGeneranAvisosSinFiltrarMotivosYLaLlegadaNoDuplica"],
    "PA-21": ["DecisionSugerenciaIntegrationTest#pa21UndecidedSuggestionsExpireAndCanNoLongerBeDecided", "DecisionSugerenciaIntegrationTest#rejectionsAndReviewOnlySuggestionsLeaveTheAgendaUntouched"],
    "PA-22": ["DecisionSugerenciaIntegrationTest#pa22AcceptingTheOverbookingRaisesTheLatestSlotOnceAndFreezesTheDay", "DecisionSugerenciaIntegrationTest#aModifiedOverbookingIsValidatedAgainstTheLimitTheDayAndItsCurrentCapacity"],
    "PA-23": ["ObservacionJornadaIntegrationTest#theCloseOnlyDependsOnAgendaAndCalendarColumnsAndNeverMentionsClinicalTables", "EstimacionAgendaIntegrationTest#estimationFunctionsOnlyReadAgendaAndCalendarTables", "SugerenciasAgendaIntegrationTest#generatorInputsOnlyReadAgendaCalendarAndEstimates"],
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ejecutar(args, cwd=ROOT, entrada=None):
    return subprocess.check_output(args, cwd=cwd, input=entrada, text=True, stderr=subprocess.STDOUT).strip()


def escribir(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def huella(base, carpetas):
    archivos = []
    for carpeta in carpetas:
        ruta = base / carpeta
        archivos.extend(p for p in ruta.rglob("*") if p.is_file()) if ruta.is_dir() else archivos.append(ruta)
    resumen = [{"ruta": str(p.relative_to(base)), "sha256": sha(p)} for p in sorted(set(archivos)) if p.exists()]
    digest = hashlib.sha256(json.dumps(resumen, sort_keys=True).encode()).hexdigest()
    return {"sha256": digest, "archivos": resumen}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directorio", type=Path, required=True)
    parser.add_argument("--log", type=Path, help="Consumir log de mvn verify recién ejecutado; sin esta opción ejecuta Maven")
    args = parser.parse_args()
    dest = args.directorio.resolve()
    dest.mkdir(parents=True, exist_ok=True)
    log = dest / "maven.log"
    if args.log:
        if args.log.resolve() != log:
            shutil.copyfile(args.log, log)
    else:
        with log.open("w") as out:
            subprocess.run(["mvn", "-B", "-ntp", "verify"], cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, check=True)
    if "BUILD SUCCESS" not in log.read_text():
        raise SystemExit("La ejecución no terminó satisfactoriamente; no se registra como aprobada.")

    casos = []
    for path in sorted((ROOT / "target/surefire-reports").glob("TEST-*.xml")):
        if abs(path.stat().st_mtime - log.stat().st_mtime) > 900:
            raise SystemExit(f"Informe fuera de la ventana de ejecución: {path.name}")
        for case in ET.parse(path).getroot().iter("testcase"):
            estado = "APROBADA"
            for tag in ("failure", "error", "skipped"):
                if case.find(tag) is not None:
                    estado = {"failure": "FALLIDA", "error": "ERROR", "skipped": "OMITIDA"}[tag]
            casos.append({"id": case.get("classname", "").rsplit(".", 1)[-1] + "#" + case.get("name", ""), "resultado": estado, "segundos": float(case.get("time", "0"))})
    if not casos or any(c["resultado"] != "APROBADA" for c in casos):
        raise SystemExit("Hay pruebas omitidas, fallidas o informes vacíos; revisar antes de cerrar.")
    totales = re.findall(r"Tests run: (\d+), Failures: (\d+), Errors: (\d+), Skipped: (\d+)", log.read_text())
    if not totales or tuple(map(int, totales[-1])) != (len(casos), 0, 0, 0):
        raise SystemExit("El total del log no coincide con los informes JUnit; no mezclar corridas parciales.")
    tests = {c["id"]: c for c in casos}
    escribir(dest / "pruebas.json", {"total": len(casos), "fallos": 0, "errores": 0, "omitidas": 0, "casos": casos})

    consulta = """SELECT json_build_object('postgres',version(),'flyway',(SELECT version FROM salud_u.flyway_schema_history WHERE success AND type='SQL' ORDER BY installed_rank DESC LIMIT 1),'cupos_para_solicitud',pg_get_functiondef('salud_u.cupos_para_solicitud(uuid)'::regprocedure))::text;"""
    db = json.loads(ejecutar(["docker", "compose", "exec", "-T", "postgres", "sh", "-c", 'psql -X -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'], entrada=consulta))
    (dest / "pa23-cupos-para-solicitud.sql").write_text(db.pop("cupos_para_solicitud") + "\n")
    auditoria = {"pruebas_nucleo": CASOS["PA-23"], "lectura_derivacion_en_o05": bool(re.search(r"\bFROM\s+salud_u\.derivacion\b", (dest / "pa23-cupos-para-solicitud.sql").read_text(), re.I)), "observacion": "El núcleo de cierre/estimación/generación solo usa agenda/calendario. O-05 consulta derivacion (especialidad, prioridad, estado y paciente); no contenido clínico. PA-23 exige ninguna tabla clínica: discrepancia pendiente de resolución, no se aprueba de forma global."}
    escribir(dest / "pa23-auditoria.json", auditoria)
    version = {"fecha": datetime.now(ZoneInfo("America/La_Paz")).isoformat(timespec="seconds"), "documento": {"nombre": DOCUMENTO.name, "sha256": sha(DOCUMENTO)}, "backend": huella(ROOT, ["src/main", "src/test", "pom.xml"]), "frontend": huella(FRONT, ["src", "next.config.ts", "package.json", "pnpm-lock.yaml"]), "git_frontend": {"rama": ejecutar(["git", "branch", "--show-current"], FRONT), "head": ejecutar(["git", "rev-parse", "HEAD"], FRONT), "cambios_sin_commit": bool(ejecutar(["git", "status", "--porcelain"], FRONT))}, "entorno": {"os": platform.platform(), "cpu": platform.machine(), "procesadores": __import__("os").cpu_count(), "memoria_kib": int(re.search(r"MemTotal:\s+(\d+)", Path('/proc/meminfo').read_text()).group(1)), "java": ejecutar(["java", "-version"]).splitlines()[0], "maven": ejecutar(["mvn", "--version"]).splitlines()[0], "node": ejecutar(["node", "--version"]), "docker": ejecutar(["docker", "--version"]), "next": json.loads((FRONT / "node_modules/next/package.json").read_text())["version"], **db}}
    escribir(dest / "version-entorno.json", version)
    etiqueta = f"local-V{db['flyway']}-{version['backend']['sha256'][:12]}-FE-{version['frontend']['sha256'][:12]}"
    entorno = "Local; PostgreSQL 17/Testcontainers; Spring real/MockMvc; datos sintéticos; programador inactivo en suite"
    rows = []
    for codigo, requeridos in CASOS.items():
        missing = set(requeridos) - tests.keys()
        if missing:
            raise SystemExit(f"Falta evidencia para {codigo}: {missing}")
        resultado = "APROBADA"
        alcance = "Escenario documental ejecutado con fixtures sintéticas."
        if codigo in ("PV-7.2", "PA-20"):
            resultado = "APROBADA_ALCANCE_BANDEJA"
            alcance = "SMTP original NO APLICA por decisión vigente. PV-7.2 adaptada: recordatorio de mañana/reintento atómico sin duplicados; PA-20: eventos en bandeja y aislamiento propio. No se certifica correo."
        if codigo == "PA-23" and auditoria["lectura_derivacion_en_o05"]:
            resultado = "OBSERVADA"
            alcance = auditoria["observacion"]
        evidencia = {"id": codigo, "resultado": resultado, "alcance": alcance, "casos": [tests[x] for x in requeridos]}
        escribir(dest / (codigo + ".json"), evidencia)
        rows.append([codigo, version["fecha"], etiqueta, entorno, resultado, codigo + ".json; pruebas.json; version-entorno.json"])
    with (dest / "registro-a6.csv").open("w", newline="") as out:
        writer = csv.writer(out)
        writer.writerow(["ID de prueba", "Fecha", "Versión", "Entorno", "Resultado", "Evidencia"])
        writer.writerows(rows)
    texto = "# Registro A.6 — C-02\n\nDatos sintéticos; responsable de ejecución: agente de desarrollo. Fuente vigente: " + DOCUMENTO.name + ".\n\n"
    texto += "| ID de prueba | Fecha | Versión | Entorno | Resultado | Evidencia |\n|---|---|---|---|---|---|\n"
    for row in rows:
        row[-1] = f"[{row[0]}]({row[0]}.json), [pruebas](pruebas.json), [versión](version-entorno.json)"
        texto += "| " + " | ".join(row) + " |\n"
    texto += "\nPV-7.2 y PA-20 se adaptan al alcance autorizado sin SMTP. El ensayo original de correo queda NO APLICA; no se presenta como ejecutado. PV-7.5 corresponde a vencimiento, no a cupos sugeridos (O-05). PA-23 queda OBSERVADA por la consulta de derivacion en O-05, pese al núcleo aprobado. Detalles en cada JSON y pa23-auditoria.json.\n"
    (dest / "registro-a6.md").write_text(texto)
    print(f"Registrados {len(rows)} criterios con {len(casos)} pruebas ejecutadas: {etiqueta}")


if __name__ == "__main__":
    main()
