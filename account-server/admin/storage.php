<?php
require_once dirname(__DIR__).'/public/storage-settings.php';
$storageLimits=storageRuntimeSettings($db);
$photoTotals=query('SELECT COALESCE(SUM(byte_size),0) AS bytes,COUNT(*) AS files FROM user_media')->fetch();
$recordTotals=query('SELECT COALESCE(SUM(byte_size),0) AS bytes,COUNT(*) AS parts,COUNT(DISTINCT user_id) AS users FROM cloud_parts')->fetch();
$diskFolder=is_dir(dirname(__DIR__).'/media')?dirname(__DIR__).'/media':dirname(__DIR__);
$diskFree=@disk_free_space($diskFolder);$diskTotal=@disk_total_space($diskFolder);
$listPage=max(1,min(100000,(int)($_GET['page']??1)));$listOffset=($listPage-1)*20;
$members=query('SELECT m.user_id,m.files,m.bytes,COALESCE(JSON_UNQUOTE(JSON_EXTRACT(s.state_json,\'$.profile.nickname\')),p.nickname,\'未设置昵称\') nickname FROM (SELECT user_id,COUNT(*) files,SUM(byte_size) bytes FROM user_media GROUP BY user_id ORDER BY bytes DESC,user_id LIMIT 21 OFFSET '.$listOffset.') m LEFT JOIN profiles p ON p.user_id=m.user_id LEFT JOIN app_states s ON s.user_id=m.user_id ORDER BY m.bytes DESC')->fetchAll();
$moreMembers=count($members)>20;$members=array_slice($members,0,20);
function storageSize(mixed $bytes): string {return is_numeric($bytes)?((float)$bytes>=1073741824?number_format((float)$bytes/1073741824,1).' GB':number_format((float)$bytes/1048576,1).' MB'):'—';}
?>

<?php if($pagePanel==='usage'):?><section class="card"><h2>照片与记录用量</h2><div class="profile-grid">
<div><small>全部照片</small><p><?=h(storageSize($photoTotals['bytes']))?> · <?=safeNumber($photoTotals['files'])?> 张</p></div>
<div><small>文字记录占用空间</small><p><?=h(storageSize($recordTotals['bytes']))?> · <?=safeNumber($recordTotals['users'])?> 个账号</p></div>
<div><small>服务器磁盘可用 / 总量</small><p><?=h(storageSize($diskFree))?> / <?=h(storageSize($diskTotal))?></p></div>
</div><p class="muted">这里统计服务器已收到的照片和记录，手机上尚未同步的内容不会计入。</p>
<?php if($diskFree!==false && $diskFree<1024*1024*1024):?><p class="error">可用空间不足1GB，请及时扩容或处理已备份的数据。</p><?php endif?>
</section><?php endif ?>
<?php if($pagePanel==='limits'):?><section class="card"><h2>账号照片设置</h2><p>保存后立即应用于后续上传。降低上限不会删除用户已有照片。</p>
<form method="post" data-confirm="确认保存照片空间和上传设置？"><input type="hidden" name="action" value="storage_capacity"><?php csrfField()?>
<div class="profile-grid">
<label>每账号照片空间（MB）<input type="number" name="storage_limit_mib" min="0" max="2147483647" step="1" value="<?=(int)ceil($storageLimits['media_storage_limit_bytes']/1048576)?>" required><small>0不限，2048约2GB。</small></label>
<label>每账号照片数量<input type="number" name="media_file_limit" min="0" max="2147483647" step="1" value="<?=$storageLimits['media_file_limit']?>" required><small>0不限；已满后替换已有照片仍按空间校验。</small></label>
<label>每人每分钟最多上传照片数<input type="number" name="media_uploads_per_minute" min="1" max="2147483647" step="1" value="<?=$storageLimits['media_uploads_per_minute']?>" required><small>默认 120 张，用于防止短时间大量上传；不影响文字记录同步。</small></label>
</div><label>操作原因<textarea name="reason" required minlength="2" maxlength="200"></textarea></label><button>保存照片设置</button></form></section><?php endif ?>
<?php if($pagePanel==='usage'):?><section class="card"><h2>照片用量最多的账号</h2><div class="table-wrap"><table><thead><tr><th>账号</th><th>昵称</th><th>照片数量</th><th>使用空间</th></tr></thead><tbody>
<?php foreach($members as $member):?><tr><td><a href="?p=user&amp;id=<?=(int)$member['user_id']?>"><?=h(clubNumber((int)$member['user_id']))?></a></td><td><?=h($member['nickname'])?></td><td><?=safeNumber($member['files'])?></td><td><?=h(storageSize($member['bytes']))?></td></tr><?php endforeach?>
</tbody></table></div><p class="muted">按照片用量排序，每页 20 个账号。</p><?php adminPageCount($listPage,$moreMembers);?></section><?php endif ?>
