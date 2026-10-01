import { Hono } from 'hono';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Env } from '../env';
const resolve=vi.fn();
vi.mock('./auth',()=>({resolveAuthUser:(...args:unknown[])=>resolve(...args)}));
import { productionE2EGate } from './production-e2e-gate';
const REN='9d836fee-7b93-41ce-b577-34a63006aaea',MAYA='a88a89e2-5421-5ce9-a33b-76d512898c37',NOW=Date.parse('2026-10-01T01:00:00Z');
const ENV={RECORDING_REHEARSAL_ENABLED:'enabled',RECORDING_REHEARSAL_PAIR:'demo-maya-ren',RECORDING_REHEARSAL_ISSUED_AT:'2026-09-30T23:00:00Z',RECORDING_REHEARSAL_EXPIRES_AT:'2026-10-01T01:00:00Z',RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID:'77777777-7777-4777-8777-777777777777'};
function app(){const a=new Hono<Env>();a.use('*',productionE2EGate);a.all('*',c=>c.json({user_id:c.get('user_id'),read_only:c.get('production_e2e_read_only'),recording_config_injected:c.get('recording_rehearsal')!==undefined}));return a;}
beforeEach(()=>{vi.useFakeTimers();vi.setSystemTime(NOW);vi.clearAllMocks();resolve.mockResolvedValue({userId:REN,authUserId:'synthetic-auth'});});afterEach(()=>vi.useRealTimers());
describe('expired recording own profile read',()=>{
 it.each(['/api/auth/me','/api/profiles/me'])('keeps same-owner read %s available at expiry without recording admission',async(path)=>{
  const r=await app().request(path,{headers:{Authorization:'Bearer synthetic-token'}},ENV);expect(r.status).toBe(200);expect(await r.json()).toEqual({user_id:REN,read_only:true,recording_config_injected:false});
 });
 it('keeps the other exact demo cohort owner readable after expiry',async()=>{resolve.mockResolvedValue({userId:MAYA,authUserId:'synthetic-auth'});vi.setSystemTime(NOW+86400000);const r=await app().request('/api/profiles/me',{headers:{Authorization:'Bearer synthetic-token'}},ENV);expect(r.status).toBe(200);});
 it.each([
  ['POST','/api/profiles/me/confirm'],['PUT','/api/profiles/me'],['GET','/api/profiles/me/generation-state'],['GET','/api/profiles/other'],
  ['POST','/api/meetup-reflections/22222222-2222-4222-8222-222222222222/bootstrap'],['GET','/api/billing/status'],
  ['POST','/api/testing/synthetic-session'],['GET','/api/chat-meetups/rooms/44444444-4444-4444-8444-444444444444'],
 ])('keeps expired %s %s closed before authentication or provider work',async(method,path)=>{const r=await app().request(path,{method,headers:{Authorization:'Bearer synthetic-token'}},ENV);expect(r.status).toBe(503);expect(resolve).not.toHaveBeenCalled();});
 it('rejects an outside authenticated owner',async()=>{resolve.mockResolvedValue({userId:'11111111-1111-4111-8111-111111111111',authUserId:'outsider'});const r=await app().request('/api/profiles/me',{headers:{Authorization:'Bearer synthetic-token'}},ENV);expect(r.status).toBe(403);});
 it.each([undefined,'Bearer ','Basic synthetic-token'])('requires a valid bearer header (%s)',async(Authorization)=>{const r=await app().request('/api/profiles/me',{headers:Authorization?{Authorization}:{}},ENV);expect(r.status).toBe(401);expect(resolve).not.toHaveBeenCalled();});
 it('preserves failed auth rejection',async()=>{resolve.mockResolvedValue(null);const r=await app().request('/api/profiles/me',{headers:{Authorization:'Bearer synthetic-token'}},ENV);expect(r.status).toBe(401);});
 it.each([
  {RECORDING_REHEARSAL_ENABLED:'disabled'}, {RECORDING_REHEARSAL_PAIR:'aoi-ren'}, {RECORDING_REHEARSAL_ISSUED_AT:undefined},
  {RECORDING_REHEARSAL_EXPIRES_AT:'bad'}, {RECORDING_REHEARSAL_ISSUED_AT:'2026-09-30T22:59:59Z'},
  {PRODUCTION_E2E_READ_ONLY:'invalid'}, {RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED:'enabled'}, {RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED:'invalid'}, {RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID:'invalid'},
 ])('rejects malformed or non-demo expired settings %#',async(overrides)=>{const r=await app().request('/api/profiles/me',{headers:{Authorization:'Bearer synthetic-token'}},{...ENV,...overrides});expect(r.status).toBe(503);expect(resolve).not.toHaveBeenCalled();});
});
