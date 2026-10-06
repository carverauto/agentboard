"""Shared context through the real CLI/API and TLS PostgreSQL, never mocks."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import urllib.request
import urllib.error

base = os.environ['AGENTBOARD_URL']
env = {k:v for k,v in os.environ.items() if not k.startswith(('DATABASE_', 'PG'))}
env.update(AGENT_ID='alpha', AGENTBOARD_MODEL='model-a', AGENTBOARD_HARNESS='codex')
def ab(*args, actor='alpha', code=0):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=dict(env,AGENT_ID=actor), capture_output=True, text=True, timeout=15)
    assert result.returncode == code, (args,result.returncode,result.stdout,result.stderr)
    return json.loads(result.stderr if code else result.stdout)
def sql(s):return subprocess.check_output([os.environ['FIXTURE_PSQL'],'-At','-v','ON_ERROR_STOP=1','-c',s],text=True).strip()
def post(data, actor='alpha'):
    r=urllib.request.Request(base+'/api/v1/context',data=json.dumps(data).encode(),headers={'Content-Type':'application/json','X-Agentboard-Agent':actor,'X-Agentboard-Model':'model-a','X-Agentboard-Harness':'codex'})
    try:
        with urllib.request.urlopen(r,timeout=15) as response:return response.status,json.load(response)
    except urllib.error.HTTPError as response:return response.code,json.load(response)

assert sql("SELECT rolsuper FROM pg_roles WHERE rolname=current_user")=='f'
ab('agent','register','--name','Alpha')
ab('agent','register','--name','Beta',actor='beta')
ab('task','create','--id','tls-work','--title','Investigate TLS')
repo='carverauto/agentboard'
args=('context','publish','--key','tls-failure','--repo',repo,'--kind','FAIL','--summary','TLS certificate failed with unknown authority','--task','tls-work','--evidence','https://github.com/carverauto/agentboard/pull/10')
with concurrent.futures.ThreadPoolExecutor(4) as pool: results=list(pool.map(lambda _:ab(*args),range(4)))
assert len({r['entry']['id'] for r in results}) == 1 and sum(not r['idempotent'] for r in results)==1, results
first=results[0]['entry'];assert first['source_agent_id']=='alpha' and first['model']=='model-a' and first['harness']=='codex' and 'detail' not in first
ab('context','publish','--key','tls-failure','--repo',repo,'--summary','Changed content',code=4)
assert sql("SELECT count(*) FROM context_entries WHERE entry_key='tls-failure'")=='1'
malicious='<script>window.contextExecuted=true</script> & café'
file=Path(os.environ['TEST_TMPDIR'])/'context-detail.txt';file.write_text(malicious)
fixed=ab('context','publish','--key','tls-fixed','--repo',repo,'--kind','FACT','--summary','TLS certificate','--detail-file',str(file),'--link',f"contradicts:{first['id']}")['entry']
show=ab('context','show',str(fixed['id']));assert show['entry']['detail']==malicious and show['links']==[{'entry_id':fixed['id'],'target_id':first['id'],'relation':'contradicts'}]
ab('context','publish','--key','unrelated','--repo','other/repo','--summary','TLS certificate')
ab('context','publish','--key','dashboard','--repo',repo,'--summary','Dashboard layout')
search=ab('context','search','TLS certificate','--repo',repo)
assert search['backend']=='pg_textsearch-1.5.1' and [r['id'] for r in search['entries']]==[fixed['id'],first['id']],search
assert search['entries'][0]['score']>search['entries'][1]['score']>0
assert all('detail' not in r for r in search['entries'])
assert [r['id'] for r in ab('context','search','TLS','--repo',repo,'--kind','FAIL')['entries']]==[first['id']]
for data in [dict(entry_key='oversize',repo=repo,kind='FACT',summary='é'*301),dict(entry_key='bad-link',repo=repo,kind='FAIL',summary='Retry',links=[dict(target_id=999999,relation='supports')]),dict(entry_key='bad-url',repo=repo,kind='OBSERVED',summary='URL',evidence_urls=['javascript:alert(1)'])]:
    assert post(data)[0]==422
assert sql("SELECT count(*) FROM context_entries WHERE entry_key IN ('oversize','bad-link','bad-url')")=='0'
assert post(dict(entry_key='unknown',repo=repo,kind='FACT',summary='Unknown'),actor='missing')[0]==422
assert post(dict(entry_key='foreign',repo='other/repo',kind='FACT',summary='Wrong repo',links=[dict(target_id=first['id'],relation='supports')]))[0]==422
assert sql("SELECT count(*) FROM context_entries WHERE entry_key='foreign'")=='0'
# Reads don't consume; acknowledgement is per agent and repeatable.
feed=ab('context','feed','--repo',repo,'--limit','1');assert feed['entries'][0]['id']==first['id'] and feed['more']
assert ab('context','feed','--repo',repo,'--limit','1')==feed
for _ in range(2):assert ab('context','ack',str(first['id']))['acknowledged']==first['id']
assert first['id'] not in [r['id'] for r in ab('context','feed','--repo',repo)['entries']]
assert first['id'] in [r['id'] for r in ab('context','feed','--repo',repo,actor='beta')['entries']]
# Reserve an earlier sequence ID, process later committed entries, then commit it.
late=int(sql("SELECT nextval('context_entries_id_seq')"))
new=ab('context','publish','--key','later-id','--repo',repo,'--summary','Later allocation')['entry']
for r in ab('context','feed','--repo',repo)['entries']:ab('context','ack',str(r['id']))
assert ab('context','feed','--repo',repo)['entries']==[]
sql(f"INSERT INTO context_entries(id,entry_key,repo,kind,summary,source_agent_id,model,harness,digest) VALUES({late},'late-commit','{repo}','OBSERVED','Late commit','alpha','model-a','codex',repeat('a',64))")
assert [r['id'] for r in ab('context','feed','--repo',repo)['entries']]==[late]
for table in ['context_entries','context_links','context_receipts']:
    p=subprocess.run([os.environ['FIXTURE_PSQL'],'-v','ON_ERROR_STOP=1','-c',f'DELETE FROM {table}'],capture_output=True,text=True)
    assert p.returncode!=0 and 'append-only' in p.stderr
print('Context CLI/API publication, concurrent retries, correction links, BM25, limits, rollback and late-commit delivery passed')

# The real connected dashboard escapes untrusted details and preserves links.
from liveview_client import LiveView, contains
view=LiveView(base, '/context/'+str(fixed['id']))
assert contains(view.initial,'&lt;script&gt;window.contextExecuted=true&lt;/script&gt;')
assert not contains(view.initial, '<script>window.contextExecuted=true</script>')
assert contains(view.initial,'contradicts') and contains(view.initial,'TLS certificate')
view.close()
# Independent UI pagination boundary: seed invented older history, then browse.
sql("INSERT INTO context_entries(entry_key,repo,kind,summary,source_agent_id,model,harness,digest) SELECT 'page-'||n, 'carverauto/agentboard','OBSERVED','History finding '||n,'alpha','model-a','codex',repeat('b',64) FROM generate_series(1,51) n")
view=LiveView(base,'/context?repo=carverauto%2Fagentboard')
assert contains(view.initial,'History finding 51') and contains(view.initial,'Older findings')
def texts(value):
    if isinstance(value,str):yield value
    elif isinstance(value,list):
        for child in value:yield from texts(child)
    elif isinstance(value,dict):
        for child in value.values():yield from texts(child)
assert 'History finding 1' not in set(texts(view.initial))
from html import unescape
import re
links=[unescape(path) for text in texts(view.initial) for path in re.findall(r'/context\?[^"\s<>]+',text) if 'cursor=' in path]
assert len(links)==1,links
older_path=links[0]
view.close()
view=LiveView(base,older_path)
assert 'History finding 1' in set(texts(view.initial))
assert 'History finding 51' not in set(texts(view.initial))
view.close()
view=LiveView(base,'/context?repo=carverauto%2Fagentboard&q=TLS+certificate')
assert contains(view.initial,'pg_textsearch-1.5.1') and contains(view.initial,'TLS certificate')
assert not contains(view.initial,'History finding')
view.close()
result=subprocess.run([os.environ['AB_BINARY'],'context','ack',str(fixed['id'])],env=env,capture_output=True,text=True,timeout=15)
assert result.returncode==0 and 'acknowledged' in result.stdout and str(fixed['id']) in result.stdout
print('Connected context dashboard escaping, relationship display, browsing, ranked search and readable acknowledgement passed')
