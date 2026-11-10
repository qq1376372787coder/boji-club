<?php
require_once dirname(__DIR__).'/public/storage-settings.php';
$storageLimits=storageRuntimeSettings($db);
$photoTotals=query('SELECT COALESCE(SUM(byte_size),0) AS bytes,COUNT(*) AS files FROM user_media')->fetch();
$recordTotals=query('SELECT COALESCE(SUM(byte_size),0) AS bytes,COUNT(*) AS parts,COUNT(DISTINCT user_id) AS users FROM cloud_parts')->fetch();
$diskFolder=is_dir(dirname(__DIR__).'/media')?dirname(__DIR__).'/media':dirname(__DIR__);
$diskFree=@disk_free_space($diskFolder);$diskTotal=@disk_total_space($diskFolder);
$members=query('SELECT m.user_id,m.files,m.bytes,COALESCE(JSON_UNQUOTE(JSON_EXTRACT(s.state_json,\'$.profile.nickname\')),p.nickname,\'未设置昵称\') nickname FROM (SELECT user_id,COUNT(*) files,SUM(byte_size) bytes FROM user_media GROUP BY user_id ORDER BY bytes DESC LIMIT 50) m LEFT JOIN profiles p ON p.user_id=m.user_id LEFT JOIN app_states s ON s.user_id=m.user_id ORDER BY m.bytes DESC')->fetchAll();
function storageSize(mixed $bytes): string {return is_numeric($bytes)?number_format((float)$bytes/1048576,1).' MB':'—';}
?>
<section class="card"><h2>照片与记录用量</h2><div class="profile-grid">
<div><small>全部照片</small><p><?=h(storageSize($photoTotals['bytes']))?> · <?=safeNumber($photoTotals['files'])?> 张</p></div>
<div><small>已分批存储的记录</small><p><?=h(storageSize($recordTotals['bytes']))?> · <?=safeNumber($recordTotals['parts'])?> 块 · <?=safeNumber($recordTotals['users'])?> 个账号</p></div>
<div><small>服务器磁盘可用 / 总量</small><p><?=h(storageSize($diskFree))?> / <?=h(storageSize($diskTotal))?></p></div>
</div><p class="muted">配额填0不限制账号的照片总量；真实磁盘不是无限空间。保留256MiB可用空间防止服务器写满，空间不足时保留本机照片并提示联系支持。单张JPEG附件仍最多4MiB，上传频率保护独立于总量配额。</p>
<?php if($diskFree!==false && $diskFree<1024*1024*1024):?><p class="error">可用空间不足1GB，请及时扩容或处理已备份的数据。</p><?php endif?>
</section>
<section class="card"><h2>账号照片设置</h2><p>所有账号使用此默认规则，两个总量上限当前可设为不限。保存立即生效，降低上限不会删除已有照片。</p>
<form method="post" data-confirm="确认保存照片空间和上传设置？"><input type="hidden" name="action" value="storage_capacity"><?php csrfField()?>
<div class="profile-grid">
<label>每账号照片空间（MB）<input type="number" name="storage_limit_mib" min="0" max="2147483647" step="1" value="<?=(int)ceil($storageLimits['media_storage_limit_bytes']/1048576)?>" required><small>0不限，2048约2GB。</small></label>
<label>每账号照片数量<input type="number" name="media_file_limit" min="0" max="2147483647" step="1" value="<?=$storageLimits['media_file_limit']?>" required><small>0不限；已满后替换已有照片仍按空间校验。</small></label>
<label>每分钟上传保护<input type="number" name="media_uploads_per_minute" min="1" max="2147483647" step="1" value="<?=$storageLimits['media_uploads_per_minute']?>" required><small>默认120，限制短时密集上传，文字同步仍可用。</small></label>
</div><label>操作原因<textarea name="reason" required minlength="2" maxlength="200"></textarea></label><button>保存照片设置</button></form></section>
<section class="card"><h2>照片用量最多的账号</h2><div class="table-wrap"><table><thead><tr><th>账号</th><th>昵称</th><th>照片数量</th><th>使用空间</th></tr></thead><tbody>
<?php foreach($members as $member):?><tr><td><a href="?p=user&amp;id=<?=(int)$member['user_id']?>"><?=h(clubNumber((int)$member['user_id']))?></a></td><td><?=h($member['nickname'])?></td><td><?=safeNumber($member['files'])?></td><td><?=h(storageSize($member['bytes']))?></td></tr><?php endforeach?>
</tbody></table></div><p class="muted">显示前50个账号；没有照片的账号不占此列表。</p></section>
