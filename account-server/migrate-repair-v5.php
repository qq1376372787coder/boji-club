<?php
declare(strict_types=1);
if(PHP_SAPI!=='cli') exit(1);
$apply=in_array('--apply',$argv,true);
$config=require __DIR__.'/config.php';
$db=new PDO($config['dsn'],$config['db_user'],$config['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false]);
require_once __DIR__.'/public/club-lock.php';
clubRulesLock($db);
$assets=json_decode(file_get_contents(__DIR__.'/bundled-media.json'),true,512,JSON_THROW_ON_ERROR);
$changes=[];
foreach($assets as $asset) {
    $old=$asset['source'];$new=$asset['published'];
    if(basename($old)!==$old || basename($new)!==$new || !str_ends_with($old,'.svg') || !str_ends_with($new,'.png')) throw new RuntimeException('Invalid bundled image');
    $info=getimagesize(__DIR__.'/admin-media/'.$new);
    if(!$info || ($info['mime']??'')!=='image/png') throw new RuntimeException('Bundled PNG not ready');
    foreach(['club_reward_catalog','club_rewards'] as $table) {
        $q=$db->prepare('SELECT COUNT(*) FROM '.$table.' WHERE image_path=?');$q->execute([$old]);$count=(int)$q->fetchColumn();
        if($count) $changes[]=[$table,$old,$new,$count];
    }
}
if($apply) {
    $db->beginTransaction();
    try {
        foreach($changes as [$table,$old,$new,$count]) $db->prepare('UPDATE '.$table.' SET image_path=? WHERE image_path=?')->execute([$new,$old]);
        $db->commit();
    } catch(Throwable $e) { if($db->inTransaction())$db->rollBack();throw $e; }
}
echo json_encode(['applied'=>$apply,'changes'=>$changes],JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT).PHP_EOL;
