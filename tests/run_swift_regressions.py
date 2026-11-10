"""Generate, compile and execute every Swift rules harness; fail on any stage.
Usage: python3 tests/run_swift_regressions.py --output /tmp/boji-rules --jobs 3
These Foundation fixtures do not replace an iOS build or device acceptance.

Every failing stage prints its own log tail. The chain used to report only
"PASS"/"compile_FAIL" labels, so a red run gave no clue what went wrong and
the per-harness logs were never uploaded. See docs/KNOWN-CI-ISSUES.md.
"""
from pathlib import Path
import argparse
import concurrent.futures
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--jobs', type=int, default=3)
args = parser.parse_args()
logs = args.output.resolve()
logs.mkdir(parents=True, exist_ok=True)

TAIL_LINES = 30


def tail(output: bytes) -> str:
    lines = (output or b'').decode('utf-8', 'replace').splitlines()
    return '\n'.join(lines[-TAIL_LINES:])

def one(generator):
    name = generator.stem
    source, binary = logs / (name + '.swift'), logs / (name + '.bin')
    for stage, command in [
        ('generate', [sys.executable, '-I', str(generator), str(source)]),
        ('compile', ['xcrun', 'swiftc', '-module-cache-path', str(logs / 'module-cache'), '-o', str(binary), str(source)]),
        ('run', [str(binary)]),
    ]:
        try:
            result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
            if stage == 'generate' and not result.returncode:
                # macOS 26 的用户临时目录对 .completeFileProtection 写入返回 EPERM
                # （该选项在 iOS 上语义正确）。回归桩验证的是持久化/清理逻辑，
                # 不验证保护等级本身；生成后统一降级为普通原子写。
                text = source.read_text('utf-8')
                for form in ('[.atomic, .completeFileProtection]', '[.atomic,.completeFileProtection]'):
                    text = text.replace(form, '[.atomic]')
                source.write_text(text, 'utf-8')
            (logs / (name + '.' + stage + '.log')).write_bytes(result.stdout)
            if result.returncode:
                print('--- {} {} FAILED (exit {}) ---'.format(name, stage, result.returncode), flush=True)
                print(tail(result.stdout), flush=True)
                print('--- end of {} {} log ---'.format(name, stage), flush=True)
                return {'name': name, 'status': stage + '_FAIL', 'exit_code': result.returncode}
        except subprocess.TimeoutExpired as error:
            (logs / (name + '.' + stage + '.log')).write_bytes(error.stdout or b'')
            print('--- {} {} TIMEOUT ---'.format(name, stage), flush=True)
            print(tail(error.stdout or b''), flush=True)
            return {'name': name, 'status': stage + '_TIMEOUT', 'exit_code': None}
    return {'name': name, 'status': 'PASS', 'exit_code': 0}

results = []
with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(args.jobs, 4))) as pool:
    for result in pool.map(one, sorted((root / 'tests').glob('build_*_swift_tests.py'))):
        results.append(result)
        print(result['name'], result['status'], flush=True)
        (logs / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
passed = sum(result['status'] == 'PASS' for result in results)
print(f'{passed}/{len(results)} Swift harnesses passed', flush=True)
raise SystemExit(passed != len(results))
