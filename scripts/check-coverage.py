"""Fail the server gate if business-domain coverage falls below its threshold."""
import json
from pathlib import Path

thresholds = {
    'login.go': 90, 'operations.go': 95, 'status.go': 95,
    'logging.go': 90, 'runtime.go': 95, 'types.go': 100,
}
counts = {name: [0, 0] for name in thresholds}
all_statements = [0, 0]
for line in Path('dist/tests/go.cover').read_text().splitlines()[1:]:
    location, statements, visits = line.split()
    name = location.split(':')[0].rsplit('/', 1)[-1]
    total = int(statements)
    covered = total if int(visits) > 0 else 0
    all_statements[0] += covered
    all_statements[1] += total
    if name in counts:
        counts[name][0] += covered
        counts[name][1] += total
summary = {}
failed = []
for name, (covered, total) in counts.items():
    percentage = 100 * covered / total if total else 0
    summary[name] = {'covered': covered, 'statements': total,
                     'percent': round(percentage, 2), 'minimum': thresholds[name]}
    print(f'{name}: {covered}/{total} statements ({percentage:.1f}%), minimum {thresholds[name]}%')
    if percentage < thresholds[name]:
        failed.append(name)
summary['allGo'] = {'covered': all_statements[0], 'statements': all_statements[1],
                    'percent': round(100 * all_statements[0] / all_statements[1], 2)}
Path('dist/tests/coverage-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
if failed:
    raise SystemExit('Coverage below threshold: ' + ', '.join(failed))
