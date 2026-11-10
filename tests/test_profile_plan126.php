<?php
declare(strict_types=1);
require_once __DIR__.'/../account-server/public/profile-facts.php';
function verify126(bool $value,string $name):void {if(!$value)throw new RuntimeException($name);echo "PASS $name\n";}
function rejects126(callable $f,string $name):void {try{$f();}catch(RuntimeException $e){verify126(true,$name);return;}throw new RuntimeException('accepted invalid '.$name);}
$doc=profileFactsEmptyDocument();
$facts=profileFactsApplyChanges($doc,[['field'=>'personal_preferences','value'=>'更喜欢早上训练，动作说明尽量简短'],['field'=>'equipment_other','value'=>'可调节训练凳'],['field'=>'training_days','value'=>[1,3,5]],['field'=>'home_training_days','value'=>[3]]],'confirmed','test126',1);
verify126($facts['personal_preferences']['value']==='更喜欢早上训练，动作说明尽量简短','explicit member preference roundtrip');
$p=profileFactsOverlayStateProfile(['nickname'=>'测试成员'],$facts);
verify126($p['equipmentOther']==='可调节训练凳'&&$p['homeTrainingDays']===[3],'equipment and home days use authoritative projections');
verify126(!isset($p['personalPreferences']),'freeform preference is not duplicated into compatibility profile');
rejects126(fn()=>profileFactNormalizeValue('personal_preferences',str_repeat('a',501),null),'preference maximum length');
rejects126(fn()=>profileFactNormalizeValue('home_training_days',[8],null),'home weekday range');
rejects126(fn()=>profileFactsApplyChanges($doc,[['field'=>'training_days','value'=>[1]],['field'=>'home_training_days','value'=>[3]]],'confirmed','test126',1),'home weekday subset');
$cleared=profileFactsClearField(['facts'=>$facts],'personal_preferences');
verify126(!isset($cleared['personal_preferences'])&&isset($cleared['equipment_other']),'clear preference preserves other facts');
verify126(profileFactNormalizeValue('home_training_days',[],null)[0]===[],'empty home schedule allowed');
echo "8 CHECKS PASSED\n";
require_once __DIR__.'/../account-server/public/ai-memory.php';
verify126(aiMemoryDeclaredPreference($facts)!==null,'explicit preference enters coach context');
verify126(aiMemoryDeclaredPreference($cleared)===null,'cleared preference immediately leaves context');
$unconfirmed=['personal_preferences'=>['value'=>'偏好','source_kind'=>'model_candidate']];
verify126(aiMemoryDeclaredPreference($unconfirmed)===null,'model candidate never becomes declared preference');
require_once __DIR__.'/../account-server/public/ai-context.php';
$projection=aiContextProjection(['kind'=>'plan_day','resource_id'=>'plan-a'],['2030-01-07'=>['exercises'=>[['id'=>'a','name'=>'A','planID'=>'plan-a','sets'=>[['id'=>'s','reps'=>8]]],['id'=>'b','name'=>'B','planID'=>'plan-b','sets'=>[]]]]]);
verify126(count($projection[0]['exercises'])===1&&$projection[0]['exercises'][0]['id']==='a','plan reference excludes same-day other plan');
echo "12 CHECKS PASSED\n";

$private=profileFactsOverlayStateProfile(['gender'=>'男'],['sex_for_nutrition'=>['value'=>'不愿提供','source_kind'=>'confirmed']]);
verify126(!isset($private['gender']),'gender opt-out cannot retain previous compatibility gender');
echo "13 CHECKS PASSED\n";
