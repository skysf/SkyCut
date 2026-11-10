"""One owned background MCP inspection case; fixtures and test App are prepared externally."""
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts/gui-smoke'))
from mcpclient import MCP

ROOT = Path(os.environ.get('SKYSTUDIO_SMOKE_DIR', '/private/tmp/srtflow-inspection-empty-mcp-20261104'))
WORK = ROOT / 'work'
HELPER = ROOT / 'SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp'
EVIDENCE = ROOT / ('inspection-empty-evidence-' + str(time.time_ns()))
EVIDENCE.mkdir(parents=True)
SOURCE = WORK / 'inspection-source.mp4'
assert SOURCE.is_file() and SOURCE.stat().st_size > 0, 'Prepare the canonical 8s blue+sine synthetic fixture first'
project = None
closed = False
calls = []
report = {'result':'running','scope':'actual MCP clean inspection range'}


def write(name, value):
    (EVIDENCE / name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')


mcp = MCP(str(HELPER), env={**os.environ,'SRTFLOW_MCP_NO_LAUNCH':'1'})
try:
    def call(name,args=None):
        started=time.monotonic()
        result=mcp.request('tools/call',{'name':name,'arguments':args or {}},timeout=40)['result']
        value=json.loads(next(item['text'] for item in result['content'] if item['type']=='text'))
        calls.append({'tool':name,'arguments':args or {},'seconds':round(time.monotonic()-started,3),'is_error':bool(result.get('isError'))})
        assert not result.get('isError'),(name,value)
        return value,result['content']

    status,_=call('get_status')
    assert not status.get('jobs') and status['generation']['daily_limit_credits']==0,status
    before_spend=status['generation']['spent_today_credits']
    call('get_settings',{'section':'ai'})
    call('open_folder',{'path':str(WORK)})
    call('set_view',{'mode':'background'})
    created,_=call('new_project',{'folder':str(WORK),'name':'Empty inspection evidence','version':'isolated'})
    project=created['project']
    write('created-project.json',created)
    status,_=call('get_status')
    owned=next(item for item in status['projects'] if item['id']==project)
    assert owned['yours'] and owned['view']=='background' and owned['shown_in']=='background (no window)',owned
    call('add_clips',{'project':project,'clips':[{'file':SOURCE.name,'source_in':0,'source_out':8,'start':0,'track':'V1'}]})
    started,_=call('inspect_video',{'project':project,'from':5,'to':6})
    job=started['job_id']
    deadline=time.monotonic()+120
    while True:
        value,content=call('get_job',{'job_id':job,'wait_seconds':10})
        if value['status'] in ('done','failed','cancelled'): break
        assert time.monotonic()<deadline,'Inspection did not finish'
    image_count=sum(item['type']=='image' for item in content)
    write('inspection.json',value)
    write('content-summary.json',{'image_count':image_count,'types':[item['type'] for item in content]})
    assert value['status']=='done' and value['coverage_complete'] is True,value
    assert value['checked_ranges']==[[5,6]],value
    assert value['findings']==[] and value['screenshot_times']==[] and image_count==0,value
    assert value['sampled_picture_times'] and value['limitations']==[],value
    assert 'image' not in value,'No requested evidence must not report a drawing failure'
    status,_=call('get_status')
    assert not status.get('jobs') and status['generation']['spent_today_credits']==before_spend,status
    call('save_project',{'project':project})
    call('close_project',{'project':project})
    closed=True
    final,_=call('get_status')
    assert not final.get('jobs') and all(item['id']!=project for item in final['projects']),final
    with urllib.request.urlopen('http://127.0.0.1:' + os.environ.get('SKYSTUDIO_SMOKE_PORT', '18766') + '/__state',timeout=5) as response:
        assert json.load(response)['admitted_jobs']==0
    with urllib.request.urlopen('http://127.0.0.1:' + os.environ.get('SKYSTUDIO_SMOKE_PORT', '18766') + '/__log',timeout=5) as response:
        rows=json.load(response)
    assert not any(row['method'] in ('POST','PUT','PATCH','DELETE') for row in rows),rows
    write('fake-server-summary.json',{'admitted_jobs':0,'requests':[{'method':r['method'],'path':r['path']} for r in rows]})
    report.update(result='passed',project=project,project_closed=True,range=[5,6],findings=0,
                  sampled_picture_times=value['sampled_picture_times'],screenshots=0,false_draw_failure=False,
                  jobs_after=0,real_provider_calls=0,
                  local_credits_spent=final['generation']['spent_today_credits']-before_spend)
    print(json.dumps(report),flush=True)
except BaseException as error:
    report.update(result='failed',error=str(error),project=project,project_closed=closed)
    raise
finally:
    if project and not closed:
        try:
            status,_=call('get_status')
            if not status.get('jobs'):
                call('save_project',{'project':project})
                call('close_project',{'project':project})
                report['project_closed_on_failure']=True
            else:
                report['cleanup_requires_review']=True
        except BaseException as error:
            report['project_cleanup_error']=str(error)
    write('mcp-calls.json',calls)
    write('summary.json',report)
    mcp.close()
