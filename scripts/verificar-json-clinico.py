"""Compare clinical rows before/after migration without printing clinical content."""
import hashlib
import json
import sys
from collections import Counter
from decimal import Decimal
from pathlib import Path

dictionary = json.loads((Path(__file__).resolve().parents[1] / "src/main/resources/clinical-json-dictionary.json").read_text())
keys = dictionary["keys"]
inverse = {value: key for key, value in keys.items()}

def legacy(value, field=""):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            target = inverse.get(key, key)
            if target in result:
                raise AssertionError("Alias clínico duplicado")
            result[target] = legacy(item, target)
        return result
    if isinstance(value, list):
        return [legacy(item, field) for item in value]
    if isinstance(value, str):
        options = dictionary["values"].get(field, {})
        return {translated: key for key, translated in options.items()}.get(value, value)
    return value

def load(path):
    return {(row["tipo"], row["id"]): row["fila"] for row in json.loads(Path(path).read_text(), parse_float=Decimal)}

before, after = map(load, sys.argv[1:3])
assert before.keys() <= after.keys(), "Faltan registros históricos"
counts = Counter()
for identity, original in before.items():
    current = after[identity]
    column = "esquema" if identity[0] == "plantilla" else "datos"
    assert {k: v for k, v in original.items() if k != column} == {k: v for k, v in current.items() if k != column}, "Cambió identidad/version/autor/fecha"
    assert legacy(original[column]) == legacy(current[column]), "Cambió contenido clínico"
    counts[identity[0]] += 1
digest = hashlib.sha256(json.dumps({str(key): legacy(row) for key, row in sorted(before.items())}, sort_keys=True, ensure_ascii=False, default=str).encode()).hexdigest()
print(json.dumps({"status": "PASS", "preserved": dict(counts), "logical_sha256": digest}, ensure_ascii=False))
