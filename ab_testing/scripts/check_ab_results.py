"""Check and display A/B test results with formatted output.

Usage:
    python check_ab_results.py                    # reads /fixFirstAgent/ab-test-id
    python check_ab_results.py config-ab-test-id  # reads /fixFirstAgent/config-ab-test-id
"""
import json
import subprocess
import os
import sys


def run_cmd(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, shell=True, encoding='utf-8')
    if r.returncode != 0:
        print(f'ERROR: {r.stderr}', file=sys.stderr)
        sys.exit(1)
    return r.stdout.strip()


REGION = run_cmd('aws configure get region') or 'us-east-1'
APP_NAME = os.environ.get('APP_NAME', 'fixFirstAgent')
PARAM_NAME = sys.argv[1] if len(sys.argv) > 1 else 'ab-test-id'

AB_TEST_ID = run_cmd(
    f'aws ssm get-parameter --name /{APP_NAME}/{PARAM_NAME} --query Parameter.Value --output text --region {REGION}'
)
print(f'A/B Test ID: {AB_TEST_ID}')

result = json.loads(run_cmd(
    f'aws bedrock-agentcore get-ab-test --ab-test-id {AB_TEST_ID} --region {REGION} --output json'
))
print(f'Status: {result["status"]}')
print(f'Execution: {result["executionStatus"]}')

results = result.get('results')
if not results:
    print('\nNo results yet.')
    print('Results appear after sessions complete (~15 min after session timeout).')
    print('Re-run this check later.')
    sys.exit(0)

print(f'\nAnalysis timestamp: {results.get("analysisTimestamp")}')
print('=' * 60)

for metric in results['evaluatorMetrics']:
    evaluator = metric.get('evaluatorArn', 'Unknown').split('/')[-1]
    control = metric['controlStats']
    print(f'\nEvaluator: {evaluator}')
    print(f'  Control (C):   mean={control["mean"]:.3f}, samples={control["sampleSize"]}')
    for v in metric['variantResults']:
        sig = 'YES' if v['isSignificant'] else 'no'
        print(f'  Treatment (T1): mean={v["mean"]:.3f}, samples={v["sampleSize"]}')
        print(f'    Change: {v.get("percentChange", 0):.1f}%')
        print(f'    p-value: {v.get("pValue", "N/A")}')
        print(f'    Significant: {sig}')
        if v.get('confidenceInterval'):
            ci = v['confidenceInterval']
            print(f'    95% CI: [{ci["lower"]:.3f}, {ci["upper"]:.3f}]')

print('\n' + '=' * 60)

all_sig = all(
    v['isSignificant']
    for m in results['evaluatorMetrics']
    for v in m['variantResults']
)
if all_sig:
    winner_change = results['evaluatorMetrics'][0]['variantResults'][0].get('percentChange', 0)
    if winner_change > 0:
        print('RECOMMENDATION: Treatment (T1) is significantly better. Consider deploying it.')
    else:
        print('RECOMMENDATION: Control (C) is significantly better. Keep the current agent.')
else:
    print('RECOMMENDATION: Not yet significant. Continue collecting samples or increase traffic.')
