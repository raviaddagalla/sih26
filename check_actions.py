import json, urllib.request
data=json.loads(urllib.request.urlopen('https://api.github.com/repos/raviaddagalla/sih26/actions/runs').read())
for r in data['workflow_runs'][:3]:
    print(f"{r['id']}: {r['head_commit']['message'].splitlines()[0]} - {r['status']} - {r['conclusion']}")
