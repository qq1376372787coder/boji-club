<?php
declare(strict_types=1);
// Public artwork only: reward IDs, names, rules, grants and claims remain intact.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$mode=$argv[1]??'check';
if(!in_array($mode,['check','apply','rollback'],true)) throw new RuntimeException('Use check, apply or rollback');
$configPath=$argv[2]??__DIR__.'/config.php';
$backupPath=$argv[3]??__DIR__.'/premium-badges-before-v20.json';
$c=require $configPath;
$db=new PDO($c['dsn'],$c['db_user'],$c['db_password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false]);
require_once __DIR__.'/public/club-lock.php';
clubRulesLock($db);
$db->beginTransaction();
try {
    $changes=[];$skipped=0;
    if($mode==='rollback') {
        $backup=json_decode(file_get_contents($backupPath),true,512,JSON_THROW_ON_ERROR);
        foreach($backup['changes'] as $row) {
            if(!in_array($row['table'],['club_reward_catalog','club_rewards'],true)) throw new RuntimeException('Invalid backup table');
            $q=$db->prepare('SELECT image_path FROM '.$row['table'].' WHERE id=? FOR UPDATE');$q->execute([$row['id']]);$current=$q->fetchColumn();
            if($current===$row['before']) continue;
            if($current!==$row['after']) throw new RuntimeException('Artwork changed since deployment; refusing to overwrite');
            $q=$db->prepare('UPDATE '.$row['table'].' SET image_path=? WHERE id=? AND image_path=?');$q->execute([$row['before'],$row['id'],$row['after']]);
            $changes[]=$row;
        }
        $db->commit();echo json_encode(['rolled_back'=>true,'restored'=>count($changes)]),PHP_EOL;exit;
    }
    $assets=json_decode(file_get_contents(__DIR__.'/premium-badges-v20.json'),true,512,JSON_THROW_ON_ERROR);
    if(count($assets)!==30) throw new RuntimeException('Complete thirty-badge set required');
    foreach($assets as $asset) {
        foreach(['published'=>'sha256','thumbnail'=>'thumb_sha256'] as $fileKey=>$hashKey) {
            $name=$asset[$fileKey];
            if(!is_string($name)||basename($name)!==$name||!preg_match('/^club-keepsake-\d{2}-[a-z0-9-]+-v20(?:-thumb)?\.png$/D',$name)) throw new RuntimeException('Invalid bundled image');
            $file=__DIR__.'/admin-media/'.$name;
            if(!is_file($file)||!hash_equals($asset[$hashKey],hash_file('sha256',$file))) throw new RuntimeException('Artwork hash mismatch');
            $info=getimagesize($file);
            if(!$info||($info['mime']??'')!=='image/png') throw new RuntimeException('Artwork must be PNG');
        }
        $q=$db->prepare("SELECT id,image_path FROM club_reward_catalog WHERE sku=? AND kind='badge' FOR UPDATE");$q->execute([$asset['sku']]);$catalog=$q->fetchAll();
        if(count($catalog)!==1) throw new RuntimeException('Missing or ambiguous canonical badge SKU');
        foreach(['club_reward_catalog','club_rewards'] as $table) {
            if($table==='club_reward_catalog') $rows=$catalog;
            else { $q=$db->prepare("SELECT id,image_path FROM club_rewards WHERE catalog_id=? AND reward_type='badge' FOR UPDATE");$q->execute([$catalog[0]['id']]);$rows=$q->fetchAll(); }
            foreach($rows as $row) {
                if($row['image_path']===$asset['published']) continue;
                if(!in_array($row['image_path'],[$asset['old'],$asset['legacy_svg']],true)) { $skipped++;continue; }
                $changes[]=['table'=>$table,'id'=>(int)$row['id'],'before'=>$row['image_path'],'after'=>$asset['published']];
            }
        }
    }
    if($mode==='check') { $db->rollBack();echo json_encode(['ready'=>true,'changes'=>count($changes),'custom_artwork_skipped'=>$skipped]),PHP_EOL;exit; }
    if($changes) {
        $backup=['scope'=>'Public artwork paths only','created_utc'=>gmdate('c'),'changes'=>$changes];
        $handle=@fopen($backupPath,'x');if(!$handle) throw new RuntimeException('Backup already exists or cannot be written');
        chmod($backupPath,0600);
        $data=json_encode($backup,JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR);
        $written=fwrite($handle,$data);fflush($handle);fclose($handle);
        if($written!==strlen($data)) throw new RuntimeException('Incomplete backup');
        foreach($changes as $row) {
            $q=$db->prepare('UPDATE '.$row['table'].' SET image_path=? WHERE id=? AND image_path=?');$q->execute([$row['after'],$row['id'],$row['before']]);
            if($q->rowCount()!==1) throw new RuntimeException('Concurrent artwork update');
        }
    }
    $db->commit();
    echo json_encode(['applied'=>true,'changed_paths'=>count($changes),'custom_artwork_skipped'=>$skipped]),PHP_EOL;
} catch(Throwable $e) { if($db->inTransaction())$db->rollBack();throw $e; }
