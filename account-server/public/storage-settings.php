<?php
declare(strict_types=1);
function storageRuntimeSettings(PDO $db,array $config=[]): array {
    $values=['media_storage_limit_bytes'=>0,'media_file_limit'=>0,'media_uploads_per_minute'=>120];
    foreach($db->query('SELECT setting_key,setting_value FROM storage_settings') as $row)if(array_key_exists($row['setting_key'],$values))$values[$row['setting_key']]=(int)$row['setting_value'];
    return [...$config,...$values];
}
function storageUsage(PDO $db,int $uid): array {
    $q=$db->prepare('SELECT COALESCE(SUM(byte_size),0) AS bytes,COUNT(*) AS files FROM user_media WHERE user_id=?');$q->execute([$uid]);$used=$q->fetch(PDO::FETCH_ASSOC);$limits=storageRuntimeSettings($db);
    return ['photo_bytes'=>(int)$used['bytes'],'photo_files'=>(int)$used['files'],'photo_limit_bytes'=>$limits['media_storage_limit_bytes'],'photo_limit_files'=>$limits['media_file_limit'],'unlimited_bytes'=>$limits['media_storage_limit_bytes']===0,'unlimited_files'=>$limits['media_file_limit']===0];
}
function storageDiskReserveProblem(string $directory,int $newBytes): ?array {
    while(!is_dir($directory)) { $parent=dirname($directory);if($parent===$directory)return ['status'=>503,'message'=>'照片存储暂不可用，文字记录仍可同步。'];$directory=$parent; }
    $free=@disk_free_space($directory);
    if($free===false || $free-$newBytes<256*1024*1024)return ['status'=>507,'message'=>'服务器照片存储暂时不足，照片仍保存在本机，文字记录可继续同步。请联系支持扩充空间。'];
    return null;
}
