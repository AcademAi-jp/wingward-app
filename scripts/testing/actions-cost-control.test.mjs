import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

const ci = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const review = readFileSync(new URL('../../.github/workflows/claude-review.yml', import.meta.url), 'utf8');
const gate = readFileSync(new URL('../../.github/workflows/auto-merge.yml', import.meta.url), 'utf8');
const job = (source, name) => source.split(`\n  ${name}:\n`)[1]?.split(/\n  [a-z][a-z-]*:\n/)[0];
const condition = (source, name) => {
  const block = job(source, name);
  assert.ok(block, `job ${name} exists`);
  const match = block.match(/^    if: (.*)(?:\n((?:      .*\n)*))?/m);
  assert.ok(match, `job ${name} has an eligibility condition`);
  return match[1] === '>' ? match[2].trim().replace(/\s*\n\s*/g, ' ') : match[1];
};
// Evaluate the actual expressions from YAML against synthetic GitHub payloads.
// The supported syntax below is intentionally narrow, not a general Actions emulator.
const evaluate = (expression, github, needs = {}) => {
  expression = expression.replace(/needs\.ios-test-detect/g, 'needs["ios-test-detect"]');
  expression = expression.replace(/github\.event\.pull_request\.labels\.\*\.name/g, 'github.event.pull_request.labels.map(label => label.name)');
  return Function('github', 'needs', 'contains', 'startsWith', 'always', 'fromJSON', `return (${expression});`)(github, needs,
    (items, value) => items?.includes(value) ?? false,
    (value, prefix) => value?.startsWith(prefix) ?? false, () => true, JSON.parse);
};
const payload = (draft, labels = [], action = 'synchronize') => ({repository:'synthetic/wingward', event_name:'pull_request', event:{action,label:{name:labels.at(-1)},
  pull_request:{number:105,draft,head:{repo:{full_name:'synthetic/wingward'}},author_association:'OWNER',base:{ref:'main'},labels:labels.map(name=>({name}))}, issue:{}, comment:{}}, ref:'refs/pull/105/merge'});
const needs = {'ios-test-detect':{result:'success',outputs:{changed:'true'}}};

test('all CI jobs remain unvalidated on ordinary Draft pushes; ready and full snapshot run real jobs', () => {
  for (const name of ['build-test','semgrep','gitleaks','ios-test-detect','ios-test-run','ios-test']) {
    const expr = condition(ci,name);
    assert.equal(evaluate(expr,payload(true),needs),false,name);
    assert.equal(evaluate(expr,payload(false,[],'ready_for_review'),needs),true,name);
    assert.equal(evaluate(expr,payload(true,['full-validation']),needs),true,name);
    assert.equal(evaluate(expr,payload(true,['full-validation'],'labeled'),needs),true,name);
    assert.equal(evaluate(expr,payload(true,['full-validation','unrelated'],'labeled'),needs),false,name);
    assert.equal(evaluate(expr,{...payload(true),event_name:'push'},needs),true,name);
  }
  assert.match(ci,/types: \[opened, synchronize, reopened, ready_for_review, labeled\]/);
  assert.equal(evaluate(condition(ci,'ios-test-run'),payload(false),{'ios-test-detect':{result:'failure',outputs:{changed:'true'}}}),false);
});

test('Claude automatic Draft pushes skip the reviewer; full snapshot and ready remain real reviews',()=>{
  const expr = condition(review,'review');
  assert.equal(evaluate(expr,payload(true)),false);
  assert.equal(evaluate(expr,payload(false,[],'ready_for_review')),true);
  assert.equal(evaluate(expr,payload(true,['request-claude-review'])),true);
  assert.equal(evaluate(expr,payload(true,['full-validation'],'labeled')),false);
  assert.equal(evaluate(expr,payload(true,['request-claude-review'],'labeled')),true);
  assert.equal(evaluate(expr,payload(false,['unrelated'],'labeled')),false);
  const stack=payload(true,['request-claude-review'],'labeled');
  stack.event.pull_request.base.ref='codex/stack-40';
  assert.equal(evaluate(expr,stack),false);
  stack.event.action='synchronize';
  assert.equal(evaluate(expr,stack),false);
  stack.event.pull_request.draft=false;
  assert.equal(evaluate(expr,stack),true);
  const cumulative=review.match(/If \$\{\{ (.*?) \}\} is true,/)[1];
  assert.equal(evaluate(cumulative,stack),false);
  assert.equal(evaluate(cumulative,payload(true,['request-claude-review'])),true);
  assert.equal(evaluate(cumulative,payload(false)),false);
  assert.match(review,/CUMULATIVE changes from/);
  assert.match(review,/--model claude-opus-5/);
  assert.match(review,/--max-turns 60/);
});

test('actual review condition refuses external heads and untrusted authors and commenters',()=>{
  const expr=condition(review,'review');
  for (const association of ['OWNER','MEMBER','COLLABORATOR','NONE','CONTRIBUTOR','FIRST_TIME_CONTRIBUTOR']) {
    const trusted=['OWNER','MEMBER','COLLABORATOR'].includes(association);
    const sameRepo=payload(false); sameRepo.event.pull_request.author_association=association;
    assert.equal(evaluate(expr,sameRepo),trusted,association);
    const fork=payload(false); fork.event.pull_request.author_association=association;
    fork.event.pull_request.head.repo.full_name='outside/fork';
    assert.equal(evaluate(expr,fork),false,`fork ${association}`);
    const comment={event_name:'issue_comment',repository:'synthetic/wingward',event:{issue:{pull_request:{}},comment:{author_association:association,body:'@claude review'}}};
    assert.equal(evaluate(expr,comment),trusted,`comment ${association}`);
    comment.event.comment.body='ordinary comment';
    assert.equal(evaluate(expr,comment),false);
  }
});

test('CI concurrency cancels superseded runs within a PR, never another PR',()=>{
  const block=ci.split('\nconcurrency:\n')[1]?.split('\n\n')[0];
  assert.match(block,/cancel-in-progress: true/);
  const group=block.match(/group: (.+)/)[1];
  const expand=g=>group.replace(/\$\{\{ (.*?) \}\}/g,(_,expr)=>evaluate(expr,g));
  assert.equal(expand(payload(true)),expand(payload(false)));
  const other=payload(true); other.event.pull_request.number=104;
  assert.notEqual(expand(payload(true)),expand(other));
  assert.equal(expand(payload(true)),expand(payload(true,['full-validation'],'labeled')));
  assert.notEqual(expand(payload(true)),expand(payload(true,['unrelated'],'labeled')));
});

test('actual auto-merge required-check shell blocks skipped/missing/failure/cancelled and absent review',()=>{
  const start=gate.indexOf('            blocked=false\n');
  const end=gate.indexOf('            if [ "$mergeable"',start);
  assert.ok(start>0 && end>start);
  const script=gate.slice(start,end)+'            echo earned\n';
  for (const target of ['build-test','semgrep','gitleaks','ios-test','claude-review']) {
    for (const conclusion of ['skipped','missing','failure','cancelled','success']) {
      const checks=['build-test','semgrep','gitleaks','ios-test','claude-review']
        .filter(name=>!(name===target && conclusion==='missing'))
        .map(name=>({name,conclusion:name===target?conclusion:'success'}));
      const result=spawnSync('bash',['-c',`for pr in 105; do\n${script}\ndone`],{
        env:{...process.env,checks:JSON.stringify(checks),sha:'synthetic'},encoding:'utf8'});
      assert.equal(result.status,0,result.stderr);
      assert.equal(result.stdout.includes('earned'),conclusion==='success',`${target}: ${conclusion}`);
    }
  }
  const checks=['build-test','semgrep','gitleaks','ios-test'].map(name=>({name,conclusion:'success'}));
  const result=spawnSync('bash',['-c',`for pr in 105; do\n${script}\ndone`],{env:{...process.env,checks:JSON.stringify(checks),sha:'synthetic'},encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  assert.equal(result.stdout.includes('earned'),false);
});

test('actual iOS detector forces XCTest for docs-only final snapshot and retains initial push behavior',()=>{
  const dir=mkdtempSync(join(tmpdir(),'wingward-cost-fixture-'));
  const git=(...args)=>execFileSync('git',args,{cwd:dir,encoding:'utf8'}).trim();
  const commit=()=>{git('add','.');git('-c','core.hooksPath=/dev/null','-c','user.name=Synthetic Reviewer','-c','user.email=reviewer@example.invalid','commit','-qm','fixture');return git('rev-parse','HEAD');};
  try {
    git('init','-q');mkdirSync(join(dir,'apps/ios'),{recursive:true});writeFileSync(join(dir,'apps/ios/App.swift'),'// synthetic\n');const root=commit();
    writeFileSync(join(dir,'README.md'),'docs\n');const docs=commit();
    const block=job(ci,'ios-test-detect');
    const forceExpression=block.match(/FORCE_IOS: \$\{\{ (.*?) \}\}/)[1];
    const script=block.split('        run: |\n')[1].split('\n').map(line=>line.startsWith('          ')?line.slice(10):line).join('\n');
    for(const [event,force,before,head,expected] of [['pull_request','false',root,docs,false],['pull_request','true',root,docs,true],['push','false','0'.repeat(40),root,true],['push','false','f'.repeat(40),root,true]]) {
      const output=join(dir,'output');writeFileSync(output,'');
      const result=spawnSync('bash',['-c',script],{cwd:dir,env:{...process.env,EVENT_NAME:event,FORCE_IOS:String(evaluate(forceExpression,payload(true,force==='true'?['full-validation']:[]))),BEFORE_SHA:before,HEAD_SHA:head,PR_BASE_SHA:before,PR_HEAD_SHA:head,GITHUB_OUTPUT:output},encoding:'utf8'});
      assert.equal(result.status,0,result.stderr);assert.equal(readFileSync(output,'utf8').trim(),`changed=${expected}`);
    }
  } finally {rmSync(dir,{recursive:true,force:true});}
});


test('all CI jobs have explicit finite execution caps within the final-run budget',()=>{
  const caps={'build-test':10,semgrep:5,gitleaks:5,'ios-test-detect':2,'ios-test':2,'ios-test-run':25};
  for (const [name,cap] of Object.entries(caps)) {
    const timeout=job(ci,name).match(/^    timeout-minutes: (\d+)$/m);
    assert.ok(timeout,`${name} requires an explicit integer timeout`);
    const minutes=Number(timeout[1]);
    assert.ok(Number.isFinite(minutes) && minutes>0 && minutes<=cap,`${name}: ${minutes} must be within 1..${cap}`);
  }
});


test('unrelated Ready PR label events cannot replace a failed validation check name',()=>{
  const names={'build-test':'build-test',semgrep:'semgrep',gitleaks:'gitleaks','ios-test-detect':'Detect iOS changes','ios-test-run':'Run iOS XCTest','ios-test':'ios-test'};
  const validations=Object.values(names);
  const event=payload(false,['unrelated'],'labeled');
  // Model a previously failed validation on the exact same head followed by an
  // unrelated label event. Each skipped job must have a disjoint check name.
  const checks=validations.map(name=>({name,conclusion:'failure'}));
  for (const [id,expected] of Object.entries(names)) {
    assert.equal((job(ci,id).match(/^    name:/gm) ?? []).length,1,`${id} must have exactly one name key`);
    const definition=job(ci,id).match(/^    name: (.*)$/m)?.[1];
    assert.ok(definition,`${id} requires an explicit isolated name`);
    const resolve=g=>definition.replace(/\$\{\{ (.*?) \}\}/g,(_,expr)=>evaluate(expr,g));
    assert.equal(evaluate(condition(ci,id),event,needs),false,`${id} must not spend a runner`);
    const skippedName=resolve(event);
    assert.match(skippedName,/ \/ Unvalidated label event$/);
    assert.ok(!validations.includes(skippedName),`${id} skipped name must not claim validation`);
    checks.push({name:skippedName,conclusion:'skipped'});
    for(const relevant of [payload(false),payload(false,[],'ready_for_review'),payload(true,['full-validation'],'labeled'),{...payload(true),event_name:'push'}]) {
      assert.equal(resolve(relevant),expected,`${id} required name remains stable`);
    }
  }
  for(const name of validations) {
    assert.equal(checks.filter(check=>check.name===name).at(-1).conclusion,'failure',`${name} stays failed`);
  }
});
