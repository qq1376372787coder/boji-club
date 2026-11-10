const fs = require('fs'), vm = require('vm'), assert = require('assert');
const handlers = {};
const labels = [{hidden:false}, {hidden:false}];
class HTMLFormElement {
  constructor() {
    this.dataset = {}; this.kind = {value:'badge'};
    this.inventory = {value:'', disabled:false, required:false};
    this.rewardInventory = {value:'', disabled:false, required:false};
  }
  querySelector(selector) {
    if (selector.includes('reward_inventory')) return this.rewardInventory;
    return selector.includes('default_inventory') ? this.inventory : selector.includes('kind') ? this.kind : null;
  }
  querySelectorAll() { return labels; }
}
const form = new HTMLFormElement();
const rewardKind = {name:'reward_type[42]', value:'badge', disabled:false, form};
vm.runInNewContext(fs.readFileSync(require('path').join(__dirname, '../account-server/admin/app.js'), 'utf8'), {
  HTMLFormElement, window:{confirm:()=>false},
  document:{querySelectorAll: selector => selector === 'form' ? [form] : [rewardKind],
    addEventListener:(event, callback) => (handlers[event] ??= []).push(callback)}
});
assert(form.rewardInventory.disabled && !form.rewardInventory.required && labels.every(l=>l.hidden));
function change() { handlers.change.forEach(f=>f({target:{...rewardKind, matches:selector=>selector.includes('reward_type')}})); }
rewardKind.value = 'physical'; change();
assert(!form.rewardInventory.disabled && form.rewardInventory.required && form.rewardInventory.value === '1' && labels.every(l=>!l.hidden));
form.rewardInventory.value = '8'; change(); assert.equal(form.rewardInventory.value,'8');
rewardKind.disabled = true; change(); assert(form.rewardInventory.disabled && !form.rewardInventory.required);
rewardKind.disabled = false; rewardKind.value = 'badge'; change(); assert(form.rewardInventory.disabled && labels.every(l=>l.hidden));
let prevented = false; form.dataset.confirm='Confirm'; handlers.submit[0]({target:form,preventDefault:()=>prevented=true}); assert(prevented);
console.log('ADMIN_V17_DOM_REGRESSIONS_PASS 6 checks');
