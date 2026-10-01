"""Only the isolated synthetic local DB created for SQL40, never Supabase/cloud.
Committed rows briefly allow two real local connections to contend; cleanup removes
only these exact synthetic Auth/permit fixtures. No credentials/config/log reads.
"""
from pathlib import Path
import subprocess,os,time,json
ROOT=Path(__file__).resolve().parents[2]
ENV={k:v for k,v in os.environ.items() if k in('PATH','HOME','TMPDIR')}
CMD=['docker','exec','-i','wingward-ui-pg-01a0db7a','psql','-X','-h','/tmp','-U','postgres','-d','wingward_demo40_verification_20260930','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose']
def sql(s):return subprocess.run(CMD,input=s,text=True,capture_output=True,env=ENV)
source=(ROOT/'supabase/tests/40_maya_ren_synthetic_test_admission.sql').read_text()
setup=source.split('DO $$\nDECLARE aid')[0]+"INSERT INTO wingward_private.synthetic_recording_admissions(admission_id,issued_at,expires_at) VALUES('90000000-0000-4000-8000-00000000d401',now()-interval '1 minute',now()+interval '119 minutes'); COMMIT;"
p=sql(setup);assert p.returncode==0,'Synthetic fixture setup must pass'
holder=None
try:
 holder=subprocess.Popen(CMD,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV)
 holder.stdin.write("BEGIN; SELECT id FROM public.matches WHERE id='20000000-0000-0000-0000-00000000d401' FOR UPDATE;\n\\echo LOCK_HELD\n");holder.stdin.flush()
 while 'LOCK_HELD' not in holder.stdout.readline():assert holder.poll() is None,'Holder must acquire synthetic relationship lock'
 start=time.monotonic()
 p=sql("""BEGIN; SET LOCAL statement_timeout='1s';
 SELECT public.demo_recording_apply_chat_meetup_action(a.admission_id,a.issued_at,a.expires_at,'40000000-0000-0000-0000-00000000d401','9d836fee-7b93-41ce-b577-34a63006aaea',0,0,'80000000-0000-4000-8000-00000000d401',repeat('1',64),'{"type":"intent","value":"yes"}') FROM wingward_private.synthetic_recording_admissions a; ROLLBACK;""")
 elapsed=time.monotonic()-start
 assert p.returncode!=0 and '42501' in p.stderr and 'Synthetic admission unavailable' in p.stderr,'Contention must fail closed with bounded permission error'
 assert elapsed<1,'Wrapper must not wait against legacy relationship-first holder'
 holder.stdin.write('ROLLBACK;\n');holder.stdin.close();holder.wait(timeout=5);holder=None
 p=sql("SELECT count(*) FROM public.meetups WHERE match_id='20000000-0000-0000-0000-00000000d401'; SELECT count(*) FROM wingward_private.synthetic_recording_admissions WHERE match_id IS NOT NULL;")
 assert p.returncode==0 and p.stdout.count('     0')==2,'Contended wrapper must leave no meetup or binding'
 print(json.dumps({'local_synthetic_lock_contention':'PASS','bounded_42501':True,'elapsed_under_1_second':True,'no_meetup_or_binding':True}))
finally:
 if holder:
  try:holder.stdin.write('ROLLBACK;\n');holder.stdin.close();holder.wait(timeout=5)
  except Exception:holder.terminate();holder.wait(timeout=5)
 p=sql("DELETE FROM wingward_private.synthetic_recording_admissions WHERE admission_id='90000000-0000-4000-8000-00000000d401'; DELETE FROM public.meetups WHERE match_id='20000000-0000-0000-0000-00000000d401'; DELETE FROM auth.users WHERE id IN('00000000-0000-0000-0000-00000000d401','00000000-0000-0000-0000-00000000d402');")
 assert p.returncode==0,'Exact synthetic fixture cleanup must pass'

# Separate regression: transaction began before start, then waited on a session lock.
p=sql(setup);assert p.returncode==0,'Second synthetic fixture setup'
p=sql("""DO $$ DECLARE a wingward_private.synthetic_recording_admissions; BEGIN SELECT * INTO a FROM wingward_private.synthetic_recording_admissions;
 PERFORM public.demo_recording_apply_chat_meetup_action(a.admission_id,a.issued_at,a.expires_at,'40000000-0000-0000-0000-00000000d401','9d836fee-7b93-41ce-b577-34a63006aaea',0,0,'80000000-0000-4000-8000-00000000d401',repeat('1',64),'{"type":"intent","value":"yes"}');
 PERFORM public.demo_recording_apply_chat_meetup_action(a.admission_id,a.issued_at,a.expires_at,'40000000-0000-0000-0000-00000000d401','a88a89e2-5421-5ce9-a33b-76d512898c37',0,0,'80000000-0000-4000-8000-00000000d402',repeat('2',64),'{"type":"intent","value":"yes"}'); END $$;
 UPDATE public.chat_meetup_sessions SET status='time_proposed',time_candidates=jsonb_build_array(jsonb_build_object('id','future-lock-test','starts_at',clock_timestamp()+interval '2 seconds','ends_at',clock_timestamp()+interval '60 minutes 2 seconds')) WHERE room_id='40000000-0000-0000-0000-00000000d401';""")
assert p.returncode==0,'Synthetic pre-start session'
holder=None;runner=None
try:
 # Correct microsecond-perfect duration using one captured start instant.
 p=sql("UPDATE public.chat_meetup_sessions SET time_candidates=jsonb_build_array(jsonb_build_object('id','future-lock-test','starts_at',t.start_at,'ends_at',t.start_at+interval '60 minutes')) FROM (SELECT clock_timestamp()+interval '2 seconds' start_at)t WHERE room_id='40000000-0000-0000-0000-00000000d401';")
 assert p.returncode==0
 holder=subprocess.Popen(CMD,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV)
 holder.stdin.write("BEGIN; SELECT meetup_id FROM public.chat_meetup_sessions WHERE room_id='40000000-0000-0000-0000-00000000d401' FOR UPDATE;\n\\echo LOCK_HELD\n");holder.stdin.flush()
 while 'LOCK_HELD' not in holder.stdout.readline():assert holder.poll() is None
 runner=subprocess.Popen(CMD,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV)
 runner.stdin.write("""BEGIN; SET LOCAL application_name='sql40-future-runner'; SET LOCAL statement_timeout='5s';
 SELECT public.demo_recording_apply_chat_meetup_action(a.admission_id,a.issued_at,a.expires_at,'40000000-0000-0000-0000-00000000d401','9d836fee-7b93-41ce-b577-34a63006aaea',1,1,'80000000-0000-4000-8000-00000000d411',repeat('b',64),'{"type":"time.approve","candidate_id":"future-lock-test"}') FROM wingward_private.synthetic_recording_admissions a; COMMIT;""");runner.stdin.close()
 waiting=False
 for _ in range(30):
  p=sql("SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE application_name='sql40-future-runner' AND wait_event_type='Lock';")
  if '     1' in p.stdout:waiting=True;break
  time.sleep(.05)
 assert waiting,'Runner must actually wait on synthetic session lock'
 time.sleep(2.2)
 holder.stdin.write('ROLLBACK;\n');holder.stdin.close();holder.wait(timeout=5);holder=None
 runner.wait(timeout=5);output=runner.stdout.read();error=runner.stderr.read()
 assert runner.returncode==0 and 'expired_candidate' in output,'Live clock must reject candidate after lock wait, despite earlier transaction start'
 runner=None
 p=sql("SELECT count(*) FROM public.chat_meetup_private_decisions WHERE user_id='9d836fee-7b93-41ce-b577-34a63006aaea' AND time_choice_id IS NOT NULL;")
 assert p.returncode==0 and '     0' in p.stdout,'Late approval must not be retained'
 print(json.dumps({'local_synthetic_future_after_lock_wait':'PASS','real_session_lock_wait':True,'expired_candidate':True,'no_time_choice_retained':True}))
finally:
 for process in (holder,runner):
  if process:
   try:process.stdin.write('ROLLBACK;\n');process.stdin.close();process.wait(timeout=5)
   except Exception:process.terminate();process.wait(timeout=5)
 p=sql("DELETE FROM wingward_private.synthetic_recording_admissions WHERE admission_id='90000000-0000-4000-8000-00000000d401'; DELETE FROM public.meetups WHERE match_id='20000000-0000-0000-0000-00000000d401'; DELETE FROM auth.users WHERE id IN('00000000-0000-0000-0000-00000000d401','00000000-0000-0000-0000-00000000d402');")
 assert p.returncode==0,'Second exact synthetic cleanup'
