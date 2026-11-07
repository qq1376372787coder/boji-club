const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const source=fs.readFileSync(require('path').join(__dirname,'../account-server/admin/app.js'),'utf8');
function fixture(search='',saved=null,hash=''){
 const events={},store=new Map(),panes=['summary','daily-records','membership'].map(name=>({dataset:{tabScope:'user-detail',tabPane:name},hidden:false,setAttribute(){}}));
 const buttons=panes.map(p=>({dataset:{tabTarget:p.dataset.tabPane},classList:{toggle(){}},setAttribute(k,v){this[k]=v;},addEventListener(k,v){this[k]=v;},focus(){this.focused=true;}}));
 const group={dataset:{tabGroup:'user-detail'},querySelectorAll:()=>buttons};
 if(saved)store.set('boji.admin.tab.user-detail.42',saved);
 const document={hidden:false,querySelector:()=>null,getElementById:()=>null,querySelectorAll:s=>s==='[data-tab-group]'?[group]:s==='[data-tab-pane]'?panes:[],addEventListener:(k,v)=>{events[k]=v;}};
 const window={location:{search,hash,href:'https://admin.example/admin/'+search+hash},history:{replaceState(){}}};
 vm.runInNewContext(source,{document,window,sessionStorage:{getItem:k=>store.get(k),setItem:(k,v)=>store.set(k,v)},HTMLFormElement:class{},URL,URLSearchParams});
 return {buttons,panes,events,store,group};
}
let f=fixture('?p=user&id=42');
assert.deepEqual(f.panes.map(p=>p.hidden),[false,true,true]);
f.buttons[2].click(); assert.deepEqual(f.panes.map(p=>p.hidden),[true,true,false]);
assert.equal(f.buttons[2]['aria-selected'],'true');assert.equal(f.store.get('boji.admin.tab.user-detail.42'),'membership');
f.buttons[2].keydown({key:'ArrowRight',preventDefault(){}});assert.equal(f.panes[0].hidden,false);assert(f.buttons[0].focused);
f.events.invalid({target:{closest:()=>f.panes[1]}});assert.equal(f.panes[1].hidden,false);
f=fixture('?p=user&id=42&date=2026-10-28','membership');assert.equal(f.panes[1].hidden,false);
f=fixture('?p=user&id=42&tab=membership',null,'#%zz');assert.equal(f.panes[2].hidden,false);
f=fixture('?p=user&id=42','membership');assert.equal(f.panes[2].hidden,false);
console.log('7 admin tab navigation/validation scenarios passed');
