import {describe,expect,it,vi} from "vitest";
import {executeMatching} from "./matching";
import {DEMO_20260930_PROFILE_IDS as IDS} from "./synthetic-matching-cohort";
vi.mock("./compatibility",async()=>{const actual=await vi.importActual<typeof import("./compatibility")>("./compatibility");return{...actual,computeProfileFeatureScores:vi.fn(()=>Array.from({length:14},(_,i)=>({featureId:i+1,featureName:"feature",rawScore:.5,normalizedScore:.5,confidence:1,evidence:{},sourcePhase:"quiz"}))),saveFeatureScores:vi.fn().mockResolvedValue(undefined)};});
function fixture(options:{outsider?:boolean;expire?:string;blocked?:boolean}={}){
 const ids=IDS.slice(0,4);let active=true;const writes:Array<Array<{user_a_id:string;user_b_id:string}>>=[];const reads:string[]=[];
 const db={from(table:string){let insert:typeof writes[number]|undefined;const q={select:()=>q,eq:()=>q,in:()=>q,insert:(rows:typeof writes[number])=>{insert=rows;return q;},then:(resolve:(r:unknown)=>unknown)=>{reads.push(table);if(table===options.expire)active=false;let data:unknown=[];
 if(table==="profiles")data=[...ids,...(options.outsider?["11111111-1111-4111-8111-111111111111"]:[])].map(id=>({user_id:id,status:"confirmed",basic_info:{},personality_analysis:{},personality_tags:[],interests:[],values:{},interaction_style:{},communication_style:{}}));
 if(table==="user_profiles")data=ids.map(id=>({id,age_verified_at:"2026-09-01T00:00:00Z",gender_identity:"woman",preferred_genders:["woman","man","nonbinary"],preference_mode:"selected",dating_market:"JP",onboarding_settings_completed_at:"2026-09-01T00:00:00Z"}));
 if(table==="blocks"&&options.blocked)data=[{blocker_id:ids[0],blocked_id:ids[1]}];
 if(insert){writes.push(insert);data=insert.map((_,i)=>({id:`match-${i}`}));}return Promise.resolve({data,error:null}).then(resolve);}};return q;}};
 return{db,ids,writes,reads,active:()=>active};
}
describe("scoped ordinary judge discovery",()=>{
 it("previews several normal candidates without writes",async()=>{const f=fixture();expect(await executeMatching(f.db as never,10,undefined,{profileIds:IDS,actorId:f.ids[0],mode:"preview",canWrite:f.active})).toBe(3);expect(f.writes).toHaveLength(0);});
 it("writes only actor-ranked pairs and preserves block gate",async()=>{const f=fixture({blocked:true});expect(await executeMatching(f.db as never,10,undefined,{profileIds:IDS,actorId:f.ids[0],mode:"start",canWrite:f.active})).toBe(2);expect(f.writes[0]).toHaveLength(2);for(const r of f.writes[0])expect([r.user_a_id,r.user_b_id]).toContain(f.ids[0]);});
 it.each(["profiles","user_profiles","blocks","matches"])("stops if %s await expires",async table=>{const f=fixture({expire:table});expect(await executeMatching(f.db as never,10,undefined,{profileIds:IDS,actorId:f.ids[0],mode:"start",canWrite:f.active})).toBe(0);expect(f.writes).toHaveLength(0);expect(f.reads.at(-1)).toBe(table);});
 it("rejects outside DB profile",async()=>{const f=fixture({outsider:true});await expect(executeMatching(f.db as never,10,undefined,{profileIds:IDS,actorId:f.ids[0],mode:"start",canWrite:f.active})).rejects.toThrow("Matching scope invalid");expect(f.writes).toHaveLength(0);});
});
