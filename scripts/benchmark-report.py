#!/usr/bin/env python3
"""Summarize fixture metrics only; never substitute these for live Mac/model measurements."""
import json, math, statistics, sys
from collections import defaultdict
samples=defaultdict(list);size=None;checks=[]
for name in sys.argv[1:]:
    for line in open(name):
        try: row=json.loads(line)
        except json.JSONDecodeError: continue
        if 'request_size_comparison' in row: size=row['request_size_comparison']
        elif 'metrics' in row: samples[row['scenario']].append(row['metrics'])
        elif 'passed' in row: checks.append(row)
result={'environment':'Linux fixture; mocked models/native dispatch/Chrome API transport; real Chromium DOM', 'scenarios':{},'browser_checks':checks}
for scenario,rows in samples.items():
    timers={}
    for key in ['command_to_first_action_ms','task_completion_ms']:
        values=sorted(r['timings'][key] for r in rows if key in r['timings'])
        if values:
            timers[key]={'median':round(statistics.median(values),3)}
            if len(values)>=20: timers[key]['p95']=round(values[math.ceil(.95*len(values))-1],3)
    result['scenarios'][scenario]={'runs':len(rows),'verified':sum(bool(r['success']) for r in rows),'timings':timers,
        'jev_requests':sorted(set(r['counts'].get('jev_requests',0) for r in rows)),
        'screenshots_sent':sorted(set(r['counts'].get('screenshots_sent',0) for r in rows))}
if size: result['synthetic_request_size']=size
print(json.dumps(result,indent=2))
