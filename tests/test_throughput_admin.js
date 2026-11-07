const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const path = require('path');
const keys = ['running','queued','retrying','pending','today_received','today_processed','today_succeeded','today_failed','today_failure_events','today_failed_attempts','today_quota_successes'];
const fields = new Map();
const counts = keys.map(key => ({dataset:{aiCount:key},textContent:'0'}));
for (const key of ['status','limits','workers','resources','alerts','refresh','account-limit']) fields.set(`[data-live-${key}]`, {textContent:'',addEventListener(name,callback){this[name]=callback;}});
const panel = {querySelector: key => fields.get(key), querySelectorAll: () => counts};
let payload, code=200, requests=0, timerStopped=false;
const document = {hidden:false,addEventListener(){},querySelectorAll:()=>[],querySelector:()=>panel};
const context = vm.createContext({document,window:{},HTMLFormElement:class{},AbortController,Intl,Date,Number,Array,
  setTimeout:()=>1,clearTimeout(){},setInterval:()=>2,clearInterval(){timerStopped=true;},
  fetch:async()=>{requests++;return {status:code,ok:code===200,json:async()=>payload};}});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../account-server/admin/app.js'),'utf8'),context);
const refresh = fields.get('[data-live-refresh]').click;
async function main(){
 payload=Object.fromEntries(keys.map((key,i)=>[key,i]));
 Object.assign(payload,{sampled_at:1791807426,oldest_queue_seconds:135,capacity_settings:{daily_limit:0,pending_limit:800,worker_limit:16,account_daily_limit:0},runtime:{configured_workers:16,effective_workers:16,pause_reason:null,resources:{memory_current:64*1048576,memory_limit:512*1048576,host_available:900*1048576}},alerts:['排队较久']});
 await refresh();assert.equal(counts[1].textContent,'1');assert.match(fields.get('[data-live-workers]').textContent,/16.*16.*135/);assert.match(fields.get('[data-live-resources]').textContent,/64.0MiB.*512.0MiB/);assert.equal(fields.get('[data-live-alerts]').textContent,'排队较久');
 assert.match(fields.get('[data-live-account-limit]').textContent,/不限制/);assert.equal(counts[8].textContent,'8');
 payload.runtime.pause_reason='host_memory';payload.runtime.effective_workers=0;payload.alerts=['资源保护'];payload.capacity_settings.account_daily_limit=50;await refresh();assert.match(fields.get('[data-live-resources]').textContent,/暂缓/);assert.match(fields.get('[data-live-workers]').textContent,/当前资源允许：0/);assert.match(fields.get('[data-live-account-limit]').textContent,/50/);
 code=500;const previous=counts[1].textContent;await refresh();assert.equal(counts[1].textContent,previous);assert.match(fields.get('[data-live-status]').textContent,/更新失败/);
 document.hidden=true;const before=requests;await refresh();assert.equal(requests,before);document.hidden=false;
 code=401;await refresh();assert.equal(timerStopped,true);assert.match(fields.get('[data-live-status]').textContent,/登录已过期/);
 console.log('5 admin live-update scenarios passed');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
